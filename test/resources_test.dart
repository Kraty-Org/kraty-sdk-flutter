import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:kraty/kraty.dart';
import 'package:flutter_test/flutter_test.dart';

/// Resource-client coverage (events.listForPlayer, grants.*,
/// inventory.*, wallet.*, players.register, lobbies.read, polling
/// helpers, X-Player-Secret injection, collectAll, error helpers).
///
/// Uses the same FakeClient pattern as `client_test.dart` so we can
/// assert on outgoing request shape (headers, body, query string)
/// without spinning up a real backend.

class FakeCall {
  FakeCall(this.method, this.url, this.headers, this.body);
  final String method;
  final String url;
  final Map<String, String> headers;
  final String? body;
}

class FakeClient extends http.BaseClient {
  final List<FakeCall> calls = [];
  final List<http.Response Function()> responses = [];

  FakeClient push(int status, {Object? body, Map<String, String>? headers}) {
    responses.add(() => http.Response(
          body == null ? '' : (body is String ? body : jsonEncode(body)),
          status,
          headers: <String, String>{'content-type': 'application/json', ...?headers},
        ));
    return this;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = request is http.Request ? request.body : null;
    final headers = Map<String, String>.fromEntries(
      request.headers.entries.map((e) => MapEntry(e.key.toLowerCase(), e.value)),
    );
    calls.add(FakeCall(
      request.method,
      request.url.toString(),
      headers,
      body == null || body.isEmpty ? null : body,
    ));
    if (responses.isEmpty) {
      throw StateError('FakeClient: out of responses');
    }
    final res = responses.removeAt(0)();
    return http.StreamedResponse(
      Stream.value(res.bodyBytes),
      res.statusCode,
      headers: res.headers,
    );
  }
}

const _apiKey = 'pUUVdrM8.djr4-0Iv9h1JvVNSMZNDmSsSN7lSVq2F9dG6DG4A5uQ';
const _baseUrl = 'https://api.test.kraty.io';

KratyClientOptions _opts(FakeClient client, {String? playerSecret}) {
  return KratyClientOptions(
    apiKey: _apiKey,
    baseUrl: _baseUrl,
    httpClient: client,
    playerSecret: playerSecret,
    generateIdempotencyKey: () => 'fixed-idem',
    retry: const KratyRetryConfig(
      attempts: 1,
      initialDelay: Duration(milliseconds: 1),
      maxDelay: Duration(milliseconds: 5),
      jitter: 0,
    ),
    timeout: const Duration(seconds: 1),
  );
}

void main() {
  group('events.listForPlayer', () {
    test('parses entryCost + entryRequirement + type + leaderboardMode + metrics', () async {
      final fake = FakeClient()
        ..push(200, body: {
          'data': [
            {
              'eventKey': 'bounty_hunt',
              'name': {'en': 'Bounty Hunt'},
              'windowId': 'w1',
              'startsAt': '2026-06-08T00:00:00Z',
              'endsAt': '2026-06-09T00:00:00Z',
              'leaderboardId': 'lb1',
              'currentAttemptId': null,
              'metadata': {},
              'type': 'single_metric',
              'leaderboardMode': 'global',
              'metrics': [
                {'key': 'bounties', 'target': 5, 'capAtTarget': true},
              ],
              'entryRequirement': null,
              'entryCost': {
                'currencies': [
                  {'key': 'cash', 'amount': 50},
                ],
                'items': [
                  {'key': 'bullet_basic', 'quantity': 1},
                ],
              },
            },
          ],
        });
      final kraty = Kraty(_opts(fake));
      final list = await kraty.events.listForPlayer(as: 'alice');
      expect(list, hasLength(1));
      final e = list.first;
      expect(e.eventKey, 'bounty_hunt');
      expect(e.type, 'single_metric');
      expect(e.leaderboardMode, 'global');
      expect(e.isLobbyMatched, isFalse);
      expect(e.metrics, hasLength(1));
      expect(e.metrics.first['key'], 'bounties');
      expect(e.entryCost, isNotNull);
      expect(e.entryCost!.currencies, hasLength(1));
      expect(e.entryCost!.currencies.first.key, 'cash');
      expect(e.entryCost!.currencies.first.amount, 50);
      expect(e.entryCost!.items, hasLength(1));
      expect(e.entryCost!.items.first.quantity, 1);
      expect(e.entryCost!.isEmpty, isFalse);
      expect(e.entryRequirement, isNull);
      kraty.close();
    });

    test('isLobbyMatched true when leaderboardMode is lobby_matched', () async {
      final fake = FakeClient()
        ..push(200, body: {
          'data': [
            {
              'eventKey': 'quick_brawl',
              'name': 'Quick Brawl',
              'windowId': 'w',
              'startsAt': '',
              'endsAt': '',
              'leaderboardId': null,
              'currentAttemptId': null,
              'metadata': {},
              'type': 'single_metric',
              'leaderboardMode': 'lobby_matched',
              'metrics': const <Object>[],
              'entryRequirement': null,
              'entryCost': null,
            },
          ],
        });
      final kraty = Kraty(_opts(fake));
      final list = await kraty.events.listForPlayer(as: 'alice');
      expect(list.first.isLobbyMatched, isTrue);
      kraty.close();
    });

    test('parses goal + unlockCondition + attemptDurationSeconds (null when absent)', () async {
      final fake = FakeClient()
        ..push(200, body: {
          'data': [
            {
              'eventKey': 'race',
              'windowId': 'w1',
              'startsAt': '',
              'endsAt': '',
              'goal': 10,
              'unlockCondition': {'type': 'level_at_least', 'level': 4},
              'attemptDurationSeconds': 300,
            },
            {'eventKey': 'old_backend', 'windowId': 'w2', 'startsAt': '', 'endsAt': ''},
          ],
        });
      final kraty = Kraty(_opts(fake));
      final list = await kraty.events.listForPlayer(as: 'alice');
      expect(list[0].goal, 10);
      expect(list[0].unlockCondition, {'type': 'level_at_least', 'level': 4});
      expect(list[0].attemptDurationSeconds, 300);
      expect(list[1].goal, isNull);
      expect(list[1].unlockCondition, isNull);
      expect(list[1].attemptDurationSeconds, isNull);
      kraty.close();
    });
  });

  group('leaderboards.list', () {
    test('GETs /sdk/v1/leaderboards and unwraps the summaries', () async {
      final fake = FakeClient()
        ..push(200, body: {
          'data': [
            {
              'key': 'weekly_band',
              'name': 'Weekly',
              'description': null,
              'resetCadence': 'weekly',
              'nextResetAt': '2026-10-05T00:00:00.000Z',
              'acceptClientScores': false,
              'contextSegments': ['level_band'],
            },
          ],
        });
      final kraty = Kraty(_opts(fake));
      final boards = await kraty.leaderboards.list();
      expect(fake.calls.single.method, 'GET');
      expect(fake.calls.single.url, '$_baseUrl/sdk/v1/leaderboards');
      expect(boards, hasLength(1));
      final b = boards.single;
      expect(b.key, 'weekly_band');
      expect(b.name, 'Weekly');
      expect(b.description, isNull);
      expect(b.resetCadence, 'weekly');
      expect(b.nextResetAt, '2026-10-05T00:00:00.000Z');
      expect(b.acceptClientScores, isFalse);
      expect(b.contextSegments, ['level_band']);
      kraty.close();
    });
  });

  group('players.register', () {
    test('POST with empty body returns PlayerRegistration', () async {
      final fake = FakeClient()
        ..push(201, body: {
          'data': {
            'playerId': 'pl-1',
            'externalPlayerId': 'alice',
            'secret': 'super-secret',
            'secretPrefix': 'super-se',
            'registeredAt': '2026-06-08T17:00:00Z',
          },
        });
      final kraty = Kraty(_opts(fake));
      final reg = await kraty.players.register('alice');
      expect(reg.secret, 'super-secret');
      expect(reg.externalPlayerId, 'alice');
      expect(reg.secretPrefix, 'super-se');
      expect(fake.calls.single.url, '$_baseUrl/sdk/v1/players/alice/register');
      expect(fake.calls.single.method, 'POST');
      kraty.close();
    });

    test('force=true appends ?force=true to the URL', () async {
      final fake = FakeClient()
        ..push(201, body: {
          'data': {
            'playerId': 'pl-1',
            'externalPlayerId': 'alice',
            'secret': 'rotated',
            'secretPrefix': 'rotated_',
            'registeredAt': '',
          },
        });
      final kraty = Kraty(_opts(fake));
      await kraty.players.register('alice', force: true);
      expect(fake.calls.single.url,
          '$_baseUrl/sdk/v1/players/alice/register?force=true');
      kraty.close();
    });

    test('409 surfaces as KratyApiError.isPlayerAlreadyRegistered', () async {
      final fake = FakeClient()
        ..push(409, body: {
          'error': {
            'code': 'player_already_registered',
            'message': 'already registered',
          },
        });
      final kraty = Kraty(_opts(fake));
      Object? caught;
      try {
        await kraty.players.register('alice');
      } catch (err) {
        caught = err;
      }
      expect(caught, isA<KratyApiError>());
      expect((caught! as KratyApiError).isPlayerAlreadyRegistered, isTrue);
      expect((caught as KratyApiError).code,
          KratyErrorCode.playerAlreadyRegistered);
      kraty.close();
    });
  });

  group('X-Player-Secret header injection', () {
    test('sent on every request when client has playerSecret', () async {
      final fake = FakeClient()
        ..push(200, body: {'data': []});
      final kraty = Kraty(_opts(fake, playerSecret: 'my-secret'));
      await kraty.events.listForPlayer(as: 'alice');
      expect(fake.calls.single.headers['x-player-secret'], 'my-secret');
      kraty.close();
    });

    test('absent when client has no playerSecret', () async {
      final fake = FakeClient()
        ..push(200, body: {'data': []});
      final kraty = Kraty(_opts(fake));
      await kraty.events.listForPlayer(as: 'alice');
      expect(fake.calls.single.headers.containsKey('x-player-secret'), isFalse);
      kraty.close();
    });

    test('absent when playerSecret is empty string', () async {
      final fake = FakeClient()
        ..push(200, body: {'data': []});
      final kraty = Kraty(_opts(fake, playerSecret: ''));
      await kraty.events.listForPlayer(as: 'alice');
      expect(fake.calls.single.headers.containsKey('x-player-secret'), isFalse);
      kraty.close();
    });
  });

  group('grants.* + collectAll', () {
    test('listPending parses Grant list', () async {
      final fake = FakeClient()
        ..push(200, body: {
          'data': [
            {
              'id': 'g1',
              'kind': 'reward',
              'contents': {'entries': []},
              'sourceKind': 'event_completion',
              'sourceRefId': null,
              'parentGrantId': null,
              'status': 'pending',
              'rolledAt': null,
              'claimedAt': null,
              'expiresAt': null,
              'createdAt': '2026-06-08T00:00:00Z',
            },
          ],
        });
      final kraty = Kraty(_opts(fake));
      final pending = await kraty.grants.listPending(as: 'alice');
      expect(pending, hasLength(1));
      expect(pending.first.id, 'g1');
      expect(pending.first.kind, 'reward');
      kraty.close();
    });

    test('collectAll opens crates + claims rewards in one sweep', () async {
      final fake = FakeClient()
        // listPending → 1 crate + 1 reward
        ..push(200, body: {
          'data': [
            {
              'id': 'crate-1',
              'kind': 'crate',
              'contents': {'crateItemKey': 'mystery'},
              'sourceKind': 'event_completion',
              'sourceRefId': null,
              'parentGrantId': null,
              'status': 'pending',
              'rolledAt': null,
              'claimedAt': null,
              'expiresAt': null,
              'createdAt': '',
            },
            {
              'id': 'reward-1',
              'kind': 'reward',
              'contents': {'entries': [{'type': 'currency', 'currencyKey': 'cash', 'amount': 100}]},
              'sourceKind': 'event_completion',
              'sourceRefId': null,
              'parentGrantId': null,
              'status': 'pending',
              'rolledAt': null,
              'claimedAt': null,
              'expiresAt': null,
              'createdAt': '',
            },
          ],
        })
        // open crate-1
        ..push(200, body: {
          'data': {
            'crate': {
              'id': 'crate-1',
              'kind': 'crate',
              'contents': {},
              'sourceKind': 'event_completion',
              'sourceRefId': null,
              'parentGrantId': null,
              'status': 'claimed',
              'rolledAt': '',
              'claimedAt': '',
              'expiresAt': null,
              'createdAt': '',
            },
            'contents': {
              'id': 'rolled-1',
              'kind': 'reward',
              'contents': {'entries': []},
              'sourceKind': 'crate_open',
              'sourceRefId': 'crate-1',
              'parentGrantId': 'crate-1',
              'status': 'pending',
              'rolledAt': '',
              'claimedAt': null,
              'expiresAt': null,
              'createdAt': '',
            },
          },
        })
        // claim reward-1
        ..push(200, body: {
          'data': {
            'id': 'reward-1',
            'kind': 'reward',
            'contents': {'entries': []},
            'sourceKind': 'event_completion',
            'sourceRefId': null,
            'parentGrantId': null,
            'status': 'claimed',
            'rolledAt': '',
            'claimedAt': '',
            'expiresAt': null,
            'createdAt': '',
          },
        });
      final kraty = Kraty(_opts(fake));
      final result = await kraty.grants.collectAll(as: 'alice');
      expect(result.processed, 2);
      expect(result.opened, hasLength(1));
      expect(result.opened.first.contents.id, 'rolled-1');
      expect(result.claimed, hasLength(1));
      expect(result.claimed.first.id, 'reward-1');
      expect(result.failures, isEmpty);
      expect(result.hasFailures, isFalse);
      // Three calls total: listPending, open, claim
      expect(fake.calls, hasLength(3));
      expect(fake.calls[0].url, contains('/pending-grants'));
      expect(fake.calls[1].url, contains('/crates/crate-1/open'));
      expect(fake.calls[2].url, contains('/grants/reward-1/claim'));
      kraty.close();
    });

    test('collectAll surfaces per-grant failures without aborting', () async {
      final fake = FakeClient()
        ..push(200, body: {
          'data': [
            {
              'id': 'good',
              'kind': 'reward',
              'contents': {'entries': []},
              'sourceKind': 'event_completion',
              'sourceRefId': null, 'parentGrantId': null, 'status': 'pending',
              'rolledAt': null, 'claimedAt': null, 'expiresAt': null, 'createdAt': '',
            },
            {
              'id': 'bad',
              'kind': 'reward',
              'contents': {'entries': []},
              'sourceKind': 'event_completion',
              'sourceRefId': null, 'parentGrantId': null, 'status': 'pending',
              'rolledAt': null, 'claimedAt': null, 'expiresAt': null, 'createdAt': '',
            },
          ],
        })
        ..push(200, body: {
          'data': {
            'id': 'good', 'kind': 'reward', 'contents': {'entries': []},
            'sourceKind': '', 'sourceRefId': null, 'parentGrantId': null,
            'status': 'claimed', 'rolledAt': '', 'claimedAt': '',
            'expiresAt': null, 'createdAt': '',
          },
        })
        // 2nd claim fails
        ..push(500, body: {
          'error': {'code': 'internal_error', 'message': 'oops'},
        });
      final kraty = Kraty(_opts(fake));
      final result = await kraty.grants.collectAll(as: 'alice');
      expect(result.processed, 2);
      expect(result.claimed, hasLength(1));
      expect(result.claimed.first.id, 'good');
      expect(result.failures, hasLength(1));
      expect(result.failures.first.grant.id, 'bad');
      expect(result.hasFailures, isTrue);
      kraty.close();
    });
  });

  group('dailyLogin.*', () {
    test('dailyLogin.read parses the calendar', () async {
      final fake = FakeClient()
        ..push(200, body: {
          'data': {
            'days': [
              {
                'day': 1,
                'entries': [
                  {'type': 'currency', 'currencyKey': 'gems', 'amount': 10},
                ],
              },
            ],
            'afterLastDay': 'restart',
            'itemKey': 'login_calendar',
            'loginStreak': 1,
            'currentDay': 1,
            'paidToday': true,
            'todayGrantId': 'g-1',
            'nextDayAt': '2030-01-08T00:00:00.000Z',
          },
        });
      final kraty = Kraty(_opts(fake));
      final cal = await kraty.dailyLogin.read(as: 'alice');
      expect(cal, isNotNull);
      expect(cal!.currentDay, 1);
      expect(cal.paidToday, isTrue);
      expect(cal.todayGrantId, 'g-1');
      expect(cal.days.single.entries.single['currencyKey'], 'gems');
      expect(fake.calls.single.url, endsWith('/sdk/v1/players/alice/daily-login'));
      kraty.close();
    });

    test('dailyLogin.read returns null without a calendar', () async {
      final fake = FakeClient()..push(200, body: {'data': null});
      final kraty = Kraty(_opts(fake));
      expect(await kraty.dailyLogin.read(as: 'alice'), isNull);
      kraty.close();
    });
  });

  group('guilds.*', () {
    const g = '0b8a6c56-49bd-4d5a-9d38-1f2b6a5f9b3e';

    test('guilds.mine returns null when guildless, parses roster + role + week otherwise', () async {
      final fake = FakeClient()
        ..push(200, body: {'data': null})
        ..push(200, body: {
          'data': {
            'guild': {
              'guildId': g,
              'name': 'Owls',
              'joinType': 'open',
              'memberCount': 1,
              'maxMembers': 50,
              'metadata': <String, Object?>{},
              'leader': {'externalPlayerId': 'alice', 'displayIdentity': null},
              'createdAt': '2026-10-01T00:00:00.000Z',
              'members': [
                {
                  'externalPlayerId': 'alice',
                  'displayIdentity': {'name': 'Alice'},
                  'role': 'leader',
                  'joinedAt': '2026-10-01T00:00:00.000Z',
                  'lastSeenAt': null,
                  'online': true,
                  'weeklyHelps': 2,
                },
              ],
            },
            'membership': {'role': 'leader', 'joinedAt': 'x', 'permissions': ['kick', 'promote']},
          },
        });
      final kraty = Kraty(_opts(fake));
      expect(await kraty.guilds.mine(as: 'alice'), isNull);
      final mine = await kraty.guilds.mine(as: 'alice');
      expect(mine!.guild.summary.maxMembers, 50);
      expect(mine.guild.members.single.weeklyHelps, 2);
      expect(mine.permissions, ['kick', 'promote']);
      expect(fake.calls.first.url, endsWith('/sdk/v1/players/alice/guild'));
      kraty.close();
    });

    test('guilds.search / recommended build query strings', () async {
      final fake = FakeClient()
        ..push(200, body: {
          'data': {
            'guilds': [
              {'guildId': g, 'name': 'Owls', 'friendCount': 2},
            ],
          },
        })
        ..push(200, body: {'data': {'guilds': <Object?>[]}});
      final kraty = Kraty(_opts(fake));
      final found = await kraty.guilds.search('night owls', country: 'US', as: 'alice');
      expect(found.single.friendCount, 2);
      await kraty.guilds.recommended(limit: 5, as: 'alice');
      expect(fake.calls[0].url, endsWith('/guilds?q=night+owls&country=US'));
      expect(fake.calls[1].url, endsWith('/guilds/recommended?limit=5'));
      kraty.close();
    });

    test('guilds.create / join send bodies; officer actions target members', () async {
      final fake = FakeClient()
        ..push(201, body: {
          'data': {
            'guild': {'guildId': g, 'members': <Object?>[]},
            'membership': {'role': 'leader', 'permissions': <Object?>[]},
            'week': <String, Object?>{},
          },
        })
        ..push(201, body: {
          'data': {
            'status': 'requested',
            'request': {'requestId': 'r1', 'guild': {'guildId': g, 'name': 'Owls'}, 'status': 'pending'},
          },
        })
        ..push(200, body: {'data': {'guildId': g, 'members': <Object?>[]}});
      final kraty = Kraty(_opts(fake));
      final created = await kraty.guilds.create(name: 'Owls', joinType: 'request', as: 'alice');
      expect(created.guild.guildId, g);
      final joined = await kraty.guilds.join(g, message: 'hi', as: 'bob');
      expect(joined.status, 'requested');
      expect(joined.request!.guildName, 'Owls');
      await kraty.guilds.kick('carol 1', as: 'alice');
      final createBody = jsonDecode(fake.calls[0].body!) as Map<String, Object?>;
      expect(createBody['name'], 'Owls');
      expect(createBody.containsKey('description'), isFalse);
      expect(fake.calls[1].url, endsWith('/sdk/v1/players/bob/guilds/$g/join'));
      expect(fake.calls[2].url, endsWith('/guild/members/carol%201/kick'));
      kraty.close();
    });

    test('guilds.donate', () async {
      final fake = FakeClient()
        ..push(201, body: {
          'data': {
            'donationId': 'd1',
            'requestId': 'h1',
            'amount': 1,
            'grantId': 'gr1',
            'rewardGrantId': null,
            'request': {'requestId': 'h1', 'status': 'open'},
            'week': {'donationsMade': 1, 'donationLimit': 20},
          },
        });
      final kraty = Kraty(_opts(fake));
      final d = await kraty.guilds.donate('h1', amount: 1, as: 'alice');
      expect(d.donationId, 'd1');
      expect(d.rewardGrantId, isNull);
      kraty.close();
    });
  });

  group('chat.*', () {
    const c = '6f1d2c3b-4a5e-4f60-8a71-9b8c7d6e5f40';
    const m = '1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d';
    final uuidRe = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');

    KratyClientOptions chatOpts(FakeClient fake, {bool? filter}) => KratyClientOptions(
          apiKey: _apiKey,
          baseUrl: _baseUrl,
          httpClient: fake,
          playerSecret: 'sek',
          generateIdempotencyKey: () => 'fixed-idem',
          retry: const KratyRetryConfig(attempts: 1),
          timeout: const Duration(seconds: 1),
          chatProfanityFilter: filter,
        );

    Map<String, Object?> message({int seq = 1, String? clientMessageId, String text = 'hello ****', String? editedAt}) =>
        <String, Object?>{
          'messageId': m,
          'conversationId': c,
          'seq': seq,
          'type': 'text',
          'sender': <String, Object?>{
            'kind': 'player',
            'player': <String, Object?>{
              'externalPlayerId': 'bob',
              'displayIdentity': <String, Object?>{'name': 'Bob', 'country': 'PT'},
            },
          },
          'text': text,
          'filtered': true,
          'customType': null,
          'payload': null,
          'replyToId': null,
          'clientMessageId': clientMessageId,
          'createdAt': '2026-10-15T10:00:00.000Z',
          'editedAt': editedAt,
          'deleted': false,
        };

    Map<String, Object?> conversation({String kind = 'direct', List<Object?>? members}) => <String, Object?>{
          'conversationId': c,
          'kind': kind,
          'title': kind == 'direct' ? null : 'Squad',
          'metadata': <String, Object?>{'emoji': 'owl'},
          'memberCount': 2,
          'lastSeq': 7,
          'lastMessageAt': '2026-10-15T10:00:00.000Z',
          'lastMessage': message(seq: 7),
          'unreadCount': 3,
          'lastReadSeq': 4,
          'mutedUntil': null,
          'peer': kind == 'direct'
              ? <String, Object?>{'externalPlayerId': 'bob', 'displayIdentity': null, 'online': true}
              : null,
          'guildId': null,
          'channel': null,
          'role': kind == 'group' ? 'owner' : null,
          'canPost': false,
          'postDenied': <String, Object?>{
            'code': 'chat_direct_not_allowed',
            'message': 'friends only',
            'details': <String, Object?>{'policy': 'friends'},
          },
          'canModerate': false,
          'filterMode': 'on_by_default',
          'createdAt': '2026-10-01T00:00:00.000Z',
          if (members != null) 'members': members,
        };

    test('config parses kinds, channels, messages, preferences and status; sends the filter header', () async {
      final fake = FakeClient()
        ..push(200, body: <String, Object?>{
          'data': <String, Object?>{
            'kinds': <String, Object?>{
              'direct': <String, Object?>{'enabled': true, 'profanityFilter': 'on_by_default', 'allowFrom': 'friends'},
              'group': <String, Object?>{
                'enabled': true,
                'profanityFilter': 'always',
                'maxMembers': 20,
                'maxGroupsPerPlayer': 5,
                'invitePolicy': 'friends',
              },
              'channel': <String, Object?>{'enabled': false, 'profanityFilter': 'always'},
            },
            'channels': <Object?>[
              <String, Object?>{
                'key': 'global',
                'name': 'Global',
                'description': null,
                'postPolicy': 'players',
                'slowModeSeconds': 5,
                'requirement': <String, Object?>{'itemKey': 'level', 'threshold': 3},
                'metadata': <String, Object?>{},
                'profanityFilter': 'always',
              },
            ],
            'messages': <String, Object?>{
              'maxLength': 500,
              'allowLinks': false,
              'customTypes': <Object?>[
                <String, Object?>{'key': 'match_invite', 'description': null, 'maxPayloadBytes': 1024, 'schema': null},
              ],
              'editWindowSeconds': 300,
            },
            'rateLimit': <String, Object?>{'messagesPerMinute': 20},
            'preferences': <String, Object?>{'profanityFilter': null, 'allowDirectFrom': 'everyone'},
            'status': <String, Object?>{
              'canChat': true,
              'canPost': false,
              'mutedUntil': '2026-10-16T00:00:00.000Z',
              'chatBannedUntil': null,
              'restrictions': <Object?>[
                <String, Object?>{
                  'restrictionId': 'r1',
                  'kind': 'chat_mute',
                  'reason': 'spam',
                  'source': 'auto',
                  'createdAt': 'x',
                  'expiresAt': '2026-10-16T00:00:00.000Z',
                  'liftedAt': null,
                  'acknowledgedAt': null,
                  'active': true,
                  'reportId': null,
                },
              ],
            },
          },
        });
      final kraty = Kraty(chatOpts(fake, filter: false));
      final cfg = await kraty.chat.config(as: 'alice');
      expect(fake.calls.single.method, 'GET');
      expect(fake.calls.single.url, '$_baseUrl/sdk/v1/players/alice/chat/config');
      expect(fake.calls.single.headers['x-kraty-chat-filter'], 'off');
      expect(fake.calls.single.headers['x-player-secret'], 'sek');
      expect(cfg.kindEnabled('group'), isTrue);
      expect(cfg.kindEnabled('channel'), isFalse);
      expect(cfg.kindEnabled('nope'), isFalse);
      expect(cfg.kinds['group']!.profanityFilter, 'always');
      expect(cfg.kinds['group']!.settings['maxMembers'], 20);
      expect(cfg.kinds['direct']!.settings['allowFrom'], 'friends');
      expect(cfg.channels.single.requirement!.threshold, 3);
      expect(cfg.channels.single.profanityFilter, 'always');
      expect(cfg.maxLength, 500);
      expect(cfg.allowLinks, isFalse);
      expect(cfg.customTypes.single.key, 'match_invite');
      expect(cfg.editWindowSeconds, 300);
      expect(cfg.messagesPerMinute, 20);
      expect(cfg.preferences.profanityFilter, isNull);
      expect(cfg.preferences.allowDirectFrom, 'everyone');
      expect(cfg.status.canPost, isFalse);
      expect(cfg.status.restrictions.single.kind, 'chat_mute');
      kraty.close();
    });

    test('filter header: on when true, absent when unset', () async {
      final on = FakeClient()..push(200, body: <String, Object?>{'data': <String, Object?>{'total': 0}});
      final unset = FakeClient()..push(200, body: <String, Object?>{'data': <String, Object?>{'total': 0}});
      final a = Kraty(chatOpts(on, filter: true));
      final b = Kraty(chatOpts(unset));
      await a.chat.unread(as: 'alice');
      await b.chat.unread(as: 'alice');
      expect(on.calls.single.headers['x-kraty-chat-filter'], 'on');
      expect(unset.calls.single.headers.containsKey('x-kraty-chat-filter'), isFalse);
      a.close();
      b.close();
    });

    test('conversations builds the query and parses the page (message, peer, postDenied)', () async {
      final fake = FakeClient()
        ..push(200, body: <String, Object?>{
          'data': <String, Object?>{
            'conversations': <Object?>[conversation()],
            'nextOffset': 20,
          },
        });
      final kraty = Kraty(chatOpts(fake));
      final page = await kraty.chat.conversations(kind: 'direct', limit: 20, offset: 0, as: 'alice');
      expect(fake.calls.single.url, endsWith('/sdk/v1/players/alice/chat/conversations?kind=direct&limit=20'));
      expect(page.nextOffset, 20);
      final conv = page.conversations.single;
      expect(conv.kind, 'direct');
      expect(conv.title, isNull);
      expect(conv.metadata['emoji'], 'owl');
      expect(conv.peer!.externalPlayerId, 'bob');
      expect(conv.peer!.online, isTrue);
      expect(conv.unreadCount, 3);
      expect(conv.lastReadSeq, 4);
      expect(conv.canPost, isFalse);
      expect(conv.postDenied!.code, 'chat_direct_not_allowed');
      expect(conv.postDenied!.details!['policy'], 'friends');
      expect(conv.filterMode, 'on_by_default');
      expect(conv.members, isNull);
      final last = conv.lastMessage!;
      expect(last.seq, 7);
      expect(last.filtered, isTrue);
      expect(last.sender.kind, 'player');
      expect(last.sender.player!.displayIdentity!.name, 'Bob');
      kraty.close();
    });

    test('unread, channels, channel, guild, conversation', () async {
      final fake = FakeClient()
        ..push(200, body: <String, Object?>{
          'data': <String, Object?>{'total': 5, 'conversations': 2, 'byKind': <String, Object?>{'direct': 3, 'guild': 2}},
        })
        ..push(200, body: <String, Object?>{
          'data': <String, Object?>{
            'channels': <Object?>[
              <String, Object?>{
                ...conversation(kind: 'channel'),
                'channel': <String, Object?>{
                  'key': 'global',
                  'name': 'Global',
                  'description': 'Everyone',
                  'postPolicy': 'server_only',
                  'slowModeSeconds': 0,
                  'requirement': null,
                  'metadata': <String, Object?>{'lang': 'en'},
                },
              },
            ],
          },
        })
        ..push(200, body: <String, Object?>{'data': conversation(kind: 'channel')})
        ..push(200, body: <String, Object?>{'data': <String, Object?>{...conversation(kind: 'guild'), 'guildId': 'g1'}})
        ..push(200, body: <String, Object?>{
          'data': conversation(kind: 'group', members: <Object?>[
            <String, Object?>{
              'externalPlayerId': 'alice',
              'displayIdentity': null,
              'role': 'owner',
              'joinedAt': 'x',
              'online': false,
            },
          ]),
        });
      final kraty = Kraty(chatOpts(fake));
      final unread = await kraty.chat.unread(as: 'alice');
      expect(unread.total, 5);
      expect(unread.conversations, 2);
      expect(unread.byKind, <String, int>{'direct': 3, 'guild': 2});
      final channels = await kraty.chat.channels(as: 'alice');
      expect(channels.single.channel!.postPolicy, 'server_only');
      expect(channels.single.channel!.requirement, isNull);
      expect(channels.single.channel!.metadata['lang'], 'en');
      await kraty.chat.channel('es mx', as: 'alice');
      final guild = await kraty.chat.guild(as: 'alice');
      expect(guild.guildId, 'g1');
      final group = await kraty.chat.conversation(c, as: 'alice');
      expect(group.role, 'owner');
      expect(group.members!.single.role, 'owner');
      expect(fake.calls.map((x) => x.url.replaceFirst('$_baseUrl/sdk/v1/players/alice/chat', '')).toList(), <String>[
        '/unread',
        '/channels',
        '/channels/es%20mx',
        '/guild',
        '/conversations/$c',
      ]);
      expect(fake.calls.every((x) => x.method == 'GET'), isTrue);
      kraty.close();
    });

    test('send auto-generates a UUID clientMessageId; an explicit one is kept', () async {
      final fake = FakeClient()
        ..push(201, body: <String, Object?>{'data': message(clientMessageId: 'auto')})
        ..push(201, body: <String, Object?>{'data': message(clientMessageId: 'auto2')})
        ..push(201, body: <String, Object?>{'data': message(clientMessageId: 'mine')});
      final kraty = Kraty(chatOpts(fake, filter: true));
      final sent = await kraty.chat.send(c, 'hello', as: 'alice');
      await kraty.chat.send(c, 'again', as: 'alice');
      await kraty.chat.send(c, 'reply', replyToId: m, clientMessageId: 'mine', as: 'alice');
      expect(sent.text, 'hello ****');
      expect(sent.clientMessageId, 'auto');
      final first = jsonDecode(fake.calls[0].body!) as Map<String, Object?>;
      final second = jsonDecode(fake.calls[1].body!) as Map<String, Object?>;
      final third = jsonDecode(fake.calls[2].body!) as Map<String, Object?>;
      expect(fake.calls[0].method, 'POST');
      expect(fake.calls[0].url, endsWith('/sdk/v1/players/alice/chat/conversations/$c/messages'));
      expect(fake.calls[0].headers['x-kraty-chat-filter'], 'on');
      expect(first['type'], 'text');
      expect(first['text'], 'hello');
      expect(first['idempotencyKey'], 'fixed-idem');
      expect(first.containsKey('replyToId'), isFalse);
      expect(first['clientMessageId'], matches(uuidRe));
      expect(second['clientMessageId'], matches(uuidRe));
      expect(second['clientMessageId'], isNot(first['clientMessageId']));
      expect(third['clientMessageId'], 'mine');
      expect(third['replyToId'], m);
      kraty.close();
    });

    test('sendCustom sends the card; system/custom fields parse', () async {
      final fake = FakeClient()
        ..push(201, body: <String, Object?>{
          'data': <String, Object?>{
            ...message(),
            'type': 'custom',
            'text': null,
            'filtered': false,
            'customType': 'match_invite',
            'payload': <String, Object?>{'matchId': 'mm1'},
          },
        });
      final kraty = Kraty(chatOpts(fake));
      final card = await kraty.chat.sendCustom(c, 'match_invite', <String, Object?>{'matchId': 'mm1'},
          text: 'join me', as: 'alice');
      final body = jsonDecode(fake.calls.single.body!) as Map<String, Object?>;
      expect(body['type'], 'custom');
      expect(body['customType'], 'match_invite');
      expect(body['payload'], <String, Object?>{'matchId': 'mm1'});
      expect(body['text'], 'join me');
      expect(body['clientMessageId'], matches(uuidRe));
      expect(card.type, 'custom');
      expect(card.text, isNull);
      expect(card.customType, 'match_invite');
      expect(card.payloadMap!['matchId'], 'mm1');
      kraty.close();
    });

    test('messages pages with before / after / limit; both throws', () async {
      final fake = FakeClient()
        ..push(200, body: <String, Object?>{
          'data': <String, Object?>{'messages': <Object?>[message(seq: 8), message(seq: 9)], 'hasMore': true},
        })
        ..push(200, body: <String, Object?>{'data': <String, Object?>{'messages': <Object?>[], 'hasMore': false}});
      final kraty = Kraty(chatOpts(fake));
      final page = await kraty.chat.messages(c, after: 7, limit: 2, as: 'alice');
      expect(page.messages.map((x) => x.seq), <int>[8, 9]);
      expect(page.hasMore, isTrue);
      await kraty.chat.messages(c, before: 8, as: 'alice');
      expect(fake.calls[0].url, endsWith('/conversations/$c/messages?after=7&limit=2'));
      expect(fake.calls[1].url, endsWith('/conversations/$c/messages?before=8'));
      expect(() => kraty.chat.messages(c, before: 1, after: 2, as: 'alice'), throwsArgumentError);
      kraty.close();
    });

    test('openDirect / createGroup / updateGroup / members / role / leave send the right verbs and bodies', () async {
      final fake = FakeClient()
        ..push(200, body: <String, Object?>{'data': conversation()})
        ..push(200, body: <String, Object?>{'data': conversation()})
        ..push(201, body: <String, Object?>{'data': conversation(kind: 'group', members: <Object?>[])})
        ..push(200, body: <String, Object?>{'data': conversation(kind: 'group', members: <Object?>[])})
        ..push(200, body: <String, Object?>{'data': conversation(kind: 'group', members: <Object?>[])})
        ..push(200, body: <String, Object?>{'data': <String, Object?>{'conversationId': c, 'removed': 'carol'}})
        ..push(200, body: <String, Object?>{'data': conversation(kind: 'group', members: <Object?>[])})
        ..push(200, body: <String, Object?>{'data': <String, Object?>{'conversationId': c, 'left': true}});
      final kraty = Kraty(chatOpts(fake));
      await kraty.chat.openDirect(externalPlayerId: 'bob', as: 'alice');
      await kraty.chat.openDirect(friendCode: 'ABC123', as: 'alice');
      final group = await kraty.chat.createGroup(title: 'Squad', externalPlayerIds: <String>['bob'], as: 'alice');
      expect(group.members, isEmpty);
      await kraty.chat.updateGroup(c, title: 'Squad 2', as: 'alice');
      await kraty.chat.addMembers(c, <String>['carol'], as: 'alice');
      await kraty.chat.removeMember(c, 'carol', as: 'alice');
      await kraty.chat.setRole(c, 'bob', 'admin', as: 'alice');
      await kraty.chat.leave(c, as: 'alice');

      final calls = fake.calls;
      Map<String, Object?> body(int i) => jsonDecode(calls[i].body!) as Map<String, Object?>;
      String path(int i) => calls[i].url.replaceFirst('$_baseUrl/sdk/v1/players/alice/chat', '');
      expect(calls.map((x) => x.method).toList(),
          <String>['POST', 'POST', 'POST', 'PATCH', 'POST', 'DELETE', 'PUT', 'POST']);
      expect(path(0), '/direct');
      expect(body(0)['externalPlayerId'], 'bob');
      expect(body(0).containsKey('friendCode'), isFalse);
      expect(body(1)['friendCode'], 'ABC123');
      expect(path(2), '/groups');
      expect(body(2)['title'], 'Squad');
      expect(body(2)['externalPlayerIds'], <Object?>['bob']);
      expect(body(2).containsKey('metadata'), isFalse);
      expect(path(3), '/conversations/$c');
      expect(body(3)['title'], 'Squad 2');
      expect(body(3).containsKey('metadata'), isFalse);
      expect(path(4), '/conversations/$c/members');
      expect(body(4)['externalPlayerIds'], <Object?>['carol']);
      expect(path(5), '/conversations/$c/members/carol');
      expect(calls[5].body, isNull);
      expect(path(6), '/conversations/$c/members/bob/role');
      expect(body(6)['role'], 'admin');
      expect(path(7), '/conversations/$c/leave');
      expect(() => kraty.chat.openDirect(as: 'alice'), throwsArgumentError);
      expect(() => kraty.chat.openDirect(externalPlayerId: 'a', friendCode: 'b', as: 'alice'), throwsArgumentError);
      kraty.close();
    });

    test('editMessage PATCHes the text and parses editedAt', () async {
      final fake = FakeClient()
        ..push(200, body: <String, Object?>{
          'data': message(seq: 4, text: 'fixed', editedAt: '2026-10-15T10:01:00.000Z'),
        });
      final kraty = Kraty(chatOpts(fake, filter: true));
      final edited = await kraty.chat.editMessage(c, m, 'fixed', as: 'alice');
      final call = fake.calls.single;
      expect(call.method, 'PATCH');
      expect(call.url, '$_baseUrl/sdk/v1/players/alice/chat/conversations/$c/messages/$m');
      final body = jsonDecode(call.body!) as Map<String, Object?>;
      expect(body['text'], 'fixed');
      expect(body.keys.where((k) => k != 'idempotencyKey'), <String>['text']);
      expect(call.headers['x-kraty-chat-filter'], 'on');
      expect(edited.text, 'fixed');
      expect(edited.editedAt, '2026-10-15T10:01:00.000Z');
      expect(edited.edited, isTrue);
      expect(ChatMessage.fromJson(message()).editedAt, isNull);
      expect(ChatMessage.fromJson(message()).edited, isFalse);
      kraty.close();
    });

    test('chat_edit_not_allowed surfaces as KratyApiError.isChatEditNotAllowed', () async {
      final fake = FakeClient()
        ..push(403, body: <String, Object?>{
          'error': <String, Object?>{'code': 'chat_edit_not_allowed', 'message': 'the edit window has passed'},
        });
      final kraty = Kraty(chatOpts(fake));
      try {
        await kraty.chat.editMessage(c, m, 'late', as: 'alice');
        fail('expected KratyApiError');
      } on KratyApiError catch (err) {
        expect(err.status, 403);
        expect(err.code, KratyErrorCode.chatEditNotAllowed);
        expect(err.isChatEditNotAllowed, isTrue);
      }
      kraty.close();
    });

    test('deleteMessage / markRead / typing / settings / preferences', () async {
      final fake = FakeClient()
        ..push(200, body: <String, Object?>{'data': <String, Object?>{'messageId': m, 'deleted': true}})
        ..push(200, body: <String, Object?>{'data': <String, Object?>{'lastReadSeq': 7}})
        ..push(200, body: <String, Object?>{'data': <String, Object?>{'ok': true}})
        ..push(200, body: <String, Object?>{'data': conversation()})
        ..push(200, body: <String, Object?>{'data': conversation()})
        ..push(200, body: <String, Object?>{'data': <String, Object?>{'profanityFilter': null, 'allowDirectFrom': 'friends'}})
        ..push(200, body: <String, Object?>{'data': <String, Object?>{'profanityFilter': false, 'allowDirectFrom': 'friends'}})
        ..push(200, body: <String, Object?>{'data': <String, Object?>{'profanityFilter': false, 'allowDirectFrom': 'nobody'}});
      final kraty = Kraty(chatOpts(fake));
      await kraty.chat.deleteMessage(c, m, as: 'alice');
      expect(await kraty.chat.markRead(c, 9, as: 'alice'), 7);
      await kraty.chat.typing(c, as: 'alice');
      await kraty.chat.setConversationSettings(c,
          mutedUntil: DateTime.utc(2026, 10, 16, 12, 0, 0, 0, 123), hidden: true, as: 'alice');
      await kraty.chat.setConversationSettings(c, unmute: true, as: 'alice');
      final reset = await kraty.chat.setPreferences(resetProfanityFilter: true, as: 'alice');
      expect(reset.profanityFilter, isNull);
      final off = await kraty.chat.setPreferences(profanityFilter: false, as: 'alice');
      expect(off.profanityFilter, isFalse);
      final prefs = await kraty.chat.preferences(as: 'alice');
      expect(prefs.allowDirectFrom, 'nobody');

      final calls = fake.calls;
      Map<String, Object?> body(int i) => jsonDecode(calls[i].body!) as Map<String, Object?>;
      String path(int i) => calls[i].url.replaceFirst('$_baseUrl/sdk/v1/players/alice/chat', '');
      expect(calls.map((x) => x.method).toList(), <String>['DELETE', 'POST', 'POST', 'PUT', 'PUT', 'PUT', 'PUT', 'GET']);
      expect(path(0), '/conversations/$c/messages/$m');
      expect(path(1), '/conversations/$c/read');
      expect(body(1)['seq'], 9);
      expect(path(2), '/conversations/$c/typing');
      expect(path(3), '/conversations/$c/settings');
      expect(body(3)['mutedUntil'], '2026-10-16T12:00:00.000Z');
      expect(body(3)['hidden'], isTrue);
      expect(body(4).containsKey('mutedUntil'), isTrue);
      expect(body(4)['mutedUntil'], isNull);
      expect(body(4).containsKey('hidden'), isFalse);
      expect(path(5), '/preferences');
      expect(body(5).containsKey('profanityFilter'), isTrue);
      expect(body(5)['profanityFilter'], isNull);
      expect(body(6)['profanityFilter'], isFalse);
      expect(body(6).containsKey('allowDirectFrom'), isFalse);
      expect(path(7), '/preferences');
      kraty.close();
    });

    test('chat_disabled surfaces as KratyApiError.isChatDisabled', () async {
      final fake = FakeClient()
        ..push(403, body: <String, Object?>{
          'error': <String, Object?>{'code': 'chat_disabled', 'message': 'chat is not enabled for this game'},
        });
      final kraty = Kraty(chatOpts(fake));
      try {
        await kraty.chat.config(as: 'alice');
        fail('expected KratyApiError');
      } on KratyApiError catch (err) {
        expect(err.status, 403);
        expect(err.isChatDisabled, isTrue);
        expect(err.isChatMuted, isFalse);
      }
      kraty.close();
    });

    test('live opens the SSE stream with channels + filter and maps every event', () async {
      String ev(String kind, Map<String, Object?> data) => 'event: $kind\ndata: ${jsonEncode(data)}\n\n';
      final sse = StringBuffer()
        ..write(ev('ready', <String, Object?>{
          'externalPlayerId': 'alice',
          'conversationIds': <Object?>[c],
          'channels': <Object?>[
            <String, Object?>{'key': 'global', 'conversationId': 'ch1'},
          ],
        }))
        ..write(': ping 1\n\n')
        ..write(ev('message', message(seq: 10)))
        ..write(ev('message_edited', message(seq: 10, text: 'edited', editedAt: '2026-10-15T10:05:00.000Z')))
        ..write(ev('message_deleted', <String, Object?>{'conversationId': c, 'messageId': m, 'seq': 10}))
        ..write(ev('typing', <String, Object?>{
          'conversationId': c,
          'player': <String, Object?>{'externalPlayerId': 'bob', 'displayIdentity': null},
        }))
        ..write(ev('read', <String, Object?>{'conversationId': c, 'externalPlayerId': 'bob', 'seq': 9}))
        ..write(ev('conversation_added', <String, Object?>{'conversationId': 'c2', 'kind': 'group'}))
        ..write(ev('conversation_updated', <String, Object?>{
          'conversationId': 'c2',
          'title': 'New name',
          'metadata': <String, Object?>{'a': 1},
          'memberCount': 4,
        }))
        ..write(ev('conversation_removed', <String, Object?>{'conversationId': 'c2', 'reason': 'removed'}))
        ..write(ev('restriction', <String, Object?>{
          'restrictionId': 'r1',
          'kind': 'chat_mute',
          'reason': 'spam',
          'expiresAt': '2026-10-16T00:00:00.000Z',
        }))
        ..write(ev('restriction_lifted', <String, Object?>{'restrictionId': 'r1', 'kind': 'chat_mute'}))
        ..write(ev('something_new', <String, Object?>{'x': 1}))
        ..write(ev('close', <String, Object?>{'reason': 'draining'}));
      final fake = FakeClient()..push(200, body: sse.toString(), headers: <String, String>{'content-type': 'text/event-stream'});
      final kraty = Kraty(chatOpts(fake, filter: false));
      final stream = await kraty.chat.live(channels: <String>['global', 'es'], as: 'alice');
      final events = await stream.events.toList();
      await stream.cancel();

      final call = fake.calls.single;
      expect(call.method, 'GET');
      expect(call.url, '$_baseUrl/sdk/v1/players/alice/chat/stream?channels=global%2Ces&filter=off');
      expect(call.headers['x-kraty-chat-filter'], 'off');
      expect(call.headers['accept'], 'text/event-stream');
      expect(call.headers['x-player-secret'], 'sek');

      expect(events.map((e) => e.kind).toList(), <String>[
        'ready',
        'message',
        'message_edited',
        'message_deleted',
        'typing',
        'read',
        'conversation_added',
        'conversation_updated',
        'conversation_removed',
        'restriction',
        'restriction_lifted',
        'something_new',
        'close',
      ]);
      final ready = events[0] as ChatReadyEvent;
      expect(ready.externalPlayerId, 'alice');
      expect(ready.conversationIds, <String>[c]);
      expect(ready.channels.single.key, 'global');
      expect(ready.channels.single.conversationId, 'ch1');
      expect((events[1] as ChatMessageEvent).message.seq, 10);
      expect((events[1] as ChatMessageEvent).message.sender.player!.externalPlayerId, 'bob');
      expect((events[1] as ChatMessageEvent).message.editedAt, isNull);
      final edited = events[2] as ChatMessageEditedEvent;
      expect(edited.message.messageId, m);
      expect(edited.message.text, 'edited');
      expect(edited.message.editedAt, '2026-10-15T10:05:00.000Z');
      final deleted = events[3] as ChatMessageDeletedEvent;
      expect(deleted.messageId, m);
      expect(deleted.seq, 10);
      expect((events[4] as ChatTypingEvent).player!.externalPlayerId, 'bob');
      expect((events[5] as ChatReadEvent).seq, 9);
      expect((events[6] as ChatConversationAddedEvent).conversationKind, 'group');
      final updated = events[7] as ChatConversationUpdatedEvent;
      expect(updated.title, 'New name');
      expect(updated.metadata['a'], 1);
      expect(updated.memberCount, 4);
      expect((events[8] as ChatConversationRemovedEvent).reason, 'removed');
      final restriction = events[9] as ChatRestrictionEvent;
      expect(restriction.restrictionKind, 'chat_mute');
      expect(restriction.reason, 'spam');
      expect(restriction.expiresAt, '2026-10-16T00:00:00.000Z');
      expect((events[10] as ChatRestrictionLiftedEvent).restrictionId, 'r1');
      expect(events[11], isA<ChatUnknownEvent>());
      expect((events[12] as ChatCloseEvent).reason, 'draining');
      kraty.close();
    });

    test('live without channels or a filter choice sends a bare URL', () async {
      final fake = FakeClient()..push(200, body: '');
      final kraty = Kraty(chatOpts(fake));
      final stream = await kraty.chat.live(as: 'alice');
      await stream.events.toList();
      expect(fake.calls.single.url, '$_baseUrl/sdk/v1/players/alice/chat/stream');
      expect(fake.calls.single.headers.containsKey('x-kraty-chat-filter'), isFalse);
      kraty.close();
    });
  });

  group('moderation.*', () {
    KratyClientOptions modOpts(FakeClient fake) => KratyClientOptions(
          apiKey: _apiKey,
          baseUrl: _baseUrl,
          httpClient: fake,
          generateIdempotencyKey: () => 'fixed-idem',
          retry: const KratyRetryConfig(attempts: 1),
          timeout: const Duration(seconds: 1),
          chatProfanityFilter: true,
        );

    Map<String, Object?> report() => <String, Object?>{
          'reportId': 'rep1',
          'targetExternalPlayerId': 'bob',
          'category': 'harassment',
          'context': 'chat',
          'status': 'open',
          'createdAt': 'x',
          'updatedAt': 'y',
          'resolvedAt': null,
        };

    test('report sends the body; reports lists with limit', () async {
      final fake = FakeClient()
        ..push(201, body: <String, Object?>{'data': report()})
        ..push(200, body: <String, Object?>{'data': <String, Object?>{'reports': <Object?>[report()]}});
      final kraty = Kraty(modOpts(fake));
      final r = await kraty.moderation.report(
        targetExternalPlayerId: 'bob',
        category: ReportCategory.harassment,
        context: ReportContext.chat,
        conversationId: 'c1',
        messageIds: <String>['m1', 'm2'],
        as: 'alice',
      );
      expect(r.reportId, 'rep1');
      expect(r.status, 'open');
      expect(r.resolvedAt, isNull);
      final mine = await kraty.moderation.reports(limit: 5, as: 'alice');
      expect(mine.single.category, 'harassment');

      expect(fake.calls[0].method, 'POST');
      expect(fake.calls[0].url, '$_baseUrl/sdk/v1/players/alice/reports');
      final body = jsonDecode(fake.calls[0].body!) as Map<String, Object?>;
      expect(body['targetExternalPlayerId'], 'bob');
      expect(body['category'], 'harassment');
      expect(body['context'], 'chat');
      expect(body['conversationId'], 'c1');
      expect(body['messageIds'], <Object?>['m1', 'm2']);
      expect(body.containsKey('comment'), isFalse);
      expect(body.containsKey('guildId'), isFalse);
      expect(fake.calls[1].url, '$_baseUrl/sdk/v1/players/alice/reports?limit=5');
      // Not a chat route: no filter header.
      expect(fake.calls[0].headers.containsKey('x-kraty-chat-filter'), isFalse);
      kraty.close();
    });

    test('status parses restrictions + pendingWarnings; acknowledgeWarning posts', () async {
      Map<String, Object?> warning({String? ack}) => <String, Object?>{
            'restrictionId': 'w1',
            'kind': 'warning',
            'reason': 'be nice',
            'source': 'moderator',
            'createdAt': 'x',
            'expiresAt': null,
            'liftedAt': null,
            'acknowledgedAt': ack,
            'active': ack == null,
            'reportId': 'rep1',
          };
      final fake = FakeClient()
        ..push(200, body: <String, Object?>{
          'data': <String, Object?>{
            'canChat': true,
            'canPost': true,
            'mutedUntil': null,
            'chatBannedUntil': null,
            'restrictions': <Object?>[warning()],
          },
        })
        ..push(200, body: <String, Object?>{'data': warning(ack: '2026-10-15T00:00:00.000Z')});
      final kraty = Kraty(modOpts(fake));
      final status = await kraty.moderation.status(as: 'alice');
      expect(status.canChat, isTrue);
      expect(status.pendingWarnings.single.reason, 'be nice');
      expect(status.pendingWarnings.single.reportId, 'rep1');
      final acked = await kraty.moderation.acknowledgeWarning('w1', as: 'alice');
      expect(acked.active, isFalse);
      expect(acked.acknowledgedAt, '2026-10-15T00:00:00.000Z');
      expect(fake.calls[0].url, '$_baseUrl/sdk/v1/players/alice/moderation/status');
      expect(fake.calls[1].method, 'POST');
      expect(fake.calls[1].url, '$_baseUrl/sdk/v1/players/alice/moderation/warnings/w1/acknowledge');
      kraty.close();
    });
  });

  group('inventory.* + wallet.*', () {
    test('inventory.list parses { items: [...] }', () async {
      final fake = FakeClient()
        ..push(200, body: {
          'data': {
            'items': [
              {
                'itemKey': 'bullet_basic',
                'quantity': 5,
                'metadata': {},
                'createdAt': '',
                'updatedAt': '',
              },
            ],
          },
        });
      final kraty = Kraty(_opts(fake));
      final inv = await kraty.inventory.list(as: 'alice');
      expect(inv, hasLength(1));
      expect(inv.first.itemKey, 'bullet_basic');
      expect(inv.first.quantity, 5);
      kraty.close();
    });

    test('inventory.consume sends quantity + auto-idem + parses applied', () async {
      final fake = FakeClient()
        ..push(200, body: {
          'data': {'itemKey': 'bullet_basic', 'quantity': 4, 'applied': true},
        });
      final kraty = Kraty(_opts(fake));
      final res = await kraty.inventory.consume(
        'bullet_basic',
        const ConsumeItemInput(quantity: 1),
        as: 'alice',
      );
      expect(res.applied, isTrue);
      expect(res.quantity, 4);
      final body = jsonDecode(fake.calls.single.body!) as Map<String, Object?>;
      expect(body['quantity'], 1);
      expect(body['idempotencyKey'], 'fixed-idem');
      kraty.close();
    });

    test('wallet.list parses { wallet: [...] }', () async {
      final fake = FakeClient()
        ..push(200, body: {
          'data': {
            'wallet': [
              {
                'economyKey': 'cash', 'balance': 200, 'metadata': {},
                'createdAt': '', 'updatedAt': '',
              },
            ],
          },
        });
      final kraty = Kraty(_opts(fake));
      final w = await kraty.wallet.list(as: 'alice');
      expect(w, hasLength(1));
      expect(w.first.economyKey, 'cash');
      expect(w.first.balance, 200);
      kraty.close();
    });

    test('wallet.debit on insufficient → isInsufficientEntryCost stays false', () async {
      final fake = FakeClient()
        ..push(409, body: {
          'error': {'code': 'conflict', 'message': 'insufficient balance'},
        });
      final kraty = Kraty(_opts(fake));
      Object? caught;
      try {
        await kraty.wallet.debit(
          'cash',
          const DebitWalletInput(amount: 9999),
          as: 'alice',
        );
      } catch (err) {
        caught = err;
      }
      expect(caught, isA<KratyApiError>());
      final err = caught! as KratyApiError;
      expect(err.code, 'conflict');
      // insufficient_entry_cost is a separate error code from
      // wallet-debit's generic insufficient, so verify the helper
      // doesn't mis-classify.
      expect(err.isInsufficientEntryCost, isFalse);
      kraty.close();
    });

    test('events.start on insufficient cost → isInsufficientEntryCost true', () async {
      final fake = FakeClient()
        ..push(402, body: {
          'error': {
            'code': 'insufficient_entry_cost',
            'message': 'not enough cash to enter, need 50',
          },
        });
      final kraty = Kraty(_opts(fake));
      Object? caught;
      try {
        await kraty.events.start('bounty_hunt', as: 'alice');
      } catch (err) {
        caught = err;
      }
      expect(caught, isA<KratyApiError>());
      final err = caught! as KratyApiError;
      expect(err.status, 402);
      expect(err.isInsufficientEntryCost, isTrue);
      expect(err.isPlayerSecretInvalid, isFalse);
      kraty.close();
    });

    test('any 401 player_secret_invalid → isPlayerSecretInvalid true', () async {
      final fake = FakeClient()
        ..push(401, body: {
          'error': {
            'code': 'player_secret_invalid',
            'message': 'invalid player secret',
          },
        });
      final kraty = Kraty(_opts(fake));
      Object? caught;
      try {
        await kraty.inventory.list(as: 'alice');
      } catch (err) {
        caught = err;
      }
      final err = caught! as KratyApiError;
      expect(err.isPlayerSecretInvalid, isTrue);
      expect(err.isLobbyForming, isFalse);
      kraty.close();
    });
  });

  group('lobbies.read', () {
    test('parses botSlots projection field', () async {
      final fake = FakeClient()
        ..push(200, body: {
          'data': {
            'id': 'l1',
            'eventId': 'e1',
            'eventWindowId': 'w1',
            'leaderboardId': null,
            'mode': 'auto',
            'status': 'forming',
            'capacity': 4,
            'fillBy': '2026-06-08T17:00:30Z',
            'participantCount': 1,
            'botSlots': 2,
            'startedAt': null,
            'endsAt': null,
          },
        });
      final kraty = Kraty(_opts(fake));
      final lobby = await kraty.lobbies.read('l1');
      expect(lobby.id, 'l1');
      expect(lobby.capacity, 4);
      expect(lobby.participantCount, 1);
      expect(lobby.botSlots, 2);
      expect(lobby.filledSlots, 3);
      expect(lobby.status, 'forming');
      kraty.close();
    });

    test('filledSlots clamps to capacity if server skew over-counts', () async {
      final fake = FakeClient()
        ..push(200, body: {
          'data': {
            'id': 'l1', 'eventId': 'e1', 'eventWindowId': 'w1',
            'leaderboardId': null, 'mode': 'auto', 'status': 'forming',
            'capacity': 4, 'fillBy': '', 'participantCount': 3,
            'botSlots': 5, 'startedAt': null, 'endsAt': null,
          },
        });
      final kraty = Kraty(_opts(fake));
      final lobby = await kraty.lobbies.read('l1');
      expect(lobby.filledSlots, 4); // capped at capacity, not 3 + 5
      kraty.close();
    });
  });

  group('Kraty lazy identity (Option B)', () {
    KratyClientOptions optsWithStore(FakeClient client, SecretStore store) =>
        KratyClientOptions(
          apiKey: _apiKey,
          baseUrl: _baseUrl,
          httpClient: client,
          secretStore: store,
          generateIdempotencyKey: () => 'fixed-idem',
          retry: const KratyRetryConfig(
            attempts: 1,
            initialDelay: Duration(milliseconds: 1),
            maxDelay: Duration(milliseconds: 5),
            jitter: 0,
          ),
          timeout: const Duration(seconds: 1),
        );

    test('auto-registers a fresh player on the first bare call', () async {
      final fake = FakeClient()
        ..push(201, body: {'data': {'secret': 'auto-secret'}})
        ..push(200, body: {'data': []});
      final store = InMemorySecretStore();
      final kraty = Kraty(optsWithStore(fake, store));
      await kraty.grants.listPending();
      // First call lazy-registers with a fresh kp_ id.
      expect(fake.calls[0].url, matches(
        RegExp(r'/sdk/v1/players/kp_[A-Za-z0-9_-]+/register$'),
      ));
      // Second call reuses the freshly-minted id without re-registering.
      expect(fake.calls[1].url, matches(
        RegExp(r'/sdk/v1/players/kp_[A-Za-z0-9_-]+/pending-grants$'),
      ));
      expect(fake.calls[1].headers['x-player-secret'], 'auto-secret');
      expect(kraty.activeExternalPlayerId, startsWith('kp_'));
      kraty.close();
    });

    test('restores a persisted identity without re-registering', () async {
      final fake = FakeClient()..push(200, body: {'data': []});
      final store = InMemorySecretStore();
      await store.write('alice', 'cached-secret');
      await store.writeActiveExternalPlayerId('alice');
      final kraty = Kraty(optsWithStore(fake, store));
      await kraty.grants.listPending();
      expect(fake.calls, hasLength(1));
      expect(fake.calls[0].url, contains('/players/alice/pending-grants'));
      expect(fake.calls[0].headers['x-player-secret'], 'cached-secret');
      kraty.close();
    });

    test('constructor identity skips the register round-trip', () async {
      final fake = FakeClient()..push(200, body: {'data': []});
      final store = InMemorySecretStore();
      final kraty = Kraty(KratyClientOptions(
        apiKey: _apiKey,
        baseUrl: _baseUrl,
        httpClient: fake,
        playerSecret: 'ctor-secret',
        activeExternalPlayerId: 'alice',
        secretStore: store,
        retry: const KratyRetryConfig(attempts: 1),
      ));
      await kraty.grants.listPending();
      expect(fake.calls, hasLength(1));
      expect(fake.calls[0].url, contains('/players/alice/pending-grants'));
      expect(fake.calls[0].headers['x-player-secret'], 'ctor-secret');
      kraty.close();
    });

    test('opts.as overrides the active player id without resolving identity', () async {
      final fake = FakeClient()..push(200, body: {'data': []});
      final store = InMemorySecretStore();
      final kraty = Kraty(optsWithStore(fake, store));
      await kraty.grants.listPending(as: 'bob');
      expect(fake.calls[0].url, contains('/players/bob/pending-grants'));
      // `as:` is the server-side-tooling escape hatch; it skips
      // identity resolution entirely, so no lazy register fires.
      expect(fake.calls, hasLength(1));
      expect(kraty.activeExternalPlayerId, isNull);
      kraty.close();
    });

    test('concurrent first-touch shares one register call', () async {
      final fake = FakeClient()
        ..push(201, body: {'data': {'secret': 'shared-secret'}})
        ..push(200, body: {'data': []})
        ..push(200, body: {'data': []});
      final store = InMemorySecretStore();
      final kraty = Kraty(optsWithStore(fake, store));
      final results = await Future.wait<List<Object?>>([
        kraty.grants.listPending(),
        kraty.grants.listPending(),
      ]);
      expect(results, hasLength(2));
      // 1 register + 2 pending-grants = 3 calls. NOT 4 (no double-register).
      expect(fake.calls, hasLength(3));
      expect(fake.calls[0].url, contains('/register'));
      kraty.close();
    });

    test('signIn installs an explicit identity and persists it', () async {
      final fake = FakeClient()..push(200, body: {'data': []});
      final store = InMemorySecretStore();
      final kraty = Kraty(optsWithStore(fake, store));
      await kraty.signIn(externalPlayerId: 'eve', secret: 'eve-secret');
      expect(kraty.activeExternalPlayerId, 'eve');
      expect(await store.read('eve'), 'eve-secret');
      expect(await store.readActiveExternalPlayerId(), 'eve');
      await kraty.grants.listPending();
      expect(fake.calls.single.url, contains('/players/eve/pending-grants'));
      expect(fake.calls.single.headers['x-player-secret'], 'eve-secret');
      kraty.close();
    });

    test('logout clears the persisted identity', () async {
      final fake = FakeClient()
        ..push(201, body: {'data': {'secret': 'fresh'}});
      final store = InMemorySecretStore();
      final kraty = Kraty(optsWithStore(fake, store));
      final id = (await kraty.ensureIdentity()).externalPlayerId;
      expect(await store.read(id), 'fresh');
      expect(kraty.activeExternalPlayerId, id);
      await kraty.logout();
      expect(kraty.activeExternalPlayerId, isNull);
      expect(await store.read(id), isNull);
      expect(await store.readActiveExternalPlayerId(), isNull);
      kraty.close();
    });
  });

  group('friends.*', () {
    test('list unwraps { friends: [...] } with identity + presence', () async {
      final fake = FakeClient()
        ..push(200, body: {
          'data': {
            'friends': [
              {
                'externalPlayerId': 'bob',
                'displayIdentity': {'name': 'Bob', 'avatar': null, 'country': 'PT'},
                'friendsSince': '2026-06-08T00:00:00Z',
                'online': true,
                'lastActiveAt': '2026-06-08T17:00:00Z',
                'status': 'in_match',
              },
            ],
          },
        });
      final kraty = Kraty(_opts(fake));
      final friends = await kraty.friends.list(as: 'alice');
      expect(friends, hasLength(1));
      expect(friends.first.externalPlayerId, 'bob');
      expect(friends.first.displayIdentity?.name, 'Bob');
      expect(friends.first.displayIdentity?.country, 'PT');
      expect(friends.first.online, isTrue);
      expect(friends.first.status, 'in_match');
      expect(fake.calls.single.url, '$_baseUrl/sdk/v1/players/alice/friends');
      kraty.close();
    });

    test('add with friendCode returns pending request', () async {
      final fake = FakeClient()
        ..push(201, body: {
          'data': {
            'status': 'pending',
            'request': {
              'requestId': 'req-1',
              'direction': 'outgoing',
              'player': {
                'externalPlayerId': 'carol',
                'displayIdentity': {'name': 'Carol'},
              },
              'createdAt': '2026-06-08T00:00:00Z',
            },
          },
        });
      final kraty = Kraty(_opts(fake));
      final res = await kraty.friends.add(
        FriendTarget.byCode('ABC123'),
        as: 'alice',
      );
      expect(res.status, 'pending');
      expect(res.request?.requestId, 'req-1');
      expect(res.request?.direction, 'outgoing');
      expect(res.request?.player.externalPlayerId, 'carol');
      expect(res.friend, isNull);
      final body = jsonDecode(fake.calls.single.body!) as Map<String, Object?>;
      expect(body['friendCode'], 'ABC123');
      expect(body.containsKey('externalPlayerId'), isFalse);
      expect(
        fake.calls.single.url,
        '$_baseUrl/sdk/v1/players/alice/friends/requests',
      );
      kraty.close();
    });

    test('add reciprocal auto-accept returns friend', () async {
      final fake = FakeClient()
        ..push(200, body: {
          'data': {
            'status': 'accepted',
            'friend': {
              'externalPlayerId': 'dave',
              'displayIdentity': {'name': 'Dave'},
              'friendsSince': '2026-06-08T00:00:00Z',
              'online': false,
              'lastActiveAt': null,
              'status': null,
            },
          },
        });
      final kraty = Kraty(_opts(fake));
      final res = await kraty.friends.add(
        FriendTarget.byExternalPlayerId('dave'),
        as: 'alice',
      );
      expect(res.status, 'accepted');
      expect(res.friend?.externalPlayerId, 'dave');
      expect(res.request, isNull);
      final body = jsonDecode(fake.calls.single.body!) as Map<String, Object?>;
      expect(body['externalPlayerId'], 'dave');
      kraty.close();
    });

    test('heartbeat sends status + parses presence', () async {
      final fake = FakeClient()
        ..push(200, body: {
          'data': {
            'online': true,
            'lastActiveAt': '2026-06-08T17:00:00Z',
            'status': 'lobby',
          },
        });
      final kraty = Kraty(_opts(fake));
      final presence = await kraty.friends.heartbeat(status: 'lobby', as: 'alice');
      expect(presence.online, isTrue);
      expect(presence.status, 'lobby');
      final body = jsonDecode(fake.calls.single.body!) as Map<String, Object?>;
      expect(body['status'], 'lobby');
      expect(fake.calls.single.method, 'POST');
      expect(fake.calls.single.url, '$_baseUrl/sdk/v1/players/alice/presence');
      kraty.close();
    });

    test('search unwraps { results: [...] } and sends q + limit', () async {
      final fake = FakeClient()
        ..push(200, body: {
          'data': {
            'results': [
              {
                'externalPlayerId': 'eve',
                'displayIdentity': {'name': 'Eve'},
                'relationship': 'request_incoming',
              },
            ],
          },
        });
      final kraty = Kraty(_opts(fake));
      final results = await kraty.friends.search('ev', limit: 10, as: 'alice');
      expect(results, hasLength(1));
      expect(results.first.externalPlayerId, 'eve');
      expect(results.first.relationship, 'request_incoming');
      expect(fake.calls.single.url,
          '$_baseUrl/sdk/v1/players/alice/friends/search?q=ev&limit=10');
      kraty.close();
    });

    test('suggestions unwraps { suggestions: [...] } and sends limit + progression', () async {
      final fake = FakeClient()
        ..push(200, body: {
          'data': {
            'suggestions': [
              {
                'externalPlayerId': 'carol',
                'displayIdentity': {'name': 'Carol'},
                'online': false,
                'lastActiveAt': null,
                'status': null,
              },
            ],
          },
        });
      final kraty = Kraty(_opts(fake));
      final suggestions = await kraty.friends
          .suggestions(limit: 5, progression: ['level'], as: 'alice');
      expect(suggestions, hasLength(1));
      expect(suggestions.first.externalPlayerId, 'carol');
      expect(suggestions.first.online, false);
      expect(fake.calls.single.url,
          '$_baseUrl/sdk/v1/players/alice/friends/suggestions?limit=5&progression=level');
      kraty.close();
    });

    test('decline / cancelRequest / remove / unblock hit the right verbs', () async {
      final fake = FakeClient()
        ..push(200, body: {'data': {'declined': true}})
        ..push(200, body: {'data': {'cancelled': true}})
        ..push(200, body: {'data': {'removed': true}})
        ..push(200, body: {'data': {'unblocked': true}});
      final kraty = Kraty(_opts(fake));
      await kraty.friends.decline('req-1', as: 'alice');
      await kraty.friends.cancelRequest('req-2', as: 'alice');
      await kraty.friends.remove('bob', as: 'alice');
      await kraty.friends.unblock('carol', as: 'alice');
      expect(fake.calls[0].method, 'POST');
      expect(fake.calls[0].url,
          '$_baseUrl/sdk/v1/players/alice/friends/requests/req-1/decline');
      expect(fake.calls[1].method, 'DELETE');
      expect(fake.calls[1].url,
          '$_baseUrl/sdk/v1/players/alice/friends/requests/req-2');
      expect(fake.calls[2].method, 'DELETE');
      expect(fake.calls[2].url, '$_baseUrl/sdk/v1/players/alice/friends/bob');
      expect(fake.calls[3].method, 'DELETE');
      expect(fake.calls[3].url, '$_baseUrl/sdk/v1/players/alice/blocks/carol');
      kraty.close();
    });
  });

  group('offers.*', () {
    const i = '5b0c1f3e-7d4a-4f8e-9c2b-1a6d3e8f0b47';
    final offerJson = <String, Object?>{
      'instanceId': i,
      'offerKey': 'starter',
      'kind': 'starter_pack',
      'name': {'en': 'Starter'},
      'description': null,
      'state': 'available',
      'tier': 0,
      'tierCount': 1,
      'current': {
        'index': 0,
        'storeProductKey': 'starter_499',
        'skus': {'google_play': 'com.game.starter'},
        'referencePriceMinor': 499,
        'contents': [
          {'type': 'currency', 'currencyKey': 'gems', 'amount': 500},
        ],
        'label': null,
        'valueLabel': 'x3',
      },
      'next': null,
      'expiresAt': '2026-10-16T00:00:00.000Z',
      'tierExpiresAt': null,
      'endsWithSession': false,
      'purchasesRemaining': 1,
      'presentation': {'layout': 'popup'},
    };

    test('offers.list builds the query and parses offers', () async {
      final fake = FakeClient()..push(200, body: {'data': [offerJson]});
      final kraty = Kraty(_opts(fake));
      final offers = await kraty.offers.list(limit: 5, level: 12, as: 'alice');
      expect(fake.calls.single.method, 'GET');
      expect(fake.calls.single.url, '$_baseUrl/sdk/v1/players/alice/offers?limit=5&level=12');
      final offer = offers.single;
      expect(offer.instanceId, i);
      expect(offer.current.skus['google_play'], 'com.game.starter');
      expect(offer.current.contents.single['amount'], 500);
      expect(offer.current.valueLabel, 'x3');
      expect((offer.name as Map)['en'], 'Starter');
      expect(offer.next, isNull);
      expect(offer.purchasesRemaining, 1);
      expect(offer.presentation.layout, 'popup');
      kraty.close();
    });

    test('offers parse the Revision 4 fields, null and set', () async {
      final tested = <String, Object?>{...offerJson, 'variantKey': 'b', 'linkedEventKey': 'lava_quest'};
      final plain = <String, Object?>{...offerJson, 'variantKey': null, 'linkedEventKey': null};
      final fake = FakeClient()
        ..push(200, body: {
          'data': [tested, plain],
        })
        ..push(200, body: {
          'data': {
            'offer': plain,
            'firstImpression': false,
            'capped': true,
            'cappedReason': 'global_gap',
            'retryAt': '2026-10-16T12:02:00.000Z',
          },
        });
      final kraty = Kraty(_opts(fake));
      final offers = await kraty.offers.list(as: 'alice');
      expect(offers[0].variantKey, 'b');
      expect(offers[0].linkedEventKey, 'lava_quest');
      expect(offers[1].variantKey, isNull);
      expect(offers[1].linkedEventKey, isNull);
      final shown = await kraty.offers.markShown(i, as: 'alice');
      expect(shown.capped, isTrue);
      expect(shown.cappedReason, 'global_gap');
      expect(shown.retryAt, '2026-10-16T12:02:00.000Z');
      kraty.close();
    });

    test('offers.list without options sends no query', () async {
      final fake = FakeClient()..push(200, body: {'data': <Object?>[]});
      final kraty = Kraty(_opts(fake));
      expect(await kraty.offers.list(as: 'alice'), isEmpty);
      expect(fake.calls.single.url, '$_baseUrl/sdk/v1/players/alice/offers');
      kraty.close();
    });

    test('offers.markShown and dismiss stamp idempotency keys', () async {
      final fake = FakeClient()
        ..push(200, body: {
          'data': {'offer': offerJson, 'firstImpression': true, 'capped': false},
        })
        ..push(200, body: {'data': offerJson});
      final kraty = Kraty(_opts(fake));
      final shown = await kraty.offers.markShown(i, as: 'alice');
      expect(shown.firstImpression, isTrue);
      expect(shown.capped, isFalse);
      expect(shown.offer.instanceId, i);
      expect(fake.calls[0].url, '$_baseUrl/sdk/v1/players/alice/offers/$i/impression');
      expect(jsonDecode(fake.calls[0].body!), {'idempotencyKey': 'fixed-idem'});

      final after = await kraty.offers.dismiss(i, idempotencyKey: 'dismiss-1', as: 'alice');
      expect(after.offerKey, 'starter');
      expect(fake.calls[1].url, '$_baseUrl/sdk/v1/players/alice/offers/$i/dismiss');
      expect(jsonDecode(fake.calls[1].body!), {'idempotencyKey': 'dismiss-1'});
      kraty.close();
    });

    test('offers.trigger sends the union and player context', () async {
      final fake = FakeClient()
        ..push(200, body: {
          'data': {'offers': [offerJson]},
        })
        ..push(200, body: {
          'data': {'offers': <Object?>[]},
        });
      final kraty = Kraty(_opts(fake));
      final armed = await kraty.offers.trigger(
        const OfferTriggerInput.resourceDepleted('lives', required: 1, available: 0, secondsToRegen: 900),
        playerContext: {'level': 7},
        as: 'alice',
      );
      expect(armed.offers.single.instanceId, i);
      expect(fake.calls[0].url, '$_baseUrl/sdk/v1/players/alice/offers/triggers');
      expect(jsonDecode(fake.calls[0].body!), {
        'trigger': {'type': 'resource_depleted', 'resource': 'lives', 'required': 1, 'available': 0, 'secondsToRegen': 900},
        'playerContext': {'level': 7},
        'idempotencyKey': 'fixed-idem',
      });

      final none = await kraty.offers.trigger(const OfferTriggerInput.failEvent('level_failed'), as: 'alice');
      expect(none.offers, isEmpty);
      expect(jsonDecode(fake.calls[1].body!), {
        'trigger': {'type': 'fail_event', 'key': 'level_failed'},
        'idempotencyKey': 'fixed-idem',
      });
      expect(const OfferTriggerInput.levelReached(12).toJson(), {'type': 'level_reached', 'level': 12});
      kraty.close();
    });

    final chainJson = <String, Object?>{
      ...offerJson,
      'offerKey': 'endless',
      'kind': 'chain',
      'state': 'shown',
      'tier': 1,
      'tierCount': 3,
      'current': {
        'index': 1,
        'type': 'free',
        'storeProductKey': null,
        'skus': <String, Object?>{},
        'referencePriceMinor': 0,
        'contents': [
          {'type': 'currency', 'currencyKey': 'coins', 'amount': 250},
        ],
        'label': null,
        'valueLabel': null,
      },
      'next': {
        'index': 2,
        'type': 'paid',
        'storeProductKey': 'p2',
        'skus': {'google_play': 'com.game.p2'},
        'referencePriceMinor': 499,
        'contents': <Object?>[],
        'label': null,
        'valueLabel': null,
      },
      'purchasesRemaining': null,
    };

    test('a free tier parses with an empty product key and isFree', () async {
      final fake = FakeClient()..push(200, body: {'data': [chainJson, offerJson]});
      final kraty = Kraty(_opts(fake));
      final offers = await kraty.offers.list(as: 'alice');
      expect(offers[0].current.isFree, isTrue);
      expect(offers[0].current.type, 'free');
      expect(offers[0].current.storeProductKey, ''); // wire null -> ''
      expect(offers[0].current.skus, isEmpty);
      expect(offers[0].next!.isFree, isFalse);
      // No `type` on the wire (older server) reads as paid.
      expect(offers[1].current.type, 'paid');
      kraty.close();
    });

    test('offers.claim posts the tapped tier with a key and parses the result', () async {
      final claim = <String, Object?>{
        'claimId': 'c1',
        'offerId': 'o1',
        'offerKey': 'endless',
        'instanceId': i,
        'tier': 1,
        'contents': [
          {'type': 'currency', 'currencyKey': 'coins', 'amount': 250},
        ],
        'granted': false,
        'grantId': null,
        'studioFulfils': true,
        'claimedAt': '2026-10-15T12:00:00.000Z',
      };
      final fake = FakeClient()
        ..push(200, body: {
          'data': {'claim': claim, 'offer': chainJson},
        })
        ..push(200, body: {
          'data': {'claim': claim, 'offer': chainJson},
        });
      final kraty = Kraty(_opts(fake));
      final out = await kraty.offers.claim(i, tier: 1, as: 'alice');
      expect(fake.calls[0].method, 'POST');
      expect(fake.calls[0].url, '$_baseUrl/sdk/v1/players/alice/offers/$i/claim');
      expect(jsonDecode(fake.calls[0].body!), {'idempotencyKey': 'fixed-idem', 'tier': 1});
      expect(out.claim.studioFulfils, isTrue);
      expect(out.claim.granted, isFalse);
      expect(out.claim.grantId, isNull);
      expect(out.claim.contents.single['amount'], 250);
      expect(out.offer.instanceId, i);

      await kraty.offers.claim(i, tier: 0, idempotencyKey: 'mine', as: 'alice');
      expect(jsonDecode(fake.calls[1].body!), {'idempotencyKey': 'mine', 'tier': 0});
      kraty.close();
    });

    test('a refused claim surfaces as a conflict with the reason', () async {
      final fake = FakeClient()
        ..push(409, body: {
          'error': {
            'code': 'conflict',
            'message': 'the current tier is not free',
            'details': {'reason': 'tier_not_free', 'offer': offerJson},
          },
        });
      final kraty = Kraty(_opts(fake));
      Object? caught;
      try {
        await kraty.offers.claim(i, tier: 0, as: 'alice');
      } catch (err) {
        caught = err;
      }
      expect(caught, isA<KratyApiError>());
      final err = caught! as KratyApiError;
      expect(err.code, 'conflict');
      expect((err.details! as Map)['reason'], 'tier_not_free');
      kraty.close();
    });

    test('trackPurchase carries offerInstanceId and parses the offer', () async {
      final fake = FakeClient()
        ..push(201, body: {
          'data': {
            'purchaseId': 'p1',
            'transactionId': 'GPA.1',
            'deduplicated': false,
            'offer': {
              'offerId': 'o1',
              'offerKey': 'starter',
              'instanceId': i,
              'tier': 0,
              'method': 'explicit',
              'status': 'attributed',
              'state': 'completed',
              'granted': false,
              'pendingVerification': false,
              'studioFulfils': true,
              'contents': [
                {'type': 'currency', 'currencyKey': 'gems', 'amount': 500},
              ],
              'validationStatus': 'unverified',
            },
          },
        })
        ..push(201, body: {
          'data': {'purchaseId': 'p2', 'offer': null},
        });
      final kraty = Kraty(_opts(fake));
      final result = await kraty.trackPurchase(
        const TrackPurchaseInput(
          transactionId: 'GPA.1',
          store: 'google_play',
          productId: 'com.game.starter',
          amountMinor: 499,
          currency: 'USD',
          offerInstanceId: i,
        ),
        as: 'alice',
      );
      expect((jsonDecode(fake.calls[0].body!) as Map)['offerInstanceId'], i);
      expect(result.offer, isNotNull);
      expect(result.offer!.studioFulfils, isTrue);
      expect(result.offer!.method, 'explicit');
      expect(result.offer!.tier, 0);
      expect(result.offer!.contents!.single['amount'], 500);

      final plain = await kraty.trackPurchase(
        const TrackPurchaseInput(
          transactionId: 't2', store: 'app_store', productId: 'gems', amountMinor: 99, currency: 'USD'),
        as: 'alice',
      );
      expect((jsonDecode(fake.calls[1].body!) as Map).containsKey('offerInstanceId'), isFalse);
      expect(plain.offer, isNull);
      kraty.close();
    });

    test('canonicalTransactionId picks the store id', () {
      expect(canonicalTransactionId(store: 'app_store', transactionId: '2000000123'), '2000000123');
      expect(canonicalTransactionId(store: 'google_play', orderId: 'GPA.1', purchaseToken: 'tok'), 'GPA.1');
      expect(canonicalTransactionId(store: 'google_play', orderId: '', purchaseToken: 'tok'), 'tok');
      expect(() => canonicalTransactionId(store: 'google_play', transactionId: 'x'), throwsArgumentError);
      expect(() => canonicalTransactionId(store: 'steam'), throwsArgumentError);
    });
  });

  group('InMemorySecretStore', () {
    test('read/write/remove roundtrip', () async {
      final store = InMemorySecretStore();
      expect(await store.read('alice'), isNull);
      await store.write('alice', 'secret-1');
      expect(await store.read('alice'), 'secret-1');
      await store.write('alice', 'secret-2');
      expect(await store.read('alice'), 'secret-2');
      await store.remove('alice');
      expect(await store.read('alice'), isNull);
    });

    test('keys are isolated per externalPlayerId', () async {
      final store = InMemorySecretStore();
      await store.write('alice', 'a');
      await store.write('bob', 'b');
      expect(await store.read('alice'), 'a');
      expect(await store.read('bob'), 'b');
      await store.remove('alice');
      expect(await store.read('bob'), 'b'); // bob unaffected
    });
  });

}

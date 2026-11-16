import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:kraty/kraty.dart';

/// Chat outbox + self-healing streams. A scripted HTTP client answers each
/// request through a function, so a test can hold a response open (SSE),
/// delay it, or switch answers mid-test. Timeouts are shrunk via options
/// (outbox timeout, heartbeat) and server-provided waits (Retry-After,
/// retryAfterMs) so every test runs in well under a second or two.

class Call {
  Call(this.method, this.url, this.body);
  final String method;
  final String url;
  final String? body;

  Map<String, Object?> get json => jsonDecode(body!) as Map<String, Object?>;
}

typedef Responder = Future<http.StreamedResponse> Function(Call call);

class ScriptClient extends http.BaseClient {
  ScriptClient(this.responder);
  final List<Call> calls = [];
  Responder responder;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = request is http.Request ? request.body : null;
    final call = Call(request.method, request.url.toString(), body == null || body.isEmpty ? null : body);
    calls.add(call);
    return responder(call);
  }
}

http.StreamedResponse jsonRes(int status, Object body, {Map<String, String>? headers}) => http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode(body))),
      status,
      headers: <String, String>{'content-type': 'application/json', ...?headers},
    );

http.StreamedResponse sseRes(Stream<List<int>> body) =>
    http.StreamedResponse(body, 200, headers: <String, String>{'content-type': 'text/event-stream'});

String ev(String kind, Map<String, Object?> data) => 'event: $kind\ndata: ${jsonEncode(data)}\n\n';

/// An SSE body the test writes to and leaves open until it closes it.
class OpenBody {
  final StreamController<List<int>> ctrl = StreamController<List<int>>();
  void write(String s) => ctrl.add(utf8.encode(s));
  Future<void> close() => ctrl.close();
}

Map<String, Object?> busy({double retryAfterSeconds = 0.01}) => <String, Object?>{
      'error': <String, Object?>{
        'code': 'service_unavailable',
        'message': 'busy',
        'details': <String, Object?>{'retryAfterSeconds': retryAfterSeconds},
      },
    };

Map<String, Object?> refusal(String code, Map<String, Object?> details) => <String, Object?>{
      'error': <String, Object?>{'code': code, 'message': 'refused', 'details': details},
    };

const _apiKey = 'pUUVdrM8.djr4-0Iv9h1JvVNSMZNDmSsSN7lSVq2F9dG6DG4A5uQ';
const _baseUrl = 'https://api.test.kraty.io';
const c = '6f1d2c3b-4a5e-4f60-8a71-9b8c7d6e5f40';

Map<String, Object?> message({int seq = 1, String conversationId = c, String? clientMessageId}) => <String, Object?>{
      'messageId': 'm$seq',
      'conversationId': conversationId,
      'seq': seq,
      'type': 'text',
      'sender': <String, Object?>{
        'kind': 'player',
        'player': <String, Object?>{'externalPlayerId': 'bob', 'displayIdentity': null},
      },
      'text': 'hi $seq',
      'filtered': false,
      'customType': null,
      'payload': null,
      'replyToId': null,
      'clientMessageId': clientMessageId,
      'createdAt': '2026-10-15T10:00:00.000Z',
      'editedAt': null,
      'deleted': false,
    };

Kraty kratyWith(
  ScriptClient fake, {
  Duration outboxTimeout = const Duration(seconds: 120),
  bool waitForCooldown = false,
}) =>
    Kraty(KratyClientOptions(
      apiKey: _apiKey,
      baseUrl: _baseUrl,
      httpClient: fake,
      playerSecret: 'sek',
      activeExternalPlayerId: 'alice',
      generateIdempotencyKey: () => 'idem-${DateTime.now().microsecondsSinceEpoch}',
      // The generic retry loop is on: the outbox must bypass it.
      retry: const KratyRetryConfig(
        attempts: 4,
        initialDelay: Duration(milliseconds: 1),
        maxDelay: Duration(milliseconds: 5),
        jitter: 0,
      ),
      timeout: const Duration(seconds: 1),
      chatOutboxTimeout: outboxTimeout,
      chatWaitForCooldown: waitForCooldown,
    ));

void main() {
  group('chat outbox', () {
    test('a send survives two busy 503s with the same clientMessageId; onPending fires first', () async {
      var n = 0;
      final fake = ScriptClient((call) async {
        n++;
        if (n == 1) return jsonRes(503, busy(), headers: <String, String>{'retry-after': '0.01'});
        if (n == 2) return jsonRes(503, busy());
        return jsonRes(201, <String, Object?>{'data': message(clientMessageId: call.json['clientMessageId'] as String)});
      });
      final kraty = kratyWith(fake);
      String? pending;
      var callsAtPending = -1;
      final sent = await kraty.chat.send(c, 'hello', onPending: (id) {
        pending = id;
        callsAtPending = fake.calls.length;
      });
      expect(callsAtPending, 0);
      expect(fake.calls, hasLength(3));
      final ids = fake.calls.map((x) => x.json['clientMessageId']).toSet();
      expect(ids, <Object?>{pending});
      expect(fake.calls.map((x) => x.json['idempotencyKey']).toSet(), hasLength(1));
      expect(sent.clientMessageId, pending);
      kraty.close();
    });

    test('keeps per-conversation order; other conversations run in parallel', () async {
      final firstGate = Completer<void>();
      final fake = ScriptClient((call) async {
        final text = call.json['text'];
        if (text == 'one') await firstGate.future;
        final conv = call.url.contains('/conversations/other/') ? 'other' : c;
        return jsonRes(201, <String, Object?>{'data': message(conversationId: conv)});
      });
      final kraty = kratyWith(fake);
      final one = kraty.chat.send(c, 'one');
      final two = kraty.chat.send(c, 'two');
      final elsewhere = kraty.chat.send('other', 'three');
      await elsewhere;
      expect(fake.calls.map((x) => x.json['text']).toList(), <String>['one', 'three']);
      firstGate.complete();
      await one;
      await two;
      expect(fake.calls.map((x) => x.json['text']).toList(), <String>['one', 'three', 'two']);
      kraty.close();
    });

    test('client-level waitForCooldown holds queued messages until the cooldown ends', () async {
      var answer = jsonRes(429, refusal('chat_slow_mode', <String, Object?>{'retryAfterSeconds': 0.2}));
      final fake = ScriptClient((call) async => answer);
      final kraty = kratyWith(fake, waitForCooldown: true);
      await expectLater(kraty.chat.send(c, 'refused'), throwsA(isA<KratyApiError>()));
      // Opting out per send fails locally even with the client default on.
      await expectLater(kraty.chat.send(c, 'opt-out', waitForCooldown: false),
          throwsA(isA<KratyApiError>().having((e) => (e.details! as Map)['local'], 'local', isTrue)));
      expect(fake.calls, hasLength(1));
      answer = jsonRes(201, <String, Object?>{'data': message()});
      final sw = Stopwatch()..start();
      final one = kraty.chat.send(c, 'one');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(fake.calls, hasLength(1));
      await one;
      expect(sw.elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 150)));
      expect(fake.calls.last.json['text'], 'one');
      expect(fake.calls, hasLength(2));
      kraty.close();
    });

    test('429 and other 4xx are never retried', () async {
      var answer = jsonRes(429, refusal('chat_rate_limited', <String, Object?>{'retryAfterSeconds': 0.2}));
      final fake = ScriptClient((call) async => answer);
      final kraty = kratyWith(fake);
      await expectLater(kraty.chat.send(c, 'x'), throwsA(isA<KratyApiError>().having((e) => e.status, 'status', 429)));
      expect(fake.calls, hasLength(1));
      answer = jsonRes(403, refusal('chat_muted', <String, Object?>{}));
      await expectLater(kraty.chat.send('d2', 'x'), throwsA(isA<KratyApiError>().having((e) => e.isChatMuted, 'muted', isTrue)));
      expect(fake.calls, hasLength(2));
      kraty.close();
    });

    test('a duplicate or rate-limited refusal never holds the conversation', () async {
      final answers = <http.StreamedResponse Function()>[
        () => jsonRes(429, refusal('chat_duplicate_message', <String, Object?>{'retryAfterSeconds': 30})),
        () => jsonRes(201, <String, Object?>{'data': message(seq: 1)}),
        () => jsonRes(429, refusal('chat_rate_limited', <String, Object?>{'retryAfterSeconds': 40})),
        () => jsonRes(201, <String, Object?>{'data': message(seq: 2, conversationId: 'd2')}),
      ];
      final fake = ScriptClient((call) async => answers.removeAt(0)());
      final kraty = kratyWith(fake);
      await expectLater(
          kraty.chat.send(c, 'gg'), throwsA(isA<KratyApiError>().having((e) => e.isChatDuplicateMessage, 'dup', isTrue)));
      expect(kraty.chat.cooldownRemaining(c), 0);
      // A different message goes out at once, not refused locally.
      expect((await kraty.chat.send(c, 'good game')).seq, 1);

      await expectLater(kraty.chat.send('d2', 'hi'), throwsA(isA<KratyApiError>().having((e) => e.status, 'status', 429)));
      expect(kraty.chat.cooldownRemaining('d2'), 0);
      expect((await kraty.chat.send('d2', 'hi again')).seq, 2);
      expect(fake.calls.map((x) => x.json['text']).toList(), <Object?>['gg', 'good game', 'hi', 'hi again']);
      kraty.close();
    });

    test('a send in cooldown fails locally; waitForCooldown sends once it ends', () async {
      var answer = jsonRes(429, refusal('chat_slow_mode', <String, Object?>{'retryAfterSeconds': 0.25}));
      final fake = ScriptClient((call) async => answer);
      final kraty = kratyWith(fake);
      await expectLater(kraty.chat.send(c, 'first'), throwsA(isA<KratyApiError>()));
      expect(fake.calls, hasLength(1));
      expect(kraty.chat.cooldownRemaining(c), 1);

      try {
        await kraty.chat.send(c, 'too soon');
        fail('expected a local refusal');
      } on KratyApiError catch (err) {
        expect(err.status, 429);
        expect(err.code, KratyErrorCode.chatSlowMode);
        expect(err.retryAfterSeconds, 1);
        expect((err.details! as Map)['local'], isTrue);
      }
      expect(fake.calls, hasLength(1));

      answer = jsonRes(201, <String, Object?>{'data': message()});
      final sw = Stopwatch()..start();
      await kraty.chat.send(c, 'patient', waitForCooldown: true);
      expect(sw.elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 150)));
      expect(fake.calls, hasLength(2));
      expect(fake.calls.last.json['text'], 'patient');
      kraty.close();
    });

    test('gives up after the outbox timeout; retry() resends the same clientMessageId', () async {
      var down = true;
      final fake = ScriptClient((call) async {
        if (down) return jsonRes(503, busy(retryAfterSeconds: 0.05));
        return jsonRes(201, <String, Object?>{'data': message(clientMessageId: call.json['clientMessageId'] as String)});
      });
      final kraty = kratyWith(fake, outboxTimeout: const Duration(milliseconds: 200));
      String? pending;
      KratyChatNotSentError? notSent;
      try {
        await kraty.chat.send(c, 'lost', onPending: (id) => pending = id);
        fail('expected KratyChatNotSentError');
      } on KratyNetworkError catch (err) {
        expect(err, isA<KratyChatNotSentError>());
        notSent = err as KratyChatNotSentError;
      }
      expect(notSent.conversationId, c);
      expect(notSent.clientMessageId, pending);
      expect(notSent.lastError, isA<KratyApiError>().having((e) => e.isServiceUnavailable, 'busy', isTrue));
      final tries = fake.calls.length;
      expect(tries, greaterThanOrEqualTo(2));
      expect(tries, lessThanOrEqualTo(5));

      down = false;
      final sent = await notSent.retry();
      expect(sent.clientMessageId, pending);
      expect(fake.calls, hasLength(tries + 1));
      expect(fake.calls.map((x) => x.json['clientMessageId']).toSet(), <Object?>{pending});
      kraty.close();
    });

    test('edits retry a busy server and a network drop', () async {
      var n = 0;
      final fake = ScriptClient((call) async {
        n++;
        if (n == 1) return jsonRes(503, busy());
        if (n == 2) throw http.ClientException('connection reset');
        return jsonRes(200, <String, Object?>{'data': message()});
      });
      final kraty = kratyWith(fake);
      await kraty.chat.editMessage(c, 'm1', 'fixed');
      expect(fake.calls, hasLength(3));
      expect(fake.calls.every((x) => x.method == 'PATCH' && x.json['text'] == 'fixed'), isTrue);
      expect(fake.calls.map((x) => x.json['idempotencyKey']).toSet(), hasLength(1));
      kraty.close();
    });
  });

  group('self-healing chat stream', () {
    test('reconnects after close (retryAfterMs) and catches up without duplicates', () async {
      final second = OpenBody();
      var streams = 0;
      final fake = ScriptClient((call) async {
        if (call.url.contains('/chat/stream')) {
          streams++;
          if (streams == 1) {
            return sseRes(Stream.value(utf8.encode([
              ev('ready', <String, Object?>{'externalPlayerId': 'alice', 'conversationIds': <Object?>[c], 'channels': <Object?>[]}),
              ev('message', message(seq: 1)),
              ev('message', message(seq: 2)),
              ev('message', message(seq: 2)),
              ev('close', <String, Object?>{'reason': 'rebalance', 'retryAfterMs': 20}),
            ].join())));
          }
          if (streams == 2) {
            // Live events arrive while the catch-up is still running.
            second.write(ev('ready', <String, Object?>{'externalPlayerId': 'alice', 'conversationIds': <Object?>[c]}));
            second.write(ev('message', message(seq: 4)));
            second.write(ev('message', message(seq: 5)));
            return sseRes(second.ctrl.stream);
          }
          return sseRes(const Stream<List<int>>.empty());
        }
        if (call.url.endsWith('/messages?after=2')) {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          return jsonRes(200, <String, Object?>{
            'data': <String, Object?>{'messages': <Object?>[message(seq: 3)], 'hasMore': true},
          });
        }
        if (call.url.endsWith('/messages?after=3')) {
          return jsonRes(200, <String, Object?>{
            'data': <String, Object?>{'messages': <Object?>[message(seq: 4)], 'hasMore': false},
          });
        }
        throw StateError('unexpected ${call.url}');
      });
      final kraty = kratyWith(fake);
      final stream = await kraty.chat.live();
      final status = <KratyConnectionEvent>[];
      stream.connection.listen(status.add);
      final events = await stream.events.take(7).toList();
      await stream.cancel();

      expect(events.map((e) => e.kind).toList(), <String>['ready', 'message', 'message', 'ready', 'message', 'message', 'message']);
      expect(events.whereType<ChatMessageEvent>().map((e) => e.message.seq).toList(), <int>[1, 2, 3, 4, 5]);
      expect(events.whereType<ChatCloseEvent>(), isEmpty);
      expect(streams, 2);
      expect(fake.calls.where((x) => x.url.contains('/messages?after=')).map((x) => x.url.split('?').last).toList(),
          <String>['after=2', 'after=3']);
      expect(status.map((s) => s.state).toList(), <KratyConnectionState>[
        KratyConnectionState.connected,
        KratyConnectionState.reconnecting,
        KratyConnectionState.connected,
      ]);
      expect(status[1].reason, 'rebalance');
      expect(status[1].retryIn, const Duration(milliseconds: 20));
      expect(status[1].attempt, 1);
      await second.close();
      kraty.close();
    });

    test('catches up quiet conversations from ready.lastSeqs and new ones from 0', () async {
      Map<String, Object?> page(List<Object?> messages) => <String, Object?>{
            'data': <String, Object?>{'messages': messages, 'hasMore': false},
          };
      var streams = 0;
      final bodies = <OpenBody>[];
      final fake = ScriptClient((call) async {
        if (call.url.contains('/chat/stream')) {
          streams++;
          if (streams == 1) {
            return sseRes(Stream.value(utf8.encode([
              ev('ready', <String, Object?>{
                'externalPlayerId': 'alice',
                'conversationIds': <Object?>['dm', 'busy'],
                'channels': <Object?>[],
                'lastSeqs': <String, Object?>{'dm': 7, 'busy': 3},
              }),
              ev('conversation_added', <String, Object?>{'conversationId': 'added', 'kind': 'group'}),
              ev('close', <String, Object?>{'reason': 'rebalance', 'retryAfterMs': 5}),
            ].join())));
          }
          // During the gap: `dm` got seq 8, `fresh` (a channel room) was created unannounced.
          final open = OpenBody();
          bodies.add(open);
          open.write(ev('ready', <String, Object?>{
            'externalPlayerId': 'alice',
            'conversationIds': <Object?>['dm', 'busy', 'added'],
            'channels': <Object?>[
              <String, Object?>{'key': 'world', 'conversationId': 'fresh', 'room': 0},
            ],
            'lastSeqs': <String, Object?>{'dm': 8, 'busy': 3, 'added': 1, 'fresh': 2},
          }));
          return sseRes(open.ctrl.stream);
        }
        if (call.url.contains('/conversations/dm/messages?after=7')) return jsonRes(200, page(<Object?>[message(seq: 8, conversationId: 'dm')]));
        if (call.url.contains('/conversations/added/messages?after=0')) {
          return jsonRes(200, page(<Object?>[message(seq: 1, conversationId: 'added')]));
        }
        if (call.url.contains('/conversations/fresh/messages?after=0')) {
          return jsonRes(200, page(<Object?>[message(seq: 1, conversationId: 'fresh'), message(seq: 2, conversationId: 'fresh')]));
        }
        throw StateError('unexpected ${call.url}');
      });
      final kraty = kratyWith(fake);
      final stream = await kraty.chat.live();
      final events = await stream.events.take(7).toList();
      await stream.cancel();

      expect(events.whereType<ChatMessageEvent>().map((e) => '${e.message.conversationId}:${e.message.seq}').toList(),
          <String>['dm:8', 'added:1', 'fresh:1', 'fresh:2']);
      expect((events.first as ChatReadyEvent).lastSeqs, <String, int>{'dm': 7, 'busy': 3});
      // `busy` is skipped (nothing newer than its cursor).
      expect(fake.calls.where((x) => x.url.contains('/messages?after=')).map((x) => x.url.split('/conversations/').last).toList(),
          <String>['dm/messages?after=7', 'added/messages?after=0', 'fresh/messages?after=0']);
      for (final b in bodies) {
        await b.close();
      }
      kraty.close();
    });

    test('an empty page that says hasMore stops the catch-up; the next reconnect retries it', () async {
      var streams = 0;
      var fetches = 0;
      final last = OpenBody();
      final ready = ev('ready', <String, Object?>{'externalPlayerId': 'alice', 'conversationIds': <Object?>[c]});
      final close = ev('close', <String, Object?>{'reason': 'rebalance', 'retryAfterMs': 5});
      final fake = ScriptClient((call) async {
        if (call.url.contains('/chat/stream')) {
          streams++;
          if (streams == 1) return sseRes(Stream.value(utf8.encode(ready + ev('message', message(seq: 4)) + close)));
          if (streams == 2) return sseRes(Stream.value(utf8.encode(ready + close)));
          last.write(ready);
          return sseRes(last.ctrl.stream);
        }
        fetches++;
        expect(call.url, endsWith('/conversations/$c/messages?after=4'));
        return jsonRes(200, <String, Object?>{
          'data': <String, Object?>{'messages': fetches == 1 ? <Object?>[] : <Object?>[message(seq: 5)], 'hasMore': fetches == 1},
        });
      });
      final kraty = kratyWith(fake);
      final stream = await kraty.chat.live();
      final messages = await stream.events.where((e) => e is ChatMessageEvent).cast<ChatMessageEvent>().take(2).toList();
      await stream.cancel();
      await last.close();
      expect(messages.map((e) => e.message.seq).toList(), <int>[4, 5]);
      expect(fetches, 2);
      expect(streams, 3);
      kraty.close();
    });

    test('heartbeatTimeout: Duration.zero turns the watchdog off', () async {
      final body = OpenBody();
      var streams = 0;
      final fake = ScriptClient((call) async {
        streams++;
        body.write(ev('ready', <String, Object?>{'externalPlayerId': 'alice'}));
        return sseRes(body.ctrl.stream);
      });
      final kraty = kratyWith(fake);
      final stream = await kraty.chat.live(heartbeatTimeout: Duration.zero);
      final status = <KratyConnectionEvent>[];
      stream.connection.listen(status.add);
      stream.events.listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(status.map((s) => s.state).toList(), <KratyConnectionState>[KratyConnectionState.connected]);
      expect(streams, 1);
      await stream.cancel();
      await body.close();
      kraty.close();
    });

    test('the heartbeat watchdog fires on silence; pings count as activity', () async {
      final body = OpenBody();
      var streams = 0;
      final fake = ScriptClient((call) async {
        streams++;
        if (streams == 1) {
          body.write(ev('ready', <String, Object?>{'externalPlayerId': 'alice'}));
          return sseRes(body.ctrl.stream);
        }
        return sseRes(OpenBody().ctrl.stream);
      });
      final kraty = kratyWith(fake);
      final stream = await kraty.chat.live(heartbeatTimeout: const Duration(milliseconds: 120));
      final status = <KratyConnectionEvent>[];
      stream.connection.listen(status.add);
      stream.events.listen((_) {});

      // Pings every 50 ms keep it alive for 300 ms.
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        body.write(': ping\n\n');
      }
      expect(status.where((s) => s.state == KratyConnectionState.reconnecting), isEmpty);
      expect(stream.connectionState, KratyConnectionState.connected);

      // Then silence.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final lost = status.where((s) => s.state == KratyConnectionState.reconnecting).toList();
      expect(lost, hasLength(1));
      expect(lost.single.reason, 'heartbeat_timeout');
      expect(stream.connectionState, KratyConnectionState.reconnecting);
      await stream.cancel();
      await body.close();
      kraty.close();
    });

    test('a fatal first connect throws; a busy one starts reconnecting', () async {
      var answer = jsonRes(403, refusal('chat_disabled', <String, Object?>{}));
      final fake = ScriptClient((call) async => answer);
      final kraty = kratyWith(fake);
      await expectLater(kraty.chat.live(), throwsA(isA<KratyApiError>().having((e) => e.isChatDisabled, 'disabled', isTrue)));

      var n = 0;
      fake.responder = (call) async {
        n++;
        if (n == 1) return jsonRes(503, busy(retryAfterSeconds: 0.02));
        return sseRes(Stream.value(utf8.encode(ev('ready', <String, Object?>{'externalPlayerId': 'alice'}))));
      };
      final stream = await kraty.chat.live();
      expect(stream.connectionState, KratyConnectionState.reconnecting);
      final status = stream.connection.take(2).toList();
      final first = await stream.events.first;
      expect(first, isA<ChatReadyEvent>());
      final seen = await status;
      expect(seen[0].reason, 'busy');
      expect(seen[0].retryIn, const Duration(milliseconds: 20));
      expect(seen[1].isConnected, isTrue);
      await stream.cancel();
      kraty.close();
    });

    test('a fatal error on a reconnect lands on errors and ends the stream', () async {
      var n = 0;
      final fake = ScriptClient((call) async {
        n++;
        if (n == 1) {
          return sseRes(Stream.value(utf8.encode(ev('ready', <String, Object?>{}) +
              ev('close', <String, Object?>{'reason': 'shutdown', 'retryAfterMs': 5}))));
        }
        return jsonRes(403, refusal('chat_disabled', <String, Object?>{}));
      });
      final kraty = kratyWith(fake);
      final stream = await kraty.chat.live();
      final errors = <Object>[];
      stream.errors.listen(errors.add);
      final events = await stream.events.toList();
      expect(events.map((e) => e.kind).toList(), <String>['ready']);
      expect(errors.single, isA<KratyApiError>());
      kraty.close();
    });
  });

  group('leaderboard + inventory streams', () {
    test('leaderboard reconnects after close but never after closed', () async {
      var n = 0;
      final fake = ScriptClient((call) async {
        n++;
        if (n == 1) {
          return sseRes(Stream.value(utf8.encode(ev('ready', <String, Object?>{}) +
              ev('score_update', <String, Object?>{'participantId': 'p1', 'score': 1}) +
              ev('close', <String, Object?>{'reason': 'shutdown', 'retryAfterMs': 5}))));
        }
        return sseRes(Stream.value(utf8.encode(ev('ready', <String, Object?>{}) +
            ev('closed', <String, Object?>{'reason': 'finalized'}) +
            ev('score_update', <String, Object?>{'participantId': 'p1', 'score': 2}))));
      });
      final kraty = kratyWith(fake);
      final stream = await kraty.eventLeaderboards.live('lb1');
      final events = await stream.events.toList();
      expect(events.map((e) => e.kind).toList(), <String>['ready', 'score_update', 'ready', 'closed']);
      expect(n, 2);
      kraty.close();
    });

    test('cancelling the events subscription stops the reconnect loop (chat, leaderboard, inventory)', () async {
      var n = 0;
      final fake = ScriptClient((call) async {
        n++;
        return sseRes(Stream.value(utf8.encode(ev('ready', <String, Object?>{}) +
            ev('close', <String, Object?>{'reason': 'rebalance', 'retryAfterMs': 20}))));
      });
      final kraty = kratyWith(fake);
      final opens = <Future<Stream<Object>> Function()>[
        () async => (await kraty.chat.live()).events,
        () async => (await kraty.eventLeaderboards.live('lb1')).events,
        () async => (await kraty.inventory.live()).events,
      ];
      for (final open in opens) {
        n = 0;
        final events = await open();
        // `.first` cancels its subscription after the first event (like a disposed StreamBuilder).
        await events.first;
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(n, 1, reason: 'no reconnect after the subscription was cancelled');
      }
      kraty.close();
    });

    test('inventory reconnects after close; autoReconnect: false keeps one connection', () async {
      var n = 0;
      final fake = ScriptClient((call) async {
        n++;
        return sseRes(Stream.value(utf8.encode(ev('ready', <String, Object?>{}) +
            ev('inventory_changed', <String, Object?>{'itemKey': 'gem$n'}) +
            ev('close', <String, Object?>{'reason': 'rebalance', 'retryAfterMs': 5}))));
      });
      final kraty = kratyWith(fake);
      final stream = await kraty.inventory.live();
      final events = await stream.events.take(4).toList();
      await stream.cancel();
      expect(events.map((e) => e.kind).toList(), <String>['ready', 'inventory_changed', 'ready', 'inventory_changed']);
      expect(events[3].itemKey, 'gem2');

      final single = await kraty.inventory.live(autoReconnect: false);
      final raw = await single.events.toList();
      expect(raw.map((e) => e.kind).toList(), <String>['ready', 'inventory_changed', 'close']);
      kraty.close();
    });
  });
}

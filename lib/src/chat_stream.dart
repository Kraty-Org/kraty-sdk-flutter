import 'dart:async';

import 'package:http/http.dart' as http;

import 'errors.dart';
import 'reconnecting_sse.dart';
import 'sse.dart';
import 'types.dart';

/// Live chat feed for one player (docs/26): every conversation they're in,
/// plus the public channels they asked to follow. One stream per player.
///
/// Message text arrives already resolved for this viewer (their profanity
/// filter choice applied), and messages from players they block never
/// arrive. By default `chat.live()` heals itself: it reconnects after any
/// drop and catches up the messages it missed (see [ChatStream]). With
/// `autoReconnect: false` it holds a single connection and does not
/// replay: after a reconnect, catch each conversation up with
/// `chat.messages(id, after: <last seq seen>)`.

String _str(Map<String, Object?> data, String key) {
  final v = data[key];
  return v is String ? v : '';
}

String? _nullableStr(Map<String, Object?> data, String key) {
  final v = data[key];
  return v is String ? v : null;
}

int _int(Map<String, Object?> data, String key) {
  final v = data[key];
  if (v is int) return v;
  if (v is num) return v.toInt();
  return 0;
}

/// One event off the chat stream. A sealed family: `switch` over the
/// subclasses. [kind] is the SSE `event:` line and [data] the raw payload,
/// for anything a newer backend adds; unknown kinds arrive as
/// [ChatUnknownEvent].
sealed class ChatStreamEvent {
  final String kind;
  final Map<String, Object?> data;

  const ChatStreamEvent(this.kind, this.data);

  /// Maps one SSE event onto its typed class.
  factory ChatStreamEvent.fromSse(String kind, Map<String, Object?> data) {
    switch (kind) {
      case 'ready':
        return ChatReadyEvent._(data);
      case 'message':
        return ChatMessageEvent._(data);
      case 'message_edited':
        return ChatMessageEditedEvent._(data);
      case 'message_deleted':
        return ChatMessageDeletedEvent._(data);
      case 'typing':
        return ChatTypingEvent._(data);
      case 'read':
        return ChatReadEvent._(data);
      case 'conversation_added':
        return ChatConversationAddedEvent._(data);
      case 'conversation_updated':
        return ChatConversationUpdatedEvent._(data);
      case 'conversation_removed':
        return ChatConversationRemovedEvent._(data);
      case 'restriction':
        return ChatRestrictionEvent._(data);
      case 'restriction_lifted':
        return ChatRestrictionLiftedEvent._(data);
      case 'close':
        return ChatCloseEvent._(data);
      default:
        return ChatUnknownEvent._(kind, data);
    }
  }
}

/// A public channel the stream follows: the conversation of the player's
/// [room] (0-based) in it.
class ChatStreamChannel {
  final String key;
  final String conversationId;
  final int room;
  const ChatStreamChannel({required this.key, required this.conversationId, this.room = 0});
}

/// `ready`: the subscription is wired; nothing sent after it is missed.
class ChatReadyEvent extends ChatStreamEvent {
  ChatReadyEvent._(Map<String, Object?> data) : super('ready', data);

  String get externalPlayerId => _str(data, 'externalPlayerId');

  /// The inbox conversations this stream follows.
  List<String> get conversationIds {
    final v = data['conversationIds'];
    return v is List ? v.whereType<String>().toList(growable: false) : const <String>[];
  }

  /// The channels from `live(channels: ...)`, with their conversation ids.
  List<ChatStreamChannel> get channels {
    final v = data['channels'];
    if (v is! List) return const <ChatStreamChannel>[];
    return v
        .whereType<Map<Object?, Object?>>()
        .map((m) {
          final c = m.cast<String, Object?>();
          return ChatStreamChannel(
            key: _str(c, 'key'),
            conversationId: _str(c, 'conversationId'),
            room: _int(c, 'room'),
          );
        })
        .toList(growable: false);
  }

  /// Every followed conversation's latest `seq` at connect time (inbox and
  /// channel rooms). The self-healing stream seeds its catch-up from it.
  /// Null from older servers.
  Map<String, int>? get lastSeqs => _lastSeqs(data);
}

Map<String, int>? _lastSeqs(Map<String, Object?> data) {
  final v = data['lastSeqs'];
  if (v is! Map) return null;
  return <String, int>{
    for (final e in v.entries)
      if (e.key is String && e.value is num) e.key as String: (e.value as num).toInt(),
  };
}

/// `message`: a new message, already resolved for this viewer.
class ChatMessageEvent extends ChatStreamEvent {
  final ChatMessage message;
  ChatMessageEvent._(Map<String, Object?> data)
      : message = ChatMessage.fromJson(data),
        super('message', data);
}

/// `message_edited`: the sender edited a message. [message] is the full
/// updated copy ([ChatMessage.editedAt] set); replace it by `messageId`.
class ChatMessageEditedEvent extends ChatStreamEvent {
  final ChatMessage message;
  ChatMessageEditedEvent._(Map<String, Object?> data)
      : message = ChatMessage.fromJson(data),
        super('message_edited', data);
}

/// `message_deleted`: drop the message (or show it as removed).
class ChatMessageDeletedEvent extends ChatStreamEvent {
  ChatMessageDeletedEvent._(Map<String, Object?> data) : super('message_deleted', data);
  String get conversationId => _str(data, 'conversationId');
  String get messageId => _str(data, 'messageId');
  int get seq => _int(data, 'seq');
}

/// `typing`: another player is typing (never your own echo).
class ChatTypingEvent extends ChatStreamEvent {
  ChatTypingEvent._(Map<String, Object?> data) : super('typing', data);
  String get conversationId => _str(data, 'conversationId');
  ChatPlayerRef? get player => ChatPlayerRef.maybe(data, 'player');
}

/// `read`: another member read up to [seq] (read receipts).
class ChatReadEvent extends ChatStreamEvent {
  ChatReadEvent._(Map<String, Object?> data) : super('read', data);
  String get conversationId => _str(data, 'conversationId');
  String get externalPlayerId => _str(data, 'externalPlayerId');
  int get seq => _int(data, 'seq');
}

/// `conversation_added`: the player joined a conversation (a new DM, added
/// to a group, joined a guild). The stream follows it from now on.
class ChatConversationAddedEvent extends ChatStreamEvent {
  ChatConversationAddedEvent._(Map<String, Object?> data) : super('conversation_added', data);
  String get conversationId => _str(data, 'conversationId');

  /// The conversation's kind (`direct`, `group`, `guild`, …).
  String get conversationKind => _str(data, 'kind');
}

/// `conversation_updated`: title, metadata or member count changed.
class ChatConversationUpdatedEvent extends ChatStreamEvent {
  ChatConversationUpdatedEvent._(Map<String, Object?> data) : super('conversation_updated', data);
  String get conversationId => _str(data, 'conversationId');
  String? get title => _nullableStr(data, 'title');
  Map<String, Object?> get metadata {
    final v = data['metadata'];
    return v is Map ? v.cast<String, Object?>() : const <String, Object?>{};
  }

  int get memberCount => _int(data, 'memberCount');
}

/// `conversation_removed`: the player left or was removed; the stream
/// stops following it.
class ChatConversationRemovedEvent extends ChatStreamEvent {
  ChatConversationRemovedEvent._(Map<String, Object?> data) : super('conversation_removed', data);
  String get conversationId => _str(data, 'conversationId');

  /// `left`, `removed`, …
  String get reason => _str(data, 'reason');
}

/// `restriction`: the player was warned, muted or chat-banned.
class ChatRestrictionEvent extends ChatStreamEvent {
  ChatRestrictionEvent._(Map<String, Object?> data) : super('restriction', data);
  String get restrictionId => _str(data, 'restrictionId');

  /// `warning`, `chat_mute` or `chat_ban`.
  String get restrictionKind => _str(data, 'kind');
  String? get reason => _nullableStr(data, 'reason');
  String? get expiresAt => _nullableStr(data, 'expiresAt');
}

/// `restriction_lifted`: a mute or ban ended early.
class ChatRestrictionLiftedEvent extends ChatStreamEvent {
  ChatRestrictionLiftedEvent._(Map<String, Object?> data) : super('restriction_lifted', data);
  String get restrictionId => _str(data, 'restrictionId');
  String get restrictionKind => _str(data, 'kind');
}

/// `close`: the server is closing the stream: `shutdown`, `rebalance`, or
/// `slow_consumer` (this client stopped reading). Only delivered with
/// `autoReconnect: false` (the default stream reconnects on its own and
/// never shows it): treat it like a drop, reconnect after [retryAfterMs],
/// then catch up.
class ChatCloseEvent extends ChatStreamEvent {
  ChatCloseEvent._(Map<String, Object?> data) : super('close', data);

  /// Why: `shutdown`, `rebalance`, `slow_consumer`, or empty.
  String get reason => _str(data, 'reason');

  /// How long the server asks the client to wait before reconnecting (ms;
  /// 0 when it didn't say).
  int get retryAfterMs => _int(data, 'retryAfterMs');
}

/// An event kind this SDK version doesn't know yet.
class ChatUnknownEvent extends ChatStreamEvent {
  ChatUnknownEvent._(super.kind, super.data);
}

/// Handle to an active chat subscription. Call [cancel] to stop.
///
/// By default (`chat.live()` with `autoReconnect: true`) the stream heals
/// itself: after a server `close`, a network drop, a busy server (503) or
/// heartbeat silence (`heartbeatTimeout`), it reconnects on its own and
/// then delivers the messages it missed, as ordinary [ChatMessageEvent]s,
/// before any live event of the new connection: every followed
/// conversation is caught up from the last `seq` known (quiet ones from
/// [ChatReadyEvent.lastSeqs], ones added during the gap from the start). Message events are deduped
/// by `(conversationId, seq)`, so a message is never delivered twice.
/// [ChatCloseEvent] is not delivered in this mode; [connection] reports
/// `reconnecting` / `connected`; [errors] only carries fatal errors (say,
/// 403 `chat_disabled` on a reconnect), after which [events] ends.
///
/// With `autoReconnect: false` it is the old single connection: [events]
/// ends when the connection does, [errors] carries transport failures and
/// [ChatCloseEvent] is delivered; reconnect and catch up yourself.
class ChatStream {
  /// Server-pushed events (every `ready`, including after a reconnect).
  /// Single-subscriber.
  final Stream<ChatStreamEvent> events;

  /// With auto-reconnect: fatal errors only (the stream ends after one).
  /// Without: transport failures and malformed payloads; re-invoke
  /// `chat.live()` after a backoff, then catch up with
  /// `chat.messages(id, after: lastSeq)`. Broadcast.
  final Stream<Object> errors;

  /// Connection status: `connected` after each successful (re)connect,
  /// once missed messages were caught up; `reconnecting` (with a reason,
  /// the wait and the try number) when the connection was lost. Not an
  /// error: show a "reconnecting…" hint. Single-subscriber and buffered.
  /// Empty with `autoReconnect: false`.
  ///
  /// A separate stream rather than a [ChatStreamEvent] subclass, so
  /// exhaustive `switch`es over [ChatStreamEvent] keep compiling.
  final Stream<KratyConnectionEvent> connection;

  final KratyConnectionState Function() _state;
  final Future<void> Function() _cancel;

  ChatStream._(this.events, this.errors, this.connection, this._state, this._cancel);

  /// The current connection state. Always `connected` with
  /// `autoReconnect: false`.
  KratyConnectionState get connectionState => _state();

  /// Cancels the subscription, closes the HTTP socket and cancels any
  /// pending reconnect. Idempotent.
  Future<void> cancel() => _cancel();
}

/// One page of messages for the chat stream's catch-up: the raw message
/// JSON (oldest first) and whether more follow.
typedef ChatCatchUpPage = ({List<Map<String, Object?>> messages, bool hasMore});

/// Opens the player's chat SSE stream. [channels] are public channel keys
/// to follow (at most 10); [filter] is `on` / `off`, sent both as
/// `?filter=` and as the `X-Kraty-Chat-Filter` header.
///
/// With [autoReconnect] (the `chat.live()` default) the stream reconnects
/// itself (see [ChatStream]) and catches up through [fetchAfter]
/// (`messages(id, after:)`); without it, a single connection.
Future<ChatStream> openChatStream({
  required String baseUrl,
  required String externalPlayerId,
  required String authHeader,
  required http.Client httpClient,
  required String sdkUserAgent,
  String? playerSecret,
  String? Function()? currentPlayerSecret,
  List<String>? channels,
  String? filter,
  bool autoReconnect = false,
  Duration heartbeatTimeout = const Duration(seconds: 40),
  Future<ChatCatchUpPage> Function(String conversationId, int after)? fetchAfter,
}) async {
  final query = <String>[
    if (channels != null && channels.isNotEmpty)
      'channels=${Uri.encodeQueryComponent(channels.join(','))}',
    if (filter != null) 'filter=$filter',
  ];
  Future<SseStream> connect({void Function()? onActivity}) => openSseStream(
        baseUrl: baseUrl,
        path: '/sdk/v1/players/${Uri.encodeComponent(externalPlayerId)}/chat/stream'
            '${query.isEmpty ? '' : '?${query.join('&')}'}',
        authHeader: authHeader,
        httpClient: httpClient,
        sdkUserAgent: sdkUserAgent,
        label: 'chat stream',
        playerSecret: currentPlayerSecret?.call() ?? playerSecret,
        headers: filter == null ? null : <String, String>{'x-kraty-chat-filter': filter},
        onActivity: onActivity,
      );

  if (!autoReconnect) {
    final raw = await connect();
    return ChatStream._(
      raw.events.map((e) => ChatStreamEvent.fromSse(e.kind, e.data)),
      raw.errors,
      const Stream<KratyConnectionEvent>.empty(),
      () => KratyConnectionState.connected,
      raw.cancel,
    );
  }

  // Last seq known per conversation: dedupes message events and drives
  // the catch-up after a reconnect.
  final lastSeq = <String, int>{};
  // Whether a `ready` seeded the cursors from `lastSeqs` (servers that send
  // it): after that, a followed conversation without a cursor is new.
  var seeded = false;
  // The latest `ready`, and whether cursors were already seeded before it.
  Map<String, Object?>? ready;
  var seededBeforeReady = false;

  bool accept(SseEvent ev) {
    if (ev.kind == 'ready') {
      ready = ev.data;
      seededBeforeReady = seeded;
      final heads = _lastSeqs(ev.data);
      if (heads != null && !seeded) {
        // Every followed conversation's seq at connect time: quiet ones get a cursor too.
        heads.forEach((conv, seq) => lastSeq.putIfAbsent(conv, () => seq));
        seeded = true;
      }
      return true;
    }
    final conv = ev.data['conversationId'];
    if (conv is! String) return true;
    switch (ev.kind) {
      case 'message':
        final seq = ev.data['seq'];
        if (seq is! num) return true;
        final prev = lastSeq[conv];
        if (prev != null && seq <= prev) return false;
        lastSeq[conv] = seq.toInt();
        return true;
      case 'message_deleted':
        final seq = ev.data['seq'];
        if (seq is num) {
          final prev = lastSeq[conv];
          if (prev == null || seq > prev) lastSeq[conv] = seq.toInt();
        }
        return true;
      case 'conversation_added':
        // New to the player: its whole history counts as missed on a reconnect.
        lastSeq.putIfAbsent(conv, () => 0);
        return true;
      case 'conversation_removed':
        lastSeq.remove(conv);
        return true;
      default:
        return true;
    }
  }

  // Runs after a reconnect's `ready` (accept has already seen it).
  Future<void> catchUp(void Function(SseEvent event) emit) async {
    final fetch = fetchAfter;
    if (fetch == null) return;
    final r = ready;
    final heads = r == null ? null : _lastSeqs(r);
    if (r != null && seededBeforeReady) {
      // Followed now but no cursor: it appeared during the gap, so its whole history is missed.
      final ids = r['conversationIds'];
      final chans = r['channels'];
      final followed = <Object?>[
        if (ids is List) ...ids,
        if (chans is List) ...chans.whereType<Map<Object?, Object?>>().map((c) => c['conversationId']),
        ...?heads?.keys,
      ];
      for (final id in followed.whereType<String>()) {
        if (id.isNotEmpty) lastSeq.putIfAbsent(id, () => 0);
      }
    }
    for (final conv in List<String>.of(lastSeq.keys)) {
      var after = lastSeq[conv];
      // The server says nothing is newer than what we have: skip the request.
      final head = heads?[conv];
      if (after != null && head != null && head <= after) continue;
      while (after != null) {
        final ChatCatchUpPage page;
        try {
          page = await fetch(conv, after);
        } on KratyApiError catch (err) {
          if (isTransientKratyError(err, include429: true)) rethrow;
          // Gone, or no longer readable: stop following it.
          lastSeq.remove(conv);
          break;
        }
        for (final m in page.messages) {
          emit(SseEvent(
            kind: 'message',
            data: m['conversationId'] is String ? m : <String, Object?>{...m, 'conversationId': conv},
          ));
        }
        // An empty page that says hasMore (every message hidden from this
        // player) stops here with the cursor unchanged: the next reconnect
        // retries, and this never spins.
        final last = page.messages.isEmpty ? null : page.messages.last['seq'];
        if (!page.hasMore || last is! num) break;
        after = last.toInt();
      }
    }
  }

  final core = ReconnectingSse(
    connect: (onActivity) => connect(onActivity: onActivity),
    heartbeatTimeout: heartbeatTimeout,
    accept: accept,
    onReconnectReady: catchUp,
  );
  await core.start();
  return ChatStream._(
    core.events.map((e) => ChatStreamEvent.fromSse(e.kind, e.data)),
    core.errors,
    core.connection,
    () => core.state,
    core.cancel,
  );
}

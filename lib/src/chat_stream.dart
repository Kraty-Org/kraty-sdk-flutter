import 'dart:async';

import 'package:http/http.dart' as http;

import 'sse.dart';
import 'types.dart';

/// Live chat feed for one player (docs/26): every conversation they're in,
/// plus the public channels they asked to follow. One stream per player.
///
/// Message text arrives already resolved for this viewer (their profanity
/// filter choice applied), and messages from players they block never
/// arrive. The stream does NOT auto-reconnect and does not replay: after a
/// reconnect, catch each conversation up with
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

/// A public channel the stream follows.
class ChatStreamChannel {
  final String key;
  final String conversationId;
  const ChatStreamChannel({required this.key, required this.conversationId});
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
          return ChatStreamChannel(key: _str(c, 'key'), conversationId: _str(c, 'conversationId'));
        })
        .toList(growable: false);
  }
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

/// `close`: the server is draining. Reconnect (then catch up).
class ChatCloseEvent extends ChatStreamEvent {
  ChatCloseEvent._(Map<String, Object?> data) : super('close', data);
  String get reason => _str(data, 'reason');
}

/// An event kind this SDK version doesn't know yet.
class ChatUnknownEvent extends ChatStreamEvent {
  ChatUnknownEvent._(super.kind, super.data);
}

/// Handle to an active chat subscription. Call [cancel] to stop.
class ChatStream {
  /// Server-pushed events. Single-subscriber.
  final Stream<ChatStreamEvent> events;

  /// Transport failures. The SDK does NOT auto-reconnect; listen here and
  /// re-invoke `chat.live()` after a backoff, then catch up with
  /// `chat.messages(id, after: lastSeq)`.
  final Stream<Object> errors;

  final Future<void> Function() _cancel;

  const ChatStream._(this.events, this.errors, this._cancel);

  /// Cancels the subscription + closes the HTTP socket. Idempotent.
  Future<void> cancel() => _cancel();
}

/// Opens the player's chat SSE stream. [channels] are public channel keys
/// to follow (at most 10); [filter] is `on` / `off`, sent both as
/// `?filter=` and as the `X-Kraty-Chat-Filter` header. Does NOT
/// auto-reconnect.
Future<ChatStream> openChatStream({
  required String baseUrl,
  required String externalPlayerId,
  required String authHeader,
  required http.Client httpClient,
  required String sdkUserAgent,
  String? playerSecret,
  List<String>? channels,
  String? filter,
}) async {
  final query = <String>[
    if (channels != null && channels.isNotEmpty)
      'channels=${Uri.encodeQueryComponent(channels.join(','))}',
    if (filter != null) 'filter=$filter',
  ];
  final raw = await openSseStream(
    baseUrl: baseUrl,
    path: '/sdk/v1/players/${Uri.encodeComponent(externalPlayerId)}/chat/stream'
        '${query.isEmpty ? '' : '?${query.join('&')}'}',
    authHeader: authHeader,
    httpClient: httpClient,
    sdkUserAgent: sdkUserAgent,
    label: 'chat stream',
    playerSecret: playerSecret,
    headers: filter == null ? null : <String, String>{'x-kraty-chat-filter': filter},
  );
  return ChatStream._(
    raw.events.map((e) => ChatStreamEvent.fromSse(e.kind, e.data)),
    raw.errors,
    raw.cancel,
  );
}

import 'dart:async';

import 'package:http/http.dart' as http;

import 'reconnecting_sse.dart';
import 'sse.dart';

/// One event emitted by the leaderboard SSE stream.
/// [kind] is the SSE `event:` line. Typically:
///   - `ready`: handshake, sent once after the subscription is wired
///   - `score_update`: a participant's score / rank changed
///   - `finalized`: the board ended (a session/lobby terminated, or the
///     event window closed). [data] carries `reason`
///     (`session_terminated` | `window_closed`) and `standings`
///     (a list of `{participantId, rank, score, name, kind}`). Find the
///     caller by `participantId` to show their placement, then stop
///     expecting `score_update`s.
///   - `closed`: the board ended for good (`reason: finalized`); the
///     stream ends after it and never reconnects
///   - `close`: the server is draining this connection (only delivered
///     with `autoReconnect: false`; the default stream reconnects itself)
///
/// [data] is the parsed `data:` JSON line (or null if it didn't parse).
class LeaderboardStreamEvent {
  final String kind;
  final Map<String, Object?> data;
  const LeaderboardStreamEvent({required this.kind, required this.data});
}

/// Handle to an active SSE subscription. Call [cancel] to stop.
///
/// By default the stream heals itself: after a server `close`, a network
/// drop, a busy server or heartbeat silence it reconnects on its own (no
/// replay: re-read the board on `connected` if you need exact standings).
/// It ends for good after `closed`. With `autoReconnect: false` it is a
/// single connection and [errors] carries transport failures.
class LeaderboardStream {
  /// Event stream: yields `ready` / `score_update` / `finalized` /
  /// `closed` / any future event kinds the server adds. Single-subscriber.
  final Stream<LeaderboardStreamEvent> events;

  /// With auto-reconnect: fatal errors only (the stream ends after one).
  /// Without: transport failures (network drop, server crash
  /// mid-stream); re-invoke `live(...)` after a backoff. Broadcast.
  final Stream<Object> errors;

  /// Connection status (`connected` / `reconnecting`); see
  /// [KratyConnectionEvent]. Single-subscriber and buffered. Empty with
  /// `autoReconnect: false`.
  final Stream<KratyConnectionEvent> connection;

  final KratyConnectionState Function() _state;
  final Future<void> Function() _cancel;

  LeaderboardStream._(
    this.events,
    this.errors,
    this.connection,
    this._state,
    this._cancel,
  );

  /// The current connection state. Always `connected` with
  /// `autoReconnect: false`.
  KratyConnectionState get connectionState => _state();

  /// Cancels the subscription, closes the HTTP socket and cancels any
  /// pending reconnect. Idempotent, so it's safe to call after the server
  /// emits `closed`.
  Future<void> cancel() => _cancel();
}

/// Opens an SSE subscription to a leaderboard. Returns a
/// [LeaderboardStream] handle the caller drives via its event/error
/// streams. With [autoReconnect] it reconnects itself (never after
/// `closed`); without, a single connection.
///
/// The SSE framing itself is parsed by the shared reader in `sse.dart`;
/// this only maps the generic events onto the leaderboard-shaped type.
Future<LeaderboardStream> openLeaderboardStream({
  required String baseUrl,
  required String leaderboardId,
  required String authHeader,
  required http.Client httpClient,
  required String sdkUserAgent,
  String? playerSecret,
  String? Function()? currentPlayerSecret,
  bool autoReconnect = false,
  Duration heartbeatTimeout = const Duration(seconds: 40),
}) async {
  Future<SseStream> connect({void Function()? onActivity}) => openSseStream(
        baseUrl: baseUrl,
        path: '/sdk/v1/event-leaderboards/$leaderboardId/stream',
        authHeader: authHeader,
        httpClient: httpClient,
        sdkUserAgent: sdkUserAgent,
        label: 'leaderboard stream',
        playerSecret: currentPlayerSecret?.call() ?? playerSecret,
        onActivity: onActivity,
      );
  LeaderboardStreamEvent map(SseEvent e) => LeaderboardStreamEvent(kind: e.kind, data: e.data);

  if (!autoReconnect) {
    final raw = await connect();
    return LeaderboardStream._(
      raw.events.map(map),
      raw.errors,
      const Stream<KratyConnectionEvent>.empty(),
      () => KratyConnectionState.connected,
      raw.cancel,
    );
  }
  final core = ReconnectingSse(
    connect: (onActivity) => connect(onActivity: onActivity),
    heartbeatTimeout: heartbeatTimeout,
    isTerminal: (e) => e.kind == 'closed',
  );
  await core.start();
  return LeaderboardStream._(core.events.map(map), core.errors, core.connection, () => core.state, core.cancel);
}

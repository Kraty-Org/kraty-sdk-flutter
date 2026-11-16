import 'dart:async';
import 'dart:math' as math;

import 'errors.dart';
import 'sse.dart';

/// Whether a self-healing live stream is currently connected.
enum KratyConnectionState {
  /// Connected and caught up: events are live.
  connected,

  /// The connection was lost (or not yet made); the SDK is reconnecting.
  reconnecting,
}

/// Connection status of a self-healing live stream (`chat.live()`,
/// `eventLeaderboards.live()`, `inventory.live()`). A status signal, never
/// an error: use it to show a "reconnecting…" hint.
///
/// - [KratyConnectionState.connected] after every successful connect: once
///   the server's `ready` arrived (and, for chat, once missed messages were
///   caught up). Also after the first connect.
/// - [KratyConnectionState.reconnecting] when the connection is lost, with
///   [reason], the wait before the next try ([retryIn]) and the try number
///   ([attempt], reset once a connection is ready).
class KratyConnectionEvent {
  final KratyConnectionState state;

  /// Why the connection was lost (`reconnecting` only): `shutdown`,
  /// `rebalance` or `slow_consumer` (the server closed it),
  /// `heartbeat_timeout` (nothing arrived for the heartbeat timeout),
  /// `error` (network drop or read error), `busy` (the server answered
  /// 503 to the reconnect) or `ended` (the server ended the stream without
  /// saying why). Null for `connected`.
  final String? reason;

  /// How long until the next connect try (`reconnecting` only).
  final Duration? retryIn;

  /// Which reconnect try this is, from 1 (`reconnecting` only).
  final int? attempt;

  const KratyConnectionEvent({
    required this.state,
    this.reason,
    this.retryIn,
    this.attempt,
  });

  /// True for [KratyConnectionState.connected].
  bool get isConnected => state == KratyConnectionState.connected;

  @override
  String toString() => state == KratyConnectionState.connected
      ? 'KratyConnectionEvent(connected)'
      : 'KratyConnectionEvent(reconnecting, reason: $reason, retryIn: $retryIn, attempt: $attempt)';
}

/// Opens one SSE connection; [onActivity] must fire for every line
/// received (comments included).
typedef SseConnector = Future<SseStream> Function(void Function() onActivity);

/// Thrown into a catch-up when its connection was replaced mid-way.
class _StaleConnection implements Exception {
  const _StaleConnection();
}

/// Self-healing SSE subscription shared by the chat, leaderboard and
/// inventory `live()` helpers (internal).
///
/// - `close` events (server draining / `slow_consumer`) are not
///   delivered: the loop waits `retryAfterMs` and reconnects.
/// - A drop, read error, end of stream, or a retryable failure to open
///   (network, 5xx incl. 503, 408, 429) reconnects after `Retry-After` /
///   `details.retryAfterSeconds`, else jittered exponential backoff
///   (1 s · 2^(n-1) · [0.5, 1], capped at 15 s). The try counter resets
///   once a connection's `ready` arrives.
/// - Any other 4xx when opening is fatal: [start] throws it on the very
///   first try, later ones land on [errors] and the streams end.
/// - Heartbeat watchdog: nothing (event or `: ping`) for
///   [heartbeatTimeout] closes the connection and reconnects.
///   [Duration.zero] (or less) turns the watchdog off.
/// - Cancelling the [events] subscription (a disposed `StreamBuilder`,
///   `break` in an `await for`) stops everything, like [cancel].
/// - [onReconnectReady] runs after the `ready` of every connection but the
///   first one that got ready; live events of that connection are held
///   until it completes. If it throws, the connection is treated as
///   dropped (and the catch-up repeats on the next one).
/// - [isTerminal] marks an event after which the stream ends for good
///   (leaderboard `closed`).
class ReconnectingSse {
  ReconnectingSse({
    required SseConnector connect,
    required Duration heartbeatTimeout,
    bool Function(SseEvent event)? isTerminal,
    bool Function(SseEvent event)? accept,
    Future<void> Function(void Function(SseEvent event) emit)? onReconnectReady,
    math.Random? random,
  })  : _connect = connect,
        _heartbeatTimeout = heartbeatTimeout,
        _isTerminal = isTerminal,
        _accept = accept,
        _onReconnectReady = onReconnectReady,
        _random = random ?? math.Random();

  final SseConnector _connect;
  final Duration _heartbeatTimeout;
  final bool Function(SseEvent event)? _isTerminal;
  final bool Function(SseEvent event)? _accept;
  final Future<void> Function(void Function(SseEvent event) emit)? _onReconnectReady;
  final math.Random _random;

  late final StreamController<SseEvent> _events = StreamController<SseEvent>(onCancel: _finish);
  final StreamController<Object> _errors = StreamController<Object>.broadcast();
  final StreamController<KratyConnectionEvent> _connection = StreamController<KratyConnectionEvent>();

  KratyConnectionState _state = KratyConnectionState.reconnecting;
  bool _stopped = false;
  bool _hadReady = false;
  int _gen = 0;
  int _attempt = 0;
  SseStream? _current;
  StreamSubscription<SseEvent>? _eventSub;
  StreamSubscription<Object>? _errorSub;
  Timer? _watchdog;
  Timer? _retryTimer;
  Future<void> _chain = Future<void>.value();

  /// Delivered events (minus `close`), in order. Single-subscriber.
  Stream<SseEvent> get events => _events.stream;

  /// Fatal errors only; the streams end right after. Broadcast.
  Stream<Object> get errors => _errors.stream;

  /// Connection status changes. Single-subscriber, buffered.
  Stream<KratyConnectionEvent> get connection => _connection.stream;

  /// The current connection state.
  KratyConnectionState get state => _state;

  /// Makes the first connection attempt. Throws when it fails fatally;
  /// a transient failure doesn't throw: the stream starts in
  /// `reconnecting` and keeps trying.
  Future<void> start() => _open(first: true);

  /// Stops for good: closes the connection and cancels any pending
  /// reconnect. Idempotent.
  Future<void> cancel() async {
    if (_stopped) return;
    _finish();
  }

  Future<void> _open({bool first = false}) async {
    if (_stopped) return;
    final gen = ++_gen;
    final SseStream stream;
    try {
      stream = await _connect(() => _onActivity(gen));
    } catch (err) {
      if (_stopped || gen != _gen) return;
      if (!isTransientKratyError(err, include429: true)) {
        if (first) {
          _finish();
          rethrow;
        }
        _fail(err);
        return;
      }
      final busy = err is KratyApiError && err.status == 503;
      _scheduleReconnect(busy ? 'busy' : 'error', wait: err is KratyApiError ? err.retryAfter : null);
      return;
    }
    if (_stopped || gen != _gen) {
      unawaited(stream.cancel().catchError((Object _) {}));
      return;
    }
    _current = stream;
    _armWatchdog(gen);
    _eventSub = stream.events.listen(
      (ev) => _enqueue(() => _handle(gen, ev)),
      onDone: () => _enqueue(() async => _drop(gen, 'ended')),
    );
    _errorSub = stream.errors.listen((err) {
      // A malformed payload isn't a dead connection: skip it.
      if (err is FormatException) return;
      _drop(gen, 'error');
    });
  }

  void _enqueue(Future<void> Function() step) {
    _chain = _chain.then((_) => step()).catchError((Object _) {});
  }

  void _onActivity(int gen) {
    if (gen == _gen && !_stopped) _armWatchdog(gen);
  }

  void _armWatchdog(int gen) {
    _watchdog?.cancel();
    _watchdog = null;
    if (_heartbeatTimeout <= Duration.zero) return; // watchdog off
    _watchdog = Timer(_heartbeatTimeout, () => _drop(gen, 'heartbeat_timeout'));
  }

  void _emit(SseEvent ev) {
    if (_events.isClosed) return;
    if (_accept != null && !_accept(ev)) return;
    _events.add(ev);
  }

  Future<void> _handle(int gen, SseEvent ev) async {
    if (_stopped || gen != _gen) return;
    if (ev.kind == 'close') {
      final ms = ev.data['retryAfterMs'];
      final r = ev.data['reason'];
      _drop(
        gen,
        r is String && r.isNotEmpty ? r : 'shutdown',
        wait: ms is num && ms >= 0 ? Duration(milliseconds: ms.round()) : null,
      );
      return;
    }
    if (ev.kind == 'ready') {
      _attempt = 0;
      _emit(ev);
      final catchUp = _onReconnectReady;
      if (_hadReady && catchUp != null) {
        try {
          await catchUp((e) {
            if (_stopped || gen != _gen) throw const _StaleConnection();
            _emit(e);
          });
        } catch (_) {
          // Network / 5xx during catch-up (or the connection already gone):
          // treat as a drop; the next connection catches up again.
          _drop(gen, 'error');
          return;
        }
        if (_stopped || gen != _gen) return;
      }
      _hadReady = true;
      _state = KratyConnectionState.connected;
      if (!_connection.isClosed) {
        _connection.add(const KratyConnectionEvent(state: KratyConnectionState.connected));
      }
      return;
    }
    _emit(ev);
    if (_isTerminal?.call(ev) ?? false) _finish();
  }

  void _drop(int gen, String reason, {Duration? wait}) {
    if (_stopped || gen != _gen) return;
    _gen++;
    _teardown();
    _scheduleReconnect(reason, wait: wait);
  }

  void _scheduleReconnect(String reason, {Duration? wait}) {
    _attempt++;
    final delay = wait ?? _backoff(_attempt);
    _state = KratyConnectionState.reconnecting;
    if (!_connection.isClosed) {
      _connection.add(KratyConnectionEvent(
        state: KratyConnectionState.reconnecting,
        reason: reason,
        retryIn: delay,
        attempt: _attempt,
      ));
    }
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      unawaited(_open());
    });
  }

  Duration _backoff(int attempt) {
    final base = 1000 * math.pow(2, math.min(attempt - 1, 10));
    final ms = math.min(15000, base * (0.5 + _random.nextDouble() * 0.5));
    return Duration(milliseconds: ms.round());
  }

  void _teardown() {
    _watchdog?.cancel();
    _watchdog = null;
    unawaited(_eventSub?.cancel());
    unawaited(_errorSub?.cancel());
    _eventSub = null;
    _errorSub = null;
    final current = _current;
    _current = null;
    if (current != null) unawaited(current.cancel().catchError((Object _) {}));
  }

  void _fail(Object err) {
    if (!_errors.isClosed) _errors.add(err);
    _finish();
  }

  void _finish() {
    if (_stopped) return;
    _stopped = true;
    _gen++;
    _retryTimer?.cancel();
    _retryTimer = null;
    _teardown();
    // Not awaited: a single-subscriber controller nobody listened to never
    // reports done.
    unawaited(_events.close());
    unawaited(_errors.close());
    unawaited(_connection.close());
  }
}

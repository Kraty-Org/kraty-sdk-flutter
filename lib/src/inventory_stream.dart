import 'dart:async';

import 'package:http/http.dart' as http;

import 'reconnecting_sse.dart';
import 'sse.dart';

/// Live feed of everything that touches a player's items, wallet, and
/// grants — no matter who caused it.
///
/// Before this, a game only saw changes it made itself: a reward granted
/// from the dashboard, a currency credited by the studio's backend, or an
/// event payout landed in the database and the running client kept showing
/// stale numbers until the next launch.

/// Who caused a change. Lets a client skip the echo of its own writes.
class InventoryEventOrigin {
  static const String client = 'client';
  static const String server = 'server';
  static const String admin = 'admin';
  static const String engine = 'engine';
}

/// One event off the inventory stream. [kind] is the SSE `event:` line:
///
///   - `ready`             handshake, once the subscription is wired
///   - `inventory_changed` an item quantity moved
///   - `wallet_changed`    a currency / progression balance moved
///   - `grant_created`     a reward became claimable
///
/// [data] is the parsed payload. The typed getters below cover the common
/// fields; read [data] directly for anything a newer backend adds.
class InventoryStreamEvent {
  final String kind;
  final Map<String, Object?> data;

  const InventoryStreamEvent({required this.kind, required this.data});

  /// `client` / `server` / `admin` / `engine`; empty for `ready`.
  String get origin => _str('origin');

  /// Set on `inventory_changed`.
  String get itemKey => _str('itemKey');

  /// Set on `wallet_changed`.
  String get economyKey => _str('economyKey');

  /// Signed change; negative for a consume. 0 when not applicable.
  int get delta => _int('delta');

  /// Quantity AFTER the change (`inventory_changed`).
  int get quantity => _int('quantity');

  /// Balance AFTER the change (`wallet_changed`).
  int get balance => _int('balance');

  /// Ledger reason (`grant_deposit`, `consume`, `admin_grant`, …).
  String get reason => _str('reason');

  /// Set on `grant_created`; claim it with `grants.collectAll()`.
  String get grantId => _str('grantId');

  /// True when this event is the echo of a write the client itself made.
  bool get isOwnWrite => origin == InventoryEventOrigin.client;

  String _str(String key) {
    final v = data[key];
    return v is String ? v : '';
  }

  int _int(String key) {
    final v = data[key];
    if (v is int) return v;
    if (v is num) return v.toInt();
    return 0;
  }
}

/// Handle to an active inventory subscription. Call [cancel] to stop.
///
/// By default the stream heals itself: after a server `close`, a network
/// drop, a busy server or heartbeat silence it reconnects on its own (no
/// replay: re-read what you show on `connected`). With
/// `autoReconnect: false` it is a single connection and [errors] carries
/// transport failures.
class InventoryStream {
  /// Server-pushed events. Single-subscriber.
  final Stream<InventoryStreamEvent> events;

  /// With auto-reconnect: fatal errors only (the stream ends after one).
  /// Without: transport failures; re-invoke `inventory.live()` after a
  /// backoff if you want resumption. Broadcast.
  final Stream<Object> errors;

  /// Connection status (`connected` / `reconnecting`); see
  /// [KratyConnectionEvent]. Single-subscriber and buffered. Empty with
  /// `autoReconnect: false`.
  final Stream<KratyConnectionEvent> connection;

  final KratyConnectionState Function() _state;
  final Future<void> Function() _cancel;

  InventoryStream._(this.events, this.errors, this.connection, this._state, this._cancel);

  /// The current connection state. Always `connected` with
  /// `autoReconnect: false`.
  KratyConnectionState get connectionState => _state();

  /// Cancels the subscription, closes the HTTP socket and cancels any
  /// pending reconnect. Idempotent.
  Future<void> cancel() => _cancel();
}

/// Opens an SSE subscription to a player's inventory / wallet / grants.
/// With [autoReconnect] it reconnects itself; without, a single
/// connection.
Future<InventoryStream> openInventoryStream({
  required String baseUrl,
  required String externalPlayerId,
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
        path: '/sdk/v1/players/${Uri.encodeComponent(externalPlayerId)}/inventory/stream',
        authHeader: authHeader,
        httpClient: httpClient,
        sdkUserAgent: sdkUserAgent,
        label: 'inventory stream',
        playerSecret: currentPlayerSecret?.call() ?? playerSecret,
        onActivity: onActivity,
      );
  InventoryStreamEvent map(SseEvent e) => InventoryStreamEvent(kind: e.kind, data: e.data);

  if (!autoReconnect) {
    final raw = await connect();
    return InventoryStream._(
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
  );
  await core.start();
  return InventoryStream._(core.events.map(map), core.errors, core.connection, () => core.state, core.cancel);
}

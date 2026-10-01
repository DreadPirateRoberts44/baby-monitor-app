import 'dart:async';
import 'dart:convert';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import '../models/notify_event.dart';
import 'pi_connection_settings.dart';

enum ConnectionStatus { disconnected, connecting, connected }

/// Holds the persistent MQTT connection to the Pi's broker and decodes
/// babymonitor/notify messages into NotifyEvents. Reconnects on its own —
/// mirrors the Pi side's own paho client, which never gives up either
/// (see pi/notify.py). Runs inside the foreground service on Android so
/// it survives the app being backgrounded (see docs/PI_CONTRACT.md).
class NotifyListener {
  static const _topic = 'babymonitor/notify';

  /// Backoff schedule for retrying a *first* connect attempt that failed
  /// outright (wrong host, Pi off, not on its WiFi yet) -- mqtt_client's
  /// own autoReconnect only ever engages after a connection has
  /// succeeded at least once, so without this a failed initial connect()
  /// would otherwise sit disconnected forever until something (Settings,
  /// app restart) calls connect() again by hand.
  static const _retryDelays = [
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 20),
    Duration(seconds: 40),
    Duration(seconds: 60),
  ];

  final PiConnectionSettings settings;
  MqttServerClient? _client;
  Timer? _retryTimer;
  int _retryAttempt = 0;

  /// Bumped on every manual connect() call so a stale retry (scheduled
  /// before the settings changed, or before a newer manual reconnect)
  /// doesn't fire after the fact and stomp on a newer attempt.
  int _connectGeneration = 0;

  final _statusController = StreamController<ConnectionStatus>.broadcast();
  final _eventController = StreamController<NotifyEvent>.broadcast();

  Stream<ConnectionStatus> get statusStream => _statusController.stream;
  Stream<NotifyEvent> get events => _eventController.stream;

  NotifyListener(this.settings);

  Future<void> connect() async {
    _retryTimer?.cancel();
    _retryTimer = null;
    _retryAttempt = 0;
    final generation = ++_connectGeneration;
    await _attemptConnect(generation);
  }

  Future<void> _attemptConnect(int generation) async {
    final host = settings.host;
    if (host == null || host.isEmpty) return;

    _statusController.add(ConnectionStatus.connecting);

    final clientId = 'baby-monitor-app-${settings.deviceId.substring(0, 8)}';
    final client = MqttServerClient(host, clientId);
    client.port = settings.mqttPort;
    client.logging(on: false);
    client.keepAlivePeriod = 30;
    client.autoReconnect = true;
    client.onConnected = () {
      _retryAttempt = 0;
      _statusController.add(ConnectionStatus.connected);
    };
    client.onDisconnected = () {
      _statusController.add(ConnectionStatus.disconnected);
    };
    client.onAutoReconnect = () {
      _statusController.add(ConnectionStatus.connecting);
    };
    _client = client;

    final connMessage = MqttConnectMessage()
        .withClientIdentifier(clientId)
        .startClean()
        .withWillQos(MqttQos.atMostOnce);
    client.connectionMessage = connMessage;

    try {
      await client.connect();
    } catch (_) {
      client.disconnect();
      _statusController.add(ConnectionStatus.disconnected);
      _scheduleRetry(generation);
      return;
    }

    if (client.connectionStatus?.state != MqttConnectionState.connected) {
      _statusController.add(ConnectionStatus.disconnected);
      _scheduleRetry(generation);
      return;
    }

    // retain=True on the Pi side means we may immediately get a replayed
    // message here from a past session — NotifyEvent.isStale() is checked
    // by the consumer (see home_screen.dart) before treating it as live.
    client.subscribe(_topic, MqttQos.atLeastOnce);

    client.updates!.listen((messages) {
      for (final message in messages) {
        final payload = message.payload as MqttPublishMessage;
        final bytes = payload.payload.message;
        final text = MqttPublishPayload.bytesToStringAsString(bytes);
        _handleMessage(text);
      }
    });
  }

  void _scheduleRetry(int generation) {
    if (generation != _connectGeneration) return;
    final delay = _retryDelays[
        _retryAttempt.clamp(0, _retryDelays.length - 1)];
    _retryAttempt++;
    _retryTimer = Timer(delay, () {
      if (generation != _connectGeneration) return;
      _attemptConnect(generation);
    });
  }

  void _handleMessage(String text) {
    try {
      final json = jsonDecode(text) as Map<String, dynamic>;
      final event = NotifyEvent.tryParse(json);
      if (event != null) _eventController.add(event);
    } catch (_) {
      // Malformed payload from the broker — drop it rather than crash the
      // listener; the next message (or the next retained replay) recovers.
    }
  }

  void disconnect() {
    _connectGeneration++;
    _retryTimer?.cancel();
    _retryTimer = null;
    _client?.disconnect();
    _client = null;
  }

  void dispose() {
    disconnect();
    _statusController.close();
    _eventController.close();
  }
}

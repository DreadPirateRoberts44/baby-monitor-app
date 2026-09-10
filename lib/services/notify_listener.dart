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

  final PiConnectionSettings settings;
  MqttServerClient? _client;

  final _statusController = StreamController<ConnectionStatus>.broadcast();
  final _eventController = StreamController<NotifyEvent>.broadcast();

  Stream<ConnectionStatus> get statusStream => _statusController.stream;
  Stream<NotifyEvent> get events => _eventController.stream;

  NotifyListener(this.settings);

  Future<void> connect() async {
    final host = settings.host;
    if (host == null || host.isEmpty) return;

    _statusController.add(ConnectionStatus.connecting);

    final clientId = 'baby-monitor-app-${settings.deviceId.substring(0, 8)}';
    final client = MqttServerClient(host, clientId)
      ..port = settings.mqttPort
      ..logging(on: false)
      ..keepAlivePeriod = 30
      ..autoReconnect = true
      ..onConnected = () => _statusController.add(ConnectionStatus.connected)
      ..onDisconnected = () =>
          _statusController.add(ConnectionStatus.disconnected)
      ..onAutoReconnect = () =>
          _statusController.add(ConnectionStatus.connecting);
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
      return;
    }

    if (client.connectionStatus?.state != MqttConnectionState.connected) {
      _statusController.add(ConnectionStatus.disconnected);
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
    _client?.disconnect();
    _client = null;
  }

  void dispose() {
    disconnect();
    _statusController.close();
    _eventController.close();
  }
}

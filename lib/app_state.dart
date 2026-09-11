import 'package:flutter/foundation.dart';

import 'models/notify_event.dart';
import 'services/fake_pi_server.dart';
import 'services/local_event_queue.dart';
import 'services/notify_listener.dart';
import 'services/pi_connection_settings.dart';
import 'services/sync_api_client.dart';
import 'services/sync_coordinator.dart';

/// A crying session currently being displayed, built up from
/// cry_started -> reason_updated* -> cry_ended. Mirrors the Pi-side
/// session lifecycle described in PI_CONTRACT.md; reason_updated
/// mutates this in place without re-alerting.
class ActiveCrySession {
  final DateTime startedAt;
  Map<String, double>? latestReasonProbs;
  double? durationSeconds;
  bool ended;

  ActiveCrySession({required this.startedAt})
      : latestReasonProbs = null,
        durationSeconds = null,
        ended = false;
}

class AppState extends ChangeNotifier {
  final PiConnectionSettings settings;
  late final NotifyListener notifyListener;
  late final SyncApiClient syncApiClient;
  late final LocalEventQueue localEventQueue;
  late final SyncCoordinator syncCoordinator;

  ConnectionStatus connectionStatus = ConnectionStatus.disconnected;
  ActiveCrySession? activeSession;

  FakePiServer? _fakePiServer;
  bool get isUsingFakePiServer => _fakePiServer != null;

  String? _realHost;
  int? _realSyncPort;

  AppState(this.settings) {
    notifyListener = NotifyListener(settings);
    syncApiClient = SyncApiClient(settings);
    localEventQueue = LocalEventQueue();
    syncCoordinator =
        SyncCoordinator(queue: localEventQueue, client: syncApiClient);
    notifyListener.statusStream.listen((status) {
      connectionStatus = status;
      notifyListeners();
      // A fresh connection is the strongest signal we're back on the
      // Pi's WiFi -- opportunistically drain the local queue right away
      // rather than waiting for the next manual refresh.
      if (status == ConnectionStatus.connected) {
        syncCoordinator.sync();
      }
    });
    notifyListener.events.listen(_handleEvent);
  }

  Future<void> connect() => notifyListener.connect();

  /// Feeds a synthetic NotifyEvent through the same handling path a real
  /// MQTT message takes. Debug/dev-seed use only (see
  /// services/dev_seed_data.dart) -- lets the UI be exercised without a
  /// real Pi publishing anything.
  void simulateNotifyEvent(NotifyEvent event) => _handleEvent(event);

  void clearActiveSession() {
    activeSession = null;
    notifyListeners();
  }

  /// Starts an in-process fake sync API (see services/fake_pi_server.dart)
  /// and repoints Settings' host/port at it, so History/Care log can be
  /// exercised against realistic-looking cry/device/care history with no
  /// real Pi at all. Debug builds only (see settings_screen.dart's
  /// kDebugMode gate) -- remembers the real host/port so "Stop" restores
  /// them exactly, rather than leaving Settings pointed at localhost.
  Future<void> startFakePiServer() async {
    assert(kDebugMode, 'Fake Pi server is debug-only');
    if (_fakePiServer != null) return;
    _realHost = settings.host;
    _realSyncPort = settings.syncPort;
    final server = FakePiServer.generate();
    final port = await server.start();
    _fakePiServer = server;
    await settings.setHost('localhost');
    await settings.setSyncPort(port);
    notifyListeners();
  }

  Future<void> stopFakePiServer() async {
    if (_fakePiServer == null) return;
    await _fakePiServer!.stop();
    _fakePiServer = null;
    if (_realHost != null) await settings.setHost(_realHost!);
    if (_realSyncPort != null) await settings.setSyncPort(_realSyncPort!);
    notifyListeners();
  }

  void _handleEvent(NotifyEvent event) {
    // Stale retained-message replay from a past session — see
    // docs/PI_CONTRACT.md's MQTT section. Don't resurrect an old alert.
    if (event.isStale()) return;

    switch (event.kind) {
      case NotifyEventKind.cryStarted:
        activeSession = ActiveCrySession(startedAt: event.timestamp)
          ..latestReasonProbs = event.stage2Probs;
        break;
      case NotifyEventKind.reasonUpdated:
        // Silent refresh only — deliberately not an alert (see
        // PI_CONTRACT.md). If we missed the cry_started (e.g. app just
        // opened mid-session), synthesize a session so the UI has
        // something to show rather than dropping the update.
        activeSession ??= ActiveCrySession(startedAt: event.timestamp);
        activeSession!.latestReasonProbs = event.aggregatedStage2Probs;
        activeSession!.durationSeconds = event.durationSeconds;
        break;
      case NotifyEventKind.cryEnded:
        activeSession ??= ActiveCrySession(startedAt: event.timestamp);
        activeSession!.latestReasonProbs = event.aggregatedStage2Probs;
        activeSession!.durationSeconds = event.durationSeconds;
        activeSession!.ended = true;
        break;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    notifyListener.dispose();
    _fakePiServer?.stop();
    super.dispose();
  }
}

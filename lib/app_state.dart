import 'package:flutter/foundation.dart';

import 'models/notify_event.dart';
import 'services/notify_listener.dart';
import 'services/pi_connection_settings.dart';
import 'services/sync_api_client.dart';

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

  ConnectionStatus connectionStatus = ConnectionStatus.disconnected;
  ActiveCrySession? activeSession;

  AppState(this.settings) {
    notifyListener = NotifyListener(settings);
    syncApiClient = SyncApiClient(settings);
    notifyListener.statusStream.listen((status) {
      connectionStatus = status;
      notifyListeners();
    });
    notifyListener.events.listen(_handleEvent);
  }

  Future<void> connect() => notifyListener.connect();

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
    super.dispose();
  }
}

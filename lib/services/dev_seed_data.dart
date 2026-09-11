import 'package:flutter/foundation.dart';

import '../app_state.dart';
import '../models/notify_event.dart';

/// Debug-only sample data for exercising the UI without a real Pi.
/// Never referenced from a release build path -- every call site is
/// gated on kDebugMode (see settings_screen.dart). Seeds:
///  - a few local care events (real rows in the same queue a genuine
///    "Log feed" tap writes to -- these DO attempt to sync to a real
///    Pi if one is configured and reachable, same as any other queued
///    event; there is nothing Pi-specific to fake here since care
///    events already round-trip through local storage)
///  - a fake active cry session (in-memory only, via the same event
///    handling path a real MQTT message takes) -- cry_history and
///    device_events are Pi-owned/read-only per PI_CONTRACT.md, so
///    there's no meaningful local seed for those; a real Pi is needed
///    to see actual history.
class DevSeedData {
  static Future<void> seed(AppState appState) async {
    assert(kDebugMode, 'DevSeedData must only be called from debug builds');

    final now = DateTime.now();
    final deviceId = appState.settings.deviceId;

    await appState.localEventQueue.enqueue(
      eventType: 'feed',
      timestamp: now.subtract(const Duration(hours: 3, minutes: 10)),
      deviceId: deviceId,
      note: 'seed data',
    );
    await appState.localEventQueue.enqueue(
      eventType: 'change',
      timestamp: now.subtract(const Duration(hours: 1, minutes: 45)),
      deviceId: deviceId,
      note: 'seed data',
    );
    await appState.localEventQueue.enqueue(
      eventType: 'feed',
      timestamp: now.subtract(const Duration(minutes: 20)),
      deviceId: deviceId,
      note: 'seed data',
    );

    appState.simulateNotifyEvent(NotifyEvent(
      kind: NotifyEventKind.cryStarted,
      timestamp: now.subtract(const Duration(minutes: 5)),
      stage1Confidence: 0.94,
      stage2Probs: const {'hungry': 0.55, 'fussy': 0.3, 'tired': 0.15},
      context: const CryContext(
        secondsSinceFeed: 1200,
        secondsSinceChange: 6300,
      ),
    ));
  }

  /// Clears everything seed() created -- local queue rows and the
  /// in-memory active session. Does not touch anything on a real Pi.
  static Future<void> clear(AppState appState) async {
    assert(kDebugMode, 'DevSeedData must only be called from debug builds');
    final rows = await appState.localEventQueue.getAll();
    for (final row in rows) {
      if (row.note == 'seed data' && row.localId != null) {
        await appState.localEventQueue.deleteLocal(row.localId!);
      }
    }
    appState.clearActiveSession();
  }
}

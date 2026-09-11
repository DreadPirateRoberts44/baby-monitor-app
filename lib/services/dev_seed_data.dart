import 'dart:math';

import 'package:flutter/foundation.dart';

import '../app_state.dart';
import '../models/notify_event.dart';

/// Debug-only sample data for exercising the UI without a real Pi.
/// Never referenced from a release build path -- every call site is
/// gated on kDebugMode (see settings_screen.dart). Seeds:
///  - ~1 month of local feed/change events (real rows in the same
///    queue a genuine "Log feed" tap writes to -- these DO attempt to
///    sync to a real Pi if one is configured and reachable, same as
///    any other queued event). This is enough data to test the History
///    and Care log tabs' scrolling/merging behavior, not just their
///    empty states.
///  - a fake active cry session (in-memory only, via the same event
///    handling path a real MQTT message takes) -- cry_history and
///    device_events are Pi-owned/read-only per PI_CONTRACT.md, so
///    there's no meaningful local seed for those; a real Pi is needed
///    to see actual cry history. See history_screen.dart's comments for
///    why feed/change events, unlike cry data, DO show up locally.
class DevSeedData {
  static const _seedNote = 'seed data';
  static const _seedDays = 30;

  static Future<void> seed(AppState appState) async {
    assert(kDebugMode, 'DevSeedData must only be called from debug builds');

    final now = DateTime.now();
    final deviceId = appState.settings.deviceId;
    final random = Random(42); // fixed seed: reproducible sample data

    // Roughly every 2.5-3.5h for feeds, 3-4.5h for changes, both jittered,
    // going back ~30 days -- enough to see realistic list length/scroll
    // behavior in History and Care log without it being unbounded.
    var feedTime = now.subtract(const Duration(days: _seedDays));
    while (feedTime.isBefore(now)) {
      final jitterMinutes = random.nextInt(60) - 30;
      await appState.localEventQueue.enqueue(
        eventType: 'feed',
        timestamp: feedTime.add(Duration(minutes: jitterMinutes)),
        deviceId: deviceId,
        note: _seedNote,
      );
      feedTime = feedTime.add(Duration(
        hours: 2,
        minutes: 30 + random.nextInt(60),
      ));
    }

    var changeTime = now
        .subtract(const Duration(days: _seedDays))
        .add(const Duration(hours: 1));
    while (changeTime.isBefore(now)) {
      final jitterMinutes = random.nextInt(60) - 30;
      await appState.localEventQueue.enqueue(
        eventType: 'change',
        timestamp: changeTime.add(Duration(minutes: jitterMinutes)),
        deviceId: deviceId,
        note: _seedNote,
      );
      changeTime = changeTime.add(Duration(
        hours: 3,
        minutes: random.nextInt(90),
      ));
    }

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
      if (row.note == _seedNote && row.localId != null) {
        await appState.localEventQueue.deleteLocal(row.localId!);
      }
    }
    appState.clearActiveSession();
  }
}

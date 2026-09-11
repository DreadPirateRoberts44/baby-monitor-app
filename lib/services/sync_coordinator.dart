import 'dart:async';

import 'local_event_queue.dart';
import 'sync_api_client.dart';

/// Drains the local pending-events queue to the Pi whenever it's
/// reachable. Deliberately opportunistic, not scheduled -- there's no
/// way to know the phone is back on the Pi's WiFi except by trying (see
/// PI_CONTRACT.md: LAN-only, no discovery beyond "same network"), so
/// this runs on app foreground and after any manual pull-to-refresh,
/// rather than polling on a timer.
class SyncCoordinator {
  final LocalEventQueue queue;
  final SyncApiClient client;

  bool _syncing = false;

  SyncCoordinator({required this.queue, required this.client});

  /// Pushes every unsynced local event to the Pi, in the order they were
  /// logged. Stops at the first failure (almost always "not on the Pi's
  /// WiFi right now") rather than reordering -- a later success without
  /// an earlier one would desync the app's view from the Pi's, and the
  /// next sync attempt just resumes from the same point.
  ///
  /// Returns the number of events successfully synced.
  Future<int> sync() async {
    if (_syncing) return 0;
    _syncing = true;
    var count = 0;
    try {
      final pending = await queue.getUnsynced();
      for (final event in pending) {
        if (event.localId == null) continue;
        try {
          // Both "created" and the Pi's dedup "skipped_duplicate" are
          // success outcomes here -- see PI_CONTRACT.md's "Duplicate
          // handling". Either way this device's copy is now redundant.
          await client.postCareEvent(event);
          await queue.markSynced(event.localId!);
          count++;
        } on SyncApiException {
          rethrow;
        } catch (_) {
          // Network failure -- expected when off the home WiFi. Stop
          // here; don't mark anything synced out of order.
          break;
        }
      }
      if (count > 0) {
        await queue.pruneSynced();
      }
    } finally {
      _syncing = false;
    }
    return count;
  }
}

import 'package:flutter/foundation.dart';

import '../../app_state.dart';
import '../../models/care_event.dart';

/// Snapshot of everything History's cards are built from: the Pi's
/// confirmed cry sessions + device events, merged with any still-local
/// care events the same way history/raw_log_screen.dart does. Pulled
/// into one place so each card fetches consistently instead of
/// reimplementing the remote-unreachable-falls-back-to-local-only dance
/// (see PI_CONTRACT.md) per screen.
@immutable
class HistorySnapshot {
  final List<CrySession> sessions;
  final List<DeviceEvent> deviceEvents;
  final List<CareEvent> careEvents;
  final bool unreachable;

  const HistorySnapshot({
    required this.sessions,
    required this.deviceEvents,
    required this.careEvents,
    required this.unreachable,
  });

  bool get isEmpty =>
      sessions.isEmpty && deviceEvents.isEmpty && careEvents.isEmpty;
}

/// Default lookback when a caller doesn't need a specific window (e.g.
/// the hub's today-only summary) -- bounds the request instead of
/// pulling a Pi's entire lifetime history on every load. Screens with
/// their own longer filter (see frequency_screen.dart's up-to-12-months
/// picker) pass a wider [since] that covers what their filter can
/// select, rather than relying on this default.
const defaultHistoryLookback = Duration(days: 90);

/// Fetches sessions/device events/care events since [since] (or the
/// last [defaultHistoryLookback] if omitted) and merges in any
/// still-local care events. A bounded window rather than a persistent
/// local cache is deliberate -- the Pi is the sole source of truth for
/// this data (see PI_CONTRACT.md) with no delete/edit tombstones, so a
/// cache could go stale (especially across multiple caregivers' phones)
/// in a way a fresh bounded fetch never can.
Future<HistorySnapshot> loadHistorySnapshot(
  AppState appState, {
  DateTime? since,
}) async {
  final effectiveSince =
      since ?? DateTime.now().subtract(defaultHistoryLookback);

  List<CrySession> sessions = [];
  List<DeviceEvent> deviceEvents = [];
  List<CareEvent> remoteCareEvents = [];
  var unreachable = false;
  try {
    sessions = await appState.syncApiClient.getCryHistory(since: effectiveSince);
    deviceEvents =
        await appState.syncApiClient.getDeviceEvents(since: effectiveSince);
    remoteCareEvents =
        await appState.syncApiClient.getCareEvents(since: effectiveSince);
  } catch (_) {
    // Expected off the home WiFi -- see PI_CONTRACT.md.
    unreachable = true;
  }

  final localCareEvents = await appState.localEventQueue.getAll();
  final careEvents = [
    ...remoteCareEvents,
    ...localCareEvents.where((e) => !e.synced),
  ];

  return HistorySnapshot(
    sessions: sessions,
    deviceEvents: deviceEvents,
    careEvents: careEvents,
    unreachable: unreachable,
  );
}

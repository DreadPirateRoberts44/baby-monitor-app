import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/care_event.dart';

/// A single row in the merged history timeline: a completed cry
/// session, a device startup/shutdown marker, or a feed/change event.
/// Cry sessions and device events are Pi-owned/read-only (see
/// PI_CONTRACT.md) and only ever come from the Pi's history endpoints
/// -- there is no local/offline view of those, and there shouldn't be
/// (the app never originates that data). Feed/change events are
/// different: they already live locally first (see
/// services/local_event_queue.dart) specifically so logging one works
/// with no network at all, so this screen shows them the same way
/// care_events_screen.dart does -- merged with whatever the Pi has
/// confirmed, so History still has something to show (and something to
/// test against) with no Pi reachable at all.
sealed class _TimelineEntry {
  DateTime get sortKey;
}

class _SessionEntry extends _TimelineEntry {
  final CrySession session;
  _SessionEntry(this.session);
  @override
  DateTime get sortKey => session.startedAt;
}

class _DeviceEntry extends _TimelineEntry {
  final DeviceEvent event;
  _DeviceEntry(this.event);
  @override
  DateTime get sortKey => event.timestamp;
}

class _CareEventEntry extends _TimelineEntry {
  final CareEvent event;
  _CareEventEntry(this.event);
  @override
  DateTime get sortKey => event.timestamp;
}

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<_TimelineEntry>? _timeline;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final appState = context.read<AppState>();

    List<CrySession> sessions = [];
    List<DeviceEvent> deviceEvents = [];
    List<CareEvent> remoteCareEvents = [];
    var unreachable = false;
    try {
      sessions = await appState.syncApiClient.getCryHistory();
      deviceEvents = await appState.syncApiClient.getDeviceEvents();
      remoteCareEvents = await appState.syncApiClient.getCareEvents();
    } catch (_) {
      // Expected off the home WiFi — see PI_CONTRACT.md. Cry sessions and
      // device events simply won't be available; local care events
      // (below) still show so the tab isn't empty just because the Pi
      // is unreachable.
      unreachable = true;
    }

    final localCareEvents = await appState.localEventQueue.getAll();

    final careEvents = [
      ...remoteCareEvents,
      ...localCareEvents.where((e) => !e.synced),
    ];

    final timeline = <_TimelineEntry>[
      ...sessions.map(_SessionEntry.new),
      ...deviceEvents.map(_DeviceEntry.new),
      ...careEvents.map(_CareEventEntry.new),
    ]..sort((a, b) => b.sortKey.compareTo(a.sortKey));

    if (mounted) {
      setState(() {
        _timeline = timeline;
        _error = timeline.isEmpty && unreachable
            ? 'Could not reach the monitor.'
            : null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Center(child: Text(_error!));
    if (_timeline == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_timeline!.isEmpty) {
      return const Center(child: Text('No history recorded yet.'));
    }

    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.builder(
        itemCount: _timeline!.length,
        itemBuilder: (context, i) {
          final entry = _timeline![i];
          return switch (entry) {
            _SessionEntry(session: final s) => ListTile(
                leading: const Icon(Icons.hearing),
                title: Text(
                    '${s.topReason[0].toUpperCase()}${s.topReason.substring(1)} · ${s.durationSeconds.toStringAsFixed(0)}s'),
                subtitle: Text(
                    DateFormat.yMMMd().add_jm().format(s.startedAt.toLocal())),
                onTap: () => _showDetail(s),
              ),
            _DeviceEntry(event: final e) => ListTile(
                dense: true,
                leading: Icon(
                  e.eventType == 'startup'
                      ? Icons.power_settings_new
                      : Icons.power_off,
                  size: 20,
                  color: Theme.of(context).colorScheme.outline,
                ),
                title: Text(
                  e.eventType == 'startup'
                      ? 'Monitor started'
                      : 'Monitor stopped',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.outline),
                ),
                subtitle: Text(
                  DateFormat.yMMMd().add_jm().format(e.timestamp.toLocal()) +
                      (e.reason != null ? ' · ${e.reason}' : ''),
                ),
              ),
            _CareEventEntry(event: final e) => ListTile(
                leading: Icon(e.eventType == 'feed'
                    ? Icons.restaurant
                    : Icons.child_friendly),
                title: Row(
                  children: [
                    Text(e.eventType == 'feed' ? 'Fed' : 'Changed'),
                    if (!e.synced) ...[
                      const SizedBox(width: 8),
                      Tooltip(
                        message: 'Not yet synced to the monitor.',
                        child: Icon(Icons.cloud_off,
                            size: 16,
                            color: Theme.of(context).colorScheme.outline),
                      ),
                    ],
                  ],
                ),
                subtitle: Text(
                    '${DateFormat.yMMMd().add_jm().format(e.timestamp.toLocal())} · ${e.source}'),
              ),
          };
        },
      ),
    );
  }

  void _showDetail(CrySession s) {
    final sorted = s.reasonProbs.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    showModalBottomSheet(
      context: context,
      builder: (_) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Session detail',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            Text(
                'Started: ${DateFormat.yMMMd().add_jm().format(s.startedAt.toLocal())}'),
            Text('Ended: ${DateFormat.yMMMd().add_jm().format(s.endedAt.toLocal())}'),
            Text('Duration: ${s.durationSeconds.toStringAsFixed(0)}s'),
            const SizedBox(height: 12),
            Text('Reason breakdown:',
                style: Theme.of(context).textTheme.titleMedium),
            for (final e in sorted)
              Text('${e.key}: ${(e.value * 100).toStringAsFixed(0)}%'),
          ],
        ),
      ),
    );
  }
}

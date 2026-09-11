import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/care_event.dart';

/// A single row in the merged history timeline -- either a completed
/// cry session or a device startup/shutdown marker. Merging these (both
/// sorted by time) is what lets device events actually do their job:
/// PI_CONTRACT.md notes they exist so a long gap between cry sessions
/// reads as "the monitor was off" rather than "the baby just didn't cry
/// for a suspiciously long time" -- that only works if they're visible
/// in the same timeline, not fetched and silently discarded.
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
    final client = context.read<AppState>().syncApiClient;
    try {
      final sessions = await client.getCryHistory();
      final deviceEvents = await client.getDeviceEvents();
      final timeline = <_TimelineEntry>[
        ...sessions.map(_SessionEntry.new),
        ...deviceEvents.map(_DeviceEntry.new),
      ]..sort((a, b) => b.sortKey.compareTo(a.sortKey));
      if (mounted) {
        setState(() {
          _timeline = timeline;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not reach the monitor.');
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

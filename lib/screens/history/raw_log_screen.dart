import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart' show Share, XFile;

import '../../app_state.dart';
import '../../models/care_event.dart';
import 'history_data.dart';

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

class RawLogScreen extends StatefulWidget {
  const RawLogScreen({super.key});

  @override
  State<RawLogScreen> createState() => _RawLogScreenState();
}

/// How far back Raw log asks the Pi for -- kept caregiver-adjustable
/// rather than always pulling everything, since a Pi running for months
/// could otherwise mean refetching a large, ever-growing history on
/// every pull-to-refresh. null means "all time" (a far-past bound, since
/// the sync API only supports a since= lower bound, not "no filter").
enum _LookbackWindow {
  sevenDays(Duration(days: 7), '7 days'),
  thirtyDays(Duration(days: 30), '30 days'),
  ninetyDays(Duration(days: 90), '90 days'),
  oneYear(Duration(days: 365), '1 year'),
  allTime(null, 'All time');

  final Duration? duration;
  final String label;
  const _LookbackWindow(this.duration, this.label);
}

class _RawLogScreenState extends State<RawLogScreen> {
  List<_TimelineEntry>? _timeline;
  String? _error;
  bool _exporting = false;
  _LookbackWindow _window = _LookbackWindow.ninetyDays;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  DateTime get _since {
    final duration = _window.duration;
    // Pi/sync_api.py has been around only since this project started, so
    // any date well before that is effectively "no lower bound" without
    // needing since= itself to be optional server-side.
    return duration == null
        ? DateTime(2024)
        : DateTime.now().subtract(duration);
  }

  Future<void> _refresh() async {
    final appState = context.read<AppState>();
    final snapshot = await loadHistorySnapshot(appState, since: _since);

    final timeline = <_TimelineEntry>[
      ...snapshot.sessions.map(_SessionEntry.new),
      ...snapshot.deviceEvents.map(_DeviceEntry.new),
      ...snapshot.careEvents.map(_CareEventEntry.new),
    ]..sort((a, b) => b.sortKey.compareTo(a.sortKey));

    if (mounted) {
      setState(() {
        _timeline = timeline;
        _error = timeline.isEmpty && snapshot.unreachable
            ? 'Could not reach the monitor.'
            : null;
      });
    }
  }

  void _changeWindow(_LookbackWindow window) {
    setState(() {
      _window = window;
      _timeline = null;
    });
    _refresh();
  }

  String _csvField(String value) {
    if (value.contains(',') || value.contains('"') || value.contains('\n')) {
      return '"${value.replaceAll('"', '""')}"';
    }
    return value;
  }

  String _buildCsv(List<_TimelineEntry> timeline) {
    final rows = <String>[
      'timestamp,type,summary,detail',
    ];
    for (final entry in timeline) {
      final (type, summary, detail) = switch (entry) {
        _SessionEntry(session: final s) => (
            'cry_session',
            s.topReason,
            'duration=${s.durationSeconds.toStringAsFixed(0)}s;'
                'confirmed_cry=${s.confirmedCrySeconds.toStringAsFixed(0)}s;'
                'density=${(s.cryDensity * 100).toStringAsFixed(0)}%;'
                'ended_at=${entry.session.endedAt.toIso8601String()}',
          ),
        _DeviceEntry(event: final e) => (
            'device_event',
            e.eventType,
            e.reason ?? '',
          ),
        _CareEventEntry(event: final e) => (
            'care_event',
            e.eventType,
            'source=${e.source};synced=${e.synced}',
          ),
      };
      final ts = entry.sortKey.toLocal().toIso8601String();
      rows.add([
        _csvField(ts),
        _csvField(type),
        _csvField(summary),
        _csvField(detail),
      ].join(','));
    }
    return rows.join('\n');
  }

  Future<void> _exportCsv() async {
    final timeline = _timeline;
    if (timeline == null || timeline.isEmpty) return;

    setState(() => _exporting = true);
    try {
      final csv = _buildCsv(timeline);
      final dir = await getTemporaryDirectory();
      final stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final file = File('${dir.path}/history_$stamp.csv');
      await file.writeAsString(csv);

      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'text/csv')],
        subject: 'Baby Monitor history export',
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not export CSV.')),
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Raw log'),
        actions: [
          PopupMenuButton<_LookbackWindow>(
            tooltip: 'How far back to load',
            initialValue: _window,
            onSelected: _changeWindow,
            itemBuilder: (context) => [
              for (final w in _LookbackWindow.values)
                PopupMenuItem(value: w, child: Text(w.label)),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_window.label),
                  const Icon(Icons.arrow_drop_down),
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: 'Export to CSV',
            icon: _exporting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.ios_share),
            onPressed: (_timeline == null || _timeline!.isEmpty || _exporting)
                ? null
                : _exportCsv,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
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
                trailing: const Icon(Icons.chevron_right),
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
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _showCareEventDetail(e),
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
            Text('Confirmed crying: ${s.confirmedCrySeconds.toStringAsFixed(0)}s '
                '(${(s.cryDensity * 100).toStringAsFixed(0)}% of session)'),
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

  void _showCareEventDetail(CareEvent e) {
    showModalBottomSheet(
      context: context,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(e.eventType == 'feed' ? 'Feed detail' : 'Change detail',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            Text(
                'When: ${DateFormat.yMMMd().add_jm().format(e.timestamp.toLocal())}'),
            Text('Logged via: ${e.source == 'button' ? 'Monitor button' : 'App'}'),
            Text(e.synced ? 'Synced to monitor' : 'Not yet synced to monitor'),
            if (e.note != null && e.note!.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('Note:', style: Theme.of(context).textTheme.titleMedium),
              Text(e.note!),
            ],
            if (e.id != null) ...[
              const SizedBox(height: 20),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                icon: const Icon(Icons.delete_outline),
                label: const Text('Delete this entry'),
                onPressed: () {
                  Navigator.of(sheetContext).pop();
                  _confirmDeleteCareEvent(e);
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDeleteCareEvent(CareEvent e) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this entry?'),
        content: Text(
          'This permanently removes this ${e.eventType == 'feed' ? 'feed' : 'change'} '
          'log from the monitor. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await context.read<AppState>().syncApiClient.deleteCareEvent(e.id!);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Entry deleted.')),
        );
      }
      await _refresh();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Could not delete — check the connection.')),
        );
      }
    }
  }
}

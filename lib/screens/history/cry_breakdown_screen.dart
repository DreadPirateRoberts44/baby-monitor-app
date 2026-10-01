import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../models/care_event.dart';
import 'history_data.dart';

/// Crying-specific breakdown: most common reason, average session
/// length, and how much of that time was confirmed crying (vs. quiet
/// gaps the Pi's merge window absorbed -- see CrySession.cryDensity),
/// restricted to sessions that started within a caregiver-chosen
/// clock-time window (e.g. "nights only", 8pm-8am) rather than a date
/// range, since the point is comparing times of day, not periods of
/// history.
class CryBreakdownScreen extends StatefulWidget {
  const CryBreakdownScreen({super.key});

  @override
  State<CryBreakdownScreen> createState() => _CryBreakdownScreenState();
}

/// Days to look back for -- this card has no date-range filter of its
/// own (its filter is clock-time-of-day, see _inRange), so without a
/// bound it would otherwise ask the Pi for a lifetime of cry sessions
/// on every load. Kept adjustable, same idea as raw_log_screen.dart's
/// window picker, since "most common reason" is meant to reflect recent
/// patterns, not necessarily the Pi's entire history.
enum _LookbackDays {
  sevenDays(7, 'Last 7 days'),
  thirtyDays(30, 'Last 30 days'),
  ninetyDays(90, 'Last 90 days'),
  oneYear(365, 'Last year');

  final int days;
  final String label;
  const _LookbackDays(this.days, this.label);
}

class _CryBreakdownScreenState extends State<CryBreakdownScreen> {
  HistorySnapshot? _snapshot;
  String? _error;

  TimeOfDay _rangeStart = const TimeOfDay(hour: 0, minute: 0);
  TimeOfDay _rangeEnd = const TimeOfDay(hour: 23, minute: 59);
  _LookbackDays _lookback = _LookbackDays.ninetyDays;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final appState = context.read<AppState>();
    final since = DateTime.now().subtract(Duration(days: _lookback.days));
    final snapshot = await loadHistorySnapshot(appState, since: since);
    if (mounted) {
      setState(() {
        _snapshot = snapshot;
        _error = snapshot.isEmpty && snapshot.unreachable
            ? 'Could not reach the monitor.'
            : null;
      });
    }
  }

  void _changeLookback(_LookbackDays lookback) {
    setState(() {
      _lookback = lookback;
      _snapshot = null;
    });
    _refresh();
  }

  bool _inRange(DateTime localStart) {
    final minutes = localStart.hour * 60 + localStart.minute;
    final startMin = _rangeStart.hour * 60 + _rangeStart.minute;
    final endMin = _rangeEnd.hour * 60 + _rangeEnd.minute;
    if (startMin <= endMin) {
      return minutes >= startMin && minutes <= endMin;
    }
    // Wraps past midnight, e.g. 20:00-08:00.
    return minutes >= startMin || minutes <= endMin;
  }

  Future<void> _pickTime(bool isStart) async {
    final initial = isStart ? _rangeStart : _rangeEnd;
    final picked = await showTimePicker(context: context, initialTime: initial);
    if (picked == null) return;
    setState(() {
      if (isStart) {
        _rangeStart = picked;
      } else {
        _rangeEnd = picked;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Crying breakdown')),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_error != null) return Center(child: Text(_error!));
    final snapshot = _snapshot;
    if (snapshot == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (snapshot.isEmpty) {
      return const Center(child: Text('No history recorded yet.'));
    }

    final sessions = snapshot.sessions
        .where((s) => _inRange(s.startedAt.toLocal()))
        .toList();

    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildFilterRow(),
          const SizedBox(height: 24),
          if (sessions.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 48),
              child: Center(child: Text('No cry sessions in this range.')),
            )
          else
            _buildStats(sessions),
        ],
      ),
    );
  }

  Widget _buildFilterRow() {
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      runSpacing: 8,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Between'),
            const SizedBox(width: 12),
            TextButton(
              onPressed: () => _pickTime(true),
              child: Text(_rangeStart.format(context)),
            ),
            const Text('and'),
            TextButton(
              onPressed: () => _pickTime(false),
              child: Text(_rangeEnd.format(context)),
            ),
          ],
        ),
        DropdownButton<_LookbackDays>(
          value: _lookback,
          items: [
            for (final l in _LookbackDays.values)
              DropdownMenuItem(value: l, child: Text(l.label)),
          ],
          onChanged: (v) {
            if (v != null) _changeLookback(v);
          },
        ),
      ],
    );
  }

  Widget _buildStats(List<CrySession> sessions) {
    final reasonCounts = <String, int>{};
    for (final s in sessions) {
      reasonCounts[s.topReason] = (reasonCounts[s.topReason] ?? 0) + 1;
    }
    final topReason =
        (reasonCounts.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
            .first;

    final avgDuration =
        sessions.map((s) => s.durationSeconds).reduce((a, b) => a + b) /
            sessions.length;
    final avgConfirmed = sessions
            .map((s) => s.confirmedCrySeconds)
            .reduce((a, b) => a + b) /
        sessions.length;
    final avgDensity = sessions.map((s) => s.cryDensity).reduce((a, b) => a + b) /
        sessions.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${sessions.length} cry session${sessions.length == 1 ? '' : 's'} '
            'in this window'),
        const SizedBox(height: 16),
        _StatCard(
          icon: Icons.psychology,
          label: 'Most common reason',
          value:
              '${topReason.key[0].toUpperCase()}${topReason.key.substring(1)}',
          detail:
              '${topReason.value} of ${sessions.length} session${sessions.length == 1 ? '' : 's'}',
        ),
        const SizedBox(height: 12),
        _StatCard(
          icon: Icons.timer,
          label: 'Average cry session length',
          value: _formatDuration(avgDuration),
          detail: 'Confirmed crying: ${_formatDuration(avgConfirmed)}',
        ),
        const SizedBox(height: 12),
        _StatCard(
          icon: Icons.percent,
          label: 'Time spent actually crying',
          value: '${(avgDensity * 100).toStringAsFixed(0)}%',
          detail: 'of the average session duration',
        ),
        const SizedBox(height: 16),
        Text('Reason breakdown', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        for (final e in reasonCounts.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value)))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                SizedBox(
                  width: 80,
                  child: Text('${e.key[0].toUpperCase()}${e.key.substring(1)}'),
                ),
                Expanded(
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: e.value / sessions.length,
                    child: Container(
                      height: 10,
                      decoration: BoxDecoration(
                        color: Colors.redAccent,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text('${e.value}'),
              ],
            ),
          ),
      ],
    );
  }

  String _formatDuration(double seconds) {
    final d = Duration(seconds: seconds.round());
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    if (m == 0) return '${s}s';
    return '${m}m ${s}s';
  }
}

class _StatCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final String detail;

  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.detail,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(icon, size: 32, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: Theme.of(context).textTheme.bodySmall),
                  Text(value, style: Theme.of(context).textTheme.headlineSmall),
                  Text(detail, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

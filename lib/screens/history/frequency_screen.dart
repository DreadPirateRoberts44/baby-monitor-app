import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import 'history_data.dart';

enum _RangeUnit { weeks, months }

/// Counts of cry/feed/change events bucketed into caregiver-configurable
/// blocks of the day (1/2/3 hours wide, starting at a chosen hour), so a
/// caregiver can see e.g. "most cries happen 6-9pm" at a glance,
/// filtered to a recent window they control (last N weeks/months) since
/// the full history could span months and dilute a recent pattern
/// shift.
class FrequencyScreen extends StatefulWidget {
  const FrequencyScreen({super.key});

  @override
  State<FrequencyScreen> createState() => _FrequencyScreenState();
}

class _FrequencyScreenState extends State<FrequencyScreen> {
  HistorySnapshot? _snapshot;
  String? _error;

  _RangeUnit _unit = _RangeUnit.weeks;
  int _count = 4;

  int _bucketHours = 3;
  int _startHour = 0;

  int get _bucketCount => 24 ~/ _bucketHours;

  /// Index of the bucket containing 24-hour clock hour [hour], relative
  /// to [_startHour] -- e.g. with startHour=6, bucketHours=3, hour=7
  /// falls in bucket 0 (6-9am), not the 2 you'd get ignoring the offset.
  int _bucketOf(int hour) => (((hour - _startHour) % 24 + 24) % 24) ~/ _bucketHours;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final appState = context.read<AppState>();
    // Fetch exactly the window the "last N weeks/months" filter can show
    // -- avoids both pulling a Pi's whole lifetime history and silently
    // truncating data the filter is supposed to cover.
    final snapshot = await loadHistorySnapshot(appState, since: _cutoff);
    if (mounted) {
      setState(() {
        _snapshot = snapshot;
        _error = snapshot.isEmpty && snapshot.unreachable
            ? 'Could not reach the monitor.'
            : null;
      });
    }
  }

  DateTime get _cutoff {
    final now = DateTime.now();
    return switch (_unit) {
      _RangeUnit.weeks => now.subtract(Duration(days: 7 * _count)),
      _RangeUnit.months => DateTime(now.year, now.month - _count, now.day,
          now.hour, now.minute),
    };
  }

  void _changeRange({_RangeUnit? unit, int? count}) {
    setState(() {
      if (unit != null) _unit = unit;
      if (count != null) _count = count;
      _snapshot = null;
    });
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Frequency by hour')),
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

    final cutoff = _cutoff;
    final cryCounts = List.filled(_bucketCount, 0);
    final feedCounts = List.filled(_bucketCount, 0);
    final changeCounts = List.filled(_bucketCount, 0);

    for (final s in snapshot.sessions) {
      final local = s.startedAt.toLocal();
      if (local.isBefore(cutoff)) continue;
      cryCounts[_bucketOf(local.hour)]++;
    }
    for (final e in snapshot.careEvents) {
      final local = e.timestamp.toLocal();
      if (local.isBefore(cutoff)) continue;
      final bucket = _bucketOf(local.hour);
      if (e.eventType == 'feed') {
        feedCounts[bucket]++;
      } else if (e.eventType == 'change') {
        changeCounts[bucket]++;
      }
    }

    final maxCount = [
      ...cryCounts,
      ...feedCounts,
      ...changeCounts,
    ].fold(0, (a, b) => a > b ? a : b);

    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildFilterRow(),
          const SizedBox(height: 24),
          if (maxCount == 0)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 48),
              child: Center(child: Text('No events in this range.')),
            )
          else ...[
            const _Legend(),
            const SizedBox(height: 16),
            for (var b = 0; b < _bucketCount; b++)
              _BucketRow(
                label: _bucketLabel(b),
                cryCount: cryCounts[b],
                feedCount: feedCounts[b],
                changeCount: changeCounts[b],
                maxCount: maxCount,
              ),
          ],
        ],
      ),
    );
  }

  String _bucketLabel(int bucket) {
    final startHour = (_startHour + bucket * _bucketHours) % 24;
    final endHour = startHour + _bucketHours;
    String fmt(int h) {
      final wrapped = h % 24;
      final period = wrapped < 12 || wrapped == 24 ? 'am' : 'pm';
      var h12 = wrapped % 12;
      if (h12 == 0) h12 = 12;
      return '$h12$period';
    }

    return '${fmt(startHour)}–${fmt(endHour)}';
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
            const Text('Last'),
            const SizedBox(width: 12),
            DropdownButton<int>(
              value: _count,
              items: [
                for (final n in [1, 2, 3, 4, 6, 8, 12])
                  DropdownMenuItem(value: n, child: Text('$n'))
              ],
              onChanged: (v) {
                if (v != null) _changeRange(count: v);
              },
            ),
            const SizedBox(width: 12),
            DropdownButton<_RangeUnit>(
              value: _unit,
              items: const [
                DropdownMenuItem(
                    value: _RangeUnit.weeks, child: Text('weeks')),
                DropdownMenuItem(
                    value: _RangeUnit.months, child: Text('months')),
              ],
              onChanged: (v) {
                if (v != null) _changeRange(unit: v);
              },
            ),
          ],
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Bucket'),
            const SizedBox(width: 12),
            DropdownButton<int>(
              value: _bucketHours,
              items: const [
                DropdownMenuItem(value: 1, child: Text('1 hr')),
                DropdownMenuItem(value: 2, child: Text('2 hrs')),
                DropdownMenuItem(value: 3, child: Text('3 hrs')),
              ],
              onChanged: (v) {
                if (v != null) setState(() => _bucketHours = v);
              },
            ),
            const SizedBox(width: 12),
            const Text('from'),
            const SizedBox(width: 12),
            DropdownButton<int>(
              value: _startHour,
              items: [
                for (var h = 0; h < 24; h++)
                  DropdownMenuItem(value: h, child: Text(_hourLabel(h)))
              ],
              onChanged: (v) {
                if (v != null) setState(() => _startHour = v);
              },
            ),
          ],
        ),
      ],
    );
  }

  String _hourLabel(int h) {
    final period = h < 12 ? 'am' : 'pm';
    var h12 = h % 12;
    if (h12 == 0) h12 = 12;
    return '$h12$period';
  }
}

class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) {
    return const Wrap(
      spacing: 16,
      children: [
        _LegendItem(color: Colors.redAccent, label: 'Cried'),
        _LegendItem(color: Colors.teal, label: 'Fed'),
        _LegendItem(color: Colors.amber, label: 'Changed'),
      ],
    );
  }
}

class _LegendItem extends StatelessWidget {
  final Color color;
  final String label;
  const _LegendItem({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 12, height: 12, color: color),
        const SizedBox(width: 6),
        Text(label),
      ],
    );
  }
}

class _BucketRow extends StatelessWidget {
  final String label;
  final int cryCount;
  final int feedCount;
  final int changeCount;
  final int maxCount;

  const _BucketRow({
    required this.label,
    required this.cryCount,
    required this.feedCount,
    required this.changeCount,
    required this.maxCount,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 56,
            child: Text(label, style: Theme.of(context).textTheme.bodySmall),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _bar(context, cryCount, Colors.redAccent),
                _bar(context, feedCount, Colors.teal),
                _bar(context, changeCount, Colors.amber),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _bar(BuildContext context, int count, Color color) {
    final fraction = maxCount == 0 ? 0.0 : count / maxCount;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Row(
        children: [
          Expanded(
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: fraction.clamp(0.02, 1.0),
              child: Container(
                height: 10,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
          ),
          if (count > 0) ...[
            const SizedBox(width: 6),
            SizedBox(
              width: 18,
              child: Text('$count',
                  style: Theme.of(context).textTheme.labelSmall),
            ),
          ],
        ],
      ),
    );
  }
}

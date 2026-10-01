import 'package:flutter/material.dart';

import 'history_data.dart';

/// Today-so-far counts (cried / fed / changed), shown as a strip at the
/// top of the History hub. Deliberately just counts -- the cards below
/// are where a caregiver drills into duration/reason/time-of-day detail.
class DailySummary extends StatelessWidget {
  final HistorySnapshot snapshot;

  const DailySummary({super.key, required this.snapshot});

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final startOfDay = DateTime(now.year, now.month, now.day);

    final criedToday = snapshot.sessions
        .where((s) => s.startedAt.toLocal().isAfter(startOfDay))
        .length;
    final fedToday = snapshot.careEvents
        .where((e) =>
            e.eventType == 'feed' && e.timestamp.toLocal().isAfter(startOfDay))
        .length;
    final changedToday = snapshot.careEvents
        .where((e) =>
            e.eventType == 'change' &&
            e.timestamp.toLocal().isAfter(startOfDay))
        .length;

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("Today's Summary",
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _SummaryStat(
                    icon: Icons.hearing, label: 'Cried', count: criedToday),
                _SummaryStat(
                    icon: Icons.restaurant, label: 'Fed', count: fedToday),
                _SummaryStat(
                    icon: Icons.child_friendly,
                    label: 'Changed',
                    count: changedToday),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryStat extends StatelessWidget {
  final IconData icon;
  final String label;
  final int count;

  const _SummaryStat({
    required this.icon,
    required this.label,
    required this.count,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: 4),
        Text('$count', style: Theme.of(context).textTheme.headlineSmall),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

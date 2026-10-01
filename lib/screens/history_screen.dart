import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import 'history/cry_breakdown_screen.dart';
import 'history/daily_summary.dart';
import 'history/frequency_screen.dart';
import 'history/history_data.dart';
import 'history/raw_log_screen.dart';

/// Landing page for the History tab: a today-so-far summary strip, plus
/// a set of circular tool cards, each opening a different way to look
/// at history (raw log, frequency-by-time-of-day, crying breakdown, and
/// future analysis tools). Kept as a simple grid of entry points rather
/// than folding tools into this screen directly, so each tool can own
/// its own state/refresh/detail-view logic the way raw_log_screen.dart
/// does.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  HistorySnapshot? _snapshot;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final appState = context.read<AppState>();
    final snapshot = await loadHistorySnapshot(appState);
    if (mounted) setState(() => _snapshot = snapshot);
  }

  @override
  Widget build(BuildContext context) {
    final tools = <_HistoryTool>[
      _HistoryTool(
        icon: Icons.receipt_long,
        label: 'Raw log',
        builder: (_) => const RawLogScreen(),
      ),
      _HistoryTool(
        icon: Icons.bar_chart,
        label: 'Frequency by hour',
        builder: (_) => const FrequencyScreen(),
      ),
      _HistoryTool(
        icon: Icons.hearing,
        label: 'Crying breakdown',
        builder: (_) => const CryBreakdownScreen(),
      ),
    ];

    final snapshot = _snapshot;

    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (snapshot != null) DailySummary(snapshot: snapshot),
          const SizedBox(height: 24),
          GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 3,
            mainAxisSpacing: 16,
            crossAxisSpacing: 16,
            childAspectRatio: 0.8,
            children: [
              for (final tool in tools) _HistoryToolCard(tool: tool),
            ],
          ),
        ],
      ),
    );
  }
}

class _HistoryTool {
  final IconData icon;
  final String label;
  final WidgetBuilder builder;

  const _HistoryTool({
    required this.icon,
    required this.label,
    required this.builder,
  });
}

class _HistoryToolCard extends StatelessWidget {
  final _HistoryTool tool;
  const _HistoryToolCard({required this.tool});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      customBorder: const CircleBorder(),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: tool.builder),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 36,
            backgroundColor: colorScheme.primaryContainer,
            child: Icon(tool.icon,
                size: 32, color: colorScheme.onPrimaryContainer),
          ),
          const SizedBox(height: 8),
          Text(
            tool.label,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/care_event.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<CrySession>? _sessions;
  List<DeviceEvent>? _deviceEvents;
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
      sessions.sort((a, b) => b.startedAt.compareTo(a.startedAt));
      if (mounted) {
        setState(() {
          _sessions = sessions;
          _deviceEvents = deviceEvents;
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
    if (_sessions == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_sessions!.isEmpty) {
      return const Center(child: Text('No crying sessions recorded yet.'));
    }

    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.builder(
        itemCount: _sessions!.length,
        itemBuilder: (context, i) {
          final s = _sessions![i];
          return ListTile(
            leading: const Icon(Icons.hearing),
            title: Text(
                '${s.topReason[0].toUpperCase()}${s.topReason.substring(1)} · ${s.durationSeconds.toStringAsFixed(0)}s'),
            subtitle: Text(
                DateFormat.yMMMd().add_jm().format(s.startedAt.toLocal())),
            onTap: () => _showDetail(s),
          );
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

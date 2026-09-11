import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/care_event.dart';

class CareEventsScreen extends StatefulWidget {
  const CareEventsScreen({super.key});

  @override
  State<CareEventsScreen> createState() => _CareEventsScreenState();
}

class _CareEventsScreenState extends State<CareEventsScreen> {
  List<CareEvent>? _events;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  /// Merges the Pi's synced history with anything still sitting in the
  /// local queue (not-yet-synced, or synced-but-not-yet-pruned). See
  /// docs/PI_CONTRACT.md and services/local_event_queue.dart -- the app
  /// is the source of truth for an event until the Pi has confirmed it.
  Future<void> _refresh() async {
    final appState = context.read<AppState>();

    // Opportunistic: if we're reachable right now, push anything queued
    // before pulling history, so a just-synced event shows as synced
    // immediately instead of "pending" for one extra refresh.
    final synced = await appState.syncCoordinator.sync();

    List<CareEvent> remote = [];
    var unreachable = false;
    try {
      remote = await appState.syncApiClient.getCareEvents();
    } catch (_) {
      // Expected outcome off the home WiFi — see PI_CONTRACT.md. Local
      // events still show below even when this fails.
      unreachable = true;
    }

    final local = await appState.localEventQueue.getAll();

    final merged = [...remote, ...local.where((e) => !e.synced)]
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));

    if (mounted) {
      setState(() {
        _events = merged;
        _error = merged.isEmpty && unreachable
            ? 'Could not reach the monitor.'
            : null;
      });
      if (synced > 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  'Synced $synced event${synced == 1 ? '' : 's'} to the monitor.')),
        );
      }
    }
  }

  Future<void> _logEvent(String eventType) async {
    final appState = context.read<AppState>();
    // Local-first: this always succeeds instantly, whether or not we're
    // on the Pi's WiFi right now. SyncCoordinator drains it later.
    await appState.localEventQueue.enqueue(
      eventType: eventType,
      timestamp: DateTime.now(),
      deviceId: appState.settings.deviceId,
    );
    await _refresh();
  }

  Future<void> _delete(CareEvent event) async {
    final appState = context.read<AppState>();
    try {
      if (event.localId != null) {
        // Not yet synced -- just drop it locally, the Pi never saw it.
        await appState.localEventQueue.deleteLocal(event.localId!);
      } else if (event.id != null) {
        await appState.syncApiClient.deleteCareEvent(event.id!);
      }
      await _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Delete failed.')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => _logEvent('feed'),
                  icon: const Icon(Icons.restaurant),
                  label: const Text('Log feed'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => _logEvent('change'),
                  icon: const Icon(Icons.child_friendly),
                  label: const Text('Log change'),
                ),
              ),
            ],
          ),
        ),
        Expanded(child: _buildList()),
      ],
    );
  }

  Widget _buildList() {
    if (_events == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_events!.isEmpty) {
      return RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          children: [
            SizedBox(
              height: 300,
              child: Center(
                child: Text(_error ?? 'No feed/change events logged yet.'),
              ),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.builder(
        itemCount: _events!.length,
        itemBuilder: (context, i) {
          final e = _events![i];
          return ListTile(
            leading: Icon(
                e.eventType == 'feed' ? Icons.restaurant : Icons.child_friendly),
            title: Row(
              children: [
                Text(e.eventType == 'feed' ? 'Fed' : 'Changed'),
                if (!e.synced) ...[
                  const SizedBox(width: 8),
                  Tooltip(
                    message: 'Not yet synced to the monitor — will sync '
                        'automatically once back on its WiFi.',
                    child: Icon(Icons.cloud_off,
                        size: 16, color: Theme.of(context).colorScheme.outline),
                  ),
                ],
              ],
            ),
            subtitle: Text(
                '${DateFormat.yMMMd().add_jm().format(e.timestamp.toLocal())} · ${e.source}'),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _delete(e),
            ),
          );
        },
      ),
    );
  }
}

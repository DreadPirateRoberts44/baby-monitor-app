import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/care_event.dart';

/// Quick-log screen for feed/change events — NOT a history browser.
/// Shows only this device's own not-yet-synced local activity from the
/// last day, so a caregiver can see "did I already log that feed a
/// minute ago" without this screen turning into a second, redundant
/// place to review the Pi's full history (that's what the History tab
/// is for — see history_screen.dart, which shows the Pi's confirmed
/// history plus any still-local events). Once an event syncs it drops
/// out of the local queue (see local_event_queue.dart's pruneSynced())
/// and so naturally disappears from here too — no special-casing needed.
class CareEventsScreen extends StatefulWidget {
  const CareEventsScreen({super.key});

  @override
  State<CareEventsScreen> createState() => _CareEventsScreenState();
}

class _CareEventsScreenState extends State<CareEventsScreen> {
  static const _recentWindow = Duration(days: 1);

  List<CareEvent>? _events;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final appState = context.read<AppState>();

    // Opportunistic: push anything queued if we're reachable right now,
    // so a just-synced event drops off this list immediately rather
    // than sticking around until the next refresh.
    final synced = await appState.syncCoordinator.sync();

    final local = await appState.localEventQueue.getUnsynced();
    final cutoff = DateTime.now().subtract(_recentWindow);
    final recent = local.where((e) => e.timestamp.isAfter(cutoff)).toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));

    if (mounted) {
      setState(() => _events = recent);
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
    if (event.localId == null) return;
    final appState = context.read<AppState>();
    await appState.localEventQueue.deleteLocal(event.localId!);
    await _refresh();
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
          children: const [
            SizedBox(
              height: 300,
              child: Center(
                child: Text(
                  'Nothing pending. Logged events sync to the monitor '
                  'automatically — see the History tab for full history.',
                  textAlign: TextAlign.center,
                ),
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
                const SizedBox(width: 8),
                Tooltip(
                  message: 'Not yet synced to the monitor — will sync '
                      'automatically once back on its WiFi.',
                  child: Icon(Icons.cloud_off,
                      size: 16, color: Theme.of(context).colorScheme.outline),
                ),
              ],
            ),
            subtitle: Text(
                DateFormat.yMMMd().add_jm().format(e.timestamp.toLocal())),
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

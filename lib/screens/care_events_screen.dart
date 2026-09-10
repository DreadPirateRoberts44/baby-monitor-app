import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/care_event.dart';
import '../services/sync_api_client.dart';

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

  Future<void> _refresh() async {
    final client = context.read<AppState>().syncApiClient;
    try {
      final events = await client.getCareEvents();
      events.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      if (mounted) setState(() {
        _events = events;
        _error = null;
      });
    } catch (e) {
      // Expected outcome if off the home WiFi — see PI_CONTRACT.md.
      if (mounted) setState(() => _error = 'Could not reach the monitor.');
    }
  }

  Future<void> _logEvent(String eventType) async {
    final appState = context.read<AppState>();
    final event = CareEvent(
      eventType: eventType,
      timestamp: DateTime.now(),
      source: 'app',
      deviceId: appState.settings.deviceId,
    );
    try {
      await appState.syncApiClient.postCareEvent(event);
      await _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text(
                  "Couldn't log — not connected to the monitor's WiFi?")),
        );
      }
    }
  }

  Future<void> _delete(CareEvent event) async {
    if (event.id == null) return;
    final client = context.read<AppState>().syncApiClient;
    try {
      await client.deleteCareEvent(event.id!);
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
    if (_error != null) {
      return Center(child: Text(_error!));
    }
    if (_events == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_events!.isEmpty) {
      return const Center(child: Text('No feed/change events logged yet.'));
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
            title: Text(e.eventType == 'feed' ? 'Fed' : 'Changed'),
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

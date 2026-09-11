import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../services/dev_seed_data.dart';
import '../services/foreground_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _hostController;
  bool? _paused;

  @override
  void initState() {
    super.initState();
    final settings = context.read<AppState>().settings;
    _hostController = TextEditingController(text: settings.host ?? '');
    _loadPauseState();
  }

  Future<void> _loadPauseState() async {
    try {
      final paused = await context.read<AppState>().syncApiClient.getPredictionPaused();
      if (mounted) setState(() => _paused = paused);
    } catch (_) {
      // Not reachable right now — leave the toggle in its unknown state.
    }
  }

  Future<void> _saveHost() async {
    final appState = context.read<AppState>();
    await appState.settings.setHost(_hostController.text.trim());
    await ForegroundServiceController.start();
    await appState.connect();
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Saved. Connecting…')));
    }
  }

  Future<void> _togglePause(bool value) async {
    final appState = context.read<AppState>();
    try {
      await appState.syncApiClient.setPredictionPaused(value);
      setState(() => _paused = value);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't reach the monitor.")),
        );
      }
    }
  }

  Future<void> _confirmReset() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset all history?'),
        content: const Text(
          'This permanently deletes all feed/change logs, cry-session '
          'history, and startup/shutdown logs on the monitor. This cannot '
          'be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete everything'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      final deleted = await context.read<AppState>().syncApiClient.resetAllData();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Reset done: $deleted')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Reset failed — could not reach the monitor.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppState>().settings;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Monitor connection', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        TextField(
          controller: _hostController,
          decoration: const InputDecoration(
            labelText: "Pi's IP address or hostname",
            hintText: 'e.g. 192.168.1.42',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        FilledButton(onPressed: _saveHost, child: const Text('Save & connect')),
        const SizedBox(height: 8),
        Text(
          'MQTT port ${settings.mqttPort}, sync API port ${settings.syncPort}.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const Divider(height: 40),
        Text('Prediction', style: Theme.of(context).textTheme.titleMedium),
        SwitchListTile(
          title: const Text('Pause cry detection'),
          subtitle: const Text(
            'Escape hatch if the monitor is misbehaving (e.g. false alarms). '
            'The microphone keeps running; only alerts stop.',
          ),
          value: _paused ?? false,
          onChanged: _paused == null ? null : _togglePause,
        ),
        const Divider(height: 40),
        Text('Danger zone', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
          onPressed: _confirmReset,
          icon: const Icon(Icons.delete_forever),
          label: const Text('Reset all history'),
        ),
        const Divider(height: 40),
        Text('About', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text('This device ID: ${settings.deviceId}',
            style: Theme.of(context).textTheme.bodySmall),
        if (kDebugMode) ...[
          const Divider(height: 40),
          Text('Developer', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Debug builds only — lets you exercise the UI without a real '
            'monitor. Never present in a release build.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () async {
                    await DevSeedData.seed(context.read<AppState>());
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Sample data seeded.')),
                      );
                    }
                  },
                  child: const Text('Seed sample data'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton(
                  onPressed: () async {
                    await DevSeedData.clear(context.read<AppState>());
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Sample data cleared.')),
                      );
                    }
                  },
                  child: const Text('Clear sample data'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Fake monitor server — serves ~30 days of realistic cry '
            'sessions, startup/shutdown events, and feed/change history '
            'over the real HTTP sync API, so History can be tested '
            'without a real Pi. Temporarily repoints the host/port above; '
            '"Stop" restores them.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Consumer<AppState>(
            builder: (context, appState, _) => FilledButton.tonalIcon(
              onPressed: () async {
                if (appState.isUsingFakePiServer) {
                  await appState.stopFakePiServer();
                  if (context.mounted) {
                    _hostController.text = appState.settings.host ?? '';
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Fake monitor stopped.')),
                    );
                  }
                } else {
                  await appState.startFakePiServer();
                  if (context.mounted) {
                    _hostController.text = appState.settings.host ?? '';
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text(
                              'Fake monitor running — check the History tab.')),
                    );
                  }
                }
              },
              icon: Icon(appState.isUsingFakePiServer
                  ? Icons.stop_circle
                  : Icons.play_circle),
              label: Text(appState.isUsingFakePiServer
                  ? 'Stop fake monitor server'
                  : 'Start fake monitor server'),
            ),
          ),
        ],
      ],
    );
  }
}

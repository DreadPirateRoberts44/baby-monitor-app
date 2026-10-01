import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/detection_settings.dart';
import '../models/notify_event.dart';
import '../services/dev_seed_data.dart';
import '../services/foreground_service.dart';
import '../services/notify_listener.dart';
import '../services/pi_connection_settings.dart';
import '../services/sync_api_client.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

enum _ConnectionTestResult { testing, success, failure }

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _hostController;
  late final TextEditingController _mqttPortController;
  late final TextEditingController _syncPortController;
  late final TextEditingController _thresholdController;
  late final TextEditingController _startWindowsController;
  late final TextEditingController _endWindowsController;
  bool? _paused;
  _ConnectionTestResult? _testResult;
  String? _testMessage;
  bool _detectionSettingsLoaded = false;
  bool _savingDetectionSettings = false;
  String? _detectionSettingsError;

  @override
  void initState() {
    super.initState();
    final settings = context.read<AppState>().settings;
    _hostController = TextEditingController(text: settings.host ?? '');
    _mqttPortController =
        TextEditingController(text: '${settings.mqttPort}');
    _syncPortController =
        TextEditingController(text: '${settings.syncPort}');
    _thresholdController = TextEditingController();
    _startWindowsController = TextEditingController();
    _endWindowsController = TextEditingController();
    _loadPauseState();
    _loadDetectionSettings();
  }

  @override
  void dispose() {
    _hostController.dispose();
    _mqttPortController.dispose();
    _syncPortController.dispose();
    _thresholdController.dispose();
    _startWindowsController.dispose();
    _endWindowsController.dispose();
    super.dispose();
  }

  Future<void> _loadPauseState() async {
    try {
      final paused =
          await context.read<AppState>().syncApiClient.getPredictionPaused();
      if (mounted) setState(() => _paused = paused);
    } catch (_) {
      // Not reachable right now — leave the toggle in its unknown state.
    }
  }

  Future<void> _loadDetectionSettings() async {
    try {
      final settings =
          await context.read<AppState>().syncApiClient.getDetectionSettings();
      if (mounted) _applyDetectionSettings(settings);
    } catch (_) {
      // Not reachable right now — fields stay blank/disabled until a
      // successful load (see _detectionSettingsLoaded).
    }
  }

  void _applyDetectionSettings(DetectionSettings settings) {
    setState(() {
      _thresholdController.text = '${settings.stage1ConfidenceThreshold}';
      _startWindowsController.text = '${settings.sessionStartMinWindows}';
      _endWindowsController.text = '${settings.sessionEndMissedWindows}';
      _detectionSettingsLoaded = true;
      _detectionSettingsError = null;
    });
  }

  Future<void> _saveDetectionSettings() async {
    final threshold = double.tryParse(_thresholdController.text.trim());
    final startWindows = int.tryParse(_startWindowsController.text.trim());
    final endWindows = int.tryParse(_endWindowsController.text.trim());
    if (threshold == null ||
        threshold < 0 ||
        threshold > 1 ||
        startWindows == null ||
        startWindows < 1 ||
        endWindows == null ||
        endWindows < 1) {
      setState(() => _detectionSettingsError =
          'Threshold must be 0-1; window counts must be positive whole numbers.');
      return;
    }

    setState(() {
      _savingDetectionSettings = true;
      _detectionSettingsError = null;
    });
    try {
      final updated =
          await context.read<AppState>().syncApiClient.updateDetectionSettings(
                stage1ConfidenceThreshold: threshold,
                sessionStartMinWindows: startWindows,
                sessionEndMissedWindows: endWindows,
              );
      if (mounted) {
        _applyDetectionSettings(updated);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Detection settings saved.')),
        );
      }
    } on DetectionSettingsException catch (e) {
      if (mounted) setState(() => _detectionSettingsError = e.message);
    } catch (_) {
      if (mounted) {
        setState(() => _detectionSettingsError =
            "Couldn't reach the monitor. Check the connection.");
      }
    } finally {
      if (mounted) setState(() => _savingDetectionSettings = false);
    }
  }

  Future<void> _resetDetectionSettings() async {
    setState(() {
      _savingDetectionSettings = true;
      _detectionSettingsError = null;
    });
    try {
      final defaults =
          await context.read<AppState>().syncApiClient.resetDetectionSettings();
      if (mounted) {
        _applyDetectionSettings(defaults);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Detection settings reset to defaults.')),
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() => _detectionSettingsError =
            "Couldn't reach the monitor. Check the connection.");
      }
    } finally {
      if (mounted) setState(() => _savingDetectionSettings = false);
    }
  }

  Future<void> _saveHost() async {
    final appState = context.read<AppState>();
    final host = _hostController.text.trim();
    if (host.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter an IP address or hostname.')),
      );
      return;
    }

    final mqttPort = int.tryParse(_mqttPortController.text.trim());
    final syncPort = int.tryParse(_syncPortController.text.trim());
    if (mqttPort == null ||
        mqttPort <= 0 ||
        mqttPort > 65535 ||
        syncPort == null ||
        syncPort <= 0 ||
        syncPort > 65535) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Ports must be numbers between 1 and 65535.')),
      );
      return;
    }

    setState(() => _testResult = _ConnectionTestResult.testing);

    await appState.settings.setHost(host);
    await appState.settings.setMqttPort(mqttPort);
    await appState.settings.setSyncPort(syncPort);
    await ForegroundServiceController.start();

    // Subscribe before connecting -- connect() can emit its terminal
    // connected/disconnected status synchronously within its own await
    // chain, so starting the listen afterwards risks missing it and
    // waiting out the full timeout for no reason.
    final statusFuture = appState.notifyListener.statusStream
        .firstWhere(
          (s) =>
              s == ConnectionStatus.connected ||
              s == ConnectionStatus.disconnected,
        )
        .timeout(const Duration(seconds: 8), onTimeout: () => ConnectionStatus.disconnected);
    await appState.connect();

    // Probe the separate HTTP sync API in parallel -- MQTT and the sync
    // API run on different ports and can succeed/fail independently (e.g.
    // broker up, sync_api.py down), so "connected" here means both, not
    // just whichever answers first.
    final mqttConnected =
        await statusFuture.then((s) => s == ConnectionStatus.connected);

    var syncReachable = false;
    try {
      await appState.syncApiClient.getPredictionPaused();
      syncReachable = true;
    } catch (_) {
      syncReachable = false;
    }

    final message = switch ((mqttConnected, syncReachable)) {
      (true, true) => 'Connected — alerts and history are both reachable.',
      (true, false) => 'Alerts connected, but the history/sync API '
          "didn't respond. Check the sync API port.",
      (false, true) => "History/sync API reachable, but the alert "
          "connection didn't come up. Check the MQTT port.",
      (false, false) => "Couldn't reach the monitor at all. Check the "
          "IP address and that the Pi is powered on and on the same WiFi.",
    };

    if (!mounted) return;
    setState(() {
      _testResult = mqttConnected && syncReachable
          ? _ConnectionTestResult.success
          : _ConnectionTestResult.failure;
      _testMessage = message;
    });
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

  void _simulateCryStarted() {
    context.read<AppState>().simulateNotifyEvent(NotifyEvent(
          kind: NotifyEventKind.cryStarted,
          timestamp: DateTime.now(),
          stage1Confidence: 0.9,
          stage2Probs: const {'hungry': 0.5, 'fussy': 0.3, 'tired': 0.2},
          context: const CryContext(
            secondsSinceFeed: 1800,
            secondsSinceChange: 5400,
          ),
        ));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Simulated: cry started')),
    );
  }

  void _simulateReasonUpdated() {
    final appState = context.read<AppState>();
    final startedAt =
        appState.activeSession?.startedAt ?? DateTime.now().subtract(
          const Duration(minutes: 1),
        );
    final durationSeconds =
        DateTime.now().difference(startedAt).inSeconds.toDouble();
    // Exercises the "silent refresh" branch (see app_state.dart's
    // _handleEvent) -- no chime, and if there's no active session yet
    // (e.g. simulated on its own without "Simulate cry started" first)
    // this also exercises the session-synthesis fallback for a missed
    // cry_started, which otherwise has no dev-mode way to trigger at
    // all.
    appState.simulateNotifyEvent(NotifyEvent(
      kind: NotifyEventKind.reasonUpdated,
      timestamp: DateTime.now(),
      aggregatedStage2Probs: const {'hungry': 0.3, 'fussy': 0.6, 'tired': 0.1},
      durationSeconds: durationSeconds,
      confirmedCrySeconds: durationSeconds * 0.7,
      cryDensity: 0.7,
      context: const CryContext(
        secondsSinceFeed: 1860,
        secondsSinceChange: 5460,
      ),
    ));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Simulated: reason updated')),
    );
  }

  void _simulateCryEnded() {
    final appState = context.read<AppState>();
    final startedAt =
        appState.activeSession?.startedAt ?? DateTime.now().subtract(
          const Duration(minutes: 3),
        );
    final durationSeconds =
        DateTime.now().difference(startedAt).inSeconds.toDouble();
    appState.simulateNotifyEvent(NotifyEvent(
      kind: NotifyEventKind.cryEnded,
      timestamp: DateTime.now(),
      aggregatedStage2Probs: const {'hungry': 0.5, 'fussy': 0.3, 'tired': 0.2},
      durationSeconds: durationSeconds,
      confirmedCrySeconds: durationSeconds * 0.85,
      cryDensity: 0.85,
      context: const CryContext(
        secondsSinceFeed: 1800,
        secondsSinceChange: 5400,
      ),
    ));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Simulated: cry ended')),
    );
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
      final deleted =
          await context.read<AppState>().syncApiClient.resetAllData();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Reset done: $deleted')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Reset failed — could not reach the monitor.')),
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
        Text('Monitor connection',
            style: Theme.of(context).textTheme.titleMedium),
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
        FilledButton(
          onPressed: _testResult == _ConnectionTestResult.testing
              ? null
              : _saveHost,
          child: _testResult == _ConnectionTestResult.testing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save & connect'),
        ),
        if (_testResult != null &&
            _testResult != _ConnectionTestResult.testing &&
            _testMessage != null) ...[
          const SizedBox(height: 8),
          _ConnectionTestBanner(
              result: _testResult!, message: _testMessage!),
        ],
        const SizedBox(height: 8),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('Advanced: ports'),
          subtitle: Text(
            'MQTT ${settings.mqttPort}, sync API ${settings.syncPort}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _mqttPortController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'MQTT port',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _syncPortController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Sync API port',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Text(
              "Only change these if the Pi's monitor.py/sync_api.py were "
              'configured with non-default ports. Defaults: MQTT '
              '${PiConnectionSettings.defaultMqttPort}, sync API '
              '${PiConnectionSettings.defaultSyncPort}.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
          ],
        ),
        const Divider(height: 40),
        Text('Prediction', style: Theme.of(context).textTheme.titleMedium),
        SwitchListTile(
          title: const Text('Pause cry detection'),
          subtitle: const Text(
            'Escape hatch if the monitor is misbehaving (e.g. false alarms). '
            'Crying will not be recorded if this is enabled',
          ),
          value: _paused ?? false,
          onChanged: _paused == null ? null : _togglePause,
        ),
        const Divider(height: 40),
        Text('Detection tuning', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Advanced — changes how the monitor itself decides a cry is '
          'happening. Leave these alone unless you know what you\'re doing.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _thresholdController,
          enabled: _detectionSettingsLoaded,
          keyboardType:
              const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: 'Stage-1 confidence threshold (0-1)',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _startWindowsController,
          enabled: _detectionSettingsLoaded,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Consecutive windows to start a session',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _endWindowsController,
          enabled: _detectionSettingsLoaded,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Missed windows to end a session',
            border: OutlineInputBorder(),
          ),
        ),
        if (_detectionSettingsError != null) ...[
          const SizedBox(height: 8),
          Text(_detectionSettingsError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ],
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: FilledButton(
                onPressed: (_detectionSettingsLoaded &&
                        !_savingDetectionSettings)
                    ? _saveDetectionSettings
                    : null,
                child: _savingDetectionSettings
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Save'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton(
                onPressed: (_detectionSettingsLoaded &&
                        !_savingDetectionSettings)
                    ? _resetDetectionSettings
                    : null,
                child: const Text('Reset to defaults'),
              ),
            ),
          ],
        ),
        if (!_detectionSettingsLoaded) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text("Couldn't load detection settings from the monitor.",
                    style: Theme.of(context).textTheme.bodySmall),
              ),
              TextButton(
                onPressed: _loadDetectionSettings,
                child: const Text('Retry'),
              ),
            ],
          ),
        ],
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
          const SizedBox(height: 16),
          Text(
            'Simulate a crying session without a real Pi — exercises the '
            'active-session card, the cry-started chime, and the silent '
            'mid-session reason_updated refresh (including its no-active-'
            'session synthesis fallback if fired on its own).',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _simulateCryStarted,
                  child: const Text('Cry started'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton(
                  onPressed: _simulateReasonUpdated,
                  child: const Text('Reason updated'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton(
                  onPressed: _simulateCryEnded,
                  child: const Text('Cry ended'),
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
                    _syncPortController.text = '${appState.settings.syncPort}';
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Fake monitor stopped.')),
                    );
                  }
                } else {
                  await appState.startFakePiServer();
                  if (context.mounted) {
                    _hostController.text = appState.settings.host ?? '';
                    _syncPortController.text = '${appState.settings.syncPort}';
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

class _ConnectionTestBanner extends StatelessWidget {
  final _ConnectionTestResult result;
  final String message;
  const _ConnectionTestBanner({required this.result, required this.message});

  @override
  Widget build(BuildContext context) {
    final success = result == _ConnectionTestResult.success;
    final color = success ? Colors.green : Colors.red;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(success ? Icons.check_circle : Icons.error_outline,
              color: color),
          const SizedBox(width: 12),
          Expanded(child: Text(message)),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../services/foreground_service.dart';
import '../services/notify_listener.dart';
import 'care_events_screen.dart';
import 'history_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeConnect());
  }

  Future<void> _maybeConnect() async {
    final appState = context.read<AppState>();
    if (!appState.settings.isConfigured) return;
    await ForegroundServiceController.start();
    await appState.connect();
  }

  @override
  Widget build(BuildContext context) {
    final screens = [
      const _StatusTab(),
      const CareEventsScreen(),
      const HistoryScreen(),
      const SettingsScreen(),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('AmliOS'),
            Text(
              'Accessible monitoring and logging intelligent Operating System',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
      body: screens[_tab],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.hearing), label: 'Status'),
          NavigationDestination(
              icon: Icon(Icons.child_care), label: 'Care log'),
          NavigationDestination(icon: Icon(Icons.history), label: 'History'),
          NavigationDestination(icon: Icon(Icons.settings), label: 'Settings'),
        ],
      ),
    );
  }
}

class _StatusTab extends StatelessWidget {
  const _StatusTab();

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();

    if (!appState.settings.isConfigured) {
      return const _NotConfiguredNotice();
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _ConnectionBanner(status: appState.connectionStatus),
        const SizedBox(height: 24),
        if (appState.activeSession == null)
          const _NoActiveSession()
        else
          _ActiveSessionCard(session: appState.activeSession!),
      ],
    );
  }
}

class _NotConfiguredNotice extends StatelessWidget {
  const _NotConfiguredNotice();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.settings_ethernet, size: 48),
            const SizedBox(height: 16),
            const Text(
              "Not connected to a monitor yet.\nEnter the Pi's address in Settings.",
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              ),
              child: const Text('Open settings'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConnectionBanner extends StatelessWidget {
  final ConnectionStatus status;
  const _ConnectionBanner({required this.status});

  @override
  Widget build(BuildContext context) {
    final (color, icon, label) = switch (status) {
      ConnectionStatus.connected => (
          Colors.green,
          Icons.check_circle,
          'Connected — listening for alerts'
        ),
      ConnectionStatus.connecting => (Colors.orange, Icons.sync, 'Connecting…'),
      ConnectionStatus.disconnected => (
          Colors.red,
          Icons.error_outline,
          'Disconnected — check WiFi / Pi address'
        ),
    };

    return Card(
      color: color.withValues(alpha: 0.12),
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Text(label),
      ),
    );
  }
}

class _NoActiveSession extends StatelessWidget {
  const _NoActiveSession();

  @override
  Widget build(BuildContext context) {
    return const Card(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Column(
          children: [
            Icon(Icons.bedtime, size: 40),
            SizedBox(height: 12),
            Text('No active crying session'),
          ],
        ),
      ),
    );
  }
}

class _ActiveSessionCard extends StatelessWidget {
  final ActiveCrySession session;
  const _ActiveSessionCard({required this.session});

  @override
  Widget build(BuildContext context) {
    final probs = session.latestReasonProbs;
    String? topReason;
    if (probs != null && probs.isNotEmpty) {
      topReason = (probs.entries.toList()
            ..sort((a, b) => b.value.compareTo(a.value)))
          .first
          .key;
    }

    return Card(
      color: session.ended ? null : Colors.red.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              session.ended ? 'Cry ended' : 'Crying now',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text('Started: ${session.startedAt.toLocal()}'),
            if (session.durationSeconds != null)
              Text('Duration: ${session.durationSeconds!.toStringAsFixed(0)}s'),
            if (session.confirmedCrySeconds != null &&
                session.cryDensity != null)
              Text(
                'Confirmed crying: ${session.confirmedCrySeconds!.toStringAsFixed(0)}s '
                '(${(session.cryDensity! * 100).toStringAsFixed(0)}% of session)',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            if (topReason != null) ...[
              const SizedBox(height: 8),
              Text('Likely reason: $topReason',
                  style: Theme.of(context).textTheme.titleMedium),
            ],
            if (session.context.secondsSinceFeed != null ||
                session.context.secondsSinceChange != null) ...[
              const SizedBox(height: 8),
              if (session.context.secondsSinceFeed != null)
                Text(
                  '${_formatSince(session.context.secondsSinceFeed!)} since last feed',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              if (session.context.secondsSinceChange != null)
                Text(
                  '${_formatSince(session.context.secondsSinceChange!)} since last change',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ],
        ),
      ),
    );
  }

  /// e.g. 11520 -> "3.2h", 90 -> "2m" -- mirrors PI_CONTRACT.md's own
  /// example format ("3.2h since feed") rather than a full h/m/s
  /// breakdown, since the point is a rough at-a-glance sense of "was it
  /// recent," not precise elapsed time.
  String _formatSince(double seconds) {
    if (seconds < 60) return '${seconds.toStringAsFixed(0)}s';
    if (seconds < 3600) return '${(seconds / 60).toStringAsFixed(0)}m';
    return '${(seconds / 3600).toStringAsFixed(1)}h';
  }
}

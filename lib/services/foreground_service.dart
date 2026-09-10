import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Keeps the process alive with the screen off / app backgrounded, same
/// mechanism music/navigation apps use — see docs/PI_CONTRACT.md on why
/// this replaces push notifications on Android. Must be started once
/// (main.dart) before relying on NotifyListener staying connected in
/// the background.
class ForegroundServiceController {
  static Future<void> init() async {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'baby_monitor_notify_channel',
        channelName: 'Baby Monitor connection',
        channelDescription:
            'Keeps the app connected to the monitor so cry alerts arrive with the screen off.',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  static Future<void> start() async {
    if (await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.startService(
      notificationTitle: 'Baby monitor connected',
      notificationText: 'Listening for cry alerts',
    );
  }

  static Future<void> stop() async {
    await FlutterForegroundTask.stopService();
  }
}

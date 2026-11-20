/// Android foreground service that keeps the app process (and its daemon
/// sockets) alive in the background with a persistent notification. This is
/// the free, no-cloud way to get timely alerts on Android.
library;

import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

class BackgroundLink {
  static bool get supported => Platform.isAndroid;

  static Future<void> init() async {
    if (!supported) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'porthole_keepalive',
        channelName: 'Connected to your machine',
        channelDescription: 'Keeps Porthole listening for sessions that need you.',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(showNotification: false),
      foregroundTaskOptions: ForegroundTaskOptions(eventAction: ForegroundTaskEventAction.nothing(), allowWakeLock: true, allowWifiLock: true),
    );
  }

  static Future<bool> start() async {
    if (!supported) return false;
    final r = await FlutterForegroundTask.startService(
      serviceId: 7433,
      notificationTitle: 'Porthole',
      notificationText: 'Watching your sessions over the VPN',
      notificationIcon: null,
    );
    return r is ServiceRequestSuccess;
  }

  static Future<void> stop() async {
    if (!supported) return;
    await FlutterForegroundTask.stopService();
  }

  static Future<bool> isRunning() async => supported && await FlutterForegroundTask.isRunningService;
}

/// Local notifications for attention events, used both for live events while
/// connected and for decrypted push notices.
library;

import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class Notifier {
  Notifier._();
  static final Notifier instance = Notifier._();
  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;
  void Function(String sessionKey)? onTap;
  /// Session key of the notification that launched the app (cold start), if any.
  String? launchPayload;

  Future<void> init() async {
    if (_ready || !(Platform.isAndroid || Platform.isIOS)) return;
    const android = AndroidInitializationSettings('@drawable/ic_notification');
    const ios = DarwinInitializationSettings(requestAlertPermission: false, requestBadgePermission: false, requestSoundPermission: false);
    await _plugin.initialize(
      settings: const InitializationSettings(android: android, iOS: ios),
      onDidReceiveNotificationResponse: (r) {
        if (r.payload != null && r.payload!.isNotEmpty) onTap?.call(r.payload!);
      },
    );
    _ready = true;
    try {
      final d = await _plugin.getNotificationAppLaunchDetails();
      if (d?.didNotificationLaunchApp == true) launchPayload = d!.notificationResponse?.payload;
    } catch (_) {}
  }

  Future<bool> requestPermission() async {
    await init();
    if (Platform.isAndroid) {
      final r = await _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationsPermission();
      return r ?? false;
    }
    if (Platform.isIOS) {
      final r = await _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()?.requestPermissions(alert: true, badge: true, sound: true);
      return r ?? false;
    }
    return false;
  }

  Future<void> show({required String id, required String title, required String body, String? sessionKey, bool urgent = false}) async {
    if (!_ready) return;
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        urgent ? 'attention' : 'activity',
        urgent ? 'Needs your attention' : 'Session activity',
        channelDescription: urgent ? 'Permission prompts and input requests' : 'Sessions finishing',
        importance: urgent ? Importance.high : Importance.defaultImportance,
        priority: urgent ? Priority.high : Priority.defaultPriority,
        category: urgent ? AndroidNotificationCategory.alarm : null,
      ),
      iOS: DarwinNotificationDetails(threadIdentifier: sessionKey ?? 'porthole', interruptionLevel: urgent ? InterruptionLevel.timeSensitive : InterruptionLevel.active),
    );
    await _plugin.show(id: id.hashCode & 0x7fffffff, title: title, body: body, notificationDetails: details, payload: sessionKey);
  }

  Future<void> cancelFor(String sessionKey) => _plugin.cancel(id: sessionKey.hashCode & 0x7fffffff);
}

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  static final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  static Future<void> initialize() async {
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    const InitializationSettings initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
    );

    await _notificationsPlugin.initialize(
      initializationSettings,
      onDidReceiveNotificationResponse: (details) {
        // Handle notification tap
      },
    );
  }

  static Future<void> showBluetoothWarning() async {
    const AndroidNotificationDetails androidPlatformChannelSpecifics =
        AndroidNotificationDetails(
      'ble_warning_channel',
      'Bluetooth Requirements',
      channelDescription: 'Alerts when Bluetooth is disabled during an active tracking session.',
      importance: Importance.max,
      priority: Priority.high,
      ongoing: true, // Non-dismissible
      autoCancel: false,
    );
    const NotificationDetails platformChannelSpecifics =
        NotificationDetails(android: androidPlatformChannelSpecifics);

    await _notificationsPlugin.show(
      888, // Unique ID for BLE Warning
      'Action Required: Enable Bluetooth',
      'Your presence tracking session is active but Bluetooth is off!',
      platformChannelSpecifics,
    );
  }

  static Future<void> cancelBluetoothWarning() async {
    await _notificationsPlugin.cancel(888);
  }

  static Future<void> showAttendanceStatus(bool isMarked, String taskName) async {
    final AndroidNotificationDetails androidPlatformChannelSpecifics =
        AndroidNotificationDetails(
      'attendance_status_channel',
      'Attendance Alerts',
      channelDescription: 'Alerts when attendance is finalized for a session.',
      importance: Importance.high,
      priority: Priority.high,
      color: isMarked ? const Color(0xFF0078D4) : const Color(0xFFE53935), // Primary blue / Red
    );
    final NotificationDetails platformChannelSpecifics =
        NotificationDetails(android: androidPlatformChannelSpecifics);

    String title = isMarked ? 'Attendance Marked ✓' : 'Attendance Failed ❌';
    String body = isMarked 
        ? 'Your presence for $taskName has been successfully automatically recorded.' 
        : 'Your presence for $taskName was not captured. Please contact your administrator.';

    await _notificationsPlugin.show(
      DateTime.now().millisecondsSinceEpoch % 100000, 
      title,
      body,
      platformChannelSpecifics,
    );
  }
}

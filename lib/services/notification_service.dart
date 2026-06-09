import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Top-level background handler for notification action buttons.
/// Required for handling actions when the app is killed/background.
@pragma('vm:entry-point')
void onNotificationActionBackground(NotificationResponse details) async {
  print('NOTIFICATION_SERVICE: [BG_ACTION] ${details.actionId} payload=${details.payload}');
  if (details.actionId == 'enable_bluetooth') {
    try { await FlutterBluePlus.turnOn(); } catch (e) {
      print('NOTIFICATION_SERVICE: [BG_ACTION] turnOn failed: $e');
    }
  } else if (details.actionId == 'mark_absent') {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('bg_mark_absent', true);
    print('NOTIFICATION_SERVICE: [BG_ACTION] bg_mark_absent flag set');
  }
}

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();
  VoidCallback? _ongoingTapCallback;
  bool _initialized = false;

  void setOngoingTapCallback(VoidCallback callback) {
    _ongoingTapCallback = callback;
  }

  Future<void> init() async {
    if (_initialized) return;
    print('NOTIFICATION_SERVICE: [INIT_START]');

    // Request permission (requires Activity context — silently skip in background isolates)
    try {
      await _notifications
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    } catch (e) {
      print('NOTIFICATION_SERVICE: [PERMISSION_SKIP] Background context, skipping: $e');
    }

    const android = AndroidInitializationSettings('@drawable/ic_notification');
    const initSettings = InitializationSettings(android: android);

    try {
      final bool? initialized = await _notifications.initialize(
        settings: initSettings,
        onDidReceiveNotificationResponse: _handleAction,
        onDidReceiveBackgroundNotificationResponse: onNotificationActionBackground,
      );
      print('NOTIFICATION_SERVICE: [INIT_RESULT] $initialized');
      _initialized = initialized ?? false;
      await _createChannels();
    } catch (e) {
      print('NOTIFICATION_SERVICE: [INIT_ERROR] $e');
      // Mark initialized so we don't keep crashing on every call
      _initialized = true;
    }
  }

  void _handleAction(NotificationResponse details) async {
    print('NOTIFICATION_SERVICE: [ACTION] id=${details.actionId} payload=${details.payload}');
    if (details.actionId == 'enable_bluetooth') {
      await _turnOnBluetooth();
    } else if (details.actionId == 'mark_absent') {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('bg_mark_absent', true);
      print('NOTIFICATION_SERVICE: [ACTION] bg_mark_absent flag set');
    } else if (details.payload == 'bt_off') {
      await _turnOnBluetooth();
    } else if (details.payload == 'ongoing') {
      _ongoingTapCallback?.call();
    }
  }

  Future<void> requestPermissions() async {
    try {
      await _notifications
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    } catch (e) {
      print('NOTIFICATION_SERVICE: [PERMISSION_ERROR] $e');
    }
  }

  Future<void> _createChannels() async {
    try {
      // BT alert — max importance, bypasses DND
      const btChannel = AndroidNotificationChannel(
        'bt_alert_v2',
        'Bluetooth Alert',
        description: 'Alerts when Bluetooth is turned off during a session',
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
        bypassDnd: true,
      );
      // Ongoing session — low importance, persistent
      const ongoingChannel = AndroidNotificationChannel(
        'ongoing_session',
        'Ongoing Session',
        description: 'Status of the currently active attendance session',
        importance: Importance.low,
      );
      // BLE error — high importance, non-dismissible
      const bleErrorChannel = AndroidNotificationChannel(
        'ble_error_channel',
        'BLE Error',
        description: 'Alerts when BLE cannot start',
        importance: Importance.high,
        playSound: true,
        enableVibration: true,
      );
      const alertChannel = AndroidNotificationChannel(
        'alert_channel',
        'Alerts',
        description: 'General session alerts',
        importance: Importance.high,
      );

      final impl = _notifications
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      await impl?.createNotificationChannel(btChannel);
      await impl?.createNotificationChannel(ongoingChannel);
      await impl?.createNotificationChannel(bleErrorChannel);
      await impl?.createNotificationChannel(alertChannel);
    } catch (e) {
      print('NOTIFICATION_SERVICE: [CHANNEL_ERROR] $e');
    }
  }

  Future<void> _turnOnBluetooth() async {
    print('NotificationService: Attempting to turn on Bluetooth');
    try {
      await FlutterBluePlus.turnOn();
    } catch (e) {
      print('NotificationService: TurnOn BT Error: $e');
    }
  }

  /// High-priority BT-off alert with two action buttons:
  /// [Enable Bluetooth] and [Mark as Absent].
  /// Shown every 10s while BT is off during a session.
  Future<void> showBluetoothAlert([String activityName = 'current session']) async {
    print('NOTIFICATION_SERVICE: [SHOW_BT_ALERT]');
    final android = AndroidNotificationDetails(
      'bt_alert_v2',
      'Bluetooth Alert',
      importance: Importance.max,
      priority: Priority.max,
      ticker: 'Bluetooth is OFF',
      icon: '@drawable/ic_notification',
      largeIcon: const DrawableResourceAndroidBitmap('@mipmap/ic_launcher_round'),
      playSound: true,
      enableVibration: true,
      fullScreenIntent: true,
      autoCancel: false,
      ongoing: false, // allows dismissal by user (actions handle the logic)
      actions: const [
        AndroidNotificationAction(
          'enable_bluetooth',
          'Enable Bluetooth',
          showsUserInterface: true,  // brings app to foreground
          cancelNotification: false,
        ),
        AndroidNotificationAction(
          'mark_absent',
          'Mark as Absent',
          showsUserInterface: false,
          cancelNotification: true,
        ),
      ],
    );
    try {
      await _notifications.show(
        id: 100,
        title: '⚠️ Bluetooth is OFF',
        body: 'Attendance for "$activityName" cannot be tracked. Turn on Bluetooth or mark absent.',
        notificationDetails: NotificationDetails(android: android),
        payload: 'bt_off',
      );
    } catch (e) {
      print('NOTIFICATION_SERVICE: [SHOW_ERROR] $e');
    }
  }

  /// Non-dismissible notification when BLE fails for non-BT reasons.
  Future<void> showBleError(String reason, String activityName) async {
    print('NOTIFICATION_SERVICE: [SHOW_BLE_ERROR] $reason');
    const android = AndroidNotificationDetails(
      'ble_error_channel',
      'BLE Error',
      importance: Importance.high,
      priority: Priority.high,
      icon: '@drawable/ic_notification',
      largeIcon: DrawableResourceAndroidBitmap('@mipmap/ic_launcher_round'),
      ongoing: true,
      autoCancel: false,
      playSound: true,
      enableVibration: true,
    );
    try {
      await _notifications.show(
        id: 104,
        title: '❌ BLE Error: $activityName',
        body: '$reason\nAttendance cannot be marked automatically.',
        notificationDetails: const NotificationDetails(android: android),
        payload: 'ble_error',
      );
    } catch (e) {
      print('NOTIFICATION_SERVICE: [SHOW_ERROR] $e');
    }
  }

  Future<void> cancelBleError() async => cancel(104);

  /// Ongoing peer-count notification. Only shown after BLE is confirmed active.
  Future<void> showOngoingSession(String activityName, int userCount) async {
    print('NOTIFICATION_SERVICE: [SHOW_ONGOING] $activityName peers=$userCount');
    const android = AndroidNotificationDetails(
      'ongoing_session',
      'Ongoing Session',
      importance: Importance.low,
      priority: Priority.low,
      showWhen: true,
      ongoing: true,
      autoCancel: false,
      icon: '@drawable/ic_notification',
      largeIcon: DrawableResourceAndroidBitmap('@mipmap/ic_launcher_round'),
    );
    try {
      await _notifications.show(
        id: 101,
        title: '📡 Tracking: $activityName',
        body: 'Users scanned: $userCount  •  Tap to view list',
        notificationDetails: const NotificationDetails(android: android),
        payload: 'ongoing',
      );
    } catch (e) {
      print('NOTIFICATION_SERVICE: [SHOW_ERROR] $e');
    }
  }

  Future<void> cancel(int id) async {
    print('NOTIFICATION_SERVICE: [CANCEL] $id');
    try {
      await _notifications.cancel(id: id);
    } catch (e) {}
  }

  Future<void> showAlert(String title, String body) async {
    print('NOTIFICATION_SERVICE: [SHOW_ALERT] $title');
    const android = AndroidNotificationDetails(
      'alert_channel',
      'Alerts',
      importance: Importance.max,
      priority: Priority.max,
      icon: '@drawable/ic_notification',
      largeIcon: DrawableResourceAndroidBitmap('@mipmap/ic_launcher_round'),
    );
    try {
      await _notifications.show(
        id: 102,
        title: title,
        body: body,
        notificationDetails: const NotificationDetails(android: android),
      );
    } catch (e) {
      print('NOTIFICATION_SERVICE: [SHOW_ERROR] $e');
    }
  }

  Future<void> showMismatchAlert(String activityName, int count) async {
    const android = AndroidNotificationDetails(
      'mismatch_alert',
      'Mismatch Alert',
      importance: Importance.max,
      priority: Priority.high,
      icon: '@drawable/ic_notification',
      largeIcon: DrawableResourceAndroidBitmap('@mipmap/ic_launcher_round'),
      category: AndroidNotificationCategory.error,
    );
    try {
      await _notifications.show(
        id: 103,
        title: 'Attendance Mismatch: $activityName',
        body: '$count records found locally are missing/stale in database!',
        notificationDetails: const NotificationDetails(android: android),
        payload: 'mismatch',
      );
    } catch (e) {
      print('NOTIFICATION_SERVICE: [SHOW_ERROR] $e');
    }
  }
}

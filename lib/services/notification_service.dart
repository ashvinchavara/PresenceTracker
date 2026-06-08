import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter/foundation.dart';

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
    if (_initialized) return; // avoid re-initializing on every call
    print('NOTIFICATION_SERVICE: [INIT_START]');
    
    // Request permission explicitly for Android 13+
    await _notifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationsPermission();

    const android = AndroidInitializationSettings('@drawable/ic_notification');
    const initSettings = InitializationSettings(android: android);
    
    try {
      final bool? initialized = await _notifications.initialize(
        settings: initSettings,
        onDidReceiveNotificationResponse: (details) {
          print('NOTIFICATION_SERVICE: [TAP] ${details.payload}');
          if (details.payload == 'bt_off') {
             _turnOnBluetooth();
          } else if (details.payload == 'ongoing') {
             _ongoingTapCallback?.call();
          }
        },
      );
      print('NOTIFICATION_SERVICE: [INIT_RESULT] $initialized');
      _initialized = initialized ?? false;

      await _createChannels();
      
    } catch (e) {
      print('NOTIFICATION_SERVICE: [INIT_ERROR] $e');
    }
  }

  Future<void> requestPermissions() async {
    await _notifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationsPermission();
  }

  Future<void> _createChannels() async {
    // BT alert channel — high importance, bypasses DND
    const btChannel = AndroidNotificationChannel(
      'bt_alert_v2',
      'Bluetooth Alert',
      description: 'Alerts when Bluetooth is turned off during a session',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
      bypassDnd: true, // override Do-Not-Disturb/silent
    );
    // Ongoing session channel — low importance, persistent
    const ongoingChannel = AndroidNotificationChannel(
      'ongoing_session',
      'Ongoing Session',
      description: 'Status of the currently active attendance session',
      importance: Importance.low,
    );
    // BLE error channel — high importance, non-dismissible
    const bleErrorChannel = AndroidNotificationChannel(
      'ble_error_channel',
      'BLE Error',
      description: 'Alerts when BLE cannot start for reasons other than Bluetooth being off',
      importance: Importance.high,
      playSound: true,
      enableVibration: true,
    );
    // General alerts channel
    const alertChannel = AndroidNotificationChannel(
      'alert_channel',
      'Alerts',
      description: 'General session alerts',
      importance: Importance.high,
    );

    final impl = _notifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await impl?.createNotificationChannel(btChannel);
    await impl?.createNotificationChannel(ongoingChannel);
    await impl?.createNotificationChannel(bleErrorChannel);
    await impl?.createNotificationChannel(alertChannel);
  }

  Future<void> _turnOnBluetooth() async {
    print('NotificationService: Attempting to turn on Bluetooth');
    try {
      await FlutterBluePlus.turnOn();
    } catch (e) {
      print('NotificationService: TurnOn BT Error: $e');
    }
  }

  /// High-priority alert shown every 10s while BT is off during a session.
  /// Tapping it attempts to turn Bluetooth back on.
  Future<void> showBluetoothAlert() async {
    print('NOTIFICATION_SERVICE: [SHOW_BT_ALERT]');
    const android = AndroidNotificationDetails(
      'bt_alert_v2',
      'Bluetooth Alert',
      importance: Importance.max,
      priority: Priority.max,
      ticker: 'Bluetooth is OFF',
      icon: '@drawable/ic_notification',
      largeIcon: DrawableResourceAndroidBitmap('@mipmap/ic_launcher_round'),
      playSound: true,
      enableVibration: true,
      fullScreenIntent: true, // pop over DND/lock screen
      autoCancel: false,      // stays until manually cleared
    );
    try {
      await _notifications.show(
        id: 100,
        title: '⚠️ Bluetooth is OFF',
        body: 'Tap to turn on Bluetooth and mark attendance.',
        notificationDetails: const NotificationDetails(android: android),
        payload: 'bt_off',
      );
    } catch (e) {
      print('NOTIFICATION_SERVICE: [SHOW_ERROR] $e');
    }
  }

  /// Non-dismissible notification shown when BLE fails for a non-Bluetooth reason
  /// (e.g. permissions denied, hardware not supported).
  Future<void> showBleError(String reason, String activityName) async {
    print('NOTIFICATION_SERVICE: [SHOW_BLE_ERROR] $reason');
    const android = AndroidNotificationDetails(
      'ble_error_channel',
      'BLE Error',
      importance: Importance.high,
      priority: Priority.high,
      icon: '@drawable/ic_notification',
      largeIcon: DrawableResourceAndroidBitmap('@mipmap/ic_launcher_round'),
      ongoing: true,         // non-dismissible
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

  /// Cancel the BLE error notification (ID 104).
  Future<void> cancelBleError() async {
    await cancel(104);
  }

  /// Ongoing notification showing real-time peer count.
  /// Should only be shown AFTER BLE scanning and advertising are confirmed active.
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
    print('NOTIFICATION_SERVICE: [SHOW_MISMATCH] $activityName');
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

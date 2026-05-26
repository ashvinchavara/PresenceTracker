import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter/foundation.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();
  VoidCallback? _ongoingTapCallback;

  void setOngoingTapCallback(VoidCallback callback) {
    _ongoingTapCallback = callback;
  }

  Future<void> init() async {
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

      await _createChannels();
      
    } catch (e) {
      print('NOTIFICATION_SERVICE: [INIT_ERROR] $e');
    }
  }

  Future<void> requestPermissions() async {
    await _notifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationsPermission();
  }

  Future<void> _createChannels() async {
    const btChannel = AndroidNotificationChannel(
      'bt_alert',
      'Bluetooth Alert',
      description: 'Alerts when Bluetooth is turned off during a session',
      importance: Importance.max,
    );
    const ongoingChannel = AndroidNotificationChannel(
      'ongoing_session',
      'Ongoing Session',
      description: 'Status of the currently active attendance session',
      importance: Importance.low,
    );

    await _notifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(btChannel);
    await _notifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(ongoingChannel);
  }

  Future<void> _turnOnBluetooth() async {
    print('NotificationService: Attempting to turn on Bluetooth');
    try {
      await FlutterBluePlus.turnOn();
    } catch (e) {
      print('NotificationService: TurnOn BT Error: $e');
    }
  }

  Future<void> showBluetoothAlert() async {
    print('NOTIFICATION_SERVICE: [SHOW_BT_ALERT]');
    const android = AndroidNotificationDetails(
      'bt_alert',
      'Bluetooth Alert',
      importance: Importance.max,
      priority: Priority.high,
      ticker: 'Bluetooth is OFF',
      icon: '@drawable/ic_notification',
      largeIcon: const DrawableResourceAndroidBitmap('@mipmap/ic_launcher_round'),
      category: AndroidNotificationCategory.alarm,
      audioAttributesUsage: AudioAttributesUsage.alarm,
      fullScreenIntent: true,
    );
    try {
      await _notifications.show(
        id: 100,
        title: 'Bluetooth is OFF',
        body: 'Tap to turn on Bluetooth and mark attendance.',
        notificationDetails: const NotificationDetails(android: android),
        payload: 'bt_off',
      );
    } catch (e) {
      print('NOTIFICATION_SERVICE: [SHOW_ERROR] $e');
    }
  }

  Future<void> showOngoingSession(String activityName, int userCount) async {
    print('NOTIFICATION_SERVICE: [SHOW_ONGOING] $activityName');
    const android = AndroidNotificationDetails(
      'ongoing_session',
      'Ongoing Session',
      importance: Importance.low,
      priority: Priority.low,
      showWhen: true,
      ongoing: true,
      icon: '@drawable/ic_notification',
      largeIcon: const DrawableResourceAndroidBitmap('@mipmap/ic_launcher_round'),
    );
    try {
      await _notifications.show(
        id: 101,
        title: 'Ongoing: $activityName',
        body: 'Peers Scanned: $userCount',
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
      largeIcon: const DrawableResourceAndroidBitmap('@mipmap/ic_launcher_round'),
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
      largeIcon: const DrawableResourceAndroidBitmap('@mipmap/ic_launcher_round'),
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

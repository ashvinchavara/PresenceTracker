import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user_node.dart';
import '../services/api_service.dart';
import '../services/session_automation_service.dart';
import '../services/foreground_task_handler.dart';
import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

class NodeRoleProvider with ChangeNotifier {
  final ApiService _apiService = ApiService();
  UserNode? _currentUserNode;
  bool _isLoading = false;
  List<String> _allowedUploadRoles = [];

  bool _isTestMode = false;
  bool get isTestMode => _isTestMode;

  void setTestMode(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    final automation = SessionAutomationService();

    if (value) {
      final now = DateTime.now();
      final t1Start = now.add(const Duration(minutes: 1));
      final t1End = t1Start.add(const Duration(minutes: 2)); // 2 minutes run time after start (total 3 minutes from now)
      
      await prefs.setString('test_start_time', t1Start.toIso8601String());
      await prefs.setString('test_end_time', t1End.toIso8601String());

      final dayNames = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
      final todayName = dayNames[now.weekday - 1];

      String formatTimeRange(DateTime s, DateTime e) {
        String formatTime(DateTime dt) {
          int hour = dt.hour;
          int minute = dt.minute;
          String period = hour >= 12 ? 'PM' : 'AM';
          hour = hour % 12;
          if (hour == 0) hour = 12;
          return "${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')} $period";
        }
        return "${formatTime(s)} - ${formatTime(e)}";
      }
      
      final testTasks = [
        {
          'id': 9901,
          'activity_name': 'Test Activity',
          'department': 'Test Dept',
          'start_time': t1Start.toIso8601String(),
          'end_time': t1End.toIso8601String(),
          'day_of_week': todayName,
          'time_range': formatTimeRange(t1Start, t1End),
          'is_test': true,
        }
      ];
      
      await prefs.setString('test_mode_tasks', jsonEncode(testTasks));

      final testAlarmData = {
        'task_id': 9901,
        'user_id': _currentUserNode?.id.toString() ?? '',
        'activity_name': 'Test Activity',
        'start_time': t1Start.toIso8601String(),
        'end_time': t1End.toIso8601String(),
        'is_root': true,
        'is_test': true,
        'status': 'scheduled',
      };

      await prefs.setString('test_session_alarm', jsonEncode(testAlarmData));
      
      // Cancel existing normal alarms
      await automation.cancelAllSessions();

      // Schedule exact test alarms (as safety fallbacks)
      print('Automation: Scheduling test start alarm at $t1Start');
      await AndroidAlarmManager.oneShotAt(
        t1Start,
        1001, // _startAlarmId
        onSessionStart,
        exact: true,
        wakeup: true,
        rescheduleOnReboot: true,
      );

      print('Automation: Scheduling test end alarm at $t1End');
      await AndroidAlarmManager.oneShotAt(
        t1End,
        1002, // _endAlarmId
        onSessionEnd,
        exact: true,
        wakeup: true,
        rescheduleOnReboot: true,
      );

      // Start the foreground service immediately in the waiting stage
      print('Automation: Initializing foreground service for Test mode immediately');
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: 'ble_session_service',
          channelName: 'BLE Attendance Session',
          channelDescription: 'Running BLE scanning and advertising for attendance tracking.',
          onlyAlertOnce: true,
        ),
        iosNotificationOptions: const IOSNotificationOptions(
          showNotification: false,
          playSound: false,
        ),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.repeat(10000), // Update every 10s
          autoRunOnBoot: true,
          autoRunOnMyPackageReplaced: true,
          allowWakeLock: true,
          allowWifiLock: true,
          stopWithTask: false,
        ),
      );

      final startResult = await FlutterForegroundTask.startService(
        serviceId: 300,
        notificationTitle: 'Waiting: Test Activity',
        notificationText: 'Starting in 60s...',
        notificationIcon: const NotificationIcon(
          metaDataName: 'com.pravera.flutter_foreground_task.NOTIFICATION_ICON',
        ),
        callback: startForegroundCallback,
      );
      print('Automation: Immediate Test Service Start Result: $startResult');
          
    } else {
      await automation.cancelAllSessions();
      
      // Clean up test mode keys
      await prefs.remove('test_mode_tasks');
      await prefs.remove('test_session_alarm');
      await prefs.remove('test_start_time');
      await prefs.remove('test_end_time');

      // Immediately restore real timetable scheduling
      final jsonStr = prefs.getString('cached_user_timetable');
      if (jsonStr != null) {
        try {
          final decoded = jsonDecode(jsonStr);
          if (decoded is List) {
            final tasks = decoded.cast<Map<String, dynamic>>();
            await automation.scheduleNextSessionIfNeeded(
                tasks, _currentUserNode?.id.toString() ?? '', canUpload);
            print('Automation: Real timetable alarms restored.');
          }
        } catch (e) {
          print('Error restoring real timetable alarms: $e');
        }
      }
    }

    // Set preference flag and provider variable AFTER all writes/scheduling complete
    await prefs.setBool('is_test_mode', value);
    _isTestMode = value;
    notifyListeners();
  }

  UserNode? get currentUserNode => _currentUserNode;
  bool get isLoading => _isLoading;
  bool get isRootNode => canUpload;
  
  bool get _realCanUpload {
    if (_currentUserNode == null) return false;
    if (_currentUserNode!.canUpload) return true;
    return _allowedUploadRoles.contains(_currentUserNode!.desig);
  }

  bool get canUpload {
    if (_isTestMode) return true;
    return _realCanUpload;
  }

  Future<void> loadSession() async {
    final prefs = await SharedPreferences.getInstance();
    _isTestMode = prefs.getBool('is_test_mode') ?? false;
    final userJson = prefs.getString('user_session');
    if (userJson != null) {
      try {
        final userMap = jsonDecode(userJson);
        _currentUserNode = UserNode.fromMap(userMap);
        await refreshPermissions();
        notifyListeners();
      } catch (e) {
        print('Error loading user session: $e');
        await prefs.remove('user_session');
      }
    }
  }

  Future<void> refreshPermissions() async {
    final prefs = await SharedPreferences.getInstance();
    
    // 1. Try to load cached roles first to avoid blocking the main isolate on start
    final cachedRoles = prefs.getStringList('cached_allowed_upload_roles');
    if (cachedRoles != null) {
      _allowedUploadRoles = cachedRoles;
      notifyListeners();
    }

    // 2. Fetch fresh roles in the background without blocking the UI
    _apiService.fetchAllowedUploadRoles().then((roles) async {
      _allowedUploadRoles = roles;
      final p = await SharedPreferences.getInstance();
      await p.setStringList('cached_allowed_upload_roles', roles);
      await p.setBool('is_root_user', _realCanUpload);
      notifyListeners();
    }).catchError((e) {
      print('Error fetching allowed upload roles in background: $e');
    });

    await prefs.setBool('is_root_user', _realCanUpload);
  }

  Future<void> fetchUserRole(String uid) async {
    _isLoading = true;
    notifyListeners();

    _currentUserNode = await _apiService.getCurrentUserNode(uid);
    await refreshPermissions();
    
    _isLoading = false;
    notifyListeners();
  }

  Future<void> setUser(UserNode user) async {
    _currentUserNode = user;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('user_session', jsonEncode(user.toMap()));
    await refreshPermissions();
    notifyListeners();
  }

  Future<void> clearUserRole() async {
    _currentUserNode = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('user_session');
    notifyListeners();
  }
}

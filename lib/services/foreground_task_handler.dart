import 'dart:async';
import 'dart:convert';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'ble_mesh_service.dart';
import 'api_service.dart';
import 'session_automation_service.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// Top-level callback that the foreground service calls to set the handler.
/// Must be a top-level or static function.
@pragma('vm:entry-point')
void startForegroundCallback() {
  FlutterForegroundTask.setTaskHandler(BleSessionTaskHandler());
}

/// The actual task handler that runs inside the foreground service isolate.
/// This isolate has full access to platform channels (BLE, notifications, etc.)
/// because it runs inside a real Android Service, not a bare isolate.
class BleSessionTaskHandler extends TaskHandler {
  final BleMeshService _bleService = BleMeshService();
  Timer? _uploadTimer;
  Timer? _verifyTimer;
  Timer? _endTimer;
  String _currentActivityName = 'Session';

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    print('FG_SERVICE: onStart triggered at $timestamp by ${starter.name}');

    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final isTestMode = prefs.getBool('is_test_mode') ?? false;
    final alarmKey = isTestMode ? 'test_session_alarm' : 'session_alarm';
    final alarmData = prefs.getString(alarmKey);
    if (alarmData == null) {
      print('FG_SERVICE: No session_alarm data found. Stopping service.');
      FlutterForegroundTask.stopService();
      return;
    }

    final data = jsonDecode(alarmData);
    final taskId = data['task_id'].toString();
    final userId = data['user_id'].toString();
    final activityName = data['activity_name'] ?? 'Session';
    final role = data['is_root'] == true ? 'root' : 'leaf';
    final isTest = data['is_test'] == true;

    print('FG_SERVICE: Starting BLE mesh for $activityName (task: $taskId, user: $userId, role: $role)');

    // Start BLE Mesh (this now works because we're in a foreground service!)
    await _bleService.initializeMeshNode(
      role, taskId, userId, activityName,
      isTest: isTest,
      startTimeStr: data['start_time'],
    );

    // Mark as active
    data['status'] = 'active';
    await prefs.setString(alarmKey, jsonEncode(data));

    // Calculate phase timers
    final endTime = DateTime.parse(data['end_time']);
    final now = DateTime.now();

    // Schedule upload (2 min before end)
    final uploadTime = isTest 
        ? endTime.subtract(const Duration(seconds: 60)) 
        : endTime.subtract(const Duration(minutes: 2));
    if (uploadTime.isAfter(now)) {
      final uploadDelay = uploadTime.difference(now);
      print('FG_SERVICE: Upload scheduled in ${uploadDelay.inSeconds}s');
      _uploadTimer = Timer(uploadDelay, _onUpload);
    }

    // Schedule verification (1 min before end)
    final verifyTime = isTest 
        ? endTime.subtract(const Duration(seconds: 30)) 
        : endTime.subtract(const Duration(minutes: 1));
    if (verifyTime.isAfter(now)) {
      final verifyDelay = verifyTime.difference(now);
      print('FG_SERVICE: Verification scheduled in ${verifyDelay.inSeconds}s');
      _verifyTimer = Timer(verifyDelay, _onVerify);
    }

    // Schedule end
    final endDelay = endTime.difference(now);
    if (endDelay.isNegative) {
      print('FG_SERVICE: End time is in the past. Stopping immediately.');
      await _onEnd();
    } else {
      print('FG_SERVICE: End scheduled in ${endDelay.inSeconds}s');
      _endTimer = Timer(endDelay, _onEnd);
    }

    // Update notification
    _currentActivityName = activityName;
    final btState = await FlutterBluePlus.adapterState.first;
    if (btState != BluetoothAdapterState.on) {
      FlutterForegroundTask.updateService(
        notificationTitle: '⚠️ Bluetooth is OFF',
        notificationText: 'Turn ON Bluetooth to track attendance for $activityName',
        notificationIcon: const NotificationIcon(metaDataName: 'com.pravera.flutter_foreground_task.NOTIFICATION_ICON'),
      );
    } else {
      FlutterForegroundTask.updateService(
        notificationTitle: 'Tracking: $activityName',
        notificationText: 'BLE mesh active • Session ends at ${endTime.hour.toString().padLeft(2, '0')}:${endTime.minute.toString().padLeft(2, '0')}',
        notificationIcon: const NotificationIcon(metaDataName: 'com.pravera.flutter_foreground_task.NOTIFICATION_ICON'),
      );
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    if (_bleService.isBtAlertShown) {
      FlutterForegroundTask.updateService(
        notificationTitle: '⚠️ Bluetooth is OFF',
        notificationText: 'Turn ON Bluetooth to track attendance for $_currentActivityName',
        notificationIcon: const NotificationIcon(metaDataName: 'com.pravera.flutter_foreground_task.NOTIFICATION_ICON'),
      );
      return;
    }

    // Periodic update: refresh notification with peer count
    final peers = _bleService.getLivePeers();
    FlutterForegroundTask.updateService(
      notificationTitle: 'Tracking: $_currentActivityName',
      notificationText: 'Peers scanned: ${peers.length} • Running...',
      notificationIcon: const NotificationIcon(metaDataName: 'com.pravera.flutter_foreground_task.NOTIFICATION_ICON'),
    );

    // Also persist peer data to SharedPreferences for UI sync
    _persistPeerData(peers);
  }

  Future<void> _persistPeerData(Map<String, Map<String, dynamic>> peers) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final Map<String, dynamic> serializable = {};
      peers.forEach((key, value) {
        serializable[key] = {
          'first_view': value['first'],
          'last_view': value['last'],
        };
      });
      await prefs.setString('root_aggregated_data', jsonEncode(serializable));
    } catch (e) {
      print('FG_SERVICE: Error persisting peer data: $e');
    }
  }

  Future<void> _onUpload() async {
    print('FG_SERVICE: Upload phase triggered at ${DateTime.now()}');
    try {
      await _bleService.uploadAttendance();
      FlutterForegroundTask.updateService(
        notificationText: 'Uploading attendance data...',
        notificationIcon: const NotificationIcon(metaDataName: 'com.pravera.flutter_foreground_task.NOTIFICATION_ICON'),
      );
    } catch (e) {
      print('FG_SERVICE: Upload error: $e');
    }
  }

  Future<void> _onVerify() async {
    print('FG_SERVICE: Verification phase triggered at ${DateTime.now()}');
    try {
      await _bleService.verifyAttendance();
      FlutterForegroundTask.updateService(
        notificationText: 'Verifying attendance...',
        notificationIcon: const NotificationIcon(metaDataName: 'com.pravera.flutter_foreground_task.NOTIFICATION_ICON'),
      );
    } catch (e) {
      print('FG_SERVICE: Verify error: $e');
    }
  }

  Future<void> _onEnd() async {
    print('FG_SERVICE: Session end triggered at ${DateTime.now()}');
    try {
      await _bleService.endMeshTask();

      final prefs = await SharedPreferences.getInstance();
      final isTestMode = prefs.getBool('is_test_mode') ?? false;
      final alarmKey = isTestMode ? 'test_session_alarm' : 'session_alarm';
      final alarmData = prefs.getString(alarmKey);
      
      // Clear current alarm
      await prefs.remove(alarmKey);
      if (isTestMode) {
        await prefs.remove('test_mode_tasks');
        await prefs.remove('test_start_time');
        await prefs.remove('test_end_time');
        await prefs.setBool('is_test_mode', false);
      }

      // CHAINING: Schedule next session
      if (alarmData != null) {
        final data = jsonDecode(alarmData);
        final userId = data['user_id'].toString();
        final isRoot = isTestMode ? (prefs.getBool('is_root_user') ?? false) : (data['is_root'] == true);
        
        print('FG_SERVICE: Session ended. Scheduling next...');
        final api = ApiService();
        List<Map<String, dynamic>> tasks = await api.getCachedUserTimetableOffline();
        if (tasks.isEmpty) {
          print('FG_SERVICE: Offline cache empty, fetching from API...');
          tasks = await api.fetchUserTimetable(userId);
        }
        
        // Save next alarm data for the alarm manager to pick up
        // The main app's SessionAutomationService will handle this
        // We just need to store the data
        if (tasks.isNotEmpty) {
          // Import and use the scheduling logic
          final SessionScheduler scheduler = SessionScheduler();
          await scheduler.scheduleNextFromForeground(tasks, userId, isRoot);
        } else {
          print('FG_SERVICE: No tasks found to schedule next.');
        }
      }
    } catch (e) {
      print('FG_SERVICE: End error: $e');
    }

    // Stop the foreground service
    FlutterForegroundTask.stopService();
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    print('FG_SERVICE: onDestroy(isTimeout: $isTimeout) at $timestamp');
    _uploadTimer?.cancel();
    _verifyTimer?.cancel();
    _endTimer?.cancel();
  }

  @override
  void onReceiveData(Object data) {
    print('FG_SERVICE: onReceiveData: $data');
    if (data is String && data == 'stop') {
      _onEnd();
    }
  }

  @override
  void onNotificationButtonPressed(String id) {
    print('FG_SERVICE: onNotificationButtonPressed: $id');
  }

  @override
  void onNotificationPressed() {
    print('FG_SERVICE: onNotificationPressed');
    FlutterForegroundTask.launchApp();
  }

  @override
  void onNotificationDismissed() {
    print('FG_SERVICE: onNotificationDismissed');
  }
}

/// Helper class to schedule the next session from within the foreground service.
/// This avoids importing the full SessionAutomationService (which depends on AlarmManager).
class SessionScheduler {
  Future<void> scheduleNextFromForeground(
    List<Map<String, dynamic>> tasks, String userId, bool isRoot) async {
    final prefs = await SharedPreferences.getInstance();
    
    if (prefs.containsKey('session_alarm')) return; // Already scheduled
    if (tasks.isEmpty) return;

    final now = DateTime.now();
    final dayNames = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    
    Map<String, dynamic>? nextTask;
    DateTime? nextStartTime;
    DateTime? nextEndTime;

    for (int dayOffset = 0; dayOffset < 7; dayOffset++) {
      final checkDate = now.add(Duration(days: dayOffset));
      final dayName = dayNames[checkDate.weekday - 1];

      for (var task in tasks) {
        final days = (task['day_of_week'] as String?)?.split(',') ?? [];
        if (!days.contains(dayName)) continue;

        DateTime start;
        DateTime end;

        if (task['is_test'] == true) {
          start = DateTime.parse(task['start_time']);
          end = DateTime.parse(task['end_time']);
        } else {
          final timeRange = task['time_range'] as String;
          final parts = timeRange.split(' - ');
          start = _parseTime(parts[0], checkDate);
          end = _parseTime(parts[1], checkDate);
        }

        if (start.isAfter(now)) {
          if (nextStartTime == null || start.isBefore(nextStartTime)) {
            nextStartTime = start;
            nextEndTime = end;
            nextTask = task;
          }
        } else if (now.isAfter(start) && now.isBefore(end)) {
          nextTask = task;
          nextStartTime = start;
          nextEndTime = end;
          break;
        }
      }
      if (nextTask != null && nextStartTime != null && nextStartTime.difference(now).inHours < 24) break;
    }

    if (nextTask != null && nextStartTime != null) {
      final alarmData = {
        'task_id': nextTask['id'],
        'user_id': userId,
        'activity_name': nextTask['activity_name'],
        'start_time': nextStartTime.toIso8601String(),
        'end_time': nextEndTime?.toIso8601String(),
        'is_root': isRoot,
        'is_test': nextTask['is_test'] == true,
        'status': 'scheduled',
      };

      await prefs.setString('session_alarm', jsonEncode(alarmData));
      print('FG_SERVICE: Next session alarm saved: ${nextTask['activity_name']} at $nextStartTime');

      if (nextStartTime.isAfter(now)) {
        // Actually schedule the alarms via AndroidAlarmManager
        try {
          await AndroidAlarmManager.initialize();
          
          print('FG_SERVICE: Scheduling start alarm at $nextStartTime');
          await AndroidAlarmManager.oneShotAt(
            nextStartTime,
            1001, // _startAlarmId
            onSessionStart,
            exact: true,
            wakeup: true,
            rescheduleOnReboot: true,
          );

          if (nextEndTime != null) {
            print('FG_SERVICE: Scheduling end alarm at $nextEndTime');
            await AndroidAlarmManager.oneShotAt(
              nextEndTime,
              1002, // _endAlarmId
              onSessionEnd,
              exact: true,
              wakeup: true,
              rescheduleOnReboot: true,
            );
          }
          print('FG_SERVICE: Next session alarms registered successfully.');
        } catch (e) {
          print('FG_SERVICE: Failed to schedule alarms from foreground: $e');
        }
      } else {
        // Start immediately (session already in progress)
        print('FG_SERVICE: Session already in progress, starting foreground service now.');
        onSessionStart();
      }
    }
  }

  DateTime _parseTime(String timeStr, DateTime baseDate) {
    timeStr = timeStr.trim().toUpperCase();
    int hour = 0;
    int minute = 0;

    if (timeStr.contains('AM') || timeStr.contains('PM')) {
      final parts = timeStr.split(' ');
      final timeParts = parts[0].split(':');
      hour = int.parse(timeParts[0]);
      minute = int.parse(timeParts[1]);
      if (timeStr.contains('PM') && hour < 12) hour += 12;
      if (timeStr.contains('AM') && hour == 12) hour = 0;
    } else {
      final timeParts = timeStr.split(':');
      hour = int.parse(timeParts[0]);
      minute = int.parse(timeParts[1]);
    }

    return DateTime(baseDate.year, baseDate.month, baseDate.day, hour, minute);
  }
}

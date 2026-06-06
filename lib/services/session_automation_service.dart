import 'dart:convert';
import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'foreground_task_handler.dart';

import 'package:flutter/widgets.dart';
import 'dart:developer' as developer;

// --- Background Task Entry Points (Top-level) ---

/// Called by AndroidAlarmManager when the session should START.
/// Instead of running BLE directly (which fails in background isolates),
/// we start a Foreground Service that has full plugin access.
@pragma('vm:entry-point')
void onSessionStart() async {
  WidgetsFlutterBinding.ensureInitialized();
  developer.log('ALARM TRIGGERED: onSessionStart called at ${DateTime.now()}', name: 'AutomationAlarm');
  print('BACKGROUND LOG: onSessionStart alarm triggered at ${DateTime.now()}');

  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  final isTestMode = prefs.getBool('is_test_mode') ?? false;
  final alarmKey = isTestMode ? 'test_session_alarm' : 'session_alarm';
  final alarmData = prefs.getString(alarmKey);
  if (alarmData == null) {
    print('BACKGROUND LOG: No alarm found for key $alarmKey. Aborting.');
    return;
  }

  final data = jsonDecode(alarmData);
  final activityName = data['activity_name'] ?? 'Session';

  // Mark as active
  data['status'] = 'active';
  await prefs.setString(alarmKey, jsonEncode(data));

  print('BACKGROUND LOG: Starting foreground service for $activityName (isTestMode: $isTestMode)');

  // Initialize the foreground task configuration
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

  // Start the foreground service
  final result = await FlutterForegroundTask.startService(
    serviceId: 300,
    notificationTitle: 'Starting: $activityName',
    notificationText: 'Initializing BLE mesh network...',
    notificationIcon: const NotificationIcon(
      metaDataName: 'com.pravera.flutter_foreground_task.NOTIFICATION_ICON',
    ),
    callback: startForegroundCallback,
  );

  print('BACKGROUND LOG: Foreground service start result: ${result}');
}

/// Called by AndroidAlarmManager when the session should END.
/// Stops the foreground service cleanly.
@pragma('vm:entry-point')
void onSessionEnd() async {
  WidgetsFlutterBinding.ensureInitialized();
  print('BACKGROUND LOG: onSessionEnd alarm triggered at ${DateTime.now()}');

  // Send stop command to the foreground service
  FlutterForegroundTask.sendDataToTask('stop');
  
  // Also stop the service directly as a fallback (give enough time for next session scheduling)
  await Future.delayed(const Duration(seconds: 30));
  await FlutterForegroundTask.stopService();

  print('BACKGROUND LOG: Foreground service stopped.');
}

class SessionAutomationService {
  static const String _alarmKey = 'session_alarm';
  static const int _startAlarmId = 1001;
  static const int _endAlarmId = 1002;

  Future<Map<String, dynamic>?> getActiveAlarm() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final isTestMode = prefs.getBool('is_test_mode') ?? false;
    final alarmKey = isTestMode ? 'test_session_alarm' : _alarmKey;
    final data = prefs.getString(alarmKey);
    if (data == null) return null;
    return jsonDecode(data);
  }

  Future<void> cancelAllSessions() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final isTestMode = prefs.getBool('is_test_mode') ?? false;
    final alarmKey = isTestMode ? 'test_session_alarm' : _alarmKey;
    await prefs.remove(alarmKey);
    await AndroidAlarmManager.cancel(_startAlarmId);
    await AndroidAlarmManager.cancel(_endAlarmId);
    
    // Also stop any running foreground service
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
  }

  Future<void> scheduleNextSessionIfNeeded(List<Map<String, dynamic>> tasks, String userId, bool isRoot) async {
    final prefs = await SharedPreferences.getInstance();
    
    // Check for existing/stale alarm
    if (prefs.containsKey(_alarmKey)) {
      final alarm = jsonDecode(prefs.getString(_alarmKey)!);
      final endTime = DateTime.tryParse(alarm['end_time'] ?? '');
      if (endTime != null && DateTime.now().isAfter(endTime)) {
        await prefs.remove(_alarmKey);
      } else {
        return; 
      }
    }

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

      await prefs.setString(_alarmKey, jsonEncode(alarmData));

      if (nextStartTime.isAfter(now)) {
        // Schedule START alarm
        developer.log('ALARM SCHEDULED: Start alarm set for $nextStartTime (Task: ${nextTask['activity_name']})', name: 'AutomationAlarm');
        print('Automation: Scheduling start alarm at $nextStartTime');
        await AndroidAlarmManager.oneShotAt(
          nextStartTime,
          _startAlarmId,
          onSessionStart,
          exact: true,
          wakeup: true,
          rescheduleOnReboot: true,
        );

        // Schedule END alarm (as a safety net to stop the foreground service)
        if (nextEndTime != null) {
          print('Automation: Scheduling end alarm at $nextEndTime');
          await AndroidAlarmManager.oneShotAt(
            nextEndTime,
            _endAlarmId,
            onSessionEnd,
            exact: true,
            wakeup: true,
            rescheduleOnReboot: true,
          );
        }
      } else {
        // Start immediately (session already in progress)
        print('Automation: Session already in progress, starting foreground service now.');
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

  Future<void> markAsNotified() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getString(_alarmKey);
    if (data == null) return;
    final map = jsonDecode(data);
    map['notified'] = true;
    await prefs.setString(_alarmKey, jsonEncode(map));
  }
}

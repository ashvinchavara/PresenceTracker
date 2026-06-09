import 'dart:convert';
import 'dart:ui';
import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'foreground_task_handler.dart';
import 'notification_service.dart';
import 'api_service.dart';
import 'log_service.dart';

import 'package:flutter/widgets.dart';

// --- Background Task Entry Points (Top-level) ---

/// Called by AndroidAlarmManager when the session should START.
/// Instead of running BLE directly (which fails in background isolates),
/// we start a Foreground Service that has full plugin access.
@pragma('vm:entry-point')
void onSessionStart() async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  await LogService.info('AlarmManager', 'onSessionStart alarm triggered at ${DateTime.now()}');

  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  final isTestMode = prefs.getBool('is_test_mode') ?? false;
  final alarmKey = isTestMode ? 'test_session_alarm' : 'session_alarm';
  final alarmData = prefs.getString(alarmKey);
  if (alarmData == null) {
    await LogService.warn('AlarmManager', 'No alarm found for key $alarmKey. Aborting.');
    return;
  }

  final data = jsonDecode(alarmData);
  final activityName = data['activity_name'] ?? 'Session';

  // Mark as active
  data['status'] = 'active';
  await prefs.setString(alarmKey, jsonEncode(data));

  await LogService.info('AlarmManager', 'Starting foreground service for $activityName (isTestMode: $isTestMode)');

  try {
    await LogService.info('AlarmManager', 'Initializing FlutterForegroundTask config...');
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

    await LogService.info('AlarmManager', 'Initializing Communication Port...');
    // Open the communication port
    FlutterForegroundTask.initCommunicationPort();

    await LogService.info('AlarmManager', 'Calling startService()...');
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

    await LogService.info('AlarmManager', 'Foreground service start result: $result');
  } catch (e, stackTrace) {
    await LogService.error('AlarmManager', 'CRITICAL ERROR starting Foreground Service: $e\n$stackTrace');
  }
}

/// Called by AndroidAlarmManager when the session should END.
/// Stops the foreground service cleanly AND schedules the next session.
@pragma('vm:entry-point')
void onSessionEnd() async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  await LogService.info('AlarmManager', 'onSessionEnd alarm triggered at ${DateTime.now()}');

  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  final isTestMode = prefs.getBool('is_test_mode') ?? false;
  final alarmKey = isTestMode ? 'test_session_alarm' : 'session_alarm';
  final alarmData = prefs.getString(alarmKey); // read BEFORE removing

  // Signal the running foreground service to stop cleanly
  FlutterForegroundTask.sendDataToTask('stop');
  await Future.delayed(const Duration(milliseconds: 500));

  // Force-stop the service as safety net
  await FlutterForegroundTask.stopService();

  // Clean up states in preferences
  await prefs.remove(alarmKey);
  await prefs.setBool('is_mesh_active', false);
  
  if (isTestMode) {
    await prefs.remove('test_mode_tasks');
    await prefs.remove('test_start_time');
    await prefs.remove('test_end_time');
    await prefs.setBool('is_test_mode', false);
  }

  // Clear any active session/alert notifications and notify user
  final notifications = NotificationService();
  await notifications.init();
  await notifications.cancel(100); // BT Alert ID
  await notifications.cancel(101); // Ongoing Session ID
  await notifications.cancel(104); // BLE Error ID
  await notifications.showAlert(
    isTestMode ? 'Test Session Ended' : 'Session Ended',
    'Attendance tracking has completed.',
  );

  // CHAIN: Schedule next session from the end alarm handler
  // This is the belt-and-suspenders path in case the foreground handler
  // was killed before its own _endTimer could fire.
  if (alarmData != null) {
    try {
      final data = jsonDecode(alarmData);
      final userId = data['user_id'].toString();
      final isRoot = isTestMode 
          ? (prefs.getBool('is_root_user') ?? false) 
          : (data['is_root'] == true);

      await LogService.info('AlarmManager', 'Scheduling next session after alarm end...');
      final api = ApiService();
      List<Map<String, dynamic>> tasks = await api.getCachedUserTimetableOffline();
      if (tasks.isEmpty) {
        tasks = await api.fetchUserTimetable(userId);
      }
      if (tasks.isNotEmpty) {
        final scheduler = SessionScheduler();
        await scheduler.scheduleNextFromForeground(tasks, userId, isRoot);
      }
    } catch (e) {
      await LogService.error('AlarmManager', 'Failed to schedule next session from onSessionEnd: $e');
    }
  }

  await LogService.info('AlarmManager', 'onSessionEnd complete.');
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
    
    // Check for existing alarm
    if (prefs.containsKey(_alarmKey)) {
      final alarm = jsonDecode(prefs.getString(_alarmKey)!);
      final status = alarm['status'];
      final endTime = DateTime.tryParse(alarm['end_time'] ?? '');
      
      if (status == 'active' && endTime != null && DateTime.now().isBefore(endTime)) {
        // A session is currently active. Do not interrupt it.
        return; 
      }
      
      // Otherwise, cancel the existing scheduled alarm to ensure a fresh schedule
      await AndroidAlarmManager.cancel(_startAlarmId);
      await AndroidAlarmManager.cancel(_endAlarmId);
      await prefs.remove(_alarmKey);
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
        await LogService.info('Scheduler', 'Scheduling start alarm at $nextStartTime (Task: ${nextTask['activity_name']})');
        try {
          await AndroidAlarmManager.oneShotAt(
            nextStartTime,
            _startAlarmId,
            onSessionStart,
            exact: true,
            wakeup: true,
            rescheduleOnReboot: true,
          );
        } catch (e) {
          await LogService.error('Scheduler', 'Failed to schedule exact start alarm: $e. Retrying with exact=false.');
          await AndroidAlarmManager.oneShotAt(
            nextStartTime,
            _startAlarmId,
            onSessionStart,
            exact: false,
            wakeup: true,
            rescheduleOnReboot: true,
          );
        }

        // Schedule END alarm (as a safety net to stop the foreground service)
        if (nextEndTime != null) {
          await LogService.info('Scheduler', 'Scheduling end alarm at $nextEndTime');
          try {
            await AndroidAlarmManager.oneShotAt(
              nextEndTime,
              _endAlarmId,
              onSessionEnd,
              exact: true,
              wakeup: true,
              rescheduleOnReboot: true,
            );
          } catch (e) {
            await LogService.error('Scheduler', 'Failed to schedule exact end alarm: $e. Retrying with exact=false.');
            await AndroidAlarmManager.oneShotAt(
              nextEndTime,
              _endAlarmId,
              onSessionEnd,
              exact: false,
              wakeup: true,
              rescheduleOnReboot: true,
            );
          }
        }
      } else {
        // Start immediately (session already in progress)
        await LogService.info('Scheduler', 'Session already in progress, starting foreground service now.');
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

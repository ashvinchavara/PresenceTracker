import 'dart:convert';
import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'ble_mesh_service.dart';
import 'api_service.dart';
import 'notification_service.dart';

// --- Background Task Entry Points (Top-level) ---

@pragma('vm:entry-point')
void onSessionStart() async {
  final prefs = await SharedPreferences.getInstance();
  final alarmData = prefs.getString('session_alarm');
  if (alarmData == null) return;

  final data = jsonDecode(alarmData);
  final taskId = data['task_id'].toString();
  final userId = data['user_id'].toString();
  final activityName = data['activity_name'] ?? 'Session';
  final role = data['is_root'] == true ? 'root' : 'leaf';

  // Start BLE Mesh Logic
  final bleService = BleMeshService();
  await bleService.initializeMeshNode(role, taskId, userId, activityName);

  // Update status to active
  data['status'] = 'active';
  await prefs.setString('session_alarm', jsonEncode(data));
  
  final endTime = DateTime.parse(data['end_time']);
  
  // 1. Schedule Pre-End Alarm (2 minutes before) for Upload
  final uploadTime = endTime.subtract(const Duration(minutes: 2));
  if (uploadTime.isAfter(DateTime.now())) {
    await AndroidAlarmManager.oneShotAt(
      uploadTime,
      1003,
      onPreEndUpload,
      exact: true,
      wakeup: true,
    );
  }

  // 2. Schedule Verification Alarm (1 minute before)
  final verifyTime = endTime.subtract(const Duration(minutes: 1));
  if (verifyTime.isAfter(DateTime.now())) {
    await AndroidAlarmManager.oneShotAt(
      verifyTime,
      1004,
      onVerificationCheck,
      exact: true,
      wakeup: true,
    );
  }

  // 3. Schedule Final End Alarm
  await AndroidAlarmManager.oneShotAt(
    endTime,
    1002,
    onSessionEnd,
    exact: true,
    wakeup: true,
  );
}

@pragma('vm:entry-point')
void onPreEndUpload() async {
  final bleService = BleMeshService();
  await bleService.uploadAttendance();
}

@pragma('vm:entry-point')
void onVerificationCheck() async {
  final bleService = BleMeshService();
  await bleService.verifyAttendance();
}

@pragma('vm:entry-point')
void onSessionEnd() async {
  final prefs = await SharedPreferences.getInstance();
  final alarmData = prefs.getString('session_alarm');
  if (alarmData == null) return;

  final data = jsonDecode(alarmData);
  final userId = data['user_id'].toString();
  final isRoot = data['is_root'] == true;

  final bleService = BleMeshService();
  await bleService.endMeshTask();

  // Clear current alarm
  await prefs.remove('session_alarm');

  // CHAINING: Schedule the next upcoming activity automatically
  print('Automation: Session ended. Scheduling next...');
  final api = ApiService();
  final tasks = await api.fetchUserTimetable(userId);
  final automation = SessionAutomationService();
  await automation.scheduleNextSessionIfNeeded(tasks, userId, isRoot);
}

class SessionAutomationService {
  static const String _alarmKey = 'session_alarm';
  static const int _startAlarmId = 1001;

  Future<Map<String, dynamic>?> getActiveAlarm() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getString(_alarmKey);
    if (data == null) return null;
    return jsonDecode(data);
  }

  Future<void> cancelAllSessions() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_alarmKey);
    await AndroidAlarmManager.cancel(_startAlarmId);
    await AndroidAlarmManager.cancel(1003); 
    await AndroidAlarmManager.cancel(1004); 
    await AndroidAlarmManager.cancel(1005); 
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

        final timeRange = task['time_range'] as String;
        final parts = timeRange.split(' - ');
        final start = _parseTime(parts[0], checkDate);
        final end = _parseTime(parts[1], checkDate);

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
        'status': 'scheduled',
      };

      await prefs.setString(_alarmKey, jsonEncode(alarmData));

      if (nextStartTime.isAfter(now)) {
        await AndroidAlarmManager.oneShotAt(
          nextStartTime,
          _startAlarmId,
          onSessionStart,
          exact: true,
          wakeup: true,
          rescheduleOnReboot: true,
        );
      } else {
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

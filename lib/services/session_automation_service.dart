import 'dart:convert';
import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'ble_mesh_service.dart';
import 'api_service.dart';
import '../providers/node_role_provider.dart';

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

  // Start BLE
  final bleService = BleMeshService();
  await bleService.initializeMeshNode(role, taskId, userId, activityName);

  // Update state to Active
  data['status'] = 'active';
  await prefs.setString('session_alarm', jsonEncode(data));
  
  // Schedule End Alarm
  final endTime = DateTime.parse(data['end_time']);
  await AndroidAlarmManager.oneShotAt(
    endTime,
    1002, // _endAlarmId
    onSessionEnd,
    exact: true,
    wakeup: true,
  );
}

@pragma('vm:entry-point')
void onSessionEnd() async {
  final prefs = await SharedPreferences.getInstance();
  final alarmData = prefs.getString('session_alarm');
  if (alarmData == null) return;

  final data = jsonDecode(alarmData);
  final role = data['is_root'] == true ? 'root' : 'leaf';

  // End BLE
  final bleService = BleMeshService();
  await bleService.endMeshTask(role);

  // Clear alarm
  await prefs.remove('session_alarm');
}

class SessionAutomationService {
  static const String _alarmKey = 'session_alarm';
  static const int _startAlarmId = 1001;
  static const int _endAlarmId = 1002;

  // --- Instance Methods ---

  Future<Map<String, dynamic>?> getActiveAlarm() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getString(_alarmKey);
    if (data == null) return null;
    return jsonDecode(data);
  }

  Future<void> scheduleNextSessionIfNeeded(List<Map<String, dynamic>> tasks, String userId, bool isRoot) async {
    print('Automation: scheduleNextSessionIfNeeded called with ${tasks.length} tasks');
    final prefs = await SharedPreferences.getInstance();
    if (prefs.containsKey(_alarmKey)) {
      print('Automation: Alarm already exists in SharedPreferences.');
      return; 
    }

    if (tasks.isEmpty) {
      print('Automation: Tasks list is empty.');
      return;
    }

    // Find immediate upcoming task across next 7 days
    final now = DateTime.now();
    final dayNames = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    
    Map<String, dynamic>? nextTask;
    DateTime? nextStartTime;
    DateTime? nextEndTime;

    print('Automation: Searching for next task starting from $now');

    for (int dayOffset = 0; dayOffset < 7; dayOffset++) {
      final checkDate = now.add(Duration(days: dayOffset));
      final dayName = dayNames[checkDate.weekday - 1];
      print('Automation: Checking $dayName (+ $dayOffset days)');

      DateTime? bestOnThisDay;
      Map<String, dynamic>? taskOnThisDay;
      DateTime? endOnThisDay;

      for (var task in tasks) {
        final days = (task['day_of_week'] as String?)?.split(',') ?? [];
        if (!days.contains(dayName)) continue;

        final timeRange = task['time_range'] as String;
        final parts = timeRange.split(' - ');
        final start = _parseTime(parts[0], checkDate);
        final end = _parseTime(parts[1], checkDate);

        // Case 1: Task is in the future
        if (start.isAfter(now)) {
          if (bestOnThisDay == null || start.isBefore(bestOnThisDay)) {
            bestOnThisDay = start;
            endOnThisDay = end;
            taskOnThisDay = task;
          }
        } 
        // Case 2: Task is happening RIGHT NOW
        else if (now.isAfter(start) && now.isBefore(end)) {
          print('Automation: Found task happening NOW: ${task['activity_name']}');
          nextTask = task;
          nextStartTime = start;
          nextEndTime = end;
          break; // Stop everything, run this now
        }
      }

      if (nextTask != null) break; // Found immediate active task

      if (bestOnThisDay != null) {
        nextTask = taskOnThisDay;
        nextStartTime = bestOnThisDay;
        nextEndTime = endOnThisDay;
        break; // Found the earliest future task
      }
    }

    if (nextTask != null && nextStartTime != null) {
      print('Automation: Next task selected: ${nextTask['activity_name']} at $nextStartTime');
      final alarmData = {
        'task_id': nextTask['id'],
        'user_id': userId,
        'activity_name': nextTask['activity_name'],
        'start_time': nextStartTime.toIso8601String(),
        'end_time': nextEndTime?.toIso8601String(),
        'is_root': isRoot,
        'status': 'scheduled',
        'notified': false,
      };

      await prefs.setString(_alarmKey, jsonEncode(alarmData));

      // Schedule Start Alarm
      if (nextStartTime.isAfter(now)) {
        print('Automation: Scheduling background alarm for $nextStartTime');
        try {
          final success = await AndroidAlarmManager.oneShotAt(
            nextStartTime,
            _startAlarmId,
            onSessionStart,
            exact: true,
            wakeup: true,
            rescheduleOnReboot: true,
          );
          print('Automation: oneShotAt result: $success');
        } catch (e) {
          print('Automation: oneShotAt ERROR: $e');
        }
      } else {
        // Already started? Run now
        print('Automation: Session already started, triggering immediately.');
        onSessionStart();
      }
    } else {
      print('Automation: No immediate upcoming tasks found for today.');
    }
  }

  DateTime _parseTime(String timeStr, DateTime baseDate) {
    // timeStr is like "10:30 AM" or "22:30"
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

    return DateTime(
      baseDate.year,
      baseDate.month,
      baseDate.day,
      hour,
      minute,
    );
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

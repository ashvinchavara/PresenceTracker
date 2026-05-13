import 'dart:convert';
import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'ble_mesh_service.dart';
import 'api_service.dart';
import '../providers/node_role_provider.dart';

class SessionAutomationService {
  static const String _alarmKey = 'session_alarm';
  static const int _startAlarmId = 1001;
  static const int _endAlarmId = 1002;

  // --- Background Task Entry Points ---
  
  @pragma('vm:entry-point')
  static void onSessionStart() async {
    final prefs = await SharedPreferences.getInstance();
    final alarmData = prefs.getString(_alarmKey);
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
    await prefs.setString(_alarmKey, jsonEncode(data));
    
    // Schedule End Alarm
    final endTime = DateTime.parse(data['end_time']);
    await AndroidAlarmManager.oneShotAt(
      endTime,
      _endAlarmId,
      onSessionEnd,
      exact: true,
      wakeup: true,
    );
  }

  @pragma('vm:entry-point')
  static void onSessionEnd() async {
    final prefs = await SharedPreferences.getInstance();
    final alarmData = prefs.getString(_alarmKey);
    if (alarmData == null) return;

    final data = jsonDecode(alarmData);
    final role = data['is_root'] == true ? 'root' : 'leaf';

    // End BLE
    final bleService = BleMeshService();
    await bleService.endMeshTask(role);

    // Clear alarm or set to completed
    await prefs.remove(_alarmKey);
    
    // The UI or app-start logic will pick up the next session
  }

  // --- Instance Methods ---

  Future<Map<String, dynamic>?> getActiveAlarm() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getString(_alarmKey);
    if (data == null) return null;
    return jsonDecode(data);
  }

  Future<void> scheduleNextSessionIfNeeded(List<Map<String, dynamic>> tasks, String userId, bool isRoot) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.containsKey(_alarmKey)) return; // Already scheduled

    if (tasks.isEmpty) return;

    // Find immediate upcoming task
    // (This logic should ideally find the first task starting AFTER now)
    final now = DateTime.now();
    Map<String, dynamic>? nextTask;
    DateTime? nextStartTime;
    DateTime? nextEndTime;

    final dayNames = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    final todayName = dayNames[now.weekday - 1];

    for (var task in tasks) {
      if (task['day_of_week'] != todayName) continue;
      
      final timeRange = task['time_range'] as String; // "HH:mm - HH:mm"
      final parts = timeRange.split(' - ');
      final startStr = parts[0];
      final endStr = parts[1];

      final start = _parseTime(startStr, now);
      final end = _parseTime(endStr, now);

      if (start.isAfter(now)) {
        if (nextStartTime == null || start.isBefore(nextStartTime)) {
          nextStartTime = start;
          nextEndTime = end;
          nextTask = task;
        }
      } else if (now.isAfter(start) && now.isBefore(end)) {
          // Current session? Trigger it immediately if not already tracking
          nextStartTime = start;
          nextEndTime = end;
          nextTask = task;
          break;
      }
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
        'notified': false, // To handle the one-time popup
      };

      await prefs.setString(_alarmKey, jsonEncode(alarmData));

      // Schedule Start Alarm
      if (nextStartTime.isAfter(now)) {
        await AndroidAlarmManager.oneShotAt(
          nextStartTime,
          _startAlarmId,
          onSessionStart,
          exact: true,
          wakeup: true,
        );
      } else {
        // Already started? Run now
        onSessionStart();
      }
    }
  }

  DateTime _parseTime(String timeStr, DateTime baseDate) {
    final parts = timeStr.split(':');
    return DateTime(
      baseDate.year,
      baseDate.month,
      baseDate.day,
      int.parse(parts[0]),
      int.parse(parts[1]),
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

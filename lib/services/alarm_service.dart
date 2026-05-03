import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import '../../models/user_node.dart';
import '../services/ble_mesh_service.dart';

class AlarmService {
  static final BleMeshService _bleMeshService = BleMeshService();

  /// Starts the Alarm Manager
  static Future<void> initialize() async {
    await AndroidAlarmManager.initialize();
  }

  /// Parses a time range like "09:00 - 11:00" and schedules alarms for today
  static void scheduleTaskAlarms(List<Map<String, dynamic>> tasks, UserNode currentUser, bool canUpload) async {
    for (var task in tasks) {
      if (task['time_range'] == null) continue;
      
      String timeRange = task['time_range'];
      List<String> times = timeRange.split('-');
      if (times.length != 2) continue;

      try {
        DateTime now = DateTime.now();
        DateTime startTime = _parseTimeString(times[0].trim(), now);
        DateTime endTime = _parseTimeString(times[1].trim(), now);

        // Check if task is still in the future or currently ongoing
        if (endTime.isAfter(now)) {
           // We use task ID as the base for the Alarm ID. 
           // Start Alarm ID: taskId * 10 
           // End Alarm ID: (taskId * 10) + 1
           int taskId = int.tryParse(task['id'].toString()) ?? task.hashCode;
           int startAlarmId = taskId * 10;
           int endAlarmId = startAlarmId + 1;
           int syncAlarmId = startAlarmId + 2;

           // Calculate the role based on dynamic upload power
           String role = canUpload ? 'root' : 'leaf';
           String taskName = task['activity_name'] ?? 'Session';

           // Schedule Start
           if (startTime.isAfter(now)) {
             await AndroidAlarmManager.oneShotAt(
                startTime,
                startAlarmId,
                bleTaskCallbackStart,
                exact: true,
                wakeup: true,
                params: {'role': role, 'taskId': taskId.toString(), 'userId': currentUser.id},
             );
           } else {
             // Already started, start immediately
             _bleMeshService.initializeMeshNode(role, taskId.toString(), currentUser.id, taskName);
           }

           // Schedule End
           await AndroidAlarmManager.oneShotAt(
              endTime,
              endAlarmId,
              bleTaskCallbackEnd,
              exact: true,
              wakeup: true,
              params: {'role': role, 'taskId': taskId.toString(), 'userId': currentUser.id, 'taskName': taskName},
           );

           // Schedule Sync (5 mins before end)
           DateTime syncTime = endTime.subtract(const Duration(minutes: 5));
           if (syncTime.isAfter(now)) {
              await AndroidAlarmManager.oneShotAt(
                 syncTime,
                 syncAlarmId,
                 bleTaskCallbackSync,
                 exact: true,
                 wakeup: true,
                 params: {'role': role, 'taskId': taskId.toString(), 'userId': currentUser.id, 'taskName': taskName},
              );
           }
        }
      } catch (e) {
        print("Failed to schedule task $task: $e");
      }
    }
  }

  /// Background callback for starting a task
  @pragma('vm:entry-point')
  static void bleTaskCallbackStart(int id, Map<String, dynamic> params) {
    String role = params['role'] ?? 'leaf';
    String taskId = params['taskId'] ?? '0';
    String userId = params['userId'] ?? 'unknown';
    String taskName = params['taskName'] ?? 'Session';
    
    _bleMeshService.initializeMeshNode(role, taskId, userId, taskName);
  }

  /// Background callback for sync (5 mins before end)
  @pragma('vm:entry-point')
  static void bleTaskCallbackSync(int id, Map<String, dynamic> params) {
    String role = params['role'] ?? 'leaf';
    String taskName = params['taskName'] ?? 'Session';
    _bleMeshService.syncAndNotify(role, taskName);
  }

  /// Background callback for ending a task
  @pragma('vm:entry-point')
  static void bleTaskCallbackEnd(int id, Map<String, dynamic> params) {
    String role = params['role'] ?? 'leaf';
    _bleMeshService.endMeshTask(role);
  }

  /// Helper to parse time strings like "10:00 AM" or "14:30"
  static DateTime _parseTimeString(String timeStr, DateTime now) {
    bool isPM = timeStr.toUpperCase().contains('PM');
    bool isAM = timeStr.toUpperCase().contains('AM');
    
    // Remove AM/PM for numerical parsing
    String cleanTime = timeStr.toUpperCase().replaceAll('AM', '').replaceAll('PM', '').trim();
    List<String> parts = cleanTime.split(':');
    
    int hour = int.parse(parts[0]);
    int minute = parts.length > 1 ? int.parse(parts[1]) : 0;
    
    if (isPM && hour < 12) hour += 12;
    if (isAM && hour == 12) hour = 0;
    
    return DateTime(now.year, now.month, now.day, hour, minute);
  }
}

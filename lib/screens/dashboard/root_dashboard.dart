import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';
import 'package:percent_indicator/circular_percent_indicator.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import '../../providers/node_role_provider.dart';
import '../../providers/theme_provider.dart';
import '../../services/api_service.dart';
import '../../services/api_service.dart';
import '../auth/auth_screen.dart';
import './attendance_history_screen.dart';
import './full_timetable_screen.dart';
import './system_diagnostics_screen.dart';
import '../../services/ble_mesh_service.dart';
import '../../services/session_automation_service.dart';
import '../../services/foreground_task_handler.dart';
import '../../core/api_config.dart';
import '../../services/test_service.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../services/notification_service.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';


class RootDashboard extends StatefulWidget {
  const RootDashboard({super.key});

  @override
  State<RootDashboard> createState() => _RootDashboardState();
}

class _RootDashboardState extends State<RootDashboard> with WidgetsBindingObserver {
  final ApiService _apiService = ApiService();
  
  double _attendancePercentage = 0.0;
  List<Map<String, dynamic>> _upcomingTasks = [];
  List<Map<String, dynamic>> _summaryData = [];
  String _displayDay = 'Today';
  bool _isLoading = true;
  bool _isSyncing = false;

  // --- MESH & AUTOMATION STATE ---
  bool _isMeshActive = false;
  String _meshTaskId = '';
  Map<String, Map<String, int>> _rootAggregatedData = {};
  Map<String, dynamic>? _currentAlarm;
  Map<String, dynamic>? _absentAlarm;
  List<String> _leaveTaskIds = [];
  Timer? _uiSyncTimer;
  StreamSubscription<BluetoothAdapterState>? _btStateSubscription;
  Timer? _btMonitoringTimer;

  // --- CONNECTIVITY STATE ---
  bool _isConnected = true;
  String _dbMode = 'cloud';
  bool _hasAutoShownDialog = false;
  bool _isDialogShowing = false;
  Timer? _healthCheckTimer;

  // --- TEST MODE STATE ---
  String _testStage = 'none'; // 'none', 'waiting', 'active', 'uploading', 'verifying', 'finished'
  int _testCountdown = 0;
  Timer? _testTimer;
  List<Map<String, dynamic>> _testActivities = [];
  final SessionAutomationService _automationService = SessionAutomationService();

  // Legacy simulation variables (mapped to test mode)
  String get _simStage => _testStage;
  int get _simCountdown => _testCountdown;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _fetchDashboardData();
    _startHealthPolling();
    _requestPermissions();
    _initForegroundService();
    _initNotifications();
    _startBluetoothMonitoring();
    FlutterForegroundTask.addTaskDataCallback(_onReceiveForegroundData);
    _uiSyncTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      _loadMeshState();
    });
    _testTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _updateTestModeTimer();
    });
  }

  void _initNotifications() {
    // Initialize the notification service in the main isolate so BT alerts work
    final notifService = NotificationService();
    notifService.init().then((_) {
      // Register tap handler: tapping the ongoing notification opens the tracker
      notifService.setOngoingTapCallback(() {
        if (mounted) _showActiveMeshDetails();
      });
      notifService.setNotificationTapCallback((response) {
        if (mounted) {
          _handleNotificationResponse(response);
        }
      });
    });
  }

  void _handleNotificationResponse(NotificationResponse response) async {
    final payload = response.payload;
    final actionId = response.actionId;
    print('Dashboard: Handling notification response: actionId=$actionId, payload=$payload');

    if (actionId == 'enable_bluetooth' || payload == 'bt_off') {
      try {
        final state = await FlutterBluePlus.adapterState.first;
        if (state == BluetoothAdapterState.on || state == BluetoothAdapterState.turningOn) {
          print('Dashboard: Bluetooth is already ON or turning ON. Skipping.');
          return;
        }
        await FlutterBluePlus.turnOn();
      } catch (e) {
        print('Dashboard: Error enabling Bluetooth from notification: $e');
      }
    } else if (payload == 'ongoing') {
      _showActiveMeshDetails();
    } else if (payload == 'mismatch') {
      _showMismatchDetailsDialog();
    } else if (payload == 'absent' || actionId == 'restart_attendance') {
      _loadMeshState();
    }
  }

  void _showMismatchDetailsDialog() async {
    final prefs = await SharedPreferences.getInstance();
    final mismatchJson = prefs.getString('mismatch_details');
    if (mismatchJson == null) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text("Attendance Verification"),
          content: const Text("No mismatch details found or they have been resolved."),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("OK")),
          ],
        ),
      );
      return;
    }

    List<dynamic> details = [];
    try {
      details = jsonDecode(mismatchJson);
    } catch (_) {}

    if (details.isEmpty) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text("Attendance Verification"),
          content: const Text("No mismatch details found."),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("OK")),
          ],
        ),
      );
      return;
    }

    int currentIndex = 0;

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setState) {
            final item = details[currentIndex];
            final String name = item['full_name'] ?? 'Unknown User';
            final String userId = item['user_id'] ?? 'Unknown ID';
            final String type = item['type'] ?? 'missing';
            final String reason = item['detail'] ?? '';

            return AlertDialog(
              title: Row(
                children: [
                  Icon(
                    type == 'missing' ? Icons.person_off : Icons.history_toggle_off,
                    color: Colors.red,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      type == 'missing' ? "Missing Record" : "Stale Record",
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  Text(
                    "ID: $userId",
                    style: TextStyle(color: Theme.of(context).textTheme.bodySmall?.color),
                  ),
                  const SizedBox(height: 15),
                  Text(
                    reason,
                    style: const TextStyle(fontSize: 14),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    "Item ${currentIndex + 1} of ${details.length}",
                    style: TextStyle(fontSize: 12, color: Theme.of(context).textTheme.bodySmall?.color),
                  ),
                ],
              ),
              actions: [
                if (currentIndex > 0)
                  TextButton(
                    onPressed: () {
                      setState(() {
                        currentIndex--;
                      });
                    },
                    child: const Text("Previous"),
                  ),
                if (currentIndex < details.length - 1)
                  ElevatedButton(
                    onPressed: () {
                      setState(() {
                        currentIndex++;
                      });
                    },
                    child: const Text("Next"),
                  )
                else
                  ElevatedButton(
                    onPressed: () {
                      Navigator.pop(ctx);
                    },
                    child: const Text("Close"),
                  ),
              ],
            );
          },
        );
      },
    );
  }

  void _initForegroundService() {
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
        eventAction: ForegroundTaskEventAction.repeat(10000),
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowWifiLock: true,
        stopWithTask: false,
      ),
    );
  }

  void _onReceiveForegroundData(Object data) {
    print('Dashboard: Received data from foreground service: $data');
    if (!mounted) return;
    if (data == 'bt_alert' || data == 'bt_alert_clear') {
      // Handled directly by BleMeshService/ForegroundTaskHandler background watchdogs
      _loadMeshState();
    } else {
      _loadMeshState();
    }
  }

  void _updateTestModeTimer() async {
    if (!mounted) return;
    final userProvider = Provider.of<NodeRoleProvider>(context, listen: false);
    if (!userProvider.isTestMode) return;

    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();

    final isTestModeInPrefs = prefs.getBool('is_test_mode') ?? false;
    if (!isTestModeInPrefs) {
      print('Dashboard: Test mode turned off in SharedPreferences. Restoring normal state...');
      userProvider.setTestMode(false);
      await _loadMeshState();
      _fetchDashboardData();
      return;
    }

    final now = DateTime.now();

    final alarm = await SessionAutomationService().getActiveAlarm();
    if (!mounted) return;
    _currentAlarm = alarm;

    if (_currentAlarm != null) {
      String status = _currentAlarm!['status'] ?? 'scheduled';
      
      if (status == 'scheduled') {
         final start = DateTime.tryParse(_currentAlarm!['start_time']) ?? now;
         _testStage = 'waiting';
         _testCountdown = start.difference(now).inSeconds;
         
         if (_testCountdown <= 0) {
           _testStage = 'transitioning';
           _testCountdown = 0;
         }
      } else if (status == 'active') {
         final end = DateTime.tryParse(_currentAlarm!['end_time']) ?? now;
         _testStage = 'active';
         _testCountdown = end.difference(now).inSeconds;
         
         if (_testCountdown <= 0) {
           _testStage = 'transitioning';
           _testCountdown = 0;
         }
      } else {
         _testStage = 'finished';
         _testCountdown = 0;
      }
    } else {
      final testStartTimeStr = prefs.getString('test_start_time');
      if (testStartTimeStr != null) {
        final start = DateTime.tryParse(testStartTimeStr) ?? now;
        _testStage = 'waiting';
        _testCountdown = start.difference(now).inSeconds;
        if (_testCountdown <= 0) {
          _testStage = 'transitioning';
          _testCountdown = 0;
        }
      } else {
        _testStage = 'finished';
        _testCountdown = 0;
      }
    }
    
    if (_testCountdown < 0) _testCountdown = 0;
    setState(() {});
  }

  Future<void> _requestPermissions() async {
    // Request critical permissions for background operations
    Map<Permission, PermissionStatus> statuses = await [
      Permission.notification,
      Permission.bluetoothScan,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.location,
      Permission.scheduleExactAlarm,
    ].request();

    // Trigger explicit notification permission request via the service
    await NotificationService().requestPermissions();
    
    if (statuses[Permission.location]?.isGranted ?? false) {
      await Permission.locationAlways.request();
    }
    
    if (statuses[Permission.notification]?.isPermanentlyDenied ?? false) {
      print('Dashboard: Notification permission permanently denied. Opening settings.');
      await openAppSettings();
    } else if (statuses[Permission.notification]?.isDenied ?? false) {
      print('Dashboard: Notification permission denied');
    }
    
    // Also check battery optimization
    if (await Permission.ignoreBatteryOptimizations.isDenied) {
      await Permission.ignoreBatteryOptimizations.request();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _uiSyncTimer?.cancel();
    _testTimer?.cancel();
    _healthCheckTimer?.cancel();
    _btStateSubscription?.cancel();
    _btMonitoringTimer?.cancel();
    FlutterForegroundTask.removeTaskDataCallback(_onReceiveForegroundData);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      print('Dashboard: App resumed, re-checking data and automation...');
      _fetchDashboardData();
      _loadMeshState();
    }
  }

  void _startBluetoothMonitoring() {
    // Check BT state immediately on app open
    FlutterBluePlus.adapterState.first.then((state) {
      if (state != BluetoothAdapterState.on && _isMeshActive) {
        print('Dashboard: Init - Bluetooth is OFF, background service will handle notification.');
      }
    });

    // Periodically monitor Bluetooth every 10 seconds if BT is off
    _btMonitoringTimer?.cancel();
    _btMonitoringTimer = Timer.periodic(const Duration(seconds: 10), (timer) async {
      if (!_isMeshActive) return;
      final state = await FlutterBluePlus.adapterState.first;
      if (state != BluetoothAdapterState.on) {
        print('Dashboard: Periodic - Bluetooth is OFF');
      }
    });

    // Continuously listen for BT state changes
    _btStateSubscription = FlutterBluePlus.adapterState.listen((state) {
      if (state != BluetoothAdapterState.on) {
        if (!_isMeshActive) return;
        print('Dashboard: Bluetooth is OFF');
      } else {
        print('Dashboard: Bluetooth is ON');
      }
    });
  }

  Future<void> _loadMeshState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    bool active = prefs.getBool('is_mesh_active') ?? false;
    String tId = prefs.getString('mesh_task_id') ?? '';
    
    Map<String, Map<String, int>> aggData = {};
    String aggStr = prefs.getString('root_aggregated_data') ?? '';
    if (aggStr.isNotEmpty) {
      try {
        Map<String, dynamic> decoded = jsonDecode(aggStr);
        decoded.forEach((k, v) {
           aggData[k] = {
             'first_view': v['first_view'],
             'last_view': v['last_view'],
           };
        });
      } catch (e) {}
    }

    Map<String, dynamic>? alarm = await _automationService.getActiveAlarm();
    print('Dashboard: Loaded alarm: $alarm');
    
    final leaveIds = prefs.getStringList('leave_task_ids') ?? [];
    
    if (mounted) {
      setState(() {
        _isMeshActive = active;
        _meshTaskId = tId;
        _rootAggregatedData = aggData;
        _currentAlarm = alarm;
        _leaveTaskIds = leaveIds;
      });
      
      if (!active) {
        NotificationService().cancel(100);
      }
      
      if (alarm != null && (alarm['notified'] ?? false) == false) {
        _showAlarmPopup(alarm);
      }
    }
  }

  void _startTestMode() async {
    final userProvider = Provider.of<NodeRoleProvider>(context, listen: false);
    userProvider.setTestMode(true);
    await Future.delayed(const Duration(milliseconds: 500));
    await _loadMeshState();
    _fetchDashboardData();
  }

  void _endTestMode() async {
    final userProvider = Provider.of<NodeRoleProvider>(context, listen: false);
    userProvider.setTestMode(false);
    
    // Stop automation and foreground service
    final automation = SessionAutomationService();
    await automation.cancelAllSessions();
    
    // Force reset mesh active state
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('is_mesh_active', false);
    
    // Clear any lingering bluetooth alert notifications
    NotificationService().cancel(100);
    
    await _loadMeshState();
    _fetchDashboardData();
  }

  void _skipTestPhase() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final testAlarmStr = prefs.getString('test_session_alarm');
    final userProvider = Provider.of<NodeRoleProvider>(context, listen: false);
    final now = DateTime.now();
    final testEndTime = now.add(const Duration(minutes: 2));

    Map<String, dynamic> testAlarm;
    if (testAlarmStr != null) {
      testAlarm = jsonDecode(testAlarmStr);
    } else {
      testAlarm = {
        'task_id': 9901,
        'user_id': userProvider.currentUserNode?.id.toString() ?? '',
        'activity_name': 'Test Activity',
        'start_time': now.toIso8601String(),
        'end_time': testEndTime.toIso8601String(),
        'is_root': true,
        'is_test': true,
        'status': 'active',
      };
    }

    // Cancel pending start alarm (alarm 1001)
    await AndroidAlarmManager.cancel(1001);

    // Update test_session_alarm in preferences to reflect running state
    testAlarm['start_time'] = now.toIso8601String();
    testAlarm['end_time'] = testEndTime.toIso8601String();
    testAlarm['status'] = 'active';

    await prefs.setString('test_session_alarm', jsonEncode(testAlarm));
    await prefs.setString('test_start_time', now.toIso8601String());
    await prefs.setString('test_end_time', testEndTime.toIso8601String());

    // Schedule test END alarm (alarm 1002) exactly 2 minutes from now
    print('Dashboard: Skip clicked. Scheduling test END alarm at $testEndTime');
    await AndroidAlarmManager.oneShotAt(
      testEndTime,
      1002, // _endAlarmId
      onSessionEnd,
      exact: true,
      wakeup: true,
      rescheduleOnReboot: true,
    );

    // Immediately trigger start flow
    onSessionStart();

    // Refresh dashboard UI state
    await Future.delayed(const Duration(milliseconds: 500));
    await _loadMeshState();
    _updateTestModeTimer();
  }

  Future<void> _fetchDashboardData() async {
    final userProvider = Provider.of<NodeRoleProvider>(context, listen: false);
    final userId = userProvider.currentUserNode?.id ?? 'unknown';
    final prefs = await SharedPreferences.getInstance();

    // 1. Load cached data to display instantly
    final cachedStats = prefs.getDouble('cached_stats_$userId');
    final cachedTasksStr = prefs.getString('cached_tasks_$userId');
    final cachedSummaryStr = prefs.getString('cached_summary_$userId');

    if (cachedStats != null || cachedTasksStr != null || cachedSummaryStr != null) {
      if (mounted) {
        setState(() {
          if (cachedStats != null) _attendancePercentage = cachedStats;
          if (cachedTasksStr != null) {
            try {
              final List<dynamic> decodedTasks = jsonDecode(cachedTasksStr);
              _processUpcomingTasks(decodedTasks.cast<Map<String, dynamic>>());
            } catch (_) {}
          }
          if (cachedSummaryStr != null) {
            try {
              final List<dynamic> decodedSummary = jsonDecode(cachedSummaryStr);
              _summaryData = decodedSummary.cast<Map<String, dynamic>>();
            } catch (_) {}
          }
          _isLoading = false;
        });
      }
    } else {
      // No cached data exists: set loading to false so dashboard opens instantly (empty state)
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }

    // 2. Start asynchronous network sync in the background
    if (mounted) {
      setState(() {
        _isSyncing = true;
      });
    }

    try {
      print('Dashboard: Fetching background updates for user $userId');
      final results = await Future.wait([
        _apiService.fetchDashboardStats(userId),
        _apiService.fetchUserTimetable(userId),
        _apiService.fetchAttendanceSummary(userId),
      ]).timeout(const Duration(seconds: 15));

      final percentage = results[0] as double;
      final tasks = List<Map<String, dynamic>>.from(results[1] as List);
      final summary = List<Map<String, dynamic>>.from(results[2] as List);
      print('Dashboard: Background fetch completed. Received ${tasks.length} tasks');

      // Update offline database cache
      await prefs.setDouble('cached_stats_$userId', percentage);
      await prefs.setString('cached_tasks_$userId', jsonEncode(tasks));
      await prefs.setString('cached_summary_$userId', jsonEncode(summary));

      if (mounted) {
        setState(() {
          _attendancePercentage = percentage;
          _summaryData = summary;
          _processUpcomingTasks(tasks);
        });

        // Background session automation check
        if (userProvider.currentUserNode != null) {
          await _automationService.scheduleNextSessionIfNeeded(
            tasks, 
            userProvider.currentUserNode!.id, 
            userProvider.canUpload
          );
          _loadMeshState();
        }
      }
    } catch (e) {
      print('Dashboard: Background sync failed/offline: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isSyncing = false;
        });
      }
    }
  }

  double _getActivityPercentage(String? activityName) {
    if (activityName == null) return 0.0;
    final item = _summaryData.firstWhere(
      (s) => s['activity_name'] == activityName,
      orElse: () => {},
    );
    if (item.isEmpty) return 0.0;
    final int total = item['total_sessions'] ?? 0;
    final int present = item['user_present'] ?? 0;
    return total > 0 ? present / total : 0.0;
  }

  void _startHealthPolling() {
    // Initial check
    _apiService.checkHealth().then((connected) async {
      final mode = connected ? await _apiService.fetchDbStatus() : 'offline';
      if (mounted) {
        setState(() {
          _isConnected = connected;
          _dbMode = mode;
          if (connected) _hasAutoShownDialog = false;
        });
        if (!connected && !_hasAutoShownDialog) {
          _hasAutoShownDialog = true;
          _showSettingsDialog();
        }
      }
    });
    
    // Poll every 10 seconds
    _healthCheckTimer = Timer.periodic(const Duration(seconds: 10), (timer) async {
      final connected = await _apiService.checkHealth();
      final mode = connected ? await _apiService.fetchDbStatus() : 'offline';
      if (mounted) {
        setState(() {
          _isConnected = connected;
          _dbMode = mode;
          if (connected) _hasAutoShownDialog = false;
        });
        if (!connected && !_isDialogShowing && !_hasAutoShownDialog) {
          _hasAutoShownDialog = true;
          _showSettingsDialog();
        }
      }
    });
  }

  void _showAlarmPopup(Map<String, dynamic> alarm) {
    _automationService.markAsNotified();
    final startTime = DateTime.parse(alarm['start_time']);
    final timeStr = "${startTime.hour.toString().padLeft(2, '0')}:${startTime.minute.toString().padLeft(2, '0')}";
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF0078D4),
        duration: const Duration(seconds: 4),
        content: Row(
          children: [
            const Icon(Icons.alarm_on, color: Colors.white),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                "Automation Set: ${alarm['activity_name']} at $timeStr",
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showSettingsDialog() {
    if (_isDialogShowing) return;
    _isDialogShowing = true;

    final TextEditingController ipController = TextEditingController(text: ApiConfig.currentIp);
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Connection Settings'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Select connection mode:'),
              const SizedBox(height: 15),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: ApiConfig.isCloudMode ? const Color(0xFF0078D4) : Colors.grey,
                      ),
                      onPressed: () {
                        setState(() => ApiConfig.isCloudMode = true);
                      },
                      child: const Text('Cloud (Primary)'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: !ApiConfig.isCloudMode ? const Color(0xFF0078D4) : Colors.grey,
                      ),
                      onPressed: () {
                        setState(() => ApiConfig.isCloudMode = false);
                      },
                      child: const Text('Local Fallback'),
                    ),
                  ),
                ],
              ),
              if (!ApiConfig.isCloudMode) ...[
                const SizedBox(height: 20),
                const Text('Enter Local Backend IP:'),
                const SizedBox(height: 10),
                TextField(
                  controller: ipController,
                  decoration: const InputDecoration(
                    labelText: 'Local IPv4',
                    hintText: 'e.g., 192.168.1.7',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx), 
              child: const Text('Cancel')
            ),
            ElevatedButton(
              onPressed: () async {
                if (ApiConfig.isCloudMode) {
                  await ApiConfig.switchToCloud();
                } else {
                  await ApiConfig.switchToLocal(ipController.text.trim());
                }
                
                if (mounted) {
                  Navigator.pop(ctx);
                  final connected = await _apiService.checkHealth();
                  this.setState(() => _isConnected = connected);
                  if (connected) _fetchDashboardData();
                }
              },
              child: const Text('Connect & Save'),
            ),
          ],
        ),
      ),
    ).then((_) => _isDialogShowing = false);
  }

  void _processUpcomingTasks(List<Map<String, dynamic>> tasks) {
    if (tasks.isEmpty) {
      _upcomingTasks = [];
      _displayDay = 'None';
      return;
    }

    final now = DateTime.now();

    final dayNames = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    final todayName = dayNames[now.weekday - 1];

    // Helper to sort tasks chronologically
    int toMinutes(String? timeStr) {
      if (timeStr == null) return 0;
      timeStr = timeStr.trim().toUpperCase();
      final parts = timeStr.split(' ');
      final timeParts = parts[0].split(':');
      int h = int.parse(timeParts[0]);
      int m = int.parse(timeParts[1]);
      if (timeStr.contains('PM') && h < 12) h += 12;
      if (timeStr.contains('AM') && h == 12) h = 0;
      return h * 60 + m;
    }

    void sortTasks(List<Map<String, dynamic>> list) {
      list.sort((a, b) {
        final startA = (a['time_range'] as String?)?.split(' - ').first;
        final startB = (b['time_range'] as String?)?.split(' - ').first;
        return toMinutes(startA).compareTo(toMinutes(startB));
      });
    }

    // 1. Try today
    final todayTasks = tasks.where((t) {
       final days = (t['day_of_week'] as String?)?.split(',') ?? [];
       return days.contains(todayName);
    }).toList();
    
    if (todayTasks.isNotEmpty) {
      sortTasks(todayTasks);
      
      final currentMinutes = now.hour * 60 + now.minute;
      final lastTaskEndStr = (todayTasks.last['time_range'] as String?)?.split(' - ').last;
      
      // If the current time is still before or equal to the end time of the last task today, show today.
      // Otherwise, we skip today and look for the next day.
      if (currentMinutes <= toMinutes(lastTaskEndStr)) {
        _upcomingTasks = todayTasks;
        _displayDay = 'Today\'s Schedule';
        return;
      }
    }

    // 2. Find next day with tasks
    for (int i = 1; i < 7; i++) {
      final nextDayIndex = (now.weekday - 1 + i) % 7;
      final nextDayName = dayNames[nextDayIndex];
      final nextTasks = tasks.where((t) {
        final days = (t['day_of_week'] as String?)?.split(',') ?? [];
        return days.contains(nextDayName);
      }).toList();
      
      if (nextTasks.isNotEmpty) {
        sortTasks(nextTasks);
        _upcomingTasks = nextTasks;
        _displayDay = 'Upcoming: $nextDayName';
        return;
      }
    }

    _upcomingTasks = [];
    _displayDay = 'None';
  }

  void _showScheduleDetails(Map<String, dynamic> task) async {
    final scheduleId = task['id'];
    if (scheduleId == null) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        minChildSize: 0.4,
        builder: (_, controller) => Container(
          decoration: BoxDecoration(
            color: Theme.of(context).canvasColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(task['activity_name'] ?? 'Task Details', 
                          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                        Text("${task['time_range']} • ${task['target_node_name']}", 
                          style: TextStyle(color: Theme.of(context).textTheme.bodySmall?.color, fontSize: 16)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Builder(
                    builder: (context) {
                      final bool isLeave = _leaveTaskIds.contains(task['id'].toString());
                      
                      if (isLeave) {
                        return ElevatedButton.icon(
                          onPressed: () => _restartTask(task),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green,
                            foregroundColor: Colors.white,
                          ),
                          icon: const Icon(Icons.refresh),
                          label: const Text('Restart Tracking'),
                        );
                      } else {
                        return OutlinedButton.icon(
                          onPressed: () => _markTaskAsLeave(task),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: Colors.red),
                            foregroundColor: Colors.red,
                          ),
                          icon: const Icon(Icons.cancel),
                          label: const Text('Mark as Absent'),
                        );
                      }
                    },
                  ),
                ],
              ),
              const Divider(height: 30),
              const Text("Assigned Personnel", 
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),
              Expanded(
                child: FutureBuilder<Map<String, dynamic>?>(
                  future: _apiService.fetchScheduleMembers(scheduleId),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snapshot.hasError || snapshot.data == null) {
                      return const Center(child: Text('Failed to load members'));
                    }

                    final members = snapshot.data!['members'] as List<dynamic>;
                    members.sort((a, b) {
                      final aPower = (a['has_upload_power'] == 1 || a['has_upload_power'] == true) ? 1 : 0;
                      final bPower = (b['has_upload_power'] == 1 || b['has_upload_power'] == true) ? 1 : 0;
                      if (aPower != bPower) return bPower.compareTo(aPower);
                      return (a['full_name'] ?? '').compareTo(b['full_name'] ?? '');
                    });
                    return ListView.builder(
                      controller: controller,
                      itemCount: members.length,
                      itemBuilder: (context, idx) {
                        final m = members[idx];
                        final dynamic rawPower = m['has_upload_power'];
                        final bool hasPower = rawPower == 1 || rawPower == true;
                        final bool isTemp = m['is_temporarily_granted'] == 1 || m['is_temporarily_granted'] == true;
                        final bool canManage = Provider.of<NodeRoleProvider>(context, listen: false).currentUserNode?.canUpload == true;

                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          decoration: BoxDecoration(
                            color: hasPower ? const Color(0xFF0078D4).withOpacity(0.1) : null,
                            borderRadius: BorderRadius.circular(12),
                            border: hasPower ? Border.all(color: const Color(0xFF0078D4).withOpacity(0.3)) : null,
                          ),
                          child: ListTile(
                            leading: CircleAvatar(
                              backgroundColor: hasPower ? const Color(0xFF0078D4) : Colors.grey.withOpacity(0.2),
                              backgroundImage: m['image_url'] != null
                                ? CachedNetworkImageProvider("${ApiConfig.baseUrl.replaceAll('/api', '')}${m['image_url']}")
                                : null,
                              child: m['image_url'] == null 
                                ? Icon(hasPower ? (isTemp ? Icons.shield : Icons.verified) : Icons.person, 
                                    color: hasPower ? Colors.white : Colors.grey)
                                : null,
                            ),
                            title: Text(m['full_name'] ?? 'Unknown', 
                              style: TextStyle(fontWeight: hasPower ? FontWeight.bold : FontWeight.normal)),
                            subtitle: Text("${m['role_name']} (${m['department_name']})"),
                            trailing: canManage
                              ? (isTemp
                                ? IconButton(
                                    icon: const Icon(Icons.shield, color: Color(0xFF0078D4), size: 20),
                                    tooltip: 'Revoke Temporary Power',
                                    onPressed: () async {
                                      final bool? confirm = await showDialog<bool>(
                                        context: context,
                                        builder: (ctx) => AlertDialog(
                                          title: const Text("Revoke Power"),
                                          content: Text("Revoke temporary upload power from ${m['full_name']}?"),
                                          actions: [
                                            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Cancel")),
                                            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text("Revoke")),
                                          ],
                                        ),
                                      );
                                      if (confirm == true) {
                                        final success = await _apiService.revokeTemporaryPower(m['id'], scheduleId);
                                        if (success && mounted) {
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            const SnackBar(content: Text("Temporary power revoked."))
                                          );
                                          Navigator.pop(context); // Close bottom sheet
                                          _showScheduleDetails(task); // Re-open to refresh
                                        }
                                      }
                                    },
                                  )
                                : (hasPower
                                  ? const Text("Uploader", style: TextStyle(color: Color(0xFF0078D4), fontWeight: FontWeight.bold, fontSize: 12))
                                  : IconButton(
                                      icon: const Icon(Icons.shield_outlined, size: 20),
                                      tooltip: 'Grant Temporary Power',
                                      onPressed: () async {
                                        final bool? confirm = await showDialog<bool>(
                                          context: context,
                                          builder: (ctx) => AlertDialog(
                                            title: const Text("Delegate Power"),
                                            content: Text("Grant temporary upload power to ${m['full_name']} for this activity today?"),
                                            actions: [
                                              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Cancel")),
                                              ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text("Grant")),
                                            ],
                                          ),
                                        );
                                        if (confirm == true) {
                                          final grantorId = Provider.of<NodeRoleProvider>(context, listen: false).currentUserNode?.id;
                                          if (grantorId != null) {
                                            final success = await _apiService.grantTemporaryPower(
                                              m['id'], 
                                              scheduleId, 
                                              int.parse(grantorId)
                                            );
                                            if (success && mounted) {
                                              ScaffoldMessenger.of(context).showSnackBar(
                                                SnackBar(content: Text("Power granted to ${m['full_name']} for today."))
                                              );
                                              Navigator.pop(context);
                                              _showScheduleDetails(task);
                                            }
                                          }
                                        }
                                      },
                                    )
                                  )
                                )
                              : (hasPower 
                                  ? const Text("Uploader", style: TextStyle(color: Color(0xFF0078D4), fontWeight: FontWeight.bold, fontSize: 12))
                                  : null),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _markTaskAsLeave(Map<String, dynamic> task) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    
    final leaveIds = prefs.getStringList('leave_task_ids') ?? [];
    final taskIdStr = task['id'].toString();
    if (!leaveIds.contains(taskIdStr)) {
      leaveIds.add(taskIdStr);
      await prefs.setStringList('leave_task_ids', leaveIds);
    }
    
    // Save as last leave task for notification restart callbacks
    await prefs.setString('last_leave_task', jsonEncode(task));
    
    // Check if the marked task is the active one
    final bool isTargeted = _currentAlarm != null && _currentAlarm!['task_id'].toString() == taskIdStr;
    final bool isActive = isTargeted && _currentAlarm!['status'] == 'active';
    
    if (isActive) {
      try {
        await FlutterForegroundTask.stopService();
      } catch (e) {
        print('Dashboard: Error stopping service: $e');
      }
    }
    
    // Remove the scheduled alarm key from prefs if it was this task
    if (isTargeted) {
      final isTestMode = prefs.getBool('is_test_mode') ?? false;
      final alarmKey = isTestMode ? 'test_session_alarm' : 'session_alarm';
      await prefs.remove(alarmKey);
    }
    
    // Reschedule so the scheduler finds the next non-leave task
    final userProvider = Provider.of<NodeRoleProvider>(context, listen: false);
    final userId = userProvider.currentUserNode?.id ?? '';
    final isRoot = userProvider.currentUserNode?.canUpload == true;
    final isTestMode = prefs.getBool('is_test_mode') ?? false;
    
    List<Map<String, dynamic>> tasks;
    if (isTestMode) {
      tasks = _upcomingTasks;
    } else {
      tasks = await _apiService.getCachedUserTimetableOffline();
      if (tasks.isEmpty) {
        tasks = await _apiService.fetchUserTimetable(userId);
      }
    }
    await _automationService.scheduleNextSessionIfNeeded(tasks, userId, isRoot);
    
    // Synchronize UI
    await _loadMeshState();
    
    final notif = NotificationService();
    await notif.init();
    await notif.cancel(100);
    await notif.cancel(101);
    await notif.showAbsentSession(task['activity_name'] ?? 'Session');
    
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("${task['activity_name'] ?? 'Session'} marked as Absent.")),
    );
    Navigator.pop(context);
  }

  void _restartTask(Map<String, dynamic> task) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    
    final leaveIds = prefs.getStringList('leave_task_ids') ?? [];
    final taskIdStr = task['id'].toString();
    leaveIds.remove(taskIdStr);
    await prefs.setStringList('leave_task_ids', leaveIds);
    
    // Cancel Leave notification if showing
    final notif = NotificationService();
    await notif.init();
    await notif.cancel(105);
    
    // Parse start and end times to decide whether to start immediately or schedule
    final now = DateTime.now();
    DateTime startTime;
    DateTime endTime;
    
    if (task['is_test'] == true || prefs.getBool('is_test_mode') == true) {
      startTime = DateTime.tryParse(task['start_time'] ?? '') ?? now;
      endTime = DateTime.tryParse(task['end_time'] ?? '') ?? now.add(const Duration(minutes: 5));
    } else {
      final timeRange = task['time_range'] as String;
      final parts = timeRange.split(' - ');
      startTime = SessionAutomationService.parseTime(parts[0], now);
      endTime = SessionAutomationService.parseTime(parts[1], now);
    }
    
    final bool isUpcoming = now.isBefore(startTime);
    final bool isOngoing = now.isAfter(startTime) && now.isBefore(endTime);
    
    final userProvider = Provider.of<NodeRoleProvider>(context, listen: false);
    final userId = userProvider.currentUserNode?.id ?? '';
    final isRoot = userProvider.currentUserNode?.canUpload == true;
    final isTestMode = prefs.getBool('is_test_mode') ?? false;
    final alarmKey = isTestMode ? 'test_session_alarm' : 'session_alarm';
    
    if (isOngoing) {
      final alarmData = {
        'task_id': task['id'],
        'user_id': userId,
        'activity_name': task['activity_name'],
        'start_time': startTime.toIso8601String(),
        'end_time': endTime.toIso8601String(),
        'is_root': isRoot,
        'is_test': task['is_test'] == true,
        'status': 'active',
      };
      await prefs.setString(alarmKey, jsonEncode(alarmData));
      onSessionStart();
      
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Started tracking for ${task['activity_name'] ?? 'Session'}.")),
      );
    } else if (isUpcoming) {
      List<Map<String, dynamic>> tasks;
      if (isTestMode) {
        tasks = _upcomingTasks;
      } else {
        tasks = await _apiService.getCachedUserTimetableOffline();
        if (tasks.isEmpty) {
          tasks = await _apiService.fetchUserTimetable(userId);
        }
      }
      await _automationService.scheduleNextSessionIfNeeded(tasks, userId, isRoot);
      
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Scheduled ${task['activity_name'] ?? 'Session'} as upcoming.")),
      );
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("This task's scheduled time has already passed.")),
      );
    }
    
    await _loadMeshState();
    if (mounted) Navigator.pop(context);
  }

  void _showActiveMeshDetails() async {
    if (_meshTaskId.isEmpty || !_isMeshActive) {
      print('Dashboard: Live Session Tracker blocked from opening because no session is currently active.');
      return;
    }
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _MeshDetailsSheet(
        taskId: _meshTaskId,
        apiService: _apiService,
        activeScannedUsers: _rootAggregatedData,
      ),
    );
  }

  Widget _buildTestModeCountdownBanner(NodeRoleProvider userProvider) {
    String title = '';
    switch (_testStage) {
      case 'waiting': title = 'Next Test Activity'; break;
      case 'active': title = 'Test Activity Active'; break;
      case 'transitioning': title = 'Starting Test...'; break;
      case 'finished': title = 'Test Finished'; break;
      default: title = 'Processing Test...'; break;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.orange.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.withOpacity(0.3), width: 2),
      ),
      child: Column(
        children: [
          Row(
            children: [
              const Icon(Icons.science, color: Colors.orange, size: 30),
              const SizedBox(width: 15),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.orange)),
                    Text(
                      _testStage == 'active' 
                        ? "Test session ends in ${(_testCountdown ~/ 60).toString().padLeft(2, '0')}:${(_testCountdown % 60).toString().padLeft(2, '0')}"
                        : "Test starts in ${(_testCountdown ~/ 60).toString().padLeft(2, '0')}:${(_testCountdown % 60).toString().padLeft(2, '0')}",
                      style: const TextStyle(fontSize: 13, color: Colors.orange),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              if (_testStage == 'waiting') ...[
                Expanded(
                  child: OutlinedButton(
                    onPressed: _skipTestPhase,
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      side: const BorderSide(color: Colors.orange),
                      foregroundColor: Colors.orange,
                    ),
                    child: const Text('Skip'),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: OutlinedButton(
                  onPressed: _endTestMode,
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    side: const BorderSide(color: Colors.red),
                    foregroundColor: Colors.red,
                  ),
                  child: const Text('Cancel'),
                ),
              ),
            ],
          )
        ],
      ),
    );
  }

  Widget _buildActiveMeshIndicator() {
    final canUpload = Provider.of<NodeRoleProvider>(context, listen: false).canUpload;
    
    return InkWell(
      onTap: canUpload ? () => _showActiveMeshDetails() : null,
      child: Container(
        margin: const EdgeInsets.only(bottom: 20),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF0078D4).withOpacity(0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFF0078D4), width: 2),
        ),
        child: Row(
          children: [
            const Icon(Icons.bluetooth_connected, color: Color(0xFF0078D4), size: 30),
            const SizedBox(width: 15),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                   const Text("Tracking Presence...", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Color(0xFF0078D4))),
                   Text(_simStage == 'active' ? "Simulation ending in ${_simCountdown}s" : (canUpload ? "Tap to view and override live attendance" : "Session is currently active"), style: const TextStyle(fontSize: 12)),
                ],
              ),
            ),
            if (canUpload)
               const Icon(Icons.arrow_forward_ios, color: Color(0xFF0078D4), size: 16),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: InkWell(
          onTap: _showSettingsDialog,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Dashboard'),
                const SizedBox(width: 8),
                if (Provider.of<NodeRoleProvider>(context).isTestMode)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    margin: const EdgeInsets.only(right: 8),
                    decoration: BoxDecoration(
                      color: Colors.orange,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text('TEST', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
                  ),
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _dbMode == 'cloud' 
                        ? Colors.green 
                        : (_dbMode == 'local' ? Colors.orange : Colors.red),
                    boxShadow: [
                      BoxShadow(
                        color: (_dbMode == 'cloud' ? Colors.green : (_dbMode == 'local' ? Colors.orange : Colors.red)).withOpacity(0.5),
                        blurRadius: 4,
                        spreadRadius: 2,
                      )
                    ],
                  ),
                ),
                if (_isSyncing) ...[
                  const SizedBox(width: 6),
                  const SizedBox(
                    width: 10,
                    height: 10,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5,
                      valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF0078D4)),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        elevation: 0,
        actions: [
          Builder(
            builder: (context) => IconButton(
              icon: const Icon(Icons.menu),
              onPressed: () => Scaffold.of(context).openEndDrawer(),
            ),
          ),
        ],
      ),
      endDrawer: Drawer(
        child: Column(
          children: [
            UserAccountsDrawerHeader(
              decoration: const BoxDecoration(color: Color(0xFF0078D4)),
              accountName: Text(Provider.of<NodeRoleProvider>(context).currentUserNode?.name ?? 'User'),
              accountEmail: Text(Provider.of<NodeRoleProvider>(context).currentUserNode?.email ?? ''),
              currentAccountPicture: CircleAvatar(
                backgroundColor: Colors.white,
                backgroundImage: Provider.of<NodeRoleProvider>(context).currentUserNode?.imageUrl != null
                  ? CachedNetworkImageProvider("${ApiConfig.baseUrl.replaceAll('/api', '')}${Provider.of<NodeRoleProvider>(context).currentUserNode!.imageUrl}")
                  : null,
                child: Provider.of<NodeRoleProvider>(context).currentUserNode?.imageUrl == null
                  ? const Icon(Icons.person, color: Color(0xFF0078D4), size: 40)
                  : null,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.lock_reset),
              title: const Text('Change Password'),
              onTap: () {
                Navigator.pop(context); // Close drawer
                _showChangePasswordDialog(context);
              },
            ),
            const Divider(),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Settings', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
              ),
            ),
            Consumer<ThemeProvider>(
              builder: (context, themeProvider, child) {
                final bool isDark = themeProvider.themeMode == ThemeMode.dark ||
                    (themeProvider.themeMode == ThemeMode.system &&
                     MediaQuery.platformBrightnessOf(context) == Brightness.dark);
                return SwitchListTile(
                  secondary: Icon(isDark ? Icons.dark_mode : Icons.light_mode),
                  title: const Text('Dark Mode'),
                  value: isDark,
                  onChanged: (val) {
                    themeProvider.toggleTheme(val);
                  },
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.analytics_outlined),
              title: const Text('System Diagnostics'),
              onTap: () {
                Navigator.pop(context); // Close drawer
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const SystemDiagnosticsScreen()),
                );
              },
            ),
            const Spacer(),
            const Divider(),
            Consumer<NodeRoleProvider>(
              builder: (context, userProvider, child) {
                if (!userProvider.isTestMode) {
                  return ListTile(
                    leading: const Icon(Icons.bug_report, color: Colors.grey),
                    title: const Text('Enable Test Mode'),
                    subtitle: const Text('Test entire app flow'),
                    onTap: () {
                      _startTestMode();
                      Navigator.pop(context);
                    },
                  );
                }

                String title = '';
                switch (_testStage) {
                  case 'waiting': title = 'Next Activity'; break;
                  case 'active': title = 'Activity Active'; break;
                  case 'transitioning': title = 'Starting...'; break;
                  case 'finished': title = 'Test Finished'; break;
                  default: title = 'Processing...'; break;
                }

                return Container(
                  margin: const EdgeInsets.all(16),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.orange.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.orange.withOpacity(0.3)),
                  ),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.science, color: Colors.orange),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
                                Text(
                                  "${(_testCountdown ~/ 60).toString().padLeft(2, '0')}:${(_testCountdown % 60).toString().padLeft(2, '0')}",
                                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.orange),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          if (_testStage == 'waiting') ...[
                            Expanded(
                              child: OutlinedButton(
                                onPressed: _skipTestPhase,
                                style: OutlinedButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  side: const BorderSide(color: Colors.orange),
                                  foregroundColor: Colors.orange,
                                ),
                                child: const Text('Skip'),
                              ),
                            ),
                            const SizedBox(width: 8),
                          ],
                          Expanded(
                            child: OutlinedButton(
                              onPressed: _endTestMode,
                              style: OutlinedButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                side: const BorderSide(color: Colors.red),
                                foregroundColor: Colors.red,
                              ),
                              child: const Text('Cancel'),
                            ),
                          ),
                        ],
                      )
                    ],
                  ),
                );
              },
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.logout, color: Colors.red),
              title: const Text('Logout', style: TextStyle(color: Colors.red)),
              onTap: () async {
                Navigator.pop(context); // Close drawer
                await Provider.of<NodeRoleProvider>(context, listen: false).clearUserRole();
                if (mounted) {
                  Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(builder: (_) => const AuthScreen()),
                  );
                }
              },
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
      body: _isLoading 
        ? const Center(child: CircularProgressIndicator())
        : RefreshIndicator(
            onRefresh: _fetchDashboardData,
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(20.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [

                  if (Provider.of<NodeRoleProvider>(context).isTestMode)
                    _buildTestModeCountdownBanner(Provider.of<NodeRoleProvider>(context, listen: false)),
                  if (_isMeshActive) _buildActiveMeshIndicator(),
                  Center(
                    child: InkWell(
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => const AttendanceHistoryScreen()),
                        );
                      },
                      borderRadius: BorderRadius.circular(100),
                      child: Padding(
                        padding: const EdgeInsets.all(12.0),
                        child: CircularPercentIndicator(
                          radius: 60.0,
                          lineWidth: 10.0,
                          animation: true,
                          percent: _attendancePercentage / 100,
                          center: Text(
                            "${_attendancePercentage.toStringAsFixed(1)}%",
                            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                          footer: const Padding(
                            padding: EdgeInsets.only(top: 15.0),
                            child: Text(
                              "Overall Attendance",
                              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18.0),
                            ),
                          ),
                          circularStrokeCap: CircularStrokeCap.round,
                           progressColor: const Color(0xFF0078D4),
                           backgroundColor: const Color(0xFF0078D4).withOpacity(0.2),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 40),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        _displayDay == 'None' ? 'Upcoming Tasks' : _displayDay,
                        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                      ),
                      if (!Provider.of<NodeRoleProvider>(context).isTestMode)
                        TextButton(
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(builder: (_) => const FullTimetableScreen()),
                            );
                          },
                          child: const Text('View Full'),
                        ),
                    ],
                  ),
                  const Divider(),
                  _upcomingTasks.isEmpty && !Provider.of<NodeRoleProvider>(context).isTestMode
                    ? const Padding(
                        padding: EdgeInsets.all(20.0),
                        child: Text("No tasks found for the near future.", style: TextStyle(color: Colors.grey)),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: _upcomingTasks.length,
                        itemBuilder: (context, index) {
                          final task = _upcomingTasks[index];
                          return _buildTaskItem(task);
                        },
                      ),
                ],
              ),
            ),
          ),
    );
  }

  Widget _buildTaskItem(Map<String, dynamic> task) {
    final bool isTest = task['is_test'] == true;
    final bool isLeave = _leaveTaskIds.contains(task['id'].toString());
    final bool isTargeted = _currentAlarm != null && _currentAlarm!['task_id'].toString() == task['id'].toString();
    final bool isActive = isTargeted && _currentAlarm!['status'] == 'active' && !isLeave;
    final Color statusColor = isLeave 
      ? Colors.red 
      : (isActive 
          ? Colors.green 
          : (isTargeted 
              ? const Color(0xFF0078D4) 
              : (isTest ? Colors.orange : Colors.grey)));
    final onSurface = Theme.of(context).colorScheme.onSurface;

    return GestureDetector(
      onTap: () => isTest ? null : _showScheduleDetails(task),
      child: Container(
        margin: const EdgeInsets.only(bottom: 15),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: onSurface.withOpacity(0.05),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isLeave ? Colors.red : statusColor.withOpacity(0.3),
            width: (isActive || isLeave) ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 40,
              height: 40,
              child: isLeave
                ? const Icon(Icons.cancel, color: Colors.red, size: 28)
                : (isActive 
                    ? Center(
                        child: Container(
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.green,
                            boxShadow: [
                              BoxShadow(
                                color: Colors.green.withOpacity(0.5),
                                blurRadius: 8,
                                spreadRadius: 4,
                              )
                            ],
                          ),
                        ),
                      )
                    : isTargeted
                      ? Icon(Icons.notifications_active, color: statusColor, size: 28)
                      : isTest 
                        ? const Icon(Icons.science, color: Colors.orange, size: 28)
                        : Stack(
                            alignment: Alignment.center,
                            children: [
                              CircularProgressIndicator(
                                value: _getActivityPercentage(task['activity_name']),
                                strokeWidth: 4,
                                backgroundColor: statusColor.withOpacity(0.1),
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  _getActivityPercentage(task['activity_name']) >= 0.75 ? Colors.green :
                                  (_getActivityPercentage(task['activity_name']) >= 0.5 ? Colors.orange : Colors.red)
                                ),
                              ),
                              Text(
                                "${(_getActivityPercentage(task['activity_name']) * 100).toInt()}%",
                                style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
                              ),
                            ],
                          )),
            ),
            const SizedBox(width: 15),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(task['activity_name'] ?? 'Session', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  if (isLeave || isActive || isTargeted) ...[
                    const SizedBox(height: 4),
                    Text(
                      isLeave ? 'Absent' : (isActive ? 'Session Active' : 'Upcoming'),
                      style: TextStyle(
                        color: statusColor,
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                  ],
                  Text(
                    "${task['time_range'] ?? 'Unknown Time'} • ${task['target_node_name'] ?? ''}",
                    style: TextStyle(color: onSurface.withOpacity(0.5), fontSize: 12),
                  ),
                ],
              ),
            ),
            if ((isActive || isTargeted) && !isLeave)
              SizedBox(
                width: 32,
                height: 32,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    CircularProgressIndicator(
                      value: _getActivityPercentage(task['activity_name']),
                      strokeWidth: 3,
                      backgroundColor: statusColor.withOpacity(0.1),
                      valueColor: AlwaysStoppedAnimation<Color>(
                        _getActivityPercentage(task['activity_name']) >= 0.75 ? Colors.green :
                        (_getActivityPercentage(task['activity_name']) >= 0.5 ? Colors.orange : Colors.red)
                      ),
                    ),
                    Text(
                      "${(_getActivityPercentage(task['activity_name']) * 100).toInt()}%",
                      style: const TextStyle(fontSize: 8, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _showChangePasswordDialog(BuildContext context) {
    final TextEditingController passwordController = TextEditingController();
    final userProvider = Provider.of<NodeRoleProvider>(context, listen: false);
    final email = userProvider.currentUserNode?.email ?? '';

    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Change Password'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Enter your new password below.'),
              const SizedBox(height: 16),
              TextField(
                controller: passwordController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'New Password',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.lock),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0078D4),
                foregroundColor: Colors.white,
              ),
              onPressed: () async {
                final newPass = passwordController.text.trim();
                if (newPass.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Password cannot be empty')),
                  );
                  return;
                }

                try {
                  final success = await _apiService.resetPassword(email, newPass);
                  if (success) {
                    if (mounted) {
                      Navigator.pop(dialogContext);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Password updated successfully')),
                      );
                    }
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Error: ${e.toString()}')),
                    );
                  }
                }
              },
              child: const Text('Change'),
            ),
          ],
        );
      },
    );
  }
}

class _MeshDetailsSheet extends StatefulWidget {
  final String taskId;
  final ApiService apiService;
  final Map<String, Map<String, dynamic>> activeScannedUsers;

  const _MeshDetailsSheet({
    required this.taskId,
    required this.apiService,
    required this.activeScannedUsers,
  });

  @override
  State<_MeshDetailsSheet> createState() => _MeshDetailsSheetState();
}

class _MeshDetailsSheetState extends State<_MeshDetailsSheet> {
  List<dynamic> _members = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadMembers();
  }

  Future<void> _loadMembers() async {
    try {
      final userProvider = Provider.of<NodeRoleProvider>(context, listen: false);
      List<dynamic> loadedMembers = [];

      if (userProvider.isTestMode) {
        // Fetch ALL users in the database
        loadedMembers = await widget.apiService.fetchAllUsers();
      } else {
        // Fetch only assigned members of the schedule
        final data = await widget.apiService.fetchScheduleMembers(int.tryParse(widget.taskId) ?? 0);
        if (data != null && data['members'] != null) {
          loadedMembers = data['members'];
        }
      }

      _sortAndSetMembers(loadedMembers);
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _sortAndSetMembers(List<dynamic> list) {
    if (!mounted) return;
    
    // Sort so scanned/present ones are at the top
    list.sort((a, b) {
      final String uIdA = a['id'].toString();
      final String uIdB = b['id'].toString();
      
      final bleService = BleMeshService();
      final livePeers = bleService.getLivePeers();
      
      final bool scannedA = widget.activeScannedUsers.containsKey(uIdA) || livePeers.containsKey(uIdA);
      final bool scannedB = widget.activeScannedUsers.containsKey(uIdB) || livePeers.containsKey(uIdB);
      
      if (scannedA != scannedB) {
        return scannedA ? -1 : 1; // Scanned/present ones first
      }
      return (a['full_name'] ?? '').compareTo(b['full_name'] ?? '');
    });

    setState(() {
      _members = list;
      _isLoading = false;
    });
  }

  void _togglePresence(dynamic member, bool currentlyPresent) {
    final bleService = BleMeshService();
    final String uId = member['id'].toString();
    
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(currentlyPresent ? "Remove Attendance" : "Mark Present"),
        content: Text(currentlyPresent 
          ? "Are you sure you want to invalidate presence for ${member['full_name']}?"
          : "Manually mark ${member['full_name']} as present?"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancel")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: currentlyPresent ? Colors.red : Colors.green),
            onPressed: () {
               bleService.toggleManualPresence(uId, !currentlyPresent);
               Navigator.pop(ctx);
               // Re-sort and update list dynamically after toggle!
               _sortAndSetMembers(_members);
               ScaffoldMessenger.of(context).showSnackBar(
                 SnackBar(content: Text('Attendance ${currentlyPresent ? "removed" : "added"} for ${member['full_name']}'))
               );
            },
            child: Text(currentlyPresent ? "Remove" : "Mark Present"),
          ),
        ],
      )
    );
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      maxChildSize: 0.9,
      minChildSize: 0.5,
      builder: (_, controller) => Container(
        decoration: BoxDecoration(
          color: Theme.of(context).canvasColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("Live Session Tracker", style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
            const Text("Monitor assigned members and manually enforce overrides", style: TextStyle(color: Colors.grey)),
            const Divider(height: 30),
            
            if (_isLoading) const Center(child: CircularProgressIndicator())
            else Expanded(
              child: ListView.builder(
                controller: controller,
                itemCount: _members.length,
                itemBuilder: (context, idx) {
                  final m = _members[idx];
                  final String uId = m['id'].toString();
                  
                  final bleService = BleMeshService();
                  final livePeers = bleService.getLivePeers();
                  
                  final bool isScanned = widget.activeScannedUsers.containsKey(uId) || livePeers.containsKey(uId);
                  final data = livePeers[uId] ?? widget.activeScannedUsers[uId];
                  
                  String timeInfo = "Not seen yet";
                  if (isScanned && data != null) {
                    final firstVal = data['first'] ?? data['first_view'];
                    final lastVal = data['last'] ?? data['last_view'];
                    if (firstVal != null && lastVal != null) {
                      final first = DateTime.fromMillisecondsSinceEpoch((firstVal as int) * 1000);
                      final last = DateTime.fromMillisecondsSinceEpoch((lastVal as int) * 1000);
                      timeInfo = "Seen: ${DateFormat('hh:mm:ss a').format(first)} - ${DateFormat('hh:mm:ss a').format(last)}";
                    }
                  }

                  final canEdit = Provider.of<NodeRoleProvider>(context, listen: false).canUpload;

                  return Card(
                    color: isScanned ? Colors.green.withOpacity(0.1) : Colors.red.withOpacity(0.05),
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: isScanned ? Colors.green : Colors.red.shade300,
                        child: Icon(isScanned ? Icons.bluetooth_connected : Icons.person_off, color: Colors.white),
                      ),
                      title: Text(m['full_name'] ?? 'Unknown', style: TextStyle(fontWeight: isScanned ? FontWeight.bold : FontWeight.normal)),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text("Role: ${m['role_name']}"),
                          Text(timeInfo, style: const TextStyle(fontSize: 10, color: Colors.grey)),
                        ],
                      ),
                      trailing: canEdit ? IconButton(
                        icon: Icon(isScanned ? Icons.remove_circle_outline : Icons.add_circle_outline, 
                                   color: isScanned ? Colors.red : Colors.green),
                        onPressed: () => _togglePresence(m, isScanned),
                      ) : (isScanned ? const Icon(Icons.check_circle, color: Colors.green) : null),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}


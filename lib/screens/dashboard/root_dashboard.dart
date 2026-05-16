import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';
import 'package:percent_indicator/circular_percent_indicator.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../providers/node_role_provider.dart';
import '../../providers/theme_provider.dart';
import '../../services/api_service.dart';
import '../../services/api_service.dart';
import '../auth/auth_screen.dart';
import './attendance_history_screen.dart';
import './full_timetable_screen.dart';
import '../../services/ble_mesh_service.dart';
import '../../services/session_automation_service.dart';
import '../../core/api_config.dart';
import '../../services/test_service.dart';
import 'package:permission_handler/permission_handler.dart';


class RootDashboard extends StatefulWidget {
  const RootDashboard({super.key});

  @override
  State<RootDashboard> createState() => _RootDashboardState();
}

class _RootDashboardState extends State<RootDashboard> {
  final ApiService _apiService = ApiService();
  
  double _attendancePercentage = 0.0;
  List<Map<String, dynamic>> _upcomingTasks = [];
  List<Map<String, dynamic>> _summaryData = [];
  String _displayDay = 'Today';
  bool _isLoading = true;

  // --- MESH & AUTOMATION STATE ---
  bool _isMeshActive = false;
  String _meshTaskId = '';
  Map<String, Map<String, int>> _rootAggregatedData = {};
  Map<String, dynamic>? _currentAlarm;
  Timer? _uiSyncTimer;

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
    _fetchDashboardData();
    _startHealthPolling();
    _requestPermissions();
    _uiSyncTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      _loadMeshState();
    });
    _testTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _updateTestModeTimer();
    });
  }

  void _updateTestModeTimer() {
    if (!mounted) return;
    final userProvider = Provider.of<NodeRoleProvider>(context, listen: false);
    if (!userProvider.isTestMode) return;

    if (_currentAlarm != null) {
      final now = DateTime.now();
      if (_currentAlarm!['status'] == 'scheduled') {
         final start = DateTime.tryParse(_currentAlarm!['start_time']) ?? now;
         _testStage = 'waiting';
         _testCountdown = start.difference(now).inSeconds;
      } else if (_currentAlarm!['status'] == 'active') {
         final end = DateTime.tryParse(_currentAlarm!['end_time']) ?? now;
         _testStage = 'active';
         _testCountdown = end.difference(now).inSeconds;
      }
      if (_testCountdown < 0) _testCountdown = 0;
      setState(() {});
    } else {
      _testStage = 'finished';
      _testCountdown = 0;
      setState(() {});
    }
  }

  Future<void> _requestPermissions() async {
    // Request critical permissions for background operations
    Map<Permission, PermissionStatus> statuses = await [
      Permission.notification,
      Permission.bluetoothScan,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();
    
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
    _uiSyncTimer?.cancel();
    _testTimer?.cancel();
    _healthCheckTimer?.cancel();
    super.dispose();
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
    
    if (mounted) {
      setState(() {
        _isMeshActive = active;
        _meshTaskId = tId;
        _rootAggregatedData = aggData;
        _currentAlarm = alarm;
      });
      
      if (alarm != null && (alarm['notified'] ?? false) == false) {
        _showAlarmPopup(alarm);
      }
    }
  }

  void _startTestMode() {
    final userProvider = Provider.of<NodeRoleProvider>(context, listen: false);
    userProvider.setTestMode(true);
    _fetchDashboardData();
  }

  void _endTestMode() {
    final userProvider = Provider.of<NodeRoleProvider>(context, listen: false);
    userProvider.setTestMode(false);
    _fetchDashboardData();
  }

  void _skipTestPhase() async {
    final prefs = await SharedPreferences.getInstance();
    final tasksJson = prefs.getString('test_mode_tasks');
    if (tasksJson == null) return;
    
    List<dynamic> tasks = jsonDecode(tasksJson);
    final now = DateTime.now();
    bool changed = false;

    for (var task in tasks) {
      DateTime start = DateTime.parse(task['start_time']);
      DateTime end = DateTime.parse(task['end_time']);
      
      // If waiting for this task to start, fast-forward to start
      if (now.isBefore(start)) {
        final duration = end.difference(start);
        task['start_time'] = now.toIso8601String();
        task['end_time'] = now.add(duration).toIso8601String();
        changed = true;
        break;
      } 
      // If currently active, fast-forward to end
      else if (now.isAfter(start) && now.isBefore(end)) {
        task['end_time'] = now.subtract(const Duration(seconds: 1)).toIso8601String();
        changed = true;
        break;
      }
    }

    if (changed) {
      await prefs.setString('test_mode_tasks', jsonEncode(tasks));
      final userProvider = Provider.of<NodeRoleProvider>(context, listen: false);
      final automation = SessionAutomationService();
      await automation.scheduleNextSessionIfNeeded(
          tasks.cast<Map<String, dynamic>>(), userProvider.currentUserNode?.id.toString() ?? '', userProvider.isRootNode);
      _updateTestModeTimer();
    }
  }

  Future<void> _fetchDashboardData() async {
    final userProvider = Provider.of<NodeRoleProvider>(context, listen: false);
    final userId = userProvider.currentUserNode?.id ?? 'unknown';

    try {
      print('Dashboard: Fetching data for user $userId');
      final percentage = await _apiService.fetchDashboardStats(userId);
      final tasks = await _apiService.fetchUserTimetable(userId);
      final summary = await _apiService.fetchAttendanceSummary(userId);
      print('Dashboard: Received ${tasks.length} tasks');

      if (mounted) {
        setState(() {
          _attendancePercentage = percentage;
          _summaryData = List<Map<String, dynamic>>.from(summary);
          _processUpcomingTasks(tasks);
          _isLoading = false;
        });

        // Automation
        if (userProvider.currentUserNode != null) {
          print('Dashboard: Triggering automation for node: ${userProvider.currentUserNode!.id}');
          await _automationService.scheduleNextSessionIfNeeded(
            tasks, 
            userProvider.currentUserNode!.id, 
            userProvider.canUpload
          );
          // Refresh state
          _loadMeshState();
        } else {
          print('Dashboard: currentUserNode is NULL, skipping automation');
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
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
    void sortTasks(List<Map<String, dynamic>> list) {
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
      _upcomingTasks = todayTasks;
      _displayDay = 'Today\'s Schedule';
      return;
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
              Text(task['activity_name'] ?? 'Task Details', 
                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              Text("${task['time_range']} • ${task['target_node_name']}", 
                style: TextStyle(color: Theme.of(context).textTheme.bodySmall?.color, fontSize: 16)),
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

  void _showActiveMeshDetails() async {
    if (_meshTaskId.isEmpty) return;
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
                return SwitchListTile(
                  secondary: Icon(themeProvider.themeMode == ThemeMode.dark ? Icons.dark_mode : Icons.light_mode),
                  title: const Text('Dark Mode'),
                  value: themeProvider.themeMode == ThemeMode.dark,
                  onChanged: (val) {
                    themeProvider.toggleTheme(val);
                  },
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
                        itemCount: Provider.of<NodeRoleProvider>(context).isTestMode ? _testActivities.length : _upcomingTasks.length,
                        itemBuilder: (context, index) {
                          final task = Provider.of<NodeRoleProvider>(context).isTestMode ? _testActivities[index] : _upcomingTasks[index];
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
    final bool isTargeted = _currentAlarm != null && _currentAlarm!['task_id'].toString() == task['id'].toString();
    final bool isActive = (isTargeted && _currentAlarm!['status'] == 'active') || (isTest && _testStage == 'active' && task['id'] == 'test_2');
    final Color statusColor = isActive ? Colors.green : (isTargeted ? const Color(0xFF0078D4) : (isTest ? Colors.orange : Colors.grey));
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
            color: statusColor.withOpacity(0.3),
            width: isActive ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 40,
              height: 40,
              child: isActive 
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
                      ),
            ),
            const SizedBox(width: 15),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(task['activity_name'] ?? 'Session', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  if (isActive || isTargeted) ...[
                    const SizedBox(height: 4),
                    Text(
                      isActive ? 'Session Active' : 'Upcoming',
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
            if (isActive || isTargeted)
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
  final Map<String, Map<String, int>> activeScannedUsers;

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
      final data = await widget.apiService.fetchScheduleMembers(int.tryParse(widget.taskId) ?? 0);
      if (data != null && data['members'] != null) {
         if (mounted) {
           setState(() {
              _members = data['members'];
              _isLoading = false;
           });
         }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _confirmRemoval(dynamic member) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Remove Attendance"),
        content: Text("Are you sure you want to invalidate presence for ${member['full_name']}?"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancel")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () {
               // Ensure state reflects manually removed (e.g., using API)
               ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Attendance removed for ${member['full_name']}')));
               Navigator.pop(ctx);
            },
            child: const Text("Remove"),
          ),
        ],
      )
    );
  }

  void _promptAddAttendance(dynamic member) async {
    TimeOfDay defaultStart = const TimeOfDay(hour: 9, minute: 0); 
    
    TimeOfDay? startT = await showTimePicker(context: context, initialTime: defaultStart, helpText: 'Select Start Time');
    if (startT == null) return;
    TimeOfDay? endT = await showTimePicker(context: context, initialTime: const TimeOfDay(hour: 10, minute: 0), helpText: 'Select End Time');
    if (endT == null) return;
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Attendance manually added for ${member['full_name']}')));
    }
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
                  final bool isScanned = widget.activeScannedUsers.containsKey(uId);

                  return Card(
                    color: isScanned ? Colors.green.withOpacity(0.1) : null,
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: isScanned ? Colors.green : Colors.grey,
                        child: Icon(isScanned ? Icons.bluetooth_connected : Icons.person_off, color: Colors.white),
                      ),
                      title: Text(m['full_name'] ?? 'Unknown', style: TextStyle(fontWeight: isScanned ? FontWeight.bold : FontWeight.normal)),
                      subtitle: Text("Role: ${m['role_name']}"),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                           if (isScanned) const Text("Scanned", style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold)),
                           const SizedBox(width: 10),
                           IconButton(
                             icon: const Icon(Icons.edit_calendar),
                             onPressed: () {
                               if (isScanned) {
                                  _confirmRemoval(m);
                               } else {
                                  _promptAddAttendance(m);
                               }
                             },
                           ),
                        ],
                      ),
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


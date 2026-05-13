import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';
import 'package:percent_indicator/circular_percent_indicator.dart';
import 'package:provider/provider.dart';
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


class RootDashboard extends StatefulWidget {
  const RootDashboard({super.key});

  @override
  State<RootDashboard> createState() => _RootDashboardState();
}

class _RootDashboardState extends State<RootDashboard> {
  final ApiService _apiService = ApiService();
  
  double _attendancePercentage = 0.0;
  List<Map<String, dynamic>> _upcomingTasks = [];
  String _displayDay = 'Today';
  bool _isLoading = true;

  // --- SIMULATION STATE ---
  int _simCountdown = 0;
  String _simStage = ''; // 'waiting', 'active', ''
  Timer? _simTimer;
  // -----------------------

  bool _isMeshActive = false;
  String _meshTaskId = '';
  Map<String, Map<String, int>> _rootAggregatedData = {};
  Timer? _uiSyncTimer;

  bool _isConnected = false;
  bool _isDialogShowing = false;
  Timer? _healthCheckTimer;
  Map<String, dynamic>? _currentAlarm;
  final SessionAutomationService _automationService = SessionAutomationService();

  @override
  void initState() {
    super.initState();
    _fetchDashboardData();
    _startHealthPolling();
    _uiSyncTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      _loadMeshState();
    });
  }

  @override
  void dispose() {
    _uiSyncTimer?.cancel();
    _simTimer?.cancel();
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
    
    if (mounted) {
      setState(() {
        _isMeshActive = active;
        _meshTaskId = tId;
        _rootAggregatedData = aggData;
        _currentAlarm = alarm;
      });
      
      if (alarm != null && alarm['notified'] == false) {
        _showAlarmPopup(alarm);
      }
    }
  }

  Future<void> _fetchDashboardData() async {
    final userProvider = Provider.of<NodeRoleProvider>(context, listen: false);
    final userId = userProvider.currentUserNode?.id ?? 'unknown';

    try {
      final percentage = await _apiService.fetchDashboardStats(userId);
      final tasks = await _apiService.fetchUserTimetable(userId);


      if (mounted) {
        setState(() {
          _attendancePercentage = percentage;
          _processUpcomingTasks(tasks);
          _isLoading = false;
        });

        // Automation
        if (userProvider.currentUserNode != null) {
          await _automationService.scheduleNextSessionIfNeeded(
            tasks, 
            userProvider.currentUserNode!.id, 
            userProvider.canUpload
          );
          // Refresh state
          _loadMeshState();
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

  void _startHealthPolling() {
    // Initial check
    _apiService.checkHealth().then((connected) {
      if (mounted) {
        setState(() => _isConnected = connected);
        if (!connected) _showSettingsDialog();
      }
    });
    
    // Poll every 10 seconds
    _healthCheckTimer = Timer.periodic(const Duration(seconds: 10), (timer) async {
      final connected = await _apiService.checkHealth();
      if (mounted) {
        setState(() => _isConnected = connected);
        if (!connected && !_isDialogShowing) {
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

    final TextEditingController ipController = TextEditingController(
      text: ApiConfig.baseUrl.replaceAll('http://', '').replaceAll(':3000/api', '')
    );
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Server Configuration'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Connection lost. Please enter the backend IP:'),
            const SizedBox(height: 10),
            TextField(
              controller: ipController,
              decoration: const InputDecoration(
                labelText: 'IPv4 Address',
                hintText: 'e.g., 192.168.1.7',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
            }, 
            child: const Text('Later')
          ),
          ElevatedButton(
            onPressed: () async {
              String newIp = ipController.text.trim();
              if (newIp.isNotEmpty) {
                await ApiConfig.updateBaseUrl(newIp);
                if (mounted) {
                   Navigator.pop(ctx);
                   _apiService.checkHealth().then((connected) {
                      if (mounted) setState(() => _isConnected = connected);
                   });
                }
              }
            },
            child: const Text('Save'),
          ),
        ],
      )
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

    // Helper to sort tasks by time string HH:mm
    void sortTasks(List<Map<String, dynamic>> list) {
      list.sort((a, b) {
        final timeA = (a['time_range'] as String?)?.split(' - ').first ?? '00:00';
        final timeB = (b['time_range'] as String?)?.split(' - ').first ?? '00:00';
        return timeA.compareTo(timeB);
      });
    }

    // 1. Try today
    final todayTasks = tasks.where((t) => t['day_of_week'] == todayName).toList();
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
      final nextTasks = tasks.where((t) => t['day_of_week'] == nextDayName).toList();
      
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
                    return ListView.builder(
                      controller: controller,
                      itemCount: members.length,
                      itemBuilder: (context, idx) {
                        final m = members[idx];
                        final dynamic rawPower = m['has_upload_power'];
                        final bool hasPower = rawPower == 1 || rawPower == true;
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
                              child: Icon(hasPower ? Icons.verified : Icons.person, 
                                color: hasPower ? Colors.white : Colors.grey),
                            ),
                            title: Text(m['full_name'] ?? 'Unknown', 
                              style: TextStyle(fontWeight: hasPower ? FontWeight.bold : FontWeight.normal)),
                            subtitle: Text("${m['role_name']} (${m['department_name']})"),
                            trailing: hasPower 
                              ? const Text("Uploader", style: TextStyle(color: Color(0xFF0078D4), fontWeight: FontWeight.bold, fontSize: 12)) 
                              : null,
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
        title: Row(
          children: [
            const Text('Dashboard'),
            const SizedBox(width: 8),
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _isConnected ? Colors.green : Colors.red,
                boxShadow: [
                  BoxShadow(
                    color: (_isConnected ? Colors.green : Colors.red).withOpacity(0.5),
                    blurRadius: 4,
                    spreadRadius: 2,
                  )
                ],
              ),
            ),
          ],
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
              currentAccountPicture: const CircleAvatar(
                backgroundColor: Colors.white,
                child: Icon(Icons.person, color: Color(0xFF0078D4), size: 40),
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
            ListTile(
              leading: Icon(Icons.bug_report, color: _simStage != '' ? Colors.grey : Colors.orange),
              title: Text(_simStage == 'waiting' ? 'Simulation Starting in ${_simCountdown}s' : 'Run BLE Simulation'),
              subtitle: Text(_simStage == 'active' ? 'Simulation Active (ends in ${_simCountdown}s)' : 'Start next session in 1 min'),
              enabled: _simStage == '',
              onTap: () {
                if (_upcomingTasks.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No upcoming tasks to simulate.')));
                  return;
                }
                
                final userProvider = Provider.of<NodeRoleProvider>(context, listen: false);
                final task = Map<String, dynamic>.from(_upcomingTasks.first);
                
                setState(() {
                  _simStage = 'waiting';
                  _simCountdown = 60;
                });

                _simTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
                   if (mounted) {
                     setState(() {
                       _simCountdown--;
                       if (_simCountdown <= 0) {
                         if (_simStage == 'waiting') {
                            // Transition to ACTIVE
                            _simStage = 'active';
                            _simCountdown = 120; // 2 minutes
                            
                            // Trigger BLE Mesh
                            final BleMeshService bleService = BleMeshService();
                            bleService.initializeMeshNode(
                              userProvider.canUpload ? 'root' : 'leaf', 
                              task['id'].toString(), 
                              userProvider.currentUserNode!.id, 
                              task['activity_name'] ?? 'Session'
                            );
                         } else {
                            // Finish Simulation
                            _simStage = '';
                            _simCountdown = 0;
                            timer.cancel();
                            
                            // Trigger End and Sync
                            final BleMeshService bleService = BleMeshService();
                            bleService.endMeshTask(userProvider.canUpload ? 'root' : 'leaf');
                         }
                       }
                     });
                   }
                });

                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    backgroundColor: Colors.orange,
                    content: Text('Simulation Started! Look at the dashboard for countdown.'),
                  )
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
                  _upcomingTasks.isEmpty 
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
                          final bool isTargeted = _currentAlarm != null && _currentAlarm!['task_id'] == task['id'];
                          final bool isActive = isTargeted && _currentAlarm!['status'] == 'active';

                          return Card(
                            margin: const EdgeInsets.only(bottom: 15),
                            shape: isTargeted ? RoundedRectangleBorder(
                              side: BorderSide(color: const Color(0xFF0078D4), width: isActive ? 2 : 1),
                              borderRadius: BorderRadius.circular(12),
                            ) : null,
                            child: InkWell(
                              onTap: () => _showScheduleDetails(task),
                              child: ListTile(
                                leading: CircleAvatar(
                                  backgroundColor: isTargeted ? const Color(0xFF0078D4) : const Color(0xFF0078D4).withOpacity(0.1),
                                  child: Icon(isActive ? Icons.sensors : Icons.event_note, color: isTargeted ? Colors.white : const Color(0xFF0078D4)),
                                ),
                                title: Row(
                                  children: [
                                    Text(
                                      task['activity_name'] ?? 'Task',
                                      style: TextStyle(fontWeight: isTargeted ? FontWeight.bold : FontWeight.normal),
                                    ),
                                    if (isActive) ...[
                                      const SizedBox(width: 8),
                                      Container(
                                        width: 8,
                                        height: 8,
                                        decoration: const BoxDecoration(color: Colors.green, shape: BoxShape.circle),
                                      ),
                                    ],
                                  ],
                                ),
                                subtitle: Text("${task['time_range'] ?? 'Unknown Time'} • ${task['target_node_name'] ?? ''}"),
                                trailing: isTargeted ? Icon(
                                  isActive ? Icons.play_circle_fill : Icons.schedule,
                                  color: const Color(0xFF0078D4),
                                ) : null,
                              ),
                            ),
                          );
                        },
                      ),
                ],
              ),
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


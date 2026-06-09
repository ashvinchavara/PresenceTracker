import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import '../../services/log_service.dart';
import '../../services/notification_service.dart';
import '../../services/session_automation_service.dart';

@pragma('vm:entry-point')
void onTestAlarmTriggered() async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  
  await LogService.info('TestAlarm', 'Test background alarm executed successfully at ${DateTime.now()}!');
  
  final notifications = NotificationService();
  await notifications.init();
  await notifications.showAlert(
    'Test Alarm Fired!',
    'The background alarm executed successfully in the background isolate.',
  );
}

class SystemDiagnosticsScreen extends StatefulWidget {
  const SystemDiagnosticsScreen({super.key});

  @override
  State<SystemDiagnosticsScreen> createState() => _SystemDiagnosticsScreenState();
}

class _SystemDiagnosticsScreenState extends State<SystemDiagnosticsScreen> {
  static const _platform = MethodChannel('com.example.presence_tracker/autostart');
  bool _exactAlarmGranted = false;
  bool _batteryOptimizationsIgnored = false;
  List<String> _logs = [];
  List<String> _filteredLogs = [];
  final TextEditingController _searchController = TextEditingController();
  Timer? _refreshTimer;
  bool _isTestAlarmScheduled = false;

  Future<void> _openAutostartSettings() async {
    try {
      final bool result = await _platform.invokeMethod('openAutostartSettings');
      await LogService.info('Diagnostics', 'Attempted to open Autostart settings. Result: $result');
    } on PlatformException catch (e) {
      await LogService.error('Diagnostics', 'Failed to launch Autostart settings channel: $e');
      await openAppSettings();
    }
  }

  @override
  void initState() {
    super.initState();
    _checkPermissions();
    _loadLogs();
    _searchController.addListener(_filterLogs);
    
    // Auto refresh logs every 3 seconds while diagnostics screen is open
    _refreshTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      _loadLogs();
      _checkPermissions();
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _checkPermissions() async {
    // Use the native AlarmManager.canScheduleExactAlarms() API — this is the
    // ground-truth check that works even when OEMs hide the toggle from App Info.
    bool exactAlarm = false;
    try {
      exactAlarm = await _platform.invokeMethod('canScheduleExactAlarms') ?? false;
    } on PlatformException {
      // Fallback to permission_handler if platform channel unavailable
      exactAlarm = await Permission.scheduleExactAlarm.status.isGranted;
    }
    final ignoreBattery = await Permission.ignoreBatteryOptimizations.status.isGranted;
    
    if (mounted) {
      setState(() {
        _exactAlarmGranted = exactAlarm;
        _batteryOptimizationsIgnored = ignoreBattery;
      });
    }
  }

  Future<void> _loadLogs() async {
    final logContent = await LogService.readLogs();
    if (!mounted) return;
    
    final lines = logContent.split('\n').where((line) => line.trim().isNotEmpty).toList();
    // Reverse order to show newest logs at the top
    final reversedLines = lines.reversed.toList();

    setState(() {
      _logs = reversedLines;
      _filterLogs();
    });
  }

  void _filterLogs() {
    final query = _searchController.text.toLowerCase().trim();
    if (query.isEmpty) {
      setState(() {
        _filteredLogs = List.from(_logs);
      });
    } else {
      setState(() {
        _filteredLogs = _logs.where((line) => line.toLowerCase().contains(query)).toList();
      });
    }
  }

  Future<void> _requestExactAlarmPermission() async {
    // Use ACTION_REQUEST_SCHEDULE_EXACT_ALARM intent which opens the dedicated
    // exact alarm settings page — works even when OEM hides it from App Info.
    try {
      await _platform.invokeMethod('openExactAlarmSettings');
    } on PlatformException {
      // Fallback to permission_handler
      await Permission.scheduleExactAlarm.request();
    }
    // Re-check after user returns from settings
    await Future.delayed(const Duration(seconds: 1));
    await _checkPermissions();
  }

  Future<void> _requestIgnoreBatteryOptimizations() async {
    await Permission.ignoreBatteryOptimizations.request();
    await _checkPermissions();
  }

  Future<void> _triggerTestAlarm() async {
    final now = DateTime.now();
    final testTime = now.add(const Duration(seconds: 10));
    
    await LogService.info('Diagnostics', 'Scheduling test background alarm to fire at $testTime');
    
    try {
      final success = await AndroidAlarmManager.oneShotAt(
        testTime,
        9999, // Test alarm ID
        onTestAlarmTriggered,
        exact: true,
        wakeup: true,
        rescheduleOnReboot: false,
      );

      if (success && mounted) {
        setState(() {
          _isTestAlarmScheduled = true;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Test alarm scheduled to trigger in 10 seconds. Put the app in the background!'),
            backgroundColor: Color(0xFF0078D4),
          ),
        );
        Timer(const Duration(seconds: 11), () {
          if (mounted) {
            setState(() {
              _isTestAlarmScheduled = false;
            });
            _loadLogs();
          }
        });
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to schedule test alarm. Check permissions.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      await LogService.error('Diagnostics', 'Failed to schedule exact test alarm: $e. Retrying with exact=false.');
      final success = await AndroidAlarmManager.oneShotAt(
        testTime,
        9999,
        onTestAlarmTriggered,
        exact: false,
        wakeup: true,
        rescheduleOnReboot: false,
      );

      if (success && mounted) {
        setState(() {
          _isTestAlarmScheduled = true;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Test alarm scheduled (inexact) in 10 seconds. Put app in background!'),
            backgroundColor: Colors.orange,
          ),
        );
        Timer(const Duration(seconds: 11), () {
          if (mounted) {
            setState(() {
              _isTestAlarmScheduled = false;
            });
            _loadLogs();
          }
        });
      }
    }
  }

  Future<void> _copyLogsToClipboard() async {
    final logContent = await LogService.readLogs();
    await Clipboard.setData(ClipboardData(text: logContent));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Logs copied to clipboard.')),
      );
    }
  }

  Future<void> _clearLogs() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear Logs'),
        content: const Text('Are you sure you want to delete all diagnostic logs?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            child: const Text('Clear'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await LogService.clearLogs();
      await _loadLogs();
    }
  }

  Widget _buildPermissionCard({
    required String title,
    required String description,
    required bool isGranted,
    required VoidCallback onRequest,
    required String actionLabel,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      elevation: 0,
      color: colorScheme.onSurface.withOpacity(0.04),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              isGranted ? Icons.check_circle : Icons.warning_rounded,
              color: isGranted ? Colors.green : Colors.orange,
              size: 28,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    description,
                    style: TextStyle(color: colorScheme.onSurface.withOpacity(0.6), fontSize: 13),
                  ),
                  if (!isGranted) ...[
                    const SizedBox(height: 12),
                    ElevatedButton(
                      onPressed: onRequest,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: colorScheme.primary,
                        foregroundColor: colorScheme.onPrimary,
                        elevation: 0,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      ),
                      child: Text(actionLabel, style: const TextStyle(fontSize: 12)),
                    )
                  ]
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _getLogLevelColor(String line) {
    if (line.contains('[ERROR]')) return Colors.red;
    if (line.contains('[WARN]')) return Colors.orange;
    return Colors.blue;
  }

  Widget _buildLogTile(String line) {
    final colorScheme = Theme.of(context).colorScheme;
    
    // Parse line: [timestamp] [level] [tag] message
    // Regex or simple splits:
    String timestamp = '';
    String level = 'INFO';
    String tag = 'System';
    String message = line;

    try {
      final matches = RegExp(r'^\[([^\]]+)\]\s+\[([^\]]+)\]\s+\[([^\]]+)\]\s+(.*)$').firstMatch(line);
      if (matches != null) {
        timestamp = matches.group(1) ?? '';
        level = matches.group(2) ?? 'INFO';
        tag = matches.group(3) ?? 'System';
        message = matches.group(4) ?? '';
        
        // Format timestamp for display (only time if it's today)
        final parsedTime = DateTime.tryParse(timestamp);
        if (parsedTime != null) {
          timestamp = '${parsedTime.hour.toString().padLeft(2, '0')}:${parsedTime.minute.toString().padLeft(2, '0')}:${parsedTime.second.toString().padLeft(2, '0')}';
        }
      }
    } catch (_) {}

    final levelColor = _getLogLevelColor(line);

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: colorScheme.onSurface.withOpacity(0.02),
        borderRadius: BorderRadius.circular(8),
        border: Border(left: BorderSide(color: levelColor, width: 4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                timestamp,
                style: TextStyle(color: colorScheme.onSurface.withOpacity(0.4), fontSize: 11, fontWeight: FontWeight.bold),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: levelColor.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  level,
                  style: TextStyle(color: levelColor, fontSize: 9, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  tag,
                  style: TextStyle(color: colorScheme.primary, fontSize: 11, fontWeight: FontWeight.bold),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            message,
            style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('System Diagnostics'),
        elevation: 0,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 12),
                    
                    // Permission Cards Section
              _buildPermissionCard(
                title: 'Alarms & Reminders',
                description: 'Required to wake up the background isolate at the scheduled attendance start and end times.',
                isGranted: _exactAlarmGranted,
                onRequest: _requestExactAlarmPermission,
                actionLabel: 'Grant Exact Alarm Permission',
              ),
              
              _buildPermissionCard(
                title: 'Ignore Battery Optimizations',
                description: 'Required to prevent the Android system from putting the app to sleep or killing BLE mesh sessions.',
                isGranted: _batteryOptimizationsIgnored,
                onRequest: _requestIgnoreBatteryOptimizations,
                actionLabel: 'Ignore Battery Optimizations',
              ),
              
              _buildPermissionCard(
                title: 'Autostart & Background Launch',
                description: 'CRITICAL FOR VIVO/iQOO: iQOO/Vivo devices block background alarm triggers when the app is swiped away. Tap below to open system settings: 1) Enable Autostart/Background startup. 2) Set Battery consumption to "Unrestricted" / "Allow High Background Power". 3) Lock the app in Recent Apps.',
                isGranted: false, // Autostart state cannot be queried programmatically on Android
                onRequest: _openAutostartSettings,
                actionLabel: 'Configure Autostart & Power Management',
              ),

              // Test Alarm Section
              Card(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                elevation: 0,
                color: colorScheme.onSurface.withOpacity(0.04),
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Row(
                    children: [
                      const Icon(Icons.alarm_add, color: Colors.blue, size: 28),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Background Alarm Tester',
                              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Verify background alarm scheduling on this specific device. Locks/closes app after clicking.',
                              style: TextStyle(color: colorScheme.onSurface.withOpacity(0.6), fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: _isTestAlarmScheduled ? null : _triggerTestAlarm,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        child: Text(_isTestAlarmScheduled ? 'Pending...' : 'Test (10s)'),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 16),

              // Logs Header & Toolbar
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'System Logs',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                  ),
                  Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.copy, size: 20),
                        tooltip: 'Copy Logs',
                        onPressed: _copyLogsToClipboard,
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 20, color: Colors.red),
                        tooltip: 'Clear Logs',
                        onPressed: _clearLogs,
                      ),
                    ],
                  ),
                ],
              ),
              
              // Search Input
              TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: 'Filter logs...',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  suffixIcon: _searchController.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: () {
                            _searchController.clear();
                          },
                        )
                      : null,
                  contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 16),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: colorScheme.onSurface.withOpacity(0.12)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: colorScheme.onSurface.withOpacity(0.12)),
                  ),
                ),
              ),

              const SizedBox(height: 12),

              // Scrollable list of logs
                  ],
                ),
              ),
              _filteredLogs.isEmpty
                  ? SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 32.0),
                        child: Center(
                          child: Text(
                            'No matching logs found.',
                            style: TextStyle(color: colorScheme.onSurface.withOpacity(0.4)),
                          ),
                        ),
                      ),
                    )
                  : SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (context, index) {
                          return _buildLogTile(_filteredLogs[index]);
                        },
                        childCount: _filteredLogs.length,
                      ),
                    ),
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ],
          ),
        ),
      ),
    );
  }
}

import 'dart:convert';
import 'package:flutter/material.dart';
import '../../services/api_service.dart';
import '../../services/test_service.dart';
import '../../providers/node_role_provider.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:table_calendar/table_calendar.dart';
import '../../services/report_service.dart';

class AttendanceHistoryScreen extends StatefulWidget {
  const AttendanceHistoryScreen({super.key});

  @override
  State<AttendanceHistoryScreen> createState() => _AttendanceHistoryScreenState();
}

class _AttendanceHistoryScreenState extends State<AttendanceHistoryScreen>
    with SingleTickerProviderStateMixin {
  final ApiService _apiService = ApiService();

  List<Map<String, dynamic>> _summary = []; // historical attendance per activity
  List<Map<String, dynamic>> _timetable = []; // recurring schedule
  bool _isLoading = true;

  TabController? _tabController;

  // Per-tab calendar state
  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;

  // Currently active activity index (0 = "All")
  int _selectedActivityIndex = 0;

  @override
  void initState() {
    super.initState();
    _fetchData();
  }

  @override
  void dispose() {
    _tabController?.dispose();
    super.dispose();
  }

  Future<void> _fetchData() async {
    final userProvider = Provider.of<NodeRoleProvider>(context, listen: false);
    final userId = userProvider.currentUserNode?.id ?? '';
    
    List<Map<String, dynamic>> summaryData = [];
    List<Map<String, dynamic>> timetableData = [];

    if (userProvider.isTestMode) {
      timetableData = TestService().getTestActivities();
      summaryData = [
        {
          'activity_name': 'Test Activity 1',
          'total_sessions': 1,
          'user_present': 1,
          'all_dates': [DateFormat('yyyy-MM-dd').format(DateTime.now().subtract(const Duration(days: 1)))],
          'present_dates': [DateFormat('yyyy-MM-dd').format(DateTime.now().subtract(const Duration(days: 1)))],
          'sessions': [
            {
              'date': DateFormat('yyyy-MM-dd').format(DateTime.now().subtract(const Duration(days: 1))),
              'is_present': true,
              'time_range': timetableData[0]['time_range'],
              'entry_time': '10:00:00',
              'exit_time': '11:00:00',
            }
          ]
        },
        {
          'activity_name': 'Test Activity 2',
          'total_sessions': 1,
          'user_present': 0,
          'all_dates': [DateFormat('yyyy-MM-dd').format(DateTime.now())],
          'present_dates': [],
          'sessions': []
        }
      ];
    } else {
      final rawSummary = await _apiService.fetchAttendanceSummary(userId);
      summaryData = rawSummary.map((item) {
        final sanitizedItem = Map<String, dynamic>.from(item);
        sanitizedItem['all_dates'] = _safeStringList(item['all_dates']);
        sanitizedItem['present_dates'] = _safeStringList(item['present_dates']);
        
        // Handle sessions as potentially serialized JSON
        if (item['sessions'] is String) {
          try {
            sanitizedItem['sessions'] = jsonDecode(item['sessions']);
          } catch (_) {
            sanitizedItem['sessions'] = [];
          }
        }
        return sanitizedItem;
      }).toList();
      timetableData = List<Map<String, dynamic>>.from(await _apiService.fetchUserTimetable(userId));
    }

    if (mounted) {
      setState(() {
        _summary = summaryData;
        _timetable = timetableData;
        _isLoading = false;
        _selectedDay = DateTime.now();
        
        _tabController = TabController(length: _summary.length + 1, vsync: this);
        _tabController!.addListener(() {
          if (!_tabController!.indexIsChanging) {
            setState(() {
              _selectedActivityIndex = _tabController!.index;
              _selectedDay = DateTime.now();
              _focusedDay = DateTime.now();
            });
          }
        });
      });
    }
  }

  void _generateReport() async {
    final userProvider = Provider.of<NodeRoleProvider>(context, listen: false);
    final userName = userProvider.currentUserNode?.name ?? 'Personnel';
    final userRole = userProvider.currentUserNode?.desig ?? 'Personnel';

    await ReportService.generateIndividualReport(
      userName: userName,
      userRole: userRole,
      summary: _summary,
    );
  }

  // ─── Computed values ───────────────────────────────────────────────────────

  int get _overallTotal {
    int total = 0;
    for (final act in _summary) {
      total += (act['total_sessions'] as num).toInt();
    }
    return total;
  }

  int get _overallPresent {
    int present = 0;
    for (final act in _summary) {
      present += (act['user_present'] as num).toInt();
    }
    return present;
  }

  double get _overallPercentage {
    final total = _overallTotal;
    final present = _overallPresent;
    if (total == 0) return 0;
    return (present / total) * 100;
  }

  double _activityPercentage(Map<String, dynamic> act) {
    final total = (act['total_sessions'] as num).toInt();
    final present = (act['user_present'] as num).toInt();
    if (total == 0) return 0;
    return (present / total) * 100;
  }

  String _extractDate(dynamic dateRaw) {
    if (dateRaw == null) return '';
    String str = dateRaw.toString();
    if (str.length >= 10 && str.contains('-')) {
      return str.substring(0, 10);
    }
    return str;
  }

  List<String> _safeStringList(dynamic data) {
    if (data == null) return [];
    
    List<dynamic> listData = [];
    if (data is List) {
      listData = data;
    } else if (data is String) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is List) {
          listData = decoded;
        } else {
          listData = data.split(',');
        }
      } catch (_) {
        listData = data.split(',');
      }
    }
    
    return listData.where((e) => e != null && e.toString().trim().isNotEmpty)
                   .map((e) => _extractDate(e.toString().trim()))
                   .toList();
  }

  Map<String, dynamic> get _currentActivityData {
    if (_selectedActivityIndex == 0) {
      final Set<String> allDates = {};
      final Set<String> presentDates = {};
      for (final act in _summary) {
        allDates.addAll(_safeStringList(act['all_dates']));
        presentDates.addAll(_safeStringList(act['present_dates']));
      }
      return {
        'activity_name': 'Overall Attendance',
        'all_dates': allDates.toList(),
        'present_dates': presentDates.toList(),
      };
    } else {
      return _summary[_selectedActivityIndex - 1];
    }
  }

  @override
  Widget build(BuildContext context) {
    final primaryColor = const Color(0xFF0078D4);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (_isLoading) {
      return Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('Attendance History'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.picture_as_pdf),
            onPressed: _generateReport,
            tooltip: 'Generate PDF Report',
          ),
          const SizedBox(width: 8),
        ],
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          indicatorColor: primaryColor,
          labelColor: primaryColor,
          unselectedLabelColor: Theme.of(context).textTheme.bodySmall?.color,
          tabs: [
            const Tab(text: 'Overall'),
            ..._summary.map((act) => Tab(text: act['activity_name'])),
          ],
        ),
      ),
      body: Column(
        children: [
          if (Provider.of<NodeRoleProvider>(context).isTestMode)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 8),
              color: Colors.orange,
              child: const Center(
                child: Text(
                  'YOU ARE ON TEST MODE (Displaying Simulated Data)',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                ),
              ),
            ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildCalendarView(_currentActivityData),
                ..._summary.map((act) => _buildCalendarView(act)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCalendarView(Map<String, dynamic> data) {
    final allDates = _safeStringList(data['all_dates']);
    final presentDates = _safeStringList(data['present_dates']);
    final primaryColor = const Color(0xFF0078D4);
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          // Stat card
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: primaryColor.withOpacity(isDark ? 0.05 : 0.03),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: primaryColor.withOpacity(0.1)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        data['activity_name'] ?? '',
                        style: TextStyle(
                          color: onSurface,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        'Total Sessions: ${allDates.length}',
                        style: TextStyle(color: onSurface.withOpacity(0.6)),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
                  decoration: BoxDecoration(
                    color: primaryColor.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${_selectedActivityIndex == 0 ? _overallPercentage.toStringAsFixed(1) : _activityPercentage(data).toStringAsFixed(1)}% (${_selectedActivityIndex == 0 ? _overallPresent : presentDates.length}/${_selectedActivityIndex == 0 ? _overallTotal : allDates.length})',
                    style: TextStyle(
                      color: primaryColor,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 25),
          // Calendar
          Container(
            decoration: BoxDecoration(
              color: onSurface.withOpacity(0.03),
              borderRadius: BorderRadius.circular(25),
              border: Border.all(color: onSurface.withOpacity(0.05)),
            ),
            child: TableCalendar(
              firstDay: DateTime.utc(2023, 1, 1),
              lastDay: DateTime.utc(2030, 12, 31),
              focusedDay: _focusedDay,
              selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
              onDaySelected: (selectedDay, focusedDay) {
                setState(() {
                  _selectedDay = selectedDay;
                  _focusedDay = focusedDay;
                });
              },
              calendarStyle: CalendarStyle(
                defaultTextStyle: TextStyle(color: onSurface),
                weekendTextStyle: TextStyle(color: onSurface.withOpacity(0.7)),
                outsideTextStyle: TextStyle(color: onSurface.withOpacity(0.2)),
                todayDecoration: BoxDecoration(
                  color: primaryColor.withOpacity(0.3),
                  shape: BoxShape.circle,
                ),
                selectedDecoration: BoxDecoration(
                  color: primaryColor,
                  shape: BoxShape.circle,
                ),
              ),
              headerStyle: HeaderStyle(
                formatButtonVisible: false,
                titleCentered: true,
                titleTextStyle: TextStyle(color: onSurface, fontSize: 18),
                leftChevronIcon: Icon(Icons.chevron_left, color: onSurface),
                rightChevronIcon: Icon(Icons.chevron_right, color: onSurface),
              ),
              calendarBuilders: CalendarBuilders(
                defaultBuilder: (context, day, focusedDay) {
                  final dateStr = DateFormat('yyyy-MM-dd').format(day);
                  final isPresent = presentDates.contains(dateStr);
                  final isAbsent = allDates.contains(dateStr) && !isPresent;

                  if (isPresent || isAbsent) {
                    return Container(
                      margin: const EdgeInsets.all(4),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color: isPresent ? Colors.green : Colors.red,
                            width: 3,
                          ),
                        ),
                      ),
                      child: Text(
                        '${day.day}',
                        style: TextStyle(color: onSurface),
                      ),
                    );
                  }
                  return null;
                },
              ),
            ),
          ),
          const SizedBox(height: 25),
          // Selected day details
          if (_selectedDay != null) _buildDayDetails(_selectedDay!),
        ],
      ),
    );
  }

  void _showManageAttendanceDialog(
      Map<String, dynamic> act, Map<String, dynamic>? session, String dateStr) async {
    final userProvider = Provider.of<NodeRoleProvider>(context, listen: false);
    final currentUserIdStr = userProvider.currentUserNode?.id ?? '';
    final currentUserId = int.tryParse(currentUserIdStr) ?? 0;
    final timetableId = int.tryParse(act['id']?.toString() ?? '') ?? int.tryParse(act['timetable_id']?.toString() ?? '') ?? 0;

    List<dynamic> allUsers = [];
    bool loadingUsers = true;

    TimeOfDay? entryTime;
    TimeOfDay? exitTime;

    if (session != null) {
      if (session['entry_time'] != null && session['entry_time'] != '--:--') {
        try {
          final parts = session['entry_time'].toString().split(':');
          entryTime = TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1]));
        } catch (_) {}
      }
      if (session['exit_time'] != null && session['exit_time'] != '--:--') {
        try {
          final parts = session['exit_time'].toString().split(':');
          exitTime = TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1]));
        } catch (_) {}
      }
    }

    entryTime ??= const TimeOfDay(hour: 10, minute: 0);
    exitTime ??= const TimeOfDay(hour: 11, minute: 0);

    dynamic selectedUser;

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            if (loadingUsers) {
              _apiService.fetchAllUsers().then((users) {
                if (ctx.mounted) {
                  setStateDialog(() {
                    allUsers = users;
                    loadingUsers = false;
                  });
                }
              });
            }

            return AlertDialog(
              backgroundColor: Theme.of(context).colorScheme.surface,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              title: Text(
                "Manage Attendance",
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontWeight: FontWeight.bold,
                ),
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "Activity: ${act['activity_name']}",
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.onSurface.withOpacity(0.8),
                      ),
                    ),
                    Text(
                      "Date: $dateStr",
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                        fontSize: 13,
                      ),
                    ),
                    const Divider(height: 30),
                    
                    Text(
                      "Edit Your Entry and Exit Time",
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: TextButton.icon(
                            icon: const Icon(Icons.login),
                            label: Text(
                              "In: ${entryTime!.format(context)}",
                              style: const TextStyle(fontSize: 12),
                            ),
                            onPressed: () async {
                              final picked = await showTimePicker(
                                context: context,
                                initialTime: entryTime!,
                              );
                              if (picked != null) {
                                setStateDialog(() => entryTime = picked);
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextButton.icon(
                            icon: const Icon(Icons.logout),
                            label: Text(
                              "Out: ${exitTime!.format(context)}",
                              style: const TextStyle(fontSize: 12),
                            ),
                            onPressed: () async {
                              final picked = await showTimePicker(
                                context: context,
                                initialTime: exitTime!,
                              );
                              if (picked != null) {
                                setStateDialog(() => exitTime = picked);
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Theme.of(context).colorScheme.primary,
                          foregroundColor: Theme.of(context).colorScheme.onPrimary,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        onPressed: () async {
                          final entryStr = "${entryTime!.hour.toString().padLeft(2, '0')}:${entryTime!.minute.toString().padLeft(2, '0')}:00";
                          final exitStr = "${exitTime!.hour.toString().padLeft(2, '0')}:${exitTime!.minute.toString().padLeft(2, '0')}:00";

                          final targetUserId = int.tryParse(userProvider.currentUserNode?.id ?? '') ?? 0;
                          final success = await _apiService.syncAttendanceRecord(
                            timetableId,
                            targetUserId,
                            currentUserId,
                            dateStr,
                            entryTime: entryStr,
                            exitTime: exitStr,
                          );

                          if (success) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text("Attendance updated successfully")),
                              );
                            }
                            Navigator.pop(ctx);
                            _fetchData();
                          } else {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text("Failed to update attendance")),
                              );
                            }
                          }
                        },
                        child: const Text("Save Your Attendance"),
                      ),
                    ),
                    
                    const Divider(height: 40),

                    Text(
                      "Mark Attendance for Another User",
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (loadingUsers)
                      const Center(child: CircularProgressIndicator())
                    else ...[
                      DropdownButtonFormField<dynamic>(
                        decoration: const InputDecoration(
                          labelText: "Select User",
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        ),
                        isExpanded: true,
                        value: selectedUser,
                        items: allUsers.map((u) {
                          return DropdownMenuItem<dynamic>(
                            value: u,
                            child: Text("${u['name'] ?? u['full_name'] ?? 'User'} (${u['role'] ?? u['desig'] ?? ''})"),
                          );
                        }).toList(),
                        onChanged: (val) {
                          setStateDialog(() => selectedUser = val);
                        },
                      ),
                      const SizedBox(height: 15),
                      if (selectedUser != null) ...[
                        Row(
                          children: [
                            Expanded(
                              child: TextButton.icon(
                                icon: const Icon(Icons.login),
                                label: Text(
                                  "In: ${entryTime!.format(context)}",
                                  style: const TextStyle(fontSize: 12),
                                ),
                                onPressed: () async {
                                  final picked = await showTimePicker(
                                    context: context,
                                    initialTime: entryTime!,
                                  );
                                  if (picked != null) {
                                    setStateDialog(() => entryTime = picked);
                                  }
                                },
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: TextButton.icon(
                                icon: const Icon(Icons.logout),
                                label: Text(
                                  "Out: ${exitTime!.format(context)}",
                                  style: const TextStyle(fontSize: 12),
                                ),
                                onPressed: () async {
                                  final picked = await showTimePicker(
                                    context: context,
                                    initialTime: exitTime!,
                                  );
                                  if (picked != null) {
                                    setStateDialog(() => exitTime = picked);
                                  }
                                },
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Theme.of(context).colorScheme.secondary,
                              foregroundColor: Theme.of(context).colorScheme.onSecondary,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                            onPressed: () async {
                              final entryStr = "${entryTime!.hour.toString().padLeft(2, '0')}:${entryTime!.minute.toString().padLeft(2, '0')}:00";
                              final exitStr = "${exitTime!.hour.toString().padLeft(2, '0')}:${exitTime!.minute.toString().padLeft(2, '0')}:00";

                              final targetId = int.tryParse(selectedUser['id'].toString()) ?? 0;
                              final success = await _apiService.syncAttendanceRecord(
                                timetableId,
                                targetId,
                                currentUserId,
                                dateStr,
                                entryTime: entryStr,
                                exitTime: exitStr,
                              );

                              if (success) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text("Attendance marked for ${selectedUser['name'] ?? selectedUser['full_name']}")),
                                  );
                                }
                                Navigator.pop(ctx);
                                _fetchData();
                              } else {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text("Failed to mark attendance")),
                                  );
                                }
                              }
                            },
                            child: const Text("Mark Attendance"),
                          ),
                        ),
                      ],
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text("Close"),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildDayDetails(DateTime day) {
    final dateStr = DateFormat('yyyy-MM-dd').format(day);
    final dayName = DateFormat('EEEE').format(day);
    final now = DateTime.now();
    final isToday = isSameDay(day, now);
    final isFuture = day.isAfter(now) && !isToday;
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final primaryColor = const Color(0xFF0078D4);

    final scheduledActivities = _timetable.where((t) {
      final days = (t['day_of_week'] as String?)?.split(',') ?? [];
      return days.contains(dayName);
    }).toList();

    final filteredActivities = _selectedActivityIndex == 0 
        ? scheduledActivities
        : scheduledActivities.where((t) => t['activity_name'] == _summary[_selectedActivityIndex - 1]['activity_name']).toList();

    if (filteredActivities.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: onSurface.withOpacity(0.05),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          'No activity scheduled for this day.',
          style: TextStyle(color: onSurface.withOpacity(0.7)),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 5, bottom: 15),
          child: Text(
            DateFormat('MMMM d, yyyy').format(day),
            style: TextStyle(
              color: onSurface.withOpacity(0.7),
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
        ),
        ...filteredActivities.map((act) {
        final activitySummary = _summary.firstWhere(
          (s) => s['activity_name'].toString().trim().toUpperCase() == act['activity_name'].toString().trim().toUpperCase(),
          orElse: () => {},
        );

        final List<String> presentDates = _safeStringList(activitySummary['present_dates']);
        final List<String> allDates = _safeStringList(activitySummary['all_dates']);

        final List<dynamic> sessions = List<dynamic>.from(activitySummary['sessions'] ?? []);
        final session = sessions.firstWhere(
          (s) => _extractDate(s['session_date'] ?? s['date']) == dateStr && s['time_range'] == act['time_range'],
          orElse: () => null,
        );

        final bool hasRecord = session != null;
        final bool isPresent = session?['is_present'] == true;
        
        String statusText = isFuture ? 'Upcoming' : 'Absent';
        Color statusColor = isFuture ? primaryColor : Colors.red;
        IconData statusIcon = isFuture ? Icons.event : Icons.cancel;

        if (hasRecord) {
          if (isPresent) {
            statusText = 'Present';
            statusColor = Colors.green;
            statusIcon = Icons.check_circle;
          } else {
            statusText = 'Absent';
            statusColor = Colors.red;
            statusIcon = Icons.cancel;
          }
        } else if (!isFuture && !isToday) {
          statusText = 'No Session';
          statusColor = Colors.grey;
          statusIcon = Icons.info_outline;
        } else if (isToday) {
           statusText = 'Scheduled Today';
           statusColor = Colors.orange;
           statusIcon = Icons.today;
        }

        final bool canUpload = Provider.of<NodeRoleProvider>(context, listen: false).canUpload;

        final cardWidget = Container(
          margin: const EdgeInsets.only(bottom: 15),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: onSurface.withOpacity(0.05),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: statusColor.withOpacity(0.3),
            ),
          ),
          child: Row(
            children: [
              Icon(statusIcon, color: statusColor, size: 30),
              const SizedBox(width: 15),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      act['activity_name'] ?? 'Activity',
                      style: TextStyle(
                        color: onSurface,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      statusText,
                      style: TextStyle(
                        color: statusColor,
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                    Text(
                      "Schedule: ${act['time_range']}\nActual: ${_formatTime12h(session?['entry_time'])} - ${_formatTime12h(session?['exit_time'])}",
                      style: TextStyle(color: onSurface.withOpacity(0.5), fontSize: 11),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );

        if (canUpload) {
          return InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () => _showManageAttendanceDialog(act, session, dateStr),
            child: cardWidget,
          );
        }
        return cardWidget;
      }).toList(),
    ],
  );
}

String _formatTime12h(dynamic timeStr) {
  if (timeStr == null || timeStr.toString().isEmpty || timeStr == '--:--') return '--:--';
  try {
    String str = timeStr.toString();
    // Handle ISO strings like 1970-01-01T14:30:00.000Z
    if (str.contains('T')) {
      str = str.split('T')[1].split('.')[0]; 
    }
    
    final parts = str.split(':');
    if (parts.length < 2) return str;
    int hour = int.parse(parts[0]);
    int minute = int.parse(parts[1]);
    final ampm = hour >= 12 ? 'PM' : 'AM';
    hour = hour % 12;
    if (hour == 0) hour = 12;
    return "${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')} $ampm";
  } catch (e) {
    return timeStr.toString();
  }
}
}

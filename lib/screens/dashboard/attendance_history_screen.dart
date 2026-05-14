import 'package:flutter/material.dart';
import '../../services/api_service.dart';
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
    final userId =
        Provider.of<NodeRoleProvider>(context, listen: false).currentUserNode?.id ?? '';
    
    final summaryData = await _apiService.fetchAttendanceSummary(userId);
    final timetableData = await _apiService.fetchUserTimetable(userId);

    if (mounted) {
      setState(() {
        _summary = List<Map<String, dynamic>>.from(summaryData);
        _timetable = List<Map<String, dynamic>>.from(timetableData);
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

  Map<String, dynamic> get _currentActivityData {
    if (_selectedActivityIndex == 0) {
      final Set<String> allDates = {};
      final Set<String> presentDates = {};
      for (final act in _summary) {
        allDates.addAll(List<String>.from(act['all_dates'] ?? []));
        presentDates.addAll(List<String>.from(act['present_dates'] ?? []));
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
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildCalendarView(_currentActivityData),
          ..._summary.map((act) => _buildCalendarView(act)),
        ],
      ),
    );
  }

  Widget _buildCalendarView(Map<String, dynamic> data) {
    final allDates = List<String>.from(data['all_dates'] ?? []);
    final presentDates = List<String>.from(data['present_dates'] ?? []);
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
          (s) => s['activity_name'] == act['activity_name'],
          orElse: () => {},
        );

        final List<String> presentDates = List<String>.from(activitySummary['present_dates'] ?? []);
        final List<String> allDates = List<String>.from(activitySummary['all_dates'] ?? []);

        final bool hasRecord = allDates.contains(dateStr);
        final bool isPresent = presentDates.contains(dateStr);
        
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

        return Container(
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
                      act['time_range'] ?? '',
                      style: TextStyle(color: onSurface.withOpacity(0.5), fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      }).toList(),
    ],
  );
}
}

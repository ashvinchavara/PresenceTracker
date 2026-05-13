import 'package:flutter/material.dart';
import '../../services/api_service.dart';
import '../../providers/node_role_provider.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:table_calendar/table_calendar.dart';

class AttendanceHistoryScreen extends StatefulWidget {
  const AttendanceHistoryScreen({super.key});

  @override
  State<AttendanceHistoryScreen> createState() => _AttendanceHistoryScreenState();
}

class _AttendanceHistoryScreenState extends State<AttendanceHistoryScreen>
    with SingleTickerProviderStateMixin {
  final ApiService _apiService = ApiService();

  List<Map<String, dynamic>> _summary = []; // per-activity data
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
    final data = await _apiService.fetchAttendanceSummary(userId);
    if (mounted) {
      setState(() {
        _summary = data;
        _isLoading = false;
        _selectedDay = DateTime.now();
        // +1 for the "All" tab
        _tabController = TabController(length: data.length + 1, vsync: this);
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

  // ─── Computed values ───────────────────────────────────────────────────────

  /// Overall percentage: sum of all user_present / sum of all total_sessions
  double get _overallPercentage {
    int totalSessions = 0;
    int totalPresent = 0;
    for (final act in _summary) {
      totalSessions += (act['total_sessions'] as num).toInt();
      totalPresent += (act['user_present'] as num).toInt();
    }
    if (totalSessions == 0) return 0;
    return (totalPresent / totalSessions) * 100;
  }

  /// Activity-specific percentage
  double _activityPercentage(Map<String, dynamic> act) {
    final total = (act['total_sessions'] as num).toInt();
    final present = (act['user_present'] as num).toInt();
    if (total == 0) return 0;
    return (present / total) * 100;
  }

  // ─── Calendar coloring ─────────────────────────────────────────────────────

  /// Returns the current filter's data: either a specific activity or merged "All"
  Map<String, dynamic> get _currentActivityData {
    if (_selectedActivityIndex == 0) {
      // Merge all activities
      final Set<String> allDates = {};
      final Set<String> presentDates = {};
      for (final act in _summary) {
        allDates.addAll(List<String>.from(act['all_dates'] ?? []));
        presentDates.addAll(List<String>.from(act['present_dates'] ?? []));
      }
      return {
        'all_dates': allDates.toList(),
        'present_dates': presentDates.toList(),
      };
    }
    return _summary[_selectedActivityIndex - 1];
  }

  String _getStatus(DateTime day) {
    final now = DateTime.now();
    final normalizedNow = DateTime(now.year, now.month, now.day);
    final normalizedDay = DateTime(day.year, day.month, day.day);
    if (normalizedDay.isAfter(normalizedNow)) return 'future';

    final dayStr = DateFormat('yyyy-MM-dd').format(normalizedDay);
    final data = _currentActivityData;
    final allDates = List<String>.from(data['all_dates'] ?? []);
    final presentDates = List<String>.from(data['present_dates'] ?? []);

    if (presentDates.contains(dayStr)) return 'present';   // Green
    if (allDates.contains(dayStr)) return 'absent';        // Red  (date existed, user not marked)
    return 'holiday';                                       // Grey (not in attendance table)
  }

  // ─── Helpers ───────────────────────────────────────────────────────────────

  String _fmt(double pct) => '${pct.toStringAsFixed(1)}%';

  Color _pctColor(double pct) {
    if (pct >= 75) return Colors.green;
    if (pct >= 50) return Colors.orange;
    return Colors.red;
  }

  // ─── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_isLoading || _tabController == null) {
      return const Scaffold(
        appBar: null,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_summary.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Attendance Calendar')),
        body: const Center(child: Text('No activities assigned.')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Attendance Calendar'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(72),
          child: Column(
            children: [
              // Overall chip
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Row(
                  children: [
                    const Text('Overall: ', style: TextStyle(fontSize: 12, color: Colors.grey)),
                    Text(
                      _fmt(_overallPercentage),
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        color: _pctColor(_overallPercentage),
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${_summary.fold<int>(0, (s, a) => s + (a['user_present'] as num).toInt())} / '
                      '${_summary.fold<int>(0, (s, a) => s + (a['total_sessions'] as num).toInt())} sessions',
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                  ],
                ),
              ),
              // Tabs: All + per-activity
              TabBar(
                controller: _tabController,
                isScrollable: true,
                labelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                unselectedLabelStyle: const TextStyle(fontSize: 11),
                tabs: [
                  Tab(text: 'All  ${_fmt(_overallPercentage)}'),
                  ..._summary.map((act) {
                    final pct = _activityPercentage(act);
                    return Tab(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(act['activity_name'] ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
                          Text(_fmt(pct),
                              style: TextStyle(fontSize: 10, color: _pctColor(pct))),
                        ],
                      ),
                    );
                  }),
                ],
              ),
            ],
          ),
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    // Selected-day records for activity list
    List<Map<String, dynamic>> dayRecords = [];
    if (_selectedDay != null) {
      final dayStr = DateFormat('yyyy-MM-dd').format(_selectedDay!);
      final activitiesToCheck =
          _selectedActivityIndex == 0 ? _summary : [_summary[_selectedActivityIndex - 1]];
      for (final act in activitiesToCheck) {
        final allDates = List<String>.from(act['all_dates'] ?? []);
        final presentDates = List<String>.from(act['present_dates'] ?? []);
        if (presentDates.contains(dayStr)) {
          dayRecords.add({
            'activity_name': act['activity_name'],
            'time_range': act['time_range'],
            'status': 'Present',
          });
        } else if (allDates.contains(dayStr)) {
          dayRecords.add({
            'activity_name': act['activity_name'],
            'time_range': act['time_range'],
            'status': 'Absent',
          });
        }
      }
    }

    return Column(
      children: [
        // ── Calendar ──
        TableCalendar(
          firstDay: DateTime.utc(2023, 1, 1),
          lastDay: DateTime.now(),
          focusedDay: _focusedDay,
          calendarFormat: CalendarFormat.month,
          availableCalendarFormats: const {CalendarFormat.month: 'Month'},
          selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
          onDaySelected: (selected, focused) {
            setState(() {
              _selectedDay = selected;
              _focusedDay = focused;
            });
          },
          calendarStyle: const CalendarStyle(
            todayDecoration: BoxDecoration(color: Colors.blueGrey, shape: BoxShape.circle),
            selectedDecoration: BoxDecoration(color: Color(0xFF0078D4), shape: BoxShape.circle),
          ),
          calendarBuilders: CalendarBuilders(
            defaultBuilder: (ctx, day, _) {
              final status = _getStatus(day);
              Color? textColor;
              BoxDecoration? decoration;

              switch (status) {
                case 'present':
                  decoration = BoxDecoration(color: Colors.green.withOpacity(0.25), shape: BoxShape.circle);
                  textColor = Colors.green;
                  break;
                case 'absent':
                  decoration = BoxDecoration(color: Colors.red.withOpacity(0.15), shape: BoxShape.circle);
                  textColor = Colors.red;
                  break;
                case 'holiday':
                  decoration = BoxDecoration(color: Colors.grey.withOpacity(0.15), shape: BoxShape.circle);
                  textColor = Colors.grey;
                  break;
                default:
                  break; // future — no decoration
              }

              return Container(
                margin: const EdgeInsets.all(4),
                alignment: Alignment.center,
                decoration: decoration,
                child: Text('${day.day}', style: TextStyle(color: textColor, fontSize: 13)),
              );
            },
            outsideBuilder: (ctx, day, _) => Container(
              margin: const EdgeInsets.all(4),
              alignment: Alignment.center,
              child: Text('${day.day}', style: const TextStyle(color: Colors.grey, fontSize: 11)),
            ),
          ),
        ),

        // ── Legend ──
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: const [
              _LegendDot(color: Colors.green, label: 'Present'),
              SizedBox(width: 16),
              _LegendDot(color: Colors.red, label: 'Absent'),
              SizedBox(width: 16),
              _LegendDot(color: Colors.grey, label: 'Holiday'),
            ],
          ),
        ),

        const Divider(height: 1),

        // ── Day detail header ──
        if (_selectedDay != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.event, size: 16, color: Colors.grey),
                const SizedBox(width: 8),
                Text(
                  DateFormat('dd MMM yyyy').format(_selectedDay!),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                if (dayRecords.isNotEmpty)
                  Chip(
                    label: Text('${dayRecords.length} present',
                        style: const TextStyle(fontSize: 11, color: Colors.white)),
                    backgroundColor: Colors.green,
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ),

        // ── Activity list for selected day ──
        Expanded(
          child: dayRecords.isEmpty
              ? Center(
                  child: Text(
                    _selectedDay == null
                        ? 'Select a date'
                        : 'No attendance recorded for this day',
                    style: const TextStyle(color: Colors.grey),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: dayRecords.length,
                  itemBuilder: (ctx, i) {
                    final rec = dayRecords[i];
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: rec['status'] == 'Present' ? Colors.green : Colors.red,
                          radius: 15,
                          child: Icon(
                            rec['status'] == 'Present' ? Icons.check : Icons.close,
                            color: Colors.white,
                            size: 16,
                          ),
                        ),
                        title: Text(rec['activity_name'] ?? '',
                            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                        subtitle: Text(rec['time_range'] ?? '',
                            style: const TextStyle(fontSize: 12)),
                        trailing: Text(rec['status'] ?? '',
                            style: TextStyle(
                                color: rec['status'] == 'Present' ? Colors.green : Colors.red,
                                fontWeight: FontWeight.bold,
                                fontSize: 12)),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// Small coloured legend dot
class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;
  const _LegendDot({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 11)),
      ],
    );
  }
}

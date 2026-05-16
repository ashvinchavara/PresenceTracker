import 'package:flutter/material.dart';
import '../../services/api_service.dart';
import '../../services/test_service.dart';
import '../../providers/node_role_provider.dart';
import 'package:provider/provider.dart';
import '../../core/api_config.dart';
import 'package:cached_network_image/cached_network_image.dart';

class FullTimetableScreen extends StatefulWidget {
  const FullTimetableScreen({super.key});

  @override
  State<FullTimetableScreen> createState() => _FullTimetableScreenState();
}

class _FullTimetableScreenState extends State<FullTimetableScreen> {
  final ApiService _apiService = ApiService();
  List<Map<String, dynamic>> _timetable = [];
  List<Map<String, dynamic>> _summary = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _fetchData();
  }

  Future<void> _fetchData() async {
    final userProvider = Provider.of<NodeRoleProvider>(context, listen: false);
    final userId = userProvider.currentUserNode?.id ?? '';
    
    List<Map<String, dynamic>> timetableData = [];
    List<Map<String, dynamic>> summaryData = [];

    if (userProvider.isTestMode) {
      timetableData = TestService().getTestActivities();
      summaryData = [
        {'activity_name': 'Test Activity 1', 'total_sessions': 1, 'user_present': 1},
        {'activity_name': 'Test Activity 2', 'total_sessions': 1, 'user_present': 0},
        {'activity_name': 'Test Activity 3', 'total_sessions': 1, 'user_present': 0},
      ];
    } else {
      final results = await Future.wait([
        _apiService.fetchUserTimetable(userId),
        _apiService.fetchAttendanceSummary(userId),
      ]);
      timetableData = List<Map<String, dynamic>>.from(results[0]);
      summaryData = List<Map<String, dynamic>>.from(results[1]);
    }

    if (mounted) {
      setState(() {
        _timetable = timetableData;
        _summary = summaryData;
        _isLoading = false;
      });
    }
  }

  double _getActivityPercentage(String? activityName) {
    if (activityName == null) return 0.0;
    final item = _summary.firstWhere(
      (s) => s['activity_name'] == activityName,
      orElse: () => {},
    );
    if (item.isEmpty) return 0.0;
    final int total = item['total_sessions'] ?? 0;
    final int present = item['user_present'] ?? 0;
    return total > 0 ? present / total : 0.0;
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
                                ? Icon(hasPower ? Icons.verified : Icons.person, 
                                    color: hasPower ? Colors.white : Colors.grey)
                                : null,
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

  @override
  Widget build(BuildContext context) {
    // Group timetable by day
    Map<String, List<Map<String, dynamic>>> grouped = {};
    for (var item in _timetable) {
      String day = item['day_of_week'] ?? 'Unknown';
      if (!grouped.containsKey(day)) grouped[day] = [];
      grouped[day]!.add(item);
    }

    List<String> days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

    return Scaffold(
      appBar: AppBar(title: const Text('Full Timetable')),
      body: Column(
        children: [
          if (Provider.of<NodeRoleProvider>(context).isTestMode)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 8),
              color: Colors.orange,
              child: const Center(
                child: Text(
                  'YOU ARE ON TEST MODE (Displaying Simulated Timetable)',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                ),
              ),
            ),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _timetable.isEmpty
                    ? const Center(child: Text('No timetable entries found.'))
                    : ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: days.length,
                        itemBuilder: (context, index) {
                            String day = days[index];
                          List<Map<String, dynamic>> activities = grouped[day] ?? [];
                          if (activities.isEmpty) return const SizedBox.shrink();

                          // Sort activities by time
                          activities.sort((a, b) {
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
                            final startA = (a['time_range'] as String?)?.split(' - ').first;
                            final startB = (b['time_range'] as String?)?.split(' - ').first;
                            return toMinutes(startA).compareTo(toMinutes(startB));
                          });

                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.symmetric(vertical: 8.0),
                                child: Text(
                                  day,
                                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF0078D4)),
                                ),
                              ),
                              ...activities.map((act) {
                                final onSurface = Theme.of(context).colorScheme.onSurface;
                                const statusColor = Colors.grey;
                                
                                return GestureDetector(
                                  onTap: () => _showScheduleDetails(act),
                                  child: Container(
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
                                        SizedBox(
                                          width: 40,
                                          height: 40,
                                          child: Stack(
                                            alignment: Alignment.center,
                                            children: [
                                              CircularProgressIndicator(
                                                value: _getActivityPercentage(act['activity_name']),
                                                strokeWidth: 4,
                                                backgroundColor: statusColor.withOpacity(0.1),
                                                valueColor: AlwaysStoppedAnimation<Color>(
                                                  _getActivityPercentage(act['activity_name']) >= 0.75 ? Colors.green :
                                                  (_getActivityPercentage(act['activity_name']) >= 0.5 ? Colors.orange : Colors.red)
                                                ),
                                              ),
                                              Text(
                                                "${(_getActivityPercentage(act['activity_name']) * 100).toInt()}%",
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
                                                "${act['time_range'] ?? 'Anytime'} • ${act['target_node_name'] ?? ''}",
                                                style: TextStyle(color: onSurface.withOpacity(0.5), fontSize: 12),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              }),
                              const SizedBox(height: 16),
                            ],
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

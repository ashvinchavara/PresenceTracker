import 'package:flutter/material.dart';
import '../../services/api_service.dart';
import '../../providers/node_role_provider.dart';
import 'package:provider/provider.dart';

class FullTimetableScreen extends StatefulWidget {
  const FullTimetableScreen({super.key});

  @override
  State<FullTimetableScreen> createState() => _FullTimetableScreenState();
}

class _FullTimetableScreenState extends State<FullTimetableScreen> {
  final ApiService _apiService = ApiService();
  List<Map<String, dynamic>> _timetable = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _fetchTimetable();
  }

  Future<void> _fetchTimetable() async {
    final userId = Provider.of<NodeRoleProvider>(context, listen: false).currentUserNode?.id ?? '';
    final data = await _apiService.fetchUserTimetable(userId);
    if (mounted) {
      setState(() {
        _timetable = data;
        _isLoading = false;
      });
    }
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
      body: _isLoading
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
                      final timeA = (a['time_range'] as String?)?.split(' - ').first ?? '00:00';
                      final timeB = (b['time_range'] as String?)?.split(' - ').first ?? '00:00';
                      return timeA.compareTo(timeB);
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
                        ...activities.map((act) => Card(
                              margin: const EdgeInsets.only(bottom: 8),
                              child: InkWell(
                                onTap: () => _showScheduleDetails(act),
                                child: ListTile(
                                  leading: const Icon(Icons.access_time, color: Color(0xFF0078D4)),
                                  title: Text(act['activity_name'] ?? 'Activity'),
                                  subtitle: Text("${act['time_range'] ?? 'Anytime'} • ${act['target_node_name'] ?? ''}"),
                                ),
                              ),
                            )),
                        const SizedBox(height: 16),
                      ],
                    );
                  },
                ),
    );
  }
}

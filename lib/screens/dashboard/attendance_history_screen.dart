import 'package:flutter/material.dart';
import '../../services/api_service.dart';
import '../../providers/node_role_provider.dart';
import 'package:provider/provider.dart';

class AttendanceHistoryScreen extends StatefulWidget {
  const AttendanceHistoryScreen({super.key});

  @override
  State<AttendanceHistoryScreen> createState() => _AttendanceHistoryScreenState();
}

class _AttendanceHistoryScreenState extends State<AttendanceHistoryScreen> {
  final ApiService _apiService = ApiService();
  List<Map<String, dynamic>> _attendanceHistory = [];
  bool _isLoading = true;
  DateTime? _selectedDate;

  @override
  void initState() {
    super.initState();
    _fetchHistory();
  }

  Future<void> _fetchHistory() async {
    final userId = Provider.of<NodeRoleProvider>(context, listen: false).currentUserNode?.id ?? '';
    final data = await _apiService.fetchAttendanceHistory(userId);
    if (mounted) {
      setState(() {
        _attendanceHistory = data;
        _isLoading = false;
      });
    }
  }

  void _selectDate(BuildContext context) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate ?? DateTime.now(),
      firstDate: DateTime(2023),
      lastDate: DateTime.now(),
    );
    if (picked != null && picked != _selectedDate) {
      setState(() {
        _selectedDate = picked;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    List<Map<String, dynamic>> filtered = _attendanceHistory;
    if (_selectedDate != null) {
      final dateStr = _selectedDate!.toIso8601String().split('T')[0];
      filtered = _attendanceHistory.where((rec) => rec['date'] == dateStr).toList();
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Attendance History'),
        actions: [
          IconButton(
            icon: const Icon(Icons.calendar_today),
            onPressed: () => _selectDate(context),
          ),
          if (_selectedDate != null)
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () => setState(() => _selectedDate = null),
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _attendanceHistory.isEmpty
              ? const Center(child: Text('No attendance records found.'))
              : Column(
                  children: [
                    if (_selectedDate != null)
                      Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: Text(
                          "Filtered for: ${_selectedDate!.toIso8601String().split('T')[0]}",
                          style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF0078D4)),
                        ),
                      ),
                    Expanded(
                      child: ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: filtered.length,
                        itemBuilder: (context, index) {
                          final rec = filtered[index];
                          return Card(
                            margin: const EdgeInsets.only(bottom: 12),
                            child: ListTile(
                              leading: const CircleAvatar(
                                backgroundColor: const Color(0xFF0078D4),
                                child: Icon(Icons.check, color: Colors.white),
                              ),
                              title: Text(rec['activity_name'] ?? 'Task'),
                              subtitle: Text("${rec['date']} | ${rec['time_range']}"),
                              trailing: Text(
                                rec['status'] ?? 'Checked',
                                style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.green),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
    );
  }
}

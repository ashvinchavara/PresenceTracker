import 'package:intl/intl.dart';

class TestService {
  static final TestService _instance = TestService._internal();
  factory TestService() => _instance;
  TestService._internal();

  List<Map<String, dynamic>> getTestActivities() {
    final now = DateTime.now();
    
    // Test activity 1: end time 5 minutes before current time
    final t1End = now.subtract(const Duration(minutes: 5));
    final t1Start = t1End.subtract(const Duration(minutes: 5));

    // Test activity 2: start time 1 minute after current time
    final t2Start = now.add(const Duration(minutes: 1));
    final t2End = t2Start.add(const Duration(minutes: 5));

    // Test activity 3: start time 1 minute after activity 2 end time
    final t3Start = t2End.add(const Duration(minutes: 1));
    final t3End = t3Start.add(const Duration(minutes: 5));

    final dateFormat = DateFormat('hh:mm a');

    return [
      {
        'id': 'test_1',
        'activity_name': 'Test Activity 1',
        'time_range': '${dateFormat.format(t1Start)} - ${dateFormat.format(t1End)}',
        'day_of_week': _getDayName(t1Start),
        'is_test': true,
      },
      {
        'id': 'test_2',
        'activity_name': 'Test Activity 2',
        'time_range': '${dateFormat.format(t2Start)} - ${dateFormat.format(t2End)}',
        'day_of_week': _getDayName(t2Start),
        'is_test': true,
      },
      {
        'id': 'test_3',
        'activity_name': 'Test Activity 3',
        'time_range': '${dateFormat.format(t3Start)} - ${dateFormat.format(t3End)}',
        'day_of_week': _getDayName(t3Start),
        'is_test': true,
      },
    ];
  }

  String _getDayName(DateTime date) {
    return DateFormat('EEEE').format(date);
  }
}

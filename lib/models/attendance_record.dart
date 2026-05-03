class AttendanceRecord {
  final String subject;
  final String time;
  final String timestamp;
  final int presentCount;
  final Map<String, dynamic> students;

  AttendanceRecord({
    required this.subject,
    required this.time,
    required this.timestamp,
    required this.presentCount,
    required this.students,
  });

  Map<String, dynamic> toMap() {
    return {
      'subject': subject,
      'time': time,
      'timestamp': timestamp,
      'presentCount': presentCount,
      'students': students, // Map of userId to Map {'name': name, 'entry': timestamp}
    };
  }

  factory AttendanceRecord.fromMap(Map<dynamic, dynamic> data) {
    return AttendanceRecord(
      subject: data['subject'] ?? '',
      time: data['time'] ?? '',
      timestamp: data['timestamp'] ?? '',
      presentCount: data['presentCount'] ?? 0,
      students: data['students'] != null ? Map<String, dynamic>.from(data['students']) : {},
    );
  }
}

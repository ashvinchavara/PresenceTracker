import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/user_node.dart';
import '../models/attendance_record.dart';
import '../core/api_config.dart';

class ApiService {

  /// Login with email and password to the Node.js/MySQL backend
  Future<UserNode?> login(String email, String password) async {
    try {
      final response = await http.post(
        Uri.parse('${ApiConfig.baseUrl}/login'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': email, 'password': password}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return UserNode.fromMap(data['user']);
      } else {
        final errorData = jsonDecode(response.body);
        throw Exception(errorData['error'] ?? 'Login failed');
      }
    } catch (e) {
      print('API Error (login): $e');
      rethrow;
    }
  }

  /// Fetch a single user profile by ID
  Future<UserNode?> getCurrentUserNode(String uid) async {
    try {
      final response = await http.get(Uri.parse('${ApiConfig.baseUrl}/users'));
      if (response.statusCode == 200) {
        final List<dynamic> users = jsonDecode(response.body);
        final match = users.firstWhere(
          (u) => u['id'].toString() == uid,
          orElse: () => null,
        );
        if (match != null) return UserNode.fromMap(match);
      }
    } catch (e) {
      print('API Error (getCurrentUserNode): $e');
    }
    return null;
  }

  /// Sync attendance: POST to /attendance with timetable_id, user_id, marked_by, date
  Future<void> syncAttendanceRecord(
      int timetableId,
      int userId,
      int markedById,
      String date) async {
    try {
      final response = await http.post(
        Uri.parse('${ApiConfig.baseUrl}/attendance'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'timetable_id': timetableId,
          'user_id': userId,
          'marked_by': markedById,
          'date': date,
        }),
      );

      if (response.statusCode == 200) {
        print('Attendance sync successful.');
      } else {
        throw Exception('Failed to sync. Server responded: ${response.body}');
      }
    } catch (e) {
      print('Attendance sync failed via API: $e');
      rethrow;
    }
  }

  /// Fetch overall attendance percentage for the dashboard
  Future<double> fetchDashboardStats(String userId) async {
    try {
      final response = await http.get(
        Uri.parse('${ApiConfig.baseUrl}/dashboard_stats/$userId'),
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return double.tryParse(data['attendance_percentage'].toString()) ?? 0.0;
      }
    } catch (e) {
      print('Error fetching stats: $e');
    }
    return 0.0;
  }

  /// Fetch timetable entries assigned to a specific user
  /// Returns list of maps with keys: id, activity_name, time_range, target_node_name, day_of_week
  Future<List<Map<String, dynamic>>> fetchUserTimetable(String userId) async {
    try {
      final response = await http.get(
        Uri.parse('${ApiConfig.baseUrl}/user_timetable/$userId'),
      );
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data.cast<Map<String, dynamic>>();
      }
    } catch (e) {
      print('Error fetching timetable: $e');
    }
    return [];
  }

  /// Fetch attendance history (past records) for a user
  /// Returns list of maps with keys: date, activity_name, time_range, status
  Future<List<Map<String, dynamic>>> fetchAttendanceHistory(String userId) async {
    try {
      final response = await http.get(
        Uri.parse('${ApiConfig.baseUrl}/attendance_history/$userId'),
      );
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data.cast<Map<String, dynamic>>();
      }
    } catch (e) {
      print('Error fetching attendance history: $e');
    }
    return [];
  }

  /// Fetch all personnel assigned to a specific timetable/schedule slot
  /// Returns map with key 'members' containing list of user objects
  Future<Map<String, dynamic>?> fetchScheduleMembers(int scheduleId) async {
    try {
      final response = await http.get(
        Uri.parse('${ApiConfig.baseUrl}/schedule_members/$scheduleId'),
      );
      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
    } catch (e) {
      print('Error fetching schedule members: $e');
    }
    return null;
  }

  /// Change user password (requires old password verification)
  Future<bool> changePassword(String email, String oldPassword, String newPassword) async {
    try {
      final response = await http.post(
        Uri.parse('${ApiConfig.baseUrl}/change-password'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'email': email,
          'oldPassword': oldPassword,
          'newPassword': newPassword,
        }),
      );

      if (response.statusCode == 200) {
        return true;
      } else {
        final errorData = jsonDecode(response.body);
        throw Exception(errorData['error'] ?? 'Failed to change password');
      }
    } catch (e) {
      print('Change Password Error: $e');
      rethrow;
    }
  }

  /// Reset password (admin/self-service — no old password required)
  Future<bool> resetPassword(String email, String newPassword) async {
    try {
      final response = await http.post(
        Uri.parse('${ApiConfig.baseUrl}/reset-password'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': email, 'newPassword': newPassword}),
      );

      if (response.statusCode == 200) {
        return true;
      } else {
        final errorData = jsonDecode(response.body);
        throw Exception(errorData['error'] ?? 'Failed to reset password');
      }
    } catch (e) {
      print('Reset Password Error: $e');
      rethrow;
    }
  }

  /// Fetch roles authorized to upload attendance (from settings table)
  Future<List<String>> fetchAllowedUploadRoles() async {
    try {
      final response = await http.get(
        Uri.parse('${ApiConfig.baseUrl}/settings/upload_roles'),
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['value'] != null) {
          final List<dynamic> roles = jsonDecode(data['value']);
          return roles.cast<String>();
        }
      }
    } catch (e) {
      print('Error fetching allowed upload roles: $e');
    }
    return [];
  }

  /// Health check — returns true if the MySQL backend is reachable
  Future<bool> checkHealth() async {
    try {
      final response = await http
          .get(Uri.parse('${ApiConfig.baseUrl}/health'))
          .timeout(const Duration(seconds: 3));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final connected = data['database'] == 'connected';
        if (connected) print('Backend Health Check: SUCCESS');
        return connected;
      }
    } catch (e) {
      print('Health Check Failed: $e');
    }
    return false;
  }
}

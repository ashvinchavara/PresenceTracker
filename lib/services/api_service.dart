import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user_node.dart';
import '../core/api_config.dart';
import 'database_service.dart';

class ApiService {
  final DatabaseService _db = DatabaseService();

  /// Generic fetch with caching
  Future<dynamic> _fetchWithCache(String path, {bool forceRefresh = false}) async {
    final cacheKey = path;
    
    // Try network first
    try {
      final response = await http.get(Uri.parse('${ApiConfig.baseUrl}$path'));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        await _db.saveCache(cacheKey, data);
        return data;
      }
    } catch (e) {
      print('Network error for $path: $e. Falling back to cache.');
    }

    // Fallback to cache
    return await _db.getCache(cacheKey);
  }

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
  Future<bool> syncAttendanceRecord(
      int timetableId,
      int userId,
      int markedById,
      String date, {
      String? entryTime,
      String? exitTime,
  }) async {
    try {
      final response = await http.post(
        Uri.parse('${ApiConfig.baseUrl}/attendance'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'timetable_id': timetableId,
          'user_id': userId,
          'marked_by': markedById,
          'date': date,
          if (entryTime != null) 'entry_time': entryTime,
          if (exitTime != null) 'exit_time': exitTime,
        }),
      );

      if (response.statusCode == 200) {
        print('Attendance sync successful.');
        return true;
      } else {
        print('Failed to sync. Server responded: ${response.body}');
        return false;
      }
    } catch (e) {
      print('Attendance sync failed via API: $e');
      return false;
    }
  }

  /// Fetch overall attendance percentage for the dashboard
  Future<double> fetchDashboardStats(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('is_test_mode') ?? false) {
      return 100.0;
    }

    final data = await _fetchWithCache('/dashboard_stats/$userId');
    if (data != null) {
      return double.tryParse(data['attendance_percentage'].toString()) ?? 0.0;
    }
    return 0.0;
  }

  Future<List<Map<String, dynamic>>> fetchUserTimetable(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('is_test_mode') ?? false) {
      final tasksJson = prefs.getString('test_mode_tasks');
      if (tasksJson != null) {
        return (jsonDecode(tasksJson) as List<dynamic>).cast<Map<String, dynamic>>();
      }
    }

    final data = await _fetchWithCache('/user_timetable/$userId');
    if (data != null) {
      return (data as List<dynamic>).cast<Map<String, dynamic>>();
    }
    return [];
  }

  Future<List<Map<String, dynamic>>> fetchAttendanceHistory(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('is_test_mode') ?? false) {
      return [
        {
          'id': 9901,
          'activity_name': 'Test Activity 1',
          'department': 'Test Dept',
          'date': DateTime.now().toIso8601String().split('T')[0],
          'entry_time': DateTime.now().subtract(const Duration(minutes: 9)).toIso8601String(),
          'exit_time': DateTime.now().subtract(const Duration(minutes: 6)).toIso8601String(),
        }
      ];
    }

    final data = await _fetchWithCache('/attendance_history/$userId');
    if (data != null) {
      return (data as List<dynamic>).cast<Map<String, dynamic>>();
    }
    return [];
  }

  /// Fetch per-activity attendance summary for a user.
  /// Returns list with: timetable_id, activity_name, time_range,
  ///   total_sessions, user_present, all_dates (List<String>), present_dates (List<String>)
  Future<List<Map<String, dynamic>>> fetchAttendanceSummary(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('is_test_mode') ?? false) {
      return [
        {
          'timetable_id': 9901,
          'activity_name': 'Test Activity 1',
          'time_range': 'Test',
          'total_sessions': 1,
          'user_present': 1,
          'all_dates': [DateTime.now().toIso8601String().split('T')[0]],
          'present_dates': [DateTime.now().toIso8601String().split('T')[0]],
        }
      ];
    }

    final data = await _fetchWithCache('/attendance_summary/$userId');
    if (data != null) {
      return (data as List<dynamic>).cast<Map<String, dynamic>>();
    }
    return [];
  }

  /// Fetch all personnel assigned to a specific timetable/schedule slot
  /// Returns map with key 'members' containing list of user objects
  Future<Map<String, dynamic>?> fetchScheduleMembers(int scheduleId) async {
    final data = await _fetchWithCache('/schedule_members/$scheduleId');
    if (data != null) {
      return data as Map<String, dynamic>;
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
          .timeout(const Duration(seconds: 10));
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

  /// Fetch DB status (cloud vs local)
  Future<String> fetchDbStatus() async {
    try {
      final response = await http
          .get(Uri.parse('${ApiConfig.baseUrl}/db-status'))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['mode'] ?? 'unknown';
      }
    } catch (e) {
      print('Error fetching DB status: $e');
    }
    return 'offline';
  }

  /// Grant temporary upload power to another user for a specific schedule and today's date
  Future<bool> grantTemporaryPower(int targetUserId, int timetableId, int grantorId) async {
    try {
      final response = await http.post(
        Uri.parse('${ApiConfig.baseUrl}/grant_temporary_power'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'user_id': targetUserId,
          'timetable_id': timetableId,
          'granted_by': grantorId,
        }),
      );
      return response.statusCode == 200;
    } catch (e) {
      print('Error granting temporary power: $e');
      return false;
    }
  }

  /// Revoke temporary upload power from another user for a specific schedule and today's date
  Future<bool> revokeTemporaryPower(int targetUserId, int timetableId) async {
    try {
      final response = await http.post(
        Uri.parse('${ApiConfig.baseUrl}/revoke_temporary_power'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'user_id': targetUserId,
          'timetable_id': timetableId,
        }),
      );
      return response.statusCode == 200;
    } catch (e) {
      print('Error revoking temporary power: $e');
      return false;
    }
  }

  Future<bool> uploadAttendanceBatch(String taskId, List<Map<String, dynamic>> records) async {
    try {
      final response = await http.post(
        Uri.parse('${ApiConfig.baseUrl}/attendance/batch'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'taskId': taskId,
          'records': records,
        }),
      );
      return response.statusCode == 200;
    } catch (e) {
      print('ApiService: Batch Upload Error: $e');
      return false;
    }
  }

  Future<List<Map<String, dynamic>>> fetchSessionAttendance(String taskId) async {
    try {
      final response = await http.get(Uri.parse('${ApiConfig.baseUrl}/attendance/session/$taskId'));
      if (response.statusCode == 200) {
        return (jsonDecode(response.body) as List<dynamic>).cast<Map<String, dynamic>>();
      }
      return [];
    } catch (e) {
      print('ApiService: Fetch Session Attendance Error: $e');
      return [];
    }
  }

  Future<List<dynamic>> fetchAllUsers() async {
    try {
      final response = await http.get(Uri.parse('${ApiConfig.baseUrl}/users'));
      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
    } catch (e) {
      print('API Error (fetchAllUsers): $e');
    }
    return [];
  }
}

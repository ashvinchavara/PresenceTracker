import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user_node.dart';
import '../services/api_service.dart';
import '../services/session_automation_service.dart';

class NodeRoleProvider with ChangeNotifier {
  final ApiService _apiService = ApiService();
  UserNode? _currentUserNode;
  bool _isLoading = false;
  List<String> _allowedUploadRoles = [];

  bool _isTestMode = false;
  bool get isTestMode => _isTestMode;

  void setTestMode(bool value) async {
    _isTestMode = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('is_test_mode', value);

    if (value) {
      final now = DateTime.now();
      
      final t1Start = now.subtract(const Duration(minutes: 10));
      final t1End = now.subtract(const Duration(minutes: 5));
      
      final t2Start = now.add(const Duration(minutes: 1));
      final t2End = t2Start.add(const Duration(minutes: 5));
      
      final t3Start = t2End.add(const Duration(minutes: 1));
      final t3End = t3Start.add(const Duration(minutes: 5));
      
      final dayNames = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
      final todayName = dayNames[now.weekday - 1];

      String formatTimeRange(DateTime s, DateTime e) {
        String twoDigits(int n) => n.toString().padLeft(2, '0');
        return "${twoDigits(s.hour)}:${twoDigits(s.minute)} - ${twoDigits(e.hour)}:${twoDigits(e.minute)}";
      }
      
      final testTasks = [
        {
          'id': 9901,
          'activity_name': 'Test Activity 1',
          'department': 'Test Dept',
          'start_time': t1Start.toIso8601String(),
          'end_time': t1End.toIso8601String(),
          'day_of_week': todayName,
          'time_range': formatTimeRange(t1Start, t1End),
          'is_test': true,
        },
        {
          'id': 9902,
          'activity_name': 'Test Activity 2',
          'department': 'Test Dept',
          'start_time': t2Start.toIso8601String(),
          'end_time': t2End.toIso8601String(),
          'day_of_week': todayName,
          'time_range': formatTimeRange(t2Start, t2End),
          'is_test': true,
        },
        {
          'id': 9903,
          'activity_name': 'Test Activity 3',
          'department': 'Test Dept',
          'start_time': t3Start.toIso8601String(),
          'end_time': t3End.toIso8601String(),
          'day_of_week': todayName,
          'time_range': formatTimeRange(t3Start, t3End),
          'is_test': true,
        }
      ];
      
      await prefs.setString('test_mode_tasks', jsonEncode(testTasks));
      
      // Trigger background automation to pick up the new test schedule
      final automation = SessionAutomationService();
      await automation.cancelAllSessions(); // Clear existing normal alarms
      await automation.scheduleNextSessionIfNeeded(
          testTasks.cast<Map<String, dynamic>>(), _currentUserNode?.id.toString() ?? '', isRootNode);
          
    } else {
      await prefs.remove('test_mode_tasks');
      final automation = SessionAutomationService();
      await automation.cancelAllSessions();
    }
  }

  UserNode? get currentUserNode => _currentUserNode;
  bool get isLoading => _isLoading;
  bool get isRootNode => canUpload;
  
  bool get canUpload {
    if (_currentUserNode == null) return false;
    // Check the user's own can_upload flag first (set from admin dashboard)
    if (_currentUserNode!.canUpload) return true;
    // Also check against the role-based allowed upload roles list
    return _allowedUploadRoles.contains(_currentUserNode!.desig);
  }

  Future<void> loadSession() async {
    final prefs = await SharedPreferences.getInstance();
    _isTestMode = prefs.getBool('is_test_mode') ?? false;
    final userJson = prefs.getString('user_session');
    if (userJson != null) {
      try {
        final userMap = jsonDecode(userJson);
        _currentUserNode = UserNode.fromMap(userMap);
        await refreshPermissions();
        notifyListeners();
      } catch (e) {
        print('Error loading user session: $e');
        await prefs.remove('user_session');
      }
    }
  }

  Future<void> refreshPermissions() async {
    _allowedUploadRoles = await _apiService.fetchAllowedUploadRoles();
    notifyListeners();
  }

  Future<void> fetchUserRole(String uid) async {
    _isLoading = true;
    notifyListeners();

    _currentUserNode = await _apiService.getCurrentUserNode(uid);
    await refreshPermissions();
    
    _isLoading = false;
    notifyListeners();
  }

  Future<void> setUser(UserNode user) async {
    _currentUserNode = user;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('user_session', jsonEncode(user.toMap()));
    await refreshPermissions();
    notifyListeners();
  }

  Future<void> clearUserRole() async {
    _currentUserNode = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('user_session');
    notifyListeners();
  }
}

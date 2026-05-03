import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user_node.dart';
import '../services/api_service.dart';

class NodeRoleProvider with ChangeNotifier {
  final ApiService _apiService = ApiService();
  UserNode? _currentUserNode;
  bool _isLoading = false;
  List<String> _allowedUploadRoles = [];

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

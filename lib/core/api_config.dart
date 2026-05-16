import 'package:shared_preferences/shared_preferences.dart';

class ApiConfig {
  /// Default Cloud URL (Render)
  static String cloudUrl = 'https://presencetracker.onrender.com/api'; 
  
  static String baseUrl = cloudUrl;
  static bool isCloudMode = true;

  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    isCloudMode = prefs.getBool('is_cloud_mode') ?? true;
    final savedLocalIp = prefs.getString('custom_local_ip');
    
    if (!isCloudMode && savedLocalIp != null && savedLocalIp.isNotEmpty) {
      baseUrl = 'http://$savedLocalIp:3000/api';
    } else {
      baseUrl = cloudUrl;
    }
  }

  static Future<void> switchToCloud() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('is_cloud_mode', true);
    isCloudMode = true;
    baseUrl = cloudUrl;
  }

  static Future<void> switchToLocal(String ip) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('is_cloud_mode', false);
    await prefs.setString('custom_local_ip', ip);
    isCloudMode = false;
    baseUrl = 'http://$ip:3000/api';
  }

  static String get currentIp {
    if (baseUrl == cloudUrl) return '192.168.1.9';
    return baseUrl.replaceAll('http://', '').replaceAll(':3000/api', '');
  }
}

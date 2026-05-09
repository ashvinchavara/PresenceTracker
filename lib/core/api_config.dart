import 'package:shared_preferences/shared_preferences.dart';

class ApiConfig {
  /// Local Machine IP (Auto-detected: 192.168.1.8)
  static String baseUrl = 'http://192.168.1.8:3000/api';

  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final savedUrl = prefs.getString('custom_backend_ip');
    if (savedUrl != null && savedUrl.isNotEmpty) {
      if (!savedUrl.startsWith('http://') && !savedUrl.startsWith('https://')) {
          baseUrl = 'http://$savedUrl:3000/api';
      } else {
          baseUrl = savedUrl;
      }
    }
  }

  static Future<void> updateBaseUrl(String ipOrUrl) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('custom_backend_ip', ipOrUrl);
    
    if (!ipOrUrl.startsWith('http://') && !ipOrUrl.startsWith('https://')) {
        baseUrl = 'http://$ipOrUrl:3000/api';
    } else {
        baseUrl = ipOrUrl;
    }
  }
}

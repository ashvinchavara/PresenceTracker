import 'dart:io';
import 'package:path_provider/path_provider.dart';

class LogService {
  static Future<File> getLogFile() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      return File('${directory.path}/system_diagnostics.log');
    } catch (e) {
      // Fallback path on Android if path_provider fails in a background isolate
      return File('/data/user/0/com.example.presence_tracker/app_flutter/system_diagnostics.log');
    }
  }

  static Future<void> log(String level, String tag, String message) async {
    final timestamp = DateTime.now().toIso8601String();
    final logLine = '[$timestamp] [$level] [$tag] $message\n';

    // Print to console/logcat
    print(logLine.trim());

    try {
      final file = await getLogFile();
      await file.writeAsString(logLine, mode: FileMode.append, flush: true);
      await _checkAndCleanupLogFile(file);
    } catch (e) {
      print('Failed to write log to file: $e');
    }
  }

  static Future<void> info(String tag, String message) => log('INFO', tag, message);
  static Future<void> warn(String tag, String message) => log('WARN', tag, message);
  static Future<void> error(String tag, String message) => log('ERROR', tag, message);

  static Future<String> readLogs() async {
    try {
      final file = await getLogFile();
      if (await file.exists()) {
        return await file.readAsString();
      }
      return 'No logs recorded yet.';
    } catch (e) {
      return 'Error reading logs: $e';
    }
  }

  static Future<void> clearLogs() async {
    try {
      final file = await getLogFile();
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      print('Error clearing logs: $e');
    }
  }

  static Future<void> _checkAndCleanupLogFile(File file) async {
    try {
      if (await file.exists()) {
        final length = await file.length();
        if (length > 1024 * 1024) { // 1MB limit
          final content = await file.readAsString();
          // Keep only the last 500KB of content
          final halfContent = content.substring(content.length ~/ 2);
          await file.writeAsString(halfContent, mode: FileMode.write, flush: true);
        }
      }
    } catch (e) {
      print('Error cleaning up log file: $e');
    }
  }
}

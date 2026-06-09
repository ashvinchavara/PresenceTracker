import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'providers/node_role_provider.dart';
import 'providers/theme_provider.dart';
import 'screens/auth/startup_screen.dart';
import 'core/api_config.dart';
import 'services/notification_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 🔥 REQUIRED: Initialize Alarm Manager FIRST
  await AndroidAlarmManager.initialize();

  // Core initialization (keep lightweight)
  await ApiConfig.init();

  // Notification init (safe for main isolate only)
  final notificationService = NotificationService();
  await notificationService.init();

  // Foreground task setup (wrap safely to avoid plugin crashes on some devices)
  try {
    FlutterForegroundTask.initCommunicationPort();

    FlutterForegroundTask.addTaskDataCallback((data) {
      try {
        if (data == 'bt_alert') {
          NotificationService().showBluetoothAlert();
        } else if (data == 'bt_alert_clear') {
          NotificationService().cancel(100);
        }
      } catch (e) {
        debugPrint('Foreground task callback error: $e');
      }
    });
  } catch (e) {
    debugPrint('Foreground task init failed: $e');
  }

  // Providers
  final roleProvider = NodeRoleProvider();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<NodeRoleProvider>.value(value: roleProvider),
        ChangeNotifierProvider<ThemeProvider>(
          create: (_) => ThemeProvider(),
        ),
      ],
      child: const PresenceTrackerApp(),
    ),
  );
}

class PresenceTrackerApp extends StatelessWidget {
  const PresenceTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);

    return MaterialApp(
      title: 'Presence Tracker',
      debugShowCheckedModeBanner: false,
      themeMode: themeProvider.themeMode,

      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0078D4),
        ),
        useMaterial3: true,
      ),

      darkTheme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: Colors.black,
        canvasColor: Colors.black,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0078D4),
          brightness: Brightness.dark,
          surface: Colors.black,
        ),
      ),

      home: const StartupScreen(),
    );
  }
}
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'providers/node_role_provider.dart';
import 'providers/theme_provider.dart';
import 'screens/auth/auth_screen.dart';
import 'core/api_config.dart';

import 'screens/dashboard/root_dashboard.dart';
import 'services/notification_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize services
  await AndroidAlarmManager.initialize();
  await ApiConfig.init();
  await NotificationService().init();
  
  // Initialize foreground task communication port
  FlutterForegroundTask.initCommunicationPort();
  
  // Initialize session
  final roleProvider = NodeRoleProvider();
  await roleProvider.loadSession();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<NodeRoleProvider>.value(value: roleProvider),
        ChangeNotifierProvider<ThemeProvider>(create: (_) => ThemeProvider()),
      ],
      child: const PresenceTrackerApp(),
    ),
  );
}

class PresenceTrackerApp extends StatelessWidget {
  const PresenceTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Check if user is already logged in
    final userNode = Provider.of<NodeRoleProvider>(context).currentUserNode;
    final themeProvider = Provider.of<ThemeProvider>(context);

    return MaterialApp(
      title: 'Presence Tracker',
      debugShowCheckedModeBanner: false,
      themeMode: themeProvider.themeMode,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0078D4)),
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
      home: userNode == null ? const AuthScreen() : const RootDashboard(),
    );
  }
}

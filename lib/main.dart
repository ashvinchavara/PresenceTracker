import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'providers/node_role_provider.dart';
import 'providers/theme_provider.dart';
import 'screens/auth/auth_screen.dart';
import 'services/alarm_service.dart';
import 'services/notification_service.dart';
import 'core/api_config.dart';

import 'screens/dashboard/root_dashboard.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize services
  await AlarmService.initialize();
  await NotificationService.initialize();
  await ApiConfig.init();
  
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
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0078D4), 
          brightness: Brightness.dark,
        ),
      ),
      home: userNode == null ? const AuthScreen() : const RootDashboard(),
    );
  }
}

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/node_role_provider.dart';
import '../dashboard/root_dashboard.dart';
import './auth_screen.dart';

class StartupScreen extends StatefulWidget {
  const StartupScreen({super.key});

  @override
  State<StartupScreen> createState() => _StartupScreenState();
}

class _StartupScreenState extends State<StartupScreen> with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  late Animation<double> _glowAnimation;
  bool _isInitDone = false;

  @override
  void initState() {
    super.initState();
    
    // Set up a pulsing and glowing animation for the logo
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 0.95, end: 1.05).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _glowAnimation = Tween<double>(begin: 10.0, end: 25.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _startAppInitialization();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _startAppInitialization() async {
    final startTime = DateTime.now();

    try {
      // Load user session from SharedPreferences
      await Provider.of<NodeRoleProvider>(context, listen: false).loadSession();
    } catch (e) {
      print('StartupScreen: Error loading session: $e');
    }

    final elapsed = DateTime.now().difference(startTime);
    final minDuration = const Duration(milliseconds: 2000);

    // Keep splash visible for at least 2 seconds for branding experience
    if (elapsed < minDuration) {
      await Future.delayed(minDuration - elapsed);
    }

    if (mounted) {
      setState(() {
        _isInitDone = true;
      });
      _navigateToNextScreen();
    }
  }

  void _navigateToNextScreen() {
    final userNode = Provider.of<NodeRoleProvider>(context, listen: false).currentUserNode;
    Navigator.pushReplacement(
      context,
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) =>
            userNode == null ? const AuthScreen() : const RootDashboard(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(opacity: animation, child: child);
        },
        transitionDuration: const Duration(milliseconds: 500),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: isDark
                ? [const Color(0xFF0F172A), const Color(0xFF020617)]
                : [const Color(0xFFE2E8F0), const Color(0xFFF8FAFC)],
          ),
        ),
        child: Stack(
          children: [
            // Decorative background lights
            Positioned(
              top: -100,
              left: -100,
              child: Container(
                width: 300,
                height: 300,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF0078D4).withOpacity(0.15),
                ),
              ),
            ),
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Beautiful Pulsing glowing brand logo
                  AnimatedBuilder(
                    animation: _pulseController,
                    builder: (context, child) {
                      return Transform.scale(
                        scale: _pulseAnimation.value,
                        child: Container(
                          width: 120,
                          height: 120,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: const LinearGradient(
                              colors: [Color(0xFF0078D4), Color(0xFF3B82F6)],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(0xFF0078D4).withOpacity(0.4),
                                blurRadius: _glowAnimation.value,
                                spreadRadius: _pulseController.value * 3,
                              ),
                            ],
                          ),
                          child: const Icon(
                            Icons.security,
                            size: 60,
                            color: Colors.white,
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 30),
                  // App Title
                  Text(
                    'Presence Tracker',
                    style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2,
                      color: isDark ? Colors.white : const Color(0xFF0F172A),
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Subtitle
                  Text(
                    'Zero-Touch Identity System',
                    style: TextStyle(
                      fontSize: 16,
                      color: isDark ? Colors.blueGrey[300] : Colors.blueGrey[600],
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 60),
                  // Sleek Custom Linear Progress Indicator
                  SizedBox(
                    width: 180,
                    child: Column(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: LinearProgressIndicator(
                            color: const Color(0xFF0078D4),
                            backgroundColor: (isDark ? Colors.white : Colors.black).withOpacity(0.08),
                            minHeight: 4,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          _isInitDone ? 'Starting...' : 'Initializing Secure Session...',
                          style: TextStyle(
                            fontSize: 12,
                            color: (isDark ? Colors.white70 : Colors.black87).withOpacity(0.6),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // Footer Brand Tag
            Positioned(
              bottom: 30,
              left: 0,
              right: 0,
              child: Center(
                child: Text(
                  'AD TENDO SYSTEMS',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 2.0,
                    color: (isDark ? Colors.white : Colors.black).withOpacity(0.3),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

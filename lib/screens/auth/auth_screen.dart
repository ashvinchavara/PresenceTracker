import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/api_service.dart';
import '../../providers/node_role_provider.dart';
import '../dashboard/root_dashboard.dart';
import './change_password_screen.dart';
import '../../core/api_config.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final ApiService _apiService = ApiService();
  
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  
  bool _isAuthenticating = false;
  bool _isConnected = false;
  Timer? _healthCheckTimer;

  @override
  void initState() {
    super.initState();
    _startHealthPolling();
  }

  @override
  void dispose() {
    _healthCheckTimer?.cancel();
    super.dispose();
  }

  void _startHealthPolling() {
    // Initial check
    _apiService.checkHealth().then((connected) {
      if (mounted) setState(() => _isConnected = connected);
    });
    
    // Poll every 10 seconds
    _healthCheckTimer = Timer.periodic(const Duration(seconds: 10), (timer) async {
      final connected = await _apiService.checkHealth();
      if (mounted) {
        setState(() => _isConnected = connected);
      }
    });
  }

  void _loginWithEmail() async {
    String email = _emailController.text.trim();
    String password = _passwordController.text.trim();

    if (email.isEmpty || password.isEmpty) {
       ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter both email and password.')),
      );
      return;
    }

    setState(() => _isAuthenticating = true);

    try {
      final user = await _apiService.login(email, password);
      
      if (user != null && mounted) {
        await Provider.of<NodeRoleProvider>(context, listen: false).setUser(user);
        
        if (mounted) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (_) => const RootDashboard()),
          );
        }
      } else if (mounted) {
         ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Invalid Email or Password.')),
        );
      }
    } catch (e) {
      String errorMessage = e.toString();
      if (errorMessage.startsWith('Exception: ')) {
        errorMessage = errorMessage.replaceFirst('Exception: ', '');
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(errorMessage)),
      );
    } finally {
       if (mounted) setState(() => _isAuthenticating = false);
    }
  }

  void _showSettingsDialog() {
    final TextEditingController ipController = TextEditingController(text: ApiConfig.baseUrl.replaceAll('http://', '').replaceAll(':3000/api', ''));
    
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Server Configuration'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Enter the IP address of the backend server:'),
            const SizedBox(height: 10),
            TextField(
              controller: ipController,
              decoration: const InputDecoration(
                labelText: 'IPv4 Address or Domain',
                hintText: 'e.g., 192.168.1.3',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              String newIp = ipController.text.trim();
              if (newIp.isNotEmpty) {
                await ApiConfig.updateBaseUrl(newIp);
                if (mounted) {
                   setState(() {
                      _isConnected = false;
                   });
                   Navigator.pop(ctx);
                   _apiService.checkHealth().then((connected) {
                      if (mounted) setState(() => _isConnected = connected);
                   });
                }
              }
            },
            child: const Text('Save'),
          ),
        ],
      )
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Presence Tracker Login'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _showSettingsDialog,
            tooltip: 'Server Settings',
          ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _isConnected ? Colors.green : Colors.red,
                      boxShadow: [
                        BoxShadow(
                          color: (_isConnected ? Colors.green : Colors.red).withOpacity(0.5),
                          blurRadius: 4,
                          spreadRadius: 2,
                        )
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _isConnected ? 'Connected to Adtendo' : 'Offline / Error',
                    style: TextStyle(
                      color: _isConnected ? Colors.green : Colors.red,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              const Icon(Icons.security, size: 80, color: Color(0xFF0078D4)),
              const SizedBox(height: 20),
              const Text(
                'Zero-Touch Identity System',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 40),
              
              TextField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'Email Address',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.email),
                ),
              ),
              const SizedBox(height: 16),
              
              TextField(
                controller: _passwordController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Password',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.lock),
                ),
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const ChangePasswordScreen()),
                    );
                  },
                  child: const Text('Change Password?'),
                ),
              ),
              const SizedBox(height: 14),
              
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _isAuthenticating ? null : _loginWithEmail,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 15),
                    backgroundColor: const Color(0xFF0078D4),
                    foregroundColor: Colors.white,
                  ),
                  child: Text(_isAuthenticating ? 'Authenticating...' : 'Login'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

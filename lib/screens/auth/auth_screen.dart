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
  bool _isDialogShowing = false;
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
      if (mounted) {
        setState(() => _isConnected = connected);
        if (!connected) _showSettingsDialog();
      }
    });
    
    // Poll every 10 seconds
    _healthCheckTimer = Timer.periodic(const Duration(seconds: 10), (timer) async {
      final connected = await _apiService.checkHealth();
      if (mounted) {
        setState(() => _isConnected = connected);
        if (!connected && !_isAuthenticating) {
          _showSettingsDialog();
        }
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

    if (!_isConnected) {
      _showSettingsDialog();
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
    if (_isDialogShowing) return;
    _isDialogShowing = true;

    final TextEditingController ipController = TextEditingController(text: ApiConfig.currentIp);
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Connection Settings'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Select connection mode:'),
              const SizedBox(height: 15),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: ApiConfig.isCloudMode ? const Color(0xFF0078D4) : Colors.grey,
                      ),
                      onPressed: () {
                        setState(() => ApiConfig.isCloudMode = true);
                      },
                      child: const Text('Cloud (Primary)'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: !ApiConfig.isCloudMode ? const Color(0xFF0078D4) : Colors.grey,
                      ),
                      onPressed: () {
                        setState(() => ApiConfig.isCloudMode = false);
                      },
                      child: const Text('Local Fallback'),
                    ),
                  ),
                ],
              ),
              if (!ApiConfig.isCloudMode) ...[
                const SizedBox(height: 20),
                const Text('Enter Local Backend IP:'),
                const SizedBox(height: 10),
                TextField(
                  controller: ipController,
                  decoration: const InputDecoration(
                    labelText: 'Local IPv4',
                    hintText: 'e.g., 192.168.1.7',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx), 
              child: const Text('Cancel')
            ),
            ElevatedButton(
              onPressed: () async {
                if (ApiConfig.isCloudMode) {
                  await ApiConfig.switchToCloud();
                } else {
                  await ApiConfig.switchToLocal(ipController.text.trim());
                }
                
                if (mounted) {
                  Navigator.pop(ctx);
                  final connected = await _apiService.checkHealth();
                  this.setState(() => _isConnected = connected);
                }
              },
              child: const Text('Connect & Save'),
            ),
          ],
        ),
      ),
    ).then((_) => _isDialogShowing = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Presence Tracker Login'),
        actions: [
          IconButton(
            icon: Icon(ApiConfig.isCloudMode ? Icons.cloud_circle : Icons.settings_ethernet),
            tooltip: 'Connection Settings',
            onPressed: _showSettingsDialog,
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
                      color: _isConnected 
                        ? (ApiConfig.isCloudMode ? Colors.green : Colors.orange) 
                        : Colors.red,
                      boxShadow: [
                        BoxShadow(
                          color: (_isConnected 
                            ? (ApiConfig.isCloudMode ? Colors.green : Colors.orange) 
                            : Colors.red).withOpacity(0.5),
                          blurRadius: 4,
                          spreadRadius: 2,
                        )
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _isConnected 
                      ? (ApiConfig.isCloudMode ? 'Live Cloud Active' : 'Local Fallback: ${ApiConfig.currentIp}')
                      : 'Offline / Server Unreachable',
                    style: TextStyle(
                      color: _isConnected ? (ApiConfig.isCloudMode ? Colors.green : Colors.orange) : Colors.red,
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

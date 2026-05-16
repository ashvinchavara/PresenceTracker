import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_service.dart';
import 'notification_service.dart';
import 'package:http/http.dart' as http;

class BleMeshService {
  static final BleMeshService _instance = BleMeshService._internal();
  factory BleMeshService() => _instance;
  BleMeshService._internal();

  final FlutterBlePeripheral _blePeripheral = FlutterBlePeripheral();
  final NotificationService _notifications = NotificationService();
  
  // State
  String _currentTaskId = '';
  String _currentUserId = '';
  String _currentActivityName = '';
  bool _canUpload = false;
  
  // Peer Data: { userId: { 'first': DateTime, 'last': DateTime } }
  Map<String, Map<String, DateTime>> _peers = {};
  Set<String> _scannedIds = {};
  
  Timer? _btWatchdog;
  Timer? _meshCycleTimer;
  Timer? _notificationTimer;
  StreamSubscription<BluetoothAdapterState>? _btStateSub;
  bool _isMeshRunning = false;
  bool _isBtAlertShown = false;
  
  // Phase management
  bool _isAdvertisingMesh = false;
  DateTime? _meshAdvStartTime;

  bool _isTestMode = false;

  Future<void> initializeMeshNode(String role, String taskId, String userId, String activityName, {bool isTest = false}) async {
    _currentTaskId = taskId;
    _currentUserId = userId;
    _currentActivityName = activityName;
    _canUpload = role == 'root';
    _isTestMode = isTest;
    _peers.clear();
    _scannedIds.clear();
    _isMeshRunning = true;

    await _notifications.init();
    
    // 1. Bluetooth Watchdog (Check every 10s)
    _startBluetoothWatchdog();

    // 2. Start Scanning (Continuous)
    _startScanning();

    // 3. Start Advertising Cycle
    _startAdvertisingCycle();

    // 4. Ongoing Notification
    _updateOngoingNotification();
    
    print('BLE Mesh Initialized for $activityName');
  }

  void _startBluetoothWatchdog() {
    _btWatchdog?.cancel();
    _btWatchdog = Timer.periodic(const Duration(seconds: 10), (timer) async {
      final state = await FlutterBluePlus.adapterState.first;
      if (state != BluetoothAdapterState.on) {
        if (!_isBtAlertShown) {
           _isBtAlertShown = true; // Set first to prevent repeats if show fails or takes time
           try {
             await _notifications.showBluetoothAlert();
           } catch (e) {
             _isBtAlertShown = false; // Reset if it actually failed
           }
        }
      } else {
        if (_isBtAlertShown) {
           _isBtAlertShown = false;
           await _notifications.cancel(100);
        }
      }
    });
  }

  void _updateOngoingNotification() {
    _notifications.showOngoingSession(_currentActivityName, _scannedIds.length);
  }

  void _startScanning() async {
    _btStateSub?.cancel();
    _btStateSub = FlutterBluePlus.adapterState.listen((state) async {
       if (state == BluetoothAdapterState.on) {
          if (!FlutterBluePlus.isScanningNow) {
            print('BleMeshService: Bluetooth ON. Starting Scan...');
            try {
              await FlutterBluePlus.startScan(timeout: const Duration(days: 1), continuousUpdates: true);
              FlutterBluePlus.scanResults.listen((results) {
                for (ScanResult r in results) {
                  _processScanResult(r);
                }
              });
            } catch (e) {
              print('BleMeshService: Start Scan Error: $e');
            }
          }
       } else if (state == BluetoothAdapterState.off) {
          print('BleMeshService: Bluetooth OFF. Stopping Scan...');
          try {
            await FlutterBluePlus.stopScan();
          } catch (e) {}
       }
    });
  }

  void _processScanResult(ScanResult r) {
    if (!r.advertisementData.manufacturerData.containsKey(1234)) return;

    try {
      final payload = utf8.decode(r.advertisementData.manufacturerData[1234]!);
      // Format: ID:1:F:L,ID:0:F:L (ID:hasInternet:FirstSeenEpoch:LastSeenEpoch)
      final parts = payload.split(',');
      for (var part in parts) {
        final fields = part.split(':');
        if (fields.length < 2) continue;

        final id = fields[0];
        final hasInternet = fields[1] == '1';
        
        DateTime? first;
        DateTime? last;
        if (fields.length >= 4) {
          first = DateTime.fromMillisecondsSinceEpoch(int.parse(fields[2]) * 1000);
          last = DateTime.fromMillisecondsSinceEpoch(int.parse(fields[3]) * 1000);
        } else {
          first = last = DateTime.now();
        }

        if (id == _currentUserId) continue;

        _scannedIds.add(id);
        
        if (!_peers.containsKey(id)) {
          _peers[id] = {'first': first!, 'last': last!};
          _updateOngoingNotification();
        } else {
          // Update last seen
          if (last!.isAfter(_peers[id]!['last']!)) {
            _peers[id]!['last'] = last;
          }
          // Update first seen if the scanned one is earlier
          if (first!.isBefore(_peers[id]!['first']!)) {
            _peers[id]!['first'] = first;
          }
        }
      }
    } catch (e) {
      // Ignore malformed
    }
  }

  void _startAdvertisingCycle() {
    _meshCycleTimer?.cancel();
    _meshCycleTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_isTestMode) {
        _advertiseCurrentPayload();
        return;
      }
      final now = DateTime.now();
      
      // Mesh cycle: 2 mins on, 10 mins off
      if (_meshAdvStartTime == null) {
        _meshAdvStartTime = now;
        _isAdvertisingMesh = true;
      }

      final diff = now.difference(_meshAdvStartTime!);
      if (_isAdvertisingMesh) {
        if (diff.inMinutes >= 2) {
          _isAdvertisingMesh = false;
          _meshAdvStartTime = now;
          _blePeripheral.stop();
          print('Mesh Advertising Phase: OFF (10 min interval)');
        } else {
          _advertiseCurrentPayload();
        }
      } else {
        if (diff.inMinutes >= 10) {
          _isAdvertisingMesh = true;
          _meshAdvStartTime = now;
          print('Mesh Advertising Phase: ON (2 min cycle)');
        }
      }
    });
  }

  int _advRotationIndex = 0;
  
  void _advertiseCurrentPayload() async {
    // Phase 1: Only own ID until 5 scanned (1 in test mode)
    bool meshMode = _isTestMode ? _scannedIds.length >= 1 : _scannedIds.length >= 5;
    
    List<String> items = [];
    // Always include self
    bool hasInternet = await _checkInternet();
    items.add('$_currentUserId:${hasInternet ? 1 : 0}');

    if (meshMode) {
      // Phase 2: Include scanned users (rotating chunks to fit BLE limit)
      final peerList = _peers.entries.toList();
      if (peerList.isNotEmpty) {
        if (_advRotationIndex >= peerList.length) _advRotationIndex = 0;
        
        // Add 1 peer at a time due to 31-byte limit
        final peer = peerList[_advRotationIndex];
        final id = peer.key;
        final f = peer.value['first']!.millisecondsSinceEpoch ~/ 1000;
        final l = peer.value['last']!.millisecondsSinceEpoch ~/ 1000;
        items.add('$id:0:$f:$l');
        _advRotationIndex++;
      }
    }

    final payload = items.join(',');
    final data = AdvertiseData(
      includeDeviceName: false,
      manufacturerId: 1234,
      manufacturerData: Uint8List.fromList(utf8.encode(payload)),
    );

    try {
      await _blePeripheral.stop();
    } catch (e) {
      print('BleMeshService: Stop Peripheral Error during rotation: $e');
    }
    try {
      await _blePeripheral.start(advertiseData: data);
    } catch (e) {
      print('BleMeshService: Start Peripheral Error during rotation: $e');
    }
  }

  Future<bool> _checkInternet() async {
    try {
      final result = await http.get(Uri.parse('https://www.google.com')).timeout(const Duration(seconds: 2));
      return result.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<void> endMeshTask() async {
    _isMeshRunning = false;
    _btWatchdog?.cancel();
    _meshCycleTimer?.cancel();
    _notificationTimer?.cancel();
    _btStateSub?.cancel();
    FlutterBluePlus.stopScan();
    await _blePeripheral.stop();
    await _notifications.cancel(101);
  }

  // --- Attendance Upload Logic ---

  Future<void> uploadAttendance() async {
    print('Starting final attendance upload...');
    final hasInternet = await _checkInternet();
    
    if (!hasInternet) {
      print('No internet. Attempting mesh delegation...');
      // Implement delegation: notify user or try to find internet peer
      // For now, we show a notification.
      _notifications.showAlert('Upload Failed', 'No internet connection. Please connect to sync.');
      return;
    }

    final api = ApiService();
    final today = DateTime.now().toIso8601String().split('T')[0];
    final ttId = int.tryParse(_currentTaskId) ?? 0;
    final uId = int.tryParse(_currentUserId) ?? 0;

    int successCount = 0;
    for (var id in _scannedIds) {
      final peer = _peers[id];
      final entry = peer?['first']?.toIso8601String().split('T')[1].substring(0, 8);
      final exit = peer?['last']?.toIso8601String().split('T')[1].substring(0, 8);
      
      final success = await api.syncAttendanceRecord(ttId, int.parse(id), uId, today, entryTime: entry, exitTime: exit);
      if (success) successCount++;
    }

    _notifications.showAlert('Attendance Uploaded', 'Successfully synced $successCount records.');
  }

  Future<void> verifyAttendance() async {
    print('Verifying attendance against database...');
    final api = ApiService();
    try {
      // 1. Fetch current user's summary
      final summaries = await api.fetchAttendanceSummary(_currentUserId);
      final today = DateTime.now().toIso8601String().split('T')[0];
      
      // 2. Find matching session record for today
      final summary = summaries.firstWhere(
        (s) => s['timetable_id'].toString() == _currentTaskId,
        orElse: () => {},
      );

      if (summary.isEmpty) {
        _notifications.showAlert('Verification Error', 'No attendance record found in database for this session.');
        return;
      }

      final sessions = List<dynamic>.from(summary['sessions'] ?? []);
      final dbSession = sessions.firstWhere(
        (s) => (s['session_date'] ?? s['date']) == today,
        orElse: () => null,
      );

      if (dbSession == null) {
        _notifications.showAlert('Verification Error', 'Attendance not uploaded yet.');
        return;
      }

      _notifications.showOngoingSession('Attendance Uploaded', _scannedIds.length);

      // 3. Detailed check for discrepancies
      // Note: In a real mesh, we might check other users here too.
      // For now, let's check the current user's entry/exit as an example.
      
      final dbEntryStr = dbSession['entry_time']?.toString();
      final dbExitStr = dbSession['exit_time']?.toString();
      
      if (dbEntryStr == null || dbExitStr == null || dbEntryStr == 'MISSING') {
         _notifications.showAlert('Attendance Alert', 'Your time records are missing in the database.');
         return;
      }

      // Check "last seen" logic (if > 10 mins lesser)
      final localLast = _peers[_currentUserId]?['last']; // Actually self is in _peers too if we add it
      if (localLast != null) {
         // Parse dbExit
         final exitParts = dbExitStr.split(':');
         final dbExit = DateTime(localLast.year, localLast.month, localLast.day, 
            int.parse(exitParts[0]), int.parse(exitParts[1]));
            
         if (dbExit.difference(localLast).inMinutes > 10) {
            _notifications.showAlert('Attendance Alert', 'Uploaded last seen is significantly early.');
         }
      }

    } catch (e) {
      print('Verification failed: $e');
    }
  }
}

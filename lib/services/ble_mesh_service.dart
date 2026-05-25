import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
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
  bool _tempUploadPower = false;
  
  // Peer Data: { userId: { 'first': int, 'last': int, 'is_manually_added': bool, 'scanned_direct': bool } }
  Map<String, Map<String, dynamic>> _peers = {};
  
  Timer? _btWatchdog;
  Timer? _meshCycleTimer;
  Timer? _notificationTimer;
  StreamSubscription<BluetoothAdapterState>? _btStateSub;
  bool _isMeshRunning = false;
  bool _isBtAlertShown = false;
  
  // Phase management
  bool _isAdvertisingMesh = false;
  DateTime? _meshAdvStartTime;
  int _peersRelayedPerPacket = 2; 
  int _peerRotationIndex = 0;

  int _activityStartEpoch = 0;
  bool _isTestMode = false;

  Future<void> initializeMeshNode(String role, String taskId, String userId, String activityName, {bool isTest = false, String? startTimeStr}) async {
    try {
      print('BleMeshService: initializeMeshNode [START] - Role: $role, Task: $taskId, User: $userId');
      _currentTaskId = taskId;
      _currentUserId = userId;
      _currentActivityName = activityName;
      _canUpload = role == 'root';
      _isTestMode = isTest;
      _activityStartEpoch = startTimeStr != null 
          ? DateTime.tryParse(startTimeStr)?.millisecondsSinceEpoch ?? DateTime.now().millisecondsSinceEpoch
          : DateTime.now().millisecondsSinceEpoch;
      _activityStartEpoch = _activityStartEpoch ~/ 1000;
      _peers.clear();
      _isMeshRunning = true;

      await _notifications.init();
      print('BleMeshService: Notifications initialized successfully');
      
      _startBluetoothWatchdog();
      _startScanning();
      _startAdvertisingCycle();
      _updateOngoingNotification();
      
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('is_mesh_active', true);
      await prefs.setString('mesh_task_id', taskId);
      
      print('BLE Mesh Initialized successfully for $activityName');
    } catch (e, stack) {
      print('BACKGROUND EXCEPTION in BleMeshService.initializeMeshNode: $e');
      print(stack);
    }
  }

  void _startBluetoothWatchdog() {
    _btWatchdog?.cancel();
    _btWatchdog = Timer.periodic(const Duration(seconds: 10), (timer) async {
      final state = await FlutterBluePlus.adapterState.first;
      if (state != BluetoothAdapterState.on) {
         try {
           // Send to main isolate to show the notification (flutter_local_notifications
           // is only initialized in the main isolate, not the foreground service isolate)
           FlutterForegroundTask.sendDataToMain('bt_alert');
         } catch (e) {
           print('BleMeshService: Watchdog error $e');
         }
      } else {
         // Cancel any existing BT alert
         FlutterForegroundTask.sendDataToMain('bt_alert_clear');
      }
    });
  }

  void _updateOngoingNotification() {
    _notifications.showOngoingSession(_currentActivityName, _peers.length);
  }

  void _startScanning() async {
    try {
      print('BleMeshService: _startScanning called');
      _btStateSub?.cancel();
      _btStateSub = FlutterBluePlus.adapterState.listen((state) async {
        print('BleMeshService: Bluetooth state is: $state');
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
            } catch (e, stack) {
              print('BleMeshService: Start Scan Error: $e');
              print(stack);
            }
          } else {
            print('BleMeshService: Already scanning, no need to startScan');
          }
        } else if (state == BluetoothAdapterState.off) {
          print('BleMeshService: Bluetooth OFF. Stopping Scan...');
          try {
            await FlutterBluePlus.stopScan();
          } catch (e) {}
        }
      });
    } catch (e, stack) {
      print('BACKGROUND EXCEPTION in BleMeshService._startScanning: $e');
      print(stack);
    }
  }

  void _processScanResult(ScanResult r) {
    if (!r.advertisementData.manufacturerData.containsKey(1234)) return;

    try {
      final bytes = r.advertisementData.manufacturerData[1234]!;
      if (bytes.length < 5) return;

      int offset = 0;
      while (offset + 4 <= bytes.length) {
        final id = bytes.sublist(offset, offset + 4).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
        offset += 4;
        
        if (offset >= bytes.length) break;
        final flags = bytes[offset];
        offset += 1;

        bool hasInternet = (flags & 0x01) != 0;
        bool isUploader = (flags & 0x02) != 0;
        bool isRelayed = (flags & 0x04) != 0;

        int first = 0;
        int last = 0;
        if (offset + 8 <= bytes.length) {
          first = ByteData.sublistView(Uint8List.fromList(bytes.sublist(offset, offset + 4))).getUint32(0);
          offset += 4;
          last = ByteData.sublistView(Uint8List.fromList(bytes.sublist(offset, offset + 4))).getUint32(0);
          offset += 4;
        } else {
           first = last = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        }

        if (id == _currentUserId) {
          final currentSelf = _peers[_currentUserId];
          if (currentSelf != null) {
            if (first < currentSelf['first']) currentSelf['first'] = first;
          }
          continue;
        }

        // Transfer Power Check
        if (isUploader && !hasInternet && !(_canUpload || _tempUploadPower)) {
           _checkAndTakeUploadPower();
        }

        if (!_peers.containsKey(id)) {
          _peers[id] = {
            'first': first,
            'last': last,
            'is_manually_added': false,
            'scanned_direct': !isRelayed
          };
          _updateOngoingNotification();
        } else {
          if (first < _peers[id]!['first']) _peers[id]!['first'] = first;
          if (last > _peers[id]!['last']) _peers[id]!['last'] = last;
          if (!isRelayed) _peers[id]!['scanned_direct'] = true;
        }
      }
    } catch (e) {
      print('BleMeshService: Scan Parse Error: $e');
    }
  }

  void _checkAndTakeUploadPower() async {
     try {
       final response = await http.get(Uri.parse('https://www.google.com')).timeout(const Duration(seconds: 3));
       if (response.statusCode == 200) {
          _tempUploadPower = true;
          print('BleMeshService: Took over temporary upload power due to internet access.');
       }
     } catch (_) {}
  }

  void _startAdvertisingCycle() {
    print('BleMeshService: _startAdvertisingCycle called');
    _meshCycleTimer?.cancel();
    _meshCycleTimer = Timer.periodic(const Duration(seconds: 10), (timer) async {
      try {
        if (!_isMeshRunning) return;

        final now = DateTime.now();
        if (_meshAdvStartTime != null) {
          final duration = now.difference(_meshAdvStartTime!);
          if (_isAdvertisingMesh && duration.inMinutes >= 2) {
            print('BleMeshService: 2m Active Advertising complete. Switching off advertising for 10m.');
            await _blePeripheral.stop();
            _isAdvertisingMesh = false;
            _meshAdvStartTime = now; 
          } else if (!_isAdvertisingMesh && duration.inMinutes >= 10) {
            print('BleMeshService: 10m Quiet cycle complete. Switching on advertising for 2m.');
            _isAdvertisingMesh = true;
            _meshAdvStartTime = now;
            _updateAdvertising();
          } else if (_isAdvertisingMesh) {
            // Re-update advertising data to rotate/refresh relayed peers
            _updateAdvertising();
          }
        } else {
          print('BleMeshService: First time starting advertising.');
          _isAdvertisingMesh = true;
          _meshAdvStartTime = now;
          _updateAdvertising();
        }
      } catch (e, stack) {
        print('BACKGROUND EXCEPTION in BleMeshService._startAdvertisingCycle timer: $e');
        print(stack);
      }
    });
  }

  void _updateAdvertising() async {
    if (!_isAdvertisingMesh) return;

    try {
      final BytesBuilder builder = BytesBuilder();
      _addEntry(builder, _currentUserId, true);
      
      if (true) { // Removed the 5-peer rule
        final peerIds = _peers.keys.where((id) => id != _currentUserId).toList();
        if (peerIds.isNotEmpty) {
           for (int i = 0; i < _peersRelayedPerPacket; i++) {
             final idx = (_peerRotationIndex + i) % peerIds.length;
             _addEntry(builder, peerIds[idx], false);
           }
           _peerRotationIndex = (_peerRotationIndex + _peersRelayedPerPacket) % peerIds.length;
        }
      }

      final AdvertiseData advData = AdvertiseData(
        manufacturerId: 1234,
        manufacturerData: builder.toBytes(),
      );

      print('BleMeshService: Starting BLE Peripheral advertisement with ${builder.length} bytes.');
      await _blePeripheral.start(advertiseData: advData);
    } catch (e, stack) {
      print('BACKGROUND EXCEPTION in BleMeshService._updateAdvertising: $e');
      print(stack);
    }
  }

  void _addEntry(BytesBuilder builder, String id, bool isSelf) {
    final idBytes = Uint8List(4);
    for (int i = 0; i < 4; i++) {
       idBytes[i] = int.parse(id.substring(i*2, i*2 + 2), radix: 16);
    }
    builder.add(idBytes);

    int flags = 0;
    if (isSelf) {
      if (_canUpload || _tempUploadPower) flags |= 0x02;
      // Note: we'd need a real way to check internet for bit 0
    } else {
      flags |= 0x04;
    }
    builder.addByte(flags);

    Map<String, dynamic> data;
    if (isSelf) {
      data = {
        'first': _activityStartEpoch,
        'last': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      };
    } else {
      data = _peers[id] ?? {
        'first': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'last': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      };
    }
    
    final bData = ByteData(8);
    bData.setUint32(0, data['first']);
    bData.setUint32(4, data['last']);
    builder.add(bData.buffer.asUint8List());
  }

  Future<void> endMeshTask() async {
    _isMeshRunning = false;
    _meshCycleTimer?.cancel();
    _notificationTimer?.cancel();
    _btWatchdog?.cancel();
    _btStateSub?.cancel();
    
    await FlutterBluePlus.stopScan();
    await _blePeripheral.stop();
    await _notifications.cancel(100); // Bluetooth alert
    await _notifications.cancel(101); // Ongoing session
    
    await verifyAttendance();
    
    _peers.clear();
    _tempUploadPower = false;
    
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('is_mesh_active', false);
    await prefs.remove('mesh_task_id');
  }

  Future<void> uploadAttendance() async {
    await _blePeripheral.stop();
    _isAdvertisingMesh = false;

    if (_peers.isEmpty) return;

    final presentList = _peers.entries.map((e) => {
      'user_id': e.key,
      'first_seen': e.value['first'],
      'last_seen': e.value['last'],
    }).toList();

    if (_canUpload || _tempUploadPower) {
       try {
         final response = await http.get(Uri.parse('https://www.google.com')).timeout(const Duration(seconds: 5));
         if (response.statusCode == 200) {
            final api = ApiService();
            await api.uploadAttendanceBatch(_currentTaskId, presentList);
         }
       } catch (e) {
         _tempUploadPower = false;
         _startPowerTransferAdv();
       }
    }
  }

  void _startPowerTransferAdv() async {
    final BytesBuilder builder = BytesBuilder();
    _addEntry(builder, _currentUserId, true);
    final bytes = builder.toBytes();
    bytes[4] = 0x02; // isUploader=1, hasInternet=0
    
    final AdvertiseData advData = AdvertiseData(
      manufacturerId: 1234,
      manufacturerData: bytes,
    );
    await _blePeripheral.start(advertiseData: advData);
  }

  Future<void> verifyAttendance() async {
    try {
      final api = ApiService();
      final dbAttendance = await api.fetchSessionAttendance(_currentTaskId);
      
      List<String> missingUsers = [];
      for (var entry in _peers.entries) {
        final id = entry.key;
        final results = dbAttendance.where((u) => u['user_id'].toString() == id);
        final dbUser = results.isNotEmpty ? results.first : null;
        
        if (dbUser == null) {
          missingUsers.add(id);
        } else {
          final dbLast = dbUser['last_seen'] as int? ?? 0;
          if ((entry.value['last'] - dbLast).abs() > 600) {
            missingUsers.add(id);
          }
        }
      }

      if (missingUsers.isNotEmpty) {
        await _notifications.showMismatchAlert(_currentActivityName, missingUsers.length);
      }
    } catch (_) {}
  }

  Map<String, Map<String, dynamic>> getLivePeers() => _peers;

  void toggleManualPresence(String userId, bool isPresent) {
    if (isPresent) {
       _peers[userId] = {
         'first': DateTime.now().millisecondsSinceEpoch ~/ 1000,
         'last': DateTime.now().millisecondsSinceEpoch ~/ 1000,
         'is_manually_added': true,
         'scanned_direct': false
       };
    } else {
       _peers.remove(userId);
    }
  }
}

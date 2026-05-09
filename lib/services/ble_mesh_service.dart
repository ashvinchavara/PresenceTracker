import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';
import 'package:shared_preferences/shared_preferences.dart';
import 'notification_service.dart';
import 'api_service.dart';

class BleMeshService {
  final FlutterBlePeripheral _blePeripheral = FlutterBlePeripheral();
  
  // Storage for Task execution
  Map<String, DateTime> _peerTimes = {}; // For Leaf nodes
  Map<String, Map<String, DateTime>> _rootAggregatedData = {}; // For Root nodes
  
  String _currentTaskId = '';
  String _currentUserId = '';
  String _currentRole = '';
  Timer? _leafBroadcastTimer;
  int _advIndex = 0;
  DateTime _resumeAdvertisingTime = DateTime.fromMillisecondsSinceEpoch(0);
  StreamSubscription<BluetoothAdapterState>? _btStateSub;

  Future<bool> checkBleAvailability() async {
    final state = await FlutterBluePlus.adapterState.first;
    return state == BluetoothAdapterState.on;
  }

  /// Called by AlarmService at the start time of a scheduled task
  void initializeMeshNode(String role, String taskId, String userId, String taskName) async {
    _currentTaskId = taskId;
    _currentUserId = userId;
    _currentRole = role;
    _peerTimes.clear();
    _rootAggregatedData.clear();
    _advIndex = 0;
    _resumeAdvertisingTime = DateTime.fromMillisecondsSinceEpoch(0);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('is_mesh_active', true);
    await prefs.setString('mesh_task_id', taskId);

    _btStateSub = FlutterBluePlus.adapterState.listen((state) {
      if (state == BluetoothAdapterState.off) {
        NotificationService.showBluetoothWarning();
      } else if (state == BluetoothAdapterState.on) {
        NotificationService.cancelBluetoothWarning();
      }
    });

    if (!await checkBleAvailability()) {
        NotificationService.showBluetoothWarning();
    } else {
        NotificationService.cancelBluetoothWarning();
    }
    
    DateTime now = DateTime.now();

    if (role == 'root') {
      print('Initializing as Root Node for Task $taskId...');
      _startRootAdvertising();
      _startRootScanning();
      
      // --- DEBUG SIMULATION FOR SINGLE DEVICE TESTING ---
      // Injects a "Virtual Student" (ID 19 - ashvinchavara@gmail.com) after 10 seconds to test sync logic
      Timer(const Duration(seconds: 10), () {
        print('DEBUG: Injecting Virtual Student (ID 19) for testing...');
        DateTime now = DateTime.now();
        _rootAggregatedData['19'] = {'first_view': now, 'last_view': now};
        _syncAggregatedDataToPrefs();
        NotificationService.showAttendanceStatus(true, "Debug: Ashvin (ID 19) Detected");
      });
      // --------------------------------------------------

      // Update broadcast payload every 5 seconds
      _leafBroadcastTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
         if (DateTime.now().isBefore(_resumeAdvertisingTime)) {
             await _blePeripheral.stop();
             return;
         }
         _startRootAdvertising(); 
      });
    } else {
      print('Initializing as Leaf Node for Task $taskId...');
      _peerTimes[userId] = now;
      _startLeafAdvertising();
      // Scan briefly to discover others, then rely on periodic broadcasts
      _startRootScanning(); 
      
      // Update broadcast payload every 5 seconds to rotate chunks
      _leafBroadcastTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
         if (DateTime.now().isBefore(_resumeAdvertisingTime)) {
             await _blePeripheral.stop();
             return;
         }
         _startLeafAdvertising(); // restarts with new dynamic payload
      });
    }
  }

  void syncAndNotify(String role, String taskName) async {
    print('Executing pre-emptive sync for $role at 5 minutes to end...');
    
    if (role == 'root') {
      _uploadAggregatedDataToDatabase();
      NotificationService.showAttendanceStatus(true, taskName);
    } else if (role == 'leaf') {
      bool likelyMarked = _peerTimes.length > 1; // Since own ID is in there too
      NotificationService.showAttendanceStatus(likelyMarked, taskName);
    }
  }

  /// Called by AlarmService at the end time of a scheduled task
  void endMeshTask(String role) async {
    print('Ending Mesh Task $_currentTaskId for $role');
    stopScanning();
    
    _blePeripheral.stop();
    _leafBroadcastTimer?.cancel();
    _btStateSub?.cancel();

    if (role == 'root') {
       _uploadAggregatedDataToDatabase();
    }
    
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('is_mesh_active', false);
    await prefs.remove('root_aggregated_data');
    await prefs.remove('mesh_task_id');
    
    NotificationService.cancelBluetoothWarning();
    
    _peerTimes.clear();
    _rootAggregatedData.clear();
  }

  void _startRootScanning() async {
    await FlutterBluePlus.startScan(timeout: const Duration(days: 1), continuousUpdates: true);
    FlutterBluePlus.scanResults.listen((results) {
      for (ScanResult r in results) {
         _processScannedPayload(r);
      }
    });
  }

  void stopScanning() {
    FlutterBluePlus.stopScan();
  }

  void _startRootAdvertising() async {
    DateTime now = DateTime.now();
    String payloadStr = "$_currentUserId:${now.millisecondsSinceEpoch ~/ 1000}";
    List<int> payloadBytes = utf8.encode(payloadStr);

    AdvertiseData data = AdvertiseData(
      includeDeviceName: false,
      manufacturerId: 1234,
      manufacturerData: Uint8List.fromList(payloadBytes),
    );

    await _blePeripheral.stop();
    await _blePeripheral.start(advertiseData: data);
    
    // Root has 1 ID, broadcasts once then pauses for 10 mins
    _resumeAdvertisingTime = DateTime.now().add(const Duration(minutes: 10));
  }

  void _startLeafAdvertising() async {
    // Update own advertising time only by the owner
    _peerTimes[_currentUserId] = DateTime.now();

    List<MapEntry<String, DateTime>> entries = _peerTimes.entries.toList();
    if (entries.isEmpty) return;

    if (_advIndex >= entries.length) {
      _advIndex = 0;
    }

    // Take next 2 peers (reduced from 5 to fit BLE 31-byte limit)
    List<MapEntry<String, DateTime>> chunk = [];
    for (int i = 0; i < 2; i++) {
      if (_advIndex < entries.length) {
        chunk.add(entries[_advIndex]);
        _advIndex++;
      } else {
        break;
      }
    }

    bool completedCycle = _advIndex >= entries.length;

    // Construct payload: userId:time,userId:time
    String payloadStr = chunk
        .map((e) => "${e.key}:${e.value.millisecondsSinceEpoch ~/ 1000}")
        .join(',');

    // Encode payload. Note: standard BLE manufacturer data is typically limited to ~26 bytes
    List<int> payloadBytes = utf8.encode(payloadStr);

    AdvertiseData data = AdvertiseData(
      includeDeviceName: false,
      manufacturerId: 1234,
      manufacturerData: Uint8List.fromList(payloadBytes),
    );

    // Stop previous if running
    await _blePeripheral.stop();
    await _blePeripheral.start(advertiseData: data);

    if (completedCycle) {
      _advIndex = 0;
      // Shuffle for better distribution in a crowd
      entries.shuffle();
      // Reduced sleep from 10 mins to 15 secs for high-density responsiveness
      _resumeAdvertisingTime = DateTime.now().add(const Duration(seconds: 15));
    }
  }

  void _processScannedPayload(ScanResult r) {
    if (r.advertisementData.manufacturerData.containsKey(1234)) {
      try {
        String payloadStr = utf8.decode(r.advertisementData.manufacturerData[1234]!);
        List<String> pairs = payloadStr.split(',');
        
        for (String pair in pairs) {
          List<String> parts = pair.split(':');
          if (parts.length == 2) {
            String peerId = parts[0];
            int epoch = int.tryParse(parts[1]) ?? 0;
            
            if (epoch > 0) {
              DateTime time = DateTime.fromMillisecondsSinceEpoch(epoch * 1000);
              
              if (_currentRole == 'root') {
                bool updated = false;
                // Root node gathers all data: lowest time is entry, highest is exit
                if (!_rootAggregatedData.containsKey(peerId)) {
                  _rootAggregatedData[peerId] = {'first_view': time, 'last_view': time};
                  updated = true;
                } else {
                  if (time.isBefore(_rootAggregatedData[peerId]!['first_view']!)) {
                    _rootAggregatedData[peerId]!['first_view'] = time;
                    updated = true;
                  }
                  if (time.isAfter(_rootAggregatedData[peerId]!['last_view']!)) {
                    _rootAggregatedData[peerId]!['last_view'] = time;
                    updated = true;
                  }
                }
                if (updated) _syncAggregatedDataToPrefs();
              } else {
                // Leaf node scans and stores the advertised time for rebroadcasting.
                // It only updates if the scanned time is newer. The data is modified ONLY by the owner (above).
                if (!_peerTimes.containsKey(peerId) || time.isAfter(_peerTimes[peerId]!)) {
                  _peerTimes[peerId] = time;
                }
              }
            }
          }
        }
      } catch (e) {
        // Handle parsing errors gracefully
      }
    }
  }

  void _uploadAggregatedDataToDatabase() async {
    print('Root Node: Uploading aggregated attendance data to SQL Backend for Task: $_currentTaskId');
    print('Total Unique Users Detected: ${_rootAggregatedData.length}');
    
    ApiService api = ApiService();
    String todayDate = DateTime.now().toIso8601String().split('T')[0];
    
    int timetableId = int.tryParse(_currentTaskId) ?? 0;
    int markedById = int.tryParse(_currentUserId) ?? 0;

    if (timetableId == 0 || markedById == 0) return;

    for (String peerId in _rootAggregatedData.keys) {
      int studentId = int.tryParse(peerId) ?? 0;
      if (studentId > 0) {
        try {
          await api.syncAttendanceRecord(timetableId, studentId, markedById, todayDate);
          print('Synced student $studentId successfully.');
        } catch (e) {
          print('Failed to sync for student $studentId: $e');
        }
      }
    }
  }

  void _syncAggregatedDataToPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      Map<String, Map<String, int>> encodable = {};
      _rootAggregatedData.forEach((k, v) {
        encodable[k] = {
          'first_view': v['first_view']!.millisecondsSinceEpoch,
          'last_view': v['last_view']!.millisecondsSinceEpoch,
        };
      });
      await prefs.setString('root_aggregated_data', jsonEncode(encodable));
    } catch (e) {
      print('Failed to sync prefs: $e');
    }
  }
}


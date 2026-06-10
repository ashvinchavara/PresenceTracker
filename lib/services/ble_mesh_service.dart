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
  bool get isBtAlertShown => _isBtAlertShown;

  // BLE active state — only true after scan + advertise both succeed
  bool _isBleActive = false;
  bool get isBleActive => _isBleActive;

  // Non-null when BLE failed for a non-BT reason (permissions, hardware, etc.)
  String? _bleError;
  String? get bleError => _bleError;

  String get currentUserId => _currentUserId;

  /// Callback fired when a user is manually marked as absent.
  /// The foreground handler sets this to trigger session end.
  Function()? onAbsentMarked;
  
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
      _isBleActive = false;
      _bleError = null;
      // Reset advertising state from any previous session
      _isAdvertisingMesh = false;
      _meshAdvStartTime = null;

      await _notifications.init();
      print('BleMeshService: Notifications initialized');

      // Cancel any stale notifications from a previous session
      await _notifications.cancel(100);
      await _notifications.cancel(104);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('is_mesh_active', true);
      await prefs.setString('mesh_task_id', taskId);
      await prefs.remove('bg_mark_absent'); // clear any stale absent flag

      // Always start the BT state listener (handles BT on/off reactively)
      _startScanningWithStateListener(role, taskId, userId, activityName, isTest, startTimeStr);

      // Check current BT state
      final btState = await FlutterBluePlus.adapterState.first;
      if (btState != BluetoothAdapterState.on) {
        print('BleMeshService: BT is OFF at init. Showing alert, waiting for BT to turn on...');
        _isBtAlertShown = true;
        _updateForegroundServiceNotification(true);
        await _notifications.showBluetoothAlert(_currentActivityName);
        // BT watchdog will keep alerting every 10s; BT state listener will start BLE when BT turns on
        _startBluetoothWatchdog();
        return; // Do NOT start scan/advertise yet
      }

      // BT is on — try to start BLE
      await _initBleWithErrorHandling(role, taskId, activityName, isTest);
      print('BLE Mesh Initialized for $activityName. BLE active: $_isBleActive');
    } catch (e, stack) {
      print('BACKGROUND EXCEPTION in BleMeshService.initializeMeshNode: $e');
      print(stack);
    }
  }

  StreamSubscription<List<ScanResult>>? _scanSub;

  /// Tries to start scan and advertise. Sets _isBleActive=true only on full success.
  /// Shows BLE error notification if either fails for a non-BT reason.
  Future<void> _initBleWithErrorHandling(String role, String taskId, String activityName, bool isTest) async {
    bool scanOk = false;
    bool advOk = false;

    // Start scanning
    try {
      await _scanSub?.cancel();
      _scanSub = FlutterBluePlus.scanResults.listen((results) {
        for (ScanResult r in results) {
          _processScanResult(r);
        }
      });

      if (!FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.startScan(timeout: const Duration(days: 1), continuousUpdates: true);
      }
      scanOk = true;
      print('BleMeshService: BLE scan started successfully.');
    } catch (e, stack) {
      _bleError = 'Scan failed: ${e.toString().split('\n').first}';
      print('BleMeshService: Start Scan Error: $e\n$stack');
      await _notifications.showBleError(_bleError!, _currentActivityName);
    }

    // Start advertising cycle
    try {
      _startAdvertisingCycle();
      advOk = true;
      print('BleMeshService: BLE advertise cycle started successfully.');
    } catch (e, stack) {
      final advErr = 'Advertise failed: ${e.toString().split('\n').first}';
      if (_bleError == null) _bleError = advErr;
      print('BleMeshService: Advertise Error: $e\n$stack');
      await _notifications.showBleError(_bleError!, _currentActivityName);
    }

    if (scanOk && advOk) {
      _isBleActive = true;
      _isBtAlertShown = false;
      _startBluetoothWatchdog();
      // Only show the ongoing peer-count notification once BLE is confirmed active
      _updateOngoingNotification();
    }
  }

  void _updateForegroundServiceNotification(bool btOff) {
    if (btOff) {

    } else {

    }
  }

  void _startBluetoothWatchdog() {
    _btWatchdog?.cancel();
    _btWatchdog = Timer.periodic(const Duration(seconds: 10), (timer) async {
      if (!_isMeshRunning) { timer.cancel(); return; }
      final state = await FlutterBluePlus.adapterState.first;
      if (state != BluetoothAdapterState.on) {
        print('BleMeshService: Watchdog - Bluetooth is OFF. Showing alert.');
        _isBtAlertShown = true;
        _isBleActive = false;
        _updateForegroundServiceNotification(true);
        await _notifications.showBluetoothAlert(_currentActivityName);
      } else {
        if (_isBtAlertShown) {
          print('BleMeshService: Watchdog - Bluetooth is ON. Clearing alert.');
          _isBtAlertShown = false;
          _updateForegroundServiceNotification(false);
          await _notifications.cancel(100);
        }
      }
    });
  }

  void _updateOngoingNotification() {
    if (!_isBleActive) return; // Only show once BLE is confirmed active
    if (_isBtAlertShown) {
      _updateForegroundServiceNotification(true);
    } else {
      final otherPeersCount = _peers.keys.where((k) => k != _currentUserId).length;
      _notifications.showOngoingSession(_currentActivityName, otherPeersCount);
    }
  }

  /// BT state listener that reactively starts/stops BLE as BT turns on/off.
  void _startScanningWithStateListener(String role, String taskId, String userId, String activityName, bool isTest, String? startTimeStr) {
    try {
      _btStateSub?.cancel();
      _btStateSub = FlutterBluePlus.adapterState.listen((state) async {
        print('BleMeshService: Bluetooth state changed: $state');
        if (state == BluetoothAdapterState.on) {
          if (_isBtAlertShown) {
            _isBtAlertShown = false;
            _updateForegroundServiceNotification(false);
            await _notifications.cancel(100);
          }
          // If BLE not yet started (was off at init), try now
          if (!_isBleActive && _isMeshRunning) {
            print('BleMeshService: BT turned ON. Initializing BLE...');
            await _initBleWithErrorHandling(role, taskId, activityName, isTest);
          }
        } else if (state == BluetoothAdapterState.off) {
          print('BleMeshService: Bluetooth OFF. Pausing BLE...');
          _isBtAlertShown = true;
          _isBleActive = false;
          _updateForegroundServiceNotification(true);
          await _notifications.showBluetoothAlert(activityName);

          try { await FlutterBluePlus.stopScan(); } catch (e) {}
        }
      });
    } catch (e, stack) {
      print('BACKGROUND EXCEPTION in BleMeshService._startScanningWithStateListener: $e');
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
        final rawIdBytes = bytes.sublist(offset, offset + 4);
        offset += 4;

        final bData = ByteData.sublistView(Uint8List.fromList(rawIdBytes));
        final parsedInt = bData.getUint32(0);
        final hexId = rawIdBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

        String id;
        if (int.tryParse(_currentUserId) != null) {
          id = parsedInt.toString();
        } else {
          id = hexId;
        }

        print('BleMeshService: Scanned matching peer ID: $id (isSelf: ${id == _currentUserId})');

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
        }

        int firstVal = first;
        int lastVal = last;
        if (firstVal == 0 || lastVal == 0) {
          if (!isRelayed) {
            final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
            if (firstVal == 0) firstVal = nowSec;
            if (lastVal == 0) lastVal = nowSec;
          }
        }

        if (id == _currentUserId) {
          if (firstVal != 0 && lastVal != 0) {
            if (!_peers.containsKey(_currentUserId)) {
              _peers[_currentUserId] = {
                'first': firstVal,
                'last': lastVal,
                'is_manually_added': false,
                'scanned_direct': !isRelayed,
              };
            } else {
              final currentSelf = _peers[_currentUserId]!;
              final curFirst = currentSelf['first'];
              final curLast = currentSelf['last'];
              if (curFirst == null || firstVal < (curFirst as int)) {
                currentSelf['first'] = firstVal;
              }
              if (curLast == null || lastVal > (curLast as int)) {
                currentSelf['last'] = lastVal;
              }
              if (!isRelayed) currentSelf['scanned_direct'] = true;
            }
          }
          continue;
        }

        // Transfer Power Check
        if (isUploader && !hasInternet && !(_canUpload || _tempUploadPower)) {
           _checkAndTakeUploadPower();
        }

        if (!_peers.containsKey(id)) {
          _peers[id] = {
            'first': firstVal != 0 ? firstVal : null,
            'last': lastVal != 0 ? lastVal : null,
            'is_manually_added': false,
            'scanned_direct': !isRelayed
          };
          _updateOngoingNotification();
        } else {
          final peerData = _peers[id]!;
          if (firstVal != 0) {
            final curFirst = peerData['first'];
            if (curFirst == null || firstVal < (curFirst as int)) {
              peerData['first'] = firstVal;
            }
          }
          if (lastVal != 0) {
            final curLast = peerData['last'];
            if (curLast == null || lastVal > (curLast as int)) {
              peerData['last'] = lastVal;
            }
          }
          if (!isRelayed) peerData['scanned_direct'] = true;
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

      final AdvertiseSettings advSettings = AdvertiseSettings(
        txPowerLevel: AdvertiseTxPower.advertiseTxPowerMedium,
        advertiseMode: AdvertiseMode.advertiseModeLowLatency,
      );

      print('BleMeshService: Starting BLE Peripheral advertisement with ${builder.length} bytes.');
      await _blePeripheral.start(
        advertiseData: advData,
        advertiseSettings: advSettings,
      );
    } catch (e, stack) {
      print('BACKGROUND EXCEPTION in BleMeshService._updateAdvertising: $e');
      print(stack);
    }
  }

  void _addEntry(BytesBuilder builder, String id, bool isSelf) {
    final idBytes = Uint8List(4);
    final parsedInt = int.tryParse(id);
    if (parsedInt != null) {
      final bData = ByteData(4);
      bData.setUint32(0, parsedInt);
      idBytes.setAll(0, bData.buffer.asUint8List());
    } else {
      try {
        final cleanId = id.replaceAll('-', '');
        final hexStr = cleanId.padLeft(8, '0').substring(0, 8);
        for (int i = 0; i < 4; i++) {
          idBytes[i] = int.parse(hexStr.substring(i * 2, i * 2 + 2), radix: 16);
        }
      } catch (e) {
        print("BleMeshService: Fallback encoding error for ID '$id': $e");
      }
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
      final selfData = _peers[_currentUserId];
      if (selfData != null && selfData['first'] != null && selfData['last'] != null) {
        data = {
          'first': selfData['first'],
          'last': selfData['last'],
        };
      } else {
        data = {
          'first': 0,
          'last': 0,
        };
      }
    } else {
      data = _peers[id] ?? {
        'first': 0,
        'last': 0,
      };
    }
    
    final bData = ByteData(8);
    bData.setUint32(0, data['first'] ?? 0);
    bData.setUint32(4, data['last'] ?? 0);
    builder.add(bData.buffer.asUint8List());
  }

  Future<void> endMeshTask() async {
    _isMeshRunning = false;
    _isBleActive = false;
    _meshCycleTimer?.cancel();
    _notificationTimer?.cancel();
    _btWatchdog?.cancel();
    _btStateSub?.cancel();
    await _scanSub?.cancel();
    _scanSub = null;
    
    try { await FlutterBluePlus.stopScan(); } catch (_) {}
    try { await _blePeripheral.stop(); } catch (_) {}
    
    if (_isBtAlertShown) {
      _isBtAlertShown = false;
    }

    // Cancel all alert/error notifications
    await _notifications.cancel(100); // BT alert
    await _notifications.cancel(101); // Ongoing session
    await _notifications.cancelBleError(); // BLE error (104)
    
    await verifyAttendance();
    
    _peers.clear();
    _tempUploadPower = false;
    _bleError = null;
    
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
      
      // Fetch schedule members to get matching user names
      final membersData = await api.fetchScheduleMembers(int.tryParse(_currentTaskId) ?? 0);
      final List<dynamic> membersList = membersData != null && membersData['members'] != null 
          ? membersData['members'] as List<dynamic> 
          : [];

      List<Map<String, dynamic>> mismatchDetails = [];
      
      for (var entry in _peers.entries) {
        final id = entry.key;
        final results = dbAttendance.where((u) => u['user_id'].toString() == id);
        final dbUser = results.isNotEmpty ? results.first : null;
        
        // Find user name
        String name = 'Unknown User';
        final matchedMember = membersList.firstWhere(
          (m) => m['id']?.toString() == id || m['user_id']?.toString() == id, 
          orElse: () => null
        );
        if (matchedMember != null) {
          name = matchedMember['full_name'] ?? 'Unknown User';
        } else if (dbUser != null && dbUser['full_name'] != null) {
          name = dbUser['full_name'];
        }

        if (dbUser == null) {
          mismatchDetails.add({
            'user_id': id,
            'full_name': name,
            'type': 'missing',
            'detail': 'This user is detected locally via BLE, but is completely missing from the cloud attendance records for this session.',
          });
        } else {
          final dbLast = dbUser['last_seen'] as int? ?? 0;
          final localLast = entry.value['last'] as int? ?? 0;
          final diff = (localLast - dbLast).abs();
          if (diff > 600) {
            final minutes = (diff / 60).round();
            mismatchDetails.add({
              'user_id': id,
              'full_name': name,
              'type': 'stale',
              'detail': 'This user has stale cloud attendance: local BLE last saw them $minutes minutes different from the cloud database timestamp ($dbLast vs $localLast).',
            });
          }
        }
      }

      final prefs = await SharedPreferences.getInstance();
      if (mismatchDetails.isNotEmpty) {
        await prefs.setString('mismatch_details', jsonEncode(mismatchDetails));
        await _notifications.showMismatchAlert(_currentActivityName, mismatchDetails.length);
      } else {
        await prefs.remove('mismatch_details');
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
       // Marking a user absent — notify the session handler to stop and chain next session
       print('BleMeshService: User $userId marked absent. Triggering session end.');
       onAbsentMarked?.call();
    }
  }
}

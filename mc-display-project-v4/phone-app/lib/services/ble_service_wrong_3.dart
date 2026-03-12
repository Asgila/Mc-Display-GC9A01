import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

class BleService extends ChangeNotifier {
  static final BleService _instance = BleService._internal();
  factory BleService() => _instance;
  BleService._internal();

  // BLE UUIDs matching the ESP32
  static const String serviceUuid = "6e400001-b5a3-f393-e0a9-e50e24dcca9e";
  static const String rxCharUuid = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"; // Write to ESP32
  static const String txCharUuid = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"; // Read from ESP32

  static const String targetDeviceName = "ESP32S3_Display";

  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _rxCharacteristic;
  BluetoothCharacteristic? _txCharacteristic;

  bool _isConnected = false;
  bool _isScanning = false;
  bool _autoConnect = true;
  bool _isConnecting = false;
  String _statusMessage = "Disconnected";

  // Track consecutive connection failures for exponential backoff + recovery
  int _consecutiveFailures = 0;
  static const int _maxConsecutiveFailures = 5;
  // After this many 257 errors, try toggling Bluetooth
  static const int _failuresBeforeBluetoothReset = 3;

  bool get isConnected => _isConnected;
  bool get isScanning => _isScanning;
  bool get autoConnect => _autoConnect;
  String get statusMessage => _statusMessage;
  String get deviceName => _connectedDevice?.platformName ?? "None";

  StreamSubscription? _scanSubscription;
  StreamSubscription? _connectionSubscription;
  StreamSubscription? _adapterSubscription;
  Timer? _reconnectTimer;

  // Initialize and start auto-connect
  Future<void> initialize() async {
    _adapterSubscription?.cancel();

    _adapterSubscription = FlutterBluePlus.adapterState.listen((state) {
      if (state == BluetoothAdapterState.on &&
          _autoConnect &&
          !_isConnected &&
          !_isConnecting) {
        // Bluetooth just came back on (possibly after a reset), try connecting
        _consecutiveFailures = 0;
        startScan();
      }
    });

    if (await FlutterBluePlus.isSupported) {
      final state = await FlutterBluePlus.adapterState.first;
      if (state == BluetoothAdapterState.on && _autoConnect) {
        startScan();
      }
    }
  }

  void setAutoConnect(bool value) {
    _autoConnect = value;
    notifyListeners();
    if (value && !_isConnected && !_isConnecting) {
      _consecutiveFailures = 0;
      startScan();
    }
  }

  /// Clean up ALL system-level BLE connections to free leaked GATT client slots.
  /// Android has a hard limit (~30) on GATT registrations. If previous connection
  /// attempts failed mid-way, their GATT slots may still be held.
  Future<void> _cleanupAllConnections() async {
    print("Cleaning up all system BLE connections...");
    try {
      List<BluetoothDevice> systemDevices = await FlutterBluePlus.systemDevices;
      for (BluetoothDevice d in systemDevices) {
        try {
          await d.disconnect();
          print("  Disconnected stale device: ${d.remoteId}");
        } catch (_) {}
      }
    } catch (e) {
      print("  Error during cleanup: $e");
    }

    // FlutterBluePlus enforces a 2000ms gap after disconnect before allowing
    // a new connect. Wait longer to be safe.
    await Future.delayed(const Duration(milliseconds: 2500));
  }

  /// Toggle Bluetooth off/on to fully reset the Android BLE stack.
  /// This is the only reliable way to free ALL leaked GATT client registrations.
  Future<bool> _resetBluetoothAdapter() async {
    print("Attempting Bluetooth adapter reset to free GATT clients...");
    _statusMessage = "Resetting Bluetooth...";
    notifyListeners();

    try {
      await FlutterBluePlus.turnOff();
      await Future.delayed(const Duration(seconds: 2));
      await FlutterBluePlus.turnOn();
      // The adapterState listener will fire when BT comes back on,
      // which will trigger a new scan. Wait for it to stabilize.
      await Future.delayed(const Duration(seconds: 3));
      print("Bluetooth adapter reset complete");
      return true;
    } catch (e) {
      // turnOff/turnOn may fail if the app lacks BLUETOOTH_ADMIN permission
      // (or BLUETOOTH_CONNECT on Android 12+).
      print("Cannot programmatically reset Bluetooth: $e");
      _statusMessage = "Please toggle Bluetooth off/on manually, then retry";
      _autoConnect = false;
      notifyListeners();
      return false;
    }
  }

  // Start scanning for the ESP32 device
  Future<void> startScan() async {
    if (_isScanning || _isConnected || _isConnecting) return;

    _isScanning = true;
    _statusMessage = "Scanning...";
    notifyListeners();

    try {
      // Stop any ongoing scan first
      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {}

      // Try connecting to a bonded/known device first (fastest path)
      List<BluetoothDevice> bonded = await FlutterBluePlus.bondedDevices;
      for (BluetoothDevice device in bonded) {
        if (device.platformName == targetDeviceName) {
          print("Found bonded $targetDeviceName, connecting directly...");
          _isScanning = false;
          _statusMessage = "Reconnecting to bonded device...";
          notifyListeners();
          await _connectToDevice(device);
          return;
        }
      }

      // Cancel previous scan subscription before creating a new one
      _scanSubscription?.cancel();
      _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
        for (ScanResult result in results) {
          if (result.device.platformName == targetDeviceName) {
            print("Found $targetDeviceName via scan!");
            FlutterBluePlus.stopScan();
            _scanSubscription?.cancel();
            _scanSubscription = null;
            _isScanning = false;
            _connectToDevice(result.device);
            return;
          }
        }
      });

      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 5),
        androidUsesFineLocation: true,
      );

      // Wait for scan to finish properly instead of arbitrary delay
      await FlutterBluePlus.isScanning
          .where((val) => val == false)
          .first
          .timeout(const Duration(seconds: 8), onTimeout: () => false);

      if (!_isConnected && !_isConnecting) {
        _isScanning = false;
        _statusMessage = "Device not found";
        notifyListeners();

        if (_autoConnect) {
          _scheduleReconnect();
        }
      }
    } catch (e) {
      print("Scan error: $e");
      _isScanning = false;
      _statusMessage = "Scan error: $e";
      notifyListeners();

      if (_autoConnect) {
        _scheduleReconnect();
      }
    }
  }

  // Connect to the ESP32 device
  Future<void> _connectToDevice(BluetoothDevice device) async {
    if (_isConnecting || _isConnected) return;
    _isConnecting = true;

    try {
      _statusMessage = "Connecting...";
      notifyListeners();

      // Always disconnect the target device first to free its GATT client slot.
      // This is critical because Android does NOT automatically free the slot
      // when a connect() call fails — the slot leaks silently.
      try {
        await device.disconnect();
      } catch (_) {}

      // FlutterBluePlus enforces a 2000ms disconnect-to-connect gap internally.
      // We wait 2500ms to ensure the BLE stack has fully cleaned up.
      // Your logs showed: "[FBP] disconnect: enforcing 2000ms disconnect gap"
      await Future.delayed(const Duration(milliseconds: 2500));

      // Bail out if user toggled autoConnect off while we were waiting
      if (!_autoConnect) {
        _isConnecting = false;
        _statusMessage = "Disconnected";
        notifyListeners();
        return;
      }

      await device.connect(
        autoConnect: false,
        timeout: const Duration(seconds: 15),
      );

      _connectedDevice = device;

      // Listen for disconnection
      _connectionSubscription?.cancel();
      _connectionSubscription = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _onDisconnected();
        }
      });

      // Discover services
      _statusMessage = "Discovering services...";
      notifyListeners();

      // Small delay for connection to stabilize before service discovery
      await Future.delayed(const Duration(milliseconds: 500));

      List<BluetoothService> services = await device.discoverServices();

      for (BluetoothService service in services) {
        if (service.uuid.toString().toLowerCase() == serviceUuid) {
          for (BluetoothCharacteristic c in service.characteristics) {
            String charUuid = c.uuid.toString().toLowerCase();
            if (charUuid == rxCharUuid) {
              _rxCharacteristic = c;
            } else if (charUuid == txCharUuid) {
              _txCharacteristic = c;
              await c.setNotifyValue(true);
              c.onValueReceived.listen((value) {
                String received = utf8.decode(value);
                print("Received from ESP32: $received");
                _handleEspCommand(received);
              });
            }
          }
        }
      }

      if (_rxCharacteristic != null) {
        _isConnected = true;
        _isScanning = false;
        _isConnecting = false;
        _consecutiveFailures = 0; // Success! Reset failure counter
        _statusMessage = "Connected";
        notifyListeners();

        sendTimeSync();
        print("Connected to $targetDeviceName");
      } else {
        _statusMessage = "Service not found on device";
        _isConnecting = false;
        try {
          await device.disconnect();
        } catch (_) {}
        notifyListeners();

        if (_autoConnect) {
          _scheduleReconnect();
        }
      }
    } catch (e) {
      print("Connection error: $e");
      _isScanning = false;
      _isConnecting = false;

      // Try to free the GATT slot from this failed attempt
      try {
        await device.disconnect();
      } catch (_) {}

      _consecutiveFailures++;

      // Check if this is the dreaded 257 GATT registration error
      bool isGattExhausted = e.toString().contains("257") ||
          e.toString().contains("FAILURE_REGISTERING_CLIENT");

      if (isGattExhausted) {
        print("GATT client slots exhausted (failure #$_consecutiveFailures)");

        if (_consecutiveFailures >= _failuresBeforeBluetoothReset) {
          // Try the nuclear option: toggle Bluetooth to reset the entire BLE stack
          bool resetOk = await _resetBluetoothAdapter();
          if (resetOk) {
            _consecutiveFailures = 0;
            // The adapterState listener will trigger a new scan when BT comes back
            return;
          } else {
            // Can't reset programmatically — tell user to do it manually
            return;
          }
        } else {
          // First try: clean up all system connections to free slots
          _statusMessage = "Cleaning up BLE connections...";
          notifyListeners();
          await _cleanupAllConnections();
        }
      } else {
        _statusMessage = "Connection failed (attempt $_consecutiveFailures)";
        notifyListeners();
      }

      // Give up after too many failures to avoid infinite loop
      if (_consecutiveFailures >= _maxConsecutiveFailures) {
        _statusMessage =
            "Connection failed $_maxConsecutiveFailures times. "
            "Toggle Bluetooth off/on, then tap reconnect.";
        _autoConnect = false;
        notifyListeners();
        return;
      }

      if (_autoConnect) {
        _scheduleReconnect();
      }
    }
  }

  void _onDisconnected() {
    _isConnected = false;
    _isConnecting = false;
    _connectedDevice = null;
    _rxCharacteristic = null;
    _txCharacteristic = null;
    _statusMessage = "Disconnected";
    notifyListeners();

    print("Disconnected from ESP32");

    if (_autoConnect) {
      // Clean disconnect (was previously connected) — reset failure count
      _consecutiveFailures = 0;
      _scheduleReconnect();
    }
  }

  /// Schedule a reconnect with exponential backoff.
  /// Delays: 3s -> 5s -> 8s -> 13s -> 20s
  /// This prevents hammering the BLE stack (which leaks a GATT slot per failure).
  void _scheduleReconnect() {
    _reconnectTimer?.cancel();

    int delaySec = 3 + (_consecutiveFailures * _consecutiveFailures);
    if (delaySec > 20) delaySec = 20;

    print("Scheduling reconnect in ${delaySec}s (failures: $_consecutiveFailures)");

    _reconnectTimer = Timer(Duration(seconds: delaySec), () {
      if (_autoConnect && !_isConnected && !_isConnecting) {
        startScan();
      }
    });
  }

  // Handle commands received from ESP32 via BLE
  static const MethodChannel _mediaControlChannel =
      MethodChannel('com.mcdisplay.app/media');

  void _handleEspCommand(String command) {
    command = command.trim();
    if (command == "MEDIA PREV") {
      _mediaControlChannel.invokeMethod('mediaControl', {'action': 'previous'});
      print("Media control: Previous");
    } else if (command == "MEDIA NEXT") {
      _mediaControlChannel.invokeMethod('mediaControl', {'action': 'next'});
      print("Media control: Next");
    } else if (command == "MEDIA TOGGLE") {
      _mediaControlChannel.invokeMethod('mediaControl', {'action': 'toggle'});
      print("Media control: Toggle");
    }
  }

  // Send raw data to ESP32
  Future<bool> sendData(String data) async {
    if (!_isConnected || _rxCharacteristic == null) {
      print("Not connected, cannot send: $data");
      return false;
    }

    try {
      List<int> bytes = utf8.encode(data);
      await _rxCharacteristic!.write(bytes, withoutResponse: false);
      print("Sent to ESP32: $data");
      return true;
    } catch (e) {
      print("Send error: $e");
      return false;
    }
  }

  // Send time sync (Unix epoch)
  Future<void> sendTimeSync() async {
    int epoch = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await sendData("TIME $epoch");
  }

  // Send music info
  Future<void> sendMusicInfo({
    required String state,
    required String title,
    required String artist,
  }) async {
    String t = title.length > 40 ? title.substring(0, 40) : title;
    String a = artist.length > 30 ? artist.substring(0, 30) : artist;
    await sendData("MUSIC $state|$t|$a");
  }

  // Send navigation data
  Future<void> sendNavigation({
    required String distance,
    required String unit,
    required double direction,
    required String instruction,
  }) async {
    String inst = instruction.length > 40 ? instruction.substring(0, 40) : instruction;
    await sendData("NAV $distance|$unit|${direction.toStringAsFixed(0)}|$inst");
  }

  // Send slide switch command
  Future<void> sendSlideSwitch(int slideIndex) async {
    await sendData("SLIDE $slideIndex");
  }

  Future<void> sendNextSlide() async {
    await sendData("NEXT_SLIDE");
  }

  Future<void> sendPrevSlide() async {
    await sendData("PREV_SLIDE");
  }

  // Disconnect
  Future<void> disconnect() async {
    _autoConnect = false;
    _isConnecting = false;
    _consecutiveFailures = 0;
    _reconnectTimer?.cancel();
    _scanSubscription?.cancel();
    _connectionSubscription?.cancel();

    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}

    if (_connectedDevice != null) {
      try {
        await _connectedDevice!.disconnect();
      } catch (_) {}
    }

    _isConnected = false;
    _connectedDevice = null;
    _rxCharacteristic = null;
    _txCharacteristic = null;
    _statusMessage = "Disconnected";
    notifyListeners();
  }

  @override
  void dispose() {
    _reconnectTimer?.cancel();
    _scanSubscription?.cancel();
    _connectionSubscription?.cancel();
    _adapterSubscription?.cancel();
    super.dispose();
  }
}

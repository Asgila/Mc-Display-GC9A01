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

  // Tracks consecutive connection failures for backoff.
  // Each failed connect() leaks an Android GATT client slot, so we must
  // limit retries aggressively. After _maxRetries we stop and ask the
  // user to toggle Bluetooth (only way to free leaked slots).
  int _consecutiveFailures = 0;
  static const int _maxRetries = 3;

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
        // Bluetooth just turned on (user may have toggled it to fix 257).
        // Reset failure counter since the BLE stack is now clean.
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

      // Wait for scan to finish properly
      await FlutterBluePlus.isScanning
          .where((val) => val == false)
          .first
          .timeout(const Duration(seconds: 8), onTimeout: () => false);

      if (!_isConnected && !_isConnecting) {
        _isScanning = false;
        _statusMessage = "Device not found";
        notifyListeners();

        // Device not found is NOT a GATT failure — safe to retry without
        // incrementing the failure counter.
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

      // IMPORTANT: Do NOT call device.disconnect() before connect().
      //
      // Why? On Android, disconnect() on an already-disconnected device is
      // harmless, but FlutterBluePlus enforces a 2000ms gap after ANY
      // disconnect() call before allowing connect(). This unnecessary delay
      // was causing timing issues and contributed to the error cycle.
      //
      // Instead, we just call connect() directly. If there's a stale
      // connection, connect() will handle it internally.

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
        _consecutiveFailures = 0;
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

      // Try to clean up the failed connection
      try {
        await device.disconnect();
      } catch (_) {}

      _consecutiveFailures++;

      bool isGattExhausted = e.toString().contains("257") ||
          e.toString().contains("FAILURE_REGISTERING_CLIENT");

      if (isGattExhausted || _consecutiveFailures >= _maxRetries) {
        // GATT client slots are exhausted, or we've failed too many times.
        // Each retry leaks another GATT slot, making things WORSE.
        // The ONLY fix is for the user to toggle Bluetooth off/on.
        _statusMessage = "BLE error — please turn Bluetooth off and on, "
            "then tap reconnect";
        _autoConnect = false;
        notifyListeners();
        print("Stopping retries after $_consecutiveFailures failures "
            "(GATT exhausted: $isGattExhausted). "
            "User must toggle Bluetooth.");
        return;
      }

      _statusMessage = "Connection failed, retrying...";
      notifyListeners();

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
      // Was previously connected, so this is a clean disconnect.
      // The GATT client was properly released. Safe to retry.
      _consecutiveFailures = 0;
      _scheduleReconnect();
    }
  }

  /// Schedule reconnect with exponential backoff.
  /// Longer delays = fewer GATT slot leaks if connection keeps failing.
  void _scheduleReconnect() {
    _reconnectTimer?.cancel();

    // Backoff: 5s, 8s, 13s (then we stop at _maxRetries)
    int delaySec = 5 + (_consecutiveFailures * 3);
    if (delaySec > 15) delaySec = 15;

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

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
  String _statusMessage = "Disconnected";

  bool get isConnected => _isConnected;
  bool get isScanning => _isScanning;
  bool get autoConnect => _autoConnect;
  String get statusMessage => _statusMessage;
  String get deviceName => _connectedDevice?.platformName ?? "None";

  StreamSubscription? _scanSubscription;
  StreamSubscription? _connectionSubscription;
  Timer? _reconnectTimer;

  // Initialize and start auto-connect
  Future<void> initialize() async {
    // Listen for adapter state changes
    FlutterBluePlus.adapterState.listen((state) {
      if (state == BluetoothAdapterState.on && _autoConnect && !_isConnected) {
        startScan();
      }
    });

    // Start scanning if Bluetooth is already on
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
    if (value && !_isConnected) {
      startScan();
    }
  }

  // Start scanning for the ESP32 device
  Future<void> startScan() async {
    if (_isScanning || _isConnected) return;

    _isScanning = true;
    _statusMessage = "Scanning...";
    notifyListeners();

    try {
      // Try connecting to a bonded/known device first (fastest path)
      List<BluetoothDevice> bonded = await FlutterBluePlus.bondedDevices;
      for (BluetoothDevice device in bonded) {
        if (device.platformName == targetDeviceName) {
          print("Found bonded $targetDeviceName, connecting directly...");
          _isScanning = false;
          _statusMessage = "Reconnecting to bonded device...";
          notifyListeners();
          _connectToDevice(device);
          return;
        }
      }

      _scanSubscription?.cancel();
      _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
        for (ScanResult result in results) {
          if (result.device.platformName == targetDeviceName) {
            print("Found $targetDeviceName!");
            FlutterBluePlus.stopScan();
            _connectToDevice(result.device);
            return;
          }
        }
      });

      // Scan with service UUID filter for faster discovery
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 5),
        androidUsesFineLocation: true,
      );

      // Wait for scan to finish
      await Future.delayed(const Duration(seconds: 6));
      if (!_isConnected) {
        _isScanning = false;
        _statusMessage = "Device not found";
        notifyListeners();

        // Retry quickly if auto-connect is enabled
        if (_autoConnect) {
          _reconnectTimer?.cancel();
          _reconnectTimer = Timer(const Duration(seconds: 2), () {
            if (_autoConnect && !_isConnected) {
              startScan();
            }
          });
        }
      }
    } catch (e) {
      print("Scan error: $e");
      _isScanning = false;
      _statusMessage = "Scan error: $e";
      notifyListeners();
    }
  }

  // Connect to the ESP32 device
  Future<void> _connectToDevice(BluetoothDevice device) async {
    try {
      _statusMessage = "Connecting...";
      notifyListeners();

      await device.connect(
        autoConnect: false,
        timeout: const Duration(seconds: 10),
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

      List<BluetoothService> services = await device.discoverServices();

      for (BluetoothService service in services) {
        if (service.uuid.toString().toLowerCase() == serviceUuid) {
          for (BluetoothCharacteristic c in service.characteristics) {
            String charUuid = c.uuid.toString().toLowerCase();
            if (charUuid == rxCharUuid) {
              _rxCharacteristic = c;
            } else if (charUuid == txCharUuid) {
              _txCharacteristic = c;
              // Subscribe to notifications from ESP32
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
        _statusMessage = "Connected";
        notifyListeners();

        // Send time sync immediately
        sendTimeSync();

        print("Connected to $targetDeviceName");
      } else {
        _statusMessage = "Service not found on device";
        await device.disconnect();
        notifyListeners();
      }
    } catch (e) {
      print("Connection error: $e");
      _statusMessage = "Connection failed: $e";
      _isScanning = false;
      notifyListeners();

      if (_autoConnect) {
        _reconnectTimer?.cancel();
        _reconnectTimer = Timer(const Duration(seconds: 2), () {
          if (_autoConnect && !_isConnected) startScan();
        });
      }
    }
  }

  void _onDisconnected() {
    _isConnected = false;
    _connectedDevice = null;
    _rxCharacteristic = null;
    _txCharacteristic = null;
    _statusMessage = "Disconnected";
    notifyListeners();

    print("Disconnected from ESP32");

    // Auto-reconnect quickly
    if (_autoConnect) {
      _reconnectTimer?.cancel();
      _reconnectTimer = Timer(const Duration(seconds: 1), () {
        if (_autoConnect && !_isConnected) startScan();
      });
    }
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
      // BLE has a 20-byte MTU by default, but we can send longer with write
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
    // Truncate to fit BLE packet limits
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
    _reconnectTimer?.cancel();
    _scanSubscription?.cancel();
    _connectionSubscription?.cancel();

    if (_connectedDevice != null) {
      await _connectedDevice!.disconnect();
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
    super.dispose();
  }
}

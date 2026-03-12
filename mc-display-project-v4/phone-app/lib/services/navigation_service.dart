import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'ble_service.dart';

/// Navigation service that reads Google Maps navigation notifications
/// and sends direction/distance data to the ESP32 display.
///
/// Uses Android's NotificationListenerService via platform channel
/// to read Google Maps turn-by-turn navigation data.
class NavigationService extends ChangeNotifier {
  static final NavigationService _instance = NavigationService._internal();
  factory NavigationService() => _instance;
  NavigationService._internal();

  static const MethodChannel _channel = MethodChannel('com.mcdisplay.app/navigation');

  final BleService _bleService = BleService();

  String _distance = "";
  String _unit = "m";
  double _direction = 0;
  String _instruction = "";
  bool _isActive = false;

  String get distance => _distance;
  String get unit => _unit;
  double get direction => _direction;
  String get instruction => _instruction;
  bool get isActive => _isActive;

  Timer? _pollTimer;

  String _lastSentDistance = "";
  double _lastSentDirection = -999;
  String _lastSentInstruction = "";

  static const Map<String, double> directions = {
    'Straight': 0,
    'Slight Right': 45,
    'Right': 90,
    'Sharp Right': 135,
    'U-Turn': 180,
    'Sharp Left': -135,
    'Left': -90,
    'Slight Left': -45,
  };

  Future<void> initialize() async {
    _channel.setMethodCallHandler(_handleMethodCall);
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _pollNavInfo();
    });
  }

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onNavChanged':
        final Map<dynamic, dynamic> data = call.arguments;
        _updateFromNative(data);
        break;
    }
    return null;
  }

  Future<void> _pollNavInfo() async {
    try {
      final Map<dynamic, dynamic>? result =
          await _channel.invokeMethod('getNavInfo');
      if (result != null) {
        _updateFromNative(result);
      }
    } catch (e) {
      // Silently fail
    }
  }

  void _updateFromNative(Map<dynamic, dynamic> data) {
    bool active = data['active'] == 'true' || data['active'] == true;
    String dist = data['distance']?.toString() ?? "";
    String u = data['unit']?.toString() ?? "";
    double dir = double.tryParse(data['direction']?.toString() ?? "0") ?? 0;
    String inst = data['instruction']?.toString() ?? "";

    if (!active && !_isActive) return;

    bool changed = active != _isActive ||
        dist != _distance ||
        dir != _direction ||
        inst != _instruction;

    _isActive = active;
    _distance = dist;
    _unit = u;
    _direction = dir;
    _instruction = inst;

    if (changed) {
      notifyListeners();
      _sendToBleIfChanged();
    }
  }

  Future<void> setNavigation({
    required String distance,
    required String unit,
    required double direction,
    required String instruction,
  }) async {
    _distance = distance;
    _unit = unit;
    _direction = direction;
    _instruction = instruction;
    _isActive = true;
    notifyListeners();
    await _sendToBle();
  }

  Future<void> updateDistance(String distance, String unit) async {
    _distance = distance;
    _unit = unit;
    notifyListeners();
    await _sendToBle();
  }

  Future<void> clearNavigation() async {
    _distance = "";
    _unit = "m";
    _direction = 0;
    _instruction = "";
    _isActive = false;
    notifyListeners();

    if (_bleService.isConnected) {
      await _bleService.sendNavigation(
        distance: "0",
        unit: "",
        direction: 0,
        instruction: "",
      );
    }
  }

  Future<void> _sendToBleIfChanged() async {
    if (!_bleService.isConnected || !_isActive) return;

    if (_distance != _lastSentDistance ||
        _direction != _lastSentDirection ||
        _instruction != _lastSentInstruction) {
      await _sendToBle();
      _lastSentDistance = _distance;
      _lastSentDirection = _direction;
      _lastSentInstruction = _instruction;
    }
  }

  Future<void> _sendToBle() async {
    if (_bleService.isConnected && _isActive) {
      await _bleService.sendNavigation(
        distance: _distance,
        unit: _unit,
        direction: _direction,
        instruction: _instruction,
      );
    }
  }

  Future<void> resend() async {
    await _sendToBle();
  }

  Future<bool> checkPermission() async {
    try {
      final bool granted = await _channel.invokeMethod('checkPermission');
      return granted;
    } catch (e) {
      return false;
    }
  }

  Future<void> requestPermission() async {
    try {
      await _channel.invokeMethod('requestPermission');
    } catch (e) {
      print("Cannot request permission: $e");
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }
}

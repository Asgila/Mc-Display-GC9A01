import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'ble_service.dart';

/// Service that reads current media playback info from the phone
/// and sends it to the ESP32 via BLE.
///
/// On Android, this uses a NotificationListenerService via platform channel
/// to read media session data. The user needs to grant notification access.
///
/// On iOS, this would use MPNowPlayingInfoCenter (not yet implemented).
class MediaService extends ChangeNotifier {
  static final MediaService _instance = MediaService._internal();
  factory MediaService() => _instance;
  MediaService._internal();

  static const MethodChannel _channel = MethodChannel('com.mcdisplay.app/media');

  String _title = "";
  String _artist = "";
  String _state = "STOPPED"; // PLAYING, PAUSED, STOPPED
  bool _isActive = false;

  String get title => _title;
  String get artist => _artist;
  String get state => _state;
  bool get isActive => _isActive;

  Timer? _pollTimer;
  final BleService _bleService = BleService();

  // Track last sent values to avoid redundant BLE sends
  String _lastSentTitle = "";
  String _lastSentArtist = "";
  String _lastSentState = "";

  /// Initialize media monitoring
  Future<void> initialize() async {
    // Set up method channel handler for media updates from native side
    _channel.setMethodCallHandler(_handleMethodCall);

    // Try to start the native media listener
    try {
      await _channel.invokeMethod('startMediaListener');
      _isActive = true;
    } catch (e) {
      print("Media listener not available: $e");
      _isActive = false;
    }

    // Poll for media info periodically as a fallback
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _pollMediaInfo();
    });

    notifyListeners();
  }

  /// Handle method calls from native platform
  Future<dynamic> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onMediaChanged':
        final Map<dynamic, dynamic> data = call.arguments;
        _updateMedia(
          title: data['title'] ?? "",
          artist: data['artist'] ?? "",
          state: data['state'] ?? "STOPPED",
        );
        break;
    }
    return null;
  }

  /// Poll native side for current media info
  Future<void> _pollMediaInfo() async {
    if (!_isActive) return;

    try {
      final Map<dynamic, dynamic>? result =
          await _channel.invokeMethod('getMediaInfo');
      if (result != null) {
        _updateMedia(
          title: result['title'] ?? "",
          artist: result['artist'] ?? "",
          state: result['state'] ?? "STOPPED",
        );
      }
    } catch (e) {
      // Silently fail - native side might not be ready
    }
  }

  /// Update media state and send to ESP32 if changed
  void _updateMedia({
    required String title,
    required String artist,
    required String state,
  }) {
    bool changed = title != _title || artist != _artist || state != _state;

    _title = title;
    _artist = artist;
    _state = state;

    if (changed) {
      notifyListeners();

      // Only send via BLE if the data actually changed from last send
      if (title != _lastSentTitle ||
          artist != _lastSentArtist ||
          state != _lastSentState) {
        _sendToBle();
        _lastSentTitle = title;
        _lastSentArtist = artist;
        _lastSentState = state;
      }
    }
  }

  /// Manually set media info (for testing or manual input)
  void setMediaInfo({
    required String title,
    required String artist,
    required String state,
  }) {
    _updateMedia(title: title, artist: artist, state: state);
  }

  /// Send current media info to ESP32
  Future<void> _sendToBle() async {
    if (_bleService.isConnected) {
      await _bleService.sendMusicInfo(
        state: _state,
        title: _title,
        artist: _artist,
      );
    }
  }

  /// Force resend current media info
  Future<void> resend() async {
    await _sendToBle();
  }

  /// Check if notification listener permission is granted (Android)
  Future<bool> checkPermission() async {
    try {
      final bool granted = await _channel.invokeMethod('checkPermission');
      return granted;
    } catch (e) {
      return false;
    }
  }

  /// Request notification listener permission (Android)
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

import 'package:flutter/material.dart';
import '../services/ble_service.dart';
import '../services/media_service.dart';

class MusicTab extends StatefulWidget {
  const MusicTab({super.key});

  @override
  State<MusicTab> createState() => _MusicTabState();
}

class _MusicTabState extends State<MusicTab> {
  final MediaService _mediaService = MediaService();
  final BleService _bleService = BleService();
  bool _permissionGranted = false;

  @override
  void initState() {
    super.initState();
    _mediaService.addListener(_onChanged);
    _bleService.addListener(_onChanged);
    _checkPermission();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _checkPermission() async {
    _permissionGranted = await _mediaService.checkPermission();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _mediaService.removeListener(_onChanged);
    _bleService.removeListener(_onChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Permission warning
          if (!_permissionGranted)
            Card(
              color: Colors.orange.withOpacity(0.15),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    const Icon(Icons.warning_amber, color: Colors.orange, size: 32),
                    const SizedBox(height: 8),
                    const Text(
                      'Notification Access Required',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'To read music info from your media player, '
                      'this app needs notification access permission.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 13),
                    ),
                    const SizedBox(height: 12),
                    ElevatedButton(
                      onPressed: () async {
                        await _mediaService.requestPermission();
                        // Re-check after a delay (user may have granted)
                        await Future.delayed(const Duration(seconds: 2));
                        _checkPermission();
                      },
                      child: const Text('Grant Permission'),
                    ),
                  ],
                ),
              ),
            ),

          const SizedBox(height: 16),

          // Current music info
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  // Album art placeholder / music icon
                  Container(
                    width: 100,
                    height: 100,
                    decoration: BoxDecoration(
                      color: Colors.grey[800],
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      _mediaService.state == "PLAYING"
                          ? Icons.music_note
                          : _mediaService.state == "PAUSED"
                              ? Icons.pause
                              : Icons.music_off,
                      size: 48,
                      color: _mediaService.state == "PLAYING"
                          ? Colors.green
                          : Colors.grey,
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Title
                  Text(
                    _mediaService.title.isEmpty
                        ? 'No track playing'
                        : _mediaService.title,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),

                  // Artist
                  Text(
                    _mediaService.artist.isEmpty
                        ? '-'
                        : _mediaService.artist,
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.cyan[300],
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),

                  // State badge
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: _stateColor().withOpacity(0.2),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      _mediaService.state,
                      style: TextStyle(
                        color: _stateColor(),
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Send to display button
          if (_bleService.isConnected)
            ElevatedButton.icon(
              onPressed: () {
                _mediaService.resend();
                _bleService.sendSlideSwitch(1); // Switch to music slide
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Sent music info to display'),
                    duration: Duration(seconds: 1),
                  ),
                );
              },
              icon: const Icon(Icons.send),
              label: const Text('Send to Display'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),

          if (!_bleService.isConnected)
            Card(
              color: Colors.red.withOpacity(0.1),
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.bluetooth_disabled, color: Colors.red, size: 16),
                    SizedBox(width: 8),
                    Text(
                      'Not connected to display',
                      style: TextStyle(color: Colors.red),
                    ),
                  ],
                ),
              ),
            ),

          const Spacer(),

          Text(
            'Music info is read automatically from your\n'
            'media player via notification access.',
            style: TextStyle(color: Colors.grey[600], fontSize: 12),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Color _stateColor() {
    switch (_mediaService.state) {
      case "PLAYING":
        return Colors.green;
      case "PAUSED":
        return Colors.orange;
      default:
        return Colors.grey;
    }
  }
}

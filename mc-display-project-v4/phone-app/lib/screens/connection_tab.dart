import 'package:flutter/material.dart';
import '../services/ble_service.dart';

class ConnectionTab extends StatefulWidget {
  const ConnectionTab({super.key});

  @override
  State<ConnectionTab> createState() => _ConnectionTabState();
}

class _ConnectionTabState extends State<ConnectionTab> {
  final BleService _bleService = BleService();

  @override
  void initState() {
    super.initState();
    _bleService.addListener(_onChanged);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
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
          // Status card
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Icon(
                    _bleService.isConnected
                        ? Icons.bluetooth_connected
                        : _bleService.isScanning
                            ? Icons.bluetooth_searching
                            : Icons.bluetooth_disabled,
                    size: 64,
                    color: _bleService.isConnected
                        ? Colors.green
                        : _bleService.isScanning
                            ? Colors.blue
                            : Colors.grey,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _bleService.statusMessage,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  if (_bleService.isConnected) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Device: ${_bleService.deviceName}',
                      style: TextStyle(color: Colors.grey[400]),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),

          // Auto-connect toggle
          Card(
            child: SwitchListTile(
              title: const Text('Auto Connect'),
              subtitle: const Text('Automatically scan and connect to ESP32'),
              value: _bleService.autoConnect,
              onChanged: (value) {
                _bleService.setAutoConnect(value);
              },
            ),
          ),
          const SizedBox(height: 12),

          // Action buttons
          if (!_bleService.isConnected && !_bleService.isScanning)
            ElevatedButton.icon(
              onPressed: () => _bleService.startScan(),
              icon: const Icon(Icons.search),
              label: const Text('Scan for Device'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),

          if (_bleService.isScanning)
            ElevatedButton.icon(
              onPressed: null,
              icon: const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              label: const Text('Scanning...'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),

          if (_bleService.isConnected) ...[
            ElevatedButton.icon(
              onPressed: () => _bleService.sendTimeSync(),
              icon: const Icon(Icons.access_time),
              label: const Text('Sync Time'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => _bleService.disconnect(),
              icon: const Icon(Icons.bluetooth_disabled),
              label: const Text('Disconnect'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                foregroundColor: Colors.red,
              ),
            ),
          ],

          const Spacer(),

          // Info text
          Text(
            'Looking for: ESP32S3_Display',
            style: TextStyle(color: Colors.grey[600], fontSize: 12),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

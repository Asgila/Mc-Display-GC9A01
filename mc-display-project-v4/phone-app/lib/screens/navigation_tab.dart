import 'package:flutter/material.dart';
import 'dart:math' as math;
import '../services/ble_service.dart';
import '../services/navigation_service.dart';

class NavigationTab extends StatefulWidget {
  const NavigationTab({super.key});

  @override
  State<NavigationTab> createState() => _NavigationTabState();
}

class _NavigationTabState extends State<NavigationTab> {
  final NavigationService _navService = NavigationService();
  final BleService _bleService = BleService();

  bool _permissionGranted = false;

  @override
  void initState() {
    super.initState();
    _navService.addListener(_onChanged);
    _bleService.addListener(_onChanged);
    _checkPermission();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _checkPermission() async {
    try {
      _permissionGranted = await _navService.checkPermission();
      if (mounted) setState(() {});
    } catch (_) {}
  }

  @override
  void dispose() {
    _navService.removeListener(_onChanged);
    _bleService.removeListener(_onChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
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
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'To read Google Maps navigation directions, '
                      'this app needs notification access permission.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 13),
                    ),
                    const SizedBox(height: 12),
                    ElevatedButton(
                      onPressed: () async {
                        await _navService.requestPermission();
                        await Future.delayed(const Duration(seconds: 2));
                        _checkPermission();
                      },
                      child: const Text('Grant Permission'),
                    ),
                  ],
                ),
              ),
            ),

          if (!_permissionGranted) const SizedBox(height: 16),

          // Google Maps info card
          Card(
            color: Colors.blue.withOpacity(0.1),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  const Icon(Icons.map, color: Colors.blue, size: 32),
                  const SizedBox(height: 8),
                  const Text(
                    'Google Maps Integration',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _navService.isActive
                        ? 'Navigation active - sending to display'
                        : 'Start navigation in Google Maps.\n'
                            'Directions will appear automatically.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.grey[400],
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Current navigation display
          if (_navService.isActive)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    // Direction arrow
                    Transform.rotate(
                      angle: _navService.direction * math.pi / 180,
                      child: const Icon(
                        Icons.navigation,
                        size: 64,
                        color: Colors.blue,
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Distance
                    Text(
                      '${_navService.distance} ${_navService.unit}',
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),

                    // Instruction
                    Text(
                      _navService.instruction,
                      style: TextStyle(
                        fontSize: 16,
                        color: Colors.yellow[300],
                      ),
                      textAlign: TextAlign.center,
                    ),

                    const SizedBox(height: 16),

                    // Clear button
                    OutlinedButton.icon(
                      onPressed: () => _navService.clearNavigation(),
                      icon: const Icon(Icons.clear),
                      label: const Text('Clear Navigation'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red,
                      ),
                    ),
                  ],
                ),
              ),
            ),

          if (!_navService.isActive) ...[
            const SizedBox(height: 16),

            // Quick test / manual entry section
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Quick Test',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Test the navigation display with sample data:',
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey[400],
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Direction quick buttons
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: NavigationService.directions.entries.map((e) {
                        return ElevatedButton(
                          onPressed: () {
                            _navService.setNavigation(
                              distance: '200',
                              unit: 'm',
                              direction: e.value,
                              instruction: e.key,
                            );
                            if (_bleService.isConnected) {
                              _bleService.sendSlideSwitch(2);
                            }
                          },
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                          ),
                          child: Text(e.key, style: const TextStyle(fontSize: 12)),
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
            ),
          ],

          const SizedBox(height: 16),

          // Connection status
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

          if (_bleService.isConnected)
            ElevatedButton.icon(
              onPressed: () {
                _navService.resend();
                _bleService.sendSlideSwitch(2);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Sent nav info to display'),
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
        ],
      ),
    );
  }
}

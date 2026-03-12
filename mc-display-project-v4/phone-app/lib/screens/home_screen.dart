import 'package:flutter/material.dart';
import '../services/ble_service.dart';
import '../services/media_service.dart';
import '../services/navigation_service.dart';
import 'connection_tab.dart';
import 'music_tab.dart';
import 'navigation_tab.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final BleService _bleService = BleService();
  final MediaService _mediaService = MediaService();
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    _initServices();
    _bleService.addListener(_onBleChanged);
  }

  final NavigationService _navService = NavigationService();

  Future<void> _initServices() async {
    await _bleService.initialize();
    await _mediaService.initialize();
    await _navService.initialize();
  }

  void _onBleChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _bleService.removeListener(_onBleChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Text('MC Display'),
            const SizedBox(width: 12),
            _buildConnectionIndicator(),
          ],
        ),
        actions: [
          // Slide switch buttons
          if (_bleService.isConnected) ...[
            IconButton(
              icon: const Icon(Icons.access_time),
              tooltip: 'Time slide',
              onPressed: () => _bleService.sendSlideSwitch(0),
            ),
            IconButton(
              icon: const Icon(Icons.music_note),
              tooltip: 'Music slide',
              onPressed: () => _bleService.sendSlideSwitch(1),
            ),
            IconButton(
              icon: const Icon(Icons.navigation),
              tooltip: 'Nav slide',
              onPressed: () => _bleService.sendSlideSwitch(2),
            ),
          ],
        ],
      ),
      body: IndexedStack(
        index: _currentIndex,
        children: const [
          ConnectionTab(),
          MusicTab(),
          NavigationTab(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) {
          setState(() => _currentIndex = index);
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.bluetooth),
            selectedIcon: Icon(Icons.bluetooth_connected),
            label: 'Connection',
          ),
          NavigationDestination(
            icon: Icon(Icons.music_note_outlined),
            selectedIcon: Icon(Icons.music_note),
            label: 'Music',
          ),
          NavigationDestination(
            icon: Icon(Icons.navigation_outlined),
            selectedIcon: Icon(Icons.navigation),
            label: 'Navigation',
          ),
        ],
      ),
    );
  }

  Widget _buildConnectionIndicator() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: _bleService.isConnected
            ? Colors.green.withOpacity(0.2)
            : Colors.red.withOpacity(0.2),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            _bleService.isConnected
                ? Icons.bluetooth_connected
                : Icons.bluetooth_disabled,
            size: 14,
            color: _bleService.isConnected ? Colors.green : Colors.red,
          ),
          const SizedBox(width: 4),
          Text(
            _bleService.isConnected ? 'Connected' : 'Disconnected',
            style: TextStyle(
              fontSize: 11,
              color: _bleService.isConnected ? Colors.green : Colors.red,
            ),
          ),
        ],
      ),
    );
  }
}

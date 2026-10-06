import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/config/app_config.dart';
import '../core/storage/kv_store.dart';
import '../core/theme/app_theme.dart';
import 'monitor.dart';
import 'ui/dashboard_screen.dart';

/// Hardware Prototype mode: the read-only monitor of the ESP32 intersection.
/// No login, no server: the only connection is the controller's WebSocket (or the simulator).
class HardwareApp extends StatefulWidget {
  const HardwareApp({super.key, required this.store, this.createMonitor});

  final KeyValueStore store;
  final HardwareMonitor Function(KeyValueStore store)? createMonitor;

  @override
  State<HardwareApp> createState() => _HardwareAppState();
}

class _HardwareAppState extends State<HardwareApp> {
  late final HardwareMonitor _monitor = (widget.createMonitor ?? HardwareMonitor.forStore)(widget.store)..start();

  @override
  void dispose() {
    _monitor.dispose(); // closes the socket, releases Wi-Fi binding and keep-awake
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final config = context.watch<AppConfig>();
    return ChangeNotifierProvider.value(
      value: _monitor,
      child: MaterialApp(
        title: 'Hardware Intersection Monitor',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: config.themeMode,
        home: const HardwareDashboardScreen(),
      ),
    );
  }
}

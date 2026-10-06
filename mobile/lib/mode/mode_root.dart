import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app.dart';
import '../core/auth/token_store.dart';
import '../core/config/app_config.dart';
import '../core/network/api_client.dart';
import '../core/storage/kv_store.dart';
import '../core/theme/app_theme.dart';
import '../data/local/telemetry_queue.dart';
import '../hardware/hardware_app.dart';
import '../hardware/monitor.dart';
import 'app_mode.dart';
import 'mode_selection_screen.dart';

/// Top of the widget tree: shows the mode selection, the hardware monitor or the software app.
/// The software app (login, server, tracking) is only built in Software mode, so Hardware mode
/// makes no network calls apart from the WebSocket to the intersection controller.
class ModeRoot extends StatefulWidget {
  const ModeRoot({super.key, required this.store, required this.config, this.hardwareMonitor});

  final KeyValueStore store;
  final AppConfig config;

  /// Tests replace the hardware monitor (no sockets, no platform channels).
  final HardwareMonitor Function(KeyValueStore store)? hardwareMonitor;

  @override
  State<ModeRoot> createState() => _ModeRootState();
}

class _ModeRootState extends State<ModeRoot> {
  late final _modes = AppModeController(widget.store);

  // Software-mode resources, created on first use and kept across mode switches.
  ApiClient? _api;
  Future<TelemetryQueue>? _queue;

  Future<TelemetryQueue> _openQueue() =>
      _queue ??= kIsWeb ? Future.value(MemoryTelemetryQueue()) : SqliteTelemetryQueue.open();

  @override
  void dispose() {
    _modes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: _modes),
        ChangeNotifierProvider.value(value: widget.config),
      ],
      child: Consumer2<AppModeController, AppConfig>(
        builder: (context, modes, config, _) => switch (modes.mode) {
          null => MaterialApp(
              key: const ValueKey('mode-selection'),
              title: 'Smart Traffic',
              debugShowCheckedModeBanner: false,
              theme: AppTheme.light(),
              darkTheme: AppTheme.dark(),
              themeMode: config.themeMode,
              home: const ModeSelectionScreen(),
            ),
          AppMode.hardware => HardwareApp(
              key: const ValueKey('mode-hardware'),
              store: widget.store,
              createMonitor: widget.hardwareMonitor,
            ),
          AppMode.software => FutureBuilder<TelemetryQueue>(
              key: const ValueKey('mode-software'),
              future: _openQueue(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return MaterialApp(
                    debugShowCheckedModeBanner: false,
                    theme: AppTheme.light(),
                    home: const Scaffold(body: Center(child: CircularProgressIndicator())),
                  );
                }
                _api ??= ApiClient(config, TokenStore());
                return SmartTrafficApp(config: config, api: _api!, queue: snapshot.data!);
              },
            ),
        },
      ),
    );
  }
}

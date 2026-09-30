import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app.dart';
import 'core/auth/token_store.dart';
import 'core/config/app_config.dart';
import 'core/network/api_client.dart';
import 'data/local/telemetry_queue.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final config = await AppConfig.load();
  final api = ApiClient(config, TokenStore());
  final TelemetryQueue queue = kIsWeb ? MemoryTelemetryQueue() : await SqliteTelemetryQueue.open();
  runApp(SmartTrafficApp(config: config, api: api, queue: queue));
}

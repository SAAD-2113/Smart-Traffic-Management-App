import 'package:flutter/material.dart';

import 'core/config/app_config.dart';
import 'core/storage/kv_store.dart';
import 'mode/mode_root.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Local settings only; nothing here touches the network.
  final store = await KeyValueStore.open();
  final config = await AppConfig.load(store);
  runApp(ModeRoot(store: store, config: config));
}

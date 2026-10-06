import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:smart_traffic/core/auth/token_store.dart';
import 'package:smart_traffic/core/config/app_config.dart';
import 'package:smart_traffic/core/network/api_client.dart';
import 'package:smart_traffic/core/storage/kv_store.dart';
import 'package:smart_traffic/data/repositories/auth_repository.dart';
import 'package:smart_traffic/features/auth/auth_controller.dart';
import 'package:smart_traffic/features/auth/login_screen.dart';
import 'package:smart_traffic/hardware/monitor.dart';
import 'package:smart_traffic/mode/app_mode.dart';
import 'package:smart_traffic/mode/mode_root.dart';

import 'hardware/fakes.dart';

void main() {
  group('remembered mode', () {
    test('nothing is remembered on a fresh install', () {
      expect(AppModeController(MemoryKeyValueStore()).mode, isNull);
    });

    test('a remembered choice opens that mode next time; switching clears it', () async {
      final store = MemoryKeyValueStore();
      final first = AppModeController(store);
      await first.choose(AppMode.hardware, remember: true);
      final second = AppModeController(store);
      expect(second.mode, AppMode.hardware);
      expect(second.remember, isTrue);
      await second.switchMode();
      expect(second.mode, isNull);
      expect(AppModeController(store).mode, isNull);
      expect(AppModeController(store).remember, isTrue, reason: 'the checkbox keeps its state');
    });

    test('without "Remember my choice" the next launch asks again', () async {
      final store = MemoryKeyValueStore();
      await AppModeController(store).choose(AppMode.software, remember: false);
      expect(AppModeController(store).mode, isNull);
    });
  });

  testWidgets('fresh install: mode selection comes before login; Hardware opens without login; Switch mode returns',
      (tester) async {
    tester.view.physicalSize = const Size(412, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = MemoryKeyValueStore();
    final config = await AppConfig.load(store);
    final monitors = <HardwareMonitor>[];
    await tester.pumpWidget(ModeRoot(
      store: store,
      config: config,
      hardwareMonitor: (_) {
        final rig = TestRig(store: store);
        monitors.add(rig.monitor);
        return rig.monitor;
      },
    ));
    await tester.pump();
    expect(find.text('Hardware Prototype'), findsOneWidget);
    expect(find.text('Live monitor for the physical V2I intersection'), findsOneWidget);
    expect(find.text('Software System'), findsOneWidget);
    expect(find.text('Full app, trips and analysis'), findsOneWidget);
    expect(find.text('Remember my choice'), findsOneWidget);
    expect(find.text('Sign in'), findsNothing);

    await tester.tap(find.text('Remember my choice'));
    await tester.pump();
    await tester.tap(find.text('Hardware Prototype'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Hardware Intersection Monitor'), findsOneWidget);
    expect(find.text('Sign in'), findsNothing);
    expect(AppModeController(store).mode, AppMode.hardware, reason: 'remembered');

    await tester.tap(find.byKey(const ValueKey('switch-mode')));
    await tester.pump();
    await tester.pump();
    expect(find.text('Hardware Prototype'), findsOneWidget);
    expect(find.text('Hardware Intersection Monitor'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Switch mode on the login screen returns to the selection', (tester) async {
    final store = MemoryKeyValueStore();
    final config = await AppConfig.load(store);
    final modes = AppModeController(store);
    await modes.choose(AppMode.software, remember: false);
    final api = ApiClient(config, TokenStore());
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: modes),
        ChangeNotifierProvider.value(value: config),
        ChangeNotifierProvider(create: (_) => AuthController(AuthRepository(api), api)),
      ],
      child: const MaterialApp(home: LoginScreen()),
    ));
    expect(find.text('Sign in'), findsWidgets);
    await tester.ensureVisible(find.text('Switch mode'));
    await tester.tap(find.text('Switch mode'));
    await tester.pump();
    expect(modes.mode, isNull);
  });
}

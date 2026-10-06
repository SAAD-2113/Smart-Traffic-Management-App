import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:smart_traffic/core/storage/kv_store.dart';
import 'package:smart_traffic/core/theme/app_theme.dart';
import 'package:smart_traffic/hardware/monitor.dart';
import 'package:smart_traffic/hardware/ui/dashboard_screen.dart';
import 'package:smart_traffic/mode/app_mode.dart';

import 'fakes.dart';

Widget _harness(HardwareMonitor m) => MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppModeController(MemoryKeyValueStore())),
        ChangeNotifierProvider.value(value: m),
      ],
      child: MaterialApp(theme: AppTheme.light(), home: const HardwareDashboardScreen()),
    );

/// Large window so every card is built; two columns.
void _bigWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(1280, 3400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _finish(WidgetTester tester, HardwareMonitor m) async {
  await tester.pumpWidget(const SizedBox());
  m.dispose();
}

void main() {
  testWidgets('every card shows the example frame', (tester) async {
    _bigWindow(tester);
    final semantics = tester.ensureSemantics();
    final rig = TestRig();
    final m = rig.monitor..start();
    rig.source.open();
    rig.source.send(exampleFrame);
    await tester.pumpWidget(_harness(m));
    await tester.pump();

    // 1. top bar
    expect(find.text('Hardware Intersection Monitor'), findsOneWidget);
    expect(find.text('Intersection I01'), findsOneWidget);
    expect(find.text('ONLINE'), findsOneWidget);
    expect(find.text('Switch mode'), findsOneWidget);
    // 2. mode and status
    expect(find.text('ADAPTIVE'), findsOneWidget);
    expect(find.text('Controller: Normal'), findsOneWidget);
    expect(find.text('Congestion: High'), findsOneWidget);
    expect(find.text('6 vehicles'), findsOneWidget);
    // 3. live signals
    expect(find.text('13'), findsOneWidget); // ceil(12980 ms)
    expect(find.text('NORTH/SOUTH — GREEN'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^N signal green')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^E signal red')), findsOneWidget);
    // 4. timing
    expect(find.text('Adaptive timing'), findsOneWidget);
    expect(find.text('22 s'), findsOneWidget);
    expect(find.text('9.0 s'), findsOneWidget);
    expect(find.text('13.0 s'), findsOneWidget);
    expect(find.text('EAST/WEST'), findsOneWidget);
    expect(find.text('NS demand 4 veh -> 22 s'), findsOneWidget);
    // 5. traffic
    expect(find.text('Demand  NS 4 · EW 1 vehicles'), findsOneWidget);
    expect(find.text('Free'), findsOneWidget);
    // 6. plan
    for (final v in ['22', '14', '19', '27']) {
      expect(find.text(v), findsOneWidget, reason: 'plan value $v');
    }
    // 7. V2I and system
    expect(find.text('OK'), findsOneWidget);
    expect(find.text('6.0'), findsOneWidget);
    expect(find.text('180 ms ago'), findsOneWidget);
    expect(find.text('12 min 45 s'), findsOneWidget);
    expect(find.text('1.0.0'), findsOneWidget);
    expect(find.text('182000 bytes'), findsOneWidget);
    // 8. vehicles: collapsed by default
    expect(find.text('Vehicles (1)'), findsOneWidget);
    expect(find.text('V01'), findsNothing);
    await tester.tap(find.text('Vehicles (1)'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('V01'), findsOneWidget);
    expect(find.text('12.4 m'), findsOneWidget);
    expect(find.text('0 km/h'), findsOneWidget);
    expect(find.text('Queued'), findsWidgets);
    semantics.dispose();
    await _finish(tester, m);
  });

  testWidgets('a frame with missing fields shows dashes and does not crash', (tester) async {
    _bigWindow(tester);
    final semantics = tester.ensureSemantics();
    final rig = TestRig();
    final m = rig.monitor..start();
    rig.source.open();
    rig.source.send(exampleWith({'mode': 'turbo'},
        remove: ['timing', 'plan', 'health', 'signals.E', 'approaches.N.queued', 'id', 'congestion']));
    await tester.pumpWidget(_harness(m));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('TURBO'), findsOneWidget);
    expect(find.text('Intersection —'), findsOneWidget);
    expect(find.text('Congestion: —'), findsOneWidget);
    expect(find.text('—'), findsWidgets);
    expect(find.bySemanticsLabel(RegExp(r'^E signal unknown')), findsOneWidget);
    semantics.dispose();
    await _finish(tester, m);
  });

  testWidgets('ev_request shows a 5 s popup; preemption shows the red banner', (tester) async {
    _bigWindow(tester);
    final rig = TestRig();
    final m = rig.monitor..start();
    rig.source.open();
    rig.source.send(exampleWith({
      'ctrl': 'preempt',
      'preempt': {'active': true, 'approach': 'E', 'vehicle_id': 'V05', 'status': 'granted'},
    }));
    await tester.pumpWidget(_harness(m));
    await tester.pump();
    expect(find.text('EMERGENCY PRIORITY — EAST — V05'), findsOneWidget);

    rig.source.send(eventFrame('ev_request', 'V05 E granted'));
    await tester.pump();
    expect(find.byKey(const ValueKey('ev-popup')), findsOneWidget);
    expect(find.text('Vehicle V05'), findsOneWidget);
    expect(find.text('Approach East'), findsOneWidget);
    expect(find.text('GRANTED'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5)); // the popup closes itself after 5 s
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('ev-popup')), findsNothing);

    rig.source.send(eventFrame('ev_request', 'V06 N rejected', seq: 2001));
    await tester.pump();
    expect(find.text('REJECTED'), findsOneWidget);
    await tester.tap(find.text('Dismiss'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('ev-popup')), findsNothing);
    expect(find.text('Emergency request'), findsNWidgets(2)); // both in the event log
    await _finish(tester, m);
  });

  testWidgets('V2I loss, unsupported version and simulated data have banners', (tester) async {
    _bigWindow(tester);
    final rig = TestRig(simulator: true);
    final m = rig.monitor..start();
    rig.source.open();
    rig.source.send(exampleWith({'ctrl': 'fallback', 'v2i.link': 'lost', 'mode': 'fixed'}));
    rig.source.send(exampleWith({'v': 3}));
    await tester.pumpWidget(_harness(m));
    await tester.pump();
    expect(find.text('V2I link lost — fixed-time fallback active'), findsOneWidget);
    expect(find.textContaining('Unsupported data version (v=3)'), findsOneWidget);
    expect(find.textContaining('SIMULATED DATA'), findsOneWidget);
    expect(find.text('FIXED'), findsOneWidget);
    expect(find.text('Fixed plan'), findsWidgets);
    await _finish(tester, m);
  });

  testWidgets('without fresh frames the dashboard goes STALE and freezes', (tester) async {
    _bigWindow(tester);
    final rig = TestRig();
    final m = rig.monitor..start();
    rig.source.open();
    rig.source.send(exampleFrame);
    await tester.pumpWidget(_harness(m));
    await tester.pump();
    expect(find.text('Last known state'), findsNothing);
    rig.clock.advance(1600);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('STALE'), findsOneWidget);
    expect(find.text('Last known state'), findsOneWidget);
    expect(find.text('12'), findsOneWidget); // frozen at 12980 - 1500 ms
    rig.clock.advance(8000);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('12'), findsOneWidget);
    rig.source.close();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('OFFLINE'), findsOneWidget);
    await _finish(tester, m);
  });
}

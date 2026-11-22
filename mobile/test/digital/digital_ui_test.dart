import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:smart_traffic/core/auth/token_store.dart';
import 'package:smart_traffic/core/config/app_config.dart';
import 'package:smart_traffic/core/network/api_client.dart';
import 'package:smart_traffic/core/storage/kv_store.dart';
import 'package:smart_traffic/core/theme/app_theme.dart';
import 'package:smart_traffic/digital/data/v2i_models.dart';
import 'package:smart_traffic/digital/data/v2i_repository.dart';
import 'package:smart_traffic/digital/intersection/digital_intersection.dart';
import 'package:smart_traffic/digital/transport/links.dart';
import 'package:smart_traffic/digital/transport/loopback.dart';
import 'package:smart_traffic/digital/ui/digital_app.dart';
import 'package:smart_traffic/digital/ui/driver_home.dart';
import 'package:smart_traffic/digital/ui/host_home.dart';
import 'package:smart_traffic/hardware/platform/hardware_platform.dart';
import 'package:smart_traffic/mode/app_mode.dart';
import 'package:smart_traffic/mode/mode_selection_screen.dart';
import 'package:smart_traffic/services/location_service.dart';
import 'package:v2i_core/v2i_core.dart' as v2i;

import '../hardware/fakes.dart' show NoPlatform;

/// The test binding's clock (follows tester.pump(duration)), starting at 0 like millis().
class BindingClock implements v2i.MonoClock {
  BindingClock() : _start = _now();
  final int _start;
  static int _now() => TestWidgetsFlutterBinding.instance.clock.now().millisecondsSinceEpoch;

  @override
  int nowMs() => _now() - _start;
}

class FakeRepo extends V2IRepository {
  FakeRepo(super.api);
  final sessions = <HostedSession>[];
  final calls = <String>[];

  HostedSession _s(String name, double lat, double lon) => HostedSession(
      id: 'S1', name: name, joinCode: 'ABC234', centerLat: lat, centerLon: lon, status: 'OPEN', createdAt: DateTime.utc(2026));

  @override
  Future<List<HostedSession>> mySessions() async => [...sessions];

  @override
  Future<HostedSession> createSession({required String name, required double centerLat, required double centerLon}) async {
    calls.add('create $name $centerLat $centerLon');
    final s = _s(name, centerLat, centerLon);
    sessions.add(s);
    return s;
  }

  @override
  Future<List<V2IProfileRow>> profiles({String? emergencyStatus}) async => [
        V2IProfileRow(fullName: 'Ali', email: 'ali@example.com', vehicleId: 1004, emergencyStatus: 'REQUESTED', emergencyReason: 'Rescue 1122'),
      ];

  @override
  Future<V2IProfileRow> setEmergency(String email, String status) async {
    calls.add('emergency $email $status');
    return (await profiles()).first;
  }

  @override
  Future<JoinedSession> join(String code) async {
    calls.add('join $code');
    return JoinedSession(sessionId: 'S1', name: 'Gate', centerLat: v2i.CENTER_LAT, centerLon: v2i.CENTER_LON, vehicleId: 1001, emergency: false);
  }

  @override
  Future<List<JoinedSession>> joined() async => [];
}

class FakeServices extends DigitalServices {
  FakeServices(super.repo, this.hub);
  final LoopbackHub hub;

  @override
  v2i.MonoClock clock() => BindingClock();

  @override
  IntersectionLink intersection(String sessionId) => hub.intersection();

  @override
  VehicleLink vehicle(String sessionId) => hub.vehicle(1001);
}

Future<(FakeRepo, LoopbackHub, Widget Function(Widget))> harness() async {
  final store = MemoryKeyValueStore();
  final config = await AppConfig.load(store);
  final repo = FakeRepo(ApiClient(config, TokenStore()));
  final hub = LoopbackHub();
  Widget wrap(Widget home) => MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: config),
          ChangeNotifierProvider(create: (_) => AppModeController(store)),
          Provider<V2IRepository>.value(value: repo),
          Provider<DigitalServices>.value(value: FakeServices(repo, hub)),
          Provider<HardwarePlatform>.value(value: const NoPlatform()),
          Provider(create: (_) => LocationService()),
        ],
        child: MaterialApp(theme: AppTheme.light(), home: Scaffold(body: SingleChildScrollView(child: home))),
      );
  return (repo, hub, wrap);
}

void bigWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(1280, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('the mode selection offers Digital V2I', (tester) async {
    bigWindow(tester);
    final modes = AppModeController(MemoryKeyValueStore());
    await tester.pumpWidget(ChangeNotifierProvider.value(
        value: modes, child: MaterialApp(theme: AppTheme.light(), home: const ModeSelectionScreen())));
    expect(find.text('Digital V2I'), findsOneWidget);
    await tester.tap(find.text('Digital V2I'));
    expect(modes.mode, AppMode.digital);
  });

  testWidgets('host: create a session at the firmware centre and run the intersection', (tester) async {
    bigWindow(tester);
    final (repo, _, wrap) = await harness();
    final me = V2IMe(role: 'ADMIN', canHost: true, canDrive: false);
    await tester.pumpWidget(wrap(HostHome(me: me)));
    await tester.pumpAndSettle();
    expect(find.text('New digital intersection'), findsOneWidget);
    expect(find.text('31.500000'), findsOneWidget, reason: 'default centre = CENTER_LAT');
    // admin: emergency requests
    expect(find.text('Ali · vehicle 1004'), findsOneWidget);
    await tester.tap(find.byTooltip('Approve'));
    await tester.pump();
    expect(repo.calls, contains('emergency ali@example.com APPROVED'));

    await tester.enterText(find.byKey(const ValueKey('session-name')), 'Campus gate');
    await tester.tap(find.byKey(const ValueKey('create-session')));
    await tester.pump();
    await tester.pump();
    expect(repo.calls, contains('create Campus gate 31.5 74.3'));
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Campus gate'), findsWidgets);
    expect(find.text('Code ABC234'), findsOneWidget);
    expect(find.text('Digital intersection'), findsOneWidget);
    expect(find.text('LANE NORTH — GREEN'), findsOneWidget);
    expect(find.text('Requested: AUTO'), findsOneWidget);

    await tester.tap(find.text('Fixed'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Requested: FIXED'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('show-join-code')));
    await tester.pump();
    expect(find.byKey(const ValueKey('join-qr')), findsOneWidget);
    expect(find.byKey(const ValueKey('join-code-big')), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pump();

    await tester.pumpWidget(const SizedBox()); // disposes the controller and its timer
  });

  testWidgets('driver: join with the code, drive, and show the signal from the intersection\'s ACK', (tester) async {
    bigWindow(tester);
    final (repo, hub, wrap) = await harness();
    // the intersection phone, on the same in-app transport and the same test clock
    final junction = DigitalIntersection(
        name: 'Gate', centerLat: v2i.CENTER_LAT, centerLon: v2i.CENTER_LON, link: hub.intersection(), clock: BindingClock())
      ..start();

    final me = V2IMe(role: 'END_USER', canHost: false, canDrive: true, vehicleId: 1001, emergencyStatus: 'NONE');
    await tester.pumpWidget(wrap(DriverHome(me: me, onChanged: () {})));
    await tester.pumpAndSettle();
    expect(find.text('1001'), findsOneWidget);
    expect(find.byKey(const ValueKey('request-emergency')), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('join-code')), 'abc234');
    await tester.tap(find.byKey(const ValueKey('join')));
    await tester.pumpAndSettle();
    expect(repo.calls, contains('join abc234'));
    expect(find.text('Simulated drive (firmware motion simulation)'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('start-drive')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Vehicle 1001'), findsOneWidget);
    expect(find.text('Intersection running'), findsOneWidget);
    // N is green at the start (fixed round-robin), the vehicle approaches on N
    expect(find.text('GREEN'), findsOneWidget);
    expect(find.textContaining('Lane N · APPROACHING'), findsOneWidget);
    expect(find.textContaining('Basis (display only)'), findsOneWidget);
    expect(junction.controller.findVeh(1001), isNotNull);
    expect(junction.rttMs[1001], isNotNull, reason: 'the vehicle reports its RTT');

    junction.stop(); // the intersection goes away: RED after 3 s without an ACK
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('RED'), findsOneWidget);
    expect(find.byKey(const ValueKey('link-lost')), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    junction.dispose();
  });
}

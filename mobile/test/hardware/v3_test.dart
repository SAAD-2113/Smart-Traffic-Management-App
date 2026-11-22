import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:smart_traffic/core/storage/kv_store.dart';
import 'package:smart_traffic/core/theme/app_theme.dart';
import 'package:smart_traffic/hardware/link/twin_source.dart';
import 'package:smart_traffic/hardware/model/frame.dart';
import 'package:smart_traffic/hardware/monitor.dart';
import 'package:smart_traffic/hardware/ui/dashboard_screen.dart';
import 'package:smart_traffic/mode/app_mode.dart';
import 'package:v2i_core/v2i_core.dart' as v2i;

import 'fakes.dart';

/// A digital firmware-v3 controller on a fake clock, the frames it would send.
class Junction {
  Junction() {
    ic.start();
  }

  final clock = v2i.FakeClock(1000);
  late final ic = v2i.IntersectionController(clock: clock, intersectionName: 'STMS-RSU');

  void run(int ms, {void Function()? each}) {
    for (var i = 0; i < ms; i++) {
      clock.advance(1);
      ic.tick();
      each?.call();
    }
  }

  String frame() => jsonEncode(ic.buildState());

  /// A hand-made pos packet (like the README's curl).
  String? send(int id, double x, double y, {double spd = 0, int hdg = 0, int ty = 0, int seq = 1}) {
    final (lat, lon) = const v2i.Geometry().xyToLatLon(x, y);
    return ic.processPacket(
      v2i.PosPacket(id: id, ty: ty, lat: lat, lon: lon, spd: spd, hdg: hdg, seq: seq, hw: 'laptop').encode(),
    );
  }
}

Widget _harness(HardwareMonitor m) => MultiProvider(
  providers: [
    ChangeNotifierProvider(create: (_) => AppModeController(MemoryKeyValueStore())),
    ChangeNotifierProvider.value(value: m),
  ],
  child: MaterialApp(theme: AppTheme.light(), home: const HardwareDashboardScreen()),
);

void main() {
  group('parser', () {
    test('a firmware v3 state frame (from the v2i_core port) parses into V3State', () {
      final j = Junction();
      j.run(2000); // clock 3 s: 1 s into the N green
      j.send(901, 0, -33, hdg: 0); // README curl: QUEUED on S
      final f = parseFrame(j.frame());
      expect(f, isA<V3StateFrame>());
      final s = (f as V3StateFrame).state;
      expect(s.version, 2);
      expect((s.mode, s.requestedMode, s.targetMode), ('fixed', 'auto', 'adaptive'));
      expect(s.switchPending, isTrue);
      expect((s.cur, s.phase), ('N', 'GREEN'));
      expect(s.intersection, 'STMS-RSU');
      expect(s.lanes.map((l) => l.lane), ['N', 'E', 'S', 'W']);
      expect(s.signals, {'N': 'G', 'E': 'R', 'S': 'R', 'W': 'R'});
      expect(s.lane('N')!.remS, 29);
      expect(s.lane('S')!.queued, 1);
      expect(s.lane('S')!.approaching, 0);
      expect(s.plan.satFlow, 1800);
      expect(s.vehicles.single.id, 901);
      expect(s.vehicles.single.st, 'QUEUED');
      expect(s.vehicles.single.lane, 'S');
      expect(s.vehicles.single.spdKmh, 0);
      expect(s.vehicles.single.rssi, isNull);
      expect(s.emergencyLane, isNull, reason: '"-" means none');
      expect(s.timing.targetGreenS, 30);
      expect(s.timing.nextPhase, 'YELLOW');
    });

    test('missing and wrong-typed fields become null, never an exception', () {
      final f = parseFrame('{"v":2,"t":"state","lanes":[{"lane":"N","sig":5}],"vehicles":[1,{"id":"x"}],"plan":7}');
      final s = (f as V3StateFrame).state;
      expect(s.mode, isNull);
      expect(s.lanes.single.sig, '5');
      expect(s.vehicles.single.id, isNull);
      expect(s.plan.cycleS, isNull);
    });

    test('the Part-3 layout still parses as before; other versions are refused', () {
      expect(parseFrame(exampleFrame), isA<StateFrame>());
      expect(parseFrame('{"v":3,"t":"state"}'), isA<UnsupportedFrame>());
      expect(parseFrame('{"t":"state"}'), isA<UnsupportedFrame>());
    });
  });

  group('monitor with firmware v3 frames', () {
    test('per-lane MM:SS displays count down between frames and freeze when data stops', () {
      final j = Junction();
      j.run(1000); // clock 2 s: N green starts
      final rig = TestRig();
      final m = rig.monitor..start();
      rig.source.open();
      rig.source.send(j.frame());
      expect(m.isV3, isTrue);
      expect(m.intersectionLabel, 'STMS-RSU');
      expect(m.laneDisplay('N'), '00:30');
      expect(m.laneDisplay('E'), '00:34');
      expect(m.countdownS, 30);
      rig.clock.advance(1000);
      expect(m.laneDisplay('N'), '00:29');
      expect(m.laneDisplay('W'), '01:41');
      rig.clock.advance(5000); // no frames: frozen 1.5 s after the last one
      expect(m.isLive, isFalse);
      expect(m.laneDisplay('N'), '00:29');
      m.dispose();
    });

    test('events are derived from state changes: vehicles, mode, emergency, phase', () {
      final j = Junction();
      final rig = TestRig();
      final m = rig.monitor..start();
      rig.source.open();
      var seq = 1;
      void feed(int ms, {void Function(int t)? each}) {
        for (var t = 0; t < ms; t++) {
          j.clock.advance(1);
          rig.clock.advance(1);
          each?.call(j.clock.ms);
          j.ic.tick();
          if (j.clock.ms % 500 == 0) rig.source.send(j.frame());
        }
      }

      feed(10000);
      // emergency vehicle 60 m west, heading east, every 500 ms from 10 s
      feed(
        20000,
        each: (t) {
          if (t % 500 == 0) j.send(201, -60, 0, spd: 30, hdg: 90, ty: 1, seq: seq++);
        },
      );
      final titles = m.events.map((e) => e.title).toList().reversed.toList();
      expect(titles, contains('Vehicle 201 connected'));
      expect(titles, contains('Emergency vehicle: priority requested'));
      expect(titles, contains('Emergency priority green'));
      expect(titles, contains('Lane W GREEN'));
      expect(titles.indexOf('Emergency vehicle: priority requested'), lessThan(titles.indexOf('Emergency priority green')));
      expect(m.notice?.request.result, 'granted');
      expect(m.notice?.request.approach, 'W');
      expect(m.notice?.request.vehicleId, '201');

      feed(4000); // the vehicle stops sending: removed by the controller after 3 s
      expect(m.events.map((e) => e.title), contains('Vehicle 201 removed'));
      m.dispose();
    });

    test('a controller restart (uptime_s goes back) is logged', () {
      final rig = TestRig();
      final m = rig.monitor..start();
      rig.source.open();
      final a = Junction()..run(30000);
      rig.source.send(a.frame());
      final b = Junction()..run(1000);
      rig.source.send(b.frame());
      expect(m.events.first.title, 'Controller restarted');
      m.dispose();
    });
  });

  group('dashboard', () {
    testWidgets('shows the four-lane layout for firmware v3 frames', (tester) async {
      tester.view.physicalSize = const Size(1280, 3400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final semantics = tester.ensureSemantics();
      final j = Junction();
      j.run(1000); // N green starts
      j.send(101, 0.0, 12.4, hdg: 180);
      final rig = TestRig();
      final m = rig.monitor..start();
      rig.source.open();
      rig.source.send(j.frame());
      await tester.pumpWidget(_harness(m));
      await tester.pump();

      expect(find.text('Intersection STMS-RSU'), findsOneWidget);
      expect(find.text('FIXED'), findsOneWidget);
      expect(find.text('Requested: AUTO'), findsOneWidget);
      expect(find.text('Switching to ADAPTIVE at the next lane decision'), findsOneWidget);
      expect(find.text('LANE NORTH — GREEN'), findsOneWidget);
      expect(find.byKey(const ValueKey('display-N')), findsOneWidget);
      expect(find.text('00:30'), findsOneWidget); // N display
      expect(find.text('00:34'), findsOneWidget); // E display
      expect(find.bySemanticsLabel(RegExp(r'^W signal red')), findsOneWidget);
      expect(find.text('Lanes'), findsOneWidget);
      expect(find.text('Webster plan (preview)'), findsOneWidget);
      expect(find.text('Vehicles (1)'), findsOneWidget);
      expect(find.text('auto: 1 vehicle(s) sending data -> adaptive | switching at next lane decision'), findsOneWidget);

      semantics.dispose();
      await tester.pumpWidget(const SizedBox());
      m.dispose();
    });
  });

  group('simulator = firmware v3 twin', () {
    test('emits valid v3 frames every 500 ms; vehicles power on after 5 s and switch AUTO to adaptive', () {
      final clock = v2i.FakeClock(0);
      final frames = <String>[];
      final src = TwinSource(clock: clock, useTimer: false)..onFrame = frames.add;
      src.start();
      for (var t = 0; t < 40000; t += 10) {
        clock.advance(10);
        src.step();
      }
      expect(frames.length, inInclusiveRange(79, 81));
      expect(frames.every((f) => f.startsWith('{"v":2,"t":"state",')), isTrue);
      final last = (parseFrame(frames.last) as V3StateFrame).state;
      expect(last.vehicleCount, 6);
      expect(last.mode, 'adaptive');
      expect(last.controller, 'Firmware v3 twin (simulated)');
    });

    test('vehicles off -> removed after 3 s, AUTO back to fixed; emergency now -> priority requested', () {
      final clock = v2i.FakeClock(0);
      String? frame;
      final src = TwinSource(clock: clock, useTimer: false)..onFrame = (f) => frame = f;
      src.start();
      void run(int ms) {
        for (var t = 0; t < ms; t += 10) {
          clock.advance(10);
          src.step();
        }
      }

      run(20000);
      src.setVehiclesOn(false);
      run(4000);
      var s = (parseFrame(frame!) as V3StateFrame).state;
      expect(s.vehicleCount, 0);
      run(80000);
      s = (parseFrame(frame!) as V3StateFrame).state;
      expect(s.mode, 'fixed');
      expect(s.dataLost, isTrue);

      src.emergencyNow();
      run(1000);
      s = (parseFrame(frame!) as V3StateFrame).state;
      expect(s.emergencyLane, 'W');
      expect(s.vehicles.single.isEmergency, isTrue);

      src.command('f');
      expect(src.requestedMode, 'fixed');
    });
  });
}

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_traffic/digital/data/v2i_models.dart';
import 'package:smart_traffic/digital/intersection/digital_intersection.dart';
import 'package:smart_traffic/digital/transport/loopback.dart';
import 'package:smart_traffic/digital/vehicle/digital_vehicle.dart';
import 'package:smart_traffic/services/packet_builder.dart' show GpsFix;
import 'package:v2i_core/v2i_core.dart' as v2i;

const lat0 = 31.520370, lon0 = 74.358749; // a session centre that is not the firmware's default

JoinedSession joined(int vid, {bool emergency = false}) =>
    JoinedSession(sessionId: 's1', name: 'Gate', centerLat: lat0, centerLon: lon0, vehicleId: vid, emergency: emergency);

class Rig {
  Rig() {
    junction = DigitalIntersection(name: 'Gate', centerLat: lat0, centerLon: lon0, link: hub.intersection(), clock: clock, useTimer: false)
      ..start();
  }

  final clock = v2i.FakeClock(1000);
  final hub = LoopbackHub();
  late final DigitalIntersection junction;
  final vehicles = <DigitalVehicle>[];

  DigitalVehicle add(int vid, DriveSource source, {bool emergency = false}) {
    final v = DigitalVehicle(
      session: joined(vid, emergency: emergency),
      link: hub.vehicle(vid, emergency: emergency),
      source: source,
      clock: clock,
      useTimer: false,
      random: math.Random(vid),
    )..start();
    vehicles.add(v);
    return v;
  }

  Future<void> run(int ms, {void Function()? each}) async {
    for (var i = 0; i < ms; i++) {
      clock.advance(1);
      await Future<void>.value(); // deliver messages (the loopback is asynchronous)
      for (final v in vehicles) {
        v.step();
      }
      junction.step();
      each?.call();
    }
  }
}

void main() {
  test('vehicles show what the intersection ACKs; the lane is decided from the coordinates around the session centre',
      () async {
    final r = Rig();
    final car = r.add(1001, const SimulatedDrive(arm: 0, slot: 0, startDist: 100, kmh: 30));
    final amb = r.add(1002, const SimulatedDrive(arm: 3, slot: 0, startDist: 140, kmh: 50), emergency: true);
    var checked = 0;
    await r.run(60000, each: () {
      // whenever the car has a fresh ACK, its signal is what the controller said for its lane
      if (!car.linkLost && car.lane != '-' && r.clock.ms - car.unit.lastAckMs == 0) {
        expect(car.signal, isIn(['G', 'Y', 'R']));
        checked++;
      }
    });
    expect(checked, greaterThan(50));
    expect(r.junction.members.keys, containsAll([1001, 1002]));
    final lines = r.junction.log.lines.map((l) => l.text).toList();
    expect(lines.where((l) => l.startsWith('[MISMATCH]')), isEmpty);
    expect(lines, contains(matches(RegExp(r'^\[PRIO\] emergency id=1002 detected on lane W'))));
    expect(lines, contains(matches(RegExp(r'^\[SIG \] lane W GREEN 5\.0s \(EMERGENCY PRIORITY id=1002'))));
    expect(amb.detectionToGreenS, isNotNull);
    // RTT is measured for every ACK. In-app transport, 1 ms test loop: the packet is handled on the
    // next pass and the ACK read on the one after, so 2 ms.
    expect(car.rttSamples, isNotEmpty);
    expect(car.rttSamples.toSet(), {2}, reason: 'measured: ${car.rttSamples.toSet()}');
    expect(r.junction.rttMs[1001], isNotNull);
    expect(r.junction.v3!.vehicles.map((v) => v.id), containsAll([1001, 1002]));
    expect(r.junction.v3!.intersection, 'Gate');
  });

  test('no ACK for 3 s: the vehicle shows RED (it never decides its own signal)', () async {
    final r = Rig();
    final car = r.add(1001, const SimulatedDrive(arm: 0, startDist: 100));
    await r.run(3000);
    expect(car.linkLost, isFalse);
    r.junction.stop(); // the intersection phone goes away
    await r.run(3001);
    expect(car.linkLost, isTrue);
    expect(car.signal, 'R');
  });

  test('requested mode from the intersection screen = the firmware Serial command', () async {
    final r = Rig();
    await r.run(2000);
    r.junction.setRequestedMode('adaptive');
    expect(r.junction.requestedMode, 'adaptive');
    expect(r.junction.log.lines.last.text,
        "[MODE] requested=adaptive (from app 'a') -> target adaptive, effective fixed now, change applies at the next lane decision");
    expect(r.junction.v3!.switchPending, isTrue);
  });

  test('replay sends the recorded points at their recorded times, then stops', () async {
    final r = Rig();
    const geo = v2i.Geometry(centerLat: lat0, centerLon: lon0);
    TripPoint at(double t, double northM, double kmh) {
      final (la, lo) = geo.xyToLatLon(0, northM);
      return TripPoint(t: t, lat: la, lon: lo, speedKmh: kmh, headingDeg: 180);
    }

    final v = r.add(1003, ReplayDrive([at(0, 120, 30), at(2, 100, 30), at(4, 60, 20), at(6, 30, 3)]));
    await r.run(5000);
    final veh = r.junction.controller.findVeh(1003)!;
    expect(veh.st, v2i.V2IState.approaching);
    expect(veh.dist, closeTo(60, 0.5), reason: 'the point recorded at 4 s, sent until 6 s');
    await r.run(2500);
    expect(r.junction.controller.findVeh(1003)!.st, v2i.V2IState.queued);
    await r.run(5000);
    expect(v.replayFinished, isTrue);
    expect(r.junction.controller.findVeh(1003), isNull, reason: 'removed by the controller 3 s after the last packet');
    expect(r.junction.log.lines.map((l) => l.text), contains(startsWith('[LOST] id=1003 Phone')));
  });

  test('live GPS: nothing before the first fix; no tl; no hdg while slow; [BASIS] matches the intersection', () async {
    final r = Rig();
    final fixes = StreamController<GpsFix>();
    final v = DigitalVehicle(
      session: joined(1004),
      link: r.hub.vehicle(1004),
      source: const LiveGpsDrive(),
      gps: () => fixes.stream,
      clock: r.clock,
      useTimer: false,
    )..start();
    r.vehicles.add(v);
    await r.run(1000);
    expect(v.packetsSent, 0, reason: 'nothing is sent before the first fix');
    const geo = v2i.Geometry(centerLat: lat0, centerLon: lon0);
    GpsFix fix(double northM, double mps, double hdg) {
      final (la, lo) = geo.xyToLatLon(0, northM);
      return GpsFix(time: DateTime.utc(2026), lat: la, lon: lo, accuracyM: 4, speedMps: mps, headingDeg: hdg);
    }

    fixes.add(fix(40, 0.5, 90)); // slow: heading not trusted
    await r.run(600);
    var veh = r.junction.controller.findVeh(1004)!;
    expect(veh.hdg, -1, reason: 'no hdg sent');
    expect(veh.tl, -1, reason: 'no tl sent');
    expect(veh.st, v2i.V2IState.queued, reason: '40 m, 1.8 km/h, first packet counts as getting closer');
    fixes.add(fix(38, 8, 180)); // moving south, towards the centre on the N arm
    await r.run(600);
    veh = r.junction.controller.findVeh(1004)!;
    expect(veh.hdg, 180);
    expect(veh.st, v2i.V2IState.approaching);
    expect((v.basis!.lane, v.basis!.st), (veh.lane, veh.st));
    await fixes.close();
  });
}

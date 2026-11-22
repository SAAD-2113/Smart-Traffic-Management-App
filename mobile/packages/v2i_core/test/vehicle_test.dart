import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:v2i_core/v2i_core.dart';

import 'bench.dart';

/// The 6 firmware presets plus 5 more on every arm (ids 105..109), all in motion simulation.
final fleet = [
  ...PRESETS,
  const VehicleSpec(id: 105, type: VT_NORMAL, arm: 1, slot: 1, startDist: 125, kmh: 30, delayS: 5),
  const VehicleSpec(id: 106, type: VT_NORMAL, arm: 2, slot: 0, startDist: 100, kmh: 40, delayS: 12),
  const VehicleSpec(id: 107, type: VT_NORMAL, arm: 2, slot: 1, startDist: 120, kmh: 35, delayS: 14),
  const VehicleSpec(id: 108, type: VT_NORMAL, arm: 3, slot: 0, startDist: 90, kmh: 25, delayS: 3),
  const VehicleSpec(id: 109, type: VT_NORMAL, arm: 3, slot: 1, startDist: 110, kmh: 30, delayS: 40),
];

void main() {
  group('long run: 11 simulated vehicles, 20 min', () {
    late Bench b;
    var entries = 0;
    final effectiveAtEntry = <String, int>{};
    final truthAtEntry = <String, int>{};
    var basisChecked = 0;
    final basisDisagree = <String>[];

    setUpAll(() {
      b = Bench();
      b.runUntil(5000);
      for (var i = 0; i < fleet.length; i++) {
        b.addVehicle(fleet[i], seed: 11 + i);
      }
      final prevS = <V2IVehicle, double>{};
      final prevAck = <V2IVehicle, (String, int)>{};
      final prevSent = <V2IVehicle, int>{};
      b.run(
        20 * 60 * 1000,
        each: () {
          for (final v in b.vehicles) {
            // stop-line entry this step?
            final before = prevS[v];
            if (before != null && before >= STOP_LINE_M && v.simS < STOP_LINE_M) {
              entries++;
              // the signal the simulation acted on (ACK state from before this step's beacon)
              final (sig, at) = prevAck[v]!;
              final eff = (at == 0 || b.clock.ms - at > ACK_TIMEOUT_MS) ? 'R' : sig;
              effectiveAtEntry.update(eff, (n) => n + 1, ifAbsent: () => 1);
              truthAtEntry.update(b.ic.sigOf(v.vArm), (n) => n + 1, ifAbsent: () => 1);
            }
            prevS[v] = v.simS;
            prevAck[v] = (v.ackSig, v.lastAckMs);

            // [BASIS] (vehicle) vs the intersection's decision for the same packet
            if (v.packetsSent != prevSent[v]) {
              prevSent[v] = v.packetsSent;
              final iv = b.ic.findVeh(v.vId);
              final basis = v.lastBasis!;
              basisChecked++;
              if (iv == null || iv.lane != basis.lane || iv.st != basis.st) {
                basisDisagree.add('t=${b.clock.ms} id=${v.vId} basis=${basis.lane}/${basis.st} rx=${iv?.lane}/${iv?.st}');
              }
            }
          }
        },
      );
    });

    test('vehicles cross the stop line only on their effective G or Y', () {
      expect(entries, greaterThan(100), reason: 'the run must exercise many crossings');
      expect(effectiveAtEntry['R'] ?? 0, 0);
      print(
        'stop-line entries: $entries, effective signal at entry: $effectiveAtEntry, '
        'controller signal at entry: $truthAtEntry',
      );
    });

    test('ground truth: no vehicle enters while the controller shows red for its lane', () {
      expect(truthAtEntry['R'] ?? 0, 0);
    });

    test('[BASIS] gives the same lane and state as the intersection for every packet', () {
      expect(basisChecked, greaterThan(20000));
      expect(basisDisagree, isEmpty);
    });

    test('no [MISMATCH], no bad packets, no lost packets, no vehicle dropped', () {
      expect(b.lines.where((l) => l.startsWith('[MISMATCH]')), isEmpty);
      expect(b.lines.where((l) => l.startsWith('[LOST]')), isEmpty);
      expect(b.ic.pktBad, 0);
      expect(b.ic.vehs.where((v) => v.used).map((v) => v.lost), everyElement(0));
      expect(b.ic.connectedVehicles(), fleet.length);
    });

    test('trips loop (LOOP_TRIP) and both emergency vehicles got priority greens', () {
      final finished = b.vehicles.map((v) => v.log.lines.where((l) => l.text.startsWith('[SIM ] trip finished')).length);
      expect(finished, everyElement(greaterThanOrEqualTo(3)));
      expect(b.lines.where((l) => l.contains('EMERGENCY PRIORITY id=201')), isNotEmpty);
      expect(b.lines.where((l) => l.contains('EMERGENCY PRIORITY id=202')), isNotEmpty);
    });

    test('green times stay within the firmware limits', () {
      for (final l in b.sig().where((l) => l.contains(' GREEN '))) {
        final s = double.parse(RegExp(r'GREEN (\d+\.\d)s').firstMatch(l)!.group(1)!);
        if (l.contains('EMERGENCY')) {
          expect(s, PRIO_MIN_GREEN_MS / 1000);
        } else if (l.contains('fixed')) {
          expect(s, FIXED_GREEN_MS / 1000);
        } else {
          expect(s, inInclusiveRange(G_MIN_MS / 1000, G_MAX_MS / 1000), reason: l);
        }
      }
    });
  });

  group('REPLAY table (TEST_SOURCE 1)', () {
    test('one row per beacon; states as commented in the firmware table', () {
      final b = Bench();
      final v = b.addVehicle(PRESETS[0], source: VehicleSource.replay);
      final states = <String>[];
      var sent = 0;
      b.run(
        7600,
        each: () {
          if (v.packetsSent != sent) {
            sent = v.packetsSent;
            final iv = b.ic.findVeh(101)!;
            states.add(stateName(iv.st));
          }
        },
      );
      expect(states, [
        ...List.filled(6, 'APPROACHING'), // 120 .. 45 m
        'QUEUED', 'QUEUED', 'QUEUED', 'QUEUED', // 30 m slow, then stopped at 20 m
        'APPROACHING', // 15 m, moving again
        'CROSSING', 'CROSSING', // 5 m, -5 m: inside the box, previous lane N
        'IGNORED', 'IGNORED', // leaving on S
        'APPROACHING', // the table loops
      ]);
      expect(b.ic.findVeh(101)!.lane, 0);
    });
  });

  group('vehicle unit', () {
    V2IVehicle unit(FakeClock clock, List<String> sent, {VehicleSource source = VehicleSource.external, int? Function()? rssi}) =>
        V2IVehicle(
          spec: PRESETS[0],
          clock: clock,
          send: sent.add,
          hw: 'ESP32-S3',
          source: source,
          rssi: rssi,
          random: math.Random(1),
        );

    test('[TX ], [BASIS] and [ACK ] lines in the README layout', () {
      final clock = FakeClock(1000);
      final sent = <String>[];
      final v = unit(clock, sent, rssi: () => -50)..start();
      v.seqNo = 25;
      v.setExternalFix(31.500111, 74.299996, 0, 181);
      v.action = 'STOPPED';
      v.sendBeacon();
      clock.advance(3);
      v.onAck('{"t":"ack","id":101,"seq":25,"mode":"fixed","lane":"N","st":"QUEUED","sig":"R","rem":71.5,"pri":0}');
      expect(v.log.lines.map((l) => l.text).skip(1), [
        '[TX  ] #25 id=101 normal ESP32-S3 lat=31.500111 lon=74.299996 spd=0.0 hdg=181 tl=N rssi=-50 (124 B) | sig=R STOPPED',
        '[BASIS] bearing=358deg dist=12.4m hdg=181deg spd=0.0km/h => expect lane N, QUEUED  -> counts in Qw',
        '[ACK ] seq=25 lane=N st=QUEUED sig=R rem=71.5s mode=fixed',
      ]);
      expect(v.lastRttMs, 3);
    });

    test('no ACK for more than 3 s => treat the signal as RED (link lost)', () {
      final clock = FakeClock(1000);
      final v = unit(clock, [])..start();
      expect(v.effectiveSignal(), 'R');
      expect(v.linkLost, isTrue);
      v.onAck('{"t":"ack","id":101,"seq":0,"mode":"adaptive","lane":"N","st":"APPROACHING","sig":"G","rem":10.0,"pri":0}');
      expect(v.effectiveSignal(), 'G');
      clock.advance(3000);
      expect(v.effectiveSignal(), 'G');
      clock.advance(1);
      expect(v.effectiveSignal(), 'R');
      expect(v.linkLost, isTrue);
    });

    test('rem counts down locally between ACKs, never below 0', () {
      final clock = FakeClock(1000);
      final v = unit(clock, [])..start();
      v.onAck('{"t":"ack","id":101,"seq":0,"mode":"adaptive","lane":"N","st":"QUEUED","sig":"R","rem":10.0,"pri":0}');
      clock.advance(2500);
      expect(v.remNow(), closeTo(7.5, 1e-9));
      clock.advance(9000);
      expect(v.remNow(), 0);
    });

    test('ACKs for another id, or not ACKs, are ignored', () {
      final clock = FakeClock(1000);
      final v = unit(clock, [])..start();
      v.onAck('{"t":"ack","id":102,"seq":0,"mode":"adaptive","lane":"N","st":"QUEUED","sig":"G","rem":1.0,"pri":0}');
      v.onAck('{"t":"state","v":2}');
      v.onAck('not json');
      expect(v.acksRx, 0);
      expect(v.effectiveSignal(), 'R');
    });

    test('the vehicle never decides its signal: G only comes from an ACK', () {
      final clock = FakeClock(1000);
      final sent = <String>[];
      final v = V2IVehicle(spec: PRESETS[0], clock: clock, send: sent.add, random: math.Random(3))..start();
      for (var i = 0; i < 60000; i++) {
        clock.advance(1);
        v.tick();
      }
      expect(sent.length, 120, reason: 'one beacon per 500 ms');
      expect(v.simS, greaterThanOrEqualTo(STOP_LINE_M), reason: 'no ACK = red: waits at the stop line');
      expect(v.committed, isFalse);
    });

    test('round-trip time is measured per seq from send to ACK', () {
      final b = Bench();
      final v = V2IVehicle(spec: PRESETS[0], clock: b.clock, send: (_) {}, random: math.Random(1))..start();
      final due = <(int, String)>[];
      final w = V2IVehicle(
        spec: PRESETS[1],
        clock: b.clock,
        random: math.Random(2),
        send: (p) {
          final a = b.ic.processPacket(p);
          if (a != null) due.add((b.clock.ms + 37, a));
        },
      );
      b.vehicles.add(w);
      b.run(
        5000,
        each: () {
          for (final d in List.of(due)) {
            if (b.clock.ms >= d.$1) {
              due.remove(d);
              w.onAck(d.$2);
            }
          }
        },
      );
      expect(w.rttSamples, hasLength(greaterThanOrEqualTo(9)));
      expect(w.rttSamples, everyElement(37));
      expect(v.rttSamples, isEmpty);
    });

    test('live GPS: no tl, hdg left out while unknown, [BASIS] then uses the previous distance', () {
      final clock = FakeClock(1000);
      final sent = <String>[];
      final v = V2IVehicle(
        spec: const VehicleSpec(id: 1001, type: VT_NORMAL, arm: 0, slot: 0, startDist: 0, kmh: 0, delayS: 0),
        clock: clock,
        send: sent.add,
        hw: 'Pixel',
        source: VehicleSource.external,
        sendTestLane: false,
      )..start();
      final geo = const Geometry();
      final (lat, lon) = geo.xyToLatLon(0, 50);
      v.setExternalFix(lat, lon, 20, null);
      v.sendBeacon();
      expect(sent.last, isNot(contains('"hdg"')));
      expect(sent.last, isNot(contains('"tl"')));
      expect(v.lastBasis!.st, V2IState.approaching);
      final (lat2, lon2) = geo.xyToLatLon(0, 52); // farther away, no heading
      v.setExternalFix(lat2, lon2, 20, null);
      v.sendBeacon();
      expect(v.lastBasis!.reason, V2IReason.headingAway);
      expect(v.log.lines.last.text, contains('hdg=-'));
    });
  });
}

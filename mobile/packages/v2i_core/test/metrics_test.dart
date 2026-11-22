import 'package:test/test.dart';
import 'package:v2i_core/v2i_core.dart';

/// A controller with a recorder and hand-made packets.
class Rec {
  Rec() {
    ic = IntersectionController(clock: clock, intersectionName: 'TEST');
    rec = SessionRecorder(ic);
    ic.start();
  }

  final clock = FakeClock(1000);
  late final IntersectionController ic;
  late final SessionRecorder rec;
  final _senders = <({int id, double x, double y, double spd, int hdg, int ty, int from, int? until, List<int> seq})>[];

  void sender(int id, double x, double y, {double spd = 0, required int hdg, int ty = 0, int from = 0, int? until, List<int>? seqs}) =>
      _senders.add((id: id, x: x, y: y, spd: spd, hdg: hdg, ty: ty, from: from, until: until, seq: seqs ?? []));

  void run(int ms) {
    for (var i = 0; i < ms; i++) {
      clock.advance(1);
      final now = clock.ms;
      for (final s in _senders) {
        if (now < s.from || (s.until != null && now >= s.until!) || (now - s.from) % 500 != 0) continue;
        final n = (now - s.from) ~/ 500;
        final seq = s.seq.isEmpty ? n + 1 : (n < s.seq.length ? s.seq[n] : s.seq.last + n - s.seq.length + 1);
        final (lat, lon) = const Geometry().xyToLatLon(s.x, s.y);
        ic.processPacket(PosPacket(id: s.id, ty: s.ty, lat: lat, lon: lon, spd: s.spd, hdg: s.hdg, seq: seq, hw: 'test').encode());
        rec.vehicleSample(s.id);
      }
      ic.tick();
      rec.tick();
    }
  }

  Metrics get metrics => computeMetrics(rec.recording);
}

void main() {
  test('the recorder keeps the full log (beyond the 5000-line view) and one snapshot per second', () {
    final r = Rec();
    for (final id in [101, 102, 103]) {
      r.sender(id, 0, 14.0 + (id - 101) * 6, hdg: 180, from: 3000); // an [RX] line each, every 500 ms
    }
    r.run(20 * 60 * 1000);
    expect(r.rec.recording.log.length, greaterThan(r.ic.log.lines.length), reason: 'the bounded view dropped lines');
    expect(r.rec.recording.log.length, greaterThan(8000));
    expect(r.rec.recording.log.first.text, startsWith('=== DIGITAL V2I INTERSECTION'), reason: 'from start() on');
    expect(r.rec.recording.snapshots.length, inInclusiveRange(1199, 1201));
    expect(r.rec.recording.samples.length, 3 * 2397, reason: 'packets at 3 s, 3.5 s, ... 1201 s');
  });

  test('wait = QUEUED on a red lane until that lane\'s next green (hand check: 8.0 s)', () {
    final r = Rec();
    // queued on S from 3 s; N's fixed green (from 2 s) has no demand: ended after 5 s at 7 s,
    // yellow 3 s, all-red 1 s, S adaptive green at 11 s
    r.sender(201, 0, -30, hdg: 0, from: 3000);
    r.run(20000);
    expect(r.rec.recording.log.map((l) => l.text), contains(startsWith('[SIG ] lane S GREEN')));
    final m = r.metrics;
    expect(m.waits, hasLength(1));
    expect(m.waits.single.queuedMs, 3000);
    expect(m.waits.single.greenMs, 11000);
    expect(m.waits.single.waitS, 8.0);
    expect(m.avgWaitS, 8.0);
    expect(m.vehicles[201]!.waits, [8.0]);
  });

  test('a vehicle queued while its lane is already green is not counted as waiting', () {
    final r = Rec();
    r.sender(101, 0, 20, hdg: 180, from: 3000); // N, which is green from 2 s
    r.run(10000);
    expect(r.metrics.waits, isEmpty);
  });

  test('cycle length = green to green of the same lane; FIXED gives 136 s', () {
    final r = Rec();
    r.run(300000);
    final m = r.metrics;
    expect(m.cycles.map((c) => c.cycleS).toSet(), {136.0});
    expect(m.meanCycleS, 136.0);
    expect(m.greens.first.plannedS, 30.0);
    expect(m.greens.first.endMs! - m.greens.first.startMs, 30000);
  });

  test('planned C0 from the [PLAN] line (README hand check: 44.6 s) and emergency detection -> green 4.0 s', () {
    final r = Rec();
    for (final (i, d) in [(1, 12.4), (2, 18.4), (3, 24.4)]) {
      r.sender(100 + i, 0, d, hdg: 180, from: 71000);
    }
    r.sender(104, 90, 0, spd: 30, hdg: 270, from: 71000);
    r.run(84000);
    expect(r.metrics.plannedCycles.first.$2, 44.6);
    r.sender(201, -60, 0, spd: 30, hdg: 90, ty: 1, from: 90000);
    r.run(10000);
    final e = r.metrics.emergencies.single;
    expect((e.id, e.lane, e.seconds), (201, 3, 4.0));
  });

  test('packet loss from seq gaps; counters of a vehicle that was removed and came back are added', () {
    final r = Rec();
    r.sender(101, 0, 40, hdg: 180, from: 3000, until: 6000, seqs: [1, 2, 4, 5, 9, 10]); // lost 1 + 3
    r.sender(101, 0, 40, hdg: 180, from: 12000, until: 13000, seqs: [1, 2]); // removed after 3 s, back
    r.run(15000);
    final v = r.metrics.vehicles[101]!;
    expect(v.pkts, 8);
    expect(v.lost, 4);
    expect(v.lossPct, closeTo(33.33, 0.01));
  });

  test('export: every file says digital simulation, measured on <device> on <date>', () {
    final r = Rec();
    r.sender(201, 0, -30, hdg: 0, from: 3000);
    r.run(20000);
    final label = ExportLabel(device: 'Pixel 8 (Android 15)', date: DateTime(2026, 11, 22, 10, 30), session: 'Gate', transport: 'In-app');
    for (final text in [
      eventLog(r.rec.recording, label),
      snapshotsCsv(r.rec.recording, label),
      samplesCsv(r.rec.recording, label),
      metricsCsv(r.metrics, r.rec.recording, label),
    ]) {
      expect(text, contains('# digital simulation, measured on Pixel 8 (Android 15) on 2026-11-22 10:30'));
    }
    final snap = snapshotsCsv(r.rec.recording, label).split('\n').where((l) => l.isNotEmpty && !l.startsWith('#')).toList();
    expect(snap.first, startsWith('t_s,mode,requested,phase,cur,sig_N,sig_E,sig_S,sig_W,rem_s_N'));
    expect(snap.length - 1, r.rec.recording.snapshots.length);
    final metrics = metricsCsv(r.metrics, r.rec.recording, label);
    expect(metrics, contains('wait_avg,all vehicles,8.0,s,'));
    expect(eventLog(r.rec.recording, label), contains('[SIG ] lane S GREEN'));
  });

  group('Fixed vs Adaptive', () {
    test('same scenario and seed: forced FIXED never adapts, AUTO does; runs are repeatable', () {
      final s = Scenario.presets(durationMs: 5 * 60 * 1000);
      final (fixed, auto) = compareFixedAdaptive(s);
      expect(fixed.recording.log.where((l) => l.text.startsWith('[PLAN] adaptive')), isEmpty);
      expect(fixed.recording.snapshots.every((x) => x.mode == 'fixed'), isTrue);
      expect(auto.recording.log.where((l) => l.text.startsWith('[PLAN] adaptive')), isNotEmpty);
      // FIXED: every normal green is the 30 s round-robin; priority greens and resumed lanes
      // (presets 5 and 6) make some green-to-green times shorter, so 136 s is not the mean
      expect(fixed.metrics.greens.where((g) => !g.priority).map((g) => g.plannedS).toSet(), {30.0});
      expect(fixed.metrics.emergencies, isNotEmpty, reason: 'priority works in every mode');
      expect(auto.metrics.emergencies, isNotEmpty);
      expect(fixed.speedup, greaterThan(1));
      // deterministic: the same seed gives the same run
      final again = runScenario(s, command: 'o');
      expect(again.recording.log.map((l) => l.text).toList(), auto.recording.log.map((l) => l.text).toList());
      final csv = comparisonCsv(
          fixed, auto, s, ExportLabel(device: 'test', date: DateTime(2026, 11, 22), session: 'comparison'));
      expect(csv, contains('metric,unit,FIXED (forced),AUTO'));
      expect(csv, contains('x real time'));
      print('5 min of presets 1-6: FIXED avg wait ${cfix(fixed.metrics.avgWaitS ?? 0, 1)} s (${fixed.metrics.waits.length}), '
          'AUTO avg wait ${cfix(auto.metrics.avgWaitS ?? 0, 1)} s (${auto.metrics.waits.length}); '
          'throughput ${fixed.metrics.totalThroughput} vs ${auto.metrics.totalThroughput}; '
          'speed ${cfix(fixed.speedup, 0)}x / ${cfix(auto.speedup, 0)}x');
    });
  });
}

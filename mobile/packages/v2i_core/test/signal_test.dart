import 'package:test/test.dart';
import 'package:v2i_core/v2i_core.dart';

import 'bench.dart';

double north(double m) => CENTER_LAT + m / M_PER_DEG_LAT;

void main() {
  group('README case 1: no vehicles -> FIXED 30 s round-robin', () {
    test('N -> E -> S -> W, 30 s green + 3 s yellow + 1 s all-red, 136 s cycle', () {
      final b = Bench();
      b.run(300000);
      final greens = [
        for (final (t, s) in b.timed)
          if (s.startsWith('[SIG ] lane ') && s.contains(' GREEN ')) (t, s),
      ];
      expect(greens.first.$2, '[SIG ] lane N GREEN 30.0s (fixed 30s round-robin: auto, no vehicle connected)');
      expect(greens.first.$1, 2000, reason: 'boot ALL RED 1.0 s, then N green');
      expect([for (final g in greens.take(5)) g.$2.substring(12, 13)], ['N', 'E', 'S', 'W', 'N']);
      for (var i = 1; i < greens.length; i++) {
        expect(greens[i].$1 - greens[i - 1].$1, 34000, reason: '30 + 3 + 1 s per lane');
      }
      expect(greens[4].$1 - greens[0].$1, 136000, reason: '136 s cycle');
      // yellow 30 s after the green, all-red 3 s later, next green 1 s later
      expect(b.timeOf('[SIG ] lane N YELLOW 3.0s (green time over)'), 32000);
      final allRed = [
        for (final (t, s) in b.timed)
          if (s == '[SIG ] ALL RED 1.0s') t,
      ];
      expect(allRed.take(2), [1000, 35000]);
      expect(b.timeOf('[SIG ] lane E GREEN 30.0s (fixed 30s round-robin: auto, no vehicle connected)'), 36000);
    });

    test('[STAT] line has the firmware layout', () {
      final b = Bench();
      b.runUntil(10001);
      expect(
        b.lines.where((l) => l.startsWith('[STAT]')).last,
        '[STAT] FIXED (auto: no vehicle connected -> fixed) req=auto | N:G E:R S:R W:R | cur=N GREEN 22.0s | '
        'veh=0 | Qw N=0.0 LOW E=0.0 LOW S=0.0 LOW W=0.0 LOW | overall=LOW',
      );
    });

    test('MM:SS displays: 00:30 at the start of green, 00:03 on yellow, estimated wait on red', () {
      final b = Bench();
      b.runUntil(2000);
      expect(b.ic.laneDisplay(0), '00:30');
      // E waits for N's 30 s green + 4 s clearance
      expect(b.ic.laneDisplay(1), '00:34');
      // W waits N, E, S
      expect(b.ic.laneDisplay(3), '01:42');
      b.runUntil(32000);
      expect(b.ic.laneDisplay(0), '00:03');
      b.runUntil(35000);
      expect(b.ic.sigOf(0), 'R');
    });
  });

  group('Webster', () {
    test('hand check: Qw=[3.0 0.5 0 0] -> q, y, Y, L, C0, g (g_E 4.1 clamped to 5.0)', () {
      final b = Bench();
      // 3 vehicles queued on N (stationary, heading south), 1 approaching on E.
      for (final (i, d) in [(1, 12.4), (2, 18.4), (3, 24.4)]) {
        b.addSender(StaticSender(id: 100 + i, lat: north(d), lon: CENTER_LON, spd: 0, hdg: 180, tl: 'N', from: 71000));
      }
      final (lat, lon) = StaticSender.at(90, 0);
      b.addSender(StaticSender(id: 104, lat: lat, lon: lon, spd: 30, hdg: 270, tl: 'E', from: 71000));
      // Vehicles start 1 s into S's fixed green (S has no demand -> ended early).
      b.runUntil(85000);

      expect(b.lines, contains('[MODE] auto: vehicle data received (1 connected) -> ADAPTIVE from the next lane decision'));
      expect(b.timeOf('[MODE] switching to adaptive: lane S has no demand -> fixed green ended early after 5.0s'), 75000);
      expect(b.lines, contains('[MODE] effective mode now ADAPTIVE (auto: 4 vehicle(s) sending data -> adaptive)'));
      expect(
        b.lines,
        contains(
          '[PLAN] adaptive Qw=[3.0 0.5 0.0 0.0] q=[540 90 0 0]veh/h y=[0.300 0.050 0.000 0.000] Y=0.350 L=16s '
          'C0=44.6s g=[24.5 5.0 0.0 0.0]s',
        ),
      );
      expect(b.timeOf('[SIG ] lane N GREEN 24.5s (adaptive Webster: Qw=3.0 y=0.300 HIGH density)'), 79000);

      final p = b.ic.decisionPlan;
      expect(p.q, [540, 90, 0, 0]);
      expect(p.y[0], closeTo(0.300, 1e-6));
      expect(p.y[1], closeTo(0.050, 1e-6));
      expect(p.Y, closeTo(0.350, 1e-6));
      expect(p.L, 16);
      expect(p.C, closeTo(44.615, 0.001)); // (1.5*16 + 5) / (1 - 0.35)
      expect(p.g[0], closeTo(24.527, 0.001)); // (0.30/0.35) * (44.615 - 16)
      expect(p.g[1], 5.0); // 4.088 clamped up to G_MIN
      expect(p.g.sublist(2), [0, 0]);
      expect(b.ic.phaseDur, 24527, reason: '(uint32_t)(g * 1000 + 0.5)');
    });

    test('Y is capped at 0.90 and the cycle is clamped to 30..90 s', () {
      final b = Bench();
      for (var i = 0; i < 16; i++) {
        final arm = i % 4;
        final d = 15.0 + (i ~/ 4) * 6;
        final (lat, lon) = StaticSender.at([0.0, d, 0.0, -d][arm], [d, 0.0, -d, 0.0][arm]);
        b.addSender(StaticSender(id: 300 + i, lat: lat, lon: lon, spd: 0, hdg: [180, 270, 0, 90][arm]));
      }
      b.run(3000);
      b.ic.densityCheck();
      final p = b.ic.computePlan();
      expect(b.ic.ls.map((s) => s.qw), [4, 4, 4, 4]);
      expect(p.Y, closeTo(0.9, 1e-6));
      expect(p.C, 90, reason: '(1.5*16+5)/(1-0.9) = 290 s, clamped to 90');
      for (final g in p.g) {
        expect(g, closeTo(18.5, 1e-5)); // (0.225/0.9)*(90-16), float32
      }
    });

    test('no demand anywhere -> idle green 5 s; lanes without demand are skipped', () {
      final b = Bench();
      // A vehicle that is IGNORED (out of range) keeps the mode adaptive but adds no demand.
      final (lat, lon) = StaticSender.at(0, 400);
      b.addSender(StaticSender(id: 201, ty: 1, lat: lat, lon: lon, spd: 0, hdg: 180, from: 3000));
      b.runUntil(45000);
      expect(b.lines, contains('[SIG ] lane E GREEN 5.0s (adaptive: vehicles connected but no demand -> idle green)'));
    });
  });
}

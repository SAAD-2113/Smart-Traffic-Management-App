import 'package:test/test.dart';
import 'package:v2i_core/v2i_core.dart';

import 'bench.dart';

double north(double m) => CENTER_LAT + m / M_PER_DEG_LAT;

/// Three vehicles queued on N (12.4 / 18.4 / 24.4 m, stationary, heading south).
List<StaticSender> queuedOnN(Bench b, {int from = 0, int? until}) => [
  for (final (i, d) in [(1, 12.4), (2, 18.4), (3, 24.4)])
    b.addSender(StaticSender(id: 100 + i, lat: north(d), lon: CENTER_LON, spd: 0, hdg: 180, tl: 'N', from: from, until: until)),
];

void main() {
  // Fixed timeline with no vehicles: N green 2 s, E 36 s, S 70 s, W 104 s (34 s per lane).
  group('AUTO fixed -> adaptive', () {
    test('a fixed green with no demand ends after the 5.0 s minimum green', () {
      final b = Bench();
      queuedOnN(b, from: 71000); // S green started at 70 s, S has no demand
      b.runUntil(80000);
      expect(b.timeOf('[MODE] auto: vehicle data received (1 connected) -> ADAPTIVE from the next lane decision'), 71000);
      // settled at 72.5 s, but the green is only 2.5 s old then: it ends at 5.0 s
      expect(b.timeOf('[MODE] switching to adaptive: lane S has no demand -> fixed green ended early after 5.0s'), 75000);
      expect(b.timeOf('[SIG ] lane S YELLOW 3.0s (fixed green ended early, no demand)'), 75000);
      expect(b.timeOf('[MODE] effective mode now ADAPTIVE (auto: 3 vehicle(s) sending data -> adaptive)'), 79000);
    });

    test('... and not before AUTO_SETTLE_MS = 1.5 s after the target changed', () {
      final b = Bench();
      queuedOnN(b, from: 80000); // S green is already 10 s old
      b.runUntil(90000);
      expect(b.timeOf('[MODE] switching to adaptive: lane S has no demand -> fixed green ended early after 11.5s'), 81500);
      final plan = b.lines.firstWhere((l) => l.startsWith('[PLAN] adaptive'));
      expect(
        plan,
        '[PLAN] adaptive Qw=[3.0 0.0 0.0 0.0] q=[540 0 0 0]veh/h y=[0.300 0.000 0.000 0.000] Y=0.300 L=16s '
        'C0=41.4s g=[25.4 0.0 0.0 0.0]s',
      );
      expect(b.timeOf('[SIG ] lane N GREEN 25.4s (adaptive Webster: Qw=3.0 y=0.300 HIGH density)'), 85500);
    });

    test('[STAT] says "switching at next lane decision" while the fixed green still runs', () {
      final b = Bench();
      queuedOnN(b, from: 71000);
      b.runUntil(72100);
      final stat = b.lines.where((l) => l.startsWith('[STAT]')).last;
      expect(
        stat,
        startsWith('[STAT] FIXED (auto: 3 vehicle(s) sending data -> adaptive | switching at next lane decision) req=auto | '),
      );
    });

    test('a fixed green WITH demand is not cut; the switch happens at its end', () {
      final b = Bench();
      b.addSender(StaticSender(id: 120, lat: north(-30), lon: CENTER_LON, spd: 0, hdg: 0, tl: 'S', from: 71000));
      b.runUntil(106000);
      expect(b.lines.where((l) => l.contains('ended early')), isEmpty);
      expect(b.timeOf('[SIG ] lane S YELLOW 3.0s (green time over)'), 100000);
      expect(b.timeOf('[MODE] effective mode now ADAPTIVE'), 104000);
    });
  });

  group('AUTO adaptive -> fixed (README case 4)', () {
    test('[LOST] about 3 s after the last packet, [MODE] at 5 s, switch when the running green ends', () {
      final b = Bench();
      queuedOnN(b, from: 71000, until: 120000); // last packets at 119.5 s
      b.runUntil(150000);

      final lost = [
        for (final (t, s) in b.timed)
          if (s.startsWith('[LOST]')) (t, s),
      ];
      expect(lost, hasLength(3));
      for (final (t, s) in lost) {
        expect(t - 119500, inInclusiveRange(3001, 3250), reason: 'timeout 3 s, checked every 250 ms');
        expect(
          s,
          matches(
            RegExp(
              r'^\[LOST\] id=10[123] laptop - no packet for 3\.[0-2]s \(pkts=98 lost=0\) -> removed, [210] vehicle\(s\) left$',
            ),
          ),
        );
      }
      expect(lost.last.$2, endsWith('-> removed, 0 vehicle(s) left'));

      final fixedAt = b.timeOf('[MODE] auto: no vehicle heard for 5s -> FIXED from the next lane decision')!;
      expect(fixedAt - 119500, inInclusiveRange(5000, 5100), reason: 'AUTO_FIXED_AFTER_MS, checked every 100 ms');

      // The running adaptive N green is not cut: it ends normally, then FIXED is latched.
      final seq = [
        for (final (t, s) in b.timed)
          if (t > fixedAt && (s.startsWith('[SIG ]') || s.startsWith('[MODE]'))) s,
      ];
      expect(seq.take(4), [
        '[SIG ] lane N YELLOW 3.0s (green time over)',
        '[SIG ] ALL RED 1.0s',
        '[MODE] effective mode now FIXED (auto: no vehicle heard for 5s -> fixed)',
        '[SIG ] lane E GREEN 30.0s (fixed 30s round-robin: auto, no vehicle connected)',
      ]);
    });

    test('mode_reason while adaptive but silent: "last vehicle heard ...s ago"', () {
      final b = Bench();
      queuedOnN(b, from: 71000, until: 90000);
      b.runUntil(93600); // 4.1 s after the last packet; vehicles already removed
      expect(b.ic.modeReason(), 'auto: last vehicle heard 4.1s ago -> adaptive until 5s of silence');
      expect(b.ic.buildState()['fallback'], false);
    });
  });

  group('manual overrides', () {
    test("'f' while adaptive: logged at once, applied at the next lane decision", () {
      final b = Bench();
      queuedOnN(b, from: 71000);
      b.runUntil(80000); // adaptive N green running since 79 s
      b.ic.command('f', src: 'serial');
      expect(
        b.lines.last,
        "[MODE] requested=fixed (from serial 'f') -> target fixed, effective adaptive now, change applies at the next lane decision",
      );
      expect(b.ic.modeReason(), 'manual: fixed forced | switching at next lane decision');
      b.runUntil(140000);
      expect(b.lines, contains('[MODE] effective mode now FIXED (manual: fixed forced)'));
      expect(b.sig().where((l) => l.contains('fixed 30s round-robin: manual')), isNotEmpty);
      expect(b.ic.buildState()['fallback'], false, reason: 'fallback is only AUTO + fixed');
    });

    test("WebSocket {\"mode\":\"adaptive\"} gives the same line with (from WebSocket)", () {
      final b = Bench();
      b.runUntil(3000);
      expect(b.ic.setReqModeByName('adaptive', 'WebSocket'), isTrue);
      expect(
        b.lines.last,
        '[MODE] requested=adaptive (from WebSocket) -> target adaptive, effective fixed now, change applies at the next lane decision',
      );
      expect(b.ic.setReqModeByName('turbo', 'WebSocket'), isFalse);
    });

    test("'a' with no vehicles: the fixed green ends early (firmware rule), then idle greens of 5 s", () {
      final b = Bench();
      b.runUntil(10000);
      b.ic.command('a', src: 'serial');
      b.runUntil(30000);
      expect(b.timeOf('[MODE] switching to adaptive: lane N has no demand -> fixed green ended early after 9.5s'), 11500);
      expect(b.lines, contains('[MODE] effective mode now ADAPTIVE (manual: adaptive forced)'));
      expect(b.lines, contains('[SIG ] lane E GREEN 5.0s (adaptive: vehicles connected but no demand -> idle green)'));
    });

    test("'o' returns to AUTO; 'r' toggles the [RX] log; 'v' prints the vehicle table", () {
      final b = Bench();
      b.ic.command('f', src: 'serial');
      b.ic.command('o', src: 'serial');
      expect(b.ic.reqMode, ReqMode.auto);
      b.ic.command('r');
      expect(b.lines.last, '[RX  ] per-packet log OFF');
      b.ic.command('v');
      expect(b.lines.reversed.take(3).toList().reversed, [
        '  id  hw        type    lane test state        spd km/h  dist m  RSSI  pkts  lost  age s',
        '(none)',
        '---------------------------------------------------------------------------------------',
      ]);
    });
  });
}

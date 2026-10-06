import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_traffic/hardware/link/simulator.dart';
import 'package:smart_traffic/hardware/model/frame.dart';

class _Run {
  _Run({bool emergencies = false, int seed = 7}) {
    sim = HardwareSimulator(emit: raw.add, random: Random(seed), emergencies: emergencies);
  }

  late final HardwareSimulator sim;
  final raw = <String>[];

  List<HwState> get states => [
        for (final r in raw)
          if (parseFrame(r) case StateFrame(:final state)) state,
      ];
  List<HwEvent> get events => [
        for (final r in raw)
          if (parseFrame(r) case EventFrame(:final event)) event,
      ];
}

void main() {
  test('every simulated frame is a valid protocol v2 frame', () {
    final run = _Run(emergencies: true)..sim.advanceTo(150000);
    for (final r in run.raw) {
      final f = parseFrame(r);
      expect(f is StateFrame || f is EventFrame, isTrue, reason: r);
      expect((jsonDecode(r) as Map)['v'], 2);
    }
  });

  test('lamps follow NS green, yellow 3 s, all-red 2 s, EW green, yellow 3 s, all-red 2 s', () {
    final run = _Run()..sim.advanceTo(300000);
    // Interval starts: the frame sent at each change has elapsed_ms 0.
    final starts = run.states.where((s) => s.timing.elapsedMs == 0).toList();
    expect(starts.length, greaterThan(12));
    const order = [('NS', 'green'), ('NS', 'yellow'), ('NS', 'all_red'), ('EW', 'green'), ('EW', 'yellow'), ('EW', 'all_red')];
    for (var i = 0; i < starts.length; i++) {
      final (phase, interval) = order[i % order.length];
      expect((starts[i].phase, starts[i].interval), (phase, interval), reason: 'interval #$i');
      if (interval == 'yellow') expect(starts[i].timing.remainingMs, 3000);
      if (interval == 'all_red') expect(starts[i].timing.remainingMs, 2000);
    }
    // Signals always match the phase and interval.
    for (final s in run.states) {
      final active = s.phase == 'NS' ? ['N', 'S'] : ['E', 'W'];
      final lamp = switch (s.interval) { 'green' => 'G', 'yellow' => 'Y', _ => 'R' };
      for (final a in ['N', 'S', 'E', 'W']) {
        expect(s.signals[a], active.contains(a) ? lamp : 'R');
      }
    }
  });

  test('adaptive green = clamp(6 + 2 x demand, 10, 60)', () {
    final run = _Run()..sim.advanceTo(300000);
    final greens = run.states.where((s) => s.interval == 'green' && s.timing.elapsedMs == 0).toList();
    expect(greens, isNotEmpty);
    for (final g in greens) {
      final m = RegExp(r'^(NS|EW) demand (\d+) veh -> (\d+) s$').firstMatch(g.timing.reason!)!;
      final demand = int.parse(m.group(2)!);
      expect(g.timing.targetS, (6 + 2 * demand).clamp(10, 60));
      expect(g.timing.remainingMs, g.timing.targetS! * 1000);
    }
  });

  test('state frames every 500 ms and the countdown ends exactly when the lamp changes', () {
    final run = _Run()..sim.advanceTo(200000);
    final states = run.states;
    for (var i = 1; i < states.length; i++) {
      final prev = states[i - 1], cur = states[i];
      expect(cur.uptimeMs! - prev.uptimeMs!, lessThanOrEqualTo(500));
      final prevDeadline = prev.uptimeMs! + prev.timing.remainingMs!;
      if (cur.interval == prev.interval && cur.phase == prev.phase) {
        // Same interval: the deadline does not move.
        expect(cur.uptimeMs! + cur.timing.remainingMs!, prevDeadline);
      } else {
        // The lamp changes exactly when the previous countdown reaches zero, never earlier.
        expect(cur.uptimeMs, prevDeadline);
      }
    }
  });

  test('the mode button switches to the 20 s fixed plan', () {
    final run = _Run()..sim.advanceTo(10000);
    run.sim.pressModeButton();
    expect(run.events.last.event, 'mode_change');
    run.sim.advanceTo(200000);
    final later = run.states.where((s) => s.uptimeMs! > 80000 && s.interval == 'green' && s.timing.elapsedMs == 0);
    expect(later, isNotEmpty);
    for (final g in later) {
      expect(g.mode, 'fixed');
      expect(g.timing.targetS, 20);
      expect(g.plan['NS']!.green, 20);
      expect(g.plan['NS']!.red, 25);
    }
  });

  test('about once a minute an emergency vehicle requests priority', () {
    final run = _Run(emergencies: true, seed: 3)..sim.advanceTo(130000);
    final requests = run.events.where((e) => e.event == 'ev_request').toList();
    expect(requests.length, inInclusiveRange(1, 3));
    expect(EvRequest.parse(requests.first.detail).result, anyOf('granted', 'rejected'));
    final granted = run.events.where((e) => e.event == 'preempt_start');
    if (granted.isNotEmpty) {
      expect(run.states.any((s) => s.preemptActive && s.ctrl == 'preempt' && s.preempt.vehicleId != null), isTrue);
    }
  });

  test('V2I link loss reports fixed-time fallback', () {
    final run = _Run()..sim.advanceTo(5000);
    run.sim.setLinkLost(true);
    expect(run.events.last.event, 'v2i_lost');
    final s = run.states.last;
    expect(s.ctrl, 'fallback');
    expect(s.v2i.link, 'lost');
    expect(s.v2iLost, isTrue);
  });
}

import 'package:test/test.dart';
import 'package:v2i_core/v2i_core.dart';

import 'bench.dart';

double north(double m) => CENTER_LAT + m / M_PER_DEG_LAT;

void queuedOnN(Bench b, {int from = 0}) {
  for (final (i, d) in [(1, 12.4), (2, 18.4), (3, 24.4)]) {
    b.addSender(StaticSender(id: 100 + i, lat: north(d), lon: CENTER_LON, spd: 0, hdg: 180, tl: 'N', from: from));
  }
}

/// Emergency on the W arm, [x] metres east of the centre (negative = west), heading east (inbound).
StaticSender emergencyW(Bench b, {int id = 201, double x = -60, double spd = 30, int from = 0, int? until}) {
  final (lat, lon) = StaticSender.at(x, 0);
  return b.addSender(StaticSender(id: id, ty: 1, lat: lat, lon: lon, spd: spd, hdg: 90, tl: 'W', from: from, until: until));
}

/// Moves an emergency sender through the box and out on the E arm (leaving = IGNORED).
void Function() driveThrough(Bench b, StaticSender e, {required int boxAt, required int outAt}) => () {
  if (b.clock.ms == boxAt) e.move(-3, 0);
  if (b.clock.ms == outAt) e.move(30, 0); // still heading 90: away from the centre on E
};

List<String> after(Bench b, Pattern p) {
  final i = b.lines.indexWhere((l) => l.contains(p));
  return i < 0 ? [] : b.lines.sublist(i);
}

List<String> prioAndSig(Iterable<String> lines) => [
  for (final l in lines)
    if (l.startsWith('[PRIO]') || l.startsWith('[SIG ]')) l,
];

void main() {
  group('README case 3 with the firmware presets 1-5 (motion simulation)', () {
    late Bench b;
    setUpAll(() {
      b = Bench();
      b.runUntil(5000); // vehicles powered after N GREEN (README run order)
      for (var i = 0; i < 5; i++) {
        b.addVehicle(PRESETS[i], seed: i + 1);
      }
      b.run(115000);
    });

    test('preempt -> yellow 3 s + all-red 1 s -> W priority green 4.0 s after the request', () {
      final seq = prioAndSig(after(b, '[PRIO] emergency id=201 detected'));
      expect(seq[0], matches(RegExp(r'^\[PRIO\] emergency id=201 detected on lane W d=\d+m APPROACHING -> priority requested$')));
      expect(
        seq[1],
        matches(RegExp(r'^\[PRIO\] emergency id=201 on lane W -> ending lane [NES] green now \(yellow 3s \+ all-red 1s\)$')),
      );
      expect(seq[2], matches(RegExp(r'^\[SIG \] lane [NES] YELLOW 3\.0s \(preempted by emergency vehicle\)$')));
      expect(seq[3], '[SIG ] ALL RED 1.0s');
      expect(
        seq[4],
        matches(RegExp(r'^\[SIG \] lane W GREEN 5\.0s \(EMERGENCY PRIORITY id=201 d=\d+m, hold until crossed, max 25s\)$')),
      );
      expect(seq[5], '[PRIO] lane W GREEN for emergency id=201, 4.0 s after its request');
      expect(seq[6], matches(RegExp(r'^\[PRIO\] emergency id=201 has crossed -> ending priority green on W after \d+\.\ds$')));
      expect(seq[7], '[PRIO] lane W waits one normal turn before it can get priority again');
      expect(seq[8], '[SIG ] lane W YELLOW 3.0s (emergency vehicle has crossed)');

      final tReq = b.timeOf('[PRIO] emergency id=201 detected')!;
      expect(b.timeOf('[SIG ] lane W GREEN 5.0s (EMERGENCY'), tReq + 4000);
    });

    test('the vehicle measures detection -> green too (0.5 s beacon granularity)', () {
      final v = b.vehicles[4];
      expect(
        v.log.lines.map((l) => l.text),
        contains(
          matches(RegExp(r'^\[PRIO\] GREEN on lane W, \d+\.\d s after the intersection first assigned this vehicle a lane$')),
        ),
      );
      final first = v.log.lines.firstWhere((l) => l.text.startsWith('[PRIO] GREEN')).text;
      final s = double.parse(RegExp(r', (\d+\.\d) s').firstMatch(first)!.group(1)!);
      expect(s, inInclusiveRange(4.0, 4.5));
    });

    test('a priority green lasts at least 5 s and every "crossed" comes after it', () {
      final greens = [
        for (final (t, s) in b.timed)
          if (s.startsWith('[SIG ] lane W GREEN 5.0s (EMERGENCY')) t,
      ];
      final crossed = [
        for (final (t, s) in b.timed)
          if (s.contains('has crossed -> ending priority green')) t,
      ];
      expect(greens.length, crossed.length);
      expect(greens, hasLength(greaterThanOrEqualTo(2)));
      for (var i = 0; i < greens.length; i++) {
        expect(crossed[i] - greens[i], greaterThanOrEqualTo(PRIO_MIN_GREEN_MS));
      }
    });

    test('a request during the one-normal-turn cooldown waits for that turn (README: "longer")', () {
      final cooldownEnd = b.timeOf('[PRIO] lane W has waited one normal turn -> may get priority again')!;
      final reqs = [
        for (final (t, s) in b.timed)
          if (s.startsWith('[PRIO] emergency id=201 detected')) t,
      ];
      final second = reqs[1];
      expect(second, lessThan(cooldownEnd), reason: 'the 2nd trip arrives while W still waits its normal turn');
      final green = [
        for (final (t, s) in b.timed)
          if (t > second && s.startsWith('[PRIO] lane W GREEN for emergency')) (t, s),
      ].first;
      expect(green.$1, cooldownEnd + 4000);
      final delay = double.parse(RegExp(r', (\d+\.\d) s after').firstMatch(green.$2)!.group(1)!);
      expect(delay, greaterThan(4.0));
    });
  });

  group('priority rules (hand-made packets)', () {
    test('resume: the lane cut short by priority is served next (adaptive)', () {
      final b = Bench();
      queuedOnN(b, from: 3000); // N (fixed green 2..32 s) has demand: no early end
      final e = emergencyW(b, from: 10000);
      b.run(40000, each: driveThrough(b, e, boxAt: 15000, outAt: 16000));

      expect(prioAndSig(after(b, '[PRIO] emergency id=201 detected')), [
        '[PRIO] emergency id=201 detected on lane W d=60m APPROACHING -> priority requested',
        '[PRIO] emergency id=201 on lane W -> ending lane N green now (yellow 3s + all-red 1s)',
        '[SIG ] lane N YELLOW 3.0s (preempted by emergency vehicle)',
        '[SIG ] ALL RED 1.0s',
        '[SIG ] lane W GREEN 5.0s (EMERGENCY PRIORITY id=201 d=60m, hold until crossed, max 25s)',
        '[PRIO] lane W GREEN for emergency id=201, 4.0 s after its request',
        // crossed at 16 s, but the priority green lasts at least 5 s
        '[PRIO] emergency id=201 has crossed -> ending priority green on W after 5.0s',
        '[PRIO] lane W waits one normal turn before it can get priority again',
        '[SIG ] lane W YELLOW 3.0s (emergency vehicle has crossed)',
        '[SIG ] ALL RED 1.0s',
        '[SIG ] lane N GREEN 25.4s (adaptive Webster: Qw=3.0 y=0.300 HIGH density, resumes lane cut by priority)',
      ]);
      expect(b.timeOf('[PRIO] emergency id=201 has crossed'), 19000);
      expect(b.timeOf('resumes lane cut by priority'), 23000);
    });

    test('resume in manual fixed mode', () {
      final b = Bench();
      b.ic.command('f', src: 'serial');
      final e = emergencyW(b, from: 10000);
      b.run(25000, each: driveThrough(b, e, boxAt: 15000, outAt: 16000));
      expect(b.lines, contains('[SIG ] lane N GREEN 30.0s (fixed 30s round-robin: manual, resumes lane cut by priority)'));
      b.runUntil(60000);
      expect(b.sig().where((l) => l.contains(' GREEN ')).last, '[SIG ] lane E GREEN 30.0s (fixed 30s round-robin: manual)');
    });

    test('max hold: priority green ends 25 s after it started if the vehicle never clears', () {
      final b = Bench();
      emergencyW(b, x: -20, spd: 0, from: 10000); // queued on W, stays
      b.runUntil(45000);
      expect(b.timeOf('[SIG ] lane W GREEN 5.0s (EMERGENCY PRIORITY id=201 d=20m'), 14000);
      expect(prioAndSig(after(b, '[PRIO] max hold')).take(3), [
        '[PRIO] max hold 25s reached on lane W -> ending priority green',
        '[PRIO] lane W waits one normal turn before it can get priority again',
        '[SIG ] lane W YELLOW 3.0s (priority max hold reached)',
      ]);
      expect(b.timeOf('[PRIO] max hold 25s reached'), 39000);
      expect(b.ic.cooldown[3], isTrue);
    });

    test('emergency on the lane that is already green: hold, max 25 s from the request (firmware rule)', () {
      final b = Bench();
      emergencyW(b, x: -20, spd: 0, from: 110000); // W fixed green 104..134 s
      b.runUntil(140000);
      expect(
        b.timeOf('[PRIO] emergency id=201 on lane W which is already green -> holding green until it crosses (max 25s)'),
        110000,
      );
      expect(b.lines.where((l) => l.startsWith('[PRIO] lane W GREEN for emergency')), isEmpty);
      // the normal end (134 s) is passed; the hold ends 25 s after the request, so this W green lasted 31 s
      expect(b.timeOf('[PRIO] max hold 25s reached on lane W'), 135000);
    });

    test('already green, vehicle leaves early: the green still runs to its planned end', () {
      final b = Bench();
      final e = emergencyW(b, x: -20, spd: 0, from: 110000);
      b.runUntil(
        140000,
        each: () {
          if (b.clock.ms == 112000) e.move(30, 0);
        },
      );
      expect(b.timeOf('[PRIO] emergency id=201 has crossed -> ending priority green on W after 24.0s'), 134000);
    });

    test('two emergencies (W, then S) and N queued: one normal turn before W or S gets priority again', () {
      final b = Bench();
      queuedOnN(b, from: 3000);
      emergencyW(b, x: -20, spd: 0, from: 10000); // queued on W, stays
      final (sLat, sLon) = StaticSender.at(0, -50);
      b.addSender(
        StaticSender(id: 202, ty: 1, lat: sLat, lon: sLon, spd: 30, hdg: 0, tl: 'S', from: 12000),
      ); // approaching S, stays
      b.runUntil(140000);

      final seq = prioAndSig(after(b, '[PRIO] emergency id=201 detected'))
          .where((l) => !l.startsWith('[SIG ] ALL RED') && !l.contains('YELLOW'))
          .take(12)
          .toList();
      expect(seq, [
        '[PRIO] emergency id=201 detected on lane W d=20m QUEUED -> priority requested',
        '[PRIO] emergency id=201 on lane W -> ending lane N green now (yellow 3s + all-red 1s)',
        '[PRIO] emergency id=202 detected on lane S d=50m APPROACHING -> priority requested',
        '[SIG ] lane W GREEN 5.0s (EMERGENCY PRIORITY id=201 d=20m, hold until crossed, max 25s)',
        '[PRIO] lane W GREEN for emergency id=201, 4.0 s after its request',
        '[PRIO] max hold 25s reached on lane W -> ending priority green',
        '[PRIO] lane W waits one normal turn before it can get priority again',
        // W is cooling down, so the S request is served next (it waited for W's whole priority green)
        '[SIG ] lane S GREEN 5.0s (EMERGENCY PRIORITY id=202 d=50m, hold until crossed, max 25s)',
        '[PRIO] lane S GREEN for emergency id=202, 31.0 s after its request',
        '[PRIO] max hold 25s reached on lane S -> ending priority green',
        '[PRIO] lane S waits one normal turn before it can get priority again',
        // both lanes cool down: the normal lane cut at 10 s is served
        '[SIG ] lane N GREEN 24.5s (adaptive Webster: Qw=3.0 y=0.300 HIGH density, resumes lane cut by priority)',
      ]);
      // emergency vehicles count in Qw too: W queued (1.0), S approaching (K = 0.5)
      expect(
        b.lines.lastWhere(
          (l) => l.startsWith('[PLAN] adaptive') && b.lines.indexOf(l) < b.lines.indexWhere((x) => x.contains('resumes lane')),
        ),
        '[PLAN] adaptive Qw=[3.0 0.0 0.5 1.0] q=[540 0 90 180]veh/h y=[0.300 0.000 0.050 0.100] Y=0.450 L=16s C0=52.7s g=[24.5 0.0 5.0 8.2]s',
      );
      final next = prioAndSig(after(b, 'resumes lane cut by priority')).skip(1).take(5).toList();
      expect(next, [
        '[PRIO] lane S has waited one normal turn -> may get priority again',
        '[PRIO] lane W has waited one normal turn -> may get priority again',
        '[SIG ] lane N YELLOW 3.0s (green time over)',
        '[SIG ] ALL RED 1.0s',
        '[SIG ] lane W GREEN 5.0s (EMERGENCY PRIORITY id=201 d=20m, hold until crossed, max 25s)', // nearest wins
      ]);
    });

    test('emergency_lane / priority_active in the state JSON', () {
      final b = Bench();
      emergencyW(b, x: -20, spd: 0, from: 10000);
      b.runUntil(10001);
      var s = b.ic.buildState();
      expect(s['emergency_lane'], 'W', reason: 'candidate waiting');
      expect(s['priority_active'], false);
      b.runUntil(15000);
      s = b.ic.buildState();
      expect(s['emergency_lane'], 'W');
      expect(s['priority_active'], true);
      expect((s['timing'] as Map)['priority'], true);
    });

    test('ACK pri=1 only while the emergency vehicle is active on a lane', () {
      final b = Bench();
      final e = emergencyW(b, x: -60, from: 3000);
      b.runUntil(3001);
      expect(e.lastAck, contains('"lane":"W"'));
      expect(e.lastAck, endsWith('"pri":1}'));
      e.move(30, 0); // leaving on E: IGNORED
      b.runUntil(3600);
      expect(e.lastAck, endsWith('"lane":"-","st":"IGNORED","sig":"-","rem":0,"pri":0}'));
    });
  });
}

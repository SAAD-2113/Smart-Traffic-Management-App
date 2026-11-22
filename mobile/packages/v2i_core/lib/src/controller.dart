import 'dart:math' as math;

import 'classify.dart';
import 'clock.dart';
import 'cnum.dart';
import 'config.dart';
import 'geometry.dart';
import 'log.dart';
import 'packets.dart';

// Port of docs/firmware-v3/intersection_esp32/intersection_esp32.ino.
// Same state, same order of operations, same log lines. Only the I/O is different:
//   UDP / HTTP POST      -> processPacket(json) returns the ACK text
//   loop()               -> tick(), called often (the app: about every 10 ms)
//   setup()              -> start()
//   Serial commands      -> command('f' | 'a' | 'o' | 'v' | 'r' | 'p' | 'h')
//   buildState()         -> buildState() (Map, same keys and order, "v":2 first)
//   TM1637 MM:SS         -> laneDisplay(lane)
// Values the firmware keeps in `float` are rounded to float32 (f32) at the same places.

enum ReqMode { auto, fixed, adaptive } // what was asked for

enum Mode { fixed, adaptive } // what the signals do

enum Phase { green, yellow, allRed }

enum Density { low, medium, high }

class Veh {
  bool used = false;
  int id = 0;
  int type = VT_NORMAL;
  int lane = -1, tl = -1;
  V2IState st = V2IState.ignored;
  V2IReason reason = V2IReason.ok;
  double spd = 0, hdg = -1, dist = 0, bearing = 0; // float
  double lat = 0, lon = 0; // double
  int rssi = 0;
  bool hasRssi = false;
  int lastSeen = 0, pkts = 0, lost = 0, lastSeq = 0;
  int lastMismatchLog = 0;
  bool prioLogged = false;
  int prioSince = 0; // when this emergency vehicle first requested priority
  String hw = '';

  /// Digital twin only (not in the firmware): last packet -> ACK round trip the vehicle
  /// reported through the transport, in ms.
  int? rttMs;
}

class LaneStat {
  int queued = 0, approach = 0, crossing = 0, emerg = 0;
  double qw = 0; // float
  Density dens = Density.low;
}

/// Webster result.
class Plan {
  double L = 0, Y = 0, C = 0;
  final q = List<double>.filled(NUM_LANES, 0);
  final y = List<double>.filled(NUM_LANES, 0);
  final g = List<double>.filled(NUM_LANES, 0); // green seconds per lane (0 = skipped)
  bool anyDemand = false;
}

String modeName(Mode m) => m == Mode.fixed ? 'fixed' : 'adaptive';
String reqModeName(ReqMode m) => m == ReqMode.auto ? 'auto' : (m == ReqMode.fixed ? 'fixed' : 'adaptive');
String densName(Density d) => d == Density.high ? 'HIGH' : (d == Density.medium ? 'MEDIUM' : 'LOW');

double _r1(double x) => f32(croundf(f32(x * 10.0)) / 10.0);
double _r2(double x) => f32(croundf(f32(x * 100.0)) / 100.0);
double _constrain(double x, double lo, double hi) => x < lo ? lo : (x > hi ? hi : x);

/// `snprintf(buf, size, ...)` truncation.
String _buf(String s, int size) => strlcpy(s, size);

class IntersectionController {
  IntersectionController({
    required this.clock,
    this.geometry = const Geometry(),
    this.intersectionName = 'STMS-RSU',
    this.controllerName = DIGITAL_CONTROLLER_NAME,
    DateTime Function()? wallClock,
    V2ILog? log,
  }) : _wall = wallClock,
       log = log ?? V2ILog();

  final MonoClock clock;
  final Geometry geometry;
  final String intersectionName;
  final String controllerName;
  final DateTime Function()? _wall;
  final V2ILog log;

  /// Called with the state JSON every WS_PERIOD_MS (the firmware's broadcastAppState()).
  void Function(Map<String, Object?> state)? onBroadcast;

  // ---------------------------------------------------------------- state
  final vehs = List<Veh>.generate(MAX_VEH, (_) => Veh());
  final ls = List<LaneStat>.generate(NUM_LANES, (_) => LaneStat());
  Plan decisionPlan = Plan(); // plan used for the current green (printed at each decision)
  Plan previewPlan = Plan(); // recomputed every second, used for red-time estimates
  int totQueued = 0, totApproach = 0;
  Density overallDens = Density.low;

  ReqMode reqMode = ReqMode.auto;
  Mode effMode = Mode.fixed; // latched at each lane decision
  Mode lastTarget = Mode.fixed;
  int targetSince = 0; // when targetMode() last changed
  bool everRx = false;
  int lastAnyRxMs = 0;

  Phase phase = Phase.allRed;
  int curLane = -1;
  int rrLane = NUM_LANES - 1; // last NORMAL green (rotation pointer) -> first green is N
  int resumeLane = -1; // normal lane cut short by a priority request
  bool prioGreen = false; // current green is an emergency-priority green
  int prioVehId = 0;
  int prioStartMs = 0;
  final cooldown = List<bool>.filled(NUM_LANES, false); // had priority -> waits one normal turn
  int phaseStart = 0, phaseDur = ALL_RED_MS;
  int pktRx = 0, pktBad = 0;
  bool logRx = LOG_RX_DEFAULT;

  int _tDens = 0, _tExpire = 0, _tStat = 0, _tWs = 0;
  bool _started = false;

  int millis() => clock.nowMs();

  void _print(String line) => log.add(LogLine(millis(), line, wall: _wall?.call()));

  // ---------------------------------------------------------------- helpers
  String phaseName() => phase == Phase.green ? 'GREEN' : (phase == Phase.yellow ? 'YELLOW' : 'ALL_RED');

  int connectedVehicles() => vehs.where((v) => v.used).length;
  bool heardRecently() => everRx && millis() - lastAnyRxMs < AUTO_FIXED_AFTER_MS;

  /// Mode the controller WANTS now (applied at the next lane decision).
  Mode targetMode() {
    if (reqMode == ReqMode.fixed) return Mode.fixed;
    if (reqMode == ReqMode.adaptive) return Mode.adaptive;
    return heardRecently() ? Mode.adaptive : Mode.fixed;
  }

  /// Human-readable reason for the effective / target mode.
  String modeReason([int size = 112]) {
    final t = targetMode();
    final pend = t != effMode ? ' | switching at next lane decision' : '';
    final String s;
    if (reqMode == ReqMode.fixed) {
      s = 'manual: fixed forced$pend';
    } else if (reqMode == ReqMode.adaptive) {
      s = 'manual: adaptive forced$pend';
    } else if (t == Mode.adaptive && connectedVehicles() > 0) {
      s = 'auto: ${connectedVehicles()} vehicle(s) sending data -> adaptive$pend';
    } else if (t == Mode.adaptive) {
      s =
          'auto: last vehicle heard ${cfix(f32((millis() - lastAnyRxMs) / 1000.0), 1)}s ago -> adaptive until '
          '${AUTO_FIXED_AFTER_MS ~/ 1000}s of silence$pend';
    } else if (!everRx) {
      s = 'auto: no vehicle connected -> fixed$pend';
    } else {
      s = 'auto: no vehicle heard for ${AUTO_FIXED_AFTER_MS ~/ 1000}s -> fixed$pend';
    }
    return _buf(s, size);
  }

  String sigOf(int lane) {
    if (lane != curLane) return 'R';
    return phase == Phase.green ? 'G' : (phase == Phase.yellow ? 'Y' : 'R');
  }

  double phaseRemS() {
    final el = millis() - phaseStart;
    return el >= phaseDur ? 0.0 : f32(f32((phaseDur - el).toDouble()) / 1000.0);
  }

  // ---------------------------------------------------------------- vehicle table + density
  Veh? findVeh(int id) {
    for (final v in vehs) {
      if (v.used && v.id == id) return v;
    }
    return null;
  }

  Veh? allocVeh() {
    for (final v in vehs) {
      if (!v.used) return v;
    }
    return null;
  }

  bool isActive(Veh v) => v.used && v.lane >= 0 && v.st != V2IState.ignored;

  Density laneLevel(LaneStat s) {
    if (s.queued >= LANE_HIGH_QUEUED || s.approach >= LANE_HIGH_APPROACH) return Density.high;
    if (s.queued >= LANE_MED_QUEUED || s.approach >= LANE_MED_APPROACH) return Density.medium;
    return Density.low;
  }

  void densityCheck() {
    for (final s in ls) {
      s
        ..queued = 0
        ..approach = 0
        ..crossing = 0
        ..emerg = 0
        ..qw = 0
        ..dens = Density.low;
    }
    for (final v in vehs) {
      if (!isActive(v)) continue;
      final s = ls[v.lane];
      if (v.st == V2IState.queued) s.queued++;
      if (v.st == V2IState.approaching) s.approach++;
      if (v.st == V2IState.crossing) s.crossing++;
      if (v.type == VT_EMERGENCY) s.emerg++;
    }
    totQueued = totApproach = 0;
    for (var l = 0; l < NUM_LANES; l++) {
      ls[l].qw = f32(ls[l].queued + f32(K_APPROACH * ls[l].approach)); // weighted queue
      ls[l].dens = laneLevel(ls[l]);
      totQueued += ls[l].queued;
      totApproach += ls[l].approach;
    }
    overallDens = (totQueued >= ALL_HIGH_QUEUED || totApproach >= ALL_HIGH_APPROACH)
        ? Density.high
        : (totQueued >= ALL_MED_QUEUED || totApproach >= ALL_MED_APPROACH)
        ? Density.medium
        : Density.low;
  }

  bool laneHasDemand(int l) => l >= 0 && (ls[l].qw > 0.0 || ls[l].emerg > 0);

  void expireVehicles() {
    final now = millis();
    for (final v in vehs) {
      if (v.used && now - v.lastSeen > VEHICLE_TIMEOUT_MS) {
        _print(
          '[LOST] id=${v.id} ${v.hw} - no packet for ${cfix(f32((now - v.lastSeen) / 1000.0), 1)}s '
          '(pkts=${v.pkts} lost=${v.lost}) -> removed, ${connectedVehicles() - 1} vehicle(s) left',
        );
        v.used = false;
      }
    }
  }

  // ---------------------------------------------------------------- emergency helpers
  /// Nearest emergency vehicle that should get priority (APPROACHING or QUEUED, not on the
  /// lane that is cooling down after its own priority green).
  Veh? priorityCandidate() {
    Veh? best;
    for (final v in vehs) {
      if (!isActive(v) || v.type != VT_EMERGENCY) continue;
      if (v.st != V2IState.approaching && v.st != V2IState.queued) continue;
      if (cooldown[v.lane]) continue;
      if (best == null || v.dist < best.dist) best = v;
    }
    return best;
  }

  /// Any emergency vehicle still on (or crossing from) [lane].
  bool emergencyOnLane(int lane) => vehs.any((v) => isActive(v) && v.type == VT_EMERGENCY && v.lane == lane);

  int emergencyLaneForState() {
    if (prioGreen && phase == Phase.green) return curLane;
    final c = priorityCandidate();
    return c?.lane ?? -1;
  }

  // ---------------------------------------------------------------- Webster
  //    q_i = Qw_i * 3600 / OBS_WINDOW_S      y_i = q_i / s
  //    Y   = sum(y_i), capped at Y_MAX       L   = 4 * (yellow + all-red)
  //    C0  = (1.5 L + 5) / (1 - Y)  in [C_MIN, C_MAX]
  //    g_i = (y_i / Y) * (C0 - L)   in [G_MIN, G_MAX];  no demand -> skipped
  Plan computePlan() {
    final p = Plan();
    p.L = f32(NUM_LANES * (YELLOW_MS + ALL_RED_MS) / 1000.0);
    p.Y = 0;
    p.anyDemand = false;
    for (var l = 0; l < NUM_LANES; l++) {
      p.q[l] = f32(f32(ls[l].qw * 3600.0) / OBS_WINDOW_S);
      p.y[l] = f32(p.q[l] / SAT_FLOW_VPH);
      p.Y = f32(p.Y + p.y[l]);
    }
    if (p.Y > f32(Y_MAX)) {
      // keep (1 - Y) positive; ratios y_i / Y unchanged
      final f = f32(f32(Y_MAX) / p.Y);
      for (var l = 0; l < NUM_LANES; l++) {
        p.y[l] = f32(p.y[l] * f);
      }
      p.Y = f32(Y_MAX);
    }
    p.C = _constrain(f32(f32(f32(1.5 * p.L) + 5.0) / f32(1.0 - p.Y)), C_MIN_S, C_MAX_S);
    final gTot = f32(p.C - p.L);
    for (var l = 0; l < NUM_LANES; l++) {
      if (p.y[l] <= 0.0 || p.Y <= 0.0) {
        p.g[l] = 0.0;
        continue;
      }
      p.anyDemand = true;
      p.g[l] = _constrain(f32(f32(p.y[l] / p.Y) * gTot), G_MIN_MS / 1000.0, G_MAX_MS / 1000.0);
    }
    return p;
  }

  String planLine(Plan p, String tag) {
    String f(int d, List<double> xs) => xs.map((x) => cfix(x, d)).join(' ');
    return '[PLAN] $tag Qw=[${f(1, [for (final s in ls) s.qw])}] q=[${f(0, p.q)}]veh/h y=[${f(3, p.y)}] '
        'Y=${cfix(p.Y, 3)} L=${cfix(p.L, 0)}s C0=${cfix(p.C, 1)}s g=[${f(1, p.g)}]s';
  }

  void printPlan(Plan p, String tag) => _print(planLine(p, tag));

  /// Green a lane would get on its next normal turn (0 = skipped).
  double plannedGreenS(int lane) {
    if (effMode == Mode.fixed) return FIXED_GREEN_MS / 1000.0;
    if (!previewPlan.anyDemand) return IDLE_GREEN_MS / 1000.0;
    return previewPlan.g[lane];
  }

  /// Remaining time of the current green, including a priority hold.
  double greenRemS() {
    if (phase != Phase.green) return 0;
    var r = phaseRemS();
    if (prioGreen && emergencyOnLane(curLane)) {
      final held = millis() - prioStartMs;
      final hold = held >= EMERG_HOLD_MAX_MS ? 0.0 : f32((EMERG_HOLD_MAX_MS - held) / 1000.0);
      if (hold > r) r = hold; // worst case: until the max hold
    }
    return r;
  }

  /// Estimated seconds until [lane] turns green (ACK, dashboard, displays).
  double etaGreenS(int lane) {
    final clr = f32((YELLOW_MS + ALL_RED_MS) / 1000.0);
    if (curLane < 0) return phaseRemS();
    if (lane == curLane && phase == Phase.green) return 0;
    double t;
    if (phase == Phase.green) {
      t = f32(greenRemS() + clr);
    } else if (phase == Phase.yellow) {
      t = f32(phaseRemS() + ALL_RED_MS / 1000.0);
    } else {
      t = phaseRemS();
    }
    final from = rrLane; // rotation continues after the last normal green
    for (var j = 1; j <= NUM_LANES; j++) {
      final l = (from + j) % NUM_LANES;
      if (l == lane) return t;
      final g = plannedGreenS(l);
      if (g > 0) t = f32(t + f32(g + clr));
    }
    return t;
  }

  double laneRemS(int lane) {
    final s = sigOf(lane);
    if (s == 'G') return greenRemS();
    if (s == 'Y') return phaseRemS();
    return etaGreenS(lane);
  }

  // ---------------------------------------------------------------- signal state machine
  void startGreen(int lane, int dur, String why) {
    curLane = lane;
    phase = Phase.green;
    phaseStart = millis();
    phaseDur = dur;
    _print('[SIG ] lane ${LANE_NAME[lane]} GREEN ${cfix(f32(dur / 1000.0), 1)}s ($why)');
  }

  void startYellow(String why, {bool normalEnd = true}) {
    if (normalEnd && !prioGreen) {
      // a normal green ran to its end
      for (var l = 0; l < NUM_LANES; l++) {
        if (cooldown[l]) {
          _print('[PRIO] lane ${LANE_NAME[l]} has waited one normal turn -> may get priority again');
          cooldown[l] = false;
        }
      }
    }
    if (prioGreen) {
      cooldown[curLane] = true; // this lane waits one normal turn
      prioGreen = false;
      _print('[PRIO] lane ${LANE_NAME[curLane]} waits one normal turn before it can get priority again');
    }
    phase = Phase.yellow;
    phaseStart = millis();
    phaseDur = YELLOW_MS;
    _print('[SIG ] lane ${LANE_NAME[curLane]} YELLOW ${cfix(YELLOW_MS / 1000.0, 1)}s ($why)');
  }

  void startAllRed() {
    phase = Phase.allRed;
    phaseStart = millis();
    phaseDur = ALL_RED_MS;
    _print('[SIG ] ALL RED ${cfix(ALL_RED_MS / 1000.0, 1)}s');
  }

  void startPriorityGreen(Veh e) {
    final why = _buf(
      'EMERGENCY PRIORITY id=${e.id} d=${cfix(e.dist, 0)}m, hold until crossed, max ${EMERG_HOLD_MAX_MS ~/ 1000}s',
      96,
    );
    prioGreen = true;
    prioVehId = e.id;
    prioStartMs = millis();
    startGreen(e.lane, PRIO_MIN_GREEN_MS, why);
    _print(
      '[PRIO] lane ${LANE_NAME[e.lane]} GREEN for emergency id=${e.id}, '
      '${cfix(f32((millis() - e.prioSince) / 1000.0), 1)} s after its request',
    );
  }

  void chooseNextLane() {
    densityCheck();

    // 1) latch the mode at the lane decision
    final t = targetMode();
    if (t != effMode) {
      effMode = t;
      final why = modeReason(96);
      _print('[MODE] effective mode now ${effMode == Mode.fixed ? 'FIXED' : 'ADAPTIVE'} ($why)');
    }

    // 2) emergency priority, every mode
    final e = priorityCandidate();
    if (e != null) {
      startPriorityGreen(e);
      return;
    }

    // 3) lane cut short by a priority green is served first
    var forced = -1;
    if (RESUME_PREEMPTED_LANE && resumeLane >= 0) {
      if (effMode == Mode.fixed || laneHasDemand(resumeLane)) forced = resumeLane;
      resumeLane = -1;
    }

    if (effMode == Mode.fixed) {
      final l = forced >= 0 ? forced : (rrLane + 1) % NUM_LANES;
      rrLane = l;
      var why = reqMode == ReqMode.fixed ? 'fixed 30s round-robin: manual' : 'fixed 30s round-robin: auto, no vehicle connected';
      if (forced >= 0) why = _buf('$why, resumes lane cut by priority', 96);
      startGreen(l, FIXED_GREEN_MS, why);
      return;
    }

    // ADAPTIVE (Webster), recomputed at every lane decision
    decisionPlan = computePlan();
    previewPlan = decisionPlan;
    printPlan(decisionPlan, 'adaptive');
    if (!decisionPlan.anyDemand) {
      final l = (rrLane + 1) % NUM_LANES;
      rrLane = l;
      startGreen(l, IDLE_GREEN_MS, 'adaptive: vehicles connected but no demand -> idle green');
      return;
    }
    var pick = -1;
    if (forced >= 0 && decisionPlan.g[forced] > 0) pick = forced;
    for (var k = 1; pick < 0 && k <= NUM_LANES; k++) {
      final l = (rrLane + k) % NUM_LANES;
      if (decisionPlan.g[l] > 0.0) pick = l;
    }
    rrLane = pick;
    final why = _buf(
      'adaptive Webster: Qw=${cfix(ls[pick].qw, 1)} y=${cfix(decisionPlan.y[pick], 3)} ${densName(ls[pick].dens)} density'
      '${pick == forced ? ', resumes lane cut by priority' : ''}',
      96,
    );
    startGreen(pick, (decisionPlan.g[pick] * 1000.0 + 0.5).truncate(), why);
  }

  void signalTick() {
    final now = millis();
    final el = now - phaseStart;
    switch (phase) {
      case Phase.green:
        // a) running priority green: hold until the emergency vehicle has crossed
        if (prioGreen) {
          final held = now - prioStartMs;
          if (held >= EMERG_HOLD_MAX_MS) {
            _print(
              '[PRIO] max hold ${EMERG_HOLD_MAX_MS ~/ 1000}s reached on lane ${LANE_NAME[curLane]} -> ending priority green',
            );
            startYellow('priority max hold reached');
          } else if (el >= phaseDur && !emergencyOnLane(curLane)) {
            _print(
              '[PRIO] emergency id=$prioVehId has crossed -> ending priority green on ${LANE_NAME[curLane]} '
              'after ${cfix(f32(held / 1000.0), 1)}s',
            );
            startYellow('emergency vehicle has crossed');
          }
          break;
        }
        // b) new emergency request
        final e = priorityCandidate();
        if (e != null && e.lane == curLane) {
          // already green: turn it into a priority hold
          prioGreen = true;
          prioVehId = e.id;
          prioStartMs = now;
          _print(
            '[PRIO] emergency id=${e.id} on lane ${LANE_NAME[curLane]} which is already green -> holding green '
            'until it crosses (max ${EMERG_HOLD_MAX_MS ~/ 1000}s)',
          );
          break;
        }
        if (e != null && el >= PREEMPT_MIN_GREEN_MS) {
          _print(
            '[PRIO] emergency id=${e.id} on lane ${LANE_NAME[e.lane]} -> ending lane ${LANE_NAME[curLane]} green now '
            '(yellow ${YELLOW_MS ~/ 1000}s + all-red ${ALL_RED_MS ~/ 1000}s)',
          );
          resumeLane = curLane;
          startYellow('preempted by emergency vehicle', normalEnd: false);
          break;
        }
        // c) AUTO fixed -> adaptive: end a fixed green that has no demand (after min green)
        if (EARLY_END_FIXED_GREEN &&
            effMode == Mode.fixed &&
            targetMode() == Mode.adaptive &&
            now - targetSince >= AUTO_SETTLE_MS &&
            el >= G_MIN_MS &&
            !laneHasDemand(curLane)) {
          _print(
            '[MODE] switching to adaptive: lane ${LANE_NAME[curLane]} has no demand -> fixed green ended early '
            'after ${cfix(f32(el / 1000.0), 1)}s',
          );
          startYellow('fixed green ended early, no demand');
          break;
        }
        // d) normal end of green
        if (el >= phaseDur) startYellow('green time over');
      case Phase.yellow:
        if (el >= YELLOW_MS) startAllRed(); // never cut short
      case Phase.allRed:
        if (el >= ALL_RED_MS) chooseNextLane(); // never cut short
    }
  }

  /// Detects automatic mode changes (logged once, applied at the next lane decision).
  void modeWatch() {
    final t = targetMode();
    if (t == lastTarget) return;
    lastTarget = t;
    targetSince = millis();
    if (reqMode != ReqMode.auto) return; // manual changes are logged by setReqMode()
    if (t == Mode.adaptive) {
      _print('[MODE] auto: vehicle data received (${connectedVehicles()} connected) -> ADAPTIVE from the next lane decision');
    } else {
      _print('[MODE] auto: no vehicle heard for ${AUTO_FIXED_AFTER_MS ~/ 1000}s -> FIXED from the next lane decision');
    }
  }

  void setReqMode(ReqMode m, String src) {
    reqMode = m;
    lastTarget = targetMode();
    targetSince = millis();
    _print(
      '[MODE] requested=${reqModeName(m)} (from $src) -> target ${modeName(lastTarget)}, effective '
      '${modeName(effMode)} now, change applies at the next lane decision',
    );
  }

  bool setReqModeByName(String s, String src) {
    if (s == 'auto' || s == 'o') {
      setReqMode(ReqMode.auto, src);
      return true;
    }
    if (s == 'fixed' || s == 'f') {
      setReqMode(ReqMode.fixed, src);
      return true;
    }
    if (s == 'adaptive' || s == 'a') {
      setReqMode(ReqMode.adaptive, src);
      return true;
    }
    return false;
  }

  // ---------------------------------------------------------------- MM:SS displays
  /// What a lane's TM1637 shows: time left in its CURRENT colour, "MM:SS".
  String laneDisplay(int lane) {
    var remaining = laneRemS(lane);
    if (remaining < 0) remaining = 0;
    var total = f32(remaining - 0.001).ceil(); // 30 at the start, then 29 ... 00
    if (total < 0) total = 0;
    if (total > 5999) total = 5999;
    final mm = total ~/ 60, ss = total % 60;
    return '${mm.toString().padLeft(2, '0')}:${ss.toString().padLeft(2, '0')}';
  }

  // ---------------------------------------------------------------- packets
  /// Processes one "pos" packet (UDP or HTTP POST body). Returns the ACK text, or null for a
  /// bad packet (the firmware sends nothing back over UDP and 400 over HTTP).
  String? processPacket(String json) {
    final d = ArduinoJsonDoc.parse(json);
    if (d == null || d.str('t', '') != 'pos') {
      pktBad++;
      _print('[RX! ] bad packet: ${strlcpy(json, 81)}');
      return null;
    }
    final id32 = d.uintOr('id', 0);
    if (id32 == 0 || id32 > 65535 || d.isNull('lat') || d.isNull('lon')) {
      pktBad++;
      _print('[RX! ] packet without id/lat/lon: ${strlcpy(json, 81)}');
      return null;
    }
    final id = id32;
    pktRx++;

    var v = findVeh(id);
    if (v == null) {
      v = allocVeh();
      if (v == null) {
        _print('[RX! ] vehicle table full');
        return null;
      }
      final fresh = Veh()
        ..used = true
        ..id = id;
      vehs[vehs.indexOf(v)] = fresh;
      v = fresh;
    }
    final first = v.pkts == 0;

    final prevLane = v.lane;
    final prevDist = first ? f32(1e9) : v.dist;
    v.type = d.intOr('ty', 0) != 0 ? VT_EMERGENCY : VT_NORMAL;
    v.spd = d.floatOr('spd', 0.0);
    v.hdg = d.isNull('hdg') ? -1.0 : d.asFloat('hdg');
    v.lat = d.asDouble('lat');
    v.lon = d.asDouble('lon');
    v.tl = laneIndex(d.str('tl', ''));
    v.hasRssi = !d.isNull('rssi');
    v.rssi = d.intOr('rssi', 0);
    v.lastSeen = millis();
    v.hw = strlcpy(d.str('hw', '?'), 12);

    // lost packets from gaps in "seq"
    if (!d.isNull('seq')) {
      final s = d.asUint32('seq');
      if (!first) {
        if (s > v.lastSeq + 1) v.lost += s - v.lastSeq - 1;
        // s <= lastSeq: vehicle restarted or duplicate -> no loss counted
      }
      v.lastSeq = s;
    }
    v.pkts++;

    // ---- lane decision from the coordinates ONLY ----
    final r = v2iClassify(v.lat, v.lon, v.spd, v.hdg, v.hdg >= 0.0, prevLane, prevDist, geometry: geometry);
    v
      ..lane = r.lane
      ..st = r.st
      ..reason = r.reason
      ..dist = r.dist
      ..bearing = r.bearing;

    final newConn = connectedVehicles() == 1 && first;
    everRx = true;
    lastAnyRxMs = millis();
    if (first) {
      _print(
        '[CONN] id=$id ${v.hw} ${v.type == VT_EMERGENCY ? 'EMERGENCY' : 'normal'} connected '
        '(${connectedVehicles()} vehicle(s))${newConn ? ' - first vehicle' : ''}',
      );
    }

    if (logRx) {
      final ign = v.st == V2IState.ignored;
      _print(
        '[RX  ] id=$id ${v.type == VT_EMERGENCY ? 'EMERG' : 'normal'} ${v.hw} lat=${cfix(v.lat, 6)} '
        'lon=${cfix(v.lon, 6)} spd=${cfix(v.spd, 1)} hdg=${cfix(v.hdg, 0)} -> lane=${v.lane >= 0 ? LANE_NAME[v.lane] : '-'} '
        'tl=${v.tl >= 0 ? LANE_NAME[v.tl] : '?'} ${stateName(v.st)} d=${cfix(v.dist, 1)}m brg=${cfix(v.bearing, 0)}'
        '${ign ? ' ' : ''}${ign ? reasonName(v.reason) : ''}',
      );
    }

    // verification against the test lane (never used for the decision)
    if (v.lane >= 0 && v.tl >= 0 && v.lane != v.tl && millis() - v.lastMismatchLog >= MISMATCH_LOG_MS) {
      v.lastMismatchLog = millis();
      _print(
        '[MISMATCH] id=$id computed lane ${LANE_NAME[v.lane]} but test data says ${LANE_NAME[v.tl]} '
        '(brg=${cfix(v.bearing, 0)} d=${cfix(v.dist, 1)}m hdg=${cfix(v.hdg, 0)})',
      );
    }

    if (v.type == VT_EMERGENCY && isActive(v) && !v.prioLogged) {
      v.prioLogged = true;
      v.prioSince = millis();
      _print(
        '[PRIO] emergency id=$id detected on lane ${LANE_NAME[v.lane]} d=${cfix(v.dist, 0)}m ${stateName(v.st)} '
        '-> priority requested',
      );
    }
    if (!isActive(v)) v.prioLogged = false; // re-arm for the next trip

    densityCheck();
    modeWatch();

    // ---- ACK ----
    final pri = (v.type == VT_EMERGENCY && isActive(v)) ? 1 : 0;
    final ack = v.lane >= 0
        ? AckPacket(
            id: id,
            seq: v.lastSeq,
            mode: modeName(effMode),
            lane: LANE_NAME[v.lane],
            st: stateName(v.st),
            sig: sigOf(v.lane),
            rem: laneRemS(v.lane),
            pri: pri,
          )
        : AckPacket(id: id, seq: v.lastSeq, mode: modeName(effMode), lane: '-', st: stateName(v.st), sig: '-', rem: 0, pri: pri);
    return ack.encode();
  }

  /// Digital twin only: RTT reported by a vehicle (shown in the vehicle table).
  void reportRtt(int id, int rttMs) => findVeh(id)?.rttMs = rttMs;

  // ---------------------------------------------------------------- state JSON
  /// Same keys, order and meaning as the firmware's buildState(). Must start with "v":2.
  Map<String, Object?> buildState() {
    final why = modeReason(112);
    final eml = emergencyLaneForState();
    final now = millis();
    final target = phase == Phase.green ? f32(phaseDur / 1000.0) : (curLane >= 0 ? plannedGreenS(curLane) : 0.0);
    return {
      'v': APP_DATA_VERSION, // FIRST key (app checks it)
      't': 'state',
      'mode': modeName(effMode), // effective
      'requested_mode': reqModeName(reqMode),
      'target_mode': modeName(targetMode()),
      'mode_reason': why,
      'fallback': reqMode == ReqMode.auto && effMode == Mode.fixed,
      'emergency_lane': eml >= 0 ? LANE_NAME[eml] : '-',
      'priority_active': prioGreen,
      'uptime_s': millis() ~/ 1000,
      'cur': curLane >= 0 ? LANE_NAME[curLane] : '-',
      'phase': phaseName(),
      'rx': pktRx,
      'bad': pktBad,
      'controller': controllerName,
      'intersection': intersectionName,
      'online': true,
      'vehicle_count': connectedVehicles(),
      'congestion': densName(overallDens),
      'queued_total': totQueued,
      'approaching_total': totApproach,
      'plan': {
        'C': jsonFloat(_r1(previewPlan.C)),
        'Y': jsonFloat(_r2(previewPlan.Y)),
        'L': jsonFloat(_r1(previewPlan.L)),
        'K': jsonFloat(f32(K_APPROACH)),
        's': jsonFloat(f32(SAT_FLOW_VPH)),
        'window_s': jsonFloat(f32(OBS_WINDOW_S)),
      },
      'lanes': [
        for (var l = 0; l < NUM_LANES; l++)
          {
            'lane': LANE_NAME[l],
            'sig': sigOf(l),
            'rem': jsonFloat(_r1(laneRemS(l))),
            'queued': ls[l].queued,
            'approach': ls[l].approach, // old key, kept for the app
            'approaching': ls[l].approach,
            'crossing': ls[l].crossing,
            'emerg': ls[l].emerg,
            'qw': jsonFloat(_r1(ls[l].qw)),
            'density': densName(ls[l].dens),
            'y': jsonFloat(_r2(previewPlan.y[l])),
            'g': jsonFloat(_r1((l == curLane && phase == Phase.green) ? f32(phaseDur / 1000.0) : plannedGreenS(l))),
          },
      ],
      'vehicles': [
        for (final v in vehs)
          if (v.used)
            {
              'id': v.id,
              'ty': v.type,
              'hw': v.hw,
              'lane': v.lane >= 0 ? LANE_NAME[v.lane] : '-',
              'tl': v.tl >= 0 ? LANE_NAME[v.tl] : '-',
              'st': stateName(v.st),
              'spd': jsonFloat(_r1(v.spd)),
              'hdg': v.hdg.truncate(),
              'dist': jsonFloat(_r1(v.dist)),
              'lat': jsonDouble(v.lat),
              'lon': jsonDouble(v.lon),
              'rssi': v.hasRssi ? v.rssi : null,
              'pkts': v.pkts,
              'lost': v.lost,
              'age_s': jsonFloat(_r1(f32((now - v.lastSeen) / 1000.0))),
            },
      ],
      'timing': {
        'phase': phaseName(),
        'lane': curLane >= 0 ? LANE_NAME[curLane] : '-',
        'target_green': jsonFloat(_r1(target)),
        'elapsed': jsonFloat(_r1(f32((now - phaseStart) / 1000.0))),
        'remaining': jsonFloat(_r1(phase == Phase.green ? greenRemS() : phaseRemS())),
        'next_phase': phase == Phase.green ? 'YELLOW' : (phase == Phase.yellow ? 'ALL_RED' : 'NEXT_GREEN'),
        'priority': prioGreen,
      },
    };
  }

  // ---------------------------------------------------------------- console
  void printVehicles() {
    final now = millis();
    _print('---- vehicles -------------------------------------------------------------------------');
    _print('  id  hw        type    lane test state        spd km/h  dist m  RSSI  pkts  lost  age s');
    var n = 0;
    for (final v in vehs) {
      if (!v.used) continue;
      n++;
      final rs = v.hasRssi ? '${v.rssi}' : '-';
      _print(
        '${'${v.id}'.padLeft(4)}  ${v.hw.padRight(8)}  ${(v.type == VT_EMERGENCY ? 'EMERG' : 'normal').padRight(6)}  '
        '${(v.lane >= 0 ? LANE_NAME[v.lane] : '-').padRight(4)} ${(v.tl >= 0 ? LANE_NAME[v.tl] : '-').padRight(4)} '
        '${stateName(v.st).padRight(12)} ${cfixw(v.spd, 8, 1)}  ${cfixw(v.dist, 6, 1)}  ${rs.padLeft(4)}  '
        '${'${v.pkts}'.padLeft(4)}  ${'${v.lost}'.padLeft(4)}  ${cfixw(f32((now - v.lastSeen) / 1000.0), 5, 1)}',
      );
    }
    if (n == 0) _print('(none)');
    _print('---------------------------------------------------------------------------------------');
  }

  String statusLine() {
    final why = modeReason(112);
    final rem = phase == Phase.green ? greenRemS() : phaseRemS();
    String q(int l) => '${cfix(ls[l].qw, 1)} ${densName(ls[l].dens)}';
    return '[STAT] ${effMode == Mode.fixed ? 'FIXED' : 'ADAPTIVE'} ($why) req=${reqModeName(reqMode)} | '
        'N:${sigOf(0)} E:${sigOf(1)} S:${sigOf(2)} W:${sigOf(3)} | '
        'cur=${curLane >= 0 ? LANE_NAME[curLane] : '-'} ${phaseName()} ${cfix(rem, 1)}s${prioGreen ? ' PRIORITY' : ''} | '
        'veh=${connectedVehicles()} | Qw N=${q(0)} E=${q(1)} S=${q(2)} W=${q(3)} | overall=${densName(overallDens)}';
  }

  void printStatus() => _print(statusLine());

  void printHelp() => _print('cmds: f=force fixed  a=force adaptive  o=auto  v=vehicle table  r=[RX] log on/off  p=plan  h=help');

  /// The Serial Monitor commands (one character each).
  void command(String c, {String src = 'app'}) {
    switch (c) {
      case 'f':
        setReqMode(ReqMode.fixed, "$src 'f'");
      case 'a':
        setReqMode(ReqMode.adaptive, "$src 'a'");
      case 'o':
        setReqMode(ReqMode.auto, "$src 'o'");
      case 'v':
        printVehicles();
      case 'r':
        logRx = !logRx;
        _print('[RX  ] per-packet log ${logRx ? 'ON' : 'OFF'}');
      case 'p':
        densityCheck();
        printPlan(computePlan(), 'preview');
      case 'h':
        printHelp();
    }
  }

  // ---------------------------------------------------------------- setup / loop
  /// setup(): banner, first plan, ALL RED 1 s before the first green (N).
  void start() {
    if (_started) return;
    _started = true;
    _print('=== DIGITAL V2I INTERSECTION ($controllerName) ===');
    _print('Intersection "$intersectionName", centre ${cfix(geometry.centerLat, 6)}, ${cfix(geometry.centerLon, 6)}');
    _print(
      'Mode: requested=AUTO -> FIXED ${FIXED_GREEN_MS ~/ 1000}s/lane while no vehicle is connected, '
      'ADAPTIVE (Webster) when vehicles send data',
    );
    printHelp();
    densityCheck();
    previewPlan = decisionPlan = computePlan();
    startAllRed();
  }

  /// loop(): the periodic jobs at the firmware's periods, then the signal state machine.
  void tick() {
    if (!_started) start();
    final now = millis();
    if (now - _tDens >= DENSITY_PERIOD_MS) {
      _tDens = now;
      densityCheck();
      modeWatch();
    }
    if (now - _tExpire >= EXPIRE_PERIOD_MS) {
      _tExpire = now;
      expireVehicles();
    }
    if (now - _tStat >= STAT_PERIOD_MS) {
      _tStat = now;
      previewPlan = computePlan();
      printStatus();
    }
    if (now - _tWs >= WS_PERIOD_MS) {
      _tWs = now;
      onBroadcast?.call(buildState());
    }
    signalTick();
  }

  /// Seconds a vehicle at this lane waits / has left, for UI: same as the ACK's "rem".
  double ackRem(int lane) => lane >= 0 ? laneRemS(lane) : 0;

  /// Distance helper for the junction view (metres east/north of the centre).
  (double x, double y) xyOf(Veh v) => geometry.latlonToXY(v.lat, v.lon);

  static double hypot(double x, double y) => math.sqrt(x * x + y * y);
}

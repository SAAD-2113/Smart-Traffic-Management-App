import 'dart:math' as math;

import 'classify.dart';
import 'clock.dart';
import 'cnum.dart';
import 'config.dart';
import 'geometry.dart';
import 'log.dart';
import 'packets.dart';

// Port of docs/firmware-v3/vehicle_node/vehicle_node.ino.
//   loop()            -> tick()
//   receiveAck()      -> onAck(text)
//   UDP send          -> the `send` callback (transport)
// The vehicle never decides its own lane or signal: it shows what the ACK says and counts
// down locally between ACKs. v2iClassify() is run only to print the [BASIS] line.

/// One vehicle preset (`struct Preset`).
class VehicleSpec {
  const VehicleSpec({
    required this.id,
    required this.type,
    required this.arm,
    required this.slot,
    required this.startDist,
    required this.kmh,
    required this.delayS,
  });

  final int id;
  final int type; // VT_NORMAL / VT_EMERGENCY
  final int arm; // 0=N 1=E 2=S 3=W (arm it approaches from)
  final int slot; // queue position when stopped: 0 = front
  final double startDist; // start distance from centre (keep below 150)
  final double kmh; // cruise speed
  final int delayS; // wait this long (parked out of range) before driving in

  VehicleSpec copyWith({int? id, int? type, int? arm, int? slot, double? startDist, double? kmh, int? delayS}) => VehicleSpec(
    id: id ?? this.id,
    type: type ?? this.type,
    arm: arm ?? this.arm,
    slot: slot ?? this.slot,
    startDist: startDist ?? this.startDist,
    kmh: kmh ?? this.kmh,
    delayS: delayS ?? this.delayS,
  );
}

/// PRESETS[6] of vehicle_node.ino (BOARD_PRESET 1..6).
const PRESETS = [
  VehicleSpec(id: 101, type: VT_NORMAL, arm: 0, slot: 0, startDist: 100.0, kmh: 30, delayS: 0), // 1 N lane, front
  VehicleSpec(id: 102, type: VT_NORMAL, arm: 0, slot: 1, startDist: 115.0, kmh: 30, delayS: 0), // 2 N lane, 2nd
  VehicleSpec(id: 103, type: VT_NORMAL, arm: 0, slot: 2, startDist: 130.0, kmh: 30, delayS: 0), // 3 N lane, 3rd
  VehicleSpec(id: 104, type: VT_NORMAL, arm: 1, slot: 0, startDist: 110.0, kmh: 30, delayS: 0), // 4 E lane
  VehicleSpec(id: 201, type: VT_EMERGENCY, arm: 3, slot: 0, startDist: 140.0, kmh: 50, delayS: 30), // 5 W, emergency, after 30 s
  VehicleSpec(id: 202, type: VT_EMERGENCY, arm: 2, slot: 0, startDist: 140.0, kmh: 50, delayS: 70), // 6 S, emergency, after 70 s
];

/// One test point { lat, lon, speed_kmh, heading_deg } (heading may be unknown).
class ReplayPoint {
  const ReplayPoint(this.lat, this.lon, this.spd, [this.hdg]);
  final double lat, lon, spd;
  final double? hdg;
}

/// REPLAY[] of vehicle_node.ino (TEST_SOURCE 1): north arm, queue, cross, leave south.
const REPLAY = [
  ReplayPoint(31.501078, 74.300000, 30.0, 180), // 120 m N, approaching
  ReplayPoint(31.500943, 74.300000, 30.0, 180), // 105 m
  ReplayPoint(31.500808, 74.300000, 28.0, 180), //  90 m
  ReplayPoint(31.500674, 74.300000, 22.0, 180), //  75 m
  ReplayPoint(31.500539, 74.300000, 15.0, 180), //  60 m
  ReplayPoint(31.500404, 74.300000, 8.0, 180), //  45 m
  ReplayPoint(31.500269, 74.300000, 3.0, 180), //  30 m  -> QUEUED (slow, inside 60 m)
  ReplayPoint(31.500180, 74.300000, 0.0, 180), //  20 m  QUEUED
  ReplayPoint(31.500180, 74.300000, 0.0, 180), //  20 m  QUEUED
  ReplayPoint(31.500180, 74.300000, 0.0, 180), //  20 m  QUEUED
  ReplayPoint(31.500135, 74.300000, 10.0, 180), //  15 m  APPROACHING again (moving)
  ReplayPoint(31.500045, 74.300000, 18.0, 180), //   5 m  CROSSING
  ReplayPoint(31.499955, 74.300000, 22.0, 180), //  -5 m  CROSSING
  ReplayPoint(31.499820, 74.300000, 28.0, 180), // -20 m  IGNORED (leaving)
  ReplayPoint(31.499551, 74.300000, 30.0, 180), // -50 m  IGNORED (leaving)
];

/// Where the transmitted fix comes from.
enum VehicleSource {
  /// TEST_SOURCE 0: motion simulation that obeys the ACK.
  simulation,

  /// TEST_SOURCE 1: one table row per 500 ms (firmware REPLAY[] or a recorded trip).
  replay,

  /// Live GPS: the app sets the fix with [V2IVehicle.setExternalFix].
  external,
}

/// A vehicle unit.
class V2IVehicle {
  V2IVehicle({
    required this.spec,
    required this.clock,
    required this.send,
    this.hw = 'Phone',
    this.source = VehicleSource.simulation,
    this.replay = REPLAY,
    this.geometry = const Geometry(),
    this.sendTestLane = true,
    this.rssi,
    this.linkUp,
    math.Random? random,
    V2ILog? log,
    DateTime Function()? wallClock,
  }) : _rnd = random ?? math.Random(),
       _wall = wallClock,
       log = log ?? V2ILog();

  final VehicleSpec spec;
  final MonoClock clock;

  /// Transmits one packet (the transport). Returns nothing; the ACK comes back via [onAck].
  final void Function(String packet) send;
  final String hw;
  final VehicleSource source;
  final List<ReplayPoint> replay;
  final Geometry geometry;

  /// Send "tl" (the arm of the test data). Live GPS sends no "tl".
  final bool sendTestLane;

  /// Wi-Fi RSSI to report, if known (phones usually leave it out).
  final int? Function()? rssi;

  /// Whether the link is up (the firmware sends only while Wi-Fi is connected).
  final bool Function()? linkUp;
  final math.Random _rnd;
  final DateTime Function()? _wall;
  final V2ILog log;

  int get vId => spec.id;
  int get vType => spec.type;
  int get vArm => spec.arm;
  int get vSlot => spec.slot;
  double get vStartDist => f32(spec.startDist);
  double get vCruise => f32(f32(spec.kmh) / 3.6); // m/s
  int get vDelayMs => spec.delayS * 1000;

  // transmitted pose = the test-data fix
  double poseLat = CENTER_LAT, poseLon = CENTER_LON;
  double poseSpdKmh = 0;
  double? poseHdg = 0;

  // simulation state
  double simS = 100; // metres from centre along the arm (negative = past the centre)
  double simV = 0; // m/s
  bool parked = false, tripDone = false;
  bool committed = false; // passed the stop line on green / unavoidable yellow
  int departAt = 0, tripDoneAt = 0;
  String action = 'START';
  int replayIdx = 0;

  // last ACK from the intersection
  String ackLane = '-', ackSt = '-', ackMode = '-';
  String ackSig = 'R';
  double ackRem = 0;
  int ackPri = 0;
  int lastAckMs = 0, seqNo = 0, acksRx = 0;
  int detectMs = 0; // when the intersection first gave this vehicle a lane
  bool prioReported = false;
  int basisPrevLane = -1; // previous lane of the local [BASIS] check
  double basisPrevDist = f32(1e9); // digital: previous distance when no heading is sent

  /// The last [BASIS] decision (for the UI).
  V2IDecision? lastBasis;

  /// Emergency vehicles: seconds from the first lane assignment to green (the [PRIO] line).
  double? detectionToGreenS;

  // Round-trip time: send time of each seq still waiting for its ACK.
  final _sentAt = <int, int>{};
  int? lastRttMs;
  final rttSamples = <int>[];

  /// RTT of the most recent ACKs by seq (digital twin: shown next to the [ACK ] lines).
  final rttBySeq = <int, int>{};
  int bytesSent = 0, packetsSent = 0;

  int _tSim = -1, _tBeacon = 0, _tReplay = 0;
  bool _started = false;

  int millis() => clock.nowMs();
  void _print(String line) => log.add(LogLine(millis(), line, wall: _wall?.call()));

  double _noise(double amp) => f32(f32(amp * (_rnd.nextInt(2001) - 1000)) / 1000.0);

  /// effectiveSignal(): no ACK for 3 s => RED (be safe).
  String effectiveSignal() {
    if (lastAckMs == 0 || millis() - lastAckMs > ACK_TIMEOUT_MS) return 'R';
    return ackSig;
  }

  bool get linkLost => lastAckMs == 0 || millis() - lastAckMs > ACK_TIMEOUT_MS;

  /// "rem" from the last ACK, counted down locally (never below 0).
  double remNow() {
    if (lastAckMs == 0) return 0;
    final r = ackRem - (millis() - lastAckMs) / 1000.0;
    return r < 0 ? 0 : r;
  }

  // ---------------------------------------------------------------- motion simulation
  void restartTrip(bool first) {
    tripDone = false;
    replayIdx = 0;
    lastAckMs = 0;
    committed = false;
    detectMs = 0;
    prioReported = false;
    basisPrevLane = -1;
    basisPrevDist = f32(1e9);
    if (first && vDelayMs > 0) {
      parked = true;
      departAt = millis() + vDelayMs;
      simS = f32(PARK_DIST_M);
      simV = 0;
      action = 'PARKED';
      _print('[SIM ] parked ${cfix(PARK_DIST_M, 0)} m out (outside detection range), departs in ${vDelayMs ~/ 1000} s');
    } else {
      parked = false;
      simS = vStartDist;
      simV = vCruise;
      action = 'START';
      if (source != VehicleSource.external) {
        _print('[SIM ] trip started ${cfix(vStartDist, 0)} m out on arm ${LANE_NAME[vArm]}');
      }
    }
  }

  void simStep(double dt) {
    if (tripDone) return;

    if (parked) {
      if (millis() - departAt < 0) {
        simS = f32(PARK_DIST_M);
        simV = 0;
        action = 'PARKED';
        return;
      }
      parked = false;
      simS = vStartDist;
      simV = vCruise;
      lastAckMs = 0;
      _print('[SIM ] departing - entering the junction detection area');
    }

    final stopSlot = f32(STOP_LINE_M + f32(vSlot * QUEUE_SPACING_M));

    if (committed) {
      // past the stop line: clear the junction
      simV = math.min(vCruise, f32(simV + f32(ACCEL_MS2 * dt)));
      simS = f32(simS - f32(simV * dt));
      action = simS > 0 ? 'CROSSING' : 'DEPARTING';
    } else {
      final sig = effectiveSignal();
      final stopAt = simS > f32(stopSlot + 0.05) ? stopSlot : f32(STOP_LINE_M); // own queue slot first, then the line
      final dStop = math.max(0.0, f32(simS - stopAt));
      var mustStop = sig != 'G';
      if (sig == 'Y') {
        final brakeDist = f32(f32(simV * simV) / f32(2.0 * DECEL_MS2));
        if (f32(simS - STOP_LINE_M) < f32(brakeDist - 0.5)) mustStop = false; // too close to stop safely: clear it
      }
      if (!mustStop) {
        simV = math.min(vCruise, f32(simV + f32(ACCEL_MS2 * dt)));
        action = sig == 'Y' ? 'RUN-YELLOW' : (simV < f32(vCruise * 0.9) ? 'ACCEL' : 'CRUISE');
        simS = f32(simS - f32(simV * dt));
      } else {
        final vAllowed = f32(math.sqrt(f32(f32(2.0 * DECEL_MS2) * dStop))); // fastest speed that can still stop
        if (simV > vAllowed) {
          simV = math.max(vAllowed, f32(simV - f32(MAX_DECEL_MS2 * dt)));
          action = 'BRAKING';
        } else {
          simV = math.min(math.min(vCruise, vAllowed), f32(simV + f32(ACCEL_MS2 * dt)));
          action = 'APPROACH-RED';
        }
        simS = f32(simS - f32(simV * dt));
        if (simS <= stopAt) {
          // never pass the stop point on red
          simS = stopAt;
          simV = 0;
        }
        if (simV < f32(0.3)) action = 'STOPPED';
      }
      if (simS < f32(STOP_LINE_M)) committed = true; // only reachable on G / run-yellow
    }

    if (simS <= f32(-DEPART_END_M)) {
      tripDone = true;
      tripDoneAt = millis();
      simV = 0;
      action = 'FINISHED';
      _print('[SIM ] trip finished - restarting in ${RESTART_DELAY_MS ~/ 1000} s');
    }
  }

  /// Builds the test-data fix that is transmitted.
  void updatePose() {
    if (source == VehicleSource.replay) {
      if (replay.isEmpty) return;
      final p = replay[replayIdx];
      poseLat = p.lat;
      poseLon = p.lon;
      poseSpdKmh = f32(p.spd);
      poseHdg = p.hdg == null ? null : f32(p.hdg!);
      action = 'REPLAY';
      if (++replayIdx >= replay.length) replayIdx = 0;
      return;
    }
    if (source != VehicleSource.simulation) return;
    final brg = f32(f32(ARM_BEARING[vArm] * f32(math.pi)) / 180.0);
    final x = simS * math.sin(brg) + _noise(GPS_NOISE_M); // metres east of centre
    final y = simS * math.cos(brg) + _noise(GPS_NOISE_M); // metres north of centre
    final (lat, lon) = geometry.xyToLatLon(x, y);
    poseLat = lat;
    poseLon = lon;
    poseSpdKmh = math.max(0.0, f32(f32(simV * 3.6) + _noise(SPD_NOISE_KMH)));
    poseHdg = wrap360(f32(f32(ARM_BEARING[vArm] + 180.0) + _noise(HDG_NOISE_DEG))); // toward the centre
  }

  /// Live GPS: position, speed (km/h) and heading (null when unknown, e.g. standing still).
  void setExternalFix(double lat, double lon, double spdKmh, double? hdg) {
    poseLat = lat;
    poseLon = lon;
    poseSpdKmh = f32(spdKmh < 0 ? 0 : spdKmh);
    poseHdg = hdg == null ? null : f32(hdg);
    action = 'GPS';
  }

  // ---------------------------------------------------------------- V2I link
  void sendBeacon() {
    // Round exactly as transmitted, so [BASIS] uses the same numbers the intersection gets
    final txLat = (poseLat * 1e6).roundToDouble() / 1e6;
    final txLon = (poseLon * 1e6).roundToDouble() / 1e6;
    final txSpd = f32(croundf(f32(poseSpdKmh * 10.0)) / 10.0);
    final int? txHdg = poseHdg == null ? null : f32(poseHdg!).round() % 360;
    final r = rssi?.call();
    final tl = sendTestLane ? LANE_NAME[vArm] : null;

    final packet = PosPacket(
      id: vId,
      ty: vType,
      lat: txLat,
      lon: txLon,
      spd: txSpd,
      hdg: txHdg,
      seq: seqNo,
      hw: hw,
      tl: tl,
      rssi: r,
    ).encode();
    final n = packetBytes(packet);
    if (n >= V2I_MAX_PACKET) {
      _print('[TX! ] packet too long - not sent');
      return;
    }
    _sentAt[seqNo] = millis();
    if (_sentAt.length > 40) _sentAt.remove(_sentAt.keys.first);
    send(packet);
    bytesSent += n;
    packetsSent++;

    _print(
      '[TX  ] #$seqNo id=$vId ${vType == VT_EMERGENCY ? 'EMERG' : 'normal'} $hw lat=${cfix(txLat, 6)} '
      'lon=${cfix(txLon, 6)} spd=${cfix(txSpd, 1)} hdg=${txHdg ?? '-'} tl=${tl ?? '-'} rssi=${r ?? '-'} ($n B) | '
      'sig=${effectiveSignal()} $action',
    );

    // [BASIS]: the same v2iClassify() as the intersection. ESP vehicles always send a heading
    // (hdgValid = true, prevDist = 1e9); without a heading the intersection uses the previous
    // distance, so the basis does too.
    final hdgValid = txHdg != null;
    final b = v2iClassify(
      txLat,
      txLon,
      txSpd,
      (txHdg ?? -1).toDouble(),
      hdgValid,
      basisPrevLane,
      hdgValid ? f32(1e9) : basisPrevDist,
      geometry: geometry,
    );
    basisPrevLane = b.lane;
    basisPrevDist = b.dist;
    lastBasis = b;
    final ign = b.st == V2IState.ignored;
    _print(
      '[BASIS] bearing=${cfix(b.bearing, 0)}deg dist=${cfix(b.dist, 1)}m hdg=${txHdg != null ? '${txHdg}deg' : '-'} '
      'spd=${cfix(txSpd, 1)}km/h => expect lane ${b.lane >= 0 ? LANE_NAME[b.lane] : '-'}, ${stateName(b.st)}'
      '${ign ? ' (' : ''}${ign ? reasonName(b.reason) : ''}${ign ? ')' : (b.st == V2IState.queued ? '  -> counts in Qw' : '')}',
    );
    seqNo++;
  }

  /// receiveAck(): one ACK text from the intersection.
  void onAck(String text) {
    final d = ArduinoJsonDoc.parse(text);
    if (d == null || d.str('t', '') != 'ack') return;
    if (d.intOr('id', 0) != vId) return;

    ackLane = strlcpy(d.str('lane', '-'), 4);
    ackSt = strlcpy(d.str('st', '-'), 16);
    ackMode = strlcpy(d.str('mode', '-'), 12);
    final sg = d.str('sig', 'R');
    ackSig = (sg.startsWith('G') || sg.startsWith('Y')) ? sg[0] : 'R';
    ackRem = d.floatOr('rem', 0.0);
    ackPri = d.intOr('pri', 0);
    lastAckMs = millis();
    acksRx++;
    final seq = d.uintOr('seq', 0);
    final sentAt = _sentAt.remove(seq);
    if (sentAt != null) {
      lastRttMs = millis() - sentAt;
      rttSamples.add(lastRttMs!);
      rttBySeq[seq] = lastRttMs!;
      if (rttBySeq.length > 400) rttBySeq.remove(rttBySeq.keys.first);
    }
    _print(
      '[ACK ] seq=$seq lane=$ackLane st=$ackSt sig=$sg rem=${cfix(ackRem, 1)}s mode=$ackMode${ackPri != 0 ? ' PRIORITY' : ''}',
    );

    // Emergency vehicle: report how long the intersection took to give it green
    final hasLane = ackLane != '-';
    if (hasLane && detectMs == 0) detectMs = millis();
    if (vType == VT_EMERGENCY && hasLane && ackSig == 'G' && !prioReported) {
      prioReported = true;
      detectionToGreenS = f32((millis() - detectMs) / 1000.0);
      _print(
        '[PRIO] GREEN on lane $ackLane, ${cfix(detectionToGreenS!, 1)} s after the intersection first assigned '
        'this vehicle a lane',
      );
    }
  }

  // ---------------------------------------------------------------- setup / loop
  void start() {
    if (_started) return;
    _started = true;
    _print(
      '=== V2I VEHICLE UNIT ($hw) id=$vId type=${vType == VT_EMERGENCY ? 'EMERGENCY' : 'normal'} '
      'lane=${LANE_NAME[vArm]} slot=$vSlot start=${cfix(vStartDist, 0)}m speed=${cfix(f32(vCruise * 3.6), 0)}km/h '
      'source=${switch (source) {
        VehicleSource.simulation => 'motion simulation',
        VehicleSource.replay => 'REPLAY table',
        VehicleSource.external => 'live GPS',
      }} ===',
    );
    restartTrip(true);
    if (source == VehicleSource.simulation) updatePose(); // replay starts at row 0 in loop()
  }

  void tick() {
    if (!_started) start();
    final now = millis();
    if (_tSim < 0) _tSim = now;

    if (source == VehicleSource.replay) {
      if (now - _tReplay >= REPLAY_INTERVAL_MS) {
        _tReplay = now;
        updatePose();
      }
    } else if (source == VehicleSource.simulation) {
      if (now - _tSim >= SIM_STEP_MS) {
        final dt = f32((now - _tSim) / 1000.0);
        _tSim = now;
        simStep(dt);
        updatePose();
      }
      if (tripDone && LOOP_TRIP && now - tripDoneAt > RESTART_DELAY_MS) restartTrip(false);
    }

    if (now - _tBeacon >= BEACON_MS && (linkUp?.call() ?? true)) {
      _tBeacon = now;
      sendBeacon();
    }
  }
}

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:v2i_core/v2i_core.dart' as v2i;

import '../../services/packet_builder.dart' show GpsFix;
import '../data/v2i_models.dart';
import '../transport/links.dart';

/// Where this vehicle's position comes from.
sealed class DriveSource {
  const DriveSource();
  String get label;
}

/// The firmware's motion simulation (TEST_SOURCE 0) on one arm of the session's junction.
class SimulatedDrive extends DriveSource {
  const SimulatedDrive({this.arm = 0, this.slot = 0, this.startDist = 100, this.kmh = 30});
  final int arm; // 0=N 1=E 2=S 3=W (the arm it approaches from)
  final int slot;
  final double startDist;
  final double kmh;

  @override
  String get label => 'Simulated drive, arm ${v2i.LANE_NAME[arm]}';
}

/// The phone's GPS. No "tl" (the lane is unknown), no "hdg" while the heading is not valid.
class LiveGpsDrive extends DriveSource {
  const LiveGpsDrive();

  @override
  String get label => 'Live GPS';
}

/// One of the driver's recorded trips, sent at its recorded times (no interpolation: between
/// two recorded points the last point is sent again, as a beacon repeats its last fix).
class ReplayDrive extends DriveSource {
  const ReplayDrive(this.points, {this.name = 'Recorded trip'});
  final List<TripPoint> points;
  final String name;

  @override
  String get label => 'Replay: $name';
}

/// GPS heading is trusted from this speed up (below it phones report noise).
const headingMinSpeedMps = 1.0;

/// This phone is a vehicle: the firmware v3 vehicle unit (v2i_core) with the server-assigned
/// id. It never decides its own signal: it shows the intersection's last ACK, counts "rem"
/// down locally and shows RED after 3 s without an ACK. v2iClassify only prints [BASIS].
class DigitalVehicle extends ChangeNotifier {
  DigitalVehicle({
    required this.session,
    required this.link,
    required this.source,
    this.gps,
    v2i.MonoClock? clock,
    this.tick = const Duration(milliseconds: 10),
    this.useTimer = true,
    this.hw = 'Phone',
    math.Random? random,
  })  : clock = clock ?? v2i.StopwatchClock(),
        emergency = session.emergency,
        _random = random; // ignore: prefer_initializing_formals

  final JoinedSession session;
  final VehicleLink link;
  final DriveSource source;

  /// Live GPS fixes (LocationService.fixes) when [source] is [LiveGpsDrive].
  final Stream<GpsFix> Function()? gps;
  final v2i.MonoClock clock;
  final Duration tick;
  final bool useTimer;
  final String hw;
  final math.Random? _random;

  late final v2i.V2IVehicle unit;
  bool emergency;
  LinkState linkState = LinkState.connecting;
  String? linkReason;
  bool intersectionOnline = false;

  /// Last error the server sent for a packet (e.g. "EMERGENCY_NOT_AUTHORIZED").
  String? lastError;

  /// Why the drive ended by itself (null while running or stopped by the user).
  String? endedReason;
  bool running = false;
  GpsFix? lastFix;
  bool replayFinished = false;

  Timer? _loop;
  StreamSubscription<GpsFix>? _gpsSub;
  int _startMs = 0, _lastUi = -1 << 40, _lastRttSent = -1 << 40, _acksSeen = 0;

  v2i.V2ILog get log => unit.log;

  void start() {
    if (running) return;
    final sim = source is SimulatedDrive ? source as SimulatedDrive : null;
    unit = v2i.V2IVehicle(
      spec: v2i.VehicleSpec(
        id: session.vehicleId,
        type: emergency ? v2i.VT_EMERGENCY : v2i.VT_NORMAL,
        arm: sim?.arm ?? 0,
        slot: sim?.slot ?? 0,
        startDist: sim?.startDist ?? 100,
        kmh: sim?.kmh ?? 30,
        delayS: 0,
      ),
      clock: clock,
      hw: hw,
      source: sim != null ? v2i.VehicleSource.simulation : v2i.VehicleSource.external,
      geometry: v2i.Geometry(centerLat: session.centerLat, centerLon: session.centerLon),
      sendTestLane: sim != null, // the simulated drive knows its arm, like the firmware's test data
      send: link.send,
      linkUp: _canSend,
      random: _random,
      wallClock: DateTime.now,
    );
    link
      ..onAck = _onAck
      ..onState = (s, r) {
        linkState = s;
        linkReason = r;
        notifyListeners();
      }
      ..onIntersection = (online) {
        intersectionOnline = online;
        notifyListeners();
      }
      ..onProfile = (allowed) {
        // the type is fixed for a drive: end it, so the next one uses the new authorisation
        emergency = allowed;
        _end(allowed
            ? 'An admin authorised this account as an emergency vehicle. Start the drive again.'
            : 'The emergency authorisation was withdrawn. Start the drive again.');
      }
      ..onError = (code, message) {
        lastError = code;
        notifyListeners();
      };
    running = true;
    _startMs = clock.nowMs();
    link.start();
    unit.start();
    if (source is LiveGpsDrive) _gpsSub = gps?.call().listen(_onFix);
    if (source is ReplayDrive) _replayStep();
    if (useTimer) _loop = Timer.periodic(tick, (_) => step());
    notifyListeners();
  }

  bool _canSend() {
    if (linkState != LinkState.online || !running) return false;
    if (source is LiveGpsDrive) return lastFix != null;
    if (source is ReplayDrive) return !replayFinished;
    return true;
  }

  void stop() => _end(null);

  void _end(String? reason) {
    if (!running) return;
    running = false;
    endedReason = reason;
    _loop?.cancel();
    _gpsSub?.cancel();
    link.stop();
    notifyListeners();
  }

  @override
  void dispose() {
    _end(null);
    super.dispose();
  }

  /// One pass of the vehicle's loop().
  void step() {
    if (!running) return;
    if (source is ReplayDrive) _replayStep();
    unit.tick();
    final now = clock.nowMs();
    if (now - _lastUi >= 100) {
      _lastUi = now;
      notifyListeners();
    }
  }

  void _onAck(String raw) {
    if (!running) return;
    unit.onAck(raw);
    if (unit.acksRx != _acksSeen) {
      _acksSeen = unit.acksRx;
      final rtt = unit.lastRttMs;
      final now = clock.nowMs();
      if (rtt != null && now - _lastRttSent >= 2000) {
        _lastRttSent = now;
        link.sendRtt(rtt); // shown in the intersection's vehicle table
      }
    }
  }

  void _onFix(GpsFix f) {
    lastFix = f;
    final speed = f.speedMps;
    final heading = f.headingDeg;
    final hdgValid = speed != null && speed >= headingMinSpeedMps && heading != null && heading >= 0;
    unit.setExternalFix(f.lat, f.lon, speed == null || speed < 0 ? 0 : speed * 3.6, hdgValid ? heading : null);
  }

  void _replayStep() {
    final pts = (source as ReplayDrive).points;
    if (pts.isEmpty) {
      replayFinished = true;
      return;
    }
    final elapsed = (clock.nowMs() - _startMs) / 1000.0;
    if (elapsed > pts.last.t + 1.0) {
      replayFinished = true; // stops sending: the intersection removes the vehicle after 3 s
      return;
    }
    var i = 0;
    while (i + 1 < pts.length && pts[i + 1].t <= elapsed) {
      i++;
    }
    final p = pts[i];
    unit.setExternalFix(p.lat, p.lon, p.speedKmh ?? 0, p.headingDeg != null && (p.speedKmh ?? 0) >= headingMinSpeedMps * 3.6 ? p.headingDeg : null);
    _replayIndex = i;
  }

  int _replayIndex = 0;

  /// Replay progress: index of the point being sent, of [replayLength].
  int get replayIndex => _replayIndex;
  int get replayLength => source is ReplayDrive ? (source as ReplayDrive).points.length : 0;

  // --- what the screen shows (all from the last ACK, counted down locally) -------------------

  /// "G" | "Y" | "R": the ACK's signal, RED when no ACK for 3 s.
  String get signal => unit.effectiveSignal();
  bool get linkLost => unit.linkLost;
  double get remaining => unit.remNow();
  String get lane => unit.ackLane;
  String get state => unit.ackSt;
  String get mode => unit.ackMode;
  bool get priority => unit.ackPri != 0;
  v2i.V2IDecision? get basis => unit.lastBasis;
  double? get detectionToGreenS => unit.detectionToGreenS;
  int? get lastRttMs => unit.lastRttMs;
  List<int> get rttSamples => unit.rttSamples;
  int get packetsSent => unit.packetsSent;
  int get acksReceived => unit.acksRx;
}

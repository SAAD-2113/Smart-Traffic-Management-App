import 'classify.dart';
import 'config.dart';
import 'controller.dart';
import 'log.dart';

// Everything a session produced, for metrics and export (digital twin only, not in the
// firmware). Nothing here changes what the controller does.

/// The controller once per second.
class Snapshot {
  Snapshot({
    required this.ms,
    required this.mode,
    required this.requested,
    required this.phase,
    required this.cur,
    required this.sig,
    required this.rem,
    required this.queued,
    required this.approaching,
    required this.qw,
    required this.vehicles,
    required this.congestion,
    required this.emergencyLane,
    required this.priority,
  });

  final int ms;
  final String mode; // effective: fixed / adaptive
  final String requested; // auto / fixed / adaptive
  final String phase; // GREEN / YELLOW / ALL_RED
  final int cur; // lane of the current phase, -1 none
  final List<String> sig; // per lane G / Y / R
  final List<double> rem; // per lane, seconds left in the current colour (red: estimated wait)
  final List<int> queued;
  final List<int> approaching;
  final List<double> qw;
  final int vehicles;
  final String congestion;
  final int emergencyLane;
  final bool priority;
}

/// One accepted packet as the intersection decided it.
class VehicleSample {
  VehicleSample({
    required this.ms,
    required this.id,
    required this.type,
    required this.hw,
    required this.lane,
    required this.st,
    required this.distM,
    required this.spdKmh,
    required this.pkts,
    required this.lost,
  });

  final int ms;
  final int id;
  final int type;
  final String hw;
  final int lane;
  final V2IState st;
  final double distM;
  final double spdKmh;
  final int pkts; // the controller's counters for this vehicle (reset when it is removed)
  final int lost;
}

/// A packet -> ACK round trip measured on a vehicle.
class RttSample {
  RttSample(this.ms, this.id, this.rttMs);
  final int ms;
  final int id;
  final int rttMs;
}

class Recording {
  Recording({required this.name, required this.startMs});

  final String name;
  final int startMs;
  int endMs = 0;
  final log = <LogLine>[];
  final snapshots = <Snapshot>[];
  final samples = <VehicleSample>[];
  final rtt = <RttSample>[];

  double get durationS => (endMs - startMs) / 1000.0;
}

/// Keeps the full log, a snapshot every second and every vehicle decision of a controller.
/// The owner calls [tick] from its loop, [vehicleSample] after each processPacket() and [rtt]
/// when a vehicle reports a round-trip time.
class SessionRecorder {
  SessionRecorder(this.controller, {String? name})
      : recording = Recording(name: name ?? controller.intersectionName, startMs: controller.millis()) {
    controller.log.listen(_onLine);
  }

  final IntersectionController controller;
  final Recording recording;
  int _lastSnap = -1 << 40;

  void _onLine(LogLine l) => recording.log.add(l);

  void close() => controller.log.unlisten(_onLine);

  void tick() {
    final now = controller.millis();
    recording.endMs = now;
    if (now - _lastSnap < 1000) return;
    _lastSnap = now;
    final c = controller;
    recording.snapshots.add(Snapshot(
      ms: now,
      mode: modeName(c.effMode),
      requested: reqModeName(c.reqMode),
      phase: c.phaseName(),
      cur: c.curLane,
      sig: [for (var l = 0; l < NUM_LANES; l++) c.sigOf(l)],
      rem: [for (var l = 0; l < NUM_LANES; l++) c.laneRemS(l)],
      queued: [for (final s in c.ls) s.queued],
      approaching: [for (final s in c.ls) s.approach],
      qw: [for (final s in c.ls) s.qw],
      vehicles: c.connectedVehicles(),
      congestion: densName(c.overallDens),
      emergencyLane: c.emergencyLaneForState(),
      priority: c.prioGreen,
    ));
  }

  void vehicleSample(int id) {
    final v = controller.findVeh(id);
    if (v == null) return;
    recording.samples.add(VehicleSample(
      ms: controller.millis(),
      id: id,
      type: v.type,
      hw: v.hw,
      lane: v.lane,
      st: v.st,
      distM: v.dist,
      spdKmh: v.spd,
      pkts: v.pkts,
      lost: v.lost,
    ));
  }

  void rtt(int id, int ms) => recording.rtt.add(RttSample(controller.millis(), id, ms));
}

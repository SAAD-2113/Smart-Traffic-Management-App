import 'dart:math' as math;

import 'clock.dart';
import 'config.dart';
import 'controller.dart';
import 'geometry.dart';
import 'metrics.dart';
import 'recorder.dart';
import 'vehicle.dart';

// Headless runs for the "Fixed vs Adaptive" comparison: the same injected vehicles, the same
// seed, once with the mode forced FIXED and once in AUTO, on a fake clock as fast as the CPU
// allows. Digital simulation only.

class Scenario {
  const Scenario({required this.vehicles, this.seed = 1, this.durationMs = 600000, this.geometry = const Geometry()});

  final List<VehicleSpec> vehicles;
  final int seed;
  final int durationMs;
  final Geometry geometry;

  /// The six firmware presets (BOARD_PRESET 1..6).
  static Scenario presets({int seed = 1, int durationMs = 600000}) =>
      Scenario(vehicles: PRESETS, seed: seed, durationMs: durationMs);
}

class RunResult {
  RunResult({required this.label, required this.recording, required this.metrics, required this.simMs, required this.wallMs});

  /// "FIXED (forced)" or "AUTO".
  final String label;
  final Recording recording;
  final Metrics metrics;
  final int simMs;
  final int wallMs;

  /// How many times faster than real time the run went (measured).
  double get speedup => wallMs <= 0 ? double.infinity : simMs / wallMs;
}

/// Runs [s] with the controller's requested mode set by [command] ('f' = forced FIXED,
/// 'o' = AUTO, 'a' = forced ADAPTIVE) before the first lane decision.
RunResult runScenario(Scenario s, {required String command, int stepMs = 10, String name = 'comparison'}) {
  final watch = Stopwatch()..start();
  final clock = FakeClock(0);
  final ic = IntersectionController(clock: clock, geometry: s.geometry, intersectionName: name);
  final rec = SessionRecorder(ic, name: name);
  if (command != 'o') ic.command(command, src: 'comparison');
  ic.start();

  final pending = <(V2IVehicle, String)>[];
  final vehicles = <V2IVehicle>[];
  for (final spec in s.vehicles) {
    late final V2IVehicle v;
    v = V2IVehicle(
      spec: spec,
      clock: clock,
      hw: 'inject',
      geometry: s.geometry,
      random: math.Random(s.seed * 7919 + spec.id),
      send: (p) {
        final ack = ic.processPacket(p);
        rec.vehicleSample(spec.id);
        if (ack != null) pending.add((v, ack)); // read on the vehicle's next pass
      },
    );
    vehicles.add(v);
  }

  for (var t = 0; t < s.durationMs; t += stepMs) {
    clock.advance(stepMs);
    final acks = List.of(pending);
    pending.clear();
    for (final (v, a) in acks) {
      v.onAck(a); // (no RTT here: in-process delivery is one loop pass, not a network)
    }
    for (final v in vehicles) {
      v.tick();
    }
    ic.tick();
    rec.tick();
  }
  rec.close();
  watch.stop();
  return RunResult(
    label: command == 'f' ? 'FIXED (forced)' : (command == 'a' ? 'ADAPTIVE (forced)' : 'AUTO'),
    recording: rec.recording,
    metrics: computeMetrics(rec.recording),
    simMs: s.durationMs,
    wallMs: watch.elapsedMilliseconds,
  );
}

/// The two runs of the comparison: forced FIXED, then AUTO (adaptive while vehicles send).
(RunResult, RunResult) compareFixedAdaptive(Scenario s, {int stepMs = 10}) =>
    (runScenario(s, command: 'f', stepMs: stepMs), runScenario(s, command: 'o', stepMs: stepMs));

/// Ids for injected test vehicles that are not firmware presets (below the account range 1001+).
const INJECT_CUSTOM_ID_MIN = 501;
const INJECT_CUSTOM_ID_MAX = 999;

/// A preset is free to inject when no vehicle in [taken] uses its id.
bool presetFree(VehicleSpec p, Iterable<int> taken) => !taken.contains(p.id);

/// Next free custom id in 501..999.
int? nextCustomId(Iterable<int> taken) {
  final used = taken.toSet();
  for (var id = INJECT_CUSTOM_ID_MIN; id <= INJECT_CUSTOM_ID_MAX; id++) {
    if (!used.contains(id)) return id;
  }
  return null;
}

/// The arm names, for labels.
String armName(int arm) => LANE_NAME[arm];

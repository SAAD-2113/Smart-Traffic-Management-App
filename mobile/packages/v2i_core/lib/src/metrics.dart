import 'classify.dart';
import 'config.dart';
import 'geometry.dart';
import 'recorder.dart';

// Metrics computed only from a Recording (log lines, snapshots, vehicle samples, RTT samples).
// Nothing is estimated: each value says where it comes from.

/// A lane's green, from its "[SIG ] lane X GREEN" line to its "[SIG ] lane X YELLOW" line.
class GreenInterval {
  GreenInterval(this.lane, this.startMs, this.endMs, this.plannedS, this.priority);
  final int lane;
  final int startMs;
  int? endMs; // null while it runs
  final double plannedS; // the green time in the [SIG] line
  final bool priority;
}

/// A vehicle that became QUEUED while its lane was not green, until that lane's next green.
class WaitEpisode {
  WaitEpisode(this.id, this.lane, this.queuedMs, this.greenMs);
  final int id;
  final int lane;
  final int queuedMs;
  final int greenMs;
  double get waitS => (greenMs - queuedMs) / 1000.0;
}

/// Time between two consecutive greens of the same lane, measured from the [SIG] lines.
class CycleSample {
  CycleSample(this.ms, this.lane, this.cycleS);
  final int ms;
  final int lane;
  final double cycleS;
}

/// "[PRIO] lane W GREEN for emergency id=201, 4.0 s after its request".
class EmergencyGreen {
  EmergencyGreen(this.ms, this.id, this.lane, this.seconds);
  final int ms;
  final int id;
  final int lane;
  final double seconds;
}

class VehicleStats {
  VehicleStats(this.id, this.type, this.hw);
  final int id;
  final int type;
  final String hw;
  int pkts = 0, lost = 0;
  final waits = <double>[];
  final rtt = <int>[];
  int crossings = 0;

  double? get lossPct => pkts + lost == 0 ? null : 100.0 * lost / (pkts + lost);
}

class Metrics {
  Metrics(this.durationS);

  final double durationS;
  final greens = <GreenInterval>[];
  final waits = <WaitEpisode>[];
  final cycles = <CycleSample>[];

  /// C0 of every [PLAN] line (the planned cycle at each adaptive lane decision).
  final plannedCycles = <(int ms, double c0)>[];
  final emergencies = <EmergencyGreen>[];
  final throughput = List<int>.filled(NUM_LANES, 0); // vehicles that entered the box, per lane
  final vehicles = <int, VehicleStats>{};
  int modeChanges = 0;

  double? get avgWaitS => waits.isEmpty ? null : waits.map((w) => w.waitS).reduce((a, b) => a + b) / waits.length;
  double? get maxWaitS => waits.isEmpty ? null : waits.map((w) => w.waitS).reduce((a, b) => a > b ? a : b);
  double? get meanCycleS => cycles.isEmpty ? null : cycles.map((c) => c.cycleS).reduce((a, b) => a + b) / cycles.length;
  int get totalThroughput => throughput.reduce((a, b) => a + b);

  /// Vehicles per hour per lane over the recorded time.
  List<double?> get throughputPerHour =>
      [for (final n in throughput) durationS <= 0 ? null : n * 3600.0 / durationS];

  List<int> get allRtt => [for (final v in vehicles.values) ...v.rtt];
  int get totalPkts => vehicles.values.fold(0, (a, v) => a + v.pkts);
  int get totalLost => vehicles.values.fold(0, (a, v) => a + v.lost);
  double? get lossPct => totalPkts + totalLost == 0 ? null : 100.0 * totalLost / (totalPkts + totalLost);
}

/// Percentile (nearest rank) of measured samples, or null.
num? percentile(List<num> xs, double p) {
  if (xs.isEmpty) return null;
  final s = [...xs]..sort();
  final rank = (p / 100 * s.length).ceil().clamp(1, s.length);
  return s[rank - 1];
}

final _greenRe = RegExp(r'^\[SIG \] lane ([NESW]) GREEN (\d+\.\d)s \((.*)\)$');
final _yellowRe = RegExp(r'^\[SIG \] lane ([NESW]) YELLOW ');
final _planRe = RegExp(r'^\[PLAN\] adaptive .* C0=(\d+\.\d)s ');
final _prioRe = RegExp(r'^\[PRIO\] lane ([NESW]) GREEN for emergency id=(\d+), (\d+\.\d) s after its request$');
final _modeRe = RegExp(r'^\[MODE\] effective mode now ');

Metrics computeMetrics(Recording r) {
  final m = Metrics(r.durationS);
  final open = <int, GreenInterval>{};

  for (final l in r.log) {
    final t = l.text;
    final g = _greenRe.firstMatch(t);
    if (g != null) {
      final lane = laneIndex(g.group(1));
      final gi = GreenInterval(lane, l.ms, null, double.parse(g.group(2)!), g.group(3)!.startsWith('EMERGENCY PRIORITY'));
      final prev = m.greens.lastWhere((x) => x.lane == lane, orElse: () => gi);
      if (!identical(prev, gi)) m.cycles.add(CycleSample(l.ms, lane, (l.ms - prev.startMs) / 1000.0));
      m.greens.add(gi);
      open[lane] = gi;
      continue;
    }
    final y = _yellowRe.firstMatch(t);
    if (y != null) {
      open.remove(laneIndex(y.group(1)))?.endMs = l.ms;
      continue;
    }
    final p = _planRe.firstMatch(t);
    if (p != null) {
      m.plannedCycles.add((l.ms, double.parse(p.group(1)!)));
      continue;
    }
    final e = _prioRe.firstMatch(t);
    if (e != null) {
      m.emergencies.add(EmergencyGreen(l.ms, int.parse(e.group(2)!), laneIndex(e.group(1)), double.parse(e.group(3)!)));
      continue;
    }
    if (_modeRe.hasMatch(t)) m.modeChanges++;
  }

  bool greenAt(int lane, int ms) =>
      m.greens.any((g) => g.lane == lane && g.startMs <= ms && (g.endMs == null || ms < g.endMs!));
  int? nextGreen(int lane, int ms) {
    for (final g in m.greens) {
      if (g.lane == lane && g.startMs > ms) return g.startMs;
    }
    return null;
  }

  // per vehicle: samples in time order
  final byId = <int, List<VehicleSample>>{};
  for (final s in r.samples) {
    (byId[s.id] ??= []).add(s);
  }
  for (final entry in byId.entries) {
    final samples = entry.value;
    final v = m.vehicles[entry.key] = VehicleStats(entry.key, samples.last.type, samples.last.hw);

    // packet counters: the controller resets them when it removes the vehicle -> add segments
    var segPkts = 0, segLost = 0;
    for (final s in samples) {
      if (s.pkts < segPkts) {
        v.pkts += segPkts;
        v.lost += segLost;
      }
      segPkts = s.pkts;
      segLost = s.lost;
    }
    v.pkts += segPkts;
    v.lost += segLost;

    for (var i = 0; i < samples.length; i++) {
      final s = samples[i];
      final prev = i > 0 ? samples[i - 1] : null;
      // entering the junction box from a lane = one vehicle through
      if (s.st == V2IState.crossing && s.lane >= 0 && prev?.st != V2IState.crossing) {
        m.throughput[s.lane]++;
        v.crossings++;
      }
      // a wait starts when the vehicle becomes QUEUED on a lane that is not green
      if (s.st != V2IState.queued || s.lane < 0 || prev?.st == V2IState.queued) continue;
      if (greenAt(s.lane, s.ms)) continue;
      final green = nextGreen(s.lane, s.ms);
      if (green == null) continue; // the recording ended first
      // it must still be on that lane, waiting (queued, or creeping up in the queue), at the green
      var stayed = false;
      for (var j = i + 1; j < samples.length; j++) {
        final x = samples[j];
        if (x.lane != s.lane || (x.st != V2IState.queued && x.st != V2IState.approaching)) {
          stayed = x.ms >= green; // left the queue only after its green started
          break;
        }
        if (x.ms >= green) {
          stayed = true;
          break;
        }
      }
      if (!stayed) continue;
      final w = WaitEpisode(s.id, s.lane, s.ms, green);
      m.waits.add(w);
      v.waits.add(w.waitS);
    }
  }
  for (final x in r.rtt) {
    (m.vehicles[x.id] ??= VehicleStats(x.id, VT_NORMAL, '')).rtt.add(x.rttMs);
  }
  return m;
}

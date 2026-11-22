import 'classify.dart';
import 'cnum.dart';
import 'config.dart';
import 'metrics.dart';
import 'recorder.dart';
import 'scenario.dart';

// CSV and raw-log export. Every file starts with "#" lines that say what the numbers are:
// a digital simulation, measured on which device and when, so they are never confused with
// hardware measurements. (pandas: read_csv(..., comment='#'))

class ExportLabel {
  const ExportLabel({required this.device, required this.date, required this.session, this.transport, this.extra = const []});

  /// e.g. "Samsung SM-A515F (Android 13)".
  final String device;

  /// Local date and time of the export.
  final DateTime date;
  final String session;
  final String? transport;
  final List<String> extra;

  String get dateText {
    String two(int v) => v.toString().padLeft(2, '0');
    final d = date;
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  /// "digital simulation, measured on `device` on `date`"
  String get line => 'digital simulation, measured on $device on $dateText';

  String header(String what) => [
        '# Digital V2I (firmware v3 twin): $what',
        '# $line',
        '# session: ${_one(session)}',
        if (transport != null) '# transport: ${_one(transport!)}',
        for (final e in extra) '# ${_one(e)}',
      ].join('\n');
}

String _one(String s) => s.replaceAll('\n', ' ');

String _csv(Object? v) {
  if (v == null) return '';
  final s = v is double ? cfix(v, 3) : '$v';
  return s.contains(',') || s.contains('"') ? '"${s.replaceAll('"', '""')}"' : s;
}

String _row(List<Object?> cells) => cells.map(_csv).join(',');

String _t(int ms, int start) => cfix((ms - start) / 1000.0, 3);

/// The raw log: time since the start (s), phone time, and the Serial-Monitor line unchanged.
String eventLog(Recording r, ExportLabel label) {
  final b = StringBuffer(label.header('controller log (Serial Monitor lines)'))..writeln();
  b.writeln('# columns: t_s, phone_time, line');
  for (final l in r.log) {
    b.writeln('${_t(l.ms, r.startMs)}\t${l.wall?.toIso8601String() ?? ''}\t${l.text}');
  }
  return b.toString();
}

String snapshotsCsv(Recording r, ExportLabel label) {
  final b = StringBuffer(label.header('controller state, one row per second'))..writeln();
  b.writeln(_row([
    't_s', 'mode', 'requested', 'phase', 'cur',
    for (final n in LANE_NAME) 'sig_$n',
    for (final n in LANE_NAME) 'rem_s_$n',
    for (final n in LANE_NAME) 'queued_$n',
    for (final n in LANE_NAME) 'approaching_$n',
    for (final n in LANE_NAME) 'qw_$n',
    'vehicles', 'congestion', 'emergency_lane', 'priority',
  ]));
  for (final s in r.snapshots) {
    b.writeln(_row([
      _t(s.ms, r.startMs), s.mode, s.requested, s.phase, s.cur >= 0 ? LANE_NAME[s.cur] : '-',
      ...s.sig,
      for (final x in s.rem) cfix(x, 1),
      ...s.queued,
      ...s.approaching,
      for (final x in s.qw) cfix(x, 1),
      s.vehicles, s.congestion, s.emergencyLane >= 0 ? LANE_NAME[s.emergencyLane] : '-', s.priority ? 1 : 0,
    ]));
  }
  return b.toString();
}

/// Every accepted packet as the intersection decided it.
String samplesCsv(Recording r, ExportLabel label) {
  final b = StringBuffer(label.header('vehicle decisions, one row per accepted packet'))..writeln();
  b.writeln(_row(['t_s', 'id', 'type', 'hw', 'lane', 'state', 'dist_m', 'spd_kmh', 'pkts', 'lost']));
  for (final s in r.samples) {
    b.writeln(_row([
      _t(s.ms, r.startMs), s.id, s.type == VT_EMERGENCY ? 'emergency' : 'normal', s.hw,
      s.lane >= 0 ? LANE_NAME[s.lane] : '-', stateName(s.st), cfix(s.distM, 1), cfix(s.spdKmh, 1), s.pkts, s.lost,
    ]));
  }
  return b.toString();
}

String _n(num? v, [int d = 1]) => v == null ? '' : cfix(v, d);

/// Summary and detail rows: metric, scope, value, unit, how it was obtained.
String metricsCsv(Metrics m, Recording r, ExportLabel label) {
  final b = StringBuffer(label.header('metrics computed from the recorded log, snapshots and packets'))..writeln();
  b.writeln(_row(['metric', 'scope', 'value', 'unit', 'source']));
  void row(String metric, String scope, Object? value, String unit, String source) =>
      b.writeln(_row([metric, scope, value, unit, source]));
  row('duration', 'session', _n(m.durationS), 's', 'recording');
  row('wait_avg', 'all vehicles', _n(m.avgWaitS), 's', 'QUEUED on a red lane -> that lane\'s next GREEN line (${m.waits.length} waits)');
  row('wait_max', 'all vehicles', _n(m.maxWaitS), 's', 'same');
  for (var l = 0; l < NUM_LANES; l++) {
    row('throughput', 'lane ${LANE_NAME[l]}', m.throughput[l], 'vehicles', 'entries into the box (CROSSING) from the lane');
    row('throughput_rate', 'lane ${LANE_NAME[l]}', _n(m.throughputPerHour[l], 0), 'veh/h', 'count / duration');
  }
  row('cycle_mean', 'all lanes', _n(m.meanCycleS), 's', 'green start -> next green start of the same lane (${m.cycles.length} cycles)');
  for (final c in m.cycles) {
    row('cycle', 'lane ${LANE_NAME[c.lane]} at ${_t(c.ms, r.startMs)} s', _n(c.cycleS), 's', '[SIG] lines');
  }
  for (final (ms, c0) in m.plannedCycles) {
    row('planned_C0', 'decision at ${_t(ms, r.startMs)} s', _n(c0), 's', '[PLAN] line');
  }
  for (final e in m.emergencies) {
    row('emergency_detection_to_green', 'id ${e.id} lane ${LANE_NAME[e.lane]} at ${_t(e.ms, r.startMs)} s', _n(e.seconds),
        's', '[PRIO] ... s after its request');
  }
  for (final v in m.vehicles.values) {
    final scope = 'vehicle ${v.id}${v.type == VT_EMERGENCY ? ' (emergency)' : ''}';
    if (v.waits.isNotEmpty) {
      row('wait_avg', scope, _n(v.waits.reduce((a, c) => a + c) / v.waits.length), 's', '${v.waits.length} waits');
      row('wait_max', scope, _n(v.waits.reduce((a, c) => a > c ? a : c)), 's', '');
    }
    row('packets', scope, v.pkts, 'packets', 'controller pkts');
    row('packets_lost', scope, v.lost, 'packets', 'gaps in seq');
    row('packet_loss', scope, _n(v.lossPct, 2), '%', 'lost / (pkts + lost)');
    if (v.rtt.isNotEmpty) {
      row('rtt_median', scope, percentile(v.rtt, 50), 'ms', 'measured on the vehicle, ${v.rtt.length} samples');
      row('rtt_p95', scope, percentile(v.rtt, 95), 'ms', '');
      row('rtt_max', scope, percentile(v.rtt, 100), 'ms', '');
    }
  }
  row('packet_loss', 'all vehicles', _n(m.lossPct, 2), '%', 'lost / (pkts + lost)');
  final all = m.allRtt;
  if (all.isNotEmpty) {
    row('rtt_median', 'all vehicles', percentile(all, 50), 'ms', '${all.length} samples');
    row('rtt_p95', 'all vehicles', percentile(all, 95), 'ms', '');
  }
  return b.toString();
}

/// Side by side: forced FIXED and AUTO on the same scenario.
String comparisonCsv(RunResult fixed, RunResult auto, Scenario s, ExportLabel label) {
  final b = StringBuffer(label.header('Fixed vs Adaptive, same injected vehicles and seed')).toString();
  final out = StringBuffer(b)..writeln();
  out.writeln('# scenario: ${s.vehicles.length} vehicles (${s.vehicles.map((v) => v.id).join(' ')}), seed ${s.seed}, '
      '${cfix(s.durationMs / 1000.0, 0)} s simulated each');
  out.writeln('# ${fixed.label}: ${cfix(fixed.speedup, 0)}x real time; ${auto.label}: ${cfix(auto.speedup, 0)}x real time');
  out.writeln(_row(['metric', 'unit', fixed.label, auto.label]));
  void row(String metric, String unit, String a, String c) => out.writeln(_row([metric, unit, a, c]));
  final f = fixed.metrics, a = auto.metrics;
  row('wait_avg', 's', _n(f.avgWaitS), _n(a.avgWaitS));
  row('wait_max', 's', _n(f.maxWaitS), _n(a.maxWaitS));
  row('waits_counted', 'count', '${f.waits.length}', '${a.waits.length}');
  row('cycle_mean', 's', _n(f.meanCycleS), _n(a.meanCycleS));
  row('throughput_total', 'vehicles', '${f.totalThroughput}', '${a.totalThroughput}');
  for (var l = 0; l < NUM_LANES; l++) {
    row('throughput_${LANE_NAME[l]}', 'vehicles', '${f.throughput[l]}', '${a.throughput[l]}');
  }
  String emerg(Metrics m) => m.emergencies.isEmpty ? '' : _n(m.emergencies.map((e) => e.seconds).reduce((x, y) => x + y) / m.emergencies.length);
  row('emergency_detection_to_green_avg', 's', emerg(f), emerg(a));
  row('emergency_greens', 'count', '${f.emergencies.length}', '${a.emergencies.length}');
  row('greens', 'count', '${f.greens.length}', '${a.greens.length}');
  return out.toString();
}

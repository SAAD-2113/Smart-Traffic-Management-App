import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:v2i_core/v2i_core.dart' as v2i;

import '../../core/theme/app_theme.dart';
import '../../hardware/platform/hardware_platform.dart';
import '../../hardware/ui/hw_style.dart' show HwCard;
import '../../widgets/common.dart';
import '../data/v2i_models.dart';
import '../data/v2i_repository.dart';
import '../export/session_export.dart';
import '../intersection/digital_intersection.dart';
import 'widgets.dart';

String _s(num? v, [int d = 1]) => v == null ? '—' : '${v.toStringAsFixed(d)} s';

/// "Samsung SM-A515F (Android 13)", or a plain fallback (never invented).
Future<String> deviceLabel(HardwarePlatform p) async => await p.deviceName() ?? 'this device (model not reported)';

/// Metrics of the running session, computed from its recording only, with export.
class MetricsScreen extends StatefulWidget {
  const MetricsScreen({super.key, required this.junction, required this.session});
  final DigitalIntersection junction;
  final HostedSession session;

  @override
  State<MetricsScreen> createState() => _MetricsScreenState();
}

class _MetricsScreenState extends State<MetricsScreen> {
  late v2i.Metrics _m = v2i.computeMetrics(widget.junction.recorder.recording);
  late final Future<String> _device = deviceLabel(context.read<HardwarePlatform>());
  final _at = DateTime.now();
  bool _busy = false;

  void _refresh() => setState(() => _m = v2i.computeMetrics(widget.junction.recorder.recording));

  Future<void> _export() async {
    setState(() => _busy = true);
    final r = widget.junction.recorder.recording;
    final label = v2i.ExportLabel(
      device: await _device,
      date: DateTime.now(),
      session: widget.session.name,
      transport: widget.junction.link.label,
      extra: ['join code ${widget.session.joinCode}, centre ${widget.session.centerLat.toStringAsFixed(6)}, '
          '${widget.session.centerLon.toStringAsFixed(6)}'],
    );
    if (!mounted) return;
    final out = await exportFiles(sessionFiles(r, v2i.computeMetrics(r), label),
        platform: context.read<HardwarePlatform>(), repo: context.read<V2IRepository>(), sessionId: widget.session.id);
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(out.summary.isEmpty ? 'Nothing exported.' : out.summary)));
  }

  @override
  Widget build(BuildContext context) {
    final m = _m;
    final theme = Theme.of(context);
    final real = [for (final v in m.vehicles.values) if (v.hw != 'inject') ...v.rtt];
    return Scaffold(
      appBar: AppBar(title: const Text('Metrics'), actions: [
        IconButton(tooltip: 'Recompute', onPressed: _refresh, icon: const Icon(Icons.refresh)),
      ]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        FutureBuilder<String>(
          future: _device,
          builder: (context, snap) => MessageBanner(
            key: const ValueKey('metrics-label'),
            icon: Icons.science_outlined,
            color: StatusColors.simulated,
            text: 'Digital simulation, measured on ${snap.data ?? '…'} on ${v2i.ExportLabel(device: '', date: _at, session: '').dateText}. '
                'Computed from this session\'s log, per-second snapshots and packets (${m.durationS.toStringAsFixed(0)} s recorded).',
          ),
        ),
        const SizedBox(height: 14),
        HwCard(
          title: 'Summary',
          icon: Icons.summarize_outlined,
          child: Wrap(spacing: 24, runSpacing: 14, children: [
            Figure('Average wait', _s(m.avgWaitS)),
            Figure('Max wait', _s(m.maxWaitS)),
            Figure('Waits counted', '${m.waits.length}'),
            Figure('Mean cycle', _s(m.meanCycleS)),
            Figure('Vehicles through', '${m.totalThroughput}'),
            Figure('Packet loss', m.lossPct == null ? '—' : '${m.lossPct!.toStringAsFixed(2)} %'),
            Figure('RTT median (phones)', v2i.percentile(real, 50) == null ? '—' : '${v2i.percentile(real, 50)} ms'),
            Figure('RTT p95 (phones)', v2i.percentile(real, 95) == null ? '—' : '${v2i.percentile(real, 95)} ms'),
          ]),
        ),
        const SizedBox(height: 8),
        Text('Wait: from becoming QUEUED on a lane that is not green to that lane\'s next GREEN line. Throughput: entries '
            'into the junction box. Cycle: green start to the next green start of the same lane. RTT: measured on the '
            'vehicle phones (injected vehicles excluded).',
            style: theme.textTheme.bodySmall),
        const SizedBox(height: 14),
        HwCard(
          title: 'Per lane',
          icon: Icons.call_split,
          child: Table(children: [
            TableRow(children: [for (final h in ['Lane', 'Through', 'veh/h', 'Greens']) Text(h, style: theme.textTheme.labelMedium)]),
            for (var l = 0; l < v2i.NUM_LANES; l++)
              TableRow(children: [
                Text(v2i.LANE_NAME[l], style: const TextStyle(fontWeight: FontWeight.w700)),
                Text('${m.throughput[l]}'),
                Text(m.throughputPerHour[l]?.toStringAsFixed(0) ?? '—'),
                Text('${m.greens.where((g) => g.lane == l).length}'),
              ]),
          ]),
        ),
        const SizedBox(height: 14),
        HwCard(
          title: 'Emergency detection → green',
          icon: Icons.emergency,
          child: m.emergencies.isEmpty
              ? const Text('No priority green in this session.')
              : Column(children: [
                  for (final e in m.emergencies)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text('Vehicle ${e.id} · lane ${v2i.LANE_NAME[e.lane]}'),
                      trailing: Text(_s(e.seconds), style: const TextStyle(fontWeight: FontWeight.w800)),
                      subtitle: Text('at ${((e.ms - widget.junction.recorder.recording.startMs) / 1000).toStringAsFixed(0)} s (intersection [PRIO] line)'),
                    ),
                ]),
        ),
        const SizedBox(height: 14),
        HwCard(
          title: 'Cycle length over time',
          icon: Icons.timeline,
          child: m.cycles.isEmpty
              ? const Text('No complete cycle yet.')
              : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  for (final c in m.cycles.reversed.take(12))
                    Text('${((c.ms - widget.junction.recorder.recording.startMs) / 1000).toStringAsFixed(0).padLeft(5)} s   lane '
                        '${v2i.LANE_NAME[c.lane]}   ${c.cycleS.toStringAsFixed(1)} s',
                        style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
                  if (m.cycles.length > 12) Text('… ${m.cycles.length - 12} earlier (all in the export)', style: theme.textTheme.bodySmall),
                ]),
        ),
        const SizedBox(height: 14),
        HwCard(
          title: 'Vehicles',
          icon: Icons.directions_car,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columnSpacing: 14,
              horizontalMargin: 4,
              columns: const [
                DataColumn(label: Text('ID')),
                DataColumn(label: Text('Device')),
                DataColumn(label: Text('Waits'), numeric: true),
                DataColumn(label: Text('Avg wait'), numeric: true),
                DataColumn(label: Text('Max wait'), numeric: true),
                DataColumn(label: Text('Through'), numeric: true),
                DataColumn(label: Text('Pkts'), numeric: true),
                DataColumn(label: Text('Lost'), numeric: true),
                DataColumn(label: Text('RTT med.'), numeric: true),
              ],
              rows: [
                for (final v in m.vehicles.values)
                  DataRow(cells: [
                    DataCell(Text('${v.id}${v.type == v2i.VT_EMERGENCY ? ' E' : ''}')),
                    DataCell(Text(v.hw)),
                    DataCell(Text('${v.waits.length}')),
                    DataCell(Text(v.waits.isEmpty ? '—' : _s(v.waits.reduce((a, b) => a + b) / v.waits.length))),
                    DataCell(Text(v.waits.isEmpty ? '—' : _s(v.waits.reduce((a, b) => a > b ? a : b)))),
                    DataCell(Text('${v.crossings}')),
                    DataCell(Text('${v.pkts}')),
                    DataCell(Text('${v.lost}')),
                    DataCell(Text(v.rtt.isEmpty ? '—' : '${v2i.percentile(v.rtt, 50)} ms')),
                  ]),
              ],
            ),
          ),
        ),
        const SizedBox(height: 18),
        Wrap(spacing: 10, runSpacing: 10, children: [
          FilledButton.icon(
            key: const ValueKey('export'),
            onPressed: _busy ? null : _export,
            icon: const Icon(Icons.download),
            label: const Text('Export CSV + raw log'),
          ),
          OutlinedButton.icon(
            key: const ValueKey('open-comparison'),
            onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => ComparisonScreen(
                          vehicles: widget.junction.injectedSpecs,
                          centerLat: widget.session.centerLat,
                          centerLon: widget.session.centerLon,
                          sessionName: widget.session.name,
                          sessionId: widget.session.id,
                        ))),
            icon: const Icon(Icons.compare_arrows),
            label: const Text('Fixed vs Adaptive'),
          ),
        ]),
      ]),
    );
  }
}

/// Top-level for compute(): the two headless runs.
(v2i.RunResult, v2i.RunResult) runComparison(v2i.Scenario s) => v2i.compareFixedAdaptive(s);

/// "Fixed vs Adaptive": the same injected vehicles and seed, once forced FIXED and once AUTO,
/// run headless at accelerated time, side by side.
class ComparisonScreen extends StatefulWidget {
  const ComparisonScreen({
    super.key,
    required this.vehicles,
    required this.centerLat,
    required this.centerLon,
    required this.sessionName,
    this.sessionId,
  });

  /// The injected vehicles; empty = the six firmware presets.
  final List<v2i.VehicleSpec> vehicles;
  final double centerLat, centerLon;
  final String sessionName;
  final String? sessionId;

  @override
  State<ComparisonScreen> createState() => _ComparisonScreenState();
}

class _ComparisonScreenState extends State<ComparisonScreen> {
  int _minutes = 10, _seed = 1;
  bool _running = false;
  (v2i.RunResult, v2i.RunResult)? _result;
  v2i.Scenario? _scenario;
  late final Future<String> _device = deviceLabel(context.read<HardwarePlatform>());

  List<v2i.VehicleSpec> get _vehicles => widget.vehicles.isEmpty ? v2i.PRESETS : widget.vehicles;

  Future<void> _run() async {
    setState(() {
      _running = true;
      _result = null;
    });
    final s = v2i.Scenario(
      vehicles: _vehicles,
      seed: _seed,
      durationMs: _minutes * 60 * 1000,
      geometry: v2i.Geometry(centerLat: widget.centerLat, centerLon: widget.centerLon),
    );
    final r = await compute(runComparison, s);
    if (!mounted) return;
    setState(() {
      _running = false;
      _scenario = s;
      _result = r;
    });
  }

  Future<void> _export() async {
    final r = _result, s = _scenario;
    if (r == null || s == null) return;
    final label = v2i.ExportLabel(device: await _device, date: DateTime.now(), session: widget.sessionName);
    if (!mounted) return;
    final out = await exportFiles([
      ExportFile('${exportBase(widget.sessionName, label.date)}_fixed_vs_adaptive.csv', 'text/csv', v2i.comparisonCsv(r.$1, r.$2, s, label)),
    ], platform: context.read<HardwarePlatform>(), repo: context.read<V2IRepository>(), sessionId: widget.sessionId);
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(out.summary)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = _result;
    return Scaffold(
      appBar: AppBar(title: const Text('Fixed vs Adaptive')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text(
          'The same vehicles (${widget.vehicles.isEmpty ? 'the six firmware presets' : '${_vehicles.length} injected: ${_vehicles.map((v) => v.id).join(', ')}'}) '
          'with the same random seed, run headless on this phone: once with the mode forced FIXED, once in AUTO '
          '(adaptive while vehicles send data). Nothing is sent over the network.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 12),
        Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          DropdownButton<int>(
            key: const ValueKey('cmp-minutes'),
            value: _minutes,
            items: [for (final m in const [5, 10, 20, 30]) DropdownMenuItem(value: m, child: Text('$m min simulated'))],
            onChanged: _running ? null : (v) => setState(() => _minutes = v ?? 10),
          ),
          DropdownButton<int>(
            value: _seed,
            items: [for (var s = 1; s <= 5; s++) DropdownMenuItem(value: s, child: Text('Seed $s'))],
            onChanged: _running ? null : (v) => setState(() => _seed = v ?? 1),
          ),
          FilledButton.icon(
            key: const ValueKey('cmp-run'),
            onPressed: _running ? null : _run,
            icon: _running
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.play_arrow),
            label: Text(_running ? 'Running…' : 'Run both'),
          ),
        ]),
        if (r != null) ...[
          const SizedBox(height: 14),
          FutureBuilder<String>(
            future: _device,
            builder: (context, snap) => MessageBanner(
              key: const ValueKey('cmp-label'),
              icon: Icons.science_outlined,
              color: StatusColors.simulated,
              text: 'Digital simulation, ${r.$1.speedup.toStringAsFixed(0)}× / ${r.$2.speedup.toStringAsFixed(0)}× real time, '
                  'measured on ${snap.data ?? '…'} on ${v2i.ExportLabel(device: '', date: DateTime.now(), session: '').dateText}.',
            ),
          ),
          const SizedBox(height: 12),
          HwCard(
            title: 'Side by side',
            icon: Icons.compare_arrows,
            child: Table(
              key: const ValueKey('cmp-table'),
              columnWidths: const {0: FlexColumnWidth(2.2)},
              children: [
                TableRow(children: [
                  const Text(''),
                  Text(r.$1.label, style: const TextStyle(fontWeight: FontWeight.w800)),
                  Text(r.$2.label, style: const TextStyle(fontWeight: FontWeight.w800)),
                ]),
                for (final (name, f, a) in _rows(r.$1.metrics, r.$2.metrics))
                  TableRow(children: [
                    Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Text(name)),
                    Text(f, style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
                    Text(a, style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
                  ]),
              ],
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(onPressed: _export, icon: const Icon(Icons.download), label: const Text('Export comparison CSV')),
        ],
      ]),
    );
  }

  static List<(String, String, String)> _rows(v2i.Metrics f, v2i.Metrics a) {
    String emerg(v2i.Metrics m) =>
        m.emergencies.isEmpty ? '—' : _s(m.emergencies.map((e) => e.seconds).reduce((x, y) => x + y) / m.emergencies.length);
    return [
      ('Average wait', _s(f.avgWaitS), _s(a.avgWaitS)),
      ('Max wait', _s(f.maxWaitS), _s(a.maxWaitS)),
      ('Waits counted', '${f.waits.length}', '${a.waits.length}'),
      ('Mean cycle', _s(f.meanCycleS), _s(a.meanCycleS)),
      ('Vehicles through', '${f.totalThroughput}', '${a.totalThroughput}'),
      for (var l = 0; l < v2i.NUM_LANES; l++) ('  lane ${v2i.LANE_NAME[l]}', '${f.throughput[l]}', '${a.throughput[l]}'),
      ('Emergency detection → green (avg)', emerg(f), emerg(a)),
      ('Greens', '${f.greens.length}', '${a.greens.length}'),
    ];
  }
}

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/units.dart';
import '../../core/utils/validators.dart';
import '../../data/models/signals.dart';
import '../../data/models/traffic.dart';
import '../../data/repositories/manager_repository.dart';
import '../../widgets/charts.dart';
import '../../widgets/common.dart';
import 'live_controller.dart';
import 'signal_plan_screen.dart';

class IntersectionDetailScreen extends StatefulWidget {
  const IntersectionDetailScreen({super.key, required this.intersectionId});
  final String intersectionId;

  @override
  State<IntersectionDetailScreen> createState() => _IntersectionDetailScreenState();
}

class _IntersectionDetailScreenState extends State<IntersectionDetailScreen> {
  IntersectionConfig? _config;
  HistorySeries? _history;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final repo = context.read<ManagerRepository>();
    try {
      final results = await Future.wait([
        repo.intersection(widget.intersectionId),
        repo.intersectionHistory(widget.intersectionId, hours: 1, bucketS: 60),
      ]);
      _config = results[0] as IntersectionConfig;
      _history = results[1] as HistorySeries;
      _error = null;
    } catch (e) {
      _error = e;
    }
    if (mounted) setState(() {});
  }

  Future<void> _update(Map<String, dynamic> changes, String message) async {
    final ok = await runGuarded(context, () => context.read<ManagerRepository>().updateIntersection(widget.intersectionId, changes),
        success: message);
    if (ok && mounted) {
      await context.read<LiveController>().refresh();
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final live = context.watch<LiveController>();
    final t = live.intersections.where((i) => i.id == widget.intersectionId).firstOrNull;
    final config = _config;
    return Scaffold(
      appBar: AppBar(title: Text(t == null ? 'Intersection' : '${t.code} · ${t.name}'), actions: [
        IconButton(tooltip: 'Refresh', onPressed: () async {
          await live.refresh();
          await _load();
        }, icon: const Icon(Icons.refresh)),
      ]),
      body: t == null
          ? (_error != null ? ErrorView(message: '$_error', onRetry: _load) : const LoadingView())
          : ListView(padding: const EdgeInsets.all(16), children: [
              Wrap(spacing: 8, runSpacing: 8, children: [
                CongestionBadge(t.congestionLevel),
                DataQualityChip(t.dataQuality),
                StatusChip(label: t.status, color: t.isActive ? StatusColors.ok : StatusColors.neutral),
                StatusChip(label: '${t.controllerType} control', color: StatusColors.info),
                if (t.sources.isNotEmpty) StatusChip(label: 'Sources: ${t.sources.join(', ')}', color: StatusColors.neutral),
              ]),
              if (t.fullyObserved)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text('Fully observed by a simulator: counts are complete, not estimates from a sample.'),
                ),
              if (t.emergencies.isNotEmpty) ...[
                const SizedBox(height: 12),
                for (final e in t.emergencies)
                  MessageBanner(
                    icon: Icons.emergency,
                    color: StatusColors.emergency,
                    text: '${e.label ?? 'Emergency vehicle'} on ${e.approachName ?? 'an approach'}, '
                        '${Units.distance(e.distanceM)} away, ETA ${e.etaS == null ? '—' : '${e.etaS!.toStringAsFixed(0)} s'}',
                  ),
              ],
              _MetricsSection(t: t),
              const SectionHeader('Approaches', subtitle: 'Per direction of travel into the junction'),
              _ApproachTable(approaches: t.approaches),
              const SectionHeader('Coordination', subtitle: 'Traffic coming from and going to neighbouring intersections'),
              _Coordination(t: t),
              const SectionHeader('Signal'),
              _SignalCard(t: t),
              const SectionHeader('Last hour', subtitle: 'Snapshots every 30 s, averaged per minute'),
              if (_history == null)
                const LoadingView()
              else ...[
                Card(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 16, 16, 8),
                    child: TimeLineChart(unit: 'vehicles', decimals: 1, series: [
                      ChartSeries(
                        label: 'Observed vehicles',
                        color: ChartColors.primary(context),
                        points: [for (final p in _history!.points) ChartPoint(p.t, p.observedVehicles)],
                      ),
                    ]),
                  ),
                ),
                const SizedBox(height: 10),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 16, 16, 8),
                    child: TimeLineChart(unit: 'km/h', series: [
                      ChartSeries(
                        label: 'Average speed',
                        color: ChartColors.primary(context),
                        points: [
                          for (final p in _history!.points)
                            ChartPoint(p.t, p.avgSpeedMps == null ? null : Units.kmh(p.avgSpeedMps!)),
                        ],
                      ),
                    ]),
                  ),
                ),
              ],
              const SectionHeader('Configuration'),
              if (config != null) _ConfigCard(config: config, onUpdate: _update, onChanged: _load),
              const SizedBox(height: 24),
            ]),
    );
  }
}

class _MetricsSection extends StatelessWidget {
  const _MetricsSection({required this.t});
  final IntersectionTraffic t;

  @override
  Widget build(BuildContext context) {
    final o = t.observed, c = t.calculated, e = t.estimated;
    Widget group(String title, String subtitle, List<Widget> rows) => Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
              Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
              const Divider(),
              ...rows,
            ]),
          ),
        );
    return Column(children: [
      const SectionHeader('Traffic now'),
      group('Observed', 'Counted and measured from vehicles in the zone', [
        InfoRow('Vehicles', '${o.vehicleCount} (${t.coreCount} in junction, ${t.departureCount} leaving)'),
        InfoRow('Stopped', '${o.stoppedCount}'),
        InfoRow('Emergency vehicles', '${o.emergencyCount}'),
        InfoRow('Speed avg / min / max',
            '${Units.speed(o.avgSpeedMps)} / ${Units.speed(o.minSpeedMps)} / ${Units.speed(o.maxSpeedMps)}'),
      ]),
      const SizedBox(height: 10),
      group('Calculated', 'Derived directly from the observed values', [
        InfoRow('Speed vs free flow', Units.percent(c.speedRatio)),
        InfoRow('Average waiting time', c.avgWaitingTimeS == null ? '—' : '${c.avgWaitingTimeS!.toStringAsFixed(0)} s (so far)'),
        InfoRow('Arriving within 60 s', '${c.expectedArrivals60s} vehicles'),
      ]),
      const SizedBox(height: 10),
      group('Estimated', 'Depends on assumptions; treat as indicative', [
        InfoRow('Total vehicles', Units.number(e.vehicleCount)),
        InfoRow('Density', e.densityVehPerKmLane == null ? '—' : '${e.densityVehPerKmLane!.toStringAsFixed(1)} veh/km/lane'),
        InfoRow('Assumed app share', '${(e.penetrationRate * 100).toStringAsFixed(1)} % of vehicles'),
        InfoRow('Congestion level', CongestionBadge.label(t.congestionLevel)),
      ]),
    ]);
  }
}

class _ApproachTable extends StatelessWidget {
  const _ApproachTable({required this.approaches});
  final List<ApproachTraffic> approaches;

  @override
  Widget build(BuildContext context) {
    if (approaches.isEmpty) {
      return const Card(child: Padding(padding: EdgeInsets.all(16), child: Text('No approaches configured.')));
    }
    return Card(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          columnSpacing: 18,
          columns: const [
            DataColumn(label: Text('Approach')),
            DataColumn(label: Text('Vehicles'), numeric: true),
            DataColumn(label: Text('Stopped'), numeric: true),
            DataColumn(label: Text('Speed')),
            DataColumn(label: Text('Wait')),
            DataColumn(label: Text('Arriving')),
            DataColumn(label: Text('Est.'), numeric: true),
            DataColumn(label: Text('Congestion')),
          ],
          rows: [
            for (final a in approaches)
              DataRow(cells: [
                DataCell(Text(a.name)),
                DataCell(Text('${a.observed.vehicleCount}')),
                DataCell(Text('${a.observed.stoppedCount}')),
                DataCell(Text(Units.speed(a.observed.avgSpeedMps))),
                DataCell(Text(a.calculated.avgWaitingTimeS == null ? '—' : '${a.calculated.avgWaitingTimeS!.toStringAsFixed(0)} s')),
                DataCell(Text('${a.calculated.expectedArrivals60s}')),
                DataCell(Text(Units.number(a.estimated.vehicleCount))),
                DataCell(CongestionBadge(a.congestionLevel, compact: true)),
              ]),
          ],
        ),
      ),
    );
  }
}

class _Coordination extends StatelessWidget {
  const _Coordination({required this.t});
  final IntersectionTraffic t;

  @override
  Widget build(BuildContext context) {
    if (t.upstream.isEmpty && t.downstream.isEmpty) {
      return const Card(child: Padding(padding: EdgeInsets.all(16), child: Text('No links to other intersections.')));
    }
    return Card(
      child: Column(children: [
        for (final u in t.upstream)
          ListTile(
            dense: true,
            leading: const Icon(Icons.call_received),
            title: Text('From ${u.fromCode} → ${u.toApproachName ?? 'approach'}'),
            subtitle: Text('${u.vehiclesOnLink} on the link · ${u.expectedArrivals60s} arriving within 60 s'
                '${u.avgSpeedMps != null ? ' · ${Units.speed(u.avgSpeedMps)}' : ''}'),
          ),
        for (final d in t.downstream)
          ListTile(
            dense: true,
            leading: const Icon(Icons.call_made),
            title: Text('To ${d.toCode}'),
            trailing: CongestionBadge(d.congestionLevel, compact: true),
          ),
      ]),
    );
  }
}

class _SignalCard extends StatelessWidget {
  const _SignalCard({required this.t});
  final IntersectionTraffic t;

  @override
  Widget build(BuildContext context) {
    final s = t.signal;
    final d = t.decision;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (s == null)
            const Text('No signal state reported. A controller (Raspberry Pi, SUMO bridge or the demo simulator) '
                'reports the phase it is showing.')
          else
            Row(children: [
              Icon(Icons.circle, color: StatusColors.light(s.state), size: 22),
              const SizedBox(width: 8),
              Expanded(
                child: Text('${s.phaseName}: ${s.state.replaceAll('_', ' ')}'
                    '${s.remainingS != null ? ' · ${s.remainingS!.toStringAsFixed(0)} s left' : ''}'),
              ),
              StatusChip(label: s.mode.replaceAll('_', ' '), color: s.mode == 'EMERGENCY' ? StatusColors.emergency : StatusColors.info),
            ]),
          if (d != null) ...[
            const Divider(height: 24),
            Text('Advisory decision: ${d.algorithmLabel}', style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text('Cycle ${d.cycleS.toStringAsFixed(0)} s · '
                '${d.phaseGreens.map((g) => '${g.phase} ${g.greenS.toStringAsFixed(0)} s').join(' · ')}'
                '${d.priorityPhase != null ? ' · priority: ${d.priorityPhase}' : ''}'),
            const SizedBox(height: 4),
            Text(d.reason, style: Theme.of(context).textTheme.bodySmall),
            Text('Valid until ${Units.clock(d.validUntil)}', style: Theme.of(context).textTheme.bodySmall),
          ] else if (t.controllerType == 'FIXED') ...[
            const Divider(height: 24),
            const Text('Fixed-time control: the controller runs its local plan; the engine sends no decisions.'),
          ],
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => SignalPlanScreen(intersectionId: t.id, code: t.code))),
              icon: const Icon(Icons.tune),
              label: const Text('Signal plan'),
            ),
          ),
        ]),
      ),
    );
  }
}

class _ConfigCard extends StatelessWidget {
  const _ConfigCard({required this.config, required this.onUpdate, required this.onChanged});
  final IntersectionConfig config;
  final Future<void> Function(Map<String, dynamic>, String) onUpdate;
  final Future<void> Function() onChanged;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Control mode'),
          const SizedBox(height: 6),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'FIXED', label: Text('Fixed time')),
              ButtonSegment(value: 'ADAPTIVE', label: Text('Adaptive')),
            ],
            selected: {config.controllerType},
            onSelectionChanged: (s) => onUpdate({'controllerType': s.first}, 'Control mode set to ${s.first}.'),
          ),
          const SizedBox(height: 12),
          const Text('Status'),
          const SizedBox(height: 6),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'ACTIVE', label: Text('Active')),
              ButtonSegment(value: 'MAINTENANCE', label: Text('Maintenance')),
              ButtonSegment(value: 'INACTIVE', label: Text('Inactive')),
            ],
            selected: {config.status},
            onSelectionChanged: (s) => onUpdate({'status': s.first}, 'Status set to ${s.first}.'),
          ),
          const Divider(height: 24),
          InfoRow('Location', '${Units.coordinate(config.latitude)}, ${Units.coordinate(config.longitude)}'),
          InfoRow('Core / approach radius', '${config.radiusM.toStringAsFixed(0)} m / ${config.approachRadiusM.toStringAsFixed(0)} m'),
          InfoRow('Approaches', config.approaches.map((a) => '${a['name']} (${(a['travelBearingDeg'] as num).toStringAsFixed(0)}°)').join(', ')),
          InfoRow('Outgoing links', '${config.outgoingLinks.length}'),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
            OutlinedButton.icon(
              onPressed: () => _addApproach(context),
              icon: const Icon(Icons.add),
              label: const Text('Approach'),
            ),
            OutlinedButton.icon(
              onPressed: () => _addLink(context),
              icon: const Icon(Icons.link),
              label: const Text('Link'),
            ),
          ]),
        ]),
      ),
    );
  }

  Future<void> _addApproach(BuildContext context) async {
    final name = TextEditingController();
    final bearing = TextEditingController();
    final lanes = TextEditingController(text: '1');
    final zone = TextEditingController(text: '200');
    final form = GlobalKey<FormState>();
    final repo = context.read<ManagerRepository>();
    await showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Add approach'),
        content: Form(
          key: form,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextFormField(controller: name, decoration: const InputDecoration(labelText: 'Name (e.g. Northbound)'),
                validator: (v) => Validators.required(v, 'A name')),
            TextFormField(controller: bearing, keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Direction of travel (°, 0 = north)'),
                validator: (v) => Validators.number(v, min: 0, max: 359.9)),
            TextFormField(controller: lanes, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Lanes'),
                validator: (v) => Validators.number(v, min: 1, max: 8)),
            TextFormField(controller: zone, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Zone length (m)'),
                validator: (v) => Validators.number(v, min: 10, max: 2000)),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              if (!form.currentState!.validate()) return;
              final ok = await runGuarded(dialogContext, () => repo.addApproach(config.id, {
                    'name': name.text.trim(),
                    'travelBearingDeg': double.parse(bearing.text),
                    'lanes': int.parse(lanes.text.split('.').first),
                    'zoneLengthM': double.parse(zone.text),
                  }));
              if (ok && dialogContext.mounted) Navigator.pop(dialogContext);
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
    await onChanged();
  }

  Future<void> _addLink(BuildContext context) async {
    final live = context.read<LiveController>();
    final repo = context.read<ManagerRepository>();
    final targets = live.intersections.where((i) => i.id != config.id).toList();
    if (targets.isEmpty) {
      showInfo(context, 'Create another intersection first.');
      return;
    }
    var target = targets.first;
    final distance = TextEditingController();
    await showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setState) => AlertDialog(
          title: Text('Link ${config.code} → …'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            DropdownButtonFormField<String>(
              initialValue: target.id,
              decoration: const InputDecoration(labelText: 'Downstream intersection'),
              items: [for (final t in targets) DropdownMenuItem(value: t.id, child: Text('${t.code} · ${t.name}'))],
              onChanged: (id) => setState(() => target = targets.firstWhere((t) => t.id == id)),
            ),
            TextField(
              controller: distance,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Road distance (m)'),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                final d = double.tryParse(distance.text);
                if (d == null || d <= 0) return;
                final ok = await runGuarded(dialogContext, () => repo.addLink(config.id, {'toIntersectionId': target.id, 'distanceM': d}));
                if (ok && dialogContext.mounted) Navigator.pop(dialogContext);
              },
              child: const Text('Add link'),
            ),
          ],
        ),
      ),
    );
    await onChanged();
  }
}

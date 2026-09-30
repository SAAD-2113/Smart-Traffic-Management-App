import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/units.dart';
import '../../core/utils/validators.dart';
import '../../data/repositories/manager_repository.dart';
import '../../widgets/common.dart';
import 'intersection_detail_screen.dart';
import 'live_controller.dart';
import 'manager_shell.dart';

class IntersectionsScreen extends StatelessWidget {
  const IntersectionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final live = context.watch<LiveController>();
    final items = live.intersections;
    return Scaffold(
      appBar: AppBar(title: const Text('Intersections'), actions: const [ConnectionIndicator()]),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final created = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => const NewIntersectionScreen()));
          if (created == true) live.refresh();
        },
        icon: const Icon(Icons.add_location_alt),
        label: const Text('Add intersection'),
      ),
      body: items.isEmpty
          ? const EmptyState(
              icon: Icons.traffic,
              title: 'No intersections yet',
              message: 'Add intersections, then their approaches and the links between them.')
          : RefreshIndicator(
              onRefresh: live.refresh,
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                itemCount: items.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, i) {
                  final n = items[i];
                  return Card(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => IntersectionDetailScreen(intersectionId: n.id))),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Row(children: [
                            Text(n.code, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                            const SizedBox(width: 10),
                            Expanded(child: Text(n.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                            CongestionBadge(n.congestionLevel, compact: true),
                          ]),
                          const SizedBox(height: 8),
                          Wrap(spacing: 8, runSpacing: 6, children: [
                            StatusChip(label: n.status, color: n.isActive ? StatusColors.ok : StatusColors.neutral),
                            StatusChip(label: n.controllerType, color: StatusColors.info),
                            StatusChip(
                                label: n.connected ? 'Controller connected' : 'No controller report',
                                color: n.connected ? StatusColors.ok : StatusColors.neutral,
                                icon: Icons.settings_input_antenna),
                            DataQualityChip(n.dataQuality),
                          ]),
                          const SizedBox(height: 10),
                          Wrap(spacing: 24, runSpacing: 6, children: [
                            _stat(context, 'Observed', '${n.observed.vehicleCount}'),
                            _stat(context, 'Estimated', Units.number(n.estimated.vehicleCount)),
                            _stat(context, 'Avg speed', Units.speed(n.observed.avgSpeedMps)),
                            _stat(context, 'Avg wait', n.calculated.avgWaitingTimeS == null ? '—' : '${n.calculated.avgWaitingTimeS!.toStringAsFixed(0)} s'),
                            _stat(context, 'Arriving 60 s', '${n.calculated.expectedArrivals60s}'),
                          ]),
                        ]),
                      ),
                    ),
                  );
                },
              ),
            ),
    );
  }

  Widget _stat(BuildContext context, String label, String value) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: Theme.of(context).textTheme.labelSmall),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
      ]);
}

/// Creates an intersection. Nothing assumes exactly four: any number can be added.
class NewIntersectionScreen extends StatefulWidget {
  const NewIntersectionScreen({super.key});

  @override
  State<NewIntersectionScreen> createState() => _NewIntersectionScreenState();
}

class _NewIntersectionScreenState extends State<NewIntersectionScreen> {
  final _form = GlobalKey<FormState>();
  final _code = TextEditingController();
  final _name = TextEditingController();
  final _lat = TextEditingController();
  final _lon = TextEditingController();
  final _radius = TextEditingController(text: '40');
  final _approachRadius = TextEditingController(text: '250');
  final _penetration = TextEditingController(text: '5');
  String _controller = 'FIXED';
  bool _fourApproaches = true;
  bool _busy = false;

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    final repo = context.read<ManagerRepository>();
    final ok = await runGuarded(context, () async {
      final created = await repo.createIntersection({
        'code': _code.text.trim().toUpperCase(),
        'name': _name.text.trim(),
        'latitude': double.parse(_lat.text),
        'longitude': double.parse(_lon.text),
        'radiusM': double.parse(_radius.text),
        'approachRadiusM': double.parse(_approachRadius.text),
        'controllerType': _controller,
        'assumedPenetrationRate': double.parse(_penetration.text) / 100,
      });
      if (_fourApproaches) {
        for (final (name, bearing) in [('Northbound', 0.0), ('Eastbound', 90.0), ('Southbound', 180.0), ('Westbound', 270.0)]) {
          await repo.addApproach(created.id, {'name': name, 'travelBearingDeg': bearing, 'zoneLengthM': 200});
        }
      }
    }, success: 'Intersection created.');
    if (mounted) setState(() => _busy = false);
    if (ok && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('New intersection')),
      body: Form(
        key: _form,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          TextFormField(
            controller: _code,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(labelText: 'Code', hintText: 'I5', helperText: 'Short, permanent identifier'),
            validator: (v) => RegExp(r'^[A-Z][A-Z0-9-]{0,15}$').hasMatch((v ?? '').trim().toUpperCase()) ? null : 'e.g. I5',
          ),
          const SizedBox(height: 12),
          TextFormField(controller: _name, decoration: const InputDecoration(labelText: 'Name'), validator: Validators.name),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: TextFormField(
                controller: _lat,
                keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                decoration: const InputDecoration(labelText: 'Latitude'),
                validator: (v) => Validators.number(v, min: -90, max: 90),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextFormField(
                controller: _lon,
                keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                decoration: const InputDecoration(labelText: 'Longitude'),
                validator: (v) => Validators.number(v, min: -180, max: 180),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: TextFormField(
                controller: _radius,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Core radius (m)'),
                validator: (v) => Validators.number(v, min: 10, max: 500),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextFormField(
                controller: _approachRadius,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Approach radius (m)'),
                validator: (v) {
                  final base = Validators.number(v, min: 20, max: 2000);
                  if (base != null) return base;
                  return double.parse(v!) <= (double.tryParse(_radius.text) ?? 0) ? 'Must exceed the core radius' : null;
                },
              ),
            ),
          ]),
          const SizedBox(height: 12),
          TextFormField(
            controller: _penetration,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
                labelText: 'Assumed share of vehicles using the app (%)',
                helperText: 'Used to estimate total traffic from app users. An assumption, shown as such.'),
            validator: (v) => Validators.number(v, min: 0.1, max: 100),
          ),
          const SizedBox(height: 12),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'FIXED', label: Text('Fixed time'), icon: Icon(Icons.timer)),
              ButtonSegment(value: 'ADAPTIVE', label: Text('Adaptive'), icon: Icon(Icons.auto_graph)),
            ],
            selected: {_controller},
            onSelectionChanged: (s) => setState(() => _controller = s.first),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Add four standard approaches'),
            subtitle: const Text('Northbound, Eastbound, Southbound, Westbound, 200 m zones'),
            value: _fourApproaches,
            onChanged: (v) => setState(() => _fourApproaches = v),
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: _busy ? null : _save, child: const Text('Create intersection')),
        ]),
      ),
    );
  }
}

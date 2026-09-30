import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/units.dart';
import '../../data/models/telemetry.dart';
import '../../data/models/vehicle.dart';
import '../../widgets/common.dart';
import 'live_controller.dart';
import 'manager_shell.dart';
import 'vehicle_detail_screen.dart';

enum _Filter { all, transmitting, emergency }

class VehiclesScreen extends StatefulWidget {
  const VehiclesScreen({super.key});

  @override
  State<VehiclesScreen> createState() => _VehiclesScreenState();
}

class _VehiclesScreenState extends State<VehiclesScreen> {
  _Filter _filter = _Filter.all;
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final live = context.watch<LiveController>();
    final vehicles = live.vehicles.where((v) {
      if (_query.isNotEmpty && !v.code.toLowerCase().contains(_query.toLowerCase())) return false;
      return switch (_filter) {
        _Filter.all => true,
        _Filter.transmitting => v.isTransmitting,
        _Filter.emergency => v.emergencyActive || isEmergencyType(v.vehicleType),
      };
    }).toList()
      ..sort((a, b) {
        if (a.emergencyActive != b.emergencyActive) return a.emergencyActive ? -1 : 1;
        return a.code.compareTo(b.code);
      });

    return Scaffold(
      appBar: AppBar(title: const Text('Vehicles'), actions: const [ConnectionIndicator()]),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: TextField(
            decoration: const InputDecoration(hintText: 'Search by Vehicle ID', prefixIcon: Icon(Icons.search), isDense: true),
            onChanged: (v) => setState(() => _query = v.trim()),
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(children: [
            for (final f in _Filter.values)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  label: Text(switch (f) {
                    _Filter.all => 'Active (${live.vehicles.length})',
                    _Filter.transmitting => 'Transmitting',
                    _Filter.emergency => 'Emergency',
                  }),
                  selected: _filter == f,
                  onSelected: (_) => setState(() => _filter = f),
                ),
              ),
            FilterChip(
              label: const Text('Show simulated'),
              selected: live.includeSimulated,
              onSelected: live.setIncludeSimulated,
            ),
          ]),
        ),
        Expanded(
          child: vehicles.isEmpty
              ? const EmptyState(
                  icon: Icons.directions_car_outlined,
                  title: 'No active vehicles',
                  message: 'Vehicles appear here while they are tracking or reported in the last 5 minutes.')
              : RefreshIndicator(
                  onRefresh: live.refresh,
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                    itemCount: vehicles.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, i) => _VehicleTile(v: vehicles[i]),
                  ),
                ),
        ),
      ]),
    );
  }
}

class _VehicleTile extends StatelessWidget {
  const _VehicleTile({required this.v});
  final LiveVehicle v;

  @override
  Widget build(BuildContext context) {
    final l = v.live;
    final (statusLabel, statusColor) = switch (v.trackingStatus) {
      'TRANSMITTING' => ('Transmitting', StatusColors.ok),
      'STALE' => ('No recent data', StatusColors.warning),
      _ => ('Not tracking', StatusColors.neutral),
    };
    return Card(
      child: ListTile(
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => VehicleDetailScreen(vehicleId: v.vehicleId))),
        leading: CircleAvatar(
          backgroundColor: (v.emergencyActive ? StatusColors.emergency : StatusColors.info).withValues(alpha: 0.15),
          child: Icon(
            v.emergencyActive ? Icons.emergency : (isEmergencyType(v.vehicleType) ? Icons.local_hospital : Icons.directions_car),
            color: v.emergencyActive ? StatusColors.emergency : StatusColors.info,
          ),
        ),
        title: Row(children: [
          Text(v.code, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(width: 6),
          if (v.isSimulated) const StatusChip(label: 'SIM', color: StatusColors.simulated),
          if (v.emergencyActive) ...[
            const SizedBox(width: 4),
            const StatusChip(label: 'EMERGENCY', color: StatusColors.emergency, filled: true),
          ],
        ]),
        subtitle: Text(
          '${vehicleTypeLabel(v.vehicleType)} · ${l == null ? 'no position' : Units.ago(l.recordedAt)}'
          '${l?.intersectionCode != null ? ' · near ${l!.intersectionCode}' : ''}',
        ),
        trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(v.trackingStatus == 'NOT_TRACKING' ? '—' : Units.speed(l?.speedMps),
              style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          StatusChip(label: statusLabel, color: statusColor),
        ]),
      ),
    );
  }
}

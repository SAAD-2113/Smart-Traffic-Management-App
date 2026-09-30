import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../core/config/app_config.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/units.dart';
import '../../data/models/telemetry.dart';
import '../../data/models/vehicle.dart';
import '../../data/repositories/manager_repository.dart';
import '../../widgets/common.dart';
import 'live_map_screen.dart';

/// Operational view of one vehicle. Shows no owner identity (privacy by design);
/// administrators can see ownership through the admin API only.
class VehicleDetailScreen extends StatefulWidget {
  const VehicleDetailScreen({super.key, required this.vehicleId});
  final String vehicleId;

  @override
  State<VehicleDetailScreen> createState() => _VehicleDetailScreenState();
}

class _VehicleDetailScreenState extends State<VehicleDetailScreen> {
  LiveVehicle? _vehicle;
  List<TrackPoint> _track = [];
  String? _status;
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final repo = context.read<ManagerRepository>();
    try {
      final results = await Future.wait([
        repo.liveVehicle(widget.vehicleId),
        repo.vehicleTrack(widget.vehicleId, minutes: 15),
        repo.managerVehicle(widget.vehicleId),
      ]);
      _vehicle = results[0] as LiveVehicle;
      _track = results[1] as List<TrackPoint>;
      _status = (results[2] as Map<String, dynamic>)['status'] as String;
      _error = null;
    } catch (e) {
      _error = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _setStatus(String status) async {
    final reason = await askReason(context,
        title: status == 'SUSPENDED' ? 'Suspend ${_vehicle!.code}?' : 'Reactivate ${_vehicle!.code}?',
        hint: 'Reason (recorded in the audit log)',
        action: status == 'SUSPENDED' ? 'Suspend' : 'Reactivate');
    if (reason == null || !mounted) return;
    final ok = await runGuarded(context, () => context.read<ManagerRepository>().setVehicleStatus(widget.vehicleId, status, reason),
        success: status == 'SUSPENDED' ? 'Vehicle suspended. Its data is excluded from now on.' : 'Vehicle reactivated.');
    if (ok) _load();
  }

  Future<void> _revoke() async {
    final reason = await askReason(context, title: 'Revoke emergency authorisation?', hint: 'Reason', action: 'Revoke');
    if (reason == null || !mounted) return;
    final ok = await runGuarded(context, () => context.read<ManagerRepository>().revoke(widget.vehicleId, reason),
        success: 'Authorisation revoked. Any active emergency has ended.');
    if (ok) _load();
  }

  @override
  Widget build(BuildContext context) {
    final v = _vehicle;
    return Scaffold(
      appBar: AppBar(title: Text(v?.code ?? 'Vehicle'), actions: [
        IconButton(tooltip: 'Refresh', onPressed: _load, icon: const Icon(Icons.refresh)),
      ]),
      body: _loading
          ? const LoadingView()
          : _error != null
              ? ErrorView(message: '$_error', onRetry: _load)
              : ListView(padding: const EdgeInsets.all(16), children: [
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    StatusChip(label: vehicleTypeLabel(v!.vehicleType), color: StatusColors.info),
                    StatusChip(label: v.trackingStatus.replaceAll('_', ' '), color: v.isTransmitting ? StatusColors.ok : StatusColors.neutral),
                    if (v.emergencyActive) const StatusChip(label: 'EMERGENCY ACTIVE', color: StatusColors.emergency, filled: true),
                    if (v.emergencyAuthorized) const StatusChip(label: 'Emergency authorised', color: StatusColors.ok),
                    if (v.isSimulated) const StatusChip(label: 'Simulated', color: StatusColors.simulated),
                    if (_status == 'SUSPENDED') const StatusChip(label: 'Suspended', color: StatusColors.danger),
                  ]),
                  const SectionHeader('Latest telemetry'),
                  if (v.live == null)
                    const Card(child: Padding(padding: EdgeInsets.all(16), child: Text('This vehicle has not reported a position yet.')))
                  else
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(children: [
                          InfoRow('Latitude', Units.coordinate(v.live!.lat)),
                          InfoRow('Longitude', Units.coordinate(v.live!.lon)),
                          InfoRow('Speed', Units.speed(v.live!.speedMps, decimals: 1)),
                          InfoRow('Heading', Units.heading(v.live!.headingDeg)),
                          InfoRow('GPS accuracy', '± ${v.live!.accuracyM.toStringAsFixed(0)} m (${v.live!.gpsQuality.toLowerCase()})'),
                          InfoRow('Used for traffic metrics', v.live!.usable ? 'Yes' : 'No (poor accuracy or mock location)'),
                          InfoRow('Intersection', v.live!.intersectionCode ?? '—'),
                          InfoRow('Approach / zone', '${v.live!.approachName ?? '—'} / ${v.live!.zone ?? '—'}'),
                          InfoRow('Recorded', '${Units.dateTime(v.live!.recordedAt)} (${Units.ago(v.live!.recordedAt)})'),
                          InfoRow('Source', v.live!.source),
                        ]),
                      ),
                    ),
                  if (_track.isNotEmpty) ...[
                    const SectionHeader('Last 15 minutes', subtitle: 'Recorded track'),
                    SizedBox(height: 260, child: ClipRRect(borderRadius: BorderRadius.circular(14), child: _TrackMap(track: _track, vehicle: v))),
                  ],
                  const SectionHeader('Actions'),
                  if (_status == 'SUSPENDED')
                    OutlinedButton.icon(onPressed: () => _setStatus('ACTIVE'), icon: const Icon(Icons.play_arrow), label: const Text('Reactivate vehicle'))
                  else
                    OutlinedButton.icon(
                      onPressed: () => _setStatus('SUSPENDED'),
                      icon: const Icon(Icons.block),
                      label: const Text('Suspend vehicle (exclude its data)'),
                    ),
                  if (v.emergencyAuthorized) ...[
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(foregroundColor: StatusColors.danger),
                      onPressed: _revoke,
                      icon: const Icon(Icons.gpp_bad_outlined),
                      label: const Text('Revoke emergency authorisation'),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Text('Managers see operational data only. Owner details are not shown.',
                      style: Theme.of(context).textTheme.bodySmall),
                ]),
    );
  }
}

class _TrackMap extends StatelessWidget {
  const _TrackMap({required this.track, required this.vehicle});
  final List<TrackPoint> track;
  final LiveVehicle vehicle;

  @override
  Widget build(BuildContext context) {
    final points = [for (final p in track) LatLng(p.lat, p.lon)];
    final bounds = LatLngBounds.fromPoints(points);
    return FlutterMap(
      options: MapOptions(
        initialCameraFit: points.length > 1
            ? CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(30), maxZoom: 17)
            : CameraFit.coordinates(coordinates: points, maxZoom: 16),
      ),
      children: [
        TileLayer(urlTemplate: context.read<AppConfig>().tileUrl, userAgentPackageName: 'com.fyp.smart_traffic'),
        PolylineLayer(polylines: [Polyline(points: points, color: ChartColors.primary(context), strokeWidth: 3)]),
        if (vehicle.live != null)
          MarkerLayer(markers: [
            Marker(point: LatLng(vehicle.live!.lat, vehicle.live!.lon), width: 34, height: 34, child: VehicleMarker(vehicle)),
          ]),
      ],
    );
  }
}

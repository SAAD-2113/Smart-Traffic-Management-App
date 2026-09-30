import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../core/config/app_config.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/units.dart';
import '../../data/models/telemetry.dart';
import '../../data/models/traffic.dart';
import '../../data/models/vehicle.dart';
import '../../widgets/common.dart';
import 'intersection_detail_screen.dart';
import 'live_controller.dart';
import 'manager_shell.dart';
import 'vehicle_detail_screen.dart';

class LiveMapScreen extends StatefulWidget {
  const LiveMapScreen({super.key});

  @override
  State<LiveMapScreen> createState() => _LiveMapScreenState();
}

class _LiveMapScreenState extends State<LiveMapScreen> {
  /// Above this many vehicles, individual markers are only drawn when zoomed in.
  static const crowdedThreshold = 150;
  static const crowdedMinZoom = 15.0;

  final _map = MapController();
  bool _showVehicles = true;
  bool _showZones = true;
  bool _emergencyOnly = false;
  double _zoom = 15;
  bool _fitted = false;

  void _fit(List<IntersectionTraffic> nodes) {
    if (_fitted || nodes.isEmpty) return;
    _fitted = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (nodes.length == 1) {
        _map.move(LatLng(nodes.first.latitude, nodes.first.longitude), 16);
        return;
      }
      // Include each approach zone, not just the centre points.
      final points = <LatLng>[];
      for (final n in nodes) {
        final dLat = n.approachRadiusM / 111320.0;
        final dLon = n.approachRadiusM / (111320.0 * math.cos(n.latitude * math.pi / 180));
        points
          ..add(LatLng(n.latitude - dLat, n.longitude - dLon))
          ..add(LatLng(n.latitude + dLat, n.longitude + dLon));
      }
      _map.fitCamera(CameraFit.bounds(bounds: LatLngBounds.fromPoints(points), padding: const EdgeInsets.fromLTRB(24, 64, 24, 24)));
    });
  }

  @override
  Widget build(BuildContext context) {
    final live = context.watch<LiveController>();
    final config = context.watch<AppConfig>();
    final nodes = live.intersections.where((i) => i.isActive).toList();
    _fit(nodes);
    final center = nodes.isEmpty
        ? const LatLng(31.5204, 74.3587)
        : LatLng(nodes.map((n) => n.latitude).reduce((a, b) => a + b) / nodes.length,
            nodes.map((n) => n.longitude).reduce((a, b) => a + b) / nodes.length);

    final vehicles = live.vehicles.where((v) => v.live != null && v.trackingStatus != 'NOT_TRACKING').toList();
    final crowded = vehicles.length > crowdedThreshold && _zoom < crowdedMinZoom;
    final visibleVehicles = vehicles
        .where((v) => _emergencyOnly ? v.emergencyActive : (_showVehicles && (!crowded || v.emergencyActive)))
        .toList()
      ..sort((a, b) => (a.emergencyActive ? 1 : 0).compareTo(b.emergencyActive ? 1 : 0)); // emergencies on top
    final byCode = {for (final n in nodes) n.code: n};

    return Scaffold(
      appBar: AppBar(title: const Text('Live map'), actions: [
        IconButton(tooltip: 'Legend', icon: const Icon(Icons.info_outline), onPressed: () => _legend(context)),
        const ConnectionIndicator(),
      ]),
      body: Stack(children: [
        FlutterMap(
          mapController: _map,
          options: MapOptions(
            initialCenter: center,
            initialZoom: 15,
            minZoom: 3,
            maxZoom: 19,
            onPositionChanged: (camera, _) {
              if ((camera.zoom - _zoom).abs() > 0.25) setState(() => _zoom = camera.zoom);
            },
          ),
          children: [
            TileLayer(urlTemplate: config.tileUrl, userAgentPackageName: 'com.fyp.smart_traffic', maxZoom: 19),
            if (_showZones)
              CircleLayer(circles: [
                for (final n in nodes) ...[
                  CircleMarker(
                    point: LatLng(n.latitude, n.longitude),
                    radius: n.approachRadiusM,
                    useRadiusInMeter: true,
                    color: StatusColors.congestion(n.congestionLevel).withValues(alpha: 0.10),
                    borderColor: StatusColors.congestion(n.congestionLevel).withValues(alpha: 0.6),
                    borderStrokeWidth: 1.5,
                  ),
                  CircleMarker(
                    point: LatLng(n.latitude, n.longitude),
                    radius: n.radiusM,
                    useRadiusInMeter: true,
                    color: StatusColors.congestion(n.congestionLevel).withValues(alpha: 0.18),
                  ),
                ],
              ]),
            PolylineLayer(polylines: [
              for (final n in nodes)
                for (final d in n.downstream)
                  if (byCode[d.toCode] != null && n.code.compareTo(d.toCode) < 0)
                    Polyline(
                      points: [LatLng(n.latitude, n.longitude), LatLng(byCode[d.toCode]!.latitude, byCode[d.toCode]!.longitude)],
                      color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.35),
                      strokeWidth: 3,
                      pattern: StrokePattern.dashed(segments: const [10, 6]),
                    ),
            ]),
            MarkerLayer(markers: [
              for (final n in nodes)
                Marker(
                  point: LatLng(n.latitude, n.longitude),
                  width: 64,
                  height: 64,
                  child: GestureDetector(onTap: () => _intersectionSheet(context, n), child: _IntersectionMarker(n)),
                ),
            ]),
            MarkerLayer(markers: [
              for (final v in visibleVehicles)
                Marker(
                  point: LatLng(v.live!.lat, v.live!.lon),
                  width: v.emergencyActive ? 44 : 30,
                  height: v.emergencyActive ? 44 : 30,
                  child: GestureDetector(onTap: () => _vehicleSheet(context, v), child: VehicleMarker(v)),
                ),
            ]),
            const RichAttributionWidget(attributions: [TextSourceAttribution('OpenStreetMap contributors')]),
          ],
        ),
        Positioned(
          left: 8,
          right: 8,
          top: 8,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              _chip('Vehicles', _showVehicles, (v) => setState(() => _showVehicles = v)),
              _chip('Emergency only', _emergencyOnly, (v) => setState(() => _emergencyOnly = v)),
              _chip('Zones', _showZones, (v) => setState(() => _showZones = v)),
              _chip('Simulated', live.includeSimulated, live.setIncludeSimulated),
            ]),
          ),
        ),
        if (crowded)
          Positioned(
            bottom: 24,
            left: 0,
            right: 0,
            child: Center(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  child: Text('${vehicles.length} vehicles · zoom in to see each one'),
                ),
              ),
            ),
          ),
      ]),
    );
  }

  Widget _chip(String label, bool selected, ValueChanged<bool> onChanged) => Padding(
        padding: const EdgeInsets.only(right: 6),
        child: FilterChip(
          label: Text(label),
          selected: selected,
          onSelected: onChanged,
          backgroundColor: Theme.of(context).colorScheme.surface,
          elevation: 2,
        ),
      );

  void _vehicleSheet(BuildContext context, LiveVehicle v) {
    final l = v.live!;
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text(v.code, style: Theme.of(sheetContext).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(width: 8),
              if (v.emergencyActive) const StatusChip(label: 'EMERGENCY', color: StatusColors.emergency, filled: true),
              if (v.isSimulated) const StatusChip(label: 'SIM', color: StatusColors.simulated),
            ]),
            Text(vehicleTypeLabel(v.vehicleType)),
            const SizedBox(height: 8),
            InfoRow('Speed', Units.speed(l.speedMps)),
            InfoRow('Heading', Units.heading(l.headingDeg)),
            InfoRow('Position', '${Units.coordinate(l.lat)}, ${Units.coordinate(l.lon)}'),
            InfoRow('Near', l.intersectionCode == null ? '—' : '${l.intersectionCode} ${l.approachName ?? ''} (${l.zone?.toLowerCase().replaceAll('_', ' ')})'),
            InfoRow('Last update', '${Units.ago(l.recordedAt)} · GPS ${l.gpsQuality.toLowerCase()}'),
            const SizedBox(height: 8),
            FilledButton.tonal(
              onPressed: () {
                Navigator.pop(sheetContext);
                Navigator.push(context, MaterialPageRoute(builder: (_) => VehicleDetailScreen(vehicleId: v.vehicleId)));
              },
              child: const Text('Vehicle details'),
            ),
          ]),
        ),
      ),
    );
  }

  void _intersectionSheet(BuildContext context, IntersectionTraffic n) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text(n.code, style: Theme.of(sheetContext).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(width: 8),
              CongestionBadge(n.congestionLevel, compact: true),
              const SizedBox(width: 6),
              DataQualityChip(n.dataQuality),
            ]),
            Text(n.name),
            const SizedBox(height: 8),
            InfoRow('Vehicles observed', '${n.observed.vehicleCount} (${n.observed.stoppedCount} stopped)'),
            InfoRow('Estimated vehicles', Units.number(n.estimated.vehicleCount, decimals: 0)),
            InfoRow('Average speed', Units.speed(n.observed.avgSpeedMps)),
            InfoRow('Signal', n.signal == null ? 'No report' : '${n.signal!.phaseName} · ${n.signal!.state}'),
            const SizedBox(height: 8),
            FilledButton.tonal(
              onPressed: () {
                Navigator.pop(sheetContext);
                Navigator.push(context, MaterialPageRoute(builder: (_) => IntersectionDetailScreen(intersectionId: n.id)));
              },
              child: const Text('Intersection details'),
            ),
          ]),
        ),
      ),
    );
  }

  void _legend(BuildContext context) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Map legend'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          _legendRow(const Icon(Icons.navigation, color: StatusColors.info), 'Vehicle (arrow shows heading)'),
          _legendRow(const Icon(Icons.navigation, color: StatusColors.simulated), 'Simulated vehicle'),
          _legendRow(const Icon(Icons.emergency, color: StatusColors.emergency), 'Emergency vehicle (active)'),
          _legendRow(const Icon(Icons.circle, color: StatusColors.neutral), 'No recent data (stale)'),
          _legendRow(const Icon(Icons.traffic, color: StatusColors.ok), 'Intersection; ring = approach zone'),
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final l in ['LOW', 'MODERATE', 'HIGH', 'SEVERE', 'UNKNOWN']) CongestionBadge(l, compact: true),
          ]),
        ]),
        actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Close'))],
      ),
    );
  }

  Widget _legendRow(Widget icon, String text) =>
      Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Row(children: [icon, const SizedBox(width: 10), Expanded(child: Text(text))]));
}

class _IntersectionMarker extends StatelessWidget {
  const _IntersectionMarker(this.n);
  final IntersectionTraffic n;

  @override
  Widget build(BuildContext context) {
    final color = StatusColors.congestion(n.congestionLevel);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          shape: BoxShape.circle,
          border: Border.all(color: color, width: 3),
          boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black26)],
        ),
        child: Icon(Icons.traffic, size: 18, color: color),
      ),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(6)),
        child: Text(n.code, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800)),
      ),
    ]);
  }
}

/// Vehicle marker: arrow rotated to the heading; emergency vehicles are larger, red and ringed.
class VehicleMarker extends StatelessWidget {
  const VehicleMarker(this.v, {super.key});
  final LiveVehicle v;

  @override
  Widget build(BuildContext context) {
    final stale = !v.isTransmitting;
    if (v.emergencyActive) {
      return Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: StatusColors.emergency.withValues(alpha: 0.2),
          border: Border.all(color: StatusColors.emergency, width: 2),
        ),
        child: const Icon(Icons.emergency, color: StatusColors.emergency, size: 26),
      );
    }
    final color = stale ? StatusColors.neutral : (v.isSimulated ? StatusColors.simulated : StatusColors.info);
    final heading = v.live?.headingDeg;
    return Opacity(
      opacity: stale ? 0.6 : 1,
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Theme.of(context).colorScheme.surface,
          boxShadow: const [BoxShadow(blurRadius: 3, color: Colors.black26)],
        ),
        child: heading == null
            ? Icon(Icons.circle, color: color, size: 16)
            : Transform.rotate(angle: heading * math.pi / 180, child: Icon(Icons.navigation, color: color, size: 22)),
      ),
    );
  }
}

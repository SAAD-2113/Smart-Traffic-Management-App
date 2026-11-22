import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:v2i_core/v2i_core.dart' as v2i;

import '../../core/network/api_exception.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/telemetry.dart';
import '../../data/models/vehicle.dart';
import '../../data/repositories/vehicle_repository.dart';
import '../../hardware/ui/hw_style.dart' show HwCard, HwChip;
import '../../widgets/common.dart';
import '../data/v2i_models.dart';
import '../data/v2i_repository.dart';
import '../vehicle/digital_vehicle.dart';
import 'vehicle_screen.dart';
import 'widgets.dart';

/// Driver: this phone is a vehicle with the id the server assigned to the account.
class DriverHome extends StatefulWidget {
  const DriverHome({super.key, required this.me, required this.onChanged});
  final V2IMe me;
  final VoidCallback onChanged;

  @override
  State<DriverHome> createState() => _DriverHomeState();
}

class _DriverHomeState extends State<DriverHome> {
  final _code = TextEditingController();
  late Future<List<JoinedSession>> _joined = context.read<V2IRepository>().joined();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    final code = _code.text.trim();
    if (code.length < 4) {
      setState(() { _error = 'Enter the code shown on the intersection phone.'; });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final s = await context.read<V2IRepository>().join(code);
      if (!mounted) return;
      _code.clear();
      setState(() { _joined = context.read<V2IRepository>().joined(); });
      await Navigator.push(context, MaterialPageRoute(builder: (_) => VehicleSetupScreen(session: s)));
    } on ApiException catch (e) {
      setState(() { _error = e.message; });
    }
    if (mounted) setState(() { _busy = false; });
  }

  Future<void> _requestEmergency() async {
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Request emergency-vehicle status'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('An admin decides. Until then this phone drives as a normal vehicle ("ty":0).'),
          TextField(controller: reason, maxLength: 200, decoration: const InputDecoration(labelText: 'Why (e.g. ambulance unit)')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Send request')),
        ],
      ),
    );
    if (ok == true && mounted) {
      try {
        await context.read<V2IRepository>().requestEmergency(reason.text.trim());
        widget.onChanged();
      } on ApiException catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
    reason.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final me = widget.me;
    final status = me.emergencyStatus ?? 'NONE';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      HwCard(
        title: 'Your vehicle',
        icon: Icons.directions_car,
        trailing: me.emergency ? emergencyChip : null,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(spacing: 24, runSpacing: 10, children: [
            Figure('V2I vehicle id', '${me.vehicleId}'),
            Figure('Emergency status', switch (status) {
              'APPROVED' => 'Approved',
              'REQUESTED' => 'Requested',
              'REJECTED' => 'Rejected',
              'REVOKED' => 'Withdrawn',
              _ => 'Normal vehicle',
            }),
          ]),
          const SizedBox(height: 8),
          Text('The id and the emergency status are stored on the server; the phone cannot choose them.',
              style: Theme.of(context).textTheme.bodySmall),
          if (status == 'NONE' || status == 'REJECTED' || status == 'REVOKED')
            TextButton.icon(
              key: const ValueKey('request-emergency'),
              onPressed: _requestEmergency,
              icon: const Icon(Icons.emergency_outlined),
              label: const Text('Request emergency-vehicle status'),
            ),
        ]),
      ),
      const SizedBox(height: 14),
      HwCard(
        title: 'Join an intersection',
        icon: Icons.login,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: TextField(
                key: const ValueKey('join-code'),
                controller: _code,
                textCapitalization: TextCapitalization.characters,
                maxLength: 8,
                decoration: InputDecoration(labelText: 'Join code', errorText: _error, counterText: ''),
                onSubmitted: (_) => _join(),
              ),
            ),
            const SizedBox(width: 10),
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: FilledButton(key: const ValueKey('join'), onPressed: _busy ? null : _join, child: const Text('Join')),
            ),
          ]),
          const SizedBox(height: 6),
          Text('The code is on the intersection phone (tap "Code" in its header).', style: Theme.of(context).textTheme.bodySmall),
        ]),
      ),
      const SizedBox(height: 14),
      FutureBuilder<List<JoinedSession>>(
        future: _joined,
        builder: (context, snap) {
          final list = snap.data ?? const <JoinedSession>[];
          if (list.isEmpty) return const SizedBox.shrink();
          return HwCard(
            title: 'Joined sessions',
            icon: Icons.history,
            child: Column(children: [
              for (final s in list)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.traffic),
                  title: Text(s.name),
                  subtitle: Text(s.intersectionOnline ? 'Intersection running' : 'Intersection not running now'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => VehicleSetupScreen(session: s))),
                ),
            ]),
          );
        },
      ),
    ]);
  }
}

/// Choose where the position comes from, then drive.
class VehicleSetupScreen extends StatefulWidget {
  const VehicleSetupScreen({super.key, required this.session});
  final JoinedSession session;

  @override
  State<VehicleSetupScreen> createState() => _VehicleSetupScreenState();
}

enum _Kind { simulated, gps, replay }

class _VehicleSetupScreenState extends State<VehicleSetupScreen> {
  _Kind _kind = _Kind.simulated;
  int _arm = 0, _slot = 0;
  late double _dist = widget.session.emergency ? 140 : 100;
  late double _kmh = widget.session.emergency ? 50 : 30;
  List<TripPoint>? _points;
  String? _tripName;
  String? _replayNote;

  void _start() {
    final DriveSource source = switch (_kind) {
      _Kind.simulated => SimulatedDrive(arm: _arm, slot: _slot, startDist: _dist, kmh: _kmh),
      _Kind.gps => const LiveGpsDrive(),
      _Kind.replay => ReplayDrive(_points!, name: _tripName ?? 'Recorded trip'),
    };
    Navigator.push(context, MaterialPageRoute(builder: (_) => VehicleScreen(session: widget.session, source: source)));
  }

  Future<void> _pickTrip() async {
    final picked = await Navigator.push<(String, List<TripPoint>)>(
        context, MaterialPageRoute(builder: (_) => const TripPickScreen()));
    if (picked == null) return;
    final (name, points) = picked;
    final s = widget.session;
    final geo = v2i.Geometry(centerLat: s.centerLat, centerLon: s.centerLon);
    var closest = double.infinity;
    for (final p in points) {
      final (x, y) = geo.latlonToXY(p.lat, p.lon);
      closest = math.min(closest, math.sqrt(x * x + y * y));
    }
    setState(() {
      _points = points;
      _tripName = name;
      _replayNote = points.isEmpty
          ? 'This trip has no recorded points.'
          : '${points.length} points over ${points.last.t.toStringAsFixed(0)} s. Closest to the junction centre: '
              '${closest.toStringAsFixed(0)} m${closest > v2i.DETECT_RADIUS_M ? ' (outside the ${v2i.DETECT_RADIUS_M.toStringAsFixed(0)} m detection range: '
                  'the intersection will ignore it)' : ''}.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.session;
    final theme = Theme.of(context);
    final canStart = _kind != _Kind.replay || (_points?.isNotEmpty ?? false);
    return Scaffold(
      appBar: AppBar(title: Text(s.name)),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Wrap(spacing: 8, runSpacing: 8, children: [
          HwChip(label: 'Vehicle ${s.vehicleId}', color: StatusColors.info, icon: Icons.directions_car),
          if (s.emergency) emergencyChip,
        ]),
        const SizedBox(height: 14),
        SegmentedButton<_Kind>(
          key: const ValueKey('drive-source'),
          segments: const [
            ButtonSegment(value: _Kind.simulated, label: Text('Simulated'), icon: Icon(Icons.smart_toy_outlined)),
            ButtonSegment(value: _Kind.gps, label: Text('Live GPS'), icon: Icon(Icons.gps_fixed)),
            ButtonSegment(value: _Kind.replay, label: Text('My trip'), icon: Icon(Icons.replay)),
          ],
          selected: {_kind},
          onSelectionChanged: (k) => setState(() => _kind = k.first),
        ),
        const SizedBox(height: 14),
        switch (_kind) {
          _Kind.simulated => HwCard(
              title: 'Simulated drive (firmware motion simulation)',
              icon: Icons.smart_toy_outlined,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('Approach arm', style: theme.textTheme.labelLarge),
                SegmentedButton<int>(
                  key: const ValueKey('arm'),
                  segments: [for (var i = 0; i < 4; i++) ButtonSegment(value: i, label: Text(v2i.LANE_NAME[i]))],
                  selected: {_arm},
                  onSelectionChanged: (a) => setState(() => _arm = a.first),
                ),
                const SizedBox(height: 10),
                Text('Queue position: ${_slot == 0 ? 'front' : '${_slot + 1}th'} (stops ${(v2i.STOP_LINE_M + _slot * v2i.QUEUE_SPACING_M).toStringAsFixed(0)} m from the centre on red)',
                    style: theme.textTheme.labelLarge),
                Slider(value: _slot.toDouble(), min: 0, max: 2, divisions: 2, onChanged: (v) => setState(() => _slot = v.round())),
                Text('Start ${_dist.toStringAsFixed(0)} m out', style: theme.textTheme.labelLarge),
                Slider(value: _dist, min: 60, max: 145, divisions: 17, onChanged: (v) => setState(() => _dist = v)),
                Text('Cruise ${_kmh.toStringAsFixed(0)} km/h', style: theme.textTheme.labelLarge),
                Slider(value: _kmh, min: 10, max: 60, divisions: 10, onChanged: (v) => setState(() => _kmh = v)),
                Text('Obeys the ACK like the firmware\'s vehicle: brakes for red, never passes the stop line on red, '
                    'restarts the trip 15 s after leaving.',
                    style: theme.textTheme.bodySmall),
              ]),
            ),
          _Kind.gps => const HwCard(
              title: 'Live GPS',
              icon: Icons.gps_fixed,
              child: Text('The phone sends its GPS position, speed and (when moving) heading twice a second. The lane is '
                  'decided by the intersection from these alone; no test lane is sent. Location permission is needed, '
                  'and the phone must be within 150 m of the junction centre to be counted.'),
            ),
          _Kind.replay => HwCard(
              title: 'Replay one of my trips',
              icon: Icons.replay,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(_tripName ?? 'No trip chosen.'),
                if (_replayNote != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(_replayNote!)),
                const SizedBox(height: 8),
                OutlinedButton.icon(onPressed: _pickTrip, icon: const Icon(Icons.list), label: const Text('Choose a recorded trip')),
                const SizedBox(height: 6),
                Text('Points are sent at their recorded times; between two points the last one is repeated (no '
                    'invented positions).',
                    style: theme.textTheme.bodySmall),
              ]),
            ),
        },
        const SizedBox(height: 18),
        FilledButton.icon(
          key: const ValueKey('start-drive'),
          onPressed: canStart ? _start : null,
          icon: const Icon(Icons.play_arrow),
          label: const Text('Start'),
        ),
      ]),
    );
  }
}

/// The driver's own vehicles and recorded trips (Software System recordings).
class TripPickScreen extends StatefulWidget {
  const TripPickScreen({super.key});

  @override
  State<TripPickScreen> createState() => _TripPickScreenState();
}

class _TripPickScreenState extends State<TripPickScreen> {
  late final Future<List<(OwnerVehicle, List<TrackingSession>)>> _data = _load();

  Future<List<(OwnerVehicle, List<TrackingSession>)>> _load() async {
    final repo = context.read<VehicleRepository>();
    final vehicles = await repo.myVehicles();
    return [for (final v in vehicles) (v, await repo.sessions(v.id))];
  }

  Future<void> _choose(OwnerVehicle v, TrackingSession t) async {
    try {
      final points = await context.read<V2IRepository>().tripPoints(v.id, t.id);
      if (mounted) Navigator.pop(context, ('${v.displayName}, ${t.startedAt.toLocal().toString().substring(0, 16)}', points));
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Recorded trips')),
      body: FutureBuilder(
        future: _data,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const LoadingView();
          if (snap.hasError) return ErrorView(message: '${snap.error}');
          final rows = [for (final (v, trips) in snap.data!) for (final t in trips) (v, t)];
          if (rows.isEmpty) {
            return const EmptyState(
                icon: Icons.route, title: 'No recorded trips', message: 'Trips recorded in the Software System appear here.');
          }
          return ListView(children: [
            for (final (v, t) in rows)
              ListTile(
                leading: const Icon(Icons.route),
                title: Text('${v.displayName} · ${t.startedAt.toLocal().toString().substring(0, 16)}'),
                subtitle: Text('${t.packetCount} points · ${(t.distanceM / 1000).toStringAsFixed(2)} km'),
                onTap: () => _choose(v, t),
              ),
          ]);
        },
      ),
    );
  }
}

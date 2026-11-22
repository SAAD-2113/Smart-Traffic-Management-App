import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:v2i_core/v2i_core.dart' as v2i;

import '../../core/config/app_config.dart';
import '../../core/network/api_exception.dart';
import '../../core/theme/app_theme.dart';
import '../../hardware/ui/hw_style.dart' show HwCard, HwChip;
import '../../services/location_service.dart';
import '../../widgets/common.dart';
import '../data/v2i_models.dart';
import '../data/v2i_repository.dart';
import 'intersection_screen.dart';
import 'widgets.dart';

/// ADMIN / MANAGER: host a digital intersection (this phone runs the controller).
class HostHome extends StatefulWidget {
  const HostHome({super.key, required this.me});
  final V2IMe me;

  @override
  State<HostHome> createState() => _HostHomeState();
}

class _HostHomeState extends State<HostHome> {
  late Future<List<HostedSession>> _sessions = context.read<V2IRepository>().mySessions();

  void _reload() => setState(() { _sessions = context.read<V2IRepository>().mySessions(); });

  Future<void> _open(HostedSession s) async {
    final options = await showModalBottomSheet<RunOptions>(context: context, showDragHandle: true, builder: (_) => const _RunSheet());
    if (options == null || !mounted) return;
    await Navigator.push(context, MaterialPageRoute(builder: (_) => IntersectionScreen(session: s, options: options)));
    if (mounted) _reload();
  }

  Future<void> _close(HostedSession s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Close the session?'),
        content: const Text('Vehicles are disconnected and the join code stops working.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Close session')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await context.read<V2IRepository>().closeSession(s.id);
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const MessageBanner(
        icon: Icons.info_outline,
        color: StatusColors.info,
        text: 'This phone becomes the intersection: it runs the firmware v3 controller (the same code as the ESP32, '
            'ported to Dart) and is the only authority for the signals. Drivers join with the code and send their '
            'position twice a second; each gets an ACK with its signal.',
      ),
      const SizedBox(height: 14),
      FutureBuilder<List<HostedSession>>(
        future: _sessions,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const LoadingView(label: 'Loading sessions…');
          if (snap.hasError) {
            return ErrorView(message: snap.error is ApiException ? (snap.error as ApiException).message : '${snap.error}', onRetry: _reload);
          }
          final open = snap.data!.where((s) => s.isOpen).toList();
          if (open.isEmpty) return _CreateSession(onCreated: _open);
          return Column(children: [for (final s in open) _SessionCard(session: s, onOpen: () => _open(s), onClose: () => _close(s))]);
        },
      ),
      if (widget.me.role == 'ADMIN') ...[const SizedBox(height: 14), const EmergencyApprovals()],
    ]);
  }
}

/// How vehicles reach this intersection.
class _RunSheet extends StatefulWidget {
  const _RunSheet();

  @override
  State<_RunSheet> createState() => _RunSheetState();
}

class _RunSheetState extends State<_RunSheet> {
  bool _cloud = true, _lan = false, _lanEmergency = false;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('How vehicles connect', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          CheckboxListTile(
            key: const ValueKey('run-cloud'),
            value: _cloud,
            onChanged: (v) => setState(() => _cloud = v ?? false),
            title: const Text('Cloud relay'),
            subtitle: const Text('Drivers join with the code, over the internet (the server checks accounts and emergency status)'),
          ),
          CheckboxListTile(
            key: const ValueKey('run-lan'),
            value: _lan,
            onChanged: (v) => setState(() => _lan = v ?? false),
            title: const Text('LAN on this phone'),
            subtitle: const Text('Like the ESP32: HTTP 8080, WebSocket 8081, UDP 4210 on this phone\'s Wi-Fi or hotspot; '
                'Hardware mode on other phones can show it'),
          ),
          if (_lan)
            SwitchListTile(
              key: const ValueKey('run-lan-emergency'),
              value: _lanEmergency,
              onChanged: (v) => setState(() => _lanEmergency = v),
              title: const Text('Accept emergency packets over the LAN'),
              subtitle: const Text('No server checks the account on the LAN; the ESP32 prototype accepts them from anyone'),
            ),
          const SizedBox(height: 8),
          FilledButton.icon(
            key: const ValueKey('run-start'),
            onPressed: _cloud || _lan
                ? () => Navigator.pop(context, RunOptions(cloud: _cloud, lan: _lan, lanEmergency: _lanEmergency))
                : null,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Run'),
          ),
        ]),
      ),
    );
  }
}

class _SessionCard extends StatelessWidget {
  const _SessionCard({required this.session, required this.onOpen, required this.onClose});
  final HostedSession session;
  final VoidCallback onOpen;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final s = session;
    return HwCard(
      key: ValueKey('session-${s.id}'),
      title: s.name,
      icon: Icons.traffic,
      trailing: HwChip(label: 'OPEN', color: StatusColors.ok),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 24, runSpacing: 12, children: [
          Figure('Join code', s.joinCode),
          Figure('Centre', '${s.centerLat.toStringAsFixed(6)}, ${s.centerLon.toStringAsFixed(6)}'),
          Figure('Joined vehicles', '${s.members}'),
          Figure('Online now', '${s.onlineVehicles}'),
        ]),
        const SizedBox(height: 14),
        Wrap(spacing: 10, runSpacing: 10, children: [
          FilledButton.icon(
              key: const ValueKey('open-intersection'), onPressed: onOpen, icon: const Icon(Icons.play_arrow), label: const Text('Run the intersection')),
          OutlinedButton.icon(
              onPressed: () => showJoinCode(context, s.name, s.joinCode), icon: const Icon(Icons.qr_code_2), label: const Text('Join code')),
          TextButton.icon(onPressed: onClose, icon: const Icon(Icons.close), label: const Text('Close session')),
        ]),
      ]),
    );
  }
}

class _CreateSession extends StatefulWidget {
  const _CreateSession({required this.onCreated});
  final Future<void> Function(HostedSession) onCreated;

  @override
  State<_CreateSession> createState() => _CreateSessionState();
}

class _CreateSessionState extends State<_CreateSession> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController(text: 'Junction 1');
  // The firmware's junction centre (v2i_common.h) until the host picks another one.
  final _lat = TextEditingController(text: v2i.CENTER_LAT.toStringAsFixed(6));
  final _lon = TextEditingController(text: v2i.CENTER_LON.toStringAsFixed(6));
  bool _busy = false;
  String? _note;

  @override
  void dispose() {
    _name.dispose();
    _lat.dispose();
    _lon.dispose();
    super.dispose();
  }

  Future<void> _useMyLocation() async {
    setState(() { _busy = true; });
    try {
      final p = await context.read<LocationService>().currentPosition();
      if (p == null) {
        _note = 'Location is not available (permission or GPS off).';
      } else {
        _lat.text = p.lat.toStringAsFixed(6);
        _lon.text = p.lon.toStringAsFixed(6);
        _note = 'Your position, ±${p.accuracyM.toStringAsFixed(0)} m.';
      }
    } catch (e) {
      _note = 'Location failed: $e';
    }
    if (mounted) setState(() { _busy = false; });
  }

  Future<void> _pickOnMap() async {
    final start = LatLng(double.tryParse(_lat.text) ?? v2i.CENTER_LAT, double.tryParse(_lon.text) ?? v2i.CENTER_LON);
    final picked = await Navigator.push<LatLng>(context, MaterialPageRoute(builder: (_) => MapPickScreen(initial: start)));
    if (picked == null) return;
    _lat.text = picked.latitude.toStringAsFixed(6);
    _lon.text = picked.longitude.toStringAsFixed(6);
    setState(() { _note = 'Picked on the map.'; });
  }

  Future<void> _create() async {
    if (!_form.currentState!.validate()) return;
    setState(() { _busy = true; });
    try {
      final s = await context.read<V2IRepository>().createSession(
          name: _name.text.trim(), centerLat: double.parse(_lat.text), centerLon: double.parse(_lon.text));
      if (mounted) await widget.onCreated(s);
    } on ApiException catch (e) {
      if (mounted) setState(() { _note = e.message; });
    }
    if (mounted) setState(() { _busy = false; });
  }

  static String? _coord(String? v, double limit) {
    final d = double.tryParse((v ?? '').trim());
    if (d == null || d.abs() > limit) return 'Enter a number between -$limit and $limit';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return HwCard(
      title: 'New digital intersection',
      icon: Icons.add_road,
      child: Form(
        key: _form,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextFormField(
            key: const ValueKey('session-name'),
            controller: _name,
            maxLength: 60,
            decoration: const InputDecoration(labelText: 'Name'),
            validator: (v) => (v ?? '').trim().isEmpty ? 'Enter a name' : null,
          ),
          Row(children: [
            Expanded(
              child: TextFormField(
                key: const ValueKey('center-lat'),
                controller: _lat,
                keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                decoration: const InputDecoration(labelText: 'Centre latitude'),
                validator: (v) => _coord(v, 90),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextFormField(
                key: const ValueKey('center-lon'),
                controller: _lon,
                keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                decoration: const InputDecoration(labelText: 'Centre longitude'),
                validator: (v) => _coord(v, 180),
              ),
            ),
          ]),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton.icon(onPressed: _busy ? null : _useMyLocation, icon: const Icon(Icons.my_location), label: const Text('Use my location')),
            OutlinedButton.icon(onPressed: _busy ? null : _pickOnMap, icon: const Icon(Icons.map_outlined), label: const Text('Pick on the map')),
          ]),
          if (_note != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_note!)),
          const SizedBox(height: 8),
          Text(
            'Arms: N, E, S, W from the centre; vehicles are detected up to ${v2i.DETECT_RADIUS_M.toStringAsFixed(0)} m. '
            'The default centre is the firmware\'s test-data origin.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const ValueKey('create-session'),
            onPressed: _busy ? null : _create,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Create and run'),
          ),
        ]),
      ),
    );
  }
}

/// Tap the map to place the junction centre; the 150 m detection circle is drawn around it.
class MapPickScreen extends StatefulWidget {
  const MapPickScreen({super.key, required this.initial});
  final LatLng initial;

  @override
  State<MapPickScreen> createState() => _MapPickScreenState();
}

class _MapPickScreenState extends State<MapPickScreen> {
  late LatLng _pick = widget.initial;

  @override
  Widget build(BuildContext context) {
    final config = context.watch<AppConfig>();
    return Scaffold(
      appBar: AppBar(title: const Text('Junction centre')),
      body: FlutterMap(
        options: MapOptions(initialCenter: widget.initial, initialZoom: 17, onTap: (_, p) => setState(() => _pick = p)),
        children: [
          TileLayer(urlTemplate: config.tileUrl, userAgentPackageName: 'com.fyp.smart_traffic', maxZoom: 19),
          CircleLayer(circles: [
            CircleMarker(
              point: _pick,
              radius: v2i.DETECT_RADIUS_M,
              useRadiusInMeter: true,
              color: const Color(0xFF7C3AED).withValues(alpha: 0.12),
              borderColor: const Color(0xFF7C3AED),
              borderStrokeWidth: 2,
            ),
          ]),
          MarkerLayer(markers: [
            Marker(point: _pick, width: 40, height: 40, child: const Icon(Icons.add_location_alt, color: Color(0xFF7C3AED), size: 40)),
          ]),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton.icon(
            onPressed: () => Navigator.pop(context, _pick),
            icon: const Icon(Icons.check),
            label: Text('Use ${_pick.latitude.toStringAsFixed(6)}, ${_pick.longitude.toStringAsFixed(6)}'),
          ),
        ),
      ),
    );
  }
}

/// ADMIN: emergency authorisation (requested by drivers, or set per account).
class EmergencyApprovals extends StatefulWidget {
  const EmergencyApprovals({super.key});

  @override
  State<EmergencyApprovals> createState() => _EmergencyApprovalsState();
}

class _EmergencyApprovalsState extends State<EmergencyApprovals> {
  late Future<List<V2IProfileRow>> _rows = context.read<V2IRepository>().profiles();

  void _reload() => setState(() { _rows = context.read<V2IRepository>().profiles(); });

  Future<void> _set(String email, String status) async {
    try {
      await context.read<V2IRepository>().setEmergency(email, status);
      _reload();
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _byEmail() async {
    final email = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Authorise an emergency vehicle'),
        content: TextField(
          controller: email,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(labelText: 'Driver account e-mail'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Approve')),
        ],
      ),
    );
    if (ok == true) await _set(email.text.trim(), 'APPROVED');
    email.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return HwCard(
      title: 'Emergency vehicles',
      icon: Icons.emergency,
      trailing: IconButton(tooltip: 'Approve by e-mail', onPressed: _byEmail, icon: const Icon(Icons.person_add_alt)),
      child: FutureBuilder<List<V2IProfileRow>>(
        future: _rows,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const LoadingView();
          if (snap.hasError) return ErrorView(message: '${snap.error}', onRetry: _reload);
          final rows = snap.data!.where((r) => r.emergencyStatus != 'NONE').toList();
          if (rows.isEmpty) {
            return Text('No requests. Drivers can ask from their Digital V2I screen, or approve an account by e-mail (+).',
                style: theme.textTheme.bodyMedium);
          }
          return Column(children: [
            for (final r in rows)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: CircleAvatar(child: Text('${r.vehicleId % 1000}')),
                title: Text('${r.fullName} · vehicle ${r.vehicleId}'),
                subtitle: Text('${r.email}${r.emergencyReason == null ? '' : '\n"${r.emergencyReason}"'}'),
                isThreeLine: r.emergencyReason != null,
                trailing: switch (r.emergencyStatus) {
                  'REQUESTED' => Wrap(spacing: 4, children: [
                      IconButton(tooltip: 'Reject', onPressed: () => _set(r.email, 'REJECTED'), icon: const Icon(Icons.close)),
                      IconButton(
                          tooltip: 'Approve',
                          onPressed: () => _set(r.email, 'APPROVED'),
                          icon: const Icon(Icons.check_circle, color: StatusColors.ok)),
                    ]),
                  'APPROVED' => TextButton(onPressed: () => _set(r.email, 'REVOKED'), child: const Text('Revoke')),
                  final s => HwChip(label: s, color: StatusColors.neutral),
                },
              ),
          ]);
        },
      ),
    );
  }
}

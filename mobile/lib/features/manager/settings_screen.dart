import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/config/app_config.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/signals.dart';
import '../../data/repositories/manager_repository.dart';
import '../../widgets/common.dart';
import '../auth/auth_controller.dart';
import '../driver/profile_screen.dart' show showChangePassword;
import 'live_controller.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final config = context.watch<AppConfig>();
    final user = context.watch<AuthController>().user!;
    return Scaffold(
      appBar: AppBar(title: const Text('System settings')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const SectionHeader('Demo simulation', subtitle: 'Simulated vehicles for demonstrations, clearly marked SIM'),
        const _DemoCard(),
        const SectionHeader('Display'),
        Card(
          child: Column(children: [
            ListTile(
              leading: const Icon(Icons.brightness_6_outlined),
              title: const Text('Theme'),
              trailing: DropdownButton<ThemeMode>(
                value: config.themeMode,
                underline: const SizedBox.shrink(),
                items: const [
                  DropdownMenuItem(value: ThemeMode.system, child: Text('System')),
                  DropdownMenuItem(value: ThemeMode.light, child: Text('Light')),
                  DropdownMenuItem(value: ThemeMode.dark, child: Text('Dark')),
                ],
                onChanged: (m) => config.setThemeMode(m ?? ThemeMode.system),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.layers_outlined),
              title: const Text('Map tiles'),
              subtitle: Text(config.tileUrl, maxLines: 2, overflow: TextOverflow.ellipsis),
              onTap: () => _editTiles(context, config),
            ),
          ]),
        ),
        const SectionHeader('Connection'),
        Card(
          child: Column(children: [
            ListTile(leading: const Icon(Icons.dns_outlined), title: const Text('Server'), subtitle: Text(config.serverUrl)),
            const ListTile(
              leading: Icon(Icons.info_outline),
              title: Text('To change the server, sign out first.'),
            ),
          ]),
        ),
        const SectionHeader('Account'),
        Card(
          child: Column(children: [
            ListTile(
              leading: const CircleAvatar(child: Icon(Icons.admin_panel_settings)),
              title: Text(user.fullName),
              subtitle: Text('${user.email} · ${user.roleLabel}'),
            ),
            ListTile(leading: const Icon(Icons.password), title: const Text('Change password'), onTap: () => showChangePassword(context)),
            ListTile(
              leading: const Icon(Icons.logout, color: StatusColors.danger),
              title: const Text('Sign out'),
              onTap: () {
                context.read<LiveController>().stop();
                context.read<AuthController>().logout();
              },
            ),
          ]),
        ),
        const SectionHeader('About'),
        const Card(
          child: Padding(
            padding: EdgeInsets.all(14),
            child: Text(
              'Smart Traffic Management System (FYP prototype) 1.0.0.\n\n'
              'Managers can view vehicles by Vehicle ID, live telemetry, traffic metrics and emergencies, and '
              'configure intersections and signal plans. Owner identities are not shown to managers. '
              'Signal decisions are advisory; emergency priority is a simulation/prototype feature.',
            ),
          ),
        ),
      ]),
    );
  }

  Future<void> _editTiles(BuildContext context, AppConfig config) async {
    final controller = TextEditingController(text: config.tileUrl);
    await showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Map tile address'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: controller, decoration: const InputDecoration(helperText: 'Must contain {z}, {x} and {y}')),
          const SizedBox(height: 8),
          const Text('The default public OpenStreetMap server is fine for a demo; heavy use needs your own tile server.',
              style: TextStyle(fontSize: 12)),
        ]),
        actions: [
          TextButton(onPressed: () => controller.text = AppConfig.defaultTileUrl, child: const Text('Default')),
          FilledButton(
            onPressed: () {
              final v = controller.text.trim();
              if (v.contains('{z}') && v.contains('{x}') && v.contains('{y}')) {
                config.setTileUrl(v);
                Navigator.pop(dialogContext);
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}

class _DemoCard extends StatefulWidget {
  const _DemoCard();

  @override
  State<_DemoCard> createState() => _DemoCardState();
}

class _DemoCardState extends State<_DemoCard> {
  DemoStatus? _status;
  Object? _error;
  double _vehicles = 30;
  bool _ambulance = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      _status = await context.read<ManagerRepository>().demoStatus();
      _error = null;
    } catch (e) {
      _error = e;
    }
    if (mounted) setState(() {});
  }

  Future<void> _run(Future<DemoStatus> Function() action, String message) async {
    setState(() => _busy = true);
    await runGuarded(context, () async => _status = await action(), success: message);
    if (mounted) {
      setState(() => _busy = false);
      await context.read<LiveController>().refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _status;
    final repo = context.read<ManagerRepository>();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: s == null
            ? (_error != null ? Text('Could not read demo status: $_error') : const LoadingView())
            : !s.enabled
                ? const Text('Demo mode is disabled on the server. Set DEMO_MODE=true in backend/.env to enable '
                    'simulated vehicles (never in production).')
                : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      StatusChip(
                        label: s.running ? 'Running' : 'Stopped',
                        color: s.running ? StatusColors.ok : StatusColors.neutral,
                        icon: Icons.science,
                      ),
                      const SizedBox(width: 8),
                      if (s.running) Text('${s.activeVehicles}/${s.vehicles} vehicles on the road'),
                    ]),
                    const SizedBox(height: 8),
                    const Text('Simulated vehicles drive the configured intersections, stop at virtual signals that '
                        'follow the engine\'s decisions, and send telemetry through the same validation as phones.'),
                    if (!s.running) ...[
                      const SizedBox(height: 8),
                      Text('Vehicles: ${_vehicles.round()}'),
                      Slider(
                        value: _vehicles,
                        min: 5,
                        max: 80,
                        divisions: 15,
                        label: '${_vehicles.round()}',
                        onChanged: (v) => setState(() => _vehicles = v),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Include a simulated ambulance'),
                        subtitle: const Text('Makes emergency trips along the corridor every few minutes'),
                        value: _ambulance,
                        onChanged: (v) => setState(() => _ambulance = v),
                      ),
                      FilledButton.icon(
                        onPressed: _busy
                            ? null
                            : () => _run(() => repo.startDemo(vehicles: _vehicles.round(), ambulance: _ambulance), 'Simulation started.'),
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('Start simulation'),
                      ),
                    ] else ...[
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: _busy ? null : () => _run(repo.stopDemo, 'Simulation stopped.'),
                        icon: const Icon(Icons.stop),
                        label: const Text('Stop simulation'),
                      ),
                    ],
                  ]),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../link/live_source.dart';
import '../monitor.dart';
import '../settings.dart';

Future<void> showHardwareSettings(BuildContext context) {
  final monitor = context.read<HardwareMonitor>();
  monitor.refreshWifiStatus();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => ChangeNotifierProvider.value(value: monitor, child: const _SettingsSheet()),
  );
}

class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet();

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  final _form = GlobalKey<FormState>();
  late final _host = TextEditingController(text: context.read<HardwareMonitor>().settings.host);
  late final _port = TextEditingController(text: '${context.read<HardwareMonitor>().settings.port}');

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  Future<void> _saveAddress() async {
    if (!_form.currentState!.validate()) return;
    await context.read<HardwareMonitor>().setAddress(_host.text.trim(), int.parse(_port.text.trim()));
    if (!mounted) return;
    FocusScope.of(context).unfocus();
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('Controller address saved.')));
  }

  @override
  Widget build(BuildContext context) {
    final m = context.watch<HardwareMonitor>();
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final sim = m.simulator;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Form(
            key: _form,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('Monitor settings', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 16),
              Text('Data source', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              SegmentedButton<DataSource>(
                key: const ValueKey('data-source'),
                segments: const [
                  ButtonSegment(value: DataSource.live, label: Text('ESP32 (live)'), icon: Icon(Icons.router_outlined)),
                  ButtonSegment(value: DataSource.simulator, label: Text('Simulator'), icon: Icon(Icons.science_outlined)),
                ],
                selected: {m.settings.source},
                onSelectionChanged: (s) => m.setSource(s.first),
              ),
              const SizedBox(height: 20),
              Text('ESP32 controller', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  flex: 3,
                  child: TextFormField(
                    key: const ValueKey('hw-host'),
                    controller: _host,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(labelText: 'IP address'),
                    validator: (v) => HardwareSettings.validateHost(v ?? ''),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: TextFormField(
                    key: const ValueKey('hw-port'),
                    controller: _port,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Port'),
                    validator: (v) => HardwareSettings.validatePort(v ?? ''),
                  ),
                ),
              ]),
              const SizedBox(height: 6),
              Text('WebSocket: ${LiveSource.uriFor(m.settings.host, m.settings.port)}', style: muted),
              const SizedBox(height: 8),
              Row(children: [
                TextButton(
                  onPressed: () {
                    _host.text = HardwareSettings.defaultHost;
                    _port.text = '${HardwareSettings.defaultPort}';
                  },
                  child: const Text('Defaults'),
                ),
                const Spacer(),
                FilledButton(key: const ValueKey('hw-save'), onPressed: _saveAddress, child: const Text('Save address')),
              ]),
              const SizedBox(height: 12),
              _InfoBox(
                icon: Icons.wifi,
                text: 'Join the Wi-Fi network "${HardwareSettings.ssid}" in the phone\'s settings. It has no internet; '
                    'if the phone asks, choose to stay connected.'
                    '${m.supportsWifiBinding ? '\nThis app keeps its connection on Wi-Fi: ${m.wifiBound ? 'Wi-Fi in use' : 'no Wi-Fi network found yet'}.' : ''}',
              ),
              if (sim != null) ...[
                const SizedBox(height: 20),
                Text('Simulator controls', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                Text('These change the simulated data only.', style: muted),
                const SizedBox(height: 8),
                Card(
                  margin: EdgeInsets.zero,
                  child: Column(children: [
                    ListTile(
                      leading: const Icon(Icons.radio_button_checked),
                      title: const Text('Press the mode button'),
                      subtitle: Text('Simulated mode: ${sim.mode == 'adaptive' ? 'Adaptive' : 'Fixed'}'),
                      onTap: () => setState(sim.pressModeButton),
                    ),
                    SwitchListTile(
                      secondary: const Icon(Icons.wifi_tethering_off),
                      title: const Text('V2I link lost'),
                      subtitle: const Text('Fixed-time fallback'),
                      value: sim.linkLost,
                      onChanged: (v) => setState(() => sim.setLinkLost(v)),
                    ),
                    ListTile(
                      leading: const Icon(Icons.emergency, color: StatusColors.emergency),
                      title: const Text('Emergency request now'),
                      subtitle: const Text('Otherwise about once a minute'),
                      onTap: sim.requestEmergencyNow,
                    ),
                  ]),
                ),
              ],
              const SizedBox(height: 16),
              const _InfoBox(
                icon: Icons.visibility_outlined,
                text: 'Read-only monitor: this app never sends commands to the controller. '
                    'The mode is changed with the button on the hardware.',
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _InfoBox extends StatelessWidget {
  const _InfoBox({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 20, color: theme.colorScheme.primary),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
      ]),
    );
  }
}

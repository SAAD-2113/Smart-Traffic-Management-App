import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../hardware/platform/hardware_platform.dart';
import '../../hardware/ui/cards_v3.dart';
import '../../hardware/ui/hw_style.dart' show HwCard;
import '../../widgets/brand.dart';
import '../../widgets/common.dart';
import '../data/v2i_models.dart';
import '../intersection/digital_intersection.dart';
import '../transport/lan_server.dart';
import '../transport/links.dart';
import 'digital_app.dart';
import 'digital_home.dart' show digitalGradient;
import 'injector_card.dart';
import 'metrics_screen.dart';
import 'widgets.dart';

const intersectionLogTags = ['SIG', 'MODE', 'PLAN', 'PRIO', 'CONN', 'LOST', 'RX', 'RX!', 'MISMATCH', 'STAT', 'APP'];

/// This phone is the digital intersection. The controller and its transport live in
/// [DigitalIntersection]; this screen only shows it and passes the operator's commands.
/// Which transports the intersection uses (both at once is fine).
class RunOptions {
  const RunOptions({this.cloud = true, this.lan = false, this.lanEmergency = false});
  final bool cloud;

  /// LanTransport: HTTP 8080, WebSocket 8081, UDP 4210 on this phone.
  final bool lan;

  /// Accept "ty":1 over the LAN (no server checks the account there).
  final bool lanEmergency;
}

class IntersectionScreen extends StatefulWidget {
  const IntersectionScreen({super.key, required this.session, this.options = const RunOptions()});
  final HostedSession session;
  final RunOptions options;

  @override
  State<IntersectionScreen> createState() => _IntersectionScreenState();
}

class _IntersectionScreenState extends State<IntersectionScreen> {
  late final DigitalIntersection _junction;
  late final HardwarePlatform _platform;
  late final AppLifecycleListener _lifecycle;
  DateTime? _pausedAt;
  String? _backgroundNote;
  LanIntersectionLink? _lan;
  List<String> _lanAddresses = const [];

  IntersectionLink _link(DigitalServices services) {
    final o = widget.options;
    final links = <IntersectionLink>[
      if (o.cloud) services.intersection(widget.session.id),
      if (o.lan) _lan = services.lan(allowEmergency: o.lanEmergency),
    ];
    return links.length == 1 ? links.single : CompositeIntersectionLink(links);
  }

  @override
  void initState() {
    super.initState();
    final s = widget.session;
    _platform = context.read<HardwarePlatform>();
    _junction = DigitalIntersection(
      name: s.name,
      centerLat: s.centerLat,
      centerLon: s.centerLon,
      link: _link(context.read<DigitalServices>()),
      clock: context.read<DigitalServices>().clock(),
    )..start();
    if (_lan != null) LanIntersectionLink.addresses().then((a) => mounted ? setState(() => _lanAddresses = a) : null);
    _platform.keepScreenOn(true);
    _lifecycle = AppLifecycleListener(
      onHide: () => _pausedAt ??= DateTime.now(),
      onShow: () {
        final at = _pausedAt;
        _pausedAt = null;
        if (at == null) return;
        final secs = DateTime.now().difference(at).inMilliseconds / 1000;
        _junction.note('app was in the background for ${secs.toStringAsFixed(1)} s');
        setState(() => _backgroundNote = 'This app was in the background for ${secs.toStringAsFixed(1)} s. Android may '
            'slow or stop the signal loop while it is hidden; keep this screen open while vehicles drive.');
      },
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _platform.keepScreenOn(false);
    _junction.dispose();
    super.dispose();
  }

  Future<bool> _confirmLeave() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Stop the intersection?'),
        content: const Text('The session stays open, but vehicles get no ACK and show RED after 3 s until you run it again.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep running')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Stop')),
        ],
      ),
    );
    return ok == true;
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: _junction,
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) async {
          if (didPop) return;
          if (await _confirmLeave() && context.mounted) Navigator.pop(context);
        },
        child: Scaffold(
          body: Consumer<DigitalIntersection>(builder: (context, j, _) {
            return LayoutBuilder(builder: (context, c) {
              final two = c.maxWidth >= 720;
              const gap = SizedBox(height: 14);
              final left = <Widget>[
                _ModeCard(junction: j),
                gap,
                InjectorCard(junction: j),
                gap,
                V3SignalCard(view: j, title: 'Digital intersection', center: (widget.session.centerLat, widget.session.centerLon)),
                gap,
                V3TimingCard(view: j),
                gap,
                V3PlanCard(view: j),
              ];
              final right = <Widget>[
                V3LanesCard(view: j),
                gap,
                V3SystemCard(view: j, extra: [
                  ('Transport', j.link.label),
                  ('Packets in / ACKs out', '${j.packetsIn} / ${j.acksOut}'),
                  ('RTT (median of vehicles)', () {
                    final m = median(j.rttMs.values.toList());
                    return m == null ? '—' : '$m ms';
                  }()),
                ]),
                gap,
                V3VehiclesCard(view: j, initiallyExpanded: true, rttMs: j.rttMs),
                gap,
                LogCard(
                  log: j.log,
                  tags: intersectionLogTags,
                  title: 'Controller log (Serial Monitor)',
                  rxOn: j.rxLogOn,
                  onToggleRx: j.toggleRxLog,
                ),
              ];
              return ListView(key: const ValueKey('intersection-screen'), padding: EdgeInsets.zero, children: [
                _Header(session: widget.session, junction: j, onStop: () async {
                  if (await _confirmLeave() && context.mounted) Navigator.pop(context);
                }),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 40),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1280),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        if (_backgroundNote != null) ...[
                          MessageBanner(text: _backgroundNote!, color: StatusColors.warning, icon: Icons.warning_amber),
                          gap,
                        ],
                        if (j.linkState == LinkState.closed) ...[
                          MessageBanner(
                              text: j.linkReason ?? 'Disconnected.', color: StatusColors.danger, icon: Icons.link_off),
                          gap,
                        ],
                        if (_lan != null) ...[
                          _LanCard(lan: _lan!, addresses: _lanAddresses),
                          gap,
                        ],
                        V3StatusRow(view: j),
                        gap,
                        if (two)
                          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: left)),
                            const SizedBox(width: 14),
                            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: right)),
                          ])
                        else ...[
                          ...left,
                          gap,
                          ...right,
                        ],
                      ]),
                    ),
                  ),
                ),
              ]);
            });
          }),
        ),
      ),
    );
  }
}

/// Where other devices on this Wi-Fi / hotspot reach the intersection.
class _LanCard extends StatelessWidget {
  const _LanCard({required this.lan, required this.addresses});
  final LanIntersectionLink lan;
  final List<String> addresses;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ip = addresses.isEmpty ? '<this phone\'s IP>' : addresses.first;
    return HwCard(
      title: 'LAN (this phone\'s Wi-Fi or hotspot)',
      icon: Icons.wifi_tethering,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SelectableText(
          [
            for (final a in addresses.isEmpty ? [ip] : addresses) 'http://$a:${lan.boundHttpPort}   ws://$a:${lan.boundWsPort}/',
          ].join('\n'),
          key: const ValueKey('lan-addresses'),
          style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        Text(
          'Vehicle phones: Connection → LAN, address $ip:${lan.boundHttpPort}. Hardware mode on any phone: '
          'controller $ip, port ${lan.boundWsPort}. curl / laptops: POST http://$ip:${lan.boundHttpPort}/api/vehicle, '
          'UDP $ip:${lan.boundUdpPort}. Emergency packets over the LAN: ${lan.allowEmergency ? 'accepted (as on the ESP32)' : 'refused'}'
          '${lan.refusedEmergency > 0 ? ' (${lan.refusedEmergency} refused)' : ''}.',
          style: theme.textTheme.bodySmall,
        ),
      ]),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.session, required this.junction, required this.onStop});
  final HostedSession session;
  final DigitalIntersection junction;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final online = junction.members.values.where((m) => m.online).length;
    return GradientHeader(
      title: session.name,
      subtitle: 'Digital intersection · firmware v3 twin · keep this screen open',
      icon: Icons.traffic,
      gradient: digitalGradient,
      actions: [
        IconButton(
          key: const ValueKey('open-metrics'),
          tooltip: 'Metrics, comparison and export',
          onPressed: () => Navigator.push(
              context, MaterialPageRoute(builder: (_) => MetricsScreen(junction: junction, session: session))),
          icon: const Icon(Icons.analytics_outlined, color: Colors.white),
        ),
        IconButton(key: const ValueKey('stop-intersection'), tooltip: 'Stop', onPressed: onStop, icon: const Icon(Icons.stop_circle_outlined, color: Colors.white)),
      ],
      child: Wrap(spacing: 8, runSpacing: 8, children: [
        InkWell(
          key: const ValueKey('show-join-code'),
          borderRadius: BorderRadius.circular(20),
          onTap: () => showJoinCode(context, session.name, session.joinCode),
          child: HeaderPill(label: 'Code ${session.joinCode}', icon: Icons.qr_code_2),
        ),
        LinkPill(state: junction.linkState, label: 'Relay'),
        HeaderPill(label: '$online vehicle phone${online == 1 ? '' : 's'} online', icon: Icons.directions_car),
      ]),
    );
  }
}

/// Requested mode (the firmware's f / a / o commands) and why the controller is in its mode.
class _ModeCard extends StatelessWidget {
  const _ModeCard({required this.junction});
  final DigitalIntersection junction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return HwCard(
      title: 'Mode',
      icon: Icons.tune,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SegmentedButton<String>(
          key: const ValueKey('mode-control'),
          segments: const [
            ButtonSegment(value: 'auto', label: Text('Auto'), icon: Icon(Icons.auto_mode)),
            ButtonSegment(value: 'fixed', label: Text('Fixed'), icon: Icon(Icons.schedule)),
            ButtonSegment(value: 'adaptive', label: Text('Adaptive'), icon: Icon(Icons.insights)),
          ],
          selected: {junction.requestedMode},
          onSelectionChanged: (s) => junction.setRequestedMode(s.first),
        ),
        const SizedBox(height: 8),
        Text(
          'Auto: fixed 30 s round-robin while no vehicle sends data, adaptive (Webster) while they do. A change applies '
          'at the next lane decision; a running green is never cut.',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ]),
    );
  }
}

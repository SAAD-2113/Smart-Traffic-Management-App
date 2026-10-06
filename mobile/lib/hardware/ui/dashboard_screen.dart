import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../mode/switch_mode.dart';
import '../../widgets/brand.dart';
import '../../widgets/common.dart' show Ticker;
import '../model/labels.dart';
import '../monitor.dart';
import '../settings.dart';
import 'cards.dart';
import 'hw_style.dart';
import 'settings_sheet.dart';

/// The Hardware Intersection Monitor. Read-only: it shows what the ESP32 reports and never
/// sends commands (mode changes happen on the controller's physical button).
class HardwareDashboardScreen extends StatelessWidget {
  const HardwareDashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(children: [
        LayoutBuilder(builder: (context, c) {
          final twoColumns = c.maxWidth >= 720;
          const gap = SizedBox(height: 14);
          final left = <Widget>[const LiveSignalCard(), gap, const TimingCard(), gap, const PlanCard()];
          final right = <Widget>[const TrafficCard(), gap, const SystemCard(), gap, const VehiclesCard(), gap, const EventLogCard()];
          return ListView(
            key: const ValueKey('hardware-dashboard'),
            padding: EdgeInsets.zero,
            children: [
              const _Header(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 96),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1280),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      const _Banners(),
                      const StatusRow(),
                      gap,
                      if (twoColumns)
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
            ],
          );
        }),
        const _EvPopup(),
      ]),
    );
  }
}

/// 1. Top bar: title, intersection ID, connection badge, last update, settings, Switch mode.
class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    final m = context.watch<HardwareMonitor>();
    final status = m.status;
    return GradientHeader(
      title: 'Hardware Intersection Monitor',
      icon: Icons.developer_board,
      actions: [
        IconButton(
          key: const ValueKey('hw-settings'),
          tooltip: 'Connection settings',
          onPressed: () => showHardwareSettings(context),
          icon: const Icon(Icons.settings, color: Colors.white),
        ),
      ],
      child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        HeaderPill(key: const ValueKey('intersection-id'), label: 'Intersection ${orDash(m.state?.id)}', icon: Icons.place_outlined),
        Container(
          key: const ValueKey('link-badge'),
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
          decoration: BoxDecoration(color: HwColors.link(status), borderRadius: BorderRadius.circular(20)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(
              switch (status) {
                LinkStatus.online => Icons.wifi,
                LinkStatus.stale => Icons.hourglass_bottom,
                LinkStatus.offline => Icons.wifi_off,
              },
              size: 14,
              color: status == LinkStatus.stale ? Colors.black : Colors.white,
            ),
            const SizedBox(width: 5),
            Text(HwColors.linkLabel(status),
                style: TextStyle(
                    color: status == LinkStatus.stale ? Colors.black : Colors.white,
                    fontWeight: FontWeight.w900,
                    fontSize: 12.5,
                    letterSpacing: 0.6)),
          ]),
        ),
        Ticker(
          period: const Duration(milliseconds: 100),
          builder: (_) => HeaderPill(
            key: const ValueKey('last-update'),
            label: m.sinceLastFrameMs == null ? 'No data yet' : 'Updated ${ago(m.sinceLastFrameMs)}',
            icon: Icons.schedule,
          ),
        ),
        HeaderPill(label: m.usingSimulator ? 'Simulator' : m.sourceLabel, icon: m.usingSimulator ? Icons.science_outlined : Icons.router_outlined),
        Material(
          color: Colors.white.withValues(alpha: 0.16),
          shape: StadiumBorder(side: BorderSide(color: Colors.white.withValues(alpha: 0.35))),
          child: InkWell(
            key: const ValueKey('switch-mode'),
            customBorder: const StadiumBorder(),
            onTap: () => switchAppMode(context),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.swap_horiz, size: 16, color: Colors.white),
                SizedBox(width: 5),
                Text('Switch mode', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12.5)),
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}

/// Simulated data, unsupported data, emergency, V2I loss and connection banners.
class _Banners extends StatelessWidget {
  const _Banners();

  @override
  Widget build(BuildContext context) {
    final m = context.watch<HardwareMonitor>();
    final s = m.state;
    final banners = <Widget>[
      if (m.showSimulated)
        _Banner(
          key: const ValueKey('simulated-banner'),
          color: StatusColors.simulated,
          icon: Icons.science,
          filled: true,
          text: m.usingSimulator
              ? 'SIMULATED DATA — generated by the app, not the hardware'
              : 'SIMULATED DATA — last state from the simulator, not the hardware',
        ),
      if (s != null && s.preemptActive)
        _Banner(
          key: const ValueKey('emergency-banner'),
          color: StatusColors.emergency,
          icon: Icons.emergency,
          filled: true,
          text: 'EMERGENCY PRIORITY — ${approachName(s.preempt.approach).toUpperCase()} — ${orDash(s.preempt.vehicleId)}'
              '${m.isLive ? '' : ' (last known)'}',
        ),
      if (s != null && s.v2iLost)
        _Banner(
          key: const ValueKey('v2i-banner'),
          color: StatusColors.warning,
          icon: Icons.sync_problem,
          filled: true,
          text: 'V2I link lost — fixed-time fallback active',
        ),
      if (m.unsupportedWarning)
        _Banner(
          key: const ValueKey('version-banner'),
          color: StatusColors.alert,
          icon: Icons.report_outlined,
          text: 'Unsupported data version (v=${m.unsupportedVersion ?? 'missing'}). Those frames are ignored; '
              'this app reads version $supportedVersionLabel.',
        ),
      if (m.unreadableWarning && !m.unsupportedWarning)
        _Banner(color: StatusColors.alert, icon: Icons.report_outlined, text: 'Unreadable frame ignored (${m.unreadableReason}).'),
      if (m.status != LinkStatus.online) _ConnectionBanner(monitor: m),
    ];
    if (banners.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(children: [
        for (var i = 0; i < banners.length; i++) ...[if (i > 0) const SizedBox(height: 8), banners[i]],
      ]),
    );
  }
}

const supportedVersionLabel = '2';

class _ConnectionBanner extends StatelessWidget {
  const _ConnectionBanner({required this.monitor});
  final HardwareMonitor monitor;

  @override
  Widget build(BuildContext context) {
    final m = monitor;
    final offline = m.status == LinkStatus.offline;
    final String text;
    if (m.usingSimulator) {
      text = 'Simulator starting…';
    } else if (offline) {
      text = 'Not connected to ${m.sourceLabel}. Join the Wi-Fi network "${HardwareSettings.ssid}" '
          '(it has no internet). Retrying every 2 s.';
    } else {
      text = 'Connected, but no data from the controller for more than 1.5 s.';
    }
    return _Banner(
      key: const ValueKey('connection-banner'),
      color: offline ? StatusColors.danger : StatusColors.warning,
      icon: offline ? Icons.wifi_off : Icons.hourglass_bottom,
      text: m.state == null ? text : '$text Showing the last known state.',
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({super.key, required this.color, required this.icon, required this.text, this.filled = false});

  final Color color;
  final IconData icon;
  final String text;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final ink = filled
        ? (color == StatusColors.warning ? Colors.black : Colors.white)
        : StatusColors.readable(color, Theme.of(context).brightness);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: filled ? color : color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: filled ? 1 : 0.5)),
      ),
      child: Row(children: [
        Icon(icon, color: ink),
        const SizedBox(width: 10),
        Expanded(
          child: Text(text,
              style: TextStyle(color: ink, fontWeight: filled ? FontWeight.w800 : FontWeight.w600, fontSize: filled ? 14.5 : 13.5)),
        ),
      ]),
    );
  }
}

/// Popup for every "ev_request" event, shown for 5 s. Notification only.
class _EvPopup extends StatelessWidget {
  const _EvPopup();

  @override
  Widget build(BuildContext context) {
    final m = context.watch<HardwareMonitor>();
    final n = m.notice;
    final theme = Theme.of(context);
    return Positioned(
      left: 16,
      right: 16,
      bottom: 16,
      child: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: n == null
              ? const SizedBox.shrink()
              : Center(
                  key: ValueKey(n),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: Card(
                      key: const ValueKey('ev-popup'),
                      elevation: 10,
                      margin: EdgeInsets.zero,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                        side: const BorderSide(color: StatusColors.emergency, width: 2),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 14, 8, 10),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                          Row(children: [
                            const Icon(Icons.emergency, color: StatusColors.emergency, size: 28),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text('Emergency vehicle request${n.simulated ? ' (simulated)' : ''}',
                                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                            ),
                          ]),
                          const SizedBox(height: 8),
                          Wrap(spacing: 8, runSpacing: 6, children: [
                            HwChip(label: 'Vehicle ${orDash(n.request.vehicleId)}', color: StatusColors.info, icon: Icons.directions_car),
                            HwChip(label: 'Approach ${approachName(n.request.approach)}', color: StatusColors.info, icon: Icons.call_split),
                            HwChip(
                              label: (n.request.result ?? 'unknown').toUpperCase(),
                              color: switch (n.request.result) {
                                'granted' => StatusColors.ok,
                                'rejected' => StatusColors.danger,
                                _ => StatusColors.neutral,
                              },
                              icon: n.request.result == 'granted' ? Icons.check_circle : Icons.info_outline,
                            ),
                          ]),
                          if (n.request.vehicleId == null && n.request.detail.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Text(n.request.detail, style: theme.textTheme.bodySmall),
                          ],
                          Row(children: [
                            Expanded(
                              child: Text('Notification only — nothing is sent to the controller.',
                                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                            ),
                            TextButton(key: const ValueKey('ev-dismiss'), onPressed: m.dismissNotice, child: const Text('Dismiss')),
                          ]),
                        ]),
                      ),
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

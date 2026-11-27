import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:v2i_core/v2i_core.dart' as v2i;

import '../../core/theme/app_theme.dart';
import '../../hardware/platform/hardware_platform.dart';
import '../../hardware/ui/hw_style.dart' show HwCard, HwChip, HwColors;
import '../../services/location_service.dart';
import '../../widgets/brand.dart';
import '../../widgets/common.dart';
import '../data/v2i_models.dart';
import '../transport/links.dart';
import '../vehicle/digital_vehicle.dart';
import 'digital_app.dart';
import 'digital_home.dart' show digitalGradient;
import 'widgets.dart';

const vehicleLogTags = ['TX', 'BASIS', 'ACK', 'PRIO', 'SIM', 'TX!'];
final _seqRe = RegExp(r'^\[ACK \] seq=(\d+) ');

/// This phone is a vehicle. It shows only what the intersection's ACK says.
/// How this vehicle reaches the intersection.
enum VehicleConnection {
  /// The server relay (joined with a code).
  cloud,

  /// POST to an intersection phone's LAN server.
  lan,

  /// HardwareBridgeTransport: POST to the real ESP32 at 192.168.4.1.
  esp32,
}

/// The physical junction's address (v2i_common.h INTERSECTION_IP_STR).
final esp32Base = Uri.parse('http://${v2i.INTERSECTION_IP_STR}');

class VehicleScreen extends StatefulWidget {
  const VehicleScreen({
    super.key,
    required this.session,
    required this.source,
    this.connection = VehicleConnection.cloud,
    this.lanAddress,
  });
  final JoinedSession session;
  final DriveSource source;
  final VehicleConnection connection;

  /// "192.168.43.1:8080" for [VehicleConnection.lan].
  final String? lanAddress;

  @override
  State<VehicleScreen> createState() => _VehicleScreenState();
}

class _VehicleScreenState extends State<VehicleScreen> {
  late final DigitalVehicle _vehicle;
  late final HardwarePlatform _platform;
  String? _gpsProblem;

  @override
  void initState() {
    super.initState();
    _platform = context.read<HardwarePlatform>();
    final location = context.read<LocationService>();
    _vehicle = DigitalVehicle(
      session: widget.session,
      link: switch (widget.connection) {
        VehicleConnection.cloud => context.read<DigitalServices>().vehicle(widget.session.sessionId),
        VehicleConnection.lan => context.read<DigitalServices>().http(Uri.parse('http://${widget.lanAddress}')),
        VehicleConnection.esp32 => context.read<DigitalServices>().http(esp32Base, what: 'ESP32'),
      },
      clock: context.read<DigitalServices>().clock(),
      source: widget.source,
      gps: () => location.fixes(
          notificationTitle: 'Digital V2I', notificationText: 'Sending this phone\'s position to the intersection'),
    );
    if (widget.source is LiveGpsDrive) {
      location.ensureAccess().then((a) {
        if (!mounted) return;
        if (a != LocationAccess.granted) {
          setState(() { _gpsProblem = 'Location is not available ($a). Allow location for this app and try again.'; });
          return;
        }
        _vehicle.start();
      });
    } else {
      _vehicle.start();
    }
    _platform.keepScreenOn(true);
    // the ESP32's network has no internet: keep this app's traffic on Wi-Fi (as Hardware mode)
    if (widget.connection == VehicleConnection.esp32) _platform.bindToWifi();
  }

  @override
  void dispose() {
    if (widget.connection == VehicleConnection.esp32) _platform.releaseWifi();
    _platform.keepScreenOn(false);
    _vehicle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: _vehicle,
      child: Scaffold(
        body: Consumer<DigitalVehicle>(builder: (context, v, _) {
          final started = v.running || v.endedReason != null;
          return ListView(key: const ValueKey('vehicle-screen'), padding: EdgeInsets.zero, children: [
            GradientHeader(
              title: 'Vehicle ${widget.session.vehicleId}',
              subtitle: '${widget.session.name} · ${widget.source.label}',
              icon: Icons.directions_car,
              gradient: digitalGradient,
              actions: [
                IconButton(
                  key: const ValueKey('stop-drive'),
                  tooltip: 'Stop',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.stop_circle_outlined, color: Colors.white),
                ),
              ],
              child: Wrap(spacing: 8, runSpacing: 8, children: [
                LinkPill(state: v.linkState, label: switch (widget.connection) {
                  VehicleConnection.cloud => 'Relay',
                  VehicleConnection.lan => 'LAN',
                  VehicleConnection.esp32 => 'ESP32',
                }),
                HeaderPill(
                  label: v.intersectionOnline ? 'Intersection running' : 'Intersection not running',
                  dotColor: v.intersectionOnline ? StatusColors.ok : StatusColors.danger,
                ),
                if (v.emergency) const HeaderPill(label: 'EMERGENCY (ty 1)', icon: Icons.emergency),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 40),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    if (_gpsProblem != null) MessageBanner(text: _gpsProblem!, color: StatusColors.danger, icon: Icons.location_off),
                    if (v.endedReason != null) ...[
                      MessageBanner(text: v.endedReason!, color: StatusColors.warning, icon: Icons.info_outline),
                      const SizedBox(height: 12),
                    ],
                    if (v.linkState == LinkState.closed && v.linkReason != null && v.linkReason != 'stopped') ...[
                      MessageBanner(text: v.linkReason!, color: StatusColors.danger, icon: Icons.link_off),
                      const SizedBox(height: 12),
                    ],
                    if (started) ...[
                      _SignalCard(v: v),
                      const SizedBox(height: 14),
                      _DetailsCard(v: v),
                      const SizedBox(height: 14),
                      LogCard(
                        log: v.log,
                        tags: vehicleLogTags,
                        title: 'Packet log (Serial Monitor)',
                        // the firmware's [ACK ] line has no RTT: shown after it, measured by seq
                        suffix: (l) {
                          if (l.tag != 'ACK') return null;
                          final seq = int.tryParse(_seqRe.firstMatch(l.text)?.group(1) ?? '');
                          final rtt = seq == null ? null : v.unit.rttBySeq[seq];
                          return rtt == null ? null : '<- RTT $rtt ms';
                        },
                      ),
                    ],
                  ]),
                ),
              ),
            ),
          ]);
        }),
      ),
    );
  }
}

/// The signal for this vehicle's lane, from the last ACK, counted down locally.
class _SignalCard extends StatelessWidget {
  const _SignalCard({required this.v});
  final DigitalVehicle v;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sig = v.signal;
    final hasLane = v.lane != '-' && v.lane.isNotEmpty;
    final word = switch (sig) { 'G' => 'GREEN', 'Y' => 'YELLOW', _ => 'RED' };
    return HwCard(
      title: 'Your signal',
      icon: Icons.traffic,
      trailing: v.priority ? const HwChip(label: 'PRIORITY', color: StatusColors.emergency, icon: Icons.emergency) : null,
      child: Ticker(
        period: const Duration(milliseconds: 100),
        builder: (context) => Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          _Head(signal: sig, dim: v.linkLost),
          const SizedBox(width: 20),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(word,
                  key: const ValueKey('signal-word'),
                  style: theme.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w900, color: StatusColors.readable(HwColors.lamp(sig), theme.brightness))),
              if (v.linkLost)
                Text(v.acksReceived == 0 ? 'No ACK yet: treated as RED' : 'No ACK for 3 s: treated as RED (be safe)',
                    key: const ValueKey('link-lost'), style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700))
              else ...[
                Text(hasLane ? '${v.remaining.ceil()} s ${sig == 'R' ? 'to green (estimate)' : 'left'}' : 'No lane: not counted',
                    key: const ValueKey('signal-rem'),
                    style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800, fontFeatures: const [FontFeature.tabularFigures()])),
                const SizedBox(height: 4),
                Text('Lane ${hasLane ? v.lane : '—'} · ${v.state} · intersection ${v.mode.toUpperCase()}', style: theme.textTheme.bodyMedium),
              ],
              const SizedBox(height: 6),
              Text('From the intersection\'s ACK; counted down on this phone between ACKs.',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _Head extends StatelessWidget {
  const _Head({required this.signal, required this.dim});
  final String signal;
  final bool dim;

  @override
  Widget build(BuildContext context) {
    Widget bulb(String which) {
      final on = signal == which;
      final c = on ? HwColors.lamp(which).withValues(alpha: dim ? 0.55 : 1) : SignalColors.off;
      return Container(
        width: 46,
        height: 46,
        margin: const EdgeInsets.all(5),
        decoration: BoxDecoration(
          color: c,
          shape: BoxShape.circle,
          boxShadow: on && !dim ? [BoxShadow(color: c.withValues(alpha: 0.8), blurRadius: 18)] : null,
        ),
      );
    }

    return Semantics(
      label: 'signal ${switch (signal) { 'G' => 'green', 'Y' => 'yellow', _ => 'red' }}',
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(color: const Color(0xFF141414), borderRadius: BorderRadius.circular(18)),
        child: Column(mainAxisSize: MainAxisSize.min, children: [bulb('R'), bulb('Y'), bulb('G')]),
      ),
    );
  }
}

/// [BASIS], detection -> green, round-trip time, counters. Every number is measured.
class _DetailsCard extends StatelessWidget {
  const _DetailsCard({required this.v});
  final DigitalVehicle v;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final b = v.basis;
    final rtt = v.rttSamples;
    final med = median(rtt);
    return HwCard(
      title: 'This vehicle',
      icon: Icons.info_outline,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: theme.colorScheme.surfaceContainer, borderRadius: BorderRadius.circular(10)),
          child: Text(
            b == null
                ? 'Basis: no packet sent yet.'
                : 'Basis (display only): bearing ${b.bearing.toStringAsFixed(0)}°, ${b.dist.toStringAsFixed(1)} m from the centre '
                    '=> lane ${b.lane >= 0 ? v2i.LANE_NAME[b.lane] : '—'}, ${v2i.stateName(b.st)}'
                    '${b.st == v2i.V2IState.ignored ? ' (${v2i.reasonName(b.reason)})' : ''}. The intersection decides.',
            key: const ValueKey('basis-line'),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(spacing: 24, runSpacing: 12, children: [
          Figure('Packets sent', '${v.packetsSent}'),
          Figure('ACKs received', '${v.acksReceived}'),
          Figure('RTT last', v.lastRttMs == null ? '—' : '${v.lastRttMs} ms'),
          Figure('RTT median', med == null ? '—' : '$med ms (${rtt.length})'),
          if (v.emergency)
            Figure('Detection → green', v.detectionToGreenS == null ? 'not yet' : '${v.detectionToGreenS!.toStringAsFixed(1)} s'),
          if (v.source is ReplayDrive) Figure('Replay (loops)', 'point ${v.replayIndex + 1} of ${v.replayLength}'),
          if (v.lastFix != null) Figure('GPS accuracy', '±${v.lastFix!.accuracyM.toStringAsFixed(0)} m'),
        ]),
        if (v.lastError != null) ...[
          const SizedBox(height: 10),
          MessageBanner(text: 'The server refused a packet: ${v.lastError}', color: StatusColors.danger, icon: Icons.block),
        ],
      ]),
    );
  }
}

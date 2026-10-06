import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import '../core/utils/units.dart';
import '../data/models/control.dart';
import '../data/models/traffic.dart';
import 'common.dart';

/// Mode badge: gradient pill with icon and label. Never colour alone.
class ModeBadge extends StatelessWidget {
  const ModeBadge(this.mode, {super.key, this.large = false});
  final String mode;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final label = switch (mode) {
      'FIXED_TIME' => 'FIXED-TIME',
      'ADAPTIVE' => 'ADAPTIVE',
      'EMERGENCY_PRIORITY' => 'EMERGENCY',
      _ => mode,
    };
    return Container(
      padding: EdgeInsets.symmetric(horizontal: large ? 14 : 10, vertical: large ? 7 : 4),
      decoration: BoxDecoration(
        gradient: ModeColors.gradient(mode),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [BoxShadow(color: ModeColors.of(mode).withValues(alpha: 0.35), blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(ModeColors.icon(mode), size: large ? 18 : 14, color: Colors.white),
        const SizedBox(width: 5),
        Text(label,
            style: TextStyle(
                color: Colors.white, fontSize: large ? 14 : 11.5, fontWeight: FontWeight.w800, letterSpacing: 0.6)),
      ]),
    );
  }
}

/// A three-lamp traffic light. [state]: GREEN, YELLOW, RED/ALL_RED or anything else (all off).
class TrafficLight extends StatelessWidget {
  const TrafficLight({super.key, required this.state, this.lampSize = 12, this.horizontal = false});
  final String state;
  final double lampSize;
  final bool horizontal;

  @override
  Widget build(BuildContext context) {
    final active = switch (state) {
      'GREEN' => 2,
      'YELLOW' || 'FLASHING' => 1,
      'RED' || 'ALL_RED' => 0,
      _ => -1,
    };
    final lamps = [
      for (var i = 0; i < 3; i++)
        _Lamp(
          color: [SignalColors.red, SignalColors.yellow, SignalColors.green][i],
          on: i == active,
          size: lampSize,
        ),
    ];
    final gap = SizedBox(width: lampSize * 0.28, height: lampSize * 0.28);
    return Container(
      padding: EdgeInsets.all(lampSize * 0.32),
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        borderRadius: BorderRadius.circular(lampSize * 0.7),
        border: Border.all(color: const Color(0xFF374151)),
      ),
      child: horizontal
          ? Row(mainAxisSize: MainAxisSize.min, children: [lamps[0], gap, lamps[1], gap, lamps[2]])
          : Column(mainAxisSize: MainAxisSize.min, children: [lamps[0], gap, lamps[1], gap, lamps[2]]),
    );
  }
}

class _Lamp extends StatelessWidget {
  const _Lamp({required this.color, required this.on, required this.size});
  final Color color;
  final bool on;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: on ? color : color.withValues(alpha: 0.16),
          boxShadow: on ? [BoxShadow(color: color.withValues(alpha: 0.8), blurRadius: size * 0.8)] : null,
        ),
      );
}

/// Seconds left in the current light interval, updated every second from the server clock.
class SignalCountdown extends StatelessWidget {
  const SignalCountdown({super.key, required this.display, required this.serverNow, this.style});
  final SignalDisplay display;
  final DateTime Function() serverNow;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => Ticker(builder: (_) {
        final left = display.remainingAt(serverNow());
        return Text(left == null ? '—' : '${left.ceil()} s', style: style);
      });
}

String lightLabel(String state) => switch (state) {
      'GREEN' => 'green',
      'YELLOW' => 'yellow',
      'ALL_RED' => 'all red',
      'FLASHING' => 'flashing',
      _ => state.toLowerCase(),
    };

/// Signal timing as a plain table: one row per phase with green, yellow, all-red and red in
/// seconds. When [reference] (the fixed plan) is given, each green also shows its change
/// against it. The current phase is highlighted.
class SignalTimingTable extends StatelessWidget {
  const SignalTimingTable({
    super.key,
    required this.timings,
    required this.cycleS,
    this.reference,
    this.referenceCycleS,
    this.highlightPhase,
  });

  final List<PhaseTiming> timings;
  final double cycleS;
  final List<PhaseTiming>? reference;
  final double? referenceCycleS;
  final String? highlightPhase;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final head = theme.textTheme.labelMedium?.copyWith(color: muted);
    String sec(double v) => '${Units.number(v, decimals: 0)} s';
    TableRow row(PhaseTiming t) {
      final active = t.phase == highlightPhase;
      final ref = reference?.where((r) => r.phase == t.phase).firstOrNull;
      final delta = ref == null ? null : t.greenS - ref.greenS;
      final style = theme.textTheme.bodyMedium?.copyWith(
        fontWeight: active ? FontWeight.w800 : FontWeight.w500,
        fontFeatures: const [FontFeature.tabularFigures()],
      );
      return TableRow(
        decoration: BoxDecoration(
          color: active ? theme.colorScheme.primary.withValues(alpha: 0.07) : null,
          borderRadius: BorderRadius.circular(8),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
            child: Text(shortPhase(t.phase), style: style, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          Text.rich(
            TextSpan(children: [
              TextSpan(text: sec(t.greenS), style: const TextStyle(fontWeight: FontWeight.w800)),
              if (delta != null && delta.abs() >= 1)
                TextSpan(
                  text: '  ${delta > 0 ? '+' : '−'}${delta.abs().toStringAsFixed(0)}',
                  style: TextStyle(
                    color: StatusColors.readable(ModeColors.adaptive, theme.brightness),
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
            ]),
            style: style,
          ),
          Text(sec(t.yellowS), style: style),
          Text(sec(t.allRedS), style: style),
          Text(sec(t.redS), style: style),
        ],
      );
    }

    final cycleChanged = referenceCycleS != null && (referenceCycleS! - cycleS).abs() >= 1;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Table(
        columnWidths: const {0: FlexColumnWidth(1.1), 1: FlexColumnWidth(1.5), 2: FlexColumnWidth(1), 3: FlexColumnWidth(1), 4: FlexColumnWidth(1)},
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        children: [
          TableRow(children: [
            Padding(padding: const EdgeInsets.only(left: 6, bottom: 4), child: Text('Phase', style: head)),
            Text('Green', style: head),
            Text('Yellow', style: head),
            Text('All-red', style: head),
            Text('Red', style: head),
          ]),
          for (final t in timings) row(t),
        ],
      ),
      const SizedBox(height: 6),
      Padding(
        padding: const EdgeInsets.only(left: 6),
        child: Text(
          'Cycle ${sec(cycleS)}'
          '${cycleChanged ? ' · fixed plan ${sec(referenceCycleS!)}' : ''}'
          '${reference != null ? ' · green change against the fixed plan' : ''}',
          style: theme.textTheme.labelMedium?.copyWith(color: muted),
        ),
      ),
    ]);
  }
}

/// Intersection code and name, then the current light: "N/S green · 12 s".
class SignalTitle extends StatelessWidget {
  const SignalTitle({super.key, required this.code, required this.name, required this.display, required this.serverNow});
  final String code;
  final String name;
  final SignalDisplay? display;
  final DateTime Function() serverNow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final d = display;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
        Text(code, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800, height: 1.1)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: muted)),
        ),
      ]),
      const SizedBox(height: 3),
      if (d == null)
        Text('No signal feed', style: theme.textTheme.bodySmall?.copyWith(color: muted))
      else
        Row(children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: SignalColors.lamp(d.state), shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text('${shortPhase(d.phaseName)} ${lightLabel(d.state)} · ',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
          ),
          SignalCountdown(
            display: d,
            serverNow: serverNow,
            style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w800),
          ),
        ]),
    ]);
  }
}

/// One figure in the "current traffic" row of a control card.
class _Figure extends StatelessWidget {
  const _Figure(this.label, this.value, {this.unit, this.child});
  final String label;
  final String value;
  final String? unit;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      const SizedBox(height: 3),
      child ??
          Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
            Text(value, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800, height: 1.1)),
            if (unit != null) ...[
              const SizedBox(width: 3),
              Text(unit!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ]),
    ]);
  }
}

/// The traffic-control card for one intersection: mode, reason, traffic behind it, timing.
class ControlCard extends StatelessWidget {
  const ControlCard({super.key, required this.item, required this.serverNow, this.onTap, this.showTiming = true});

  final IntersectionTraffic item;
  final DateTime Function() serverNow;
  final VoidCallback? onTap;
  final bool showTiming;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = item.control;
    final display = item.displaySignal;
    final muted = theme.colorScheme.onSurfaceVariant;
    final modeColor = c == null ? StatusColors.neutral : ModeColors.of(c.mode);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(border: Border(left: BorderSide(color: modeColor, width: 4))),
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Header: live light, name, mode.
            Row(children: [
              TrafficLight(state: display?.state ?? 'OFF', lampSize: 10),
              const SizedBox(width: 12),
              Expanded(child: SignalTitle(code: item.code, name: item.name, display: display, serverNow: serverNow)),
              if (c != null) ModeBadge(c.mode),
            ]),
            if (c == null) ...[
              const SizedBox(height: 10),
              Text('Control status not available yet.', style: theme.textTheme.bodySmall?.copyWith(color: muted)),
            ] else ...[
              const SizedBox(height: 12),
              _ReasonBox(control: c),
              const SizedBox(height: 12),
              _TrafficFigures(control: c),
              if (showTiming) ...[
                const SizedBox(height: 14),
                Row(children: [
                  Text(c.timingChanged ? 'Active timing (calculated)' : 'Signal timing (fixed plan)',
                      style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700)),
                  const Spacer(),
                  if (c.timingChanged) Text('advisory', style: theme.textTheme.labelSmall?.copyWith(color: muted)),
                ]),
                const SizedBox(height: 8),
                SignalTimingTable(
                  timings: c.activeTiming,
                  cycleS: c.activeCycleS,
                  reference: c.timingChanged ? c.fixedTiming : null,
                  referenceCycleS: c.timingChanged ? c.fixedCycleS : null,
                  highlightPhase: c.priorityPhase ?? display?.phaseName,
                ),
              ],
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                Text('Policy: ${policyLabel(c.policy)}', style: theme.textTheme.labelSmall?.copyWith(color: muted)),
                Text('·', style: theme.textTheme.labelSmall?.copyWith(color: muted)),
                Ticker(
                  period: const Duration(seconds: 15),
                  builder: (_) => Text('${modeLabel(c.mode)} for ${Units.duration(serverNow().difference(c.since).inSeconds.toDouble())}',
                      style: theme.textTheme.labelSmall?.copyWith(color: muted)),
                ),
                if (display?.virtual ?? false) ...[
                  Text('·', style: theme.textTheme.labelSmall?.copyWith(color: muted)),
                  Tooltip(
                    message: 'No signal hardware is connected; the server runs this plan to show the lights.',
                    child: Text('Lights: virtual controller', style: theme.textTheme.labelSmall?.copyWith(color: muted)),
                  ),
                ],
              ]),
            ],
          ]),
        ),
      ),
    );
  }
}

class _ReasonBox extends StatelessWidget {
  const _ReasonBox({required this.control});
  final ControlStatus control;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = control;
    final color = ModeColors.of(c.mode);
    final pending = c.pending;
    final icon = switch (c.reason) {
      'HIGH_CONGESTION' || 'SEVERE_CONGESTION' || 'CONGESTION_DETECTED' => Icons.trending_up,
      'CONGESTION_EASING' || 'CONGESTION_CLEARED' => Icons.trending_down,
      'INSUFFICIENT_DATA' => Icons.signal_cellular_connected_no_internet_4_bar,
      'EMERGENCY_VEHICLE' => Icons.emergency,
      'MANUAL_FIXED' || 'MANUAL_ADAPTIVE' => Icons.tune,
      _ => Icons.check_circle_outline,
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: theme.brightness == Brightness.dark ? 0.16 : 0.07),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, size: 18, color: StatusColors.readable(color, theme.brightness)),
          const SizedBox(width: 6),
          Text('Reason', style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ]),
        const SizedBox(height: 4),
        Text(c.headline, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 3),
        Text(c.detail, style: theme.textTheme.bodySmall),
        if (pending != null) ...[
          const SizedBox(height: 8),
          Row(children: [
            Icon(Icons.hourglass_top, size: 15, color: ModeColors.of(pending.toMode)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '${pending.toMode == 'ADAPTIVE' ? 'Switching to adaptive' : 'Returning to fixed-time'} in '
                '${pending.inS.ceil()} s ${pending.condition}',
                style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
          ]),
        ],
      ]),
    );
  }
}

class _TrafficFigures extends StatelessWidget {
  const _TrafficFigures({required this.control});
  final ControlStatus control;

  @override
  Widget build(BuildContext context) {
    final t = control.traffic;
    final theme = Theme.of(context);
    final vehicles = t.windowVehicleCount ?? t.vehicleCount.toDouble();
    final speed = t.windowAvgSpeedMps ?? t.avgSpeedMps;
    final wait = t.windowAvgWaitingTimeS ?? t.avgWaitingTimeS;
    final level = t.averagedLevel ?? t.congestionLevel;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Current traffic · ${t.windowS.toStringAsFixed(0)} s average',
          style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      const SizedBox(height: 6),
      LayoutBuilder(builder: (context, c) {
        final figures = [
          _Figure('Vehicles', vehicles.toStringAsFixed(0)),
          _Figure('Average speed', Units.speedValue(speed), unit: 'km/h'),
          _Figure('Congestion', '', child: CongestionBadge(level, compact: true)),
          _Figure('Waiting', wait == null ? '—' : wait.toStringAsFixed(0), unit: wait == null ? null : 's'),
        ];
        final perRow = c.maxWidth >= 360 ? 4 : 2;
        final width = (c.maxWidth - (perRow - 1) * 10) / perRow;
        return Wrap(spacing: 10, runSpacing: 10, children: [
          for (final f in figures) SizedBox(width: width, child: f),
        ]);
      }),
    ]);
  }
}

/// Recent mode change as a list row.
class ModeEventTile extends StatelessWidget {
  const ModeEventTile({super.key, required this.event, this.dense = false});
  final ModeEvent event;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = ModeColors.of(event.toMode);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: dense ? 6 : 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(gradient: ModeColors.gradient(event.toMode), shape: BoxShape.circle),
          child: Icon(ModeColors.icon(event.toMode), color: Colors.white, size: 19),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text(event.intersectionCode, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(width: 6),
              Flexible(
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Flexible(
                    child: Text(modeLabel(event.fromMode),
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
                  ),
                  Icon(Icons.arrow_forward, size: 14, color: theme.colorScheme.onSurfaceVariant),
                  Flexible(
                    child: Text(modeLabel(event.toMode),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w800, color: StatusColors.readable(color, theme.brightness))),
                  ),
                ]),
              ),
            ]),
            Text(event.headline, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
            if (!dense)
              Text(event.detail,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ]),
        ),
        const SizedBox(width: 8),
        Ticker(
          period: const Duration(seconds: 20),
          builder: (_) => Text(Units.ago(event.at),
              style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ),
      ]),
    );
  }
}

/// Map marker: one signal head per approach, placed on the side traffic arrives from, around
/// a hub in the mode colour. North is up (map rotation is disabled on the live map).
class IntersectionSignalMarker extends StatelessWidget {
  const IntersectionSignalMarker({super.key, required this.item, required this.serverNow, this.scale = 1.0});

  static const baseSize = 104.0;

  final IntersectionTraffic item;
  final DateTime Function() serverNow;
  final double scale;

  @override
  Widget build(BuildContext context) {
    final c = item.control;
    final display = item.displaySignal;
    final mode = c?.mode ?? 'UNKNOWN';
    final hub = 38.0 * scale;
    final radius = 36.0 * scale;
    final head = 21.0 * scale;
    final size = baseSize * scale;
    return SizedBox(
      width: size,
      height: size + 18 * scale,
      child: Stack(clipBehavior: Clip.none, alignment: Alignment.center, children: [
        Positioned(
          top: 0,
          left: 0,
          width: size,
          height: size,
          child: Stack(alignment: Alignment.center, children: [
            // Faint cross: the roads.
            Container(width: size * 0.86, height: 6 * scale, color: Colors.black.withValues(alpha: 0.12)),
            Container(width: 6 * scale, height: size * 0.86, color: Colors.black.withValues(alpha: 0.12)),
            for (final h in display?.heads ?? const <SignalHead>[])
              Transform.translate(
                offset: _arrivalOffset(h.bearingDeg, radius),
                child: _Head(light: h.light, size: head),
              ),
            Container(
              width: hub,
              height: hub,
              decoration: BoxDecoration(
                gradient: c == null ? null : ModeColors.gradient(mode),
                color: c == null ? StatusColors.neutral : null,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2.5 * scale),
                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 6 * scale)],
              ),
              child: Icon(ModeColors.icon(mode), color: Colors.white, size: 19 * scale),
            ),
          ]),
        ),
        Positioned(
          bottom: 0,
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 7 * scale, vertical: 2 * scale),
            decoration: BoxDecoration(
              color: const Color(0xFF0F172A).withValues(alpha: 0.88),
              borderRadius: BorderRadius.circular(8 * scale),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(item.code,
                  style: TextStyle(color: Colors.white, fontSize: 11.5 * scale, fontWeight: FontWeight.w800)),
              if (display != null) ...[
                SizedBox(width: 5 * scale),
                Container(
                  width: 7 * scale,
                  height: 7 * scale,
                  decoration: BoxDecoration(color: SignalColors.lamp(display.state), shape: BoxShape.circle),
                ),
                SizedBox(width: 3 * scale),
                SignalCountdown(
                  display: display,
                  serverNow: serverNow,
                  style: TextStyle(color: Colors.white, fontSize: 11 * scale, fontWeight: FontWeight.w700),
                ),
              ],
            ]),
          ),
        ),
      ]),
    );
  }

  /// Vehicles travelling on bearing b arrive from b + 180°, so the head sits on that side.
  static Offset _arrivalOffset(double travelBearingDeg, double radius) {
    final from = (travelBearingDeg + 180) * math.pi / 180;
    return Offset(math.sin(from) * radius, -math.cos(from) * radius);
  }
}

class _Head extends StatelessWidget {
  const _Head({required this.light, required this.size});
  final String light;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = SignalColors.lamp(light);
    final on = light != 'OFF';
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size * 0.17),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(size * 0.3),
        border: Border.all(color: Colors.white.withValues(alpha: 0.9), width: 1.2),
      ),
      child: Container(
        decoration: BoxDecoration(
          color: on ? color : SignalColors.off,
          shape: BoxShape.circle,
          boxShadow: on ? [BoxShadow(color: color.withValues(alpha: 0.9), blurRadius: size * 0.5)] : null,
        ),
      ),
    );
  }
}

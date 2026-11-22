import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../widgets/common.dart' show Ticker;
import '../model/frame_v3.dart';
import '../model/labels.dart';
import '../model/v3_view.dart';
import 'hw_style.dart';
import 'intersection_view.dart';

// Cards for firmware v3 state (four lanes, one green at a time). Every number shown comes from
// the controller's state JSON; nothing is estimated by the app except the local countdown
// between two states (re-anchored on every state).

const _tick = Duration(milliseconds: 100);

String _lower(String? s) => (s ?? '').toLowerCase();

String _s1(double? v) => v == null ? dash : '${v.toStringAsFixed(1)} s';

String v3PhaseLine(V3State s) {
  return switch (s.phase) {
    'GREEN' => 'LANE ${approachName(s.cur).toUpperCase()} — ${s.priorityActive == true ? 'EMERGENCY PRIORITY GREEN' : 'GREEN'}',
    'YELLOW' => 'LANE ${approachName(s.cur).toUpperCase()} — YELLOW',
    'ALL_RED' => 'ALL RED',
    null => dash,
    final p => p,
  };
}

String _interval(String? phase) => switch (phase) {
  'GREEN' => 'green',
  'YELLOW' => 'yellow',
  'ALL_RED' => 'all_red',
  _ => '',
};

String stateLabel(String? st) => switch (st) {
  'APPROACHING' => 'Approaching',
  'QUEUED' => 'Queued',
  'CROSSING' => 'Crossing',
  'IGNORED' => 'Ignored',
  null => dash,
  final s => s,
};

/// Mode badge, requested mode, pending switch, congestion, vehicles.
class V3StatusRow extends StatelessWidget {
  const V3StatusRow({super.key, required this.view});
  final V3View view;

  @override
  Widget build(BuildContext context) {
    final s = view.v3;
    final live = view.isLive;
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Opacity(
          opacity: live || s == null ? 1 : 0.6,
          child: Container(
            key: const ValueKey('mode-badge'),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
            decoration: BoxDecoration(
              gradient: HwColors.modeGradient(s?.mode),
              borderRadius: BorderRadius.circular(24),
              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.15), blurRadius: 8, offset: const Offset(0, 2))],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(HwColors.modeIcon(s?.mode), color: Colors.white, size: 22),
                const SizedBox(width: 8),
                Text(
                  modeName(s?.mode),
                  style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w900, letterSpacing: 1),
                ),
              ],
            ),
          ),
        ),
        HwChip(
          key: const ValueKey('requested-chip'),
          label: 'Requested: ${modeName(s?.requestedMode)}',
          color: StatusColors.info,
          icon: Icons.tune,
          large: true,
        ),
        if (s != null && s.switchPending)
          HwChip(
            key: const ValueKey('pending-chip'),
            label: 'Switching to ${modeName(s.targetMode)} at the next lane decision',
            color: StatusColors.warning,
            icon: Icons.schedule,
            large: true,
          ),
        HwChip(
          key: const ValueKey('congestion-chip'),
          label: 'Congestion: ${levelName(s?.congestion == null ? null : _lower(s!.congestion))}',
          color: HwColors.level(_lower(s?.congestion)),
          icon: Icons.traffic_outlined,
          large: true,
        ),
        HwChip(
          key: const ValueKey('total-chip'),
          label: s?.vehicleCount == null
              ? 'Vehicles: —'
              : '${s!.vehicleCount} ${s.vehicleCount == 1 ? 'vehicle' : 'vehicles'} connected',
          color: StatusColors.info,
          icon: Icons.directions_car_outlined,
          large: true,
        ),
      ],
    );
  }
}

/// The junction: four heads with their real lamps, each lane's MM:SS display, and the countdown
/// of the current phase in the middle.
class V3SignalCard extends StatelessWidget {
  const V3SignalCard({super.key, required this.view, this.title = 'Live signals'});
  final V3View view;
  final String title;

  @override
  Widget build(BuildContext context) {
    final s = view.v3;
    final theme = Theme.of(context);
    return HwCard(
      title: title,
      icon: Icons.traffic,
      trailing: view.showingLastKnown
          ? const HwChip(label: 'Last known state', color: StatusColors.neutral, icon: Icons.history)
          : null,
      child: s == null
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Center(
                child: Column(
                  children: [
                    const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 3)),
                    const SizedBox(height: 12),
                    Text('Waiting for the controller…', style: theme.textTheme.bodyMedium),
                  ],
                ),
              ),
            )
          : Ticker(
              period: _tick,
              builder: (context) {
                final live = view.isLive;
                return Column(
                  children: [
                    IntersectionView(
                      signals: s.signals,
                      countdown: view.countdownS,
                      interval: _interval(s.phase),
                      live: live,
                      displays: {for (final l in v3Lanes) l: view.laneDisplay(l)},
                    ),
                    const SizedBox(height: 12),
                    Text(
                      v3PhaseLine(s),
                      key: const ValueKey('phase-line'),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.5,
                        color: live ? null : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      live ? view.countdownSource : 'Last known state — the countdown is paused',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                );
              },
            ),
    );
  }
}

/// Current phase: target green, elapsed, remaining, next phase, why this mode.
class V3TimingCard extends StatelessWidget {
  const V3TimingCard({super.key, required this.view});
  final V3View view;

  @override
  Widget build(BuildContext context) {
    final s = view.v3;
    final t = s?.timing;
    final theme = Theme.of(context);
    final fixed = s?.isFixed ?? false;
    return HwCard(
      title: 'Current phase',
      icon: fixed ? Icons.schedule : Icons.auto_mode,
      trailing: t?.priority == true
          ? const HwChip(label: 'Priority hold', color: StatusColors.emergency, icon: Icons.emergency)
          : null,
      child: Ticker(
        period: _tick,
        builder: (context) {
          final color = view.isLive ? HwColors.interval(_interval(s?.phase)) : StatusColors.neutral;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: HwFigure(s?.phase == 'GREEN' ? 'Planned green' : 'Next green (plan)', _s1(t?.targetGreenS), big: true),
                  ),
                  Expanded(child: HwFigure('Elapsed', secondsFromMs(view.elapsedMs), big: true)),
                  Expanded(child: HwFigure('Remaining', secondsFromMs(view.remainingMs), big: true)),
                ],
              ),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  key: const ValueKey('timing-progress'),
                  value: view.progress ?? 0,
                  minHeight: 10,
                  color: color,
                  backgroundColor: theme.colorScheme.surfaceContainerHigh,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Text('Next  ', style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  Text(switch (t?.nextPhase) {
                    'ALL_RED' => 'ALL RED',
                    'NEXT_GREEN' => 'NEXT LANE GREEN',
                    null => dash,
                    final p => p,
                  }, style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w800)),
                ],
              ),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: (fixed ? ModeColors.fixed : ModeColors.adaptive).withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: (fixed ? ModeColors.fixed : ModeColors.adaptive).withValues(alpha: 0.25)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Mode reason (from the controller)',
                      style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      orDash(s?.modeReason),
                      key: const ValueKey('timing-reason'),
                      style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Per lane: signal and display, queue counts, Qw, density, flow ratio and planned green.
class V3LanesCard extends StatelessWidget {
  const V3LanesCard({super.key, required this.view});
  final V3View view;

  @override
  Widget build(BuildContext context) {
    final s = view.v3;
    final theme = Theme.of(context);
    final muted = theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    String n(num? v, [int d = 0]) => v == null ? dash : v.toStringAsFixed(d);
    return HwCard(
      title: 'Lanes',
      icon: Icons.call_split,
      child: Ticker(
        period: _tick,
        builder: (context) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            key: const ValueKey('lanes-table'),
            headingRowHeight: 32,
            dataRowMinHeight: 38,
            dataRowMaxHeight: 44,
            columnSpacing: 14,
            horizontalMargin: 4,
            headingTextStyle: muted,
            columns: const [
              DataColumn(label: Text('Lane')),
              DataColumn(label: Text('Signal')),
              DataColumn(label: Text('Queued'), numeric: true),
              DataColumn(label: Text('Appr.'), numeric: true),
              DataColumn(label: Text('Cross.'), numeric: true),
              DataColumn(label: Text('Qw'), numeric: true),
              DataColumn(label: Text('Density')),
              DataColumn(label: Text('y'), numeric: true),
              DataColumn(label: Text('Green s'), numeric: true),
            ],
            rows: [
              for (final name in v3Lanes)
                () {
                  final l = s?.lane(name);
                  return DataRow(
                    cells: [
                      DataCell(
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _LaneDot(name, signal: l?.sig),
                            const SizedBox(width: 6),
                            Text(approachName(name), style: const TextStyle(fontWeight: FontWeight.w700)),
                            if ((l?.emerg ?? 0) > 0) ...[
                              const SizedBox(width: 4),
                              const Tooltip(
                                message: 'Emergency vehicle on this lane',
                                child: Icon(Icons.emergency, key: ValueKey('ev-icon'), color: StatusColors.emergency, size: 18),
                              ),
                            ],
                          ],
                        ),
                      ),
                      DataCell(
                        Text(
                          '${l?.sig ?? dash}  ${view.laneDisplay(name) ?? '--:--'}',
                          style: const TextStyle(fontWeight: FontWeight.w800, fontFeatures: [FontFeature.tabularFigures()]),
                        ),
                      ),
                      DataCell(Text(n(l?.queued))),
                      DataCell(Text(n(l?.approaching))),
                      DataCell(Text(n(l?.crossing))),
                      DataCell(Text(n(l?.qw, 1))),
                      DataCell(
                        HwChip(
                          label: levelName(l?.density == null ? null : _lower(l!.density)),
                          color: HwColors.level(_lower(l?.density)),
                        ),
                      ),
                      DataCell(Text(n(l?.y, 2))),
                      DataCell(Text(l?.greenS == null ? dash : (l!.greenS == 0 ? 'skip' : l.greenS!.toStringAsFixed(1)))),
                    ],
                  );
                }(),
            ],
          ),
        ),
      ),
    );
  }
}

class _LaneDot extends StatelessWidget {
  const _LaneDot(this.lane, {this.signal});
  final String lane;
  final String? signal;

  @override
  Widget build(BuildContext context) => Container(
    width: 24,
    height: 24,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      shape: BoxShape.circle,
      border: Border.all(color: HwColors.lamp(signal), width: 2.5),
    ),
    child: Text(lane, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 11.5)),
  );
}

/// The Webster preview plan the controller reports (recomputed every second).
class V3PlanCard extends StatelessWidget {
  const V3PlanCard({super.key, required this.view});
  final V3View view;

  @override
  Widget build(BuildContext context) {
    final p = view.v3?.plan;
    final theme = Theme.of(context);
    String v(double? x, {int d = 1, String unit = ''}) => x == null ? dash : '${x.toStringAsFixed(d)}$unit';
    final items = <(String, String)>[
      ('Cycle C0', v(p?.cycleS, unit: ' s')),
      ('Y = Σ y', v(p?.y, d: 2)),
      ('Lost time L', v(p?.lostS, d: 0, unit: ' s')),
      ('K (approaching)', v(p?.k, d: 1)),
      ('Saturation s', v(p?.satFlow, d: 0, unit: ' veh/h')),
      ('Window', v(p?.windowS, d: 0, unit: ' s')),
    ];
    return HwCard(
      title: 'Webster plan (preview)',
      icon: Icons.functions,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, c) {
              final perRow = c.maxWidth >= 420 ? 3 : 2;
              final w = (c.maxWidth - (perRow - 1) * 12) / perRow;
              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [for (final (label, value) in items) SizedBox(width: w, child: HwFigure(label, value))],
              );
            },
          ),
          const SizedBox(height: 10),
          Text(
            'q = Qw·3600/window · y = q/s · C0 = (1.5L + 5)/(1 − Y), 30–90 s · g = (y/Y)(C0 − L), 5–30 s. '
            'Per-lane y and green are in the Lanes card.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// Packets, uptime and totals reported by the controller.
class V3SystemCard extends StatelessWidget {
  const V3SystemCard({super.key, required this.view, this.extra = const []});
  final V3View view;

  /// More (label, value) pairs, e.g. the transport's round-trip time in Digital V2I.
  final List<(String, String)> extra;

  @override
  Widget build(BuildContext context) {
    final s = view.v3;
    final items = <(String, String)>[
      ('Controller', orDash(s?.controller)),
      ('Uptime', uptime(s?.uptimeS == null ? null : s!.uptimeS! * 1000)),
      ('Packets received', orDash(s?.rx)),
      ('Bad packets', orDash(s?.bad)),
      ('Queued (all lanes)', orDash(s?.queuedTotal)),
      ('Approaching (all)', orDash(s?.approachingTotal)),
      ...extra,
    ];
    return HwCard(
      title: 'Controller',
      icon: Icons.memory,
      child: LayoutBuilder(
        builder: (context, c) {
          final perRow = c.maxWidth >= 420 ? 3 : 2;
          final w = (c.maxWidth - (perRow - 1) * 12) / perRow;
          final theme = Theme.of(context);
          return Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final (label, value) in items)
                SizedBox(
                  width: w,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                      const SizedBox(height: 3),
                      Text(value, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// The controller's vehicle table (lane decided from the coordinates only).
class V3VehiclesCard extends StatelessWidget {
  const V3VehiclesCard({super.key, required this.view, this.initiallyExpanded = false, this.rttMs});
  final V3View view;
  final bool initiallyExpanded;

  /// Digital V2I only: packet -> ACK round trip per vehicle id, as reported by the vehicles.
  final Map<int, int>? rttMs;

  @override
  Widget build(BuildContext context) {
    final list = view.v3?.vehicles ?? const <V3Vehicle>[];
    final theme = Theme.of(context);
    final muted = theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    String n(num? v, [int d = 0, String unit = '']) => v == null ? dash : '${v.toStringAsFixed(d)}$unit';
    final showRtt = rttMs != null;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          key: const ValueKey('vehicles-tile'),
          initiallyExpanded: initiallyExpanded,
          tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          leading: Icon(Icons.list_alt, color: theme.colorScheme.primary),
          title: Text('Vehicles (${list.length})', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
          subtitle: Text(
            'Lane decided by the intersection from position, speed and heading',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          children: [
            if (list.isEmpty)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text('No vehicles connected.', style: theme.textTheme.bodyMedium),
              )
            else
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  key: const ValueKey('vehicles-table'),
                  headingRowHeight: 32,
                  dataRowMinHeight: 34,
                  dataRowMaxHeight: 40,
                  columnSpacing: 14,
                  horizontalMargin: 4,
                  headingTextStyle: muted,
                  columns: [
                    const DataColumn(label: Text('ID')),
                    const DataColumn(label: Text('Type')),
                    const DataColumn(label: Text('Device')),
                    const DataColumn(label: Text('Lane')),
                    const DataColumn(label: Text('Test lane')),
                    const DataColumn(label: Text('State')),
                    const DataColumn(label: Text('Speed'), numeric: true),
                    const DataColumn(label: Text('Distance'), numeric: true),
                    const DataColumn(label: Text('Heading'), numeric: true),
                    const DataColumn(label: Text('RSSI'), numeric: true),
                    const DataColumn(label: Text('Pkts'), numeric: true),
                    const DataColumn(label: Text('Lost'), numeric: true),
                    const DataColumn(label: Text('Age'), numeric: true),
                    if (showRtt) const DataColumn(label: Text('RTT'), numeric: true),
                  ],
                  rows: [
                    for (final v in list)
                      DataRow(
                        cells: [
                          DataCell(Text(orDash(v.id), style: const TextStyle(fontWeight: FontWeight.w700))),
                          DataCell(
                            v.isEmergency
                                ? const Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.emergency, color: StatusColors.emergency, size: 16),
                                      SizedBox(width: 4),
                                      Text('Emergency'),
                                    ],
                                  )
                                : Text(v.ty == null ? dash : 'Normal'),
                          ),
                          DataCell(Text(orDash(v.hw))),
                          DataCell(Text(orDash(v.lane))),
                          DataCell(
                            v.mismatch
                                ? Tooltip(
                                    message: 'Lane from the coordinates differs from the test data',
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Icon(Icons.warning_amber, color: StatusColors.warning, size: 16),
                                        const SizedBox(width: 3),
                                        Text(orDash(v.testLane)),
                                      ],
                                    ),
                                  )
                                : Text(orDash(v.testLane)),
                          ),
                          DataCell(Text(stateLabel(v.st))),
                          DataCell(Text(n(v.spdKmh, 1, ' km/h'))),
                          DataCell(Text(n(v.distM, 1, ' m'))),
                          DataCell(Text(v.hdg == null || v.hdg! < 0 ? dash : '${v.hdg}°')),
                          DataCell(Text(v.rssi == null ? dash : '${v.rssi} dBm')),
                          DataCell(Text(orDash(v.pkts))),
                          DataCell(Text(orDash(v.lost))),
                          DataCell(Text(n(v.ageS, 1, ' s'))),
                          if (showRtt) DataCell(Text(rttMs![v.id] == null ? dash : '${rttMs![v.id]} ms')),
                        ],
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../widgets/common.dart' show Ticker;
import '../model/frame.dart';
import '../model/labels.dart';
import '../monitor.dart';
import 'hw_style.dart';
import 'intersection_view.dart';

const _tick = Duration(milliseconds: 100);

/// 2. Mode and status: large mode badge, controller state, congestion, vehicles.
class StatusRow extends StatelessWidget {
  const StatusRow({super.key});

  @override
  Widget build(BuildContext context) {
    final m = context.watch<HardwareMonitor>();
    final s = m.state;
    final live = m.isLive;
    return Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
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
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(HwColors.modeIcon(s?.mode), color: Colors.white, size: 22),
            const SizedBox(width: 8),
            Text(modeName(s?.mode),
                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w900, letterSpacing: 1)),
          ]),
        ),
      ),
      HwChip(
        key: const ValueKey('ctrl-chip'),
        label: 'Controller: ${ctrlName(s?.ctrl)}',
        color: HwColors.ctrl(s?.ctrl),
        icon: HwColors.ctrlIcon(s?.ctrl),
        large: true,
      ),
      HwChip(
        key: const ValueKey('congestion-chip'),
        label: 'Congestion: ${levelName(s?.congestion)}',
        color: HwColors.level(s?.congestion),
        icon: Icons.traffic_outlined,
        large: true,
      ),
      HwChip(
        key: const ValueKey('total-chip'),
        label: s?.totalVehicles == null ? 'Vehicles: —' : '${s!.totalVehicles} ${s.totalVehicles == 1 ? 'vehicle' : 'vehicles'}',
        color: StatusColors.info,
        icon: Icons.directions_car_outlined,
        large: true,
      ),
    ]);
  }
}

/// 3. Live signal card: the intersection with its four heads and the countdown.
class LiveSignalCard extends StatelessWidget {
  const LiveSignalCard({super.key});

  @override
  Widget build(BuildContext context) {
    final m = context.watch<HardwareMonitor>();
    final s = m.state;
    final theme = Theme.of(context);
    return HwCard(
      title: 'Live signals',
      icon: Icons.traffic,
      trailing: m.showingLastKnown ? const HwChip(label: 'Last known state', color: StatusColors.neutral, icon: Icons.history) : null,
      child: s == null
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Center(
                child: Column(children: [
                  const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 3)),
                  const SizedBox(height: 12),
                  Text('Waiting for the controller…', style: theme.textTheme.bodyMedium),
                ]),
              ),
            )
          : Ticker(
              period: _tick,
              builder: (context) {
                final live = m.isLive;
                return Column(children: [
                  IntersectionView(signals: s.signals, countdown: m.countdownS, interval: s.interval, live: live),
                  const SizedBox(height: 12),
                  Text(phaseLine(s.phase, s.interval),
                      key: const ValueKey('phase-line'),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.5,
                        color: live ? null : theme.colorScheme.onSurfaceVariant,
                      )),
                  const SizedBox(height: 2),
                  Text(
                    live
                        ? (m.usingSimulator ? 'Countdown from the simulator' : 'Countdown from the controller')
                        : 'Last known state — the countdown is paused',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ]);
              },
            ),
    );
  }
}

/// 4. Adaptive timing (or "Fixed plan" in fixed mode).
class TimingCard extends StatelessWidget {
  const TimingCard({super.key});

  @override
  Widget build(BuildContext context) {
    final m = context.watch<HardwareMonitor>();
    final s = m.state;
    final t = s?.timing;
    final theme = Theme.of(context);
    final fixed = s?.isFixed ?? false;
    final targetLabel = s?.interval == null || s?.interval == 'green' ? 'Target green' : 'Target (${intervalName(s?.interval).toLowerCase()})';
    return HwCard(
      title: fixed ? 'Fixed plan' : (s?.isAdaptive ?? false ? 'Adaptive timing' : 'Timing'),
      icon: fixed ? Icons.schedule : Icons.auto_mode,
      child: Ticker(
        period: _tick,
        builder: (context) {
          final progress = m.progress;
          final color = m.isLive ? HwColors.interval(s?.interval) : StatusColors.neutral;
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: HwFigure(targetLabel, seconds(t?.targetS), big: true)),
              Expanded(child: HwFigure('Elapsed', secondsFromMs(m.elapsedMs), big: true)),
              Expanded(child: HwFigure('Remaining', secondsFromMs(m.remainingMs), big: true)),
            ]),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                key: const ValueKey('timing-progress'),
                value: progress ?? 0,
                minHeight: 10,
                color: color,
                backgroundColor: theme.colorScheme.surfaceContainerHigh,
              ),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Text('Next phase  ', style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              Text(phaseName(t?.nextPhase), style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w800)),
            ]),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: (fixed ? ModeColors.fixed : ModeColors.adaptive).withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: (fixed ? ModeColors.fixed : ModeColors.adaptive).withValues(alpha: 0.25)),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(fixed ? 'Fixed plan' : 'Reason',
                    style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                const SizedBox(height: 2),
                Text(
                  fixed
                      ? 'Green times come from the controller\'s configured plan${t?.reason == null ? '' : ' (${t!.reason})'}.'
                      : orDash(t?.reason),
                  key: const ValueKey('timing-reason'),
                  style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
              ]),
            ),
          ]);
        },
      ),
    );
  }
}

/// 5. Traffic per approach.
class TrafficCard extends StatelessWidget {
  const TrafficCard({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<HardwareMonitor>().state;
    final theme = Theme.of(context);
    final muted = theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    TableRow row(String a) {
      final ap = s?.approaches[a];
      return TableRow(children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Row(children: [
            _ApproachDot(a, signal: s?.signals[a]),
            const SizedBox(width: 8),
            Flexible(child: Text(approachName(a), style: const TextStyle(fontWeight: FontWeight.w700))),
            if (ap?.ev == true) ...[
              const SizedBox(width: 6),
              const Tooltip(
                message: 'Emergency vehicle on this approach',
                child: Icon(Icons.emergency, key: ValueKey('ev-icon'), color: StatusColors.emergency, size: 20),
              ),
            ],
          ]),
        ),
        _cell(orDash(ap?.queued), theme),
        _cell(orDash(ap?.approaching), theme),
        Align(
          alignment: Alignment.centerLeft,
          child: HwChip(label: levelName(ap?.level), color: HwColors.level(ap?.level)),
        ),
      ]);
    }

    return HwCard(
      title: 'Traffic',
      icon: Icons.directions_car_filled_outlined,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Table(
          columnWidths: const {0: FlexColumnWidth(1.5), 1: FlexColumnWidth(1), 2: FlexColumnWidth(1.2), 3: FlexColumnWidth(1.2)},
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          children: [
            TableRow(children: [
              Text('Approach', style: muted),
              Text('Queued', style: muted),
              Text('Approaching', style: muted),
              Text('Level', style: muted),
            ]),
            for (final a in approaches) row(a),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Demand  NS ${orDash(s?.demand['NS'])} · EW ${orDash(s?.demand['EW'])} vehicles',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ]),
    );
  }
}

Widget _cell(String text, ThemeData theme) => Text(text,
    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800, fontFeatures: const [FontFeature.tabularFigures()]));

class _ApproachDot extends StatelessWidget {
  const _ApproachDot(this.approach, {this.signal});
  final String approach;
  final String? signal;

  @override
  Widget build(BuildContext context) => Container(
        width: 26,
        height: 26,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          shape: BoxShape.circle,
          border: Border.all(color: HwColors.lamp(signal), width: 2.5),
        ),
        child: Text(approach, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
      );
}

/// 6. Signal plan: NS and EW, green / yellow / all-red / red in seconds.
class PlanCard extends StatelessWidget {
  const PlanCard({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<HardwareMonitor>().state;
    final theme = Theme.of(context);
    final muted = theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    String sec(double? v) => v == null ? dash : v.toStringAsFixed(v == v.roundToDouble() ? 0 : 1);
    TableRow row(String p) {
      final plan = s?.plan[p];
      final active = s?.phase == p;
      final style = theme.textTheme.titleSmall?.copyWith(
          fontWeight: active ? FontWeight.w900 : FontWeight.w600, fontFeatures: const [FontFeature.tabularFigures()]);
      return TableRow(
        decoration: BoxDecoration(
          color: active ? theme.colorScheme.primary.withValues(alpha: 0.07) : null,
          borderRadius: BorderRadius.circular(8),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 6),
            child: Text(p == 'NS' ? 'N/S' : 'E/W', style: style),
          ),
          Text(sec(plan?.green), style: style),
          Text(sec(plan?.yellow), style: style),
          Text(sec(plan?.allRed), style: style),
          Text(sec(plan?.red), style: style),
        ],
      );
    }

    return HwCard(
      title: 'Signal plan',
      icon: Icons.table_chart_outlined,
      trailing: Text('seconds', style: muted),
      child: Table(
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        children: [
          TableRow(children: [
            Padding(padding: const EdgeInsets.only(left: 6, bottom: 4), child: Text('Phase', style: muted)),
            Text('Green', style: muted),
            Text('Yellow', style: muted),
            Text('All-red', style: muted),
            Text('Red', style: muted),
          ]),
          for (final p in phases) row(p),
        ],
      ),
    );
  }
}

/// 7. V2I link and controller health.
class SystemCard extends StatelessWidget {
  const SystemCard({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<HardwareMonitor>().state;
    final v = s?.v2i;
    final h = s?.health;
    final link = v?.link;
    final items = <(String, Widget)>[
      (
        'V2I link',
        HwChip(
          label: link == 'ok' ? 'OK' : (link == 'lost' ? 'LOST' : orDash(link?.toUpperCase())),
          color: link == 'ok' ? StatusColors.ok : (link == 'lost' ? StatusColors.warning : StatusColors.neutral),
          icon: link == 'ok' ? Icons.wifi_tethering : Icons.wifi_tethering_off,
        )
      ),
      ('Active vehicles', _value(orDash(v?.activeVehicles))),
      ('Packets / s', _value(v?.pktsPerS == null ? dash : v!.pktsPerS!.toStringAsFixed(1))),
      ('Last packet', _value(v?.lastPktMsAgo == null ? dash : '${v!.lastPktMsAgo} ms ago')),
      ('Rejected packets', _value(orDash(v?.rejected))),
      ('Controller uptime', _value(uptime(s?.uptimeMs))),
      ('Firmware', _value(orDash(h?.firmware))),
      ('Clients', _value(orDash(h?.clients))),
      ('Free heap', _value(h?.heap == null ? dash : '${h!.heap} bytes')),
    ];
    return HwCard(
      title: 'V2I & system',
      icon: Icons.memory,
      child: LayoutBuilder(builder: (context, c) {
        final perRow = c.maxWidth >= 420 ? 3 : 2;
        final w = (c.maxWidth - (perRow - 1) * 12) / perRow;
        final theme = Theme.of(context);
        return Wrap(spacing: 12, runSpacing: 12, children: [
          for (final (label, value) in items)
            SizedBox(
              width: w,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                const SizedBox(height: 3),
                value,
              ]),
            ),
        ]);
      }),
    );
  }

  static Widget _value(String text) => Builder(
        builder: (context) => Text(text,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
      );
}

/// 8. Vehicles reported by the controller (collapsed by default).
class VehiclesCard extends StatelessWidget {
  const VehiclesCard({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<HardwareMonitor>().state;
    final list = s?.vehicles ?? const <HwVehicle>[];
    final theme = Theme.of(context);
    final muted = theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    String kmh(double? spd) => spd == null ? dash : '${(spd * speedUnitToKmh).toStringAsFixed(0)} km/h';
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          key: const ValueKey('vehicles-tile'),
          initiallyExpanded: false,
          tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          leading: Icon(Icons.list_alt, color: theme.colorScheme.primary),
          title: Text('Vehicles (${list.length})', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
          children: [
            if (list.isEmpty)
              Padding(padding: const EdgeInsets.all(8), child: Text('No vehicles reported.', style: theme.textTheme.bodyMedium))
            else
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  headingRowHeight: 32,
                  dataRowMinHeight: 34,
                  dataRowMaxHeight: 40,
                  columnSpacing: 16,
                  horizontalMargin: 4,
                  headingTextStyle: muted,
                  columns: const [
                    DataColumn(label: Text('ID')),
                    DataColumn(label: Text('Type')),
                    DataColumn(label: Text('App.')),
                    DataColumn(label: Text('State')),
                    DataColumn(label: Text('Distance'), numeric: true),
                    DataColumn(label: Text('Speed'), numeric: true),
                    DataColumn(label: Text('ETA'), numeric: true),
                  ],
                  rows: [
                    for (final v in list)
                      DataRow(cells: [
                        DataCell(Text(orDash(v.id), style: const TextStyle(fontWeight: FontWeight.w700))),
                        DataCell(v.isEmergency
                            ? const Row(mainAxisSize: MainAxisSize.min, children: [
                                Icon(Icons.emergency, color: StatusColors.emergency, size: 16),
                                SizedBox(width: 4),
                                Text('Emergency'),
                              ])
                            : Text(v.type == null ? dash : (v.type == 'normal' ? 'Normal' : v.type!))),
                        DataCell(Text(orDash(v.approach))),
                        DataCell(Text(vehicleStateName(v.state))),
                        DataCell(Text(v.distM == null ? dash : '${v.distM!.toStringAsFixed(1)} m')),
                        DataCell(Text(kmh(v.speed))),
                        DataCell(Text(seconds(v.etaS, decimals: v.etaS != null && v.etaS! % 1 != 0 ? 1 : 0))),
                      ]),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 9. Event log: last 20, newest first, local time.
class EventLogCard extends StatelessWidget {
  const EventLogCard({super.key});

  @override
  Widget build(BuildContext context) {
    final m = context.watch<HardwareMonitor>();
    final theme = Theme.of(context);
    return HwCard(
      title: 'Event log',
      icon: Icons.history,
      trailing: Text('last ${HardwareMonitor.maxEvents}', style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      child: m.events.isEmpty
          ? Text('No events yet.', style: theme.textTheme.bodyMedium)
          : Column(children: [
              for (final e in m.events)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    SizedBox(
                      width: 64,
                      child: Text(clock(e.at),
                          style: theme.textTheme.labelMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant, fontFeatures: const [FontFeature.tabularFigures()])),
                    ),
                    Icon(_eventIcon(e), size: 18, color: _eventColor(e)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                          Text(e.title, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
                          if (e.fromApp) const HwChip(label: 'App', color: StatusColors.neutral),
                          if (e.simulated) const HwChip(label: 'SIM', color: StatusColors.simulated),
                        ]),
                        if (e.detail != null && e.detail!.isNotEmpty)
                          Text(e.detail!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                      ]),
                    ),
                  ]),
                ),
            ]),
    );
  }

  static IconData _eventIcon(LogEntry e) => switch (e.event) {
        'phase_change' => Icons.traffic,
        'mode_change' => Icons.swap_horiz,
        'ev_request' || 'preempt_start' || 'preempt_end' => Icons.emergency,
        'v2i_lost' => Icons.wifi_tethering_off,
        'v2i_restored' => Icons.wifi_tethering,
        'restart' => Icons.power_settings_new,
        _ => e.fromApp ? Icons.restart_alt : Icons.info_outline,
      };

  static Color _eventColor(LogEntry e) => switch (e.event) {
        'ev_request' || 'preempt_start' || 'preempt_end' => StatusColors.emergency,
        'v2i_lost' => StatusColors.warning,
        'v2i_restored' => StatusColors.ok,
        _ => e.fromApp ? StatusColors.alert : StatusColors.info,
      };
}

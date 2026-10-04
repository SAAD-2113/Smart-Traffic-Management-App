import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/units.dart';
import '../../data/models/control.dart';
import '../../data/models/traffic.dart';
import '../../widgets/brand.dart';
import '../../widgets/charts.dart';
import '../../widgets/common.dart';
import '../../widgets/signal_widgets.dart';
import 'intersection_detail_screen.dart';
import 'live_controller.dart';

/// Traffic control centre: what every signal is doing, why, and the network picture.
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final live = context.watch<LiveController>();
    final o = live.overview;
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= 1100;

    return Scaffold(
      body: o == null
          ? (live.error != null ? ErrorView(message: live.error!, onRetry: live.refresh) : const LoadingView())
          : RefreshIndicator(
              onRefresh: live.refresh,
              child: ListView(padding: EdgeInsets.zero, children: [
                _Header(overview: o),
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1400),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        for (final e in live.emergencies)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: MessageBanner(
                              icon: Icons.emergency,
                              color: StatusColors.emergency,
                              text: 'Emergency: ${e.vehicleCode} (${e.vehicleType.toLowerCase().replaceAll('_', ' ')}'
                                  '${e.isSimulated ? ', simulated' : ''})'
                                  '${e.nextIntersectionCode != null ? ' heading to ${e.nextIntersectionCode}' : ''}'
                                  '${e.etaS != null ? ', ETA ${e.etaS!.toStringAsFixed(0)} s' : ''}'
                                  ' · ${Units.speed(e.speedMps)}',
                            ),
                          ),
                        _ModeSummary(overview: o, intersections: live.intersections),
                        const SizedBox(height: 12),
                        _KeyFigures(overview: o, columns: width >= 900 ? 3 : 2),
                        SectionHeader(
                          'Signal control',
                          subtitle: 'Mode, reason and timing for each intersection',
                          trailing: IconButton(
                            tooltip: 'How switching works',
                            icon: const Icon(Icons.help_outline),
                            onPressed: () => _showRules(context, live.controlConfig),
                          ),
                        ),
                        if (live.intersections.isEmpty)
                          const EmptyState(icon: Icons.traffic, title: 'No intersections configured')
                        else
                          _ControlGrid(items: live.intersections.where((i) => i.isActive).toList(), columns: wide ? 2 : 1),
                        const SectionHeader('Mode changes', subtitle: 'Switches between fixed-time and adaptive, newest first'),
                        _ModeLog(events: live.modeEvents),
                        const SectionHeader('Transmitting vehicles', subtitle: 'Last 30 minutes (since this screen opened)'),
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(8, 16, 16, 8),
                            child: TimeLineChart(
                              unit: 'vehicles',
                              series: [
                                ChartSeries(
                                  label: 'Transmitting',
                                  color: ChartColors.primary(context),
                                  points: [for (final p in live.trend) ChartPoint(p.time, p.transmitting.toDouble())],
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SectionHeader('Average speed'),
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(8, 16, 16, 8),
                            child: TimeLineChart(
                              unit: 'km/h',
                              series: [
                                ChartSeries(
                                  label: 'Average speed',
                                  color: ChartColors.primary(context),
                                  points: [
                                    for (final p in live.trend)
                                      ChartPoint(p.time, p.avgSpeedMps == null ? null : Units.kmh(p.avgSpeedMps!)),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SectionHeader('System status'),
                        _SystemCard(overview: o),
                      ]),
                    ),
                  ),
                ),
              ]),
            ),
    );
  }

  static void _showRules(BuildContext context, ControlConfig? config) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: _RulesContent(config: config),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.overview});
  final TrafficOverview overview;

  @override
  Widget build(BuildContext context) {
    final live = context.watch<LiveController>();
    final s = overview.system;
    final (connLabel, connColor) = switch (live.connection) {
      LiveConnection.live => ('Live', SignalColors.green),
      LiveConnection.polling => ('Polling', SignalColors.yellow),
      LiveConnection.connecting => ('Connecting', Colors.white70),
      LiveConnection.offline => ('Offline', SignalColors.red),
    };
    return GradientHeader(
      title: 'Traffic Control Center',
      icon: Icons.traffic,
      actions: [
        IconButton(
          tooltip: 'Refresh',
          onPressed: live.refresh,
          icon: const Icon(Icons.refresh, color: Colors.white),
        ),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Ticker(
          builder: (_) => Text('Updated ${Units.ago(live.lastUpdate)} · ${overview.activeIntersections} intersections',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 13)),
        ),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          HeaderPill(label: connLabel, dotColor: connColor),
          HeaderPill(
            label: s.engineRunning ? 'Engine running' : 'Engine stopped',
            icon: s.engineRunning ? Icons.memory : Icons.warning_amber,
          ),
          if (s.simulationRunning) const HeaderPill(label: 'Demo simulation', icon: Icons.science),
          if (s.externalSources.isNotEmpty) HeaderPill(label: s.externalSources.join(', '), icon: Icons.hub),
        ]),
      ]),
    );
  }
}

/// How many intersections are in each mode right now.
class _ModeSummary extends StatelessWidget {
  const _ModeSummary({required this.overview, required this.intersections});
  final TrafficOverview overview;
  final List<IntersectionTraffic> intersections;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final auto = intersections.where((i) => i.control?.policy == 'AUTO').length;
    final active = intersections.where((i) => i.isActive).length;
    final cells = [
      ('FIXED_TIME', overview.fixedTimeIntersections, 'Fixed-time', 'Normal traffic, configured plan'),
      ('ADAPTIVE', overview.adaptiveIntersections, 'Adaptive', 'Timing from current traffic'),
      ('EMERGENCY_PRIORITY', overview.emergencyPriorityIntersections, 'Emergency', 'Priority for an emergency vehicle'),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text('Signal control now', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
            const Spacer(),
            Text('Automatic switching: $auto of $active',
                style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ]),
          const SizedBox(height: 12),
          LayoutBuilder(builder: (context, c) {
            final w = (c.maxWidth - 2 * 10) / 3;
            final compact = w < 190;
            return Wrap(spacing: 10, runSpacing: 10, children: [
              for (final (mode, count, label, hint) in cells)
                SizedBox(
                  width: w,
                  child: compact
                      ? Container(
                          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
                          decoration: BoxDecoration(
                            color: ModeColors.of(mode).withValues(alpha: theme.brightness == Brightness.dark ? 0.14 : 0.06),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: ModeColors.of(mode).withValues(alpha: count > 0 ? 0.45 : 0.15)),
                          ),
                          child: Column(children: [
                            Container(
                              width: 34,
                              height: 34,
                              decoration: BoxDecoration(gradient: ModeColors.gradient(mode), shape: BoxShape.circle),
                              child: Icon(ModeColors.icon(mode), color: Colors.white, size: 18),
                            ),
                            const SizedBox(height: 6),
                            Text('$count', style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800, height: 1)),
                            const SizedBox(height: 2),
                            Text(label, style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700)),
                          ]),
                        )
                      : Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: ModeColors.of(mode).withValues(alpha: theme.brightness == Brightness.dark ? 0.14 : 0.06),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: ModeColors.of(mode).withValues(alpha: count > 0 ? 0.45 : 0.15)),
                    ),
                    child: Row(children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(gradient: ModeColors.gradient(mode), shape: BoxShape.circle),
                        child: Icon(ModeColors.icon(mode), color: Colors.white, size: 21),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(label, style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700)),
                          Text(hint,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                        ]),
                      ),
                      Text('$count', style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800)),
                    ]),
                  ),
                ),
            ]);
          }),
        ]),
      ),
    );
  }
}

class _KeyFigures extends StatelessWidget {
  const _KeyFigures({required this.overview, required this.columns});
  final TrafficOverview overview;
  final int columns;

  @override
  Widget build(BuildContext context) {
    final o = overview;
    final tiles = [
      StatTile(
        label: 'Active vehicles',
        value: '${o.activeVehicles}',
        icon: Icons.directions_car,
        caption: '${o.transmittingVehicles} sending data',
      ),
      StatTile(
        label: 'Average speed',
        value: Units.speedValue(o.averageSpeedMps),
        unit: 'km/h',
        icon: Icons.speed,
        accent: Brand.cyan,
        caption: 'Live vehicles',
      ),
      StatTile(
        label: 'Congested',
        value: '${o.congestedIntersections}',
        unit: o.congestedIntersections == 1 ? 'intersection' : 'intersections',
        icon: Icons.warning_amber,
        accent: o.congestedIntersections > 0 ? StatusColors.alert : StatusColors.ok,
        caption: o.congestedCodes.isEmpty ? 'None right now' : o.congestedCodes.join(', '),
      ),
      StatTile(
        label: 'Emergency',
        value: '${o.emergencyVehicles}',
        icon: Icons.emergency,
        accent: o.emergencyVehicles > 0 ? StatusColors.emergency : StatusColors.neutral,
        caption: o.pendingAuthorizations > 0 ? '${o.pendingAuthorizations} to review' : 'Vehicles active',
      ),
      StatTile(
        label: 'Traffic density',
        value: Units.number(o.averageDensity, decimals: 1),
        unit: 'veh/km',
        icon: Icons.stacked_line_chart,
        accent: Brand.teal,
        caption: 'Per lane, estimated',
      ),
      StatTile(
        label: 'Signal controllers',
        value: '${o.connectedIntersections}/${o.activeIntersections}',
        unit: 'connected',
        icon: Icons.settings_input_antenna,
        accent: StatusColors.simulated,
        caption: o.simulatedVehicles > 0 ? '${o.simulatedVehicles} simulated vehicles' : '${o.totalRegisteredVehicles} vehicles registered',
      ),
    ];
    return GridView(
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        mainAxisExtent: 86,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
      ),
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      children: tiles,
    );
  }
}

class _ControlGrid extends StatelessWidget {
  const _ControlGrid({required this.items, required this.columns});
  final List<IntersectionTraffic> items;
  final int columns;

  @override
  Widget build(BuildContext context) {
    final live = context.read<LiveController>();
    return LayoutBuilder(builder: (context, c) {
      final w = (c.maxWidth - (columns - 1) * 12) / columns;
      return Wrap(spacing: 12, runSpacing: 12, children: [
        for (final item in items)
          SizedBox(
            width: w,
            child: ControlCard(
              item: item,
              serverNow: () => live.serverNow,
              onTap: () => Navigator.push(
                  context, MaterialPageRoute(builder: (_) => IntersectionDetailScreen(intersectionId: item.id))),
            ),
          ),
      ]);
    });
  }
}

class _ModeLog extends StatelessWidget {
  const _ModeLog({required this.events});
  final List<ModeEvent> events;

  @override
  Widget build(BuildContext context) {
    if (events.isEmpty) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(8),
          child: EmptyState(
            icon: Icons.swap_horiz,
            title: 'No mode changes yet',
            message: 'When congestion builds up at an intersection it switches to adaptive timing, '
                'and the change and its reason appear here.',
          ),
        ),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        child: Column(children: [
          for (final (i, e) in events.take(8).indexed) ...[
            if (i > 0) const Divider(height: 1),
            ModeEventTile(event: e),
          ],
        ]),
      ),
    );
  }
}

class _RulesContent extends StatelessWidget {
  const _RulesContent({required this.config});
  final ControlConfig? config;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rules = config?.rules ?? const <String>[];
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('How fixed-time and adaptive switching works',
          style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
      const SizedBox(height: 4),
      Text('Intersections set to Automatic follow these rules. The values come from the server configuration.',
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      const SizedBox(height: 14),
      _flow(context),
      const SizedBox(height: 14),
      if (rules.isEmpty)
        const Text('Rules are not available from this server.')
      else
        for (final r in rules)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.chevron_right, size: 20, color: theme.colorScheme.primary),
              const SizedBox(width: 4),
              Expanded(child: Text(r)),
            ]),
          ),
    ]);
  }

  /// Traffic data -> congestion -> normal / congested -> mode.
  Widget _flow(BuildContext context) {
    Widget box(String text, {String? mode}) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            gradient: mode == null ? null : ModeColors.gradient(mode),
            color: mode == null ? Theme.of(context).colorScheme.surfaceContainerHigh : null,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(text,
              textAlign: TextAlign.center,
              style: TextStyle(fontWeight: FontWeight.w700, color: mode == null ? null : Colors.white)),
        );
    const arrow = Icon(Icons.arrow_downward, size: 18);
    return Center(
      child: Column(children: [
        box('Traffic data'),
        arrow,
        box('Congestion (1-minute average)'),
        arrow,
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Column(children: [box('Normal'), arrow, box('FIXED-TIME', mode: 'FIXED_TIME')]),
          const SizedBox(width: 24),
          Column(children: [box('Congested'), arrow, box('ADAPTIVE', mode: 'ADAPTIVE')]),
        ]),
        const SizedBox(height: 8),
        box('Emergency vehicle: priority in either mode', mode: 'EMERGENCY_PRIORITY'),
      ]),
    );
  }
}

class _SystemCard extends StatelessWidget {
  const _SystemCard({required this.overview});
  final TrafficOverview overview;

  @override
  Widget build(BuildContext context) {
    final s = overview.system;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(children: [
          InfoRow('Database', s.database == 'ok' ? 'OK' : 'Unavailable',
              valueColor: s.database == 'ok' ? StatusColors.ok : StatusColors.danger),
          InfoRow('Traffic engine',
              s.engineRunning ? 'Running · ${Units.number(s.engineCycleMs, decimals: 0)} ms per cycle' : 'Not running',
              valueColor: s.engineRunning ? StatusColors.ok : StatusColors.warning),
          InfoRow('Last engine cycle', Units.ago(s.engineLastCycleAt)),
          InfoRow('Live dashboards', '${s.websocketClients} connected'),
          InfoRow('External sources', s.externalSources.isEmpty ? 'None' : s.externalSources.join(', ')),
          InfoRow('Demo mode', s.demoMode ? (s.simulationRunning ? 'Enabled · simulation running' : 'Enabled') : 'Disabled'),
        ]),
      ),
    );
  }
}

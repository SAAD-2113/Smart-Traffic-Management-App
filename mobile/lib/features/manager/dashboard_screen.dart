import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/units.dart';
import '../../data/models/traffic.dart';
import '../../widgets/charts.dart';
import '../../widgets/common.dart';
import 'intersection_detail_screen.dart';
import 'live_controller.dart';
import 'manager_shell.dart';

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final live = context.watch<LiveController>();
    final o = live.overview;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Traffic dashboard'),
        actions: [
          if (o?.system.simulationRunning ?? false)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: StatusChip(label: 'Demo simulation', color: StatusColors.simulated, icon: Icons.science),
            ),
          const ConnectionIndicator(),
          IconButton(tooltip: 'Refresh', onPressed: live.refresh, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: o == null
          ? (live.error != null ? ErrorView(message: live.error!, onRetry: live.refresh) : const LoadingView())
          : RefreshIndicator(
              onRefresh: live.refresh,
              child: ListView(padding: const EdgeInsets.all(16), children: [
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
                GridView(
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 340,
                    mainAxisExtent: 118,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                  ),
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  children: [
                    MetricCard(
                      label: 'Active vehicles',
                      value: '${o.activeVehicles}',
                      icon: Icons.directions_car,
                      caption: 'Tracking session open',
                    ),
                    MetricCard(
                      label: 'Transmitting now',
                      value: '${o.transmittingVehicles}',
                      icon: Icons.sensors,
                      color: StatusColors.ok,
                      caption: 'Fix within the last 15 s',
                    ),
                    MetricCard(
                      label: 'Emergency vehicles',
                      value: '${o.emergencyVehicles}',
                      icon: Icons.emergency,
                      color: o.emergencyVehicles > 0 ? StatusColors.emergency : null,
                      caption: o.pendingAuthorizations > 0 ? '${o.pendingAuthorizations} requests to review' : 'Active now',
                    ),
                    MetricCard(
                      label: 'Average speed',
                      value: Units.speedValue(o.averageSpeedMps),
                      unit: 'km/h',
                      icon: Icons.speed,
                      caption: 'Transmitting vehicles',
                    ),
                    MetricCard(
                      label: 'Traffic density',
                      value: Units.number(o.averageDensity, decimals: 1),
                      unit: 'veh/km/lane',
                      icon: Icons.stacked_line_chart,
                      caption: 'Estimated, approach zones',
                    ),
                    MetricCard(
                      label: 'Congested intersections',
                      value: '${o.congestedIntersections}',
                      icon: Icons.warning_amber,
                      color: o.congestedIntersections > 0 ? StatusColors.alert : StatusColors.ok,
                      caption: o.congestedCodes.isEmpty ? 'None' : o.congestedCodes.join(', '),
                    ),
                    MetricCard(
                      label: 'Connected intersections',
                      value: '${o.connectedIntersections}/${o.activeIntersections}',
                      icon: Icons.settings_input_antenna,
                      caption: 'Signal controller reporting',
                    ),
                    MetricCard(
                      label: 'Registered vehicles',
                      value: '${o.totalRegisteredVehicles}',
                      icon: Icons.app_registration,
                      caption: o.simulatedVehicles > 0 ? '+ ${o.simulatedVehicles} simulated' : 'Real vehicles',
                    ),
                  ],
                ),
                const SectionHeader('Intersections', subtitle: 'Tap for approaches, signal timing and history'),
                ...live.intersections.map((i) => _IntersectionRow(item: i)),
                if (live.intersections.isEmpty)
                  const EmptyState(icon: Icons.traffic, title: 'No intersections configured'),
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
                const SizedBox(height: 24),
              ]),
            ),
    );
  }
}

class _IntersectionRow extends StatelessWidget {
  const _IntersectionRow({required this.item});
  final IntersectionTraffic item;

  @override
  Widget build(BuildContext context) {
    final signal = item.signal;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        child: ListTile(
          onTap: () => Navigator.push(
              context, MaterialPageRoute(builder: (_) => IntersectionDetailScreen(intersectionId: item.id))),
          leading: CircleAvatar(
            backgroundColor: StatusColors.congestion(item.congestionLevel).withValues(alpha: 0.15),
            child: Text(item.code, style: TextStyle(fontWeight: FontWeight.w800, color: StatusColors.congestion(item.congestionLevel))),
          ),
          title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '${plural(item.observed.vehicleCount, 'vehicle')} observed · ${Units.speed(item.observed.avgSpeedMps)}'
            '${item.calculated.avgWaitingTimeS != null ? ' · wait ${item.calculated.avgWaitingTimeS!.toStringAsFixed(0)} s' : ''}'
            '${signal != null ? '\nSignal: ${signal.phaseName} ${signal.state.replaceAll('_', ' ').toLowerCase()} (${signal.mode.replaceAll('_', ' ').toLowerCase()})' : ''}',
          ),
          isThreeLine: signal != null,
          trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
            CongestionBadge(item.congestionLevel, compact: true),
            const SizedBox(height: 4),
            Text(item.controllerType, style: Theme.of(context).textTheme.labelSmall),
          ]),
        ),
      ),
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

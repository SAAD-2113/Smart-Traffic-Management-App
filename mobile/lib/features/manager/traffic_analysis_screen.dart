import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/units.dart';
import '../../widgets/charts.dart';
import '../../widgets/common.dart';
import 'live_controller.dart';
import 'manager_shell.dart';

/// Compares intersections right now, one measure per chart.
class TrafficAnalysisScreen extends StatelessWidget {
  const TrafficAnalysisScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final live = context.watch<LiveController>();
    final nodes = live.intersections.where((i) => i.isActive).toList()
      ..sort((a, b) => seriesSlots([a.code, b.code])[a.code]!.compareTo(seriesSlots([a.code, b.code])[b.code]!));

    Widget chart(String title, String unit, List<BarItem> items, {int decimals = 0, String? subtitle}) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(title, subtitle: subtitle),
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 16, 16, 8),
                child: CategoryBarChart(unit: unit, decimals: decimals, items: items),
              ),
            ),
          ],
        );

    return Scaffold(
      appBar: AppBar(title: const Text('Traffic analysis'), actions: const [ConnectionIndicator()]),
      body: nodes.isEmpty
          ? const EmptyState(icon: Icons.analytics_outlined, title: 'No active intersections')
          : ListView(padding: const EdgeInsets.all(16), children: [
              const MessageBanner(
                icon: Icons.school_outlined,
                color: StatusColors.info,
                text: 'Observed: counted from reporting vehicles. Calculated: derived from observed values '
                    '(speed ratio, waiting time). Estimated: scaled by the assumed share of vehicles running the '
                    'app, so treat it as indicative. "No data" is not the same as "no traffic".',
              ),
              chart('Vehicles observed', 'vehicles', [for (final n in nodes) BarItem(n.code, n.observed.vehicleCount.toDouble())]),
              chart('Average speed', 'km/h', [
                for (final n in nodes) BarItem(n.code, n.observed.avgSpeedMps == null ? null : Units.kmh(n.observed.avgSpeedMps!)),
              ]),
              chart('Average waiting time', 's', [for (final n in nodes) BarItem(n.code, n.calculated.avgWaitingTimeS)],
                  subtitle: 'Time the currently stopped vehicles have waited so far'),
              chart('Estimated density', 'veh/km/lane', decimals: 1, [
                for (final n in nodes) BarItem(n.code, n.estimated.densityVehPerKmLane),
              ]),
              const SectionHeader('Summary table'),
              Card(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    columnSpacing: 18,
                    columns: const [
                      DataColumn(label: Text('Code')),
                      DataColumn(label: Text('Congestion')),
                      DataColumn(label: Text('Data')),
                      DataColumn(label: Text('Observed'), numeric: true),
                      DataColumn(label: Text('Estimated'), numeric: true),
                      DataColumn(label: Text('Speed')),
                      DataColumn(label: Text('Wait')),
                      DataColumn(label: Text('Arriving 60 s'), numeric: true),
                      DataColumn(label: Text('Emergency'), numeric: true),
                    ],
                    rows: [
                      for (final n in nodes)
                        DataRow(cells: [
                          DataCell(Text(n.code, style: const TextStyle(fontWeight: FontWeight.w700))),
                          DataCell(CongestionBadge(n.congestionLevel, compact: true)),
                          DataCell(Text(n.dataQuality)),
                          DataCell(Text('${n.observed.vehicleCount}')),
                          DataCell(Text(Units.number(n.estimated.vehicleCount))),
                          DataCell(Text(Units.speed(n.observed.avgSpeedMps))),
                          DataCell(Text(n.calculated.avgWaitingTimeS == null ? '—' : '${n.calculated.avgWaitingTimeS!.toStringAsFixed(0)} s')),
                          DataCell(Text('${n.calculated.expectedArrivals60s}')),
                          DataCell(Text('${n.observed.emergencyCount}')),
                        ]),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
            ]),
    );
  }
}

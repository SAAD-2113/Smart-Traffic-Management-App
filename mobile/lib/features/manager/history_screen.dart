import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/units.dart';
import '../../data/models/traffic.dart';
import '../../data/repositories/manager_repository.dart';
import '../../widgets/charts.dart';
import '../../widgets/common.dart';

/// Traffic history per intersection (one colour per intersection, same order everywhere).
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  static const ranges = {'1 h': (1.0, 60), '6 h': (6.0, 300), '24 h': (24.0, 900), '7 days': (168.0, 3600)};
  String _range = '1 h';
  late Future<List<HistorySeries>> _future = _fetch();

  Future<List<HistorySeries>> _fetch() {
    final (hours, bucket) = ranges[_range]!;
    return context.read<ManagerRepository>().networkHistory(hours: hours, bucketS: bucket);
  }

  void _select(String range) => setState(() {
        _range = range;
        _future = _fetch();
      });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Traffic history'), actions: [
        IconButton(tooltip: 'Refresh', onPressed: () => _select(_range), icon: const Icon(Icons.refresh)),
      ]),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: SegmentedButton<String>(
            segments: [for (final r in ranges.keys) ButtonSegment(value: r, label: Text(r))],
            selected: {_range},
            onSelectionChanged: (s) => _select(s.first),
          ),
        ),
        Expanded(
          child: FutureBuilder<List<HistorySeries>>(
            future: _future,
            builder: (context, snapshot) {
              if (snapshot.hasError) return ErrorView(message: '${snapshot.error}', onRetry: () => _select(_range));
              if (!snapshot.hasData) return const LoadingView();
              final series = snapshot.data!.where((s) => s.points.isNotEmpty).toList();
              if (series.isEmpty) {
                return const EmptyState(
                    icon: Icons.history,
                    title: 'No history in this period',
                    message: 'The engine stores a snapshot every 30 seconds while it runs.');
              }
              final slots = seriesSlots(series.map((s) => s.code));
              List<ChartSeries> build(double? Function(HistoryPoint p) value) => [
                    for (final s in series)
                      ChartSeries(
                        label: s.code,
                        color: ChartColors.series(context, slots[s.code]!),
                        points: [for (final p in s.points) ChartPoint(p.t, value(p))],
                      ),
                  ];
              Widget card(String title, String unit, List<ChartSeries> data, {int decimals = 0, String? subtitle}) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SectionHeader(title, subtitle: subtitle),
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(8, 12, 16, 8),
                          child: TimeLineChart(unit: unit, series: data, decimals: decimals, height: 210),
                        ),
                      ),
                    ],
                  );
              return ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), children: [
                if (series.length > 8)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text('More than 8 intersections: open an intersection for its own history.'),
                  ),
                card('Vehicles observed', 'vehicles', build((p) => p.observedVehicles), decimals: 1),
                card('Average speed', 'km/h', build((p) => p.avgSpeedMps == null ? null : Units.kmh(p.avgSpeedMps!))),
                card('Congestion', 'level', build((p) => p.congestionRank), decimals: 1,
                    subtitle: '0 = low, 1 = moderate, 2 = high, 3 = severe (bucket average)'),
                card('Average waiting time', 's', build((p) => p.avgWaitingTimeS)),
              ]);
            },
          ),
        ),
      ]),
    );
  }
}

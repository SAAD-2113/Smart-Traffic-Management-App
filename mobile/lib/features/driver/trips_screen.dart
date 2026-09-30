import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/utils/units.dart';
import '../../widgets/common.dart';
import 'driver_controller.dart';

class TripsScreen extends StatefulWidget {
  const TripsScreen({super.key});

  @override
  State<TripsScreen> createState() => _TripsScreenState();
}

class _TripsScreenState extends State<TripsScreen> {
  late Future<void> _loading;

  @override
  void initState() {
    super.initState();
    _loading = context.read<DriverController>().loadTrips();
  }

  Future<void> _reload() {
    final f = context.read<DriverController>().loadTrips();
    setState(() => _loading = f);
    return f;
  }

  static String _reason(String? r) => switch (r) {
        'USER' => 'Stopped by you',
        'RESTARTED' => 'Restarted',
        'TIMEOUT' => 'No data (timed out)',
        'VEHICLE_SUSPENDED' => 'Vehicle suspended',
        null => 'In progress',
        _ => r,
      };

  @override
  Widget build(BuildContext context) {
    final trips = context.watch<DriverController>().trips;
    return Scaffold(
      appBar: AppBar(title: const Text('Trips'), actions: [
        IconButton(tooltip: 'Refresh', onPressed: _reload, icon: const Icon(Icons.refresh)),
      ]),
      body: FutureBuilder(
        future: _loading,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done && trips.isEmpty) return const LoadingView();
          if (snapshot.hasError && trips.isEmpty) return ErrorView(message: '${snapshot.error}', onRetry: _reload);
          if (trips.isEmpty) {
            return const EmptyState(
                icon: Icons.route, title: 'No trips yet', message: 'Each tracking session appears here with its distance and speeds.');
          }
          return RefreshIndicator(
            onRefresh: _reload,
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: trips.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, i) {
                final t = trips[i];
                return Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Icon(t.isOpen ? Icons.play_circle : Icons.check_circle_outline),
                        const SizedBox(width: 8),
                        Expanded(child: Text(Units.dateTime(t.startedAt), style: Theme.of(context).textTheme.titleSmall)),
                        Text(_reason(t.endReason), style: Theme.of(context).textTheme.bodySmall),
                      ]),
                      const Divider(),
                      Wrap(spacing: 20, runSpacing: 6, children: [
                        _stat('Duration', Units.duration(t.durationS)),
                        _stat('Distance', Units.distance(t.distanceM)),
                        _stat('Average', Units.speed(t.avgSpeedMps)),
                        _stat('Top speed', Units.speed(t.maxSpeedMps)),
                        _stat('Packets', '${t.packetCount}${t.rejectedCount > 0 ? ' (${t.rejectedCount} rejected)' : ''}'),
                      ]),
                    ]),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }

  Widget _stat(String label, String value) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(fontSize: 12)),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
      ]);
}

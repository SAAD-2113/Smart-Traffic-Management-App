import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/units.dart';
import '../../data/models/emergency.dart';
import '../../data/models/vehicle.dart';
import '../../data/repositories/manager_repository.dart';
import '../../widgets/charts.dart';
import '../../widgets/common.dart';
import 'live_controller.dart';
import 'manager_shell.dart';

/// Emergency vehicles: what is active now, authorisation requests to review, and history.
class EmergencyAdminScreen extends StatelessWidget {
  const EmergencyAdminScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final pending = context.watch<LiveController>().overview?.pendingAuthorizations ?? 0;
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Emergency vehicles'),
          actions: const [ConnectionIndicator()],
          bottom: TabBar(tabs: [
            const Tab(text: 'Active'),
            Tab(child: Badge(isLabelVisible: pending > 0, label: Text('$pending'), child: const Text('Requests'))),
            const Tab(text: 'History'),
          ]),
        ),
        body: const TabBarView(children: [_ActiveTab(), _RequestsTab(), _HistoryTab()]),
      ),
    );
  }
}

class _ActiveTab extends StatelessWidget {
  const _ActiveTab();

  @override
  Widget build(BuildContext context) {
    final live = context.watch<LiveController>();
    if (live.emergencies.isEmpty) {
      return const EmptyState(icon: Icons.emergency_outlined, title: 'No active emergency vehicles',
          message: 'Authorised vehicles appear here as soon as their driver activates emergency mode.');
    }
    return ListView(padding: const EdgeInsets.all(16), children: [
      for (final e in live.emergencies)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(Icons.emergency, color: StatusColors.emergency),
                const SizedBox(width: 8),
                Text(e.vehicleCode, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(width: 8),
                Text(vehicleTypeLabel(e.vehicleType)),
                const Spacer(),
                if (e.isSimulated) const StatusChip(label: 'SIM', color: StatusColors.simulated),
              ]),
              const SizedBox(height: 8),
              Ticker(builder: (_) => InfoRow('Active for', Units.duration(DateTime.now().difference(e.startedAt).inSeconds.toDouble()))),
              InfoRow('Speed', Units.speed(e.speedMps)),
              InfoRow('Heading', Units.heading(e.headingDeg)),
              InfoRow('Next intersection', e.nextIntersectionCode == null ? '—' : '${e.nextIntersectionCode} via ${e.approachName ?? '?'}'),
              InfoRow('ETA', e.etaS == null ? '—' : '${e.etaS!.toStringAsFixed(0)} s'),
              InfoRow('Last position', e.lastFixAt == null ? 'none' : Units.ago(e.lastFixAt)),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(foregroundColor: StatusColors.danger),
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: const Text('End emergency'),
                  onPressed: () async {
                    final note = await askReason(context, title: 'End emergency for ${e.vehicleCode}?', hint: 'Reason', action: 'End');
                    if (note == null || !context.mounted) return;
                    await runGuarded(context, () => context.read<ManagerRepository>().endEmergency(e.id, note), success: 'Emergency ended.');
                    if (context.mounted) await context.read<LiveController>().refresh();
                  },
                ),
              ),
            ]),
          ),
        ),
    ]);
  }
}

class _RequestsTab extends StatefulWidget {
  const _RequestsTab();

  @override
  State<_RequestsTab> createState() => _RequestsTabState();
}

class _RequestsTabState extends State<_RequestsTab> {
  late Future<List<AuthorizationRequest>> _future = context.read<ManagerRepository>().authorizations();

  Future<void> _reload() async {
    final f = context.read<ManagerRepository>().authorizations();
    setState(() => _future = f);
    await f;
    if (mounted) await context.read<LiveController>().refresh();
  }

  Future<void> _approve(AuthorizationRequest r) async {
    DateTime? validUntil;
    final notes = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setState) => AlertDialog(
          title: Text('Approve ${r.vehicleCode}?'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${vehicleTypeLabel(r.vehicleType)}, registration ${r.registrationNumber ?? '—'}. '
                'Approve only after verifying the vehicle with its organisation.'),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              icon: const Icon(Icons.event),
              label: Text(validUntil == null ? 'No expiry' : 'Valid until ${Units.dateTime(validUntil)}'),
              onPressed: () async {
                final picked = await showDatePicker(
                  context: dialogContext,
                  firstDate: DateTime.now().add(const Duration(days: 1)),
                  lastDate: DateTime.now().add(const Duration(days: 730)),
                  initialDate: DateTime.now().add(const Duration(days: 365)),
                );
                if (picked != null) setState(() => validUntil = picked);
              },
            ),
            TextField(controller: notes, decoration: const InputDecoration(labelText: 'Notes (optional)')),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Approve')),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    await runGuarded(context, () => context.read<ManagerRepository>().approve(r.id, validUntil: validUntil, notes: notes.text.trim()),
        success: '${r.vehicleCode} is authorised for emergency mode.');
    await _reload();
  }

  Future<void> _reject(AuthorizationRequest r) async {
    final notes = await askReason(context, title: 'Reject ${r.vehicleCode}?', hint: 'Reason shown in the audit log', action: 'Reject');
    if (notes == null || !mounted) return;
    await runGuarded(context, () => context.read<ManagerRepository>().reject(r.id, notes), success: 'Request rejected.');
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<AuthorizationRequest>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.hasError) return ErrorView(message: '${snapshot.error}', onRetry: _reload);
        if (!snapshot.hasData) return const LoadingView();
        final items = snapshot.data!;
        if (items.isEmpty) {
          return const EmptyState(icon: Icons.verified_user_outlined, title: 'No authorisation requests',
              message: 'Drivers who register an ambulance, fire truck or police vehicle appear here for verification.');
        }
        return RefreshIndicator(
          onRefresh: _reload,
          child: ListView(padding: const EdgeInsets.all(16), children: [
            for (final r in items)
              Card(
                child: ListTile(
                  leading: Icon(r.status == 'PENDING' ? Icons.hourglass_top : Icons.verified_user,
                      color: switch (r.status) {
                        'APPROVED' => StatusColors.ok,
                        'PENDING' => StatusColors.warning,
                        _ => StatusColors.danger,
                      }),
                  title: Text('${r.vehicleCode} · ${vehicleTypeLabel(r.vehicleType)}'),
                  subtitle: Text('Registration ${r.registrationNumber ?? '—'} · requested ${Units.ago(r.requestedAt)}'
                      '\n${r.status}${r.validUntil != null ? ' until ${Units.dateTime(r.validUntil)}' : ''}'
                      '${r.notes != null ? ' · ${r.notes}' : ''}'),
                  isThreeLine: true,
                  trailing: r.status != 'PENDING'
                      ? null
                      : Row(mainAxisSize: MainAxisSize.min, children: [
                          IconButton(tooltip: 'Reject', onPressed: () => _reject(r), icon: const Icon(Icons.close, color: StatusColors.danger)),
                          IconButton(tooltip: 'Approve', onPressed: () => _approve(r), icon: const Icon(Icons.check, color: StatusColors.ok)),
                        ]),
                ),
              ),
          ]),
        );
      },
    );
  }
}

class _HistoryTab extends StatefulWidget {
  const _HistoryTab();

  @override
  State<_HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<_HistoryTab> {
  late Future<List<EmergencyEvent>> _future = context.read<ManagerRepository>().emergencyEvents(limit: 200);

  Future<void> _reload() async {
    final f = context.read<ManagerRepository>().emergencyEvents(limit: 200);
    setState(() => _future = f);
    await f;
  }

  static String _reason(String? r) => switch (r) {
        'DRIVER' => 'ended by driver',
        'MANAGER' => 'ended by manager',
        'TIMEOUT' => 'timed out',
        'AUTH_REVOKED' => 'authorisation revoked',
        'TRACKING_STOPPED' => 'tracking stopped',
        'VEHICLE_SUSPENDED' => 'vehicle suspended',
        'DEMO_STOPPED' => 'demo stopped',
        null => 'active',
        _ => r.toLowerCase(),
      };

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<EmergencyEvent>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.hasError) return ErrorView(message: '${snapshot.error}', onRetry: _reload);
        if (!snapshot.hasData) return const LoadingView();
        final events = snapshot.data!;
        if (events.isEmpty) return const EmptyState(icon: Icons.history, title: 'No emergency activity yet');
        final perHour = <DateTime, int>{};
        for (final e in events) {
          final t = e.startedAt.toLocal();
          final hour = DateTime(t.year, t.month, t.day, t.hour);
          perHour[hour] = (perHour[hour] ?? 0) + 1;
        }
        final hours = perHour.keys.toList()..sort();
        return RefreshIndicator(
          onRefresh: _reload,
          child: ListView(padding: const EdgeInsets.all(16), children: [
            const SectionHeader('Emergency activations per hour'),
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 16, 16, 8),
                child: CategoryBarChart(
                  unit: 'activations',
                  items: [for (final h in hours.skip(hours.length > 12 ? hours.length - 12 : 0)) BarItem('${h.hour}:00', perHour[h]!.toDouble())],
                ),
              ),
            ),
            const SectionHeader('Events'),
            for (final e in events)
              ListTile(
                leading: Icon(e.isActive ? Icons.emergency : Icons.check_circle_outline,
                    color: e.isActive ? StatusColors.emergency : StatusColors.neutral),
                title: Text('${e.vehicleCode} · ${vehicleTypeLabel(e.vehicleType)}${e.isSimulated ? ' (simulated)' : ''}'),
                subtitle: Text('${Units.dateTime(e.startedAt)} · ${Units.duration(e.durationS)} · ${_reason(e.endReason)}'),
              ),
          ]),
        );
      },
    );
  }
}

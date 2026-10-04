import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/units.dart';
import '../../data/models/control.dart';
import '../../data/models/signals.dart';
import '../../data/repositories/manager_repository.dart';
import '../../widgets/common.dart';
import '../../widgets/signal_widgets.dart';
import 'live_controller.dart';
import 'manager_shell.dart';
import 'signal_plan_screen.dart';

/// Signal control overview: plan, latest advisory decision and the state each controller reports.
class SignalsScreen extends StatefulWidget {
  const SignalsScreen({super.key});

  @override
  State<SignalsScreen> createState() => _SignalsScreenState();
}

class _SignalsScreenState extends State<SignalsScreen> {
  late Future<List<SignalOverviewItem>> _future = context.read<ManagerRepository>().signalsOverview();

  Future<void> _reload() async {
    final f = context.read<ManagerRepository>().signalsOverview();
    setState(() => _future = f);
    await f;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Signal control'), actions: [
        IconButton(tooltip: 'Refresh', onPressed: _reload, icon: const Icon(Icons.refresh)),
        const ConnectionIndicator(),
      ]),
      body: FutureBuilder<List<SignalOverviewItem>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.hasError) return ErrorView(message: '${snapshot.error}', onRetry: _reload);
          if (!snapshot.hasData) return const LoadingView();
          final items = snapshot.data!;
          return RefreshIndicator(
            onRefresh: _reload,
            child: ListView(padding: const EdgeInsets.all(16), children: [
              const MessageBanner(
                icon: Icons.shield_outlined,
                color: StatusColors.info,
                text: 'Automatic intersections run the fixed-time plan in normal traffic and switch to adaptive '
                    'timing when congestion builds up. Decisions are advisory and expire after 15 s; controllers keep '
                    'their own minimum green, yellow and all-red times. Emergency priority is a simulation/prototype feature.',
              ),
              const SizedBox(height: 12),
              for (final item in items) ...[_SignalTile(item: item, onChanged: _reload), const SizedBox(height: 10)],
            ]),
          );
        },
      ),
    );
  }
}

class _SignalTile extends StatelessWidget {
  const _SignalTile({required this.item, required this.onChanged});
  final SignalOverviewItem item;
  final Future<void> Function() onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final live = context.watch<LiveController>();
    // Live parts (mode, lights) from the WebSocket feed; plan and connection from this screen's load.
    final current = live.intersections.where((i) => i.id == item.intersectionId).firstOrNull;
    final control = current?.control ?? item.control;
    final display = current?.displaySignal ?? item.displaySignal;
    final muted = theme.colorScheme.onSurfaceVariant;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () async {
          await Navigator.push(
              context, MaterialPageRoute(builder: (_) => SignalPlanScreen(intersectionId: item.intersectionId, code: item.code)));
          await onChanged();
        },
        child: Container(
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: control == null ? StatusColors.neutral : ModeColors.of(control.mode), width: 4)),
          ),
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              TrafficLight(state: display?.state ?? 'OFF', lampSize: 11),
              const SizedBox(width: 12),
              Expanded(
                child: SignalTitle(code: item.code, name: item.name, display: display, serverNow: () => live.serverNow),
              ),
              if (control != null) ModeBadge(control.mode),
            ]),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 6, children: [
              StatusChip(label: 'Policy: ${policyLabel(item.controllerType)}', color: StatusColors.info, icon: Icons.tune),
              StatusChip(
                label: item.connected
                    ? 'Controller connected'
                    : (display?.virtual ?? false)
                        ? 'Virtual controller'
                        : 'Not reporting',
                color: item.connected ? StatusColors.ok : StatusColors.neutral,
                icon: Icons.settings_input_antenna,
              ),
              if (item.plan.isDefault) const StatusChip(label: 'Default plan', color: StatusColors.neutral),
            ]),
            if (control != null) ...[
              const SizedBox(height: 10),
              Text(control.headline, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
              Text(control.detail, maxLines: 3, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
              const SizedBox(height: 12),
              SignalTimingDiagram(
                timings: control.activeTiming,
                cycleS: control.activeCycleS,
                reference: control.timingChanged ? control.fixedTiming : null,
                referenceCycleS: control.timingChanged ? control.fixedCycleS : null,
                highlightPhase: control.priorityPhase ?? display?.phaseName,
              ),
            ] else
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('Fixed plan: cycle ${item.plan.fixedCycleS.toStringAsFixed(0)} s',
                    style: theme.textTheme.bodySmall),
              ),
            const SizedBox(height: 6),
            Row(children: [
              Expanded(
                child: Text(
                    item.decision == null
                        ? 'No decision is sent; the controller runs its fixed plan.'
                        : 'Decision valid until ${Units.clock(item.decision!.validUntil)} (advisory)',
                    style: theme.textTheme.bodySmall?.copyWith(color: muted)),
              ),
              Text('Edit plan', style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.primary)),
              Icon(Icons.chevron_right, size: 18, color: theme.colorScheme.primary),
            ]),
          ]),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/units.dart';
import '../../data/models/signals.dart';
import '../../data/repositories/manager_repository.dart';
import '../../widgets/common.dart';
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
                text: 'Decisions are advisory and expire after 15 s. Controllers keep their own minimum green, '
                    'yellow and all-red times and fall back to their fixed plan when no valid decision exists. '
                    'Emergency priority is a simulation/prototype feature.',
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
    final s = item.state;
    final d = item.decision;
    final plan = item.plan;
    final greens = d == null
        ? [for (final p in plan.phases) PhaseGreenView(p.name, p.fixedGreenS)]
        : [for (final g in d.phaseGreens) PhaseGreenView(g.phase, g.greenS)];
    final totalGreen = greens.fold<double>(0, (sum, g) => sum + g.greenS);
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () async {
          await Navigator.push(context, MaterialPageRoute(builder: (_) => SignalPlanScreen(intersectionId: item.intersectionId, code: item.code)));
          await onChanged();
        },
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text(item.code, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(width: 8),
              Expanded(child: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
              StatusChip(label: item.controllerType, color: StatusColors.info),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Icon(Icons.circle, size: 18, color: s == null ? StatusColors.neutral : StatusColors.light(s.state)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(s == null
                    ? 'No controller has reported a state'
                    : '${s.phaseName} · ${s.state.replaceAll('_', ' ')}${s.remainingS != null ? ' · ${s.remainingS!.toStringAsFixed(0)} s' : ''}'
                        ' · ${s.mode.replaceAll('_', ' ').toLowerCase()} · ${s.source.toLowerCase()}'),
              ),
              StatusChip(
                label: item.connected ? 'Connected' : 'Not reporting',
                color: item.connected ? StatusColors.ok : StatusColors.neutral,
              ),
            ]),
            const SizedBox(height: 10),
            Text(d == null ? 'Timing: fixed plan (cycle ${plan.fixedCycleS.toStringAsFixed(0)} s)' : 'Timing: ${d.algorithmLabel} (cycle ${d.cycleS.toStringAsFixed(0)} s)',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            _GreenSplit(greens: greens, priority: d?.priorityPhase, total: totalGreen),
            if (d != null) ...[
              const SizedBox(height: 6),
              Text(d.reason, maxLines: 3, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
              Text('Valid until ${Units.clock(d.validUntil)}', style: Theme.of(context).textTheme.bodySmall),
            ],
          ]),
        ),
      ),
    );
  }
}

class PhaseGreenView {
  PhaseGreenView(this.phase, this.greenS);
  final String phase;
  final double greenS;
}

/// Horizontal bar showing how green time is split between phases (labels, not colour, carry identity).
class _GreenSplit extends StatelessWidget {
  const _GreenSplit({required this.greens, required this.priority, required this.total});
  final List<PhaseGreenView> greens;
  final String? priority;
  final double total;

  @override
  Widget build(BuildContext context) {
    if (greens.isEmpty || total <= 0) return const SizedBox.shrink();
    final base = ChartColors.primary(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Row(children: [
        for (var i = 0; i < greens.length; i++)
          Expanded(
            flex: (greens[i].greenS * 10).round().clamp(1, 100000),
            child: Container(
              height: 28,
              margin: EdgeInsets.only(right: i == greens.length - 1 ? 0 : 2),
              color: greens[i].phase == priority ? StatusColors.emergency : base.withValues(alpha: i.isEven ? 0.9 : 0.55),
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text('${greens[i].phase} ${greens[i].greenS.toStringAsFixed(0)} s',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
            ),
          ),
      ]),
    );
  }
}

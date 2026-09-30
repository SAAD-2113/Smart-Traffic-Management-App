import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/units.dart';
import '../../data/models/signals.dart';
import '../../data/models/traffic.dart';
import '../../data/repositories/manager_repository.dart';
import '../../widgets/common.dart';

/// Edits the phases and safety limits of one intersection's signal plan. The server validates
/// every limit again (minimum green, yellow, all-red, approach coverage, cycle bounds).
class SignalPlanScreen extends StatefulWidget {
  const SignalPlanScreen({super.key, required this.intersectionId, required this.code});
  final String intersectionId;
  final String code;

  @override
  State<SignalPlanScreen> createState() => _SignalPlanScreenState();
}

class _SignalPlanScreenState extends State<SignalPlanScreen> {
  SignalPlanConfig? _plan;
  List<String> _approaches = [];
  List<SignalDecisionInfo> _decisions = [];
  Object? _error;
  bool _dirty = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final repo = context.read<ManagerRepository>();
    try {
      final results = await Future.wait([
        repo.signalPlan(widget.intersectionId),
        repo.intersection(widget.intersectionId),
        repo.decisions(widget.intersectionId, limit: 10),
      ]);
      _plan = results[0] as SignalPlanConfig;
      _approaches = (results[1] as IntersectionConfig).approaches.map((a) => a['name'] as String).toList();
      _decisions = results[2] as List<SignalDecisionInfo>;
      _dirty = false;
      _error = null;
    } catch (e) {
      _error = e;
    }
    if (mounted) setState(() {});
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final ok = await runGuarded(context, () async {
      _plan = await context.read<ManagerRepository>().saveSignalPlan(widget.intersectionId, _plan!);
    }, success: 'Signal plan saved.');
    if (mounted) {
      setState(() {
        _saving = false;
        if (ok) _dirty = false;
      });
    }
  }

  void _changed() => setState(() => _dirty = true);

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    return Scaffold(
      appBar: AppBar(title: Text('${widget.code} signal plan'), actions: [
        if (_dirty)
          TextButton(onPressed: _saving ? null : _save, child: const Text('Save')),
      ]),
      body: plan == null
          ? (_error != null ? ErrorView(message: '$_error', onRetry: _load) : const LoadingView())
          : ListView(padding: const EdgeInsets.all(16), children: [
              if (plan.isDefault)
                const MessageBanner(
                  icon: Icons.info_outline,
                  color: StatusColors.info,
                  text: 'This is the default plan generated from the approaches (opposite directions share a phase). '
                      'Saving stores it as this intersection\'s plan.',
                ),
              for (var i = 0; i < plan.phases.length; i++) _phaseCard(plan, i),
              OutlinedButton.icon(
                onPressed: plan.phases.length >= 8
                    ? null
                    : () {
                        plan.phases.add(PhaseConfig(
                            name: 'Phase ${plan.phases.length + 1}', approaches: [], minGreenS: 10, maxGreenS: 60,
                            fixedGreenS: 25, yellowS: 3, allRedS: 2));
                        _changed();
                      },
                icon: const Icon(Icons.add),
                label: const Text('Add phase'),
              ),
              const SectionHeader('Cycle limits (adaptive control)'),
              Row(children: [
                Expanded(child: _numberField('Minimum cycle (s)', plan.minCycleS, (v) => plan.minCycleS = v)),
                const SizedBox(width: 12),
                Expanded(child: _numberField('Maximum cycle (s)', plan.maxCycleS, (v) => plan.maxCycleS = v)),
              ]),
              const SizedBox(height: 16),
              FilledButton(onPressed: _dirty && !_saving ? _save : null, child: const Text('Save plan')),
              const SectionHeader('Recent decisions', subtitle: 'Stored when the timing changes'),
              if (_decisions.isEmpty)
                const Text('No adaptive decisions yet (the intersection may be in fixed-time mode).')
              else
                for (final d in _decisions)
                  Card(
                    child: ListTile(
                      dense: true,
                      title: Text('${d.algorithmLabel} · cycle ${d.cycleS.toStringAsFixed(0)} s'
                          '${d.priorityPhase != null ? ' · priority ${d.priorityPhase}' : ''}'),
                      subtitle: Text('${Units.dateTime(d.createdAt)}\n'
                          '${d.phaseGreens.map((g) => '${g.phase} ${g.greenS.toStringAsFixed(0)} s').join(', ')}'),
                      isThreeLine: true,
                    ),
                  ),
            ]),
    );
  }

  Widget _phaseCard(SignalPlanConfig plan, int i) {
    final p = plan.phases[i];
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: TextFormField(
                  initialValue: p.name,
                  decoration: const InputDecoration(labelText: 'Phase name', isDense: true),
                  onChanged: (v) {
                    p.name = v.trim();
                    _changed();
                  },
                ),
              ),
              IconButton(
                tooltip: 'Remove phase',
                onPressed: plan.phases.length <= 2
                    ? null
                    : () {
                        plan.phases.removeAt(i);
                        _changed();
                      },
                icon: const Icon(Icons.delete_outline),
              ),
            ]),
            const SizedBox(height: 8),
            const Text('Approaches served (green together)'),
            Wrap(spacing: 6, children: [
              for (final a in _approaches)
                FilterChip(
                  label: Text(a),
                  selected: p.approaches.contains(a),
                  onSelected: (on) {
                    if (on) {
                      for (final other in plan.phases) {
                        other.approaches.remove(a); // an approach belongs to one phase only
                      }
                      p.approaches.add(a);
                    } else {
                      p.approaches.remove(a);
                    }
                    _changed();
                  },
                ),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: _numberField('Min green', p.minGreenS, (v) => p.minGreenS = v)),
              const SizedBox(width: 8),
              Expanded(child: _numberField('Fixed green', p.fixedGreenS, (v) => p.fixedGreenS = v)),
              const SizedBox(width: 8),
              Expanded(child: _numberField('Max green', p.maxGreenS, (v) => p.maxGreenS = v)),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: _numberField('Yellow', p.yellowS, (v) => p.yellowS = v)),
              const SizedBox(width: 8),
              Expanded(child: _numberField('All-red', p.allRedS, (v) => p.allRedS = v)),
              const Spacer(),
            ]),
          ]),
        ),
      ),
    );
  }

  Widget _numberField(String label, double value, void Function(double) onChanged) => TextFormField(
        initialValue: value.toStringAsFixed(value == value.roundToDouble() ? 0 : 1),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: label, suffixText: 's', isDense: true),
        onChanged: (v) {
          final parsed = double.tryParse(v);
          if (parsed != null) {
            onChanged(parsed);
            _changed();
          }
        },
      );
}

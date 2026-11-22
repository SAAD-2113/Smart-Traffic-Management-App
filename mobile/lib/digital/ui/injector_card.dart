import 'package:flutter/material.dart';
import 'package:v2i_core/v2i_core.dart' as v2i;

import '../../core/theme/app_theme.dart';
import '../../hardware/ui/hw_style.dart' show HwCard;
import '../intersection/digital_intersection.dart';

/// Test injector: virtual vehicles that run the firmware's vehicle simulation inside this phone,
/// so the intersection can be demonstrated alone. The six firmware presets are one-tap buttons.
class InjectorCard extends StatefulWidget {
  const InjectorCard({super.key, required this.junction});
  final DigitalIntersection junction;

  @override
  State<InjectorCard> createState() => _InjectorCardState();
}

String presetLabel(int i, v2i.VehicleSpec p) =>
    '${i + 1} · ${p.id} ${v2i.LANE_NAME[p.arm]}${p.type == v2i.VT_EMERGENCY ? ' EMERG' : ''}'
    '${p.slot > 0 ? ' slot ${p.slot}' : ''}${p.delayS > 0 ? ' +${p.delayS}s' : ''}';

class _InjectorCardState extends State<InjectorCard> {
  int _arm = 0, _slot = 0, _delay = 0;
  bool _emergency = false;

  void _addCustom() {
    final j = widget.junction;
    final id = v2i.nextCustomId(j.injectedIds);
    if (id == null) return;
    // start distance and speed as in the firmware presets (normal 100 m / 30 km/h, emergency 140 m / 50 km/h)
    j.inject(v2i.VehicleSpec(
      id: id,
      type: _emergency ? v2i.VT_EMERGENCY : v2i.VT_NORMAL,
      arm: _arm,
      slot: _slot,
      startDist: _emergency ? 140 : 100,
      kmh: _emergency ? 50 : 30,
      delayS: _delay,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final j = widget.junction;
    final theme = Theme.of(context);
    final taken = j.injectedIds.toSet();
    return HwCard(
      title: 'Test injector',
      icon: Icons.smart_toy_outlined,
      trailing: j.injected.isEmpty
          ? null
          : TextButton(key: const ValueKey('remove-all-injected'), onPressed: j.removeAllInjected, child: const Text('Remove all')),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Virtual vehicles that run the firmware\'s vehicle simulation in this phone (marked "inject"). '
            'They obey the ACK like the ESP vehicles.',
            style: theme.textTheme.bodySmall),
        const SizedBox(height: 10),
        Text('Firmware presets', style: theme.textTheme.labelLarge),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (var i = 0; i < v2i.PRESETS.length; i++)
            FilterChip(
              key: ValueKey('preset-${i + 1}'),
              avatar: v2i.PRESETS[i].type == v2i.VT_EMERGENCY ? const Icon(Icons.emergency, size: 16, color: StatusColors.emergency) : null,
              label: Text(presetLabel(i, v2i.PRESETS[i])),
              selected: taken.contains(v2i.PRESETS[i].id),
              onSelected: (on) => on ? j.inject(v2i.PRESETS[i]) : j.removeInjected(v2i.PRESETS[i].id),
            ),
        ]),
        const SizedBox(height: 14),
        Text('Custom vehicle', style: theme.textTheme.labelLarge),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(
            child: SegmentedButton<int>(
              key: const ValueKey('inject-arm'),
              segments: [for (var a = 0; a < 4; a++) ButtonSegment(value: a, label: Text(v2i.LANE_NAME[a]))],
              selected: {_arm},
              onSelectionChanged: (s) => setState(() => _arm = s.first),
            ),
          ),
        ]),
        const SizedBox(height: 6),
        Wrap(spacing: 12, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          DropdownButton<int>(
            value: _slot,
            items: [for (var s = 0; s < 3; s++) DropdownMenuItem(value: s, child: Text('Slot $s'))],
            onChanged: (v) => setState(() => _slot = v ?? 0),
          ),
          DropdownButton<int>(
            value: _delay,
            items: [for (final d in const [0, 10, 30, 60, 90]) DropdownMenuItem(value: d, child: Text(d == 0 ? 'Now' : 'After $d s'))],
            onChanged: (v) => setState(() => _delay = v ?? 0),
          ),
          FilterChip(
            label: const Text('Emergency'),
            selected: _emergency,
            onSelected: (v) => setState(() => _emergency = v),
          ),
          FilledButton.tonalIcon(
            key: const ValueKey('inject-custom'),
            onPressed: _addCustom,
            icon: const Icon(Icons.add),
            label: const Text('Add'),
          ),
        ]),
        if (j.injected.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final v in j.injected)
              InputChip(
                label: Text('${v.vId} ${v2i.LANE_NAME[v.vArm]} · ${v.action.toLowerCase()}'),
                avatar: v.vType == v2i.VT_EMERGENCY ? const Icon(Icons.emergency, size: 16, color: StatusColors.emergency) : null,
                onDeleted: () => j.removeInjected(v.vId),
              ),
          ]),
        ],
      ]),
    );
  }
}

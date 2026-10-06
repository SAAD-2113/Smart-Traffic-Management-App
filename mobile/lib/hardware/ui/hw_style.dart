import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../monitor.dart';

/// Colours for hardware values. Colours always come with a label or icon, never alone.
class HwColors {
  static Color lamp(String? signal) => switch (signal) {
        'G' => SignalColors.green,
        'Y' => SignalColors.yellow,
        'R' => SignalColors.red,
        _ => SignalColors.off,
      };

  /// The lamp as shown when the data is not current: greyed out.
  static Color lampGreyed(String? signal) =>
      signal == 'G' || signal == 'Y' || signal == 'R' ? const Color(0xFF8A94A6) : SignalColors.off;

  static Color interval(String? interval) => switch (interval) {
        'green' => SignalColors.green,
        'yellow' || 'flash' => SignalColors.yellow,
        'all_red' => SignalColors.red,
        _ => StatusColors.neutral,
      };

  static Color level(String? level) => switch (level) {
        'free' => StatusColors.ok,
        'low' => Brand.teal,
        'medium' => StatusColors.warning,
        'high' => StatusColors.alert,
        _ => StatusColors.neutral,
      };

  static Color ctrl(String? ctrl) => switch (ctrl) {
        'normal' => StatusColors.ok,
        'preempt' => StatusColors.emergency,
        'fallback' => StatusColors.warning,
        'fault' => StatusColors.danger,
        'startup' || 'rest' || 'idle' => StatusColors.info,
        _ => StatusColors.neutral,
      };

  static IconData ctrlIcon(String? ctrl) => switch (ctrl) {
        'normal' => Icons.check_circle_outline,
        'preempt' => Icons.emergency,
        'fallback' => Icons.sync_problem,
        'fault' => Icons.error_outline,
        'startup' => Icons.power_settings_new,
        'rest' || 'idle' => Icons.pause_circle_outline,
        _ => Icons.help_outline,
      };

  static Color link(LinkStatus s) => switch (s) {
        LinkStatus.online => StatusColors.ok,
        LinkStatus.stale => StatusColors.warning,
        LinkStatus.offline => StatusColors.danger,
      };

  static String linkLabel(LinkStatus s) => switch (s) {
        LinkStatus.online => 'ONLINE',
        LinkStatus.stale => 'STALE',
        LinkStatus.offline => 'OFFLINE',
      };

  /// Same look as the software app's mode badges.
  static LinearGradient modeGradient(String? mode) => switch (mode) {
        'adaptive' => ModeColors.gradient('ADAPTIVE'),
        'fixed' => ModeColors.gradient('FIXED_TIME'),
        _ => const LinearGradient(colors: [Color(0xFF64748B), Color(0xFF94A3B8)]),
      };

  static IconData modeIcon(String? mode) => switch (mode) {
        'adaptive' => ModeColors.icon('ADAPTIVE'),
        'fixed' => ModeColors.icon('FIXED_TIME'),
        _ => Icons.help_outline,
      };
}

/// Titled card used by every dashboard section.
class HwCard extends StatelessWidget {
  const HwCard({super.key, required this.title, required this.icon, required this.child, this.trailing});

  final String title;
  final IconData icon;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, size: 20, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(child: Text(title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800))),
            ?trailing,
          ]),
          const SizedBox(height: 12),
          child,
        ]),
      ),
    );
  }
}

/// Small coloured label with an optional icon (same style as the software app's chips).
class HwChip extends StatelessWidget {
  const HwChip({super.key, required this.label, required this.color, this.icon, this.large = false});

  final String label;
  final Color color;
  final IconData? icon;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final ink = StatusColors.readable(color, Theme.of(context).brightness);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: large ? 12 : 9, vertical: large ? 6 : 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[Icon(icon, size: large ? 17 : 14, color: ink), const SizedBox(width: 5)],
        Text(label,
            style: TextStyle(color: ink, fontWeight: FontWeight.w700, fontSize: large ? 14 : 12.5)),
      ]),
    );
  }
}

/// Label above a value.
class HwFigure extends StatelessWidget {
  const HwFigure(this.label, this.value, {super.key, this.big = false});
  final String label;
  final String value;
  final bool big;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(label, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      const SizedBox(height: 2),
      Text(value,
          style: (big ? theme.textTheme.headlineSmall : theme.textTheme.titleMedium)
              ?.copyWith(fontWeight: FontWeight.w800, fontFeatures: const [FontFeature.tabularFigures()])),
    ]);
  }
}

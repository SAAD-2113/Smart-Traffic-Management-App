import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import 'glass.dart';

/// Gradient hero header with a title, an optional subtitle, actions and extra content.
class GradientHeader extends StatelessWidget {
  const GradientHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.actions = const [],
    this.child,
    this.gradient = Brand.hero,
    this.padding = const EdgeInsets.fromLTRB(20, 18, 12, 20),
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final List<Widget> actions;
  final Widget? child;
  final Gradient gradient;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    return Container(
      decoration: BoxDecoration(
        gradient: gradient,
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(28)),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.28), blurRadius: 18, offset: const Offset(0, 6))],
      ),
      child: Stack(children: [
        // Signal glows behind the asphalt glass: red, amber, green.
        const Positioned(right: -50, top: -60, child: _Glow(size: 200, color: Brand.red, opacity: 0.38)),
        const Positioned(right: 70, bottom: -90, child: _Glow(size: 170, color: Brand.amber, opacity: 0.26)),
        const Positioned(left: -70, bottom: -80, child: _Glow(size: 190, color: Brand.green, opacity: 0.30)),
        // The three lamps as a hairline along the bottom edge.
        const Positioned(left: 24, right: 24, bottom: 0, child: SignalStripe()),
        Padding(
          padding: padding.copyWith(top: padding.top + top),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (icon != null) ...[
                Container(
                  padding: const EdgeInsets.all(9),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
                  ),
                  child: Icon(icon, color: Colors.white, size: 24),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 23, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
                  if (subtitle != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(subtitle!,
                          style: TextStyle(color: Colors.white.withValues(alpha: 0.78), fontSize: 13.5)),
                    ),
                ]),
              ),
              ...actions,
            ]),
            if (child != null) ...[const SizedBox(height: 14), child!],
          ]),
        ),
      ]),
    );
  }
}

class _Glow extends StatelessWidget {
  const _Glow({required this.size, required this.color, required this.opacity});
  final double size;
  final Color color;
  final double opacity;

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(colors: [color.withValues(alpha: opacity), color.withValues(alpha: 0)]),
          ),
        ),
      );
}

/// A thin red / amber / green line: the three lamps as an accent.
class SignalStripe extends StatelessWidget {
  const SignalStripe({super.key, this.height = 3});
  final double height;

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(height),
        child: SizedBox(
          height: height,
          child: const Row(children: [
            Expanded(child: ColoredBox(color: Brand.red)),
            Expanded(child: ColoredBox(color: Brand.amber)),
            Expanded(child: ColoredBox(color: Brand.green)),
          ]),
        ),
      );
}

/// The app's mark: a traffic light (asphalt housing, red / amber / green lamps with a glow),
/// the same drawing as the launcher icon.
class TrafficLightLogo extends StatelessWidget {
  const TrafficLightLogo({super.key, this.size = 72});
  final double size;

  @override
  Widget build(BuildContext context) {
    final lamp = size * 0.2;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: Brand.hero,
        borderRadius: BorderRadius.circular(size * 0.28),
        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
        boxShadow: [
          BoxShadow(color: Brand.red.withValues(alpha: 0.28), blurRadius: size * 0.3, offset: Offset(-size * 0.08, -size * 0.04)),
          BoxShadow(color: Brand.green.withValues(alpha: 0.28), blurRadius: size * 0.3, offset: Offset(size * 0.08, size * 0.08)),
        ],
      ),
      child: Center(
        child: Container(
          width: size * 0.36,
          padding: EdgeInsets.symmetric(vertical: size * 0.05),
          decoration: BoxDecoration(
            color: const Color(0xFF0A0A0A),
            borderRadius: BorderRadius.circular(size * 0.1),
            border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final c in Brand.signals)
              Container(
                width: lamp,
                height: lamp,
                margin: EdgeInsets.symmetric(vertical: size * 0.022),
                decoration: BoxDecoration(
                  color: c,
                  shape: BoxShape.circle,
                  boxShadow: [BoxShadow(color: c.withValues(alpha: 0.75), blurRadius: lamp * 0.7)],
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

/// Small translucent pill for use on gradient headers.
class HeaderPill extends StatelessWidget {
  const HeaderPill({super.key, required this.label, this.icon, this.dotColor});
  final String label;
  final IconData? icon;
  final Color? dotColor;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.13),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (dotColor != null) ...[
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: dotColor,
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: dotColor!.withValues(alpha: 0.7), blurRadius: 6)],
              ),
            ),
            const SizedBox(width: 6),
          ],
          if (icon != null) ...[Icon(icon, size: 14, color: Colors.white), const SizedBox(width: 5)],
          Text(label, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
        ]),
      );
}

/// A key figure: label, big value, optional unit and caption. Text uses text colours; the
/// accent colour only tints the icon.
class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    this.unit,
    this.caption,
    this.accent,
    this.onTap,
  });

  final String label;
  final String value;
  final IconData icon;
  final String? unit;
  final String? caption;
  final Color? accent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = accent ?? theme.colorScheme.primary;
    return GlassCard(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Row(children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [color.withValues(alpha: 0.22), color.withValues(alpha: 0.08)],
                ),
                borderRadius: BorderRadius.circular(13),
              ),
              child: Icon(icon, color: color, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                  // The value keeps its width; a long unit gives way (ellipsis) instead.
                  Text(value,
                      maxLines: 1,
                      style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800, height: 1.15)),
                  if (unit != null) ...[
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(unit!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                    ),
                  ],
                ]),
                if (caption != null)
                  Text(caption!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Primary action with the brand gradient.
class GradientButton extends StatelessWidget {
  const GradientButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.gradient = Brand.action,
    this.busy = false,
    this.height = 54,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final Gradient gradient;
  final bool busy;
  final double height;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !busy;
    return Opacity(
      opacity: enabled || busy ? 1 : 0.5,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: gradient,
          borderRadius: BorderRadius.circular(16),
          boxShadow: enabled
              ? [BoxShadow(color: Brand.green.withValues(alpha: 0.32), blurRadius: 14, offset: const Offset(0, 5))]
              : null,
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: enabled ? onPressed : null,
            borderRadius: BorderRadius.circular(16),
            child: SizedBox(
              height: height,
              child: Center(
                child: busy
                    ? const SizedBox(
                        width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                    : Row(mainAxisSize: MainAxisSize.min, children: [
                        if (icon != null) ...[Icon(icon, color: Colors.white), const SizedBox(width: 10)],
                        Text(label,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 16.5, fontWeight: FontWeight.w700, letterSpacing: 0.2)),
                      ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

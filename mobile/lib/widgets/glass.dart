import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';

/// The background behind every screen: white (light) or black (dark) with soft red, amber and
/// green signal glows and a faint dot grid, which the glass surfaces above it frost over.
///
/// Used as `MaterialApp.builder`, so it sits under the navigator; screens are transparent.
/// Glass surfaces below it share one backdrop snapshot ([BackdropGroup]).
class GlassBackdrop extends StatelessWidget {
  const GlassBackdrop({super.key, required this.child});

  final Widget child;

  /// For `MaterialApp(builder: GlassBackdrop.builder)`.
  static Widget builder(BuildContext context, Widget? child) => GlassBackdrop(child: child ?? const SizedBox());

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return ColoredBox(
      color: Glass.background(brightness),
      child: Stack(fit: StackFit.expand, children: [
        RepaintBoundary(child: CustomPaint(painter: _GlowPainter(brightness))),
        BackdropGroup(child: child),
      ]),
    );
  }
}

class _GlowPainter extends CustomPainter {
  _GlowPainter(this.brightness);
  final Brightness brightness;

  @override
  void paint(Canvas canvas, Size size) {
    final dark = brightness == Brightness.dark;
    final w = size.width, h = size.height;
    final r = (w > h ? w : h);
    // (centre, radius, colour, strength light / dark)
    final glows = <(Offset, double, Color, double, double)>[
      (Offset(w * -0.05, h * 0.02), r * 0.62, Brand.red, 0.16, 0.30),
      (Offset(w * 1.02, h * 0.34), r * 0.55, Brand.amber, 0.20, 0.24),
      (Offset(w * 0.12, h * 1.0), r * 0.62, Brand.green, 0.17, 0.28),
      (Offset(w * 0.95, h * 0.95), r * 0.40, Brand.orange, 0.08, 0.14),
    ];
    for (final (c, radius, color, light, darkA) in glows) {
      final a = dark ? darkA : light;
      final paint = Paint()
        ..shader = RadialGradient(colors: [
          color.withValues(alpha: a),
          color.withValues(alpha: a * 0.45),
          color.withValues(alpha: 0),
        ], stops: const [0, 0.45, 1]).createShader(Rect.fromCircle(center: c, radius: radius));
      canvas.drawCircle(c, radius, paint);
    }
    // Faint dot grid: crisp detail that glass surfaces visibly blur.
    final dot = Paint()..color = (dark ? Colors.white : Colors.black).withValues(alpha: dark ? 0.07 : 0.06);
    const step = 22.0;
    for (var y = step / 2; y < h; y += step) {
      for (var x = step / 2; x < w; x += step) {
        canvas.drawCircle(Offset(x, y), 0.9, dot);
      }
    }
  }

  @override
  bool shouldRepaint(_GlowPainter old) => old.brightness != brightness;
}

/// Frosted glass: clips to [borderRadius], blurs what is behind (shared [BackdropGroup]
/// snapshot when there is one) and paints the translucent glass fill with a hairline border.
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(20)),
    this.color,
    this.padding,
    this.border = true,
    this.blur = Glass.blurSigma,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final Color? color;
  final EdgeInsetsGeometry? padding;
  final bool border;
  final double blur;

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter.grouped(
        filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: color ?? Glass.fill(b),
            borderRadius: borderRadius,
            border: border ? Border.all(color: Glass.border(b)) : null,
            gradient: _sheen(b),
          ),
          child: padding == null ? child : Padding(padding: padding!, child: child),
        ),
      ),
    );
  }

  /// A light sheen from the top-left edge, the "glass" highlight.
  static LinearGradient _sheen(Brightness b) => LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Colors.white.withValues(alpha: b == Brightness.dark ? 0.06 : 0.35),
          Colors.white.withValues(alpha: 0),
        ],
        stops: const [0, 0.55],
      );
}

/// A drop-in replacement for [Card] with a frosted-glass background: same parameters, the
/// theme's glass fill and border, and background blur. A solid [color] is made translucent
/// (at most 72 % opaque) so tinted cards stay glass too.
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    this.child,
    this.margin,
    this.color,
    this.shape,
    this.clipBehavior,
    this.elevation,
    this.shadowColor,
    this.surfaceTintColor,
    this.semanticContainer = true,
    this.borderOnForeground = true,
  });

  final Widget? child;
  final EdgeInsetsGeometry? margin;
  final Color? color;
  final ShapeBorder? shape;
  final Clip? clipBehavior;
  final double? elevation;
  final Color? shadowColor;
  final Color? surfaceTintColor;
  final bool semanticContainer;
  final bool borderOnForeground;

  @override
  Widget build(BuildContext context) {
    final cardTheme = CardTheme.of(context);
    final shape = this.shape ?? cardTheme.shape ?? const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(20)));
    final radius = shape is RoundedRectangleBorder
        ? shape.borderRadius.resolve(Directionality.of(context))
        : const BorderRadius.all(Radius.circular(20));
    final base = color;
    final fill = base == null ? null : (base.a > 0.72 ? base.withValues(alpha: 0.72) : base);
    return Padding(
      padding: margin ?? cardTheme.margin ?? EdgeInsets.zero,
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter.grouped(
          filter: ui.ImageFilter.blur(sigmaX: Glass.blurSigma, sigmaY: Glass.blurSigma),
          child: Card(
            margin: EdgeInsets.zero,
            color: fill,
            shape: shape,
            clipBehavior: clipBehavior,
            elevation: 0,
            shadowColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            semanticContainer: semanticContainer,
            borderOnForeground: borderOnForeground,
            child: child,
          ),
        ),
      ),
    );
  }
}

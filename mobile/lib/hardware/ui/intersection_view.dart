import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import 'hw_style.dart';

/// Top-down view of the intersection: two roads, one signal head per approach (N top, S bottom,
/// W left, E right) showing its real lamp, and the countdown in the middle.
class IntersectionView extends StatelessWidget {
  const IntersectionView({
    super.key,
    required this.signals,
    required this.countdown,
    required this.interval,
    required this.live,
  });

  /// "R" | "Y" | "G" | "OFF" per approach; null when missing.
  final Map<String, String?> signals;

  /// Seconds shown in the centre, or null ("—").
  final int? countdown;
  final String? interval;

  /// False: greyed lamps and a grey countdown ("Last known state").
  final bool live;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final size = c.maxWidth.clamp(220.0, 340.0);
      final road = size * 0.34;
      final lamp = (size * 0.058).clamp(13.0, 20.0);
      final center = size / 2;
      // Head size: three bulbs (lamp + margins) inside a padded, bordered body.
      final thick = lamp * 1.6 + 2.4;
      final long = lamp * 4.2 + 2.4;
      final gap = lamp * 0.55;
      final dark = Theme.of(context).brightness == Brightness.dark;
      Widget head(String a, {required bool vertical}) => _SignalHead(
            key: ValueKey('head-$a'),
            approach: a,
            signal: signals[a],
            lamp: lamp,
            vertical: vertical,
            live: live,
          );
      return Center(
        child: SizedBox(
          width: size,
          height: size,
          child: Stack(children: [
            Positioned.fill(child: CustomPaint(painter: _RoadPainter(road: road, dark: dark))),
            // Each head stands on its approach, just outside the junction box.
            Positioned(left: center - thick / 2, top: center - road / 2 - gap - long, child: head('N', vertical: true)),
            Positioned(left: center - thick / 2, top: center + road / 2 + gap, child: head('S', vertical: true)),
            Positioned(left: center - road / 2 - gap - long, top: center - thick / 2, child: head('W', vertical: false)),
            Positioned(left: center + road / 2 + gap, top: center - thick / 2, child: head('E', vertical: false)),
            Center(child: _Countdown(seconds: countdown, interval: interval, live: live, size: road * 0.92)),
          ]),
        ),
      );
    });
  }
}

class _RoadPainter extends CustomPainter {
  _RoadPainter({required this.road, required this.dark});
  final double road;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final asphalt = Paint()..color = dark ? const Color(0xFF263250) : const Color(0xFFD5DCE8);
    final r = Radius.circular(road * 0.18);
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: c, width: road, height: size.height), r), asphalt);
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: c, width: size.width, height: road), r), asphalt);
    // Centre lines (dashed) up to the junction box, and stop lines.
    final line = Paint()
      ..color = dark ? Colors.white24 : Colors.white
      ..strokeWidth = 2;
    const dash = 8.0, space = 7.0;
    for (var y = 4.0; y < c.dy - road / 2 - 4; y += dash + space) {
      canvas.drawLine(Offset(c.dx, y), Offset(c.dx, y + dash), line);
      canvas.drawLine(Offset(c.dx, size.height - y), Offset(c.dx, size.height - y - dash), line);
    }
    for (var x = 4.0; x < c.dx - road / 2 - 4; x += dash + space) {
      canvas.drawLine(Offset(x, c.dy), Offset(x + dash, c.dy), line);
      canvas.drawLine(Offset(size.width - x, c.dy), Offset(size.width - x - dash, c.dy), line);
    }
    final stop = Paint()
      ..color = dark ? Colors.white38 : Colors.white
      ..strokeWidth = 3;
    final h = road / 2;
    canvas.drawLine(Offset(c.dx - h, c.dy - h), Offset(c.dx + h, c.dy - h), stop);
    canvas.drawLine(Offset(c.dx - h, c.dy + h), Offset(c.dx + h, c.dy + h), stop);
    canvas.drawLine(Offset(c.dx - h, c.dy - h), Offset(c.dx - h, c.dy + h), stop);
    canvas.drawLine(Offset(c.dx + h, c.dy - h), Offset(c.dx + h, c.dy + h), stop);
  }

  @override
  bool shouldRepaint(_RoadPainter old) => old.road != road || old.dark != dark;
}

/// A three-lamp head; only the lamp in [signal] is lit.
class _SignalHead extends StatelessWidget {
  const _SignalHead({
    super.key,
    required this.approach,
    required this.signal,
    required this.lamp,
    required this.vertical,
    required this.live,
  });

  final String approach;
  final String? signal;
  final double lamp;
  final bool vertical;
  final bool live;

  @override
  Widget build(BuildContext context) {
    Widget bulb(String which) {
      final on = signal == which;
      final color = on ? (live ? HwColors.lamp(which) : HwColors.lampGreyed(which)) : SignalColors.off;
      return Container(
        width: lamp,
        height: lamp,
        margin: EdgeInsets.all(lamp * 0.15),
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          boxShadow: on && live ? [BoxShadow(color: color.withValues(alpha: 0.85), blurRadius: lamp * 0.8)] : null,
        ),
      );
    }

    final bulbs = [bulb('R'), bulb('Y'), bulb('G')];
    final body = Container(
      padding: EdgeInsets.all(lamp * 0.15),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(lamp * 0.45),
        border: Border.all(color: Colors.white.withValues(alpha: 0.85), width: 1.2),
      ),
      child: vertical
          ? Column(mainAxisSize: MainAxisSize.min, children: bulbs)
          : Row(mainAxisSize: MainAxisSize.min, children: bulbs),
    );
    return Semantics(
      container: true,
      label: '$approach signal ${switch (signal) { 'G' => 'green', 'Y' => 'yellow', 'R' => 'red', 'OFF' => 'off', _ => 'unknown' }}',
      child: Stack(clipBehavior: Clip.none, children: [
        body,
        Positioned(
          right: vertical ? -lamp * 1.05 : null,
          left: vertical ? null : 0,
          top: vertical ? 0 : -lamp * 1.05,
          child: Text(approach,
              style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: lamp * 0.8,
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ),
      ]),
    );
  }
}

class _Countdown extends StatelessWidget {
  const _Countdown({required this.seconds, required this.interval, required this.live, required this.size});

  final int? seconds;
  final String? interval;
  final bool live;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ring = live ? HwColors.interval(interval) : StatusColors.neutral;
    return Container(
      key: const ValueKey('countdown'),
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        shape: BoxShape.circle,
        border: Border.all(color: ring, width: size * 0.07),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 10)],
      ),
      alignment: Alignment.center,
      child: FittedBox(
        child: Padding(
          padding: EdgeInsets.all(size * 0.12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
            Text(seconds == null ? '—' : '$seconds',
                key: const ValueKey('countdown-value'),
                style: TextStyle(
                  fontSize: size * 0.42,
                  fontWeight: FontWeight.w900,
                  height: 1,
                  color: live ? theme.colorScheme.onSurface : theme.colorScheme.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                )),
            if (seconds != null)
              Text(' s', style: TextStyle(fontSize: size * 0.16, fontWeight: FontWeight.w700, color: theme.colorScheme.onSurfaceVariant)),
          ]),
        ),
      ),
    );
  }
}

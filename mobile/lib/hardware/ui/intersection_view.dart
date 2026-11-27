import 'dart:math' as math;

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
    this.displays,
    this.dots,
  });

  /// Optional vehicles to draw (firmware v3 / Digital V2I): metres east / north of the centre.
  final List<JunctionDot>? dots;

  /// Optional MM:SS display beside each head (firmware v3 lanes: the TM1637 modules).
  final Map<String, String?>? displays;

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
      final d = displays;
      final dispW = lamp * 3.4, dispH = lamp * 1.35;
      Widget display(String a) => _LaneDisplay(
            key: ValueKey('display-$a'),
            text: d?[a],
            signal: signals[a],
            live: live,
            width: dispW,
            height: dispH,
          );
      final nTop = center - road / 2 - gap - long, sTop = center + road / 2 + gap;
      final wLeft = center - road / 2 - gap - long, eLeft = center + road / 2 + gap;
      return Center(
        child: SizedBox(
          width: size,
          height: size,
          child: Stack(children: [
            Positioned.fill(child: CustomPaint(painter: _RoadPainter(road: road, dark: dark))),
            // Each head stands on its approach, just outside the junction box.
            Positioned(left: center - thick / 2, top: nTop, child: head('N', vertical: true)),
            Positioned(left: center - thick / 2, top: sTop, child: head('S', vertical: true)),
            Positioned(left: wLeft, top: center - thick / 2, child: head('W', vertical: false)),
            Positioned(left: eLeft, top: center - thick / 2, child: head('E', vertical: false)),
            if (d != null) ...[
              // vertical heads: display on the left (the label is on the right)
              Positioned(left: center - thick / 2 - 6 - dispW, top: nTop + long / 2 - dispH / 2, child: display('N')),
              Positioned(left: center - thick / 2 - 6 - dispW, top: sTop + long / 2 - dispH / 2, child: display('S')),
              // horizontal heads: display below (the label is above)
              Positioned(left: wLeft + long / 2 - dispW / 2, top: center + thick / 2 + 6, child: display('W')),
              Positioned(left: eLeft + long / 2 - dispW / 2, top: center + thick / 2 + 6, child: display('E')),
            ],
            if (dots != null && dots!.isNotEmpty)
              Positioned.fill(
                child: IgnorePointer(child: CustomPaint(painter: _DotPainter(dots: dots!, road: road, live: live))),
              ),
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
    final asphalt = Paint()..color = dark ? const Color(0xFF2B2826) : const Color(0xFFE2DFDB);
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
        color: const Color(0xFF141414),
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

/// A vehicle on the junction drawing.
class JunctionDot {
  const JunctionDot({required this.x, required this.y, required this.state, this.emergency = false, this.lane});

  /// Metres east (x) and north (y) of the junction centre.
  final double x, y;

  /// "APPROACHING" | "QUEUED" | "CROSSING" | "IGNORED".
  final String? state;
  final bool emergency;

  /// Lane the intersection decided ("N".."W"), null when none.
  final String? lane;

  static Color colorOf(String? state) => switch (state) {
        'QUEUED' => const Color(0xFFEF4444),
        'APPROACHING' => const Color(0xFFF59E0B),
        'CROSSING' => const Color(0xFF16A34A),
        _ => const Color(0xFFA8A29E),
      };
}

/// Schematic positions: the 10 m junction box maps to the drawn box and 150 m (the detection
/// radius) to the edge, at the vehicle's real bearing; dots sit in the left-hand inbound lane of
/// their arm so they do not hide the signal heads.
class _DotPainter extends CustomPainter {
  _DotPainter({required this.dots, required this.road, required this.live});
  final List<JunctionDot> dots;
  final double road;
  final bool live;

  static const boxM = 10.0, edgeM = 150.0;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final half = size.shortestSide / 2;
    for (final d in dots) {
      final r = math.sqrt(d.x * d.x + d.y * d.y);
      final b = math.atan2(d.x, d.y); // bearing from north, radians
      final px = r <= boxM ? r / boxM * road / 2 : road / 2 + (math.min(r, edgeM) - boxM) / (edgeM - boxM) * (half - road / 2 - 6);
      var p = c + Offset(math.sin(b) * px, -math.cos(b) * px);
      if (r > boxM) {
        // left-hand traffic: the inbound lane is to the right of the arm, seen from the centre
        final arm = d.lane == null ? b : const {'N': 0.0, 'E': math.pi / 2, 'S': math.pi, 'W': 3 * math.pi / 2}[d.lane]!;
        p += Offset(math.sin(arm + math.pi / 2), -math.cos(arm + math.pi / 2)) * (road / 4);
      }
      final color = live ? JunctionDot.colorOf(d.state) : const Color(0xFFA8A29E);
      final radius = d.emergency ? 7.5 : 6.0;
      canvas.drawCircle(p, radius + 1.5, Paint()..color = Colors.white);
      canvas.drawCircle(p, radius, Paint()..color = color);
      if (d.emergency) {
        canvas.drawCircle(p, radius + 3, Paint()
          ..color = const Color(0xFFD50000)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2);
      }
      if (r > edgeM) {
        canvas.drawCircle(p, radius - 2.5, Paint()..color = Colors.white); // beyond 150 m: hollow
      }
    }
  }

  @override
  bool shouldRepaint(_DotPainter old) => true;
}

/// A lane's 4-digit display, "MM:SS" in the lane's current colour.
class _LaneDisplay extends StatelessWidget {
  const _LaneDisplay({
    super.key,
    required this.text,
    required this.signal,
    required this.live,
    required this.width,
    required this.height,
  });

  final String? text;
  final String? signal;
  final bool live;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final color = live ? HwColors.lamp(signal) : const Color(0xFF9A948E);
    return Container(
      width: width,
      height: height,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xFF0E0E0E),
        borderRadius: BorderRadius.circular(height * 0.22),
        border: Border.all(color: Colors.white.withValues(alpha: 0.6)),
      ),
      child: FittedBox(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: height * 0.2),
          child: Text(text ?? '--:--',
              style: TextStyle(
                color: text == null ? const Color(0xFF9A948E) : (signal == 'Y' ? const Color(0xFFFFD54F) : color),
                fontWeight: FontWeight.w900,
                fontSize: height * 0.7,
                letterSpacing: 1,
                fontFeatures: const [FontFeature.tabularFigures()],
              )),
        ),
      ),
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

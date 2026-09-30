import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/theme/app_theme.dart';

class ChartPoint {
  ChartPoint(this.time, this.value);
  final DateTime time;
  final double? value;
}

class ChartSeries {
  ChartSeries({required this.label, required this.color, required this.points});
  final String label;
  final Color color;
  final List<ChartPoint> points;
}

/// Time-series line chart: one measure (one y-axis), thin lines, legend for 2+ series,
/// touch tooltips. Gaps in the data (null values) break the line instead of inventing values.
class TimeLineChart extends StatelessWidget {
  const TimeLineChart({
    super.key,
    required this.series,
    required this.unit,
    this.height = 200,
    this.minY = 0,
    this.decimals = 0,
  });

  final List<ChartSeries> series;
  final String unit;
  final double height;
  final double? minY;
  final int decimals;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final all = series.expand((s) => s.points).where((p) => p.value != null).toList();
    if (all.isEmpty) {
      return SizedBox(
        height: height,
        child: Center(child: Text('No data in this period', style: theme.textTheme.bodySmall)),
      );
    }
    final minX = all.map((p) => p.time.millisecondsSinceEpoch).reduce(math.min).toDouble();
    final maxX = all.map((p) => p.time.millisecondsSinceEpoch).reduce(math.max).toDouble();
    final maxV = all.map((p) => p.value!).reduce(math.max);
    final maxY = maxV <= 0 ? 1.0 : maxV * 1.15;
    final span = math.max(1.0, maxX - minX);
    final timeFormat = span > const Duration(hours: 20).inMilliseconds ? DateFormat('d MMM HH:mm') : DateFormat.Hm();
    final labelStyle = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant, fontSize: 11);

    List<FlSpot> spots(ChartSeries s) => [
          for (final p in s.points)
            p.value == null ? FlSpot.nullSpot : FlSpot(p.time.millisecondsSinceEpoch.toDouble(), p.value!),
        ];

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (series.length > 1)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Wrap(spacing: 14, runSpacing: 4, children: [
            for (final s in series)
              Row(mainAxisSize: MainAxisSize.min, children: [
                Container(width: 14, height: 3, color: s.color),
                const SizedBox(width: 6),
                Text(s.label, style: theme.textTheme.bodySmall),
              ]),
          ]),
        ),
      SizedBox(
        height: height,
        child: LineChart(
          LineChartData(
            minX: minX,
            maxX: maxX == minX ? minX + 1 : maxX,
            minY: minY,
            maxY: maxY,
            clipData: const FlClipData.all(),
            gridData: FlGridData(
              drawVerticalLine: false,
              getDrawingHorizontalLine: (_) => FlLine(color: ChartColors.grid(context), strokeWidth: 1),
            ),
            borderData: FlBorderData(show: false),
            titlesData: FlTitlesData(
              topTitles: const AxisTitles(),
              rightTitles: const AxisTitles(),
              leftTitles: AxisTitles(
                axisNameWidget: Text(unit, style: labelStyle),
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 40,
                  getTitlesWidget: (v, meta) => (v == meta.max)
                      ? const SizedBox.shrink()
                      : Text(v.toStringAsFixed(decimals), style: labelStyle),
                ),
              ),
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 26,
                  interval: span / 4,
                  getTitlesWidget: (v, meta) => (v == meta.min || v == meta.max)
                      ? const SizedBox.shrink()
                      : Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(timeFormat.format(DateTime.fromMillisecondsSinceEpoch(v.toInt())), style: labelStyle),
                        ),
                ),
              ),
            ),
            lineTouchData: LineTouchData(
              touchTooltipData: LineTouchTooltipData(
                fitInsideHorizontally: true,
                fitInsideVertically: true,
                getTooltipColor: (_) => theme.colorScheme.inverseSurface,
                getTooltipItems: (spots) => [
                  for (final s in spots)
                    LineTooltipItem(
                      '${series[s.barIndex].label}: ${s.y.toStringAsFixed(decimals)} $unit'
                      '${s == spots.first ? '\n${timeFormat.format(DateTime.fromMillisecondsSinceEpoch(s.x.toInt()))}' : ''}',
                      TextStyle(color: theme.colorScheme.onInverseSurface, fontSize: 12),
                    ),
                ],
              ),
            ),
            lineBarsData: [
              for (final s in series)
                LineChartBarData(
                  spots: spots(s),
                  color: s.color,
                  barWidth: 2,
                  isCurved: false,
                  dotData: FlDotData(show: s.points.length <= 2),
                ),
            ],
          ),
          duration: Duration.zero,
        ),
      ),
    ]);
  }
}

class BarItem {
  BarItem(this.label, this.value);
  final String label;
  final double? value;
}

/// One measure across categories (e.g. intersections). One hue: the bars differ in value,
/// not in identity. Missing values are shown as "no data" rather than zero.
class CategoryBarChart extends StatelessWidget {
  const CategoryBarChart({super.key, required this.items, required this.unit, this.height = 180, this.decimals = 0});

  final List<BarItem> items;
  final String unit;
  final double height;
  final int decimals;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = ChartColors.primary(context);
    final values = items.map((i) => i.value ?? 0).toList();
    final maxY = values.isEmpty ? 1.0 : math.max(1.0, values.reduce(math.max) * 1.2);
    final labelStyle = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant, fontSize: 11);
    return SizedBox(
      height: height,
      child: BarChart(
        BarChartData(
          maxY: maxY,
          gridData: FlGridData(
            drawVerticalLine: false,
            getDrawingHorizontalLine: (_) => FlLine(color: ChartColors.grid(context), strokeWidth: 1),
          ),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(),
            rightTitles: const AxisTitles(),
            leftTitles: AxisTitles(
              axisNameWidget: Text(unit, style: labelStyle),
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 40,
                getTitlesWidget: (v, meta) =>
                    v == meta.max ? const SizedBox.shrink() : Text(v.toStringAsFixed(decimals), style: labelStyle),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 28,
                getTitlesWidget: (v, meta) {
                  final i = v.toInt();
                  if (i < 0 || i >= items.length) return const SizedBox.shrink();
                  final missing = items[i].value == null;
                  return Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(missing ? '${items[i].label}\nno data' : items[i].label,
                        textAlign: TextAlign.center, style: labelStyle),
                  );
                },
              ),
            ),
          ),
          barTouchData: BarTouchData(
            touchTooltipData: BarTouchTooltipData(
              getTooltipColor: (_) => theme.colorScheme.inverseSurface,
              getTooltipItem: (group, _, rod, _) => BarTooltipItem(
                items[group.x].value == null
                    ? '${items[group.x].label}: no data'
                    : '${items[group.x].label}: ${rod.toY.toStringAsFixed(decimals)} $unit',
                TextStyle(color: theme.colorScheme.onInverseSurface, fontSize: 12),
              ),
            ),
          ),
          barGroups: [
            for (var i = 0; i < items.length; i++)
              BarChartGroupData(x: i, barRods: [
                BarChartRodData(
                  toY: items[i].value ?? 0,
                  color: color,
                  width: 22,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                ),
              ]),
          ],
        ),
        duration: Duration.zero,
      ),
    );
  }
}

/// Intersection codes sorted, so colour slot n always means the same intersection.
Map<String, int> seriesSlots(Iterable<String> codes) {
  final sorted = codes.toSet().toList()..sort(_naturalCompare);
  return {for (var i = 0; i < sorted.length; i++) sorted[i]: i};
}

int _naturalCompare(String a, String b) {
  final na = int.tryParse(a.replaceAll(RegExp(r'\D'), ''));
  final nb = int.tryParse(b.replaceAll(RegExp(r'\D'), ''));
  if (na != null && nb != null && na != nb) return na.compareTo(nb);
  return a.compareTo(b);
}

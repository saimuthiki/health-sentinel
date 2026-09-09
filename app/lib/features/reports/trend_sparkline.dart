import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../core/theme/hp_palette.dart';
import '../../data/models/models.dart';

/// A biomarker's history at a glance, with the usual range drawn behind it.
///
/// A sparkline, not a full chart: the number and its status carry the meaning,
/// and this only answers "is it moving the right way?". There are no axis
/// labels, because a chart with labels invites reading a trend as a prognosis.
class TrendSparkline extends StatelessWidget {
  const TrendSparkline({super.key, required this.trend, this.height = 56});

  final BiomarkerTrend trend;
  final double height;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    final List<TrendPoint> points = trend.points;

    if (points.length < 2) {
      return SizedBox(height: height);
    }

    final List<double> values =
        points.map((TrendPoint e) => e.value).toList();
    double lowest = values.reduce((double a, double b) => a < b ? a : b);
    double highest = values.reduce((double a, double b) => a > b ? a : b);
    final double? refLow = trend.refLow;
    final double? refHigh = trend.refHigh;
    if (refLow != null && refLow < lowest) {
      lowest = refLow;
    }
    if (refHigh != null && refHigh > highest) {
      highest = refHigh;
    }
    final double pad = (highest - lowest).abs() * 0.15 + 0.5;

    return SizedBox(
      height: height,
      child: Semantics(
        label: '${trend.displayName} over ${points.length} measurements, '
            'most recently ${values.last} ${trend.unit}',
        excludeSemantics: true,
        child: LineChart(
          LineChartData(
            minX: 0,
            maxX: (points.length - 1).toDouble(),
            minY: lowest - pad,
            maxY: highest + pad,
            gridData: FlGridData(show: false),
            titlesData: FlTitlesData(show: false),
            borderData: FlBorderData(show: false),
            lineTouchData: LineTouchData(enabled: false),
            rangeAnnotations: RangeAnnotations(
              horizontalRangeAnnotations: <HorizontalRangeAnnotation>[
                if (refLow != null && refHigh != null)
                  HorizontalRangeAnnotation(
                    y1: refLow,
                    y2: refHigh,
                    color: p.calmSoft,
                  ),
              ],
            ),
            lineBarsData: <LineChartBarData>[
              LineChartBarData(
                spots: <FlSpot>[
                  for (int i = 0; i < points.length; i++)
                    FlSpot(i.toDouble(), points[i].value),
                ],
                isCurved: true,
                curveSmoothness: 0.25,
                barWidth: 2.5,
                color: p.pine,
                dotData: FlDotData(show: false),
                belowBarData: BarAreaData(show: false),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/hp_palette.dart';

/// The HealthPulse mark: the day drawn as an arc from waking to sleeping, with
/// one warm moment sitting on it - now.
///
/// The same geometry is in `android/app/src/main/res/drawable/hp_mark.xml`, so
/// the splash screen and the first Flutter frame show the same shape.
class HpMark extends StatelessWidget {
  const HpMark({super.key, this.size = 56});

  final double size;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _HpMarkPainter(
          stroke: p.pine,
          dot: p.marigold,
          horizon: p.outline,
        ),
        isComplex: false,
      ),
    );
  }
}

class _HpMarkPainter extends CustomPainter {
  const _HpMarkPainter({
    required this.stroke,
    required this.dot,
    required this.horizon,
  });

  final Color stroke;
  final Color dot;
  final Color horizon;

  @override
  void paint(Canvas canvas, Size size) {
    final double s = size.shortestSide / 108.0;
    final Paint arc = Paint()
      ..color = stroke
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 8 * s;

    final Rect rect = Rect.fromCircle(
      center: Offset(54 * s, 60 * s),
      radius: 24 * s,
    );
    canvas.drawArc(rect, math.pi, math.pi, false, arc);

    final Paint horizonPaint = Paint()
      ..color = horizon
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 5 * s;
    canvas.drawLine(
        Offset(32 * s, 70 * s), Offset(76 * s, 70 * s), horizonPaint);

    canvas.drawCircle(
      Offset(71 * s, 43 * s),
      8 * s,
      Paint()..color = dot,
    );
  }

  @override
  bool shouldRepaint(_HpMarkPainter oldDelegate) =>
      oldDelegate.stroke != stroke ||
      oldDelegate.dot != dot ||
      oldDelegate.horizon != horizon;
}

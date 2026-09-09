import 'package:flutter/material.dart';

import '../theme/hp_palette.dart';
import '../theme/hp_spacing.dart';
import '../theme/hp_typography.dart';

/// A progress bar with the number spelled out beside it.
///
/// Progress is the one other place marigold is spent. The written value carries
/// the meaning; the bar only makes it glanceable, which is why the bar is never
/// the only thing on screen saying how far along the day is.
class HpMeter extends StatelessWidget {
  const HpMeter({
    super.key,
    required this.label,
    required this.value,
    required this.target,
    required this.unit,
    this.footnote,
  });

  final String label;
  final double value;
  final double target;
  final String unit;
  final String? footnote;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    final double fraction =
        target <= 0 ? 0 : (value / target).clamp(0.0, 1.0).toDouble();
    final String reading = '${_trim(value)} of ${_trim(target)} $unit';

    return Semantics(
      label: '$label: $reading',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  label,
                  style: HpType.label.copyWith(color: p.inkMuted),
                ),
              ),
              Text(
                reading,
                style: HpType.figureSmall.copyWith(color: p.ink, fontSize: 16),
              ),
            ],
          ),
          const SizedBox(height: HpSpacing.sm),
          ClipRRect(
            borderRadius: HpRadii.pillRadius,
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: 8,
              backgroundColor: p.surfaceSunk,
              valueColor: AlwaysStoppedAnimation<Color>(p.marigold),
            ),
          ),
          if (footnote != null) ...<Widget>[
            const SizedBox(height: HpSpacing.sm),
            Text(
              footnote!,
              style: HpType.micro.copyWith(color: p.inkFaint),
            ),
          ],
        ],
      ),
    );
  }

  static String _trim(double v) {
    if (v == v.roundToDouble()) {
      return v.toStringAsFixed(0);
    }
    return v.toStringAsFixed(1);
  }
}

import 'package:flutter/material.dart';

import '../theme/hp_palette.dart';
import '../theme/hp_spacing.dart';
import '../theme/hp_typography.dart';

/// The permanent disclaimer.
///
/// This widget has **no dismiss affordance and never will**. It is one of the
/// three independent places where the boundary between coaching and medicine is
/// enforced (see `docs/01-product-and-safety.md`); the other two are the model
/// persona and the server-side output validator. Any screen that shows an
/// interpretation of health data shows this, and on the report and plan screens
/// it is pinned rather than scrolled with the content.
///
/// It is deliberately quiet rather than alarming. A warning the user learns to
/// skip past is worth nothing, and a red banner on every screen of a daily app
/// teaches exactly that.
class HpDisclaimer extends StatelessWidget {
  const HpDisclaimer({super.key}) : compact = false;

  /// A single line, for places where the full paragraph would crowd the content.
  const HpDisclaimer.compact({super.key}) : compact = true;

  final bool compact;

  static const String fullText =
      'HealthPulse is a coach, not a doctor. It explains your results in plain '
      'language and suggests food, movement and sleep. It does not diagnose, and '
      'it never recommends a medicine or a dose. Anything unusual here is worth '
      'discussing with your doctor.';

  static const String compactText =
      'A coach, not a doctor. Worth discussing anything unusual with your doctor.';

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    final String text = compact ? compactText : fullText;

    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
        HpSpacing.gutter,
        compact ? HpSpacing.md : HpSpacing.lg,
        HpSpacing.gutter,
        compact ? HpSpacing.md : HpSpacing.lg,
      ),
      decoration: BoxDecoration(
        color: p.isDark ? p.surfaceSunk : p.surfaceSunk,
        border: Border(top: BorderSide(color: p.hairline)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.shield_outlined, size: 18, color: p.inkMuted),
          const SizedBox(width: HpSpacing.md),
          Expanded(
            child: Text(
              text,
              style: (compact ? HpType.micro : HpType.label)
                  .copyWith(color: p.inkMuted, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../theme/hp_palette.dart';
import '../theme/hp_spacing.dart';
import '../theme/hp_typography.dart';

/// The card shown for an `urgent` finding.
///
/// Three deliberate rules, all of them product requirements rather than taste:
///
/// 1. **It cannot be dismissed.** There is no close button, no swipe target and
///    no `onDismiss` parameter. If a red-flag value can be swiped away, the
///    safety layer has a hole in it.
/// 2. **It dominates.** It breaks the card grid - full width, a solid bar down
///    the leading edge, a square leading corner, and the only place in the app
///    where a solid alarm colour is used. Nothing else on the screen competes.
/// 3. **It does not diagnose or prescribe.** [body] says what was seen and why
///    it matters; [steps] are things to *do* or *ask*, never a medicine, never a
///    dose, and never an instruction to stop a treatment.
class HpEscalationCard extends StatelessWidget {
  const HpEscalationCard({
    super.key,
    required this.title,
    required this.body,
    this.steps = const <String>[],
    this.onFindCare,
    this.findCareLabel = 'How to get care today',
    this.footnote,
  });

  /// Plain and specific: "Your potassium is well below the usual range".
  final String title;

  /// One or two sentences on what was seen and how soon to act.
  final String body;

  /// Actions and questions. Never a medicine, never a dose.
  final List<String> steps;

  final VoidCallback? onFindCare;
  final String findCareLabel;

  /// Where the threshold came from, so the claim is traceable.
  final String? footnote;

  static const BorderRadius _rightRadius = BorderRadius.only(
    topRight: Radius.circular(HpRadii.card),
    bottomRight: Radius.circular(HpRadii.card),
  );

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;

    return Semantics(
      container: true,
      liveRegion: true,
      label: 'Needs attention. $title',
      child: DecoratedBox(
        // The solid leading bar is a sibling layer rather than a thick
        // BorderSide: a BoxDecoration may not combine a non-uniform border with
        // a border radius, and the square leading edge is the point of the shape.
        decoration: BoxDecoration(
          color: p.urgentSolid,
          borderRadius: _rightRadius,
        ),
        child: Container(
          width: double.infinity,
          margin: const EdgeInsets.only(left: 6),
          padding: const EdgeInsets.all(HpSpacing.lg),
          decoration: BoxDecoration(
            color: p.urgentSoft,
            borderRadius: _rightRadius,
            border: Border.all(color: p.urgentSolid),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Container(
                    width: 30,
                    height: 30,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: p.urgentSolid,
                      borderRadius: HpRadii.pillRadius,
                    ),
                    child: Icon(
                      Icons.priority_high_rounded,
                      size: 19,
                      color: p.onUrgent,
                    ),
                  ),
                  const SizedBox(width: HpSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          'Needs attention',
                          style: HpType.label.copyWith(
                            color: p.urgentInk,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: HpSpacing.xxs),
                        Text(
                          title,
                          style: HpType.headline.copyWith(color: p.ink),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: HpSpacing.md),
              Text(body, style: HpType.reading.copyWith(color: p.ink)),
              if (steps.isNotEmpty) ...<Widget>[
                const SizedBox(height: HpSpacing.lg),
                for (final String step in steps)
                  Padding(
                    padding: const EdgeInsets.only(bottom: HpSpacing.sm),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Padding(
                          padding: const EdgeInsets.only(top: 7),
                          child: Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: p.urgentInk,
                              borderRadius: HpRadii.pillRadius,
                            ),
                          ),
                        ),
                        const SizedBox(width: HpSpacing.md),
                        Expanded(
                          child: Text(
                            step,
                            style: HpType.body.copyWith(color: p.ink),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
              if (onFindCare != null) ...<Widget>[
                const SizedBox(height: HpSpacing.md),
                Material(
                  color: p.urgentSolid,
                  borderRadius: HpRadii.fieldRadius,
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: onFindCare,
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 52),
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(
                        horizontal: HpSpacing.xl,
                        vertical: HpSpacing.md,
                      ),
                      child: Text(
                        findCareLabel,
                        textAlign: TextAlign.center,
                        style: HpType.button.copyWith(color: p.onUrgent),
                      ),
                    ),
                  ),
                ),
              ],
              if (footnote != null) ...<Widget>[
                const SizedBox(height: HpSpacing.md),
                Text(
                  footnote!,
                  style: HpType.micro.copyWith(color: p.inkMuted),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

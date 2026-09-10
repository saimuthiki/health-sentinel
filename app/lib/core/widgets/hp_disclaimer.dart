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
/// What *can* change is how much room it takes. A four-line paragraph pinned to
/// the bottom of a daily app is read once and skipped for ever after, and it
/// costs the content a quarter of a phone screen every single day. So the line
/// that carries the meaning - **a coach, not a doctor** - is always on screen,
/// and the elaboration is one tap away behind it. Collapsing the detail is not
/// the same as dismissing the notice: there is no state, on any screen, in which
/// this widget is absent or in which that first line is not visible.
///
/// It is deliberately quiet rather than alarming. A warning the user learns to
/// skip past is worth nothing, and a red banner on every screen of a daily app
/// teaches exactly that.
class HpDisclaimer extends StatefulWidget {
  const HpDisclaimer({super.key}) : compact = false;

  /// The tighter type scale, for places where the content is already dense.
  ///
  /// Both forms are one line until they are opened; this only changes how loud
  /// that line is.
  const HpDisclaimer.compact({super.key}) : compact = true;

  final bool compact;

  /// The elaboration. Behind a tap, never removed.
  static const String fullText =
      'HealthPulse is a coach, not a doctor. It explains your results in plain '
      'language and suggests food, movement and sleep. It does not diagnose, and '
      'it never recommends a medicine or a dose. Anything unusual here is worth '
      'discussing with your doctor.';

  /// The line that is always on screen, in every state, on every screen.
  static const String compactText = 'A coach, not a doctor.';

  static const String expandLabel = 'What this means';
  static const String collapseLabel = 'Close';

  @override
  State<HpDisclaimer> createState() => _HpDisclaimerState();
}

class _HpDisclaimerState extends State<HpDisclaimer> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    final TextStyle lineStyle = (widget.compact ? HpType.micro : HpType.label)
        .copyWith(color: p.inkMuted, height: 1.5);

    return Semantics(
      container: true,
      // Read as one thing, and read the permanent sentence first, so a screen
      // reader never announces the control before the claim it qualifies.
      label: HpDisclaimer.compactText,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: p.surfaceSunk,
          border: Border(top: BorderSide(color: p.hairline)),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            // Opens and closes the elaboration. It cannot close the notice: the
            // line below is outside the animated part and has no branch that
            // omits it.
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                HpSpacing.gutter,
                widget.compact ? HpSpacing.md : HpSpacing.lg,
                HpSpacing.gutter,
                widget.compact ? HpSpacing.md : HpSpacing.lg,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: <Widget>[
                      Icon(Icons.shield_outlined, size: 18, color: p.inkMuted),
                      const SizedBox(width: HpSpacing.md),
                      Expanded(
                        child: Text(
                          HpDisclaimer.compactText,
                          style: lineStyle,
                        ),
                      ),
                      const SizedBox(width: HpSpacing.sm),
                      Text(
                        _open
                            ? HpDisclaimer.collapseLabel
                            : HpDisclaimer.expandLabel,
                        style: HpType.micro.copyWith(color: p.inkFaint),
                      ),
                      Icon(
                        _open
                            ? Icons.keyboard_arrow_down_rounded
                            : Icons.keyboard_arrow_up_rounded,
                        size: 18,
                        color: p.inkFaint,
                      ),
                    ],
                  ),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 160),
                    curve: Curves.easeOut,
                    alignment: Alignment.topCenter,
                    child: _open
                        ? Padding(
                            padding: const EdgeInsets.only(
                              top: HpSpacing.md,
                              left: 18 + HpSpacing.md,
                            ),
                            child: Text(
                              HpDisclaimer.fullText,
                              style: HpType.micro
                                  .copyWith(color: p.inkMuted, height: 1.5),
                            ),
                          )
                        : const SizedBox(width: double.infinity),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../../core/theme/hp_palette.dart';
import '../../core/theme/hp_spacing.dart';
import '../../core/theme/hp_typography.dart';
import '../../data/models/models.dart';

/// The three answers, drawn once and used in both places that ask the question.
///
/// It lives here rather than inside either screen because there are two doors
/// into the same store — the plan card asks about a meal that was just eaten,
/// the tastes screen asks about a food in the abstract — and the answers have to
/// be the same three words sending the same three numbers on both. Two copies of
/// this would drift the first time somebody reworded a button, and the wording
/// is what tells a person what will happen.
///
/// The plan screen depends on this file, not the other way round: the tastes
/// feature owns what an answer is, and the plan card borrows it.
class TasteChoiceRow extends StatelessWidget {
  const TasteChoiceRow({
    super.key,
    required this.keyPrefix,
    required this.selected,
    required this.busyStance,
    required this.onTaste,
  });

  /// What the chips' keys are scoped by — a plan item id on the plan screen, a
  /// food id on the tastes screen — so a test can name one chip on one row.
  final String keyPrefix;

  /// The answer that landed, or null while none has. Never what was tapped.
  final TasteStance? selected;

  /// The chip waiting on its call, or null.
  final TasteStance? busyStance;

  /// Null while the row is busy, which is how every chip disables itself at
  /// once. One question, one call: a second answer cannot be sent while the
  /// first is still open.
  final void Function(TasteStance stance)? onTaste;

  @override
  Widget build(BuildContext context) {
    final void Function(TasteStance stance)? tap = onTaste;

    // Wrap, not Row: "Did not like it" beside the other two does not fit on a
    // narrow phone, and three answers squeezed onto one line is how somebody
    // taps the wrong one.
    return Wrap(
      spacing: HpSpacing.sm,
      runSpacing: HpSpacing.sm,
      children: <Widget>[
        for (final TasteStance stance in TasteStance.values)
          _TasteChip(
            key: ValueKey<String>('taste-$keyPrefix-${stance.name}'),
            stance: stance,
            selected: selected == stance,
            busy: busyStance == stance,
            onPressed: tap == null ? null : () => tap(stance),
          ),
      ],
    );
  }
}

/// One answer. Filled when it is the one that landed, outlined otherwise.
///
/// The selected state is carried by a fill *and* a tick rather than by colour
/// alone — the same reason the chosen meal option uses a filled circle against
/// an empty one. It is at least 48dp tall, which is the minimum target this app
/// promises everywhere else.
class _TasteChip extends StatelessWidget {
  const _TasteChip({
    super.key,
    required this.stance,
    required this.selected,
    required this.busy,
    required this.onPressed,
  });

  final TasteStance stance;
  final bool selected;
  final bool busy;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    final Color background = selected ? p.pineSoft : p.surface;
    final Color edge = selected ? p.pine : p.hairline;
    final Color label = selected ? p.pineDeep : p.ink;

    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: background,
        borderRadius: HpRadii.pillRadius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: busy ? null : onPressed,
          child: Container(
            constraints: const BoxConstraints(minHeight: 48),
            padding: const EdgeInsets.symmetric(
              horizontal: HpSpacing.lg,
              vertical: HpSpacing.sm,
            ),
            decoration: BoxDecoration(
              borderRadius: HpRadii.pillRadius,
              border: Border.all(color: edge),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (busy) ...<Widget>[
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(p.pineDeep),
                    ),
                  ),
                  const SizedBox(width: HpSpacing.sm),
                ] else if (selected) ...<Widget>[
                  Icon(Icons.check_rounded, size: 16, color: p.pineDeep),
                  const SizedBox(width: HpSpacing.sm),
                ],
                Text(
                  stance.label,
                  style: HpType.label.copyWith(color: label),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

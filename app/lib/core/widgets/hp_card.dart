import 'package:flutter/material.dart';

import '../theme/hp_palette.dart';
import '../theme/hp_spacing.dart';

/// Not every block of content is a card.
///
/// A raised surface means "this is a thing you can act on" - a meal you can
/// swap, a report you can open. Rows that are only information stay on the
/// ground, separated by space and a hairline. Making everything a card is how a
/// screen loses its hierarchy.
enum HpCardTone {
  /// Something you can act on. Sits above the ground with a hairline edge.
  raised,

  /// Grouping only, no shadow.
  flat,

  /// A quiet tint for supporting context.
  tinted,
}

class HpCard extends StatelessWidget {
  const HpCard({
    super.key,
    required this.child,
    this.tone = HpCardTone.raised,
    this.padding = const EdgeInsets.all(HpSpacing.lg),
    this.onTap,
    this.semanticLabel,
  });

  final Widget child;
  final HpCardTone tone;
  final EdgeInsets padding;
  final VoidCallback? onTap;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;

    Color background = p.surface;
    Color edge = p.hairline;
    List<BoxShadow> shadow = p.isDark ? HpElevation.none : HpElevation.resting;

    if (tone == HpCardTone.flat) {
      background = p.surface;
      shadow = HpElevation.none;
    } else if (tone == HpCardTone.tinted) {
      background = p.isDark ? p.surfaceSunk : p.pineSoft;
      edge = p.isDark ? p.hairline : p.pineSoft;
      shadow = HpElevation.none;
    }

    final Widget body = Padding(padding: padding, child: child);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: HpRadii.cardRadius,
        border: Border.all(color: edge),
        boxShadow: shadow,
      ),
      child: onTap == null
          ? Semantics(label: semanticLabel, child: body)
          : Material(
              type: MaterialType.transparency,
              child: InkWell(
                onTap: onTap,
                borderRadius: HpRadii.cardRadius,
                child: Semantics(label: semanticLabel, child: body),
              ),
            ),
    );
  }
}

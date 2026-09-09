import 'package:flutter/material.dart';

import '../theme/hp_palette.dart';
import '../theme/hp_spacing.dart';
import '../theme/hp_typography.dart';
import 'hp_button.dart';

/// A section heading whose rule earns its place.
///
/// The hairline is not decoration: it runs to whatever the section wants to say
/// about itself - how many items, when it was last updated - so the line carries
/// information instead of drawing a box. Headings are sentence case in the serif;
/// there is no tracked-out capital label above them, which is the commonest tell
/// of a templated screen.
class HpSectionHeader extends StatelessWidget {
  const HpSectionHeader({
    super.key,
    required this.title,
    this.note,
    this.actionLabel,
    this.onAction,
  });

  final String title;

  /// A short fact about the section: "4 values", "updated yesterday".
  final String? note;

  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    return Padding(
      padding: const EdgeInsets.only(bottom: HpSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          // Every child that can grow is flexible, and the weights keep the title
          // roomiest. The note used to be a plain Text with no flex, so on a
          // narrow phone it took its full intrinsic width, left the title and the
          // rule fighting over what remained, and the Row overflowed -- caught by
          // a real RenderFlex overflow at 360dp, which is an ordinary phone width.
          Flexible(
            flex: 5,
            child: Semantics(
              header: true,
              child: Text(
                title,
                style: HpType.headline.copyWith(color: p.ink),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          const SizedBox(width: HpSpacing.md),
          // The rule is decoration: it gives up its width first.
          Expanded(
            child: Container(height: 1, color: p.hairline),
          ),
          if (note != null) ...<Widget>[
            const SizedBox(width: HpSpacing.md),
            Flexible(
              flex: 4,
              child: Text(
                note!,
                style: HpType.micro.copyWith(color: p.inkFaint),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.end,
              ),
            ),
          ],
          if (actionLabel != null) ...<Widget>[
            const SizedBox(width: HpSpacing.xs),
            HpTextAction(label: actionLabel!, onPressed: onAction),
          ],
        ],
      ),
    );
  }
}

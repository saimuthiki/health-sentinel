import 'package:flutter/material.dart';

import '../theme/hp_severity.dart';
import '../theme/hp_spacing.dart';
import '../theme/hp_typography.dart';

/// The severity marker used beside every lab value.
///
/// Colour is never the only signal: each level has its own icon shape and its own
/// word, so the chip still works in greyscale, for a colour-blind reader, and for
/// a screen reader. The words avoid diagnosis - a value is "outside the usual
/// range", never "abnormal" and never the name of a condition.
class HpStatusChip extends StatelessWidget {
  const HpStatusChip({
    super.key,
    required this.severity,
    this.label,
    this.dense = false,
  });

  final HpSeverity severity;

  /// Overrides the default word for this level. Keep it plain and non-clinical.
  final String? label;

  final bool dense;

  @override
  Widget build(BuildContext context) {
    final HpSeverityStyle style = HpSeverityStyle.of(context, severity);
    final String text = label ?? style.label;

    return Semantics(
      label: 'Status: $text',
      excludeSemantics: true,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: dense ? HpSpacing.sm : HpSpacing.md,
          vertical: dense ? HpSpacing.xs : HpSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: style.background,
          borderRadius: HpRadii.pillRadius,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(style.icon, size: dense ? 14 : 16, color: style.foreground),
            SizedBox(width: dense ? HpSpacing.xs : HpSpacing.sm),
            Flexible(
              child: Text(
                text,
                style: (dense ? HpType.micro : HpType.label)
                    .copyWith(color: style.foreground),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

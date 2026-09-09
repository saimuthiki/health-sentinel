import 'package:flutter/material.dart';

import '../theme/hp_palette.dart';
import '../theme/hp_spacing.dart';
import '../theme/hp_typography.dart';

/// How much weight a button carries. There is one primary action per screen.
enum HpButtonTone {
  /// The single main action.
  primary,

  /// An alternative that is still a real choice.
  secondary,

  /// Low-commitment: "not now", "skip".
  quiet,
}

/// The app's button.
///
/// Every instance is at least 52dp tall, which clears Android's 48dp minimum
/// target with room for a fingertip on a phone held one-handed at 7am. The label
/// is always a verb phrase naming what happens, and it keeps that wording for the
/// rest of the flow: the button that says "Save profile" produces "Profile saved".
class HpButton extends StatelessWidget {
  const HpButton({
    super.key,
    required this.label,
    this.onPressed,
    this.tone = HpButtonTone.primary,
    this.icon,
    this.busy = false,
    this.expand = true,
  });

  final String label;
  final VoidCallback? onPressed;
  final HpButtonTone tone;
  final IconData? icon;

  /// Shows a spinner in place of the icon and blocks taps, without changing the
  /// button's height, so the layout does not jump.
  final bool busy;

  final bool expand;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    final bool enabled = onPressed != null && !busy;

    Color background = p.pine;
    Color foreground = p.onPine;
    Color? border;

    if (tone == HpButtonTone.secondary) {
      background = p.surface;
      foreground = p.pine;
      border = p.outline;
    } else if (tone == HpButtonTone.quiet) {
      background = Colors.transparent;
      foreground = p.inkMuted;
    }

    if (!enabled) {
      background =
          tone == HpButtonTone.quiet ? Colors.transparent : p.surfaceSunk;
      foreground = p.inkMuted;
      border = tone == HpButtonTone.secondary ? p.hairline : null;
    }

    final bool hasLeading = busy || icon != null;
    final Widget leading = busy
        ? SizedBox(
            width: 17,
            height: 17,
            child: CircularProgressIndicator(strokeWidth: 2, color: foreground),
          )
        : Icon(icon, size: 19, color: foreground);

    return Material(
      color: background,
      borderRadius: HpRadii.fieldRadius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: enabled ? onPressed : null,
        borderRadius: HpRadii.fieldRadius,
        child: Container(
          constraints: const BoxConstraints(minHeight: 52),
          padding: const EdgeInsets.symmetric(
            horizontal: HpSpacing.xl,
            vertical: HpSpacing.md,
          ),
          decoration: border == null
              ? null
              : BoxDecoration(
                  borderRadius: HpRadii.fieldRadius,
                  border: Border.all(color: border),
                ),
          child: Row(
            mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              if (hasLeading) leading,
              if (hasLeading) const SizedBox(width: HpSpacing.md),
              Flexible(
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  style: HpType.button.copyWith(color: foreground),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A text-weight action, padded so it still clears a 48dp touch target.
class HpTextAction extends StatelessWidget {
  const HpTextAction({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    final Color tint = onPressed == null ? p.inkFaint : p.pine;
    return InkWell(
      onTap: onPressed,
      borderRadius: HpRadii.fieldRadius,
      child: Container(
        constraints: const BoxConstraints(minHeight: HpSpacing.minTapTarget),
        padding: const EdgeInsets.symmetric(horizontal: HpSpacing.sm),
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Flexible(
              child: Text(
                label,
                style: HpType.label
                    .copyWith(color: tint, fontWeight: FontWeight.w600),
              ),
            ),
            if (icon != null) ...<Widget>[
              const SizedBox(width: HpSpacing.xs),
              Icon(icon, size: 17, color: tint),
            ],
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../theme/hp_palette.dart';
import '../theme/hp_spacing.dart';
import '../theme/hp_typography.dart';
import 'hp_button.dart';

/// An empty screen is an invitation, not an apology.
///
/// [title] says what is not here yet, [body] says what putting something here
/// will get the person, and the action names that first step in the same words
/// the next screen will use.
class HpEmptyState extends StatelessWidget {
  const HpEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String body;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: HpSpacing.gutter,
        vertical: HpSpacing.section,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 52,
            height: 52,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: p.pineSoft,
              borderRadius: HpRadii.pillRadius,
            ),
            child: Icon(icon, size: 24, color: p.pineDeep),
          ),
          const SizedBox(height: HpSpacing.lg),
          Text(title, style: HpType.headline.copyWith(color: p.ink)),
          const SizedBox(height: HpSpacing.sm),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Text(body, style: HpType.body.copyWith(color: p.inkMuted)),
          ),
          if (actionLabel != null) ...<Widget>[
            const SizedBox(height: HpSpacing.xl),
            HpButton(
              label: actionLabel!,
              onPressed: onAction,
              expand: false,
            ),
          ],
        ],
      ),
    );
  }
}

/// Waiting, said honestly.
///
/// The backend sleeps on the free hosting tier and can take the better part of a
/// minute to wake (docs/02-architecture.md section 4). Pretending that is instant
/// makes the app feel broken; naming it makes the app feel truthful.
class HpLoadingState extends StatelessWidget {
  const HpLoadingState({
    super.key,
    this.message = 'Getting your day ready',
    this.detail,
  });

  final String message;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: HpSpacing.gutter,
        vertical: HpSpacing.section,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2.2, color: p.pine),
          ),
          const SizedBox(width: HpSpacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(message, style: HpType.bodyStrong.copyWith(color: p.ink)),
                if (detail != null) ...<Widget>[
                  const SizedBox(height: HpSpacing.xs),
                  Text(
                    detail!,
                    style: HpType.label.copyWith(color: p.inkFaint),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A placeholder block used while real content loads. No shimmer: a health app
/// that flickers reads as unstable.
class HpSkeletonLine extends StatelessWidget {
  const HpSkeletonLine({super.key, this.width, this.height = 14});

  final double? width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: context.hp.surfaceSunk,
        borderRadius: HpRadii.pillRadius,
      ),
    );
  }
}

/// Something went wrong, said in the interface's voice: what happened, and the
/// one thing that fixes it. No apology, no blame, no stack trace.
class HpErrorState extends StatelessWidget {
  const HpErrorState({
    super.key,
    required this.title,
    required this.body,
    this.onRetry,
    this.retryLabel = 'Try again',
  });

  final String title;
  final String body;
  final VoidCallback? onRetry;
  final String retryLabel;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: HpSpacing.gutter,
        vertical: HpSpacing.xxl,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(Icons.cloud_off_rounded, size: 20, color: p.inkMuted),
              const SizedBox(width: HpSpacing.md),
              Expanded(
                child: Text(
                  title,
                  style: HpType.bodyStrong.copyWith(color: p.ink),
                ),
              ),
            ],
          ),
          const SizedBox(height: HpSpacing.sm),
          Text(body, style: HpType.body.copyWith(color: p.inkMuted)),
          if (onRetry != null) ...<Widget>[
            const SizedBox(height: HpSpacing.lg),
            HpButton(
              label: retryLabel,
              onPressed: onRetry,
              tone: HpButtonTone.secondary,
              expand: false,
            ),
          ],
        ],
      ),
    );
  }
}

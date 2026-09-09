import 'package:flutter/material.dart';

import '../../data/cache/cache_freshness.dart';
import '../theme/hp_palette.dart';
import '../theme/hp_spacing.dart';
import '../theme/hp_typography.dart';

/// The line that appears over anything read off this phone rather than fetched.
///
/// It exists because of one product rule: **cached is never presented as
/// current.** An app that quietly shows yesterday's plan the same way it shows
/// today's is not being helpful, it is being misleading — and the person it
/// misleads is looking at their own health.
///
/// So it says both halves out loud: where this came from, and how old it is.
/// It is quiet rather than alarming, because being offline is ordinary; what
/// would not be ordinary is not being told.
class HpStaleNotice extends StatelessWidget {
  const HpStaleNotice({
    super.key,
    required this.storedAt,
    this.detail,
    this.now,
  });

  /// When the backend answered — not when this was written or read.
  final DateTime storedAt;

  /// What is missing as a result. On Today that is the honest and important
  /// one: nothing new was checked, including anything that would need a doctor.
  final String? detail;

  /// Test seam.
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    final String label = stalenessLabel(storedAt, now: now);
    final String? note = detail;

    return Semantics(
      container: true,
      label: note == null ? label : '$label. $note',
      excludeSemantics: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
          horizontal: HpSpacing.lg,
          vertical: HpSpacing.md,
        ),
        decoration: BoxDecoration(
          color: p.surfaceSunk,
          borderRadius: HpRadii.cardRadius,
          border: Border.all(color: p.hairline),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(Icons.cloud_off_rounded, size: 18, color: p.inkFaint),
            const SizedBox(width: HpSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    label,
                    style: HpType.label.copyWith(color: p.inkMuted),
                  ),
                  if (note != null) ...<Widget>[
                    const SizedBox(height: HpSpacing.xs),
                    Text(
                      note,
                      style: HpType.micro.copyWith(color: p.inkFaint),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

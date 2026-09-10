import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/hp_palette.dart';
import '../../core/theme/hp_spacing.dart';
import '../../core/theme/hp_typography.dart';
import '../../data/api/api_status.dart';
import '../../data/providers.dart';

/// "Nothing is broken, the free host is getting out of bed."
///
/// The health engine runs on Render's free tier, which stops the instance after
/// about a quarter of an hour of quiet and starts it again on the next request.
/// That start takes the better part of a minute. Today has said so since the
/// beginning, but Today is not where a new person meets it: the first request
/// any account ever makes is the consent POST, and the second is the profile
/// save. Both of those used to spin in silence for fifty seconds on the two
/// screens where a silent spinner does the most damage, because there is no
/// content behind it to suggest the app is alive.
///
/// So the notice is a widget rather than a paragraph copied into three screens.
/// It watches [apiPhaseProvider] and draws nothing at all unless the client is
/// genuinely mid-wake-up - the phase is set by a real probe in flight, not
/// guessed - which is what keeps it honest on the days the backend is already
/// awake and answers in a second.
class ApiWakingNotice extends ConsumerWidget {
  const ApiWakingNotice({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ApiPhase phase = ref.watch(apiPhaseProvider);
    if (phase != ApiPhase.waking) {
      return const SizedBox.shrink();
    }

    final HpPalette p = context.hp;
    final String? detail = phase.waitingDetail;

    return Semantics(
      liveRegion: true,
      container: true,
      child: Padding(
        padding: const EdgeInsets.only(bottom: HpSpacing.md),
        child: Container(
          padding: const EdgeInsets.all(HpSpacing.md),
          decoration: BoxDecoration(
            color: p.pineSoft,
            borderRadius: HpRadii.fieldRadius,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: p.pineDeep,
                ),
              ),
              const SizedBox(width: HpSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      phase.waitingMessage,
                      style: HpType.bodyStrong.copyWith(color: p.ink),
                    ),
                    if (detail != null) ...<Widget>[
                      const SizedBox(height: HpSpacing.xs),
                      Text(
                        detail,
                        style: HpType.label.copyWith(color: p.inkMuted),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

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
/// misleads is looking at their own health. On Today the omission is a real
/// one: `HttpHealthRepository` strips escalations out of anything it caches, so
/// a saved day genuinely cannot carry a finding that needs a doctor. Something
/// has to say that.
///
/// The shape is `HpDisclaimer`'s, and for the same reason. The fact that must
/// never go missing is one quiet line that is always on screen; the paragraph
/// that explains it — including the sentence about a doctor — sits one tap
/// behind it. A four-line warning at the top of the screen someone opens every
/// morning is read once and skipped for ever after, and the clause that
/// frightens is the one it gets skipped for. Collapsed is not dismissed: there
/// is no state of this widget in which the first line is absent.
///
/// It also says nothing about *why* the fetch failed, and that is deliberate.
/// The screen is told only *when* the saved copy was fetched
/// (`CacheAware.servedFromCacheAt` returns a `DateTime` and nothing else), and
/// even the repository below it cannot really tell a phone with no signal from
/// a backend that was asleep: `ApiClient` labels every socket error it does not
/// recognise `ApiFailureKind.offline`, and seven different failure kinds all end
/// up serving the cache. So the copy states what is known — this was saved, at
/// this time — and, where the cause matters, says plainly that we cannot tell
/// which it was. Telling somebody they are offline while their phone is plainly
/// online teaches them to disbelieve the rest of the screen too.
class HpStaleNotice extends StatefulWidget {
  const HpStaleNotice({
    super.key,
    required this.storedAt,
    this.checking = false,
    this.now,
  });

  /// When the backend answered — not when this was written or read.
  final DateTime storedAt;

  /// True while a fresh attempt is in flight, so the notice can show that it is
  /// working on it rather than sitting there.
  final bool checking;

  /// Test seam.
  final DateTime? now;

  /// The elaboration. Behind a tap, never removed.
  ///
  /// This is where the important half lives: nothing new has been checked, and
  /// that includes anything that would need a doctor.
  static const String fullText =
      'This is the day HealthPulse saved on your phone. The app could not '
      'reach the health engine when it last tried, and from here it cannot '
      'tell whether that is your connection or our own server waking up — so '
      'it does not guess. Nothing new has been checked since the time above, '
      'including anything that would need a doctor. The app keeps trying by '
      'itself and this line goes as soon as it gets through. You can also pull '
      'the screen down to try straight away.';

  static const String expandLabel = 'What this means';
  static const String collapseLabel = 'Close';

  /// Shown in place of [expandLabel] while an attempt is in flight.
  static const String checkingLabel = 'Checking';

  @override
  State<HpStaleNotice> createState() => _HpStaleNoticeState();
}

class _HpStaleNoticeState extends State<HpStaleNotice> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    // Both halves in one line, from the one place in the app that writes it:
    // where this came from, and how old it is.
    final String label = stalenessLabel(widget.storedAt, now: widget.now);
    final String trailing = widget.checking
        ? HpStaleNotice.checkingLabel
        : (_open ? HpStaleNotice.collapseLabel : HpStaleNotice.expandLabel);

    return Semantics(
      container: true,
      // Read as one thing, and read the permanent sentence first, so a screen
      // reader never announces the control before the claim it qualifies.
      label: label,
      child: Container(
        width: double.infinity,
        constraints: const BoxConstraints(
          minHeight: HpSpacing.minTapTarget,
        ),
        decoration: BoxDecoration(
          color: p.surfaceSunk,
          borderRadius: HpRadii.cardRadius,
          border: Border.all(color: p.hairline),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: HpRadii.cardRadius,
            // Opens and closes the elaboration. It cannot close the notice: the
            // line above it is outside the animated part and has no branch that
            // omits it.
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: HpSpacing.lg,
                vertical: HpSpacing.md,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: <Widget>[
                      // A clock rather than a struck-through cloud: the thing we
                      // know is that this copy is from earlier, not that the
                      // phone has no signal.
                      Icon(Icons.history_rounded, size: 18, color: p.inkMuted),
                      const SizedBox(width: HpSpacing.md),
                      Expanded(
                        child: Text(
                          label,
                          style: HpType.label
                              .copyWith(color: p.inkMuted, height: 1.4),
                        ),
                      ),
                      const SizedBox(width: HpSpacing.sm),
                      Text(
                        trailing,
                        style: HpType.micro.copyWith(color: p.inkFaint),
                      ),
                      Icon(
                        _open
                            ? Icons.keyboard_arrow_up_rounded
                            : Icons.keyboard_arrow_down_rounded,
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
                              HpStaleNotice.fullText,
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

/// The other half of the same story: the saved copy has just been replaced by a
/// fresh one.
///
/// A notice that disappears without a word leaves the person wondering whether
/// it worked or whether they missed something. This says so, once and quietly,
/// and the screen that shows it takes it away again after a few seconds.
///
/// It claims nothing about the network — only what actually happened here.
class HpFreshNotice extends StatelessWidget {
  const HpFreshNotice({super.key});

  static const String text = 'Up to date — fetched just now.';

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;

    return Semantics(
      container: true,
      label: text,
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
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Icon(
              Icons.check_circle_outline_rounded,
              size: 18,
              color: p.calmInk,
            ),
            const SizedBox(width: HpSpacing.md),
            Expanded(
              child: Text(
                text,
                style: HpType.label.copyWith(color: p.inkMuted, height: 1.4),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

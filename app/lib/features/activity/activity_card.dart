import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format/hp_format.dart';
import '../../core/theme/hp_palette.dart';
import '../../core/theme/hp_spacing.dart';
import '../../core/theme/hp_typography.dart';
import '../../core/widgets/widgets.dart';
import '../../data/providers.dart';
import '../common/failure_copy.dart';
import 'activity_service.dart';
import 'log_activity_sheet.dart';

/// Exercise on the Today screen: what was done, and what it came to.
///
/// This replaces a bar that said "Moving: 0 of 43 minutes". The owner's
/// objection to it was that "movement" is not a thing anybody does, and that a
/// bar with no way to fill it is not something you can act on:
///
/// > "you can let the user know all the types of physical exercises - instead of
/// > this 'movement target' kind of thing ... How much time did he spend? You can
/// > ask that and include that, like this much of calories you had burnt till
/// > date."
///
/// So the card does four things the meter could not: it names activities, it
/// takes minutes, it shows energy for today and since he started, and it counts
/// the days he has kept it up.
///
/// **What it is careful not to claim.** The energy figure is an estimate worked
/// out from a published population average and the weight on his profile, and
/// every place it appears says so in the same breath. The streak counts *days
/// with something logged* and the words on screen say exactly that. Nothing here
/// connects a number to weight, to a lab value, or to any health outcome - a card
/// that said "you burned 300 kcal, so you are losing weight" would be the exact
/// failure this app exists not to commit.
///
/// **Where the numbers come from.** The minutes bar is drawn from the briefing
/// Today already loads, so it is right offline and right in sample builds. The
/// energy and the streak come from `GET /v1/activity/summary`, which is the only
/// thing that can work them out, because the arithmetic needs a body weight and a
/// MET table and neither belongs on the phone.
class ActivityCard extends ConsumerStatefulWidget {
  const ActivityCard({
    super.key,
    required this.minutesToday,
    required this.targetMinutes,
  });

  /// Moderate-equivalent minutes logged today, from the Today briefing.
  final int minutesToday;

  /// The daily slice of the WHO weekly target, from the same place.
  final int targetMinutes;

  @override
  ConsumerState<ActivityCard> createState() => _ActivityCardState();
}

class _ActivityCardState extends ConsumerState<ActivityCard> {
  /// True while a session is being written. One flag, cleared in a `finally`:
  /// two taps on "Add exercise" while the first is in flight would log the
  /// session twice, and a spinner that cannot stop is indistinguishable from a
  /// dead app.
  bool _saving = false;

  Future<void> _addExercise() async {
    if (_saving) {
      return;
    }
    final ActivityCatalogue? catalogue =
        ref.read(activityTypesProvider).value;
    if (catalogue == null) {
      return;
    }
    final ActivityEntry? entry =
        await showLogActivitySheet(context, catalogue: catalogue);
    if (entry == null || !mounted) {
      return;
    }
    await _log(entry);
  }

  Future<void> _log(ActivityEntry entry) async {
    if (_saving) {
      return;
    }
    final ActivityService? service = ref.read(activityServiceProvider);
    if (service == null) {
      return;
    }
    // Taken before the await. After it this widget may be gone, and reaching
    // through a dead context for the messenger is how a failure ends up thrown
    // instead of shown.
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    setState(() => _saving = true);
    try {
      final LoggedActivity logged = await service.log(
        activity: entry.activityKey,
        minutes: entry.minutes,
        intensity: entry.intensity,
      );
      if (mounted) {
        // Today owns the minutes and the summary owns the energy. Refetch both
        // rather than holding a second copy of either here.
        ref.invalidate(todayProvider);
        ref.invalidate(activitySummaryProvider);
      }
      messenger.showSnackBar(
        SnackBar(content: Text(confirmationFor(logged))),
      );
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            explainFailure(
              error,
              fallback: 'That could not be saved just now. Try again in a '
                  'moment.',
            ),
          ),
        ),
      );
    } finally {
      // In the `finally`, never after the `try`: an exception would otherwise
      // skip the line that puts the button back.
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    final bool hasBackend = ref.watch(activityServiceProvider) != null;
    final AsyncValue<ActivityCatalogue?> types =
        ref.watch(activityTypesProvider);
    final ActivitySummary? summary = ref.watch(activitySummaryProvider).value;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        HpMeter(
          label: 'Exercise today',
          value: widget.minutesToday.toDouble(),
          target: widget.targetMinutes.toDouble(),
          unit: 'minutes',
          footnote: 'Moderate to vigorous minutes, which is what the weekly '
              'target counts. A vigorous minute counts as two.',
        ),
        if (summary != null) ...<Widget>[
          const SizedBox(height: HpSpacing.lg),
          _EnergySoFar(summary: summary),
        ],
        const SizedBox(height: HpSpacing.lg),
        if (!hasBackend)
          Text(
            activityNeedsBackendMessage,
            style: HpType.micro.copyWith(color: p.inkFaint),
          )
        else if (types.hasError)
          _CouldNotLoad(
            error: types.error,
            onRetry: () => ref.invalidate(activityTypesProvider),
          )
        else
          HpButton(
            key: const ValueKey<String>('activity-add-button'),
            label: 'Add exercise',
            icon: Icons.directions_run_rounded,
            tone: HpButtonTone.secondary,
            busy: _saving,
            onPressed:
                types.value == null || _saving ? null : _addExercise,
          ),
      ],
    );
  }
}

/// What to say after one session lands.
///
/// Public so the wording is testable on its own, and so there is one place that
/// decides how an estimate is spoken about. The word "estimate" is never more
/// than a few words from the number.
String confirmationFor(LoggedActivity logged) {
  final String what = '${logged.label}, ${logged.minutes} minutes.';
  final int? kcal = logged.energy.kcal;
  if (kcal == null) {
    final String why = logged.energy.unavailableReason ?? '';
    return why.isEmpty
        ? '$what Recorded.'
        : '$what Recorded, without an energy figure. $why';
  }
  return '$what About ${formatKcal(kcal)} kcal - an estimate, not a measurement.';
}

/// "12,400", so a five-figure total can be read at a glance.
String formatKcal(int kcal) {
  final String digits = kcal.abs().toString();
  final StringBuffer out = StringBuffer();
  for (int i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) {
      out.write(',');
    }
    out.write(digits[i]);
  }
  return out.toString();
}

/// Today's energy and the running total, or the reason there is not one.
class _EnergySoFar extends StatelessWidget {
  const _EnergySoFar({required this.summary});

  final ActivitySummary summary;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    final ActivityEnergy today = summary.today.energy;
    final ActivityEnergy total = summary.total.energy;

    if (!total.isKnown && !today.isKnown) {
      return _NoEnergyYet(
        reason: today.unavailableReason ?? total.unavailableReason ?? '',
        offerProfile: summary.weightKg == null,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: _Figure(
                value: _kcalLabel(summary.today),
                caption: 'today',
              ),
            ),
            const SizedBox(width: HpSpacing.md),
            Expanded(
              child: _Figure(
                value: _kcalLabel(summary.total),
                caption: _sinceLabel(summary.total.start),
              ),
            ),
          ],
        ),
        if (summary.loggedDaysInARow >= 2) ...<Widget>[
          const SizedBox(height: HpSpacing.sm),
          Text(
            // A count of logging. It says so, because "3 day streak" beside a
            // health app quietly reads as a claim about health.
            '${summary.loggedDaysInARow} days in a row with something logged.',
            style: HpType.label.copyWith(color: p.pineDeep),
          ),
        ],
        const SizedBox(height: HpSpacing.sm),
        Text(
          _basisLine(summary),
          style: HpType.micro.copyWith(color: p.inkFaint),
        ),
        if (total.sessionsWithoutEnergy > 0) ...<Widget>[
          const SizedBox(height: HpSpacing.xs),
          Text(
            total.sessionsWithoutEnergy == 1
                ? 'One session has no energy figure, because nothing recorded '
                    'what it was. Its minutes still count.'
                : '${total.sessionsWithoutEnergy} sessions have no energy '
                    'figure, because nothing recorded what they were. Their '
                    'minutes still count.',
            style: HpType.micro.copyWith(color: p.inkFaint),
          ),
        ],
      ],
    );
  }

  /// One window's energy, in words.
  ///
  /// Three different answers, kept apart on purpose. Nothing logged is
  /// "Nothing yet" rather than "About 0 kcal", which would read as a claim about
  /// a day that has not been recorded. A window we could not cost is "Not worked
  /// out" rather than a zero. And a total the backend could not see all of is
  /// "At least", never a flat figure that is quietly short - see `GAPS.md` G19.
  static String _kcalLabel(ActivityTotals totals) {
    if (totals.isEmpty) {
      return 'Nothing yet';
    }
    final int? kcal = totals.energy.kcal;
    if (kcal == null) {
      return 'Not worked out';
    }
    final String lead = totals.truncated ? 'At least' : 'About';
    return '$lead ${formatKcal(kcal)} kcal';
  }

  static String _sinceLabel(DateTime? start) {
    if (start == null) {
      return 'so far';
    }
    return 'since ${HpFormat.dayShort(start)}';
  }

  /// The sentence that stops the number reading as a measurement.
  ///
  /// It names the weight it used, because a figure worked out from a stale
  /// weight is wrong in a way nobody can see, and naming it is the only way he
  /// finds out.
  static String _basisLine(ActivitySummary summary) {
    final double? weight = summary.weightKg;
    final String from = weight == null
        ? 'your weight'
        : 'your weight of ${HpFormat.number(weight)} kg';
    return 'An estimate, not a measurement: worked out from the minutes you '
        'entered, $from, and a published average for each activity. It says '
        'nothing about your weight or your health.';
  }
}

/// One number with a word under it.
class _Figure extends StatelessWidget {
  const _Figure({required this.value, required this.caption});

  final String value;
  final String caption;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          value,
          style: HpType.figureSmall.copyWith(color: p.ink, fontSize: 16),
        ),
        const SizedBox(height: HpSpacing.xxs),
        Text(caption, style: HpType.micro.copyWith(color: p.inkFaint)),
      ],
    );
  }
}

/// No energy figure, and why. Never a zero standing in for "we cannot say".
class _NoEnergyYet extends StatelessWidget {
  const _NoEnergyYet({required this.reason, required this.offerProfile});

  final String reason;

  /// True when the missing input is body weight, which he can fix himself.
  final bool offerProfile;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'Energy burnt is not shown yet',
          style: HpType.bodyStrong.copyWith(color: p.ink),
        ),
        const SizedBox(height: HpSpacing.xs),
        Text(reason, style: HpType.body.copyWith(color: p.inkMuted)),
        if (offerProfile)
          HpTextAction(
            label: 'Add your weight',
            icon: Icons.arrow_forward_rounded,
            onPressed: () => GoRouter.of(context).go('/more/profile'),
          ),
      ],
    );
  }
}

/// The list would not load, so there is nothing to pick from yet.
class _CouldNotLoad extends StatelessWidget {
  const _CouldNotLoad({required this.error, required this.onRetry});

  final Object? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          explainFailure(
            error,
            fallback: 'The list of activities could not be loaded.',
          ),
          style: HpType.micro.copyWith(color: p.inkMuted),
        ),
        HpTextAction(label: 'Try again', onPressed: onRetry),
      ],
    );
  }
}

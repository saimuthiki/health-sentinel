import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format/hp_format.dart';
import '../../core/theme/hp_palette.dart';
import '../../core/theme/hp_severity.dart';
import '../../core/theme/hp_spacing.dart';
import '../../core/theme/hp_typography.dart';
import '../../core/widgets/widgets.dart';
import '../../data/api/api_status.dart';
import '../../data/models/models.dart';
import '../../data/providers.dart';
import '../../data/repository/health_repository.dart';
import '../common/consent_routing.dart';
import '../common/failure_copy.dart';
import '../common/severity_ui.dart';
import 'day_routine.dart';
import 'hydration_card.dart';
import 'scannable_note.dart';

/// The screen people open every morning.
///
/// It is built as the day itself - a single ribbon of time from waking to
/// sleeping, with the current moment marked - rather than a grid of statistics.
/// The product is the loop, and the loop happens at particular hours, so the
/// hours are the structure. Everything else on the screen stays deliberately
/// quiet so that the ribbon, and any escalation above it, are what the eye finds.
///
/// The ribbon is a *routine*, not a feed of plan rows: waking, movement,
/// breakfast, the day's meals with water between them, and winding down. What
/// belongs at each hour is worked out in `day_routine.dart`; this file is only
/// the drawing of it.
class TodayScreen extends ConsumerWidget {
  const TodayScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<TodayBriefing> today = ref.watch(todayProvider);
    final ApiPhase phase = ref.watch(apiPhaseProvider);

    // The moment reminders start making sense: there is a day on screen with
    // times on it. This is where the notification permission is asked for, not
    // on first launch, when the answer would only ever be "not now".
    ref.listen<AsyncValue<TodayBriefing>>(
      todayProvider,
      (AsyncValue<TodayBriefing>? previous, AsyncValue<TodayBriefing> next) {
        final TodayBriefing? briefing = next.value;
        if (briefing != null && briefing.meals.isNotEmpty) {
          ref.read(scheduledRemindersProvider);
        }
      },
    );

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: <Widget>[
            Expanded(
              child: today.when(
                // The free hosting tier stops the backend when nobody is using
                // it and the first request of the day wakes it, which takes the
                // better part of a minute. Saying so is the difference between
                // "slow this morning" and "broken".
                loading: () => HpLoadingState(
                  message: phase.waitingMessage,
                  detail: phase.waitingDetail ??
                      'This can take a moment on the first open.',
                ),
                // The sentence comes from the error mapper, so a refused
                // consent or an expired sign-in says so instead of every
                // failure reading as "no signal". It is still our copy: no
                // server string reaches this screen.
                error: (Object error, StackTrace stack) {
                  // A missing consent is not a failure to retry, it is a step
                  // that was never finished, so the action is the consent
                  // screen rather than "try again" - which would fail again,
                  // for ever, with no way out of the tab.
                  final String? consentRoute = consentRouteFor(
                    error,
                    consentAlreadyRecorded: false,
                  );
                  if (consentRoute != null) {
                    return HpErrorState(
                      title: 'One step is still open',
                      body: explainFailure(
                        error,
                        fallback: 'We still need your agreement to the consent '
                            'notice before anything about your health is '
                            'looked at.',
                      ),
                      retryLabel: 'Read it and agree',
                      onRetry: () => GoRouter.of(context).go(consentRoute),
                    );
                  }
                  return HpErrorState(
                    title: 'Today could not be loaded',
                    body: explainFailure(
                      error,
                      fallback: 'The app could not reach the health engine. '
                          'Your data is safe.',
                    ),
                    onRetry: () => ref.invalidate(todayProvider),
                  );
                },
                data: (TodayBriefing briefing) =>
                    _TodayBody(briefing: briefing),
              ),
            ),
            // Today interprets health data, so the disclaimer is on screen
            // rather than buried at the bottom of a scroll.
            const HpDisclaimer.compact(),
          ],
        ),
      ),
    );
  }
}

class _TodayBody extends ConsumerWidget {
  const _TodayBody({required this.briefing});

  final TodayBriefing briefing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final HpPalette p = context.hp;
    final DateTime now = DateTime.now();
    final HealthRepository repository = ref.watch(healthRepositoryProvider);
    final DateTime? cachedAt = _servedFromCacheAt(repository);

    // Meals, not plan rows. Four things to choose between at lunch is one
    // lunch, and the heading has to count the same way the ribbon does or the
    // screen contradicts itself in the first two lines.
    final int mealCount = groupMealsBySlot(briefing).length;

    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(todayProvider),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(
          HpSpacing.gutter,
          HpSpacing.xl,
          HpSpacing.gutter,
          HpSpacing.section,
        ),
        children: <Widget>[
          Text(
            '${HpFormat.greeting(now)}, ${briefing.displayName.split(' ').first}',
            style: HpType.display.copyWith(color: p.ink),
          ),
          const SizedBox(height: HpSpacing.xs),
          Text(
            HpFormat.dayFull(briefing.date),
            style: HpType.label.copyWith(color: p.inkFaint),
          ),
          const SizedBox(height: HpSpacing.xxl),

          // An urgent finding sits above everything, including the day itself,
          // and there is no way to put it away.
          for (final EscalationNotice notice in briefing.escalations) ...<Widget>[
            HpEscalationCard(
              title: notice.title,
              body: notice.body,
              steps: notice.steps,
              footnote: notice.sourceCitation,
              onFindCare: () => _showCareSheet(context),
            ),
            const SizedBox(height: HpSpacing.xxl),
          ],

          // Below the escalations, never above them: if this day came off the
          // phone rather than off the network, say so and say what is missing
          // as a result. Nothing cached is ever shown as though it were current.
          if (cachedAt != null) ...<Widget>[
            HpStaleNotice(
              storedAt: cachedAt,
              detail: 'You are offline, so nothing new was checked \u2014 '
                  'including anything that would need a doctor.',
            ),
            const SizedBox(height: HpSpacing.xxl),
          ],

          HpSectionHeader(
            title: 'Your day',
            note: mealCount == 1 ? '1 meal planned' : '$mealCount meals planned',
          ),
          HpDayTimeline(entries: _timelineFor(context, briefing, now)),
          const SizedBox(height: HpSpacing.section),

          HpCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                HydrationControls(
                  loggedMl: briefing.hydrationMl,
                  targetMl: briefing.hydrationTargetMl,
                ),
                const SizedBox(height: HpSpacing.lg),
                Container(height: 1, color: p.hairline),
                const SizedBox(height: HpSpacing.lg),
                HpMeter(
                  label: 'Moving',
                  value: briefing.movementMinutes.toDouble(),
                  target: briefing.movementTargetMinutes.toDouble(),
                  unit: 'minutes',
                ),
              ],
            ),
          ),
          const SizedBox(height: HpSpacing.section),

          HpSectionHeader(
            title: 'Worth knowing',
            note: briefing.lastReportHeadline == null
                ? null
                : 'from your last report',
          ),
          for (final FocusNote note in briefing.focus) ...<Widget>[
            _FocusCard(note: note),
            const SizedBox(height: HpSpacing.md),
          ],
          const SizedBox(height: HpSpacing.xl),

          if (briefing.planRationale != null)
            HpCard(
              tone: HpCardTone.tinted,
              child: ScannableNote(
                // Calm, and said in the app's own words rather than a severity
                // word: this card is not a finding, it is the reason today
                // looks the way it does.
                severity: HpSeverity.calm,
                chipLabel: 'Today’s plan',
                title: 'Why today looks like this',
                body: briefing.planRationale!,
              ),
            ),
        ],
      ),
    );
  }

  static void _showCareSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext sheetContext) {
        final HpPalette p = sheetContext.hp;
        return Padding(
          padding: const EdgeInsets.fromLTRB(
            HpSpacing.gutter,
            0,
            HpSpacing.gutter,
            HpSpacing.section,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Getting care today',
                style: HpType.headline.copyWith(color: p.ink),
              ),
              const SizedBox(height: HpSpacing.md),
              Text(
                'HealthPulse cannot book an appointment or contact anyone for '
                'you. Call your own doctor or clinic and read them the value on '
                'the card. If you feel very unwell, go to the nearest emergency '
                'department or call your local emergency number.',
                style: HpType.reading.copyWith(color: p.inkMuted),
              ),
              const SizedBox(height: HpSpacing.xl),
              HpButton(
                label: 'Close',
                tone: HpButtonTone.secondary,
                onPressed: () => Navigator.of(sheetContext).pop(),
              ),
            ],
          ),
        );
      },
    );
  }

  /// The routine, drawn as the ribbon.
  ///
  /// The only thing decided here is what a row *does*; what the rows are is
  /// [buildDayRoutine]'s job. A meal opens the plan, because "what exactly are
  /// my four lunch options" is the next question after seeing that there are
  /// four of them, and the plan is where they are written out with the reason
  /// each one is there.
  static List<HpTimelineEntry> _timelineFor(
    BuildContext context,
    TodayBriefing briefing,
    DateTime now,
  ) {
    final List<DayMoment> moments = buildDayRoutine(briefing);
    final int minutesNow = now.hour * 60 + now.minute;

    // "Now" is the next thing that has not happened yet, which is the question
    // someone actually opens the app to answer.
    int nowIndex = moments.indexWhere(
      (DayMoment moment) => moment.minutesOfDay >= minutesNow,
    );
    if (nowIndex < 0) {
      nowIndex = moments.length - 1;
    }

    return <HpTimelineEntry>[
      for (int i = 0; i < moments.length; i++)
        HpTimelineEntry(
          time: HpFormat.clockLabel(moments[i].time),
          title: moments[i].title,
          detail: moments[i].detail,
          icon: moments[i].icon,
          state: i < nowIndex
              ? HpTimelineState.done
              : (i == nowIndex
                  ? HpTimelineState.now
                  : HpTimelineState.upcoming),
          onTap: moments[i].kind == DayMomentKind.meal
              ? () => GoRouter.of(context).go('/plan')
              : null,
        ),
    ];
  }
}

class _FocusCard extends StatelessWidget {
  const _FocusCard({required this.note});

  final FocusNote note;

  @override
  Widget build(BuildContext context) {
    return HpCard(
      onTap: note.linkedBiomarker == null
          ? null
          : () => GoRouter.of(context).go('/reports'),
      child: ScannableNote(
        severity: note.tone.severity,
        title: note.title,
        body: note.body,
        action: note.actionLabel == null
            ? null
            : HpTextAction(
                label: note.actionLabel!,
                onPressed: () => GoRouter.of(context).go('/reports'),
              ),
      ),
    );
  }
}

/// When Today's content was last fetched, or null if it came straight off the
/// network or the repository does not cache at all.
///
/// Takes [Object] rather than [HealthRepository] on purpose: promotion from
/// [Object] to [CacheAware] always applies, so this needs no cast in either
/// direction. `flutter analyze` treats both an unpromoted call and an
/// unnecessary cast as build failures, and this avoids having to guess which.
DateTime? _servedFromCacheAt(Object repository) => repository is CacheAware
    ? repository.servedFromCacheAt(CacheAware.cacheSubjectToday)
    : null;

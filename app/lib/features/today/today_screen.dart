import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format/hp_format.dart';
import '../../core/theme/hp_palette.dart';
import '../../core/theme/hp_severity.dart';
import '../../core/theme/hp_spacing.dart';
import '../../core/theme/hp_typography.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/models.dart';
import '../../data/providers.dart';
import '../common/severity_ui.dart';

/// The screen people open every morning.
///
/// It is built as the day itself - a single ribbon of time from waking to
/// sleeping, with the current moment marked - rather than a grid of statistics.
/// The product is the loop, and the loop happens at particular hours, so the
/// hours are the structure. Everything else on the screen stays deliberately
/// quiet so that the ribbon, and any escalation above it, are what the eye finds.
class TodayScreen extends ConsumerWidget {
  const TodayScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<TodayBriefing> today = ref.watch(todayProvider);

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: <Widget>[
            Expanded(
              child: today.when(
                loading: () => const HpLoadingState(
                  message: 'Getting your day ready',
                  detail: 'This can take a moment on the first open.',
                ),
                error: (Object error, StackTrace stack) => HpErrorState(
                  title: 'Today could not be loaded',
                  body: 'You are seeing this because the app could not reach '
                      'the health engine. Your data is safe.',
                  onRetry: () => ref.invalidate(todayProvider),
                ),
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
  const _TodayBody({super.key, required this.briefing});

  final TodayBriefing briefing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final HpPalette p = context.hp;
    final DateTime now = DateTime.now();

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

          // An urgent finding sits above everything, including the day itself.
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

          HpSectionHeader(
            title: 'Your day',
            note: '${briefing.meals.length} planned',
          ),
          HpDayTimeline(entries: _timelineFor(briefing, now)),
          const SizedBox(height: HpSpacing.section),

          HpCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                HpMeter(
                  label: 'Water so far',
                  value: briefing.hydrationMl,
                  target: briefing.hydrationTargetMl,
                  unit: 'ml',
                  footnote: 'A glass every couple of hours is easier than '
                      'catching up at night.',
                ),
                const SizedBox(height: HpSpacing.lg),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: HpButton(
                        label: 'Add a glass',
                        tone: HpButtonTone.secondary,
                        icon: Icons.add_rounded,
                        onPressed: () async {
                          await ref
                              .read(healthRepositoryProvider)
                              .logHydration(250);
                          ref.invalidate(todayProvider);
                        },
                      ),
                    ),
                  ],
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Why today looks like this',
                    style: HpType.bodyStrong.copyWith(color: p.ink),
                  ),
                  const SizedBox(height: HpSpacing.sm),
                  Text(
                    briefing.planRationale!,
                    style: HpType.reading.copyWith(color: p.inkMuted),
                  ),
                ],
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

  static List<HpTimelineEntry> _timelineFor(
    TodayBriefing briefing,
    DateTime now,
  ) {
    final int minutesNow = now.hour * 60 + now.minute;
    final List<_Moment> moments = <_Moment>[
      _Moment(
        time: briefing.wakeTime,
        title: 'Wake up',
        detail: 'Fifteen minutes of morning light helps your vitamin D.',
        icon: Icons.wb_sunny_outlined,
      ),
      for (final MealPlanItem meal in briefing.meals)
        _Moment(
          time: meal.timeOfDay ?? meal.mealSlot.defaultTime,
          title: meal.title,
          detail: meal.portion,
          icon: Icons.restaurant_outlined,
        ),
      _Moment(
        time: '18:30',
        title: 'A walk',
        detail: '${briefing.movementTargetMinutes} minutes is the target today.',
        icon: Icons.directions_walk_rounded,
      ),
      _Moment(
        time: briefing.sleepTime,
        title: 'Wind down',
        detail: 'Screens away thirty minutes before this.',
        icon: Icons.bedtime_outlined,
      ),
    ]..sort(
        (_Moment a, _Moment b) => HpFormat.minutesOfDay(a.time)
            .compareTo(HpFormat.minutesOfDay(b.time)),
      );

    // "Now" is the next thing that has not happened yet, which is the question
    // someone actually opens the app to answer.
    int nowIndex = moments.indexWhere(
      (_Moment m) => HpFormat.minutesOfDay(m.time) >= minutesNow,
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
        ),
    ];
  }
}

class _Moment {
  const _Moment({
    required this.time,
    required this.title,
    required this.icon,
    this.detail,
  });

  final String time;
  final String title;
  final String? detail;
  final IconData icon;
}

class _FocusCard extends StatelessWidget {
  const _FocusCard({super.key, required this.note});

  final FocusNote note;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    final HpSeverity severity = note.tone.severity;

    return HpCard(
      onTap: note.linkedBiomarker == null
          ? null
          : () => GoRouter.of(context).go('/reports'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          HpStatusChip(severity: severity, dense: true),
          const SizedBox(height: HpSpacing.md),
          Text(note.title, style: HpType.headline.copyWith(color: p.ink)),
          const SizedBox(height: HpSpacing.sm),
          Text(note.body, style: HpType.reading.copyWith(color: p.inkMuted)),
          if (note.actionLabel != null) ...<Widget>[
            const SizedBox(height: HpSpacing.sm),
            HpTextAction(
              label: note.actionLabel!,
              onPressed: () => GoRouter.of(context).go('/reports'),
            ),
          ],
        ],
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:healthpulse/core/theme/hp_theme.dart';
import 'package:healthpulse/core/widgets/widgets.dart';
import 'package:healthpulse/data/api/api_failure.dart';
import 'package:healthpulse/data/repository/health_repository.dart';
import 'package:healthpulse/features/summary/weekly_summary_screen.dart';
import 'package:healthpulse/features/summary/weekly_summary_service.dart';

/// The weekly summary screen.
///
/// The owner asked for a summary that "will boost the user", and almost all of
/// these tests are about the boundary that request runs into: a health app may
/// be warm, and it may not make anything up. So the interesting cases are the
/// ones where there is nothing to be warm about.
///
/// The rest is the ordinary contract every screen in this app keeps: a busy flag
/// cleared in a `finally`, no double-fire, and a refusal that says which refusal
/// it was rather than "something went wrong".
void main() {
  // ------------------------------------------------------------ the full week

  testWidgets('a real week shows the sentence and the counts as separate things',
      (WidgetTester tester) async {
    useTallSurface(tester);
    final _FakeSummaryService service = _FakeSummaryService();

    await tester.pumpWidget(summaryApp(service));
    await settleWithoutAnimations(tester);

    expect(service.loads, 1, reason: 'the week is fetched once on arrival');
    // The one sentence a model wrote.
    expect(find.textContaining('You showed up for your plan'), findsOneWidget);
    // And the counts, which nothing generated.
    expect(find.text('What you did'), findsOneWidget);
    expect(
      find.text('You marked 4 meals as eaten and 1 meal as skipped, on 3 days.'),
      findsOneWidget,
    );
  });

  testWidgets('the movement bar is drawn from the backend and cites its source',
      (WidgetTester tester) async {
    useTallSurface(tester);

    await tester.pumpWidget(summaryApp(_FakeSummaryService()));
    await settleWithoutAnimations(tester);

    expect(find.byType(HpMeter), findsOneWidget);
    final HpMeter meter = tester.widget<HpMeter>(find.byType(HpMeter));
    expect(meter.value, 95);
    expect(meter.target, 150);
    expect(meter.footnote, contains('World Health Organization'));
  });

  testWidgets('what the week cannot count is on the screen, not hidden',
      (WidgetTester tester) async {
    useTallSurface(tester);

    await tester.pumpWidget(summaryApp(_FakeSummaryService()));
    await settleWithoutAnimations(tester);

    expect(find.text('What this does not count'), findsOneWidget);
    // Water is the one that matters: glasses are tallied on this phone and
    // never sent anywhere, so an absence here must not read as a zero.
    expect(find.textContaining('Water is not counted here'), findsOneWidget);
  });

  // ----------------------------------------------------------- the quiet week

  testWidgets('an empty week says so and is not dressed up as progress',
      (WidgetTester tester) async {
    useTallSurface(tester);

    await tester.pumpWidget(summaryApp(_FakeSummaryService(quiet: true)));
    await settleWithoutAnimations(tester);

    expect(find.text('A quiet week'), findsOneWidget);
    expect(
      find.textContaining('do not have enough from this week'),
      findsOneWidget,
    );
    expect(find.textContaining('no movement was logged'), findsOneWidget);
    // No encouragement, no bar, and nothing to write again.
    expect(find.textContaining('You showed up'), findsNothing);
    expect(find.byType(HpMeter), findsNothing);
    expect(find.widgetWithText(HpButton, 'Write it again'), findsNothing);
  });

  testWidgets('a quiet week offers a way to make the next one real',
      (WidgetTester tester) async {
    useTallSurface(tester);

    await tester.pumpWidget(summaryApp(_FakeSummaryService(quiet: true)));
    await settleWithoutAnimations(tester);

    expect(
      find.widgetWithText(HpButton, 'Open today’s plan'),
      findsOneWidget,
    );
  });

  // ------------------------------------------------------- a visible downgrade

  testWidgets('counts without a sentence say why there is no sentence',
      (WidgetTester tester) async {
    useTallSurface(tester);

    // The model wrote something that broke a rail, so the backend withheld it
    // and sent the counts alone. A gap with no explanation reads as a bug.
    await tester.pumpWidget(summaryApp(_FakeSummaryService(noSentence: true)));
    await settleWithoutAnimations(tester);

    expect(find.text(noSentenceMessage), findsOneWidget);
    expect(find.text('What you did'), findsOneWidget);
    expect(find.byType(HpMeter), findsOneWidget);
  });

  // -------------------------------------------------------------- writing again

  testWidgets('writing it again replaces the sentence',
      (WidgetTester tester) async {
    useTallSurface(tester);
    final _FakeSummaryService service = _FakeSummaryService();

    await tester.pumpWidget(summaryApp(service));
    await settleWithoutAnimations(tester);

    await tester.ensureVisible(find.widgetWithText(HpButton, 'Write it again'));
    await tester.tap(find.widgetWithText(HpButton, 'Write it again'));
    await settleWithoutAnimations(tester);

    expect(service.refreshes, 1);
    expect(find.textContaining('A second look at the same week'), findsOneWidget);
  });

  testWidgets('a second tap while the first is in flight sends nothing',
      (WidgetTester tester) async {
    useTallSurface(tester);
    // Held open on a Completer: the fake otherwise settles in a microtask and
    // awaiting the tap would flush it, so the "second" tap would land on a call
    // that had already finished.
    final _FakeSummaryService service = _FakeSummaryService(holdRefresh: true);

    await tester.pumpWidget(summaryApp(service));
    await settleWithoutAnimations(tester);

    final Finder button = find.widgetWithText(HpButton, 'Write it again');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pump();
    expect(service.refreshes, 1);
    // The wait is visible while it happens.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    // Turned away twice over: the button draws itself disabled while it is
    // busy, and `_refresh` guards on the flag as well, so a control that was
    // left enabled by a later change still could not send this twice.
    await tester.tap(button, warnIfMissed: false);
    await tester.pump();
    expect(
      service.refreshes,
      1,
      reason: 'a second tap asked for the same rewrite twice',
    );

    service.releaseRefresh();
    await settleWithoutAnimations(tester);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('a refused rewrite leaves the week alone and says which refusal',
      (WidgetTester tester) async {
    useTallSurface(tester);
    final _FakeSummaryService service = _FakeSummaryService(refuseRefresh: true);

    await tester.pumpWidget(summaryApp(service));
    await settleWithoutAnimations(tester);

    final Finder button = find.widgetWithText(HpButton, 'Write it again');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await settleWithoutAnimations(tester);

    expect(find.text(refusalMessage), findsOneWidget);
    // The week that was on screen is still on screen, unchanged.
    expect(find.textContaining('You showed up for your plan'), findsOneWidget);
    // And the flag was cleared in the `finally`, so it can be tried again.
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.tap(button);
    await settleWithoutAnimations(tester);
    expect(service.refreshes, 2);
  });

  // --------------------------------------------------------------- first fetch

  testWidgets('a failed fetch offers a way back in',
      (WidgetTester tester) async {
    useTallSurface(tester);
    final _FakeSummaryService service = _FakeSummaryService(refuseLoad: true);

    await tester.pumpWidget(summaryApp(service));
    await settleWithoutAnimations(tester);

    expect(find.text('We could not fetch your week'), findsOneWidget);
    expect(find.text(refusalMessage), findsOneWidget);

    service.refuseLoad = false;
    await tester.tap(find.widgetWithText(HpButton, 'Try again'));
    await settleWithoutAnimations(tester);
    expect(find.textContaining('You showed up for your plan'), findsOneWidget);
  });

  testWidgets('a build with no backend says so instead of spinning',
      (WidgetTester tester) async {
    useTallSurface(tester);

    await tester.pumpWidget(summaryApp(null));
    await settleWithoutAnimations(tester);

    expect(find.text('We could not fetch your week'), findsOneWidget);
    expect(find.textContaining('no backend to ask'), findsOneWidget);
  });

  // ------------------------------------------------------------------ parsing

  test('a week parses out of the wire shape the backend sends', () {
    final WeeklySummary week = WeeklySummary.fromJson(fullWeekJson);
    expect(week.hasEnoughData, isTrue);
    expect(week.proseSource, WeeklyProseSource.model);
    expect(week.facts.markedEaten, 4);
    expect(week.facts.movementMinutes, 95);
    expect(week.facts.hasAnything, isTrue);
    expect(week.weekStart.day, 7);
  });

  test('an unknown prose source is read as the counts alone, never as the model',
      () {
    expect(WeeklyProseSource.fromWire('something new'),
        WeeklyProseSource.computed);
  });

  test('a week label names both ends of it', () {
    final String label =
        weekLabel(DateTime(2026, 9, 7), DateTime(2026, 9, 13));
    expect(label, contains('7 Sep'));
    expect(label, contains('13 Sep'));
  });
}

// ------------------------------------------------------------------- harness

/// The sentence a refused call puts on screen, written in this app rather than
/// by the server.
final String refusalMessage =
    const ApiFailure(ApiFailureKind.wakingUpTimedOut).message;

const Map<String, dynamic> fullWeekJson = <String, dynamic>{
  'week_start': '2026-09-07',
  'week_end': '2026-09-13',
  'has_enough_data': true,
  'summary': 'You showed up for your plan on several days this week, and you '
      'logged your walks as you went.',
  'prose_source': 'model',
  'lines': <String>[
    'We planned 21 meals for you across 5 days.',
    'You marked 4 meals as eaten and 1 meal as skipped, on 3 days.',
  ],
  'not_measured': <String>[
    'Water is not counted here. Your glasses are tallied on this phone only.',
  ],
  'facts': <String, dynamic>{
    'meals_planned': 21,
    'days_planned': 5,
    'marked_eaten': 4,
    'marked_skipped': 1,
    'days_with_a_mark': 3,
    'meals_logged': 2,
    'days_with_a_meal_logged': 2,
    'movement_minutes': 95,
    'days_moved': 3,
    'movement_target_minutes_per_week': 150,
    'movement_target_source':
        'World Health Organization, Physical activity guidelines 2020',
    'report_measured_on': null,
    'report_values': 0,
    'report_outside_usual_range': 0,
  },
  'generated': true,
};

const Map<String, dynamic> quietWeekJson = <String, dynamic>{
  'week_start': '2026-09-07',
  'week_end': '2026-09-13',
  'has_enough_data': false,
  'summary': null,
  'prose_source': 'quiet',
  'lines': <String>[
    'We do not have enough from this week to tell you anything true about it.',
    'No meal from your plan was marked eaten or skipped, no meal was logged, '
        'no movement was logged.',
  ],
  'not_measured': <String>[
    'Water is not counted here. Your glasses are tallied on this phone only.',
  ],
  'facts': <String, dynamic>{},
  'generated': false,
};

/// A summary service that answers from fixtures and records what it was asked.
class _FakeSummaryService implements WeeklySummaryService {
  _FakeSummaryService({
    this.quiet = false,
    this.noSentence = false,
    this.refuseLoad = false,
    this.refuseRefresh = false,
    this.holdRefresh = false,
  });

  bool quiet;
  final bool noSentence;
  bool refuseLoad;
  final bool refuseRefresh;
  final bool holdRefresh;

  int loads = 0;
  int refreshes = 0;

  Completer<void>? _held;

  void releaseRefresh() {
    _held?.complete();
    _held = null;
  }

  @override
  Future<WeeklySummary> load({DateTime? weekStart}) async {
    loads += 1;
    if (refuseLoad) {
      throw HealthRepositoryException(refusalMessage);
    }
    return WeeklySummary.fromJson(_body());
  }

  @override
  Future<WeeklySummary> refresh({DateTime? weekStart}) async {
    refreshes += 1;
    if (holdRefresh) {
      final Completer<void> gate = Completer<void>();
      _held = gate;
      await gate.future;
    }
    if (refuseRefresh) {
      throw HealthRepositoryException(refusalMessage);
    }
    return WeeklySummary.fromJson(<String, dynamic>{
      ..._body(),
      'summary': 'A second look at the same week, in different words.',
    });
  }

  Map<String, dynamic> _body() {
    if (quiet) {
      return quietWeekJson;
    }
    if (noSentence) {
      return <String, dynamic>{
        ...fullWeekJson,
        'summary': null,
        'prose_source': 'computed',
      };
    }
    return fullWeekJson;
  }
}

/// The screen, wired to [service].
///
/// A plain [MaterialApp] rather than a router: the only routes this screen knows
/// about are the way back to More and the way to Today, and neither is tapped
/// here. `null` stands for a build with no backend address.
Widget summaryApp(WeeklySummaryService? service) {
  return ProviderScope(
    overrides: <Override>[
      weeklySummaryServiceProvider.overrideWithValue(service),
    ],
    child: MaterialApp(
      theme: HpTheme.light(),
      home: const WeeklySummaryScreen(),
    ),
  );
}

/// A surface tall enough that this screen has no fold.
void useTallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(600, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Let a queued failure or success land without waiting on any animation.
///
/// [WidgetTester.pumpAndSettle] cannot be used here: a spinner animates for
/// ever, so a screen that is meant to be busy would time the test out.
Future<void> settleWithoutAnimations(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 32));
  await tester.pump();
}

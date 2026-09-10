import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:healthpulse/core/theme/hp_theme.dart';
import 'package:healthpulse/core/widgets/widgets.dart';
import 'package:healthpulse/data/repository/health_repository.dart';
import 'package:healthpulse/features/activity/activity_card.dart';
import 'package:healthpulse/features/activity/activity_service.dart';
import 'package:healthpulse/features/activity/log_activity_sheet.dart';

/// The exercise card, which replaced a bar that said "Moving: 0 of 43 minutes".
///
/// The owner asked for three things and each has tests here:
///
/// > "you can let the user know all the types of physical exercises ... How much
/// > time did he spend? ... this much of calories you had burnt till date."
///
/// The fourth thing, which he did not ask for and which matters more, is that
/// none of it overclaims. An energy figure worked out from a population average
/// and a recorded weight is an estimate, and the word "estimate" is never far
/// from the number; a missing body weight produces no number at all rather than
/// a plausible one; and nothing on the card connects a kilocalorie to weight loss
/// or to any other health outcome.
void main() {
  // ------------------------------------------------------------- the wording

  group('what the card is allowed to say', () {
    test('a logged session is confirmed as an estimate, never as a measurement',
        () {
      final String said = confirmationFor(
        const LoggedActivity(
          label: 'Badminton',
          minutes: 45,
          intensity: 'moderate',
          energy: ActivityEnergy(kcal: 290),
        ),
      );
      expect(said, contains('Badminton, 45 minutes'));
      expect(said, contains('290 kcal'));
      expect(said, contains('estimate'));
      expect(said, contains('not a measurement'));
    });

    test('with no energy figure it says so instead of saying zero', () {
      final String said = confirmationFor(
        const LoggedActivity(
          label: 'Something else',
          minutes: 30,
          intensity: 'moderate',
          energy: ActivityEnergy(
            unavailableReason: 'Nothing here says what the activity was.',
          ),
        ),
      );
      expect(said, contains('without an energy figure'));
      expect(said, contains('Nothing here says what the activity was.'));
      expect(said, isNot(contains('0 kcal')));
    });

    test('a five figure total is readable at a glance', () {
      expect(formatKcal(0), '0');
      expect(formatKcal(290), '290');
      expect(formatKcal(12400), '12,400');
      expect(formatKcal(1234567), '1,234,567');
    });
  });

  // ------------------------------------------------------- naming the exercise

  testWidgets('the sheet names real activities instead of "movement"',
      (WidgetTester tester) async {
    useTallSurface(tester);
    final _FakeActivityService service = _FakeActivityService();

    await tester.pumpWidget(cardApp(service: service));
    await settle(tester);
    await tester.tap(find.byKey(addButtonKey));
    await settleSheet(tester);

    expect(find.byType(LogActivitySheet), findsOneWidget);
    expect(find.text('What did you do?'), findsOneWidget);
    for (final String name in <String>[
      'Badminton',
      'Running',
      'Yoga',
      'Something else',
    ]) {
      expect(find.text(name), findsOneWidget, reason: '$name is not offered');
    }
    // And each one is described in words somebody would use for their own
    // afternoon, not in METs.
    expect(find.text('A social game, singles or doubles'), findsOneWidget);
  });

  testWidgets('picking one and entering minutes logs exactly that',
      (WidgetTester tester) async {
    useTallSurface(tester);
    final _FakeActivityService service = _FakeActivityService();

    await tester.pumpWidget(cardApp(service: service));
    await settle(tester);
    await tester.tap(find.byKey(addButtonKey));
    await settleSheet(tester);
    await tester.tap(find.text('Badminton'));
    await settle(tester);

    // The citation for the figure about to be produced is on the screen that
    // produces it, not buried somewhere else.
    expect(find.textContaining('Ainsworth'), findsOneWidget);
    expect(find.textContaining('15030'), findsOneWidget);

    await tester.enterText(find.byKey(minutesFieldKey), '45');
    await settle(tester);
    await tester.tap(find.text('Add it'));
    await settleSheet(tester);

    expect(service.logged, <String>['badminton/45/null']);
  });

  testWidgets('an activity too gentle for the target says so before the write',
      (WidgetTester tester) async {
    useTallSurface(tester);
    await tester.pumpWidget(cardApp(service: _FakeActivityService()));
    await settle(tester);
    await tester.tap(find.byKey(addButtonKey));
    await settleSheet(tester);
    await tester.tap(find.text('Yoga'));
    await settle(tester);

    // Discovered here, rather than after the write when the bar does not move.
    expect(
      find.textContaining('will not move that bar'),
      findsOneWidget,
    );
  });

  testWidgets('"something else" has to say how hard it was, and it is sent',
      (WidgetTester tester) async {
    useTallSurface(tester);
    final _FakeActivityService service = _FakeActivityService();

    await tester.pumpWidget(cardApp(service: service));
    await settle(tester);
    await tester.tap(find.byKey(addButtonKey));
    await settleSheet(tester);
    await tester.tap(find.text('Something else'));
    await settle(tester);

    // Described so it can be answered from memory of the hour, not in METs.
    expect(find.text('You could talk, but not sing'), findsOneWidget);
    await tester.tap(find.text('Vigorous'));
    await settle(tester);
    await tester.enterText(find.byKey(minutesFieldKey), '20');
    await settle(tester);
    await tester.tap(find.text('Add it'));
    await settleSheet(tester);

    expect(service.logged, <String>['other/20/vigorous']);
  });

  // ------------------------------------------------------------ energy so far

  testWidgets('today and the running total are shown, and named as estimates',
      (WidgetTester tester) async {
    useTallSurface(tester);
    await tester.pumpWidget(
      cardApp(
        service: _FakeActivityService(
          summary: summaryWith(
            todayKcal: 290,
            totalKcal: 12400,
            since: DateTime(2026, 3, 3),
            streak: 4,
          ),
        ),
      ),
    );
    await settle(tester);

    expect(find.text('About 290 kcal'), findsOneWidget);
    expect(find.text('About 12,400 kcal'), findsOneWidget);
    // "Till date" is not a thing we can say honestly, so a real date is named.
    expect(find.text('since 3 Mar'), findsOneWidget);
    // Boosting, and true: it counts logging and says that is what it counts.
    expect(
      find.text('4 days in a row with something logged.'),
      findsOneWidget,
    );
    expect(find.textContaining('An estimate, not a measurement'), findsOneWidget);
    expect(find.textContaining('your weight of 70 kg'), findsOneWidget);
    // The one sentence that must be there: no health claim rides on the number.
    expect(
      find.textContaining('says nothing about your weight or your health'),
      findsOneWidget,
    );
  });

  testWidgets('no recorded weight means no number, a reason, and a way to fix it',
      (WidgetTester tester) async {
    useTallSurface(tester);
    await tester.pumpWidget(
      cardApp(
        service: _FakeActivityService(summary: summaryWithoutWeight()),
      ),
    );
    await settle(tester);

    expect(find.text('Energy burnt is not shown yet'), findsOneWidget);
    expect(find.textContaining('no weight on your profile'), findsOneWidget);
    // Never a zero standing in for "we cannot say".
    expect(find.textContaining('0 kcal'), findsNothing);

    await tester.ensureVisible(find.text('Add your weight'));
    await tester.tap(find.text('Add your weight'));
    await settleSheet(tester);
    expect(find.text(profileMarker), findsOneWidget);
  });

  testWidgets('a total the backend could not see all of says "at least"',
      (WidgetTester tester) async {
    useTallSurface(tester);
    await tester.pumpWidget(
      cardApp(
        service: _FakeActivityService(
          summary: summaryWith(
            todayKcal: 100,
            totalKcal: 40000,
            since: DateTime(2025, 1, 6),
            truncated: true,
          ),
        ),
      ),
    );
    await settle(tester);

    expect(find.text('At least 40,000 kcal'), findsOneWidget);
  });

  // ----------------------------------------------------------- while in flight

  testWidgets('a second tap while the first write is in flight logs once',
      (WidgetTester tester) async {
    useTallSurface(tester);
    final _FakeActivityService service = _FakeActivityService(hold: true);

    await tester.pumpWidget(cardApp(service: service));
    await settle(tester);
    await tester.tap(find.byKey(addButtonKey));
    await settleSheet(tester);
    await tester.tap(find.text('Running'));
    await settle(tester);
    await tester.tap(find.text('Add it'));
    await settleSheet(tester);

    // The write is held open, so this is genuinely inside the window the busy
    // guard exists for. Never pumpAndSettle here: the spinner never settles.
    expect(service.logged.length, 1);
    await tester.tap(find.byKey(addButtonKey), warnIfMissed: false);
    await settle(tester);
    expect(service.logged.length, 1);

    service.release();
    await settle(tester);
  });

  testWidgets('a failed write says why, in our words, and gives the button back',
      (WidgetTester tester) async {
    useTallSurface(tester);
    final _FakeActivityService service = _FakeActivityService(
      failure: const HealthRepositoryException(
        'The health engine is still waking up. Try again in a moment.',
      ),
    );

    await tester.pumpWidget(cardApp(service: service));
    await settle(tester);
    await tester.tap(find.byKey(addButtonKey));
    await settleSheet(tester);
    await tester.tap(find.text('Walking'));
    await settle(tester);
    await tester.tap(find.text('Add it'));
    await settleSheet(tester);

    expect(
      find.text('The health engine is still waking up. Try again in a moment.'),
      findsOneWidget,
    );
    // And the card is usable again: the flag is cleared in a `finally`.
    expect(addButton(tester).busy, isFalse);
    expect(addButton(tester).onPressed, isNotNull);
  });

  // ------------------------------------------------------------- no backend

  testWidgets('a build with no health engine says so instead of offering a dead '
      'button', (WidgetTester tester) async {
    useTallSurface(tester);
    await tester.pumpWidget(cardApp(service: null));
    await settle(tester);

    expect(find.byKey(addButtonKey), findsNothing);
    expect(find.text(activityNeedsBackendMessage), findsOneWidget);
  });
}

// --------------------------------------------------------------------- harness

const Key addButtonKey = ValueKey<String>('activity-add-button');
const Key minutesFieldKey = ValueKey<String>('activity-minutes-field');

/// What the profile screen says here, so a test can tell "the weight link went
/// somewhere" from "the weight link did nothing".
const String profileMarker = 'PROFILE-REACHED';

/// The card, wired to [service], with somewhere for its one link to go.
Widget cardApp({
  required ActivityService? service,
  int minutesToday = 18,
  int targetMinutes = 43,
}) {
  return ProviderScope(
    overrides: <Override>[
      activityServiceProvider.overrideWithValue(service),
    ],
    child: MaterialApp.router(
      theme: HpTheme.light(),
      routerConfig: GoRouter(
        initialLocation: '/today',
        routes: <RouteBase>[
          GoRoute(
            path: '/today',
            builder: (BuildContext context, GoRouterState state) => Scaffold(
              body: SingleChildScrollView(
                child: ActivityCard(
                  minutesToday: minutesToday,
                  targetMinutes: targetMinutes,
                ),
              ),
            ),
          ),
          GoRoute(
            path: '/more/profile',
            builder: (BuildContext context, GoRouterState state) =>
                const Scaffold(body: Center(child: Text(profileMarker))),
          ),
        ],
      ),
    ),
  );
}

/// A surface tall enough that the card and an open sheet both fit.
void useTallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(600, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Let a queued future land without waiting on any animation.
///
/// [WidgetTester.pumpAndSettle] cannot be used in this file: a busy button
/// animates for ever, so a card that is *meant* to be busy would time it out.
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 32));
  await tester.pump();
}

/// The same, with enough time for a bottom sheet to open or close.
Future<void> settleSheet(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

/// The add button itself, so an assertion is about the state the guard keeps
/// rather than about whether a spinner happens to be painted this frame.
HpButton addButton(WidgetTester tester) =>
    tester.widget<HpButton>(find.byKey(addButtonKey));

/// The list the backend publishes, in the shape it publishes it.
const ActivityCatalogue testCatalogue = ActivityCatalogue(
  source: 'Ainsworth BE, et al. 2011 Compendium of Physical Activities. '
      'Medicine and Science in Sports and Exercise. 2011;43(8):1575-1581.',
  energyBasis: 'This is an estimate, not a measurement.',
  activities: <ActivityType>[
    ActivityType(
      key: 'badminton',
      label: 'Badminton',
      example: 'A social game, singles or doubles',
      mets: 5.5,
      intensity: 'moderate',
      source: '5.5 METs - Ainsworth BE, et al. Activity code 15030, '
          "'badminton, social singles and doubles, general'.",
    ),
    ActivityType(
      key: 'running',
      label: 'Running',
      example: 'About 10 km/h, a steady run',
      mets: 9.8,
      intensity: 'vigorous',
      source: '9.8 METs - Ainsworth BE, et al. Activity code 12050.',
    ),
    ActivityType(
      key: 'walking',
      label: 'Walking',
      example: 'A brisk walk, about 5 km/h',
      mets: 3.5,
      intensity: 'moderate',
      source: '3.5 METs - Ainsworth BE, et al. Activity code 17190.',
    ),
    ActivityType(
      key: 'yoga',
      label: 'Yoga',
      example: 'Hatha yoga, held postures',
      mets: 2.5,
      intensity: 'light',
      countsTowardTarget: false,
      source: '2.5 METs - Ainsworth BE, et al. Activity code 02150.',
    ),
    ActivityType(
      key: 'other',
      label: 'Something else',
      example: 'Anything not on this list',
      needsIntensity: true,
      source: 'No energy figure: we do not know what this was.',
    ),
  ],
);

ActivitySummary summaryWith({
  required int todayKcal,
  required int totalKcal,
  required DateTime since,
  int streak = 0,
  bool truncated = false,
}) {
  return ActivitySummary(
    today: ActivityTotals(
      sessions: 1,
      minutes: 45,
      moderateEquivalentMinutes: 45,
      daysLogged: 1,
      energy: ActivityEnergy(kcal: todayKcal),
    ),
    week: ActivityTotals(
      sessions: 3,
      minutes: 120,
      energy: ActivityEnergy(kcal: todayKcal),
    ),
    total: ActivityTotals(
      start: since,
      sessions: 40,
      minutes: 2000,
      daysLogged: 30,
      energy: ActivityEnergy(kcal: totalKcal),
      truncated: truncated,
    ),
    loggedDaysInARow: streak,
    targetMinutesPerDay: 43,
    targetMinutesPerWeek: 300,
    weightKg: 70,
    energyBasis: 'This is an estimate, not a measurement.',
  );
}

ActivitySummary summaryWithoutWeight() {
  const ActivityEnergy silent = ActivityEnergy(
    unavailableReason:
        'Energy is worked out from body weight, and there is no weight on your '
        'profile. Add it to your health profile and this will start showing.',
  );
  return const ActivitySummary(
    today: ActivityTotals(sessions: 1, minutes: 45, energy: silent),
    week: ActivityTotals(sessions: 1, minutes: 45, energy: silent),
    total: ActivityTotals(sessions: 1, minutes: 45, energy: silent),
  );
}

/// The service, with every call recorded and the write holdable.
class _FakeActivityService implements ActivityService {
  _FakeActivityService({
    ActivitySummary? summary,
    this.failure,
    this.hold = false,
  }) : _summary = summary;

  final ActivitySummary? _summary;

  /// Thrown by [log] instead of writing, when set.
  final Object? failure;

  /// Hold [log] open until [release] is called.
  ///
  /// Without this a test cannot tap twice "while the first call is in flight":
  /// the fake settles in a microtask, and microtasks flush between two awaited
  /// taps, so the second tap would land after the first had finished.
  final bool hold;

  /// Every write, as `key/minutes/intensity`. Recorded before the gate and
  /// before any refusal, so it counts attempts rather than successes.
  final List<String> logged = <String>[];

  final Completer<void> _gate = Completer<void>();

  void release() {
    if (!_gate.isCompleted) {
      _gate.complete();
    }
  }

  @override
  Future<ActivityCatalogue> types() async => testCatalogue;

  @override
  Future<ActivitySummary> summary() async {
    final ActivitySummary? held = _summary;
    if (held == null) {
      // Nothing logged yet, and no weight either: the quietest honest answer.
      return summaryWithoutWeight();
    }
    return held;
  }

  @override
  Future<LoggedActivity> log({
    required String activity,
    required int minutes,
    String? intensity,
  }) async {
    logged.add('$activity/$minutes/$intensity');
    if (hold) {
      await _gate.future;
    }
    final Object? thrown = failure;
    if (thrown != null) {
      throw thrown;
    }
    return LoggedActivity(
      label: activity,
      minutes: minutes,
      intensity: intensity ?? 'moderate',
      energy: const ActivityEnergy(kcal: 290),
    );
  }
}

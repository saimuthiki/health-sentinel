import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:healthpulse/core/theme/hp_theme.dart';
import 'package:healthpulse/data/api/api_failure.dart';
import 'package:healthpulse/data/models/models.dart';
import 'package:healthpulse/data/providers.dart';
import 'package:healthpulse/data/repository/fake_health_repository.dart';
import 'package:healthpulse/data/repository/http_health_repository.dart';
import 'package:healthpulse/features/plan/plan_screen.dart';

import '_onboarding_harness.dart';

/// The screen the owner misread.
///
/// He was given four things for breakfast as four full-width cards in a row and
/// took them for a checklist - oats *and* ragi *and* jaggery *and* chia seeds -
/// before working out for himself that they were alternatives. Every test here
/// is one piece of that: the options belong to one meal, the meal says out loud
/// that it is a choice, and the buttons on it now do something and say so when
/// they cannot.
void main() {
  /// A plan with a meal that offers a real choice and a meal that does not.
  MealPlan planWith({String? rationale}) {
    return MealPlan(
      id: 'plan-test',
      planDate: DateTime(2026, 9, 10),
      rationale: rationale,
      items: const <MealPlanItem>[
        MealPlanItem(
          id: 'b1',
          mealSlot: MealSlot.breakfast,
          title: 'Oats with milk and banana',
          portion: '40 g oats',
          timeOfDay: '08:30',
          nutrients: <String, double>{'kcal': 320},
        ),
        MealPlanItem(
          id: 'b2',
          mealSlot: MealSlot.breakfast,
          title: 'Ragi dosa with coconut chutney',
          portion: '2 dosas',
          timeOfDay: '08:30',
          nutrients: <String, double>{'kcal': 412},
        ),
        MealPlanItem(
          id: 'b3',
          mealSlot: MealSlot.breakfast,
          title: 'Chia seeds soaked overnight',
          portion: '2 tablespoons',
          timeOfDay: '08:30',
          nutrients: <String, double>{'kcal': 138},
        ),
        MealPlanItem(
          id: 'l1',
          mealSlot: MealSlot.lunch,
          title: 'Rajma, brown rice and a beetroot salad',
          portion: '1 cup rajma',
          timeOfDay: '13:30',
          nutrients: <String, double>{'kcal': 620},
        ),
      ],
      dayNutrients: const <String, double>{'kcal': 1370},
      targets: const <String, double>{'kcal': 2100},
    );
  }

  Widget planApp(_PlanRepository repository) {
    return ProviderScope(
      overrides: <Override>[
        healthRepositoryProvider.overrideWithValue(repository),
      ],
      child: MaterialApp(
        theme: HpTheme.light(),
        home: const PlanScreen(),
      ),
    );
  }

  /// Put the plan on screen with its data already in. Two pumps, never
  /// [WidgetTester.pumpAndSettle]: the loading state holds a spinner that
  /// animates for ever, so settling on it would only ever time out.
  Future<void> showPlan(WidgetTester tester, _PlanRepository repository) async {
    useTallSurface(tester);
    await tester.pumpWidget(planApp(repository));
    await tester.pump();
    await tester.pump();
  }

  Finder slot(MealSlot which) =>
      find.byKey(ValueKey<String>('meal-slot-${which.wire}'));

  Finder option(String itemId) =>
      find.byKey(ValueKey<String>('meal-option-$itemId'));

  Finder insideOption(String itemId, Finder what) =>
      find.descendant(of: option(itemId), matching: what);

  /// Every word actually on screen, including the runs inside a rich paragraph,
  /// so a test can ask "is all of this still reachable" rather than trusting a
  /// finder to look inside a [TextSpan] for it.
  String visibleText(WidgetTester tester) {
    return tester
        .widgetList<Text>(find.byType(Text))
        .map((Text text) => text.data ?? text.textSpan?.toPlainText() ?? '')
        .join('\n');
  }

  bool anySpinner() =>
      find.byType(CircularProgressIndicator).evaluate().isNotEmpty;

  testWidgets('a meal with three options is one panel, not three cards',
      (WidgetTester tester) async {
    final _PlanRepository repository = _PlanRepository(plan: planWith());
    await showPlan(tester, repository);

    // Exactly one breakfast. This is the owner's complaint stated as an
    // assertion: whatever else changes, three options may never become three
    // things standing on their own.
    expect(slot(MealSlot.breakfast), findsOneWidget);

    for (final String id in <String>['b1', 'b2', 'b3']) {
      expect(
        find.descendant(of: slot(MealSlot.breakfast), matching: option(id)),
        findsOneWidget,
        reason: '$id must be nested inside the breakfast panel',
      );
    }

    // And the titles are in there with them, so the nesting is not just a key
    // in the tree that happens to line up.
    expect(
      find.descendant(
        of: slot(MealSlot.breakfast),
        matching: find.text('Ragi dosa with coconut chutney'),
      ),
      findsOneWidget,
    );

    // Lunch keeps its own panel; the meals are not merged into one list either.
    expect(slot(MealSlot.lunch), findsOneWidget);
    expect(
      find.descendant(of: slot(MealSlot.lunch), matching: option('l1')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: slot(MealSlot.breakfast), matching: option('l1')),
      findsNothing,
    );
  });

  testWidgets('a meal of several says it is a choice; a meal of one does not',
      (WidgetTester tester) async {
    final _PlanRepository repository = _PlanRepository(plan: planWith());
    await showPlan(tester, repository);

    expect(
      find.descendant(
        of: slot(MealSlot.breakfast),
        matching: find.textContaining('3 options'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: slot(MealSlot.breakfast),
        matching: find.textContaining('pick one'),
      ),
      findsOneWidget,
    );

    // One item is not a choice, and saying "pick one" over a single thing would
    // simply be a lie.
    expect(
      find.descendant(
        of: slot(MealSlot.lunch),
        matching: find.textContaining('pick one'),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: slot(MealSlot.lunch),
        matching: find.text('One thing to eat'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('"I ate this" posts that item once, and marks the others',
      (WidgetTester tester) async {
    final _PlanRepository repository = _PlanRepository(plan: planWith());
    await showPlan(tester, repository);

    await tester.ensureVisible(insideOption('b2', find.text('I ate this')));
    await tester.tap(insideOption('b2', find.text('I ate this')));
    await settleWithoutAnimations(tester);

    // The right item, the right plan, the right state, exactly once.
    expect(repository.marks, <String>['plan-test/b2:done']);

    expect(insideOption('b2', find.text('You ate this')), findsOneWidget);
    // The others are dimmed to "not chosen" and stay on screen: he has to be
    // able to see, and re-pick, what he turned down.
    expect(insideOption('b1', find.text('Not this one')), findsOneWidget);
    expect(insideOption('b3', find.text('Not this one')), findsOneWidget);
    expect(option('b1'), findsOneWidget);
  });

  testWidgets('choosing another option corrects the first one',
      (WidgetTester tester) async {
    final _PlanRepository repository = _PlanRepository(plan: planWith());
    await showPlan(tester, repository);

    await tester.tap(insideOption('b2', find.text('I ate this')));
    await settleWithoutAnimations(tester);
    await tester.tap(insideOption('b1', find.text('I ate this instead')));
    await settleWithoutAnimations(tester);

    // Not two things eaten. The first choice is unsaid before the second is
    // said, which is what keeps the learning loop honest.
    expect(
      repository.marks,
      <String>['plan-test/b2:done', 'plan-test/b2:skipped', 'plan-test/b1:done'],
    );
    expect(insideOption('b1', find.text('You ate this')), findsOneWidget);
    expect(insideOption('b2', find.text('Not this one')), findsOneWidget);

    // And it is reversible: tapping the chosen one again takes it back.
    await tester.tap(insideOption('b1', find.text('Undo')));
    await settleWithoutAnimations(tester);
    expect(repository.marks.last, 'plan-test/b1:skipped');
    expect(find.text('You ate this'), findsNothing);
  });

  testWidgets('a second tap while the first call is in flight does not post twice',
      (WidgetTester tester) async {
    // The call is held open on a Completer. The fake settles in a microtask and
    // awaiting a tap flushes microtasks, so a call left to settle on its own
    // would already have finished before the "second" tap and the test would be
    // proving nothing.
    final _PlanRepository repository =
        _PlanRepository(plan: planWith(), hold: true);
    await showPlan(tester, repository);

    await tester.tap(insideOption('b2', find.text('I ate this')));
    await tester.pump();

    // Genuinely mid-flight: one call started, nothing has come back.
    expect(repository.marks, <String>['plan-test/b2:done']);
    expect(
      insideOption('b2', find.byType(CircularProgressIndicator)),
      findsOneWidget,
    );

    // The same button again, and a different option in the same meal. Neither
    // may reach the repository while the first call is still open. The busy
    // button still carries its label, so this is the very same target.
    await tester.tap(insideOption('b2', find.text('I ate this')));
    await tester.pump();
    await tester.tap(insideOption('b1', find.text('I ate this')));
    await tester.pump();
    expect(repository.marks, <String>['plan-test/b2:done']);

    repository.release();
    await settleWithoutAnimations(tester);

    expect(repository.marks, <String>['plan-test/b2:done']);
    expect(anySpinner(), isFalse, reason: 'the busy state outlived the call');
    expect(insideOption('b2', find.text('You ate this')), findsOneWidget);
  });

  testWidgets('a refused call stops the spinner, says why, and can be retried',
      (WidgetTester tester) async {
    const ApiFailure refusal = ApiFailure(ApiFailureKind.wakingUpTimedOut);
    final _PlanRepository repository =
        _PlanRepository(plan: planWith(), refusal: refusal);
    await showPlan(tester, repository);

    await tester.tap(insideOption('b2', find.text('I ate this')));
    await settleWithoutAnimations(tester);

    // 1. The spinner stopped - the `finally` did its job.
    expect(anySpinner(), isFalse);

    // 2. A sentence a person can read, and one this app wrote.
    expect(find.text(refusal.message), findsOneWidget);

    // 3. Nothing is claimed that did not land.
    expect(find.text('You ate this'), findsNothing);

    // 4. The button works again: a second tap really does try again.
    expect(repository.marks.length, 1);
    await tester.tap(insideOption('b2', find.text('I ate this')));
    await settleWithoutAnimations(tester);
    expect(repository.marks.length, 2);
  });

  testWidgets('every word of a long rationale survives the More disclosure',
      (WidgetTester tester) async {
    const String rationale =
        'Today has more iron in it than last week. Your haemoglobin came back '
        'at 11.8 g/dL, which is just under the usual range, so the plan pairs '
        'iron-rich food with vitamin C in the same meal. The last thing worth '
        'saying is that Thursday dinner stays light, because you told me you '
        'eat late on Thursdays.';

    final _PlanRepository repository =
        _PlanRepository(plan: planWith(rationale: rationale));
    await showPlan(tester, repository);

    // Collapsed: the first sentence carries the point, and the rest is behind
    // "More" rather than gone.
    expect(
      visibleText(tester).contains('Today has more iron in it than last week.'),
      isTrue,
    );
    expect(visibleText(tester).contains('eat late on Thursdays'), isFalse);

    await tester.tap(find.text('More'));
    await tester.pump();

    // Expanded: the whole of it, character for character. This text came from
    // the server and has already been through the safety validator, so it may
    // be re-presented but never shortened or re-worded.
    expect(visibleText(tester).contains(rationale), isTrue);
    expect(find.text('Less'), findsOneWidget);
  });
}

/// The fake, holding one particular plan, with the marking call watched.
///
/// It throws the same [ApiRepositoryException] the real HTTP repository throws,
/// so the screen under test sees exactly what a refused backend call looks like
/// in production - our own sentence, and an [ApiFailure] a caller could branch
/// on - rather than a bare `Exception`.
class _PlanRepository extends FakeHealthRepository {
  _PlanRepository({
    required this.plan,
    this.refusal,
    this.hold = false,
  }) : super(latency: Duration.zero, signedIn: true);

  final MealPlan plan;

  /// What a marking call refuses with, or null when it succeeds.
  final ApiFailure? refusal;

  /// Hold every marking call open until [release] is called, so a second tap
  /// can land inside the window the busy guard exists for.
  final bool hold;

  /// Every call made, as "planId/itemId:state", in the order they were made.
  final List<String> marks = <String>[];

  final Completer<void> _gate = Completer<void>();

  void release() {
    if (!_gate.isCompleted) {
      _gate.complete();
    }
  }

  @override
  Future<MealPlan> loadPlan(DateTime date) async => plan;

  @override
  Future<void> markPlanItem({
    required String planId,
    required String itemId,
    required bool done,
  }) async {
    // Recorded before any refusal, so a test can count attempts and not just
    // successes.
    marks.add('$planId/$itemId:${done ? 'done' : 'skipped'}');
    final ApiFailure? refused = refusal;
    if (refused != null) {
      throw ApiRepositoryException(refused);
    }
    if (hold) {
      await _gate.future;
    }
  }
}

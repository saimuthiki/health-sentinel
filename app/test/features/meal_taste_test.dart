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

/// *Did you enjoy it?* — asked on the plan, answered in one tap, and honest
/// about what the answer did.
///
/// The owner asked for three answers on each thing he ate, stored on the server,
/// and taken into account next time. The server half of that already worked. This
/// is the half that did not exist: the question, the three buttons, and — the
/// part that is easiest to get wrong — saying only what actually happened.
///
/// Two things are load-bearing here and neither is cosmetic:
///
/// **The meal is written down once.** `app/planner/context.py` sums `food_logs`
/// to work out what has been eaten today, so logging the same plate again in
/// order to attach a second opinion would double-count its nutrients and pull
/// the day's gap report — and therefore tomorrow's plan — out of shape.
/// Changing your mind must re-rate the entry that is already there.
///
/// **A plan item with no `food_id` moves nothing.** The backend answers
/// `preference_updated: false`, and the card has to say so. Claiming we learned
/// something about a food that is not in our list is a promise about the future
/// we cannot keep.
void main() {
  MealPlan planWith() {
    return MealPlan(
      id: 'plan-test',
      planDate: DateTime(2026, 9, 10),
      items: const <MealPlanItem>[
        MealPlanItem(
          id: 'b1',
          foodId: 'f_ragi',
          mealSlot: MealSlot.breakfast,
          title: 'Ragi dosa with coconut chutney',
          portion: '2 dosas',
          timeOfDay: '08:30',
          nutrients: <String, double>{'kcal': 412},
        ),
        MealPlanItem(
          id: 'b2',
          // No food id on purpose: this is the case the copy has to be honest
          // about, and the only way to keep it honest is to draw it in a test.
          mealSlot: MealSlot.breakfast,
          title: 'Aunt’s upma, made the way she makes it',
          portion: '1 bowl',
          timeOfDay: '08:30',
          nutrients: <String, double>{'kcal': 290},
        ),
      ],
      dayNutrients: const <String, double>{'kcal': 702},
      targets: const <String, double>{'kcal': 2100},
    );
  }

  Widget planApp(_TasteRepository repository) {
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

  /// Two pumps, never [WidgetTester.pumpAndSettle]: the loading state holds a
  /// spinner that animates for ever, so settling on it would only time out.
  Future<void> showPlan(WidgetTester tester, _TasteRepository repository) async {
    useTallSurface(tester);
    await tester.pumpWidget(planApp(repository));
    await tester.pump();
    await tester.pump();
  }

  Finder option(String itemId) =>
      find.byKey(ValueKey<String>('meal-option-$itemId'));

  Finder insideOption(String itemId, Finder what) =>
      find.descendant(of: option(itemId), matching: what);

  Finder chip(String itemId, TasteStance stance) =>
      find.byKey(ValueKey<String>('taste-$itemId-${stance.name}'));

  Finder note(String itemId) =>
      find.byKey(ValueKey<String>('taste-note-$itemId'));

  bool anySpinner() =>
      find.byType(CircularProgressIndicator).evaluate().isNotEmpty;

  /// Say "I ate this" on [itemId] and let the call land.
  Future<void> eat(WidgetTester tester, String itemId) async {
    await tester.ensureVisible(insideOption(itemId, find.text('I ate this')));
    await tester.tap(insideOption(itemId, find.text('I ate this')));
    await settleWithoutAnimations(tester);
  }

  Future<void> tapTaste(
    WidgetTester tester,
    String itemId,
    TasteStance stance,
  ) async {
    await tester.ensureVisible(chip(itemId, stance));
    await tester.tap(chip(itemId, stance));
    await settleWithoutAnimations(tester);
  }

  testWidgets('the question is not asked until the meal is marked eaten',
      (WidgetTester tester) async {
    final _TasteRepository repository = _TasteRepository(plan: planWith());
    await showPlan(tester, repository);

    // Nothing has been said about eating anything, so there is nothing to have
    // an opinion about. Asking anyway would be asking about a hypothetical.
    expect(find.text('Did you enjoy it?'), findsNothing);
    expect(chip('b1', TasteStance.loved), findsNothing);

    await eat(tester, 'b1');

    // It appears inside that option's own card, under the confirmation — not in
    // a dialog, and not on the other option, which was not eaten.
    expect(insideOption('b1', find.text('You ate this')), findsOneWidget);
    expect(
      insideOption('b1', find.text('Did you enjoy it?')),
      findsOneWidget,
    );
    expect(find.text('Did you enjoy it?'), findsOneWidget);
    for (final TasteStance stance in TasteStance.values) {
      expect(insideOption('b1', chip('b1', stance)), findsOneWidget);
    }
    expect(chip('b2', TasteStance.loved), findsNothing);

    // And nothing has been asserted about taste yet.
    expect(note('b1'), findsNothing);
    expect(repository.rated, isEmpty);
  });

  testWidgets('"Loved it" logs the meal once, rates it 5, and says what that did',
      (WidgetTester tester) async {
    final _TasteRepository repository = _TasteRepository(plan: planWith());
    await showPlan(tester, repository);
    await eat(tester, 'b1');

    await tapTaste(tester, 'b1', TasteStance.loved);

    // One entry in the diary, carrying the food the planner selects on.
    expect(repository.logged, <String>['f_ragi/Ragi dosa with coconut chutney']);
    // 5 and not 4: `app/ai/context.py` keeps only the highest-scoring likes and
    // `rank_foods` scales its bonus by score/5, so 5 is what survives the cap.
    expect(repository.rated, <String>['log-1:5']);

    // A plan claim, and only a plan claim. Nothing about health.
    expect(
      insideOption('b1', find.text('We will suggest this more often.')),
      findsOneWidget,
    );
    expect(note('b1'), findsOneWidget);
    expect(anySpinner(), isFalse);
  });

  // 1 / 3 / 5, never 2 or 4, written out as literals rather than read off the
  // enum — the point is to pin the three numbers, and a test that asked the enum
  // what it holds would agree with any answer it gave.
  //
  // A 2 is recorded as a dislike and, before the boundary was moved, was offered
  // again anyway; a 4 is a like, but the one `app/ai/context.py` trims first out
  // of the prompt; 3 is the only rating that is genuinely neutral.
  //
  // One `testWidgets` per answer, not one loop inside a single test: pumping a
  // second plan into the same tree reuses `_SlotSection`'s state, and the second
  // case would then be running against the first case's answers.
  const Map<TasteStance, String> sends = <TasteStance, String>{
    TasteStance.loved: 'log-1:5',
    TasteStance.okay: 'log-1:3',
    TasteStance.disliked: 'log-1:1',
  };
  sends.forEach((TasteStance stance, String expected) {
    testWidgets('"${stance.label}" sends ${stance.rating} and says what it did',
        (WidgetTester tester) async {
      final _TasteRepository repository = _TasteRepository(plan: planWith());
      await showPlan(tester, repository);
      await eat(tester, 'b1');
      await tapTaste(tester, 'b1', stance);

      expect(repository.rated, <String>[expected]);
      expect(insideOption('b1', find.text(stance.effect)), findsOneWidget);
    });
  });

  testWidgets('changing the answer re-rates the same entry, it does not log again',
      (WidgetTester tester) async {
    final _TasteRepository repository = _TasteRepository(plan: planWith());
    await showPlan(tester, repository);
    await eat(tester, 'b1');

    await tapTaste(tester, 'b1', TasteStance.disliked);
    await tapTaste(tester, 'b1', TasteStance.loved);
    await tapTaste(tester, 'b1', TasteStance.okay);

    // Three opinions, one meal. A second food_logs row for the same plate would
    // be counted again by `_intake_today` and would corrupt the gap report.
    expect(repository.logged.length, 1);
    expect(repository.rated, <String>['log-1:1', 'log-1:5', 'log-1:3']);

    // And the card shows the last one, not the first.
    expect(
      insideOption('b1', find.text(TasteStance.okay.effect)),
      findsOneWidget,
    );
    expect(
      find.text(TasteStance.disliked.effect),
      findsNothing,
      reason: 'a superseded answer is still on screen',
    );
  });

  testWidgets('a meal with no food behind it says so instead of claiming a lesson',
      (WidgetTester tester) async {
    final _TasteRepository repository = _TasteRepository(plan: planWith());
    await showPlan(tester, repository);
    await eat(tester, 'b2');

    await tapTaste(tester, 'b2', TasteStance.loved);

    // It was logged and rated — that is a fact about the day and it is kept.
    expect(repository.logged, <String>[
      'null/Aunt’s upma, made the way she makes it',
    ]);
    expect(repository.rated, <String>['log-1:5']);

    // But nothing the planner reads moved, so nothing is promised.
    expect(
      insideOption(
        'b2',
        find.textContaining('not in our food list yet'),
      ),
      findsOneWidget,
    );
    expect(
      find.text('We will suggest this more often.'),
      findsNothing,
      reason: 'the card claimed a preference moved when the reply said it did '
          'not',
    );
  });

  testWidgets('a second answer while the first is in flight does not post twice',
      (WidgetTester tester) async {
    // Held on a Completer. The fake settles in a microtask and awaiting a tap
    // flushes microtasks, so a call left to settle on its own would already
    // have finished before the "second" tap and this would prove nothing.
    final _TasteRepository repository = _TasteRepository(plan: planWith());
    await showPlan(tester, repository);
    await eat(tester, 'b1');

    repository.hold = true;
    await tester.ensureVisible(chip('b1', TasteStance.loved));
    await tester.tap(chip('b1', TasteStance.loved));
    await tester.pump();

    // Genuinely mid-flight: the meal was logged, the rating is open.
    expect(repository.logged.length, 1);
    expect(repository.rated, <String>['log-1:5']);
    expect(
      find.descendant(
        of: chip('b1', TasteStance.loved),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );

    // Neither the same chip nor a different one may reach the repository.
    await tester.tap(chip('b1', TasteStance.loved));
    await tester.pump();
    await tester.tap(chip('b1', TasteStance.disliked));
    await tester.pump();
    expect(repository.rated, <String>['log-1:5']);

    // Nor may the meal be un-marked underneath the answer: the taste question
    // shares the card's busy guard, which is the whole reason it has one.
    await tester.tap(insideOption('b1', find.text('Undo')));
    await tester.pump();
    expect(repository.marks, <String>['plan-test/b1:done']);

    repository.release();
    await settleWithoutAnimations(tester);

    expect(repository.rated, <String>['log-1:5']);
    expect(anySpinner(), isFalse, reason: 'the busy state outlived the call');
    expect(note('b1'), findsOneWidget);
  });

  testWidgets('a refused rating stops the spinner, says why, claims nothing, retries',
      (WidgetTester tester) async {
    const ApiFailure refusal = ApiFailure(ApiFailureKind.wakingUpTimedOut);
    final _TasteRepository repository =
        _TasteRepository(plan: planWith(), refuseRating: refusal);
    await showPlan(tester, repository);
    await eat(tester, 'b1');

    await tapTaste(tester, 'b1', TasteStance.loved);

    // 1. The spinner stopped — the `finally` did its job.
    expect(anySpinner(), isFalse);
    // 2. A sentence a person can read, and one this app wrote.
    expect(find.text(refusal.message), findsOneWidget);
    // 3. Nothing is claimed that did not land.
    expect(note('b1'), findsNothing);
    expect(find.text('We will suggest this more often.'), findsNothing);

    // 4. The meal is still marked eaten. A refused opinion is not a reason to
    //    throw away the fact that was already recorded.
    expect(insideOption('b1', find.text('You ate this')), findsOneWidget);

    // 5. It can be tried again — and still does not log the meal a second time,
    //    because the entry was made before the rating failed.
    repository.refuseRating = null;
    await tapTaste(tester, 'b1', TasteStance.loved);
    expect(repository.logged.length, 1);
    expect(repository.rated, <String>['log-1:5', 'log-1:5']);
    expect(note('b1'), findsOneWidget);
  });
}

/// The fake, holding one plan, with every write watched.
///
/// It throws the same [ApiRepositoryException] the real HTTP repository throws,
/// so the screen sees what a refused backend call looks like in production.
///
/// [logMeal] and [rateMeal] are overridden rather than inherited so the test can
/// see the *order* of the calls. The inherited behaviour is still what decides
/// whether a preference moved: an item with no `foodId` answers
/// `preferenceUpdated: false`, exactly as the endpoint does.
class _TasteRepository extends FakeHealthRepository {
  _TasteRepository({required this.plan, this.refuseRating})
      : super(latency: Duration.zero, signedIn: true);

  final MealPlan plan;

  /// What a rating refuses with, or null when it succeeds. Settable, so one
  /// test can prove a retry after a refusal.
  ApiFailure? refuseRating;

  /// Hold every rating open until [release], so a second tap can land inside
  /// the window the busy guard exists for.
  bool hold = false;

  /// "foodId/freeText" for each meal written down, in order.
  final List<String> logged = <String>[];

  /// "foodLogId:rating" for each rating sent, in order.
  final List<String> rated = <String>[];

  /// "planId/itemId:state" for each mark, in order.
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
    marks.add('$planId/$itemId:${done ? 'done' : 'skipped'}');
  }

  @override
  Future<String> logMeal({
    MealSlot? mealSlot,
    String? foodId,
    String? freeText,
    String source = 'manual',
  }) async {
    logged.add('$foodId/$freeText');
    return super.logMeal(
      mealSlot: mealSlot,
      foodId: foodId,
      freeText: freeText,
      source: source,
    );
  }

  @override
  Future<MealRating> rateMeal({
    required String foodLogId,
    required int rating,
  }) async {
    // Recorded before any refusal, so a test can count attempts and not only
    // successes.
    rated.add('$foodLogId:$rating');
    final ApiFailure? refused = refuseRating;
    if (refused != null) {
      throw ApiRepositoryException(refused);
    }
    if (hold) {
      await _gate.future;
    }
    return super.rateMeal(foodLogId: foodLogId, rating: rating);
  }
}

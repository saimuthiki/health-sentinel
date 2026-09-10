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
import 'package:healthpulse/features/tastes/tastes_screen.dart';

import '_onboarding_harness.dart';

/// The screen that makes the learning visible.
///
/// The planner drops a disliked food silently — it simply stops appearing — so
/// without this list the only evidence that anything was learned is a plan that
/// quietly changed. That is the worst of both: somebody who cannot tell whether
/// the app is listening, and cannot correct it when it has misheard. Every test
/// here is one part of "he can see it, and he can change it in one tap".
void main() {
  Widget tastesApp(_TastesRepository repository) {
    return ProviderScope(
      overrides: <Override>[
        healthRepositoryProvider.overrideWithValue(repository),
      ],
      child: MaterialApp(
        theme: HpTheme.light(),
        home: const TastesScreen(),
      ),
    );
  }

  /// Two pumps, never [WidgetTester.pumpAndSettle]: the loading state holds a
  /// spinner that animates for ever.
  Future<void> show(WidgetTester tester, _TastesRepository repository) async {
    useTallSurface(tester);
    await tester.pumpWidget(tastesApp(repository));
    await tester.pump();
    await tester.pump();
  }

  Finder row(String foodId) =>
      find.byKey(ValueKey<String>('taste-row-$foodId'));

  Finder chip(String foodId, TasteStance stance) =>
      find.byKey(ValueKey<String>('taste-$foodId-${stance.name}'));

  Finder insideRow(String foodId, Finder what) =>
      find.descendant(of: row(foodId), matching: what);

  Future<void> tapTaste(
    WidgetTester tester,
    String foodId,
    TasteStance stance,
  ) async {
    await tester.ensureVisible(chip(foodId, stance));
    await tester.tap(chip(foodId, stance));
    await settleWithoutAnimations(tester);
  }

  testWidgets('every belief is listed by name, with what it does to the plan',
      (WidgetTester tester) async {
    final _TastesRepository repository = _TastesRepository();
    await show(tester, repository);

    // Names, never ids. A list of uuids is a list nobody can correct.
    expect(find.text('Ragi (finger millet)'), findsOneWidget);
    expect(find.text('Roasted chana'), findsOneWidget);
    expect(find.text('f_ragi'), findsNothing);

    // What each belief does, said as a plan claim. Never a health claim.
    expect(
      insideRow('f_ragi', find.text(TasteStance.loved.effect)),
      findsOneWidget,
    );
    expect(
      insideRow('f_chana', find.text(TasteStance.disliked.effect)),
      findsOneWidget,
    );

    // All three answers on every row, so correcting one is a single tap and
    // never a menu.
    for (final TasteStance stance in TasteStance.values) {
      expect(insideRow('f_ragi', chip('f_ragi', stance)), findsOneWidget);
    }
  });

  testWidgets('the stored answer is the one carrying the tick',
      (WidgetTester tester) async {
    final _TastesRepository repository = _TastesRepository();
    await show(tester, repository);

    // Checked through the tick and not the fill, because the tick is the part
    // that has to be there: selection carried by colour alone fails the person
    // who cannot separate those two colours, and it fails a screenshot in
    // greyscale. Shape, not only colour.
    Finder tick(String foodId, TasteStance stance) => find.descendant(
          of: chip(foodId, stance),
          matching: find.byIcon(Icons.check_rounded),
        );

    expect(tick('f_ragi', TasteStance.loved), findsOneWidget);
    expect(tick('f_ragi', TasteStance.okay), findsNothing);
    expect(tick('f_ragi', TasteStance.disliked), findsNothing);
    expect(tick('f_chana', TasteStance.disliked), findsOneWidget);

    // And it moves when the answer moves.
    await tapTaste(tester, 'f_ragi', TasteStance.disliked);
    expect(tick('f_ragi', TasteStance.disliked), findsOneWidget);
    expect(tick('f_ragi', TasteStance.loved), findsNothing);
  });

  testWidgets('one tap corrects one row and leaves the others alone',
      (WidgetTester tester) async {
    final _TastesRepository repository = _TastesRepository();
    await show(tester, repository);

    await tapTaste(tester, 'f_ragi', TasteStance.okay);

    // The correction goes to the preferences endpoint, not to the food diary:
    // changing your mind about ragi is not the same as eating ragi, and logging
    // one would add a portion of it to today's intake.
    expect(repository.corrections, <String>['f_ragi:okay']);
    expect(repository.logged, isEmpty);

    // The row now says what it now believes.
    expect(
      insideRow('f_ragi', find.text(TasteStance.okay.effect)),
      findsOneWidget,
    );
    // And the row nobody touched is untouched.
    expect(
      insideRow('f_chana', find.text(TasteStance.disliked.effect)),
      findsOneWidget,
    );
  });

  testWidgets('"It was okay" is how a belief is forgotten — there is no delete',
      (WidgetTester tester) async {
    final _TastesRepository repository = _TastesRepository();
    await show(tester, repository);

    await tapTaste(tester, 'f_chana', TasteStance.okay);

    // 3, which is neutral: the planner's filter does not act on it and its
    // ranking gives it nothing. A real "forget I said anything", and reached by
    // the same three buttons rather than by a fourth control.
    expect(repository.corrections, <String>['f_chana:okay']);
    expect(
      insideRow('f_chana', find.text('Noted. This will not change what we '
          'suggest.')),
      findsOneWidget,
    );

    // Nothing offers to delete the row, because nothing needs to.
    expect(find.textContaining('Delete'), findsNothing);
    expect(find.textContaining('Remove'), findsNothing);
  });

  testWidgets('a second tap while the first is in flight does not send twice',
      (WidgetTester tester) async {
    // Held on a Completer: the fake settles in a microtask and awaiting a tap
    // flushes microtasks, so a call left to settle would already be done.
    final _TastesRepository repository = _TastesRepository(hold: true);
    await show(tester, repository);

    await tester.ensureVisible(chip('f_ragi', TasteStance.okay));
    await tester.tap(chip('f_ragi', TasteStance.okay));
    await tester.pump();

    expect(repository.corrections, <String>['f_ragi:okay']);
    // The spinner sits on the chip that was pressed, not on the one that
    // happens to be selected.
    expect(
      find.descendant(
        of: chip('f_ragi', TasteStance.okay),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );

    await tester.tap(chip('f_ragi', TasteStance.disliked));
    await tester.pump();
    await tester.tap(chip('f_ragi', TasteStance.okay));
    await tester.pump();
    expect(repository.corrections, <String>['f_ragi:okay']);

    // A different row is its own call and its own guard, so a slow correction
    // never holds up the next one.
    await tester.tap(chip('f_chana', TasteStance.loved));
    await tester.pump();
    expect(repository.corrections, <String>['f_ragi:okay', 'f_chana:loved']);

    repository.release();
    await settleWithoutAnimations(tester);
    expect(
      find.byType(CircularProgressIndicator),
      findsNothing,
      reason: 'the busy state outlived the call',
    );
  });

  testWidgets('a refused correction says why on its own row, and can be retried',
      (WidgetTester tester) async {
    const ApiFailure refusal = ApiFailure(ApiFailureKind.wakingUpTimedOut);
    final _TastesRepository repository =
        _TastesRepository(refusal: refusal);
    await show(tester, repository);

    await tapTaste(tester, 'f_ragi', TasteStance.disliked);

    // The spinner stopped, and the sentence is one this app wrote.
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(insideRow('f_ragi', find.text(refusal.message)), findsOneWidget);

    // It belongs to the row it happened on. One refused correction is not a
    // reason to put a red line across a list that is otherwise fine.
    expect(insideRow('f_chana', find.text(refusal.message)), findsNothing);

    // Nothing is claimed that did not land: the row still shows what the
    // server last confirmed.
    expect(
      insideRow('f_ragi', find.text(TasteStance.loved.effect)),
      findsOneWidget,
    );

    // And it can be tried again.
    repository.refusal = null;
    await tapTaste(tester, 'f_ragi', TasteStance.disliked);
    expect(repository.corrections.length, 2);
    expect(
      insideRow('f_ragi', find.text(TasteStance.disliked.effect)),
      findsOneWidget,
    );
    expect(find.text(refusal.message), findsNothing);
  });

  testWidgets('nothing learned yet says which kind of empty it is',
      (WidgetTester tester) async {
    final _TastesRepository repository = _TastesRepository(empty: true);
    await show(tester, repository);

    expect(find.text('Nothing learned yet'), findsOneWidget);
    // It says where the answers come from, so an empty list reads as "we have
    // not asked you yet" rather than as something that failed to load.
    expect(find.textContaining('mark a meal as eaten'), findsOneWidget);
    expect(row('f_ragi'), findsNothing);
  });

  testWidgets('a list that will not load offers a retry and blames nothing on the user',
      (WidgetTester tester) async {
    const ApiFailure refusal = ApiFailure(ApiFailureKind.wakingUpTimedOut);
    final _TastesRepository repository =
        _TastesRepository(loadRefusal: refusal);
    await show(tester, repository);

    expect(find.text('That list could not be loaded'), findsOneWidget);
    expect(find.text(refusal.message), findsOneWidget);

    // The retry works: a list that came back on the second attempt is drawn.
    repository.loadRefusal = null;
    await tester.tap(find.text('Try again'));
    await settleWithoutAnimations(tester);
    expect(find.text('Ragi (finger millet)'), findsOneWidget);
  });
}

/// The fake, with every preference write watched.
///
/// It extends [FakeHealthRepository] so the seeded beliefs, the food names and
/// the stance arithmetic are the real ones rather than a second copy written for
/// this file — and so a method this test forgets to think about behaves the way
/// the rest of the app already sees it behave.
class _TastesRepository extends FakeHealthRepository {
  _TastesRepository({
    this.refusal,
    this.loadRefusal,
    this.hold = false,
    bool empty = false,
  }) : super(latency: Duration.zero, signedIn: true) {
    if (empty) {
      foodPreferences.clear();
    }
  }

  /// What a correction refuses with, or null. Settable, so a retry can be
  /// proved after a refusal.
  ApiFailure? refusal;

  /// What the list read refuses with, or null. Settable for the same reason.
  ApiFailure? loadRefusal;

  /// Hold every correction open until [release].
  final bool hold;

  /// "foodId:stance" for each correction sent, in order.
  final List<String> corrections = <String>[];

  /// Any meal written down. Must stay empty: a correction is not a meal.
  final List<String> logged = <String>[];

  final Completer<void> _gate = Completer<void>();

  void release() {
    if (!_gate.isCompleted) {
      _gate.complete();
    }
  }

  @override
  Future<List<FoodPreference>> loadFoodPreferences() async {
    final ApiFailure? refused = loadRefusal;
    if (refused != null) {
      throw ApiRepositoryException(refused);
    }
    return super.loadFoodPreferences();
  }

  @override
  Future<String> logMeal({
    MealSlot? mealSlot,
    String? foodId,
    String? freeText,
    String source = 'manual',
  }) async {
    logged.add(foodId ?? '(no food)');
    return super.logMeal(
      mealSlot: mealSlot,
      foodId: foodId,
      freeText: freeText,
      source: source,
    );
  }

  @override
  Future<FoodPreference> setFoodPreference({
    required String foodId,
    required TasteStance stance,
  }) async {
    // Recorded before any refusal, so a test can count attempts and not only
    // successes.
    corrections.add('$foodId:${stance.name}');
    final ApiFailure? refused = refusal;
    if (refused != null) {
      throw ApiRepositoryException(refused);
    }
    if (hold) {
      await _gate.future;
    }
    return super.setFoodPreference(foodId: foodId, stance: stance);
  }
}

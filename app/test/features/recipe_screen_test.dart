import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:healthpulse/core/theme/hp_theme.dart';
import 'package:healthpulse/core/widgets/widgets.dart';
import 'package:healthpulse/data/api/api_failure.dart';
import 'package:healthpulse/data/repository/health_repository.dart';
import 'package:healthpulse/features/recipes/recipe_screen.dart';
import 'package:healthpulse/features/recipes/recipe_service.dart';

/// The recipe screen: how to make one meal of a plan, and how much to have.
///
/// The owner asked for both halves in one sentence, and they come from opposite
/// places, so most of these tests are about keeping them apart:
///
/// * the **amount** is the plan's, printed by the backend from the stored row
///   its nutrition was computed from, and it is the only quantity on the screen;
/// * the **method** carries no amounts at all, so there is nothing on this
///   screen that can disagree with the Plan tab.
///
/// And the case the owner named himself: sunflower seeds need buying, not
/// cooking, and that is an answer rather than an empty screen.
void main() {
  // ------------------------------------------------------------- a real dish

  testWidgets('a dish shows its ingredients and numbered steps',
      (WidgetTester tester) async {
    useTallSurface(tester);

    await tester.pumpWidget(recipeApp(_FakeRecipeService()));
    await settleWithoutAnimations(tester);

    expect(find.text('What goes in'), findsOneWidget);
    expect(find.text('Rajma'), findsWidgets);
    expect(find.text('How to make it'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(
      find.text('Soak the rajma overnight in plenty of water.'),
      findsOneWidget,
    );
    expect(find.textContaining('about 45 minutes'), findsOneWidget);
  });

  testWidgets('the only quantity on the screen is the plan’s own',
      (WidgetTester tester) async {
    useTallSurface(tester);

    await tester.pumpWidget(recipeApp(_FakeRecipeService()));
    await settleWithoutAnimations(tester);

    // The portion, from the plan row.
    expect(find.text('Your portion: 150 g of rajma.'), findsOneWidget);
    // And the sentence that stops it being read as the recipe's own amount.
    expect(find.textContaining('no weights of its own'), findsOneWidget);
    // The ingredients say so too, so a reader who expected amounts knows at
    // once that their absence is deliberate.
    expect(find.text('names only'), findsOneWidget);
  });

  testWidgets('the request carries the item and the date and no quantity',
      (WidgetTester tester) async {
    useTallSurface(tester);
    final _FakeRecipeService service = _FakeRecipeService();

    await tester.pumpWidget(recipeApp(service));
    await settleWithoutAnimations(tester);

    expect(service.asked, <String>['mpi-1@2026-09-07']);
  });

  // ------------------------------------------------------ nothing to make

  testWidgets('sunflower seeds say there is nothing to make, and still say how much',
      (WidgetTester tester) async {
    useTallSurface(tester);

    await tester.pumpWidget(recipeApp(_FakeRecipeService(kind: _Kind.readyToEat)));
    await settleWithoutAnimations(tester);

    expect(find.textContaining('eaten as it comes'), findsOneWidget);
    // The half of the question that always has an answer.
    expect(find.text('Your portion: 30 g of sunflower seed.'), findsOneWidget);
    // No empty method headings, and nothing to write again for a packet: a
    // button that regenerates the recipe for a handful of seeds would do
    // nothing at all.
    expect(find.text('How to make it'), findsNothing);
    expect(find.widgetWithText(HpButton, 'Try writing it again'), findsNothing);
    expect(find.widgetWithText(HpButton, 'Write the method again'), findsNothing);
  });

  testWidgets('an oil says it belongs inside something else',
      (WidgetTester tester) async {
    useTallSurface(tester);

    await tester.pumpWidget(recipeApp(_FakeRecipeService(kind: _Kind.ingredient)));
    await settleWithoutAnimations(tester);

    expect(find.textContaining('ingredient rather than a dish'), findsOneWidget);
    expect(find.text('How to make it'), findsNothing);
  });

  testWidgets('a method we do not have is said out loud, with a way to ask again',
      (WidgetTester tester) async {
    useTallSurface(tester);

    await tester.pumpWidget(recipeApp(_FakeRecipeService(kind: _Kind.noMethod)));
    await settleWithoutAnimations(tester);

    // A heading over an empty list would read as a bug. A sentence does not.
    expect(find.textContaining('do not have a method for this one yet'),
        findsOneWidget);
    expect(find.text('How to make it'), findsNothing);
    expect(
      find.widgetWithText(HpButton, 'Try writing it again'),
      findsOneWidget,
    );
  });

  // ------------------------------------------------------------ writing again

  testWidgets('writing the method again replaces it',
      (WidgetTester tester) async {
    useTallSurface(tester);
    final _FakeRecipeService service = _FakeRecipeService();

    await tester.pumpWidget(recipeApp(service));
    await settleWithoutAnimations(tester);

    final Finder button =
        find.widgetWithText(HpButton, 'Write the method again');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await settleWithoutAnimations(tester);

    expect(service.refreshes, 1);
    expect(find.textContaining('Rinse the rajma and start again.'),
        findsOneWidget);
  });

  testWidgets('a second tap while the first is in flight sends nothing',
      (WidgetTester tester) async {
    useTallSurface(tester);
    // Held on a Completer: the fake otherwise settles in a microtask, and
    // awaiting the tap would flush it before the second one landed.
    final _FakeRecipeService service = _FakeRecipeService(holdRefresh: true);

    await tester.pumpWidget(recipeApp(service));
    await settleWithoutAnimations(tester);

    final Finder button =
        find.widgetWithText(HpButton, 'Write the method again');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pump();
    expect(service.refreshes, 1);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.tap(button, warnIfMissed: false);
    await tester.pump();
    expect(
      service.refreshes,
      1,
      reason: 'a second tap asked for the same method twice',
    );

    service.releaseRefresh();
    await settleWithoutAnimations(tester);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('a refused rewrite leaves the method alone and says which refusal',
      (WidgetTester tester) async {
    useTallSurface(tester);
    final _FakeRecipeService service = _FakeRecipeService(refuseRefresh: true);

    await tester.pumpWidget(recipeApp(service));
    await settleWithoutAnimations(tester);

    final Finder button =
        find.widgetWithText(HpButton, 'Write the method again');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await settleWithoutAnimations(tester);

    expect(find.text(refusalMessage), findsOneWidget);
    // The method that was on screen is still on screen.
    expect(
      find.text('Soak the rajma overnight in plenty of water.'),
      findsOneWidget,
    );
    // The flag was cleared in the `finally`, so it can be tried again.
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.tap(button);
    await settleWithoutAnimations(tester);
    expect(service.refreshes, 2);
  });

  // --------------------------------------------------------------- first fetch

  testWidgets('a failed fetch offers a way back in', (WidgetTester tester) async {
    useTallSurface(tester);
    final _FakeRecipeService service = _FakeRecipeService(refuseLoad: true);

    await tester.pumpWidget(recipeApp(service));
    await settleWithoutAnimations(tester);

    expect(find.text('We could not fetch this recipe'), findsOneWidget);
    expect(find.text(refusalMessage), findsOneWidget);

    service.refuseLoad = false;
    await tester.tap(find.widgetWithText(HpButton, 'Try again'));
    await settleWithoutAnimations(tester);
    expect(find.text('How to make it'), findsOneWidget);
  });

  testWidgets('a build with no backend says so instead of spinning',
      (WidgetTester tester) async {
    useTallSurface(tester);

    await tester.pumpWidget(recipeApp(null));
    await settleWithoutAnimations(tester);

    expect(find.text('We could not fetch this recipe'), findsOneWidget);
    expect(find.textContaining('no backend to ask'), findsOneWidget);
  });

  // ------------------------------------------------------------------ parsing

  test('a recipe parses out of the wire shape the backend sends', () {
    final Recipe recipe = Recipe.fromJson(rajmaJson);
    expect(recipe.preparation, RecipePreparation.method);
    expect(recipe.hasMethod, isTrue);
    expect(recipe.portionGrams, 150);
    expect(recipe.prepMinutes, 45);
    expect(recipe.stored, isFalse);
  });

  test('an item that needs no preparation parses as one', () {
    final Recipe recipe = Recipe.fromJson(seedsJson);
    expect(recipe.preparation, RecipePreparation.none);
    expect(recipe.hasMethod, isFalse);
    expect(recipe.note, isNotNull);
  });

  test('an unknown preparation is read as a dish rather than as nothing to do',
      () {
    // The safe direction: a method offered for something that needs none is a
    // wasted screen, but nothing hidden.
    expect(RecipePreparation.fromWire('something new'),
        RecipePreparation.method);
  });
}

// ------------------------------------------------------------------- harness

final String refusalMessage =
    const ApiFailure(ApiFailureKind.wakingUpTimedOut).message;

final DateTime planDate = DateTime(2026, 9, 7);

const Map<String, dynamic> rajmaJson = <String, dynamic>{
  'item_id': 'mpi-1',
  'plan_date': '2026-09-07',
  'food_id': 'f-rajma',
  'display_name': 'Rajma',
  'portion_grams': 150.0,
  'portion_line': 'Your portion: 150 g of rajma.',
  'amounts_note': 'The amount above is your plan’s. The method is a method — it '
      'deliberately carries no weights of its own.',
  'preparation': 'method',
  'note': null,
  'ingredients': <String>['Rajma', 'Onion', 'Tomato'],
  'steps': <String>[
    'Soak the rajma overnight in plenty of water.',
    'Drain it, cover with fresh water and pressure cook until soft.',
  ],
  'prep_minutes': 45,
  'stored': false,
  'generated': true,
};

const Map<String, dynamic> seedsJson = <String, dynamic>{
  'item_id': 'mpi-1',
  'plan_date': '2026-09-07',
  'food_id': 'f-sunflower',
  'display_name': 'Sunflower seed',
  'portion_grams': 30.0,
  'portion_line': 'Your portion: 30 g of sunflower seed.',
  'amounts_note': 'The amount above is your plan’s.',
  'preparation': 'none',
  'note': 'Nothing to make here. This is eaten as it comes — pick it up at the '
      'shop, measure out your portion, and that is the whole job.',
  'ingredients': <String>[],
  'steps': <String>[],
  'prep_minutes': null,
  'stored': false,
  'generated': false,
};

const Map<String, dynamic> oilJson = <String, dynamic>{
  'item_id': 'mpi-1',
  'plan_date': '2026-09-07',
  'food_id': 'f-oil',
  'display_name': 'Groundnut oil',
  'portion_grams': 5.0,
  'portion_line': 'Your portion: 5 g of groundnut oil.',
  'amounts_note': 'The amount above is your plan’s.',
  'preparation': 'ingredient',
  'note': 'This one is a cooking ingredient rather than a dish. It belongs '
      'inside whatever you are making that day.',
  'ingredients': <String>[],
  'steps': <String>[],
  'prep_minutes': null,
  'stored': false,
  'generated': false,
};

const Map<String, dynamic> noMethodJson = <String, dynamic>{
  'item_id': 'mpi-1',
  'plan_date': '2026-09-07',
  'food_id': 'f-rajma',
  'display_name': 'Rajma',
  'portion_grams': 150.0,
  'portion_line': 'Your portion: 150 g of rajma.',
  'amounts_note': 'The amount above is your plan’s.',
  'preparation': 'method',
  'note': 'We do not have a method for this one yet. Nothing was made up to '
      'fill the gap.',
  'ingredients': <String>[],
  'steps': <String>[],
  'prep_minutes': null,
  'stored': false,
  'generated': false,
};

enum _Kind { dish, readyToEat, ingredient, noMethod }

/// A recipe service that answers from fixtures and records what it was asked.
class _FakeRecipeService implements RecipeService {
  _FakeRecipeService({
    this.kind = _Kind.dish,
    this.refuseLoad = false,
    this.refuseRefresh = false,
    this.holdRefresh = false,
  });

  final _Kind kind;
  bool refuseLoad;
  final bool refuseRefresh;
  final bool holdRefresh;

  /// Every call, as `itemId@date`. Nothing else travels, and in particular no
  /// quantity does.
  final List<String> asked = <String>[];
  int refreshes = 0;

  Completer<void>? _held;

  void releaseRefresh() {
    _held?.complete();
    _held = null;
  }

  @override
  Future<Recipe> load({required String itemId, required DateTime on}) async {
    asked.add('$itemId@${on.toIso8601String().split('T').first}');
    if (refuseLoad) {
      throw HealthRepositoryException(refusalMessage);
    }
    return Recipe.fromJson(_body());
  }

  @override
  Future<Recipe> refresh({required String itemId, required DateTime on}) async {
    refreshes += 1;
    if (holdRefresh) {
      final Completer<void> gate = Completer<void>();
      _held = gate;
      await gate.future;
    }
    if (refuseRefresh) {
      throw HealthRepositoryException(refusalMessage);
    }
    return Recipe.fromJson(<String, dynamic>{
      ..._body(),
      'steps': <String>['Rinse the rajma and start again.'],
      'stored': false,
    });
  }

  Map<String, dynamic> _body() {
    switch (kind) {
      case _Kind.dish:
        return rajmaJson;
      case _Kind.readyToEat:
        return seedsJson;
      case _Kind.ingredient:
        return oilJson;
      case _Kind.noMethod:
        return noMethodJson;
    }
  }
}

/// The screen, wired to [service].
///
/// A plain [MaterialApp] rather than a router: the only route this screen knows
/// about is the way back to the plan, and it is not tapped here. `null` stands
/// for a build with no backend address.
Widget recipeApp(RecipeService? service) {
  return ProviderScope(
    overrides: <Override>[
      recipeServiceProvider.overrideWithValue(service),
    ],
    child: MaterialApp(
      theme: HpTheme.light(),
      home: RecipeScreen(itemId: 'mpi-1', planDate: planDate),
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
Future<void> settleWithoutAnimations(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 32));
  await tester.pump();
}

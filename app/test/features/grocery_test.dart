import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:healthpulse/core/theme/hp_theme.dart';
import 'package:healthpulse/core/widgets/widgets.dart';
import 'package:healthpulse/data/api/api_failure.dart';
import 'package:healthpulse/data/models/models.dart';
import 'package:healthpulse/data/providers.dart';
import 'package:healthpulse/data/repository/fake_health_repository.dart';
import 'package:healthpulse/data/repository/http_health_repository.dart';
import 'package:healthpulse/features/grocery/grocery_screen.dart';

/// The grocery screen: the week's shopping, and a tick box per line.
///
/// The behaviours worth protecting, and why each one is here:
///
/// * the list arrives grouped into aisles, with the backend's column values
///   turned into English rather than shown raw;
/// * a line says both numbers — what is already at home and what is left to
///   bring — and ticking one moves the weight from the second to the first;
/// * ticking a line reaches the backend as that line and that state;
/// * a refused tick leaves the box showing what the backend actually holds,
///   says why on that line and nowhere else, and leaves no spinner running;
/// * a second tap while the first is in flight sends nothing;
/// * an empty list says which kind of empty it is, from the count of planned
///   days the backend sends rather than by hedging.
void main() {
  group('the week’s list', () {
    testWidgets('arrives grouped into aisles, with readable headings',
        (WidgetTester tester) async {
      useTallSurface(tester);

      await tester.pumpWidget(groceryApp(_GroceryRepository()));
      await settleWithoutAnimations(tester);

      // The backend sends `food_group` values. None of them should reach a
      // person's eyes.
      expect(find.text('Cereals and millets'), findsOneWidget);
      expect(find.text('Pulses and legumes'), findsOneWidget);
      expect(find.text('Leafy vegetables'), findsOneWidget);
      expect(find.text('cereal_millet'), findsNothing);
      expect(find.text('leafy_vegetable'), findsNothing);

      expect(find.text('Ragi flour'), findsOneWidget);
      expect(find.text('Kidney beans'), findsOneWidget);
      expect(find.text('Spinach'), findsOneWidget);

      // The amount and where the line stands, on one line.
      expect(find.text('616 g · Still to buy'), findsOneWidget);
      // Past a thousand grams, kilograms.
      expect(find.text('1.2 kg · Still to buy'), findsOneWidget);
      // A line the kitchen partly covers says both halves of it, which is the
      // whole point of the pantry: 839 g needed, 300 g of it already there.
      expect(find.text('300 g at home · bring 539 g'), findsOneWidget);
      // And one it covers entirely says there is nothing to bring — while
      // staying on the list, so it can be unticked.
      expect(find.text('770 g at home · nothing to bring'), findsOneWidget);
      // What the backend already holds is what is ticked.
      expect(checkboxFor(tester, 'Spinach').value, isTrue);
      expect(checkboxFor(tester, 'Ragi flour').value, isFalse);
    });

    testWidgets('says how much of it is still to bring home',
        (WidgetTester tester) async {
      useTallSurface(tester);

      await tester.pumpWidget(groceryApp(_GroceryRepository()));
      await settleWithoutAnimations(tester);

      expect(find.text('3 of 4 still to bring home.'), findsOneWidget);
    });
  });

  group('ticking a line', () {
    testWidgets('sends that item, with have', (WidgetTester tester) async {
      useTallSurface(tester);
      final _GroceryRepository repository = _GroceryRepository();

      await tester.pumpWidget(groceryApp(repository));
      await settleWithoutAnimations(tester);

      await tapCheckboxFor(tester, 'Ragi flour');
      await settleWithoutAnimations(tester);

      expect(repository.writes, <String>['gi1=have']);
      expect(checkboxFor(tester, 'Ragi flour').value, isTrue);
      // The weight moves with the tick: the whole of what the week needs is
      // now claimed to be in the kitchen, so there is nothing left to bring.
      // The server writes exactly that against the food, and this is what it
      // will answer with on the next read.
      expect(find.text('616 g at home · nothing to bring'), findsOneWidget);
      // The line that was not touched is untouched.
      expect(checkboxFor(tester, 'Kidney beans').value, isFalse);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('unticking one that is already at home sends need',
        (WidgetTester tester) async {
      useTallSurface(tester);
      final _GroceryRepository repository = _GroceryRepository();

      await tester.pumpWidget(groceryApp(repository));
      await settleWithoutAnimations(tester);

      await tapCheckboxFor(tester, 'Spinach');
      await settleWithoutAnimations(tester);

      expect(repository.writes, <String>['gi3=need']);
      expect(checkboxFor(tester, 'Spinach').value, isFalse);
      // Unticking forgets the claim, so the whole 770 g the week needs is to
      // bring again — the correction has to be worth something, or there was
      // no point in offering it.
      expect(find.text('770 g · Still to buy'), findsOneWidget);
    });

    testWidgets('"I bought this" sends bought, not have',
        (WidgetTester tester) async {
      useTallSurface(tester);
      final _GroceryRepository repository = _GroceryRepository();

      await tester.pumpWidget(groceryApp(repository));
      await settleWithoutAnimations(tester);

      final Finder bought = find.descendant(
        of: find.widgetWithText(HpCard, 'Kidney beans'),
        matching: find.widgetWithText(HpTextAction, 'I bought this'),
      );
      await tester.ensureVisible(bought);
      await tester.tap(bought);
      await settleWithoutAnimations(tester);

      expect(repository.writes, <String>['gi2=bought']);
      // Bought and had-all-along both mean "do not bring this", so the box is
      // ticked either way — but the line says which.
      expect(checkboxFor(tester, 'Kidney beans').value, isTrue);
      expect(find.text('539 g · Bought this week'), findsOneWidget);
    });
  });

  group('when a line is refused', () {
    testWidgets('the box stays where it was and the line says why',
        (WidgetTester tester) async {
      useTallSurface(tester);
      final _GroceryRepository repository =
          _GroceryRepository(refuseItemId: 'gi2');

      await tester.pumpWidget(groceryApp(repository));
      await settleWithoutAnimations(tester);

      await tapCheckboxFor(tester, 'Kidney beans');
      await settleWithoutAnimations(tester);

      // The box never moved: it is drawn from what the backend holds, and the
      // backend refused, so what it holds is what it held.
      expect(checkboxFor(tester, 'Kidney beans').value, isFalse);
      // And the person is told, in our own words rather than the server's.
      expect(find.text(refusalMessage), findsOneWidget);
      // Nothing left running. A spinner that outlives its request is how a row
      // ends up permanently dead.
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('the other lines are neither marked nor blocked',
        (WidgetTester tester) async {
      useTallSurface(tester);
      final _GroceryRepository repository =
          _GroceryRepository(refuseItemId: 'gi2');

      await tester.pumpWidget(groceryApp(repository));
      await settleWithoutAnimations(tester);

      await tapCheckboxFor(tester, 'Kidney beans');
      await settleWithoutAnimations(tester);

      // The refusal belongs to the line it happened on, and to no other.
      expect(
        find.descendant(
          of: find.widgetWithText(HpCard, 'Kidney beans'),
          matching: find.text(refusalMessage),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.widgetWithText(HpCard, 'Ragi flour'),
          matching: find.text(refusalMessage),
        ),
        findsNothing,
        reason: 'one refused line must not paint an error across the others',
      );

      // And a line that failed does not stop the next one working.
      await tapCheckboxFor(tester, 'Ragi flour');
      await settleWithoutAnimations(tester);

      expect(repository.writes, <String>['gi2=have', 'gi1=have']);
      expect(checkboxFor(tester, 'Ragi flour').value, isTrue);
    });
  });

  testWidgets('a second tap while the first is in flight sends nothing',
      (WidgetTester tester) async {
    useTallSurface(tester);
    // Held open on a Completer. The fake settles in a microtask, and awaiting a
    // tap flushes microtasks, so without this the "second" tap would land on a
    // call that had already finished.
    final _GroceryRepository repository = _GroceryRepository(holdWrites: true);

    await tester.pumpWidget(groceryApp(repository));
    await settleWithoutAnimations(tester);

    await tapCheckboxFor(tester, 'Ragi flour');
    await tester.pump();
    expect(repository.writes, <String>['gi1=have']);
    // The wait is visible while it happens.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tapCheckboxFor(tester, 'Ragi flour');
    await tester.pump();
    expect(
      repository.writes,
      <String>['gi1=have'],
      reason: 'a second tap posted the same change twice',
    );

    // A different line is not held up by the one in flight.
    await tapCheckboxFor(tester, 'Kidney beans');
    await tester.pump();
    expect(repository.writes, <String>['gi1=have', 'gi2=have']);

    repository.releaseWrites();
    await settleWithoutAnimations(tester);
    expect(checkboxFor(tester, 'Ragi flour').value, isTrue);
    expect(checkboxFor(tester, 'Kidney beans').value, isTrue);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('an empty list says which kind of empty it is',
      (WidgetTester tester) async {
    useTallSurface(tester);

    // None of the seven days planned, which is what the backend counted on the
    // request that built this list.
    await tester.pumpWidget(
      groceryApp(_GroceryRepository(empty: true, plannedDays: 0)),
    );
    await settleWithoutAnimations(tester);

    expect(find.text('Nothing to buy for this week yet'), findsOneWidget);
    // The reason, not just the absence: nothing is planned, and the way out of
    // it is the plan.
    expect(
      find.textContaining('have not been planned yet'),
      findsOneWidget,
    );
    expect(find.widgetWithText(HpButton, 'Open your plan'), findsOneWidget);
    expect(find.byType(Checkbox), findsNothing);
  });

  testWidgets('an empty list on a planned week says it is not a fault',
      (WidgetTester tester) async {
    useTallSurface(tester);

    // The opposite case, and it used to be indistinguishable from the one
    // above: every day is planned and every ingredient came to under five
    // grams. Somebody standing in front of this deserves to be told it is not
    // a fault rather than sent to plan a week that is already planned.
    await tester.pumpWidget(
      groceryApp(_GroceryRepository(empty: true, plannedDays: 7)),
    );
    await settleWithoutAnimations(tester);

    expect(find.text('Nothing worth writing down this week'), findsOneWidget);
    expect(find.textContaining('is not a fault'), findsOneWidget);
    expect(find.textContaining('have not been planned yet'), findsNothing);
  });

  testWidgets('an empty list on a half-planned week says how far it got',
      (WidgetTester tester) async {
    useTallSurface(tester);

    await tester.pumpWidget(
      groceryApp(_GroceryRepository(empty: true, plannedDays: 3)),
    );
    await settleWithoutAnimations(tester);

    expect(find.textContaining('3 days of the week beginning'), findsOneWidget);
    expect(find.textContaining('The other 4 days have'), findsOneWidget);
  });

  testWidgets('a failed fetch offers a way back in',
      (WidgetTester tester) async {
    useTallSurface(tester);
    final _GroceryRepository repository = _GroceryRepository(refuseLoad: true);

    await tester.pumpWidget(groceryApp(repository));
    await settleWithoutAnimations(tester);

    expect(find.text('We could not fetch your grocery list'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    // "Try again" is a real retry, not a redraw of the same refusal.
    repository.refuseLoad = false;
    await tester.tap(find.widgetWithText(HpButton, 'Try again'));
    await settleWithoutAnimations(tester);

    expect(find.text('Ragi flour'), findsOneWidget);
  });
}

// ---------------------------------------------------------------- harness

/// The sentence a refused call puts on screen, written in this app rather than
/// by the server.
final String refusalMessage =
    const ApiFailure(ApiFailureKind.wakingUpTimedOut).message;

/// The screen, wired to [repository].
///
/// A plain [MaterialApp] rather than a router: the only routes this screen
/// knows about are the way back to More and the way to the plan, and neither is
/// tapped here.
Widget groceryApp(FakeHealthRepository repository) {
  return ProviderScope(
    overrides: <Override>[
      healthRepositoryProvider.overrideWithValue(repository),
    ],
    child: MaterialApp(
      theme: HpTheme.light(),
      home: const GroceryScreen(),
    ),
  );
}

/// A surface tall enough that this screen has no fold. A tap below the fold
/// throws rather than scrolling.
void useTallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(600, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Let a queued failure or success land without waiting on any animation.
///
/// [WidgetTester.pumpAndSettle] cannot be used here: a spinner animates for
/// ever, so a screen that is *meant* to be busy would time the test out.
Future<void> settleWithoutAnimations(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 32));
  await tester.pump();
}

/// The tick box on the line whose name is [name].
Checkbox checkboxFor(WidgetTester tester, String name) {
  return tester.widget<Checkbox>(
    find.descendant(
      of: find.widgetWithText(HpCard, name),
      matching: find.byType(Checkbox),
    ),
  );
}

Future<void> tapCheckboxFor(WidgetTester tester, String name) async {
  final Finder target = find.descendant(
    of: find.widgetWithText(HpCard, name),
    matching: find.byType(Checkbox),
  );
  await tester.ensureVisible(target);
  await tester.tap(target);
}

/// The fake repository, with the grocery calls watched, gated or refused.
///
/// It answers with its own small list rather than the fake's sample one, so the
/// names, the aisles and the quantities under test cannot drift when the sample
/// data is edited for some other screen's sake.
class _GroceryRepository extends FakeHealthRepository {
  _GroceryRepository({
    this.refuseItemId,
    this.holdWrites = false,
    this.empty = false,
    this.plannedDays,
    this.refuseLoad = false,
  }) : super(latency: Duration.zero, signedIn: true);

  /// The one item id whose writes are refused, or null for none.
  final String? refuseItemId;

  /// Hold every write open until [releaseWrites] is called, so a second tap can
  /// be made while the first change is genuinely still in flight.
  final bool holdWrites;

  /// Answer with a list that has no lines on it.
  final bool empty;

  /// How many of the week's days the backend says are planned behind the list.
  /// Null is what a plain read sends, so that case is exercised too.
  final int? plannedDays;

  /// Not final: a test turns it off to prove "Try again" really tries again.
  bool refuseLoad;

  /// Every write that reached the repository, as `itemId=state`, in order.
  final List<String> writes = <String>[];

  /// What has been stored, so a reload shows what was written.
  final Map<String, GroceryState> stored = <String, GroceryState>{};

  final Completer<void> _writeGate = Completer<void>();

  void releaseWrites() {
    if (!_writeGate.isCompleted) {
      _writeGate.complete();
    }
  }

  Never _refuse() => throw ApiRepositoryException(
        const ApiFailure(ApiFailureKind.wakingUpTimedOut),
      );

  @override
  Future<GroceryList> loadGroceryList() async {
    if (refuseLoad) {
      _refuse();
    }
    return GroceryList(
      weekStart: DateTime(2026, 9, 7),
      plannedDays: plannedDays,
      items: empty
          ? const <GroceryItem>[]
          : <GroceryItem>[
              for (final GroceryItem item in _lines)
                stored.containsKey(item.id)
                    ? item.withState(stored[item.id]!)
                    : item,
            ],
    );
  }

  @override
  Future<GroceryState> setGroceryItemState({
    required String itemId,
    required GroceryState state,
  }) async {
    writes.add('$itemId=${state.wire}');
    if (itemId == refuseItemId) {
      _refuse();
    }
    if (holdWrites) {
      await _writeGate.future;
    }
    stored[itemId] = state;
    return state;
  }

  /// Two aisles with more than one line and two with one, so grouping is
  /// actually exercised; one line nothing is known about, one the kitchen
  /// partly covers, and one it covers entirely, so all three shapes of the
  /// amount line show.
  ///
  /// `quantity` is what is still to bring and `have` is what the kitchen is
  /// credited with, exactly as `GET /v1/grocery` sends them: the week's
  /// requirement is the two added together.
  static const List<GroceryItem> _lines = <GroceryItem>[
    GroceryItem(
      id: 'gi1',
      foodId: 'ragi_flour',
      name: 'Ragi flour',
      quantity: 616,
      aisle: 'cereal_millet',
    ),
    GroceryItem(
      id: 'gi4',
      foodId: 'rice_brown',
      name: 'Brown rice',
      quantity: 1155,
      aisle: 'cereal_millet',
    ),
    // 839 g needed for the week, 300 g of it already in the kitchen.
    GroceryItem(
      id: 'gi2',
      foodId: 'rajma',
      name: 'Kidney beans',
      quantity: 539,
      have: 300,
      aisle: 'pulse_legume',
    ),
    // Covered entirely: nothing to bring, but still a line to untick.
    GroceryItem(
      id: 'gi3',
      foodId: 'spinach',
      name: 'Spinach',
      quantity: 0,
      have: 770,
      aisle: 'leafy_vegetable',
      state: GroceryState.have,
    ),
  ];
}

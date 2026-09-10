import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:healthpulse/data/models/models.dart';
import 'package:healthpulse/data/repository/health_repository.dart';

import '_today_harness.dart';

/// The three sentences of a focus note, kept apart so a test can ask for each
/// one by name and prove that none of them went missing.
const String noteSentenceOne =
    'Yours came back at 18 ng/mL, where 30 to 100 is usual.';
const String noteSentenceTwo =
    'Fifteen minutes of morning sun and today’s ragi both help.';
const String noteSentenceThree =
    'Worth asking your doctor whether you need more than food can give you.';
const String noteBody =
    '$noteSentenceOne $noteSentenceTwo $noteSentenceThree';

/// A single breakfast, for the tests that need a day on screen but are not
/// about the meals themselves.
const List<MealPlanItem> oneBreakfast = <MealPlanItem>[
  MealPlanItem(
    id: 'b1',
    mealSlot: MealSlot.breakfast,
    title: 'Ragi dosa',
    timeOfDay: '08:30',
  ),
];

void main() {
  group('the day is a routine, not a list of plan rows', () {
    testWidgets('two breakfast items make one breakfast, not two',
        (WidgetTester tester) async {
      // The bug in the owner's own words: "a breakfast item at 8:30, then
      // ANOTHER breakfast item at 8:30". One slot is one moment in the day.
      useTallSurface(tester);
      final TodayFakeRepository repository = TodayFakeRepository(
        briefing: briefingWith(
          meals: const <MealPlanItem>[
            MealPlanItem(
              id: 'b1',
              mealSlot: MealSlot.breakfast,
              title: 'Ragi dosa',
              timeOfDay: '08:30',
            ),
            MealPlanItem(
              id: 'b2',
              mealSlot: MealSlot.breakfast,
              title: 'Pesarattu',
              timeOfDay: '08:30',
            ),
          ],
        ),
      );

      await tester.pumpWidget(todayApp(repository: repository));
      await tester.pump();

      expect(find.text('Breakfast'), findsOneWidget);
      expect(find.text('8:30 am'), findsOneWidget);
      // And no row per food item, which is what produced the double entry.
      expect(find.text('Ragi dosa'), findsNothing);
      expect(find.text('Pesarattu'), findsNothing);
      // The heading counts meals the same way the ribbon does.
      expect(find.text('1 meal planned'), findsOneWidget);
    });

    testWidgets('the options read as a choice, not as a plateful',
        (WidgetTester tester) async {
      useTallSurface(tester);
      final TodayFakeRepository repository = TodayFakeRepository(
        briefing: briefingWith(
          meals: const <MealPlanItem>[
            MealPlanItem(
              id: 'l1',
              mealSlot: MealSlot.lunch,
              title: 'Pearl millet',
              timeOfDay: '13:30',
            ),
            MealPlanItem(
              id: 'l2',
              mealSlot: MealSlot.lunch,
              title: 'Green gram split',
              timeOfDay: '13:30',
            ),
            MealPlanItem(
              id: 'l3',
              mealSlot: MealSlot.lunch,
              title: 'Paneer',
              timeOfDay: '13:30',
            ),
          ],
        ),
      );

      await tester.pumpWidget(todayApp(repository: repository));
      await tester.pump();

      expect(
        find.text('Choose one of 3: Pearl millet, Green gram split, Paneer'),
        findsOneWidget,
      );
    });

    testWidgets('waking, movement, meals, water and winding down, in order',
        (WidgetTester tester) async {
      useTallSurface(tester);
      final TodayFakeRepository repository = TodayFakeRepository(
        briefing: briefingWith(
          meals: const <MealPlanItem>[
            MealPlanItem(
              id: 'b1',
              mealSlot: MealSlot.breakfast,
              title: 'Ragi dosa',
              timeOfDay: '08:30',
            ),
            MealPlanItem(
              id: 'l1',
              mealSlot: MealSlot.lunch,
              title: 'Rajma and rice',
              timeOfDay: '13:30',
            ),
            MealPlanItem(
              id: 'd1',
              mealSlot: MealSlot.dinner,
              title: 'Palak paneer',
              timeOfDay: '20:30',
            ),
          ],
        ),
      );

      await tester.pumpWidget(todayApp(repository: repository));
      await tester.pump();

      expect(find.text('Wake up'), findsOneWidget);
      expect(find.text('Move'), findsOneWidget);
      expect(find.text('Wind down'), findsOneWidget);
      // Halfway between waking at 6:30 and breakfast at 8:30.
      expect(find.text('7:30 am'), findsOneWidget);
      // The target minutes the briefing carries, and no invented workout.
      expect(
        find.textContaining('40 minutes is the target today'),
        findsOneWidget,
      );

      // Water is spread through the gaps between meals: two in the long
      // morning, two in the longer afternoon.
      expect(find.text('Water'), findsNWidgets(4));

      double topOf(String label) => tester.getTopLeft(find.text(label)).dy;
      expect(topOf('Wake up'), lessThan(topOf('Move')));
      expect(topOf('Move'), lessThan(topOf('Breakfast')));
      expect(topOf('Breakfast'), lessThan(topOf('Lunch')));
      expect(topOf('Lunch'), lessThan(topOf('Dinner')));
      expect(topOf('Dinner'), lessThan(topOf('Wind down')));
    });

    testWidgets('tapping a meal opens the plan', (WidgetTester tester) async {
      useTallSurface(tester);
      final TodayFakeRepository repository = TodayFakeRepository(
        briefing: briefingWith(meals: oneBreakfast),
      );

      await tester.pumpWidget(todayApp(repository: repository));
      await tester.pump();

      await tester.ensureVisible(find.text('Breakfast'));
      await tester.pump();
      await tester.tap(find.text('Breakfast'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(find.text(planMarker), findsOneWidget);
    });
  });

  group('hydration is what he drank, not a count of taps', () {
    testWidgets('a chosen amount is logged to the millilitre',
        (WidgetTester tester) async {
      useTallSurface(tester);
      final TodayFakeRepository repository = TodayFakeRepository(
        briefing: briefingWith(meals: oneBreakfast),
      );

      await tester.pumpWidget(todayApp(repository: repository));
      await tester.pump();

      await tester.ensureVisible(find.text('250 ml'));
      await tester.pump();
      await tester.tap(find.text('250 ml'));
      await settleWithoutAnimations(tester);

      expect(repository.hydrationCalls, <double>[250]);
    });

    testWidgets('"Other amount" logs the number he typed',
        (WidgetTester tester) async {
      useTallSurface(tester);
      final TodayFakeRepository repository = TodayFakeRepository(
        briefing: briefingWith(meals: oneBreakfast),
      );

      await tester.pumpWidget(todayApp(repository: repository));
      await tester.pump();

      await tester.ensureVisible(find.text('Other amount'));
      await tester.pump();
      await tester.tap(find.text('Other amount'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('How much did you drink?'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '375');
      await tester.pump();
      await tester.tap(find.text('Add it'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(repository.hydrationCalls, <double>[375]);
    });

    testWidgets('a refused write says why and leaves no spinner behind',
        (WidgetTester tester) async {
      useTallSurface(tester);
      final TodayFakeRepository repository = TodayFakeRepository(
        briefing: briefingWith(meals: oneBreakfast),
        hydrationFailure: const HealthRepositoryException(
          'Your sign-in has expired. Sign in again to keep your day in sync.',
        ),
      );

      await tester.pumpWidget(todayApp(repository: repository));
      await tester.pump();

      await tester.ensureVisible(find.text('250 ml'));
      await tester.pump();
      await tester.tap(find.text('250 ml'));
      await settleWithoutAnimations(tester);

      // The mapped sentence, not a catch-all, and not the exception's own
      // `toString`.
      expect(
        find.text(
          'Your sign-in has expired. Sign in again to keep your day in sync.',
        ),
        findsOneWidget,
      );
      // A spinner that cannot stop is indistinguishable from a dead app.
      expect(find.byType(CircularProgressIndicator), findsNothing);
      // And the amount is offered again rather than left mid-write.
      expect(find.text('A glass'), findsOneWidget);
    });

    testWidgets('a second tap during the first write logs nothing',
        (WidgetTester tester) async {
      useTallSurface(tester);
      final TodayFakeRepository repository = TodayFakeRepository(
        briefing: briefingWith(meals: oneBreakfast),
        holdHydration: true,
      );

      await tester.pumpWidget(todayApp(repository: repository));
      await tester.pump();

      await tester.ensureVisible(find.text('250 ml'));
      await tester.pump();
      await tester.tap(find.text('250 ml'));
      await tester.pump();

      // The button is inert while the write is open, so this lands on nothing.
      await tester.tap(find.text('250 ml'), warnIfMissed: false);
      await tester.pump();
      expect(repository.hydrationCalls.length, 1);

      repository.releaseHydration();
      await settleWithoutAnimations(tester);
    });
  });

  group('worth knowing, at a glance', () {
    testWidgets('the whole of a note is still reachable behind "More"',
        (WidgetTester tester) async {
      useTallSurface(tester);
      final TodayFakeRepository repository = TodayFakeRepository(
        briefing: briefingWith(
          meals: oneBreakfast,
          focus: const <FocusNote>[
            FocusNote(
              id: 'f1',
              title: 'Vitamin D is below the usual range',
              body: noteBody,
              tone: NoteTone.attention,
            ),
          ],
          // One sentence, so this card contributes no second "More" for the
          // finder to trip over - and so the no-boundary case is drawn too.
          planRationale: 'It keeps your usual 8:30 breakfast.',
        ),
      );

      await tester.pumpWidget(todayApp(repository: repository));
      await tester.pump();

      // Collapsed: the title, the severity word and the first sentence.
      expect(find.text('Vitamin D is below the usual range'), findsOneWidget);
      expect(find.text('Outside the usual range'), findsOneWidget);
      expect(find.text(noteSentenceOne), findsOneWidget);
      expect(find.text(noteSentenceTwo), findsNothing);
      expect(find.text(noteSentenceThree), findsNothing);

      await tester.ensureVisible(find.text('More'));
      await tester.pump();
      await tester.tap(find.text('More'));
      await settleWithoutAnimations(tester);

      // Every character the server sent is now on screen. Nothing was
      // summarised, shortened or dropped - only moved behind a tap.
      expect(find.text(noteSentenceOne), findsOneWidget);
      expect(find.text(noteSentenceTwo), findsOneWidget);
      expect(find.text(noteSentenceThree), findsOneWidget);
      expect(find.text('Less'), findsOneWidget);

      // A rationale with no sentence boundary in it is shown whole rather than
      // hidden behind a disclosure that has nothing in it.
      expect(find.text('It keeps your usual 8:30 breakfast.'), findsOneWidget);
    });
  });

  group('what must never move', () {
    testWidgets('the escalation sits above the day and cannot be dismissed',
        (WidgetTester tester) async {
      useTallSurface(tester);
      final TodayBriefing briefing = TodayBriefing(
        date: DateTime(2026, 9, 10),
        displayName: 'Sai Muthiki',
        meals: oneBreakfast,
        escalations: const <EscalationNotice>[
          EscalationNotice(
            id: 'e1',
            title: 'Your potassium is well below the usual range',
            body: 'Please contact a doctor today rather than waiting.',
          ),
        ],
      );
      final TodayFakeRepository repository =
          TodayFakeRepository(briefing: briefing);

      await tester.pumpWidget(todayApp(repository: repository));
      await tester.pump();

      final double escalationTop = tester
          .getTopLeft(
            find.text('Your potassium is well below the usual range'),
          )
          .dy;
      expect(escalationTop, lessThan(tester.getTopLeft(find.text('Wake up')).dy));

      // Nothing anywhere on the card offers to put it away.
      expect(find.text('Dismiss'), findsNothing);
      expect(find.byIcon(Icons.close), findsNothing);
      expect(find.byIcon(Icons.close_rounded), findsNothing);
    });

    testWidgets('the disclaimer is pinned under everything',
        (WidgetTester tester) async {
      useTallSurface(tester);
      final TodayFakeRepository repository = TodayFakeRepository(
        briefing: briefingWith(meals: oneBreakfast),
      );

      await tester.pumpWidget(todayApp(repository: repository));
      await tester.pump();

      expect(find.text('A coach, not a doctor.'), findsOneWidget);
    });
  });
}

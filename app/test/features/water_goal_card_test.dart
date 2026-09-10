import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:healthpulse/core/theme/hp_theme.dart';
import 'package:healthpulse/data/models/models.dart';
import 'package:healthpulse/data/providers.dart';
import 'package:healthpulse/data/repository/fake_health_repository.dart';
import 'package:healthpulse/data/repository/health_repository.dart';
import 'package:healthpulse/features/today/hydration_card.dart';

/// The water card: the goal he types, the figure our sources support, and the
/// two things the server says that this app must never say for itself.
///
/// The rule these tests exist to hold is that **the app renders and the server
/// decides**. The warning attached to a large goal and the reason a goal was
/// refused both carry literature citations and live in one place,
/// `backend/app/rules/daily_goals.py`. So they are asserted here word for word:
/// a test that only checked "some warning appeared" would pass just as happily
/// against a sentence this app had written itself, which is the thing that must
/// not exist.
///
/// The other rule is that no goal means no bar. When the server declines to give
/// a figure - pregnancy, a condition where fluid intake is a doctor's decision -
/// the honest answer is the reason and nothing to fill, never a default.
void main() {
  /// The kind of sentence the server actually sends: a paragraph, with a
  /// citation in it, written for the person who typed the number.
  const String caution =
      '5000 ml a day is above the published intake figures we hold: the highest '
      'adult adequate intake for total water is 3.7 L a day, of which about '
      'three quarters comes from drinks (Institute of Medicine 2005). It is '
      'worth asking a doctor whether this amount is right for you.';

  const String refusal =
      '6500 ml a day is more than we will set a goal for. Our limit is 6000 ml, '
      'which across a normal waking day is about 375 ml an hour - roughly half '
      'the slowest peak rate at which healthy kidneys have been measured to '
      'clear water (Noakes 2001). Your goal has not been changed.';

  const String noGoal =
      'How much to drink is set by a doctor when a condition on your profile '
      'affects fluid balance, so we do not show a water goal here. Please ask '
      'your doctor what daily amount is right for you.';

  TodayBriefing briefing({
    double? targetMl = 2600,
    double? sourcedMl,
    bool chosen = false,
    String source = '',
    String cautionText = '',
  }) {
    return TodayBriefing(
      date: DateTime(2026, 9, 10),
      displayName: 'Sai Muthiki',
      hydrationMl: 900,
      hydrationTargetMl: targetMl,
      hydrationTargetSourcedMl: sourcedMl,
      hydrationTargetChosenByUser: chosen,
      hydrationTargetSource: source,
      hydrationTargetCaution: cautionText,
    );
  }

  Widget cardApp(_WaterFake repository) {
    return ProviderScope(
      overrides: <Override>[
        healthRepositoryProvider.overrideWithValue(repository),
      ],
      child: MaterialApp(
        theme: HpTheme.light(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: HydrationControls(
              loggedMl: repository.briefing.hydrationMl,
              targetMl: repository.briefing.hydrationTargetMl,
            ),
          ),
        ),
      ),
    );
  }

  /// A surface tall enough that the card and its sheet fit with no fold.
  void useTallSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(600, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// Let the sheet open, or a queued answer land, without waiting on a spinner.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
  }

  Future<void> openGoalSheet(WidgetTester tester) async {
    await tester.ensureVisible(find.text('Set your own water goal'));
    await tester.pump();
    await tester.tap(find.text('Set your own water goal'));
    await settle(tester);
  }

  group('setting a goal of his own', () {
    testWidgets('sends the number he typed, exactly as he typed it',
        (WidgetTester tester) async {
      useTallSurface(tester);
      final _WaterFake repository = _WaterFake(
        briefing: briefing(),
        answer: const HydrationGoal(
          millilitres: 5000,
          sourcedMillilitres: 2000,
          chosenByUser: true,
        ),
      );

      await tester.pumpWidget(cardApp(repository));
      await settle(tester);
      await openGoalSheet(tester);

      expect(find.text('Your daily water goal'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '5000');
      await tester.pump();
      await tester.tap(find.text('Save this goal'));
      await settle(tester);

      // Not clamped, not rounded, not talked out of it.
      expect(repository.goalsSet, <int?>[5000]);
    });

    testWidgets("shows the server's warning word for word",
        (WidgetTester tester) async {
      useTallSurface(tester);
      final _WaterFake repository = _WaterFake(
        briefing: briefing(),
        answer: const HydrationGoal(
          millilitres: 5000,
          sourcedMillilitres: 2000,
          chosenByUser: true,
          caution: caution,
        ),
      );

      await tester.pumpWidget(cardApp(repository));
      await settle(tester);
      await openGoalSheet(tester);
      await tester.enterText(find.byType(TextField), '5000');
      await tester.pump();
      await tester.tap(find.text('Save this goal'));
      await settle(tester);

      expect(find.text(caution), findsOneWidget);
    });

    testWidgets('goes back to the sourced figure without typing a number',
        (WidgetTester tester) async {
      useTallSurface(tester);
      final _WaterFake repository = _WaterFake(
        briefing: briefing(targetMl: 5000, sourcedMl: 2000, chosen: true),
        answer: const HydrationGoal(
          millilitres: 2000,
          sourcedMillilitres: 2000,
        ),
      );

      await tester.pumpWidget(cardApp(repository));
      await settle(tester);
      await tester.ensureVisible(find.text('Change your water goal'));
      await tester.pump();
      await tester.tap(find.text('Change your water goal'));
      await settle(tester);
      await tester.tap(find.text('Use the figure our sources support'));
      await settle(tester);

      // A null the server is meant to act on, not "no answer".
      expect(repository.goalsSet, <int?>[null]);
    });

    testWidgets('a second save while the first is in flight sends nothing',
        (WidgetTester tester) async {
      useTallSurface(tester);
      final _WaterFake repository = _WaterFake(
        briefing: briefing(),
        answer: const HydrationGoal(millilitres: 3000),
        hold: true,
      );

      await tester.pumpWidget(cardApp(repository));
      await settle(tester);
      await openGoalSheet(tester);
      await tester.enterText(find.byType(TextField), '3000');
      await tester.pump();
      await tester.tap(find.text('Save this goal'));
      await tester.pump();

      // The card is busy, so this lands on nothing.
      await tester.tap(
        find.text('Set your own water goal'),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(repository.goalsSet.length, 1);

      repository.release();
      await settle(tester);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });

  group('a refusal', () {
    testWidgets("reaches the screen carrying the server's own reason",
        (WidgetTester tester) async {
      useTallSurface(tester);
      final _WaterFake repository = _WaterFake(
        briefing: briefing(),
        failure: const HealthRepositoryException(refusal),
      );

      await tester.pumpWidget(cardApp(repository));
      await settle(tester);
      await openGoalSheet(tester);
      await tester.enterText(find.byType(TextField), '6500');
      await tester.pump();
      await tester.tap(find.text('Save this goal'));
      await settle(tester);

      expect(find.text(refusal), findsOneWidget);
      // And the card is usable again rather than left mid-write.
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('A glass'), findsOneWidget);
    });
  });

  group('when the server will not give a goal', () {
    testWidgets('there is no bar, and the reason is shown instead',
        (WidgetTester tester) async {
      useTallSurface(tester);
      final _WaterFake repository = _WaterFake(
        briefing: briefing(targetMl: null, source: noGoal),
      );

      await tester.pumpWidget(cardApp(repository));
      await settle(tester);

      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.text(noGoal), findsOneWidget);
      // The water he has drunk is still his to see, and still his to add to.
      expect(find.text('900 ml'), findsOneWidget);
      expect(find.text('A glass'), findsOneWidget);
    });

    testWidgets('no default number is drawn in its place',
        (WidgetTester tester) async {
      useTallSurface(tester);
      final _WaterFake repository = _WaterFake(
        briefing: briefing(targetMl: null, source: noGoal),
      );

      await tester.pumpWidget(cardApp(repository));
      await settle(tester);

      for (final String invented in <String>['2500 ml', '2600 ml', '2000 ml']) {
        expect(
          find.textContaining(invented),
          findsNothing,
          reason: 'a goal nobody computed must never appear',
        );
      }
    });
  });

  group('the evidence beside the choice', () {
    testWidgets('the sourced figure stays visible next to his own goal',
        (WidgetTester tester) async {
      useTallSurface(tester);
      final _WaterFake repository = _WaterFake(
        briefing: briefing(targetMl: 5000, sourcedMl: 2000, chosen: true),
      );

      await tester.pumpWidget(cardApp(repository));
      await settle(tester);

      expect(find.text('900 of 5000 ml'), findsOneWidget);
      expect(find.textContaining('2000 ml'), findsOneWidget);
    });

    testWidgets('nothing is shown beside a goal that is ours anyway',
        (WidgetTester tester) async {
      useTallSurface(tester);
      final _WaterFake repository = _WaterFake(
        briefing: briefing(targetMl: 2000, sourcedMl: 2000),
      );

      await tester.pumpWidget(cardApp(repository));
      await settle(tester);

      expect(find.text('900 of 2000 ml'), findsOneWidget);
      expect(find.textContaining('Our sources support'), findsNothing);
    });
  });

  group('the amounts still work', () {
    testWidgets('a chosen amount is still logged to the millilitre',
        (WidgetTester tester) async {
      useTallSurface(tester);
      final _WaterFake repository = _WaterFake(briefing: briefing());

      await tester.pumpWidget(cardApp(repository));
      await settle(tester);
      await tester.ensureVisible(find.text('250 ml'));
      await tester.pump();
      await tester.tap(find.text('250 ml'));
      await settle(tester);

      expect(repository.drinks, <double>[250]);
    });

    testWidgets('"Other amount" still logs the number he typed',
        (WidgetTester tester) async {
      useTallSurface(tester);
      final _WaterFake repository = _WaterFake(briefing: briefing());

      await tester.pumpWidget(cardApp(repository));
      await settle(tester);
      await tester.ensureVisible(find.text('Other amount'));
      await tester.pump();
      await tester.tap(find.text('Other amount'));
      await settle(tester);

      expect(find.text('How much did you drink?'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '375');
      await tester.pump();
      await tester.tap(find.text('Add it'));
      await settle(tester);

      expect(repository.drinks, <double>[375]);
    });
  });
}

/// The sample repository, with the day fixed and every water write recorded.
///
/// It extends [FakeHealthRepository] rather than implementing
/// [HealthRepository], so a method added to the interface tomorrow does not
/// break this file.
class _WaterFake extends FakeHealthRepository {
  _WaterFake({
    required this.briefing,
    this.answer,
    this.failure,
    this.hold = false,
  }) : super(latency: Duration.zero, signedIn: true);

  /// Exactly what Today will be given, goal and all.
  final TodayBriefing briefing;

  /// What `setHydrationTarget` answers with. Test data: this fake deliberately
  /// judges nothing, because the envelope and its citations are the server's.
  final HydrationGoal? answer;

  /// Thrown instead of answering, for the refusal case.
  final Object? failure;

  /// Hold the write open, so a second tap can land inside the busy window.
  final bool hold;

  final List<int?> goalsSet = <int?>[];
  final List<double> drinks = <double>[];

  final Completer<void> _gate = Completer<void>();

  void release() {
    if (!_gate.isCompleted) {
      _gate.complete();
    }
  }

  @override
  Future<TodayBriefing> loadToday(DateTime date) async => briefing;

  @override
  Future<double> logHydration(double millilitres) async {
    drinks.add(millilitres);
    return millilitres;
  }

  @override
  Future<HydrationGoal> setHydrationTarget(int? millilitres) async {
    goalsSet.add(millilitres);
    if (hold) {
      await _gate.future;
    }
    final Object? thrown = failure;
    if (thrown != null) {
      throw thrown;
    }
    return answer ?? const HydrationGoal();
  }
}

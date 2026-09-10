import 'package:flutter_test/flutter_test.dart';
import 'package:healthpulse/data/api/wire.dart';
import 'package:healthpulse/data/models/models.dart';

/// Three numbers about water arrive on one plan response, and they mean three
/// different things: what the plan **asked** for, what the person **drank**, and
/// what their **goal** is. The app used to hold only the first and draw it as
/// the third, which is why the bar on Today was measured against something
/// nobody had chosen.
///
/// These tests are mostly about keeping them apart, and about the fourth case
/// that is not a number at all: a goal the server deliberately will not give.
void main() {
  Map<String, dynamic> planJson({
    Object? targetMl = 5000,
    Object? sourcedMl = 2000,
    bool chosen = true,
    String source = 'You set this goal yourself: 5000 ml.',
    String caution = 'A warning with its citation.',
  }) {
    return <String, dynamic>{
      'plan_date': '2026-09-10',
      'items': <dynamic>[],
      'rationale': 'A steady day.',
      'hydration_ml': 2500,
      'hydration_logged_ml': 1200,
      'hydration_target_ml': targetMl,
      'hydration_target_sourced_ml': sourcedMl,
      'hydration_target_chosen_by_user': chosen,
      'hydration_target_source': source,
      'hydration_target_caution': caution,
    };
  }

  group('the plan', () {
    test('keeps what was asked for, what was drunk and the goal apart', () {
      final MealPlan plan = Wire.planFrom(planJson());

      expect(plan.hydrationTargetMl, 2500, reason: 'what the plan asked for');
      expect(plan.hydrationLoggedMl, 1200, reason: 'what was actually drunk');
      expect(plan.hydrationGoal.millilitres, 5000, reason: 'the goal in force');
    });

    test('carries everything the server says about the goal', () {
      final HydrationGoal goal = Wire.planFrom(planJson()).hydrationGoal;

      expect(goal.hasTarget, isTrue);
      expect(goal.sourcedMillilitres, 2000);
      expect(goal.chosenByUser, isTrue);
      expect(goal.source, 'You set this goal yourself: 5000 ml.');
      expect(goal.caution, 'A warning with its citation.');
    });

    test('a goal the server will not give comes through as null', () {
      const String reason =
          'Water needs change during pregnancy, and we do not hold a figure we '
          'could stand behind for that.';
      final HydrationGoal goal = Wire.planFrom(
        planJson(
          targetMl: null,
          sourcedMl: null,
          chosen: false,
          source: reason,
          caution: '',
        ),
      ).hydrationGoal;

      expect(goal.millilitres, isNull);
      expect(goal.hasTarget, isFalse);
      // The slot that would carry a citation carries the reason instead.
      expect(goal.source, reason);
    });

    test('a plan with no hydration keys at all invents nothing', () {
      final MealPlan plan = Wire.planFrom(<String, dynamic>{
        'plan_date': '2026-09-10',
        'items': <dynamic>[],
      });

      expect(plan.hydrationLoggedMl, 0);
      expect(plan.hydrationGoal.hasTarget, isFalse);
      expect(plan.hydrationGoal.source, '');
    });
  });

  group('setting a goal', () {
    test('sends the number as it was typed', () {
      expect(
        Wire.hydrationTargetBody(5000),
        <String, dynamic>{'millilitres': 5000},
      );
    });

    test('sends a null that means "go back to yours", not a missing key', () {
      final Map<String, dynamic> body = Wire.hydrationTargetBody(null);

      expect(body.containsKey('millilitres'), isTrue);
      expect(body['millilitres'], isNull);
    });

    test('reads the reply with the same five keys the plan uses', () {
      final HydrationGoal goal =
          Wire.hydrationGoalFrom(<String, dynamic>{
        'hydration_target_ml': 3500,
        'hydration_target_sourced_ml': 2000,
        'hydration_target_chosen_by_user': true,
        'hydration_target_source': 'You set this goal yourself: 3500 ml.',
        'hydration_target_caution': 'Above the published range.',
      });

      expect(goal.millilitres, 3500);
      expect(goal.chosenByUser, isTrue);
      expect(goal.caution, 'Above the published range.');
    });
  });

  group('the day, stored and read back', () {
    test('a briefing round-trips its goal without acquiring a default', () {
      final TodayBriefing briefing = TodayBriefing(
        date: DateTime(2026, 9, 10),
        displayName: 'Sai Muthiki',
        hydrationMl: 1200,
        hydrationTargetSource: 'Please ask your doctor.',
      );

      final TodayBriefing back = TodayBriefing.fromJson(briefing.toJson());

      expect(back.hydrationMl, 1200);
      expect(back.hydrationTargetMl, isNull);
      expect(back.hydrationTargetSource, 'Please ask your doctor.');
      expect(back.hydrationGoal.hasTarget, isFalse);
    });

    test('a chosen goal and its evidence survive the cache', () {
      final TodayBriefing briefing = TodayBriefing(
        date: DateTime(2026, 9, 10),
        displayName: 'Sai Muthiki',
        hydrationMl: 900,
        hydrationTargetMl: 5000,
        hydrationTargetSourcedMl: 2000,
        hydrationTargetChosenByUser: true,
        hydrationTargetCaution: 'A warning with its citation.',
      );

      final TodayBriefing back = TodayBriefing.fromJson(briefing.toJson());

      expect(back.hydrationTargetMl, 5000);
      expect(back.hydrationTargetSourcedMl, 2000);
      expect(back.hydrationTargetChosenByUser, isTrue);
      expect(back.hydrationTargetCaution, 'A warning with its citation.');
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:healthpulse/data/api/wire.dart';
import 'package:healthpulse/data/models/models.dart';

/// The four answers that used to be asked and then thrown away.
///
/// The wizard has always collected goals and a PIN code. `Wire.profileTo` sent
/// neither, and its own comment said so, so the GOALS section of every planning
/// prompt has been empty since the prompt was written and a PIN code has never
/// left the phone. These tests are the round trip, in both directions, because
/// sending a field is only half of it: the profile that comes back from the save
/// is what the screen then draws.
void main() {
  /// The saved answers, with something in every field this file is about.
  HealthProfile answered() => HealthProfile(
        userId: 'u1',
        dob: DateTime(1990, 3, 4),
        sex: Sex.male,
        heightCm: 172,
        weightKg: 74,
        activityLevel: ActivityLevel.moderate,
        dietType: DietType.nonVeg,
        cuisinePrefs: const <String>['South Indian'],
        city: 'Hyderabad',
        pincode: '500081',
        wakeTime: '06:30',
        sleepTime: '22:30',
        mealTimes: MealSlot.defaultTimes,
        conditions: const <String>['Thyroid'],
        allergies: const <Allergy>[
          Allergy(id: 'a1', allergen: 'Peanuts', severity: AllergySeverity.severe),
        ],
        goalTypes: const <GoalType>[
          GoalType.weight,
          GoalType.skin,
          GoalType.hair,
        ],
        hydrationTargetOverrideMl: 2600,
      );

  /// What the server answers a save with: the same body, echoed as `ProfileOut`
  /// would, so a round trip here is the round trip the app really makes.
  Map<String, dynamic> asProfileOut(Map<String, dynamic> body) =>
      <String, dynamic>{'user_id': 'u1', ...body};

  group('goals', () {
    test('the goals the wizard collected are in the body that is sent', () {
      final Map<String, dynamic> body = Wire.profileTo(answered());
      expect(body['goal_types'], <String>['weight', 'skin', 'hair']);
    });

    test('the order they were chosen in survives the trip', () {
      final HealthProfile back = Wire.profileFrom(
        asProfileOut(Wire.profileTo(answered())),
        userId: 'u1',
      );
      expect(back.goalTypes, <GoalType>[
        GoalType.weight,
        GoalType.skin,
        GoalType.hair,
      ]);
    });

    test('choosing none sends an empty list rather than nothing at all', () {
      // Null is dropped from the body and the backend reads a missing key as
      // "unset", so an empty list is how "I want none of these" is said.
      final Map<String, dynamic> body =
          Wire.profileTo(const HealthProfile(userId: 'u1'));
      expect(body.containsKey('goal_types'), isTrue);
      expect(body['goal_types'], isEmpty);
    });

    test('a goal type the app does not know does not blank the rest', () {
      final HealthProfile back = Wire.profileFrom(
        <String, dynamic>{
          'user_id': 'u1',
          'goal_types': <dynamic>['weight', 'something_new', 42],
        },
        userId: 'u1',
      );
      expect(back.goalTypes.first, GoalType.weight);
      expect(back.goalTypes.length, 2, reason: 'the number was not a string');
    });
  });

  group('PIN code', () {
    test('it is sent, and it comes back', () {
      final Map<String, dynamic> body = Wire.profileTo(answered());
      expect(body['pincode'], '500081');
      expect(
        Wire.profileFrom(asProfileOut(body), userId: 'u1').pincode,
        '500081',
      );
    });

    test('never answered stays never answered', () {
      final Map<String, dynamic> body =
          Wire.profileTo(const HealthProfile(userId: 'u1'));
      expect(body.containsKey('pincode'), isFalse);
      expect(
        Wire.profileFrom(asProfileOut(body), userId: 'u1').pincode,
        isNull,
      );
    });

    test('a blank one from the server reads as unset, not as an empty answer',
        () {
      final HealthProfile back = Wire.profileFrom(
        <String, dynamic>{'user_id': 'u1', 'pincode': '   '},
        userId: 'u1',
      );
      expect(back.pincode, isNull);
    });
  });

  group('a water target the person chose', () {
    test('it is carried both ways, exactly as given', () {
      final Map<String, dynamic> body = Wire.profileTo(answered());
      expect(body['hydration_target_override_ml'], 2600);
      expect(
        Wire.profileFrom(asProfileOut(body), userId: 'u1')
            .hydrationTargetOverrideMl,
        2600,
      );
    });

    test('not having chosen one is null, not zero', () {
      final HealthProfile back = Wire.profileFrom(
        <String, dynamic>{'user_id': 'u1'},
        userId: 'u1',
      );
      expect(back.hydrationTargetOverrideMl, isNull);

      final Map<String, dynamic> body = Wire.profileTo(back);
      expect(body.containsKey('hydration_target_override_ml'), isFalse);
    });
  });

  group('sex', () {
    test('there are three options and all three are stored as themselves', () {
      expect(Sex.values.map((Sex s) => s.wire).toList(),
          <String>['female', 'male', 'other']);
      for (final Sex sex in Sex.values) {
        final HealthProfile back = Wire.profileFrom(
          asProfileOut(Wire.profileTo(HealthProfile(userId: 'u1', sex: sex))),
          userId: 'u1',
        );
        expect(back.sex, sex, reason: 'the answer changed on the way back');
      }
    });

    test('a row written before the fourth option went away still reads', () {
      final HealthProfile back = Wire.profileFrom(
        <String, dynamic>{'user_id': 'u1', 'sex': 'prefer_not_to_say'},
        userId: 'u1',
      );
      expect(back.sex, Sex.other);
    });
  });

  test('nothing else about the profile changed on the way through', () {
    final HealthProfile before = answered();
    final HealthProfile after = Wire.profileFrom(
      asProfileOut(Wire.profileTo(before)),
      userId: 'u1',
    );
    expect(after.dob, before.dob);
    expect(after.heightCm, before.heightCm);
    expect(after.weightKg, before.weightKg);
    expect(after.activityLevel, before.activityLevel);
    expect(after.dietType, before.dietType);
    expect(after.cuisinePrefs, before.cuisinePrefs);
    expect(after.city, before.city);
    expect(after.wakeTime, before.wakeTime);
    expect(after.sleepTime, before.sleepTime);
    expect(after.conditions, before.conditions);
    expect(after.allergies.length, before.allergies.length);
    expect(after.allergies.first.allergen, 'Peanuts');
    expect(after.allergies.first.severity, AllergySeverity.severe);
    // `early_morning` is not a slot the backend has, so it is the one thing
    // that is deliberately not sent. Everything else the wizard asks about is.
    expect(after.mealTimes['breakfast'], before.mealTimes['breakfast']);
    expect(after.mealTimes['dinner'], before.mealTimes['dinner']);
  });
}

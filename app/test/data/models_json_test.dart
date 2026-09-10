import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:healthpulse/data/models/models.dart';

/// Round-trip tests for every hand-written codec.
///
/// There is no code generation in this app, so these tests are what stands
/// between a renamed column and a screen full of blanks. Each one encodes a
/// model, decodes it, encodes it again, and asserts the two payloads are
/// identical - which catches a dropped field, a wrong key and a lossy date
/// format in a single assertion.
void main() {
  /// Encodes, decodes and re-encodes, so the comparison is of data rather than
  /// of object identity.
  Map<String, dynamic> roundTrip(
    Map<String, dynamic> json,
    Map<String, dynamic> Function(Map<String, dynamic>) decodeEncode,
  ) {
    final Map<String, dynamic> viaJson =
        jsonDecode(jsonEncode(json)) as Map<String, dynamic>;
    return decodeEncode(viaJson);
  }

  group('HealthProfile', () {
    final HealthProfile profile = HealthProfile(
      userId: 'u1',
      dob: DateTime(1994, 3, 2),
      sex: Sex.female,
      heightCm: 163.5,
      weightKg: 58,
      activityLevel: ActivityLevel.moderate,
      dietType: DietType.egg,
      cuisinePrefs: const <String>['South Indian', 'Bengali'],
      city: 'Hyderabad',
      pincode: '500081',
      wakeTime: '06:15',
      sleepTime: '22:45',
      mealTimes: MealSlot.defaultTimes,
      conditions: const <String>['Thyroid'],
      allergies: const <Allergy>[
        Allergy(
          id: 'a1',
          allergen: 'Prawns',
          severity: AllergySeverity.severe,
        ),
      ],
      goalTypes: const <GoalType>[GoalType.energy, GoalType.deficiency],
      updatedAt: DateTime(2026, 9, 9, 7, 30),
    );

    test('survives a JSON round trip', () {
      expect(
        roundTrip(
          profile.toJson(),
          (Map<String, dynamic> j) => HealthProfile.fromJson(j).toJson(),
        ),
        equals(profile.toJson()),
      );
    });

    test('keeps every field it was given', () {
      final HealthProfile decoded = HealthProfile.fromJson(profile.toJson());
      expect(decoded.userId, 'u1');
      expect(decoded.dob, DateTime(1994, 3, 2));
      expect(decoded.sex, Sex.female);
      expect(decoded.heightCm, 163.5);
      expect(decoded.weightKg, 58);
      expect(decoded.activityLevel, ActivityLevel.moderate);
      expect(decoded.dietType, DietType.egg);
      expect(decoded.cuisinePrefs, <String>['South Indian', 'Bengali']);
      expect(decoded.city, 'Hyderabad');
      expect(decoded.pincode, '500081');
      expect(decoded.wakeTime, '06:15');
      expect(decoded.sleepTime, '22:45');
      expect(decoded.mealTimes['breakfast'], '08:30');
      expect(decoded.conditions, <String>['Thyroid']);
      expect(decoded.allergies.single.allergen, 'Prawns');
      expect(decoded.allergies.single.severity, AllergySeverity.severe);
      expect(decoded.goalTypes, <GoalType>[
        GoalType.energy,
        GoalType.deficiency,
      ]);
    });

    test('an empty profile still round-trips', () {
      const HealthProfile empty = HealthProfile(userId: 'u2');
      expect(
        HealthProfile.fromJson(empty.toJson()).toJson(),
        equals(empty.toJson()),
      );
    });

    test('works out an age from a date of birth', () {
      final DateTime now = DateTime.now();
      final HealthProfile aged = HealthProfile(
        userId: 'u3',
        dob: DateTime(now.year - 30, now.month, now.day),
      );
      expect(aged.ageYears, 30);
      expect(const HealthProfile(userId: 'u4').ageYears, isNull);
    });
  });

  group('LabResult', () {
    final LabResult result = LabResult(
      id: 'l1',
      biomarkerCode: 'vitamin_d',
      displayName: 'Vitamin D (25-OH)',
      value: 18,
      unit: 'ng/mL',
      status: LabStatus.low,
      reportId: 'r1',
      printedRange: '30 - 100',
      refLow: 30,
      refHigh: 100,
      measuredOn: DateTime(2026, 8, 14),
      plainLanguage: 'Below the usual range.',
      sourceCitation: 'Endocrine Society reference interval, adults',
    );

    test('survives a JSON round trip', () {
      expect(
        roundTrip(
          result.toJson(),
          (Map<String, dynamic> j) => LabResult.fromJson(j).toJson(),
        ),
        equals(result.toJson()),
      );
    });

    test('never invents a value it could not read', () {
      const LabResult unreadable = LabResult(
        id: 'l2',
        biomarkerCode: 'ferritin',
        displayName: 'Ferritin',
        value: null,
        unit: 'ng/mL',
        status: LabStatus.needsReview,
        needsReview: true,
      );
      final LabResult decoded = LabResult.fromJson(unreadable.toJson());
      expect(decoded.value, isNull);
      expect(decoded.needsReview, isTrue);
      expect(decoded.valueLabel, '--');
      expect(decoded.isOutsideRange, isFalse);
    });

    test('an unknown status decodes as needing a human check', () {
      final LabResult decoded = LabResult.fromJson(<String, dynamic>{
        'id': 'l3',
        'biomarker_code': 'unknown_thing',
        'display_name': 'Something new',
        'unit': '',
        'status': 'a_status_this_app_has_never_heard_of',
      });
      expect(decoded.status, LabStatus.needsReview);
    });

    test('formats its value with the unit', () {
      expect(result.valueLabel, '18 ng/mL');
    });
  });

  group('HealthReport', () {
    final HealthReport report = HealthReport(
      id: 'r1',
      fileName: 'apollo-cbc-14-aug.pdf',
      status: ReportStatus.extracted,
      labName: 'Apollo Diagnostics',
      collectedOn: DateTime(2026, 8, 14),
      createdAt: DateTime(2026, 8, 15, 9, 12),
      headline: 'Most values are in range.',
      results: <LabResult>[
        const LabResult(
          id: 'l1',
          biomarkerCode: 'vitamin_d',
          displayName: 'Vitamin D',
          value: 18,
          unit: 'ng/mL',
          status: LabStatus.low,
        ),
        const LabResult(
          id: 'l2',
          biomarkerCode: 'hba1c',
          displayName: 'HbA1c',
          value: 5.4,
          unit: '%',
          status: LabStatus.normal,
        ),
        const LabResult(
          id: 'l3',
          biomarkerCode: 'ferritin',
          displayName: 'Ferritin',
          unit: 'ng/mL',
          status: LabStatus.needsReview,
          needsReview: true,
        ),
      ],
    );

    test('survives a JSON round trip with its results', () {
      expect(
        roundTrip(
          report.toJson(),
          (Map<String, dynamic> j) => HealthReport.fromJson(j).toJson(),
        ),
        equals(report.toJson()),
      );
    });

    test('counts what is out of range and what needs a check', () {
      expect(report.outsideRangeCount, 1);
      expect(report.needsReviewCount, 1);
    });
  });

  group('MealPlan', () {
    final MealPlan plan = MealPlan(
      id: 'p1',
      planDate: DateTime(2026, 9, 9),
      generatedAt: DateTime(2026, 9, 9, 5, 40),
      rationale: 'More iron than last week.',
      hydrationTargetMl: 2600,
      dayNutrients: const <String, double>{'kcal': 1980, 'iron_mg': 16.4},
      targets: const <String, double>{'kcal': 2100, 'iron_mg': 17},
      items: const <MealPlanItem>[
        MealPlanItem(
          id: 'i1',
          mealSlot: MealSlot.breakfast,
          title: 'Ragi dosa',
          portion: '2 dosas',
          whyText: 'Ragi carries calcium and iron.',
          timeOfDay: '08:30',
          nutrients: <String, double>{'kcal': 412, 'iron_mg': 3.9},
        ),
        MealPlanItem(
          id: 'i2',
          mealSlot: MealSlot.lunch,
          title: 'Rajma and rice',
          orderIndex: 1,
        ),
      ],
    );

    test('survives a JSON round trip', () {
      expect(
        roundTrip(
          plan.toJson(),
          (Map<String, dynamic> j) => MealPlan.fromJson(j).toJson(),
        ),
        equals(plan.toJson()),
      );
    });

    test('groups its items by meal slot', () {
      expect(plan.itemsFor(MealSlot.breakfast).single.title, 'Ragi dosa');
      expect(plan.itemsFor(MealSlot.dinner), isEmpty);
    });

    test('reads energy from the recomputed nutrients', () {
      expect(plan.items.first.kcal, 412);
      expect(plan.items.last.kcal, isNull);
    });
  });

  group('Goal, Symptom, ChatMessage, ConsentRecord', () {
    test('a goal round-trips', () {
      final Goal goal = Goal(
        id: 'g1',
        goalType: GoalType.deficiency,
        title: 'Bring vitamin D back into range',
        target: '30 ng/mL by the next test',
        progress: 0.34,
        createdAt: DateTime(2026, 8, 16),
      );
      expect(Goal.fromJson(goal.toJson()).toJson(), equals(goal.toJson()));
    });

    test('a symptom round-trips', () {
      final Symptom symptom = Symptom(
        id: 's1',
        label: 'Tired in the afternoon',
        onset: DateTime(2026, 8, 20),
        severity: 3,
        pattern: 'after lunch',
      );
      expect(
        Symptom.fromJson(symptom.toJson()).toJson(),
        equals(symptom.toJson()),
      );
    });

    test('a chat message round-trips with its attachments', () {
      final ChatMessage message = ChatMessage(
        id: 'm1',
        role: ChatRole.user,
        content: 'Here is my latest report',
        threadId: 't1',
        attachments: const <String>['apollo-cbc-14-aug.pdf'],
        createdAt: DateTime(2026, 9, 9, 7, 4),
      );
      expect(
        ChatMessage.fromJson(message.toJson()).toJson(),
        equals(message.toJson()),
      );
    });

    test('a consent record round-trips', () {
      final ConsentRecord consent = ConsentRecord(
        id: 'c1',
        consentType: ConsentType.aiProcessing,
        version: '2026-09-01',
        acceptedAt: DateTime(2026, 9, 9, 7, 0),
      );
      expect(
        ConsentRecord.fromJson(consent.toJson()).toJson(),
        equals(consent.toJson()),
      );
    });
  });

  group('TodayBriefing', () {
    final TodayBriefing briefing = TodayBriefing(
      date: DateTime(2026, 9, 9),
      displayName: 'Sai Muthiki',
      wakeTime: '06:15',
      sleepTime: '22:45',
      hydrationMl: 900,
      hydrationTargetMl: 2600,
      movementMinutes: 18,
      movementTargetMinutes: 40,
      meals: const <MealPlanItem>[
        MealPlanItem(
          id: 'i1',
          mealSlot: MealSlot.breakfast,
          title: 'Ragi dosa',
          timeOfDay: '08:30',
        ),
      ],
      focus: const <FocusNote>[
        FocusNote(
          id: 'f1',
          title: 'Vitamin D is below the usual range',
          body: 'Sunlight and food help. Worth asking your doctor.',
          tone: NoteTone.attention,
          linkedBiomarker: 'vitamin_d',
        ),
      ],
      escalations: <EscalationNotice>[
        EscalationNotice(
          id: 'e1',
          title: 'Your potassium is well below the usual range',
          body: 'Please contact a doctor today.',
          steps: const <String>['Call your doctor today.'],
          raisedAt: DateTime(2026, 9, 8, 19, 12),
          sourceCitation: 'ICMR clinical chemistry reference intervals',
        ),
      ],
      planRationale: 'More iron than last week.',
      lastReportHeadline: 'Full blood count, 14 August',
    );

    test('survives a JSON round trip', () {
      expect(
        roundTrip(
          briefing.toJson(),
          (Map<String, dynamic> j) => TodayBriefing.fromJson(j).toJson(),
        ),
        equals(briefing.toJson()),
      );
    });

    test('knows when something has been escalated', () {
      expect(briefing.hasEscalation, isTrue);
      expect(
        TodayBriefing(date: DateTime(2026, 9, 9), displayName: 'Sai')
            .hasEscalation,
        isFalse,
      );
    });
  });

  group('BiomarkerTrend', () {
    final BiomarkerTrend trend = BiomarkerTrend(
      biomarkerCode: 'vitamin_d',
      displayName: 'Vitamin D (25-OH)',
      unit: 'ng/mL',
      refLow: 30,
      refHigh: 100,
      points: <TrendPoint>[
        TrendPoint(measuredOn: DateTime(2025, 9, 12), value: 14),
        TrendPoint(measuredOn: DateTime(2026, 8, 14), value: 18),
      ],
    );

    test('survives a JSON round trip', () {
      expect(
        roundTrip(
          trend.toJson(),
          (Map<String, dynamic> j) => BiomarkerTrend.fromJson(j).toJson(),
        ),
        equals(trend.toJson()),
      );
    });
  });

  group('AuthSession', () {
    test('round-trips and copies', () {
      const AuthSession session = AuthSession(
        userId: 'u1',
        email: 'sai@example.com',
        displayName: 'Sai Muthiki',
      );
      expect(
        AuthSession.fromJson(session.toJson()).toJson(),
        equals(session.toJson()),
      );
      expect(session.copyWith(hasCompletedProfile: true).hasCompletedProfile,
          isTrue);
      expect(session.copyWith(hasCompletedProfile: true).userId, 'u1');
    });
  });

  group('enums', () {
    test('every wire value is unique within its enum', () {
      expect(Sex.values.map((Sex e) => e.wire).toSet().length,
          Sex.values.length);
      expect(DietType.values.map((DietType e) => e.wire).toSet().length,
          DietType.values.length);
      expect(LabStatus.values.map((LabStatus e) => e.wire).toSet().length,
          LabStatus.values.length);
      expect(MealSlot.values.map((MealSlot e) => e.wire).toSet().length,
          MealSlot.values.length);
    });

    test('an unrecognised wire value falls back rather than throwing', () {
      expect(DietType.fromWire('something_else'), DietType.veg);
      expect(Sex.fromWire(null), Sex.other);
      // Rows written before the fourth option was removed still read.
      expect(Sex.fromWire('prefer_not_to_say'), Sex.other);
      expect(MealSlot.fromWire(42), MealSlot.breakfast);
      expect(ReportStatus.fromWire(''), ReportStatus.uploaded);
    });

    test('the default meal times cover every slot', () {
      expect(MealSlot.defaultTimes.length, MealSlot.values.length);
      expect(MealSlot.defaultTimes['dinner'], '20:30');
    });
  });

  group('json helpers', () {
    test('read a wrongly typed field without throwing', () {
      expect(asDouble(<String>['not a number'], fallback: 1), 1);
      expect(asString(42, fallback: 'fallback'), 'fallback');
      expect(asStringList('not a list'), isEmpty);
      expect(asMapList('not a list'), isEmpty);
      expect(asDoubleOrNull('12.5'), 12.5);
      expect(asDoubleOrNull(null), isNull);
    });

    test('dates keep their calendar form', () {
      expect(dateToJson(DateTime(2026, 8, 4)), '2026-08-04');
      expect(asDate('2026-08-04'), DateTime(2026, 8, 4));
      expect(asDate('not a date'), isNull);
      expect(asDate(null), isNull);
    });

    test('prune drops nulls but keeps false and zero', () {
      final Map<String, dynamic> pruned = prune(<String, dynamic>{
        'a': null,
        'b': false,
        'c': 0,
        'd': <String>[],
      });
      expect(pruned.containsKey('a'), isFalse);
      expect(pruned['b'], isFalse);
      expect(pruned['c'], 0);
      expect(pruned['d'], isEmpty);
    });
  });
}

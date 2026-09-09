import 'package:flutter_test/flutter_test.dart';
import 'package:healthpulse/data/api/wire.dart';
import 'package:healthpulse/data/models/models.dart';

/// The seams between what the API returns and what the screens expect.
///
/// Two of these assertions are safety properties rather than mapping details:
/// a lab value must arrive on screen digit for digit, and an `urgent` red flag
/// must come out of the mapper ahead of everything else so the screen cannot
/// render it second by accident.
void main() {
  group('lab values are never reformatted', () {
    test('the string the backend sent is the string that is shown', () {
      for (final String raw in <String>['0.45', '11.80', '18', '2.9', '100.0']) {
        final LabResult result = Wire.labResultFrom(<String, dynamic>{
          'biomarker_code': 'vitamin_d',
          'display_name': 'Vitamin D',
          'value': raw,
          'unit': 'ng/mL',
          'status': 'low',
        });
        expect(result.valueText, raw);
        expect(result.valueLabel, '$raw ng/mL');
      }
    });

    test('a value that could not be read stays empty rather than becoming zero',
        () {
      final LabResult result = Wire.labResultFrom(<String, dynamic>{
        'biomarker_code': 'ferritin',
        'value': '',
        'unit': 'ng/mL',
        'status': 'unknown',
        'needs_review': true,
      });
      expect(result.value, isNull);
      expect(result.valueText, isNull);
      expect(result.valueLabel, '--');
      expect(result.needsReview, isTrue);
    });

    test('the backend\'s "unknown" becomes "needs your check", not "normal"',
        () {
      final LabResult result = Wire.labResultFrom(<String, dynamic>{
        'biomarker_code': 'x',
        'value': '5',
        'unit': '',
        'status': 'unknown',
      });
      expect(result.status, LabStatus.needsReview);
      expect(result.status, isNot(LabStatus.normal));
    });
  });

  group('escalations', () {
    final List<Map<String, dynamic>> flags = <Map<String, dynamic>>[
      <String, dynamic>{
        'code': 'routine_thing',
        'escalation': 'routine',
        'message': 'Nothing here needs a doctor today.',
      },
      <String, dynamic>{
        'code': 'soon_thing',
        'escalation': 'see_doctor_soon',
        'message': 'This is worth raising at your next appointment.',
      },
      <String, dynamic>{
        'code': 'urgent_thing',
        'escalation': 'urgent',
        'message': 'This reading is far outside the usual range.',
      },
    ];

    test('urgent comes first, whatever order the backend sent', () {
      final List<EscalationNotice> notices = Wire.escalationsFrom(flags);
      expect(notices, hasLength(2));
      expect(notices.first.id, 'urgent_thing');
      expect(notices.first.title, Wire.urgentTitle);
      expect(notices.last.id, 'soon_thing');
    });

    test('routine findings are not dressed up as alarms', () {
      final List<EscalationNotice> notices = Wire.escalationsFrom(flags);
      expect(
        notices.map((EscalationNotice n) => n.id),
        isNot(contains('routine_thing')),
      );
    });

    test('the guarded message is shown word for word', () {
      final List<EscalationNotice> notices = Wire.escalationsFrom(flags);
      expect(notices.first.body, 'This reading is far outside the usual range.');
    });

    test('our own steps name no medicine, no dose and no diagnosis', () {
      final List<RegExp> forbidden = <RegExp>[
        RegExp(r'\byou have (diabetes|anaemia|anemia|a deficiency)\b',
            caseSensitive: false),
        RegExp(r'\bstop taking\b', caseSensitive: false),
        RegExp(r'\byou should take\b', caseSensitive: false),
        RegExp(r'\btake \d', caseSensitive: false),
        RegExp(r'\b\d+(\.\d+)?\s?(iu|mg|mcg|ug)\b', caseSensitive: false),
      ];
      final List<String> copy = <String>[
        Wire.urgentTitle,
        Wire.soonTitle,
        ...Wire.urgentSteps,
        ...Wire.soonSteps,
      ];
      expect(copy.length, greaterThan(5));
      for (final String text in copy) {
        for (final RegExp pattern in forbidden) {
          expect(pattern.hasMatch(text), isFalse,
              reason: 'escalation copy matched ${pattern.pattern}: "$text"');
        }
      }
    });
  });

  group('meal slots', () {
    test('the backend\'s evening_snack is the app\'s evening', () {
      expect(Wire.mealSlotIn('evening_snack'), MealSlot.evening);
      expect(Wire.mealSlotOut(MealSlot.evening), 'evening_snack');
    });

    test('early morning has no server slot and is never sent', () {
      expect(Wire.mealSlotOut(MealSlot.earlyMorning), isNull);
      final Map<String, dynamic> body = Wire.profileTo(
        const HealthProfile(
          userId: 'u1',
          mealTimes: <String, String>{
            'early_morning': '06:30',
            'breakfast': '08:30',
            'evening': '17:00',
          },
        ),
      );
      final Map<String, dynamic> meals =
          body['meal_times'] as Map<String, dynamic>;
      expect(meals.containsKey('early_morning'), isFalse);
      expect(meals['breakfast'], '08:30');
      expect(meals['evening_snack'], '17:00');
    });
  });

  group('the profile body the API will actually accept', () {
    test('sends only keys ProfileIn declares', () {
      // `ProfileIn` is extra="forbid": one unexpected key is a 422 and the
      // whole save fails, so this list is the contract.
      const Set<String> allowed = <String>{
        'display_name',
        'locale',
        'timezone',
        'dob',
        'sex',
        'height_cm',
        'weight_kg',
        'activity_level',
        'diet_type',
        'cuisine_pref',
        'city',
        'wake_time',
        'sleep_time',
        'meal_times',
        'conditions',
        'allergies',
        'is_pregnant',
      };
      final Map<String, dynamic> body = Wire.profileTo(
        HealthProfile(
          userId: 'u1',
          dob: DateTime(1994, 3, 2),
          sex: Sex.undisclosed,
          heightCm: 163.5,
          weightKg: 58,
          city: 'Hyderabad',
          pincode: '500081',
          conditions: const <String>['thyroid'],
          goalTypes: const <GoalType>[GoalType.energy],
          allergies: const <Allergy>[
            Allergy(id: 'a1', allergen: 'peanut',
                severity: AllergySeverity.severe),
          ],
          mealTimes: MealSlot.defaultTimes,
        ),
        displayName: 'Sai',
      );
      expect(body.keys.toSet().difference(allowed), isEmpty);
      expect(body.containsKey('pincode'), isFalse);
      expect(body.containsKey('goal_types'), isFalse);
      expect(body.containsKey('user_id'), isFalse);
    });

    test('"prefer not to say" becomes the sex the backend has a word for', () {
      final Map<String, dynamic> body = Wire.profileTo(
        const HealthProfile(userId: 'u1', sex: Sex.undisclosed),
      );
      expect(body['sex'], 'other');
    });

    test('times are sent as HH:mm and read back from HH:MM:SS', () {
      final Map<String, dynamic> body = Wire.profileTo(
        const HealthProfile(userId: 'u1', wakeTime: '06:05', sleepTime: '22:45'),
      );
      expect(body['wake_time'], '06:05');
      expect(body['sleep_time'], '22:45');

      final HealthProfile back = Wire.profileFrom(
        <String, dynamic>{
          'user_id': 'u1',
          'wake_time': '06:05:00',
          'sleep_time': '22:45:00',
          'meal_times': <String, dynamic>{'lunch': '13:30:00'},
        },
        userId: 'u1',
      );
      expect(back.wakeTime, '06:05');
      expect(back.sleepTime, '22:45');
      expect(back.mealTimes['lunch'], '13:30');
    });

    test('the backend\'s fifth activity level folds into the fourth', () {
      final HealthProfile back = Wire.profileFrom(
        <String, dynamic>{'user_id': 'u1', 'activity_level': 'very_active'},
        userId: 'u1',
      );
      expect(back.activityLevel, ActivityLevel.active);
    });
  });

  group('the plan', () {
    test('carries no numbers the client worked out for itself', () {
      final MealPlan plan = Wire.planFrom(
        <String, dynamic>{
          'plan_date': '2026-09-09',
          'hydration_ml': 2600,
          'rationale': 'More iron than last week.',
          'items': <Object>[
            <String, dynamic>{
              'meal_slot': 'lunch',
              'display_name': 'Rajma with brown rice',
              'grams': 320.0,
              'computed_nutrients': <String, dynamic>{
                'kcal': 620.0,
                'iron_mg': 5.6,
              },
              'why_text': 'Rajma brings both protein and iron.',
              'order_index': 3,
            },
          ],
        },
        mealTimes: const <String, String>{'lunch': '13:30'},
      );

      expect(plan.hydrationTargetMl, 2600);
      expect(plan.items.single.mealSlot, MealSlot.lunch);
      expect(plan.items.single.nutrients['iron_mg'], 5.6);
      expect(plan.items.single.timeOfDay, '13:30');
      // Day totals and targets have no endpoint. Adding the items up here is
      // exactly what CLAUDE.md forbids, so they stay empty.
      expect(plan.dayNutrients, isEmpty);
      expect(plan.targets, isEmpty);
    });

    test('a portion is printed exactly as the number arrived', () {
      final MealPlan plan = Wire.planFrom(<String, dynamic>{
        'plan_date': '2026-09-09',
        'items': <Object>[
          <String, dynamic>{
            'meal_slot': 'breakfast',
            'display_name': 'Ragi dosa',
            'grams': 180.0,
          },
        ],
      });
      expect(plan.items.single.portion, '180.0 g');
    });

    test('a hydration target the backend does not have stays at zero', () {
      final MealPlan plan = Wire.planFrom(<String, dynamic>{
        'plan_date': '2026-09-09',
        'hydration_ml': 0,
      });
      expect(plan.hydrationTargetMl, 0);
    });
  });

  group('reports', () {
    test('a detail carries its red flags with it, urgent first', () {
      final HealthReport report = Wire.reportDetailFrom(<String, dynamic>{
        'report': <String, dynamic>{
          'id': 'r1',
          'status': 'extracted',
          'report_type': 'blood',
          'lab_name': 'Apollo Diagnostics',
          'collected_on': '2026-08-14',
          'file_hash': 'abc',
        },
        'results': <Object>[
          <String, dynamic>{
            'biomarker_code': 'potassium',
            'display_name': 'Potassium',
            'value': '2.9',
            'unit': 'mmol/L',
            'status': 'critical_low',
          },
        ],
        'red_flags': <Object>[
          <String, dynamic>{
            'code': 'k_low',
            'escalation': 'urgent',
            'message': 'This potassium reading is well below the usual range.',
          },
        ],
      });

      expect(report.id, 'r1');
      expect(report.labName, 'Apollo Diagnostics');
      expect(report.hasEscalation, isTrue);
      expect(report.escalations.first.title, Wire.urgentTitle);
      expect(report.results.single.valueLabel, '2.9 mmol/L');
      expect(report.results.single.reportId, 'r1');
      // Nothing invented: the endpoint returns no headline, so there is none.
      expect(report.headline, isNull);
      expect(report.results.single.refLow, isNull);
    });

    test('a summary without a lab name is labelled by what it is', () {
      final HealthReport report = Wire.reportSummaryFrom(<String, dynamic>{
        'id': 'r2',
        'status': 'uploaded',
        'report_type': 'thyroid',
        'file_hash': 'x',
      });
      expect(report.fileName, 'Thyroid panel');
      expect(report.status, ReportStatus.uploaded);
    });
  });

  test('the account maps onto the session that drives routing', () {
    final AuthSession session = Wire.sessionFrom(<String, dynamic>{
      'user_id': 'u1',
      'email': 'sai@example.com',
      'display_name': 'Sai',
      'has_health_profile': false,
      'consent_current': true,
    });
    expect(session.userId, 'u1');
    expect(session.hasAcceptedConsent, isTrue);
    expect(session.hasCompletedProfile, isFalse);
  });

  test('a lab value keeps every digit down BOTH paths', () {
    // ResultOut.value is a str on the backend precisely so the lab's own figure
    // survives. A rounded lab value is a wrong lab value, so assert it on the
    // live path (Wire.labResultFrom) and on the cache path (fromJson, reading
    // what toJson wrote) -- a value must not be re-rounded on the way back off
    // the phone either.
    for (final String printed in <String>['0.45', '11.80', '100.0', '1.005', '169']) {
      final Map<String, dynamic> payload = <String, dynamic>{
        'biomarker_code': 'X',
        'display_name': 'X',
        'value': printed,
        'unit': 'ng/mL',
        'status': 'low',
      };

      final LabResult live = Wire.labResultFrom(payload);
      expect(live.valueLabel, '$printed ng/mL', reason: 'live path, $printed');

      final LabResult cached = LabResult.fromJson(live.toJson());
      expect(cached.valueLabel, '$printed ng/mL', reason: 'cache round trip, $printed');
    }
  });
}

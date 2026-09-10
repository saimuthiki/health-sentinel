import '../../services/alert_schedule.dart';
import '../models/models.dart';

/// Where the backend's shapes become the app's shapes.
///
/// The API was read and matched as it is implemented, not as either side would
/// design it, and the seams show. They are handled here, in one file, rather
/// than smeared through the repository:
///
/// * **Meal slots differ.** The backend has five (`app/domain/enums.py`); the
///   app has six, including an early-morning slot the planner has no name for.
///   `evening_snack` and `evening` are the same meal under two names.
/// * **Lab values arrive as strings.** `ResultOut.value` is a `str`, and it stays
///   one all the way to the screen. See [LabResult.valueText] for why that is a
///   safety property and not a typing accident.
/// * **Some things the app models do not exist server-side yet** — day nutrient
///   totals, goals, biomarker trends, a report headline. Those come back empty.
///   Empty is honest; a plausible number the client worked out for itself is not.
class Wire {
  const Wire._();

  // ------------------------------------------------------------ meal slots

  static const Map<String, MealSlot> _slotIn = <String, MealSlot>{
    'early_morning': MealSlot.earlyMorning,
    'breakfast': MealSlot.breakfast,
    'mid_morning': MealSlot.midMorning,
    'lunch': MealSlot.lunch,
    'evening_snack': MealSlot.evening,
    'evening': MealSlot.evening,
    'dinner': MealSlot.dinner,
  };

  /// The slots the backend will accept. `early_morning` is absent on purpose:
  /// sending it would be a 422, so an early-morning time is simply not sent.
  static const Map<MealSlot, String> _slotOut = <MealSlot, String>{
    MealSlot.breakfast: 'breakfast',
    MealSlot.midMorning: 'mid_morning',
    MealSlot.lunch: 'lunch',
    MealSlot.evening: 'evening_snack',
    MealSlot.dinner: 'dinner',
  };

  static MealSlot mealSlotIn(Object? value) =>
      _slotIn[value is String ? value : ''] ?? MealSlot.breakfast;

  static String? mealSlotOut(MealSlot slot) => _slotOut[slot];

  // ------------------------------------------------------------- account

  static AuthSession sessionFrom(
    Map<String, dynamic> me, {
    String fallbackEmail = '',
  }) {
    final String email = asString(me['email']);
    return AuthSession(
      userId: asString(me['user_id']),
      email: email.isEmpty ? fallbackEmail : email,
      displayName: asString(me['display_name']),
      hasCompletedProfile: asBool(me['has_health_profile']),
      hasAcceptedConsent: asBool(me['consent_current']),
    );
  }

  static const Map<String, ActivityLevel> _activityIn =
      <String, ActivityLevel>{
    'sedentary': ActivityLevel.sedentary,
    'light': ActivityLevel.light,
    'moderate': ActivityLevel.moderate,
    'active': ActivityLevel.active,
    // The backend has a fifth level the app does not draw. Folding it into the
    // nearest one it does is honest; inventing a fifth chip is not.
    'very_active': ActivityLevel.active,
  };

  static HealthProfile profileFrom(
    Map<String, dynamic> json, {
    required String userId,
  }) {
    final Map<String, String> meals = <String, String>{};
    final Object? rawTimes = json['meal_times'];
    if (rawTimes is Map) {
      rawTimes.forEach((Object? key, Object? value) {
        final MealSlot? slot = _slotIn[key is String ? key : ''];
        final String? at =
            normaliseTimeOfDay(value is String ? value : null);
        if (slot != null && at != null) {
          meals[slot.wire] = at;
        }
      });
    }

    final List<Allergy> allergies = <Allergy>[];
    final List<Map<String, dynamic>> rawAllergies =
        asMapList(json['allergies']);
    for (int i = 0; i < rawAllergies.length; i++) {
      final String allergen = asString(rawAllergies[i]['allergen']);
      if (allergen.isEmpty) {
        continue;
      }
      allergies.add(
        Allergy(
          // The API returns allergies as a list without row ids, so the id is
          // a local list key. Nothing is sent back that depends on it.
          id: 'allergy-$i',
          allergen: allergen,
          severity: AllergySeverity.fromWire(rawAllergies[i]['severity']),
        ),
      );
    }

    return HealthProfile(
      userId: asString(json['user_id'], fallback: userId),
      dob: asDate(json['dob']),
      sex: Sex.fromWire(json['sex']),
      heightCm: asDoubleOrNull(json['height_cm']),
      weightKg: asDoubleOrNull(json['weight_kg']),
      activityLevel:
          _activityIn[asString(json['activity_level'])] ?? ActivityLevel.light,
      dietType: DietType.fromWire(json['diet_type']),
      cuisinePrefs: asStringList(json['cuisine_pref']),
      city: asStringOrNull(json['city']),
      wakeTime: normaliseTimeOfDay(asStringOrNull(json['wake_time'])) ?? '06:30',
      sleepTime:
          normaliseTimeOfDay(asStringOrNull(json['sleep_time'])) ?? '22:30',
      mealTimes: meals,
      conditions: asStringList(json['conditions']),
      allergies: allergies,
    );
  }

  /// The body for `PUT /v1/me/profile`.
  ///
  /// `ProfileIn` is declared `extra="forbid"`, so a single unexpected key is a
  /// 422 and the whole save fails. Only the fields that model accepts are sent,
  /// and the list caps (12 cuisines, 20 conditions, 40 allergies) are applied
  /// here so a long list is trimmed rather than rejected outright.
  ///
  /// `is_pregnant` and `pincode` are not sent: the app has no field for either,
  /// and `PUT` replaces, so `is_pregnant` returns to its default on every save.
  static Map<String, dynamic> profileTo(
    HealthProfile profile, {
    String? displayName,
    String? locale,
    String? timezone,
  }) {
    final Map<String, String> meals = <String, String>{};
    profile.mealTimes.forEach((String key, String value) {
      for (final MealSlot slot in MealSlot.values) {
        if (slot.wire != key) {
          continue;
        }
        final String? wire = _slotOut[slot];
        final String? at = normaliseTimeOfDay(value);
        if (wire != null && at != null) {
          meals[wire] = at;
        }
      }
    });

    return prune(<String, dynamic>{
      'display_name': displayName,
      'locale': locale,
      'timezone': timezone,
      'dob': dateToJson(profile.dob),
      'sex': _sexOut(profile.sex),
      'height_cm': profile.heightCm,
      'weight_kg': profile.weightKg,
      'activity_level': profile.activityLevel.wire,
      'diet_type': profile.dietType.wire,
      'cuisine_pref': profile.cuisinePrefs.take(12).toList(),
      'city': profile.city,
      'wake_time': normaliseTimeOfDay(profile.wakeTime),
      'sleep_time': normaliseTimeOfDay(profile.sleepTime),
      'meal_times': meals,
      'conditions': profile.conditions.take(20).toList(),
      'allergies': profile.allergies
          .take(40)
          .map((Allergy a) => <String, dynamic>{
                'allergen': a.allergen,
                'severity': a.severity.wire,
              })
          .toList(),
    });
  }

  /// The backend has no "prefer not to say"; `other` is the honest neighbour.
  static String _sexOut(Sex sex) {
    switch (sex) {
      case Sex.female:
        return 'female';
      case Sex.male:
        return 'male';
      case Sex.other:
      case Sex.undisclosed:
        return 'other';
    }
  }

  // ---------------------------------------------------------------- plan

  static MealPlan planFrom(
    Map<String, dynamic> json, {
    Map<String, String> mealTimes = const <String, String>{},
  }) {
    final DateTime date = asDate(json['plan_date']) ?? DateTime.now();
    final List<MealPlanItem> items = <MealPlanItem>[];
    final List<Map<String, dynamic>> rows = asMapList(json['items']);
    for (int i = 0; i < rows.length; i++) {
      items.add(planItemFrom(rows[i], index: i, mealTimes: mealTimes));
    }
    return MealPlan(
      id: 'plan-${dateToJson(date)}',
      planDate: date,
      rationale: _nonEmpty(asString(json['rationale'])),
      status: 'active',
      items: items,
      // `hydration_ml` is the day's target, read back from the audit row the
      // planner wrote. It is zero when the backend has none, and zero is passed
      // through: the model's 2500 default would be a number nobody computed.
      hydrationTargetMl: asDouble(json['hydration_ml']),
      // The API returns no day totals and no ICMR targets. Working them out
      // here would mean adding up nutrient numbers on the client, which is the
      // one thing CLAUDE.md says the client must never do.
      dayNutrients: const <String, double>{},
      targets: const <String, double>{},
    );
  }

  static MealPlanItem planItemFrom(
    Map<String, dynamic> json, {
    int index = 0,
    Map<String, String> mealTimes = const <String, String>{},
  }) {
    final MealSlot slot = mealSlotIn(json['meal_slot']);
    return MealPlanItem(
      id: asStringOrNull(json['id']) ?? '${slot.wire}-$index',
      mealSlot: slot,
      title: asString(json['display_name']),
      portion: _portion(json['grams']),
      whyText: _nonEmpty(asString(json['why_text'])),
      nutrients: asDoubleMap(json['computed_nutrients']),
      orderIndex: asInt(json['order_index'], fallback: index),
      foodId: asStringOrNull(json['food_id']),
      recipeId: asStringOrNull(json['recipe_id']),
      // The plan carries no times, so the ribbon uses the user's own meal times
      // from their profile. That is the user's setting, not a computed number.
      timeOfDay: mealTimes[slot.wire],
    );
  }

  /// The portion, printed exactly as the number arrived.
  ///
  /// No rounding and no unit conversion: `180.0` is shown as `180.0 g`. It reads
  /// a little stiffly and that is the correct trade — a gram figure the app
  /// tidied up is a gram figure the app changed.
  static String? _portion(Object? grams) {
    if (grams is num) {
      return '$grams g';
    }
    if (grams is String && grams.trim().isNotEmpty) {
      return '${grams.trim()} g';
    }
    return null;
  }

  // -------------------------------------------------------------- reports

  static const Map<String, LabStatus> _resultStatus = <String, LabStatus>{
    'critical_low': LabStatus.criticalLow,
    'low': LabStatus.low,
    'borderline_low': LabStatus.borderlineLow,
    'normal': LabStatus.normal,
    'borderline_high': LabStatus.borderlineHigh,
    'high': LabStatus.high,
    'critical_high': LabStatus.criticalHigh,
    // The backend's `unknown` means "we could not place this against a range".
    // The app already has a word for that, and it asks the user rather than
    // pretending the value is fine.
    'unknown': LabStatus.needsReview,
  };

  static const Map<String, String> _reportLabels = <String, String>{
    'blood': 'Blood test',
    'urine': 'Urine test',
    'thyroid': 'Thyroid panel',
    'vitamin': 'Vitamin panel',
    'lipid': 'Lipid profile',
    'diabetes': 'Diabetes panel',
    'scan': 'Scan',
    'prescription': 'Prescription',
    'other': 'Report',
  };

  static HealthReport reportSummaryFrom(Map<String, dynamic> json) {
    final String? labName = _nonEmpty(asString(json['lab_name']));
    final String reportType =
        asString(json['report_type'], fallback: 'other');
    return HealthReport(
      id: asString(json['id']),
      // Report file names are not returned — deliberately, they can carry a
      // person's name. What is shown is the lab, or what kind of report it is.
      fileName: labName ?? (_reportLabels[reportType] ?? 'Report'),
      status: ReportStatus.fromWire(json['status']),
      reportType: reportType,
      labName: labName,
      collectedOn: asDate(json['collected_on']),
      createdAt: asTimestamp(json['created_at']),
      mimeType: asString(json['mime_type'], fallback: 'application/pdf'),
    );
  }

  /// `ReportDetail`: the report, its values, and the red flags recomputed for it.
  static HealthReport reportDetailFrom(Map<String, dynamic> json) {
    final Map<String, dynamic> header = asMap(json['report']);
    final HealthReport summary = reportSummaryFrom(header);
    final String reportId = summary.id;
    return HealthReport(
      id: reportId,
      fileName: summary.fileName,
      status: summary.status,
      reportType: summary.reportType,
      labName: summary.labName,
      collectedOn: summary.collectedOn,
      createdAt: summary.createdAt,
      mimeType: summary.mimeType,
      // No headline is returned by this endpoint, and one is not made up here.
      results: asMapList(json['results'])
          .map((Map<String, dynamic> row) =>
              labResultFrom(row, reportId: reportId))
          .toList(),
      escalations: escalationsFrom(
        json['red_flags'],
        raisedAt: summary.createdAt,
      ),
    );
  }

  static LabResult labResultFrom(
    Map<String, dynamic> json, {
    String? reportId,
  }) {
    final String raw = asString(json['value']).trim();
    final String code = asString(json['biomarker_code']);
    return LabResult(
      // The row's own id when the API sent one. `ResultOut.id` is null on the
      // reply to an upload, which is a preview of what was just read rather
      // than rows read back, so the biomarker code stays as the fallback: it is
      // unique within one report, which is all a list key has to be.
      id: asString(json['id'], fallback: code),
      // The address of the row, and null when there is not one. Only a row with
      // an id can be confirmed, and the screen checks this rather than sending
      // something that is not an id at all.
      rowId: asStringOrNull(json['id']),
      biomarkerCode: code,
      displayName: asString(json['display_name'], fallback: code),
      // Kept for the chart. Never rendered: the screen shows [valueText].
      value: raw.isEmpty ? null : double.tryParse(raw),
      valueText: raw.isEmpty ? null : raw,
      unit: asString(json['unit']),
      status: _resultStatus[asString(json['status'])] ?? LabStatus.needsReview,
      reportId: reportId,
      printedRange: asStringOrNull(json['printed_range']),
      needsReview: asBool(json['needs_review']),
      measuredOn: asDate(json['measured_on']),
    );
  }

  // ---------------------------------------------------------- escalations

  /// `RedFlagOut` rows become the cards that sit above everything else.
  ///
  /// Only `urgent` and `see_doctor_soon` become a card; `routine` is not an
  /// escalation and dressing one up as an alarm would teach people to ignore the
  /// real thing. `message` is shown **verbatim**: it is deterministic text from
  /// `app/rules/red_flags.py` that has already been through the safety
  /// validator, and rewording it on the client would step outside the one place
  /// that copy is checked. Everything around it — the heading, the steps — is
  /// fixed app copy that names no condition, no medicine and no dose.
  static List<EscalationNotice> escalationsFrom(
    Object? rows, {
    DateTime? raisedAt,
  }) {
    final List<EscalationNotice> urgent = <EscalationNotice>[];
    final List<EscalationNotice> soon = <EscalationNotice>[];
    for (final Map<String, dynamic> row in asMapList(rows)) {
      final String level = asString(row['escalation']);
      final String message = asString(row['message']).trim();
      if (message.isEmpty) {
        continue;
      }
      final EscalationNotice notice = EscalationNotice(
        id: asString(row['code'], fallback: 'red-flag'),
        title: level == 'urgent' ? urgentTitle : soonTitle,
        body: message,
        steps: level == 'urgent' ? urgentSteps : soonSteps,
        raisedAt: raisedAt,
      );
      if (level == 'urgent') {
        urgent.add(notice);
      } else if (level == 'see_doctor_soon') {
        soon.add(notice);
      }
    }
    return <EscalationNotice>[...urgent, ...soon];
  }

  /// Headings and steps for an escalation card. Fixed strings, written here,
  /// never generated: they tell a person what to do and what to ask, which is
  /// what the safety charter permits, and they name nothing it forbids.
  static const String urgentTitle = 'Please speak to a doctor today';
  static const String soonTitle = 'Worth seeing a doctor soon';

  static const List<String> urgentSteps = <String>[
    'Contact a doctor or a clinic today and show them this reading.',
    'Ask whether they want to repeat the test before anything else.',
    'If you feel very unwell, go to an emergency department now rather than '
        'waiting.',
    'Keep to anything already prescribed to you unless your doctor says '
        'otherwise.',
  ];

  static const List<String> soonSteps = <String>[
    'Book an appointment and show your doctor this reading.',
    'Ask what, if anything, they want to check next.',
    'Keep to anything already prescribed to you unless your doctor says '
        'otherwise.',
  ];

  // ------------------------------------------------------------------ chat

  static ChatMessage chatMessageFrom(Map<String, dynamic> json) => ChatMessage(
        id: asString(json['id']),
        role: ChatRole.fromWire(json['role']),
        content: asString(json['content']),
        createdAt: asTimestamp(json['created_at']),
      );

  /// `ChatReply` — the answer to one sent message.
  static ChatMessage replyFrom(Map<String, dynamic> json) => ChatMessage(
        id: 'reply-${DateTime.now().microsecondsSinceEpoch}',
        role: ChatRole.assistant,
        content: asString(json['reply']),
        threadId: asStringOrNull(json['thread_id']),
        createdAt: DateTime.now(),
      );

  // --------------------------------------------------------------- alerts

  static AlertPlan alertsFrom(Map<String, dynamic> json) =>
      AlertPlan.fromJson(json);

  static String? _nonEmpty(String value) =>
      value.trim().isEmpty ? null : value.trim();
}

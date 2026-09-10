import 'dart:typed_data';

import '../../services/alert_schedule.dart';
import '../models/models.dart';
import 'health_repository.dart';

/// Sample data good enough to design against.
///
/// Everything here is invented and belongs to a fictional person. It exists so
/// that every screen renders with believable content before the backend is
/// wired, and so that the widget tests have something to assert against. The
/// copy follows the same rules as production copy: nothing diagnoses, nothing
/// prescribes, and every out-of-range value is phrased as something to discuss
/// with a doctor.
class FakeHealthRepository implements HealthRepository {
  FakeHealthRepository({
    this.latency = const Duration(milliseconds: 400),
    bool signedIn = false,
  }) : _session = signedIn
            ? const AuthSession(
                userId: 'demo-user',
                email: 'sai@example.com',
                displayName: 'Sai Muthiki',
                hasCompletedProfile: true,
                hasAcceptedConsent: true,
              )
            : null;

  /// Set to [Duration.zero] in tests so nothing has to wait.
  final Duration latency;

  AuthSession? _session;
  HealthProfile? _profile;
  double _hydrationMl = 900;

  /// The reminders as they stand, so a toggle made on the reminders screen is
  /// still there when the screen is opened again. Started from the sample list
  /// with the quiet-hours flags worked out, which is what the backend sends.
  AlertPlan _alerts = _rebuilt(
    alerts: _sampleAlerts.alerts,
    quietHours: _sampleAlerts.quietHours,
  );

  /// What has been marked eaten or skipped, newest write wins.
  ///
  /// Keyed by plan item id. The real backend keeps an append-only trail; the
  /// fake keeps only the latest state, which is all a screen ever asks it for
  /// and is enough for a widget test to prove the right call was made.
  final Map<String, bool> markedPlanItems = <String, bool>{};

  /// Every meal written down in this session, oldest first.
  ///
  /// A list rather than a map because the ordering is the interesting part: a
  /// screen that logs the same plate twice would double-count its nutrients on
  /// the real backend, and a test can see that here.
  final List<LoggedMeal> loggedMeals = <LoggedMeal>[];

  /// The rating on each logged meal, by food log id. Newest answer wins, which
  /// is what the backend's upsert on `food_log_id` does.
  final Map<String, int> mealRatings = <String, int>{};

  /// What we believe about each food, by food id.
  ///
  /// Seeded with two beliefs so the tastes screen has something to show in
  /// sample mode. An empty screen would look like a screen that failed to load,
  /// and the whole point of it is that a belief is visible.
  final Map<String, TasteStance> foodPreferences = <String, TasteStance>{
    'f_ragi': TasteStance.loved,
    'f_chana': TasteStance.disliked,
  };

  /// Names for the foods the sample plan refers to.
  ///
  /// The real backend resolves these from the `foods` table; this is the same
  /// idea, and it is what stops the tastes screen showing a column of ids.
  static const Map<String, String> _foodNames = <String, String>{
    'f_almonds': 'Almonds',
    'f_ragi': 'Ragi (finger millet)',
    'f_guava': 'Guava',
    'f_rajma': 'Rajma (kidney beans)',
    'f_chana': 'Roasted chana',
    'f_palak': 'Palak (spinach)',
  };

  /// The rows whose values have been confirmed, by [LabResult.rowId].
  ///
  /// The sample reports are shared by every instance and are never changed, so
  /// a confirmation is kept here instead and applied on the way out of
  /// [loadReport]. That is also what a real backend does: the tap sends a
  /// request, and the screen only changes when the report is read again.
  final Set<String> confirmedResults = <String>{};

  final List<ChatMessage> _messages = <ChatMessage>[
    ChatMessage(
      id: 'm1',
      role: ChatRole.assistant,
      content:
          'Morning. Your report from 14 August is in, and two values are worth '
          'a look. Want to go through them, or shall I fold them into today’s '
          'plan first?',
      createdAt: DateTime(2026, 9, 9, 7, 2),
    ),
    ChatMessage(
      id: 'm2',
      role: ChatRole.user,
      content: 'Go through them please',
      createdAt: DateTime(2026, 9, 9, 7, 4),
    ),
    ChatMessage(
      id: 'm3',
      role: ChatRole.assistant,
      content:
          'Your vitamin D came back at 18 ng/mL, where the usual range is 30 to '
          '100. Low vitamin D is common and often shows up as tiredness. Morning '
          'sunlight and foods like ragi, mushrooms and fortified milk help. It is '
          'worth asking your doctor whether you need a supplement, and at what '
          'dose — that part is their call, not mine.',
      createdAt: DateTime(2026, 9, 9, 7, 4),
    ),
  ];

  Future<T> _settle<T>(T value) async {
    if (latency > Duration.zero) {
      await Future<void>.delayed(latency);
    }
    return value;
  }

  @override
  Future<AuthSession?> restoreSession() => _settle(_session);

  @override
  Future<AuthSession> signIn({
    required String email,
    required String password,
  }) async {
    if (!email.contains('@')) {
      throw const HealthRepositoryException(
        'That does not look like an email address. Check it and try again.',
      );
    }
    if (password.length < 8) {
      throw const HealthRepositoryException(
        'Passwords are at least 8 characters. Try again.',
      );
    }
    _session = AuthSession(
      userId: 'demo-user',
      email: email,
      displayName: 'Sai Muthiki',
      hasCompletedProfile: _profile != null,
      hasAcceptedConsent: true,
    );
    return _settle(_session!);
  }

  @override
  Future<AuthSession> signUp({
    required String email,
    required String password,
    required String displayName,
  }) async {
    if (password.length < 8) {
      throw const HealthRepositoryException(
        'Passwords are at least 8 characters. Try again.',
      );
    }
    _session = AuthSession(
      userId: 'demo-user',
      email: email,
      displayName: displayName,
    );
    return _settle(_session!);
  }

  @override
  Future<void> signOut() async {
    _session = null;
    await _settle<void>(null);
  }

  @override
  Future<ConsentRecord> recordConsent(
    ConsentType type, {
    required String version,
  }) {
    _session = _session?.copyWith(hasAcceptedConsent: true);
    return _settle(
      ConsentRecord(
        id: 'consent-${type.wire}',
        consentType: type,
        version: version,
        acceptedAt: DateTime.now(),
      ),
    );
  }

  @override
  Future<HealthProfile?> loadHealthProfile() => _settle(_profile);

  @override
  Future<HealthProfile> saveHealthProfile(HealthProfile profile) {
    _profile = profile;
    _session = _session?.copyWith(hasCompletedProfile: true);
    return _settle(profile);
  }

  @override
  Future<TodayBriefing> loadToday(DateTime date) {
    return _settle(
      TodayBriefing(
        date: DateTime(date.year, date.month, date.day),
        displayName: _session?.displayName ?? 'Sai Muthiki',
        wakeTime: _profile?.wakeTime ?? '06:15',
        sleepTime: _profile?.sleepTime ?? '22:45',
        hydrationMl: _hydrationMl,
        hydrationTargetMl: 2600,
        movementMinutes: 18,
        movementTargetMinutes: 40,
        meals: _sampleMeals,
        focus: _sampleFocus,
        escalations: _sampleEscalations,
        planRationale:
            'Today has more iron than last week because your haemoglobin came '
            'back on the low side, and it keeps your usual 8:30 breakfast.',
        lastReportHeadline:
            'Full blood count and vitamin panel, Apollo Diagnostics, 14 August',
      ),
    );
  }

  @override
  Future<List<HealthReport>> loadReports() => _settle(_sampleReports);

  @override
  Future<HealthReport> loadReport(String reportId) {
    final HealthReport report = _sampleReports.firstWhere(
      (HealthReport r) => r.id == reportId,
      orElse: () => _sampleReports.first,
    );
    return _settle(_withConfirmations(report));
  }

  @override
  Future<void> confirmResult({
    required String reportId,
    required String resultId,
  }) async {
    confirmedResults.add(resultId);
    await _settle<void>(null);
  }

  /// [report] with any confirmed row no longer asking to be checked.
  ///
  /// Confirming does not change the value - there is no way to send one - so
  /// the number, the unit and the printed range are all copied across
  /// untouched. What changes is that we are no longer asking about it.
  HealthReport _withConfirmations(HealthReport report) {
    if (confirmedResults.isEmpty) {
      return report;
    }
    return HealthReport(
      id: report.id,
      fileName: report.fileName,
      status: report.status,
      reportType: report.reportType,
      labName: report.labName,
      collectedOn: report.collectedOn,
      createdAt: report.createdAt,
      mimeType: report.mimeType,
      storagePath: report.storagePath,
      keepOriginalUntil: report.keepOriginalUntil,
      headline: report.headline,
      results: report.results.map(_confirmedRow).toList(),
      escalations: report.escalations,
    );
  }

  LabResult _confirmedRow(LabResult result) {
    final String? rowId = result.rowId;
    if (rowId == null || !confirmedResults.contains(rowId)) {
      return result;
    }
    return LabResult(
      id: result.id,
      rowId: rowId,
      biomarkerCode: result.biomarkerCode,
      displayName: result.displayName,
      unit: result.unit,
      status: result.status,
      value: result.value,
      valueText: result.valueText,
      reportId: result.reportId,
      printedRange: result.printedRange,
      refLow: result.refLow,
      refHigh: result.refHigh,
      needsReview: false,
      confirmedByUser: true,
      measuredOn: result.measuredOn,
      plainLanguage: result.plainLanguage,
      sourceCitation: result.sourceCitation,
    );
  }

  @override
  Future<MealPlan> loadPlan(DateTime date) {
    return _settle(
      MealPlan(
        id: 'plan-1',
        planDate: DateTime(date.year, date.month, date.day),
        generatedAt: DateTime(date.year, date.month, date.day, 5, 40),
        rationale:
            'More iron and vitamin C together than last week, because your '
            'haemoglobin came back on the low side. Your Thursday dinner slot is '
            'lighter — you told me you eat late on Thursdays.',
        items: _sampleMeals,
        hydrationTargetMl: 2600,
        dayNutrients: const <String, double>{
          'kcal': 1980,
          'protein_g': 68,
          'fibre_g': 31,
          'iron_mg': 16.4,
          'calcium_mg': 820,
          'vitamin_d_ug': 4.2,
        },
        targets: const <String, double>{
          'kcal': 2100,
          'protein_g': 60,
          'fibre_g': 30,
          'iron_mg': 17,
          'calcium_mg': 1000,
          'vitamin_d_ug': 15,
        },
      ),
    );
  }

  @override
  Future<void> markPlanItem({
    required String planId,
    required String itemId,
    required bool done,
  }) async {
    markedPlanItems[itemId] = done;
    await _settle<void>(null);
  }

  // ---------------------------------------------------------------- tastes

  @override
  Future<String> logMeal({
    MealSlot? mealSlot,
    String? foodId,
    String? freeText,
    String source = 'manual',
  }) async {
    if (foodId == null && (freeText ?? '').trim().isEmpty) {
      // The same refusal the endpoint gives, so a screen that forgets to say
      // what was eaten fails here rather than on somebody's phone.
      throw const HealthRepositoryException(
        'Tell us either which food it was, or what you ate in words.',
      );
    }
    final String id = 'log-${loggedMeals.length + 1}';
    loggedMeals.add(
      LoggedMeal(id: id, mealSlot: mealSlot, foodId: foodId, freeText: freeText),
    );
    return _settle(id);
  }

  @override
  Future<MealRating> rateMeal({
    required String foodLogId,
    required int rating,
  }) async {
    // Newest answer wins, exactly as the backend's upsert on `food_log_id`
    // does. Rating the same meal twice is a correction, not a second opinion.
    mealRatings[foodLogId] = rating;

    String? foodId;
    for (final LoggedMeal meal in loggedMeals) {
      if (meal.id == foodLogId) {
        foodId = meal.foodId;
        break;
      }
    }
    if (foodId == null) {
      // No food behind the meal, so nothing the planner reads can move. The
      // fake has to be honest about this or the "not in our food list" path is
      // never seen until production.
      return _settle(
        MealRating(foodLogId: foodLogId, rating: rating),
      );
    }

    final TasteStance stance = _stanceForRating(rating);
    foodPreferences[foodId] = stance;
    return _settle(
      MealRating(
        foodLogId: foodLogId,
        rating: rating,
        preferenceUpdated: true,
        stance: stance,
      ),
    );
  }

  @override
  Future<List<FoodPreference>> loadFoodPreferences() async {
    final List<FoodPreference> rows = <FoodPreference>[
      for (final MapEntry<String, TasteStance> entry in foodPreferences.entries)
        FoodPreference(
          foodId: entry.key,
          // A belief nobody can name is one nobody can correct, so an id with
          // no name behind it is left out rather than shown as itself. The
          // backend does the same.
          name: _foodNames[entry.key] ?? entry.key,
          stance: entry.value,
          score: entry.value.rating.toDouble(),
        ),
    ]..sort(
        (FoodPreference a, FoodPreference b) =>
            a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      );
    return _settle(rows);
  }

  @override
  Future<FoodPreference> setFoodPreference({
    required String foodId,
    required TasteStance stance,
  }) async {
    if (!_foodNames.containsKey(foodId)) {
      throw const HealthRepositoryException(
        'We do not have that food in our list, so there is nothing to change.',
      );
    }
    foodPreferences[foodId] = stance;
    return _settle(
      FoodPreference(
        foodId: foodId,
        name: _foodNames[foodId] ?? foodId,
        stance: stance,
        score: stance.rating.toDouble(),
      ),
    );
  }

  /// The same arithmetic `app/api/feedback.py` uses, and for the same reason:
  /// 3 is the only rating that is genuinely neutral, and everything at or below
  /// 2 is a dislike.
  static TasteStance _stanceForRating(int rating) {
    if (rating <= 2) {
      return TasteStance.disliked;
    }
    if (rating >= 4) {
      return TasteStance.loved;
    }
    return TasteStance.okay;
  }

  /// This week's list, with any ticks made in this session still on it.
  ///
  /// The sample lines are what a week of [_sampleMeals] actually adds up to,
  /// with the aisles written as the backend writes them — `cereal_millet`, not
  /// "Cereals and millets". That matters: the aisle is a `foods.food_group`
  /// value, so a screen built against a fake that pre-prettified it would look
  /// right here and show `pulse_legume` on a phone.
  @override
  Future<GroceryList> loadGroceryList() {
    return _settle(
      GroceryList(
        weekStart: _sampleWeekStart,
        items: <GroceryItem>[
          for (final GroceryItem item in _sampleGroceries)
            groceryStates.containsKey(item.id)
                ? item.withState(groceryStates[item.id]!)
                : item,
        ],
      ),
    );
  }

  /// Record the state, the way `PATCH /v1/grocery/items/{item_id}` does.
  ///
  /// Including the refusal for an item that is not on the list: the real
  /// endpoint answers "That item does not exist, or is not yours" rather than
  /// quietly succeeding, and a fake that accepted anything would let a screen
  /// be built on a promise the server does not keep.
  @override
  Future<GroceryState> setGroceryItemState({
    required String itemId,
    required GroceryState state,
  }) async {
    final bool known =
        _sampleGroceries.any((GroceryItem item) => item.id == itemId);
    if (!known) {
      throw const HealthRepositoryException(
        'That item is not on this week’s list any more. Open the list again to '
        'see what it says now.',
      );
    }
    groceryStates[itemId] = state;
    return _settle(state);
  }

  /// What has been ticked, by grocery item id. Newest write wins, as on the
  /// server: the row carries one state, not a history.
  final Map<String, GroceryState> groceryStates = <String, GroceryState>{};

  @override
  Future<List<Goal>> loadGoals() => _settle(_sampleGoals);

  @override
  Future<List<BiomarkerTrend>> loadTrends() => _settle(_sampleTrends);

  @override
  Future<List<ChatMessage>> loadMessages() =>
      _settle(List<ChatMessage>.unmodifiable(_messages));

  @override
  Future<ChatMessage> sendMessage(
    String text, {
    List<String> attachments = const <String>[],
  }) async {
    final ChatMessage sent = ChatMessage(
      id: 'm${_messages.length + 1}',
      role: ChatRole.user,
      content: text,
      attachments: attachments,
      createdAt: DateTime.now(),
    );
    _messages.add(sent);
    final ChatMessage reply = ChatMessage(
      id: 'm${_messages.length + 1}',
      role: ChatRole.assistant,
      content:
          'Noted, and I have added it to what I know about you. I will fold it '
          'into tomorrow’s plan and tell you what changed.',
      createdAt: DateTime.now(),
    );
    _messages.add(reply);
    return _settle(reply);
  }

  @override
  Future<double> logHydration(double millilitres) {
    _hydrationMl += millilitres;
    return _settle(_hydrationMl);
  }

  @override
  Future<AlertPlan> loadAlerts() => _settle(_alerts);

  /// Turn a type on or off, the way `PATCH /v1/alerts/{alert_type}` does.
  ///
  /// Including the refusal. The backend keeps escalations always on, and a fake
  /// that cheerfully switched them off would let a screen be built against a
  /// promise the real server does not keep.
  @override
  Future<AlertPlan> setAlertEnabled(
    String alertType, {
    required bool enabled,
  }) async {
    if (alertType == AlertDefinition.escalationType && !enabled) {
      throw const HealthRepositoryException(
        'Escalation alerts cannot be switched off. They only appear when '
        'something in your results needs a doctor.',
      );
    }
    _alerts = _rebuilt(
      alerts: <AlertDefinition>[
        for (final AlertDefinition alert in _alerts.alerts)
          if (alert.alertType == alertType)
            AlertDefinition(
              alertType: alert.alertType,
              title: alert.title,
              body: alert.body,
              at: alert.at,
              id: alert.id,
              enabled: enabled,
            )
          else
            alert,
      ],
      quietHours: _alerts.quietHours,
    );
    return _settle(_alerts);
  }

  @override
  Future<AlertPlan> setQuietHours({
    required String start,
    required String end,
  }) {
    _alerts = _rebuilt(
      alerts: _alerts.alerts,
      quietHours: QuietHours(start: start, end: end),
    );
    return _settle(_alerts);
  }

  /// Rebuild the plan with `suppressed_by_quiet_hours` worked out again.
  ///
  /// The real backend recomputes that flag on every write and sends it down
  /// with the list, so the fake does the same rather than leaving a stale flag
  /// behind: a screen built against a fake that never updates it would look
  /// right here and be wrong on a phone.
  static AlertPlan _rebuilt({
    required List<AlertDefinition> alerts,
    required QuietHours quietHours,
  }) {
    return AlertPlan(
      alerts: <AlertDefinition>[
        for (final AlertDefinition alert in alerts)
          AlertDefinition(
            alertType: alert.alertType,
            title: alert.title,
            body: alert.body,
            at: alert.at,
            id: alert.id,
            enabled: alert.enabled,
            suppressedByQuietHours:
                !alert.alwaysOn && quietHours.covers(alert.at),
          ),
      ],
      quietHours: quietHours,
    );
  }

  /// A small, believable version of what `GET /v1/privacy/export` answers with.
  ///
  /// The real document is the whole account, table by table. This one has the
  /// same shape and enough in it that the export screen can be built and tested
  /// — and, like everything else here, it belongs to a fictional person.
  @override
  Future<Map<String, dynamic>> exportEverything() {
    return _settle(<String, dynamic>{
      'exported_at': '2026-09-10T06:30:00Z',
      'tables': <String, dynamic>{
        'profiles': <Map<String, dynamic>>[
          <String, dynamic>{
            'display_name': _session?.displayName ?? 'Sai Muthiki',
            'locale': 'en_IN',
            'timezone': 'Asia/Kolkata',
          },
        ],
        'lab_results': <Map<String, dynamic>>[
          <String, dynamic>{
            'biomarker_code': 'vitamin_d',
            'value': 18,
            'unit': 'ng/mL',
            'measured_on': '2026-08-14',
          },
          <String, dynamic>{
            'biomarker_code': 'hemoglobin',
            'value': 11.8,
            'unit': 'g/dL',
            'measured_on': '2026-08-14',
          },
        ],
        'alerts': <Map<String, dynamic>>[
          for (final AlertDefinition alert in _alerts.alerts) alert.toJson(),
        ],
      },
    });
  }

  @override
  Future<HealthReport> uploadReport({
    required String fileName,
    required String mimeType,
    required Uint8List bytes,
    void Function(int sent, int total)? onProgress,
  }) async {
    // The fake still drives the progress callback, so the upload screen can be
    // built and tested without a network: nought, half, all.
    onProgress?.call(0, bytes.length);
    onProgress?.call(bytes.length ~/ 2, bytes.length);
    onProgress?.call(bytes.length, bytes.length);
    return _settle(_sampleReports.first);
  }

  // -------------------------------------------------------------- sample data

  static const AlertPlan _sampleAlerts = AlertPlan(
    alerts: <AlertDefinition>[
      AlertDefinition(
        alertType: 'meal',
        title: 'Breakfast time',
        body: 'Today\u2019s breakfast is ready in your plan.',
        at: '08:20',
      ),
      AlertDefinition(
        alertType: 'hydration',
        title: 'Water',
        body: 'Time for a glass of water.',
        at: '11:00',
      ),
      AlertDefinition(
        alertType: 'sleep',
        title: 'Wind down',
        body: 'Screens off soon \u2014 you sleep better when the last hour is '
            'quiet.',
        at: '21:45',
      ),
      AlertDefinition(
        alertType: 'hydration',
        title: 'Water',
        body: 'Time for a glass of water.',
        at: '23:30',
      ),
      // The one type nobody can switch off, and the reason the reminders screen
      // has to explain itself rather than simply drawing another switch.
      AlertDefinition(
        alertType: AlertDefinition.escalationType,
        title: 'A result your doctor should see',
        body: 'Your potassium reading is one to speak to a doctor about today.',
        at: '09:00',
      ),
    ],
    quietHours: QuietHours(start: '22:30', end: '06:00'),
  );

  static final List<MealPlanItem> _sampleMeals = <MealPlanItem>[
    const MealPlanItem(
      id: 'i1',
      foodId: 'f_almonds',
      mealSlot: MealSlot.earlyMorning,
      title: 'Warm water with soaked almonds',
      portion: '250 ml, 6 almonds',
      timeOfDay: '06:30',
      whyText:
          'Soaking softens the skins, which makes the iron easier for your body '
          'to take up.',
      nutrients: <String, double>{'kcal': 96, 'protein_g': 3.5, 'iron_mg': 0.8},
    ),
    const MealPlanItem(
      id: 'i2',
      foodId: 'f_ragi',
      mealSlot: MealSlot.breakfast,
      title: 'Ragi dosa with coconut chutney',
      portion: '2 dosas, 40 g chutney',
      timeOfDay: '08:30',
      whyText:
          'Ragi is one of the better everyday sources of calcium and iron, and '
          'you rated this 5 stars last Tuesday.',
      nutrients: <String, double>{
        'kcal': 412,
        'protein_g': 11.2,
        'fibre_g': 6.4,
        'iron_mg': 3.9,
        'calcium_mg': 268,
      },
    ),
    const MealPlanItem(
      id: 'i3',
      foodId: 'f_guava',
      mealSlot: MealSlot.midMorning,
      title: 'Guava',
      portion: '1 medium',
      timeOfDay: '11:00',
      whyText:
          'Vitamin C alongside this morning’s ragi helps your body absorb '
          'the iron from it.',
      nutrients: <String, double>{'kcal': 68, 'fibre_g': 5.4},
    ),
    const MealPlanItem(
      id: 'i4',
      foodId: 'f_rajma',
      mealSlot: MealSlot.lunch,
      title: 'Rajma, brown rice and a beetroot salad',
      portion: '1 cup rajma, 3/4 cup rice, 80 g salad',
      timeOfDay: '13:30',
      whyText:
          'Rajma brings both protein and iron, and lemon on the salad keeps the '
          'iron easy to absorb.',
      nutrients: <String, double>{
        'kcal': 620,
        'protein_g': 22.4,
        'fibre_g': 13.1,
        'iron_mg': 5.6,
      },
    ),
    const MealPlanItem(
      id: 'i5',
      foodId: 'f_chana',
      mealSlot: MealSlot.evening,
      title: 'Masala chai with roasted chana',
      portion: '150 ml, 30 g chana',
      timeOfDay: '17:00',
      whyText:
          'Chana keeps you going to dinner without a sugar dip at seven.',
      nutrients: <String, double>{'kcal': 184, 'protein_g': 7.1},
    ),
    const MealPlanItem(
      id: 'i6',
      foodId: 'f_palak',
      mealSlot: MealSlot.dinner,
      title: 'Palak paneer with two phulkas',
      portion: '150 g curry, 2 phulkas',
      timeOfDay: '20:30',
      whyText:
          'Spinach and paneer together cover iron and calcium in one plate, and '
          'it is light enough to sleep on.',
      nutrients: <String, double>{
        'kcal': 528,
        'protein_g': 24.3,
        'fibre_g': 6.2,
        'iron_mg': 5.4,
        'calcium_mg': 486,
      },
    ),
  ];

  static final List<FocusNote> _sampleFocus = <FocusNote>[
    const FocusNote(
      id: 'f1',
      title: 'Vitamin D is below the usual range',
      body:
          'Yours came back at 18 ng/mL, where 30 to 100 is usual. Fifteen minutes '
          'of morning sun and today’s ragi and mushrooms both help. Worth '
          'asking your doctor whether you need more than food can give you.',
      tone: NoteTone.attention,
      linkedBiomarker: 'vitamin_d',
      actionLabel: 'See the value',
    ),
    const FocusNote(
      id: 'f2',
      title: 'Haemoglobin is near the low edge',
      body:
          'At 11.8 g/dL it sits just under the usual range for you. Today’s '
          'plan pairs iron-rich food with vitamin C, which is the part most people '
          'miss.',
      tone: NoteTone.watch,
      linkedBiomarker: 'hemoglobin',
    ),
    const FocusNote(
      id: 'f3',
      title: 'You have hit your water target four days running',
      body: 'Keep the 11am glass going — it is the one you used to skip.',
      tone: NoteTone.calm,
    ),
  ];

  static final List<EscalationNotice> _sampleEscalations =
      <EscalationNotice>[
    EscalationNotice(
      id: 'e1',
      title: 'Your potassium is well below the usual range',
      body:
          'The reading is 2.9 mmol/L, where 3.5 to 5.1 is usual. A value this far '
          'below the range is one doctors want to see quickly, especially '
          'alongside the muscle weakness you mentioned on Sunday. Please contact '
          'a doctor today rather than waiting for your next appointment.',
      steps: const <String>[
        'Call your doctor or a clinic today and read them this value.',
        'Ask whether they want to repeat the test before anything else.',
        'Go to an emergency department if you get palpitations, severe '
            'weakness or fainting.',
        'Keep taking anything already prescribed to you unless your doctor '
            'tells you otherwise.',
      ],
      raisedAt: DateTime(2026, 9, 8, 19, 12),
      sourceCitation:
          'Threshold from our reference range table, sourced from ICMR clinical '
          'chemistry reference intervals.',
    ),
  ];

  static final List<HealthReport> _sampleReports = <HealthReport>[
    HealthReport(
      id: 'r1',
      fileName: 'apollo-cbc-14-aug.pdf',
      status: ReportStatus.extracted,
      reportType: 'blood_panel',
      labName: 'Apollo Diagnostics',
      collectedOn: DateTime(2026, 8, 14),
      createdAt: DateTime(2026, 8, 15, 9, 12),
      headline:
          'Most values are in range. Vitamin D is low and haemoglobin is near '
          'the low edge — both worth raising at your next appointment.',
      results: <LabResult>[
        LabResult(
          id: 'l1',
          rowId: 'row-l1',
          biomarkerCode: 'vitamin_d',
          displayName: 'Vitamin D (25-OH)',
          value: 18,
          unit: 'ng/mL',
          status: LabStatus.low,
          refLow: 30,
          refHigh: 100,
          printedRange: '30 - 100',
          measuredOn: DateTime(2026, 8, 14),
          plainLanguage:
              'Below the usual range. Common in India, and often behind low '
              'energy. Sunlight and food help; your doctor can say whether you '
              'need more than that.',
          sourceCitation: 'Endocrine Society reference interval, adults',
        ),
        LabResult(
          id: 'l2',
          rowId: 'row-l2',
          biomarkerCode: 'hemoglobin',
          displayName: 'Haemoglobin',
          value: 11.8,
          unit: 'g/dL',
          status: LabStatus.borderlineLow,
          refLow: 12,
          refHigh: 15,
          printedRange: '12.0 - 15.0',
          measuredOn: DateTime(2026, 8, 14),
          plainLanguage:
              'Just under the usual range. Worth watching, and worth mentioning '
              'if you have been more tired than normal.',
          sourceCitation: 'WHO haemoglobin thresholds, adult women',
        ),
        LabResult(
          id: 'l3',
          rowId: 'row-l3',
          biomarkerCode: 'hba1c',
          displayName: 'HbA1c',
          value: 5.4,
          unit: '%',
          status: LabStatus.normal,
          refLow: 4,
          refHigh: 5.7,
          printedRange: '4.0 - 5.7',
          measuredOn: DateTime(2026, 8, 14),
          plainLanguage: 'In the usual range. Nothing to do here.',
          sourceCitation: 'ADA diagnostic thresholds',
        ),
        LabResult(
          id: 'l4',
          rowId: 'row-l4',
          biomarkerCode: 'ferritin',
          displayName: 'Ferritin',
          value: null,
          unit: 'ng/mL',
          status: LabStatus.needsReview,
          needsReview: true,
          printedRange: '13 - 150',
          measuredOn: DateTime(2026, 8, 14),
          plainLanguage:
              'We could not read this one from the scan with confidence, so we '
              'have not guessed it. Check it against your printed report.',
        ),
      ],
    ),
    HealthReport(
      id: 'r2',
      fileName: 'thyroid-panel-02-may.pdf',
      status: ReportStatus.extracted,
      reportType: 'thyroid_panel',
      labName: 'Dr Lal PathLabs',
      collectedOn: DateTime(2026, 5, 2),
      createdAt: DateTime(2026, 5, 3, 18, 40),
      headline: 'All four thyroid values were in the usual range.',
      results: <LabResult>[
        LabResult(
          id: 'l5',
          rowId: 'row-l5',
          biomarkerCode: 'tsh',
          displayName: 'TSH',
          value: 2.3,
          unit: 'mIU/L',
          status: LabStatus.normal,
          refLow: 0.4,
          refHigh: 4.0,
          printedRange: '0.40 - 4.00',
          measuredOn: DateTime(2026, 5, 2),
          sourceCitation: 'ATA reference interval, adults',
        ),
      ],
    ),
  ];

  /// The Monday the sample list runs from.
  static final DateTime _sampleWeekStart = DateTime(2026, 9, 7);

  /// A week of [_sampleMeals], added up. Quantities carry the tenth the
  /// planner adds on top, which is why none of them is a round number.
  static final List<GroceryItem> _sampleGroceries = <GroceryItem>[
    const GroceryItem(
      id: 'gi1',
      foodId: 'ragi_flour',
      name: 'Ragi flour',
      quantity: 616,
      aisle: 'cereal_millet',
    ),
    const GroceryItem(
      id: 'gi2',
      foodId: 'rice_brown',
      name: 'Rice, brown',
      quantity: 1155,
      aisle: 'cereal_millet',
    ),
    const GroceryItem(
      id: 'gi3',
      foodId: 'wheat_flour_atta',
      name: 'Wheat flour, wholemeal (atta)',
      quantity: 462,
      aisle: 'cereal_millet',
      // Already in the kitchen, so the sample screen shows both states.
      state: GroceryState.have,
    ),
    const GroceryItem(
      id: 'gi4',
      foodId: 'rajma',
      name: 'Kidney beans (rajma)',
      quantity: 539,
      aisle: 'pulse_legume',
    ),
    const GroceryItem(
      id: 'gi5',
      foodId: 'chana_roasted',
      name: 'Chana, roasted',
      quantity: 231,
      aisle: 'pulse_legume',
    ),
    const GroceryItem(
      id: 'gi6',
      foodId: 'spinach',
      name: 'Spinach (palak)',
      quantity: 770,
      aisle: 'leafy_vegetable',
    ),
    const GroceryItem(
      id: 'gi7',
      foodId: 'beetroot',
      name: 'Beetroot',
      quantity: 616,
      aisle: 'vegetable',
    ),
    const GroceryItem(
      id: 'gi8',
      foodId: 'guava',
      name: 'Guava',
      quantity: 1078,
      aisle: 'fruit',
    ),
    const GroceryItem(
      id: 'gi9',
      foodId: 'paneer',
      name: 'Paneer',
      quantity: 385,
      aisle: 'dairy',
    ),
    const GroceryItem(
      id: 'gi10',
      foodId: 'almond',
      name: 'Almonds',
      quantity: 62,
      aisle: 'nut_seed',
    ),
  ];

  static final List<Goal> _sampleGoals = <Goal>[
    Goal(
      id: 'g1',
      goalType: GoalType.deficiency,
      title: 'Bring vitamin D back into range',
      target: '30 ng/mL by the next test',
      progress: 0.34,
      createdAt: DateTime(2026, 8, 16),
    ),
    Goal(
      id: 'g2',
      goalType: GoalType.energy,
      title: 'Fewer afternoon slumps',
      target: 'Four good afternoons a week',
      progress: 0.6,
      createdAt: DateTime(2026, 8, 16),
    ),
    Goal(
      id: 'g3',
      goalType: GoalType.sleep,
      title: 'In bed by 10:45',
      target: 'Five nights a week',
      progress: 0.8,
      createdAt: DateTime(2026, 7, 30),
    ),
  ];

  static final List<BiomarkerTrend> _sampleTrends = <BiomarkerTrend>[
    BiomarkerTrend(
      biomarkerCode: 'vitamin_d',
      displayName: 'Vitamin D (25-OH)',
      unit: 'ng/mL',
      refLow: 30,
      refHigh: 100,
      points: <TrendPoint>[
        TrendPoint(measuredOn: DateTime(2025, 9, 12), value: 14),
        TrendPoint(measuredOn: DateTime(2026, 2, 3), value: 16),
        TrendPoint(measuredOn: DateTime(2026, 8, 14), value: 18),
      ],
    ),
    BiomarkerTrend(
      biomarkerCode: 'hemoglobin',
      displayName: 'Haemoglobin',
      unit: 'g/dL',
      refLow: 12,
      refHigh: 15,
      points: <TrendPoint>[
        TrendPoint(measuredOn: DateTime(2025, 9, 12), value: 12.4),
        TrendPoint(measuredOn: DateTime(2026, 2, 3), value: 12.1),
        TrendPoint(measuredOn: DateTime(2026, 8, 14), value: 11.8),
      ],
    ),
  ];
}

/// One meal written down by [FakeHealthRepository.logMeal].
///
/// [foodId] null is the case that matters: a meal typed in words, or read off a
/// photo, has no row in the foods table, so rating it moves no preference. The
/// fake keeps the distinction so a screen is tested against both.
class LoggedMeal {
  const LoggedMeal({
    required this.id,
    this.mealSlot,
    this.foodId,
    this.freeText,
  });

  final String id;
  final MealSlot? mealSlot;
  final String? foodId;
  final String? freeText;
}

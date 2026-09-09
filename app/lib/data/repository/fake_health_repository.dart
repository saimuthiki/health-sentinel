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
    return _settle(report);
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
  Future<AlertPlan> loadAlerts() => _settle(_sampleAlerts);

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
    ],
    quietHours: QuietHours(start: '22:30', end: '06:00'),
  );

  static final List<MealPlanItem> _sampleMeals = <MealPlanItem>[
    const MealPlanItem(
      id: 'i1',
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
              'have not guessed it. Tap to type what your report says.',
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

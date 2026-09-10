import 'dart:typed_data';

import '../../services/alert_schedule.dart';
import '../../services/auth_service.dart';
import '../api/api_client.dart';
import '../api/api_failure.dart';
import '../api/wire.dart';
import '../cache/cache_freshness.dart';
import '../cache/offline_cache.dart';
import '../models/models.dart';
import 'health_repository.dart';

/// A [HealthRepositoryException] that still knows what actually went wrong.
///
/// The message is the one the interface shows and it comes from [ApiFailure],
/// which means it was written in this app rather than by the server. The
/// failure itself rides along so that a caller who needs to branch — sign the
/// person out, offer a retry, send them back to consent — can, without parsing
/// a sentence.
class ApiRepositoryException extends HealthRepositoryException {
  ApiRepositoryException(this.failure) : super(failure.message);

  final ApiFailure failure;
}

/// The real repository: our FastAPI service, Supabase for identity only, and a
/// small local cache so the app opens to something on a train.
///
/// It implements exactly the interface [FakeHealthRepository] implements, which
/// is what makes swapping them a single line in `providers.dart` and what lets
/// every widget test keep running against the fake.
///
/// Three habits run through all of it:
///
/// * **Cached is never current.** Anything served from the cache is recorded in
///   [servedFromCacheAt] so the screen can label it, and escalations are
///   stripped before anything is written, because a stored red flag shown after
///   a failed refresh is a claim about somebody's health right now that nobody
///   checked.
/// * **No number is composed here.** Day nutrient totals, targets, trends and
///   goals have no endpoint yet, so they come back empty rather than added up
///   on the phone.
/// * **No server sentence reaches a screen.** Everything thrown out of here is
///   an [ApiRepositoryException] carrying our own copy.
class HttpHealthRepository implements HealthRepository, CacheAware {
  HttpHealthRepository({
    required ApiClient api,
    required AuthGateway auth,
    required OfflineCache cache,
    DateTime Function()? clock,
  })  : _api = api,
        _auth = auth,
        _cache = cache,
        _now = clock ?? DateTime.now;

  final ApiClient _api;
  final AuthGateway _auth;
  final OfflineCache _cache;
  final DateTime Function() _now;

  final Map<String, DateTime> _fromCache = <String, DateTime>{};

  /// The name typed at sign-up, held until the profile wizard saves it.
  ///
  /// It cannot be written at sign-up: `PUT /v1/me/profile` also creates the
  /// health-profile row, and creating one there would flip `has_health_profile`
  /// to true and skip the onboarding the person has not done yet.
  String _pendingDisplayName = '';

  /// The conversation being continued, so a reply lands in the right thread.
  String? _threadId;

  /// `app/repositories/profiles.py` requires **all three** of these at the
  /// current version before anything will analyse health data. The consent
  /// screen presents them as one decision, covering exactly these three things,
  /// so accepting it records all three.
  static const List<String> requiredConsentTypes = <String>[
    'health_data',
    'ai_processing',
    'not_a_doctor',
  ];

  @override
  DateTime? servedFromCacheAt(String subject) => _fromCache[subject];

  // ------------------------------------------------------------------ auth

  @override
  Future<AuthSession?> restoreSession() async {
    final AuthUser? user = _auth.currentUser;
    if (user == null) {
      // Not signed in. That is an answer, not a failure.
      return null;
    }
    try {
      final Map<String, dynamic> me = await _api.getMap('/v1/me');
      await _cache.write(OfflineCache.account, me);
      return Wire.sessionFrom(me, fallbackEmail: user.email);
    } on ApiFailure catch (failure) {
      if (failure.requiresSignIn) {
        return null;
      }
      final Cached<Map<String, dynamic>>? stored =
          await _cache.read(OfflineCache.account);
      if (stored != null) {
        // Which screen someone belongs on is not health data, so remembering it
        // is safe and it is what lets the app open offline into the shell
        // rather than back into the sign-in flow.
        return Wire.sessionFrom(stored.value, fallbackEmail: user.email);
      }
      throw _wrap(failure);
    }
  }

  @override
  Future<AuthSession> signIn({
    required String email,
    required String password,
  }) async {
    final AuthUser user = await _auth.signIn(email: email, password: password);
    try {
      final Map<String, dynamic> me = await _api.getMap('/v1/me');
      await _cache.write(OfflineCache.account, me);
      return Wire.sessionFrom(me, fallbackEmail: user.email);
    } on ApiFailure catch (failure) {
      throw _wrap(failure);
    }
  }

  @override
  Future<AuthSession> signUp({
    required String email,
    required String password,
    required String displayName,
  }) async {
    final AuthUser user = await _auth.signUp(
      email: email,
      password: password,
      displayName: displayName,
    );
    _pendingDisplayName = displayName.trim();
    // Deliberately no profile write here. See [_pendingDisplayName].
    return AuthSession(
      userId: user.id,
      email: user.email,
      displayName: _pendingDisplayName,
    );
  }

  @override
  Future<void> signOut() async {
    await _auth.signOut();
    _threadId = null;
    _pendingDisplayName = '';
    _fromCache.clear();
    // A cache that outlives a sign-out is a leak: meal times, a report line and
    // a day's plan all describe the person who just left.
    await _cache.clear();
  }

  @override
  Future<ConsentRecord> recordConsent(
    ConsentType type, {
    required String version,
  }) async {
    try {
      Map<String, dynamic> last = const <String, dynamic>{};
      for (final String consentType in requiredConsentTypes) {
        last = await _api.postMap(
          '/v1/me/consents',
          body: <String, dynamic>{
            'consent_type': consentType,
            'version': version,
            'accepted': true,
          },
        );
      }
      return ConsentRecord(
        // The API returns a receipt rather than a row id. The local key is the
        // type and the version, which is what the record actually is.
        id: '${type.wire}@$version',
        consentType: type,
        version: asString(last['version'], fallback: version),
        acceptedAt: asTimestamp(last['accepted_at']) ?? _now(),
      );
    } on ApiFailure catch (failure) {
      throw _wrap(failure);
    }
  }

  // --------------------------------------------------------------- profile

  @override
  Future<HealthProfile?> loadHealthProfile() async {
    try {
      final Map<String, dynamic> me = await _api.getMap('/v1/me');
      await _cache.write(OfflineCache.account, me);
      if (!asBool(me['has_health_profile'])) {
        // The endpoint always answers with a profile, filled or not, so the
        // account flag is the only honest way to know onboarding is undone.
        return null;
      }
      final Map<String, dynamic> json = await _api.getMap('/v1/me/profile');
      return Wire.profileFrom(json, userId: asString(me['user_id']));
    } on ApiFailure catch (failure) {
      throw _wrap(failure);
    }
  }

  @override
  Future<HealthProfile> saveHealthProfile(HealthProfile profile) async {
    try {
      final Map<String, dynamic> json = await _api.putMap(
        '/v1/me/profile',
        body: Wire.profileTo(
          profile,
          displayName:
              _pendingDisplayName.isEmpty ? null : _pendingDisplayName,
        ),
      );
      final HealthProfile saved =
          Wire.profileFrom(json, userId: profile.userId);
      // `ProfileOut` carries no goals, so the ones just chosen are kept rather
      // than dropped on the way back to the wizard.
      return saved.copyWith(
        goalTypes: profile.goalTypes,
        updatedAt: _now(),
      );
    } on ApiFailure catch (failure) {
      throw _wrap(failure);
    }
  }

  // ----------------------------------------------------------------- today

  @override
  Future<TodayBriefing> loadToday(DateTime date) async {
    try {
      final Map<String, dynamic> me = await _api.getMap('/v1/me');
      final Map<String, dynamic> profileJson =
          await _api.getMap('/v1/me/profile');
      final HealthProfile profile =
          Wire.profileFrom(profileJson, userId: asString(me['user_id']));
      // generates: true -- reading today's plan builds it when there is not one
      // yet, which is a model call, not a row read.
      final Map<String, dynamic> planJson =
          await _api.getMap('/v1/plan/today', generates: true);
      final MealPlan plan =
          Wire.planFrom(planJson, mealTimes: profile.mealTimes);

      final HealthReport? latest = await _latestReport();
      List<EscalationNotice> escalations = const <EscalationNotice>[];
      String? headline;
      if (latest != null) {
        headline = _reportLine(latest);
        // The private form, so a failure here is still a raw [ApiFailure] and
        // the cache fallback below can see it.
        final HealthReport detail = await _reportDetail(latest.id);
        escalations = detail.escalations;
      }

      final TodayBriefing briefing = TodayBriefing(
        date: DateTime(date.year, date.month, date.day),
        displayName: asString(me['display_name'], fallback: _pendingDisplayName),
        wakeTime: profile.wakeTime,
        sleepTime: profile.sleepTime,
        hydrationMl: await _hydrationTotal(date),
        hydrationTargetMl: plan.hydrationTargetMl,
        meals: plan.items,
        escalations: escalations,
        planRationale: plan.rationale,
        lastReportHeadline: headline,
      );

      _fromCache.remove(CacheAware.cacheSubjectToday);
      await _cache.write(
        OfflineCache.plan,
        // Stored without escalations, on purpose. A red flag is a statement
        // about someone's health *now*; serving a stored one after a failed
        // refresh would show a finding that may already be resolved and hide a
        // new one nobody fetched.
        _withoutEscalations(briefing).toJson(),
      );
      return briefing;
    } on ApiFailure catch (failure) {
      final TodayBriefing? cached = await _cachedToday(failure, date);
      if (cached != null) {
        return cached;
      }
      throw _wrap(failure);
    }
  }

  Future<TodayBriefing?> _cachedToday(ApiFailure failure, DateTime date) async {
    if (!failure.isRetryable) {
      // A 403 or a 422 is not a connectivity problem, and answering one from
      // the cache would hide a real refusal behind stale data.
      return null;
    }
    final Cached<Map<String, dynamic>>? stored =
        await _cache.read(OfflineCache.plan);
    if (stored == null) {
      return null;
    }
    _fromCache[CacheAware.cacheSubjectToday] = stored.storedAt;
    final TodayBriefing briefing = TodayBriefing.fromJson(stored.value);
    // Escalations were never written, so this is already empty. Being explicit
    // means a future change to the cache cannot quietly resurrect one.
    return _withoutEscalations(briefing);
  }

  static TodayBriefing _withoutEscalations(TodayBriefing briefing) {
    return TodayBriefing(
      date: briefing.date,
      displayName: briefing.displayName,
      wakeTime: briefing.wakeTime,
      sleepTime: briefing.sleepTime,
      hydrationMl: briefing.hydrationMl,
      hydrationTargetMl: briefing.hydrationTargetMl,
      movementMinutes: briefing.movementMinutes,
      movementTargetMinutes: briefing.movementTargetMinutes,
      meals: briefing.meals,
      focus: briefing.focus,
      escalations: const <EscalationNotice>[],
      planRationale: briefing.planRationale,
      lastReportHeadline: briefing.lastReportHeadline,
    );
  }

  // --------------------------------------------------------------- reports

  @override
  Future<List<HealthReport>> loadReports() async {
    try {
      final Map<String, dynamic> json = await _api.getMap('/v1/reports');
      final List<HealthReport> reports = asMapList(json['reports'])
          .map(Wire.reportSummaryFrom)
          .toList();
      _fromCache.remove(CacheAware.cacheSubjectReports);
      if (reports.isNotEmpty) {
        await _cache.write(OfflineCache.latestReport, reports.first.toJson());
      }
      return reports;
    } on ApiFailure catch (failure) {
      if (failure.isRetryable) {
        final Cached<Map<String, dynamic>>? stored =
            await _cache.read(OfflineCache.latestReport);
        if (stored != null) {
          _fromCache[CacheAware.cacheSubjectReports] = stored.storedAt;
          // Only the summary line is kept, never the values: a lab number shown
          // from a cache is a lab number shown without knowing it still stands.
          return <HealthReport>[HealthReport.fromJson(stored.value)];
        }
      }
      throw _wrap(failure);
    }
  }

  @override
  Future<HealthReport> loadReport(String reportId) async {
    try {
      return await _reportDetail(reportId);
    } on ApiFailure catch (failure) {
      // Never answered from the cache. A report screen shows lab values and any
      // red flag over them; both have to be current or absent.
      throw _wrap(failure);
    }
  }

  Future<HealthReport> _reportDetail(String reportId) async {
    final Map<String, dynamic> json =
        await _api.getMap('/v1/reports/${Uri.encodeComponent(reportId)}');
    return Wire.reportDetailFrom(json);
  }

  @override
  Future<HealthReport> uploadReport({
    required String fileName,
    required String mimeType,
    required Uint8List bytes,
    void Function(int sent, int total)? onProgress,
  }) async {
    try {
      final Map<String, dynamic> json = await _api.uploadFile(
        '/v1/reports',
        field: 'file',
        filename: fileName,
        contentType: mimeType,
        bytes: bytes,
        onProgress: onProgress,
      );
      return Wire.reportDetailFrom(json);
    } on ApiFailure catch (failure) {
      throw _wrap(failure);
    }
  }

  Future<HealthReport?> _latestReport() async {
    final Map<String, dynamic> json = await _api.getMap(
      '/v1/reports',
      query: const <String, String>{'limit': '1'},
    );
    final List<Map<String, dynamic>> rows = asMapList(json['reports']);
    if (rows.isEmpty) {
      return null;
    }
    return Wire.reportSummaryFrom(rows.first);
  }

  static String _reportLine(HealthReport report) {
    final String? lab = report.labName;
    if (lab == null || lab == report.fileName) {
      return report.fileName;
    }
    return '${report.fileName} · $lab';
  }

  // ------------------------------------------------------------------ plan

  @override
  Future<MealPlan> loadPlan(DateTime date) async {
    final DateTime today = _now();
    final bool isToday = date.year == today.year &&
        date.month == today.month &&
        date.day == today.day;
    final String path = isToday
        ? '/v1/plan/today'
        : '/v1/plan/${dateToJson(date)}';
    try {
      final Map<String, dynamic> profileJson =
          await _api.getMap('/v1/me/profile');
      final Map<String, dynamic> json = await _api.getMap(path);
      final MealPlan plan = Wire.planFrom(
        json,
        mealTimes: Wire.profileFrom(profileJson, userId: '').mealTimes,
      );
      _fromCache.remove(CacheAware.cacheSubjectPlan);
      if (isToday) {
        await _cache.write(OfflineCache.mealPlan, plan.toJson());
      }
      return plan;
    } on ApiFailure catch (failure) {
      if (isToday && failure.isRetryable) {
        final Cached<Map<String, dynamic>>? stored =
            await _cache.read(OfflineCache.mealPlan);
        if (stored != null) {
          _fromCache[CacheAware.cacheSubjectPlan] = stored.storedAt;
          return MealPlan.fromJson(stored.value);
        }
      }
      throw _wrap(failure);
    }
  }

  /// Mark one item of a plan done or skipped.
  ///
  /// The body carries exactly the two fields `PlanItemProgressIn` allows —
  /// `plan_id` and `state` — because that model is declared `extra="forbid"`,
  /// so an extra field is a 422 rather than something quietly ignored. The
  /// reply is a receipt for what was written and holds nothing a screen needs,
  /// so nothing is returned: the interface asked a question and got an answer,
  /// and that is the whole contract.
  @override
  Future<void> markPlanItem({
    required String planId,
    required String itemId,
    required bool done,
  }) async {
    try {
      await _api.postMap(
        '/v1/feedback/plan-items/${Uri.encodeComponent(itemId)}',
        body: <String, dynamic>{
          'plan_id': planId,
          'state': done ? 'done' : 'skipped',
        },
      );
    } on ApiFailure catch (failure) {
      throw _wrap(failure);
    }
  }

  /// No endpoint yet. An empty list is the truthful answer; a plausible one
  /// made up on the client is not.
  @override
  Future<List<Goal>> loadGoals() async => const <Goal>[];

  /// The API exposes no biomarker history. Charting one from the single report
  /// the app can see would be drawing a trend from one point.
  @override
  Future<List<BiomarkerTrend>> loadTrends() async => const <BiomarkerTrend>[];

  // ------------------------------------------------------------------ chat

  @override
  Future<List<ChatMessage>> loadMessages() async {
    try {
      final List<dynamic> threads = await _api.getList('/v1/chat/threads');
      if (threads.isEmpty) {
        return const <ChatMessage>[];
      }
      final Object? first = threads.first;
      final String threadId =
          first is Map ? asString(first.cast<String, dynamic>()['id']) : '';
      if (threadId.isEmpty) {
        return const <ChatMessage>[];
      }
      _threadId = threadId;
      final List<dynamic> rows = await _api.getList(
        '/v1/chat/threads/${Uri.encodeComponent(threadId)}/messages',
      );
      return rows
          .whereType<Map<dynamic, dynamic>>()
          .map((Map<dynamic, dynamic> row) =>
              Wire.chatMessageFrom(row.cast<String, dynamic>()))
          .toList();
    } on ApiFailure catch (failure) {
      throw _wrap(failure);
    }
  }

  @override
  Future<ChatMessage> sendMessage(
    String text, {
    List<String> attachments = const <String>[],
  }) async {
    final String message = text.trim();
    if (message.isEmpty) {
      throw const HealthRepositoryException(
        'There is nothing in that message to send.',
      );
    }
    if (message.length > _maxMessageChars) {
      // Checked here so a long message is refused kindly rather than by a 422.
      throw const HealthRepositoryException(
        'That message is longer than we can send in one go. Try splitting it '
        'in two.',
      );
    }
    try {
      final Map<String, dynamic> json = await _api.postMap(
        '/v1/chat/messages',
        body: <String, dynamic>{
          'message': message,
          if (_threadId != null) 'thread_id': _threadId,
          // The interface passes report ids; the file itself is never re-sent,
          // because the backend already read it once.
          'attachment_report_ids': attachments.take(5).toList(),
        },
      );
      final ChatMessage reply = Wire.replyFrom(json);
      _threadId = reply.threadId ?? _threadId;
      return reply;
    } on ApiFailure catch (failure) {
      throw _wrap(failure);
    }
  }

  static const int _maxMessageChars = 4000;

  // ------------------------------------------------------- hydration, alerts

  /// The one running total the app owns.
  ///
  /// There is no endpoint to log a glass of water against — the plan carries a
  /// hydration *target* and nothing to count towards it — so the tally lives on
  /// the phone, per calendar day, and is presented as the user's own count
  /// rather than as anything the backend computed.
  @override
  Future<double> logHydration(double millilitres) async {
    final DateTime today = _now();
    final double total = await _hydrationTotal(today) + millilitres;
    await _cache.write(
      OfflineCache.hydrationFor(today),
      <String, dynamic>{'ml': total},
    );
    return total;
  }

  Future<double> _hydrationTotal(DateTime date) async {
    final Cached<Map<String, dynamic>>? stored =
        await _cache.read(OfflineCache.hydrationFor(date));
    if (stored == null) {
      return 0;
    }
    return asDouble(stored.value['ml']);
  }

  @override
  Future<AlertPlan> loadAlerts() async {
    try {
      final Map<String, dynamic> json = await _api.getMap('/v1/alerts');
      await _cache.write(OfflineCache.alerts, json);
      return Wire.alertsFrom(json);
    } on ApiFailure catch (failure) {
      if (failure.isRetryable) {
        // Alerts are the one thing that is *safer* to use stale: they are
        // reminders built from the user's own times, they contain no finding,
        // and a phone that keeps yesterday's meal reminder is behaving exactly
        // as an offline-first reminder should.
        final Cached<Map<String, dynamic>>? stored =
            await _cache.read(OfflineCache.alerts);
        if (stored != null) {
          return Wire.alertsFrom(stored.value);
        }
      }
      throw _wrap(failure);
    }
  }

  /// `PATCH /v1/alerts/{alert_type}` with the one field the endpoint allows.
  ///
  /// `ToggleIn` is declared `extra="forbid"` in `backend/app/api/alerts.py`, so
  /// anything sent beside `enabled` is a 422 rather than something quietly
  /// dropped. The reply is the whole alert list again — the same shape
  /// `GET /v1/alerts` answers with — so the fresh copy is cached exactly as a
  /// read would be, and the phone never has to guess what changed.
  ///
  /// Switching off an escalation is refused by the server, which is the point:
  /// a card telling somebody to see a doctor is not a preference.
  @override
  Future<AlertPlan> setAlertEnabled(
    String alertType, {
    required bool enabled,
  }) async {
    try {
      final Map<String, dynamic> json = await _api.patchMap(
        '/v1/alerts/${Uri.encodeComponent(alertType)}',
        body: <String, dynamic>{'enabled': enabled},
      );
      await _cache.write(OfflineCache.alerts, json);
      return Wire.alertsFrom(json);
    } on ApiFailure catch (failure) {
      throw _wrap(failure);
    }
  }

  /// `PUT /v1/alerts/quiet-hours`, which answers with the whole list again.
  ///
  /// `QuietHoursIn` forbids extra fields too, and it validates both times, so
  /// only `start` and `end` are sent and both are the 24-hour `HH:mm` the
  /// backend parses. Nothing here decides which reminders the window covers:
  /// the reply already says, per alert, whether quiet hours will hold it.
  @override
  Future<AlertPlan> setQuietHours({
    required String start,
    required String end,
  }) async {
    try {
      final Map<String, dynamic> json = await _api.putMap(
        '/v1/alerts/quiet-hours',
        body: <String, dynamic>{'start': start, 'end': end},
      );
      await _cache.write(OfflineCache.alerts, json);
      return Wire.alertsFrom(json);
    } on ApiFailure catch (failure) {
      throw _wrap(failure);
    }
  }

  /// `GET /v1/privacy/export` — the whole record, as one JSON object.
  ///
  /// Two deliberate choices. It is asked for on the long timeout, because this
  /// reads every table the account owns and the free host may have to wake up
  /// first, and twenty seconds is the budget for reading a row rather than for
  /// reading a life. And nothing is cached: this is the complete health record,
  /// and the one place it belongs is the file the person chose to save it to.
  @override
  Future<Map<String, dynamic>> exportEverything() async {
    try {
      return await _api.getMap('/v1/privacy/export', generates: true);
    } on ApiFailure catch (failure) {
      throw _wrap(failure);
    }
  }

  ApiRepositoryException _wrap(ApiFailure failure) =>
      ApiRepositoryException(failure);
}

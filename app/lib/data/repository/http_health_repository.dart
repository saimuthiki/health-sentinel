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
  ApiRepositoryException(this.failure, {String? message})
      : super(message ?? failure.message);

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
/// * **No number is composed here.** Day nutrient totals, targets and trends
///   have no endpoint yet, so they come back empty rather than added up on the
///   phone. [loadGoals] is still empty for the same reason — the profile now
///   carries which goals are active, but there is no endpoint returning them as
///   `Goal` rows with their own ids, titles and progress.
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
      // `ProfileOut` now carries the goals and the PIN code back, so what the
      // screen shows after a save is what the server actually holds — not the
      // request echoed at the user. If the two ever disagree, the disagreement
      // is visible, which is the point.
      return Wire.profileFrom(json, userId: profile.userId)
          .copyWith(updatedAt: _now());
    } on ApiFailure catch (failure) {
      throw _wrap(failure);
    }
  }

  // ----------------------------------------------------------------- today

  @override
  Future<TodayBriefing> loadToday(DateTime date) async {
    try {
      // Before anything is read: a glass tapped with no signal last night is
      // owed to the server, and opening the app is when the signal came back.
      // Best effort - it can add to the day, and it can never break it.
      await _flushPendingDrinks();
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
        escalations = await _escalationsFor(latest.id);
      }

      final TodayBriefing briefing = TodayBriefing(
        date: DateTime(date.year, date.month, date.day),
        displayName: asString(me['display_name'], fallback: _pendingDisplayName),
        wakeTime: profile.wakeTime,
        sleepTime: profile.sleepTime,
        // The server's figure for the day, plus anything this phone has not
        // managed to send yet. Not the cache: the cache is now a copy of this
        // number for when the network is gone, not the number itself.
        hydrationMl: plan.hydrationLoggedMl + await _pendingTotalFor(date),
        // The goal, and everything the server says about it. `null` here means
        // the server will not give a goal for this profile, and that travels
        // through as null so the screen can show the reason and no bar.
        hydrationTargetMl: plan.hydrationGoal.millilitres,
        hydrationTargetSourcedMl: plan.hydrationGoal.sourcedMillilitres,
        hydrationTargetChosenByUser: plan.hydrationGoal.chosenByUser,
        hydrationTargetSource: plan.hydrationGoal.source,
        hydrationTargetCaution: plan.hydrationGoal.caution,
        meals: plan.items,
        escalations: escalations,
        planRationale: plan.rationale,
        lastReportHeadline: headline,
      );

      _fromCache.remove(CacheAware.cacheSubjectToday);
      // The server's own figure, kept for the train. It is a copy, not a tally.
      await _writeDayTotal(date, plan.hydrationLoggedMl);
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
      hydrationTargetSourcedMl: briefing.hydrationTargetSourcedMl,
      hydrationTargetChosenByUser: briefing.hydrationTargetChosenByUser,
      hydrationTargetSource: briefing.hydrationTargetSource,
      hydrationTargetCaution: briefing.hydrationTargetCaution,
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

  /// The latest report's red flags, or one card saying they could not be read.
  ///
  /// This used to be a bare `await _reportDetail(...)`, and it is where the day went
  /// when one report answered 500: the failure travelled out of [loadToday], past the
  /// plan and the profile that had already loaded fine, and the person was told Today
  /// could not be loaded. One report's detail is not the day.
  ///
  /// Surviving it must not turn into a quiet all-clear, so the failure is not swallowed:
  /// it becomes [Wire.uncheckedFindingsNotice], which lands in `escalations` and renders
  /// as an escalation card above everything else, exactly where a real finding would.
  /// The person is told the difference between *nothing found* and *not checked*.
  ///
  /// Two failures are still let through, because neither is something this screen can
  /// work around: an expired sign-in and a missing consent both have to stop the app and
  /// send the person somewhere else.
  Future<List<EscalationNotice>> _escalationsFor(String reportId) async {
    try {
      final HealthReport detail = await _reportDetail(reportId);
      return detail.escalations;
    } on ApiFailure catch (failure) {
      if (failure.requiresSignIn ||
          failure.kind == ApiFailureKind.consentRequired) {
        rethrow;
      }
      return <EscalationNotice>[Wire.uncheckedFindingsNotice(raisedAt: _now())];
    }
  }

  Future<HealthReport> _reportDetail(String reportId) async {
    final Map<String, dynamic> json =
        await _api.getMap('/v1/reports/${Uri.encodeComponent(reportId)}');
    return Wire.reportDetailFrom(json);
  }

  /// Confirm one value, and return nothing.
  ///
  /// The body carries the single field `ConfirmIn` defines. The reply is a
  /// receipt naming the row and the answer, and holds nothing the screen does
  /// not already know, so it is not returned: what the screen shows next comes
  /// from fetching the report again, which is the only thing that can say what
  /// the backend actually stored.
  @override
  Future<void> confirmResult({
    required String reportId,
    required String resultId,
  }) async {
    try {
      await _api.postMap(
        '/v1/reports/${Uri.encodeComponent(reportId)}'
        '/results/${Uri.encodeComponent(resultId)}/confirm',
        body: const <String, dynamic>{'confirmed': true},
      );
    } on ApiFailure catch (failure) {
      throw _wrap(failure);
    }
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

  // ---------------------------------------------------------------- tastes

  @override
  Future<String> logMeal({
    MealSlot? mealSlot,
    String? foodId,
    String? freeText,
    String source = 'manual',
  }) async {
    try {
      final Map<String, dynamic> json = await _api.postMap(
        '/v1/feedback/meals',
        body: Wire.logMealBody(
          mealSlot: mealSlot,
          foodId: foodId,
          freeText: freeText,
          source: source,
        ),
      );
      return asString(json['id']);
    } on ApiFailure catch (failure) {
      throw _wrap(failure);
    }
  }

  /// A POST, and one that is never replayed on a timeout — see [ApiClient].
  ///
  /// That is the right trade here even though the write itself is idempotent:
  /// the rating replaces, but this call is only ever made against a food log
  /// this session created, and a silent replay of a call whose reply is what
  /// the screen says out loud is not worth the second sentence it could
  /// produce. A person who wants to try again taps again.
  @override
  Future<MealRating> rateMeal({
    required String foodLogId,
    required int rating,
  }) async {
    try {
      final Map<String, dynamic> json = await _api.postMap(
        '/v1/feedback/meals/${Uri.encodeComponent(foodLogId)}/rating',
        body: <String, dynamic>{'rating': rating},
      );
      return Wire.ratingFrom(json);
    } on ApiFailure catch (failure) {
      throw _wrap(failure);
    }
  }

  @override
  Future<List<FoodPreference>> loadFoodPreferences() async {
    try {
      final Map<String, dynamic> json =
          await _api.getMap('/v1/feedback/preferences');
      return Wire.preferencesFrom(json);
    } on ApiFailure catch (failure) {
      throw _wrap(failure);
    }
  }

  /// A PUT, so the client is allowed to replay it after a dropped connection:
  /// sending the same stance twice leaves exactly the same row.
  @override
  Future<FoodPreference> setFoodPreference({
    required String foodId,
    required TasteStance stance,
  }) async {
    try {
      final Map<String, dynamic> json = await _api.putMap(
        '/v1/feedback/preferences/${Uri.encodeComponent(foodId)}',
        // The rating, not the stance. The backend owns where the boundaries
        // between liked, neutral and disliked sit, and sending a stance would
        // put a second copy of that judgement on the phone.
        body: <String, dynamic>{'rating': stance.rating},
      );
      return Wire.preferenceFrom(json);
    } on ApiFailure catch (failure) {
      throw _wrap(failure);
    }
  }

  // --------------------------------------------------------------- grocery

  /// `GET /v1/grocery` — the current week, as the backend decides which week
  /// that is.
  ///
  /// No `week_start` is sent: the endpoint defaults to the week containing
  /// today, and a phone that worked out its own Monday would eventually
  /// disagree with the server about which week it is standing in.
  ///
  /// Not cached, unlike Today and the plan. A shopping list read out of a cache
  /// would show ticks that may since have changed on another device, and the
  /// harm of that — believing a thing is already in the kitchen when it is not
  /// — is exactly the harm this feature exists to prevent.
  @override
  Future<GroceryList> loadGroceryList() async {
    try {
      return GroceryList.fromJson(await _api.getMap('/v1/grocery'));
    } on ApiFailure catch (failure) {
      throw _wrap(failure);
    }
  }

  /// `PATCH /v1/grocery/items/{item_id}` with the one field `StateIn` allows.
  ///
  /// The reply is read for its `state` and nothing else. See the interface for
  /// why: the endpoint composes its answer without the name lookup, so every
  /// other field on it is either unchanged or blank.
  @override
  Future<GroceryState> setGroceryItemState({
    required String itemId,
    required GroceryState state,
  }) async {
    try {
      final Map<String, dynamic> json = await _api.patchMap(
        '/v1/grocery/items/${Uri.encodeComponent(itemId)}',
        body: <String, dynamic>{'state': state.wire},
      );
      return GroceryState.fromWire(json['state']);
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

  /// `POST /v1/feedback/hydration` — one drink, recorded on the server.
  ///
  /// This used to add the millilitres to the phone's own cache and call nothing
  /// at all, which meant water was lost on reinstall, invisible on a second
  /// device, and never seen by the backend — and it is why the weekly summary
  /// honestly refused to report hydration.
  ///
  /// The cache is still here, and it is still the offline path, but it is no
  /// longer the source of truth. The order is: send anything already queued,
  /// send this glass, keep the server's total. If the network refuses in a way
  /// that trying again could fix, the glass is **queued** and counted straight
  /// away, so somebody tapping "a glass" on a train neither loses it nor is told
  /// it failed. If the refusal is one replaying could never fix — a signed-out
  /// session, a body the server will not take — it is thrown, and nothing is
  /// kept, because keeping it silently on the phone is precisely the bug.
  @override
  Future<double> logHydration(double millilitres) async {
    final int amount = millilitres.round();
    if (amount <= 0) {
      throw const HealthRepositoryException(
        'There is nothing there to add to today’s water.',
      );
    }
    final DateTime today = _now();
    try {
      // Queued glasses first, so the server hears about them in the order they
      // were drunk rather than in the order the signal came back.
      await _sendPendingDrinks();
      final int total = await _sendDrink(today, amount);
      await _writeDayTotal(today, total.toDouble());
      return total.toDouble() + await _pendingTotalFor(today);
    } on ApiFailure catch (failure) {
      if (failure.isRetryable) {
        return _queueDrink(today, amount);
      }
      throw _wrap(failure);
    }
  }

  /// `PUT /v1/plan/hydration-target` — this person's own daily water goal.
  ///
  /// Nothing about the envelope is decided here. The server stores the number
  /// exactly as typed, attaches its own warning above the published intake
  /// range, refuses above its ceiling, and gives no goal at all where fluid
  /// intake is a doctor's decision; this method sends a number and returns what
  /// came back. A `null` clears the goal and puts the sourced figure back.
  ///
  /// The one place this differs from every other call in this file is the
  /// refusal. Normally a server sentence is never shown and [ApiFailure] carries
  /// our own copy instead — see `api_failure.dart` for why. A 422 from *this*
  /// endpoint is the exception, for the same reason a red flag's `message` is
  /// shown word for word: the text is deterministic, curated, cited and written
  /// for the person who typed the number, and our own "something on that form
  /// was not in a shape we could use" would replace "6500 ml is more than we
  /// will set a goal for, and here is why" with nothing at all. Only the 422 is
  /// treated this way, and only when the server actually sent a reason.
  @override
  Future<HydrationGoal> setHydrationTarget(int? millilitres) async {
    try {
      final Map<String, dynamic> json = await _api.putMap(
        '/v1/plan/hydration-target',
        body: Wire.hydrationTargetBody(millilitres),
      );
      return Wire.hydrationGoalFrom(json);
    } on ApiFailure catch (failure) {
      throw _refusedGoal(failure);
    }
  }

  ApiRepositoryException _refusedGoal(ApiFailure failure) {
    final String reason = (failure.serverDetail ?? '').trim();
    if (failure.kind != ApiFailureKind.invalidRequest || reason.isEmpty) {
      return _wrap(failure);
    }
    return ApiRepositoryException(failure, message: reason);
  }

  /// One calendar day as the backend writes one. Never null: [dateToJson] only
  /// answers null for a null date, and there is none here.
  static String _dayKey(DateTime date) =>
      dateToJson(DateTime(date.year, date.month, date.day))!;

  /// One drink, sent. Answers with the day's total as the server now holds it.
  Future<int> _sendDrink(DateTime day, int millilitres) async {
    final Map<String, dynamic> json = await _api.postMap(
      '/v1/feedback/hydration',
      body: <String, dynamic>{
        'millilitres': millilitres,
        // Sent rather than left to default to "today", so a glass queued last
        // night and sent this morning still lands on last night.
        'on': _dayKey(day),
      },
    );
    return asInt(json['day_total_ml']);
  }

  /// Send everything queued, oldest first, emptying the queue as it goes.
  ///
  /// Each entry is removed **before** its total is written, so a process killed
  /// between the two loses a number on a bar rather than sending a glass twice.
  /// A queued drink the server refuses outright is dropped — one bad entry must
  /// not jam the queue behind it for ever — and the refusal is rethrown, so
  /// nobody is told it was saved.
  Future<void> _sendPendingDrinks() async {
    List<Map<String, dynamic>> queued = await _pendingDrinks();
    while (queued.isNotEmpty) {
      final Map<String, dynamic> first = queued.first;
      final DateTime? on = asDate(first['on']);
      final int millilitres = asInt(first['ml']);
      final List<Map<String, dynamic>> rest = queued.sublist(1);
      if (on == null || millilitres <= 0) {
        // Not something we can send. It is not evidence of anything either.
        await _writePendingDrinks(rest);
        queued = rest;
        continue;
      }
      try {
        final int total = await _sendDrink(on, millilitres);
        await _writePendingDrinks(rest);
        await _writeDayTotal(on, total.toDouble());
      } on ApiFailure catch (failure) {
        if (!failure.isRetryable) {
          // It will never be accepted, so it must not sit at the head of the
          // queue for ever. Dropped here, and still reported below.
          await _writePendingDrinks(rest);
        }
        rethrow;
      }
      queued = rest;
    }
  }

  /// Keep a glass that could not be sent, and answer with today's total anyway.
  Future<double> _queueDrink(DateTime day, int millilitres) async {
    final DateTime on = DateTime(day.year, day.month, day.day);
    final List<Map<String, dynamic>> queued = <Map<String, dynamic>>[
      ...await _pendingDrinks(),
      <String, dynamic>{'on': _dayKey(on), 'ml': millilitres},
    ];
    await _writePendingDrinks(queued);
    return await _storedDayTotal(on) + await _pendingTotalFor(on);
  }

  /// Try to empty the queue, and never fail a screen for it.
  ///
  /// Called on the way into [loadToday]: opening the app with signal is the
  /// commonest moment for last night's queued glass to get through, and the
  /// person did not ask for it, so it must not be able to break the day.
  Future<void> _flushPendingDrinks() async {
    try {
      await _sendPendingDrinks();
    } on ApiFailure {
      // Still queued, still counted on screen, tried again next time.
    }
  }

  Future<List<Map<String, dynamic>>> _pendingDrinks() async {
    final Cached<Map<String, dynamic>>? stored =
        await _cache.read(OfflineCache.pendingHydration);
    if (stored == null) {
      return <Map<String, dynamic>>[];
    }
    return asMapList(stored.value['drinks']);
  }

  Future<void> _writePendingDrinks(List<Map<String, dynamic>> drinks) async {
    await _cache.write(
      OfflineCache.pendingHydration,
      <String, dynamic>{'drinks': drinks},
    );
  }

  /// What is still owed to one day, in millilitres.
  Future<double> _pendingTotalFor(DateTime date) async {
    final String key = _dayKey(date);
    double total = 0;
    for (final Map<String, dynamic> drink in await _pendingDrinks()) {
      if (asString(drink['on']) == key) {
        total += asDouble(drink['ml']);
      }
    }
    return total;
  }

  /// The last total the server gave for this day, or zero if it never has.
  Future<double> _storedDayTotal(DateTime date) async {
    final Cached<Map<String, dynamic>>? stored =
        await _cache.read(OfflineCache.hydrationFor(date));
    if (stored == null) {
      return 0;
    }
    return asDouble(stored.value['ml']);
  }

  Future<void> _writeDayTotal(DateTime date, double millilitres) async {
    await _cache.write(
      OfflineCache.hydrationFor(date),
      <String, dynamic>{'ml': millilitres},
    );
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

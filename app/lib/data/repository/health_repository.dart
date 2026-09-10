import 'dart:typed_data';

import '../../services/alert_schedule.dart';
import '../models/models.dart';

/// Everything the interface needs from the outside world, in one place.
///
/// The app never talks to Supabase's database or to Gemini directly: it talks to
/// our FastAPI backend, which is the only place that holds secrets and the only
/// place the safety validator can run where a modified APK cannot skip it. This
/// interface is what the screens depend on, so Phase 1 can be built and tested
/// against [FakeHealthRepository] and the HTTP implementation can drop in behind
/// it without a single screen changing.
abstract class HealthRepository {
  /// The signed-in user, or null. Never throws for "not signed in".
  Future<AuthSession?> restoreSession();

  Future<AuthSession> signIn({
    required String email,
    required String password,
  });

  Future<AuthSession> signUp({
    required String email,
    required String password,
    required String displayName,
  });

  Future<void> signOut();

  /// Writes a row to `consents` with the version of the text that was shown.
  Future<ConsentRecord> recordConsent(
    ConsentType type, {
    required String version,
  });

  /// Null until onboarding has been completed.
  Future<HealthProfile?> loadHealthProfile();

  Future<HealthProfile> saveHealthProfile(HealthProfile profile);

  Future<TodayBriefing> loadToday(DateTime date);

  Future<List<HealthReport>> loadReports();

  Future<HealthReport> loadReport(String reportId);

  Future<MealPlan> loadPlan(DateTime date);

  /// Record that one item of a plan was eaten, or was not.
  ///
  /// `POST /v1/feedback/plan-items/{item_id}` is the observed half of the
  /// learning loop: what the plan suggested and what actually happened are kept
  /// as two separate facts, so this writes to an append-only trail rather than
  /// changing the plan. [done] false is the honest opposite of "I ate this" —
  /// the backend records it as `skipped` — and it is what an undo, or a change
  /// of mind about which option in a meal was eaten, has to send.
  Future<void> markPlanItem({
    required String planId,
    required String itemId,
    required bool done,
  });

  Future<List<Goal>> loadGoals();

  Future<List<BiomarkerTrend>> loadTrends();

  Future<List<ChatMessage>> loadMessages();

  Future<ChatMessage> sendMessage(String text, {List<String> attachments});

  /// Adds to today's hydration total and returns the new total in millilitres.
  Future<double> logHydration(double millilitres);

  /// The reminders the phone should schedule for itself.
  ///
  /// The server says what and when — including whether an alert falls inside
  /// quiet hours — and the device does the scheduling, so reminders keep
  /// arriving with the app closed, with no signal, and with the backend asleep.
  Future<AlertPlan> loadAlerts();

  /// Turn one kind of reminder on or off, and get the whole plan back.
  ///
  /// [alertType] is the wire string the backend uses — `hydration`, `meal`,
  /// `sleep` and the rest — not a display name. The reply is the complete plan
  /// as it now stands, including which alerts quiet hours will hold, because
  /// that judgement is made on the server and working it out again on the phone
  /// is how two answers to one question get started.
  ///
  /// Escalations — the reminders that say a result needs a doctor — cannot be
  /// switched off, and asking to is refused rather than quietly ignored.
  Future<AlertPlan> setAlertEnabled(
    String alertType, {
    required bool enabled,
  });

  /// Set the window in which the phone stays quiet, and get the plan back.
  ///
  /// Both times are 24-hour `HH:mm`. A window that crosses midnight — 22:30 to
  /// 06:00, which is the ordinary case — is perfectly acceptable; deciding what
  /// falls inside it is the server's job and not this app's.
  Future<AlertPlan> setQuietHours({
    required String start,
    required String end,
  });

  /// Everything the backend holds about this account, as one JSON document.
  ///
  /// This is the whole health record — profile, reports, values, plans, chat,
  /// consents — so it is fetched when it is asked for, handed straight to
  /// whoever asked, and never written to the app's own storage: a second copy
  /// of somebody's medical history that they did not ask for is exactly what
  /// this app must not leave lying about.
  Future<Map<String, dynamic>> exportEverything();

  /// Send one report file and get back what came out of it.
  ///
  /// [onProgress] reports bytes leaving the phone, which is not the same as the
  /// report being read: extraction happens after the last byte lands, and the
  /// upload screen says so rather than sitting on a full bar.
  Future<HealthReport> uploadReport({
    required String fileName,
    required String mimeType,
    required Uint8List bytes,
    void Function(int sent, int total)? onProgress,
  });
}

/// Implemented by a repository that can answer from a local copy.
///
/// The interface exists so a screen can ask "was this off the network, or off
/// this phone, and how old is it" — and then say so. Anything served from a
/// cache is labelled; nothing cached is ever presented as current. Repositories
/// that never cache (the fake) simply do not implement it.
abstract class CacheAware {
  /// When the data last returned for [subject] was fetched from the backend, or
  /// null when the last answer came straight off the network.
  ///
  /// [subject] is one of [cacheSubjectToday], [cacheSubjectPlan],
  /// [cacheSubjectReports].
  DateTime? servedFromCacheAt(String subject);

  static const String cacheSubjectToday = 'today';
  static const String cacheSubjectPlan = 'plan';
  static const String cacheSubjectReports = 'reports';
}

/// Thrown for problems the interface should explain rather than swallow.
class HealthRepositoryException implements Exception {
  const HealthRepositoryException(this.message);

  /// Written for the person reading it: what happened and what fixes it.
  final String message;

  @override
  String toString() => message;
}

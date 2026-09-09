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

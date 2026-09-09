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
}

/// Thrown for problems the interface should explain rather than swallow.
class HealthRepositoryException implements Exception {
  const HealthRepositoryException(this.message);

  /// Written for the person reading it: what happened and what fixes it.
  final String message;

  @override
  String toString() => message;
}

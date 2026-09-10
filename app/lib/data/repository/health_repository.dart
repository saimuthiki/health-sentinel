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

  /// Say that a value the report reader was unsure about really is what the
  /// report says.
  ///
  /// `POST /v1/reports/{report_id}/results/{result_id}/confirm` accepts one
  /// thing: a yes. It clears the "please check this" flag on that row and
  /// records that a person decided it, not the app. It does **not** carry a
  /// corrected value, and there is no endpoint that does - so nothing built on
  /// top of this may look like an edit, or a person will type a number in and
  /// watch it be thrown away.
  ///
  /// [resultId] is [LabResult.rowId], the row's id in the backend's
  /// `lab_results` table. Nothing else addresses the row.
  Future<void> confirmResult({
    required String reportId,
    required String resultId,
  });

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

  /// Write down that a meal was eaten, and get back the id of that entry.
  ///
  /// `POST /v1/feedback/meals`. Either [foodId] or [freeText] must say what it
  /// was — the endpoint refuses a row that says neither, because a meal nobody
  /// can name is not a fact about anybody's day.
  ///
  /// Only the id comes back, deliberately. It is the one thing a caller needs
  /// (it is what [rateMeal] addresses) and the only field of the reply that is
  /// not simply the request read back.
  ///
  /// **Call this once per meal.** `app/planner/context.py` sums `food_logs` to
  /// work out what has already been eaten today, so a second row for the same
  /// plate double-counts its nutrients and pulls the day's gap report — and
  /// therefore tomorrow's plan — out of shape. To change a rating, re-send
  /// [rateMeal] against the same id; that is a correction and the backend
  /// stores it as one.
  Future<String> logMeal({
    MealSlot? mealSlot,
    String? foodId,
    String? freeText,
    String source,
  });

  /// Say what one logged meal was worth, on the 1–5 the planner reads.
  ///
  /// `POST /v1/feedback/meals/{food_log_id}/rating`. Rating the same meal again
  /// replaces the answer rather than adding one, so a mistap is correctable —
  /// it used to be a 409.
  ///
  /// The reply is the point. [MealRating.preferenceUpdated] is false, with no
  /// stance, when the logged meal has no food behind it: the rating is kept,
  /// but nothing the planner reads has moved. A caller must say that plainly
  /// rather than claim a lesson was learned. Use [TasteStance.rating] to pick
  /// the number rather than writing one in.
  Future<MealRating> rateMeal({
    required String foodLogId,
    required int rating,
  });

  /// Every food this app has formed a belief about, by name.
  ///
  /// `GET /v1/feedback/preferences`. This is the read behind the tastes screen,
  /// and it exists because a belief nobody can see is worse than no belief: the
  /// planner drops a disliked food silently, so without this the only evidence
  /// is a plan that quietly stopped offering something.
  Future<List<FoodPreference>> loadFoodPreferences();

  /// Change what we believe about one food, and get the row back as it now is.
  ///
  /// `PUT /v1/feedback/preferences/{food_id}`. A correction with no meal
  /// attached — changing your mind about soya is not the same as eating soya,
  /// and if the only way to say so were to log one, every correction would add
  /// a portion to the day's intake.
  ///
  /// There is no delete, and none is needed: [TasteStance.okay] is neutral at
  /// 3.0, which the planner's filter does not act on and its ranking gives
  /// nothing to. That is a real "forget this", reached by the same three
  /// buttons as everything else.
  Future<FoodPreference> setFoodPreference({
    required String foodId,
    required TasteStance stance,
  });

  /// This week's shopping list, grouped into aisles by the backend.
  ///
  /// `GET /v1/grocery` builds the list the first time it is asked for by adding
  /// up the portions of the meals already planned for that week. So it is
  /// derived from the plan — which is itself built from the profile, the lab
  /// findings and the food preferences — and not a fixed list of healthy
  /// things. Nothing is invented here or on the server: a week with no planned
  /// days answers with no items, and that is the honest answer.
  Future<GroceryList> loadGroceryList();

  /// Say whether one line is needed, already at home, or bought.
  ///
  /// `PATCH /v1/grocery/items/{item_id}` carries the single field `StateIn`
  /// allows, and that model is declared `extra="forbid"`, so anything else is a
  /// 422 rather than something quietly dropped.
  ///
  /// Only the state comes back, deliberately. The endpoint answers with a
  /// `GroceryItemOut` built without the reference-table lookup the read does,
  /// so its `name` is always the empty string; a caller handed that whole
  /// object would sooner or later use it to redraw the line and blank the
  /// label. Returning the one field the reply can be trusted for makes that
  /// mistake impossible to make.
  Future<GroceryState> setGroceryItemState({
    required String itemId,
    required GroceryState state,
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

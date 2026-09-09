import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config/app_config.dart';
import '../services/alert_schedule.dart';
import '../services/auth_service.dart';
import '../services/notification_service.dart';
import 'api/api_client.dart';
import 'api/api_status.dart';
import 'cache/offline_cache.dart';
import 'models/models.dart';
import 'repository/fake_health_repository.dart';
import 'repository/health_repository.dart';
import 'repository/http_health_repository.dart';

/// What this build was told at compile time. Overridden in tests.
final appConfigProvider = Provider<AppConfig>((ref) {
  return AppConfig.fromEnvironment;
});

/// Why startup could not connect, in our own words, or null when it did.
///
/// A sentence rather than the bootstrap object itself, so that `data/` need not
/// import `core/bootstrap.dart`, which imports back into here.
final startupErrorProvider = Provider<String?>((ref) => null);

/// Supabase, once it has been initialised in `bootstrap()`.
///
/// Null until then, and null forever in a build with no configuration — which
/// is exactly what keeps the app on the fake repository instead of throwing on
/// the first request.
final authGatewayProvider = Provider<AuthGateway?>((ref) => null);

/// The offline store. The real one is injected by `bootstrap()`; the in-memory
/// one keeps tests and unconfigured builds off the sqflite platform channel.
final offlineCacheProvider = Provider<OfflineCache>((ref) {
  final OfflineCache cache = MemoryOfflineCache();
  ref.onDispose(cache.close);
  return cache;
});

/// Our own backend, or null when this build has no address for one.
final apiClientProvider = Provider<ApiClient?>((ref) {
  final AppConfig config = ref.watch(appConfigProvider);
  final AuthGateway? auth = ref.watch(authGatewayProvider);
  final Uri? base = config.apiBase;
  if (!config.isReady || base == null || auth == null) {
    return null;
  }
  final ApiClient client = ApiClient(baseUrl: base, tokens: auth);
  ref.onDispose(client.close);
  return client;
});

/// The single seam between the interface and the outside world.
///
/// [FakeHealthRepository] is still the default, and it is what every widget test
/// runs against. The real service takes over when — and only when — this build
/// was given an address and Supabase came up: one condition, no screen changes,
/// and an unconfigured APK that shows sample data rather than a crash.
final healthRepositoryProvider = Provider<HealthRepository>((ref) {
  final ApiClient? api = ref.watch(apiClientProvider);
  final AuthGateway? auth = ref.watch(authGatewayProvider);
  if (api == null || auth == null) {
    return FakeHealthRepository();
  }
  return HttpHealthRepository(
    api: api,
    auth: auth,
    cache: ref.watch(offlineCacheProvider),
  );
});

/// Changes in what the connection is doing.
final apiPhaseStreamProvider = StreamProvider<ApiPhase>((ref) {
  final ApiClient? api = ref.watch(apiClientProvider);
  if (api == null) {
    return Stream<ApiPhase>.value(ApiPhase.idle);
  }
  return api.phases;
});

/// The phase to draw right now, including before the first event arrives.
///
/// This is what turns a fifty-second Render cold start from a spinner that looks
/// broken into a screen that says what is happening.
final apiPhaseProvider = Provider<ApiPhase>((ref) {
  final ApiClient? api = ref.watch(apiClientProvider);
  return ref.watch(apiPhaseStreamProvider).value ?? api?.phase ?? ApiPhase.idle;
});

/// Sign-ins, sign-outs and token refreshes, wherever they happen.
final authLifecycleProvider = StreamProvider<AuthLifecycle>((ref) {
  final AuthGateway? auth = ref.watch(authGatewayProvider);
  if (auth == null) {
    return Stream<AuthLifecycle>.empty();
  }
  return auth.lifecycle;
});

/// The phone's own alarm scheduler.
final notificationServiceProvider = Provider<NotificationService>((ref) {
  return NotificationService(cache: ref.watch(offlineCacheProvider));
});

/// Fetch the alert definitions and hand them to Android.
///
/// Watched from Today once there is a plan on screen, which is the moment the
/// notification permission request makes sense — the person is looking at times
/// they asked for, so "shall we remind you?" answers itself. Asking on first
/// launch, before any of that exists, is how an app earns a permanent refusal.
final scheduledRemindersProvider = FutureProvider<int>((ref) async {
  if (ref.watch(apiClientProvider) == null) {
    // Sample mode. The fake has believable alerts in it, and setting real
    // alarms from invented data would put a fictional person's breakfast on
    // somebody's lock screen.
    return 0;
  }
  final AlertPlan plan = await ref.watch(healthRepositoryProvider).loadAlerts();
  return ref.watch(notificationServiceProvider).applyPlan(plan);
});

/// Who is signed in, and whether they have got through consent and onboarding.
class SessionController extends AsyncNotifier<AuthSession?> {
  @override
  Future<AuthSession?> build() {
    return ref.read(healthRepositoryProvider).restoreSession();
  }

  Future<void> signIn({required String email, required String password}) async {
    state = const AsyncValue<AuthSession?>.loading();
    state = await AsyncValue.guard<AuthSession?>(
      () => ref.read(healthRepositoryProvider).signIn(
            email: email,
            password: password,
          ),
    );
  }

  Future<void> signUp({
    required String email,
    required String password,
    required String displayName,
  }) async {
    state = const AsyncValue<AuthSession?>.loading();
    state = await AsyncValue.guard<AuthSession?>(
      () => ref.read(healthRepositoryProvider).signUp(
            email: email,
            password: password,
            displayName: displayName,
          ),
    );
  }

  Future<void> acceptConsent() async {
    await ref.read(healthRepositoryProvider).recordConsent(
          ConsentType.aiProcessing,
          version: consentVersion,
        );
    final AuthSession? current = state.value;
    if (current != null) {
      state = AsyncValue<AuthSession?>.data(
        current.copyWith(hasAcceptedConsent: true),
      );
    }
  }

  void markProfileComplete() {
    final AuthSession? current = state.value;
    if (current != null) {
      state = AsyncValue<AuthSession?>.data(
        current.copyWith(hasCompletedProfile: true),
      );
    }
  }

  Future<void> signOut() async {
    await ref.read(healthRepositoryProvider).signOut();
    // Reminders carry the person's own meal times in their bodies. Leaving them
    // scheduled after a sign-out would keep telling whoever holds the phone next
    // when the last person ate.
    await ref.read(notificationServiceProvider).forgetEverything();
    ref.invalidate(scheduledRemindersProvider);
    state = const AsyncValue<AuthSession?>.data(null);
  }
}

final sessionControllerProvider =
    AsyncNotifierProvider<SessionController, AuthSession?>(
  SessionController.new,
);

/// The version of the consent text currently shown. Bump it whenever the wording
/// changes; `consents` stores it so we always know what somebody agreed to.
const String consentVersion = '2026-09-01';

final todayProvider = FutureProvider.autoDispose<TodayBriefing>((ref) {
  return ref.watch(healthRepositoryProvider).loadToday(DateTime.now());
});

final reportsProvider = FutureProvider.autoDispose<List<HealthReport>>((ref) {
  return ref.watch(healthRepositoryProvider).loadReports();
});

final reportProvider =
    FutureProvider.autoDispose.family<HealthReport, String>((ref, String id) {
  return ref.watch(healthRepositoryProvider).loadReport(id);
});

final planProvider = FutureProvider.autoDispose<MealPlan>((ref) {
  return ref.watch(healthRepositoryProvider).loadPlan(DateTime.now());
});

final goalsProvider = FutureProvider.autoDispose<List<Goal>>((ref) {
  return ref.watch(healthRepositoryProvider).loadGoals();
});

final trendsProvider = FutureProvider.autoDispose<List<BiomarkerTrend>>((ref) {
  return ref.watch(healthRepositoryProvider).loadTrends();
});

final messagesProvider = FutureProvider.autoDispose<List<ChatMessage>>((ref) {
  return ref.watch(healthRepositoryProvider).loadMessages();
});

/// The health profile being filled in, held across the steps of the wizard.
class ProfileWizardController extends Notifier<HealthProfile> {
  @override
  HealthProfile build() {
    return HealthProfile(
      userId: ref.read(sessionControllerProvider).value?.userId ?? 'pending',
      mealTimes: MealSlot.defaultTimes,
    );
  }

  void update(HealthProfile Function(HealthProfile current) change) {
    state = change(state);
  }

  void setMealTime(MealSlot slot, String time) {
    final Map<String, String> next = Map<String, String>.from(state.mealTimes);
    next[slot.wire] = time;
    state = state.copyWith(mealTimes: next);
  }

  void toggleCuisine(String cuisine) {
    final List<String> next = List<String>.from(state.cuisinePrefs);
    if (next.contains(cuisine)) {
      next.remove(cuisine);
    } else {
      next.add(cuisine);
    }
    state = state.copyWith(cuisinePrefs: next);
  }

  void toggleCondition(String condition) {
    final List<String> next = List<String>.from(state.conditions);
    if (next.contains(condition)) {
      next.remove(condition);
    } else {
      next.add(condition);
    }
    state = state.copyWith(conditions: next);
  }

  void toggleGoal(GoalType goal) {
    final List<GoalType> next = List<GoalType>.from(state.goalTypes);
    if (next.contains(goal)) {
      next.remove(goal);
    } else {
      next.add(goal);
    }
    state = state.copyWith(goalTypes: next);
  }

  void addAllergy(String allergen, AllergySeverity severity) {
    final String cleaned = allergen.trim();
    if (cleaned.isEmpty) {
      return;
    }
    final List<Allergy> next = List<Allergy>.from(state.allergies)
      ..add(
        Allergy(
          id: 'local-${DateTime.now().microsecondsSinceEpoch}',
          allergen: cleaned,
          severity: severity,
        ),
      );
    state = state.copyWith(allergies: next);
  }

  void removeAllergy(String id) {
    state = state.copyWith(
      allergies:
          state.allergies.where((Allergy a) => a.id != id).toList(),
    );
  }

  Future<void> save() async {
    await ref
        .read(healthRepositoryProvider)
        .saveHealthProfile(state.copyWith(updatedAt: DateTime.now()));
    ref.read(sessionControllerProvider.notifier).markProfileComplete();
  }
}

final profileWizardProvider =
    NotifierProvider<ProfileWizardController, HealthProfile>(
  ProfileWizardController.new,
);

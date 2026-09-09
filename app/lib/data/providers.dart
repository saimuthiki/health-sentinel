import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'models/models.dart';
import 'repository/fake_health_repository.dart';
import 'repository/health_repository.dart';

/// The single seam between the interface and the outside world.
///
/// Phase 1 runs on [FakeHealthRepository] so that every screen is fully runnable
/// before the backend exists. Wiring the real service is one override here and
/// no change to any screen. Tests override it with a zero-latency fake.
final healthRepositoryProvider = Provider<HealthRepository>((ref) {
  return FakeHealthRepository();
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

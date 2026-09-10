import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:healthpulse/core/theme/hp_theme.dart';
import 'package:healthpulse/data/api/api_status.dart';
import 'package:healthpulse/data/models/models.dart';
import 'package:healthpulse/data/providers.dart';
import 'package:healthpulse/data/repository/fake_health_repository.dart';
import 'package:healthpulse/data/repository/health_repository.dart';
import 'package:healthpulse/features/today/today_screen.dart';

/// What the plan tab says here, so a test can tell "tapping a meal went to the
/// plan" from "tapping a meal did nothing", without pulling the real plan
/// screen and everything it fetches into a test about Today.
const String planMarker = 'PLAN-REACHED';

/// The same, for the reports tab that a focus note links to.
const String reportsMarker = 'REPORTS-REACHED';

/// The fake, with Today's answer fixed and every hydration write recorded.
///
/// It extends [FakeHealthRepository] rather than implementing
/// [HealthRepository] so that a method added to the interface tomorrow does not
/// break this file: the sample repository already answers everything Today does
/// not care about.
class TodayFakeRepository extends FakeHealthRepository {
  TodayFakeRepository({
    required this.briefing,
    this.hydrationFailure,
    this.holdHydration = false,
  }) : super(latency: Duration.zero, signedIn: true);

  /// Exactly what Today will be given, so a test can put two breakfast items in
  /// front of the screen and assert on what it makes of them.
  final TodayBriefing briefing;

  /// When set, `logHydration` throws this instead of writing.
  final HealthRepositoryException? hydrationFailure;

  /// Hold `logHydration` open until [releaseHydration] is called.
  ///
  /// Without this a test cannot tap twice "while the first call is in flight":
  /// the fake settles in a microtask, and microtasks flush between two awaited
  /// taps, so the second tap would land after the first had already finished.
  /// Holding the call open is the only way to put a second tap inside the
  /// window the busy guard exists for.
  final bool holdHydration;

  /// Every amount handed to `logHydration`, in the order it arrived. Recorded
  /// before the gate and before any refusal, so it counts attempts rather than
  /// successes.
  final List<double> hydrationCalls = <double>[];

  final Completer<void> _hydrationGate = Completer<void>();

  void releaseHydration() {
    if (!_hydrationGate.isCompleted) {
      _hydrationGate.complete();
    }
  }

  @override
  Future<TodayBriefing> loadToday(DateTime date) async => briefing;

  @override
  Future<double> logHydration(double millilitres) async {
    hydrationCalls.add(millilitres);
    if (holdHydration) {
      await _hydrationGate.future;
    }
    final HealthRepositoryException? failure = hydrationFailure;
    if (failure != null) {
      throw failure;
    }
    return super.logHydration(millilitres);
  }
}

/// A briefing with the parts Today draws, and sensible values for the rest.
///
/// Wake and sleep are the enum's own defaults rather than the sample
/// repository's, so the times a test asserts on can be worked out on paper:
/// waking at 6:30 and breakfast at 8:30 puts movement at 7:30.
TodayBriefing briefingWith({
  List<MealPlanItem> meals = const <MealPlanItem>[],
  List<FocusNote> focus = const <FocusNote>[],
  String? planRationale,
  double hydrationMl = 900,
  int movementTargetMinutes = 40,
}) {
  return TodayBriefing(
    date: DateTime(2026, 9, 10),
    displayName: 'Sai Muthiki',
    wakeTime: '06:30',
    sleepTime: '22:30',
    hydrationMl: hydrationMl,
    hydrationTargetMl: 2600,
    movementMinutes: 18,
    movementTargetMinutes: movementTargetMinutes,
    meals: meals,
    focus: focus,
    planRationale: planRationale,
  );
}

/// Today, wired to [repository], with somewhere for its two links to go.
Widget todayApp({required HealthRepository repository}) {
  return ProviderScope(
    overrides: <Override>[
      healthRepositoryProvider.overrideWithValue(repository),
      // Fixed rather than driven through a real client: these tests are about
      // what the screen does with a phase, not how the client picks one.
      apiPhaseProvider.overrideWithValue(ApiPhase.idle),
    ],
    child: MaterialApp.router(
      theme: HpTheme.light(),
      routerConfig: GoRouter(
        initialLocation: '/today',
        routes: <RouteBase>[
          GoRoute(
            path: '/today',
            builder: (BuildContext context, GoRouterState state) =>
                const TodayScreen(),
          ),
          GoRoute(
            path: '/plan',
            builder: (BuildContext context, GoRouterState state) =>
                const Scaffold(body: Center(child: Text(planMarker))),
          ),
          GoRoute(
            path: '/reports',
            builder: (BuildContext context, GoRouterState state) =>
                const Scaffold(body: Center(child: Text(reportsMarker))),
          ),
        ],
      ),
    ),
  );
}

/// A surface tall enough that a whole day fits on it with no fold.
///
/// Today is a long screen by design, and a tap on something below the fold
/// throws rather than scrolling. [WidgetTester.ensureVisible] is still used
/// before every tap; this only keeps the widgets built so the finder has
/// something to scroll to.
void useTallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(600, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Let a queued failure or success land without waiting on any animation.
///
/// [WidgetTester.pumpAndSettle] cannot be used here: a spinner animates for
/// ever, so a screen that is *meant* to be busy would time it out and a screen
/// that is meant not to be would pass for the wrong reason.
Future<void> settleWithoutAnimations(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 32));
  await tester.pump();
}

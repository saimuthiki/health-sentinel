import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:healthpulse/core/theme/hp_theme.dart';
import 'package:healthpulse/data/api/api_status.dart';
import 'package:healthpulse/data/providers.dart';
import 'package:healthpulse/data/repository/health_repository.dart';
import 'package:healthpulse/features/auth/sign_in_screen.dart';
import 'package:healthpulse/features/chat/chat_screen.dart';
import 'package:healthpulse/features/onboarding/consent_screen.dart';
import 'package:healthpulse/features/profile/health_profile_screen.dart';

/// What the screen after the wizard says, so a test can tell "was navigated
/// onward" from "is still here" without depending on Today or on what it
/// fetches.
const String todayMarker = 'TODAY-REACHED';

/// The onboarding routes, with the same `?blocked=1` handling the real router
/// has, so a redirect to the recovery path is exercised end to end.
GoRouter onboardingRouter({String initialLocation = '/consent'}) {
  return GoRouter(
    initialLocation: initialLocation,
    routes: <RouteBase>[
      GoRoute(
        path: '/welcome',
        builder: (BuildContext context, GoRouterState state) =>
            const SignInScreen(),
      ),
      GoRoute(
        path: '/consent',
        builder: (BuildContext context, GoRouterState state) => ConsentScreen(
          recovered: state.uri.queryParameters['blocked'] == '1',
        ),
      ),
      GoRoute(
        path: '/profile',
        builder: (BuildContext context, GoRouterState state) =>
            const HealthProfileScreen(),
      ),
      GoRoute(
        path: '/chat',
        builder: (BuildContext context, GoRouterState state) =>
            const ChatScreen(),
      ),
      GoRoute(
        path: '/today',
        builder: (BuildContext context, GoRouterState state) =>
            const Scaffold(body: Center(child: Text(todayMarker))),
      ),
    ],
  );
}

/// The app, wired to [repository] and to a fixed connection [phase].
///
/// [apiPhaseProvider] is overridden rather than driven through a real API
/// client: the point of these tests is what the screens do with a phase, not
/// how the client decides on one, which `test/data/api/api_client_test.dart`
/// already covers.
Widget onboardingApp({
  required HealthRepository repository,
  required GoRouter router,
  ApiPhase phase = ApiPhase.idle,
}) {
  return ProviderScope(
    overrides: <Override>[
      healthRepositoryProvider.overrideWithValue(repository),
      apiPhaseProvider.overrideWithValue(phase),
    ],
    child: MaterialApp.router(
      theme: HpTheme.light(),
      routerConfig: router,
    ),
  );
}

/// A surface tall enough that a long first-run screen has no fold.
///
/// These screens are deliberately wordy - it is a consent notice - and a tap on
/// something below the fold throws rather than scrolling, so the alternative is
/// a scroll before every interaction.
void useTallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(600, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Let a queued failure or success land without waiting on any animation.
///
/// [WidgetTester.pumpAndSettle] cannot be used on these screens: a spinner
/// animates for ever, so a screen that is *meant* to be busy would time it out
/// and a screen that is meant not to be would pass for the wrong reason.
Future<void> settleWithoutAnimations(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 32));
  await tester.pump();
}

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/sign_in_screen.dart';
import '../../features/auth/sign_up_screen.dart';
import '../../features/chat/chat_screen.dart';
import '../../features/common/consent_routing.dart';
import '../../features/more/more_screen.dart';
import '../../features/onboarding/consent_screen.dart';
import '../../features/plan/plan_screen.dart';
import '../../features/profile/health_profile_screen.dart';
import '../../features/reports/report_detail_screen.dart';
import '../../features/reports/reports_screen.dart';
import '../../features/setup/not_configured_screen.dart';
import '../../features/shell/home_shell.dart';
import '../../features/splash/splash_screen.dart';
import '../../features/today/today_screen.dart';

/// The app's routes.
///
/// The five tabs are branches of a [StatefulShellRoute] so each keeps its own
/// navigation stack and scroll position: coming back to Reports after answering
/// a message should not throw away where you were.
///
/// Where someone goes after signing in is decided in one place - the splash
/// screen and the auth screens - rather than in a router redirect, because a
/// redirect that reads asynchronous session state is the kind of thing that
/// silently loops.
GoRouter buildAppRouter() {
  final GlobalKey<NavigatorState> rootNavigatorKey =
      GlobalKey<NavigatorState>(debugLabel: 'root');

  return GoRouter(
    initialLocation: '/',
    navigatorKey: rootNavigatorKey,
    routes: <RouteBase>[
      GoRoute(
        path: '/',
        builder: (BuildContext context, GoRouterState state) =>
            const SplashScreen(),
      ),
      GoRoute(
        // Where the splash sends someone when this build has no backend to
        // talk to. A real destination rather than a dialog, so it survives a
        // rotation and can be linked to from a bug report.
        path: '/not-configured',
        builder: (BuildContext context, GoRouterState state) =>
            const NotConfiguredScreen(),
      ),
      GoRoute(
        path: '/welcome',
        builder: (BuildContext context, GoRouterState state) =>
            const SignInScreen(),
      ),
      GoRoute(
        path: '/sign-up',
        builder: (BuildContext context, GoRouterState state) =>
            const SignUpScreen(),
      ),
      GoRoute(
        // `?blocked=1` means the app arrived here from a refusal rather than
        // from signing up, so the screen can say why. See
        // `features/common/consent_routing.dart`.
        path: '/consent',
        builder: (BuildContext context, GoRouterState state) => ConsentScreen(
          recovered:
              state.uri.queryParameters[consentBlockedParam] == '1',
        ),
      ),
      GoRoute(
        path: '/profile',
        builder: (BuildContext context, GoRouterState state) =>
            const HealthProfileScreen(),
      ),
      StatefulShellRoute.indexedStack(
        builder: (
          BuildContext context,
          GoRouterState state,
          StatefulNavigationShell navigationShell,
        ) =>
            HomeShell(navigationShell: navigationShell),
        branches: <StatefulShellBranch>[
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: '/today',
                builder: (BuildContext context, GoRouterState state) =>
                    const TodayScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: '/reports',
                builder: (BuildContext context, GoRouterState state) =>
                    const ReportsScreen(),
                routes: <RouteBase>[
                  GoRoute(
                    path: ':reportId',
                    builder: (BuildContext context, GoRouterState state) =>
                        ReportDetailScreen(
                      reportId: state.pathParameters['reportId'] ?? '',
                    ),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: '/plan',
                builder: (BuildContext context, GoRouterState state) =>
                    const PlanScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: '/chat',
                builder: (BuildContext context, GoRouterState state) =>
                    const ChatScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: '/more',
                builder: (BuildContext context, GoRouterState state) =>
                    const MoreScreen(),
              ),
            ],
          ),
        ],
      ),
    ],
  );
}

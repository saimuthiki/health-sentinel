import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/sign_in_screen.dart';
import '../../features/auth/sign_up_screen.dart';
import '../../features/chat/chat_screen.dart';
import '../../features/common/consent_routing.dart';
import '../../features/export/export_screen.dart';
import '../../features/grocery/grocery_screen.dart';
import '../../features/more/more_screen.dart';
import '../../features/onboarding/consent_screen.dart';
import '../../features/plan/plan_screen.dart';
import '../../features/profile/health_profile_screen.dart';
import '../../features/profile/profile_routing.dart';
import '../../features/profile/profile_summary_screen.dart';
import '../../features/recipes/recipe_screen.dart';
import '../../features/reminders/reminders_screen.dart';
import '../../features/reports/report_detail_screen.dart';
import '../../features/reports/reports_screen.dart';
import '../../features/setup/not_configured_screen.dart';
import '../../features/shell/home_shell.dart';
import '../../features/splash/splash_screen.dart';
import '../../features/summary/weekly_summary_screen.dart';
import '../../features/tastes/tastes_screen.dart';
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
        // How to make one meal of a plan, and how much of it to have. The item
        // is in the path and the plan's date is a query parameter, so the link
        // survives a rotation and can be pasted into a bug report. Neither
        // carries a quantity: the portion is read off the stored plan row on
        // the server, which is the row its nutrition was computed from.
        path: '/recipe/:itemId',
        builder: (BuildContext context, GoRouterState state) => RecipeScreen(
          itemId: state.pathParameters['itemId'] ?? '',
          planDate:
              DateTime.tryParse(state.uri.queryParameters[recipeDateParam] ?? '')
                  ?? DateTime.now(),
        ),
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
        // The six-step wizard, and only the first run of it. Coming back to
        // the profile later goes to `/more/profile` instead, which shows what
        // is already saved - see `features/profile/profile_routing.dart`.
        //
        // `?return=review` means the wizard was opened from that summary by
        // somebody who would rather answer the whole set again, so finishing
        // it goes back there rather than to Today. Same idea as `?blocked=1`
        // on the consent screen: one route, told how it was reached.
        path: '/profile',
        builder: (BuildContext context, GoRouterState state) =>
            HealthProfileScreen(
          returnToReview: state.uri.queryParameters[profileReturnParam] ==
              profileReturnReview,
        ),
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
                // These are all screens reached from a tile on More, so they
                // are children of it rather than top-level routes: the tab bar
                // stays where it is, the More tab keeps its place in the
                // stack, and going back is going back to the list the tile was
                // on.
                routes: <RouteBase>[
                  GoRoute(
                    // Everything the profile already holds, each answer
                    // editable on its own. A child of More for the reason
                    // above: this is the screen the owner reached by tapping
                    // "Health profile", and it must have a back control that
                    // lands on the list he tapped it from.
                    path: 'profile',
                    builder: (BuildContext context, GoRouterState state) =>
                        const ProfileSummaryScreen(),
                  ),
                  GoRoute(
                    path: 'tastes',
                    builder: (BuildContext context, GoRouterState state) =>
                        const TastesScreen(),
                  ),
                  GoRoute(
                    path: 'reminders',
                    builder: (BuildContext context, GoRouterState state) =>
                        const RemindersScreen(),
                  ),
                  GoRoute(
                    path: 'export',
                    builder: (BuildContext context, GoRouterState state) =>
                        const ExportScreen(),
                  ),
                  GoRoute(
                    path: 'grocery',
                    builder: (BuildContext context, GoRouterState state) =>
                        const GroceryScreen(),
                  ),
                  GoRoute(
                    // The week just gone. A child of More for the same reason
                    // the grocery list is one: this is a screen reached from a
                    // tile on that list, and its back control lands there.
                    path: 'week',
                    builder: (BuildContext context, GoRouterState state) =>
                        const WeeklySummaryScreen(),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    ],
  );
}

/// The query parameter carrying the plan's date into `/recipe/:itemId`.
///
/// Named here, beside the route that reads it, for the same reason
/// `consentBlockedParam` and `profileReturnParam` are: a bare string literal
/// spelled two different ways in two files is a link that silently loses its
/// date and quietly shows the wrong day's portion.
const String recipeDateParam = 'on';

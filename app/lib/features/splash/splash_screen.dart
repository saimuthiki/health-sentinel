import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/hp_palette.dart';
import '../../core/theme/hp_spacing.dart';
import '../../core/theme/hp_typography.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/models.dart';
import '../../data/providers.dart';

/// The first frame, and the only place the app decides where someone belongs.
///
/// It shows the same mark as the Android launch drawable, so the handover from
/// the system splash to Flutter is invisible.
class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> {
  bool _routed = false;

  void _routeFor(AuthSession? session) {
    if (_routed || !mounted) {
      return;
    }
    _routed = true;
    if (session == null) {
      context.go('/welcome');
    } else if (!session.hasAcceptedConsent) {
      context.go('/consent');
    } else if (!session.hasCompletedProfile) {
      context.go('/profile');
    } else {
      context.go('/today');
    }
  }

  void _scheduleRoute(AuthSession? session) {
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      _routeFor(session);
    });
  }

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;

    // A build with no backend never asks for a session at all: there is nothing
    // to ask. Saying so is the calm answer; a spinner over a socket that will
    // never connect is not.
    if (ref.watch(apiClientProvider) == null &&
        !ref.watch(appConfigProvider).isReady) {
      WidgetsBinding.instance.addPostFrameCallback((Duration _) {
        if (!_routed && mounted) {
          _routed = true;
          context.go('/not-configured');
        }
      });
      return _splashBody(p);
    }

    final AsyncValue<AuthSession?> session =
        ref.watch(sessionControllerProvider);

    if (session.hasValue) {
      _scheduleRoute(session.value);
    } else if (session.hasError) {
      // A failure to restore a session is not an error worth a screen: it means
      // "not signed in", and the welcome screen is the honest answer.
      _scheduleRoute(null);
    }

    return _splashBody(p);
  }

  Widget _splashBody(HpPalette p) {
    return Scaffold(
      backgroundColor: p.ground,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const HpMark(size: 84),
            const SizedBox(height: HpSpacing.lg),
            Text('HealthPulse', style: HpType.title.copyWith(color: p.ink)),
            const SizedBox(height: HpSpacing.xs),
            Text(
              'A coach, not a doctor',
              style: HpType.label.copyWith(color: p.inkFaint),
            ),
          ],
        ),
      ),
    );
  }
}

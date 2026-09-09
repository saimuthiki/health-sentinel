import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/router/app_router.dart';
import 'core/theme/hp_theme.dart';
import 'data/providers.dart';
import 'services/auth_service.dart';

/// The application widget.
///
/// Both themes are supplied and the device's setting chooses between them: a
/// health app is opened in bed at midnight as often as at breakfast, and forcing
/// a bright screen at either end of the day is a small unkindness.
///
/// It is also where the auth-state stream reaches routing. Where somebody goes
/// *after an action they took* is decided by the screen they took it on, which
/// is why there is no asynchronous redirect in the router. But a session can
/// also end without anybody touching this phone — a refresh token revoked, a
/// password changed, an account deleted — and that has to land somewhere. It
/// lands here: one listener, one destination, and the session state thrown away
/// so nothing keeps rendering a signed-out person's day.
class HealthPulseApp extends ConsumerStatefulWidget {
  const HealthPulseApp({super.key});

  @override
  ConsumerState<HealthPulseApp> createState() => _HealthPulseAppState();
}

class _HealthPulseAppState extends ConsumerState<HealthPulseApp> {
  late final GoRouter _router = buildAppRouter();

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<AuthLifecycle>>(
      authLifecycleProvider,
      (AsyncValue<AuthLifecycle>? previous, AsyncValue<AuthLifecycle> next) {
        if (next.value != AuthLifecycle.signedOut) {
          return;
        }
        ref.invalidate(sessionControllerProvider);
        _router.go('/welcome');
      },
    );

    return MaterialApp.router(
      title: 'HealthPulse',
      debugShowCheckedModeBanner: false,
      routerConfig: _router,
      theme: HpTheme.light(),
      darkTheme: HpTheme.dark(),
      themeMode: ThemeMode.system,
    );
  }
}

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'core/router/app_router.dart';
import 'core/theme/hp_theme.dart';

/// The application widget.
///
/// Both themes are supplied and the device's setting chooses between them: a
/// health app is opened in bed at midnight as often as at breakfast, and forcing
/// a bright screen at either end of the day is a small unkindness.
class HealthPulseApp extends StatefulWidget {
  const HealthPulseApp({super.key});

  @override
  State<HealthPulseApp> createState() => _HealthPulseAppState();
}

class _HealthPulseAppState extends State<HealthPulseApp> {
  late final GoRouter _router = buildAppRouter();

  @override
  Widget build(BuildContext context) {
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

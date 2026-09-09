import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/bootstrap.dart';
import 'data/providers.dart';

Future<void> main() async {
  // Configuration, Supabase and the offline store, in that order. It cannot
  // throw: a build with no `--dart-define` values comes back with no overrides
  // and the app opens on sample data with an honest screen in front of it.
  final Bootstrap boot = await bootstrap();
  runApp(
    ProviderScope(
      overrides: <Override>[
        startupErrorProvider.overrideWithValue(boot.startupError),
        ...boot.overrides,
      ],
      child: const HealthPulseApp(),
    ),
  );
}

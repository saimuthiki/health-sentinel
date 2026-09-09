import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/cache/offline_cache.dart';
import '../data/providers.dart';
import '../services/auth_service.dart';
import 'config/app_config.dart';

/// What `main()` learned before the first frame.
class Bootstrap {
  const Bootstrap({
    required this.config,
    required this.overrides,
    this.startupError,
  });

  final AppConfig config;

  /// The providers to swap in. Empty means the app runs on the fake repository.
  final List<Override> overrides;

  /// Set when the configuration looked right but starting up failed anyway.
  /// Our own sentence, never an exception string.
  final String? startupError;

  bool get isConnected => overrides.isNotEmpty;

  /// What the "not connected" screen shows. The startup failure wins, because
  /// it is the more specific of the two.
  String get explanation => startupError ?? config.explanation;
}

/// Everything that has to happen before `runApp`, and nothing that does not.
///
/// It never throws. An app that cannot reach its backend has to open anyway and
/// say so calmly — a health app that crashes on launch because a build flag was
/// missing is a health app somebody uninstalls before they ever see it.
Future<Bootstrap> bootstrap({
  AppConfig config = AppConfig.fromEnvironment,
}) async {
  WidgetsFlutterBinding.ensureInitialized();

  if (!config.isReady) {
    // No address, a malformed one, or — the one worth failing loudly over — a
    // service-role key where the anon key belongs. Nothing is initialised.
    return Bootstrap(config: config, overrides: const <Override>[]);
  }

  try {
    await Supabase.initialize(
      url: config.supabaseUrl,
      anonKey: config.supabaseAnonKey,
    );
  } catch (_) {
    return Bootstrap(
      config: config,
      overrides: const <Override>[],
      startupError:
          'HealthPulse could not start its connection to the sign-in service. '
          'Check that this phone is online, then open the app again.',
    );
  }

  final SupabaseAuthGateway gateway =
      SupabaseAuthGateway(Supabase.instance.client);
  final SqfliteOfflineCache cache = SqfliteOfflineCache();

  return Bootstrap(
    config: config,
    overrides: <Override>[
      appConfigProvider.overrideWithValue(config),
      authGatewayProvider.overrideWithValue(gateway),
      offlineCacheProvider.overrideWithValue(cache),
    ],
  );
}

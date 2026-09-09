import 'dart:convert';

/// Where a build gets its addresses from, and what the app does when it has none.
///
/// Every value here arrives at **build time** through `--dart-define`. Nothing is
/// read from a file that could be committed by accident, and there is no default
/// that points at a real server, so a clone of this repository builds an app that
/// is honestly unconfigured rather than one quietly pointed somewhere.
///
/// Two of the three values are addresses. The third, [supabaseAnonKey], is a key
/// that is *designed* to ship inside a client: it identifies the project and
/// carries the `anon` role, and every table it can reach is fenced by Row Level
/// Security. The service-role key is the opposite of that in every way and must
/// never appear anywhere under `app/` — [carriesServiceRoleKey] exists so that a
/// paste of the wrong key fails loudly at launch instead of silently shipping.
class AppConfig {
  const AppConfig({
    this.supabaseUrl = '',
    this.supabaseAnonKey = '',
    this.apiBaseUrl = '',
  });

  /// The values baked into *this* build.
  ///
  /// All three default to the empty string. That is deliberate: the owner has
  /// not supplied them yet, and an app that cannot reach a backend should say so
  /// on a calm screen rather than crash on the first request or hang forever on
  /// a socket that will never connect.
  static const AppConfig fromEnvironment = AppConfig(
    supabaseUrl: String.fromEnvironment('SUPABASE_URL'),
    supabaseAnonKey: String.fromEnvironment('SUPABASE_ANON_KEY'),
    apiBaseUrl: String.fromEnvironment('API_BASE_URL'),
  );

  /// `https://<project>.supabase.co`.
  final String supabaseUrl;

  /// The publishable `anon` key. Public by design; RLS is the real boundary.
  final String supabaseAnonKey;

  /// The root of our own FastAPI service, e.g. `https://healthpulse-api.onrender.com`.
  final String apiBaseUrl;

  /// The `--dart-define` names, in the order the README lists them.
  static const List<String> defineNames = <String>[
    'SUPABASE_URL',
    'SUPABASE_ANON_KEY',
    'API_BASE_URL',
  ];

  /// Which defines were left empty, by name, for the "not configured" screen.
  List<String> get missing {
    final List<String> out = <String>[];
    if (supabaseUrl.trim().isEmpty) {
      out.add('SUPABASE_URL');
    }
    if (supabaseAnonKey.trim().isEmpty) {
      out.add('SUPABASE_ANON_KEY');
    }
    if (apiBaseUrl.trim().isEmpty) {
      out.add('API_BASE_URL');
    }
    return out;
  }

  /// The API root as a [Uri], or null when it is missing or not an https(s) URL.
  Uri? get apiBase => _httpUri(apiBaseUrl);

  /// The Supabase project URL as a [Uri], or null when it will not parse.
  Uri? get supabaseBase => _httpUri(supabaseUrl);

  /// True when the anon slot has been filled with a **service-role** key.
  ///
  /// A Supabase key is a JWT whose payload names its role. A service-role key
  /// bypasses Row Level Security entirely, so one inside an APK hands every
  /// user's health data to anyone who unzips it. This is checked rather than
  /// trusted, and [status] turns it into a refusal to start.
  bool get carriesServiceRoleKey {
    final String? role = _jwtRole(supabaseAnonKey);
    return role != null && role != 'anon';
  }

  ConfigStatus get status {
    if (missing.isNotEmpty) {
      return ConfigStatus.notConfigured;
    }
    if (carriesServiceRoleKey) {
      return ConfigStatus.wrongKey;
    }
    if (apiBase == null || supabaseBase == null) {
      return ConfigStatus.badAddress;
    }
    return ConfigStatus.ready;
  }

  /// True only when this build may talk to a real backend.
  bool get isReady => status == ConfigStatus.ready;

  /// What to tell the person holding the phone. Plain, calm, and never a
  /// stack trace or a key fragment.
  String get explanation {
    switch (status) {
      case ConfigStatus.ready:
        return 'Connected.';
      case ConfigStatus.notConfigured:
        return 'This copy of HealthPulse was built without the addresses it '
            'needs to reach its server, so there is nothing for it to talk to '
            'yet. Nothing is broken and nothing has been lost.';
      case ConfigStatus.badAddress:
        return 'This copy of HealthPulse was built with an address it cannot '
            'use. It needs a full web address beginning with https.';
      case ConfigStatus.wrongKey:
        return 'This build carries the wrong Supabase key. The app must be '
            'built with the publishable anon key, never the service key, so it '
            'will not connect until that is corrected.';
    }
  }

  /// The exact command that fixes it, for the screen and for the README.
  static const String buildCommand =
      'flutter build apk --release \\\n'
      '  --dart-define=SUPABASE_URL=https://YOUR-PROJECT.supabase.co \\\n'
      '  --dart-define=SUPABASE_ANON_KEY=YOUR-ANON-KEY \\\n'
      '  --dart-define=API_BASE_URL=https://YOUR-BACKEND.onrender.com';

  static Uri? _httpUri(String raw) {
    final String trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    final Uri? parsed = Uri.tryParse(trimmed);
    if (parsed == null || !parsed.hasScheme || !parsed.hasAuthority) {
      return null;
    }
    if (parsed.scheme != 'https' && parsed.scheme != 'http') {
      return null;
    }
    return parsed;
  }

  /// The `role` claim of a JWT, without verifying it. Reading it is enough to
  /// tell an `anon` key from a `service_role` key; we are not trusting it for
  /// anything else.
  static String? _jwtRole(String token) {
    final List<String> parts = token.trim().split('.');
    if (parts.length != 3) {
      return null;
    }
    try {
      final String segment = parts[1];
      final int pad = segment.length % 4;
      final String padded =
          pad == 0 ? segment : segment + ('=' * (4 - pad));
      final Object? decoded = jsonDecode(utf8.decode(base64Url.decode(padded)));
      if (decoded is Map && decoded['role'] is String) {
        return decoded['role'] as String;
      }
    } catch (_) {
      // An unparseable key is not a service-role key; it is just wrong, and
      // [status] catches that when the connection fails.
      return null;
    }
    return null;
  }
}

/// Why the app is, or is not, allowed to talk to a backend.
enum ConfigStatus { ready, notConfigured, badAddress, wrongKey }

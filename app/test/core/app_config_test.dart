import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:healthpulse/core/config/app_config.dart';

/// Build-time configuration, and the two ways it can be wrong.
///
/// The default is empty on purpose. A repository that builds an app pointed at
/// somebody's real project by accident is a worse outcome than one that builds
/// an app which says it is not connected.
void main() {
  String jwt(String role, {bool padded = true}) {
    String segment(Object value) {
      final String encoded = base64Url.encode(utf8.encode(jsonEncode(value)));
      return padded ? encoded : encoded.replaceAll('=', '');
    }

    return '${segment(<String, dynamic>{'alg': 'HS256', 'typ': 'JWT'})}'
        '.${segment(<String, dynamic>{'role': role, 'iss': 'supabase'})}'
        '.signature-we-never-verify';
  }

  group('an unconfigured build', () {
    test('defaults to nothing, and says so rather than guessing', () {
      const AppConfig config = AppConfig();
      expect(config.supabaseUrl, isEmpty);
      expect(config.supabaseAnonKey, isEmpty);
      expect(config.apiBaseUrl, isEmpty);
      expect(config.isReady, isFalse);
      expect(config.status, ConfigStatus.notConfigured);
      expect(config.apiBase, isNull);
    });

    test('names every missing define, so the fix is obvious', () {
      const AppConfig config = AppConfig();
      expect(config.missing, AppConfig.defineNames);

      final AppConfig partial = AppConfig(
        supabaseUrl: 'https://project.supabase.co',
        supabaseAnonKey: jwt('anon'),
      );
      expect(partial.missing, <String>['API_BASE_URL']);
      expect(partial.isReady, isFalse);
    });

    test('the explanation is calm and mentions no key', () {
      const AppConfig config = AppConfig();
      expect(config.explanation, contains('server'));
      expect(config.explanation.toLowerCase(), contains('nothing is broken'));
      expect(config.explanation, isNot(contains('null')));
      expect(config.explanation, isNot(contains('Exception')));
    });

    test('the documented build command names all three defines', () {
      for (final String name in AppConfig.defineNames) {
        expect(AppConfig.buildCommand, contains('--dart-define=$name='));
      }
      expect(AppConfig.buildCommand, isNot(contains('SERVICE')));
    });
  });

  group('a configured build', () {
    final AppConfig config = AppConfig(
      supabaseUrl: 'https://project.supabase.co',
      supabaseAnonKey: jwt('anon'),
      apiBaseUrl: 'https://healthpulse-api.onrender.com',
    );

    test('is ready and parses both addresses', () {
      expect(config.status, ConfigStatus.ready);
      expect(config.isReady, isTrue);
      expect(config.missing, isEmpty);
      expect(config.apiBase, Uri.parse('https://healthpulse-api.onrender.com'));
      expect(config.supabaseBase, Uri.parse('https://project.supabase.co'));
    });

    test('an anon key is not mistaken for a service key', () {
      expect(config.carriesServiceRoleKey, isFalse);
    });

    test('an unpadded JWT still reads', () {
      final AppConfig unpadded = AppConfig(
        supabaseUrl: 'https://project.supabase.co',
        supabaseAnonKey: jwt('anon', padded: false),
        apiBaseUrl: 'https://api.test',
      );
      expect(unpadded.carriesServiceRoleKey, isFalse);
      expect(unpadded.isReady, isTrue);
    });
  });

  group('the two ways it goes wrong', () {
    test('a service-role key in the anon slot refuses to start', () {
      final AppConfig config = AppConfig(
        supabaseUrl: 'https://project.supabase.co',
        supabaseAnonKey: jwt('service_role'),
        apiBaseUrl: 'https://api.test',
      );
      expect(config.carriesServiceRoleKey, isTrue);
      expect(config.status, ConfigStatus.wrongKey);
      expect(config.isReady, isFalse,
          reason: 'a key that bypasses Row Level Security must never ship');
      expect(config.explanation.toLowerCase(), contains('anon key'));
    });

    test('an address that is not a web address is refused', () {
      for (final String bad in <String>[
        'healthpulse-api.onrender.com',
        'ftp://example.com',
        'not a url at all',
      ]) {
        final AppConfig config = AppConfig(
          supabaseUrl: 'https://project.supabase.co',
          supabaseAnonKey: jwt('anon'),
          apiBaseUrl: bad,
        );
        expect(config.apiBase, isNull, reason: 'accepted "$bad"');
        expect(config.status, ConfigStatus.badAddress);
      }
    });

    test('a key that is not a JWT at all is not treated as a service key', () {
      final AppConfig config = AppConfig(
        supabaseUrl: 'https://project.supabase.co',
        supabaseAnonKey: 'plainly-not-a-jwt',
        apiBaseUrl: 'https://api.test',
      );
      expect(config.carriesServiceRoleKey, isFalse);
    });
  });

  test('what this build was actually compiled with is empty', () {
    // Nothing in CI passes --dart-define, and nothing should: a real address
    // committed to a test would be a real address in the repository.
    expect(AppConfig.fromEnvironment.isReady, isFalse);
    expect(AppConfig.fromEnvironment.supabaseAnonKey, isEmpty);
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:healthpulse/services/auth_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// What we say when the auth provider says no.
///
/// The provider's own wording is read to pick a sentence and never shown: it is
/// written for developers and it changes between versions. That makes the
/// mapping itself the thing that has to be right, because a wrong mapping tells
/// someone to fix something that was never broken.
///
/// This suite exists because it did exactly that. A bare `contains('email')`
/// caught "Email rate limit exceeded" and "Email signups are disabled" and
/// reported both as "that does not look like an email address" -- sending
/// someone off to re-check a perfectly good address while the real cause was a
/// project setting.
void main() {
  String signUp(String providerMessage) =>
      SupabaseAuthGateway.explainAuthError(AuthException(providerMessage), signingUp: true);

  String signIn(String providerMessage) =>
      SupabaseAuthGateway.explainAuthError(AuthException(providerMessage), signingUp: false);

  group('a valid address is never blamed for something else', () {
    test('a rate limit is reported as a rate limit', () {
      final String message = signUp('Email rate limit exceeded');
      expect(message, contains('Too many attempts'));
      expect(message, isNot(contains('does not look like an email')));
    });

    test('sign-ups being switched off says so, and says it is not your typing', () {
      for (final String raw in <String>[
        'Signups not allowed for this instance',
        'Email signups are disabled',
        'Signup is disabled',
      ]) {
        final String message = signUp(raw);
        expect(message, contains('turned off'), reason: raw);
        expect(message, contains('Nothing is wrong with what you typed'), reason: raw);
        expect(message, isNot(contains('does not look like an email')), reason: raw);
      }
    });

    test('a mail-sending failure is owned by us, not by the address', () {
      final String message = signUp('Error sending confirmation email');
      expect(message, contains('our end, not'));
      expect(message, isNot(contains('does not look like an email')));
    });
  });

  group('a genuinely bad address still says so', () {
    test('the provider phrasings that really mean the address is unusable', () {
      for (final String raw in <String>[
        'Invalid email',
        'Email address is invalid',
        'Unable to validate email address: invalid format',
      ]) {
        expect(signUp(raw), contains('does not look like an email'), reason: raw);
      }
    });
  });

  group('the rest of the mapping still holds', () {
    test('an existing account points at signing in', () {
      expect(signUp('User already registered'), contains('already an account'));
    });

    test('wrong credentials do not reveal whether the account exists', () {
      final String message = signIn('Invalid login credentials');
      expect(message, contains('did not match an account'));
      expect(message, isNot(contains('no account')));
      expect(message, isNot(contains('wrong password')));
    });

    test('an unconfirmed email points at the confirmation link', () {
      expect(signIn('Email not confirmed'), contains('confirmation link'));
    });

    test('a weak password is about the password', () {
      expect(signUp('Password should be at least 6 characters'),
          contains('password will not do'));
    });

    test('anything unrecognised falls back without blaming a field', () {
      final String message = signUp('some unmapped provider failure');
      expect(message, isNot(contains('does not look like an email')));
      expect(message, isNot(contains('password will not do')));
      expect(message, isNotEmpty);
    });

    test('the provider wording is never shown to the user', () {
      const String raw = 'pq: duplicate key value violates unique constraint';
      expect(signUp(raw), isNot(contains('pq:')));
      expect(signUp(raw), isNot(contains('constraint')));
    });
  });

  group('the machine-readable code is trusted before the prose', () {
    String byCode(String code, {String message = 'some prose that may change'}) =>
        SupabaseAuthGateway.explainAuthError(
          AuthException(message, code: code),
          signingUp: true,
        );

    test('email_provider_disabled - the code from a real signup failure', () {
      // Taken verbatim from the project's auth log:
      //   "error": "400: Email signups are disabled",
      //   "error_code": "email_provider_disabled"
      final String message = byCode(
        'email_provider_disabled',
        message: '400: Email signups are disabled',
      );
      expect(message, contains('turned off'));
      expect(message, contains('Nothing is wrong with what you typed'));
      expect(message, isNot(contains('does not look like an email')));
    });

    test('the code wins even when the prose would map elsewhere', () {
      // Prose says "email", which the fallback would have caught. The code says
      // this is a rate limit. The code is the contract, so it decides.
      final String message = byCode(
        'over_email_send_rate_limit',
        message: 'Email address could not be reached',
      );
      expect(message, contains('Too many attempts'));
      expect(message, isNot(contains('does not look like an email')));
    });

    test('each code maps to its own sentence', () {
      expect(byCode('email_exists'), contains('already an account'));
      expect(byCode('invalid_credentials'), contains('did not match an account'));
      expect(byCode('email_not_confirmed'), contains('confirmation link'));
      expect(byCode('weak_password'), contains('password will not do'));
      expect(byCode('email_address_invalid'), contains('does not look like an email'));
      expect(byCode('email_address_not_authorized'), contains('allowed list'));
    });

    test('an unknown code falls through to reading the prose', () {
      final String message = byCode(
        'some_code_that_did_not_exist_when_this_was_written',
        message: 'User already registered',
      );
      expect(message, contains('already an account'));
    });

    test('no code at all still works, which is the older response shape', () {
      expect(signUp('Email signups are disabled'), contains('turned off'));
    });
  });
}

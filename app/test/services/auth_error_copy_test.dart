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
}

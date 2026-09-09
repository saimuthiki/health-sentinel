import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/api/auth_token_provider.dart';
import '../data/repository/health_repository.dart';

/// Who is signed in, expressed without mentioning Supabase.
class AuthUser {
  const AuthUser({
    required this.id,
    required this.email,
    this.displayName = '',
  });

  final String id;
  final String email;
  final String displayName;
}

/// What the session just did. The router listens to this so that a session
/// ending anywhere — a refresh token revoked on another device, a password
/// changed, an account deleted — puts the person back on the sign-in screen
/// instead of leaving them looking at a screen that will never load again.
enum AuthLifecycle { signedIn, signedOut, refreshed, unchanged }

/// Everything the app needs from an identity provider.
///
/// It is an interface for the same reason [AuthTokenProvider] is: so that the
/// repository, the router and the tests can be written and run without a
/// Supabase project existing. [SupabaseAuthGateway] is the only implementation
/// that ships.
abstract class AuthGateway implements AuthTokenProvider {
  AuthUser? get currentUser;

  /// Broadcast. Emits on every sign-in, sign-out and token refresh.
  Stream<AuthLifecycle> get lifecycle;

  Future<AuthUser> signIn({required String email, required String password});

  Future<AuthUser> signUp({
    required String email,
    required String password,
    required String displayName,
  });

  Future<void> signOut();
}

/// Email and password against Supabase Auth.
///
/// Sign-in happens here and **only** here: the backend never sees a password and
/// never issues a token, it only verifies the one this app already holds
/// (`backend/app/api/auth.py`). Session persistence is Supabase's own — it
/// writes the refresh token to the platform's secure storage and restores it on
/// launch, which is why nothing in this file reads or writes a token to disk.
class SupabaseAuthGateway implements AuthGateway {
  SupabaseAuthGateway(this._supabase) {
    // The element type is left to inference on purpose: this is the one place
    // a Supabase type name would leak into a signature, and the package moves.
    _subscription = _supabase.auth.onAuthStateChange.listen(
      (state) => _lifecycle.add(_lifecycleOf(state.event.name)),
      onError: (Object _) {
        // A broken auth stream is not a reason to take the app down. The next
        // request will get a 401 and route the person to sign in properly.
      },
    );
  }

  final SupabaseClient _supabase;
  final StreamController<AuthLifecycle> _lifecycle =
      StreamController<AuthLifecycle>.broadcast();
  StreamSubscription<dynamic>? _subscription;

  @override
  Stream<AuthLifecycle> get lifecycle => _lifecycle.stream;

  @override
  AuthUser? get currentUser {
    final user = _supabase.auth.currentUser;
    if (user == null) {
      return null;
    }
    final Object? name = user.userMetadata?['display_name'];
    return AuthUser(
      id: user.id,
      email: user.email ?? '',
      displayName: name is String ? name : '',
    );
  }

  @override
  Future<String?> accessToken() async {
    final session = _supabase.auth.currentSession;
    if (session == null) {
      return null;
    }
    if (session.isExpired) {
      return refreshAccessToken();
    }
    return session.accessToken;
  }

  @override
  Future<String?> refreshAccessToken() async {
    try {
      final response = await _supabase.auth.refreshSession();
      return response.session?.accessToken;
    } catch (_) {
      // A refresh token that will not renew means the session is over. The
      // client turns a null here into "please sign in again".
      return null;
    }
  }

  @override
  Future<AuthUser> signIn({
    required String email,
    required String password,
  }) async {
    try {
      final response = await _supabase.auth.signInWithPassword(
        email: email.trim(),
        password: password,
      );
      final user = response.user;
      if (user == null || response.session == null) {
        throw const HealthRepositoryException(_signInFailed);
      }
      return AuthUser(id: user.id, email: user.email ?? email.trim());
    } on AuthException catch (error) {
      throw HealthRepositoryException(_explain(error, signingUp: false));
    }
  }

  @override
  Future<AuthUser> signUp({
    required String email,
    required String password,
    required String displayName,
  }) async {
    try {
      final response = await _supabase.auth.signUp(
        email: email.trim(),
        password: password,
        data: <String, dynamic>{'display_name': displayName.trim()},
      );
      final user = response.user;
      if (user == null) {
        throw const HealthRepositoryException(_signUpFailed);
      }
      if (response.session == null) {
        // The project has email confirmation switched on. Nothing has gone
        // wrong; there is simply a step in an inbox before signing in works.
        throw const HealthRepositoryException(
          'Your account was created. Open the confirmation link we just '
          'emailed you, then come back and sign in.',
        );
      }
      return AuthUser(
        id: user.id,
        email: user.email ?? email.trim(),
        displayName: displayName.trim(),
      );
    } on AuthException catch (error) {
      throw HealthRepositoryException(_explain(error, signingUp: true));
    }
  }

  @override
  Future<void> signOut() async {
    try {
      await _supabase.auth.signOut();
    } on AuthException {
      // Already signed out as far as the server is concerned. The local session
      // is cleared either way, and staying signed in is the worse failure.
    }
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    await _lifecycle.close();
  }

  static AuthLifecycle _lifecycleOf(String eventName) {
    switch (eventName) {
      case 'signedIn':
      case 'initialSession':
        return AuthLifecycle.signedIn;
      case 'signedOut':
      case 'userDeleted':
        return AuthLifecycle.signedOut;
      case 'tokenRefreshed':
        return AuthLifecycle.refreshed;
      default:
        return AuthLifecycle.unchanged;
    }
  }

  static const String _signInFailed =
      'That email and password did not match an account. Check both and try '
      'again.';
  static const String _signUpFailed =
      'That account could not be created. Check the email address and try '
      'again.';

  /// Turn an auth error into one of our sentences.
  ///
  /// The provider's own message is read to *choose* a sentence and is never
  /// shown: it is written for developers, it changes between versions, and it
  /// occasionally says more about an account than the person in front of the
  /// phone should be told.
  static String _explain(AuthException error, {required bool signingUp}) {
    final String hint = error.message.toLowerCase();
    if (hint.contains('already registered') ||
        hint.contains('already been registered') ||
        hint.contains('user already exists')) {
      return 'There is already an account with that email. Try signing in '
          'instead.';
    }
    if (hint.contains('invalid login') || hint.contains('invalid credentials')) {
      return _signInFailed;
    }
    if (hint.contains('email not confirmed')) {
      return 'Open the confirmation link we emailed you, then sign in.';
    }
    if (hint.contains('password')) {
      return 'That password will not do. Use at least 8 characters, and '
          'something you have not used elsewhere.';
    }
    if (hint.contains('email')) {
      return 'That does not look like an email address we can use. Check it '
          'and try again.';
    }
    if (hint.contains('rate limit') || hint.contains('too many')) {
      return 'That is a few too many attempts in a row. Wait a minute and try '
          'again.';
    }
    return signingUp ? _signUpFailed : _signInFailed;
  }
}

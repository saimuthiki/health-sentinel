/// How the HTTP client gets a bearer token, and how it asks for a fresh one.
///
/// This is an interface rather than a direct call into `supabase_flutter` for
/// two reasons. The first is that the token lifecycle is the one part of the
/// client that genuinely needs testing — a 401 must refresh once and retry once,
/// and no more — and a test that needs a real Supabase project is a test nobody
/// runs. The second is that nothing below this line should know that Supabase
/// exists at all.
abstract class AuthTokenProvider {
  /// The current access token, refreshing it first if it has already expired.
  /// Null means "not signed in", which is not an error.
  Future<String?> accessToken();

  /// Force a refresh after the backend has rejected the token we had.
  /// Returns the new token, or null when the session could not be renewed —
  /// which the client turns into [ApiFailureKind.signedOut].
  Future<String?> refreshAccessToken();
}

/// Used before sign-in, and by the endpoints that need no token at all
/// (`/healthz` is the one that matters — it is how the app wakes the backend).
class AnonymousTokens implements AuthTokenProvider {
  const AnonymousTokens();

  @override
  Future<String?> accessToken() async => null;

  @override
  Future<String?> refreshAccessToken() async => null;
}

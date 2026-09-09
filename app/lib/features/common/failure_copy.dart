import '../../data/repository/health_repository.dart';

/// The one place a failure becomes a sentence on a screen.
///
/// Everything the repository throws is a [HealthRepositoryException], and its
/// message was written in this app — by the error mapper in
/// `data/api/api_failure.dart` for anything that came off the wire, or by the
/// repository itself for the handful of things it refuses locally. So showing
/// it is safe, and it is a real improvement on a single catch-all line: an
/// expired sign-in, a consent that has not been given and a backend that is
/// still waking up are three different problems with three different answers,
/// and telling somebody "no signal" for all three is telling them nothing.
///
/// Anything else — a bug in this app, a `TypeError`, something a plugin threw —
/// falls back to [fallback]. An exception's `toString()` is never shown: it is
/// written for whoever wrote the code, not for whoever is holding the phone.
String explainFailure(Object? error, {required String fallback}) {
  if (error is HealthRepositoryException) {
    final String message = error.message.trim();
    if (message.isNotEmpty) {
      return message;
    }
  }
  return fallback;
}

/// A missing consent is a place to go, not a sentence to read.
///
/// The backend refuses anything that analyses health data until a consent row
/// exists (`backend/app/api/deps.py`, `require_consent`), and it says so with a
/// `consent-required` problem type that `api_failure.dart` already maps. What
/// was missing was the other half: somewhere for the person to be sent. Showing
/// "please agree to the consent notice" on a screen with no way to reach the
/// consent notice is a dead end, and it is the dead end that locked the owner
/// out of his own account.
///
/// So this is the one place that decides. Every screen that can receive a
/// refusal asks it the same question and gets the same answer.
library;

import '../../data/api/api_failure.dart';
import '../../data/repository/http_health_repository.dart';

/// The consent screen.
const String consentPath = '/consent';

/// The consent screen, told that it is being shown because something was
/// refused rather than because the person has just signed up.
///
/// See [consentRouteFor] for why a bare 403 lands here.
const String consentRecoveryPath = '/consent?blocked=1';

/// The query parameter [consentRecoveryPath] carries, read by the router.
const String consentBlockedParam = 'blocked';

/// The [ApiFailure] inside [error], or null when it did not come off the wire.
ApiFailure? apiFailureOf(Object? error) =>
    error is ApiRepositoryException ? error.failure : null;

/// Where to send someone whose request was refused, or null when this failure
/// has nothing to do with consent.
///
/// Two cases route here:
///
/// **`consent-required`.** Unambiguous: the backend named the problem. It is a
/// destination, never a toast, wherever it turns up.
///
/// **A bare 403 with no recognised problem type, when the app has no evidence
/// consent was ever recorded.** This is the case the owner actually hit, and it
/// is a deliberate judgement rather than an accident. The app cannot tell a
/// `PermissionDenied` from a proxy's own 403 from an older backend build, so it
/// weighs the two mistakes it could make. Routing a genuine "forbidden" to the
/// consent screen costs the person one tap, and the consent POST that follows
/// either succeeds - in which case consent really was what was missing - or
/// fails with a message that is now shown and retryable. Reporting a genuine
/// missing consent as "that is not something this account can open" costs the
/// person their account, because that screen offers no way forward at all. The
/// second mistake is unrecoverable and the first is not, so the app takes the
/// recoverable one and says plainly on arrival why it did.
///
/// [consentAlreadyRecorded] is the app's evidence, when it has any: a restored
/// session that already says consent was accepted means a 403 is about
/// something else entirely, and sending that person to a screen they have
/// already completed would be a loop rather than a fix.
String? consentRouteFor(
  Object? error, {
  required bool consentAlreadyRecorded,
}) {
  final ApiFailure? failure = apiFailureOf(error);
  if (failure == null) {
    return null;
  }
  if (failure.kind == ApiFailureKind.consentRequired) {
    return consentPath;
  }
  if (failure.kind == ApiFailureKind.forbidden && !consentAlreadyRecorded) {
    return consentRecoveryPath;
  }
  return null;
}

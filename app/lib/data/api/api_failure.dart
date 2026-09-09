import 'dart:convert';

/// Everything that can go wrong between this app and the backend, as a closed
/// set with a sentence of our own attached to each one.
///
/// The backend answers errors as RFC 9457 `application/problem+json`:
///
/// ```json
/// {"type": "https://healthpulse.app/problems/not-found",
///  "title": "Not found",
///  "status": 404,
///  "detail": "That report does not exist, or is not yours.",
///  "instance": "/v1/reports/...",
///  "request_id": "01J..."}
/// ```
///
/// `detail` is written for a person and is safe by construction — but it is
/// still a **server** string, and the one rule this file exists to keep is that
/// no server string is ever put in front of a user. The server's copy can change
/// without the app knowing, an intermediate proxy can substitute its own body,
/// and a 500 detail is deliberately the same fixed sentence for every cause. So
/// the `type` is read, matched against [ApiFailureKind], and a sentence *this
/// app* wrote is shown. `detail` is kept for logs only, in [serverDetail].
enum ApiFailureKind {
  /// The build carries no backend address. Nothing was attempted.
  notConfigured,

  /// The phone could not open a connection at all.
  offline,

  /// The backend accepted the connection and then did not answer in time.
  timeout,

  /// The free hosting tier was asleep and did not finish waking up.
  wakingUpTimedOut,

  /// 401. The access token is missing, expired past refreshing, or rejected.
  signedOut,

  /// 403 `forbidden`.
  forbidden,

  /// 403 `consent-required`.
  consentRequired,

  /// 404.
  notFound,

  /// 409.
  conflict,

  /// 413.
  fileTooLarge,

  /// 415.
  unsupportedFile,

  /// 422.
  invalidRequest,

  /// 429.
  rateLimited,

  /// 503 `upstream-unavailable`.
  upstreamUnavailable,

  /// 503 `not-ready` — configured wrongly, or still starting.
  notReady,

  /// 500, and anything else with a status we do not recognise.
  serverError,

  /// A 2xx whose body was not the shape we expected.
  unreadableResponse,
}

/// A failure, carrying the sentence to show and nothing that came off the wire.
class ApiFailure implements Exception {
  const ApiFailure(
    this.kind, {
    this.status,
    this.problemType,
    this.requestId,
    this.serverDetail,
    this.retryAfter,
  });

  final ApiFailureKind kind;

  /// The HTTP status, when there was a response at all.
  final int? status;

  /// The `type` URI the backend sent. Diagnostic only.
  final String? problemType;

  /// The backend's request id, so a person can quote it to us. It is an opaque
  /// identifier, not prose, so it is the one server-provided value the app may
  /// show — and only ever as a small trailing line, never as the explanation.
  final String? requestId;

  /// The server's own `detail`. **Never rendered.** Kept so that a log or a bug
  /// report can carry it.
  final String? serverDetail;

  /// From a `Retry-After` header, when the backend sent one.
  final Duration? retryAfter;

  /// What the person reading the screen is told. Written here, in the app's
  /// voice: what happened, and the one thing that changes it.
  String get message => _messages[kind]!;

  /// True when trying the same thing again in a moment is reasonable.
  bool get isRetryable {
    switch (kind) {
      case ApiFailureKind.offline:
      case ApiFailureKind.timeout:
      case ApiFailureKind.wakingUpTimedOut:
      case ApiFailureKind.rateLimited:
      case ApiFailureKind.upstreamUnavailable:
      case ApiFailureKind.notReady:
      case ApiFailureKind.serverError:
        return true;
      case ApiFailureKind.notConfigured:
      case ApiFailureKind.signedOut:
      case ApiFailureKind.forbidden:
      case ApiFailureKind.consentRequired:
      case ApiFailureKind.notFound:
      case ApiFailureKind.conflict:
      case ApiFailureKind.fileTooLarge:
      case ApiFailureKind.unsupportedFile:
      case ApiFailureKind.invalidRequest:
      case ApiFailureKind.unreadableResponse:
        return false;
    }
  }

  /// True when the app should stop and send the person back to signing in.
  bool get requiresSignIn => kind == ApiFailureKind.signedOut;

  @override
  String toString() => 'ApiFailure(${kind.name}, status: $status)';

  static const Map<ApiFailureKind, String> _messages =
      <ApiFailureKind, String>{
    ApiFailureKind.notConfigured:
        'This copy of HealthPulse has not been connected to its server yet, so '
            'there is nothing to fetch.',
    ApiFailureKind.offline:
        'Your phone is not online, so nothing new could be fetched. Anything '
            'saved on this phone is still here.',
    ApiFailureKind.timeout:
        'The health engine did not answer in time. Nothing was lost — try '
            'again in a moment.',
    ApiFailureKind.wakingUpTimedOut:
        'The health engine is on free hosting and goes to sleep when it is not '
            'used. It is taking longer than usual to wake up. Try again in a '
            'minute.',
    ApiFailureKind.signedOut:
        'Your sign-in has expired. Please sign in again to carry on.',
    ApiFailureKind.forbidden:
        'That is not something this account can open.',
    ApiFailureKind.consentRequired:
        'Please agree to the consent notice before we look at anything about '
            'your health.',
    ApiFailureKind.notFound:
        'We could not find that. It may have been deleted from this account.',
    ApiFailureKind.conflict:
        'That has already been done, so nothing changed.',
    ApiFailureKind.fileTooLarge:
        'That file is too large to send. A photo of each page on its own '
            'usually fits comfortably.',
    ApiFailureKind.unsupportedFile:
        'We can read PDF files and JPEG, PNG or HEIC photos. Try one of those.',
    ApiFailureKind.invalidRequest:
        'Something on that form was not in a shape we could use. Check what '
            'you typed and try again.',
    ApiFailureKind.rateLimited:
        'You are going a little fast for us. Give it a moment and try again.',
    ApiFailureKind.upstreamUnavailable:
        'A service we depend on is not answering right now. Nothing you sent '
            'was lost. Try again shortly.',
    ApiFailureKind.notReady:
        'The health engine is still starting up. Give it a minute and try '
            'again.',
    // Deliberately not word for word the backend's own 500 detail. The rule is
    // that the app writes what the app shows, and a copy that happens to match
    // today would drift silently the day the server's changes.
    ApiFailureKind.serverError:
        'Something went wrong at our end. Nothing you sent was lost \u2014 give '
            'it a moment and try again.',
    ApiFailureKind.unreadableResponse:
        'The health engine sent back something this version of the app could '
            'not read. Updating the app usually fixes it.',
  };

  /// The `type` URI suffixes the backend mints, mapped to our failures.
  ///
  /// These come straight from `backend/app/core/errors.py`; the key is the last
  /// path segment of `https://healthpulse.app/problems/<code>`.
  static const Map<String, ApiFailureKind> _byCode = <String, ApiFailureKind>{
    'not-authenticated': ApiFailureKind.signedOut,
    'forbidden': ApiFailureKind.forbidden,
    'consent-required': ApiFailureKind.consentRequired,
    'not-found': ApiFailureKind.notFound,
    'conflict': ApiFailureKind.conflict,
    'payload-too-large': ApiFailureKind.fileTooLarge,
    'unsupported-file-type': ApiFailureKind.unsupportedFile,
    'invalid-request': ApiFailureKind.invalidRequest,
    'rate-limited': ApiFailureKind.rateLimited,
    'upstream-unavailable': ApiFailureKind.upstreamUnavailable,
    'not-ready': ApiFailureKind.notReady,
    'internal-error': ApiFailureKind.serverError,
  };

  /// Read a problem document, or fall back to the status line.
  ///
  /// Nothing in [body] is trusted for display. The status is trusted over the
  /// document's own `status` field, because the status line is the thing the
  /// HTTP client actually saw.
  factory ApiFailure.fromResponse(
    int status,
    List<int> bodyBytes, {
    String? retryAfterHeader,
  }) {
    Map<String, dynamic> problem = const <String, dynamic>{};
    try {
      final String text = utf8.decode(bodyBytes, allowMalformed: true);
      if (text.trim().isNotEmpty) {
        final Object? decoded = jsonDecode(text);
        if (decoded is Map) {
          problem = decoded.cast<String, dynamic>();
        }
      }
    } catch (_) {
      // A body that will not parse tells us nothing, and an HTML error page
      // from a proxy is exactly the sort of thing we must not put on screen.
      problem = const <String, dynamic>{};
    }

    final String? type =
        problem['type'] is String ? problem['type'] as String : null;
    final String? detail =
        problem['detail'] is String ? problem['detail'] as String : null;
    final String? requestId =
        problem['request_id'] is String ? problem['request_id'] as String : null;

    return ApiFailure(
      _kindFor(status, type),
      status: status,
      problemType: type,
      requestId: requestId,
      serverDetail: detail,
      retryAfter: _parseRetryAfter(retryAfterHeader),
    );
  }

  static ApiFailureKind _kindFor(int status, String? type) {
    final String? code = _codeOf(type);
    if (code != null) {
      final ApiFailureKind? known = _byCode[code];
      if (known != null) {
        return known;
      }
      // `app.main._http_handler` mints `http-<status>` for Starlette's own
      // errors. Those carry no meaning beyond the status, so fall through.
    }
    switch (status) {
      case 401:
        return ApiFailureKind.signedOut;
      case 403:
        return ApiFailureKind.forbidden;
      case 404:
        return ApiFailureKind.notFound;
      case 409:
        return ApiFailureKind.conflict;
      case 413:
        return ApiFailureKind.fileTooLarge;
      case 415:
        return ApiFailureKind.unsupportedFile;
      case 422:
        return ApiFailureKind.invalidRequest;
      case 429:
        return ApiFailureKind.rateLimited;
      case 503:
        return ApiFailureKind.upstreamUnavailable;
      default:
        return ApiFailureKind.serverError;
    }
  }

  static String? _codeOf(String? type) {
    if (type == null || type.trim().isEmpty) {
      return null;
    }
    final int slash = type.lastIndexOf('/');
    final String code = slash == -1 ? type : type.substring(slash + 1);
    return code.trim().isEmpty ? null : code.trim();
  }

  /// `Retry-After` is either seconds or an HTTP date. Only seconds are honoured;
  /// a date we cannot parse simply means we do not know how long to wait.
  static Duration? _parseRetryAfter(String? header) {
    if (header == null || header.trim().isEmpty) {
      return null;
    }
    final int? seconds = int.tryParse(header.trim());
    if (seconds != null && seconds >= 0) {
      return Duration(seconds: seconds);
    }
    return null;
  }
}

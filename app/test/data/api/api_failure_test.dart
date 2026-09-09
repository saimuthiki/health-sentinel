import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:healthpulse/data/api/api_failure.dart';

/// Every problem the backend can return, and the sentence a person is shown for
/// it.
///
/// The property under test is not "the mapping is complete" — it is that **the
/// server's own words never reach a screen.** `backend/app/core/errors.py`
/// writes a `detail` for each problem; this suite proves that detail is parsed,
/// used to choose one of our sentences, and then left behind.
void main() {
  List<int> problem(String code, int status, String detail) {
    return utf8.encode(
      jsonEncode(<String, dynamic>{
        'type': 'https://healthpulse.app/problems/$code',
        'title': 'A title we also do not show',
        'status': status,
        'detail': detail,
        'instance': '/v1/thing',
        'request_id': '01JEXAMPLE',
      }),
    );
  }

  /// Code, status, and the exact `detail` the backend ships today.
  const List<List<Object>> cases = <List<Object>>[
    <Object>[
      'not-authenticated',
      401,
      'Your sign-in could not be verified. Please sign in again.',
      ApiFailureKind.signedOut,
    ],
    <Object>['forbidden', 403, 'You do not have access to that.',
        ApiFailureKind.forbidden],
    <Object>[
      'consent-required',
      403,
      'Please accept the current consent notice before we analyse anything '
          'about your health.',
      ApiFailureKind.consentRequired,
    ],
    <Object>['not-found', 404, 'We could not find that.',
        ApiFailureKind.notFound],
    <Object>['conflict', 409, 'That has already been done.',
        ApiFailureKind.conflict],
    <Object>[
      'payload-too-large',
      413,
      'That file is larger than we can accept.',
      ApiFailureKind.fileTooLarge,
    ],
    <Object>[
      'unsupported-file-type',
      415,
      'We can read PDF, JPEG, PNG and HEIC files.',
      ApiFailureKind.unsupportedFile,
    ],
    <Object>[
      'invalid-request',
      422,
      'Some of what you sent was not in a form we could use.',
      ApiFailureKind.invalidRequest,
    ],
    <Object>[
      'rate-limited',
      429,
      'You are going a little fast. Please try again shortly.',
      ApiFailureKind.rateLimited,
    ],
    <Object>[
      'upstream-unavailable',
      503,
      'A service we depend on is not responding right now. Please try again '
          'shortly.',
      ApiFailureKind.upstreamUnavailable,
    ],
    <Object>[
      'not-ready',
      503,
      'The service is starting up or is not fully configured.',
      ApiFailureKind.notReady,
    ],
    <Object>[
      'internal-error',
      500,
      'Something went wrong on our side. Nothing you sent was lost. Please try '
          'again in a moment.',
      ApiFailureKind.serverError,
    ],
  ];

  group('problem+json becomes a typed failure', () {
    for (final List<Object> row in cases) {
      final String code = row[0] as String;
      final int status = row[1] as int;
      final String detail = row[2] as String;
      final ApiFailureKind expected = row[3] as ApiFailureKind;

      test('$code is ${expected.name}', () {
        final ApiFailure failure =
            ApiFailure.fromResponse(status, problem(code, status, detail));
        expect(failure.kind, expected);
        expect(failure.status, status);
        expect(failure.problemType, endsWith('/$code'));
        expect(failure.requestId, '01JEXAMPLE');
        // Kept for a log, never for a screen.
        expect(failure.serverDetail, detail);
      });
    }
  });

  test('every failure has a sentence of our own, and it is not the server\'s',
      () {
    for (final ApiFailureKind kind in ApiFailureKind.values) {
      final ApiFailure failure = ApiFailure(kind);
      expect(failure.message.trim(), isNotEmpty,
          reason: '${kind.name} has no message');
      // A sentence, not a code fragment.
      expect(failure.message, contains(' '));
      expect(failure.message.toLowerCase(), isNot(contains('exception')));
      expect(failure.message.toLowerCase(), isNot(contains('http ')));
    }

    for (final List<Object> row in cases) {
      final ApiFailure failure = ApiFailure.fromResponse(
        row[1] as int,
        problem(row[0] as String, row[1] as int, row[2] as String),
      );
      expect(
        failure.message,
        isNot(equals(row[2] as String)),
        reason: '${row[0]} shows the backend\'s own detail verbatim',
      );
    }
  });

  test('an unrecognised problem type falls back to the status', () {
    final ApiFailure failure = ApiFailure.fromResponse(
      404,
      problem('something-invented-later', 404, 'A detail we do not know'),
    );
    expect(failure.kind, ApiFailureKind.notFound);
  });

  test('Starlette\'s own http-<status> problems map by status', () {
    final ApiFailure failure =
        ApiFailure.fromResponse(405, problem('http-405', 405, 'Nope.'));
    expect(failure.kind, ApiFailureKind.serverError);
    expect(failure.message, isNot(contains('Nope')));
  });

  test('an HTML error page from a proxy never reaches the screen', () {
    const String html =
        '<html><body><h1>502 Bad Gateway</h1><pre>upstream connect error, '
        'host=10.0.0.4:8000</pre></body></html>';
    final ApiFailure failure =
        ApiFailure.fromResponse(502, utf8.encode(html));
    expect(failure.kind, ApiFailureKind.serverError);
    expect(failure.message, isNot(contains('502')));
    expect(failure.message, isNot(contains('upstream')));
    expect(failure.message, isNot(contains('10.0.0.4')));
    expect(failure.serverDetail, isNull);
  });

  test('an empty body is still a typed failure', () {
    final ApiFailure failure = ApiFailure.fromResponse(429, const <int>[]);
    expect(failure.kind, ApiFailureKind.rateLimited);
    expect(failure.message, isNotEmpty);
  });

  test('Retry-After in seconds is read; a date is not guessed at', () {
    final ApiFailure withSeconds = ApiFailure.fromResponse(
      429,
      problem('rate-limited', 429, 'Slow down.'),
      retryAfterHeader: '30',
    );
    expect(withSeconds.retryAfter, const Duration(seconds: 30));

    final ApiFailure withDate = ApiFailure.fromResponse(
      429,
      problem('rate-limited', 429, 'Slow down.'),
      retryAfterHeader: 'Wed, 21 Oct 2026 07:28:00 GMT',
    );
    expect(withDate.retryAfter, isNull);
  });

  test('what is worth retrying, and what sends someone to sign in', () {
    expect(const ApiFailure(ApiFailureKind.offline).isRetryable, isTrue);
    expect(const ApiFailure(ApiFailureKind.wakingUpTimedOut).isRetryable,
        isTrue);
    expect(const ApiFailure(ApiFailureKind.notFound).isRetryable, isFalse);
    expect(const ApiFailure(ApiFailureKind.consentRequired).isRetryable,
        isFalse);
    expect(const ApiFailure(ApiFailureKind.signedOut).requiresSignIn, isTrue);
    expect(const ApiFailure(ApiFailureKind.forbidden).requiresSignIn, isFalse);
  });

  test('the cold-start message explains the wait rather than blaming the phone',
      () {
    final String message =
        const ApiFailure(ApiFailureKind.wakingUpTimedOut).message;
    expect(message.toLowerCase(), contains('wake'));
    expect(message.toLowerCase(), contains('try again'));
  });
}

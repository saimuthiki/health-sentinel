import 'package:flutter_test/flutter_test.dart';
import 'package:healthpulse/data/api/api_failure.dart';
import 'package:healthpulse/data/repository/health_repository.dart';
import 'package:healthpulse/data/repository/http_health_repository.dart';
import 'package:healthpulse/features/common/failure_copy.dart';

/// The last gate before a screen: nothing that came off the wire, and nothing
/// an exception printed, is allowed through as user-facing copy.
void main() {
  test('a mapped API failure shows our sentence for it', () {
    final ApiRepositoryException error = ApiRepositoryException(
      const ApiFailure(ApiFailureKind.consentRequired, status: 403),
    );
    expect(
      explainFailure(error, fallback: 'fallback'),
      const ApiFailure(ApiFailureKind.consentRequired).message,
    );
    expect(explainFailure(error, fallback: 'fallback'),
        contains('consent notice'));
  });

  test('a repository refusal written locally shows too', () {
    expect(
      explainFailure(
        const HealthRepositoryException('That message is too long to send.'),
        fallback: 'fallback',
      ),
      'That message is too long to send.',
    );
  });

  test('anything else falls back, and never prints the exception', () {
    const String secretish =
        'FormatException: Unexpected character (at character 1) in '
        'https://internal.host/v1/thing';
    expect(
      explainFailure(Exception(secretish), fallback: 'Something went wrong.'),
      'Something went wrong.',
    );
    expect(
      explainFailure(StateError(secretish), fallback: 'Something went wrong.'),
      'Something went wrong.',
    );
    expect(explainFailure(null, fallback: 'Something went wrong.'),
        'Something went wrong.');
    expect(
      explainFailure('a bare string', fallback: 'Something went wrong.'),
      'Something went wrong.',
    );
  });

  test('an empty message falls back rather than showing a blank screen', () {
    expect(
      explainFailure(const HealthRepositoryException('   '),
          fallback: 'Something went wrong.'),
      'Something went wrong.',
    );
  });

  test('the failure rides along so a caller can still branch on it', () {
    final ApiRepositoryException error = ApiRepositoryException(
      const ApiFailure(ApiFailureKind.signedOut, status: 401),
    );
    expect(error.failure.requiresSignIn, isTrue);
    expect(error.message, error.failure.message);
  });
}

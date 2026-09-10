import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:healthpulse/data/api/api_failure.dart';
import 'package:healthpulse/data/repository/health_repository.dart';
import 'package:healthpulse/data/repository/http_health_repository.dart';
import 'package:healthpulse/features/auth/sign_in_screen.dart';
import 'package:healthpulse/features/common/consent_routing.dart';
import 'package:healthpulse/features/onboarding/consent_screen.dart';

import '_onboarding_harness.dart';
import '_refusing_repository.dart';

/// A missing consent must be a destination, never a message.
///
/// The owner's account was signed in at Supabase and refused by the backend,
/// and the app answered with "That is not something this account can open" on a
/// screen with no way onward. There was no route back to consent from anywhere.
void main() {
  ApiRepositoryException refusal(ApiFailureKind kind, {int? status}) {
    return ApiRepositoryException(ApiFailure(kind, status: status));
  }

  group('consentRouteFor', () {
    test('a named consent-required always goes to consent', () {
      expect(
        consentRouteFor(
          refusal(ApiFailureKind.consentRequired, status: 403),
          consentAlreadyRecorded: false,
        ),
        consentPath,
      );
      // Even when the app thinks consent was recorded: the backend is the one
      // holding the row, and it has just said otherwise.
      expect(
        consentRouteFor(
          refusal(ApiFailureKind.consentRequired, status: 403),
          consentAlreadyRecorded: true,
        ),
        consentPath,
      );
    });

    test('a bare 403 with no consent on record goes to consent, and says so',
        () {
      expect(
        consentRouteFor(
          refusal(ApiFailureKind.forbidden, status: 403),
          consentAlreadyRecorded: false,
        ),
        consentRecoveryPath,
      );
    });

    test('a bare 403 after consent was recorded is left alone', () {
      // Otherwise this is a loop: back to a screen already completed, which
      // then refuses in the same way.
      expect(
        consentRouteFor(
          refusal(ApiFailureKind.forbidden, status: 403),
          consentAlreadyRecorded: true,
        ),
        isNull,
      );
    });

    test('nothing else is diverted', () {
      for (final ApiFailureKind kind in <ApiFailureKind>[
        ApiFailureKind.signedOut,
        ApiFailureKind.offline,
        ApiFailureKind.timeout,
        ApiFailureKind.wakingUpTimedOut,
        ApiFailureKind.notFound,
        ApiFailureKind.serverError,
      ]) {
        expect(
          consentRouteFor(refusal(kind), consentAlreadyRecorded: false),
          isNull,
          reason: '${kind.name} is not a consent problem',
        );
      }
    });

    test('a failure that never came off the wire is not a consent problem', () {
      expect(
        consentRouteFor(
          const HealthRepositoryException('That message is too long.'),
          consentAlreadyRecorded: false,
        ),
        isNull,
      );
      expect(
        consentRouteFor(Exception('boom'), consentAlreadyRecorded: false),
        isNull,
      );
      expect(consentRouteFor(null, consentAlreadyRecorded: false), isNull);
    });
  });

  group('signing in', () {
    Future<void> signIn(WidgetTester tester) async {
      final Finder fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), 'sai@example.com');
      await tester.enterText(fields.at(1), 'a-real-password');
      await tester.pump();
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
    }

    testWidgets('a consent-required refusal routes to consent, not a message',
        (WidgetTester tester) async {
      useTallSurface(tester);
      await tester.pumpWidget(
        onboardingApp(
          repository: RefusingRepository(
            signedIn: false,
            refuseSignIn: true,
            failure: const ApiFailure(
              ApiFailureKind.consentRequired,
              status: 403,
            ),
          ),
          router: onboardingRouter(initialLocation: '/welcome'),
        ),
      );
      await tester.pump();

      await signIn(tester);

      expect(find.byType(ConsentScreen), findsOneWidget);
      expect(find.byType(SignInScreen), findsNothing);
      // The refusal became a place to go, so it is not also shouted at anyone.
      expect(
        find.text(const ApiFailure(ApiFailureKind.consentRequired).message),
        findsNothing,
      );
    });

    testWidgets('the bare 403 the owner hit routes to consent, explained',
        (WidgetTester tester) async {
      useTallSurface(tester);
      await tester.pumpWidget(
        onboardingApp(
          repository: RefusingRepository(
            signedIn: false,
            refuseSignIn: true,
            failure: const ApiFailure(ApiFailureKind.forbidden, status: 403),
          ),
          router: onboardingRouter(initialLocation: '/welcome'),
        ),
      );
      await tester.pump();

      await signIn(tester);

      expect(find.byType(ConsentScreen), findsOneWidget);
      expect(
        find.textContaining('could not confirm that this account has agreed'),
        findsOneWidget,
      );
      // Not the dead-end sentence he actually saw.
      expect(
        find.text(const ApiFailure(ApiFailureKind.forbidden).message),
        findsNothing,
      );
    });

    testWidgets('a wrong password still stays on the sign-in screen',
        (WidgetTester tester) async {
      useTallSurface(tester);
      await tester.pumpWidget(
        onboardingApp(
          repository: RefusingRepository(
            signedIn: false,
            refuseSignIn: true,
            failure: const ApiFailure(ApiFailureKind.signedOut, status: 401),
          ),
          router: onboardingRouter(initialLocation: '/welcome'),
        ),
      );
      await tester.pump();

      await signIn(tester);

      // Moving somebody off the one screen that can fix a bad password would be
      // worse than showing them the sentence.
      expect(find.byType(SignInScreen), findsOneWidget);
      expect(find.byType(ConsentScreen), findsNothing);
      expect(
        find.text(const ApiFailure(ApiFailureKind.signedOut).message),
        findsOneWidget,
      );
    });
  });
}

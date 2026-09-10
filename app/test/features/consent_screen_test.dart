import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:healthpulse/data/api/api_failure.dart';
import 'package:healthpulse/data/api/api_status.dart';
import 'package:healthpulse/features/onboarding/consent_screen.dart';
import 'package:healthpulse/features/profile/health_profile_screen.dart';

import '_onboarding_harness.dart';
import '_refusing_repository.dart';

/// The screen the owner got stuck on.
///
/// He signed up, tapped "Agree and continue", and the free host took fifty
/// seconds to wake. The button spun, said nothing, and when the call finally
/// failed nothing reset it: no message, no retry, no way forward, and no
/// consent row on the server. Sign-up then said the account existed and sign-in
/// was refused with a 403. Every test here is one of the pieces of that trap.
void main() {
  /// Both switches. The button is inert until both are on, which is the point
  /// of having two of them.
  Future<void> agreeToBoth(WidgetTester tester) async {
    final Finder switches = find.byType(Switch);
    expect(switches, findsNWidgets(2));
    for (int i = 0; i < 2; i++) {
      await tester.ensureVisible(switches.at(i));
      await tester.tap(switches.at(i));
      await tester.pump();
    }
  }

  // The spinner is the whole complaint: a button that spins for ever.
  bool consentIsBusy() {
    final Finder spinner = find.descendant(
      of: find.byType(ConsentScreen),
      matching: find.byType(CircularProgressIndicator),
    );
    return spinner.evaluate().isNotEmpty;
  }

  testWidgets(
      'a refused consent stops the spinner, says why, and stays put',
      (WidgetTester tester) async {
    useTallSurface(tester);
    final RefusingRepository repository = RefusingRepository(
      refuseConsent: true,
      failure: const ApiFailure(ApiFailureKind.wakingUpTimedOut),
    );

    await tester.pumpWidget(
      onboardingApp(repository: repository, router: onboardingRouter()),
    );
    await tester.pump();

    await agreeToBoth(tester);
    await tester.tap(find.text('Agree and continue'));
    await settleWithoutAnimations(tester);

    // 1. The spinner stopped.
    expect(consentIsBusy(), isFalse,
        reason: 'the busy state outlived the failure');

    // 2. A sentence a person can read, and one this app wrote.
    expect(
      find.text(const ApiFailure(ApiFailureKind.wakingUpTimedOut).message),
      findsOneWidget,
    );

    // 3. Still on consent. Nothing may move on from a consent that was never
    //    recorded, because that is exactly what locked the account.
    expect(find.byType(ConsentScreen), findsOneWidget);
    expect(find.byType(HealthProfileScreen), findsNothing);

    // 4. The button works again: a second tap really does try again.
    expect(repository.consentCalls, 1);
    await tester.tap(find.text('Agree and continue'));
    await settleWithoutAnimations(tester);
    expect(repository.consentCalls, 2);
  });

  testWidgets('a consent that succeeds moves on once', (WidgetTester tester) async {
    useTallSurface(tester);
    final RefusingRepository repository = RefusingRepository();

    await tester.pumpWidget(
      onboardingApp(repository: repository, router: onboardingRouter()),
    );
    await tester.pump();

    await agreeToBoth(tester);
    await tester.tap(find.text('Agree and continue'));
    // Safe to settle here and nowhere else: on the way out there is no spinner
    // left to animate for ever, and the page transition has to finish before
    // "the consent screen is gone" means anything.
    await tester.pumpAndSettle();

    expect(find.byType(HealthProfileScreen), findsOneWidget);
    expect(find.byType(ConsentScreen), findsNothing);
    // Once. Not twice, and not zero times with a navigation anyway.
    expect(repository.consentCalls, 1);
  });

  testWidgets('a second tap while the first is in flight is ignored',
      (WidgetTester tester) async {
    useTallSurface(tester);
    final RefusingRepository repository = RefusingRepository();

    await tester.pumpWidget(
      onboardingApp(repository: repository, router: onboardingRouter()),
    );
    await tester.pump();

    await agreeToBoth(tester);
    await tester.tap(find.text('Agree and continue'));
    // No pump between the taps: the first call has not resolved yet.
    await tester.tap(find.text('Agree and continue'));
    await tester.pumpAndSettle();

    expect(repository.consentCalls, 1);
  });

  testWidgets('says the free host is waking, and roughly how long',
      (WidgetTester tester) async {
    useTallSurface(tester);

    await tester.pumpWidget(
      onboardingApp(
        repository: RefusingRepository(),
        router: onboardingRouter(),
        phase: ApiPhase.waking,
      ),
    );
    // Never pumpAndSettle here: the notice carries a spinner of its own.
    await tester.pump();

    expect(find.text(ApiPhase.waking.waitingMessage), findsOneWidget);
    expect(find.textContaining('free hosting'), findsOneWidget);
    expect(find.textContaining('up to a minute'), findsOneWidget);
  });

  testWidgets('says nothing about waking when nothing is waking',
      (WidgetTester tester) async {
    useTallSurface(tester);

    await tester.pumpWidget(
      onboardingApp(
        repository: RefusingRepository(),
        router: onboardingRouter(),
      ),
    );
    await tester.pump();

    expect(find.textContaining('free hosting'), findsNothing);
    expect(find.text(ApiPhase.waking.waitingMessage), findsNothing);
  });

  testWidgets('explains itself when it was reached by a refusal',
      (WidgetTester tester) async {
    useTallSurface(tester);

    await tester.pumpWidget(
      onboardingApp(
        repository: RefusingRepository(),
        router: onboardingRouter(initialLocation: '/consent?blocked=1'),
      ),
    );
    await tester.pump();

    expect(find.byType(ConsentScreen), findsOneWidget);
    expect(
      find.textContaining('could not confirm that this account has agreed'),
      findsOneWidget,
    );
  });

  testWidgets('says nothing of the sort when it was reached the ordinary way',
      (WidgetTester tester) async {
    useTallSurface(tester);

    await tester.pumpWidget(
      onboardingApp(
        repository: RefusingRepository(),
        router: onboardingRouter(),
      ),
    );
    await tester.pump();

    expect(find.byType(ConsentScreen), findsOneWidget);
    expect(
      find.textContaining('could not confirm that this account has agreed'),
      findsNothing,
    );
  });
}

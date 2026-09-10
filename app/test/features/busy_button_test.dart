import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:healthpulse/core/widgets/hp_button.dart';
import 'package:healthpulse/data/api/api_failure.dart';
import 'package:healthpulse/features/chat/chat_screen.dart';
import 'package:healthpulse/features/onboarding/consent_screen.dart';
import 'package:healthpulse/features/profile/health_profile_screen.dart';

import '_onboarding_harness.dart';
import '_refusing_repository.dart';

/// The regression this whole change exists to prevent.
///
/// The shape of the bug was not "consent is broken". It was an `async` button
/// handler written as
///
/// ```dart
/// setState(() => _busy = true);
/// await somethingThatCanThrow();
/// setState(() => _busy = false);
/// ```
///
/// where the second `setState` is unreachable the moment the call throws. Every
/// handler that ever sets a busy flag is checked here against the same three
/// questions, because on a first-run screen a spinner that cannot stop is
/// indistinguishable from a dead app - and force-quitting a dead app is how the
/// owner ended up with an account he could not sign into.
void main() {
  /// The one assertion this file is about, applied the same way everywhere.
  void expectRecoverable({
    required Finder screen,
    required String label,
  }) {
    final Finder spinner = find.descendant(
      of: screen,
      matching: find.byType(CircularProgressIndicator),
    );
    expect(
      spinner,
      findsNothing,
      reason: '$label left a spinner running after the call failed',
    );
    expect(
      screen,
      findsOneWidget,
      reason: '$label navigated away from a call that did not succeed',
    );
  }

  testWidgets('consent: "Agree and continue" recovers from a refusal',
      (WidgetTester tester) async {
    useTallSurface(tester);
    final RefusingRepository repository = RefusingRepository(
      refuseConsent: true,
      failure: const ApiFailure(ApiFailureKind.serverError, status: 500),
    );

    await tester.pumpWidget(
      onboardingApp(repository: repository, router: onboardingRouter()),
    );
    await tester.pump();

    final Finder switches = find.byType(Switch);
    for (int i = 0; i < 2; i++) {
      await tester.tap(switches.at(i));
      await tester.pump();
    }
    await tester.tap(find.text('Agree and continue'));
    await settleWithoutAnimations(tester);

    expectRecoverable(screen: find.byType(ConsentScreen), label: 'consent');
    // And the button really is live again, not merely still on screen.
    final HpButtonProbe consent = probe(tester, 'Agree and continue');
    expect(consent.busy, isFalse);
    expect(consent.enabled, isTrue);
  });

  testWidgets('profile wizard: "Save profile" recovers from a refusal',
      (WidgetTester tester) async {
    useTallSurface(tester);
    final RefusingRepository repository = RefusingRepository(
      refuseProfile: true,
      failure: const ApiFailure(ApiFailureKind.wakingUpTimedOut),
    );

    await tester.pumpWidget(
      onboardingApp(
        repository: repository,
        router: onboardingRouter(initialLocation: '/profile'),
      ),
    );
    await tester.pump();

    // Six steps, five taps of Continue to reach the last one.
    for (int step = 1; step < 6; step++) {
      await tester.tap(find.text('Continue'));
      await tester.pump();
    }
    expect(find.text('Save profile'), findsOneWidget);

    await tester.tap(find.text('Save profile'));
    await settleWithoutAnimations(tester);

    expectRecoverable(
      screen: find.byType(HealthProfileScreen),
      label: 'profile wizard',
    );
    expect(find.text(todayMarker), findsNothing);
    expect(
      find.text(const ApiFailure(ApiFailureKind.wakingUpTimedOut).message),
      findsOneWidget,
    );

    final HpButtonProbe save = probe(tester, 'Save profile');
    expect(save.busy, isFalse);
    expect(save.enabled, isTrue);

    // Every answer is still in the wizard, so trying again is one tap.
    expect(repository.profileSaves, 1);
    await tester.tap(find.text('Save profile'));
    await settleWithoutAnimations(tester);
    expect(repository.profileSaves, 2);
  });

  testWidgets('chat: send recovers from a refusal and keeps the words',
      (WidgetTester tester) async {
    useTallSurface(tester);
    final RefusingRepository repository = RefusingRepository(refuseSend: true);

    await tester.pumpWidget(
      onboardingApp(
        repository: repository,
        router: onboardingRouter(initialLocation: '/chat'),
      ),
    );
    await settleWithoutAnimations(tester);

    const String typed = 'I had two idlis and a coffee';
    await tester.enterText(find.byType(TextField), typed);
    await tester.pump();
    await tester.tap(find.widgetWithIcon(IconButton, Icons.send_rounded));
    await settleWithoutAnimations(tester);

    expectRecoverable(screen: find.byType(ChatScreen), label: 'chat');

    // The send button is usable again rather than disabled for the life of the
    // screen, which is what a stuck `_sending` did.
    final IconButton send = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.send_rounded),
    );
    expect(send.onPressed, isNotNull);

    // And the message is back in the box rather than lost.
    final TextField input = tester.widget<TextField>(find.byType(TextField));
    expect(input.controller?.text, typed);
    expect(
      find.text(const ApiFailure(ApiFailureKind.wakingUpTimedOut).message),
      findsOneWidget,
    );
  });
}

/// What a test needs to know about one of the app's buttons.
class HpButtonProbe {
  const HpButtonProbe({required this.busy, required this.enabled});

  final bool busy;
  final bool enabled;
}

/// Read the state of the [HpButton] carrying [label].
HpButtonProbe probe(WidgetTester tester, String label) {
  final HpButton button = tester.widget<HpButton>(
    find.widgetWithText(HpButton, label),
  );
  return HpButtonProbe(busy: button.busy, enabled: button.onPressed != null);
}

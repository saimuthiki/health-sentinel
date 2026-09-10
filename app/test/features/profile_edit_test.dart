import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:healthpulse/core/theme/hp_theme.dart';
import 'package:healthpulse/data/api/api_failure.dart';
import 'package:healthpulse/data/models/models.dart';
import 'package:healthpulse/data/providers.dart';
import 'package:healthpulse/data/repository/fake_health_repository.dart';
import 'package:healthpulse/data/repository/health_repository.dart';
import 'package:healthpulse/data/repository/http_health_repository.dart';
import 'package:healthpulse/features/profile/health_profile_screen.dart';
import 'package:healthpulse/features/profile/profile_inputs.dart';
import 'package:healthpulse/features/profile/profile_routing.dart';
import 'package:healthpulse/features/profile/profile_summary_screen.dart';

/// The bug the owner reported, in his own words: tapping "Health profile" in
/// More "again asks for the same user preferences right from the start. There
/// is no back option, and there are no already-filled options."
///
/// Every test here is one piece of that. The one that matters most is the
/// second: `PUT /v1/me/profile` replaces the whole record, so a screen that
/// edits one answer has to send every other answer back exactly as it found
/// them. Getting that wrong would turn "change my city" into "delete my
/// allergies", which is worse than the bug being fixed.
void main() {
  // ---------------------------------------------------------------- fixtures

  /// A profile with most things answered and one thing left blank, because a
  /// half-filled profile is the ordinary case rather than the odd one.
  ///
  /// The values deliberately avoid the hint text of the boxes that show them -
  /// the city box hints "Hyderabad", the weight box hints "64" - so that
  /// finding a value on screen proves it came from the saved profile and not
  /// from an empty box's placeholder.
  HealthProfile savedProfile() {
    return HealthProfile(
      userId: 'demo-user',
      dob: DateTime(1990, 3, 4),
      sex: Sex.female,
      heightCm: 170,
      activityLevel: ActivityLevel.moderate,
      dietType: DietType.jain,
      cuisinePrefs: const <String>['South Indian'],
      city: 'Bengaluru',
      pincode: '560001',
      wakeTime: '06:00',
      sleepTime: '22:00',
      mealTimes: MealSlot.defaultTimes,
      conditions: const <String>['Thyroid'],
      allergies: const <Allergy>[
        Allergy(id: 'a1', allergen: 'Peanuts', severity: AllergySeverity.severe),
      ],
      goalTypes: const <GoalType>[GoalType.energy],
    );
  }

  const ApiFailure refusal = ApiFailure(ApiFailureKind.wakingUpTimedOut);

  const String moreMarker = 'MORE-REACHED';

  /// A surface tall enough that the whole summary has no fold.
  ///
  /// A `ListView` only builds what it can show, and a tap on something that was
  /// never built throws rather than scrolling to it, so the alternative is a
  /// scroll before every single interaction.
  void useTallSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(620, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// Let a queued success or refusal land without waiting on any animation.
  ///
  /// [WidgetTester.pumpAndSettle] cannot be used while anything on screen is
  /// spinning: a progress indicator animates for ever, so a screen that is
  /// meant to be busy would time the settle out and a screen that is meant not
  /// to be would pass for the wrong reason.
  Future<void> settleWithoutAnimations(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 32));
    await tester.pump();
  }

  /// Let a route change finish, by hand.
  ///
  /// [WidgetTester.pumpAndSettle] is no use for this: both the summary and the
  /// wizard fetch or send on arrival, and a progress indicator never settles.
  /// Pumping a fixed run of frames gets past the page transition without ever
  /// asking the tree to go quiet.
  Future<void> settleRouteChange(WidgetTester tester) async {
    for (int i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  Finder answerRow(String name) =>
      find.byKey(ValueKey<String>('profile-answer-$name'));

  Finder editAction(String name) =>
      find.descendant(of: answerRow(name), matching: find.text('Edit'));

  Finder cancelAction(String name) =>
      find.descendant(of: answerRow(name), matching: find.text('Cancel'));

  Finder saveAction(String name) => find.descendant(
        of: answerRow(name),
        matching: find.text('Save this change'),
      );

  Finder boxIn(String name) =>
      find.descendant(of: answerRow(name), matching: find.byType(TextField));

  Future<void> tapAction(WidgetTester tester, Finder action) async {
    await tester.ensureVisible(action);
    await tester.tap(action);
    await tester.pump();
  }

  /// The onboarding wizard, the summary, and somewhere for each of them to
  /// lead, with the same `?return=` handling the real router has.
  GoRouter profileRouter({String initialLocation = profileReviewPath}) {
    return GoRouter(
      initialLocation: initialLocation,
      routes: <RouteBase>[
        GoRoute(
          path: profileWizardPath,
          builder: (BuildContext context, GoRouterState state) =>
              HealthProfileScreen(
            returnToReview: state.uri.queryParameters[profileReturnParam] ==
                profileReturnReview,
          ),
        ),
        GoRoute(
          path: '/today',
          builder: (BuildContext context, GoRouterState state) =>
              const Scaffold(body: Center(child: Text('TODAY-REACHED'))),
        ),
        GoRoute(
          path: '/more',
          builder: (BuildContext context, GoRouterState state) =>
              const Scaffold(body: Center(child: Text(moreMarker))),
          routes: <RouteBase>[
            GoRoute(
              path: 'profile',
              builder: (BuildContext context, GoRouterState state) =>
                  const ProfileSummaryScreen(),
            ),
          ],
        ),
      ],
    );
  }

  Widget profileApp({
    required HealthRepository repository,
    required GoRouter router,
  }) {
    return ProviderScope(
      overrides: <Override>[
        healthRepositoryProvider.overrideWithValue(repository),
      ],
      child: MaterialApp.router(theme: HpTheme.light(), routerConfig: router),
    );
  }

  /// Open the summary with [repository] behind it and wait for the fetch.
  Future<void> openSummary(
    WidgetTester tester,
    HealthRepository repository,
  ) async {
    await tester.pumpWidget(
      profileApp(repository: repository, router: profileRouter()),
    );
    await settleWithoutAnimations(tester);
  }

  // ------------------------------------------------------------------- tests

  testWidgets('coming back from More shows what is saved, not an empty form',
      (WidgetTester tester) async {
    useTallSurface(tester);
    final _EditProfileRepository repository = _EditProfileRepository();
    repository.seed(savedProfile());

    await openSummary(tester, repository);

    // The summary, not the six-step wizard. This is the whole complaint.
    expect(find.byType(ProfileSummaryScreen), findsOneWidget);
    expect(find.byType(HealthProfileScreen), findsNothing);
    expect(find.text('Step 1 of 6'), findsNothing);

    // Every saved answer is on screen, filled in.
    expect(find.text('Bengaluru'), findsOneWidget);
    expect(find.text('560001'), findsOneWidget);
    expect(find.text('170 cm'), findsOneWidget);
    expect(find.text('Jain'), findsOneWidget);
    expect(find.text('Female'), findsOneWidget);
    expect(find.text('Peanuts · Severe'), findsOneWidget);
    expect(find.text('Thyroid'), findsOneWidget);
    expect(find.text('South Indian'), findsOneWidget);
    expect(find.text('Energy'), findsOneWidget);
    expect(find.text('Moderately active'), findsOneWidget);
    expect(find.textContaining('4 Mar 1990'), findsOneWidget);
    expect(find.textContaining('Awake 6:00 am'), findsOneWidget);

    // And the one thing never answered says so, rather than showing a blank
    // that would read as an answer of "nothing".
    expect(
      find.descendant(
        of: answerRow('weight'),
        matching: find.text(profileNotAnswered),
      ),
      findsOneWidget,
    );
    expect(find.text(profileNotAnswered), findsOneWidget);
  });

  testWidgets('changing one answer sends every other answer back unchanged',
      (WidgetTester tester) async {
    useTallSurface(tester);
    final _EditProfileRepository repository = _EditProfileRepository();
    repository.seed(savedProfile());

    await openSummary(tester, repository);

    await tapAction(tester, editAction('city'));
    await tester.enterText(boxIn('city'), 'Chennai');
    await tester.pump();
    await tapAction(tester, saveAction('city'));
    await settleWithoutAnimations(tester);

    expect(repository.saves, 1, reason: 'one change, one save');

    final HealthProfile? saved = repository.stored;
    expect(saved, isNotNull);
    expect(saved!.city, 'Chennai');

    // The save replaces the whole profile, so everything that was not being
    // edited has to come back exactly as it went in. This is the assertion
    // that stops "change my city" from deleting an allergy.
    expect(saved.dob, DateTime(1990, 3, 4));
    expect(saved.sex, Sex.female);
    expect(saved.heightCm, 170);
    expect(saved.weightKg, isNull);
    expect(saved.dietType, DietType.jain);
    expect(saved.activityLevel, ActivityLevel.moderate);
    expect(saved.cuisinePrefs, <String>['South Indian']);
    expect(saved.conditions, <String>['Thyroid']);
    expect(saved.allergies.length, 1);
    expect(saved.allergies.first.allergen, 'Peanuts');
    expect(saved.allergies.first.severity, AllergySeverity.severe);
    expect(saved.goalTypes, <GoalType>[GoalType.energy]);
    expect(saved.wakeTime, '06:00');
    expect(saved.sleepTime, '22:00');
    expect(saved.mealTimes, MealSlot.defaultTimes);
    expect(saved.pincode, '560001');

    // The editor closed on success, and the row now reads the new answer.
    expect(saveAction('city'), findsNothing);
    expect(
      find.descendant(of: answerRow('city'), matching: find.text('Chennai')),
      findsOneWidget,
    );
    expect(find.text('Saved.'), findsOneWidget);
  });

  testWidgets('a refused save stops the spinner, says why, and can be retried',
      (WidgetTester tester) async {
    useTallSurface(tester);
    final _EditProfileRepository repository = _EditProfileRepository();
    repository.seed(savedProfile());

    await openSummary(tester, repository);

    repository.refuseSaves = true;
    await tapAction(tester, editAction('city'));
    await tester.enterText(boxIn('city'), 'Chennai');
    await tester.pump();
    await tapAction(tester, saveAction('city'));
    await settleWithoutAnimations(tester);

    // 1. Nothing is still spinning.
    expect(
      find.descendant(
        of: find.byType(ProfileSummaryScreen),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsNothing,
      reason: 'the busy state outlived the failure',
    );

    // 2. A sentence this app wrote, mapped from the refusal.
    expect(find.text(refusal.message), findsOneWidget);

    // 3. The change was sent, and nothing already saved was touched.
    expect(repository.lastSent!.city, 'Chennai');
    expect(repository.stored!.city, 'Bengaluru');
    expect(repository.stored!.allergies.length, 1);

    // 4. The change is still on screen and still sendable.
    expect(saveAction('city'), findsOneWidget);
    expect(tester.widget<TextField>(boxIn('city')).controller?.text, 'Chennai');
    expect(repository.saves, 1);
    await tapAction(tester, saveAction('city'));
    await settleWithoutAnimations(tester);
    expect(repository.saves, 2, reason: 'a second tap really does try again');
  });

  testWidgets('a second tap while the save is in flight is ignored',
      (WidgetTester tester) async {
    useTallSurface(tester);
    final _EditProfileRepository repository = _EditProfileRepository();
    repository.seed(savedProfile());

    await openSummary(tester, repository);

    // The save is held open on purpose. Awaiting a tap flushes microtasks, so
    // a fake that settles immediately would have finished - and closed the
    // editor - before the second tap ever landed, and this test would be
    // proving something else entirely.
    repository.hangSaves = true;
    await tapAction(tester, editAction('city'));
    await tester.enterText(boxIn('city'), 'Chennai');
    await tester.pump();

    await tester.ensureVisible(saveAction('city'));
    await tester.tap(saveAction('city'));
    expect(repository.saves, 1);

    // No pump in between, so the second tap reaches the handler's own guard
    // rather than being turned away by the button rebuilding itself as busy.
    await tester.tap(saveAction('city'));
    expect(repository.saves, 1, reason: 'the profile was sent twice');

    // Now let a frame through: still here, still busy, still one call.
    await tester.pump();
    expect(
      find.descendant(
        of: find.byType(ProfileSummaryScreen),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );

    repository.releaseSave();
    await settleWithoutAnimations(tester);

    expect(repository.saves, 1);
    expect(repository.stored!.city, 'Chennai');
    expect(saveAction('city'), findsNothing);
  });

  testWidgets('cancelling an edit puts the saved answer back and saves nothing',
      (WidgetTester tester) async {
    useTallSurface(tester);
    final _EditProfileRepository repository = _EditProfileRepository();
    repository.seed(savedProfile());

    await openSummary(tester, repository);

    await tapAction(tester, editAction('city'));
    await tester.enterText(boxIn('city'), 'Chennai');
    await tester.pump();
    await tapAction(tester, cancelAction('city'));

    expect(repository.saves, 0);
    expect(saveAction('city'), findsNothing);
    expect(
      find.descendant(of: answerRow('city'), matching: find.text('Bengaluru')),
      findsOneWidget,
    );

    // Reopening starts from what is saved, not from the abandoned edit.
    await tapAction(tester, editAction('city'));
    expect(
      tester.widget<TextField>(boxIn('city')).controller?.text,
      'Bengaluru',
    );
  });

  testWidgets('leaving goes back to More and loses nothing',
      (WidgetTester tester) async {
    useTallSurface(tester);
    final _EditProfileRepository repository = _EditProfileRepository();
    repository.seed(savedProfile());

    await openSummary(tester, repository);

    expect(find.byTooltip('Back to More'), findsOneWidget);
    await tester.tap(find.byTooltip('Back to More'));
    await settleRouteChange(tester);

    expect(find.text(moreMarker), findsOneWidget);
    expect(find.byType(ProfileSummaryScreen), findsNothing);
    expect(repository.stored!.city, 'Bengaluru');
  });

  testWidgets('the wizard opened from the summary is pre-filled and comes back',
      (WidgetTester tester) async {
    useTallSurface(tester);
    final _EditProfileRepository repository = _EditProfileRepository();
    repository.seed(savedProfile());

    await openSummary(tester, repository);

    await tapAction(
      tester,
      find.text('Go through all the questions again'),
    );
    await settleRouteChange(tester);

    expect(find.byType(HealthProfileScreen), findsOneWidget);
    expect(find.text('Step 1 of 6'), findsOneWidget);
    // Pre-filled from the profile the summary fetched, not blank.
    expect(find.text('170'), findsOneWidget);

    // Step one has a back control here, because there is somewhere behind it.
    expect(find.text('Back'), findsOneWidget);
    await tester.tap(find.text('Back'));
    await settleRouteChange(tester);

    expect(find.byType(ProfileSummaryScreen), findsOneWidget);
    expect(find.text('Bengaluru'), findsOneWidget);
  });

  testWidgets('back through the wizard keeps what was typed',
      (WidgetTester tester) async {
    useTallSurface(tester);
    final _EditProfileRepository repository = _EditProfileRepository();

    await tester.pumpWidget(
      profileApp(
        repository: repository,
        router: profileRouter(initialLocation: profileWizardPath),
      ),
    );
    await settleWithoutAnimations(tester);

    expect(find.text('Step 1 of 6'), findsOneWidget);
    // Nothing behind step one on a genuine first run, so no control that would
    // do nothing is offered.
    expect(find.text('Back'), findsNothing);

    await tester.enterText(find.byKey(profileHeightFieldKey), '172');
    await tester.pump();
    await tapAction(tester, find.text('Continue'));
    expect(find.text('Step 2 of 6'), findsOneWidget);

    await tapAction(tester, find.text('Back'));
    expect(find.text('Step 1 of 6'), findsOneWidget);
    expect(find.text('172'), findsOneWidget);
  });

  testWidgets('with no profile yet it offers the wizard rather than blanks',
      (WidgetTester tester) async {
    useTallSurface(tester);
    final _EditProfileRepository repository = _EditProfileRepository();

    await openSummary(tester, repository);

    expect(find.text('Nothing saved here yet'), findsOneWidget);
    expect(find.text('Set up my health profile'), findsOneWidget);
    expect(find.text(profileNotAnswered), findsNothing);
  });

  testWidgets('a refused fetch says why and can be tried again',
      (WidgetTester tester) async {
    useTallSurface(tester);
    final _EditProfileRepository repository = _EditProfileRepository();
    repository.seed(savedProfile());
    repository.refuseLoads = true;

    await openSummary(tester, repository);

    expect(find.text('We could not fetch your health profile'), findsOneWidget);
    expect(find.text(refusal.message), findsOneWidget);

    repository.refuseLoads = false;
    await tapAction(tester, find.text('Try again'));
    await settleWithoutAnimations(tester);

    expect(find.text('Bengaluru'), findsOneWidget);
  });
}

/// The fake, with the profile calls made to refuse or to hang.
///
/// `_refusing_repository.dart` is shared with the onboarding tests and can only
/// refuse a profile save, never hold one open, so this test file brings its own
/// rather than changing a harness other tests depend on.
class _EditProfileRepository extends FakeHealthRepository {
  _EditProfileRepository() : super(latency: Duration.zero, signedIn: true);

  bool refuseLoads = false;
  bool refuseSaves = false;

  /// Hold `saveHealthProfile` open until [releaseSave] is called, so a second
  /// tap can be made while the first call is genuinely still in flight.
  bool hangSaves = false;

  /// How many times the screen actually sent the profile.
  int saves = 0;

  /// What the fake is holding now, and what the screen last sent.
  ///
  /// Mirrored here rather than read back through [loadHealthProfile] because a
  /// future that completes on a microtask needs a pump to resolve inside
  /// `testWidgets`, and an assertion about what was saved should not quietly
  /// depend on remembering that.
  HealthProfile? stored;
  HealthProfile? lastSent;

  final Completer<void> _gate = Completer<void>();

  void releaseSave() {
    if (!_gate.isCompleted) {
      _gate.complete();
    }
  }

  /// Put a profile on the server without it counting as a save the screen made.
  ///
  /// The fake records the profile synchronously and defers only the value it
  /// hands back, so there is nothing here worth waiting for.
  void seed(HealthProfile profile) {
    stored = profile;
    unawaited(super.saveHealthProfile(profile));
  }

  @override
  Future<HealthProfile?> loadHealthProfile() {
    if (refuseLoads) {
      throw ApiRepositoryException(
        const ApiFailure(ApiFailureKind.wakingUpTimedOut),
      );
    }
    return super.loadHealthProfile();
  }

  @override
  Future<HealthProfile> saveHealthProfile(HealthProfile profile) async {
    saves += 1;
    lastSent = profile;
    if (refuseSaves) {
      throw ApiRepositoryException(
        const ApiFailure(ApiFailureKind.wakingUpTimedOut),
      );
    }
    if (hangSaves) {
      await _gate.future;
    }
    stored = profile;
    return super.saveHealthProfile(profile);
  }
}

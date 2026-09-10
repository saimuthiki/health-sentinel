import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:healthpulse/core/theme/hp_theme.dart';
import 'package:healthpulse/core/widgets/widgets.dart';
import 'package:healthpulse/data/api/api_failure.dart';
import 'package:healthpulse/data/providers.dart';
import 'package:healthpulse/data/repository/fake_health_repository.dart';
import 'package:healthpulse/data/repository/health_repository.dart';
import 'package:healthpulse/data/repository/http_health_repository.dart';
import 'package:healthpulse/features/reminders/reminders_screen.dart';
import 'package:healthpulse/services/alert_schedule.dart';

/// The reminders screen: a switch per kind of reminder, and quiet hours.
///
/// The behaviours worth protecting, and why each one is here:
///
/// * a toggle reaches the backend with the right type and the right state;
/// * a refused toggle leaves the switch showing what the backend actually
///   holds, says why, and leaves no spinner running;
/// * a second tap while the first is in flight sends nothing;
/// * quiet hours save the two times that are on screen;
/// * the escalation type has no switch at all, and says why.
void main() {
  group('turning a reminder on and off', () {
    testWidgets('sends the type and the new state', (WidgetTester tester) async {
      useTallSurface(tester);
      final _RemindersRepository repository = _RemindersRepository();

      await tester.pumpWidget(remindersApp(repository));
      await settleWithoutAnimations(tester);

      await tapSwitchFor(tester, 'Meals');
      await settleWithoutAnimations(tester);

      expect(repository.toggles, <String>['meal=false']);
      expect(switchFor(tester, 'Meals').value, isFalse);
      // The row that was not touched is untouched.
      expect(switchFor(tester, 'Water').value, isTrue);
    });

    testWidgets('a refusal snaps the switch back, says why, and stops spinning',
        (WidgetTester tester) async {
      useTallSurface(tester);
      final _RemindersRepository repository =
          _RemindersRepository(refuseToggle: true);

      await tester.pumpWidget(remindersApp(repository));
      await settleWithoutAnimations(tester);
      expect(switchFor(tester, 'Water').value, isTrue);

      await tapSwitchFor(tester, 'Water');
      await settleWithoutAnimations(tester);

      // The switch never moved: it is drawn from what the backend holds, and
      // the backend refused, so what it holds is what it held.
      expect(switchFor(tester, 'Water').value, isTrue);
      // And the person is told, in our own words rather than the server's.
      expect(
        find.text(
          const ApiFailure(ApiFailureKind.wakingUpTimedOut).message,
        ),
        findsOneWidget,
      );
      // Nothing left running. A spinner that outlives its request is how a row
      // ends up permanently dead.
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('a second tap while the first is in flight sends nothing',
        (WidgetTester tester) async {
      useTallSurface(tester);
      // Held open on a Completer. The fake settles in a microtask, and awaiting
      // a tap flushes microtasks, so without this the "second" tap would land
      // on a call that had already finished.
      final _RemindersRepository repository =
          _RemindersRepository(holdToggle: true);

      await tester.pumpWidget(remindersApp(repository));
      await settleWithoutAnimations(tester);

      await tapSwitchFor(tester, 'Water');
      await tester.pump();
      expect(repository.toggles, <String>['hydration=false']);
      // The wait is visible while it happens.
      expect(find.byType(CircularProgressIndicator), findsWidgets);

      await tapSwitchFor(tester, 'Water');
      await tester.pump();
      expect(
        repository.toggles,
        <String>['hydration=false'],
        reason: 'a second tap posted the same change twice',
      );

      repository.releaseToggle();
      await settleWithoutAnimations(tester);
      expect(switchFor(tester, 'Water').value, isFalse);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });

  group('quiet hours', () {
    testWidgets('saves the two times on screen', (WidgetTester tester) async {
      useTallSurface(tester);
      final _RemindersRepository repository = _RemindersRepository();

      await tester.pumpWidget(remindersApp(repository));
      await settleWithoutAnimations(tester);

      // The picker itself is Flutter's own `showTimePicker`, so the callback it
      // would call is called directly. What is under test is what this screen
      // does with a chosen time, not whether Material's dial works.
      timeRow(tester, 'Quiet from').onChanged(
        const TimeOfDay(hour: 21, minute: 15),
      );
      await tester.pump();
      timeRow(tester, 'Quiet until').onChanged(
        const TimeOfDay(hour: 5, minute: 45),
      );
      await tester.pump();

      // What was chosen is what is shown, before anything is saved.
      expect(find.text('9:15 pm'), findsOneWidget);
      expect(find.text('5:45 am'), findsOneWidget);

      final Finder save = find.widgetWithText(HpButton, 'Save quiet hours');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await settleWithoutAnimations(tester);

      expect(repository.quietHoursSaved, <String>['21:15', '05:45']);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('a refused save says why and leaves the times as chosen',
        (WidgetTester tester) async {
      useTallSurface(tester);
      final _RemindersRepository repository =
          _RemindersRepository(refuseQuietHours: true);

      await tester.pumpWidget(remindersApp(repository));
      await settleWithoutAnimations(tester);

      timeRow(tester, 'Quiet from').onChanged(
        const TimeOfDay(hour: 23, minute: 0),
      );
      await tester.pump();

      final Finder save = find.widgetWithText(HpButton, 'Save quiet hours');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await settleWithoutAnimations(tester);

      expect(
        find.text(
          const ApiFailure(ApiFailureKind.wakingUpTimedOut).message,
        ),
        findsOneWidget,
      );
      // Nothing typed is thrown away by a failure: the choice is still there to
      // press save on again.
      expect(find.text('11:00 pm'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });

  group('the one that cannot be switched off', () {
    testWidgets('has no switch, and says why', (WidgetTester tester) async {
      useTallSurface(tester);

      await tester.pumpWidget(remindersApp(_RemindersRepository()));
      await settleWithoutAnimations(tester);

      expect(find.text('Findings that need a doctor'), findsOneWidget);
      expect(
        find.descendant(
          of: find.widgetWithText(HpCard, 'Findings that need a doctor'),
          matching: find.byType(Switch),
        ),
        findsNothing,
        reason: 'an escalation is not a preference and must not have a switch',
      );
      expect(find.text(escalationCannotBeSilenced), findsOneWidget);
    });

    testWidgets('the repository refuses it even if something else asks',
        (WidgetTester tester) async {
      // The screen never offers this, but the rule lives below the screen too:
      // the backend refuses, and so does the fake the whole app is built
      // against, so nothing can be built on the assumption that it works.
      final FakeHealthRepository repository =
          FakeHealthRepository(latency: Duration.zero, signedIn: true);

      await expectLater(
        repository.setAlertEnabled(
          AlertDefinition.escalationType,
          enabled: false,
        ),
        throwsA(isA<HealthRepositoryException>()),
      );
    });
  });

  testWidgets('a failed fetch offers a way back in', (WidgetTester tester) async {
    useTallSurface(tester);
    final _RemindersRepository repository = _RemindersRepository(refuseLoad: true);

    await tester.pumpWidget(remindersApp(repository));
    await settleWithoutAnimations(tester);

    expect(find.text('We could not fetch your reminders'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    // "Try again" is a real retry, not a redraw of the same refusal.
    repository.refuseLoad = false;
    await tester.tap(find.widgetWithText(HpButton, 'Try again'));
    await settleWithoutAnimations(tester);

    expect(find.text('Meals'), findsOneWidget);
  });
}

// ---------------------------------------------------------------- harness

/// The screen, wired to [repository].
///
/// A plain [MaterialApp] rather than a router: the only route this screen knows
/// about is the way back to More, and that is a tap on a back arrow no test
/// here makes.
Widget remindersApp(FakeHealthRepository repository) {
  return ProviderScope(
    overrides: <Override>[
      healthRepositoryProvider.overrideWithValue(repository),
    ],
    child: MaterialApp(
      theme: HpTheme.light(),
      home: const RemindersScreen(),
    ),
  );
}

/// A surface tall enough that this screen has no fold. A tap below the fold
/// throws rather than scrolling.
void useTallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(600, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Let a queued failure or success land without waiting on any animation.
///
/// [WidgetTester.pumpAndSettle] cannot be used here: a spinner animates for
/// ever, so a screen that is *meant* to be busy would time the test out.
Future<void> settleWithoutAnimations(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 32));
  await tester.pump();
}

/// The switch in the card whose title is [title].
Switch switchFor(WidgetTester tester, String title) {
  return tester.widget<Switch>(
    find.descendant(
      of: find.widgetWithText(HpCard, title),
      matching: find.byType(Switch),
    ),
  );
}

Future<void> tapSwitchFor(WidgetTester tester, String title) async {
  final Finder target = find.descendant(
    of: find.widgetWithText(HpCard, title),
    matching: find.byType(Switch),
  );
  await tester.ensureVisible(target);
  await tester.tap(target);
}

/// The time row labelled [label], so its callback can be called the way the
/// platform picker would call it.
HpTimeRow timeRow(WidgetTester tester, String label) {
  return tester.widget<HpTimeRow>(find.widgetWithText(HpTimeRow, label));
}

/// The fake repository, with the alert writes watched, gated or refused.
class _RemindersRepository extends FakeHealthRepository {
  _RemindersRepository({
    this.refuseToggle = false,
    this.refuseQuietHours = false,
    this.holdToggle = false,
    this.refuseLoad = false,
  }) : super(latency: Duration.zero, signedIn: true);

  final bool refuseToggle;
  final bool refuseQuietHours;

  /// Hold `setAlertEnabled` open until [releaseToggle] is called, so a second
  /// tap can be made while the first change is genuinely still in flight.
  final bool holdToggle;

  /// Not final: a test turns it off to prove "Try again" really tries again.
  bool refuseLoad;

  /// Every toggle that reached the repository, as `type=state`.
  final List<String> toggles = <String>[];

  /// The two times of the last quiet-hours save.
  List<String> quietHoursSaved = const <String>[];

  final Completer<void> _toggleGate = Completer<void>();

  void releaseToggle() {
    if (!_toggleGate.isCompleted) {
      _toggleGate.complete();
    }
  }

  Never _refuse() => throw ApiRepositoryException(
        const ApiFailure(ApiFailureKind.wakingUpTimedOut),
      );

  @override
  Future<AlertPlan> loadAlerts() {
    if (refuseLoad) {
      _refuse();
    }
    return super.loadAlerts();
  }

  @override
  Future<AlertPlan> setAlertEnabled(
    String alertType, {
    required bool enabled,
  }) async {
    toggles.add('$alertType=$enabled');
    if (refuseToggle) {
      _refuse();
    }
    if (holdToggle) {
      await _toggleGate.future;
    }
    return super.setAlertEnabled(alertType, enabled: enabled);
  }

  @override
  Future<AlertPlan> setQuietHours({
    required String start,
    required String end,
  }) {
    quietHoursSaved = <String>[start, end];
    if (refuseQuietHours) {
      _refuse();
    }
    return super.setQuietHours(start: start, end: end);
  }
}

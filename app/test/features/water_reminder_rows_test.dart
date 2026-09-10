import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:healthpulse/core/theme/hp_theme.dart';
import 'package:healthpulse/data/providers.dart';
import 'package:healthpulse/data/repository/fake_health_repository.dart';
import 'package:healthpulse/features/reminders/reminders_screen.dart';
import 'package:healthpulse/services/alert_schedule.dart';

/// What a row of the reminders screen says now that water is a schedule.
///
/// Two changes are under test, and both exist because the backend now derives
/// eight to ten water reminders a day instead of two or three:
///
/// * a long list of times is said as a count and a span, because ten times
///   joined with dots is a wall rather than a fact somebody can read;
/// * the words the reminder will actually use are shown under the row. They
///   are the server's own — built in `backend/app/planner/alerts.py` from the
///   goal in force, which may be one the person chose for themselves — and
///   they are rendered verbatim. That is the only way to see what a reminder
///   says without waiting for one to arrive.
void main() {
  testWidgets('a water schedule is said as a count and a span',
      (WidgetTester tester) async {
    useTallReminderSurface(tester);

    await tester.pumpWidget(
      remindersAppWith(_FixedAlertsRepository(_everyNinetyMinutes)),
    );
    await settleWithoutSpinners(tester);

    expect(find.text('10 times a day, 7:00 am to 8:30 pm'), findsOneWidget);
    // And not as the wall it replaces.
    expect(find.textContaining('7:00 am · 8:30 am'), findsNothing);
  });

  testWidgets('a kind with only a few times still lists them',
      (WidgetTester tester) async {
    useTallReminderSurface(tester);

    await tester.pumpWidget(
      remindersAppWith(_FixedAlertsRepository(_everyNinetyMinutes)),
    );
    await settleWithoutSpinners(tester);

    expect(find.text('8:20 am · 9:30 pm'), findsOneWidget);
  });

  testWidgets('the row says what the reminder will actually say',
      (WidgetTester tester) async {
    useTallReminderSurface(tester);

    await tester.pumpWidget(
      remindersAppWith(_FixedAlertsRepository(_everyNinetyMinutes)),
    );
    await settleWithoutSpinners(tester);

    // Verbatim, including the goal this person set for themselves. Nothing on
    // the screen composes this sentence; it arrived written.
    expect(find.text(_waterBody), findsOneWidget);
  });

  testWidgets('the one that cannot be switched off still says so as well',
      (WidgetTester tester) async {
    useTallReminderSurface(tester);

    await tester.pumpWidget(
      remindersAppWith(_FixedAlertsRepository(_everyNinetyMinutes)),
    );
    await settleWithoutSpinners(tester);

    // The body line is an addition to that sentence, not a replacement for it.
    expect(find.text(escalationCannotBeSilenced), findsOneWidget);
    expect(find.text('Your potassium reading is one to speak to a doctor '
        'about today.'), findsOneWidget);
  });
}

// ---------------------------------------------------------------- harness

/// The screen, wired to [repository]. A plain [MaterialApp] rather than a
/// router: no test here taps the way back to More.
Widget remindersAppWith(FakeHealthRepository repository) {
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

/// A surface tall enough that this screen has no fold: a tap or an expectation
/// below the fold would otherwise need scrolling.
void useTallReminderSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(600, 3200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Let the queued fetch land without waiting on an animation.
///
/// [WidgetTester.pumpAndSettle] cannot be used on this screen: a spinner
/// animates for ever, so a screen that is meant to be busy would time the test
/// out instead of failing it.
Future<void> settleWithoutSpinners(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 32));
  await tester.pump();
}

const String _waterBody =
    'Time for a glass of water -- about 20 across the day, toward the 5000 ml '
    'you set yourself.';

/// A day of reminders shaped the way the backend now derives them for somebody
/// who set themselves a large water goal: ten of them, ninety minutes apart,
/// the last one well before bed.
final AlertPlan _everyNinetyMinutes = AlertPlan(
  alerts: <AlertDefinition>[
    for (final String at in <String>[
      '07:00',
      '08:30',
      '10:00',
      '11:30',
      '13:00',
      '14:30',
      '16:00',
      '17:30',
      '19:00',
      '20:30',
    ])
      AlertDefinition(
        alertType: 'hydration',
        title: 'Water',
        body: _waterBody,
        at: at,
      ),
    const AlertDefinition(
      alertType: 'meal',
      title: 'Breakfast time',
      body: 'Today’s breakfast is ready in your plan.',
      at: '08:20',
    ),
    const AlertDefinition(
      alertType: 'meal',
      title: 'Dinner time',
      body: 'Today’s dinner is ready in your plan.',
      at: '21:30',
    ),
    const AlertDefinition(
      alertType: AlertDefinition.escalationType,
      title: 'A result your doctor should see',
      body: 'Your potassium reading is one to speak to a doctor about today.',
      at: '09:00',
    ),
  ],
);

/// The fake repository, answering with one fixed plan.
class _FixedAlertsRepository extends FakeHealthRepository {
  _FixedAlertsRepository(this.plan)
      : super(latency: Duration.zero, signedIn: true);

  final AlertPlan plan;

  @override
  Future<AlertPlan> loadAlerts() async => plan;
}

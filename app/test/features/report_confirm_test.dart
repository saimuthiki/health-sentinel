import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:healthpulse/core/theme/hp_theme.dart';
import 'package:healthpulse/data/api/api_failure.dart';
import 'package:healthpulse/data/providers.dart';
import 'package:healthpulse/data/repository/fake_health_repository.dart';
import 'package:healthpulse/data/repository/http_health_repository.dart';
import 'package:healthpulse/features/reports/report_detail_screen.dart';

// Confirming a value the report reader was not sure about.
//
// Report extraction is a model reading a photograph of a piece of paper, and it
// gets test names wrong. This is the only path by which the person holding the
// paper can put one right, so the things that matter are: the right row is
// named, the same confirmation is never posted twice, and a refusal says so and
// can be tried again. What is deliberately *not* here is a text field: the
// endpoint takes a yes and nothing else, so a box to type a value into would be
// a box whose contents are thrown away.

/// The fake repository, remembering exactly which row was confirmed.
///
/// It can also be made to refuse, or to hold the call open. Holding it open is
/// the only way to test the in-flight guard: the fake settles in a microtask,
/// and microtasks flush between two awaited taps, so a second tap would
/// otherwise land on a call that had already finished.
class ConfirmingRepository extends FakeHealthRepository {
  ConfirmingRepository({this.refuse = false, this.hang = false})
      : super(latency: Duration.zero, signedIn: true);

  /// Refuse the way the real repository refuses: our own sentence, and an
  /// [ApiFailure] the screen can branch on.
  final bool refuse;

  /// Hold `confirmResult` open until [release] is called.
  final bool hang;

  /// What was posted, as `reportId/resultId`, in order.
  final List<String> posted = <String>[];

  static const ApiFailure failure = ApiFailure(ApiFailureKind.wakingUpTimedOut);

  final Completer<void> _gate = Completer<void>();

  void release() {
    if (!_gate.isCompleted) {
      _gate.complete();
    }
  }

  @override
  Future<void> confirmResult({
    required String reportId,
    required String resultId,
  }) async {
    posted.add('$reportId/$resultId');
    if (refuse) {
      throw ApiRepositoryException(failure);
    }
    if (hang) {
      await _gate.future;
    }
    return super.confirmResult(reportId: reportId, resultId: resultId);
  }
}

/// The report screen on its own, wired to [repository].
///
/// No router: nothing on this screen reaches for one while it is being built,
/// and the back button is never tapped here.
Widget reportApp(FakeHealthRepository repository) {
  return ProviderScope(
    overrides: <Override>[
      healthRepositoryProvider.overrideWithValue(repository),
    ],
    child: MaterialApp(
      theme: HpTheme.light(),
      home: const ReportDetailScreen(reportId: 'r1'),
    ),
  );
}

/// A surface tall enough that four value cards have no fold.
void useTallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(600, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Let a queued failure or success land without waiting on any animation.
///
/// [WidgetTester.pumpAndSettle] cannot be used anywhere on this screen: both
/// the loading state and the busy button carry a spinner, and a spinner
/// animates for ever.
Future<void> settleWithoutAnimations(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 32));
  await tester.pump();
}

void main() {
  const String openLabel = 'Check this against your report';
  const String closeLabel = 'Not now';
  const String confirmLabel = 'Yes, that matches my report';

  /// The sample report's one flagged row, as the fake stores it.
  const String flaggedRow = 'r1/row-l4';

  bool isBusy() => find
      .descendant(
        of: find.byType(ReportDetailScreen),
        matching: find.byType(CircularProgressIndicator),
      )
      .evaluate()
      .isNotEmpty;

  /// Open the report, then open the panel over the flagged value.
  Future<void> openThePanel(
    WidgetTester tester,
    FakeHealthRepository repository,
  ) async {
    await tester.pumpWidget(reportApp(repository));
    await settleWithoutAnimations(tester);

    await tester.ensureVisible(find.text(openLabel));
    await tester.pump();
    await tester.tap(find.text(openLabel));
    await settleWithoutAnimations(tester);

    await tester.ensureVisible(find.text(confirmLabel));
    await tester.pump();
  }

  testWidgets('the confirmation names the report and the row', (
    WidgetTester tester,
  ) async {
    useTallSurface(tester);
    final ConfirmingRepository repository = ConfirmingRepository();

    await openThePanel(tester, repository);
    await tester.tap(find.text(confirmLabel));
    await settleWithoutAnimations(tester);

    // The row's own id, not the biomarker code, and the report it belongs to.
    expect(repository.posted, <String>[flaggedRow]);

    // And the screen has caught up with what the backend now holds: the value
    // is no longer asking to be checked, so the whole panel has gone.
    expect(find.text(confirmLabel), findsNothing);
    expect(find.text(closeLabel), findsNothing);
    expect(find.text(openLabel), findsNothing);
    expect(isBusy(), isFalse);
  });

  testWidgets('the button promises only what the endpoint can do', (
    WidgetTester tester,
  ) async {
    useTallSurface(tester);

    await tester.pumpWidget(reportApp(ConfirmingRepository()));
    await settleWithoutAnimations(tester);

    // There is no endpoint that accepts a typed-in value, so nothing offers to
    // take one. This is the label that used to be here, over a dead button.
    expect(find.text('Type what your report says'), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(find.text(openLabel), findsOneWidget);
  });

  testWidgets('a second tap while the first is in flight does not post twice', (
    WidgetTester tester,
  ) async {
    useTallSurface(tester);
    final ConfirmingRepository repository = ConfirmingRepository(hang: true);

    await openThePanel(tester, repository);
    await tester.tap(find.text(confirmLabel));

    // Genuinely mid-flight: one call started, nothing has come back.
    expect(repository.posted.length, 1);

    // The second tap with no pump in between, so it reaches the handler's own
    // guard rather than being turned away by the button's busy state - a frame
    // would rebuild the button as busy and stop the tap a layer too early.
    await tester.tap(find.text(confirmLabel));
    expect(repository.posted.length, 1,
        reason: 'the second tap confirmed the same row twice');

    await tester.pump();
    expect(isBusy(), isTrue);

    // The held call still finishes properly once it is let go.
    repository.release();
    await settleWithoutAnimations(tester);

    expect(repository.posted, <String>[flaggedRow]);
    expect(isBusy(), isFalse);
  });

  testWidgets('a refusal leaves no spinner and can be tried again', (
    WidgetTester tester,
  ) async {
    useTallSurface(tester);
    final ConfirmingRepository repository = ConfirmingRepository(refuse: true);

    await openThePanel(tester, repository);
    await tester.tap(find.text(confirmLabel));
    await settleWithoutAnimations(tester);

    // 1. The spinner stopped.
    expect(isBusy(), isFalse, reason: 'the busy state outlived the failure');

    // 2. A sentence a person can read, and one this app wrote.
    expect(find.text(ConfirmingRepository.failure.message), findsOneWidget);

    // 3. Nothing moved. The row is still flagged and still asking, because the
    //    backend never said otherwise.
    expect(find.text(closeLabel), findsOneWidget);
    expect(find.text(confirmLabel), findsOneWidget);

    // 4. The button works again: a second tap really does try again.
    await tester.ensureVisible(find.text(confirmLabel));
    await tester.pump();
    await tester.tap(find.text(confirmLabel));
    await settleWithoutAnimations(tester);
    expect(repository.posted.length, 2);
  });
}

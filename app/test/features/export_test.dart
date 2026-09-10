import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:healthpulse/core/theme/hp_theme.dart';
import 'package:healthpulse/core/widgets/widgets.dart';
import 'package:healthpulse/data/api/api_failure.dart';
import 'package:healthpulse/data/providers.dart';
import 'package:healthpulse/data/repository/fake_health_repository.dart';
import 'package:healthpulse/data/repository/http_health_repository.dart';
import 'package:healthpulse/features/export/export_saver.dart';
import 'package:healthpulse/features/export/export_screen.dart';

/// "Export everything": fetch the whole record, then hand it to the phone's own
/// save box so the owner chooses where it lands.
///
/// What is protected here:
///
/// * the wait is on screen while it happens — this call reads every table and
///   the free host may be asleep, so a silent minute is not acceptable;
/// * what reaches the saver is the record, under a name a person can find;
/// * a refusal says why, in our words, and the button still works afterwards;
/// * closing the save box is not a failure, and says so;
/// * a second tap while the first is in flight fetches nothing twice.
void main() {
  testWidgets('the wait is on screen while the record is being gathered',
      (WidgetTester tester) async {
    useTallSurface(tester);
    // Held open on a Completer: the fake settles in a microtask, so without
    // this the export would be finished before anything could be asserted.
    final _ExportRepository repository = _ExportRepository(holdExport: true);
    final _RecordingSaver saver = _RecordingSaver();

    await tester.pumpWidget(exportApp(repository, saver));
    await settleWithoutAnimations(tester);

    await tapExport(tester, 'Export everything');
    await tester.pump();

    expect(repository.exportCalls, 1);
    expect(find.text('Gathering your record'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    // Nothing has been handed to the save box yet.
    expect(saver.calls, 0);

    repository.releaseExport();
    await settleWithoutAnimations(tester);

    expect(find.text('Gathering your record'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('hands the record to the save box and says where it went',
      (WidgetTester tester) async {
    useTallSurface(tester);
    final _RecordingSaver saver = _RecordingSaver(savedAs: 'my-record.json');

    await tester.pumpWidget(exportApp(_ExportRepository(), saver));
    await settleWithoutAnimations(tester);

    await tapExport(tester, 'Export everything');
    await settleWithoutAnimations(tester);

    expect(saver.calls, 1);
    // A name with the date in it, so a second copy is telling about itself.
    expect(saver.fileName, matches(r'^healthpulse-export-\d{4}-\d{2}-\d{2}\.json$'));

    // What went into the file is the document the backend answered with, not
    // something composed on the phone.
    final Object? written = jsonDecode(utf8.decode(saver.bytes!));
    expect(written, isA<Map<String, dynamic>>());
    expect((written! as Map<String, dynamic>)['tables'], isNotNull);

    // And the person is told the name it was actually saved under, which is the
    // one thing about the destination we genuinely know.
    expect(find.text('Saved'), findsOneWidget);
    expect(find.text('my-record.json'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('a refusal says why and leaves the button working',
      (WidgetTester tester) async {
    useTallSurface(tester);
    final _ExportRepository repository = _ExportRepository(refuseExport: true);
    final _RecordingSaver saver = _RecordingSaver();

    await tester.pumpWidget(exportApp(repository, saver));
    await settleWithoutAnimations(tester);

    await tapExport(tester, 'Export everything');
    await settleWithoutAnimations(tester);

    expect(
      find.text(const ApiFailure(ApiFailureKind.wakingUpTimedOut).message),
      findsOneWidget,
    );
    // Nothing was written anywhere, and nothing is still spinning.
    expect(saver.calls, 0);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);

    // Retryable means retryable: the same button, pressed again, tries again.
    repository.refuseExport = false;
    await tapExport(tester, 'Export everything');
    await settleWithoutAnimations(tester);

    expect(repository.exportCalls, 2);
    expect(saver.calls, 1);
    expect(find.text('Saved'), findsOneWidget);
  });

  testWidgets('closing the save box saves nothing, and says so',
      (WidgetTester tester) async {
    useTallSurface(tester);
    final _RecordingSaver saver = _RecordingSaver(cancel: true);

    await tester.pumpWidget(exportApp(_ExportRepository(), saver));
    await settleWithoutAnimations(tester);

    await tapExport(tester, 'Export everything');
    await settleWithoutAnimations(tester);

    expect(saver.calls, 1);
    expect(find.textContaining('Nothing was saved'), findsOneWidget);
    expect(find.text('Saved'), findsNothing);
  });

  testWidgets('a save that fails says so in words a person can act on',
      (WidgetTester tester) async {
    useTallSurface(tester);
    final _RecordingSaver saver = _RecordingSaver(
      refusal: 'That file could not be saved. Try again and pick a folder you '
          'can write to, such as Downloads.',
    );

    await tester.pumpWidget(exportApp(_ExportRepository(), saver));
    await settleWithoutAnimations(tester);

    await tapExport(tester, 'Export everything');
    await settleWithoutAnimations(tester);

    expect(find.textContaining('could not be saved'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('a second tap while the first is in flight fetches nothing twice',
      (WidgetTester tester) async {
    useTallSurface(tester);
    final _ExportRepository repository = _ExportRepository(holdExport: true);
    final _RecordingSaver saver = _RecordingSaver();

    await tester.pumpWidget(exportApp(repository, saver));
    await settleWithoutAnimations(tester);

    await tapExport(tester, 'Export everything');
    await tester.pump();
    await tapExport(tester, 'Export everything');
    await tester.pump();

    expect(
      repository.exportCalls,
      1,
      reason: 'a second tap fetched the whole health record a second time',
    );

    repository.releaseExport();
    await settleWithoutAnimations(tester);
    expect(saver.calls, 1);
  });
}

// ---------------------------------------------------------------- harness

/// The screen, wired to [repository] and to a saver that writes nothing.
Widget exportApp(FakeHealthRepository repository, ExportSaver saver) {
  return ProviderScope(
    overrides: <Override>[
      healthRepositoryProvider.overrideWithValue(repository),
      exportSaverProvider.overrideWithValue(saver),
    ],
    child: MaterialApp(
      theme: HpTheme.light(),
      home: const ExportScreen(),
    ),
  );
}

/// A surface tall enough that this screen has no fold.
void useTallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(600, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Let a queued failure or success land without waiting on any animation.
///
/// This screen shows two indeterminate indicators while it works, and both
/// animate for ever, so [WidgetTester.pumpAndSettle] would time the test out.
Future<void> settleWithoutAnimations(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 32));
  await tester.pump();
}

Future<void> tapExport(WidgetTester tester, String label) async {
  final Finder button = find.widgetWithText(HpButton, label);
  await tester.ensureVisible(button);
  await tester.tap(button);
}

/// The fake repository, with the export watched, gated or refused.
class _ExportRepository extends FakeHealthRepository {
  _ExportRepository({
    this.holdExport = false,
    this.refuseExport = false,
  }) : super(latency: Duration.zero, signedIn: true);

  /// Hold `exportEverything` open until [releaseExport] is called.
  final bool holdExport;

  /// Not final: a test turns it off to prove the button still works after a
  /// refusal.
  bool refuseExport;

  int exportCalls = 0;

  final Completer<void> _exportGate = Completer<void>();

  void releaseExport() {
    if (!_exportGate.isCompleted) {
      _exportGate.complete();
    }
  }

  @override
  Future<Map<String, dynamic>> exportEverything() async {
    exportCalls += 1;
    if (refuseExport) {
      throw ApiRepositoryException(
        const ApiFailure(ApiFailureKind.wakingUpTimedOut),
      );
    }
    if (holdExport) {
      await _exportGate.future;
    }
    return super.exportEverything();
  }
}

/// A saver that records what it was handed instead of opening anything.
///
/// The real one puts Android's own save box in front of the person, which no
/// widget test has. Everything either side of that — what is fetched, what is
/// encoded, what is said afterwards — is ordinary Dart and is what these tests
/// are about.
class _RecordingSaver implements ExportSaver {
  _RecordingSaver({
    this.savedAs = 'healthpulse-export.json',
    this.cancel = false,
    this.refusal,
  });

  /// The name the save box reports back, which need not be the one asked for:
  /// Android renames a duplicate rather than overwriting it.
  final String savedAs;

  /// True to answer the way a closed save box does.
  final bool cancel;

  /// Set to refuse the way a folder that cannot be written to does.
  final String? refusal;

  int calls = 0;
  String? fileName;
  Uint8List? bytes;

  @override
  Future<SavedExport?> save({
    required String fileName,
    required Uint8List bytes,
  }) async {
    calls += 1;
    this.fileName = fileName;
    this.bytes = bytes;
    final String? refusal = this.refusal;
    if (refusal != null) {
      throw ExportSaverException(refusal);
    }
    if (cancel) {
      return null;
    }
    return SavedExport(fileName: savedAs);
  }
}

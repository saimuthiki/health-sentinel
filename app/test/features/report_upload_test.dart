import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:healthpulse/core/theme/hp_theme.dart';
import 'package:healthpulse/data/models/models.dart';
import 'package:healthpulse/data/providers.dart';
import 'package:healthpulse/data/repository/fake_health_repository.dart';
import 'package:healthpulse/data/repository/health_repository.dart';
import 'package:healthpulse/features/reports/report_upload.dart';
import 'package:healthpulse/features/reports/reports_screen.dart';

// Uploading a report: the one path the whole product hangs off.
//
// All three buttons in the "Add a report" sheet end in a camera, a gallery or a
// file browser, and none of those exist inside a widget test - they are the
// phone answering a method channel, and there is no phone here. So these tests
// do not try. Choosing a file sits behind ReportPicker, and each test swaps in
// a stub that hands back a file, or hands back nothing, or refuses.
//
// What is checked is everything around the picker, which is where all the ways
// this can go wrong actually live: a cancel that has to stay completely silent,
// a file that has to be turned down before it is sent rather than after, a busy
// state that has to clear on every path, and a full progress bar that must not
// be allowed to pretend the report has been read.

/// What the fake report detail screen prints, so a test can tell "navigated to
/// the new report" apart from "still sitting on the list".
const String detailMarker = 'REPORT-DETAIL';

/// A file whose first bytes really are a PDF, at whatever length is asked for.
Uint8List pdfBytes({int length = 2048}) {
  final Uint8List bytes = Uint8List(length);
  bytes.setRange(0, 8, const <int>[
    0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x37, // "%PDF-1.7"
  ]);
  return bytes;
}

/// A file whose first bytes really are a JPEG.
Uint8List jpegBytes({int length = 2048}) {
  final Uint8List bytes = Uint8List(length);
  bytes.setRange(0, 4, const <int>[0xFF, 0xD8, 0xFF, 0xE0]);
  return bytes;
}

/// A picker that does not touch the phone.
///
/// Returning null is a cancel, which is what happens most of the time in real
/// life and is the one outcome that has to produce nothing at all.
class StubPicker implements ReportPicker {
  StubPicker({this.result, this.refusal});

  final PickedReport? result;

  /// Set to make the picker fail the way a refused camera permission fails.
  final ReportPickerException? refusal;

  /// How many times the picker was actually opened, so a retry can be shown not
  /// to send somebody back to find their report a second time.
  int calls = 0;

  final List<ReportSource> sources = <ReportSource>[];

  @override
  Future<PickedReport?> pick(ReportSource source) async {
    calls += 1;
    sources.add(source);
    final ReportPickerException? failure = refusal;
    if (failure != null) {
      throw failure;
    }
    return result;
  }
}

/// The fake repository, remembering exactly what it was asked to upload.
///
/// It drives [onProgress] the way the real one does - none, half, all - so the
/// screen's two-stage wait can be exercised, and it can be held open after the
/// last byte so a test can look at the screen during the part where the bytes
/// have gone but the backend has not answered yet.
class RecordingRepository extends FakeHealthRepository {
  RecordingRepository({
    this.failuresBeforeSuccess = 0,
    this.holdAfterLastByte = false,
  }) : super(latency: Duration.zero, signedIn: true);

  /// How many uploads refuse before one is allowed through.
  final int failuresBeforeSuccess;

  final bool holdAfterLastByte;

  int uploads = 0;
  final List<String> fileNames = <String>[];
  final List<String> mimeTypes = <String>[];

  final Completer<void> _held = Completer<void>();

  /// Let a held upload finish.
  void finish() {
    if (!_held.isCompleted) {
      _held.complete();
    }
  }

  @override
  Future<HealthReport> uploadReport({
    required String fileName,
    required String mimeType,
    required Uint8List bytes,
    void Function(int sent, int total)? onProgress,
  }) async {
    uploads += 1;
    fileNames.add(fileName);
    mimeTypes.add(mimeType);

    onProgress?.call(0, bytes.length);
    onProgress?.call(bytes.length ~/ 2, bytes.length);
    onProgress?.call(bytes.length, bytes.length);

    if (holdAfterLastByte) {
      await _held.future;
    }
    if (uploads <= failuresBeforeSuccess) {
      throw const HealthRepositoryException(
        'The upload stopped part way. Nothing was saved.',
      );
    }
    return HealthReport(
      id: 'r-new',
      fileName: fileName,
      status: ReportStatus.extracted,
    );
  }
}

/// The reports tab and a stand-in for the report it navigates to.
GoRouter reportsRouter() {
  return GoRouter(
    initialLocation: '/reports',
    routes: <RouteBase>[
      GoRoute(
        path: '/reports',
        builder: (BuildContext context, GoRouterState state) =>
            const ReportsScreen(),
        routes: <RouteBase>[
          GoRoute(
            path: ':reportId',
            builder: (BuildContext context, GoRouterState state) => Scaffold(
              body: Center(
                child: Text('$detailMarker ${state.pathParameters['reportId']}'),
              ),
            ),
          ),
        ],
      ),
    ],
  );
}

Widget reportsApp({
  required HealthRepository repository,
  required ReportPicker picker,
}) {
  return ProviderScope(
    overrides: <Override>[
      healthRepositoryProvider.overrideWithValue(repository),
      reportPickerProvider.overrideWithValue(picker),
    ],
    child: MaterialApp.router(
      theme: HpTheme.light(),
      routerConfig: reportsRouter(),
    ),
  );
}

/// A phone-shaped surface with room for a sheet and a notice at once.
void useSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(600, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Let queued work land without waiting on any animation.
///
/// [WidgetTester.pumpAndSettle] cannot be used anywhere on this screen: a
/// progress bar with no end in sight animates for ever, so a screen that is
/// *meant* to be busy would time the test out, and one that is meant not to be
/// would pass for the wrong reason. Four hundred milliseconds is past the end of
/// the bottom sheet's entrance and exit.
Future<void> settleWithoutAnimations(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

/// Open the sheet and tap one of the three ways in.
Future<void> chooseFromSheet(WidgetTester tester, String option) async {
  await tester.tap(find.byTooltip('Upload a report'));
  await settleWithoutAnimations(tester);
  await tester.tap(find.text(option));
  await settleWithoutAnimations(tester);
}

/// None of the three things the screen says when something has gone wrong.
void expectNothingWentWrong() {
  expect(find.text('That file cannot be used'), findsNothing);
  expect(find.text('That could not be opened'), findsNothing);
  expect(find.text('Your report was not sent'), findsNothing);
  expect(find.byType(SnackBar), findsNothing);
}

void main() {
  testWidgets('backing out of the picker uploads nothing and says nothing',
      (WidgetTester tester) async {
    useSurface(tester);
    // The picker returns null, which is what a cancel looks like from every one
    // of the three plugins. It is far and away the commonest outcome here.
    final StubPicker picker = StubPicker();
    final RecordingRepository repository = RecordingRepository();

    await tester.pumpWidget(
      reportsApp(repository: repository, picker: picker),
    );
    await settleWithoutAnimations(tester);
    await chooseFromSheet(tester, 'Choose a PDF');

    expect(picker.calls, 1, reason: 'the picker should have been opened once');
    expect(picker.sources.single, ReportSource.pdf);
    expect(repository.uploads, 0, reason: 'a cancel must send nothing');
    expectNothingWentWrong();
    expect(
      find.byType(LinearProgressIndicator),
      findsNothing,
      reason: 'a cancel must not leave the screen looking busy',
    );
    expect(find.text('Try again'), findsNothing);
  });

  testWidgets('a chosen file is uploaded once, with its name and type',
      (WidgetTester tester) async {
    useSurface(tester);
    final StubPicker picker = StubPicker(
      result: PickedReport(
        fileName: 'august-panel.pdf',
        bytes: pdfBytes(),
      ),
    );
    final RecordingRepository repository = RecordingRepository();

    await tester.pumpWidget(
      reportsApp(repository: repository, picker: picker),
    );
    await settleWithoutAnimations(tester);
    await chooseFromSheet(tester, 'Choose a PDF');

    expect(repository.uploads, 1, reason: 'one tap, one upload');
    expect(repository.fileNames.single, 'august-panel.pdf');
    expect(repository.mimeTypes.single, 'application/pdf');
    expectNothingWentWrong();
    // And the loop is closed: the new report is what you are looking at.
    expect(find.text('$detailMarker r-new'), findsOneWidget);
  });

  testWidgets('the type comes from the file, not from the button that was tapped',
      (WidgetTester tester) async {
    useSurface(tester);
    // A photo somebody saved with a .pdf name, chosen through "Choose a PDF".
    // Believing either the name or the button would send the wrong content
    // type, and the backend refuses a file that is not what it was sent as.
    final StubPicker picker = StubPicker(
      result: PickedReport(fileName: 'scan.pdf', bytes: jpegBytes()),
    );
    final RecordingRepository repository = RecordingRepository();

    await tester.pumpWidget(
      reportsApp(repository: repository, picker: picker),
    );
    await settleWithoutAnimations(tester);
    await chooseFromSheet(tester, 'Choose a PDF');

    expect(repository.mimeTypes.single, 'image/jpeg');
  });

  testWidgets('a file over the limit is refused before anything is sent',
      (WidgetTester tester) async {
    useSurface(tester);
    final StubPicker picker = StubPicker(
      result: PickedReport(
        fileName: 'whole-folder.pdf',
        bytes: pdfBytes(length: 25000000),
      ),
    );
    final RecordingRepository repository = RecordingRepository();

    await tester.pumpWidget(
      reportsApp(repository: repository, picker: picker),
    );
    await settleWithoutAnimations(tester);
    await chooseFromSheet(tester, 'Choose a PDF');

    expect(
      repository.uploads,
      0,
      reason: 'the file must be turned down before it is uploaded, not after',
    );
    expect(find.text('That file cannot be used'), findsOneWidget);
    expect(find.textContaining('That file is 25.0 MB'), findsOneWidget);
    expect(
      find.text('Try again'),
      findsNothing,
      reason: 'a file that is too big will still be too big',
    );
  });

  testWidgets('a file of a type the backend will not open is refused too',
      (WidgetTester tester) async {
    useSurface(tester);
    final StubPicker picker = StubPicker(
      result: PickedReport(
        fileName: 'notes.docx',
        // Long enough to be sniffed, and not the start of anything we take.
        bytes: Uint8List(2048),
      ),
    );
    final RecordingRepository repository = RecordingRepository();

    await tester.pumpWidget(
      reportsApp(repository: repository, picker: picker),
    );
    await settleWithoutAnimations(tester);
    await chooseFromSheet(tester, 'Choose a PDF');

    expect(repository.uploads, 0);
    expect(find.textContaining('PDF, or a JPEG, PNG or HEIC'), findsOneWidget);
  });

  testWidgets('a refused camera says what happened and what fixes it',
      (WidgetTester tester) async {
    useSurface(tester);
    final StubPicker picker = StubPicker(
      refusal: const ReportPickerException(
        'HealthPulse does not have permission to use the camera.',
      ),
    );
    final RecordingRepository repository = RecordingRepository();

    await tester.pumpWidget(
      reportsApp(repository: repository, picker: picker),
    );
    await settleWithoutAnimations(tester);
    await chooseFromSheet(tester, 'Take a photo');

    expect(picker.sources.single, ReportSource.camera);
    expect(repository.uploads, 0);
    expect(find.text('That could not be opened'), findsOneWidget);
    expect(
      find.textContaining('permission to use the camera'),
      findsOneWidget,
      reason: 'the sentence written for the person is the one shown',
    );
    expect(
      find.byType(LinearProgressIndicator),
      findsNothing,
      reason: 'a refused permission must not leave the screen busy',
    );
  });

  testWidgets('a failed upload clears the busy state and can be retried',
      (WidgetTester tester) async {
    useSurface(tester);
    final StubPicker picker = StubPicker(
      result: PickedReport(fileName: 'august-panel.pdf', bytes: pdfBytes()),
    );
    final RecordingRepository repository =
        RecordingRepository(failuresBeforeSuccess: 1);

    await tester.pumpWidget(
      reportsApp(repository: repository, picker: picker),
    );
    await settleWithoutAnimations(tester);
    await chooseFromSheet(tester, 'Choose a PDF');

    expect(repository.uploads, 1);
    expect(
      find.byType(LinearProgressIndicator),
      findsNothing,
      reason: 'the busy state was not cleared when the upload threw',
    );
    expect(find.text('Your report was not sent'), findsOneWidget);
    expect(
      find.textContaining('The upload stopped part way'),
      findsOneWidget,
      reason: 'the repository sentence should be the one on screen',
    );
    // The upload button works again, so nobody is locked out of the one thing
    // this screen is for.
    final IconButton upload = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.upload_file_outlined),
    );
    expect(upload.onPressed, isNotNull);

    // And the same file goes again without being chosen a second time.
    await tester.tap(find.text('Try again'));
    await settleWithoutAnimations(tester);

    expect(repository.uploads, 2);
    expect(picker.calls, 1, reason: 'a retry must not reopen the picker');
    expect(find.text('$detailMarker r-new'), findsOneWidget);
  });

  testWidgets('a full bar says the report is being read, not that it is done',
      (WidgetTester tester) async {
    useSurface(tester);
    final StubPicker picker = StubPicker(
      result: PickedReport(fileName: 'august-panel.pdf', bytes: pdfBytes()),
    );
    final RecordingRepository repository =
        RecordingRepository(holdAfterLastByte: true);

    await tester.pumpWidget(
      reportsApp(repository: repository, picker: picker),
    );
    await settleWithoutAnimations(tester);
    await chooseFromSheet(tester, 'Choose a PDF');

    // Every byte has left the phone. Nothing has been read yet.
    expect(find.text('Your report is being read'), findsOneWidget);
    expect(find.text('Sending your report'), findsNothing);
    expect(
      find.textContaining('Done'),
      findsNothing,
      reason: 'the bytes arriving is not the report being read',
    );
    final LinearProgressIndicator bar =
        tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(
      bar.value,
      isNull,
      reason: 'the wait is now on the backend, so there is nothing left to count',
    );

    repository.finish();
    await settleWithoutAnimations(tester);
    expect(find.text('$detailMarker r-new'), findsOneWidget);
  });

  group('what the bytes say the file is', () {
    test('recognises the four types the backend accepts', () {
      expect(sniffReportMimeType(pdfBytes()), 'application/pdf');
      expect(sniffReportMimeType(jpegBytes()), 'image/jpeg');

      final Uint8List png = Uint8List(64);
      png.setRange(0, 8, const <int>[
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
      ]);
      expect(sniffReportMimeType(png), 'image/png');

      final Uint8List heic = Uint8List(64);
      heic.setRange(4, 12, 'ftypheic'.codeUnits);
      expect(sniffReportMimeType(heic), 'image/heic');
    });

    test('says nothing rather than guessing', () {
      expect(sniffReportMimeType(Uint8List(64)), isNull);
      // Too short to be anything, including too short to read a header from.
      expect(sniffReportMimeType(pdfBytes(length: 8)), isNull);
    });

    test('refuses an empty file, a huge one and an unknown one', () {
      expect(describeUploadRefusal(Uint8List(0)), 'That file was empty.');
      expect(
        describeUploadRefusal(pdfBytes(length: maxReportBytes + 1)),
        contains('The limit is'),
      );
      expect(describeUploadRefusal(Uint8List(64)), unreadableFileMessage);
      expect(describeUploadRefusal(pdfBytes()), isNull);
    });
  });
}

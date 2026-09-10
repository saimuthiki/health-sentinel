import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:healthpulse/core/theme/hp_theme.dart';
import 'package:healthpulse/data/api/api_failure.dart';
import 'package:healthpulse/data/providers.dart';
import 'package:healthpulse/data/repository/fake_health_repository.dart';
import 'package:healthpulse/data/repository/http_health_repository.dart';
import 'package:healthpulse/features/chat/chat_photo.dart';
import 'package:healthpulse/features/chat/chat_photo_sheet.dart';
import 'package:healthpulse/features/chat/chat_screen.dart';
import 'package:healthpulse/features/chat/chat_thinking_bubble.dart';
// describeFileTooLarge lives with the report upload, and the assertion below
// is that a photo too big for chat is refused in exactly the same words as a
// report too big to upload. One sentence for one situation, wherever it
// happens.
import 'package:healthpulse/features/reports/report_upload.dart';

/// The camera in the chat composer, which the owner asked for like this:
///
/// > "a camera symbol would be even better, so the user can upload a photo and
/// > then pass that information to the app - something like 'hey, I ate this and
/// > these items'. Or if there are any skin allergies, he can take a photo and
/// > upload it in the chat section."
///
/// Two pictures, one button, and opposite handling. The tests below are mostly
/// about the second of those: a photograph of somebody's skin is kept with the
/// conversation and is never given to the AI, the app says so before the camera
/// opens rather than after the answer disappoints somebody, and the person - not
/// a model - is the one who says which kind of picture it is.
///
/// The rest is regression cover for what the previous round established about
/// chat, all of which has to survive a photo being attached: the optimistic
/// bubble, the thinking indicator, the busy flag cleared in a `finally`, a
/// failed send handing the words back, and no double send.
void main() {
  const String typed = 'I ate this';

  // ---------------------------------------------------------------- refusals

  group('what the phone refuses before anything is sent', () {
    test('a PDF is turned down and sent to the Reports tab instead', () {
      final Uint8List pdf = Uint8List.fromList(<int>[
        ...'%PDF-1.7'.codeUnits,
        ...List<int>.filled(40, 0x20),
      ]);
      // It sniffs perfectly well - it is simply not a photograph, and the
      // sentence has to send somebody somewhere useful rather than just say no.
      expect(describeChatPhotoRefusal(pdf), notAPhotoMessage);
      expect(notAPhotoMessage, contains('Reports tab'));
    });

    test('an empty file is turned down', () {
      expect(describeChatPhotoRefusal(Uint8List(0)), 'That file was empty.');
    });

    test('a photo past the limit is turned down before it is looked at', () {
      // The size is checked before the bytes are sniffed, so this never has to
      // be a real picture - which is just as well at twenty megabytes.
      final Uint8List big = Uint8List(maxChatPhotoBytes + 1);
      expect(
        describeChatPhotoRefusal(big),
        describeFileTooLarge(maxChatPhotoBytes + 1),
      );
    });

    test('a real photo is accepted', () {
      expect(describeChatPhotoRefusal(onePixelPng), isNull);
    });
  });

  // ------------------------------------------------------------------- asking

  testWidgets('the sheet asks which kind, and says what happens to a skin photo',
      (WidgetTester tester) async {
    useTallSurface(tester);
    final _Harness harness = _Harness();

    await tester.pumpWidget(harness.app());
    await settle(tester);

    // The button says both things it is for. Somebody told only "send a photo"
    // will not guess that a rash is welcome here.
    expect(find.byTooltip(photoButtonTooltip), findsOneWidget);
    await tester.tap(cameraFinder());
    await settleSheet(tester);

    expect(find.text('Send a photo'), findsOneWidget);
    expect(find.text(ChatPhotoKind.meal.choiceLabel), findsOneWidget);
    expect(find.text(ChatPhotoKind.body.choiceLabel), findsOneWidget);
    // The promise is made before the camera opens, not after the reply.
    expect(
      find.textContaining('I do not read photos of skin'),
      findsOneWidget,
      reason: 'somebody must not find out after the fact that we will not look',
    );
  });

  testWidgets('the kind comes from the tap, and travels with the upload',
      (WidgetTester tester) async {
    useTallSurface(tester);
    final _Harness harness = _Harness();

    await tester.pumpWidget(harness.app());
    await settle(tester);
    await tester.tap(cameraFinder());
    await settleSheet(tester);
    await tester.ensureVisible(find.byKey(bodyCameraKey));
    await tester.tap(find.byKey(bodyCameraKey));
    await settleSheet(tester);

    // The picker was asked for exactly what was tapped. Nothing anywhere is
    // asked to work out what the picture is of.
    expect(harness.picker.asked, <String>['body/camera']);
    expect(harness.service.uploaded.single.kind, ChatPhotoKind.body);
    // And what the backend said about it is on screen straight away.
    expect(find.text(_FakeChatPhotoService.bodyNotice), findsOneWidget);
    expect(find.text(ChatPhotoKind.body.chipLabel), findsOneWidget);
  });

  testWidgets('a meal photo is attached with no such notice',
      (WidgetTester tester) async {
    useTallSurface(tester);
    final _Harness harness = _Harness();

    await tester.pumpWidget(harness.app());
    await settle(tester);
    await harness.attach(tester, mealGalleryKey);

    expect(harness.picker.asked, <String>['meal/gallery']);
    expect(find.text(_FakeChatPhotoService.bodyNotice), findsNothing);
    expect(find.text(ChatPhotoKind.meal.chipLabel), findsOneWidget);
  });

  // ------------------------------------------------------------------ sending

  testWidgets('the photo is in the conversation as my own message before the reply',
      (WidgetTester tester) async {
    useTallSurface(tester);
    final _Harness harness = _Harness(holdSend: true);

    await tester.pumpWidget(harness.app());
    await settle(tester);
    await harness.attach(tester, mealCameraKey);

    await tester.enterText(find.byType(TextField), typed);
    await tester.pump();
    await tester.tap(sendFinder());
    await tester.pump();

    // Everything the previous round established, with a picture on it: the
    // words, the picture itself, the "on its way" line, an empty box and a
    // closed send button.
    expect(find.text(typed), findsOneWidget);
    expect(
      find.descendant(of: find.byType(ListView), matching: find.byType(Image)),
      findsOneWidget,
      reason: 'the picture is not in the bubble with the words it was sent with',
    );
    expect(find.byType(ChatThinkingBubble), findsOneWidget);
    expect(find.text('Sending'), findsOneWidget);
    expect(inputText(tester), isEmpty);
    expect(sendButton(tester).onPressed, isNull);

    // Tapping again while it is in flight must not send it twice.
    await tester.tap(sendFinder(), warnIfMissed: false);
    await tester.pump();
    expect(harness.service.sends.length, 1);

    harness.service.release();
    await settle(tester);
  });

  testWidgets('the message goes with the photo id, and never through the repository',
      (WidgetTester tester) async {
    useTallSurface(tester);
    final _Harness harness = _Harness();

    await tester.pumpWidget(harness.app());
    await settle(tester);
    await harness.attach(tester, mealCameraKey);
    await tester.enterText(find.byType(TextField), typed);
    await tester.pump();
    await tester.tap(sendFinder());
    await settle(tester);

    final _SentMessage sent = harness.service.sends.single;
    expect(sent.message, typed);
    expect(sent.photoIds, <String>['photo-1']);
    expect(sent.reportIds, isEmpty);
    // The photo is no longer waiting to go with the next message, and the busy
    // flag was cleared - the regression `busy_button_test.dart` exists for.
    expect(find.text(ChatPhotoKind.meal.chipLabel), findsNothing);
    expect(sendButton(tester).onPressed, isNotNull);
    expect(find.byType(ChatThinkingBubble), findsNothing);
  });

  testWidgets('what the backend says about the photo replaces what it said at attach time',
      (WidgetTester tester) async {
    useTallSurface(tester);
    final _Harness harness = _Harness(
      replyNotes: <String>[_FakeChatPhotoService.notFoodNote],
    );

    await tester.pumpWidget(harness.app());
    await settle(tester);
    await harness.attach(tester, mealCameraKey);
    await tester.enterText(find.byType(TextField), typed);
    await tester.pump();
    await tester.tap(sendFinder());
    await settle(tester);

    expect(find.text(_FakeChatPhotoService.notFoodNote), findsOneWidget);
  });

  testWidgets('a refused send gives the words back and keeps the photo',
      (WidgetTester tester) async {
    useTallSurface(tester);
    final _Harness harness = _Harness(refuseSend: true);

    await tester.pumpWidget(harness.app());
    await settle(tester);
    await harness.attach(tester, bodyGalleryKey);
    await tester.enterText(find.byType(TextField), typed);
    await tester.pump();
    await tester.tap(sendFinder());
    await settle(tester);

    // The words come back, the photo is still attached, and the screen works.
    expect(inputText(tester), typed);
    expect(find.text(ChatPhotoKind.body.chipLabel), findsOneWidget);
    expect(
      find.text(const ApiFailure(ApiFailureKind.wakingUpTimedOut).message),
      findsOneWidget,
    );
    expect(sendButton(tester).onPressed, isNotNull);
    expect(find.byType(ChatThinkingBubble), findsNothing);
    // A message that never left must not be sitting in the conversation.
    expect(
      find.descendant(of: find.byType(ListView), matching: find.text(typed)),
      findsNothing,
    );

    // Trying again reuses the picture that is already stored rather than
    // uploading twenty megabytes a second time.
    await tester.tap(sendFinder());
    await settle(tester);
    expect(harness.service.uploads, 1);
    expect(harness.service.sends.length, 2);
  });

  testWidgets('a photo the phone will not accept is never uploaded',
      (WidgetTester tester) async {
    useTallSurface(tester);
    final _Harness harness = _Harness(picked: notAPhotoBytes);

    await tester.pumpWidget(harness.app());
    await settle(tester);
    await harness.attach(tester, mealCameraKey);

    expect(harness.service.uploads, 0);
    expect(find.text(notAPhotoMessage), findsOneWidget);
    expect(find.text(ChatPhotoKind.meal.chipLabel), findsNothing);
  });

  testWidgets('backing out of the camera changes nothing',
      (WidgetTester tester) async {
    useTallSurface(tester);
    final _Harness harness = _Harness(backsOut: true);

    await tester.pumpWidget(harness.app());
    await settle(tester);
    await harness.attach(tester, mealCameraKey);

    expect(harness.service.uploads, 0);
    expect(find.text(ChatPhotoKind.meal.chipLabel), findsNothing);
    // Not a failure, so nothing is said about it.
    expect(find.text(notAPhotoMessage), findsNothing);
  });

  testWidgets('a build with no health engine says so instead of opening a camera',
      (WidgetTester tester) async {
    useTallSurface(tester);
    final _Harness harness = _Harness(noService: true);

    await tester.pumpWidget(harness.app());
    await settle(tester);
    await tester.tap(cameraFinder());
    await settleSheet(tester);

    expect(find.text(photoNeedsBackendMessage), findsOneWidget);
    expect(find.text('Send a photo'), findsNothing);
    expect(harness.picker.asked, isEmpty);
  });

  testWidgets('a photo can be taken back off the message',
      (WidgetTester tester) async {
    useTallSurface(tester);
    final _Harness harness = _Harness();

    await tester.pumpWidget(harness.app());
    await settle(tester);
    await harness.attach(tester, bodyCameraKey);
    expect(find.text(ChatPhotoKind.body.chipLabel), findsOneWidget);

    await tester.tap(find.byTooltip('Remove the photo'));
    await settle(tester);

    expect(find.text(ChatPhotoKind.body.chipLabel), findsNothing);
    expect(find.text(_FakeChatPhotoService.bodyNotice), findsNothing);
  });
}

// --------------------------------------------------------------------- fixtures

/// A real 1x1 PNG, so the widgets that draw it have something that decodes.
final Uint8List onePixelPng = Uint8List.fromList(<int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xDE,
  0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, 0x54,
  0x78, 0x9C, 0x63, 0x38, 0x91, 0x62, 0x04, 0x00,
  0x03, 0x56, 0x01, 0x5F, 0xE8, 0x17, 0x84, 0x52,
  0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44,
  0xAE, 0x42, 0x60, 0x82,
]);

/// Long enough to be sniffed, and not a picture of anything.
final Uint8List notAPhotoBytes = Uint8List.fromList(
  List<int>.filled(64, 0x41),
);

class _SentMessage {
  _SentMessage(this.message, this.photoIds, this.reportIds);

  final String message;
  final List<String> photoIds;
  final List<String> reportIds;
}

/// A picker that never touches a camera and records what it was asked for.
class _FakeChatPhotoPicker implements ChatPhotoPicker {
  _FakeChatPhotoPicker(this.bytes);

  /// Null stands for somebody backing out of the camera.
  final Uint8List? bytes;

  final List<String> asked = <String>[];

  @override
  Future<PickedChatPhoto?> pick(ChatPhotoKind kind, ChatPhotoSource source) async {
    asked.add('${kind.wire}/${source.name}');
    final Uint8List? data = bytes;
    if (data == null) {
      return null;
    }
    return PickedChatPhoto(fileName: 'photo.png', bytes: data, kind: kind);
  }
}

/// The backend, without one.
///
/// It stands in for the two endpoints the real service calls, and it also puts
/// the sent message into the fake repository - because the real backend stores
/// it, and the screen reloads the conversation expecting to find it there.
class _FakeChatPhotoService implements ChatPhotoService {
  _FakeChatPhotoService({
    required this.repository,
    required this.replyNotes,
    this.holdSend = false,
    this.refuseSend = false,
  });

  /// The backend's own words, which the app must show rather than write itself.
  static const String bodyNotice =
      'Your photo is saved to this conversation. HealthPulse does not look at '
      'pictures of skin or body changes.';
  static const String notFoodNote =
      'This photo was sent as a meal but does not appear to be food.';

  final FakeHealthRepository repository;
  final List<String> replyNotes;
  final bool holdSend;
  final bool refuseSend;

  int uploads = 0;
  final List<PickedChatPhoto> uploaded = <PickedChatPhoto>[];
  final List<_SentMessage> sends = <_SentMessage>[];

  final Completer<void> _gate = Completer<void>();

  void release() {
    if (!_gate.isCompleted) {
      _gate.complete();
    }
  }

  @override
  Future<ChatPhotoUpload> upload(
    PickedChatPhoto photo, {
    void Function(int sent, int total)? onProgress,
  }) async {
    uploads += 1;
    uploaded.add(photo);
    return ChatPhotoUpload(
      photoId: 'photo-$uploads',
      label: photo.kind.chipLabel,
      notices: photo.kind == ChatPhotoKind.body
          ? const <String>[bodyNotice]
          : const <String>[],
    );
  }

  @override
  Future<ChatPhotoReply> send({
    required String message,
    required List<String> photoIds,
    required List<String> reportIds,
  }) async {
    sends.add(_SentMessage(message, photoIds, reportIds));
    if (refuseSend) {
      throw ApiRepositoryException(
        const ApiFailure(ApiFailureKind.wakingUpTimedOut),
      );
    }
    if (holdSend) {
      // A Completer rather than a latency: the fake repository runs with
      // `Duration.zero`, so a call that settles at once has already finished
      // before a test can ask "is it showing that it is thinking?".
      await _gate.future;
    }
    await repository.sendMessage(message, attachments: reportIds);
    return ChatPhotoReply(threadId: 't1', notes: replyNotes);
  }
}

/// One assembled screen and the two fakes behind it.
class _Harness {
  _Harness({
    Uint8List? picked,
    bool backsOut = false,
    List<String> replyNotes = const <String>[],
    bool holdSend = false,
    bool refuseSend = false,
    this.noService = false,
  })  : picker = _FakeChatPhotoPicker(
          backsOut ? null : (picked ?? onePixelPng),
        ),
        service = _FakeChatPhotoService(
          repository: FakeHealthRepository(
            latency: Duration.zero,
            signedIn: true,
          ),
          replyNotes: replyNotes,
          holdSend: holdSend,
          refuseSend: refuseSend,
        );

  final _FakeChatPhotoPicker picker;
  final _FakeChatPhotoService service;

  /// The conversation behind it all. Held by the service, because the service
  /// stands in for the endpoint that stores a message, and a message that is
  /// stored is a message the reload finds.
  FakeHealthRepository get repository => service.repository;

  /// A build with no backend address, where the camera has nowhere to send to.
  final bool noService;

  Widget app() {
    return ProviderScope(
      overrides: <Override>[
        healthRepositoryProvider.overrideWithValue(repository),
        chatPhotoPickerProvider.overrideWithValue(picker),
        chatPhotoServiceProvider
            .overrideWithValue(noService ? null : service),
      ],
      child: MaterialApp(
        theme: HpTheme.light(),
        home: const ChatScreen(),
      ),
    );
  }

  /// Open the sheet, tap one of its four buttons, and let the upload land.
  Future<void> attach(WidgetTester tester, Key which) async {
    await tester.tap(cameraFinder());
    await settleSheet(tester);
    await tester.ensureVisible(find.byKey(which));
    await tester.tap(find.byKey(which));
    await settleSheet(tester);
  }
}

// ----------------------------------------------------------------- test utils

/// A surface tall enough that every bubble is built.
///
/// `ListView.builder` only builds what is on screen, so on a phone-sized
/// surface `find.text` would miss a bubble below the fold - and a test that
/// cannot see the newest message is not testing anything.
void useTallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(600, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Let a queued call land without ever waiting for "no animation left".
///
/// [WidgetTester.pumpAndSettle] cannot be used on this screen: the thinking
/// indicator animates for as long as it is on screen, by design, so a screen
/// that is meant to be busy would simply time it out.
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 32));
  await tester.pump();
}

/// The same, with enough time for a bottom sheet to open or close.
Future<void> settleSheet(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

/// Functions rather than stored [Finder]s, so every use is a fresh look at the
/// tree rather than a cached one.
Finder sendFinder() => find.widgetWithIcon(IconButton, Icons.send_rounded);

/// The composer's camera. `HpButton` is not an [IconButton], so this still finds
/// exactly one thing while the sheet - which has camera icons of its own - is
/// open.
Finder cameraFinder() =>
    find.widgetWithIcon(IconButton, Icons.photo_camera_outlined);

IconButton sendButton(WidgetTester tester) =>
    tester.widget<IconButton>(sendFinder());

String inputText(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField)).controller?.text ?? '';

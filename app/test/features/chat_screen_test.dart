import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:healthpulse/core/theme/hp_theme.dart';
import 'package:healthpulse/core/widgets/widgets.dart';
import 'package:healthpulse/data/api/api_failure.dart';
import 'package:healthpulse/data/models/models.dart';
import 'package:healthpulse/data/providers.dart';
import 'package:healthpulse/data/repository/fake_health_repository.dart';
import 'package:healthpulse/data/repository/http_health_repository.dart';
import 'package:healthpulse/features/chat/chat_screen.dart';
import 'package:healthpulse/features/chat/chat_thinking_bubble.dart';

/// The two bugs this file exists for, in the owner's words:
///
/// > "When I give a message it doesn't tell anything on the screen [...] the
/// > user might think the app is not working."
/// > "The attachment button is also not working."
///
/// Sending used to clear the box, wait for a whole round trip through Gemini,
/// and only then put anything on screen - which on a free hosting tier that
/// lets the machine sleep is several seconds of a screen that has not changed.
/// The attach button had an empty `onPressed`.
void main() {
  const String typed = 'I had two idlis and a coffee';

  testWidgets('the message and a thinking line are on screen before the reply',
      (WidgetTester tester) async {
    useTallSurface(tester);
    final GatedRepository repository = GatedRepository(holdSend: true);

    await tester.pumpWidget(chatApp(repository));
    await settle(tester);

    await tester.enterText(find.byType(TextField), typed);
    await tester.pump();
    await tester.tap(find.widgetWithIcon(IconButton, Icons.send_rounded));
    await tester.pump();

    // The send is still in flight - nothing has come back from the server - and
    // the person can already see their own words and something saying a reply
    // is coming.
    expect(repository.sendCalls, 1);
    expect(
      find.text(typed),
      findsOneWidget,
      reason: 'the message did not appear until the reply came back',
    );
    expect(find.byType(ChatThinkingBubble), findsOneWidget);
    expect(find.text(ChatThinkingBubble.label), findsOneWidget);
    // The echo says it is an echo rather than borrowing a timestamp it has not
    // been given.
    expect(find.text('Sending'), findsOneWidget);

    // And the box is empty and the button is closed, so the same message cannot
    // be sent twice by somebody who thinks nothing happened.
    expect(inputText(tester), isEmpty);
    expect(sendButton(tester).onPressed, isNull);

    // Nothing added to this screen may push the disclaimer off it. Chat is the
    // screen most likely to be mistaken for asking a doctor.
    expect(find.text(HpDisclaimer.compactText), findsOneWidget);

    repository.releaseSend();
    await settle(tester);
  });

  testWidgets('the thinking line goes when the reply lands, once only',
      (WidgetTester tester) async {
    useTallSurface(tester);
    final GatedRepository repository = GatedRepository(holdSend: true);

    await tester.pumpWidget(chatApp(repository));
    await settle(tester);

    await tester.enterText(find.byType(TextField), typed);
    await tester.pump();
    await tester.tap(find.widgetWithIcon(IconButton, Icons.send_rounded));
    await tester.pump();
    expect(find.byType(ChatThinkingBubble), findsOneWidget);

    repository.releaseSend();
    await settle(tester);

    expect(find.byType(ChatThinkingBubble), findsNothing);
    expect(find.text('Sending'), findsNothing);
    expect(find.textContaining('Noted, and I have added it'), findsOneWidget);
    // The local echo and the reloaded conversation must not both be drawing the
    // same message: the echo is dropped in the same frame the reloaded list
    // arrives in.
    expect(find.text(typed), findsOneWidget);
    expect(sendButton(tester).onPressed, isNotNull);
  });

  testWidgets('a refused send takes the echo back and returns the words',
      (WidgetTester tester) async {
    useTallSurface(tester);
    final GatedRepository repository = GatedRepository(refuseSend: true);

    await tester.pumpWidget(chatApp(repository));
    await settle(tester);

    await tester.enterText(find.byType(TextField), typed);
    await tester.pump();
    await tester.tap(find.widgetWithIcon(IconButton, Icons.send_rounded));
    await settle(tester);

    // A message that never left must not be sitting in the conversation looking
    // like it did. The only place these words survive is the input box.
    expect(
      find.descendant(
        of: find.byType(ListView),
        matching: find.text(typed),
      ),
      findsNothing,
      reason: 'a message that failed to send was left in the conversation',
    );
    expect(find.byType(ChatThinkingBubble), findsNothing);
    expect(find.text('Sending'), findsNothing);
    expect(inputText(tester), typed);

    // The sentence sits above the box, and the screen is usable again - the
    // regression `busy_button_test.dart` exists for.
    expect(
      find.text(const ApiFailure(ApiFailureKind.wakingUpTimedOut).message),
      findsOneWidget,
    );
    expect(sendButton(tester).onPressed, isNotNull);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('attached reports go as ids and are cleared once the message has',
      (WidgetTester tester) async {
    useTallSurface(tester);
    final GatedRepository repository = GatedRepository();

    await tester.pumpWidget(chatApp(repository));
    await settle(tester);

    await tester.tap(attachButton());
    await settleSheet(tester);

    // The sheet offers reports already uploaded, not a file picker: an
    // attachment here is a report id.
    expect(find.text('Attach a report'), findsOneWidget);
    await tester.tap(find.text('Apollo Diagnostics'));
    await tester.pump();
    await tester.tap(find.text('Attach 1 report'));
    await settleSheet(tester);

    expect(find.byType(Chip), findsOneWidget);
    expect(find.widgetWithText(Chip, 'Apollo Diagnostics'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Does this explain it?');
    await tester.pump();
    await tester.tap(find.widgetWithIcon(IconButton, Icons.send_rounded));
    await settle(tester);

    expect(repository.lastAttachments, <String>['r1']);
    expect(
      find.byType(Chip),
      findsNothing,
      reason: 'the attachment stayed on a message that has already gone',
    );
  });

  testWidgets('attached reports are kept when the send failed',
      (WidgetTester tester) async {
    useTallSurface(tester);
    final GatedRepository repository = GatedRepository(refuseSend: true);

    await tester.pumpWidget(chatApp(repository));
    await settle(tester);

    await tester.tap(attachButton());
    await settleSheet(tester);
    await tester.tap(find.text('Apollo Diagnostics'));
    await tester.pump();
    await tester.tap(find.text('Attach 1 report'));
    await settleSheet(tester);

    await tester.enterText(find.byType(TextField), typed);
    await tester.pump();
    await tester.tap(find.widgetWithIcon(IconButton, Icons.send_rounded));
    await settle(tester);

    expect(repository.lastAttachments, <String>['r1']);
    // The words are being handed back, so what was attached to them is handed
    // back too: sending again is one tap, not a re-selection.
    expect(find.byType(Chip), findsOneWidget);
    expect(inputText(tester), typed);
  });

  testWidgets('the sheet says when there is nothing to attach yet',
      (WidgetTester tester) async {
    useTallSurface(tester);

    await tester.pumpWidget(chatApp(GatedRepository(noReports: true)));
    await settle(tester);

    await tester.tap(attachButton());
    await settleSheet(tester);

    expect(find.text('No reports to attach yet'), findsOneWidget);
    expect(find.byType(CheckboxListTile), findsNothing);
    // Somebody with no reports needs to be told what an attachment is here and
    // where the first one comes from, not shown an empty list.
    expect(
      find.textContaining('Add one on the Reports tab'),
      findsOneWidget,
    );

    // And the way out of the empty state is the Reports tab itself, at the
    // route `app_router.dart` actually registers.
    await tester.tap(find.text('Go to Reports'));
    await settleSheet(tester);
    expect(find.text(reportsMarker), findsOneWidget);
  });
}

/// The fake repository with a gate on `sendMessage`.
///
/// Why a [Completer] rather than a latency: the fake is built with
/// `Duration.zero` in tests and awaiting a `tester.tap` flushes microtasks, so a
/// call that settles immediately has already finished before a test can ask "is
/// it showing that it is thinking?". Holding the call open is the only way to
/// get inside the window this whole change exists for.
/// `_refusing_repository.dart` does the same thing for consent.
class GatedRepository extends FakeHealthRepository {
  GatedRepository({
    this.holdSend = false,
    this.refuseSend = false,
    this.noReports = false,
  }) : super(latency: Duration.zero, signedIn: true);

  /// Hold `sendMessage` open until [releaseSend] is called.
  final bool holdSend;

  /// Refuse it with the same exception the real HTTP repository throws, so the
  /// screen sees what a refused backend call actually looks like.
  final bool refuseSend;

  /// Answer `loadReports` with nothing, for somebody who has not uploaded yet.
  final bool noReports;

  int sendCalls = 0;

  /// What the screen actually passed as attachments, so a test can prove report
  /// *ids* went rather than anything else.
  List<String> lastAttachments = const <String>[];

  final Completer<void> _sendGate = Completer<void>();

  void releaseSend() {
    if (!_sendGate.isCompleted) {
      _sendGate.complete();
    }
  }

  @override
  Future<List<HealthReport>> loadReports() {
    if (noReports) {
      return Future<List<HealthReport>>.value(const <HealthReport>[]);
    }
    return super.loadReports();
  }

  @override
  Future<ChatMessage> sendMessage(
    String text, {
    List<String> attachments = const <String>[],
  }) async {
    sendCalls += 1;
    lastAttachments = attachments;
    if (refuseSend) {
      throw ApiRepositoryException(
        const ApiFailure(ApiFailureKind.wakingUpTimedOut),
      );
    }
    if (holdSend) {
      await _sendGate.future;
    }
    return super.sendMessage(text, attachments: attachments);
  }
}

/// Where the sheet's "upload a new one" action leads, so a test can tell that
/// it went somewhere real.
const String reportsMarker = 'REPORTS-REACHED';

/// The chat tab, wired to [repository], with the one other route the screen can
/// send somebody to.
Widget chatApp(FakeHealthRepository repository) {
  return ProviderScope(
    overrides: <Override>[
      healthRepositoryProvider.overrideWithValue(repository),
    ],
    child: MaterialApp.router(
      theme: HpTheme.light(),
      routerConfig: GoRouter(
        initialLocation: '/chat',
        routes: <RouteBase>[
          GoRoute(
            path: '/chat',
            builder: (BuildContext context, GoRouterState state) =>
                const ChatScreen(),
          ),
          GoRoute(
            path: '/reports',
            builder: (BuildContext context, GoRouterState state) =>
                const Scaffold(body: Center(child: Text(reportsMarker))),
          ),
        ],
      ),
    ),
  );
}

/// A surface tall enough that every bubble in the conversation is built.
///
/// `ListView.builder` only builds what is on screen, so on a phone-sized test
/// surface `find.text` would miss a bubble that is merely below the fold - and
/// a test that cannot see the newest message is not testing anything.
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
/// that is meant to be busy would time it out.
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 32));
  await tester.pump();
}

/// The same, with enough time for a bottom sheet to open or close and for a
/// route change behind it to finish. Both are fixed-length transitions, so this
/// waits out a generous fixed length rather than asking for a still tree.
Future<void> settleSheet(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

IconButton sendButton(WidgetTester tester) => tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.send_rounded),
    );

/// A function rather than a stored [Finder], so every use is a fresh look at
/// the tree rather than a cached one.
Finder attachButton() =>
    find.widgetWithIcon(IconButton, Icons.attach_file_rounded);

String inputText(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField)).controller?.text ?? '';

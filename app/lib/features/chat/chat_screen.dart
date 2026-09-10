import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format/hp_format.dart';
import '../../core/theme/hp_palette.dart';
import '../../core/theme/hp_spacing.dart';
import '../../core/theme/hp_typography.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/models.dart';
import '../../data/providers.dart';
import '../common/failure_copy.dart';
import 'chat_attachment_sheet.dart';
import 'chat_thinking_bubble.dart';

/// Where symptoms, questions and "I had two idlis" go.
///
/// Chat is an input to the loop rather than the product itself: what is said
/// here becomes symptoms, goals and food preferences, and shows up in tomorrow's
/// plan. The disclaimer sits at the top rather than the bottom because this is
/// the screen most likely to be mistaken for asking a doctor.
class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

/// The Reports tab, as `core/router/app_router.dart` registers it.
const String _reportsRoute = '/reports';

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  bool _sending = false;

  /// Why the last send did not go, or null. Kept on screen rather than shown in
  /// a snack bar: a message that failed to send is worth more than four
  /// seconds of somebody's attention, and it sits next to the box holding the
  /// words that need re-sending.
  String? _sendError;

  /// The message that has just been sent, held here until the reloaded
  /// conversation contains it, and null the rest of the time.
  ///
  /// This is the fix for "I press send and nothing happens". [messagesProvider]
  /// only knows what the server has told it, so a message cannot appear in that
  /// list until a whole round trip through Gemini has finished — several seconds
  /// on a free hosting tier that lets the machine fall asleep between requests.
  /// Rather than write into the provider, which would mean inventing server
  /// state on the phone, the screen draws this one message *after* the
  /// provider's list, so the bubble is there on the same frame as the tap.
  ///
  /// It is cleared in the same `setState` that ends the send, which is what
  /// keeps exactly one copy of the message on screen: while it is set the
  /// reloaded list does not contain the message yet, and by the time it is
  /// cleared the reloaded list does.
  ChatMessage? _pending;

  /// Reports chosen to travel with the next message.
  ///
  /// Held as whole reports rather than as ids so the chips above the input can
  /// name them; only the ids are sent.
  final List<HealthReport> _attachments = <HealthReport>[];

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Put the newest bubble in view, after the frame that adds it.
  ///
  /// Scrolling during a build would scroll to a maximum extent measured before
  /// the new bubble existed, so this waits for that frame to be built first.
  /// `hasClients` covers the case where there is no list to scroll at all: the
  /// first message of a conversation is sent from the empty state, and the
  /// controller is attached to nothing until a [ListView] is on screen.
  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted || !_scroll.hasClients) {
        return;
      }
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: HpMotion.settle,
        curve: HpMotion.ease,
      );
    });
  }

  /// Choose which already-uploaded reports go with the next message.
  ///
  /// The sheet returns null when it was dismissed without a decision, which
  /// leaves the current choice exactly as it was.
  ///
  /// Going to Reports happens here rather than inside the sheet, and only once
  /// the sheet's future has resolved — which is to say once it has finished
  /// closing. Changing the page out from under a sheet that is still animating
  /// out is how a navigation ends up half-applied.
  Future<void> _openAttachments() async {
    final ChatAttachmentResult? result = await showChatAttachmentSheet(
      context,
      selected: _attachments,
    );
    if (!mounted || result == null) {
      return;
    }
    if (result.openReports) {
      GoRouter.of(context).go(_reportsRoute);
      return;
    }
    final List<HealthReport>? chosen = result.reports;
    if (chosen == null) {
      return;
    }
    setState(() {
      _attachments
        ..clear()
        ..addAll(chosen);
    });
  }

  void _removeAttachment(HealthReport report) {
    setState(() {
      _attachments.removeWhere((HealthReport r) => r.id == report.id);
    });
  }

  String _attachmentLabel(HealthReport report) =>
      report.labName ?? report.fileName;

  /// Send the message, and give it back if it did not go.
  ///
  /// The busy flag is cleared in a `finally`. Before this, a refused send left
  /// `_sending` true for the life of the screen: the send button stayed
  /// disabled, the typed message had already been cleared, and there was no way
  /// to get either back short of leaving the tab.
  Future<void> _send() async {
    final String text = _input.text.trim();
    if (text.isEmpty || _sending) {
      return;
    }
    final List<String> attachmentIds =
        _attachments.map((HealthReport r) => r.id).toList();

    setState(() {
      _sending = true;
      _sendError = null;
      // A local echo, marked pending, with an id no server would recognise and
      // no timestamp: nothing about it pretends to be a stored message.
      _pending = ChatMessage(
        id: 'local-${DateTime.now().microsecondsSinceEpoch}',
        role: ChatRole.user,
        content: text,
        attachments: attachmentIds,
        pending: true,
      );
    });
    _input.clear();
    _scrollToEnd();

    String? failure;
    bool sent = false;
    try {
      await ref
          .read(healthRepositoryProvider)
          .sendMessage(text, attachments: attachmentIds);
      sent = true;
      if (mounted) {
        // Refreshed and *awaited*, rather than invalidated and forgotten. The
        // echo has to stay on screen until the list that replaces it has
        // actually arrived, or the message would blink out of existence for the
        // length of the reload and the screen would look like it had lost it.
        //
        // Guarded by `mounted` because `ref` belongs to a widget: somebody who
        // sends a message and immediately leaves the tab must not be met with a
        // crash for a message that went perfectly well.
        //
        // Held in a variable and awaited on the next line rather than awaited
        // in one go: `refresh` is annotated so that its result cannot be
        // dropped, and an `await` on its own does not count as having used it.
        // The analyzer is right to insist - a refresh fired and forgotten is
        // exactly the bug this line exists to avoid.
        final Future<List<ChatMessage>> reloaded =
            ref.refresh(messagesProvider.future);
        await reloaded;
      }
    } catch (error) {
      if (!sent) {
        failure = explainFailure(
          error,
          fallback:
              'That message could not be sent just now. It is still in the '
              'box - try again in a moment.',
        );
      }
      // When `sent` is true the message did reach the server and only the
      // reload failed. That is the conversation list's problem, and the list
      // says so itself, with its own retry; handing the words back here would
      // be inviting somebody to send the same thing a second time.
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
          _sendError = failure;
          // The echo goes at the same moment the reloaded list arrives, so the
          // message is never on screen twice and never missing in between. On a
          // failure it goes too: a message that was not sent must not be left
          // sitting in somebody's history looking like it was.
          _pending = null;
          if (sent) {
            _attachments.clear();
          }
        });
        _scrollToEnd();
      }
    }

    if (failure == null || !mounted) {
      return;
    }
    // The words somebody just typed are theirs; losing them to a dropped
    // connection is not acceptable. The reports they attached are kept for the
    // same reason - the message is about to be sent again exactly as it was.
    _input.text = text;
    _input.selection = TextSelection.collapsed(offset: text.length);
  }

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    final AsyncValue<List<ChatMessage>> messages =
        ref.watch(messagesProvider);
    final String? sendError = _sendError;

    return Scaffold(
      appBar: AppBar(title: const Text('Chat')),
      body: SafeArea(
        bottom: false,
        child: Column(
          children: <Widget>[
            const HpDisclaimer.compact(),
            Expanded(
              child: messages.when(
                loading: () =>
                    const HpLoadingState(message: 'Loading your conversation'),
                error: (Object error, StackTrace stack) => HpErrorState(
                  title: 'Chat is unavailable',
                  body: explainFailure(
                    error,
                    fallback: 'The app could not reach the health engine. '
                        'Your messages are safe.',
                  ),
                  onRetry: () => ref.invalidate(messagesProvider),
                ),
                data: (List<ChatMessage> list) {
                  final ChatMessage? pending = _pending;
                  if (list.isEmpty && pending == null) {
                    return const HpEmptyState(
                      icon: Icons.forum_outlined,
                      title: 'Tell it something',
                      body: 'A symptom, a goal, what you had for lunch, or a '
                          'question about a value in your report. Anything you '
                          'say here shapes tomorrow’s plan.',
                    );
                  }
                  // Two rows are added while a send is in flight: the message
                  // itself, and the "on its way" bubble under it. The first
                  // message of a conversation is sent from the empty state
                  // above, so the list has to be able to carry the echo on its
                  // own, with nothing before it.
                  final int tail = pending == null ? 0 : 2;
                  return ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(
                      HpSpacing.gutter,
                      HpSpacing.xl,
                      HpSpacing.gutter,
                      HpSpacing.xl,
                    ),
                    itemCount: list.length + tail,
                    itemBuilder: (BuildContext context, int index) {
                      if (index < list.length) {
                        return _Bubble(message: list[index]);
                      }
                      if (index == list.length && pending != null) {
                        return _Bubble(message: pending);
                      }
                      return const ChatThinkingBubble();
                    },
                  );
                },
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(
                HpSpacing.md,
                HpSpacing.sm,
                HpSpacing.md,
                HpSpacing.sm,
              ),
              decoration: BoxDecoration(
                color: p.surface,
                border: Border(top: BorderSide(color: p.hairline)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (sendError != null) ...<Widget>[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        HpSpacing.sm,
                        HpSpacing.sm,
                        HpSpacing.sm,
                        0,
                      ),
                      child: Semantics(
                        liveRegion: true,
                        container: true,
                        child: Text(
                          sendError,
                          style: HpType.label.copyWith(color: p.urgentInk),
                        ),
                      ),
                    ),
                  ],
                  if (_attachments.isNotEmpty) ...<Widget>[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        HpSpacing.sm,
                        HpSpacing.sm,
                        HpSpacing.sm,
                        0,
                      ),
                      child: Wrap(
                        spacing: HpSpacing.sm,
                        runSpacing: HpSpacing.xs,
                        children: <Widget>[
                          for (final HealthReport report in _attachments)
                            Chip(
                              avatar: Icon(
                                Icons.description_outlined,
                                size: 16,
                                color: p.pineDeep,
                              ),
                              label: Text(_attachmentLabel(report)),
                              labelStyle: HpType.label.copyWith(color: p.ink),
                              backgroundColor: p.pineSoft,
                              side: BorderSide(color: p.pineSoft),
                              deleteIconColor: p.inkMuted,
                              deleteButtonTooltipMessage:
                                  'Remove ${_attachmentLabel(report)}',
                              onDeleted: () => _removeAttachment(report),
                            ),
                        ],
                      ),
                    ),
                  ],
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: <Widget>[
                      IconButton(
                        icon: const Icon(Icons.attach_file_rounded),
                        // "A report", not "a report or a photo": what travels
                        // with a message is the id of something already
                        // uploaded, and the sheet says so plainly.
                        tooltip: 'Attach a report',
                        onPressed: _sending ? null : _openAttachments,
                      ),
                      Expanded(
                        child: TextField(
                          controller: _input,
                          minLines: 1,
                          maxLines: 5,
                          textCapitalization: TextCapitalization.sentences,
                          decoration: const InputDecoration(
                            hintText: 'Ask something, or say what you ate',
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            filled: false,
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: HpSpacing.sm,
                              vertical: HpSpacing.md,
                            ),
                          ),
                          onSubmitted: (String _) => _send(),
                        ),
                      ),
                      const SizedBox(width: HpSpacing.xs),
                      IconButton.filled(
                        icon: const Icon(Icons.send_rounded),
                        tooltip: 'Send',
                        onPressed: _sending ? null : _send,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    final bool mine = message.role == ChatRole.user;
    final DateTime? at = message.createdAt;

    return Padding(
      padding: const EdgeInsets.only(bottom: HpSpacing.lg),
      child: Column(
        crossAxisAlignment:
            mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: <Widget>[
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: HpSpacing.lg,
                vertical: HpSpacing.md,
              ),
              decoration: BoxDecoration(
                color: mine ? p.pineSoft : p.surface,
                border: Border.all(color: mine ? p.pineSoft : p.hairline),
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(HpRadii.card),
                  topRight: const Radius.circular(HpRadii.card),
                  bottomLeft: Radius.circular(mine ? HpRadii.card : 4),
                  bottomRight: Radius.circular(mine ? 4 : HpRadii.card),
                ),
              ),
              child: Text(
                message.content,
                style: HpType.reading.copyWith(color: p.ink),
              ),
            ),
          ),
          // A local echo has no timestamp to show, because the server has not
          // given it one yet. Saying "Sending" is more honest than borrowing the
          // phone's clock for a message that might still fail.
          if (message.pending) ...<Widget>[
            const SizedBox(height: HpSpacing.xs),
            Text(
              'Sending',
              style: HpType.micro.copyWith(color: p.inkFaint),
            ),
          ] else if (at != null) ...<Widget>[
            const SizedBox(height: HpSpacing.xs),
            Text(
              HpFormat.clockLabel(
                '${at.hour.toString().padLeft(2, '0')}:'
                '${at.minute.toString().padLeft(2, '0')}',
              ),
              style: HpType.micro.copyWith(color: p.inkFaint),
            ),
          ],
        ],
      ),
    );
  }
}

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
import 'chat_photo.dart';
import 'chat_photo_sheet.dart';
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

/// The camera button's tooltip. Says both things it is for, because a person
/// who has only been told "send a photo" will not guess that a rash is welcome.
const String photoButtonTooltip = 'Send a photo of a meal, or of a skin concern';

/// Shown while a picture is being stored. Kept here so the screen and its tests
/// name one string rather than two copies that can drift apart.
const String attachingPhotoLabel = 'Saving your photo';

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

  /// The photograph waiting to go with the next message, or null.
  ///
  /// One at a time. A conversation is a sequence of things somebody said, and
  /// "here are four pictures and one sentence" is not one of them; the backend
  /// accepts three, and if that ever needs using this becomes a list.
  ///
  /// It is already uploaded by the time it is held here - see [_addPhoto] - so
  /// what this carries is the bytes to draw on screen plus the id to send.
  PickedChatPhoto? _photo;

  /// True while a photo is being stored, which is a different kind of busy from
  /// [_sending] and has to be told apart from it: the send button is closed for
  /// both, but only one of them puts a message in the conversation.
  bool _attaching = false;

  /// What the backend said about the photo - that a skin picture is kept and not
  /// interpreted, or that a picture sent as a meal turned out not to be food.
  ///
  /// Its words, not ours and never the AI's. See `backend/app/rules/chat_photos.py`.
  List<String> _photoNotes = const <String>[];

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

  /// Attach a photograph: ask what it is, pick it, check it, store it.
  ///
  /// The order matters. The question comes first, before the camera opens,
  /// because the answer decides what the backend is allowed to do with the
  /// picture and the person is the only one who reliably knows it - see
  /// `chat_photo_sheet.dart`. The bytes are checked here, on the phone, so a
  /// picture that was never going to be accepted is refused now rather than
  /// after a long upload. And the storing happens now rather than on send, so
  /// that the sentence about a skin photo not being interpreted is on screen
  /// *before* anybody waits for a reply.
  Future<void> _addPhoto() async {
    if (_sending || _attaching) {
      return;
    }
    final ChatPhotoService? service = ref.read(chatPhotoServiceProvider);
    if (service == null) {
      // A build with no backend address. Saying so beats opening a camera we
      // have nowhere to send the result of.
      setState(() => _sendError = photoNeedsBackendMessage);
      return;
    }

    final ChatPhotoRequest? request = await showChatPhotoSheet(context);
    if (!mounted || request == null) {
      return;
    }

    PickedChatPhoto? picked;
    try {
      picked = await ref
          .read(chatPhotoPickerProvider)
          .pick(request.kind, request.source);
    } catch (error) {
      if (mounted) {
        setState(() {
          _sendError = explainFailure(
            error,
            fallback: 'That photo could not be opened. Please try again.',
          );
        });
      }
      return;
    }
    if (!mounted || picked == null) {
      // Backing out of a camera is the commonest outcome and is not a failure.
      return;
    }
    final PickedChatPhoto chosen = picked;

    final String? refusal = describeChatPhotoRefusal(chosen.bytes);
    if (refusal != null) {
      setState(() => _sendError = refusal);
      return;
    }

    setState(() {
      _attaching = true;
      _sendError = null;
      _photoNotes = const <String>[];
    });

    String? failure;
    ChatPhotoUpload? stored;
    try {
      stored = await service.upload(chosen);
      chosen.uploadedId = stored.photoId;
      chosen.uploadedLabel = stored.label;
    } catch (error) {
      failure = explainFailure(error, fallback: photoUploadFallbackMessage);
    } finally {
      if (mounted) {
        final ChatPhotoUpload? result = stored;
        setState(() {
          _attaching = false;
          _sendError = failure;
          // Only a photo that actually reached the backend is held: one that
          // did not has no id, and a chip for it above the composer would be
          // an attachment that quietly goes nowhere when send is tapped.
          _photo = result == null ? null : chosen;
          _photoNotes = result?.notices ?? const <String>[];
        });
      }
    }
  }

  /// Take the photo back off the message.
  ///
  /// The copy already stored on the server is left where it is. Removing it
  /// would need a delete endpoint of its own, and the file is already inside
  /// the promise that matters: it sits in this user's own folder, so
  /// `POST /v1/privacy/delete` sweeps it with everything else.
  void _removePhoto() {
    setState(() {
      _photo = null;
      _photoNotes = const <String>[];
    });
  }

  /// Stop showing what the backend said about a photo.
  void _dismissPhotoNotes() {
    setState(() => _photoNotes = const <String>[]);
  }

  /// Send the message, and give it back if it did not go.
  ///
  /// The busy flag is cleared in a `finally`. Before this, a refused send left
  /// `_sending` true for the life of the screen: the send button stayed
  /// disabled, the typed message had already been cleared, and there was no way
  /// to get either back short of leaving the tab.
  Future<void> _send() async {
    final String text = _input.text.trim();
    // `_attaching` joins the guard: a photo that is still going up has no id
    // yet, so a send now would post the message without it.
    if (text.isEmpty || _sending || _attaching) {
      return;
    }
    final List<String> attachmentIds =
        _attachments.map((HealthReport r) => r.id).toList();
    final PickedChatPhoto? photo = _photo;

    setState(() {
      _sending = true;
      _sendError = null;
      // A local echo, marked pending, with an id no server would recognise and
      // no timestamp: nothing about it pretends to be a stored message. Its
      // attachment labels are the words the backend will use when the same
      // message comes back, so the bubble does not relabel itself on reload.
      _pending = ChatMessage(
        id: 'local-${DateTime.now().microsecondsSinceEpoch}',
        role: ChatRole.user,
        content: text,
        attachments: <String>[
          ...List<String>.filled(attachmentIds.length, reportChipLabel),
          if (photo != null) photo.chipLabel,
        ],
        pending: true,
      );
    });
    _input.clear();
    _scrollToEnd();

    String? failure;
    List<String>? notes;
    bool sent = false;
    try {
      final String? photoId = photo?.uploadedId;
      final ChatPhotoService? photos = ref.read(chatPhotoServiceProvider);
      if (photo != null) {
        // A message carrying a photo goes through the chat feature's own
        // service, because the repository's `sendMessage` has no way to name a
        // photo. See `chat_photo.dart`.
        //
        // Neither of these can be null in practice - a photo is only held here
        // once it has been stored, which needed both - but they are checked
        // rather than asserted, because a `!` that is wrong is a crash and a
        // thrown ChatPhotoException is a sentence somebody can read.
        if (photos == null || photoId == null) {
          throw const ChatPhotoException(photoUploadFallbackMessage);
        }
        final ChatPhotoReply reply = await photos.send(
          message: text,
          photoIds: <String>[photoId],
          reportIds: attachmentIds,
        );
        notes = reply.notes;
      } else {
        await ref
            .read(healthRepositoryProvider)
            .sendMessage(text, attachments: attachmentIds);
      }
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
        final List<String>? replyNotes = notes;
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
            // The photo has gone with the message, so it is no longer waiting
            // to go with the next one.
            _photo = null;
          }
          if (replyNotes != null) {
            // What the backend says about the photo *after* reading the message
            // replaces what it said when the photo was attached.
            _photoNotes = replyNotes;
          }
        });
        _scrollToEnd();
      }
    }

    if (failure == null || !mounted) {
      return;
    }
    // The words somebody just typed are theirs; losing them to a dropped
    // connection is not acceptable. The reports and the photo they attached are
    // kept for the same reason - the message is about to be sent again exactly
    // as it was, and the photo is already stored, so trying again costs one
    // small request rather than another upload.
    _input.text = text;
    _input.selection = TextSelection.collapsed(offset: text.length);
  }

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    final AsyncValue<List<ChatMessage>> messages =
        ref.watch(messagesProvider);
    final String? sendError = _sendError;
    final PickedChatPhoto? waiting = _photo;

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
                        // The echo draws the actual picture, from the bytes
                        // still in memory. A message reloaded from the server
                        // shows the label instead: the file lives in private
                        // storage and is not addressable from here.
                        return _Bubble(message: pending, photo: _photo);
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
                  if (_photoNotes.isNotEmpty) ...<Widget>[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        HpSpacing.sm,
                        HpSpacing.sm,
                        HpSpacing.sm,
                        0,
                      ),
                      child: _PhotoNotes(
                        notes: _photoNotes,
                        onDismiss: _dismissPhotoNotes,
                      ),
                    ),
                  ],
                  // Hidden while the message is going: the picture is in the
                  // bubble by then, and two of it on one screen reads as two
                  // photographs rather than one.
                  if (waiting != null && !_sending) ...<Widget>[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        HpSpacing.sm,
                        HpSpacing.sm,
                        HpSpacing.sm,
                        0,
                      ),
                      child: _PhotoStrip(photo: waiting, onRemove: _removePhoto),
                    ),
                  ],
                  if (_attaching) ...<Widget>[
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
                          attachingPhotoLabel,
                          style: HpType.label.copyWith(color: p.inkMuted),
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
                        // uploaded, and the sheet says so plainly. The camera
                        // beside it is the other thing, and has its own button
                        // rather than a second row in this sheet, because a
                        // photograph is a different act from picking a file.
                        tooltip: 'Attach a report',
                        onPressed: _sending || _attaching ? null : _openAttachments,
                      ),
                      IconButton(
                        icon: const Icon(Icons.photo_camera_outlined),
                        tooltip: photoButtonTooltip,
                        // Closed while a photo is already going up, so two
                        // pictures cannot race each other into one message.
                        onPressed:
                            _sending || _attaching || _photo != null ? null : _addPhoto,
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
                        onPressed: _sending || _attaching ? null : _send,
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
  const _Bubble({required this.message, this.photo});

  final ChatMessage message;

  /// The picture this message is carrying, when the app still has the bytes.
  ///
  /// Only ever set on the local echo of a message being sent. Once the
  /// conversation is reloaded the server describes the attachment in words -
  /// "Photo of a meal" - because the file is in private storage and this screen
  /// has no address for it.
  final PickedChatPhoto? photo;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    final bool mine = message.role == ChatRole.user;
    final DateTime? at = message.createdAt;
    final PickedChatPhoto? picture = photo;

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
              child: Column(
                crossAxisAlignment: mine
                    ? CrossAxisAlignment.end
                    : CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (picture != null) ...<Widget>[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(HpRadii.field),
                      // Capped rather than drawn at full size: a bubble is a
                      // bubble, and a portrait photograph at its own height
                      // would push the words that went with it off the screen.
                      // `contain` rather than `cover`, so a wide picture is
                      // scaled down inside the bubble rather than spilling out
                      // of the side of it.
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 180),
                        child: Image.memory(
                          picture.bytes,
                          fit: BoxFit.contain,
                          // A picture that will not decode must not take the
                          // message down with it.
                          errorBuilder: (BuildContext context, Object error,
                                  StackTrace? stack) =>
                              _AttachmentChip(label: picture.chipLabel),
                        ),
                      ),
                    ),
                    const SizedBox(height: HpSpacing.sm),
                  ] else if (message.attachments.isNotEmpty) ...<Widget>[
                    Wrap(
                      spacing: HpSpacing.xs,
                      runSpacing: HpSpacing.xs,
                      children: <Widget>[
                        for (final String label in message.attachments)
                          _AttachmentChip(label: label),
                      ],
                    ),
                    const SizedBox(height: HpSpacing.sm),
                  ],
                  Text(
                    message.content,
                    style: HpType.reading.copyWith(color: p.ink),
                  ),
                ],
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

/// The name of one thing travelling with a message, inside its bubble.
///
/// A label rather than the file: the picture itself is in private storage and
/// the words are what the server sends back. Small and quiet on purpose - it is
/// a note about the message, not the message.
class _AttachmentChip extends StatelessWidget {
  const _AttachmentChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: HpSpacing.sm,
        vertical: HpSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: p.surface,
        border: Border.all(color: p.hairline),
        borderRadius: HpRadii.pillRadius,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.image_outlined, size: 13, color: p.inkFaint),
          const SizedBox(width: HpSpacing.xs),
          Text(label, style: HpType.micro.copyWith(color: p.inkMuted)),
        ],
      ),
    );
  }
}

/// The photograph waiting to go with the next message.
///
/// A thumbnail rather than a file name, because a person who has taken three
/// pictures of the same arm this week cannot tell them apart by name, and
/// sending the wrong one is a wasted trip through the whole loop.
class _PhotoStrip extends StatelessWidget {
  const _PhotoStrip({required this.photo, required this.onRemove});

  final PickedChatPhoto photo;

  /// Taking it back off the message. Always available while the strip is on
  /// screen: the strip is hidden for the length of a send, so there is no window
  /// in which somebody could unattach a photo that has already gone.
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;

    return Row(
      children: <Widget>[
        ClipRRect(
          borderRadius: BorderRadius.circular(HpRadii.field),
          child: Image.memory(
            photo.bytes,
            width: 44,
            height: 44,
            fit: BoxFit.cover,
            errorBuilder:
                (BuildContext context, Object error, StackTrace? stack) =>
                    Container(
              width: 44,
              height: 44,
              color: p.surfaceSunk,
              child: Icon(Icons.image_outlined, size: 18, color: p.inkFaint),
            ),
          ),
        ),
        const SizedBox(width: HpSpacing.md),
        Expanded(
          child: Text(
            photo.chipLabel,
            style: HpType.label.copyWith(color: p.ink),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.close_rounded, size: 18),
          tooltip: 'Remove the photo',
          onPressed: onRemove,
        ),
      ],
    );
  }
}

/// What the backend said about a photograph.
///
/// Deliberately not a bubble in the conversation. These sentences are the app
/// speaking about what it will and will not do - that a picture of skin is kept
/// but not read - and dressing them as a reply would blur the one line this
/// screen most needs to keep clear: what came from the health engine's rules,
/// and what came from a language model.
class _PhotoNotes extends StatelessWidget {
  const _PhotoNotes({required this.notes, required this.onDismiss});

  final List<String> notes;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;

    return Semantics(
      liveRegion: true,
      container: true,
      child: Container(
        padding: const EdgeInsets.fromLTRB(
          HpSpacing.md,
          HpSpacing.md,
          HpSpacing.sm,
          HpSpacing.md,
        ),
        decoration: BoxDecoration(
          color: p.calmSoft,
          borderRadius: HpRadii.cardRadius,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(Icons.info_outline_rounded, size: 18, color: p.calmInk),
            const SizedBox(width: HpSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  for (final String note in notes)
                    Padding(
                      padding: EdgeInsets.only(
                        bottom: note == notes.last ? 0 : HpSpacing.sm,
                      ),
                      child: Text(
                        note,
                        style: HpType.label.copyWith(color: p.ink),
                      ),
                    ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close_rounded, size: 18),
              tooltip: 'Dismiss',
              onPressed: onDismiss,
            ),
          ],
        ),
      ),
    );
  }
}

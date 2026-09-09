import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format/hp_format.dart';
import '../../core/theme/hp_palette.dart';
import '../../core/theme/hp_spacing.dart';
import '../../core/theme/hp_typography.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/models.dart';
import '../../data/providers.dart';

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

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  bool _sending = false;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final String text = _input.text.trim();
    if (text.isEmpty || _sending) {
      return;
    }
    setState(() => _sending = true);
    _input.clear();
    await ref.read(healthRepositoryProvider).sendMessage(text);
    ref.invalidate(messagesProvider);
    if (mounted) {
      setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    final AsyncValue<List<ChatMessage>> messages =
        ref.watch(messagesProvider);

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
                  body: 'The app could not reach the health engine. Your '
                      'messages are safe.',
                  onRetry: () => ref.invalidate(messagesProvider),
                ),
                data: (List<ChatMessage> list) {
                  if (list.isEmpty) {
                    return const HpEmptyState(
                      icon: Icons.forum_outlined,
                      title: 'Tell it something',
                      body: 'A symptom, a goal, what you had for lunch, or a '
                          'question about a value in your report. Anything you '
                          'say here shapes tomorrow’s plan.',
                    );
                  }
                  return ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(
                      HpSpacing.gutter,
                      HpSpacing.xl,
                      HpSpacing.gutter,
                      HpSpacing.xl,
                    ),
                    itemCount: list.length,
                    itemBuilder: (BuildContext context, int index) =>
                        _Bubble(message: list[index]),
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
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  IconButton(
                    icon: const Icon(Icons.attach_file_rounded),
                    tooltip: 'Attach a report or a photo',
                    onPressed: () {},
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
          if (at != null) ...<Widget>[
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

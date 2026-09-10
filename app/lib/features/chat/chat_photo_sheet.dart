import 'package:flutter/material.dart';

import '../../core/theme/hp_palette.dart';
import '../../core/theme/hp_spacing.dart';
import '../../core/theme/hp_typography.dart';
import '../../core/widgets/widgets.dart';
import 'chat_photo.dart';

/// What the sheet was closed with: which kind of photo, taken which way.
class ChatPhotoRequest {
  const ChatPhotoRequest(this.kind, this.source);

  final ChatPhotoKind kind;
  final ChatPhotoSource source;
}

/// Keys, so a test can tap one of four buttons that deliberately share two
/// labels. The labels are repeated because "Take a photo" is the right words in
/// both places; only the section above them differs.
const Key mealCameraKey = ValueKey<String>('chat-photo-meal-camera');
const Key mealGalleryKey = ValueKey<String>('chat-photo-meal-gallery');
const Key bodyCameraKey = ValueKey<String>('chat-photo-body-camera');
const Key bodyGalleryKey = ValueKey<String>('chat-photo-body-gallery');

/// Ask what this photograph is, before opening the camera.
///
/// **This question is the safety feature, not a piece of tidiness.** A picture
/// of somebody's dinner and a picture of somebody's rash arrive through the same
/// camera and have to be handled in opposite ways, and the only party who
/// reliably knows which is which is the person holding the phone. So the app
/// asks, in plain words, and it says next to each choice what will happen -
/// including, for a skin photo, that the AI will not be shown it. Nobody should
/// discover that after the fact.
///
/// Guessing instead would be worse in a specific direction: a photo of a rash
/// mistaken for food is a picture of somebody's body handed to a general-purpose
/// model with a prompt about lunch. There is no version of that we would want to
/// explain afterwards.
///
/// Returns null when the sheet was dismissed with a swipe.
Future<ChatPhotoRequest?> showChatPhotoSheet(BuildContext context) {
  return showModalBottomSheet<ChatPhotoRequest>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (BuildContext sheetContext) => const _ChatPhotoSheet(),
  );
}

class _ChatPhotoSheet extends StatelessWidget {
  const _ChatPhotoSheet();

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;

    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            HpSpacing.gutter,
            0,
            HpSpacing.gutter,
            HpSpacing.xxl,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Send a photo',
                style: HpType.headline.copyWith(color: p.ink),
              ),
              const SizedBox(height: HpSpacing.sm),
              Text(
                'What is the picture of? The two are handled differently, so it '
                'matters which you pick.',
                style: HpType.body.copyWith(color: p.inkMuted),
              ),
              const SizedBox(height: HpSpacing.xl),
              _Choice(
                icon: Icons.restaurant_outlined,
                kind: ChatPhotoKind.meal,
                body: 'I will look at what is on the plate, say what I can see, '
                    'and fold it into today’s eating. A packet or a menu works '
                    'too.',
                cameraKey: mealCameraKey,
                galleryKey: mealGalleryKey,
              ),
              const SizedBox(height: HpSpacing.lg),
              _Choice(
                icon: Icons.healing_outlined,
                kind: ChatPhotoKind.body,
                // The honest sentence, said before the camera opens rather than
                // after the answer disappoints somebody.
                body: 'I will keep this with your conversation, but I do not '
                    'read photos of skin and I will not say what something might '
                    'be — a picture cannot be examined the way a person can. '
                    'Tell me about it in words and I will ask the right '
                    'questions, and show the photo itself to a doctor.',
                cameraKey: bodyCameraKey,
                galleryKey: bodyGalleryKey,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Choice extends StatelessWidget {
  const _Choice({
    required this.icon,
    required this.kind,
    required this.body,
    required this.cameraKey,
    required this.galleryKey,
  });

  final IconData icon;
  final ChatPhotoKind kind;
  final String body;
  final Key cameraKey;
  final Key galleryKey;

  void _choose(BuildContext context, ChatPhotoSource source) {
    Navigator.of(context).pop(ChatPhotoRequest(kind, source));
  }

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;

    return Container(
      padding: const EdgeInsets.all(HpSpacing.lg),
      decoration: BoxDecoration(
        color: p.surface,
        border: Border.all(color: p.hairline),
        borderRadius: HpRadii.cardRadius,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(icon, size: 20, color: p.pineDeep),
              const SizedBox(width: HpSpacing.sm),
              Expanded(
                child: Text(
                  kind.choiceLabel,
                  style: HpType.bodyStrong.copyWith(color: p.ink),
                ),
              ),
            ],
          ),
          const SizedBox(height: HpSpacing.sm),
          Text(body, style: HpType.body.copyWith(color: p.inkMuted)),
          const SizedBox(height: HpSpacing.lg),
          // Wrap rather than Row: two buttons and their labels do not fit side
          // by side on a narrow phone, and a row that overflows is a yellow
          // stripe across somebody's screen.
          Wrap(
            spacing: HpSpacing.sm,
            runSpacing: HpSpacing.sm,
            children: <Widget>[
              HpButton(
                key: cameraKey,
                label: 'Take a photo',
                icon: Icons.photo_camera_outlined,
                expand: false,
                onPressed: () => _choose(context, ChatPhotoSource.camera),
              ),
              HpButton(
                key: galleryKey,
                label: 'From gallery',
                icon: Icons.photo_library_outlined,
                tone: HpButtonTone.secondary,
                expand: false,
                onPressed: () => _choose(context, ChatPhotoSource.gallery),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../../core/theme/hp_palette.dart';
import '../../core/theme/hp_spacing.dart';
import '../../core/theme/hp_typography.dart';

/// The "we are on it" bubble that sits under a message that has just been sent.
///
/// Why this exists at all: sending used to change nothing on the screen. The
/// backend calls Gemini, and the free hosting tier lets the machine fall asleep
/// between requests, so the wait is routinely several seconds — during which the
/// app looked frozen, and the natural thing to do with an app that looks frozen
/// is to send the same message again.
///
/// The wording is chosen carefully. This bubble may say that a *reply* is
/// coming; it must never suggest that a medical opinion is being formed, which
/// is the one promise this app does not get to make (see the safety charter in
/// `CLAUDE.md`). "Reading that" describes what is actually happening.
class ChatThinkingBubble extends StatefulWidget {
  const ChatThinkingBubble({super.key});

  /// Kept here so the screen and its tests refer to one string, not two copies
  /// of it that can drift apart.
  static const String label = 'Reading that — your reply is on its way';

  @override
  State<ChatThinkingBubble> createState() => _ChatThinkingBubbleState();
}

class _ChatThinkingBubbleState extends State<ChatThinkingBubble>
    with SingleTickerProviderStateMixin {
  /// One full pass of the wave. Slow enough to read as breathing rather than
  /// blinking: a health app that flickers reads as an unstable one.
  static const Duration _cycle = Duration(milliseconds: 1100);

  late final AnimationController _wave;

  @override
  void initState() {
    super.initState();
    _wave = AnimationController(vsync: this, duration: _cycle)..repeat();
  }

  @override
  void dispose() {
    // Disposing here is what stops the animation the moment the indicator leaves
    // the tree, which is the whole reason this is a widget with a lifecycle
    // rather than a loop somewhere. A ticker that outlives its widget keeps the
    // phone — and every widget test that runs after this one — awake for ever.
    _wave.dispose();
    super.dispose();
  }

  /// How bright dot [index] is at [t], a value running 0 to 1 through one cycle.
  ///
  /// Each dot lags the one before it by a sixth of a cycle, which is what makes
  /// the row read as one wave travelling left to right instead of three lights
  /// blinking together. Dart's `%` never returns a negative number for a
  /// positive divisor, so the lag wraps cleanly at the start of each cycle.
  static double _dotOpacity(double t, int index) {
    final double phase = (t - index * 0.16) % 1.0;
    final double rise = phase < 0.5 ? phase * 2 : 2 - phase * 2;
    return (0.28 + 0.72 * rise).clamp(0.0, 1.0).toDouble();
  }

  Widget _dot(HpPalette p, int index) {
    return Opacity(
      opacity: _dotOpacity(_wave.value, index),
      child: Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(color: p.pine, shape: BoxShape.circle),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;

    return Padding(
      padding: const EdgeInsets.only(bottom: HpSpacing.lg),
      child: Semantics(
        // A screen reader has no way to see three dots pulse, so the line under
        // the bubble is announced instead, once, when it appears.
        liveRegion: true,
        container: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: HpSpacing.lg,
                vertical: HpSpacing.lg,
              ),
              decoration: BoxDecoration(
                // The same shape the assistant's own bubbles use, so the answer
                // lands where the waiting was rather than somewhere new.
                color: p.surface,
                border: Border.all(color: p.hairline),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(HpRadii.card),
                  topRight: Radius.circular(HpRadii.card),
                  bottomLeft: Radius.circular(4),
                  bottomRight: Radius.circular(HpRadii.card),
                ),
              ),
              child: AnimatedBuilder(
                animation: _wave,
                builder: (BuildContext context, Widget? child) => Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    _dot(p, 0),
                    const SizedBox(width: HpSpacing.xs),
                    _dot(p, 1),
                    const SizedBox(width: HpSpacing.xs),
                    _dot(p, 2),
                  ],
                ),
              ),
            ),
            const SizedBox(height: HpSpacing.xs),
            Text(
              ChatThinkingBubble.label,
              style: HpType.micro.copyWith(color: p.inkFaint),
            ),
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../../core/theme/hp_palette.dart';
import '../../core/theme/hp_severity.dart';
import '../../core/theme/hp_spacing.dart';
import '../../core/theme/hp_typography.dart';
import '../../core/widgets/widgets.dart';

/// Where one sentence ends and the next begins.
///
/// A full stop, question mark or exclamation mark, optionally followed by a
/// closing quote or bracket, and then whitespace. Insisting on the whitespace
/// is what keeps "11.8 g/dL" in one piece: a full stop with a digit after it is
/// part of a number, not the end of a thought.
///
/// Spelled out with escapes rather than written as a raw string: two of the
/// closing characters are a curly apostrophe and a curly double quote, and a
/// pattern is easier to trust when nothing in it is a character you have to
/// squint at.
final RegExp _sentenceEnd = RegExp('[.!?]["\\u2019\\u201d)\\]]*\\s+');

/// Cut server-written health text into sentences, without losing a word of it.
///
/// This matters more here than anywhere else in the app. A focus note's body
/// and the plan rationale are generated text that has already been through the
/// server-side safety validator, so the app is allowed to *re-present* them and
/// is not allowed to edit them. Shortening a sentence, dropping the last one,
/// or paraphrasing would put words in front of the reader that nothing checked.
///
/// So this only ever cuts, and it only ever cuts at a sentence boundary. Every
/// character that came from the server is in exactly one of the pieces returned,
/// in its original order; the only thing dropped is the run of whitespace
/// between two sentences, which becomes the gap between two bullets. Text with
/// no boundary in it - one long sentence - comes back as a single piece and is
/// shown whole.
List<String> splitIntoSentences(String text) {
  final String whole = text.trim();
  if (whole.isEmpty) {
    return const <String>[];
  }

  final List<String> sentences = <String>[];
  int start = 0;
  for (final RegExpMatch match in _sentenceEnd.allMatches(whole)) {
    if (match.end <= start) {
      continue;
    }
    final String piece = whole.substring(start, match.end).trim();
    if (piece.isNotEmpty) {
      sentences.add(piece);
    }
    start = match.end;
  }
  if (start < whole.length) {
    final String tail = whole.substring(start).trim();
    if (tail.isNotEmpty) {
      sentences.add(tail);
    }
  }
  return sentences.isEmpty ? <String>[whole] : sentences;
}

/// A block of server-written text, arranged so it can be taken in at a glance.
///
/// The owner's complaint about this screen was blunt and correct: a paragraph
/// of health copy on a phone at seven in the morning does not get read. So the
/// first sentence is given the weight of a headline and the rest go behind
/// "More", one bullet per sentence.
///
/// Behind, never gone. Nothing is summarised and nothing is truncated - the
/// disclosure expands in place and the whole of what the server sent is one tap
/// away, which is the difference between presenting text differently and
/// editing it.
class ScannableBody extends StatefulWidget {
  const ScannableBody({super.key, required this.text});

  final String text;

  @override
  State<ScannableBody> createState() => _ScannableBodyState();
}

class _ScannableBodyState extends State<ScannableBody> {
  bool _open = false;

  @override
  void didUpdateWidget(ScannableBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A new day's text is a new thing to read, so it starts collapsed again
    // rather than showing the tail of yesterday's note expanded.
    if (oldWidget.text != widget.text) {
      _open = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    final List<String> sentences = splitIntoSentences(widget.text);

    // One sentence, or none to speak of: there is nothing to put behind a
    // disclosure, so show it as it came.
    if (sentences.length <= 1) {
      return Text(
        widget.text,
        style: HpType.reading.copyWith(color: p.ink),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          sentences.first,
          style: HpType.reading.copyWith(color: p.ink),
        ),
        if (_open) ...<Widget>[
          for (final String sentence in sentences.skip(1))
            _BulletLine(text: sentence),
        ],
        HpTextAction(
          label: _open ? 'Less' : 'More',
          icon: _open
              ? Icons.keyboard_arrow_up_rounded
              : Icons.keyboard_arrow_down_rounded,
          onPressed: () => setState(() => _open = !_open),
        ),
      ],
    );
  }
}

/// One sentence as a bullet.
///
/// The marker is a drawn dot rather than a character or an emoji. An emoji here
/// would have to mean something - and on a screen about lab values, a picture
/// that means something is a picture that can be read as a diagnosis.
class _BulletLine extends StatelessWidget {
  const _BulletLine({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    return Padding(
      padding: const EdgeInsets.only(top: HpSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            // Enough to sit on the first line's x-height rather than its top.
            padding: const EdgeInsets.only(top: 11, right: HpSpacing.sm),
            child: Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                color: p.inkFaint,
                shape: BoxShape.circle,
              ),
            ),
          ),
          Expanded(
            child: Text(
              text,
              style: HpType.reading.copyWith(color: p.inkMuted),
            ),
          ),
        ],
      ),
    );
  }
}

/// The contents of a "worth knowing" card: how serious, what it is about, and
/// what it says.
///
/// The order is the order the eye wants it in. The chip is a shape and a word
/// before it is a colour, so the weight of the thing lands first; the title is
/// short and specific; the body is scannable. Everything about the card is
/// designed to be answerable in two seconds and still be readable in full.
class ScannableNote extends StatelessWidget {
  const ScannableNote({
    super.key,
    required this.severity,
    required this.title,
    required this.body,
    this.chipLabel,
    this.action,
  });

  final HpSeverity severity;

  /// A more specific word than the severity's own. Keep it plain and
  /// non-clinical - it is read out as "Status: ..." by a screen reader.
  final String? chipLabel;

  final String title;

  /// Server-written text. Presented, never edited. See [splitIntoSentences].
  final String body;

  /// An optional action under the body, such as "See the value".
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        HpStatusChip(severity: severity, label: chipLabel, dense: true),
        const SizedBox(height: HpSpacing.md),
        Text(title, style: HpType.headline.copyWith(color: p.ink)),
        const SizedBox(height: HpSpacing.sm),
        ScannableBody(text: body),
        if (action != null) ...<Widget>[
          const SizedBox(height: HpSpacing.xs),
          action!,
        ],
      ],
    );
  }
}

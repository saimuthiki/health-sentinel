import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/hp_palette.dart';
import '../../core/theme/hp_spacing.dart';
import '../../core/theme/hp_typography.dart';
import '../../core/widgets/widgets.dart';
import '../../data/providers.dart';
import '../common/failure_copy.dart';

/// One amount of water somebody might actually have drunk.
@immutable
class HydrationAmount {
  const HydrationAmount({required this.label, required this.millilitres});

  /// Plain words: what the thing is, not a number.
  final String label;

  final double millilitres;

  /// The number, spelled out under the words, so the button says both.
  String get amountLabel => '${millilitres.round()} ml';
}

/// The three amounts on offer without asking.
///
/// They are deliberately different sizes rather than three near-identical ones:
/// a mouthful at your desk, an ordinary tumbler, and the bottle you carry. If
/// none of them is right, "Other amount" is there.
const List<HydrationAmount> hydrationAmounts = <HydrationAmount>[
  HydrationAmount(label: 'A sip', millilitres: 100),
  HydrationAmount(label: 'A glass', millilitres: 250),
  HydrationAmount(label: 'A bottle', millilitres: 500),
];

/// The water meter, and the ways of adding to it.
///
/// The old version had a single "Add a glass" button that always wrote 250 ml,
/// which meant the total on screen was not what anybody had drunk - it was a
/// count of taps multiplied by a guess. Since the point of the number is to be
/// true, the amount has to be the user's to say.
///
/// This is a stateful widget for one reason: a write to the backend takes time,
/// and during that time every button here has to be inert. Two taps on "A
/// glass" while the first is still in flight would log half a litre.
class HydrationControls extends ConsumerStatefulWidget {
  const HydrationControls({
    super.key,
    required this.loggedMl,
    required this.targetMl,
  });

  final double loggedMl;
  final double targetMl;

  @override
  ConsumerState<HydrationControls> createState() => _HydrationControlsState();
}

class _HydrationControlsState extends ConsumerState<HydrationControls> {
  /// The amount currently being written, or null when nothing is in flight.
  ///
  /// One field doing two jobs on purpose: it is the busy flag *and* the answer
  /// to "which button should be showing the spinner", so there is only one
  /// piece of state that can be left in the wrong position.
  double? _saving;

  Future<void> _log(double millilitres) async {
    if (_saving != null) {
      return;
    }
    // Taken before the await. After it, this widget may be gone, and reaching
    // through a dead `context` for the messenger is how a failure ends up
    // thrown instead of shown.
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    setState(() => _saving = millilitres);
    try {
      await ref.read(healthRepositoryProvider).logHydration(millilitres);
      if (mounted) {
        // The repository hands back the new total, but Today owns that number,
        // so refetch rather than hold a second copy of it here.
        ref.invalidate(todayProvider);
      }
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            explainFailure(
              error,
              fallback: 'That could not be saved just now. Try again in a '
                  'moment.',
            ),
          ),
        ),
      );
    } finally {
      // In the `finally`, never after the `try`: an exception would otherwise
      // skip the line that puts the button back, and a spinner that cannot
      // stop is indistinguishable from a dead app.
      if (mounted) {
        setState(() => _saving = null);
      }
    }
  }

  Future<void> _logOther() async {
    if (_saving != null) {
      return;
    }
    final double? millilitres = await showModalBottomSheet<double>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (BuildContext sheetContext) => const _OtherAmountSheet(),
    );
    if (millilitres == null || !mounted) {
      return;
    }
    await _log(millilitres);
  }

  @override
  Widget build(BuildContext context) {
    final bool busy = _saving != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        HpMeter(
          label: 'Water so far',
          value: widget.loggedMl,
          target: widget.targetMl,
          unit: 'ml',
          footnote: 'A glass every couple of hours is easier than catching up '
              'at night.',
        ),
        const SizedBox(height: HpSpacing.lg),
        // A Wrap rather than a Row: at a large text size, or on a narrow
        // phone, these fall onto a second line instead of overflowing.
        Wrap(
          spacing: HpSpacing.sm,
          runSpacing: HpSpacing.sm,
          children: <Widget>[
            for (final HydrationAmount amount in hydrationAmounts)
              _AmountPill(
                label: amount.label,
                detail: amount.amountLabel,
                busy: _saving == amount.millilitres,
                onTap: busy ? null : () => _log(amount.millilitres),
              ),
            _AmountPill(
              label: 'Other amount',
              busy: false,
              onTap: busy ? null : _logOther,
            ),
          ],
        ),
      ],
    );
  }
}

/// A small two-line button: the words on top, the millilitres underneath.
///
/// Not [HpButton], and the reason is width. Three amounts have to sit on one
/// line of a 360dp phone, and [HpButton] is the full-size action of a screen -
/// 52dp tall with 20dp of padding on each side - so three of them would stack
/// into a column three buttons deep for what is meant to be a quick tap. This
/// borrows the same surface, outline and radius so it still reads as one of the
/// app's buttons, and it keeps the 48dp target Android asks for.
class _AmountPill extends StatelessWidget {
  const _AmountPill({
    required this.label,
    required this.busy,
    required this.onTap,
    this.detail,
  });

  final String label;

  /// The amount in millilitres, written out. Null on "Other amount", where the
  /// number is the whole question.
  final String? detail;

  final bool busy;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    final bool enabled = onTap != null && !busy;
    final Color foreground = enabled ? p.pine : p.inkMuted;

    return Semantics(
      button: true,
      enabled: enabled,
      label: detail == null ? label : '$label, $detail',
      excludeSemantics: true,
      child: Material(
        color: enabled ? p.surface : p.surfaceSunk,
        borderRadius: HpRadii.fieldRadius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? onTap : null,
          child: Container(
            constraints:
                const BoxConstraints(minHeight: HpSpacing.minTapTarget),
            padding: const EdgeInsets.symmetric(
              horizontal: HpSpacing.md,
              vertical: HpSpacing.sm,
            ),
            decoration: BoxDecoration(
              borderRadius: HpRadii.fieldRadius,
              border: Border.all(color: enabled ? p.outline : p.hairline),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                if (busy)
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: foreground,
                    ),
                  )
                else
                  Text(
                    label,
                    style: HpType.label.copyWith(
                      color: foreground,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                if (detail != null) ...<Widget>[
                  const SizedBox(height: HpSpacing.xxs),
                  Text(
                    detail!,
                    style: HpType.micro.copyWith(color: p.inkFaint),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "Other amount": type it, or step to it.
///
/// Both ways in, because neither is right for everybody. Stepping suits the
/// person adding the same odd-sized bottle every day; typing suits the person
/// who knows it was 375. The sheet is deliberately short - one question, one
/// number, one button - so it can be answered without reading.
class _OtherAmountSheet extends StatefulWidget {
  const _OtherAmountSheet();

  @override
  State<_OtherAmountSheet> createState() => _OtherAmountSheetState();
}

class _OtherAmountSheetState extends State<_OtherAmountSheet> {
  /// One step of the plus and minus buttons.
  static const int _step = 50;

  /// The range the field will accept. The lower end stops an accidental "0 ml"
  /// write; the upper end stops a slipped finger turning 300 into 3000 and
  /// making the day's total nonsense.
  static const int _smallest = 50;
  static const int _largest = 2000;

  final TextEditingController _controller =
      TextEditingController(text: '300');

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// The number in the field, or null when it is empty or out of range.
  int? get _entered {
    final int? typed = int.tryParse(_controller.text.trim());
    if (typed == null || typed < _smallest || typed > _largest) {
      return null;
    }
    return typed;
  }

  void _nudge(int by) {
    int next = (_entered ?? 250) + by;
    if (next < _smallest) {
      next = _smallest;
    }
    if (next > _largest) {
      next = _largest;
    }
    _controller.text = next.toString();
    _controller.selection =
        TextSelection.collapsed(offset: _controller.text.length);
    setState(() {});
  }

  /// Hand the amount back to the card that opened this sheet.
  ///
  /// A method rather than a closure over the parsed number, so nothing has to
  /// reason about whether a nullable local is still known to be non-null once
  /// it is inside a callback.
  void _confirm() {
    final int? entered = _entered;
    if (entered == null) {
      return;
    }
    Navigator.of(context).pop(entered.toDouble());
  }

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;

    return Padding(
      // The keyboard covers the bottom of the sheet the moment the field is
      // tapped, and the button that finishes the job is at the bottom.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
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
                'How much did you drink?',
                style: HpType.headline.copyWith(color: p.ink),
              ),
              const SizedBox(height: HpSpacing.sm),
              Text(
                'It is added to today’s water total.',
                style: HpType.body.copyWith(color: p.inkMuted),
              ),
              const SizedBox(height: HpSpacing.xl),
              Row(
                children: <Widget>[
                  IconButton(
                    onPressed: () => _nudge(-_step),
                    icon: const Icon(Icons.remove_rounded),
                    tooltip: '$_step ml less',
                  ),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      textAlign: TextAlign.center,
                      keyboardType: TextInputType.number,
                      inputFormatters: <TextInputFormatter>[
                        FilteringTextInputFormatter.digitsOnly,
                      ],
                      style: HpType.figureSmall.copyWith(color: p.ink),
                      decoration: const InputDecoration(suffixText: 'ml'),
                      onChanged: (String _) => setState(() {}),
                    ),
                  ),
                  IconButton(
                    onPressed: () => _nudge(_step),
                    icon: const Icon(Icons.add_rounded),
                    tooltip: '$_step ml more',
                  ),
                ],
              ),
              const SizedBox(height: HpSpacing.sm),
              Text(
                'Anything from $_smallest ml to $_largest ml.',
                style: HpType.micro.copyWith(color: p.inkFaint),
              ),
              const SizedBox(height: HpSpacing.xl),
              HpButton(
                label: 'Add it',
                onPressed: _entered == null ? null : _confirm,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/hp_palette.dart';
import '../../core/theme/hp_spacing.dart';
import '../../core/theme/hp_typography.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/models.dart';
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

/// The water meter, the ways of adding to it, and the goal it is measured
/// against.
///
/// The old version had a single "Add a glass" button that always wrote 250 ml,
/// which meant the total on screen was not what anybody had drunk - it was a
/// count of taps multiplied by a guess. Since the point of the number is to be
/// true, the amount has to be the user's to say.
///
/// The goal is the user's to say too, and **everything about what is allowed is
/// the server's**. `backend/app/rules/daily_goals.py` decides the figure our
/// sources support, warns above the published intake range, refuses above its
/// ceiling, and gives no goal at all where fluid intake is a doctor's decision -
/// with the literature citations that justify each of those. This card sends a
/// number and renders the answer. It never composes a warning of its own, never
/// decides whether one is due, and never falls back to a default goal when the
/// server declines to give one: no goal means the reason and no bar.
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

  /// Millilitres logged today: the server's figure, plus anything this phone
  /// has not managed to send yet.
  final double loggedMl;

  /// The goal in force, or **null when the server will not give one**. Null is
  /// an answer, and it is drawn as one.
  final double? targetMl;

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

  /// True while a goal is being written.
  bool _settingGoal = false;

  /// The server's warning from the most recent successful set, or null when no
  /// goal has been set on this screen yet.
  ///
  /// Shown **verbatim** and never composed here. It is held separately from the
  /// briefing's own copy of it so that the warning appears the instant the
  /// server sends it, rather than a round trip later - and an empty string is a
  /// real answer meaning "there is nothing to say about this goal", which is why
  /// this is a nullable String and not an empty one.
  String? _cautionAfterSet;

  /// Why the last attempt to set a goal did not work, or null.
  ///
  /// Shown in the card rather than in a snackbar. A refusal from this endpoint
  /// is a paragraph with a citation in it, written for the person who typed the
  /// number, and four seconds at the bottom of the screen is not long enough to
  /// read one.
  String? _goalProblem;

  /// Nothing else may be tapped while anything here is being written.
  bool get _busy => _saving != null || _settingGoal;

  Future<void> _log(double millilitres) async {
    if (_busy) {
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
    if (_busy) {
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

  /// Ask for a goal, then write it.
  ///
  /// The sheet does not judge the number and neither does this. Anything above
  /// zero is sent, and what comes back - a goal, a goal with a warning, or a
  /// refusal with its reason - is the server's answer to show.
  Future<void> _setGoal() async {
    if (_busy) {
      return;
    }
    final _GoalChoice? choice = await showModalBottomSheet<_GoalChoice>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (BuildContext sheetContext) =>
          _GoalSheet(goal: _goalFrom(ref.read(todayProvider).valueOrNull)),
    );
    if (choice == null || !mounted) {
      return;
    }
    await _saveGoal(choice.millilitres);
  }

  Future<void> _saveGoal(int? millilitres) async {
    if (_settingGoal) {
      return;
    }
    setState(() {
      _settingGoal = true;
      // The last refusal is about the last number. It is not about this one.
      _goalProblem = null;
    });
    try {
      final HydrationGoal saved = await ref
          .read(healthRepositoryProvider)
          .setHydrationTarget(millilitres);
      if (mounted) {
        setState(() => _cautionAfterSet = saved.caution);
        // Today owns the goal as well as the total, so the card asks for the
        // day again rather than holding a second copy of either.
        ref.invalidate(todayProvider);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _goalProblem = explainFailure(
            error,
            fallback: 'Your goal could not be saved just now, so nothing has '
                'changed. Try again in a moment.',
          );
          // Whatever warning was on screen belonged to the goal that is still
          // in force; nothing was set, so nothing new is being warned about.
          _cautionAfterSet = null;
        });
      }
    } finally {
      // In the `finally`, never after the `try`. A spinner that cannot stop is
      // indistinguishable from a dead app.
      if (mounted) {
        setState(() => _settingGoal = false);
      }
    }
  }

  /// The goal to draw, and everything the server said about it.
  ///
  /// Today is the screen that fetches it, so the card reads the same briefing
  /// the screen around it is drawing rather than asking for the goal a second
  /// time. The Today screen hands down only the millilitres - it has done since
  /// before there was anything else to hand down - and that is the answer until
  /// the briefing lands, which is also what keeps this card drawable in a test
  /// that pumps it on its own.
  ///
  /// Passed a briefing rather than reading one, so the caller decides between
  /// `watch` in a build and `read` in a callback.
  HydrationGoal _goalFrom(TodayBriefing? briefing) =>
      briefing?.hydrationGoal ?? HydrationGoal(millilitres: widget.targetMl);

  @override
  Widget build(BuildContext context) {
    final bool busy = _busy;
    final HydrationGoal goal =
        _goalFrom(ref.watch(todayProvider).valueOrNull);
    final double? target = goal.millilitres;
    final double? sourced = goal.sourcedMillilitres;
    final String caution = (_cautionAfterSet ?? goal.caution).trim();
    final String? problem = _goalProblem;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (target != null)
          HpMeter(
            label: 'Water so far',
            value: widget.loggedMl,
            target: target,
            unit: 'ml',
            footnote: 'A glass every couple of hours is easier than catching up '
                'at night.',
          )
        else
          // No goal, so no bar, and never a default number in its place. The
          // reason is the server's own sentence.
          _NoGoalYet(loggedMl: widget.loggedMl, reason: goal.source),
        if (target != null && sourced != null && sourced != target) ...<Widget>[
          const SizedBox(height: HpSpacing.sm),
          _SourcedBeside(millilitres: sourced, chosen: goal.chosenByUser),
        ],
        if (caution.isNotEmpty) ...<Widget>[
          const SizedBox(height: HpSpacing.md),
          // Word for word as the server wrote it. It carries the references
          // behind it, and a version of it written here would be a second,
          // uncited copy of a clinical judgement.
          _GoalNote(text: caution, key: const ValueKey<String>('water-caution')),
        ],
        if (problem != null) ...<Widget>[
          const SizedBox(height: HpSpacing.md),
          _GoalNote(text: problem, key: const ValueKey<String>('water-refusal')),
        ],
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
        const SizedBox(height: HpSpacing.md),
        Align(
          alignment: Alignment.centerLeft,
          child: HpButton(
            label: goal.chosenByUser
                ? 'Change your water goal'
                : 'Set your own water goal',
            tone: HpButtonTone.quiet,
            expand: false,
            busy: _settingGoal,
            onPressed: busy ? null : _setGoal,
          ),
        ),
      ],
    );
  }
}

/// The water total when there is deliberately no goal to measure it against.
///
/// A figure and a sentence, and **no bar**. The sentence is the server's, and
/// it is the whole reason this widget exists: on a profile where fluid intake is
/// a doctor's decision, or in pregnancy, the honest answer is that we do not
/// hold a figure - and a bar filled against a number the app invented would be
/// the opposite of that answer.
class _NoGoalYet extends StatelessWidget {
  const _NoGoalYet({required this.loggedMl, required this.reason});

  final double loggedMl;
  final String reason;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    final String text = reason.trim();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                'Water so far',
                style: HpType.label.copyWith(color: p.inkMuted),
              ),
            ),
            Text(
              '${loggedMl.round()} ml',
              style: HpType.figureSmall.copyWith(color: p.ink, fontSize: 16),
            ),
          ],
        ),
        if (text.isNotEmpty) ...<Widget>[
          const SizedBox(height: HpSpacing.sm),
          Text(text, style: HpType.body.copyWith(color: p.inkMuted)),
        ],
      ],
    );
  }
}

/// The figure our sources support, kept beside the one the person chose.
///
/// Only the number comes from the server; the words around it are ours and say
/// nothing clinical. Showing it is the point: a goal somebody set for themselves
/// should not quietly replace the evidence, it should sit next to it.
class _SourcedBeside extends StatelessWidget {
  const _SourcedBeside({required this.millilitres, required this.chosen});

  final double millilitres;
  final bool chosen;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    return Text(
      chosen
          ? 'This is your own goal. Our sources support '
              '${millilitres.round()} ml a day for your profile.'
          : 'Our sources support ${millilitres.round()} ml a day for your '
              'profile.',
      style: HpType.micro.copyWith(color: p.inkFaint),
    );
  }
}

/// A block of the server's own text about the goal: its warning, or its refusal.
///
/// Rendered exactly as it arrived. Nothing here shortens it, rewrites it or
/// decides whether it was deserved.
class _GoalNote extends StatelessWidget {
  const _GoalNote({required this.text, super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(HpSpacing.md),
      decoration: BoxDecoration(
        color: p.attentionSoft,
        borderRadius: HpRadii.fieldRadius,
      ),
      child: Text(
        text,
        style: HpType.body.copyWith(color: p.attentionInk),
      ),
    );
  }
}

/// What the goal sheet hands back: a number, or a deliberate null.
///
/// A class rather than a bare `int?`, because the sheet has two different ways
/// of ending in nothing - "go back to the figure our sources support", which is
/// a null the server is meant to act on, and a swipe down, which is no answer at
/// all. Those must not be the same value.
@immutable
class _GoalChoice {
  const _GoalChoice(this.millilitres);

  /// The goal to set, or null to clear it and use the sourced figure.
  final int? millilitres;
}

/// "Set your own water goal": type it, save it, or go back to ours.
///
/// The one thing this sheet deliberately does **not** do is decide whether a
/// number is a good idea. It refuses an empty field and a zero, because those
/// are not numbers rather than because they are unwise, and sends everything
/// else. The envelope - warn here, refuse there, no goal at all for this profile
/// - is the server's, is written down with its references, and exists in one
/// place. A copy of it here would be a second opinion nobody could cite.
class _GoalSheet extends StatefulWidget {
  const _GoalSheet({required this.goal});

  final HydrationGoal goal;

  @override
  State<_GoalSheet> createState() => _GoalSheetState();
}

class _GoalSheetState extends State<_GoalSheet> {
  late final TextEditingController _controller =
      TextEditingController(text: _startingText(widget.goal.millilitres));

  /// The goal already in force, so changing it is an edit rather than a retype.
  /// Empty when there is not one.
  static String _startingText(double? millilitres) =>
      millilitres == null ? '' : millilitres.round().toString();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// The number in the field, or null when there is not one in it.
  int? get _entered {
    final int? typed = int.tryParse(_controller.text.trim());
    if (typed == null || typed <= 0) {
      return null;
    }
    return typed;
  }

  void _save() {
    final int? entered = _entered;
    if (entered == null) {
      return;
    }
    Navigator.of(context).pop(_GoalChoice(entered));
  }

  void _useOurs() {
    Navigator.of(context).pop(const _GoalChoice(null));
  }

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    final double? sourced = widget.goal.sourcedMillilitres;

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
                'Your daily water goal',
                style: HpType.headline.copyWith(color: p.ink),
              ),
              const SizedBox(height: HpSpacing.sm),
              Text(
                sourced == null
                    ? 'Tell us the amount you are aiming for each day.'
                    : 'Tell us the amount you are aiming for each day. Our '
                        'sources support ${sourced.round()} ml for your '
                        'profile.',
                style: HpType.body.copyWith(color: p.inkMuted),
              ),
              const SizedBox(height: HpSpacing.xl),
              TextField(
                controller: _controller,
                textAlign: TextAlign.center,
                keyboardType: TextInputType.number,
                inputFormatters: <TextInputFormatter>[
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(5),
                ],
                style: HpType.figureSmall.copyWith(color: p.ink),
                decoration: const InputDecoration(suffixText: 'ml'),
                onChanged: (String _) => setState(() {}),
              ),
              const SizedBox(height: HpSpacing.sm),
              Text(
                'We will tell you what is known about the amount you pick, and '
                'we will say so plainly if it is more than we will set a goal '
                'for.',
                style: HpType.micro.copyWith(color: p.inkFaint),
              ),
              const SizedBox(height: HpSpacing.xl),
              HpButton(
                label: 'Save this goal',
                onPressed: _entered == null ? null : _save,
              ),
              const SizedBox(height: HpSpacing.sm),
              HpButton(
                label: 'Use the figure our sources support',
                tone: HpButtonTone.quiet,
                onPressed: _useOurs,
              ),
            ],
          ),
        ),
      ),
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

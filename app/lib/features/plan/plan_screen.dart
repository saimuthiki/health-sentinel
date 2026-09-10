import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format/hp_format.dart';
import '../../core/theme/hp_palette.dart';
import '../../core/theme/hp_spacing.dart';
import '../../core/theme/hp_typography.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/models.dart';
import '../../data/providers.dart';
import '../../data/repository/health_repository.dart';
import '../common/failure_copy.dart';

/// Today's plan, meal by meal, with the reason each thing is there.
///
/// The reason is not a nice-to-have. A plan you cannot argue with is a plan you
/// stop trusting, so every item carries the sentence that explains it, and the
/// nutrient numbers underneath come from the foods table rather than from
/// anything a model asserted.
///
/// The screen used to lay a meal out as a run of full-width cards, one per
/// option, under a thin heading. The owner read that as a list of instructions
/// and thought he was meant to eat all of them, before working out for himself
/// that they were alternatives. A layout you have to work out is a layout that
/// is wrong, so each meal is now **one** bounded panel with its options nested
/// visibly inside it, and the panel says in words when there is a choice.
class PlanScreen extends ConsumerWidget {
  const PlanScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<MealPlan> plan = ref.watch(planProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Plan')),
      body: SafeArea(
        bottom: false,
        child: Column(
          children: <Widget>[
            Expanded(
              child: plan.when(
                loading: () => const HpLoadingState(
                  message: 'Putting today’s plan together',
                ),
                error: (Object error, StackTrace stack) => HpErrorState(
                  title: 'The plan could not be loaded',
                  body: explainFailure(
                    error,
                    fallback: 'The app could not reach the health engine. '
                        'Yesterday’s plan is still in Today.',
                  ),
                  onRetry: () => ref.invalidate(planProvider),
                ),
                data: (MealPlan data) => _Body(plan: data),
              ),
            ),
            // Not dismissible, by product requirement.
            const HpDisclaimer(),
          ],
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.plan});

  final MealPlan plan;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    final String? rationale = plan.rationale;

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        HpSpacing.gutter,
        HpSpacing.lg,
        HpSpacing.gutter,
        HpSpacing.section,
      ),
      children: <Widget>[
        Text(
          HpFormat.relativeDay(plan.planDate),
          style: HpType.display.copyWith(color: p.ink),
        ),
        const SizedBox(height: HpSpacing.xs),
        Text(
          HpFormat.dayFull(plan.planDate),
          style: HpType.label.copyWith(color: p.inkFaint),
        ),
        if (rationale != null) ...<Widget>[
          const SizedBox(height: HpSpacing.xl),
          _RationaleCard(rationale: rationale),
        ],
        const SizedBox(height: HpSpacing.section),
        // One panel per meal, in the order the day happens. A slot with nothing
        // in it is left out rather than shown empty: a heading over nothing
        // reads as something that failed to load.
        for (final MealSlot slot in MealSlot.values)
          if (plan.itemsFor(slot).isNotEmpty) ...<Widget>[
            _SlotSection(
              // Keyed by the slot, so that which meal you chose from stays
              // attached to that meal if the plan is reloaded and the list of
              // meals comes back a different length.
              key: ValueKey<String>('slot-${slot.wire}'),
              planId: plan.id,
              slot: slot,
              items: plan.itemsFor(slot),
            ),
            const SizedBox(height: HpSpacing.lg),
          ],
        const SizedBox(height: HpSpacing.md),
        HpSectionHeader(
          title: 'Day totals',
          note: 'from the foods table',
        ),
        _TotalsCard(plan: plan),
      ],
    );
  }
}

/// "What changed, and why", with a strong opening line and the rest on request.
///
/// The owner's honest verdict on a paragraph inside a plan is that he will not
/// read it, so the first sentence carries the point and the remainder waits
/// behind "More". What this must never do is lose any of it: [MealPlan]'s
/// rationale is server-generated health text that has already been through the
/// safety validator, so this widget only re-presents it. Nothing is summarised,
/// re-worded or cut — expanding shows the original, opening and remainder,
/// character for character.
class _RationaleCard extends StatefulWidget {
  const _RationaleCard({required this.rationale});

  final String rationale;

  @override
  State<_RationaleCard> createState() => _RationaleCardState();
}

class _RationaleCardState extends State<_RationaleCard> {
  bool _expanded = false;

  /// Where the first sentence ends, or the end of the text when there is only
  /// one. The split looks for a full stop *followed by a space*, so a decimal
  /// inside a number — "11.8 g/dL" — is not mistaken for the end of a sentence.
  static int _firstSentenceEnd(String text) {
    final int stop = text.indexOf('. ');
    if (stop < 0) {
      return text.length;
    }
    return stop + 1;
  }

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    final String text = widget.rationale.trim();
    final int end = _firstSentenceEnd(text);
    final String opening = text.substring(0, end);
    final String remainder = text.substring(end);
    final bool hasMore = remainder.trim().isNotEmpty;

    return HpCard(
      tone: HpCardTone.tinted,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'What changed, and why',
            style: HpType.bodyStrong.copyWith(color: p.ink),
          ),
          const SizedBox(height: HpSpacing.sm),
          if (hasMore && _expanded)
            // One Text, two runs. Joining the halves as spans rather than as
            // two widgets is what keeps the space between the sentences: end to
            // end, these are the original string exactly.
            Text.rich(
              TextSpan(
                children: <InlineSpan>[
                  TextSpan(
                    text: opening,
                    style: HpType.reading.copyWith(
                      color: p.ink,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  TextSpan(
                    text: remainder,
                    style: HpType.reading.copyWith(color: p.inkMuted),
                  ),
                ],
              ),
            )
          else
            Text(
              opening,
              style: HpType.reading.copyWith(
                color: p.ink,
                fontWeight: FontWeight.w600,
              ),
            ),
          if (hasMore) ...<Widget>[
            const SizedBox(height: HpSpacing.sm),
            Align(
              alignment: Alignment.centerLeft,
              child: HpTextAction(
                label: _expanded ? 'Less' : 'More',
                icon: _expanded
                    ? Icons.keyboard_arrow_up_rounded
                    : Icons.keyboard_arrow_down_rounded,
                onPressed: () => setState(() => _expanded = !_expanded),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// How one option sits against the rest of its meal.
enum _OptionState {
  /// Nothing in this meal has been chosen yet.
  open,

  /// This is the one that was eaten.
  chosen,

  /// Something else in this meal was eaten.
  passedOver,
}

/// One meal: a bounded panel with its options nested inside it.
///
/// The panel is [HpCardTone.tinted] and the options inside it are ordinary
/// raised cards. That is the design system's own grammar rather than a new
/// invention: a raised surface means "something you can act on", which each
/// option is, and a quiet tint underneath is grouping, which is what a meal is.
/// A raised card inside a raised card would have read as two things of equal
/// weight, which is the confusion this screen exists to fix.
class _SlotSection extends ConsumerStatefulWidget {
  const _SlotSection({
    super.key,
    required this.planId,
    required this.slot,
    required this.items,
  });

  final String planId;
  final MealSlot slot;
  final List<MealPlanItem> items;

  @override
  ConsumerState<_SlotSection> createState() => _SlotSectionState();
}

class _SlotSectionState extends ConsumerState<_SlotSection> {
  /// The option that was eaten, or null while nothing has been said.
  ///
  /// It lives here, for as long as this screen is open, and is deliberately not
  /// read back from the server: no endpoint returns what was marked, and
  /// deciding on the phone what somebody ate would be inventing it.
  String? _chosenId;

  /// The option whose call is in flight, or null. One at a time for the whole
  /// meal, so two buttons in the same panel can never race each other.
  String? _busyItemId;

  /// The last refusal, in our own words.
  String? _error;

  /// Say what was eaten and, when the answer changes, unsay the last one.
  ///
  /// Three things happen here and each is deliberate.
  ///
  /// **It cannot fire twice.** A second tap while a call is in flight returns
  /// immediately, and the busy flag is cleared in a `finally`, so no path out
  /// of here — a refusal, a timeout while the free host wakes, a bug below —
  /// can leave a button spinning for ever. A missing `finally` on the consent
  /// screen once locked the owner out of his own account.
  ///
  /// **Changing your mind is a correction, not an addition.** Choosing a
  /// different option first marks the previous one skipped, because leaving it
  /// marked done would tell the learning loop he ate both. Tapping the chosen
  /// option again undoes it the same way, which is what makes this reversible.
  /// The correction is sent first: if the second call then fails, the worst
  /// this leaves behind is nothing marked, never two things marked eaten.
  ///
  /// **The panel only claims what actually landed.** [_chosenId] is set from a
  /// local that each step updates after its own call has returned, so a
  /// sequence that fails half way through still shows the truth.
  Future<void> _choose(MealPlanItem item) async {
    if (_busyItemId != null) {
      return;
    }
    final String? previous = _chosenId;
    final bool undo = previous == item.id;

    setState(() {
      _busyItemId = item.id;
      _error = null;
    });

    String? chosen = previous;
    String? failure;
    try {
      final HealthRepository repository = ref.read(healthRepositoryProvider);
      if (undo) {
        await repository.markPlanItem(
          planId: widget.planId,
          itemId: item.id,
          done: false,
        );
        chosen = null;
      } else {
        if (previous != null) {
          await repository.markPlanItem(
            planId: widget.planId,
            itemId: previous,
            done: false,
          );
          chosen = null;
        }
        await repository.markPlanItem(
          planId: widget.planId,
          itemId: item.id,
          done: true,
        );
        chosen = item.id;
      }
    } catch (error) {
      failure = explainFailure(
        error,
        fallback: 'That could not be saved just now. Nothing was lost — try '
            'again in a moment.',
      );
    } finally {
      if (mounted) {
        setState(() {
          _busyItemId = null;
          _error = failure;
          _chosenId = chosen;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    final List<MealPlanItem> items = widget.items;
    final String? chosenId = _chosenId;
    final String? error = _error;

    // Said in words, because the layout on its own is what he had to work out.
    // With a single item there is nothing to choose, and telling somebody to
    // pick one of one would simply be untrue.
    final String countLine = items.length == 1
        ? 'One thing to eat'
        : '${items.length} options — pick one, not all of them';

    return HpCard(
      key: ValueKey<String>('meal-slot-${widget.slot.wire}'),
      tone: HpCardTone.tinted,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    widget.slot.label,
                    style: HpType.headline.copyWith(color: p.ink),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const SizedBox(width: HpSpacing.md),
              Text(
                HpFormat.clockLabel(
                  items.first.timeOfDay ?? widget.slot.defaultTime,
                ),
                style: HpType.label.copyWith(color: p.inkFaint),
              ),
            ],
          ),
          const SizedBox(height: HpSpacing.xxs),
          Text(countLine, style: HpType.micro.copyWith(color: p.inkFaint)),
          const SizedBox(height: HpSpacing.lg),
          for (int i = 0; i < items.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(height: HpSpacing.md),
            _MealOption(
              item: items[i],
              state: chosenId == null
                  ? _OptionState.open
                  : chosenId == items[i].id
                      ? _OptionState.chosen
                      : _OptionState.passedOver,
              busy: _busyItemId == items[i].id,
              // Every button in the meal goes quiet while any one of them is
              // working, which is what stops a second tap posting twice.
              onPressed: _busyItemId == null ? () => _choose(items[i]) : null,
            ),
          ],
          if (error != null) ...<Widget>[
            const SizedBox(height: HpSpacing.md),
            Semantics(
              liveRegion: true,
              container: true,
              child: Text(
                error,
                style: HpType.label.copyWith(color: p.urgentInk),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One option inside a meal: what it is, what it brings, and why it is here.
class _MealOption extends StatelessWidget {
  const _MealOption({
    required this.item,
    required this.state,
    required this.busy,
    required this.onPressed,
  });

  final MealPlanItem item;
  final _OptionState state;

  /// This option's own call is in flight.
  final bool busy;

  /// Null while the meal is busy, which is how the button disables itself.
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    final bool chosen = state == _OptionState.chosen;
    final bool passedOver = state == _OptionState.passedOver;

    String action = 'I ate this';
    if (chosen) {
      action = 'Undo';
    } else if (passedOver) {
      action = 'I ate this instead';
    }

    // What was not chosen is dimmed by dropping its title to the muted ink and
    // by losing its shadow — not by fading the whole card. An Opacity over body
    // text takes it below the contrast this app promises, and somebody
    // re-reading what they turned down is exactly who that would fail. In dark
    // mode there is no shadow to lose, so the filled tick against the empty
    // circle below carries the difference: shape, not only colour. Nothing is
    // hidden either — changing your mind stays one tap away.
    return HpCard(
      key: ValueKey<String>('meal-option-${item.id}'),
      tone: passedOver ? HpCardTone.flat : HpCardTone.raised,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Text(
                  item.title,
                  style: HpType.headline.copyWith(
                    color: passedOver ? p.inkMuted : p.ink,
                  ),
                ),
              ),
              if (item.kcal != null) ...<Widget>[
                const SizedBox(width: HpSpacing.md),
                Text(
                  '${HpFormat.number(item.kcal!, decimals: 0)} kcal',
                  style: HpType.figureSmall.copyWith(color: p.inkMuted),
                ),
              ],
            ],
          ),
          if (item.portion != null) ...<Widget>[
            const SizedBox(height: HpSpacing.xxs),
            Text(
              item.portion!,
              style: HpType.label.copyWith(color: p.inkFaint),
            ),
          ],
          if (item.whyText != null) ...<Widget>[
            const SizedBox(height: HpSpacing.md),
            Text(
              item.whyText!,
              style: HpType.reading.copyWith(color: p.inkMuted),
            ),
          ],
          if (chosen || passedOver) ...<Widget>[
            const SizedBox(height: HpSpacing.md),
            Row(
              children: <Widget>[
                Icon(
                  chosen
                      ? Icons.check_circle_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 18,
                  color: chosen ? p.pine : p.inkFaint,
                ),
                const SizedBox(width: HpSpacing.sm),
                Flexible(
                  child: Text(
                    chosen ? 'You ate this' : 'Not this one',
                    style: HpType.label.copyWith(
                      color: chosen ? p.pineDeep : p.inkFaint,
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: HpSpacing.lg),
          // There is no "Swap" button any more, and its absence is the point.
          // Nothing in the API can swap one item: the only thing on offer is
          // POST /v1/plan/regenerate, which rebuilds the whole day and would
          // throw away every other meal to change one. A button that cannot do
          // what it says is worse than no button — and now that the
          // alternatives sit together in this panel, swapping *is* tapping a
          // different one, which needs no control of its own.
          HpButton(
            label: action,
            tone: chosen ? HpButtonTone.quiet : HpButtonTone.secondary,
            busy: busy,
            onPressed: onPressed,
          ),
        ],
      ),
    );
  }
}

class _TotalsCard extends StatelessWidget {
  const _TotalsCard({required this.plan});

  final MealPlan plan;

  static const Map<String, String> _labels = <String, String>{
    'kcal': 'Energy',
    'protein_g': 'Protein',
    'fibre_g': 'Fibre',
    'iron_mg': 'Iron',
    'calcium_mg': 'Calcium',
    'vitamin_d_ug': 'Vitamin D',
  };

  static const Map<String, String> _units = <String, String>{
    'kcal': 'kcal',
    'protein_g': 'g',
    'fibre_g': 'g',
    'iron_mg': 'mg',
    'calcium_mg': 'mg',
    'vitamin_d_ug': 'µg',
  };

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;

    return HpCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (final String key in _labels.keys)
            if (plan.dayNutrients.containsKey(key)) ...<Widget>[
              HpMeter(
                label: _labels[key] ?? key,
                value: plan.dayNutrients[key] ?? 0,
                target: plan.targets[key] ?? 0,
                unit: _units[key] ?? '',
              ),
              const SizedBox(height: HpSpacing.lg),
            ],
          Text(
            'Targets come from the ICMR-NIN 2020 tables for your age, sex and '
            'activity level. Nutrient amounts are recalculated from our food '
            'database, not estimated.',
            style: HpType.micro.copyWith(color: p.inkFaint),
          ),
        ],
      ),
    );
  }
}

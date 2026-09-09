import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format/hp_format.dart';
import '../../core/theme/hp_palette.dart';
import '../../core/theme/hp_spacing.dart';
import '../../core/theme/hp_typography.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/models.dart';
import '../../data/providers.dart';

/// Today's plan, meal by meal, with the reason each thing is there.
///
/// The reason is not a nice-to-have. A plan you cannot argue with is a plan you
/// stop trusting, so every item carries the sentence that explains it, and the
/// nutrient numbers underneath come from the foods table rather than from
/// anything a model asserted.
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
                  body: 'The app could not reach the health engine. Yesterday’s '
                      'plan is still in Today.',
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
  const _Body({super.key, required this.plan});

  final MealPlan plan;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;

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
        if (plan.rationale != null) ...<Widget>[
          const SizedBox(height: HpSpacing.xl),
          HpCard(
            tone: HpCardTone.tinted,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'What changed, and why',
                  style: HpType.bodyStrong.copyWith(color: p.ink),
                ),
                const SizedBox(height: HpSpacing.sm),
                Text(
                  plan.rationale!,
                  style: HpType.reading.copyWith(color: p.inkMuted),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: HpSpacing.section),
        for (final MealSlot slot in MealSlot.values)
          if (plan.itemsFor(slot).isNotEmpty) ...<Widget>[
            HpSectionHeader(
              title: slot.label,
              note: HpFormat.clockLabel(
                plan.itemsFor(slot).first.timeOfDay ?? slot.defaultTime,
              ),
            ),
            for (final MealPlanItem item in plan.itemsFor(slot)) ...<Widget>[
              _MealCard(item: item),
              const SizedBox(height: HpSpacing.md),
            ],
            const SizedBox(height: HpSpacing.xl),
          ],
        HpSectionHeader(
          title: 'Day totals',
          note: 'from the foods table',
        ),
        _TotalsCard(plan: plan),
      ],
    );
  }
}

class _MealCard extends StatelessWidget {
  const _MealCard({super.key, required this.item});

  final MealPlanItem item;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;

    return HpCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Text(
                  item.title,
                  style: HpType.headline.copyWith(color: p.ink),
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
          const SizedBox(height: HpSpacing.lg),
          Row(
            children: <Widget>[
              Expanded(
                child: HpButton(
                  label: 'I ate this',
                  tone: HpButtonTone.secondary,
                  onPressed: () {},
                ),
              ),
              const SizedBox(width: HpSpacing.md),
              HpTextAction(label: 'Swap', onPressed: () {}),
            ],
          ),
        ],
      ),
    );
  }
}

class _TotalsCard extends StatelessWidget {
  const _TotalsCard({super.key, required this.plan});

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

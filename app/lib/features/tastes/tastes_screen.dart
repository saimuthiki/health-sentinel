import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/hp_palette.dart';
import '../../core/theme/hp_spacing.dart';
import '../../core/theme/hp_typography.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/models.dart';
import '../../data/providers.dart';
import '../../data/repository/health_repository.dart';
import '../common/failure_copy.dart';
import 'taste_choice.dart';

/// Everything this app believes about what you like to eat, and one tap to
/// change any of it.
///
/// **This screen exists because the belief is otherwise invisible.** A food you
/// said you did not like is dropped by the planner silently — it simply stops
/// appearing — so without a list, the only evidence that anything was learned is
/// a plan that quietly changed. That is the worst of both: a person who cannot
/// tell whether the app is listening, and cannot correct it when it has
/// misheard. A belief nobody can see or correct is worse than no belief at all.
///
/// **A correction here is not a meal.** It goes to
/// `PUT /v1/feedback/preferences/{food_id}`, which moves the preference and
/// touches the food diary not at all. That matters: the day's intake is summed
/// from logged meals, so if changing your mind about soya required logging soya,
/// every correction would add a portion of it to today and pull tomorrow's plan
/// out of shape.
///
/// **There is no way to delete a row, and none is needed.** "It was okay" is
/// neutral, which the planner's filter does not act on and its ranking gives
/// nothing to — a genuine "forget I said anything", reached by the same three
/// buttons as everything else rather than by a fourth control that behaves
/// differently.
///
/// **A refusal belongs to the row it happened on.** Each food keeps its own busy
/// flag and its own sentence, so correcting several things quickly works and one
/// that fails says so where it failed instead of putting a red line across a
/// list that is otherwise fine.
class TastesScreen extends ConsumerStatefulWidget {
  const TastesScreen({super.key});

  @override
  ConsumerState<TastesScreen> createState() => _TastesScreenState();
}

class _TastesScreenState extends ConsumerState<TastesScreen> {
  /// Rows corrected in this session, by food id.
  ///
  /// Held over the fetched list rather than refetching the whole thing after
  /// every tap: one correction is not a reason to make somebody watch the list
  /// they are working through reload underneath them.
  final Map<String, TasteStance> _corrected = <String, TasteStance>{};

  /// The answer each row is waiting on, by food id.
  ///
  /// The pending *stance* and not just a flag, so the spinner sits on the chip
  /// that was actually pressed rather than on the one that happens to be
  /// selected. A map rather than a single id, because correcting three things
  /// one after another is the ordinary way this screen is used: each row is its
  /// own call, its own spinner and its own guard.
  final Map<String, TasteStance> _busy = <String, TasteStance>{};

  /// Why one row's last change did not happen, by food id.
  final Map<String, String> _failures = <String, String>{};

  Future<void> _set(FoodPreference food, TasteStance stance) async {
    if (_busy.containsKey(food.foodId)) {
      return;
    }
    setState(() {
      _busy[food.foodId] = stance;
      _failures.remove(food.foodId);
    });

    TasteStance? landed;
    String? failure;
    try {
      final HealthRepository repository = ref.read(healthRepositoryProvider);
      final FoodPreference saved = await repository.setFoodPreference(
        foodId: food.foodId,
        stance: stance,
      );
      // What came back, not what was tapped. The server decides where the line
      // between liked, neutral and disliked falls, and this screen shows its
      // answer rather than predicting it.
      landed = saved.stance;
    } catch (error) {
      failure = explainFailure(
        error,
        fallback: 'That could not be saved just now. Nothing was lost — try '
            'again in a moment.',
      );
    } finally {
      // In a `finally`, so no refusal, timeout or bug below can leave a row
      // spinning for ever.
      // Written in the enclosing body, not inside the `setState` closure: a
      // local is only promoted to non-null out here, and both maps hold
      // non-nullable values.
      if (mounted) {
        if (failure != null) {
          _failures[food.foodId] = failure;
        }
        if (landed != null) {
          _corrected[food.foodId] = landed;
        }
        setState(() {
          _busy.remove(food.foodId);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<FoodPreference>> preferences =
        ref.watch(foodPreferencesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Food you like')),
      body: SafeArea(
        bottom: false,
        child: preferences.when(
          loading: () => const HpLoadingState(
            message: 'Looking up what we have learned',
          ),
          error: (Object error, StackTrace stack) => HpErrorState(
            title: 'That list could not be loaded',
            body: explainFailure(
              error,
              fallback: 'The app could not reach the health engine. Nothing '
                  'you have told us has been lost.',
            ),
            onRetry: () => ref.invalidate(foodPreferencesProvider),
          ),
          data: _list,
        ),
      ),
    );
  }

  Widget _list(List<FoodPreference> fetched) {
    final HpPalette p = context.hp;

    if (fetched.isEmpty) {
      return const HpEmptyState(
        icon: Icons.restaurant_outlined,
        title: 'Nothing learned yet',
        // Says which kind of empty this is. "No preferences" on its own reads
        // like something that failed to load.
        body: 'When you mark a meal as eaten on the Plan tab we will ask '
            'whether you enjoyed it. Every answer you give shows up here, and '
            'you can change any of them.',
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        HpSpacing.gutter,
        HpSpacing.lg,
        HpSpacing.gutter,
        HpSpacing.section,
      ),
      children: <Widget>[
        Text(
          'These are the foods we take into account when we put a day '
          'together. Change any of them and the next plan will follow.',
          style: HpType.reading.copyWith(color: p.inkMuted),
        ),
        const SizedBox(height: HpSpacing.lg),
        for (final FoodPreference food in fetched) ...<Widget>[
          _TasteRow(
            food: food,
            // The corrected answer wins over the fetched one, so a row shows
            // what this session actually saved rather than what was true when
            // the screen opened.
            stance: _corrected[food.foodId] ?? food.stance,
            busyStance: _busy[food.foodId],
            failure: _failures[food.foodId],
            onTaste: (TasteStance stance) => _set(food, stance),
          ),
          const SizedBox(height: HpSpacing.md),
        ],
        const SizedBox(height: HpSpacing.sm),
        Text(
          '“It was okay” is how you take a food back out of this: it stops '
          'counting either way, and we go back to suggesting it as often as '
          'anything else.',
          style: HpType.micro.copyWith(color: p.inkFaint),
        ),
      ],
    );
  }
}

/// One food, what we believe about it, and the three answers.
class _TasteRow extends StatelessWidget {
  const _TasteRow({
    required this.food,
    required this.stance,
    required this.busyStance,
    required this.failure,
    required this.onTaste,
  });

  final FoodPreference food;

  /// What we believe right now — the corrected answer if there is one, else the
  /// one that was fetched.
  final TasteStance stance;

  /// The answer this row is waiting on, or null when nothing is in flight.
  final TasteStance? busyStance;

  final String? failure;
  final void Function(TasteStance stance) onTaste;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    final String? refusal = failure;

    return HpCard(
      key: ValueKey<String>('taste-row-${food.foodId}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            food.name,
            style: HpType.bodyStrong.copyWith(color: p.ink),
          ),
          const SizedBox(height: HpSpacing.xxs),
          // What this belief does to the plan, in the same words the plan card
          // uses when the answer is first given. Only a plan claim: never a
          // sentence about what the food does to a person.
          Text(
            stance.effect,
            style: HpType.micro.copyWith(color: p.inkFaint),
          ),
          const SizedBox(height: HpSpacing.md),
          TasteChoiceRow(
            keyPrefix: food.foodId,
            selected: stance,
            busyStance: busyStance,
            // Every chip on this row goes quiet while the row is working, which
            // is what stops a second tap sending a second correction.
            onTaste: busyStance == null ? onTaste : null,
          ),
          if (refusal != null) ...<Widget>[
            const SizedBox(height: HpSpacing.sm),
            Semantics(
              liveRegion: true,
              container: true,
              child: Text(
                refusal,
                style: HpType.label.copyWith(color: p.urgentInk),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

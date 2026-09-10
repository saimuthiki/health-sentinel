import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format/hp_format.dart';
import '../../core/theme/hp_palette.dart';
import '../../core/theme/hp_spacing.dart';
import '../../core/theme/hp_typography.dart';
import '../../core/widgets/widgets.dart';
import '../common/failure_copy.dart';
import 'recipe_service.dart';

/// How to make one meal from the plan, and how much of it to have.
///
/// The owner asked for two things at once — "how to make a dish, and how much to
/// have" — and they come from two different places, which is the whole shape of
/// this screen.
///
/// **The amount is at the top, and it is the plan's.** It is read off the stored
/// plan row on the server: the same row the plan's nutrition was computed from.
/// The method below it carries no amounts at all, because the backend refuses a
/// method that does. So there is exactly one quantity on this screen and nothing
/// on it can contradict the Plan tab. The sentence explaining that is the
/// backend's and is shown rather than paraphrased.
///
/// **Some items have no method, and that is an answer rather than a gap.** A
/// packet of sunflower seeds needs buying, not cooking — the owner said so
/// himself — and this screen says exactly that, in a sentence, with the portion
/// still answered. No spinner, no model call, no four condescending steps for
/// opening a packet.
///
/// **A method we could not write is said out loud.** Not an empty list under a
/// heading, which reads as a bug: a sentence, and a way to ask again.
class RecipeScreen extends ConsumerStatefulWidget {
  const RecipeScreen({
    super.key,
    required this.itemId,
    required this.planDate,
  });

  /// The `meal_plan_items` row this recipe is for.
  final String itemId;

  /// The plan's date. Sent with the request, because a plan item is addressed
  /// through the day it belongs to.
  final DateTime planDate;

  @override
  ConsumerState<RecipeScreen> createState() => _RecipeScreenState();
}

class _RecipeScreenState extends ConsumerState<RecipeScreen> {
  Recipe? _recipe;

  bool _loading = true;

  /// True while a deliberate rewrite is in flight.
  bool _refreshing = false;

  String? _loadFailure;
  String? _refreshFailure;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final RecipeService? service = ref.read(recipeServiceProvider);
    setState(() {
      _loading = true;
      _loadFailure = null;
    });

    Recipe? fetched;
    String? failure;
    try {
      if (service == null) {
        throw const _NoBackend();
      }
      fetched = await service.load(
        itemId: widget.itemId,
        on: widget.planDate,
      );
    } catch (error) {
      failure = error is _NoBackend
          ? _noBackendMessage
          : explainFailure(
              error,
              fallback: 'This recipe could not be fetched just now. Nothing has '
                  'changed — try again in a moment.',
            );
    } finally {
      // In a `finally`, so a thrown failure cannot leave the screen spinning.
      final Recipe? recipe = fetched;
      final String? message = failure;
      if (mounted) {
        setState(() {
          _loading = false;
          _loadFailure = message;
          if (recipe != null) {
            _recipe = recipe;
            _refreshFailure = null;
          }
        });
      }
    }
  }

  /// Ask for the method to be written again.
  ///
  /// A dish is generated once and stored, so this is the only way to get a new
  /// one — and the guard against a second tap is here rather than on a disabled
  /// button, so a slow rewrite cannot become two.
  Future<void> _refresh() async {
    if (_refreshing) {
      return;
    }
    final RecipeService? service = ref.read(recipeServiceProvider);
    setState(() {
      _refreshing = true;
      _refreshFailure = null;
    });

    Recipe? fetched;
    String? failure;
    try {
      if (service == null) {
        throw const _NoBackend();
      }
      fetched = await service.refresh(
        itemId: widget.itemId,
        on: widget.planDate,
      );
    } catch (error) {
      failure = error is _NoBackend
          ? _noBackendMessage
          : explainFailure(
              error,
              fallback: 'That could not be written again just now. What is on '
                  'screen is still what we have — try again in a moment.',
            );
    } finally {
      final Recipe? recipe = fetched;
      final String? message = failure;
      if (mounted) {
        setState(() {
          _refreshing = false;
          _refreshFailure = message;
          if (recipe != null) {
            _recipe = recipe;
          }
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    final Recipe? recipe = _recipe;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          tooltip: 'Back to your plan',
          onPressed: () => context.go('/plan'),
        ),
        title: Text(
          recipe == null || recipe.displayName.isEmpty
              ? 'How to make it'
              : recipe.displayName,
        ),
      ),
      body: SafeArea(bottom: false, child: _body(p)),
    );
  }

  Widget _body(HpPalette p) {
    final Recipe? recipe = _recipe;
    if (recipe == null && _loading) {
      return const HpLoadingState(
        message: 'Fetching the method',
        detail: 'A dish is written once and kept, so this is quick after the '
            'first time anybody opens it.',
      );
    }
    final String? loadFailure = _loadFailure;
    if (recipe == null) {
      return HpErrorState(
        title: 'We could not fetch this recipe',
        body: loadFailure ??
            'Nothing has changed. Your plan is exactly as it was.',
        onRetry: _load,
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
          'From your plan for ${HpFormat.dayShort(recipe.planDate)}',
          style: HpType.label.copyWith(color: p.inkFaint),
        ),
        const SizedBox(height: HpSpacing.md),
        _Portion(recipe: recipe),
        const SizedBox(height: HpSpacing.section),
        if (recipe.hasMethod) ..._method(p, recipe) else ..._noMethod(p, recipe),
        const SizedBox(height: HpSpacing.section),
        const HpDisclaimer(),
      ],
    );
  }

  List<Widget> _method(HpPalette p, Recipe recipe) {
    return <Widget>[
      if (recipe.ingredients.isNotEmpty) ...<Widget>[
        const HpSectionHeader(
          title: 'What goes in',
          // Said plainly, because a reader who expects amounts and finds none
          // should know at once that it is deliberate.
          note: 'names only',
        ),
        for (final String ingredient in recipe.ingredients)
          Padding(
            padding: const EdgeInsets.only(bottom: HpSpacing.xs),
            child: Text(
              ingredient,
              style: HpType.reading.copyWith(color: p.ink),
            ),
          ),
        const SizedBox(height: HpSpacing.lg),
      ],
      HpSectionHeader(
        title: 'How to make it',
        note: _prepNote(recipe.prepMinutes),
      ),
      for (int index = 0; index < recipe.steps.length; index++)
        _Step(number: index + 1, text: recipe.steps[index]),
      const SizedBox(height: HpSpacing.lg),
      _refreshRow(p, label: 'Write the method again'),
    ];
  }

  List<Widget> _noMethod(HpPalette p, Recipe recipe) {
    final String note = recipe.note ?? '';
    final bool nothingToMake =
        recipe.preparation != RecipePreparation.method;
    return <Widget>[
      HpCard(
        tone: nothingToMake ? HpCardTone.tinted : HpCardTone.flat,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(
              nothingToMake
                  ? Icons.shopping_basket_outlined
                  : Icons.notes_rounded,
              size: 18,
              color: nothingToMake ? p.pine : p.inkFaint,
            ),
            const SizedBox(width: HpSpacing.sm),
            Expanded(
              child: Text(
                note.isEmpty ? _fallbackNote : note,
                style: HpType.reading.copyWith(color: p.ink),
              ),
            ),
          ],
        ),
      ),
      // Only offered where a method is actually possible. Asking to write the
      // recipe for a handful of seeds again would be a button that does nothing.
      if (!nothingToMake) ...<Widget>[
        const SizedBox(height: HpSpacing.lg),
        _refreshRow(p, label: 'Try writing it again'),
      ],
    ];
  }

  Widget _refreshRow(HpPalette p, {required String label}) {
    final String? message = _refreshFailure;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        HpButton(
          label: label,
          icon: Icons.refresh_rounded,
          tone: HpButtonTone.quiet,
          busy: _refreshing,
          onPressed: _refresh,
        ),
        if (message != null) ...<Widget>[
          const SizedBox(height: HpSpacing.md),
          Semantics(
            liveRegion: true,
            container: true,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(
                  Icons.error_outline_rounded,
                  size: 18,
                  color: p.urgentInk,
                ),
                const SizedBox(width: HpSpacing.sm),
                Expanded(
                  child: Text(
                    message,
                    style: HpType.label.copyWith(color: p.urgentInk),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  static String? _prepNote(int? minutes) {
    if (minutes == null || minutes <= 0) {
      return null;
    }
    return 'about $minutes minutes';
  }
}

/// Said when the backend sent no sentence at all. It always does; this is the
/// belt to that braces, so a blank card is impossible.
const String _fallbackNote =
    'We do not have a method for this one yet. Nothing was made up to fill the '
    'gap.';

/// The amount, and why it is the only one on the screen.
class _Portion extends StatelessWidget {
  const _Portion({required this.recipe});

  final Recipe recipe;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    return HpCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            recipe.portionLine,
            style: HpType.bodyStrong.copyWith(color: p.ink),
          ),
          if (recipe.amountsNote.isNotEmpty) ...<Widget>[
            const SizedBox(height: HpSpacing.sm),
            Text(
              recipe.amountsNote,
              style: HpType.label.copyWith(color: p.inkMuted),
            ),
          ],
        ],
      ),
    );
  }
}

/// One numbered step.
class _Step extends StatelessWidget {
  const _Step({required this.number, required this.text});

  final int number;
  final String text;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    return Padding(
      padding: const EdgeInsets.only(bottom: HpSpacing.md),
      child: MergeSemantics(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              width: 24,
              child: Text(
                '$number',
                style: HpType.figureSmall.copyWith(color: p.pine),
              ),
            ),
            const SizedBox(width: HpSpacing.sm),
            Expanded(
              child: Text(
                text,
                style: HpType.reading.copyWith(color: p.ink),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown in a build with no backend address.
const String _noBackendMessage =
    'This build has no backend to ask, so there is no recipe to fetch. Sign in '
    'on a configured build to see it.';

class _NoBackend implements Exception {
  const _NoBackend();
}

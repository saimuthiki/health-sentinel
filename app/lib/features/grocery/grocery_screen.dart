import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format/hp_format.dart';
import '../../core/theme/hp_palette.dart';
import '../../core/theme/hp_spacing.dart';
import '../../core/theme/hp_typography.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/models.dart';
import '../../data/providers.dart';
import '../common/failure_copy.dart';

/// The week's shopping list: what the plan needs, and what is already at home.
///
/// Four decisions are worth knowing before reading the code, because each of
/// them is a choice rather than an accident.
///
/// **The list is not a list of healthy things somebody typed out.** It is added
/// up from the meals already planned for this week — `GET /v1/grocery` sums the
/// portions of every planned day, adds a tenth because portions are never
/// exact, and drops anything under five grams. The plan those meals came from
/// is built from the profile, the lab findings, the goals and the foods the
/// person has said they like, so the list changes when any of those change. The
/// screen says so in as many words, because a list that quietly changed week to
/// week with no explanation would look like a bug.
///
/// **A tick box never moves on its own.** It is drawn from the state the
/// backend last confirmed, the tap sends a request, and the box only moves when
/// the reply comes back. That is one round trip slower than moving it
/// optimistically, and it is the only version that cannot leave somebody
/// standing in a shop looking at a ticked box for something that is not in
/// their kitchen. While a request is in flight a small spinner sits beside that
/// one row.
///
/// **A refusal belongs to the row it happened on.** Each line keeps its own
/// failure sentence and its own busy flag, so ticking six things quickly works,
/// a slow one does not block the others, and one that fails says so where it
/// failed instead of putting a red line across a list that is otherwise fine.
///
/// **An empty list says which kind of empty it is.** See [_EmptyList].
class GroceryScreen extends ConsumerStatefulWidget {
  const GroceryScreen({super.key});

  @override
  ConsumerState<GroceryScreen> createState() => _GroceryScreenState();
}

class _GroceryScreenState extends ConsumerState<GroceryScreen> {
  /// What the backend last told us. Null until the first fetch answers.
  GroceryList? _list;

  bool _loading = true;

  /// Why the list could not be fetched at all. Shown instead of the list.
  String? _loadFailure;

  /// The item ids with a request in flight.
  ///
  /// A set rather than a single id, because ticking several things one after
  /// another is the ordinary way this screen is used: each line is its own
  /// request, its own spinner and its own guard, so a slow one never holds up
  /// the next.
  final Set<String> _busyItems = <String>{};

  /// Why a line's last change did not happen, by item id.
  ///
  /// Kept per item on purpose. One refused tick is not a reason to tell
  /// somebody the whole list is broken.
  final Map<String, String> _itemFailures = <String, String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Fetch the list. Called on arrival and by "Try again".
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadFailure = null;
    });

    GroceryList? list;
    String? failure;
    try {
      list = await ref.read(healthRepositoryProvider).loadGroceryList();
    } catch (error) {
      failure = explainFailure(
        error,
        fallback: 'Your grocery list could not be fetched just now. Nothing '
            'has changed — try again in a moment.',
      );
    } finally {
      // In a `finally`, so a thrown failure cannot leave this screen spinning
      // for ever with no way back into it. The same reason `_accept()` on the
      // consent screen clears its flag there.
      final GroceryList? fetched = list;
      if (mounted) {
        setState(() {
          _loading = false;
          _loadFailure = failure;
          if (fetched != null) {
            _list = fetched;
            // A fresh list is a fresh answer about every line on it, so the old
            // refusals no longer describe anything on screen.
            _itemFailures.clear();
          }
        });
      }
    }
  }

  /// Say where one line stands, and move the box only if the backend agrees.
  ///
  /// The busy set is cleared in a `finally` for the same reason the consent
  /// screen clears its flag there: a path out of here that skipped it would
  /// leave the row spinning for ever and turn every later tap on it away as a
  /// duplicate. A refusal changes nothing but the sentence under that one line
  /// — [_list] is only ever changed by what the server actually answered, so a
  /// box that failed to move is still showing what the backend holds.
  Future<void> _setItemState(GroceryItem item, GroceryState next) async {
    final String? itemId = item.id;
    if (itemId == null) {
      // Nothing to address the change to. Such a row draws its tick box
      // disabled and says why, so this is a guard rather than a path anybody
      // can actually take.
      return;
    }
    if (_busyItems.contains(itemId)) {
      // Already in flight. A second tap would send the same change twice, and
      // a third could send the opposite one out of order.
      return;
    }
    setState(() {
      _busyItems.add(itemId);
      _itemFailures.remove(itemId);
    });

    GroceryState? saved;
    String? failure;
    try {
      saved = await ref.read(healthRepositoryProvider).setGroceryItemState(
            itemId: itemId,
            state: next,
          );
    } catch (error) {
      failure = explainFailure(
        error,
        fallback: 'That could not be saved just now. The line is still the way '
            'it was — try again in a moment.',
      );
    } finally {
      // Both copied out before the `setState` closure, so the closure reads
      // values that cannot change under it.
      final GroceryState? fresh = saved;
      final String? message = failure;
      if (mounted) {
        setState(() {
          _busyItems.remove(itemId);
          if (message != null) {
            _itemFailures[itemId] = message;
          }
          if (fresh != null) {
            // Only this line changes, and only its state. Refetching the whole
            // list here would throw away the ticks of every other request still
            // in flight.
            _list = _list?.withItemState(itemId, fresh);
          }
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          tooltip: 'Back to More',
          onPressed: () => context.go('/more'),
        ),
        title: const Text('Grocery list'),
      ),
      body: SafeArea(
        bottom: false,
        child: _body(p),
      ),
    );
  }

  Widget _body(HpPalette p) {
    final GroceryList? list = _list;
    if (list == null && _loading) {
      return const HpLoadingState(
        message: 'Adding up this week’s list',
        detail: 'The health engine sleeps between visits, so the first look of '
            'the day can take a moment.',
      );
    }
    final String? loadFailure = _loadFailure;
    if (list == null) {
      return HpErrorState(
        title: 'We could not fetch your grocery list',
        body: loadFailure ??
            'Nothing has changed. Whatever you had already ticked is still '
                'ticked.',
        onRetry: _load,
      );
    }

    if (list.items.isEmpty) {
      return SingleChildScrollView(
        child: _EmptyList(weekStart: list.weekStart),
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
          'This is the week beginning ${HpFormat.dayShort(list.weekStart)}. '
          'Every line is added up from the meals already planned for those '
          'days — nothing here was invented for the shop.',
          style: HpType.reading.copyWith(color: p.inkMuted),
        ),
        const SizedBox(height: HpSpacing.md),
        Text(
          'Tick what you already have at home. Whatever is left unticked is '
          'what to bring.',
          style: HpType.reading.copyWith(color: p.inkMuted),
        ),
        const SizedBox(height: HpSpacing.section),
        for (final GroceryAisle aisle in list.aisles) ...<Widget>[
          HpSectionHeader(
            title: aisleTitle(aisle.name),
            note: _stillToBuyNote(aisle.stillToBuy, aisle.items.length),
          ),
          for (final GroceryItem item in aisle.items)
            _GroceryRow(
              item: item,
              busy: item.id != null && _busyItems.contains(item.id),
              failure: item.id == null ? null : _itemFailures[item.id],
              onStateChanged: (GroceryState next) =>
                  _setItemState(item, next),
            ),
          const SizedBox(height: HpSpacing.lg),
        ],
        const SizedBox(height: HpSpacing.md),
        Text(
          list.stillToBuy == 0
              ? 'Nothing left to bring — every line is either at home or '
                  'bought.'
              : '${list.stillToBuy} of ${list.items.length} still to bring '
                  'home.',
          style: HpType.label.copyWith(color: p.inkFaint),
        ),
      ],
    );
  }

  /// "2 of 5 to buy", or "all sorted" once an aisle needs nothing.
  static String _stillToBuyNote(int stillToBuy, int total) {
    if (stillToBuy == 0) {
      return 'all sorted';
    }
    return '$stillToBuy of $total to buy';
  }
}

/// What an aisle is called on screen.
///
/// The backend sends the food's `food_group` straight through as the aisle, so
/// what arrives is `cereal_millet` and `leafy_vegetable` — column values, not
/// English. Written here rather than on the server for the same reason
/// `reminderTypeTitle` is written in the reminders screen: it is display copy,
/// and the backend has no business holding it. A group this app has not heard
/// of still gets a readable heading rather than being hidden, because a line
/// somebody has to buy and cannot find is worse than an imperfect heading.
String aisleTitle(String aisle) {
  switch (aisle) {
    case 'cereal_millet':
      return 'Cereals and millets';
    case 'pulse_legume':
      return 'Pulses and legumes';
    case 'vegetable':
      return 'Vegetables';
    case 'leafy_vegetable':
      return 'Leafy vegetables';
    case 'fruit':
      return 'Fruit';
    case 'dairy':
      return 'Dairy';
    case 'egg':
      return 'Eggs';
    case 'fish_seafood':
      return 'Fish and seafood';
    case 'meat_poultry':
      return 'Meat and poultry';
    case 'nut_seed':
      return 'Nuts and seeds';
    case 'oil_fat':
      return 'Oils and fats';
    case 'sugar_sweetener':
      return 'Sugar and sweeteners';
  }
  final String spaced = aisle.replaceAll('_', ' ').trim();
  if (spaced.isEmpty) {
    return 'Other';
  }
  return spaced[0].toUpperCase() + spaced.substring(1);
}

/// One line of the list: a tick box, what to buy, and how much.
class _GroceryRow extends StatelessWidget {
  const _GroceryRow({
    required this.item,
    required this.busy,
    required this.failure,
    required this.onStateChanged,
  });

  final GroceryItem item;

  /// True while this line's change is in flight. The guard against a second tap
  /// is in the screen, not in here.
  final bool busy;

  /// Why this line's last change did not happen, or null.
  final String? failure;

  final ValueChanged<GroceryState> onStateChanged;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    final bool addressable = item.id != null;
    final String? message = failure;

    return Padding(
      padding: const EdgeInsets.only(bottom: HpSpacing.sm),
      child: HpCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // Merged, so a screen reader reads "Ragi flour, 616 g, still to
            // buy, checkbox, not checked" as one thing rather than announcing a
            // bare unlabelled checkbox and then some text. This is what
            // `CheckboxListTile` does, and the row is only laid out by hand
            // because of the spinner.
            MergeSemantics(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  // Left tappable while the change is in flight, on purpose.
                  // The box shows what the backend holds, so it has nothing to
                  // say yet; the spinner beside it says a change is on its way;
                  // and a second tap is turned away by the guard in
                  // `_setItemState` rather than by a dead control, so nothing
                  // is sent twice.
                  Checkbox(
                    value: item.state.isSettled,
                    onChanged: addressable
                        ? (bool? ticked) => onStateChanged(
                              ticked == true
                                  ? GroceryState.have
                                  : GroceryState.need,
                            )
                        : null,
                  ),
                  const SizedBox(width: HpSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          item.displayName,
                          style: HpType.bodyStrong.copyWith(color: p.ink),
                        ),
                        const SizedBox(height: HpSpacing.xxs),
                        Text(
                          _amountLine(),
                          style: HpType.label.copyWith(color: p.inkFaint),
                        ),
                      ],
                    ),
                  ),
                  if (busy) ...<Widget>[
                    const SizedBox(width: HpSpacing.md),
                    SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        color: p.pine,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (!addressable) ...<Widget>[
              const SizedBox(height: HpSpacing.md),
              Text(
                'This line has no row behind it yet, so it cannot be ticked. '
                'Fetching the list again usually gives it one.',
                style: HpType.label.copyWith(color: p.inkMuted),
              ),
            ] else if (item.state == GroceryState.need) ...<Widget>[
              const SizedBox(height: HpSpacing.sm),
              // A third state the tick box cannot express. Ticking says "it is
              // in my kitchen"; this says "I picked it up on this week's shop".
              // Both mean do not buy it, and keeping them apart is what would
              // one day let the backend take a real pantry off next week's
              // quantities.
              HpTextAction(
                label: 'I bought this',
                icon: Icons.shopping_basket_outlined,
                onPressed: () => onStateChanged(GroceryState.bought),
              ),
            ],
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
        ),
      ),
    );
  }

  /// "900 g · Still to buy", or just the state when there is no quantity.
  String _amountLine() {
    final String amount = item.quantityLabel;
    if (amount.isEmpty) {
      return item.state.label;
    }
    return '$amount · ${item.state.label}';
  }
}

/// An empty list, with the reason it is empty.
///
/// There are two ways to get here and they mean opposite things, so the screen
/// has to say which. A list is built only from days that have already been
/// planned, so by far the commoner reason is that this week has no plan yet —
/// and the honest answer to that is a way into the plan, not an apology. The
/// other reason is that the week is planned and every ingredient in it came to
/// less than five grams, which the planner does not bother writing down; that
/// is mentioned rather than hidden, because somebody standing in front of an
/// empty screen with a planned week deserves to know it is not a fault.
///
/// The backend cannot currently tell the two apart for us: `GroceryListOut`
/// carries no count of the planned days behind it. That is written up as a
/// backend change worth making rather than guessed at here.
class _EmptyList extends StatelessWidget {
  const _EmptyList({required this.weekStart});

  final DateTime weekStart;

  @override
  Widget build(BuildContext context) {
    return HpEmptyState(
      icon: Icons.shopping_cart_outlined,
      title: 'Nothing to buy for this week yet',
      body: 'Your list is added up from the meals already planned for the week '
          'beginning ${HpFormat.dayShort(weekStart)} — so an empty list almost '
          'always means those days have not been planned yet. Plan a day and '
          'its ingredients appear here. If the week is planned, everything in '
          'it is in amounts too small to be worth a line.',
      actionLabel: 'Open your plan',
      onAction: () => context.go('/plan'),
    );
  }
}

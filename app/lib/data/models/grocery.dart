/// `grocery_lists` and `grocery_items` — the week's shopping, and where each
/// line stands.
///
/// Two things are worth knowing before reading this file, because both of them
/// shaped it.
///
/// **Nothing here is invented.** `GET /v1/grocery` adds up the portions of the
/// meals that have already been planned for that week
/// (`backend/app/planner/grocery.py`), rounds the total up by a tenth because
/// portions are never exact, and drops anything under five grams. So a line is
/// arithmetic over the plan, not a suggestion; the aisle is the food's own food
/// group, so the list walks in the order of a shop.
///
/// **There is no `toJson` on purpose.** These models are never written to the
/// offline cache. A shopping list that was ticked on a train and then shown as
/// though it were current would tell somebody they already have something they
/// do not, which is worse than an empty screen — so the list is fetched, shown,
/// and forgotten.
library;

import 'json.dart';

/// Where one line stands: to buy, already at home, or picked up this week.
///
/// These three strings are exactly what `StateIn` in `backend/app/api/grocery.py`
/// accepts, and that model is declared `extra="forbid"`, so sending anything
/// else — or anything beside `state` — is a 422 rather than something quietly
/// ignored.
enum GroceryState {
  /// Not at home, so it has to be bought. What every line starts as.
  need('need', 'Still to buy'),

  /// The owner's "we do have it in my room": already in the kitchen, so there
  /// is no need to bring it.
  have('have', 'Already in the kitchen'),

  /// Picked up on this week's shop. Also means "do not buy it", but it is a
  /// different fact from having had it all along, and the backend keeps them
  /// apart — see [isSettled].
  bought('bought', 'Bought this week');

  const GroceryState(this.wire, this.label);

  /// The string the endpoint accepts, never a display name.
  final String wire;

  /// What a person reads next to the line.
  final String label;

  static GroceryState fromWire(Object? value) =>
      GroceryState.values.firstWhere(
        (GroceryState state) => state.wire == value,
        // An unknown state means the backend grew one we have not heard of.
        // Showing such a line as "still to buy" errs towards bringing something
        // home twice, which is the harmless half of being wrong.
        orElse: () => GroceryState.need,
      );

  /// True when this line does not need bringing home.
  ///
  /// This is what the tick box shows, and it is deliberately true for both
  /// [have] and [bought]: the question the box asks is "do I need to bring
  /// this?", and the answer is no in both cases. Which of the two it is, is
  /// said in words beside it rather than by a second control.
  bool get isSettled => this != GroceryState.need;
}

/// One line of the list: a food, how much of it, and where it stands.
class GroceryItem {
  const GroceryItem({
    required this.id,
    required this.foodId,
    this.name = '',
    this.quantity = 0,
    this.unit = 'g',
    this.aisle = 'Other',
    this.state = GroceryState.need,
  });

  /// The row id `PATCH /v1/grocery/items/{item_id}` is addressed with.
  ///
  /// Nullable because `GroceryItemOut` declares it so. A line with no id cannot
  /// be ticked — there is nothing to address the change to — and the screen
  /// says as much rather than drawing a control that silently does nothing.
  final String? id;

  /// The `foods` table id this line came from. Not shown; it is what the
  /// backend would need if the pantry were ever fed back into the sums.
  final String foodId;

  /// The food's name from the reference table. Can be empty: the backend looks
  /// names up per list, and a food row that has since gone leaves this blank.
  final String name;

  /// How much to buy. Already includes the tenth the planner adds on top.
  final double quantity;

  /// Almost always `g`. Kept as the backend sent it rather than assumed.
  final String unit;

  /// The food group, which doubles as the aisle. `Other` when unknown.
  final String aisle;

  final GroceryState state;

  /// The name, falling back to the food id so a line is never a blank row.
  ///
  /// An id is not pretty, but a line with no label at all cannot be shopped
  /// for, and inventing a name for a food we could not look up would be worse
  /// than showing the identifier we do have.
  String get displayName {
    final String trimmed = name.trim();
    return trimmed.isEmpty ? foodId : trimmed;
  }

  /// "900 g", "1.2 kg" — the amount as it would be said out loud.
  ///
  /// Grams turn into kilograms past a thousand for the same reason millilitres
  /// turn into litres elsewhere in the app: nobody buys 1 200 grams of rice.
  /// Any other unit is left exactly as the backend sent it, because guessing at
  /// a conversion we were not told about is how a quantity comes out wrong.
  String get quantityLabel {
    if (quantity <= 0) {
      return '';
    }
    if (unit == 'g' && quantity >= 1000) {
      return '${_trimmed(quantity / 1000)} kg';
    }
    return '${_trimmed(quantity)} $unit';
  }

  /// The same line with a different state. Used when the backend has confirmed
  /// a change, so the list on screen matches the list on the server.
  GroceryItem withState(GroceryState next) => GroceryItem(
        id: id,
        foodId: foodId,
        name: name,
        quantity: quantity,
        unit: unit,
        aisle: aisle,
        state: next,
      );

  factory GroceryItem.fromJson(Map<String, dynamic> json) => GroceryItem(
        id: asStringOrNull(json['id']),
        foodId: asString(json['food_id']),
        name: asString(json['name']),
        quantity: asDouble(json['quantity']),
        unit: asString(json['unit'], fallback: 'g'),
        aisle: asString(json['aisle'], fallback: 'Other'),
        state: GroceryState.fromWire(json['state']),
      );

  /// One decimal at most, and none at all for a whole number.
  static String _trimmed(double value) {
    final double rounded = (value * 10).roundToDouble() / 10;
    if (rounded == rounded.roundToDouble()) {
      return rounded.toStringAsFixed(0);
    }
    return rounded.toStringAsFixed(1);
  }
}

/// Every line of one aisle, so the list can be walked rather than searched.
class GroceryAisle {
  const GroceryAisle({required this.name, required this.items});

  final String name;
  final List<GroceryItem> items;

  /// How many lines in this aisle still have to be brought home.
  int get stillToBuy =>
      items.where((GroceryItem item) => !item.state.isSettled).length;
}

/// One week's list, as `GET /v1/grocery` answers with it.
class GroceryList {
  const GroceryList({
    required this.weekStart,
    this.status = 'open',
    this.items = const <GroceryItem>[],
  });

  /// The Monday the week runs from. The backend decides which week that is; the
  /// app does not work it out a second time.
  final DateTime weekStart;

  /// `open` today. Kept because the backend sends it and a list that has been
  /// closed off is a state this screen would have to respect if it ever grows.
  final String status;

  final List<GroceryItem> items;

  int get stillToBuy =>
      items.where((GroceryItem item) => !item.state.isSettled).length;

  /// The lines grouped by aisle, aisles in the order the backend listed them.
  ///
  /// The order is not re-sorted here on purpose: `GroceryRepository.items`
  /// orders by aisle already, and a screen that sorted a second time would be a
  /// second opinion about the order of a shop.
  List<GroceryAisle> get aisles {
    final List<String> order = <String>[];
    final Map<String, List<GroceryItem>> grouped =
        <String, List<GroceryItem>>{};
    for (final GroceryItem item in items) {
      final String aisle = item.aisle.trim().isEmpty ? 'Other' : item.aisle;
      if (!grouped.containsKey(aisle)) {
        grouped[aisle] = <GroceryItem>[];
        order.add(aisle);
      }
      grouped[aisle]!.add(item);
    }
    return <GroceryAisle>[
      for (final String aisle in order)
        GroceryAisle(name: aisle, items: grouped[aisle]!),
    ];
  }

  /// The same list with one line's state replaced.
  ///
  /// Only the state is touched. `PATCH /v1/grocery/items/{item_id}` answers
  /// with a `GroceryItemOut` that has **no name on it** — the endpoint builds
  /// its reply without the reference lookup the read does — so rebuilding a
  /// whole line out of that reply would blank the label the person is reading.
  GroceryList withItemState(String itemId, GroceryState next) {
    return GroceryList(
      weekStart: weekStart,
      status: status,
      items: <GroceryItem>[
        for (final GroceryItem item in items)
          if (item.id == itemId) item.withState(next) else item,
      ],
    );
  }

  factory GroceryList.fromJson(Map<String, dynamic> json) => GroceryList(
        weekStart: asDate(json['week_start']) ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        status: asString(json['status'], fallback: 'open'),
        items: asMapList(json['items']).map(GroceryItem.fromJson).toList(),
      );
}

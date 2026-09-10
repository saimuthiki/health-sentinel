import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/api/api_client.dart';
import '../../data/api/api_failure.dart';
import '../../data/models/json.dart';
import '../../data/providers.dart';
import '../../data/repository/health_repository.dart';

/// How to make one item of a plan, and how much of it to have.
///
/// **The amount is the plan's, and it is the only quantity here.** [portionGrams]
/// is read off the stored plan row on the server — the same row the plan's
/// nutrition was computed from — and this app never sends a quantity that could
/// become one. The method itself carries no weights, volumes, cups or spoons at
/// all: the backend refuses one that does, because a recipe with its own amounts
/// beside a plan with its own numbers is two accounts of one meal. [amountsNote]
/// is the backend's sentence saying exactly that, and the screen shows it.
///
/// **Some items need nothing doing to them.** [preparation] is decided on the
/// server from the curated foods table before any model is considered, so a
/// packet of sunflower seeds comes back as [RecipePreparation.none] with a
/// sentence and no steps — and costs no model call.
class Recipe {
  const Recipe({
    required this.itemId,
    required this.planDate,
    required this.displayName,
    required this.portionGrams,
    required this.portionLine,
    required this.amountsNote,
    required this.preparation,
    this.foodId,
    this.note,
    this.ingredients = const <String>[],
    this.steps = const <String>[],
    this.prepMinutes,
    this.stored = false,
    this.generated = false,
  });

  factory Recipe.fromJson(Map<String, dynamic> json) {
    return Recipe(
      itemId: asString(json['item_id']),
      planDate: asDate(json['plan_date']) ?? DateTime.now(),
      displayName: asString(json['display_name']),
      portionGrams: asDouble(json['portion_grams']),
      portionLine: asString(json['portion_line']),
      amountsNote: asString(json['amounts_note']),
      preparation: RecipePreparation.fromWire(asString(json['preparation'])),
      foodId: asStringOrNull(json['food_id']),
      note: asStringOrNull(json['note']),
      ingredients: asStringList(json['ingredients']),
      steps: asStringList(json['steps']),
      prepMinutes: asIntOrNull(json['prep_minutes']),
      stored: asBool(json['stored']),
      generated: asBool(json['generated']),
    );
  }

  final String itemId;
  final DateTime planDate;
  final String displayName;

  /// Off the plan row. Never sent by this app.
  final double portionGrams;

  /// That amount as a sentence, written by the backend in Python.
  final String portionLine;

  /// Why the method below cannot disagree with the plan's numbers.
  final String amountsNote;

  final RecipePreparation preparation;
  final String? foodId;

  /// The sentence for an item that needs no preparation, one that is an
  /// ingredient rather than a dish, or a method we do not have.
  final String? note;

  final List<String> ingredients;
  final List<String> steps;
  final int? prepMinutes;

  /// True when the method came out of the backend's store rather than out of a
  /// model call. A dish is generated once and read every time after that.
  final bool stored;

  /// True when a model wrote this method during this request.
  final bool generated;

  /// True when there is a method to draw.
  bool get hasMethod => steps.isNotEmpty;
}

/// What, if anything, this item needs doing to it.
enum RecipePreparation {
  /// Eaten as it comes. The owner's own example: sunflower seeds.
  none('none'),

  /// A cooking ingredient rather than a dish.
  ingredient('ingredient'),

  /// A dish with a method.
  method('method');

  const RecipePreparation(this.wire);

  final String wire;

  static RecipePreparation fromWire(String value) {
    for (final RecipePreparation kind in RecipePreparation.values) {
      if (kind.wire == value) {
        return kind;
      }
    }
    return RecipePreparation.method;
  }
}

/// Fetching one item's recipe.
///
/// Feature-local, for the same reason `features/chat/chat_photo.dart` keeps its
/// own service: these two endpoints are called from one screen, and the shared
/// repository interface is not this change's file to add to.
abstract class RecipeService {
  /// `GET /v1/recipes/plan-items/{itemId}`. Serves the stored method when there
  /// is one, which is almost always, so this is usually a read.
  Future<Recipe> load({required String itemId, required DateTime on});

  /// `POST /v1/recipes/plan-items/{itemId}/refresh`. Writes the method again.
  Future<Recipe> refresh({required String itemId, required DateTime on});
}

/// The service, or null in a build with no backend address.
final recipeServiceProvider = Provider<RecipeService?>((ref) {
  final ApiClient? api = ref.watch(apiClientProvider);
  if (api == null) {
    return null;
  }
  return HttpRecipeService(api);
});

/// The real one, against our own FastAPI service.
class HttpRecipeService implements RecipeService {
  HttpRecipeService(this._api);

  final ApiClient _api;

  @override
  Future<Recipe> load({required String itemId, required DateTime on}) {
    // `generates: true`: the first person to open a dish pays for it being
    // written, and that is a model call rather than a row read. Everybody after
    // them gets the stored one, but the timeout has to allow for being first.
    return _fetch(() => _api.getMap(
          '/v1/recipes/plan-items/${Uri.encodeComponent(itemId)}',
          query: <String, String>{'on': _isoDay(on)},
          generates: true,
        ));
  }

  @override
  Future<Recipe> refresh({required String itemId, required DateTime on}) {
    return _fetch(() => _api.postMap(
          '/v1/recipes/plan-items/${Uri.encodeComponent(itemId)}/refresh',
          query: <String, String>{'on': _isoDay(on)},
        ));
  }

  Future<Recipe> _fetch(Future<Map<String, dynamic>> Function() call) async {
    try {
      return Recipe.fromJson(await call());
    } on ApiFailure catch (failure) {
      throw HealthRepositoryException(failure.message);
    }
  }

  static String _isoDay(DateTime on) => on.toIso8601String().split('T').first;
}

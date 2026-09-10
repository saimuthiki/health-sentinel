import 'enums.dart';
import 'json.dart';

/// `meal_plan_items` - one thing to eat, with the reason it is there.
///
/// [nutrients] is recomputed on the server from the `foods` table after the
/// model has chosen the meal. If the model claims a dosa has 12 g of protein and
/// the database says 8.4 g, this field says 8.4.
class MealPlanItem {
  const MealPlanItem({
    required this.id,
    required this.mealSlot,
    required this.title,
    this.portion,
    this.whyText,
    this.nutrients = const <String, double>{},
    this.orderIndex = 0,
    this.recipeId,
    this.foodId,
    this.timeOfDay,
  });

  final String id;
  final MealSlot mealSlot;
  final String title;

  /// Human-readable serving: "2 idlis with sambar".
  final String? portion;

  /// Why this is in the plan, in the user's terms: "iron with vitamin C, which
  /// helps absorption". Explanation, not instruction.
  final String? whyText;

  /// Keys match the `foods.per_100g` nutrient keys: kcal, protein_g, iron_mg...
  final Map<String, double> nutrients;

  final int orderIndex;
  final String? recipeId;
  final String? foodId;

  /// 24-hour "HH:mm", copied from the user's meal times.
  final String? timeOfDay;

  double? get kcal => nutrients['kcal'];

  factory MealPlanItem.fromJson(Map<String, dynamic> json) => MealPlanItem(
        id: asString(json['id']),
        mealSlot: MealSlot.fromWire(json['meal_slot']),
        title: asString(json['title']),
        portion: asStringOrNull(json['portion']),
        whyText: asStringOrNull(json['why_text']),
        nutrients: asDoubleMap(json['computed_nutrients']),
        orderIndex: asInt(json['order_index']),
        recipeId: asStringOrNull(json['recipe_id']),
        foodId: asStringOrNull(json['food_id']),
        timeOfDay: asStringOrNull(json['time_of_day']),
      );

  Map<String, dynamic> toJson() => prune(<String, dynamic>{
        'id': id,
        'meal_slot': mealSlot.wire,
        'title': title,
        'portion': portion,
        'why_text': whyText,
        'computed_nutrients': nutrients,
        'order_index': orderIndex,
        'recipe_id': recipeId,
        'food_id': foodId,
        'time_of_day': timeOfDay,
      });
}

/// The daily drinking-water goal, exactly as the server describes it.
///
/// Every field here is the server's answer. Nothing in this class is computed,
/// defaulted or judged on the phone, and that is the point of it existing at
/// all: the goal, the figure our sources support, whether the person chose it
/// themselves, the citation behind it and the warning attached to it are all
/// decided in one place - `backend/app/rules/daily_goals.py`, which carries the
/// literature references (IOM 2005, Hew-Butler 2015, Noakes 2001). The app
/// renders what it is sent and never composes a second version of it.
///
/// [millilitres] is **null when the server will not give a goal** - pregnancy,
/// or a condition where fluid intake is a doctor's decision. That is a real
/// answer, not a missing one: [source] then carries the reason instead of the
/// citation, and a screen must show the reason and no bar rather than falling
/// back to a number of its own.
///
/// The same five keys arrive on the day plan and on the reply to
/// `PUT /v1/plan/hydration-target`, so one class reads both.
class HydrationGoal {
  const HydrationGoal({
    this.millilitres,
    this.sourcedMillilitres,
    this.chosenByUser = false,
    this.source = '',
    this.caution = '',
  });

  /// The goal in force, or null when there is deliberately not one.
  final double? millilitres;

  /// What the published guideline says for this profile, sent whatever the
  /// person chose, so the evidence can stay visible beside the choice.
  final double? sourcedMillilitres;

  /// True when [millilitres] is a goal this person set rather than ours.
  final bool chosenByUser;

  /// The citation for the number, or the reason there is not one. Deterministic
  /// text from curated code; no model has ever touched it.
  final String source;

  /// The plain warning attached to a chosen goal above the published range, or
  /// empty when there is nothing to say. Shown verbatim, never rewritten.
  final String caution;

  /// Whether there is a goal to draw a bar against at all.
  bool get hasTarget => millilitres != null;

  factory HydrationGoal.fromJson(Map<String, dynamic> json) => HydrationGoal(
        millilitres: asDoubleOrNull(json['hydration_target_ml']),
        sourcedMillilitres: asDoubleOrNull(json['hydration_target_sourced_ml']),
        chosenByUser: asBool(json['hydration_target_chosen_by_user']),
        source: asString(json['hydration_target_source']),
        caution: asString(json['hydration_target_caution']),
      );

  Map<String, dynamic> toJson() => prune(<String, dynamic>{
        'hydration_target_ml': millilitres,
        'hydration_target_sourced_ml': sourcedMillilitres,
        'hydration_target_chosen_by_user': chosenByUser,
        'hydration_target_source': source,
        'hydration_target_caution': caution,
      });
}

/// `meal_plans` - a day of eating and the reason it looks the way it does.
class MealPlan {
  const MealPlan({
    required this.id,
    required this.planDate,
    this.rationale,
    this.status = 'active',
    this.generatedAt,
    this.items = const <MealPlanItem>[],
    this.hydrationTargetMl = 2500,
    this.hydrationLoggedMl = 0,
    this.hydrationGoal = const HydrationGoal(),
    this.dayNutrients = const <String, double>{},
    this.targets = const <String, double>{},
  });

  final String id;
  final DateTime planDate;

  /// "Why does today look like this?" - the change and its reason, so the
  /// learning is visible instead of mysterious.
  final String? rationale;

  final String status;
  final DateTime? generatedAt;
  final List<MealPlanItem> items;

  /// What the plan **asked** this person to drink, from the day plan's own
  /// `hydration_ml`. It is not the goal and it is not what anybody drank; those
  /// are [hydrationGoal] and [hydrationLoggedMl].
  final double hydrationTargetMl;

  /// Millilitres of water actually logged for this day, summed by the server
  /// from the drinks `POST /v1/feedback/hydration` recorded. Zero means nothing
  /// was logged, which is not the same as nothing drunk.
  final double hydrationLoggedMl;

  /// The daily water goal in force, or an explained absence of one.
  final HydrationGoal hydrationGoal;

  /// Day totals, recomputed server-side.
  final Map<String, double> dayNutrients;

  /// ICMR-NIN targets for this person's age, sex and activity level.
  final Map<String, double> targets;

  List<MealPlanItem> itemsFor(MealSlot slot) =>
      items.where((MealPlanItem i) => i.mealSlot == slot).toList();

  factory MealPlan.fromJson(Map<String, dynamic> json) => MealPlan(
        id: asString(json['id']),
        planDate: asDate(json['plan_date']) ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        rationale: asStringOrNull(json['rationale']),
        status: asString(json['status'], fallback: 'active'),
        generatedAt: asTimestamp(json['generated_at']),
        items: asMapList(json['items']).map(MealPlanItem.fromJson).toList(),
        hydrationTargetMl:
            asDouble(json['hydration_target_ml'], fallback: 2500),
        hydrationLoggedMl: asDouble(json['hydration_logged_ml']),
        // Nested, unlike everything else here, because this class's own JSON is
        // the offline cache's dialect rather than the API's: `MealPlan` already
        // spends `hydration_target_ml` on the plan's asked-for figure, and the
        // goal uses that same key on the wire. One key, two meanings, is how a
        // plan's suggestion ends up drawn as somebody's goal.
        hydrationGoal: HydrationGoal.fromJson(asMap(json['hydration_goal'])),
        dayNutrients: asDoubleMap(json['day_nutrients']),
        targets: asDoubleMap(json['targets']),
      );

  Map<String, dynamic> toJson() => prune(<String, dynamic>{
        'id': id,
        'plan_date': dateToJson(planDate),
        'rationale': rationale,
        'status': status,
        'generated_at': timestampToJson(generatedAt),
        'items': items.map((MealPlanItem i) => i.toJson()).toList(),
        'hydration_target_ml': hydrationTargetMl,
        'hydration_logged_ml': hydrationLoggedMl,
        'hydration_goal': hydrationGoal.toJson(),
        'day_nutrients': dayNutrients,
        'targets': targets,
      });
}

/// `goals`, with the progress the backend computes for it.
class Goal {
  const Goal({
    required this.id,
    required this.goalType,
    required this.title,
    this.target,
    this.priority = 1,
    this.status = GoalStatus.active,
    this.progress,
    this.createdAt,
  });

  final String id;
  final GoalType goalType;
  final String title;
  final String? target;
  final int priority;
  final GoalStatus status;

  /// 0.0 to 1.0, or null when there is nothing to measure against yet.
  final double? progress;

  final DateTime? createdAt;

  factory Goal.fromJson(Map<String, dynamic> json) => Goal(
        id: asString(json['id']),
        goalType: GoalType.fromWire(json['goal_type']),
        title: asString(json['title']),
        target: asStringOrNull(json['target']),
        priority: asInt(json['priority'], fallback: 1),
        status: GoalStatus.fromWire(json['status']),
        progress: asDoubleOrNull(json['progress']),
        createdAt: asTimestamp(json['created_at']),
      );

  Map<String, dynamic> toJson() => prune(<String, dynamic>{
        'id': id,
        'goal_type': goalType.wire,
        'title': title,
        'target': target,
        'priority': priority,
        'status': status.wire,
        'progress': progress,
        'created_at': timestampToJson(createdAt),
      });
}

/// `symptoms` - something the user told us, in their words.
class Symptom {
  const Symptom({
    required this.id,
    required this.label,
    this.onset,
    this.severity,
    this.pattern,
    this.status = 'open',
  });

  final String id;
  final String label;
  final DateTime? onset;

  /// 1 to 5, as the user rated it. Not a clinical score.
  final int? severity;

  /// "after meals", "in the evening".
  final String? pattern;

  final String status;

  factory Symptom.fromJson(Map<String, dynamic> json) => Symptom(
        id: asString(json['id']),
        label: asString(json['label']),
        onset: asDate(json['onset']),
        severity: asIntOrNull(json['severity']),
        pattern: asStringOrNull(json['pattern']),
        status: asString(json['status'], fallback: 'open'),
      );

  Map<String, dynamic> toJson() => prune(<String, dynamic>{
        'id': id,
        'label': label,
        'onset': dateToJson(onset),
        'severity': severity,
        'pattern': pattern,
        'status': status,
      });
}

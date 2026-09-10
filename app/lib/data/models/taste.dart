/// What we believe about one food, and the three answers that can change it.
///
/// The owner asked for one question — *did you enjoy it?* — with three answers,
/// and for the answer to count next time. These are the app's half of that. The
/// backend's half is `app/api/feedback.py` and `app/nutrition/candidates.py`,
/// and the numbers below are not arbitrary: each one is the score that makes the
/// planner behave the way the button's label promises.
library;

import 'json.dart';

/// The three answers, and the rating each one sends.
///
/// **1, 3 and 5 — not 2 and 4.** Every one of these is load-bearing:
///
/// * **5 for "Loved it"**, because `app/ai/context.py` sorts likes by score and
///   keeps only the top twelve before they reach the model, and `rank_foods`
///   scales its bonus by `score / 5`. A 4 is a like too, but it is the one that
///   gets trimmed first and lifts least. 5 is what survives.
/// * **3 for "It was okay"**, because 3 is the only rating that lands on
///   `Stance.NEUTRAL` — anything at or below 2 is a dislike, anything at or
///   above 4 is a like. Neutral at 3.0 is invisible to the filter *and* to the
///   ranking, which is what makes this a genuine "forget I said anything"
///   rather than a fourth opinion.
/// * **1 for "Did not like it"**, because the planner drops a disliked food at
///   or below 2.0. A 2 would be recorded as a dislike, described to the model
///   as a dislike, and then offered again anyway.
///
/// Only plan claims live on these labels. "We will suggest this more often" is
/// something this app controls and can be held to. What a food does to somebody
/// is not, and nothing here says it.
enum TasteStance {
  loved(
    wire: 'like',
    rating: 5,
    label: 'Loved it',
    effect: 'We will suggest this more often.',
  ),
  okay(
    wire: 'neutral',
    rating: 3,
    label: 'It was okay',
    effect: 'Noted. This will not change what we suggest.',
  ),
  disliked(
    wire: 'dislike',
    rating: 1,
    label: 'Did not like it',
    effect: 'We will stop suggesting this.',
  );

  const TasteStance({
    required this.wire,
    required this.rating,
    required this.label,
    required this.effect,
  });

  /// The `stance` string the backend stores and returns.
  final String wire;

  /// The 1–5 sent to change it. See the enum comment for why these three.
  final int rating;

  /// What the button says.
  final String label;

  /// What happens to the plan, said as a plan claim and never a health claim.
  final String effect;

  /// Read a stored stance back into one of the three answers.
  ///
  /// The backend has a fourth value, `never`, which no button here can produce
  /// — it is a hard exclusion set elsewhere. It folds into [disliked] because
  /// that is what it does to the plan, and showing it as anything else would
  /// tell somebody we are still considering a food we are not.
  ///
  /// Anything unrecognised reads as [okay]. Not as a guess: neutral is the
  /// stance that changes nothing, so an answer we cannot interpret is shown as
  /// the one that claims nothing.
  static TasteStance fromWire(Object? value) {
    if (value == 'never') {
      return TasteStance.disliked;
    }
    return TasteStance.values.firstWhere(
      (TasteStance e) => e.wire == value,
      orElse: () => TasteStance.okay,
    );
  }
}

/// One food, and what we believe about it. `GET /v1/feedback/preferences`.
///
/// [name] is resolved server-side from the `foods` table and is never an id: the
/// whole point of the tastes screen is that a belief is something a person can
/// recognise and correct, and a list of uuids is neither.
class FoodPreference {
  const FoodPreference({
    required this.foodId,
    required this.name,
    required this.stance,
    this.score = 0,
  });

  final String foodId;
  final String name;
  final TasteStance stance;

  /// The 0–5 the planner actually reads. Kept because it is the truth of the
  /// row, even though the screen shows the stance rather than the number — a
  /// score is not something anybody asked to see.
  final double score;

  factory FoodPreference.fromJson(Map<String, dynamic> json) => FoodPreference(
        foodId: asString(json['food_id']),
        name: asString(json['name']),
        stance: TasteStance.fromWire(json['stance']),
        score: asDouble(json['score']),
      );

  Map<String, dynamic> toJson() => prune(<String, dynamic>{
        'food_id': foodId,
        'name': name,
        'stance': stance.wire,
        'score': score,
      });
}

/// What came back from rating one logged meal.
///
/// [preferenceUpdated] is the field that matters, and it is the reason this is a
/// small object rather than nothing at all. A meal logged as free text, or from
/// a photo, has no `food_id` — so the rating is stored against that meal and
/// **no preference moves**. The backend says so plainly, and the screen has to
/// say so too: telling somebody we learned something when the food is not in
/// our list is a claim about the future we cannot keep.
class MealRating {
  const MealRating({
    required this.foodLogId,
    required this.rating,
    this.preferenceUpdated = false,
    this.stance,
  });

  final String foodLogId;
  final int rating;

  /// True only when a food preference the planner reads actually changed.
  final bool preferenceUpdated;

  /// Where the food ended up, or null when nothing moved.
  final TasteStance? stance;

  factory MealRating.fromJson(Map<String, dynamic> json) {
    final bool updated = asBool(json['preference_updated']);
    return MealRating(
      foodLogId: asString(json['food_log_id']),
      rating: asInt(json['rating']),
      preferenceUpdated: updated,
      // Only read when something moved, so a stray stance on a reply that said
      // nothing changed cannot become a sentence claiming it did.
      stance: updated ? TasteStance.fromWire(json['stance']) : null,
    );
  }
}

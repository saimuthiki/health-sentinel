"""Candidate food selection for the planner.

**No language model is involved anywhere in this file.** The model never chooses which
foods are *allowed* -- it only arranges the shortlist this module hands it
(``docs/04-ai-pipeline.md`` stage 6: "It composes meals only from CANDIDATES").

Two jobs, in this order and never the other way round:

1. **Filter** -- diet type, allergens, foods the user has marked ``never``, foods they
   dislike. This is a safety gate. It fails **closed**: anything we cannot prove is safe
   for this person is left out.
2. **Rank** -- how much of the day's outstanding gaps a food closes, plus how much the
   user likes it. This is a preference, and it can never re-admit something filtered.

Because the list is bounded (300 by default) the planning prompt stays small and cheap,
which is the other half of why this module exists.
"""

from __future__ import annotations

import re
import unicodedata
from collections.abc import Iterable, Sequence
from dataclasses import dataclass

from app.domain.enums import DietType, Stance
from app.domain.models import FoodItem, FoodPreference, HealthProfile, NutrientGap
from app.nutrition.gaps import GapReport

__all__ = [
    "ALLERGEN_SYNONYMS",
    "DEFAULT_LIMIT",
    "DIET_ALLOWED_FLAGS",
    "DISLIKE_SCORE_THRESHOLD",
    "Rejection",
    "ScoredFood",
    "allergen_tokens",
    "filter_foods",
    "rank_foods",
    "select_candidates",
]

DEFAULT_LIMIT = 300

#: A food the user rated below this, and marked as disliked, is not offered again.
DISLIKE_SCORE_THRESHOLD = 2.0

#: How much a strong "like" can lift a food up the ranking. Kept smaller than the gap
#: contribution so that a favourite food cannot bury the nutrient the person needs.
LIKE_WEIGHT = 0.6


# ------------------------------------------------------------------------------ diet

#: Which ``foods.diet_flags`` values a diet type may eat. A food carrying **no** flags
#: is excluded for every restricted diet -- unknown is not the same as allowed.
DIET_ALLOWED_FLAGS: dict[DietType, frozenset[str] | None] = {
    DietType.NON_VEG: None,  # None means "no restriction"
    DietType.EGG: frozenset({"veg", "vegan", "jain", "egg"}),
    DietType.VEG: frozenset({"veg", "vegan", "jain"}),
    DietType.VEGAN: frozenset({"vegan"}),
    DietType.JAIN: frozenset({"jain"}),
}


def diet_allows(food: FoodItem, diet_type: DietType) -> bool:
    allowed = DIET_ALLOWED_FLAGS.get(diet_type, frozenset())
    if allowed is None:
        return True
    flags = {flag.strip().lower() for flag in food.diet_flags if flag}
    return bool(flags & allowed)


# ------------------------------------------------------------------------- allergens

_NON_WORD = re.compile(r"[^a-z0-9]+")

#: Canonical allergen -> the words people and labs actually write. Both the user's
#: allergy rows and the food's allergen list are folded through this table, so
#: "groundnut", "moongphali" and "peanuts" are all the same thing.
ALLERGEN_SYNONYMS: dict[str, frozenset[str]] = {
    "peanut": frozenset(
        {"peanut", "peanuts", "groundnut", "groundnuts", "moongphali", "mungfali",
         "arachis", "peanut oil", "groundnut oil"}
    ),
    "tree_nut": frozenset(
        {"tree nut", "tree nuts", "treenut", "nut", "nuts", "almond", "almonds",
         "badam", "cashew", "cashews", "kaju", "walnut", "walnuts", "akhrot",
         "pistachio", "pista", "hazelnut", "pecan", "macadamia", "brazil nut"}
    ),
    "milk": frozenset(
        {"milk", "dairy", "lactose", "casein", "whey", "curd", "dahi", "yoghurt",
         "yogurt", "paneer", "cheese", "butter", "ghee", "cream", "khoya", "buttermilk"}
    ),
    "egg": frozenset({"egg", "eggs", "anda", "albumin", "egg white", "egg yolk"}),
    "wheat": frozenset(
        {"wheat", "gluten", "atta", "maida", "suji", "semolina", "rava", "barley",
         "rye", "seitan", "daliya"}
    ),
    "soy": frozenset({"soy", "soya", "soybean", "soyabean", "tofu", "edamame", "miso"}),
    "fish": frozenset(
        {"fish", "machli", "machhli", "anchovy", "anchovies", "tuna", "salmon",
         "sardine", "rohu", "surmai", "pomfret"}
    ),
    "shellfish": frozenset(
        {"shellfish", "prawn", "prawns", "shrimp", "jhinga", "crab", "lobster",
         "squid", "calamari", "mussel", "oyster", "clam"}
    ),
    "sesame": frozenset({"sesame", "til", "tahini", "gingelly", "sesame oil"}),
    "mustard": frozenset({"mustard", "sarson", "rai", "mustard oil"}),
    "sulphite": frozenset({"sulphite", "sulfite", "sulphites", "sulfites"}),
    "mushroom": frozenset({"mushroom", "mushrooms", "khumb"}),
    "brinjal": frozenset({"brinjal", "eggplant", "aubergine", "baingan"}),
    "banana": frozenset({"banana", "kela", "plantain"}),
    "corn": frozenset({"corn", "maize", "makka", "makkai", "cornflour"}),
}

_ALLERGEN_LOOKUP: dict[str, str] = {
    variant: canonical
    for canonical, variants in ALLERGEN_SYNONYMS.items()
    for variant in variants
}


def _fold(text: str) -> str:
    folded = unicodedata.normalize("NFKD", text)
    folded = "".join(ch for ch in folded if not unicodedata.combining(ch))
    return _NON_WORD.sub(" ", folded.lower()).strip()


def allergen_tokens(raw: str) -> set[str]:
    """Every token an allergen string should be treated as.

    Returns the canonical family *and* the literal words, so an allergen we have never
    seen before still matches itself. Nothing is dropped: an unrecognised allergen must
    not become a silent "safe".
    """
    text = _fold(raw)
    if not text:
        return set()
    tokens = {text}
    tokens.update(text.split())
    canonical = {_ALLERGEN_LOOKUP[token] for token in tokens if token in _ALLERGEN_LOOKUP}
    tokens |= canonical
    for family in canonical:
        tokens |= {_fold(word) for word in ALLERGEN_SYNONYMS[family]}
    return {token for token in tokens if token}


def _profile_allergen_tokens(profile: HealthProfile) -> set[str]:
    tokens: set[str] = set()
    for allergy in profile.allergies:
        tokens |= allergen_tokens(allergy.allergen)
    return tokens


def _food_allergen_tokens(food: FoodItem) -> set[str]:
    tokens: set[str] = set()
    for allergen in food.allergens:
        tokens |= allergen_tokens(allergen)
    # The food's own name is checked too. Allergen columns get missed when reference
    # data is imported; a name match is a cheap second line of defence, and the cost of
    # wrongly excluding a food is that the user sees one fewer option.
    for word in _fold(food.name).split():
        tokens.add(word)
        if word in _ALLERGEN_LOOKUP:
            tokens.add(_ALLERGEN_LOOKUP[word])
    tokens.add(_fold(food.name))
    return {token for token in tokens if token}


def contains_allergen(food: FoodItem, user_tokens: set[str]) -> bool:
    """Does this food touch anything the user reacts to? Errs towards yes."""
    if not user_tokens:
        return False
    food_tokens = _food_allergen_tokens(food)
    if food_tokens & user_tokens:
        return True
    # Substring fallback for compound words ("peanutbutter", "soyachunks").
    for user_token in user_tokens:
        if len(user_token) < 4:
            continue
        for food_token in food_tokens:
            if user_token in food_token or (
                len(food_token) >= 4 and food_token in user_token
            ):
                return True
    return False


# --------------------------------------------------------------------------- filtering


@dataclass(frozen=True)
class Rejection:
    """A food that did not make the shortlist, and the reason. Kept for the audit
    trail and for the "why did my plan change?" screen."""

    food: FoodItem
    reason: str


def filter_foods(
    foods: Iterable[FoodItem],
    profile: HealthProfile,
    preferences: Sequence[FoodPreference] = (),
    *,
    dislike_threshold: float = DISLIKE_SCORE_THRESHOLD,
) -> tuple[list[FoodItem], list[Rejection]]:
    """Apply every hard filter. Returns ``(allowed, rejected)``."""
    stance_by_id = {pref.food_id: pref for pref in preferences}
    user_allergens = _profile_allergen_tokens(profile)

    allowed: list[FoodItem] = []
    rejected: list[Rejection] = []

    for food in foods:
        if contains_allergen(food, user_allergens):
            rejected.append(Rejection(food, "allergen"))
            continue
        if not diet_allows(food, profile.diet_type):
            rejected.append(Rejection(food, f"diet:{profile.diet_type.value}"))
            continue
        pref = stance_by_id.get(food.id)
        if pref is not None:
            if pref.stance is Stance.NEVER:
                rejected.append(Rejection(food, "stance:never"))
                continue
            if pref.stance is Stance.DISLIKE and pref.score < dislike_threshold:
                rejected.append(Rejection(food, "disliked"))
                continue
        allowed.append(food)

    return allowed, rejected


# ----------------------------------------------------------------------------- ranking


@dataclass(frozen=True)
class ScoredFood:
    food: FoodItem
    score: float
    gap_score: float
    like_score: float


def _deficits(
    gaps: GapReport | Sequence[NutrientGap] | None,
) -> dict[str, tuple[float, float]]:
    """nutrient -> (deficit used for ranking, target)."""
    if gaps is None:
        return {}
    if isinstance(gaps, GapReport):
        return {
            gap.nutrient: (gaps.effective_deficit(gap.nutrient), gap.target)
            for gap in gaps.gaps
        }
    return {gap.nutrient: (gap.deficit, gap.target) for gap in gaps}


def rank_foods(
    foods: Iterable[FoodItem],
    gaps: GapReport | Sequence[NutrientGap] | None = None,
    preferences: Sequence[FoodPreference] = (),
    *,
    portion_g: float = 100.0,
) -> list[ScoredFood]:
    """Score foods by gap closure plus liking. Highest first, ties by name."""
    deficits = _deficits(gaps)
    prefs = {pref.food_id: pref for pref in preferences}

    scored: list[ScoredFood] = []
    for food in foods:
        nutrients = food.nutrients_for(portion_g)
        gap_score = 0.0
        for nutrient, (deficit, _target) in deficits.items():
            if deficit <= 0:
                continue
            supplied = float(nutrients.get(nutrient, 0.0))
            if supplied <= 0:
                continue
            gap_score += min(1.0, supplied / deficit)

        pref = prefs.get(food.id)
        like_score = 0.0
        if pref is not None and pref.stance is Stance.LIKE:
            like_score = max(0.0, min(1.0, pref.score / 5.0))
        elif pref is not None and pref.stance is Stance.DISLIKE:
            like_score = -max(0.0, min(1.0, (5.0 - pref.score) / 5.0))

        scored.append(
            ScoredFood(
                food=food,
                score=gap_score + LIKE_WEIGHT * like_score,
                gap_score=gap_score,
                like_score=like_score,
            )
        )

    scored.sort(key=lambda item: (-item.score, item.food.name.lower(), item.food.id))
    return scored


def select_candidates(
    foods: Iterable[FoodItem],
    profile: HealthProfile,
    *,
    gaps: GapReport | Sequence[NutrientGap] | None = None,
    preferences: Sequence[FoodPreference] = (),
    limit: int = DEFAULT_LIMIT,
    dislike_threshold: float = DISLIKE_SCORE_THRESHOLD,
) -> list[FoodItem]:
    """The bounded, filtered, ranked food list the planning prompt is given.

    The filter runs first and the ranking cannot undo it, so no food on this list can be
    one the user is allergic to, one their diet excludes, or one they told us never to
    suggest again.
    """
    allowed, _rejected = filter_foods(
        foods, profile, preferences, dislike_threshold=dislike_threshold
    )
    ranked = rank_foods(allowed, gaps, preferences)
    return [scored.food for scored in ranked[: max(0, limit)]]


def selection_report(
    foods: Iterable[FoodItem],
    profile: HealthProfile,
    *,
    gaps: GapReport | Sequence[NutrientGap] | None = None,
    preferences: Sequence[FoodPreference] = (),
    limit: int = DEFAULT_LIMIT,
    dislike_threshold: float = DISLIKE_SCORE_THRESHOLD,
) -> tuple[list[ScoredFood], list[Rejection]]:
    """:func:`select_candidates` with the scores and the rejection reasons kept."""
    allowed, rejected = filter_foods(
        foods, profile, preferences, dislike_threshold=dislike_threshold
    )
    ranked = rank_foods(allowed, gaps, preferences)
    return ranked[: max(0, limit)], rejected

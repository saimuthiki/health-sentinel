"""The only sanctioned path for a nutrient number that a user will see.

**No language model is involved anywhere in this file.** Every number produced here is
``grams / 100 * per_100g_value`` over rows from the ``foods`` reference table.

``CLAUDE.md``: *"Nutrient numbers shown to the user come from the ``foods`` table, never
from model free-text. The backend recomputes totals and overwrites anything the model
claimed."* :func:`recompute_plan_items` is that overwrite, and it is deliberately
destructive: whatever the model put in ``computed_nutrients`` or ``why_text`` is thrown
away before anything is stored or displayed.
"""

from __future__ import annotations

from collections.abc import Iterable, Mapping, Sequence
from dataclasses import dataclass
from dataclasses import field as dc_field
from datetime import datetime

from pydantic import BaseModel, ConfigDict

from app.domain.enums import MealSlot
from app.domain.models import FoodItem, MealPlanItem, NutrientGap
from app.nutrition.why import why_sentence

__all__ = [
    "MAX_ITEM_GRAMS",
    "ConsumedItem",
    "DiscardedItem",
    "RecomputedPlan",
    "day_total",
    "index_foods",
    "intake_from_logs",
    "meal_totals",
    "nutrients_for",
    "pct_of_gaps_closed",
    "recompute_plan_items",
    "sum_nutrients",
]

#: A single plate of one food. Anything larger is a transcription or model error, and we
#: would rather drop the item than publish a 5,000 kcal breakfast.
MAX_ITEM_GRAMS = 1500.0


class ConsumedItem(BaseModel):
    """One thing a user actually ate, resolved to a food id.

    Local to ``app.nutrition``: it is the in-memory shape of a ``food_logs`` row that
    has been matched to the ``foods`` table. Rows still sitting as free text or an
    unmatched photo have no nutrient numbers and must not appear here.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    food_id: str
    grams: float
    meal_slot: MealSlot | None = None
    logged_at: datetime | None = None
    source: str = "manual"


FoodIndex = Mapping[str, FoodItem]


def index_foods(foods: Iterable[FoodItem]) -> dict[str, FoodItem]:
    """Build the id -> food lookup used by everything else in this module."""
    return {food.id: food for food in foods}


def nutrients_for(food: FoodItem, grams: float) -> dict[str, float]:
    """Nutrients for a portion. A thin, named wrapper over
    :meth:`FoodItem.nutrients_for` so that greps for "nutrient maths" land here."""
    return food.nutrients_for(grams)


def sum_nutrients(parts: Iterable[Mapping[str, float]]) -> dict[str, float]:
    """Add up nutrient dictionaries, keeping every key that appears in any of them."""
    total: dict[str, float] = {}
    for part in parts:
        for key, value in part.items():
            total[key] = total.get(key, 0.0) + float(value)
    return total


def _portions(
    items: Iterable[ConsumedItem], foods: FoodIndex
) -> list[tuple[ConsumedItem, dict[str, float]]]:
    resolved: list[tuple[ConsumedItem, dict[str, float]]] = []
    for item in items:
        food = foods.get(item.food_id)
        if food is None or item.grams <= 0:
            continue
        resolved.append((item, food.nutrients_for(item.grams)))
    return resolved


def meal_totals(
    items: Iterable[ConsumedItem], foods: FoodIndex
) -> dict[MealSlot | None, dict[str, float]]:
    """Per-meal nutrient totals. Items with no meal slot are grouped under ``None``."""
    totals: dict[MealSlot | None, dict[str, float]] = {}
    for item, nutrients in _portions(items, foods):
        bucket = totals.setdefault(item.meal_slot, {})
        for key, value in nutrients.items():
            bucket[key] = bucket.get(key, 0.0) + value
    return totals


def day_total(items: Iterable[ConsumedItem], foods: FoodIndex) -> dict[str, float]:
    """Whole-day nutrient totals."""
    return sum_nutrients(nutrients for _, nutrients in _portions(items, foods))


def intake_from_logs(
    logs: Iterable[ConsumedItem], foods: FoodIndex
) -> dict[str, float]:
    """What the user actually ate, as a nutrient dictionary. Alias of
    :func:`day_total`, named for the caller in :mod:`app.nutrition.gaps`."""
    return day_total(logs, foods)


def pct_of_gaps_closed(
    nutrients: Mapping[str, float], gaps: Sequence[NutrientGap]
) -> dict[str, float]:
    """What percentage of each outstanding gap this portion closes.

    A gap with nothing left to close is omitted rather than reported as 100% -- there is
    no honest percentage of zero.
    """
    closed: dict[str, float] = {}
    for gap in gaps:
        deficit = gap.deficit
        if deficit <= 0:
            continue
        supplied = float(nutrients.get(gap.nutrient, 0.0))
        if supplied <= 0:
            continue
        closed[gap.nutrient] = min(100.0, supplied / deficit * 100.0)
    return closed


# ------------------------------------------------------------------ plan recomputation


@dataclass(frozen=True)
class DiscardedItem:
    """A model-proposed item we refused, and why. Surfaced so it can be logged."""

    item: MealPlanItem
    reason: str


@dataclass(frozen=True)
class RecomputedPlan:
    """The result of :func:`recompute_plan_items`.

    ``discarded`` is not an error list to be swallowed -- the caller logs it, because a
    model that keeps inventing food ids is a prompt problem worth seeing.
    """

    items: list[MealPlanItem] = dc_field(default_factory=list)
    discarded: list[DiscardedItem] = dc_field(default_factory=list)
    day_totals: dict[str, float] = dc_field(default_factory=dict)
    meal_slot_totals: dict[MealSlot, dict[str, float]] = dc_field(default_factory=dict)


def recompute_plan_items(
    proposed: Sequence[MealPlanItem],
    foods: FoodIndex,
    *,
    gaps: Sequence[NutrientGap] = (),
    recipes: Mapping[str, Sequence[tuple[str, float]]] | None = None,
) -> RecomputedPlan:
    """Rebuild every nutrient number in a model-proposed plan from the foods table.

    What this function guarantees, and what the tests assert:

    * ``computed_nutrients`` is **always** replaced. Anything the model supplied is
      discarded unread -- it is never merged, never used as a fallback.
    * ``why_text`` is regenerated from those recomputed numbers by
      :func:`app.nutrition.why.why_sentence`, so the sentence a user reads cannot
      contain a number the model made up.
    * ``display_name`` is taken from the foods table, so a model cannot mislabel a food.
    * An item naming a food id (or recipe id) that is not in our tables is **dropped**,
      not repaired. A hallucinated food has no nutrition, and guessing which real food
      was meant would be exactly the silent guess the safety charter forbids.
    * Portions are clamped to ``0 < grams <= MAX_ITEM_GRAMS``.
    """
    recipes = recipes or {}
    kept: list[MealPlanItem] = []
    discarded: list[DiscardedItem] = []

    for index, item in enumerate(proposed):
        if item.grams <= 0:
            discarded.append(DiscardedItem(item, "portion size was zero or negative"))
            continue
        if item.grams > MAX_ITEM_GRAMS:
            discarded.append(
                DiscardedItem(
                    item, f"portion size {item.grams:g} g exceeds {MAX_ITEM_GRAMS:g} g"
                )
            )
            continue

        components: list[tuple[FoodItem, float]] = []
        display = item.display_name

        if item.food_id is not None:
            food = foods.get(item.food_id)
            if food is None:
                discarded.append(
                    DiscardedItem(
                        item, f"food id {item.food_id!r} is not in the foods table"
                    )
                )
                continue
            components.append((food, item.grams))
            display = food.name
        elif item.recipe_id is not None:
            parts = recipes.get(item.recipe_id)
            if not parts:
                discarded.append(
                    DiscardedItem(
                        item, f"recipe id {item.recipe_id!r} is not in the recipes table"
                    )
                )
                continue
            base = sum(grams for _, grams in parts)
            if base <= 0:
                discarded.append(
                    DiscardedItem(item, f"recipe {item.recipe_id!r} has no ingredients")
                )
                continue
            scale = item.grams / base
            missing = [food_id for food_id, _ in parts if food_id not in foods]
            if missing:
                discarded.append(
                    DiscardedItem(
                        item,
                        f"recipe {item.recipe_id!r} uses foods not in the foods table: "
                        + ", ".join(sorted(missing)),
                    )
                )
                continue
            components = [(foods[food_id], grams * scale) for food_id, grams in parts]
        else:
            discarded.append(DiscardedItem(item, "item named neither a food nor a recipe"))
            continue

        nutrients = sum_nutrients(
            food.nutrients_for(grams) for food, grams in components
        )
        kept.append(
            item.model_copy(
                update={
                    "display_name": display,
                    "computed_nutrients": nutrients,
                    "why_text": why_sentence(nutrients, gaps, food_name=display),
                    "order_index": index,
                }
            )
        )

    slot_totals: dict[MealSlot, dict[str, float]] = {}
    for item in kept:
        bucket = slot_totals.setdefault(item.meal_slot, {})
        for key, value in item.computed_nutrients.items():
            bucket[key] = bucket.get(key, 0.0) + value

    return RecomputedPlan(
        items=kept,
        discarded=discarded,
        day_totals=sum_nutrients(item.computed_nutrients for item in kept),
        meal_slot_totals=slot_totals,
    )

"""What a generated recipe may say, checked deterministically.

The problem this module exists for is arithmetic, not safety.

A plan item is **one food from the ``foods`` table at a weight in grams**, and every
nutrient number on the Plan screen is recomputed from that one row by
:func:`app.nutrition.compute.recompute_plan_items`. A generated method that says "two
tablespoons of oil" has quietly changed the meal, and the screen would then be showing
the plan's calories beside a recipe that does not produce them. The two would contradict
each other and neither would be marked as wrong.

There is no honest way to reconcile them from here: the planner never populates
``recipe_id`` (see :func:`app.planner.service.parse_plan_items`), so there is no
``recipe_items`` row to recompute from, and inviting a model to invent ingredient weights
would be putting nutrient numbers back into model output -- exactly what CLAUDE.md
forbids. So the feature takes the other road, and takes it structurally:

    **The recipe is a method. The numbers stay the plan's.**

Rail: **a recipe may not contain a unit of mass or volume, and may not contain a nutrient
word.** "Simmer for twenty minutes" is fine -- time is not a quantity of food. "One cup of
rice" is not. The single quantity on the screen is the plan's own ``grams``, printed by us
in Python beside the method, and the screen says in as many words that the amounts are the
plan's rather than the recipe's.

Two further rails, from the charter rather than from arithmetic:

* **no health claim** -- "good for hair growth", "rich in iron", "helps digestion". A
  recipe is instructions. Why a food helps is already written by
  :func:`app.nutrition.why.why_sentence` from the ``foods`` table, and that is where it
  stays.
* **no medicine or supplement word at all.** The safety validator catches a drug name and
  catches a dose; this catches "add a supplement", which is neither and still has no
  business in a method.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

#: Units of mass and volume. Cooking measures included: a tablespoon of oil moves a meal's
#: energy as surely as a gram does.
MEASURE_WORDS: tuple[str, ...] = (
    "g", "gm", "gms", "gram", "grams", "kg", "kilo", "kilos", "kilogram", "kilograms",
    "mg", "mcg", "ug", "µg", "iu",
    "ml", "millilitre", "millilitres", "milliliter", "milliliters",
    "l", "litre", "litres", "liter", "liters",
    "cup", "cups", "cupful",
    "tbsp", "tablespoon", "tablespoons", "tblsp",
    "tsp", "teaspoon", "teaspoons",
    "oz", "ounce", "ounces", "lb", "pound", "pounds",
    "katori", "vati", "ladle", "ladleful", "scoop", "scoops",
)

#: Nutrient and energy words. A method never needs one.
#:
#: "iron", "fat" and "sodium" are deliberately absent: a cast-iron kadhai, trimming the
#: fat and salt are all ordinary cooking language, and a rail that rejects real
#: instructions costs the reader a recipe for nothing. None of the three can carry a
#: number past this module anyway, because every unit is banned, and "rich in iron" and
#: "low in fat" are caught as claims below.
NUTRIENT_WORDS: tuple[str, ...] = (
    "calorie", "calories", "kcal", "kilocalorie", "kilocalories", "energy",
    "protein", "proteins", "carb", "carbs", "carbohydrate", "carbohydrates",
    "fibre", "fiber", "calcium", "zinc", "magnesium",
    "potassium", "folate", "vitamin", "vitamins", "b12", "omega",
    "macro", "macros", "micronutrient", "micronutrients", "nutrient", "nutrients",
    "glycemic", "glycaemic",
)

#: Claims about what food does to a body.
CLAIM_PHRASES: tuple[str, ...] = (
    "good for",
    "great for",
    "helps with",
    "helps your",
    "helps to",
    "boosts",
    "boost your",
    "improves your",
    "strengthens",
    "builds your",
    "prevents",
    "cures",
    "treats",
    "heals",
    "detox",
    "detoxes",
    "detoxifies",
    "aids digestion",
    "aids in",
    "reduces your",
    "lowers your",
    "raises your",
    "rich in",
    "packed with",
    "loaded with",
    "high in",
    "low in",
    "source of",
    "immunity",
    "metabolism",
    "weight loss",
    "hair growth",
    "skin glow",
    "anti inflammatory",
    "anti-inflammatory",
    "superfood",
)

#: Medicine and supplement vocabulary, with no number needed to make it wrong here.
MEDICINE_WORDS: tuple[str, ...] = (
    "supplement", "supplements", "tablet", "tablets", "capsule", "capsules",
    "syrup", "sachet", "sachets", "dose", "dosage", "medicine", "medication",
    "prescription", "prescribed", "injection", "tonic",
)


def _matcher(words: tuple[str, ...]) -> re.Pattern[str]:
    ordered = sorted({w.lower() for w in words}, key=lambda w: (-len(w), w))
    body = "|".join(re.escape(w).replace(r"\ ", r"\s+") for w in ordered)
    # The alternation MUST stay inside a group: without one, `|` binds looser
    # than the boundary look-arounds and only the first and last branch keep
    # them -- which is how a bare "l" starts matching the middle of words.
    # No letter or digit either side, so "gram" does not fire on "programme" and "l"
    # does not fire on every word containing one.
    return re.compile(rf"(?<![A-Za-z0-9])(?:{body})(?![A-Za-z0-9])", re.IGNORECASE)


_MEASURE_RE = _matcher(MEASURE_WORDS)
_NUTRIENT_RE = _matcher(NUTRIENT_WORDS)
_CLAIM_RE = _matcher(CLAIM_PHRASES)
_MEDICINE_RE = _matcher(MEDICINE_WORDS)


@dataclass(frozen=True)
class RecipeRailFinding:
    rule: str
    excerpt: str

    def __str__(self) -> str:
        return f"{self.rule}: {self.excerpt!r}"


def check_recipe_text(text: str) -> list[RecipeRailFinding]:
    """Every rail the candidate recipe breaks. Empty means it may be stored and shown."""
    cleaned = (text or "").strip()
    if not cleaned:
        return [RecipeRailFinding("empty", "")]
    found: list[RecipeRailFinding] = []
    for rule, pattern in (
        ("measurement", _MEASURE_RE),
        ("nutrient_word", _NUTRIENT_RE),
        ("health_claim", _CLAIM_RE),
        ("medicine_word", _MEDICINE_RE),
    ):
        match = pattern.search(cleaned)
        if match is not None:
            found.append(RecipeRailFinding(rule, match.group(0)))
    return found


def feedback_for(findings: list[RecipeRailFinding]) -> str:
    """The instruction for the one retry the safety pipeline allows."""
    reasons = "\n".join(f"- {finding}" for finding in findings)
    return (
        "Your previous recipe was rejected before anybody read it, for these reasons:\n"
        f"{reasons}\n\n"
        "Write it again with no weights and no measures of any kind -- no grams, no "
        "millilitres, no cups, no spoons. The app prints the portion itself from the "
        "person's plan. Say amounts as method instead: 'enough water to cover', 'a little "
        "oil', 'salt to taste'. Do not mention any nutrient, any calorie count, anything a "
        "food is good for, or any medicine or supplement. Instructions only."
    )


__all__ = [
    "CLAIM_PHRASES",
    "MEASURE_WORDS",
    "MEDICINE_WORDS",
    "NUTRIENT_WORDS",
    "RecipeRailFinding",
    "check_recipe_text",
    "feedback_for",
]

"""The "why this food" sentence -- pure string formatting over recomputed numbers.

**No language model is involved anywhere in this file.** Every figure in the sentence
comes from :mod:`app.nutrition.compute`, which got it from the ``foods`` table.

    >>> why_sentence({"protein_g": 18.0, "fibre_g": 4.2, "iron_mg": 1.86},
    ...              [NutrientGap(nutrient="iron_mg", target=19.0, current=13.0,
    ...                           unit="mg")])
    "18 g protein, 4.2 g fibre, covers 31% of today's iron gap"

The sentence is deliberately a list of facts, not advice. It never contains a verb in
the imperative and never contains a dose, because ``CLAUDE.md`` forbids the app from
prescribing anything -- and because a factual fragment is the one thing we can always
stand behind.
"""

from __future__ import annotations

from typing import Mapping, Sequence

from app.domain.models import NutrientGap

__all__ = [
    "NUTRIENT_LABELS",
    "format_amount",
    "nutrient_unit",
    "why_sentence",
]

#: Plain-English name for each nutrient key, and the unit its key encodes.
NUTRIENT_LABELS: dict[str, str] = {
    "kcal": "energy",
    "protein_g": "protein",
    "fat_g": "fat",
    "carb_g": "carbohydrate",
    "fibre_g": "fibre",
    "iron_mg": "iron",
    "calcium_mg": "calcium",
    "vitamin_d_ug": "vitamin D",
    "b12_ug": "vitamin B12",
    "folate_ug": "folate",
    "zinc_mg": "zinc",
    "magnesium_mg": "magnesium",
    "potassium_mg": "potassium",
    "vitamin_c_mg": "vitamin C",
    "vitamin_a_ug": "vitamin A",
}

_UNIT_BY_SUFFIX = {"_g": "g", "_mg": "mg", "_ug": "ug", "_ml": "ml"}

#: Which nutrients are worth putting in a sentence, best first. Energy is deliberately
#: last: a coaching sentence about a food is more useful when it leads with what the
#: food gives you.
_HEADLINE_ORDER: tuple[str, ...] = (
    "protein_g",
    "fibre_g",
    "iron_mg",
    "calcium_mg",
    "vitamin_d_ug",
    "b12_ug",
    "folate_ug",
    "zinc_mg",
    "vitamin_c_mg",
    "kcal",
)

#: Amounts below this are not worth a sentence -- "0.03 g iron" is noise.
_MIN_WORTH_SAYING: dict[str, float] = {
    "kcal": 10.0,
    "protein_g": 1.0,
    "fibre_g": 0.5,
    "iron_mg": 0.3,
    "calcium_mg": 20.0,
    "vitamin_d_ug": 0.2,
    "b12_ug": 0.1,
    "folate_ug": 10.0,
    "zinc_mg": 0.3,
    "vitamin_c_mg": 2.0,
}

#: A gap clause is only added when the portion makes a difference worth naming.
MIN_GAP_PCT = 5.0


def nutrient_unit(nutrient: str) -> str:
    if nutrient == "kcal":
        return "kcal"
    for suffix, unit in _UNIT_BY_SUFFIX.items():
        if nutrient.endswith(suffix):
            return unit
    return ""


def format_amount(nutrient: str, value: float) -> str:
    """Round the way a person would say it: '18 g', '4.2 g', '210 kcal'."""
    unit = nutrient_unit(nutrient)
    if nutrient == "kcal":
        return f"{round(value):g} kcal"
    if value >= 10:
        text = f"{round(value):g}"
    else:
        text = f"{round(value, 1):g}"
    return f"{text} {unit}".strip()


def _gap_clause(
    nutrients: Mapping[str, float], gaps: Sequence[NutrientGap]
) -> tuple[str, str] | None:
    """The single biggest gap this portion closes, as ``(nutrient, clause)``."""
    best: tuple[float, str, str] | None = None
    for gap in gaps:
        deficit = gap.deficit
        if deficit <= 0:
            continue
        supplied = float(nutrients.get(gap.nutrient, 0.0))
        if supplied <= 0:
            continue
        pct = min(100.0, supplied / deficit * 100.0)
        if pct < MIN_GAP_PCT:
            continue
        label = NUTRIENT_LABELS.get(gap.nutrient, gap.nutrient)
        clause = f"covers {round(pct):g}% of today's {label} gap"
        if best is None or pct > best[0]:
            best = (pct, gap.nutrient, clause)
    if best is None:
        return None
    return best[1], best[2]


def why_sentence(
    nutrients: Mapping[str, float],
    gaps: Sequence[NutrientGap] = (),
    *,
    food_name: str | None = None,
    max_nutrients: int = 2,
) -> str:
    """Build the sentence shown under a planned food.

    ``food_name`` is accepted so the caller can pass it, but it is only used when there
    is nothing else to say -- the sentence sits directly under the food's name in the
    app, so repeating it reads badly.
    """
    gap_pick = _gap_clause(nutrients, gaps)
    gap_nutrient = gap_pick[0] if gap_pick else None

    parts: list[str] = []
    for nutrient in _HEADLINE_ORDER:
        if len(parts) >= max_nutrients:
            break
        if nutrient == gap_nutrient:
            continue  # the gap clause already says this one, and better
        value = float(nutrients.get(nutrient, 0.0))
        if value < _MIN_WORTH_SAYING.get(nutrient, 0.0):
            continue
        label = NUTRIENT_LABELS.get(nutrient, nutrient)
        parts.append(f"{format_amount(nutrient, value)} {label}")

    if gap_pick:
        parts.append(gap_pick[1])

    if not parts:
        if food_name:
            return f"We do not hold nutrient values for {food_name} yet."
        return "We do not hold nutrient values for this item yet."
    return ", ".join(parts)

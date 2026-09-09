"""The week's shopping list, derived from the plans that already exist.

Pure arithmetic over stored plan items: no model call, no invented quantities. A food
appearing in four meals becomes one line with the grams added up, grouped by the aisle
its food group implies so the list is walkable.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date, timedelta

from app.domain.models import MealPlanItem

#: Below this a line is not worth writing down; spices and garnishes.
MIN_LINE_GRAMS = 5.0

#: Buy a little more than the plan needs, because portions are never exact.
BUFFER = 1.1


@dataclass(frozen=True)
class GroceryLine:
    food_id: str
    quantity: float
    unit: str
    aisle: str

    def as_row(self) -> dict[str, object]:
        return {
            "food_id": self.food_id,
            "quantity": round(self.quantity, 2),
            "unit": self.unit,
            "aisle": self.aisle,
            "state": "need",
        }


def week_dates(week_start: date) -> list[date]:
    return [week_start + timedelta(days=offset) for offset in range(7)]


def build_lines(
    items: list[MealPlanItem],
    aisles: dict[str, str],
    *,
    pantry: dict[str, float] | None = None,
) -> list[GroceryLine]:
    """Sum the plan's portions per food, take off what the pantry already holds."""
    totals: dict[str, float] = {}
    for item in items:
        if not item.food_id or item.grams <= 0:
            continue
        totals[item.food_id] = totals.get(item.food_id, 0.0) + item.grams

    have = pantry or {}
    lines: list[GroceryLine] = []
    for food_id, grams in totals.items():
        needed = grams * BUFFER - float(have.get(food_id, 0.0))
        if needed < MIN_LINE_GRAMS:
            continue
        lines.append(
            GroceryLine(
                food_id=food_id,
                quantity=needed,
                unit="g",
                aisle=aisles.get(food_id, "Other"),
            )
        )
    lines.sort(key=lambda line: (line.aisle.lower(), line.food_id))
    return lines

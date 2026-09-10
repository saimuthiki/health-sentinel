"""The week's shopping list, derived from the plans that already exist.

Pure arithmetic over stored plan items: no model call, no invented quantities. A food
appearing in four meals becomes one line with the grams added up, grouped by the aisle
its food group implies so the list is walkable.

Two numbers per line, not one. What the week *needs* is the sum of the portions plus a
buffer; what has to be *brought home* is that, less whatever the kitchen already holds
(``pantry_items``, via :func:`pantry_credit`). Keeping them apart is what lets a line
say "you already have 400 g, bring 600 g" instead of quietly shrinking with no
explanation -- and it is what lets a line that is fully covered still be shown, and
therefore unticked when it turns out the jar was empty.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime, timedelta

from app.domain.models import MealPlanItem

#: Below this a line is not worth writing down; spices and garnishes.
MIN_LINE_GRAMS = 5.0

#: Buy a little more than the plan needs, because portions are never exact.
BUFFER = 1.1

#: How long a stated "I have this at home" is still believed, in days, by
#: ``foods.food_group``.
#:
#: These are shorter than the food would physically last, on purpose, because two
#: things eat a pantry entry at once: the food spoils, and *this week's plan cooks it*.
#: A kilo of rice ticked on Monday is largely gone by Sunday however well rice keeps,
#: so believing it for a month would quietly under-buy next week's list. Erring the
#: other way costs a spare packet; erring this way means running out mid-plan, which is
#: the failure that matters. The gradient is kept, though -- a bottle of oil is still
#: believed for three weeks and a bunch of spinach for three days, which is the honest
#: difference between them.
SHELF_LIFE_DAYS: dict[str, int] = {
    "fish_seafood": 2,
    "meat_poultry": 2,
    "leafy_vegetable": 3,
    "dairy": 5,
    "egg": 5,
    "fruit": 5,
    "vegetable": 5,
    "cereal_millet": 10,
    "pulse_legume": 10,
    "nut_seed": 10,
    "sugar_sweetener": 10,
    "oil_fat": 21,
}

#: A food group we have not heard of is treated as perishable, which is the half of
#: being wrong that ends in a spare packet rather than an empty jar.
DEFAULT_SHELF_LIFE_DAYS = 5


@dataclass(frozen=True)
class GroceryLine:
    food_id: str
    #: Still to bring home: the week's requirement less what the kitchen holds.
    quantity: float
    unit: str
    aisle: str
    #: How much of the requirement the pantry already covers. Zero unless a pantry was
    #: passed in.
    have: float = 0.0

    @property
    def required(self) -> float:
        """What the week needs, before the pantry is taken off."""
        return self.quantity + self.have

    @property
    def covered(self) -> bool:
        """True when there is nothing left worth bringing home."""
        return self.quantity < MIN_LINE_GRAMS

    def as_row(self) -> dict[str, object]:
        """The ``grocery_items`` row for this line.

        ``quantity`` is the **requirement**, not the remainder. The stored row has to
        outlive today's pantry: the pantry decays daily and is subtracted again on every
        read, so a row that had already had it deducted would take it off twice. It also
        keeps the row inside ``grocery_items_quantity_check`` (``quantity > 0``), which a
        fully covered line would otherwise fail.
        """
        return {
            "food_id": self.food_id,
            "quantity": round(self.required, 2),
            "unit": self.unit,
            "aisle": self.aisle,
            "state": "have" if self.covered else "need",
        }


def week_dates(week_start: date) -> list[date]:
    return [week_start + timedelta(days=offset) for offset in range(7)]


def build_lines(
    items: list[MealPlanItem],
    aisles: dict[str, str],
    *,
    pantry: dict[str, float] | None = None,
    keep_covered: bool = False,
) -> list[GroceryLine]:
    """Sum the plan's portions per food, take off what the pantry already holds.

    ``keep_covered`` decides what happens to a food the pantry covers entirely. Left
    False, it drops off the list, which is what a caller adding up a shop wants. Set
    True -- as the endpoint does -- the line stays with ``quantity`` zero and the whole
    requirement in :attr:`GroceryLine.have`, so the person can see that it was
    considered and untick it if the kitchen turns out to be emptier than they said.
    """
    totals: dict[str, float] = {}
    for item in items:
        if not item.food_id or item.grams <= 0:
            continue
        totals[item.food_id] = totals.get(item.food_id, 0.0) + item.grams

    held = pantry or {}
    lines: list[GroceryLine] = []
    for food_id, grams in totals.items():
        required = grams * BUFFER
        if required < MIN_LINE_GRAMS:
            # A pinch of something. Not worth a line whatever the pantry says.
            continue
        to_buy, covered = split_requirement(required, float(held.get(food_id, 0.0)))
        if to_buy == 0.0 and not keep_covered:
            continue
        lines.append(
            GroceryLine(
                food_id=food_id,
                quantity=to_buy,
                unit="g",
                aisle=aisles.get(food_id, "Other"),
                have=covered,
            )
        )
    lines.sort(key=lambda line: (line.aisle.lower(), line.food_id))
    return lines


def split_requirement(required: float, held: float) -> tuple[float, float]:
    """``(still to buy, covered by the pantry)`` for one line's requirement.

    The one place the subtraction happens, so a stored row read back on Thursday is
    split exactly the way it was built on Monday. A remainder under
    :data:`MIN_LINE_GRAMS` is treated as nothing left to buy rather than as a two-gram
    errand: the same threshold that keeps a pinch of asafoetida off the list.
    """
    required = max(required, 0.0)
    covered = min(max(held, 0.0), required)
    to_buy = required - covered
    if to_buy < MIN_LINE_GRAMS:
        return 0.0, required
    return to_buy, covered


def pantry_credit(
    rows: list[dict[str, object]],
    *,
    groups: dict[str, str],
    today: date,
) -> dict[str, float]:
    """``food_id -> grams still believed to be at home``, from ``pantry_items`` rows.

    A pantry entry is a claim made on a day, not a running inventory -- nothing tells us
    when the jar was actually opened. So the claim is believed in full on the day it was
    made and fades to nothing over :data:`SHELF_LIFE_DAYS` for that food's group, and the
    list quietly asks for the food again as it fades. That is deliberately the
    pessimistic reading: half credit on day five of ten means half a packet bought that
    may not have been needed, where the optimistic reading means an ingredient missing
    on the evening it is cooked.

    A row in any unit but grams is skipped rather than guessed at, and so is one whose
    ``updated_at`` cannot be read: an undated claim has no age, and an unaged claim
    cannot be decayed.
    """
    credit: dict[str, float] = {}
    for row in rows:
        food_id = str(row.get("food_id") or "")
        if not food_id:
            continue
        if str(row.get("unit") or "g") != "g":
            continue
        try:
            quantity = float(row.get("quantity") or 0.0)
        except (TypeError, ValueError):
            continue
        if quantity <= 0:
            continue
        stated_on = _as_date(row.get("updated_at"))
        if stated_on is None:
            continue
        keeps = SHELF_LIFE_DAYS.get(groups.get(food_id, ""), DEFAULT_SHELF_LIFE_DAYS)
        age = max(0, (today - stated_on).days)
        remaining = quantity * max(0.0, 1.0 - age / keeps)
        if remaining >= MIN_LINE_GRAMS:
            credit[food_id] = credit.get(food_id, 0.0) + remaining
    return credit


def _as_date(value: object) -> date | None:
    """The date part of a Postgres timestamptz, or None if it cannot be read."""
    if isinstance(value, datetime):
        return value.date()
    if isinstance(value, date):
        return value
    text = str(value or "").strip()
    if not text:
        return None
    try:
        return datetime.fromisoformat(text.replace("Z", "+00:00")).date()
    except ValueError:
        try:
            return date.fromisoformat(text[:10])
        except ValueError:
            return None

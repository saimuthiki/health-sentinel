"""The week's grocery list, and what the kitchen already holds.

Built from the plans that already exist for that week, by adding up portions --
:mod:`app.planner.grocery`. No model call, no invented quantity.

**Two numbers per line.** What the week needs is arithmetic over the plan. What has to
be brought home is that, less what the pantry holds -- so a line can say "you already
have 400 g, bring 600 g" rather than a tick box that changes nothing.

**Where the memory lives.** On ``pantry_items``, keyed on ``(user_id, food_id)``, not on
the list. ``GET ?rebuild=true`` deletes and reinserts every ``grocery_items`` row, so a
tick kept only there lasts until the next rebuild; the pantry outlives every list and is
subtracted again on every read. That is why ``have`` and ``need`` are *derived* here from
the pantry rather than read off the row: the stored ``state`` column is written to stay
honest, but it is never the authority. ``bought`` is the exception -- a purchase is
something that happened, not something to recompute -- so it is recorded in the
``health_events`` trail beside meal logs and plan progress, and replayed onto the rows a
rebuild has just recreated.

**What a stored row holds.** ``grocery_items.quantity`` is the week's *requirement*, with
the buffer, before the pantry. Storing the remainder instead would subtract the pantry
twice -- once when the row was written and again on every read -- and a fully covered
line would have to be stored at zero, which ``grocery_items_quantity_check`` forbids.
"""

from __future__ import annotations

from datetime import UTC, date, datetime, time
from typing import Annotated, Any, Literal

from fastapi import APIRouter, Depends
from pydantic import BaseModel, ConfigDict

from app.api.deps import CurrentUser, get_audit, get_gateway, get_grocery, get_plans, get_reference
from app.core.errors import NotFound
from app.domain.models import FoodItem
from app.planner.grocery import (
    build_lines,
    pantry_credit,
    split_requirement,
    week_dates,
)
from app.repositories.audit import AuditRepository
from app.repositories.base import SupabaseGateway
from app.repositories.grocery import PantryRepository
from app.repositories.plans import (
    GroceryRepository,
    PlanRepository,
    plan_item_from_row,
    week_start_for,
)
from app.repositories.reference import ReferenceRepository

router = APIRouter(prefix="/v1/grocery", tags=["grocery"])

#: The append-only record of a shop. Read back by :func:`_rebuild` so that "I bought
#: this" survives the list being rebuilt under it.
BOUGHT_EVENT = "grocery_bought"


def get_pantry(
    principal: CurrentUser,
    gateway: Annotated[SupabaseGateway, Depends(get_gateway)],
) -> PantryRepository:
    """The pantry, as the signed-in user -- the same shape as every provider in
    :mod:`app.api.deps`.

    It lives here rather than there only because ``deps.py`` is not this change's to
    edit; it belongs beside its siblings and should move when that file is free.
    """
    return PantryRepository(gateway.rest(gateway.as_user(principal)), principal.user_id)


Grocery = Annotated[GroceryRepository, Depends(get_grocery)]
Plans = Annotated[PlanRepository, Depends(get_plans)]
Reference = Annotated[ReferenceRepository, Depends(get_reference)]
Pantry = Annotated[PantryRepository, Depends(get_pantry)]
Audit = Annotated[AuditRepository, Depends(get_audit)]

State = Literal["need", "have", "bought"]


class GroceryItemOut(BaseModel):
    id: str | None = None
    food_id: str
    name: str = ""
    #: Still to bring home. Zero when the pantry covers the line.
    quantity: float
    #: How much of the requirement the kitchen is already credited with. The week's
    #: requirement is ``quantity + have``.
    have: float = 0.0
    unit: str = "g"
    aisle: str = "Other"
    state: State = "need"


class GroceryListOut(BaseModel):
    week_start: date
    status: str = "open"
    #: How many of the week's seven days have a plan behind this list.
    #:
    #: Null when this request read stored rows instead of rebuilding, because counting
    #: it then would cost seven more queries for an answer nothing needs: a list is only
    #: ever empty on a request that rebuilt it, and the empty case is the only one that
    #: has to tell an unplanned week apart from a planned week of tiny amounts.
    planned_days: int | None = None
    items: list[GroceryItemOut] = []


class StateIn(BaseModel):
    model_config = ConfigDict(extra="forbid")

    state: State


@router.get("", response_model=GroceryListOut, summary="This week's list")
async def weekly_list(
    grocery: Grocery,
    plans: Plans,
    reference: Reference,
    pantry: Pantry,
    audit: Audit,
    week_start: date | None = None,
    rebuild: bool = False,
) -> GroceryListOut:
    """Read the list, building it from the week's plans the first time it is asked for."""
    start = week_start_for(week_start or date.today())
    header = await grocery.ensure_list(start)
    list_id = str(header.get("id") or "")
    if not list_id:
        raise NotFound("We could not open a list for that week.")

    rows = await grocery.items(list_id)
    planned_days: int | None = None
    if rebuild or not rows:
        rows, planned_days = await _rebuild(
            start, list_id, grocery, plans, reference, pantry, audit
        )

    food_ids = [str(row.get("food_id")) for row in rows if row.get("food_id")]
    foods = await _foods(food_ids, reference)
    # Taken off again on every read, not once when the row was written: the credit
    # fades day by day, so Thursday's list asks for a little more than Monday's did.
    credit = pantry_credit(
        await pantry.for_foods(food_ids), groups=_groups(foods), today=date.today()
    )
    return GroceryListOut(
        week_start=start,
        status=str(header.get("status") or "open"),
        planned_days=planned_days,
        items=[_item_out(row, foods, credit) for row in rows],
    )


@router.patch("/items/{item_id}", response_model=GroceryItemOut, summary="Have, need or bought")
async def set_item_state(
    item_id: str,
    payload: StateIn,
    grocery: Grocery,
    pantry: Pantry,
    audit: Audit,
    week_start: date | None = None,
) -> GroceryItemOut:
    """Say where one line stands, and remember it somewhere a rebuild cannot reach.

    * ``have`` records the week's requirement for that food in the pantry, dated now.
      The line said how much the week needs and the person said they have it, so that
      is the quantity being claimed; it decays from today
      (:func:`app.planner.grocery.pantry_credit`).
    * ``need`` forgets the pantry row. Unticking is the correction of a claim, and a
      correction that left a stale quantity behind would be the dangerous half of wrong.
    * ``bought`` deliberately does **not** stock the pantry. What was bought for this
      week is what this week's meals will eat, so carrying it forward would tell next
      week's list that a cupboard is full when it is empty -- the one error that ends in
      an ingredient missing on the evening it is cooked. It is written to the
      ``health_events`` trail instead, which is what makes it survive a rebuild.
    """
    start = week_start_for(week_start or date.today())
    header = await grocery.list_for_week(start)
    if header is None:
        raise NotFound("There is no list for that week.")
    rows = await grocery.set_state(item_id, str(header.get("id")), payload.state)
    if not rows:
        raise NotFound("That item does not exist, or is not yours.")
    row = rows[0]
    food_id = str(row.get("food_id") or "")
    required = _as_float(row.get("quantity"))
    unit = str(row.get("unit") or "g")

    held = 0.0
    if food_id and payload.state == "have":
        await pantry.hold(food_id, required, unit=unit)
        # Written a moment ago, so it has not had a day to decay: the whole requirement
        # is covered. Cheaper and more exact than reading back what we just wrote.
        held = required
    elif food_id and payload.state == "need":
        await pantry.clear(food_id)
    elif food_id and payload.state == "bought":
        await audit.event(
            BOUGHT_EVENT,
            {
                "food_id": food_id,
                "week_start": start.isoformat(),
                "quantity": round(required, 2),
                "unit": unit,
            },
        )

    # A bought line reports the week's requirement rather than a pantry split: nothing
    # was claimed about the kitchen, and the list read is where the split is worked out.
    to_buy, covered = split_requirement(required, held)
    return GroceryItemOut(
        id=str(row.get("id")),
        food_id=food_id,
        quantity=round(to_buy, 2),
        have=round(covered, 2),
        unit=unit,
        aisle=str(row.get("aisle") or "Other"),
        state=_state(row.get("state")),
    )


async def _rebuild(
    week_start: date,
    list_id: str,
    grocery: GroceryRepository,
    plans: PlanRepository,
    reference: ReferenceRepository,
    pantry: PantryRepository,
    audit: AuditRepository,
) -> tuple[list[dict[str, Any]], int]:
    """Rewrite the list from the week's plans. Returns the rows and how many days had one.

    A day with no plan is skipped and not invented: this endpoint adds up plans, it does
    not make them. The count comes back so the screen can say which kind of empty an
    empty list is, instead of hedging between "nothing planned yet" and "planned, but
    every ingredient was a pinch".
    """
    items = []
    planned_days = 0
    for day in week_dates(week_start):
        header = await plans.plan_for(day)
        if header is None:
            continue
        planned_days += 1
        for row in await plans.items_for(str(header.get("id"))):
            parsed = plan_item_from_row(row)
            if parsed is not None:
                items.append(parsed)
    if not items:
        return [], planned_days

    food_ids = [i.food_id for i in items if i.food_id]
    foods = await _foods(food_ids, reference)
    aisles = {food_id: (food.food_group or "Other") for food_id, food in foods.items()}
    credit = pantry_credit(
        await pantry.for_foods(food_ids), groups=_groups(foods), today=date.today()
    )
    # keep_covered, so a food the kitchen already has still gets a row. Dropping it
    # would leave nothing to untick when the jar turns out to be empty.
    lines = build_lines(items, aisles, pantry=credit, keep_covered=True)
    rows = await grocery.replace_items(list_id, [line.as_row() for line in lines])

    bought = await _bought_this_week(audit, week_start)
    for row in rows:
        if str(row.get("food_id")) in bought and _state(row.get("state")) != "bought":
            row["state"] = "bought"
            await grocery.set_state(str(row.get("id")), list_id, "bought")
    return rows, planned_days


async def _bought_this_week(audit: AuditRepository, week_start: date) -> set[str]:
    """The foods already picked up on this week's shop, from the append-only trail."""
    since = datetime.combine(week_start, time.min, tzinfo=UTC)
    rows = await audit.events_since(BOUGHT_EVENT, since, limit=500)
    bought: set[str] = set()
    for row in rows:
        payload = row.get("payload")
        if not isinstance(payload, dict):
            continue
        if str(payload.get("week_start") or "") != week_start.isoformat():
            continue
        food_id = str(payload.get("food_id") or "")
        if food_id:
            bought.add(food_id)
    return bought


def _item_out(
    row: dict[str, Any], foods: dict[str, FoodItem], credit: dict[str, float]
) -> GroceryItemOut:
    """One stored row, split into what is held and what is still to buy.

    The state is derived rather than trusted, because the pantry is the memory and the
    row's column is only a copy of it -- one that a rebuild resets and that says nothing
    about a claim having since decayed. ``bought`` is left alone: it is a fact about a
    shop, not a claim about a cupboard.
    """
    food_id = str(row.get("food_id") or "")
    required = _as_float(row.get("quantity"))
    to_buy, covered = split_requirement(required, credit.get(food_id, 0.0))
    stored = _state(row.get("state"))
    state: State = stored if stored == "bought" else ("have" if to_buy == 0.0 else "need")
    return GroceryItemOut(
        id=str(row.get("id")) if row.get("id") else None,
        food_id=food_id,
        name=foods[food_id].name if food_id in foods else "",
        quantity=round(to_buy, 2),
        have=round(covered, 2),
        unit=str(row.get("unit") or "g"),
        aisle=str(row.get("aisle") or "Other"),
        state=state,
    )


async def _foods(food_ids: list[str], reference: ReferenceRepository) -> dict[str, FoodItem]:
    """``food_id -> food``. One lookup for both the name and the aisle."""
    ids = [f for f in food_ids if f]
    if not ids:
        return {}
    return {food.id: food for food in await reference.foods_by_id(ids)}


def _groups(foods: dict[str, FoodItem]) -> dict[str, str]:
    """``food_id -> food_group``, which is what decides how fast a claim decays."""
    return {food_id: (food.food_group or "") for food_id, food in foods.items()}


def _as_float(value: object) -> float:
    try:
        return float(value or 0.0)
    except (TypeError, ValueError):
        return 0.0


def _state(value: object) -> State:
    raw = str(value or "need")
    return raw if raw in ("need", "have", "bought") else "need"  # type: ignore[return-value]

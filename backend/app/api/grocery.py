"""The week's grocery list.

Built from the plans that already exist for that week, by adding up portions --
:mod:`app.planner.grocery`. No model call, no invented quantity.
"""

from __future__ import annotations

from datetime import date
from typing import Annotated, Literal

from fastapi import APIRouter, Depends
from pydantic import BaseModel, ConfigDict

from app.api.deps import get_grocery, get_plans, get_reference
from app.core.errors import NotFound
from app.planner.grocery import build_lines, week_dates
from app.repositories.plans import (
    GroceryRepository,
    PlanRepository,
    plan_item_from_row,
    week_start_for,
)
from app.repositories.reference import ReferenceRepository

router = APIRouter(prefix="/v1/grocery", tags=["grocery"])

Grocery = Annotated[GroceryRepository, Depends(get_grocery)]
Plans = Annotated[PlanRepository, Depends(get_plans)]
Reference = Annotated[ReferenceRepository, Depends(get_reference)]

State = Literal["need", "have", "bought"]


class GroceryItemOut(BaseModel):
    id: str | None = None
    food_id: str
    name: str = ""
    quantity: float
    unit: str = "g"
    aisle: str = "Other"
    state: State = "need"


class GroceryListOut(BaseModel):
    week_start: date
    status: str = "open"
    items: list[GroceryItemOut] = []


class StateIn(BaseModel):
    model_config = ConfigDict(extra="forbid")

    state: State


@router.get("", response_model=GroceryListOut, summary="This week's list")
async def weekly_list(
    grocery: Grocery,
    plans: Plans,
    reference: Reference,
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
    if rebuild or not rows:
        rows = await _rebuild(start, list_id, grocery, plans, reference)

    names = await _names([str(row.get("food_id")) for row in rows], reference)
    return GroceryListOut(
        week_start=start,
        status=str(header.get("status") or "open"),
        items=[
            GroceryItemOut(
                id=str(row.get("id")) if row.get("id") else None,
                food_id=str(row.get("food_id")),
                name=names.get(str(row.get("food_id")), ""),
                quantity=float(row.get("quantity") or 0),
                unit=str(row.get("unit") or "g"),
                aisle=str(row.get("aisle") or "Other"),
                state=_state(row.get("state")),
            )
            for row in rows
        ],
    )


@router.patch("/items/{item_id}", response_model=GroceryItemOut, summary="Have, need or bought")
async def set_item_state(
    item_id: str,
    payload: StateIn,
    grocery: Grocery,
    week_start: date | None = None,
) -> GroceryItemOut:
    start = week_start_for(week_start or date.today())
    header = await grocery.list_for_week(start)
    if header is None:
        raise NotFound("There is no list for that week.")
    rows = await grocery.set_state(item_id, str(header.get("id")), payload.state)
    if not rows:
        raise NotFound("That item does not exist, or is not yours.")
    row = rows[0]
    return GroceryItemOut(
        id=str(row.get("id")),
        food_id=str(row.get("food_id")),
        quantity=float(row.get("quantity") or 0),
        unit=str(row.get("unit") or "g"),
        aisle=str(row.get("aisle") or "Other"),
        state=_state(row.get("state")),
    )


async def _rebuild(
    week_start: date,
    list_id: str,
    grocery: GroceryRepository,
    plans: PlanRepository,
    reference: ReferenceRepository,
) -> list[dict]:
    items = []
    for day in week_dates(week_start):
        header = await plans.plan_for(day)
        if header is None:
            continue
        for row in await plans.items_for(str(header.get("id"))):
            parsed = plan_item_from_row(row)
            if parsed is not None:
                items.append(parsed)
    if not items:
        return []
    aisles = await reference.aisle_for_foods([i.food_id for i in items if i.food_id])
    lines = build_lines(items, aisles)
    return await grocery.replace_items(list_id, [line.as_row() for line in lines])


async def _names(food_ids: list[str], reference: ReferenceRepository) -> dict[str, str]:
    ids = [f for f in food_ids if f]
    if not ids:
        return {}
    return {food.id: food.name for food in await reference.foods_by_id(ids)}


def _state(value: object) -> State:
    raw = str(value or "need")
    return raw if raw in ("need", "have", "bought") else "need"  # type: ignore[return-value]

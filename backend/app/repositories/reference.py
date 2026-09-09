"""Shared reference data: biomarkers, reference ranges, foods, recipes, RDA targets.

``db/policies/100_rls.sql`` gives ``authenticated`` a SELECT policy on every one of these
tables and no write policy at all. So these reads run with the **user's own token** like
everything else -- there is no reason to reach for the service role to read a table the
user is already allowed to read, and doing so would put our code back in the enforcement
path for no gain.
"""

from __future__ import annotations

from decimal import Decimal, InvalidOperation
from typing import Any

from app.domain.enums import Sex
from app.domain.models import FoodItem, ReferenceRange
from app.repositories.base import PostgrestClient, Rows, in_

FOOD_COLUMNS = "id,name,name_local,food_group,per_100g,diet_flags,allergens,region,source"
RANGE_COLUMNS = (
    "biomarker_code,sex,age_min,age_max,pregnancy,low,high,borderline_low,"
    "borderline_high,critical_low,critical_high,source_citation"
)


class ReferenceRepository:
    """Read-only lookups. Not user-scoped, because none of this is user data."""

    def __init__(self, client: PostgrestClient) -> None:
        self.db = client

    async def reference_ranges(self, biomarker_codes: list[str]) -> list[ReferenceRange]:
        if not biomarker_codes:
            return []
        rows = await self.db.select(
            "reference_ranges",
            columns=RANGE_COLUMNS,
            filters={"biomarker_code": in_(sorted(set(biomarker_codes)))},
            limit=1000,
        )
        return [r for r in (_range_from_row(row) for row in rows) if r is not None]

    async def biomarkers(self, codes: list[str] | None = None) -> Rows:
        filters = {"biomarker_code": in_(codes)} if codes else None
        return await self.db.select(
            "biomarkers",
            columns="code,display_name,category,canonical_unit,higher_is_worse",
            filters=filters,
            limit=500,
        )

    async def foods(self, *, limit: int = 1000) -> list[FoodItem]:
        rows = await self.db.select("foods", columns=FOOD_COLUMNS, limit=limit)
        return [food_from_row(row) for row in rows]

    async def foods_by_id(self, food_ids: list[str]) -> list[FoodItem]:
        if not food_ids:
            return []
        rows = await self.db.select(
            "foods",
            columns=FOOD_COLUMNS,
            filters={"id": in_(sorted(set(food_ids)))},
            limit=1000,
        )
        return [food_from_row(row) for row in rows]

    async def recipe_items(self, recipe_ids: list[str]) -> dict[str, list[tuple[str, float]]]:
        """``recipe_id -> [(food_id, grams)]``, the shape ``recompute_plan_items`` wants."""
        if not recipe_ids:
            return {}
        rows = await self.db.select(
            "recipe_items",
            columns="recipe_id,food_id,grams",
            filters={"recipe_id": in_(sorted(set(recipe_ids)))},
            limit=2000,
        )
        out: dict[str, list[tuple[str, float]]] = {}
        for row in rows:
            recipe_id = str(row.get("recipe_id"))
            food_id = str(row.get("food_id"))
            try:
                grams = float(row.get("grams") or 0)
            except (TypeError, ValueError):
                continue
            if grams > 0:
                out.setdefault(recipe_id, []).append((food_id, grams))
        return out

    async def aisle_for_foods(self, food_ids: list[str]) -> dict[str, str]:
        """Food group doubles as the shop aisle, so the grocery list is walkable."""
        foods = await self.foods_by_id(food_ids)
        return {food.id: (food.food_group or "Other") for food in foods}


# --------------------------------------------------------------------- row -> domain


def food_from_row(row: dict[str, Any]) -> FoodItem:
    raw = row.get("per_100g")
    per_100g: dict[str, float] = {}
    if isinstance(raw, dict):
        for key, value in raw.items():
            try:
                per_100g[str(key)] = float(value)
            except (TypeError, ValueError):
                continue
    return FoodItem(
        id=str(row.get("id")),
        name=str(row.get("name") or ""),
        name_local=row.get("name_local"),
        food_group=row.get("food_group"),
        per_100g=per_100g,
        diet_flags=[str(f) for f in (row.get("diet_flags") or [])],
        allergens=[str(a) for a in (row.get("allergens") or [])],
        region=row.get("region"),
        source=str(row.get("source") or "unknown"),
    )


def _decimal(value: Any) -> Decimal | None:
    if value is None:
        return None
    try:
        return Decimal(str(value))
    except (InvalidOperation, ValueError):
        return None


def _range_from_row(row: dict[str, Any]) -> ReferenceRange | None:
    citation = str(row.get("source_citation") or "").strip()
    if not citation:
        # Policy from docs/03-data-model.md: a threshold with no provenance is not a
        # threshold we are willing to judge someone's blood against.
        return None
    sex_raw = str(row.get("sex") or "").strip()
    return ReferenceRange(
        biomarker_code=str(row.get("biomarker_code")),
        sex=Sex(sex_raw) if sex_raw in set(Sex) else None,
        age_min=row.get("age_min"),
        age_max=row.get("age_max"),
        pregnancy=row.get("pregnancy"),
        low=_decimal(row.get("low")),
        high=_decimal(row.get("high")),
        borderline_low=_decimal(row.get("borderline_low")),
        borderline_high=_decimal(row.get("borderline_high")),
        critical_low=_decimal(row.get("critical_low")),
        critical_high=_decimal(row.get("critical_high")),
        source_citation=citation,
    )

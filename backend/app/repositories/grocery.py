"""``pantry_items`` -- what the kitchen already holds.

This is the grocery feature's *memory*, and it is deliberately not kept on the
shopping list itself. ``grocery_items`` is rebuilt by deleting and reinserting every
row (:meth:`app.repositories.plans.GroceryRepository.replace_items`), so a tick stored
only there lasts until the next rebuild and no longer. ``pantry_items`` is keyed on
``(user_id, food_id)`` and outlives every list, which is what makes "I already have
this" mean something next week as well as this one.

The table is not new: ``db/migrations/007_plans_grocery_alerts.sql`` created it, with
its unique index, its ``updated_at`` trigger and its four RLS policies in
``db/policies/100_rls.sql``, and ``app.repositories.privacy`` already erases and exports
it. Nothing here needs a migration.

Why a separate module rather than another class in ``plans.py``: nothing about the
pantry belongs to meal plans, and the file that holds :class:`GroceryRepository` is
already the busiest in the package.
"""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Any

from app.repositories.base import Rows, eq, in_
from app.repositories.profiles import UserScopedRepository

PANTRY_COLUMNS = "id,food_id,quantity,unit,updated_at"


class PantryRepository(UserScopedRepository):
    """``pantry_items``, as the signed-in user. RLS is the boundary, as everywhere."""

    async def for_foods(self, food_ids: list[str]) -> Rows:
        """What the kitchen holds, for the foods a list actually mentions.

        Narrowed to the foods asked about rather than reading the whole pantry: a list
        is a handful of lines and the pantry grows for ever.
        """
        ids = sorted({food_id for food_id in food_ids if food_id})
        if not ids:
            return []
        return await self.db.select(
            "pantry_items",
            columns=PANTRY_COLUMNS,
            filters={**self._mine, "food_id": in_(ids)},
            limit=500,
        )

    async def all(self) -> Rows:
        return await self.db.select(
            "pantry_items", columns=PANTRY_COLUMNS, filters=self._mine, limit=500
        )

    async def hold(self, food_id: str, quantity: float, *, unit: str = "g") -> dict[str, Any]:
        """Record that this much of a food is at home, as of now.

        ``updated_at`` is written explicitly rather than left to the trigger, because it
        is not decoration here: :func:`app.planner.grocery.pantry_credit` reads it as the
        date the claim was made and lets the claim decay from it.
        """
        if quantity < 0:
            raise ValueError("a pantry quantity cannot be negative")
        row = {
            "user_id": self.user_id,
            "food_id": food_id,
            "quantity": round(float(quantity), 2),
            "unit": unit,
            "updated_at": datetime.now(UTC).isoformat(),
        }
        rows = await self.db.upsert("pantry_items", row, on_conflict="user_id,food_id")
        return rows[0] if rows else row

    async def clear(self, food_id: str) -> None:
        """Forget a food entirely.

        Deleting rather than storing a zero: "I do not have this" and "I have none of
        this left, recorded on Tuesday" are the same fact, and one row shape says it
        without the reader having to know which.
        """
        await self.db.delete(
            "pantry_items",
            filters={**self._mine, "food_id": eq(food_id)},
            returning=False,
        )


__all__ = ["PANTRY_COLUMNS", "PantryRepository"]

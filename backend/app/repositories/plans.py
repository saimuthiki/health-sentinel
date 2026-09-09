"""Meal plans, grocery lists, alerts, food logs, preferences, goals and memory.

All user-scoped, all as the user, all RLS-enforced.
"""

from __future__ import annotations

from datetime import UTC, date, datetime
from typing import Any

from app.domain.enums import AlertType, GoalType, MealSlot, Stance
from app.domain.models import (
    DayPlan,
    FoodPreference,
    Goal,
    MealPlanItem,
    MemoryFact,
    ScheduledAlert,
)
from app.repositories.base import Rows, eq, in_
from app.repositories.mapping import iso, parse_time, slot_from_db, slot_to_db
from app.repositories.profiles import UserScopedRepository

PLAN_COLUMNS = "id,plan_date,generated_at,model,rationale,status"
PLAN_ITEM_COLUMNS = (
    "id,meal_plan_id,meal_slot,recipe_id,food_id,grams,computed_nutrients,why_text,order_index"
)
ALERT_COLUMNS = "id,alert_type,title,body,schedule_rule,enabled,quiet_hours"
GROCERY_ITEM_COLUMNS = "id,grocery_list_id,food_id,quantity,unit,aisle,state"


class PlanRepository(UserScopedRepository):
    """``meal_plans`` + ``meal_plan_items``."""

    async def plan_for(self, plan_date: date) -> dict[str, Any] | None:
        return await self.db.select_one(
            "meal_plans",
            columns=PLAN_COLUMNS,
            filters={**self._mine, "plan_date": eq(plan_date.isoformat())},
        )

    async def items_for(self, plan_id: str) -> Rows:
        return await self.db.select(
            "meal_plan_items",
            columns=PLAN_ITEM_COLUMNS,
            filters={"meal_plan_id": eq(plan_id)},
            order="order_index.asc",
        )

    async def recent(self, *, limit: int = 14) -> Rows:
        return await self.db.select(
            "meal_plans",
            columns=PLAN_COLUMNS,
            filters=self._mine,
            order="plan_date.desc",
            limit=limit,
        )

    async def save(self, plan: DayPlan, *, model: str, rationale: str) -> dict[str, Any]:
        """Write the plan for a date, replacing whatever was there.

        ``meal_plans`` is unique on ``(user_id, plan_date)``, so a regenerate upserts the
        header and rewrites the items rather than accumulating duplicates.
        """
        header = {
            "user_id": self.user_id,
            "plan_date": plan.plan_date.isoformat(),
            "generated_at": datetime.now(UTC).isoformat(),
            "model": model,
            "rationale": rationale,
            "status": "active",
        }
        rows = await self.db.upsert("meal_plans", header, on_conflict="user_id,plan_date")
        plan_id = str(rows[0]["id"]) if rows and rows[0].get("id") else None
        if plan_id is None:
            existing = await self.plan_for(plan.plan_date)
            plan_id = str(existing["id"]) if existing else ""
        if not plan_id:
            return {}

        await self.db.delete(
            "meal_plan_items", filters={"meal_plan_id": eq(plan_id)}, returning=False
        )
        if plan.items:
            await self.db.insert(
                "meal_plan_items",
                [
                    {
                        "meal_plan_id": plan_id,
                        "meal_slot": slot_to_db(item.meal_slot),
                        "recipe_id": item.recipe_id,
                        "food_id": item.food_id,
                        "grams": item.grams,
                        "computed_nutrients": item.computed_nutrients,
                        "why_text": item.why_text,
                        "order_index": item.order_index,
                    }
                    for item in plan.items
                ],
                returning=False,
            )
        return {**header, "id": plan_id}

    async def mark_item(self, item_id: str, plan_id: str, *, done: bool) -> Rows:
        """Plan items have no state column of their own; progress lives in
        ``health_events`` (see :class:`AuditRepository`). This only proves ownership."""
        rows = await self.db.select(
            "meal_plan_items",
            columns="id",
            filters={"id": eq(item_id), "meal_plan_id": eq(plan_id)},
        )
        return rows


class FoodLogRepository(UserScopedRepository):
    """``food_logs``, ``food_feedback`` and ``food_preferences``."""

    async def log_meal(
        self,
        *,
        meal_slot: MealSlot | None,
        food_id: str | None,
        free_text: str | None,
        source: str = "manual",
        logged_at: datetime | None = None,
        image_path: str | None = None,
    ) -> dict[str, Any]:
        row = {
            "user_id": self.user_id,
            "logged_at": (logged_at or datetime.now(UTC)).isoformat(),
            "meal_slot": slot_to_db(meal_slot) if meal_slot else None,
            "food_id": food_id,
            "free_text": free_text,
            "image_path": image_path,
            "source": source,
        }
        rows = await self.db.insert("food_logs", row)
        return rows[0] if rows else row

    async def logs_between(self, start: datetime, end: datetime) -> Rows:
        return await self.db.select(
            "food_logs",
            columns="id,logged_at,meal_slot,food_id,free_text,source",
            filters={
                **self._mine,
                "logged_at": f"gte.{start.isoformat()}",
            },
            order="logged_at.asc",
            limit=200,
        )

    async def food_id_for_log(self, food_log_id: str) -> str | None:
        row = await self.db.select_one(
            "food_logs", columns="food_id", filters={**self._mine, "id": eq(food_log_id)}
        )
        if row is None:
            return None
        food_id = row.get("food_id")
        return str(food_id) if food_id else None

    async def rate(self, food_log_id: str, rating: int, note: str | None = None) -> dict[str, Any]:
        row = {
            "user_id": self.user_id,
            "food_log_id": food_log_id,
            "rating": int(rating),
            "note": note,
        }
        rows = await self.db.insert("food_feedback", row)
        return rows[0] if rows else row

    async def preferences(self) -> list[FoodPreference]:
        rows = await self.db.select(
            "food_preferences",
            columns="food_id,stance,score",
            filters=self._mine,
            limit=500,
        )
        food_ids = [str(r.get("food_id")) for r in rows if r.get("food_id")]
        names = await self._food_names(food_ids)
        out: list[FoodPreference] = []
        for row in rows:
            food_id = str(row.get("food_id") or "")
            stance_raw = str(row.get("stance") or "neutral")
            try:
                score = float(row.get("score") or 0.0)
            except (TypeError, ValueError):
                score = 0.0
            out.append(
                FoodPreference(
                    food_id=food_id,
                    name=names.get(food_id, food_id),
                    stance=Stance(stance_raw) if stance_raw in set(Stance) else Stance.NEUTRAL,
                    score=score,
                )
            )
        return out

    async def _food_names(self, food_ids: list[str]) -> dict[str, str]:
        if not food_ids:
            return {}
        rows = await self.db.select(
            "foods", columns="id,name", filters={"id": in_(sorted(set(food_ids)))}, limit=500
        )
        return {str(r["id"]): str(r.get("name") or r["id"]) for r in rows}

    async def set_preference(self, food_id: str, stance: Stance, score: float) -> dict[str, Any]:
        row = {
            "user_id": self.user_id,
            "food_id": food_id,
            "stance": stance.value,
            "score": score,
        }
        rows = await self.db.upsert("food_preferences", row, on_conflict="user_id,food_id")
        return rows[0] if rows else row


class GroceryRepository(UserScopedRepository):
    """``grocery_lists`` + ``grocery_items``."""

    async def list_for_week(self, week_start: date) -> dict[str, Any] | None:
        return await self.db.select_one(
            "grocery_lists",
            columns="id,week_start,status,created_at",
            filters={**self._mine, "week_start": eq(week_start.isoformat())},
        )

    async def ensure_list(self, week_start: date) -> dict[str, Any]:
        existing = await self.list_for_week(week_start)
        if existing:
            return existing
        rows = await self.db.insert(
            "grocery_lists",
            {"user_id": self.user_id, "week_start": week_start.isoformat(), "status": "open"},
        )
        return rows[0] if rows else {}

    async def items(self, list_id: str) -> Rows:
        return await self.db.select(
            "grocery_items",
            columns=GROCERY_ITEM_COLUMNS,
            filters={"grocery_list_id": eq(list_id)},
            order="aisle.asc",
        )

    async def replace_items(self, list_id: str, items: list[dict[str, Any]]) -> Rows:
        await self.db.delete(
            "grocery_items", filters={"grocery_list_id": eq(list_id)}, returning=False
        )
        if not items:
            return []
        return await self.db.insert(
            "grocery_items",
            [{**item, "grocery_list_id": list_id} for item in items],
        )

    async def set_state(self, item_id: str, list_id: str, state: str) -> Rows:
        if state not in ("need", "have", "bought"):
            raise ValueError("grocery state must be need, have or bought")
        return await self.db.update(
            "grocery_items",
            {"state": state},
            filters={"id": eq(item_id), "grocery_list_id": eq(list_id)},
        )


class AlertRepository(UserScopedRepository):
    """``alerts``. The rows the phone reads to schedule its own local notifications."""

    async def all(self) -> Rows:
        return await self.db.select(
            "alerts", columns=ALERT_COLUMNS, filters=self._mine, order="alert_type.asc"
        )

    async def replace(self, alerts: list[ScheduledAlert], *, keep_types: bool = True) -> Rows:
        """Rewrite the generated alert set, preserving whatever the user switched off."""
        existing = await self.all() if keep_types else []
        disabled = {
            str(row.get("alert_type"))
            for row in existing
            if row.get("enabled") is False
        }
        quiet = next(
            (row.get("quiet_hours") for row in existing if row.get("quiet_hours")), {}
        )
        await self.db.delete("alerts", filters=self._mine, returning=False)
        if not alerts:
            return []
        return await self.db.insert(
            "alerts",
            [
                {
                    "user_id": self.user_id,
                    "alert_type": alert.alert_type.value,
                    "title": alert.title,
                    "body": alert.body,
                    "schedule_rule": alert.at.isoformat(timespec="minutes"),
                    "enabled": alert.enabled and alert.alert_type.value not in disabled,
                    "quiet_hours": quiet or {},
                }
                for alert in alerts
            ],
        )

    async def set_enabled(self, alert_type: AlertType, enabled: bool) -> Rows:
        return await self.db.update(
            "alerts",
            {"enabled": enabled},
            filters={**self._mine, "alert_type": eq(alert_type.value)},
        )

    async def set_quiet_hours(self, start: str, end: str) -> Rows:
        for value in (start, end):
            if parse_time(value) is None:
                raise ValueError("quiet hours must be HH:MM")
        return await self.db.update(
            "alerts",
            {"quiet_hours": {"start": start, "end": end}},
            filters=self._mine,
        )


class GoalRepository(UserScopedRepository):
    """``goals`` and ``user_memory`` -- the two learned inputs to the planner."""

    async def active_goals(self) -> list[Goal]:
        rows = await self.db.select(
            "goals",
            columns="id,goal_type,title,priority,status",
            filters={**self._mine, "status": eq("active")},
            order="priority.asc",
            limit=20,
        )
        out: list[Goal] = []
        for row in rows:
            goal_type = str(row.get("goal_type") or "")
            if goal_type not in set(GoalType):
                continue
            out.append(
                Goal(
                    id=str(row.get("id")),
                    goal_type=GoalType(goal_type),
                    title=str(row.get("title") or ""),
                    priority=int(row.get("priority") or 1),
                    status=str(row.get("status") or "active"),
                )
            )
        return out

    async def memory(self, *, limit: int = 50) -> list[MemoryFact]:
        rows = await self.db.select(
            "user_memory",
            columns="fact,category,confidence,confirmed",
            filters=self._mine,
            order="confidence.desc",
            limit=limit,
        )
        out: list[MemoryFact] = []
        for row in rows:
            try:
                confidence = float(row.get("confidence") or 0.0)
            except (TypeError, ValueError):
                continue
            out.append(
                MemoryFact(
                    fact=str(row.get("fact") or ""),
                    category=str(row.get("category") or "other"),
                    confidence=confidence,
                    confirmed=bool(row.get("confirmed", False)),
                )
            )
        return [fact for fact in out if fact.fact]

    async def remember(
        self, fact: str, category: str, confidence: float, *, source_message_id: str | None = None
    ) -> dict[str, Any]:
        row = {
            "user_id": self.user_id,
            "fact": fact,
            "category": category,
            "confidence": confidence,
            # Low-confidence facts are shown to the user to confirm before they shape a
            # plan (docs/04-ai-pipeline.md, the learning loop).
            "confirmed": confidence >= 0.9,
            "source_message_id": source_message_id,
        }
        rows = await self.db.insert("user_memory", row)
        return rows[0] if rows else row


# --------------------------------------------------------------------- row -> domain


def plan_item_from_row(row: dict[str, Any]) -> MealPlanItem | None:
    slot = slot_from_db(row.get("meal_slot"))
    if slot is None:
        return None
    nutrients_raw = row.get("computed_nutrients")
    nutrients: dict[str, float] = {}
    if isinstance(nutrients_raw, dict):
        for key, value in nutrients_raw.items():
            try:
                nutrients[str(key)] = float(value)
            except (TypeError, ValueError):
                continue
    try:
        grams = float(row.get("grams") or 0.0)
    except (TypeError, ValueError):
        grams = 0.0
    return MealPlanItem(
        meal_slot=slot,
        food_id=row.get("food_id"),
        recipe_id=row.get("recipe_id"),
        display_name=str(row.get("display_name") or ""),
        grams=grams,
        computed_nutrients=nutrients,
        why_text=str(row.get("why_text") or ""),
        order_index=int(row.get("order_index") or 0),
    )


def alert_from_row(row: dict[str, Any]) -> ScheduledAlert | None:
    alert_type = str(row.get("alert_type") or "")
    at = parse_time(row.get("schedule_rule"))
    if alert_type not in set(AlertType) or at is None:
        return None
    return ScheduledAlert(
        alert_type=AlertType(alert_type),
        title=str(row.get("title") or ""),
        body=str(row.get("body") or ""),
        at=at,
        enabled=bool(row.get("enabled", True)),
    )


def week_start_for(day: date) -> date:
    """Monday of ``day``'s week -- the key ``grocery_lists`` is unique on."""
    return date.fromordinal(day.toordinal() - day.weekday())


__all__ = [
    "AlertRepository",
    "FoodLogRepository",
    "GoalRepository",
    "GroceryRepository",
    "PlanRepository",
    "alert_from_row",
    "iso",
    "plan_item_from_row",
    "week_start_for",
]

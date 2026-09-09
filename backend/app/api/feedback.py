"""What the user actually did: meals logged, ratings given, plan items done or skipped.

This is the observed layer of the learning loop (docs/04-ai-pipeline.md). It is pure
arithmetic -- a rating moves a preference score, nothing here asks a model anything.
Making the effect visible is the point: an invisible learning system feels broken.
"""

from __future__ import annotations

from datetime import datetime
from typing import Annotated, Literal

from fastapi import APIRouter, Depends
from pydantic import BaseModel, ConfigDict, Field

from app.api.deps import get_audit, get_food_logs, get_plans
from app.core.errors import NotFound
from app.domain.enums import MealSlot, Stance
from app.repositories.audit import AuditRepository
from app.repositories.plans import FoodLogRepository, PlanRepository

router = APIRouter(prefix="/v1/feedback", tags=["feedback"])

Logs = Annotated[FoodLogRepository, Depends(get_food_logs)]
Plans = Annotated[PlanRepository, Depends(get_plans)]
Audit = Annotated[AuditRepository, Depends(get_audit)]

#: How far a single rating moves a food's score, on the 0-5 scale the planner reads.
RATING_TO_SCORE: dict[int, float] = {1: 1.0, 2: 2.0, 3: 3.0, 4: 4.0, 5: 5.0}
#: At or below this a food stops being offered; at or above it becomes a "like".
DISLIKE_AT = 2.0
LIKE_AT = 4.0


class LogMealIn(BaseModel):
    model_config = ConfigDict(extra="forbid")

    meal_slot: MealSlot | None = None
    food_id: str | None = None
    free_text: str | None = Field(default=None, max_length=280)
    source: Literal["planned", "chat", "photo", "manual"] = "manual"
    logged_at: datetime | None = None


class LogMealOut(BaseModel):
    id: str
    meal_slot: MealSlot | None = None
    food_id: str | None = None
    logged_at: str | None = None


class RatingIn(BaseModel):
    model_config = ConfigDict(extra="forbid")

    rating: int = Field(ge=1, le=5)
    note: str | None = Field(default=None, max_length=280)


class RatingOut(BaseModel):
    food_log_id: str
    rating: int
    preference_updated: bool = False
    stance: Stance | None = None


class PlanItemProgressIn(BaseModel):
    model_config = ConfigDict(extra="forbid")

    plan_id: str
    state: Literal["done", "skipped"]


class PlanItemProgressOut(BaseModel):
    item_id: str
    state: Literal["done", "skipped"]


@router.post("/meals", response_model=LogMealOut, status_code=201, summary="Log a meal")
async def log_meal(payload: LogMealIn, logs: Logs, audit: Audit) -> LogMealOut:
    if payload.food_id is None and not (payload.free_text or "").strip():
        raise NotFound("Tell us either which food it was, or what you ate in words.")
    row = await logs.log_meal(
        meal_slot=payload.meal_slot,
        food_id=payload.food_id,
        free_text=payload.free_text,
        source=payload.source,
        logged_at=payload.logged_at,
    )
    await audit.event("meal_logged", {"food_id": payload.food_id, "source": payload.source})
    return LogMealOut(
        id=str(row.get("id", "")),
        meal_slot=payload.meal_slot,
        food_id=payload.food_id,
        logged_at=str(row.get("logged_at")) if row.get("logged_at") else None,
    )


@router.post(
    "/meals/{food_log_id}/rating",
    response_model=RatingOut,
    status_code=201,
    summary="Rate a meal 1-5",
)
async def rate_meal(food_log_id: str, payload: RatingIn, logs: Logs, audit: Audit) -> RatingOut:
    """Record the rating and move the food's preference score by the same arithmetic
    every time, so the user can predict what a 1-star does."""
    await logs.rate(food_log_id, payload.rating, payload.note)

    food_id = await logs.food_id_for_log(food_log_id)
    if not food_id:
        return RatingOut(food_log_id=food_log_id, rating=payload.rating)

    score = RATING_TO_SCORE[payload.rating]
    if score <= DISLIKE_AT:
        stance = Stance.DISLIKE
    elif score >= LIKE_AT:
        stance = Stance.LIKE
    else:
        stance = Stance.NEUTRAL
    await logs.set_preference(food_id, stance, score)
    await audit.event(
        "food_rated", {"food_id": food_id, "rating": payload.rating, "stance": stance.value}
    )
    return RatingOut(
        food_log_id=food_log_id,
        rating=payload.rating,
        preference_updated=True,
        stance=stance,
    )


@router.post(
    "/plan-items/{item_id}",
    response_model=PlanItemProgressOut,
    summary="Mark a plan item done or skipped",
)
async def mark_plan_item(
    item_id: str, payload: PlanItemProgressIn, plans: Plans, audit: Audit
) -> PlanItemProgressOut:
    """``meal_plan_items`` has no state column, so progress is recorded in the
    append-only ``health_events`` trail. That keeps the plan itself immutable -- what was
    suggested and what was done stay separate facts."""
    owned = await plans.mark_item(item_id, payload.plan_id, done=payload.state == "done")
    if not owned:
        raise NotFound("That plan item does not exist, or is not yours.")
    await audit.event(
        "plan_item_progress",
        {"item_id": item_id, "plan_id": payload.plan_id, "state": payload.state},
    )
    return PlanItemProgressOut(item_id=item_id, state=payload.state)

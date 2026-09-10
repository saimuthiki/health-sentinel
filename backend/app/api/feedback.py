"""What the user actually did: meals logged, ratings given, plan items done or skipped.

This is the observed layer of the learning loop (docs/04-ai-pipeline.md). It is pure
arithmetic -- a rating moves a preference score, nothing here asks a model anything.
Making the effect visible is the point: an invisible learning system feels broken.
"""

from __future__ import annotations

from datetime import UTC, date, datetime, time, timedelta
from typing import Annotated, Any, Literal

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel, ConfigDict, Field

from app.api.deps import get_audit, get_food_logs, get_plans, get_profiles
from app.core.errors import NotFound, ValidationFailed
from app.domain.enums import MealSlot, Stance
from app.repositories.audit import AuditRepository
from app.repositories.plans import FoodLogRepository, PlanRepository
from app.repositories.profiles import ProfileRepository
from app.rules.daily_goals import moderate_equivalent_minutes, resolve_movement_target

router = APIRouter(prefix="/v1/feedback", tags=["feedback"])

Logs = Annotated[FoodLogRepository, Depends(get_food_logs)]
Plans = Annotated[PlanRepository, Depends(get_plans)]
Audit = Annotated[AuditRepository, Depends(get_audit)]
Profiles = Annotated[ProfileRepository, Depends(get_profiles)]

#: How far a single rating moves a food's score, on the 0-5 scale the planner reads.
RATING_TO_SCORE: dict[int, float] = {1: 1.0, 2: 2.0, 3: 3.0, 4: 4.0, 5: 5.0}
#: At or below this a food stops being offered; at or above it becomes a "like".
DISLIKE_AT = 2.0
LIKE_AT = 4.0

#: The audit event type one movement entry is written as. Read back by this module and
#: by ``app.api.plan``; nothing else should know the spelling.
MOVEMENT_EVENT = "movement_logged"

#: A single entry longer than this is far more likely to be a typo (400 for 40) than a
#: real session, and one bad entry would swamp a week. Refused rather than clamped, so
#: the person can see what happened and correct it.
MAX_MOVEMENT_MINUTES = 600

#: How many days a movement summary may span in one request.
MAX_MOVEMENT_WINDOW_DAYS = 92
DEFAULT_MOVEMENT_WINDOW_DAYS = 7


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


# --------------------------------------------------------------------------- movement


class LogMovementIn(BaseModel):
    """One session of movement the user actually did.

    There is deliberately no ``user_id`` here. ``extra="forbid"`` refuses one if it is
    sent, and the row is written by :class:`AuditRepository` under the caller's own id
    with the caller's own token -- so logging into someone else's day is refused twice,
    once by this schema and once by Row Level Security.
    """

    model_config = ConfigDict(extra="forbid")

    minutes: int = Field(ge=1, le=MAX_MOVEMENT_MINUTES)
    #: WHO's target counts moderate-to-vigorous activity, so those are the two things
    #: this endpoint accepts. Gentler movement is good for a person but is not what the
    #: 150 minutes measures, and counting it would overstate the week.
    intensity: Literal["moderate", "vigorous"] = "moderate"
    activity: str | None = Field(default=None, max_length=60)
    #: The day the movement happened, for logging last night's game this morning.
    #: Defaults to today; a future date is refused.
    on: date | None = None


class LogMovementOut(BaseModel):
    on: date
    minutes: int
    intensity: Literal["moderate", "vigorous"]
    activity: str | None = None
    #: What this entry contributes to the target, in the target's own unit.
    moderate_equivalent_minutes: int
    #: The whole day's total after this entry, so the bar can move without a second call.
    day_total_moderate_equivalent_minutes: int


class MovementDayOut(BaseModel):
    on: date
    minutes: int
    moderate_equivalent_minutes: int
    entries: int = 0


class MovementSummaryOut(BaseModel):
    start: date
    end: date
    #: One row per day in the window, zeros included -- a week with a gap in it should
    #: look like a week with a gap in it, not like a shorter week.
    days: list[MovementDayOut] = Field(default_factory=list)
    total_minutes: int = 0
    total_moderate_equivalent_minutes: int = 0
    target_minutes_per_day: int | None = None
    target_minutes_per_week: int | None = None
    target_source: str = ""


@router.post(
    "/movement",
    response_model=LogMovementOut,
    status_code=201,
    summary="Log movement",
)
async def log_movement(payload: LogMovementIn, audit: Audit) -> LogMovementOut:
    """Record one bout of movement.

    It goes into the append-only ``health_events`` trail, for the same reason
    :func:`mark_plan_item` does and the same reason the planner writes ``hydration_ml``
    there: **there is no movement table**, the schema is applied to a live database, and
    inventing a migration is not this change's to make. The trail is already the place
    this project records "what the user did" facts that have no column of their own, it is
    user-scoped and RLS-protected, and it is append-only -- so an entry cannot be quietly
    rewritten later.

    Only the raw ``minutes`` and ``intensity`` are stored. The moderate-equivalent figure
    is derived on the way out instead of being frozen into the row, so that if the
    equivalence in ``app.rules.daily_goals`` is ever corrected, past weeks are corrected
    with it rather than left carrying an old arithmetic.
    """
    on = payload.on or date.today()
    if on > date.today():
        raise ValidationFailed("We cannot log movement for a day that has not happened yet.")

    await audit.event(
        MOVEMENT_EVENT,
        {
            "on": on.isoformat(),
            "minutes": payload.minutes,
            "intensity": payload.intensity,
            "activity": (payload.activity or "").strip() or None,
        },
    )

    days = await _movement_days(audit, on, on)
    return LogMovementOut(
        on=on,
        minutes=payload.minutes,
        intensity=payload.intensity,
        activity=(payload.activity or "").strip() or None,
        moderate_equivalent_minutes=moderate_equivalent_minutes(
            payload.minutes, payload.intensity
        ),
        day_total_moderate_equivalent_minutes=days[on].moderate_equivalent_minutes,
    )


@router.get(
    "/movement",
    response_model=MovementSummaryOut,
    summary="Movement over a range of days",
)
async def movement_summary(
    audit: Audit,
    profiles: Profiles,
    start: Annotated[date | None, Query(description="First day, inclusive.")] = None,
    end: Annotated[date | None, Query(description="Last day, inclusive.")] = None,
) -> MovementSummaryOut:
    """Movement per day across a window, defaulting to the last seven days.

    A range rather than a single day from the start. The owner asked to see a week, WHO
    states the target weekly rather than daily, and a read that can already answer "how
    much did I move this week" costs one query parameter now and a migration of every
    caller later.
    """
    end_on = end or date.today()
    start_on = start or (end_on - timedelta(days=DEFAULT_MOVEMENT_WINDOW_DAYS - 1))
    if start_on > end_on:
        raise ValidationFailed("The start of the range is after its end.")
    if (end_on - start_on).days + 1 > MAX_MOVEMENT_WINDOW_DAYS:
        raise ValidationFailed(
            f"Ask for at most {MAX_MOVEMENT_WINDOW_DAYS} days of movement at a time."
        )

    days = await _movement_days(audit, start_on, end_on)
    target = resolve_movement_target(await profiles.health_profile(), on=end_on)
    ordered = [days[day] for day in sorted(days)]
    return MovementSummaryOut(
        start=start_on,
        end=end_on,
        days=ordered,
        total_minutes=sum(day.minutes for day in ordered),
        total_moderate_equivalent_minutes=sum(
            day.moderate_equivalent_minutes for day in ordered
        ),
        target_minutes_per_day=target.minutes_per_day,
        target_minutes_per_week=target.minutes_per_week,
        target_source=target.source,
    )


async def movement_minutes_on(audit: AuditRepository, on: date) -> int:
    """Moderate-equivalent minutes logged for one day. The figure the Today bar fills.

    Lives here rather than in :mod:`app.api.plan` so that the write shape and every read
    of it have exactly one owner.
    """
    days = await _movement_days(audit, on, on)
    return days[on].moderate_equivalent_minutes


async def _movement_days(
    audit: AuditRepository, start: date, end: date
) -> dict[date, MovementDayOut]:
    """Fold the audit trail into one row per day in ``[start, end]``, zeros included."""
    since = datetime.combine(start, time.min, tzinfo=UTC)
    rows = await audit.events_since(MOVEMENT_EVENT, since)

    days = {
        start + timedelta(days=offset): MovementDayOut(
            on=start + timedelta(days=offset), minutes=0, moderate_equivalent_minutes=0
        )
        for offset in range((end - start).days + 1)
    }
    for row in rows:
        parsed = _movement_entry(row.get("payload"))
        if parsed is None:
            continue
        on, minutes, intensity = parsed
        day = days.get(on)
        if day is None:
            continue
        days[on] = MovementDayOut(
            on=on,
            minutes=day.minutes + minutes,
            moderate_equivalent_minutes=(
                day.moderate_equivalent_minutes
                + moderate_equivalent_minutes(minutes, intensity)
            ),
            entries=day.entries + 1,
        )
    return days


def _movement_entry(payload: Any) -> tuple[date, int, str] | None:
    """One stored payload, or ``None`` if it is not one we can read.

    An unreadable row is skipped rather than guessed at, and never counted as zero
    minutes of something -- the same stance ``app.api.plan._hydration_for`` takes.
    """
    if not isinstance(payload, dict):
        return None
    try:
        on = date.fromisoformat(str(payload.get("on")))
        minutes = int(payload.get("minutes"))
    except (TypeError, ValueError):
        return None
    if minutes <= 0:
        return None
    intensity = str(payload.get("intensity") or "moderate")
    return on, minutes, intensity

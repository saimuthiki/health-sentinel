"""Today's plan, any date's plan, and regenerating one.

Screens **read** a stored plan; they do not generate one. Generation happens once a day,
or when the user explicitly asks -- that is what keeps this inside the free tier
(docs/04-ai-pipeline.md, "staying inside the free tier").
"""

from __future__ import annotations

from datetime import date
from typing import Annotated

from fastapi import APIRouter, Depends
from pydantic import BaseModel, ConfigDict, Field

from app.api.deps import (
    get_audit,
    get_planner,
    get_plans,
    get_profiles,
    get_reference,
    require_consent,
)
from app.api.feedback import movement_minutes_on
from app.api.guarded import GuardedText, guarded_deterministic
from app.core.errors import NotFound, NotReady, ValidationFailed
from app.domain.enums import Escalation, MealSlot, SafetyVerdict
from app.planner.service import PlannerService
from app.repositories.audit import AuditRepository
from app.repositories.plans import PlanRepository, plan_item_from_row
from app.repositories.profiles import ProfileRepository
from app.repositories.reference import ReferenceRepository
from app.rules.daily_goals import (
    HYDRATION_CEILING_ML,
    HYDRATION_OVERRIDE_FIELD,
    HYDRATION_OVERRIDE_FLOOR_ML,
    chosen_hydration_ml,
    judge_hydration_choice,
    resolve_hydration_target,
    resolve_movement_target,
)

router = APIRouter(prefix="/v1/plan", tags=["plan"])

Plans = Annotated[PlanRepository, Depends(get_plans)]
Reference = Annotated[ReferenceRepository, Depends(get_reference)]
Planner = Annotated[PlannerService, Depends(get_planner)]
Audit = Annotated[AuditRepository, Depends(get_audit)]
Profiles = Annotated[ProfileRepository, Depends(get_profiles)]


class PlanItemOut(BaseModel):
    id: str | None = None
    meal_slot: MealSlot
    food_id: str | None = None
    recipe_id: str | None = None
    display_name: str
    grams: float
    #: Recomputed in Python from the foods table. Never a number the model wrote.
    computed_nutrients: dict[str, float] = Field(default_factory=dict)
    #: Built by app.nutrition.why from those recomputed numbers, then scanned.
    why_text: GuardedText
    order_index: int = 0


class DayPlanOut(BaseModel):
    model_config = ConfigDict(extra="forbid")

    plan_date: date
    items: list[PlanItemOut] = Field(default_factory=list)
    #: What the plan says to drink. Not a target -- see ``hydration_target_ml``.
    hydration_ml: int = 0
    #: This person's daily drinking-water goal, from ``app.rules.daily_goals``. ``null``
    #: when we will not answer -- pregnancy, or a condition where fluid is a doctor's
    #: decision -- and ``hydration_target_source`` then carries the reason instead of the
    #: citation. The app must show the text and no bar in that case, never a default.
    hydration_target_ml: int | None = None
    #: Citation for the number above, or the reason there is not one. Deterministic text
    #: from curated code; no model has ever touched it.
    hydration_target_source: str = ""
    #: True when ``hydration_target_ml`` is a goal this person set for themselves rather
    #: than the one our sources support.
    hydration_target_chosen_by_user: bool = False
    #: What the guideline says for this profile, sent **whatever** the person chose, so
    #: the app can show the evidence beside the choice instead of replacing it.
    hydration_target_sourced_ml: int | None = None
    #: The plain warning attached to a chosen goal above the published range: what the
    #: risk actually is, and that it is worth asking a doctor. Empty when there is nothing
    #: to say. It warns; it never blocks and never quietly caps.
    hydration_target_caution: str = ""
    movement_target_minutes_per_day: int | None = None
    #: WHO states the movement target weekly, so this is the number that matters.
    movement_target_minutes_per_week: int | None = None
    movement_target_source: str = ""
    #: Moderate-equivalent minutes logged for ``plan_date``: what fills the bar.
    movement_minutes_logged: int = 0
    #: The only prose a model writes here, and it went through the safety pipeline.
    rationale: GuardedText
    escalation: Escalation = Escalation.ROUTINE
    safety_verdict: SafetyVerdict = SafetyVerdict.PASS
    generated: bool = False


class RegenerateIn(BaseModel):
    model_config = ConfigDict(extra="forbid")

    plan_date: date | None = None


class HydrationTargetIn(BaseModel):
    """The water goal somebody wants. ``null`` clears it and puts the sourced one back."""

    model_config = ConfigDict(extra="forbid")

    millilitres: int | None = Field(
        default=None,
        description=(
            "The daily drinking-water goal to set, in millilitres, or null to go back to "
            f"the figure our sources support. Between {HYDRATION_OVERRIDE_FLOOR_ML} and "
            f"{HYDRATION_CEILING_ML}; above the published range it is accepted with a "
            "warning, above the ceiling it is refused with the reason."
        ),
    )


class HydrationTargetOut(BaseModel):
    """The goal now in force, said back exactly as the Today screen will show it."""

    model_config = ConfigDict(extra="forbid")

    hydration_target_ml: int | None = None
    hydration_target_source: str = ""
    hydration_target_chosen_by_user: bool = False
    hydration_target_sourced_ml: int | None = None
    hydration_target_caution: str = ""


@router.get("/today", response_model=DayPlanOut, summary="Today's plan")
async def today(
    plans: Plans, planner: Planner, reference: Reference, audit: Audit, profiles: Profiles
) -> DayPlanOut:
    return await _read_or_generate(date.today(), plans, planner, reference, audit, profiles)


@router.post(
    "/regenerate",
    response_model=DayPlanOut,
    dependencies=[Depends(require_consent)],
    summary="Regenerate a plan",
)
async def regenerate(
    payload: RegenerateIn,
    plans: Plans,
    planner: Planner,
    reference: Reference,
    audit: Audit,
    profiles: Profiles,
) -> DayPlanOut:
    """Explicitly ask for a new plan. This is the only route that always calls a model."""
    plan_date = payload.plan_date or date.today()
    planned = await planner.generate(plan_date)
    goals = await _daily_goals(profiles, audit, plan_date)
    return DayPlanOut(
        plan_date=plan_date,
        items=[
            PlanItemOut(
                meal_slot=item.meal_slot,
                food_id=item.food_id,
                recipe_id=item.recipe_id,
                display_name=item.display_name,
                grams=item.grams,
                computed_nutrients=item.computed_nutrients,
                why_text=planned.why_texts.get(index, guarded_deterministic(item.why_text)),
                order_index=item.order_index,
            )
            for index, item in enumerate(planned.plan.items)
        ],
        hydration_ml=planned.plan.hydration_ml,
        **goals,
        rationale=planned.rationale,
        escalation=planned.escalation,
        safety_verdict=planned.verdict,
        generated=True,
    )


@router.put(
    "/hydration-target",
    response_model=HydrationTargetOut,
    summary="Set my own water goal",
)
async def set_hydration_target(
    payload: HydrationTargetIn, profiles: Profiles, audit: Audit
) -> HydrationTargetOut:
    """Let this person choose their own daily water goal.

    Three outcomes, all decided by :func:`app.rules.daily_goals.judge_hydration_choice`
    and none of them by this function:

    * **Refused** -- above the ceiling that module can defend from a citation, below the
      floor where a goal stops being one, or a large goal on a profile where fluid intake
      is a doctor's decision. A 422 carrying the reason, and nothing is written.
    * **Accepted with a warning** -- above the published intake range. The number is
      stored *exactly as typed*: no cap, no rounding, no silent substitution. The warning
      comes back in ``hydration_target_caution`` for the app to show, and is written to
      the audit trail with the figure, so what was chosen and what was said about it can
      be reviewed later.
    * **Accepted** -- stored, nothing to say.

    The goal lives on the health profile, in the optional ``hydration_target_override_ml``
    field. This endpoint owns the *decision*; it does not own the profile contract, so it
    checks the field exists before writing and checks the value came back after writing
    rather than reporting a success it did not verify.
    """
    profile = await profiles.health_profile()
    verdict = judge_hydration_choice(profile, payload.millilitres)
    if not verdict.accepted:
        # Recorded as well as refused. A refusal is a thing the person tried to do to
        # their own health, and the trail a clinician reads should have it in.
        await audit.event(
            "hydration_target_refused",
            {"asked_ml": payload.millilitres, "reason": verdict.reason},
        )
        raise ValidationFailed(verdict.reason)

    if HYDRATION_OVERRIDE_FIELD not in type(profile).model_fields:
        raise NotReady(
            "Setting your own water goal is not available in this version yet. Your goal "
            "has not been changed, and the figure on your Today screen is still the one "
            "our sources support."
        )

    saved = await profiles.save_health_profile(
        profile.model_copy(update={HYDRATION_OVERRIDE_FIELD: verdict.millilitres})
    )
    if chosen_hydration_ml(saved) != verdict.millilitres:
        # The field exists on the model but did not survive the round trip -- a column or
        # a mapping is missing underneath us. Saying "saved" here would be a lie the user
        # would only discover by watching the bar not move.
        raise NotReady(
            "Your water goal could not be stored just now, so nothing has changed. "
            "Please try again in a moment."
        )

    target = resolve_hydration_target(saved)
    await audit.event(
        "hydration_target_set",
        {
            "millilitres": verdict.millilitres,
            "sourced_ml": target.sourced_millilitres,
            # The warning exactly as it was put in front of the person, not a flag saying
            # one was shown. GAPS.md G20 asks a clinician to review these.
            "caution_shown": verdict.caution,
        },
    )
    return HydrationTargetOut(
        hydration_target_ml=target.millilitres,
        hydration_target_source=target.source,
        hydration_target_chosen_by_user=target.chosen_by_user,
        hydration_target_sourced_ml=target.sourced_millilitres,
        hydration_target_caution=verdict.caution or target.caution,
    )


@router.get("/{plan_date}", response_model=DayPlanOut, summary="A date's plan")
async def plan_for_date(
    plan_date: date,
    plans: Plans,
    planner: Planner,
    reference: Reference,
    audit: Audit,
    profiles: Profiles,
) -> DayPlanOut:
    return await _read_or_generate(
        plan_date, plans, planner, reference, audit, profiles, allow_generate=False
    )


# --------------------------------------------------------------------------- helpers


async def _read_or_generate(
    plan_date: date,
    plans: PlanRepository,
    planner: PlannerService,
    reference: ReferenceRepository,
    audit: AuditRepository,
    profiles: ProfileRepository,
    *,
    allow_generate: bool = True,
) -> DayPlanOut:
    header = await plans.plan_for(plan_date)
    if header is None:
        if not allow_generate:
            raise NotFound("There is no plan for that date yet.")
        await planner.generate(plan_date)
        return await _read_or_generate(
            plan_date, plans, planner, reference, audit, profiles, allow_generate=False
        )

    rows = await plans.items_for(str(header.get("id")))
    items = [item for item in (plan_item_from_row(row) for row in rows) if item is not None]
    names = await _display_names(items, reference)

    return DayPlanOut(
        plan_date=plan_date,
        items=[
            PlanItemOut(
                id=str(row.get("id")) if row.get("id") else None,
                meal_slot=item.meal_slot,
                food_id=item.food_id,
                recipe_id=item.recipe_id,
                display_name=item.display_name or names.get(item.food_id or "", ""),
                grams=item.grams,
                computed_nutrients=item.computed_nutrients,
                why_text=guarded_deterministic(item.why_text),
                order_index=item.order_index,
            )
            for row, item in zip(rows, items, strict=False)
        ],
        hydration_ml=await _hydration_for(plan_date, audit),
        **await _daily_goals(profiles, audit, plan_date),
        rationale=guarded_deterministic(str(header.get("rationale") or "")),
        escalation=Escalation.ROUTINE,
        generated=False,
    )


async def _daily_goals(
    profiles: ProfileRepository, audit: AuditRepository, plan_date: date
) -> dict[str, object]:
    """The water and movement half of the Today screen.

    Both targets are resolved by curated Python from a cited guideline
    (:mod:`app.rules.daily_goals`) and neither has ever been near a model, so they need no
    safety guard -- the same standing as a reference range. They are attached to the plan
    response because that is the one call the Today screen already makes for the day.
    """
    profile = await profiles.health_profile()
    hydration = resolve_hydration_target(profile, on=plan_date)
    movement = resolve_movement_target(profile, on=plan_date)
    return {
        "hydration_target_ml": hydration.millilitres,
        "hydration_target_source": hydration.source,
        "hydration_target_chosen_by_user": hydration.chosen_by_user,
        "hydration_target_sourced_ml": hydration.sourced_millilitres,
        "hydration_target_caution": hydration.caution,
        "movement_target_minutes_per_day": movement.minutes_per_day,
        "movement_target_minutes_per_week": movement.minutes_per_week,
        "movement_target_source": movement.source,
        "movement_minutes_logged": await movement_minutes_on(audit, plan_date),
    }


async def _display_names(items: list, reference: ReferenceRepository) -> dict[str, str]:
    """``meal_plan_items`` has no name column, so names come from the foods table."""
    food_ids = [item.food_id for item in items if item.food_id]
    if not food_ids:
        return {}
    foods = await reference.foods_by_id([f for f in food_ids if f])
    return {food.id: food.name for food in foods}


async def _hydration_for(plan_date: date, audit: AuditRepository) -> int:
    """``meal_plans`` has no hydration column, so the figure is read back from the
    ``plan_generated`` audit row the planner wrote. Zero when there is none -- never a
    number we made up on the way out."""
    for row in await audit.events("plan_generated", limit=60):
        payload = row.get("payload")
        if not isinstance(payload, dict) or payload.get("plan_date") != plan_date.isoformat():
            continue
        try:
            return int(payload.get("hydration_ml") or 0)
        except (TypeError, ValueError):
            return 0
    return 0

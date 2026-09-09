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
    get_reference,
    require_consent,
)
from app.api.guarded import GuardedText, guarded_deterministic
from app.core.errors import NotFound
from app.domain.enums import Escalation, MealSlot, SafetyVerdict
from app.planner.service import PlannerService
from app.repositories.audit import AuditRepository
from app.repositories.plans import PlanRepository, plan_item_from_row
from app.repositories.reference import ReferenceRepository

router = APIRouter(prefix="/v1/plan", tags=["plan"])

Plans = Annotated[PlanRepository, Depends(get_plans)]
Reference = Annotated[ReferenceRepository, Depends(get_reference)]
Planner = Annotated[PlannerService, Depends(get_planner)]
Audit = Annotated[AuditRepository, Depends(get_audit)]


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
    hydration_ml: int = 0
    #: The only prose a model writes here, and it went through the safety pipeline.
    rationale: GuardedText
    escalation: Escalation = Escalation.ROUTINE
    safety_verdict: SafetyVerdict = SafetyVerdict.PASS
    generated: bool = False


class RegenerateIn(BaseModel):
    model_config = ConfigDict(extra="forbid")

    plan_date: date | None = None


@router.get("/today", response_model=DayPlanOut, summary="Today's plan")
async def today(
    plans: Plans, planner: Planner, reference: Reference, audit: Audit
) -> DayPlanOut:
    return await _read_or_generate(date.today(), plans, planner, reference, audit)


@router.post(
    "/regenerate",
    response_model=DayPlanOut,
    dependencies=[Depends(require_consent)],
    summary="Regenerate a plan",
)
async def regenerate(
    payload: RegenerateIn, plans: Plans, planner: Planner, reference: Reference
) -> DayPlanOut:
    """Explicitly ask for a new plan. This is the only route that always calls a model."""
    plan_date = payload.plan_date or date.today()
    planned = await planner.generate(plan_date)
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
        rationale=planned.rationale,
        escalation=planned.escalation,
        safety_verdict=planned.verdict,
        generated=True,
    )


@router.get("/{plan_date}", response_model=DayPlanOut, summary="A date's plan")
async def plan_for_date(
    plan_date: date, plans: Plans, planner: Planner, reference: Reference, audit: Audit
) -> DayPlanOut:
    return await _read_or_generate(
        plan_date, plans, planner, reference, audit, allow_generate=False
    )


# --------------------------------------------------------------------------- helpers


async def _read_or_generate(
    plan_date: date,
    plans: PlanRepository,
    planner: PlannerService,
    reference: ReferenceRepository,
    audit: AuditRepository,
    *,
    allow_generate: bool = True,
) -> DayPlanOut:
    header = await plans.plan_for(plan_date)
    if header is None:
        if not allow_generate:
            raise NotFound("There is no plan for that date yet.")
        await planner.generate(plan_date)
        return await _read_or_generate(
            plan_date, plans, planner, reference, audit, allow_generate=False
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
        rationale=guarded_deterministic(str(header.get("rationale") or "")),
        escalation=Escalation.ROUTINE,
        generated=False,
    )


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

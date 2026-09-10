"""Recipes: how to make one item of a plan, and how much of it to have.

    "You can skip the photos and build the recipes."

A recipe is addressed by the **plan item** rather than by the food, and that is the
important decision in this module. "How much to have" is a number, and a number that
arrived from the phone is a number nobody checked -- so the endpoint reads the plan row
itself, takes ``grams`` off it, and prints that. The client sends an id and a date and
nothing else that becomes a quantity.

What comes back has three shapes, decided before any model is considered by
:func:`app.rules.recipe_readiness.assess`:

* ``preparation: "none"`` -- sunflower seeds, a banana, a glass of milk. The owner's own
  example. A curated sentence, the portion, and **no model call at all**.
* ``preparation: "ingredient"`` -- oil, sugar. Not a dish; it belongs inside another item.
* ``preparation: "method"`` -- ingredients and steps, generated once for that dish and
  stored (:mod:`app.planner.recipe_method`).

**The amounts.** The method carries no weights or volumes anywhere -- that is enforced
deterministically in :mod:`app.rules.recipe_text_rails`, not asked for politely -- and the
one quantity on the screen is ``portion_grams``, straight off the plan row that the
nutrition arithmetic was done on. ``amounts_note`` says so to the reader in as many words,
because a recipe screen beside a nutrition screen invites exactly the assumption that the
recipe's amounts produced those numbers.

This router is **not** registered in ``app/main.py`` by this change; the two lines to add
are in the change note handed over with it.
"""

from __future__ import annotations

from datetime import date
from typing import Annotated, Any, Literal

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel, ConfigDict, Field

from app.ai.client import GeminiClient
from app.api.deps import (
    get_audit,
    get_gemini,
    get_plans,
    get_reference,
    get_safety_judge,
    require_consent,
)
from app.api.guarded import GuardedText, guarded_deterministic
from app.core.errors import NotFound
from app.core.logging import get_logger
from app.domain.enums import SafetyVerdict
from app.planner.recipe_method import RecipeMethod, RecipeMethodService
from app.repositories.audit import AuditRepository
from app.repositories.plans import PlanRepository
from app.repositories.reference import ReferenceRepository
from app.rules import recipe_readiness

log = get_logger("app.api.recipes")

router = APIRouter(prefix="/v1/recipes", tags=["recipes"])

Audit = Annotated[AuditRepository, Depends(get_audit)]
Plans = Annotated[PlanRepository, Depends(get_plans)]
Reference = Annotated[ReferenceRepository, Depends(get_reference)]
Gemini = Annotated[GeminiClient | None, Depends(get_gemini)]
Judge = Annotated[object | None, Depends(get_safety_judge)]

#: Said beside every method, and beside every portion. Deterministic copy: it is the one
#: sentence that keeps the recipe and the plan's nutrition arithmetic from being read as
#: two accounts of the same thing.
AMOUNTS_NOTE = (
    "The amount below is your plan's, and it is what the plan's nutrition was worked out "
    "from. The method is a method -- it deliberately carries no weights of its own, so "
    "there is nothing here to disagree with your plan."
)

#: When we have no method and could not write one.
NO_METHOD_NOTE = (
    "We do not have a method for this one yet. Nothing was made up to fill the gap -- "
    "pull the screen down to try again in a moment."
)


class RecipeOut(BaseModel):
    model_config = ConfigDict(extra="forbid")

    item_id: str
    plan_date: date
    food_id: str | None = None
    display_name: str = ""

    #: Straight off the ``meal_plan_items`` row. The only quantity on this screen.
    portion_grams: float = 0.0
    #: That quantity as a sentence, built in Python. Never model text.
    portion_line: GuardedText
    #: Why the amounts here cannot contradict the plan's numbers.
    amounts_note: GuardedText

    preparation: Literal["none", "ingredient", "method"] = "method"
    #: The curated sentence for a food that needs nothing doing to it, or for one that is
    #: an ingredient rather than a dish, or for a method we could not write.
    note: GuardedText | None = None

    ingredients: list[GuardedText] = Field(default_factory=list)
    steps: list[GuardedText] = Field(default_factory=list)
    prep_minutes: int | None = None

    #: True when the method came out of the store rather than out of a model call now.
    #: A recipe is generated once per dish and then read; this is how that is visible.
    stored: bool = False
    generated: bool = False
    safety_verdict: SafetyVerdict = SafetyVerdict.PASS


@router.get(
    "/plan-items/{item_id}",
    response_model=RecipeOut,
    summary="How to make one item of a plan",
)
async def recipe_for_plan_item(
    item_id: str,
    plans: Plans,
    reference: Reference,
    audit: Audit,
    gemini: Gemini,
    judge: Judge,
    on: Annotated[
        date | None, Query(description="The plan's date. Defaults to today.")
    ] = None,
) -> RecipeOut:
    return await _recipe(
        item_id, on or date.today(), plans, reference, audit, gemini, judge, refresh=False
    )


@router.post(
    "/plan-items/{item_id}/refresh",
    response_model=RecipeOut,
    dependencies=[Depends(require_consent)],
    summary="Write this dish's method again",
)
async def refresh_recipe(
    item_id: str,
    plans: Plans,
    reference: Reference,
    audit: Audit,
    gemini: Gemini,
    judge: Judge,
    on: Annotated[date | None, Query(description="The plan's date.")] = None,
) -> RecipeOut:
    """Discard the stored method for this dish and write a new one.

    The only route that always calls a model, and only for a dish that needs one -- asking
    to regenerate the method for a handful of seeds still costs nothing.
    """
    return await _recipe(
        item_id, on or date.today(), plans, reference, audit, gemini, judge, refresh=True
    )


# --------------------------------------------------------------------------- the work


async def _recipe(
    item_id: str,
    plan_date: date,
    plans: PlanRepository,
    reference: ReferenceRepository,
    audit: AuditRepository,
    gemini: GeminiClient | None,
    judge: object | None,
    *,
    refresh: bool,
) -> RecipeOut:
    row = await _plan_item(item_id, plan_date, plans)
    food_id = str(row.get("food_id") or "") or None
    grams = _grams(row.get("grams"))

    food = None
    if food_id:
        found = await reference.foods_by_id([food_id])
        food = found[0] if found else None

    display_name = food.name if food is not None else ""
    readiness = recipe_readiness.assess(
        food_group=food.food_group if food is not None else None,
        name=display_name,
        name_local=food.name_local if food is not None else None,
    )

    base = RecipeOut(
        item_id=item_id,
        plan_date=plan_date,
        food_id=food_id,
        display_name=display_name,
        portion_grams=grams,
        portion_line=guarded_deterministic(portion_line(display_name, grams)),
        amounts_note=guarded_deterministic(AMOUNTS_NOTE),
        preparation=readiness.need.value,  # type: ignore[arg-type]
    )

    if not readiness.wants_a_method:
        # The owner's own case. No model, no cost, no four condescending steps for a
        # packet of seeds -- and the portion is still answered, which is the half of the
        # question that always has an answer.
        return base.model_copy(
            update={"note": guarded_deterministic(readiness.note)}
        )

    if not display_name or not food_id:
        # A plan item with no food behind it cannot be cooked and must not be guessed at.
        return base.model_copy(update={"note": guarded_deterministic(NO_METHOD_NOTE)})

    service = RecipeMethodService(audit=audit, gemini=gemini, judge=judge)
    method: RecipeMethod | None = await service.method_for(
        food_id=food_id, display_name=display_name, refresh=refresh
    )
    if method is None:
        return base.model_copy(update={"note": guarded_deterministic(NO_METHOD_NOTE)})

    await audit.event(
        "recipe_viewed",
        {"food_id": food_id, "stored": method.stored, "plan_date": plan_date.isoformat()},
    )
    return base.model_copy(
        update={
            "ingredients": method.ingredients,
            "steps": method.steps,
            "prep_minutes": method.prep_minutes,
            "stored": method.stored,
            "generated": not method.stored,
            "safety_verdict": method.verdict,
        }
    )


async def _plan_item(
    item_id: str, plan_date: date, plans: PlanRepository
) -> dict[str, Any]:
    """The stored plan-item row, or a 404.

    Read through the plan for the date rather than by id alone, because
    :class:`app.repositories.plans.PlanRepository` has no by-id read and adding one is not
    this change's file to touch. It is also the safer shape: the row is reached through a
    plan that Row Level Security has already proved belongs to the caller.
    """
    header = await plans.plan_for(plan_date)
    if header is None:
        raise NotFound("There is no plan for that date.")
    for row in await plans.items_for(str(header.get("id"))):
        if str(row.get("id")) == item_id:
            return row
    raise NotFound("That plan item does not exist on that date, or is not yours.")


def portion_line(display_name: str, grams: float) -> str:
    """"Your portion: 150 g of rajma." Built here, in Python, from the plan's own number.

    Rounded to whole grams for reading. Nothing is scaled, converted into cups or turned
    into a household measure: we have no data that says what a cup of anything weighs, and
    inventing one would put a made-up number beside a real one.
    """
    amount = f"{round(grams):,} g" if grams > 0 else "the amount in your plan"
    if display_name:
        return f"Your portion: {amount} of {display_name.lower()}."
    return f"Your portion: {amount}."


def _grams(value: Any) -> float:
    try:
        grams = float(value)
    except (TypeError, ValueError):
        return 0.0
    return grams if grams > 0 else 0.0

"""Stages 6-8: ask for a plan, throw away its numbers, keep its judgement.

    6. plan generation      -- Gemini, choosing only from candidate foods we supplied
    7. recompute + validate -- app.nutrition then app.safety, no model
    8. persist + schedule   -- rows written, alerts derived

Two guarantees this module exists to keep:

* **Every nutrient number is recomputed in Python from the ``foods`` table.**
  :func:`app.nutrition.compute.recompute_plan_items` replaces ``computed_nutrients`` and
  regenerates ``why_text`` from those recomputed numbers, so nothing a model claimed
  about grams of protein survives. Items naming a food we do not have are dropped, not
  repaired.
* **The one piece of prose the model does write -- the day's rationale -- goes through
  :func:`app.api.guarded.run_guarded`**, which is ``app.safety.pipeline.guard``. If it
  cannot be made safe in one retry, no plan is stored.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import date
from typing import Any

from app.ai.client import GeminiClient, GeminiError
from app.ai.context import build_context_block
from app.ai.prompts import for_task
from app.ai.routing import Task, model_for
from app.ai.schemas import DAY_PLAN_SCHEMA
from app.api.guarded import Guarded, GuardedText, guarded_or_withheld, run_guarded
from app.core.errors import UpstreamUnavailable
from app.core.logging import get_logger
from app.domain.enums import Escalation, MealSlot, SafetyVerdict, max_escalation
from app.domain.models import DayPlan, MealPlanItem, PlanContext, ScheduledAlert
from app.nutrition.compute import index_foods, recompute_plan_items
from app.planner.alerts import derive_alerts
from app.planner.context import AssembledContext, ContextAssembler
from app.repositories.audit import AuditRepository
from app.repositories.plans import AlertRepository, PlanRepository
from app.repositories.reference import ReferenceRepository

log = get_logger("app.planner")

#: Fallback when the model gives no hydration figure. Deliberately modest.
DEFAULT_HYDRATION_ML = 2000
MAX_HYDRATION_ML = 5000


@dataclass
class PlannedDay:
    """A finished, persisted plan and everything the API needs to describe it."""

    plan: DayPlan
    rationale: GuardedText
    why_texts: dict[int, GuardedText] = field(default_factory=dict)
    alerts: list[ScheduledAlert] = field(default_factory=list)
    escalation: Escalation = Escalation.ROUTINE
    verdict: SafetyVerdict = SafetyVerdict.PASS
    discarded: list[str] = field(default_factory=list)
    model: str = ""


class PlannerService:
    """Stages 6-8 for one user."""

    def __init__(
        self,
        *,
        assembler: ContextAssembler,
        plans: PlanRepository,
        alerts: AlertRepository,
        reference: ReferenceRepository,
        audit: AuditRepository,
        gemini: GeminiClient | None = None,
        judge: Any | None = None,
    ) -> None:
        self.assembler = assembler
        self.plans = plans
        self.alerts = alerts
        self.reference = reference
        self.audit = audit
        self.gemini = gemini
        self.judge = judge

    async def generate(self, plan_date: date) -> PlannedDay:
        assembled = await self.assembler.assemble(plan_date)
        escalation = max_escalation(flag.escalation for flag in assembled.red_flags)

        payload_holder: dict[str, Any] = {}
        model = model_for(Task.PLAN_DAY)

        guarded = await self._guarded_plan(assembled, escalation, payload_holder, model)
        if guarded.blocked:
            log.error("plan blocked by the safety layer", plan_date=plan_date.isoformat())
            await self.audit.event(
                "plan_blocked", {"plan_date": plan_date.isoformat(), "model": model}
            )
            raise UpstreamUnavailable(
                "We could not put today's plan together safely, so we have not saved one. "
                "Please try again, and if it keeps happening tell us."
            )

        payload = payload_holder.get("payload") or {}
        plan = await self._build_plan(assembled, payload, plan_date, escalation)

        stored = await self.plans.save(plan, model=model, rationale=str(guarded.text))
        derived = derive_alerts(assembled.context.profile, plan)
        await self.alerts.replace(derived)
        await self.audit.event(
            "plan_generated",
            {
                "plan_date": plan_date.isoformat(),
                "plan_id": str(stored.get("id", "")),
                "item_count": len(plan.items),
                "safety_verdict": guarded.verdict.value,
                # meal_plans has no hydration column, and inventing one is not mine to do.
                # The figure lives on this audit row so a stored plan can be read back
                # complete. Reported as a schema gap rather than worked around further.
                "hydration_ml": plan.hydration_ml,
            },
        )

        return PlannedDay(
            plan=plan,
            rationale=guarded.text,
            why_texts={
                index: guarded_or_withheld(item.why_text)
                for index, item in enumerate(plan.items)
            },
            alerts=derived,
            escalation=escalation,
            verdict=guarded.verdict,
            discarded=payload_holder.get("discarded", []),
            model=model,
        )

    # -- stage 6 -----------------------------------------------------------

    async def _guarded_plan(
        self,
        assembled: AssembledContext,
        escalation: Escalation,
        holder: dict[str, Any],
        model: str,
    ) -> Guarded:
        """Generate under the safety pipeline.

        The generate function returns the **rationale**, because that is the only string
        the model writes that a user reads. A violation regenerates the whole plan rather
        than patching the sentence, so the plan and the prose the user sees always come
        from the same attempt.
        """
        if self.gemini is None:
            raise UpstreamUnavailable("Meal planning is not configured on this server.")

        context_block = build_context_block(assembled.context)
        system = for_task(Task.PLAN_DAY.value)

        async def generate(feedback: str | None) -> str:
            prompt = context_block if feedback is None else f"{feedback}\n\n{context_block}"
            try:
                payload, run = await self.gemini.generate_json(  # type: ignore[union-attr]
                    model=model,
                    parts=prompt,
                    task=Task.PLAN_DAY.value,
                    system_instruction=system,
                    response_schema=DAY_PLAN_SCHEMA,
                    temperature=0.4,
                )
            except GeminiError as exc:
                log.warning("plan generation failed", error_type=type(exc).__name__)
                raise
            await self.audit.ai_run(run)
            if not isinstance(payload, dict):
                raise ValueError("plan response was not an object")
            holder["payload"] = payload
            return str(payload.get("rationale") or "")

        return await run_guarded(generate, escalation, judge=self.judge)

    # -- stage 7 -----------------------------------------------------------

    async def _build_plan(
        self,
        assembled: AssembledContext,
        payload: dict[str, Any],
        plan_date: date,
        escalation: Escalation,
    ) -> DayPlan:
        proposed = parse_plan_items(payload, assembled.context)
        food_ids = [item.food_id for item in proposed if item.food_id]
        recipe_ids = [item.recipe_id for item in proposed if item.recipe_id]

        foods = await self.reference.foods_by_id([f for f in food_ids if f])
        # The candidate list already holds most of these; refetching by id keeps the
        # nutrient numbers straight from the table rather than from anything cached
        # alongside the prompt.
        index = {
            **index_foods(assembled.context.candidate_foods),
            **index_foods(foods),
        }
        recipes = await self.reference.recipe_items([r for r in recipe_ids if r])

        recomputed = recompute_plan_items(
            proposed, index, gaps=assembled.context.gaps, recipes=recipes
        )
        for dropped in recomputed.discarded:
            log.warning("plan item discarded", reason=dropped.reason)

        return DayPlan(
            plan_date=plan_date,
            items=recomputed.items,
            hydration_ml=_hydration(payload.get("hydration_ml")),
            # The rationale on the domain object stays empty: the text a user sees is the
            # guarded one, and keeping an unguarded copy here would be a second door.
            rationale="",
            escalation=escalation,
        )


# ------------------------------------------------------------------------ parsing


def parse_plan_items(payload: dict[str, Any], context: PlanContext) -> list[MealPlanItem]:
    """Model JSON -> proposed items, before any nutrient maths.

    ``computed_nutrients`` is left empty and ``why_text`` is left as the model's sentence
    only so that :func:`recompute_plan_items` has something to overwrite; neither value
    survives stage 7.
    """
    allowed = {food.id for food in context.candidate_foods}
    items: list[MealPlanItem] = []
    for index, raw in enumerate(payload.get("items") or []):
        if not isinstance(raw, dict):
            continue
        slot_raw = str(raw.get("meal_slot") or "")
        if slot_raw not in set(MealSlot):
            continue
        food_id = str(raw.get("food_id") or "").strip()
        if not food_id or food_id not in allowed:
            # The model was told to choose by id from CANDIDATES. Anything else is
            # invented, and an invented food has no nutrition.
            log.warning("plan item named a food outside the candidate list")
            continue
        try:
            grams = float(raw.get("grams") or 0)
        except (TypeError, ValueError):
            continue
        items.append(
            MealPlanItem(
                meal_slot=MealSlot(slot_raw),
                food_id=food_id,
                display_name="",
                grams=grams,
                computed_nutrients={},
                why_text=str(raw.get("why") or ""),
                order_index=int(raw.get("order_index") or index),
            )
        )
    return items


def _hydration(value: Any) -> int:
    try:
        millilitres = int(value)
    except (TypeError, ValueError):
        return DEFAULT_HYDRATION_ML
    if millilitres <= 0:
        return DEFAULT_HYDRATION_ML
    return min(millilitres, MAX_HYDRATION_ML)

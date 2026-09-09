"""Stage 6, first half: assemble everything the planning prompt is allowed to see.

Nothing in here asks a model anything. It reads the user's own rows, runs the
deterministic rules and nutrition code over them, and hands the planner a
:class:`~app.domain.models.PlanContext` -- including the candidate food list, already
filtered by diet, allergies and dislikes, so the model composes meals only from foods we
chose for it.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, date, datetime, timedelta

from app.core.logging import get_logger
from app.domain.models import ClassifiedResult, PlanContext, RedFlag
from app.nutrition import candidates as candidate_rules
from app.nutrition import compute as nutrition_compute
from app.nutrition.gaps import GapReport, compute_gaps
from app.repositories.plans import FoodLogRepository, GoalRepository
from app.repositories.profiles import ProfileRepository
from app.repositories.reference import ReferenceRepository
from app.repositories.reports import ReportRepository, result_from_row
from app.rules import red_flags as red_flag_rules

log = get_logger("app.planner.context")

#: How many foods the prompt may choose from. ``app.ai.context`` trims further to fit.
CANDIDATE_LIMIT = 320

#: How far back a lab result still counts as "current" for planning purposes.
FINDINGS_WINDOW_DAYS = 365


@dataclass
class AssembledContext:
    """The plan context plus the pieces the caller needs afterwards."""

    context: PlanContext
    gap_report: GapReport
    latest_results: list[ClassifiedResult]
    red_flags: list[RedFlag]


def latest_per_biomarker(results: list[ClassifiedResult]) -> list[ClassifiedResult]:
    """One row per biomarker, the most recently measured. Undated rows lose to dated."""
    best: dict[str, ClassifiedResult] = {}
    for result in results:
        current = best.get(result.biomarker_code)
        if current is None:
            best[result.biomarker_code] = result
            continue
        if current.measured_on is None and result.measured_on is not None:
            best[result.biomarker_code] = result
        elif (
            result.measured_on is not None
            and current.measured_on is not None
            and result.measured_on > current.measured_on
        ):
            best[result.biomarker_code] = result
    return sorted(best.values(), key=lambda r: r.biomarker_code)


class ContextAssembler:
    """Builds a :class:`PlanContext` for one user and one date."""

    def __init__(
        self,
        *,
        profiles: ProfileRepository,
        reports: ReportRepository,
        goals: GoalRepository,
        food_logs: FoodLogRepository,
        reference: ReferenceRepository,
    ) -> None:
        self.profiles = profiles
        self.reports = reports
        self.goals = goals
        self.food_logs = food_logs
        self.reference = reference

    async def assemble(self, plan_date: date) -> AssembledContext:
        profile = await self.profiles.health_profile()

        history_rows = await self.reports.history()
        history = [r for r in (result_from_row(row) for row in history_rows) if r is not None]
        cutoff = plan_date - timedelta(days=FINDINGS_WINDOW_DAYS)
        recent = [
            r for r in history if r.measured_on is None or r.measured_on >= cutoff
        ]
        findings = latest_per_biomarker(recent)

        flags = red_flag_rules.evaluate(findings, history)

        foods = await self.reference.foods(limit=1000)
        intake = await self._intake_today(plan_date, foods)
        gap_report = compute_gaps(profile, intake, findings, on=plan_date)

        preferences = await self.food_logs.preferences()
        likes = [p for p in preferences if p.stance.value == "like"]
        dislikes = [p for p in preferences if p.stance.value in ("dislike", "never")]

        chosen = candidate_rules.select_candidates(
            foods,
            profile,
            gaps=gap_report,
            preferences=preferences,
            limit=CANDIDATE_LIMIT,
        )

        context = PlanContext(
            profile=profile,
            findings=findings,
            red_flags=flags,
            gaps=gap_report.outstanding(),
            goals=await self.goals.active_goals(),
            likes=likes,
            dislikes=dislikes,
            memory=await self.goals.memory(),
            candidate_foods=chosen,
            plan_date=plan_date,
        )
        log.info(
            "plan context assembled",
            finding_count=len(findings),
            gap_count=len(context.gaps),
            candidate_count=len(chosen),
            red_flag_count=len(flags),
        )
        return AssembledContext(
            context=context,
            gap_report=gap_report,
            latest_results=findings,
            red_flags=flags,
        )

    async def _intake_today(self, plan_date: date, foods: list) -> dict[str, float]:
        """What the user has already eaten today, from ``food_logs``.

        Only logs matched to a food id contribute; free text and unmatched photos have no
        nutrient numbers, and inventing them is exactly what the charter forbids.
        """
        start = datetime.combine(plan_date, datetime.min.time(), tzinfo=UTC)
        end = start + timedelta(days=1)
        rows = await self.food_logs.logs_between(start, end)
        index = nutrition_compute.index_foods(foods)
        items = []
        for row in rows:
            food_id = row.get("food_id")
            if not food_id or str(food_id) not in index:
                continue
            # food_logs carries no portion size, so a logged food counts as one standard
            # 100 g portion. Stated here rather than hidden: it is an assumption, and the
            # schema has nowhere better to put a real weight yet.
            items.append(
                nutrition_compute.ConsumedItem(food_id=str(food_id), grams=100.0)
            )
        if not items:
            return {}
        return nutrition_compute.intake_from_logs(items, index)

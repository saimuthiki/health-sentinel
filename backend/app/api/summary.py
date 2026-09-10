"""The weekly summary.

    "I may need this weekly report... please try to implement the weekly summary, which
    will be something like it will boost the user."

Two routes, shaped like ``app/api/plan.py``: a read that generates if it has to, and an
explicit regenerate. Everything about *what* a week may contain, what it must refuse to
say, and why it is generated on demand rather than on a schedule is written up in
:mod:`app.planner.weekly_summary` and :mod:`app.rules.weekly_rollup`. Three things are
worth repeating here, because they are what the response shape is for:

* **the counts and the prose are separate fields.** Every number in ``facts`` was computed
  in Python from our own rows. The one field a model wrote is ``summary``, it is
  ``GuardedText``, and it contains no digits at all -- see
  :mod:`app.rules.summary_prose_rails`;
* **a quiet week says so.** ``has_enough_data`` is false, ``summary`` is null, and
  ``lines`` explains exactly what was not logged. No model is called. An empty week
  honestly reported is what makes a full week's sentence worth reading;
* **a downgrade is visible.** ``prose_source`` says whether the reader is getting the
  model's sentence, our counts alone, or a quiet week. The app never has to infer it from
  a null.

This router is **not** registered in ``app/main.py`` by this change; the two lines to add
are in the change note handed over with it.
"""

from __future__ import annotations

from datetime import date
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel, ConfigDict, Field

from app.ai.client import GeminiClient
from app.api.deps import (
    get_audit,
    get_food_logs,
    get_gemini,
    get_plans,
    get_profiles,
    get_reports,
    get_safety_judge,
    require_consent,
)
from app.api.guarded import GuardedText, guarded_many, guarded_many_or_withheld
from app.core.errors import ValidationFailed
from app.domain.enums import SafetyVerdict
from app.planner.weekly_summary import WeeklySummary, WeeklySummaryService
from app.repositories.audit import AuditRepository
from app.repositories.plans import FoodLogRepository, PlanRepository
from app.repositories.profiles import ProfileRepository
from app.repositories.reports import ReportRepository
from app.rules import weekly_rollup as rollup

router = APIRouter(prefix="/v1/summary", tags=["summary"])

Audit = Annotated[AuditRepository, Depends(get_audit)]
Plans = Annotated[PlanRepository, Depends(get_plans)]
Logs = Annotated[FoodLogRepository, Depends(get_food_logs)]
Reports = Annotated[ReportRepository, Depends(get_reports)]
Profiles = Annotated[ProfileRepository, Depends(get_profiles)]
Gemini = Annotated[GeminiClient | None, Depends(get_gemini)]
Judge = Annotated[object | None, Depends(get_safety_judge)]

#: How far back a summary may be asked for. Two years of weeks is more history than this
#: app has, and it stops an open-ended date from turning into an unbounded trail read.
MAX_WEEKS_BACK = 104


class WeekFactsOut(BaseModel):
    """The week, counted. Not one of these numbers has been near a model."""

    model_config = ConfigDict(extra="forbid")

    meals_planned: int = 0
    days_planned: int = 0
    #: "Marked", not "eaten": what is recorded is the tap, and those are two claims.
    marked_eaten: int = 0
    marked_skipped: int = 0
    days_with_a_mark: int = 0
    meals_logged: int = 0
    days_with_a_meal_logged: int = 0
    #: Moderate-equivalent minutes, the unit the WHO target is written in.
    movement_minutes: int = 0
    days_moved: int = 0
    movement_target_minutes_per_week: int | None = None
    movement_target_source: str = ""
    #: The most recent report we could read, and two counts off it. Which values and what
    #: they mean stay on the Reports tab; this is a count of rows.
    report_measured_on: date | None = None
    report_values: int = 0
    report_outside_usual_range: int = 0


class WeeklySummaryOut(BaseModel):
    model_config = ConfigDict(extra="forbid")

    week_start: date
    week_end: date
    #: False when the week has too little logged in it to say anything encouraging that is
    #: also true. The app shows ``lines`` and no encouragement, and says why.
    has_enough_data: bool = False
    #: The only prose a model wrote. Null on a quiet week, on a rails failure, on a
    #: blocked generation, and when no model is configured.
    summary: GuardedText | None = None
    #: ``model``, ``computed`` or ``quiet``. See the module docstring.
    prose_source: Literal["model", "computed", "quiet"] = "quiet"
    #: Our own sentences about the week, built from ``facts``. Always present.
    lines: list[GuardedText] = Field(default_factory=list)
    #: What this summary cannot say about *this* week, and why. Hydration was the
    #: standing example until drinks started reaching the server; it now appears here
    #: only for a week that genuinely has no record of any, which is what every week
    #: before that change looks like. Derived from the facts rather than fixed, so the
    #: sentences and the numbers cannot drift apart.
    not_measured: list[GuardedText] = Field(default_factory=list)
    facts: WeekFactsOut = Field(default_factory=WeekFactsOut)
    #: True when a model was called during this request.
    generated: bool = False
    safety_verdict: SafetyVerdict = SafetyVerdict.PASS


@router.get("/weekly", response_model=WeeklySummaryOut, summary="A week's summary")
async def weekly(
    audit: Audit,
    plans: Plans,
    logs: Logs,
    reports: Reports,
    profiles: Profiles,
    gemini: Gemini,
    judge: Judge,
    week_start: Annotated[
        date | None,
        Query(description="Any date in the week you want. Defaults to the last complete week."),
    ] = None,
) -> WeeklySummaryOut:
    """Read the summary for a week, generating the one sentence in it if there is none.

    The default is the **last complete** week rather than this one: a summary of a week
    still in progress would say something different every day, which reads as the app
    changing its mind about how somebody is doing.
    """
    window = _window(week_start)
    service = _service(audit, plans, logs, reports, profiles, gemini, judge)
    return _out(await service.summarise(window))


@router.post(
    "/weekly/refresh",
    response_model=WeeklySummaryOut,
    dependencies=[Depends(require_consent)],
    summary="Write this week's summary again",
)
async def refresh(
    audit: Audit,
    plans: Plans,
    logs: Logs,
    reports: Reports,
    profiles: Profiles,
    gemini: Gemini,
    judge: Judge,
    week_start: Annotated[date | None, Query(description="Any date in the week.")] = None,
) -> WeeklySummaryOut:
    """Discard the stored sentence and write a new one. The only route that always calls a
    model -- and only when the week has enough in it to be worth one."""
    window = _window(week_start)
    service = _service(audit, plans, logs, reports, profiles, gemini, judge)
    return _out(await service.summarise(window, refresh=True))


# --------------------------------------------------------------------------- helpers


def _window(week_start: date | None) -> rollup.WeekWindow:
    """Any date in a week -> that Monday-to-Sunday week, refusing the impossible ones."""
    today = date.today()
    if week_start is None:
        return rollup.last_complete_week(today)
    if week_start > today:
        raise ValidationFailed("We cannot summarise a week that has not happened yet.")
    window = rollup.week_window(week_start)
    if (today - window.start).days > MAX_WEEKS_BACK * 7:
        raise ValidationFailed("That week is further back than we keep summaries for.")
    return window


def _service(
    audit: AuditRepository,
    plans: PlanRepository,
    logs: FoodLogRepository,
    reports: ReportRepository,
    profiles: ProfileRepository,
    gemini: GeminiClient | None,
    judge: object | None,
) -> WeeklySummaryService:
    """Built here rather than in ``app/api/deps.py``.

    Every repository it needs is already a dependency of this module, so a factory in
    ``deps.py`` would buy nothing but an edit to a shared file.
    """
    return WeeklySummaryService(
        audit=audit,
        plans=plans,
        food_logs=logs,
        reports=reports,
        profiles=profiles,
        gemini=gemini,
        judge=judge,
    )


def _out(summary: WeeklySummary) -> WeeklySummaryOut:
    """The service's result as the wire shape.

    ``lines`` and ``not_measured`` are minted rather than returned raw: they are our own
    copy, assembled from our own counts, and this codebase scans even its own strings
    before showing them.

    ``lines`` uses ``guarded_many_or_withheld`` because each line stands alone -- one line
    that cannot be shown should cost that line, not the week. ``not_measured`` is fixed
    constants, so a violation there is a straight bug in a literal and still raises.
    """
    facts = summary.facts
    note = facts.report
    return WeeklySummaryOut(
        week_start=facts.window.start,
        week_end=facts.window.end,
        has_enough_data=not facts.is_quiet,
        summary=summary.encouragement,
        prose_source=_source(summary.prose_source),
        lines=guarded_many_or_withheld(summary.lines),
        not_measured=guarded_many(list(summary.not_measured)),
        facts=WeekFactsOut(
            meals_planned=facts.planned_items,
            days_planned=facts.planned_days,
            marked_eaten=facts.marked_eaten,
            marked_skipped=facts.marked_skipped,
            days_with_a_mark=facts.days_with_a_mark,
            meals_logged=facts.meals_logged,
            days_with_a_meal_logged=facts.days_with_a_meal_logged,
            movement_minutes=facts.movement_minutes,
            days_moved=facts.days_moved,
            movement_target_minutes_per_week=facts.movement_target_minutes_per_week,
            movement_target_source=facts.movement_target_source,
            report_measured_on=note.measured_on if note else None,
            report_values=note.values if note else 0,
            report_outside_usual_range=note.outside_usual_range if note else 0,
        ),
        generated=summary.generated,
        safety_verdict=summary.verdict,
    )


def _source(value: str) -> Literal["model", "computed", "quiet"]:
    if value in ("model", "computed", "quiet"):
        return value  # type: ignore[return-value]
    return "computed"

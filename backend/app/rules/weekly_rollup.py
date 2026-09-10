"""One week of what actually happened, counted in Python.

This module is the whole factual basis of the weekly summary. Everything a person reads
in that summary as a *number* is computed here, from rows this service already stores,
and nothing here has ever been near a language model. That is the same standing as
``app.rules.daily_goals`` and it is deliberate: the model's job in the summary is to say
one warm sentence about facts it was handed, never to work out what the facts are.

**What a week can honestly contain**, and where each part comes from:

* meals **planned** -- ``meal_plans`` and ``meal_plan_items`` for the seven dates;
* plan items **marked eaten or skipped** -- the ``plan_item_progress`` rows
  ``POST /v1/feedback/plan-items/{id}`` writes into the append-only ``health_events``
  trail;
* meals **logged** -- ``food_logs``;
* **movement** logged -- the ``movement_logged`` rows in the same trail, folded with the
  same moderate-equivalent arithmetic the Today bar uses;
* **water** logged -- the ``hydration_logged`` rows ``POST /v1/feedback/hydration``
  writes into that same trail, summed as millilitres;
* **what the last report said** -- the date it was read and how many of its values sat
  outside our own reference ranges, which is a count of rows, not an interpretation.

**On hydration, which this summary used to refuse outright.** It refused for a good
reason: until ``POST /v1/feedback/hydration`` existed, ``logHydration`` in the Flutter
repository wrote to the phone's own cache and no endpoint received it, so the only
hydration figure the backend held was what a *plan asked for* -- and printing that as
"you drank" would have been a fabrication. Now there is a record of a drink, and a week
that has one is counted like any other. A week that has **none** is still not reported as
zero: :func:`not_measured_for` says there is no record rather than claiming the person
drank nothing, which is the only honest thing to say about every week before this
shipped. That distinction is the whole point -- an absence and a zero look identical on a
bar and mean opposite things.

*Trends and causes.* Nothing here compares one week with another and nothing here
attributes anything to anything. A count is a fact. "Up from last week" is a trend, and a
trend built on a week where somebody simply forgot to tap is not a fact about their
health. See :mod:`app.rules.summary_prose_rails` for the other half of that rule, which
is what stops the model writing one.
"""

from __future__ import annotations

from collections.abc import Iterable, Mapping, Sequence
from dataclasses import dataclass, field
from datetime import UTC, date, datetime, time, timedelta
from typing import Any

from app.domain.enums import ResultStatus
from app.rules.daily_goals import moderate_equivalent_minutes

#: The ``health_events.event_type`` one movement entry is written as. Spelled out here
#: rather than imported so that :mod:`app.rules` does not depend on :mod:`app.api`;
#: ``tests/rules/test_weekly_rollup.py`` asserts it still matches
#: ``app.api.feedback.MOVEMENT_EVENT``, so a rename cannot silently empty this column.
MOVEMENT_EVENT = "movement_logged"

#: Likewise for the row ``POST /v1/feedback/plan-items/{id}`` writes.
PLAN_ITEM_EVENT = "plan_item_progress"

#: And for one drink of water. Matched against ``app.api.feedback.HYDRATION_EVENT`` by
#: ``tests/rules/test_weekly_rollup.py``, exactly as the movement one is.
HYDRATION_EVENT = "hydration_logged"

#: Said when a week holds no record of a drink at all -- which is every week before water
#: logging existed, and any week since where nobody tapped. Deliberately "we have no
#: record" and never "you drank nothing": those are opposite claims and only one of them
#: is something we know.
NO_WATER_RECORDED = (
    "Water is not counted for this week -- we have no record of any. That is what a week "
    "before water logging reached the app looks like, and it is also what a week nobody "
    "tapped looks like, so we say nothing about it rather than show you a zero."
)

#: Said always. Comparing weeks is the other thing this summary will not do.
NOT_COMPARED = (
    "Nothing here is compared with another week. We count what you logged, and we leave "
    "the reading of it to you and your doctor."
)


#: Below this a week has too little in it to say anything encouraging that is also true.
#: Two separate logged things on two separate days: one tap on one day is a person trying
#: the app, not a week worth congratulating. An honest "we do not have enough" is what
#: makes the full weeks believable.
MIN_SIGNALS_FOR_PROSE = 2
MIN_ACTIVE_DAYS_FOR_PROSE = 2


@dataclass(frozen=True)
class WeekWindow:
    """Monday to Sunday inclusive. The unit the whole feature is stated in."""

    start: date
    end: date

    @property
    def days(self) -> list[date]:
        return [self.start + timedelta(days=offset) for offset in range(7)]

    def contains(self, day: date) -> bool:
        return self.start <= day <= self.end

    def started_at(self) -> datetime:
        """Midnight UTC on the Monday: the ``occurred_at`` floor for a trail read."""
        return datetime.combine(self.start, time.min, tzinfo=UTC)


def week_window(day: date) -> WeekWindow:
    """The Monday-to-Sunday week containing ``day``."""
    monday = day - timedelta(days=day.weekday())
    return WeekWindow(start=monday, end=monday + timedelta(days=6))


def last_complete_week(today: date) -> WeekWindow:
    """The most recent week that has finished.

    The default the endpoint uses. A summary of a week that is still running would be
    read as a verdict on it, and would say something different every day.
    """
    return week_window(today - timedelta(days=today.weekday() + 1))


@dataclass(frozen=True)
class ReportNote:
    """What the last report said, reduced to things that are counts of rows."""

    #: The day the values were measured, when the report carried one.
    measured_on: date | None = None
    values: int = 0
    #: Values our own reference ranges put outside the usual range. A count, not a
    #: judgement: which ones and what they mean stay on the Reports tab.
    outside_usual_range: int = 0
    #: Values we could not assess and asked the user to confirm.
    needs_review: int = 0


@dataclass(frozen=True)
class WeekFacts:
    """Everything true about one week that this service can prove from its own rows."""

    window: WeekWindow

    planned_items: int = 0
    planned_days: int = 0

    marked_eaten: int = 0
    marked_skipped: int = 0
    days_with_a_mark: int = 0

    meals_logged: int = 0
    days_with_a_meal_logged: int = 0

    movement_minutes: int = 0
    days_moved: int = 0
    movement_target_minutes_per_week: int | None = None
    movement_target_source: str = ""

    #: Millilitres of water logged across the week, and the days at least one drink
    #: landed on. Zero and zero mean *no record*, never "drank nothing" -- see
    #: :func:`not_measured_for`, which is what says so on screen.
    hydration_ml: int = 0
    days_hydrated: int = 0

    #: Days with at least one logged thing of any kind. The union of the three day sets
    #: rather than the largest of them: a week with a meal on Monday and a walk on
    #: Thursday is two active days, and a maximum would call it one.
    days_active: int = 0

    report: ReportNote | None = None

    #: Every number above, as a set, so :mod:`app.rules.summary_prose_rails` can refuse a
    #: sentence containing a number we did not compute.
    numbers: frozenset[int] = field(default_factory=frozenset)

    # -- how much of a week is there ---------------------------------------

    @property
    def signals(self) -> int:
        """Logged things, of any kind. Planning is not logging: a plan is generated for
        you, so counting it would let a week the person never opened look busy."""
        return (
            self.marked_eaten
            + self.marked_skipped
            + self.meals_logged
            + self.days_moved
            + self.days_hydrated
        )

    @property
    def active_days(self) -> int:
        """Days with at least one logged thing, counted once each."""
        return self.days_active

    @property
    def is_quiet(self) -> bool:
        """True when there is not enough logged to say anything encouraging and true."""
        return (
            self.signals < MIN_SIGNALS_FOR_PROSE
            or self.active_days < MIN_ACTIVE_DAYS_FOR_PROSE
        )


# ----------------------------------------------------------------------- the roll-up


def roll_up(
    window: WeekWindow,
    *,
    plan_dates: Iterable[date] = (),
    planned_items: int = 0,
    progress_events: Sequence[Mapping[str, Any]] = (),
    food_log_rows: Sequence[Mapping[str, Any]] = (),
    movement_events: Sequence[Mapping[str, Any]] = (),
    movement_target_minutes_per_week: int | None = None,
    movement_target_source: str = "",
    hydration_events: Sequence[Mapping[str, Any]] = (),
    report: ReportNote | None = None,
) -> WeekFacts:
    """Fold already-fetched rows into one week of counts. Pure: no I/O, no model.

    Rows that cannot be read are skipped rather than guessed at and are never counted as
    a zero of anything -- the stance :func:`app.api.plan._hydration_for` takes and for the
    same reason: a row we cannot parse is not evidence that nothing happened.
    """
    eaten, skipped, mark_days = _fold_progress(window, progress_events)
    meals, meal_days = _fold_food_logs(window, food_log_rows)
    minutes, move_days = _fold_movement(window, movement_events)
    millilitres, water_days = _fold_hydration(window, hydration_events)
    planned_days = len({day for day in plan_dates if window.contains(day)})

    facts = WeekFacts(
        window=window,
        planned_items=max(0, planned_items),
        planned_days=planned_days,
        marked_eaten=eaten,
        marked_skipped=skipped,
        days_with_a_mark=len(mark_days),
        meals_logged=meals,
        days_with_a_meal_logged=len(meal_days),
        movement_minutes=minutes,
        days_moved=len(move_days),
        movement_target_minutes_per_week=movement_target_minutes_per_week,
        movement_target_source=movement_target_source,
        hydration_ml=millilitres,
        days_hydrated=len(water_days),
        days_active=len(mark_days | meal_days | move_days | water_days),
        report=report,
    )
    return _with_numbers(facts)


def _with_numbers(facts: WeekFacts) -> WeekFacts:
    """Attach the set of integers a sentence about this week is allowed to contain."""
    values: set[int] = {
        facts.planned_items,
        facts.planned_days,
        facts.marked_eaten,
        facts.marked_skipped,
        facts.days_with_a_mark,
        facts.meals_logged,
        facts.days_with_a_meal_logged,
        facts.movement_minutes,
        facts.days_moved,
        facts.hydration_ml,
        facts.days_hydrated,
    }
    if facts.movement_target_minutes_per_week is not None:
        values.add(facts.movement_target_minutes_per_week)
    if facts.report is not None:
        values.update({facts.report.values, facts.report.outside_usual_range})
    return WeekFacts(
        window=facts.window,
        planned_items=facts.planned_items,
        planned_days=facts.planned_days,
        marked_eaten=facts.marked_eaten,
        marked_skipped=facts.marked_skipped,
        days_with_a_mark=facts.days_with_a_mark,
        meals_logged=facts.meals_logged,
        days_with_a_meal_logged=facts.days_with_a_meal_logged,
        movement_minutes=facts.movement_minutes,
        days_moved=facts.days_moved,
        movement_target_minutes_per_week=facts.movement_target_minutes_per_week,
        movement_target_source=facts.movement_target_source,
        hydration_ml=facts.hydration_ml,
        days_hydrated=facts.days_hydrated,
        days_active=facts.days_active,
        report=facts.report,
        numbers=frozenset(values),
    )


def _fold_progress(
    window: WeekWindow, rows: Sequence[Mapping[str, Any]]
) -> tuple[int, int, set[date]]:
    """``plan_item_progress`` rows -> (eaten, skipped, the days marked on).

    The payload carries no date of its own, so the day is ``occurred_at`` -- the day the
    person tapped. That is what the count is called on screen ("marked"), rather than
    "eaten on", because those are two different claims and only one of them is recorded.
    """
    eaten = 0
    skipped = 0
    days: set[date] = set()
    seen: set[str] = set()
    for row in rows:
        occurred = _day_of(row.get("occurred_at"))
        if occurred is None or not window.contains(occurred):
            continue
        payload = row.get("payload")
        if not isinstance(payload, dict):
            continue
        item_id = str(payload.get("item_id") or "").strip()
        state = str(payload.get("state") or "").strip()
        if not item_id or state not in ("done", "skipped"):
            continue
        # The trail is append-only, so changing your mind writes a second row for the
        # same item. Counting both would say somebody ate nine of six meals. The newest
        # row wins, and `events_since` hands them to us oldest first.
        key = f"{occurred.isoformat()}:{item_id}"
        if key in seen:
            continue
        seen.add(key)
        if state == "done":
            eaten += 1
        else:
            skipped += 1
        days.add(occurred)
    return eaten, skipped, days


def _fold_food_logs(
    window: WeekWindow, rows: Sequence[Mapping[str, Any]]
) -> tuple[int, set[date]]:
    """``food_logs`` rows -> (meals logged, the days at least one landed on)."""
    count = 0
    days: set[date] = set()
    for row in rows:
        logged = _day_of(row.get("logged_at"))
        if logged is None or not window.contains(logged):
            continue
        count += 1
        days.add(logged)
    return count, days


def _fold_movement(
    window: WeekWindow, rows: Sequence[Mapping[str, Any]]
) -> tuple[int, set[date]]:
    """``movement_logged`` rows -> (moderate-equivalent minutes, the days moved on).

    Only ``minutes`` and ``intensity`` are stored, so the equivalence is applied here on
    the way out. If :mod:`app.rules.daily_goals` ever corrects it, past weeks are
    corrected with it -- the same reason ``POST /v1/feedback/movement`` does not freeze
    the figure into the row.
    """
    minutes = 0
    days: set[date] = set()
    for row in rows:
        payload = row.get("payload")
        if not isinstance(payload, dict):
            continue
        try:
            on = date.fromisoformat(str(payload.get("on")))
            raw = int(payload.get("minutes"))
        except (TypeError, ValueError):
            continue
        if raw <= 0 or not window.contains(on):
            continue
        minutes += moderate_equivalent_minutes(
            raw, str(payload.get("intensity") or "moderate")
        )
        days.add(on)
    return minutes, days


def _fold_hydration(
    window: WeekWindow, rows: Sequence[Mapping[str, Any]]
) -> tuple[int, set[date]]:
    """``hydration_logged`` rows -> (millilitres, the days at least one drink landed on).

    Nothing is derived: the endpoint stores millilitres and this adds them up. A row that
    will not parse is skipped rather than counted as zero, for the reason in
    :func:`roll_up` -- a row we cannot read is not evidence that nobody drank.
    """
    millilitres = 0
    days: set[date] = set()
    for row in rows:
        payload = row.get("payload")
        if not isinstance(payload, dict):
            continue
        try:
            on = date.fromisoformat(str(payload.get("on")))
            raw = int(payload.get("millilitres"))
        except (TypeError, ValueError):
            continue
        if raw <= 0 or not window.contains(on):
            continue
        millilitres += raw
        days.add(on)
    return millilitres, days


def report_note(
    result_rows: Sequence[Mapping[str, Any]], *, measured_on: date | None = None
) -> ReportNote:
    """``lab_results`` rows -> the two counts the summary may state.

    ``status`` is written by :mod:`app.rules.classify`, never by a model, and null means
    "we could not assess this" rather than "normal" -- so a null counts towards
    ``needs_review`` and never towards ``outside_usual_range``.
    """
    values = 0
    outside = 0
    review = 0
    for row in result_rows:
        values += 1
        raw = row.get("status")
        status = (
            ResultStatus(raw) if isinstance(raw, str) and raw in set(ResultStatus) else None
        )
        if status is not None and status.is_abnormal:
            outside += 1
        if status is None or bool(row.get("needs_review", False)):
            review += 1
    return ReportNote(
        measured_on=measured_on,
        values=values,
        outside_usual_range=outside,
        needs_review=review,
    )


def _day_of(value: Any) -> date | None:
    """The calendar day of a stored timestamp, or None if it will not parse."""
    if value is None:
        return None
    text = str(value).strip()
    if not text:
        return None
    normalised = text.replace("Z", "+00:00")
    try:
        return datetime.fromisoformat(normalised).date()
    except ValueError:
        pass
    try:
        return date.fromisoformat(text[:10])
    except ValueError:
        return None


# ------------------------------------------------------------------ deterministic copy


def factual_lines(facts: WeekFacts) -> list[str]:
    """The week, in our own sentences. No model, no adjectives, no comparisons.

    These are what the screen shows above the encouragement, and they are what the
    encouragement is generated *from*. When a week is too quiet for encouragement, they
    are the whole summary -- which is the point: an empty week honestly reported is worth
    more than a cheerful sentence made out of nothing.
    """
    lines: list[str] = []
    if facts.planned_items:
        lines.append(
            f"We planned {_plural(facts.planned_items, 'meal', 'meals')} for you across "
            f"{_plural(facts.planned_days, 'day', 'days')}."
        )
    if facts.marked_eaten or facts.marked_skipped:
        lines.append(
            f"You marked {_plural(facts.marked_eaten, 'meal', 'meals')} as eaten and "
            f"{_plural(facts.marked_skipped, 'meal', 'meals')} as skipped, on "
            f"{_plural(facts.days_with_a_mark, 'day', 'days')}."
        )
    if facts.meals_logged:
        lines.append(
            f"You logged {_plural(facts.meals_logged, 'meal', 'meals')} of your own, on "
            f"{_plural(facts.days_with_a_meal_logged, 'day', 'days')}."
        )
    if facts.days_moved:
        line = (
            f"You logged {_plural(facts.movement_minutes, 'minute', 'minutes')} of "
            f"movement on {_plural(facts.days_moved, 'day', 'days')}"
        )
        target = facts.movement_target_minutes_per_week
        if target:
            line += f", against a weekly goal of {target} minutes"
        lines.append(line + ".")
    if facts.days_hydrated:
        # No goal on this line. The water goal is a *daily* figure and this total is a
        # week's, so printing them side by side would invite the wrong arithmetic, and
        # multiplying the goal by seven would be a number nobody computed.
        lines.append(
            f"You logged {_plural(facts.hydration_ml, 'millilitre', 'millilitres')} of "
            f"water on {_plural(facts.days_hydrated, 'day', 'days')}."
        )
    note = facts.report
    if note is not None and note.values:
        when = f" from {note.measured_on.isoformat()}" if note.measured_on else ""
        sentence = (
            f"Your most recent report{when} had "
            f"{_plural(note.values, 'value', 'values')} we could read"
        )
        if note.outside_usual_range:
            sentence += (
                f", and {note.outside_usual_range} of them sat outside the usual range "
                "-- those are the ones worth taking to your doctor"
            )
        lines.append(sentence + ".")
    return lines


def quiet_week_lines(facts: WeekFacts) -> list[str]:
    """What a week with almost nothing in it says.

    It names each thing that was not logged, in order, so that the reason the screen is
    short is visible. It offers no encouragement, because there is nothing yet to
    encourage, and it does not apologise either.
    """
    missing: list[str] = []
    if not (facts.marked_eaten or facts.marked_skipped):
        missing.append("no meal from your plan was marked eaten or skipped")
    if not facts.meals_logged:
        missing.append("no meal was logged")
    if not facts.days_moved:
        missing.append("no movement was logged")
    if not facts.days_hydrated:
        missing.append("no water was logged")

    lines = [
        "We do not have enough from this week to tell you anything true about it.",
    ]
    if missing:
        lines.append(_sentence_case(", ".join(missing)) + ".")
    if facts.planned_items:
        lines.append(
            f"Your plan was there -- {_plural(facts.planned_items, 'meal', 'meals')} "
            f"across {_plural(facts.planned_days, 'day', 'days')} -- so the only thing "
            "missing is the tap that says what you actually did."
        )
    lines.append(
        "Tap a meal as eaten when you eat it and log your walks as you go. Next week's "
        "summary will then be about your week rather than about a gap."
    )
    return lines


def not_measured_for(facts: WeekFacts) -> tuple[str, ...]:
    """Sentences about what this summary cannot say for **this** week, and why.

    Deterministic copy, shown to the reader beside the counts so that an absence is never
    mistaken for a zero. The water sentence is dropped as soon as there is water to count:
    a week with drinks in it gets a line in :func:`factual_lines` instead, and telling
    somebody we do not count something we have just counted would be the same kind of lie
    in the other direction.
    """
    if facts.days_hydrated:
        return (NOT_COMPARED,)
    return (NO_WATER_RECORDED, NOT_COMPARED)


def _plural(count: int, singular: str, plural: str) -> str:
    return f"{count} {singular if count == 1 else plural}"


def _sentence_case(text: str) -> str:
    return text[:1].upper() + text[1:] if text else text


__all__ = [
    "HYDRATION_EVENT",
    "MIN_ACTIVE_DAYS_FOR_PROSE",
    "MIN_SIGNALS_FOR_PROSE",
    "MOVEMENT_EVENT",
    "NOT_COMPARED",
    "NO_WATER_RECORDED",
    "PLAN_ITEM_EVENT",
    "ReportNote",
    "WeekFacts",
    "WeekWindow",
    "factual_lines",
    "last_complete_week",
    "not_measured_for",
    "quiet_week_lines",
    "report_note",
    "roll_up",
    "week_window",
]

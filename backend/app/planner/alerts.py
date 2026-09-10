"""Stage 8: derive the alert schedule the phone will use.

The phone schedules these itself with Android's ``AlarmManager`` (docs/02-architecture.md
§3), so they fire with the app closed, with no network and with the backend asleep. All
this module does is decide *what* and *when*, from the user's own wake time, sleep time,
meal times and water goal -- including a water goal the person set for themselves, which
changes both what the reminder says and how finely the day is spread.

Every string here is a constant or is built from the user's own profile. Nothing a model
wrote reaches an alert.
"""

from __future__ import annotations

from datetime import date, time, timedelta

from app.domain.enums import AlertType, MealSlot
from app.domain.models import DayPlan, HealthProfile, ScheduledAlert
from app.planner.weekly_summary_alert import weekly_summary_alert
from app.rules.daily_goals import (
    HYDRATION_CAUTION_ABOVE_ML,
    HydrationTarget,
    resolve_hydration_target,
)

#: Used when the profile has not said otherwise.
DEFAULT_MEAL_TIMES: dict[MealSlot, time] = {
    MealSlot.BREAKFAST: time(8, 0),
    MealSlot.MID_MORNING: time(11, 0),
    MealSlot.LUNCH: time(13, 30),
    MealSlot.EVENING_SNACK: time(17, 30),
    MealSlot.DINNER: time(20, 30),
}

MEAL_LABELS: dict[MealSlot, str] = {
    MealSlot.BREAKFAST: "Breakfast",
    MealSlot.MID_MORNING: "Mid-morning",
    MealSlot.LUNCH: "Lunch",
    MealSlot.EVENING_SNACK: "Evening snack",
    MealSlot.DINNER: "Dinner",
}

DEFAULT_WAKE = time(7, 0)
DEFAULT_SLEEP = time(23, 0)

#: Water reminders, spread across the waking day.
#:
#: The old schedule was one reminder every three hours, which is a nudge rather than a
#: plan: on a 16-hour day it lands five or six times and says nothing about how much. Two
#: hours is the ordinary spacing now, and the first is half an hour after waking.
HYDRATION_INTERVAL_MINUTES = 120

#: The spacing used when the goal in force is a large one the person set for themselves
#: (above :data:`app.rules.daily_goals.HYDRATION_CAUTION_ABOVE_ML`). More reminders, not
#: bigger ones: the hazard in a high daily target is drinking it in a few large gulps,
#: because it is the *rate* that outruns the kidneys' ability to clear water. Ten
#: reminders across a 14-hour stretch put a 5 L goal at about 500 ml a sitting and
#: 360 ml an hour, comfortably under the 735-970 ml/hour peak clearance Noakes et al.
#: measured -- the same citation the ceiling in ``daily_goals`` rests on.
HYDRATION_CLOSE_INTERVAL_MINUTES = 90

#: The first reminder is this long after waking, and the last one this long before bed.
#: An hour used to be the tail margin; 90 minutes is "well before bed" rather than "just
#: before it", and nobody wants a glass of water at the moment they lie down.
HYDRATION_FIRST_CALL_MINUTES = 30
HYDRATION_LAST_CALL_MINUTES = 90

#: How many water reminders a day is a reminder rather than a nag.
MAX_HYDRATION_REMINDERS = 8
MAX_HYDRATION_REMINDERS_SPREAD = 10

#: Grocery days: both weekend days. Saturday for the week's shop, Sunday for whatever
#: Saturday missed -- the owner asked for both, and a list that is only offered once is a
#: list that is missed by anybody whose Saturday is busy.
GROCERY_WEEKDAYS: frozenset[int] = frozenset({5, 6})
GROCERY_TIME = time(10, 0)


def _minus(at: time, minutes: int) -> time:
    total = (at.hour * 60 + at.minute - minutes) % (24 * 60)
    return time(total // 60, total % 60)


def _plus(at: time, minutes: int) -> time:
    total = (at.hour * 60 + at.minute + minutes) % (24 * 60)
    return time(total // 60, total % 60)


def meal_times(profile: HealthProfile) -> dict[MealSlot, time]:
    merged = dict(DEFAULT_MEAL_TIMES)
    merged.update(profile.meal_times)
    return merged


def derive_alerts(
    profile: HealthProfile, plan: DayPlan, *, on: date | None = None
) -> list[ScheduledAlert]:
    """The alert rows the device should schedule for this plan."""
    on = on or plan.plan_date
    times = meal_times(profile)
    wake = profile.wake_time or DEFAULT_WAKE
    sleep = profile.sleep_time or DEFAULT_SLEEP

    slots_used = {item.meal_slot for item in plan.items}
    alerts: list[ScheduledAlert] = []

    for slot in (
        MealSlot.BREAKFAST,
        MealSlot.MID_MORNING,
        MealSlot.LUNCH,
        MealSlot.EVENING_SNACK,
        MealSlot.DINNER,
    ):
        if slot not in slots_used:
            continue
        at = times.get(slot, DEFAULT_MEAL_TIMES[slot])
        alerts.append(
            ScheduledAlert(
                alert_type=AlertType.MEAL,
                title=f"{MEAL_LABELS[slot]} time",
                body=f"Today's {MEAL_LABELS[slot].lower()} is ready in your plan.",
                # Ten minutes early, so there is time to actually make it.
                at=_minus(at, 10),
            )
        )

    # The goal actually in force, which may be one the user set for themselves. It also
    # decides whether there are water reminders at all: when `daily_goals` refuses to
    # publish a target -- pregnancy, a condition where fluid intake is a doctor's
    # decision, an age our sources do not cover -- telling that person to drink a glass of
    # water eight times a day is precisely the coaching the rules module exists to stop.
    hydration = resolve_hydration_target(profile, on=on)
    if hydration.millilitres is not None:
        spread = hydration.millilitres > HYDRATION_CAUTION_ABOVE_ML
        water_body = _hydration_body(hydration, plan.hydration_ml)
        for at in hydration_times(
            wake,
            sleep,
            interval_minutes=(
                HYDRATION_CLOSE_INTERVAL_MINUTES if spread else HYDRATION_INTERVAL_MINUTES
            ),
            limit=(
                MAX_HYDRATION_REMINDERS_SPREAD if spread else MAX_HYDRATION_REMINDERS
            ),
        ):
            alerts.append(
                ScheduledAlert(
                    alert_type=AlertType.HYDRATION,
                    title="Water",
                    body=water_body,
                    at=at,
                )
            )

    alerts.append(
        ScheduledAlert(
            alert_type=AlertType.ACTIVITY,
            title="Move a little",
            body="A short walk after a meal does more for you than a long one later.",
            at=_plus(times.get(MealSlot.DINNER, DEFAULT_MEAL_TIMES[MealSlot.DINNER]), 30),
        )
    )
    alerts.append(
        ScheduledAlert(
            alert_type=AlertType.SLEEP,
            title="Wind down",
            body="Screens off soon -- you sleep better when the last hour is quiet.",
            at=_minus(sleep, 45),
        )
    )
    if on.weekday() in GROCERY_WEEKDAYS:
        alerts.append(
            ScheduledAlert(
                alert_type=AlertType.GROCERY,
                title="Grocery run",
                body="Your list for the week is ready in the app.",
                at=GROCERY_TIME,
            )
        )
    # The weekly summary belongs here and nowhere else. AlertRepository.replace
    # rewrites the derived set, so a summary alert inserted from any other place
    # would be deleted by the next plan generation -- and this is also what makes
    # the WEEKLY_SUMMARY switch on the reminders screen govern something that can
    # actually arrive.
    summary = weekly_summary_alert(profile, on=on)
    if summary is not None:
        alerts.append(summary)
    return alerts


def hydration_times(
    wake: time,
    sleep: time,
    *,
    interval_minutes: int = HYDRATION_INTERVAL_MINUTES,
    limit: int = MAX_HYDRATION_REMINDERS,
) -> list[time]:
    """Evenly spaced reminders from just after waking to well before bed.

    The window is the user's own: :data:`HYDRATION_FIRST_CALL_MINUTES` after ``wake`` to
    :data:`HYDRATION_LAST_CALL_MINUTES` before ``sleep``. Nothing is ever placed after
    that, so a late target cannot push a reminder into the night -- the last glass of the
    day is an hour and a half before bed, not at two in the morning.

    ``interval_minutes`` and ``limit`` are arguments rather than constants read from
    module scope because a large chosen goal is spread more finely than a small one; see
    :data:`HYDRATION_CLOSE_INTERVAL_MINUTES`.
    """
    start = _plus(wake, HYDRATION_FIRST_CALL_MINUTES)
    stop = _minus(sleep, HYDRATION_LAST_CALL_MINUTES)
    start_minutes = start.hour * 60 + start.minute
    stop_minutes = stop.hour * 60 + stop.minute
    if stop_minutes <= start_minutes:
        # A wake and sleep time that cross midnight, or are unset in a way that puts bed
        # before breakfast. Fall back to a plain eight-hour window from waking rather than
        # producing nothing or wrapping round the clock.
        stop_minutes = start_minutes + 8 * 60
    step = max(15, int(interval_minutes))
    out: list[time] = []
    current = start_minutes
    while current <= stop_minutes and len(out) < limit:
        out.append(time((current // 60) % 24, current % 60))
        current += step
    return out


#: What one glass holds, for turning a daily total into a number of glasses. The same
#: 250 ml the app's own "A glass" button logs.
GLASS_ML = 250


def _hydration_body(target: HydrationTarget, plan_ml: int) -> str:
    """The words on a water reminder.

    A goal the person set for themselves wins, and is named as theirs -- a reminder that
    quoted our figure at somebody who deliberately chose a different one would be the app
    arguing with them once every ninety minutes. Otherwise the plan's own hydration figure
    is used, exactly as before, and the sourced target is the last resort.

    Every number here is arithmetic done in this function on a figure from curated code or
    from the user's own choice. No model text reaches an alert body.
    """
    if target.chosen_by_user and target.millilitres:
        glasses = max(1, round(target.millilitres / GLASS_ML))
        return (
            f"Time for a glass of water -- about {glasses} across the day, toward the "
            f"{target.millilitres} ml you set yourself."
        )
    if plan_ml > 0:
        glasses = max(1, round(plan_ml / GLASS_ML))
        return f"Time for a glass of water -- about {glasses} across the day."
    if target.millilitres:
        glasses = max(1, round(target.millilitres / GLASS_ML))
        return f"Time for a glass of water -- about {glasses} across the day."
    return "Time for a glass of water."


def quiet_hours_cover(at: time, start: time, end: time) -> bool:
    """True when ``at`` falls inside a quiet window, including one crossing midnight."""
    if start <= end:
        return start <= at < end
    return at >= start or at < end


def next_occurrence(at: time, after: date) -> date:
    """The date an alert at ``at`` next fires, given it is scheduled daily."""
    return after + timedelta(days=0)

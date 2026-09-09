"""Stage 8: derive the alert schedule the phone will use.

The phone schedules these itself with Android's ``AlarmManager`` (docs/02-architecture.md
§3), so they fire with the app closed, with no network and with the backend asleep. All
this module does is decide *what* and *when*, from the user's own wake time, sleep time
and meal times.

Every string here is a constant or is built from the user's own profile. Nothing a model
wrote reaches an alert.
"""

from __future__ import annotations

from datetime import date, time, timedelta

from app.domain.enums import AlertType, MealSlot
from app.domain.models import DayPlan, HealthProfile, ScheduledAlert

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

#: Water reminders, spread across waking hours.
HYDRATION_INTERVAL_HOURS = 3
#: Grocery day: Saturday morning, so the week's list is bought before it starts.
GROCERY_WEEKDAY = 5
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

    for at in hydration_times(wake, sleep):
        alerts.append(
            ScheduledAlert(
                alert_type=AlertType.HYDRATION,
                title="Water",
                body=_hydration_body(plan.hydration_ml),
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
    if on.weekday() == GROCERY_WEEKDAY:
        alerts.append(
            ScheduledAlert(
                alert_type=AlertType.GROCERY,
                title="Grocery run",
                body="Your list for the week is ready in the app.",
                at=GROCERY_TIME,
            )
        )
    return alerts


def hydration_times(wake: time, sleep: time) -> list[time]:
    """Evenly spaced reminders between waking and an hour before bed."""
    start = _plus(wake, 30)
    stop = _minus(sleep, 60)
    start_minutes = start.hour * 60 + start.minute
    stop_minutes = stop.hour * 60 + stop.minute
    if stop_minutes <= start_minutes:
        stop_minutes = start_minutes + 8 * 60
    out: list[time] = []
    step = HYDRATION_INTERVAL_HOURS * 60
    current = start_minutes
    while current <= stop_minutes and len(out) < 8:
        out.append(time((current // 60) % 24, current % 60))
        current += step
    return out


def _hydration_body(total_ml: int) -> str:
    if total_ml <= 0:
        return "Time for a glass of water."
    glasses = max(1, round(total_ml / 250))
    return f"Time for a glass of water -- about {glasses} across the day."


def quiet_hours_cover(at: time, start: time, end: time) -> bool:
    """True when ``at`` falls inside a quiet window, including one crossing midnight."""
    if start <= end:
        return start <= at < end
    return at >= start or at < end


def next_occurrence(at: time, after: date) -> date:
    """The date an alert at ``at`` next fires, given it is scheduled daily."""
    return after + timedelta(days=0)

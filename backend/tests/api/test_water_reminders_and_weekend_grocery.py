"""Water reminders across the waking day, and a grocery reminder on both weekend days.

The owner asked for two things here. Regular drinking reminders, because a single water
alert is a nudge and not a plan; and the shopping reminder on Sunday as well as Saturday,
because a list offered once is a list missed by anybody whose Saturday is busy.

The schedule is the interesting half. It is built from the person's own wake and sleep
times, it stops well before bed, and it gets *finer* rather than *bigger* when the goal in
force is a large one somebody chose for themselves -- drinking a high daily total in a few
gulps is the part that outruns the kidneys, so the same litres are spread across more
reminders. Nothing here comes from a model.
"""

from __future__ import annotations

from datetime import date, time
from itertools import pairwise

import pytest

from app.domain.enums import AlertType, MealSlot, Sex
from app.domain.models import DayPlan, HealthProfile, MealPlanItem
from app.planner.alerts import (
    GROCERY_WEEKDAYS,
    HYDRATION_LAST_CALL_MINUTES,
    MAX_HYDRATION_REMINDERS,
    MAX_HYDRATION_REMINDERS_SPREAD,
    derive_alerts,
    hydration_times,
)
from app.rules.daily_goals import HYDRATION_CAUTION_ABOVE_ML

WEDNESDAY = date(2026, 9, 9)
SATURDAY = date(2026, 9, 12)
SUNDAY = date(2026, 9, 13)

ADULT_DOB = date(2001, 3, 1)
WAKE = time(6, 30)
SLEEP = time(22, 30)


def owner(**kwargs) -> HealthProfile:
    """The owner's own day: up at half six, in bed at half ten, adult, male."""
    kwargs.setdefault("dob", ADULT_DOB)
    kwargs.setdefault("sex", Sex.MALE)
    kwargs.setdefault("wake_time", WAKE)
    kwargs.setdefault("sleep_time", SLEEP)
    return HealthProfile(user_id="owner", **kwargs)


def a_plan(on: date = WEDNESDAY, hydration_ml: int = 2500) -> DayPlan:
    return DayPlan(
        plan_date=on,
        items=[
            MealPlanItem(
                meal_slot=MealSlot.LUNCH,
                food_id="a",
                display_name="Ragi",
                grams=80,
                why_text="x",
            )
        ],
        hydration_ml=hydration_ml,
    )


def water_alerts(profile: HealthProfile, *, on: date = WEDNESDAY, hydration_ml: int = 2500):
    return [
        alert
        for alert in derive_alerts(profile, a_plan(on, hydration_ml), on=on)
        if alert.alert_type is AlertType.HYDRATION
    ]


def minutes(at: time) -> int:
    return at.hour * 60 + at.minute


# --------------------------------------------------------------- across the waking day


def test_water_is_a_schedule_now_and_not_a_single_nudge() -> None:
    times = [alert.at for alert in water_alerts(owner())]
    assert len(times) == MAX_HYDRATION_REMINDERS
    assert times == sorted(times)
    # Every gap is the same, and it is two hours.
    gaps = {minutes(b) - minutes(a) for a, b in pairwise(times)}
    assert gaps == {120}


def test_the_first_one_is_after_waking_and_the_last_well_before_bed() -> None:
    times = [alert.at for alert in water_alerts(owner())]
    assert times[0] == time(7, 0)
    assert minutes(times[-1]) <= minutes(SLEEP) - HYDRATION_LAST_CALL_MINUTES
    # Nobody wants a glass of water at two in the morning: nothing lands in the night.
    assert all(time(6, 30) <= at <= time(21, 0) for at in times)


def test_the_schedule_is_the_persons_own_hours_not_ours() -> None:
    early = [alert.at for alert in water_alerts(owner(wake_time=time(5, 0), sleep_time=time(21, 0)))]
    assert early[0] == time(5, 30)
    assert minutes(early[-1]) <= minutes(time(19, 30))


def test_a_day_whose_times_make_no_sense_still_gets_a_sane_window() -> None:
    # Sleep before waking (a night shift, or a profile filled in wrongly). The fallback is
    # a plain eight-hour stretch from waking, not an empty list and not a wrap round
    # midnight.
    times = hydration_times(time(22, 0), time(23, 0))
    assert times
    assert times[0] == time(22, 30)


# ------------------------------------------------- a goal somebody set for themselves


def test_a_large_chosen_goal_is_spread_more_finely_rather_than_poured_faster() -> None:
    times = [alert.at for alert in water_alerts(owner(hydration_target_override_ml=5000))]
    assert len(times) == MAX_HYDRATION_REMINDERS_SPREAD
    gaps = {minutes(b) - minutes(a) for a, b in pairwise(times)}
    assert gaps == {90}
    # Still nothing in the night.
    assert minutes(times[-1]) <= minutes(SLEEP) - HYDRATION_LAST_CALL_MINUTES
    # And the litres per hour stay under the slowest peak rate healthy kidneys have been
    # measured to clear water at (735 ml/h, Noakes 2001), which is the point of spreading.
    span_hours = (minutes(times[-1]) - minutes(times[0])) / 60
    assert 5000 / span_hours < 735


def test_the_reminder_says_the_goal_actually_in_force() -> None:
    body = water_alerts(owner(hydration_target_override_ml=5000))[0].body
    assert "5000 ml" in body
    assert "you set yourself" in body
    # 5000 / 250 ml a glass = 20, computed here and not quoted from anywhere.
    assert "20" in body


def test_without_a_chosen_goal_the_body_is_the_one_it_always_was() -> None:
    body = water_alerts(owner())[0].body
    assert body == "Time for a glass of water -- about 10 across the day."


def test_a_goal_just_under_the_caution_line_keeps_the_ordinary_spacing() -> None:
    times = water_alerts(owner(hydration_target_override_ml=HYDRATION_CAUTION_ABOVE_ML))
    assert len(times) == MAX_HYDRATION_REMINDERS


# ------------------------------------------------ nobody is told to drink who should not


@pytest.mark.parametrize(
    "who",
    [
        {"conditions": ["Stage 4 CKD"]},
        {"sex": Sex.FEMALE, "is_pregnant": True},
        {"dob": date(2012, 3, 1)},
    ],
)
def test_no_water_reminders_at_all_where_there_is_no_water_target(who: dict) -> None:
    profile = owner(**who)
    assert water_alerts(profile) == []
    # The rest of the day is untouched: this is a water rule, not a silence.
    kinds = {alert.alert_type for alert in derive_alerts(profile, a_plan(), on=WEDNESDAY)}
    assert AlertType.MEAL in kinds
    assert AlertType.SLEEP in kinds


def test_a_high_goal_on_a_restricted_profile_buys_no_reminders_either() -> None:
    assert water_alerts(owner(conditions=["dialysis"], hydration_target_override_ml=5000)) == []


# ------------------------------------------------------------------- the weekend shop


@pytest.mark.parametrize("on", [SATURDAY, SUNDAY])
def test_the_grocery_reminder_lands_on_both_weekend_days(on: date) -> None:
    alerts = derive_alerts(owner(), a_plan(on), on=on)
    grocery = [alert for alert in alerts if alert.alert_type is AlertType.GROCERY]
    assert len(grocery) == 1
    assert grocery[0].at == time(10, 0)


@pytest.mark.parametrize("day", [7, 8, 9, 10, 11])  # Monday to Friday of the same week
def test_and_on_no_weekday(day: int) -> None:
    on = date(2026, 9, day)
    assert on.weekday() < 5
    alerts = derive_alerts(owner(), a_plan(on), on=on)
    assert not [alert for alert in alerts if alert.alert_type is AlertType.GROCERY]


def test_the_weekend_is_the_two_days_and_not_a_number_somewhere_else() -> None:
    assert frozenset({SATURDAY.weekday(), SUNDAY.weekday()}) == GROCERY_WEEKDAYS


# ------------------------------------------------------------ everything stays schedulable


def test_every_alert_derived_is_a_type_the_app_already_knows_how_to_show() -> None:
    # The reminders screen lists all nine types by wire string. Anything derived here has
    # to be one of them, or somebody receives a reminder they cannot find a switch for.
    alerts = derive_alerts(
        owner(hydration_target_override_ml=5000), a_plan(SATURDAY), on=SATURDAY
    )
    assert alerts
    assert {alert.alert_type for alert in alerts} <= set(AlertType)
    assert all(alert.title and alert.body for alert in alerts)

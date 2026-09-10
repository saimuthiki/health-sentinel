"""The reminder that makes a weekly feature weekly.

``AlertType.WEEKLY_SUMMARY`` existed, the reminders screen listed it, and nothing had ever
created a row of that type -- so the toggle governed a reminder that could not arrive. The
first test here is the proof of that gap; the rest are the fix.
"""

from __future__ import annotations

from datetime import date, time

from app.domain.enums import AlertType
from app.domain.models import DayPlan, HealthProfile
from app.planner.alerts import derive_alerts
from app.planner.weekly_summary_alert import (
    SUMMARY_WEEKDAY,
    summary_time,
    weekly_summary_alert,
)

MONDAY = date(2026, 9, 7)
WEDNESDAY = date(2026, 9, 9)


def profile(**fields) -> HealthProfile:
    return HealthProfile(user_id="u1", **fields)


def plan(on: date = MONDAY) -> DayPlan:
    return DayPlan(plan_date=on, items=[], hydration_ml=2000, rationale="")


def test_the_planner_now_derives_the_weekly_summary_alert():
    """The hook is in, and this is the test that was left to catch it going in.

    It used to assert the opposite: that ``derive_alerts`` produced no summary alert,
    because the module that calls this one was another change's file to edit. The call
    has since been added, and flipping this assertion is how that was noticed rather
    than discovered later.

    Why it has to be derived here and not inserted anywhere else:
    ``AlertRepository.replace`` rewrites the derived set, so a summary alert written
    from any other place is deleted by the next plan generation.
    """
    derived = derive_alerts(profile(), plan(), on=MONDAY)
    assert AlertType.WEEKLY_SUMMARY in {alert.alert_type for alert in derived}


def test_no_summary_alert_is_derived_on_a_day_that_is_not_monday():
    """The other half: it is a weekly reminder, so six days a week it is absent."""
    derived = derive_alerts(profile(), plan(on=WEDNESDAY), on=WEDNESDAY)
    assert AlertType.WEEKLY_SUMMARY not in {alert.alert_type for alert in derived}


def test_the_alert_exists_on_a_monday():
    alert = weekly_summary_alert(profile(), on=MONDAY)
    assert alert is not None
    assert alert.alert_type is AlertType.WEEKLY_SUMMARY
    assert alert.enabled is True
    assert MONDAY.weekday() == SUMMARY_WEEKDAY


def test_there_is_no_alert_on_any_other_day():
    """Shaped like the grocery alert: the row exists only on the day it is for."""
    for offset in range(1, 7):
        day = date.fromordinal(MONDAY.toordinal() + offset)
        assert weekly_summary_alert(profile(), on=day) is None


def test_it_is_monday_rather_than_sunday_night():
    """A summary of a week that has not ended would say something different in the
    morning, which reads as the app changing its mind."""
    sunday = date.fromordinal(MONDAY.toordinal() - 1)
    assert sunday.weekday() == 6
    assert weekly_summary_alert(profile(), on=sunday) is None


def test_the_time_follows_this_persons_own_wake_time():
    assert summary_time(profile(wake_time=time(6, 0))) == time(7, 30)
    assert summary_time(profile(wake_time=time(9, 45))) == time(11, 15)


def test_a_profile_that_has_not_said_when_it_wakes_still_gets_a_time():
    assert summary_time(profile()) == time(8, 30)


def test_a_wake_time_near_midnight_does_not_produce_an_impossible_clock():
    assert summary_time(profile(wake_time=time(23, 30))) == time(1, 0)


def test_the_notification_text_neither_congratulates_nor_consoles():
    """It is read on a lock screen by somebody who has opened nothing. We have not counted
    their week yet, so we cannot say how it went."""
    alert = weekly_summary_alert(profile(), on=MONDAY)
    assert alert is not None
    body = alert.body.lower()
    for word in ("well done", "great", "sorry", "missed", "behind", "streak"):
        assert word not in body
    assert "ready" in body


def test_nothing_about_the_alert_came_from_a_model():
    """Every string is a constant in the module, which is what lets it be a notification
    at all: there is no safety pipeline on a lock screen."""
    from app.planner import weekly_summary_alert as module

    alert = weekly_summary_alert(profile(), on=MONDAY)
    assert alert is not None
    assert alert.title == module.TITLE
    assert alert.body == module.BODY


def test_the_alert_survives_a_call_with_no_date_at_all():
    """Called without ``on`` -- as a caller that already knows it is the right day would
    -- it always returns the alert rather than guessing at today."""
    assert weekly_summary_alert(profile()) is not None

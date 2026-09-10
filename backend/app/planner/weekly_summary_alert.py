"""The one alert that makes a weekly feature actually weekly.

``AlertType.WEEKLY_SUMMARY`` has existed in :mod:`app.domain.enums` and been listed on the
reminders screen since before this change, and **nothing has ever created a row of that
type**: :func:`app.planner.alerts.derive_alerts` emits meal, hydration, activity, sleep and
grocery alerts and no summary alert, so the toggle on the phone has always governed a kind
of reminder that could not arrive. That is the gap this module fills.

It is a separate module because ``app/planner/alerts.py`` is not this change's file to
edit. The function is written, tested and ready; the single line that calls it is reported
rather than inserted -- see the change note at the bottom of this docstring.

**Why an alert rather than a server-side job.** The summary itself is generated on demand
(:mod:`app.planner.weekly_summary`) because this deployment has no scheduler and the free
host sleeps. The phone does not sleep in that sense: Android's ``AlarmManager`` fires with
the app closed, with no network and with the backend cold, which is exactly why every
other reminder in this app is scheduled on the device. So the weekly rhythm lives where
the reliable clock is, and the generation happens when the person taps the notification.

**Monday, not Sunday night.** The summary covers a finished Monday-to-Sunday week. Asked
for on Sunday evening it would be a summary of a week that has not ended, and it would say
something different on Monday -- which reads as the app changing its mind. Monday morning
is the first moment the week is a fact.

The change ``app/planner/alerts.py`` needs, at the end of ``derive_alerts`` beside the
existing grocery block::

    from app.planner.weekly_summary_alert import weekly_summary_alert

    summary = weekly_summary_alert(profile, on=on)
    if summary is not None:
        alerts.append(summary)
"""

from __future__ import annotations

from datetime import date, time

from app.domain.enums import AlertType
from app.domain.models import HealthProfile, ScheduledAlert

#: Monday. ``date.weekday()`` counts from zero.
SUMMARY_WEEKDAY = 0

#: How long after waking the nudge lands. Long enough to be out of the rush, early enough
#: to still be Monday morning.
MINUTES_AFTER_WAKE = 90

#: Used when the profile has not said when this person wakes. The same default
#: ``app.planner.alerts`` uses, repeated rather than imported so that this module can be
#: read on its own.
DEFAULT_WAKE = time(7, 0)

TITLE = "Your week"

#: Deliberately flat. A notification is read on a lock screen by somebody who has not
#: opened anything yet, so it must not congratulate or console -- neither of which we know
#: to be warranted until the week has been counted.
BODY = "Last week's summary is ready. Have a look when you have a minute."


def summary_time(profile: HealthProfile) -> time:
    """When Monday's nudge fires, from this person's own wake time."""
    wake = profile.wake_time or DEFAULT_WAKE
    total = (wake.hour * 60 + wake.minute + MINUTES_AFTER_WAKE) % (24 * 60)
    return time(total // 60, total % 60)


def weekly_summary_alert(
    profile: HealthProfile, *, on: date | None = None
) -> ScheduledAlert | None:
    """The weekly-summary alert for ``on``, or ``None`` on any other day.

    Shaped like the grocery alert in :func:`app.planner.alerts.derive_alerts`: the row
    exists only on the day it is for, because the alert set is rewritten whenever a plan
    is generated and the device schedules whatever it is handed.

    Every string is a constant from this module. No model has been near it, which is what
    lets it be a notification at all -- there is no safety pipeline on a lock screen.
    """
    if on is not None and on.weekday() != SUMMARY_WEEKDAY:
        return None
    return ScheduledAlert(
        alert_type=AlertType.WEEKLY_SUMMARY,
        title=TITLE,
        body=BODY,
        at=summary_time(profile),
    )


__all__ = [
    "BODY",
    "DEFAULT_WAKE",
    "MINUTES_AFTER_WAKE",
    "SUMMARY_WEEKDAY",
    "TITLE",
    "summary_time",
    "weekly_summary_alert",
]

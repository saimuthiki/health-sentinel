"""The alert definitions the phone should schedule for itself.

The server never fires these. It says *what* and *when*; Android's ``AlarmManager`` does
the rest, which is why reminders keep working with the app closed, with no network and
with a free-tier backend asleep (docs/07-open-decisions.md, D3).

Quiet hours are applied here rather than on the device so that the rule lives in one
place and the app cannot drift from it.
"""

from __future__ import annotations

from datetime import time
from typing import Annotated

from fastapi import APIRouter, Depends
from pydantic import BaseModel, ConfigDict, Field, field_validator

from app.api.deps import get_alerts
from app.core.errors import NotFound, ValidationFailed
from app.domain.enums import AlertType
from app.planner.alerts import quiet_hours_cover
from app.repositories.mapping import parse_time
from app.repositories.plans import AlertRepository

router = APIRouter(prefix="/v1/alerts", tags=["alerts"])

Alerts = Annotated[AlertRepository, Depends(get_alerts)]

#: Escalation alerts are never silenced. An undismissable card is not a preference.
ALWAYS_ON: frozenset[AlertType] = frozenset({AlertType.ESCALATION})


class QuietHours(BaseModel):
    start: str | None = None
    end: str | None = None


class AlertOut(BaseModel):
    id: str | None = None
    alert_type: AlertType
    title: str
    body: str
    at: str = Field(description="Local time of day, HH:MM.")
    enabled: bool = True
    #: True when this alert falls inside the user's quiet hours and the device should
    #: hold it. Computed here so the app has one rule to follow, not two.
    suppressed_by_quiet_hours: bool = False


class AlertList(BaseModel):
    alerts: list[AlertOut] = Field(default_factory=list)
    quiet_hours: QuietHours = Field(default_factory=QuietHours)


class ToggleIn(BaseModel):
    model_config = ConfigDict(extra="forbid")

    enabled: bool


class QuietHoursIn(BaseModel):
    model_config = ConfigDict(extra="forbid")

    start: str = Field(description="HH:MM")
    end: str = Field(description="HH:MM")

    @field_validator("start", "end")
    @classmethod
    def _valid_time(cls, value: str) -> str:
        if parse_time(value) is None:
            raise ValueError("must be a time of day like 22:30")
        return value.strip()[:5]


@router.get("", response_model=AlertList, summary="Alerts to schedule")
async def list_alerts(alerts: Alerts) -> AlertList:
    rows = await alerts.all()
    quiet = QuietHours()
    for row in rows:
        raw = row.get("quiet_hours")
        if isinstance(raw, dict) and raw.get("start") and raw.get("end"):
            quiet = QuietHours(start=str(raw["start"]), end=str(raw["end"]))
            break

    out: list[AlertOut] = []
    for row in rows:
        alert_type = str(row.get("alert_type") or "")
        at = parse_time(row.get("schedule_rule"))
        if alert_type not in set(AlertType) or at is None:
            continue
        kind = AlertType(alert_type)
        out.append(
            AlertOut(
                id=str(row.get("id")) if row.get("id") else None,
                alert_type=kind,
                title=str(row.get("title") or ""),
                body=str(row.get("body") or ""),
                at=at.isoformat(timespec="minutes"),
                enabled=bool(row.get("enabled", True)),
                suppressed_by_quiet_hours=_suppressed(kind, at, quiet),
            )
        )
    return AlertList(alerts=out, quiet_hours=quiet)


@router.patch("/{alert_type}", response_model=AlertList, summary="Turn a type on or off")
async def toggle(alert_type: AlertType, payload: ToggleIn, alerts: Alerts) -> AlertList:
    if alert_type in ALWAYS_ON and not payload.enabled:
        raise ValidationFailed(
            "Escalation alerts cannot be switched off. They only appear when something "
            "in your results needs a doctor."
        )
    rows = await alerts.set_enabled(alert_type, payload.enabled)
    if not rows:
        raise NotFound("You have no alerts of that type yet.")
    return await list_alerts(alerts)


@router.put("/quiet-hours", response_model=AlertList, summary="Set quiet hours")
async def set_quiet_hours(payload: QuietHoursIn, alerts: Alerts) -> AlertList:
    await alerts.set_quiet_hours(payload.start, payload.end)
    return await list_alerts(alerts)


def _suppressed(kind: AlertType, at: time, quiet: QuietHours) -> bool:
    if kind in ALWAYS_ON or not quiet.start or not quiet.end:
        return False
    start = parse_time(quiet.start)
    end = parse_time(quiet.end)
    if start is None or end is None:
        return False
    return quiet_hours_cover(at, start, end)

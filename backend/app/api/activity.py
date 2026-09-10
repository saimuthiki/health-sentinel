"""Named exercise: what he did, for how long, and what it cost in energy.

``/v1/feedback/movement`` already records minutes and an intensity, and the Today screen
already draws them as a bar. What it could not do was name anything. The owner asked for
that in as many words:

    "The person may spend some physical activity, like running, badminton or something
    like that. How much time did he spend? ... this much of calories you had burnt till
    date ... you can let the user know all the types of physical exercises -- instead of
    this 'movement target' kind of thing."

So this router adds three things and changes nothing:

* ``GET /v1/activity/types`` -- the named list, each row carrying its own citation.
* ``POST /v1/activity/sessions`` -- one session, by name, in minutes.
* ``GET /v1/activity/summary`` -- today, this week, and the running total since the
  first thing he ever logged, with the energy figure for each.

**It writes the same event the existing endpoint writes.** A session logged here lands in
``health_events`` as ``movement_logged`` with exactly the payload
``app.api.feedback._movement_entry`` already reads, plus an ``activity_key`` that older
reader ignores. So the Today bar and ``GET /v1/feedback/movement`` pick these up for free,
there is one trail rather than two, and nothing had to be rewritten to get there.

The one exception is activity under 3 METs. WHO's 150 minutes counts moderate-to-vigorous
activity, so an hour of Hatha yoga is good for a person and is *not* part of what that bar
measures. Counting it would overstate the week. Those sessions are written as
``activity_logged`` instead: this module reads them, gives them their energy figure, and
the WHO bar never sees them.
"""

from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass
from datetime import UTC, date, datetime, time, timedelta
from typing import Annotated, Any, Literal

from fastapi import APIRouter, Depends
from pydantic import BaseModel, ConfigDict, Field

from app.api.deps import get_audit, get_principal, get_profiles
from app.api.feedback import MAX_MOVEMENT_MINUTES, MOVEMENT_EVENT
from app.core.errors import ValidationFailed
from app.domain.models import HealthProfile
from app.repositories.audit import AuditRepository
from app.repositories.profiles import ProfileRepository
from app.rules.activity_energy import (
    ACTIVITIES,
    COMPENDIUM_2011,
    ENERGY_IS_AN_ESTIMATE,
    MODERATE,
    NO_WEIGHT_RECORDED,
    NOTHING_NAMED_TO_COST,
    OTHER_ACTIVITY_KEY,
    Activity,
    activity_for,
    energy_kcal,
    round_kcal,
)
from app.rules.daily_goals import moderate_equivalent_minutes, resolve_movement_target

router = APIRouter(prefix="/v1/activity", tags=["activity"])

Audit = Annotated[AuditRepository, Depends(get_audit)]
Profiles = Annotated[ProfileRepository, Depends(get_profiles)]

#: Event type for a session that is real exercise but is **not** what WHO's 150 minutes
#: counts, because it is under 3 METs. Kept out of ``movement_logged`` so the target bar
#: cannot be inflated by it; read here so the energy total still includes it.
LIGHT_ACTIVITY_EVENT = "activity_logged"

#: Earlier than any row this product can hold, so "since you started" really is every
#: session rather than a window we chose. What actually bounds the answer is
#: :data:`TRAIL_ROW_LIMIT`, and when that bites we say so instead of under-reporting.
TRAIL_BEGINS = datetime(1970, 1, 1, tzinfo=UTC)

#: The most rows ``AuditRepository.events_since`` will return for one event type. It
#: orders ascending, so hitting this limit drops the **newest** sessions -- which is why
#: the recent window below is fetched separately and is always exact.
TRAIL_ROW_LIMIT = 500

#: How many days back "this week" means, today included.
WEEK_DAYS = 7

#: The window re-fetched on its own when the lifetime read was truncated, so that today
#: and this week stay exact even for somebody with years of history.
RECENT_WINDOW_DAYS = 31


# --------------------------------------------------------------------------- schemas


class ActivityTypeOut(BaseModel):
    key: str
    label: str
    example: str
    #: ``null`` for "Something else", where there is no published figure to state.
    mets: float | None = None
    #: ``light`` | ``moderate`` | ``vigorous``, or ``null`` when the person says.
    intensity: str | None = None
    #: False only for activity under 3 METs, which WHO's weekly figure does not count.
    counts_toward_target: bool = True
    #: Whether this row needs the caller to send an intensity. True only for
    #: "Something else".
    needs_intensity: bool = False
    #: The citation for this row's MET figure, or the reason there is not one.
    source: str


class ActivityTypesOut(BaseModel):
    activities: list[ActivityTypeOut] = Field(default_factory=list)
    #: The one citation behind every MET figure above.
    source: str = COMPENDIUM_2011
    #: The sentence that must accompany any energy figure taken from these.
    energy_basis: str = ENERGY_IS_AN_ESTIMATE


class LogActivityIn(BaseModel):
    """One session of a named activity.

    No ``user_id``, and ``extra="forbid"`` refuses one if it is sent. The row is written
    by :class:`AuditRepository` under the caller's own id with the caller's own token, so
    logging into somebody else's day is refused twice over.
    """

    model_config = ConfigDict(extra="forbid")

    #: One of the keys from ``GET /v1/activity/types``. An unknown key is refused rather
    #: than guessed at or filed under "other".
    activity: str
    minutes: int = Field(ge=1, le=MAX_MOVEMENT_MINUTES)
    #: Only for "Something else", and required there. For every other activity the
    #: intensity comes from the Compendium and is not the caller's to state.
    intensity: Literal["moderate", "vigorous"] | None = None
    #: The day it happened, for logging last night's game this morning. A future date is
    #: refused.
    on: date | None = None


class EnergyOut(BaseModel):
    """An energy figure, or a stated reason there is not one."""

    #: Kilocalories, rounded to the nearest 5. ``null`` when it could not be worked out.
    kcal: int | None = None
    #: Present only when ``kcal`` is null: which of the two missing inputs it was.
    unavailable_reason: str | None = None
    #: Sessions inside this total that carry no energy figure of their own -- an older
    #: free-text entry, or a "Something else". Their minutes are counted; their energy
    #: is not, so the total is a floor rather than a guess.
    sessions_without_energy: int = 0


class ActivityTotalsOut(BaseModel):
    start: date | None = None
    end: date | None = None
    sessions: int = 0
    minutes: int = 0
    #: Minutes in the unit WHO's target is written in: a vigorous minute counts twice.
    #: Light activity is excluded entirely, because the guideline does not count it.
    moderate_equivalent_minutes: int = 0
    days_logged: int = 0
    energy: EnergyOut = Field(default_factory=EnergyOut)
    #: True when the audit read hit its row limit, so this total is "at least" rather
    #: than "exactly". Said out loud rather than quietly under-reported.
    truncated: bool = False


class LogActivityOut(BaseModel):
    on: date
    activity: str
    label: str
    minutes: int
    intensity: str
    counts_toward_target: bool
    moderate_equivalent_minutes: int
    energy: EnergyOut
    #: The whole of that day after this session, so the card can move without a second
    #: call. That day, not necessarily today: a session can be logged against yesterday.
    day: ActivityTotalsOut


class ActivitySummaryOut(BaseModel):
    today: ActivityTotalsOut
    week: ActivityTotalsOut
    #: Everything logged, ever. ``start`` is the first day with anything on it, so the
    #: app can say "since 3 March" rather than the untrue "till date".
    total: ActivityTotalsOut
    #: Consecutive days ending today (or yesterday, if nothing is logged yet today) with
    #: at least one session on them. A count of logging, not a claim about health.
    logged_days_in_a_row: int = 0
    target_minutes_per_day: int | None = None
    target_minutes_per_week: int | None = None
    target_source: str = ""
    #: The weight the energy figures were worked out from, so the app can show what it
    #: used. ``null`` when the profile has none.
    weight_kg: float | None = None
    energy_basis: str = ENERGY_IS_AN_ESTIMATE


# --------------------------------------------------------------------------- reading


@dataclass(frozen=True)
class _Session:
    """One stored session, already interpreted. Never a partially-read row."""

    on: date
    minutes: int
    intensity: str
    mets: float | None
    counts_toward_target: bool


def _describe(activity: Activity, *, needs_intensity: bool) -> ActivityTypeOut:
    return ActivityTypeOut(
        key=activity.key,
        label=activity.label,
        example=activity.example,
        mets=activity.mets,
        intensity=activity.intensity,
        counts_toward_target=activity.counts_toward_target,
        needs_intensity=needs_intensity,
        source=activity.source,
    )


def _energy_for(
    sessions: list[_Session], weight_kg: float | None
) -> EnergyOut:
    """Add up what can be added up, and count what could not.

Two different silences are kept apart. No recorded weight means *nothing* can be
    worked out, so ``kcal`` is null and the reason says which input is missing. A weight
    plus a session with no MET value means the rest of the total still stands and one
    session is missing from it, which is reported as a count rather than folded in as a
    zero.
    """
    if weight_kg is None:
        return EnergyOut(
            kcal=None,
            unavailable_reason=NO_WEIGHT_RECORDED,
            sessions_without_energy=len(sessions),
        )
    total = 0.0
    unknown = 0
    for session in sessions:
        kcal = energy_kcal(session.mets, session.minutes, weight_kg)
        if kcal is None:
            unknown += 1
            continue
        total += kcal
    if sessions and unknown == len(sessions):
        # Every session here is one we cannot cost. Answering "0 kcal" would read as
        # "you burnt nothing", which is a different and untrue claim. Nothing logged at
        # all is a real zero and keeps one.
        return EnergyOut(
            kcal=None,
            unavailable_reason=NOTHING_NAMED_TO_COST,
            sessions_without_energy=unknown,
        )
    return EnergyOut(kcal=round_kcal(total), sessions_without_energy=unknown)


def _totals(
    sessions: list[_Session],
    weight_kg: float | None,
    *,
    start: date | None,
    end: date | None,
    truncated: bool = False,
) -> ActivityTotalsOut:
    days = {session.on for session in sessions}
    return ActivityTotalsOut(
        start=start if start is not None else (min(days) if days else None),
        end=end if end is not None else (max(days) if days else None),
        sessions=len(sessions),
        minutes=sum(session.minutes for session in sessions),
        moderate_equivalent_minutes=sum(
            moderate_equivalent_minutes(session.minutes, session.intensity)
            for session in sessions
            if session.counts_toward_target
        ),
        days_logged=len(days),
        energy=_energy_for(sessions, weight_kg),
        truncated=truncated,
    )


def _session_from(payload: Any, *, counts_toward_target: bool) -> _Session | None:
    """One stored payload, or ``None`` when it is not one we can read.

    An unreadable row is skipped rather than guessed at, and never counted as zero
    minutes of something -- the same stance ``app.api.feedback._movement_entry`` takes.

    A row written before this router existed carries no ``activity_key``. Its minutes
    still count; its energy cannot, because nothing says what the activity was. That
    session comes back with ``mets=None`` and is counted in
    ``EnergyOut.sessions_without_energy``.
    """
    if not isinstance(payload, dict):
        return None
    try:
        on = date.fromisoformat(str(payload.get("on")))
        minutes = int(payload.get("minutes"))
    except (TypeError, ValueError):
        return None
    if minutes <= 0:
        return None
    activity = activity_for(str(payload.get("activity_key") or ""))
    return _Session(
        on=on,
        minutes=minutes,
        intensity=str(payload.get("intensity") or MODERATE),
        mets=activity.mets if activity is not None else None,
        counts_toward_target=counts_toward_target,
    )


async def _sessions_since(
    audit: AuditRepository, since: datetime
) -> tuple[list[_Session], bool]:
    """Every session recorded at or after ``since``, and whether the read was truncated.

    Both event types are read: ``movement_logged`` for anything that counts toward WHO's
    target -- including entries made through ``/v1/feedback/movement`` before this router
    existed -- and ``activity_logged`` for the under-3-MET sessions deliberately kept out
    of it.
    """
    sessions: list[_Session] = []
    truncated = False
    for event_type, counts in (
        (MOVEMENT_EVENT, True),
        (LIGHT_ACTIVITY_EVENT, False),
    ):
        rows = await audit.events_since(event_type, since, limit=TRAIL_ROW_LIMIT)
        # events_since orders ascending, so a full page means the newest rows were the
        # ones left behind. Never silently: the caller is told.
        truncated = truncated or len(rows) >= TRAIL_ROW_LIMIT
        for row in rows:
            session = _session_from(row.get("payload"), counts_toward_target=counts)
            if session is not None:
                sessions.append(session)
    return sessions, truncated


def _streak(sessions: list[_Session], today: date) -> int:
    """Consecutive days with something logged, ending today or yesterday.

    Yesterday is allowed as the end so that opening the app at 8am does not report a
    fortnight's habit as broken before the day has happened. Nothing more is claimed than
    "you logged something on each of these days".
    """
    days = {session.on for session in sessions}
    cursor = today if today in days else today - timedelta(days=1)
    run = 0
    while cursor in days:
        run += 1
        cursor -= timedelta(days=1)
    return run


async def _weight_kg(profiles: ProfileRepository) -> tuple[float | None, HealthProfile]:
    profile = await profiles.health_profile()
    weight = profile.weight_kg
    if weight is None or weight <= 0:
        return None, profile
    return float(weight), profile


# -------------------------------------------------------------------------- endpoints


@router.get(
    "/types",
    response_model=ActivityTypesOut,
    summary="The named activities",
    # The list is not user data, but every other route under /v1 is behind a token and a
    # route that can be probed without one is a new surface for no gain. One rule.
    dependencies=[Depends(get_principal)],
)
async def activity_types() -> ActivityTypesOut:
    """The list the app shows, with the citation for every figure in it.

    Curated data held in ``app.rules.activity_energy`` rather than in ``db/seed`` -- that
    module's docstring says why -- and deliberately not model output. Naming an exercise
    and stating its energy cost is a health number, so it follows the same rule every
    other number in this service follows: it comes from a cited published source or it
    does not exist.
    """
    return ActivityTypesOut(
        activities=[
            _describe(activity, needs_intensity=activity.key == OTHER_ACTIVITY_KEY)
            for activity in ACTIVITIES
        ]
    )


@router.post(
    "/sessions",
    response_model=LogActivityOut,
    status_code=201,
    summary="Log one session of a named activity",
)
async def log_activity(
    payload: LogActivityIn, audit: Audit, profiles: Profiles
) -> LogActivityOut:
    """Record one session, by name.

    Where it is stored, and why, is in this module's docstring: the same append-only
    ``health_events`` trail and the same ``movement_logged`` shape the older endpoint
    writes, so nothing downstream needed changing to see it.

    What is **not** stored is the energy figure. Like the moderate-equivalent minutes in
    ``app.api.feedback``, it is derived on the way out from the activity key, the minutes
    and the profile's weight. Freezing a kcal figure into the row would mean a corrected
    MET value never reached the sessions already logged, and it would keep answering with
    an old body weight for ever.
    """
    activity = activity_for(payload.activity)
    if activity is None:
        raise ValidationFailed(
            "We do not know that activity. Choose one from the list, or "
            f"'{OTHER_ACTIVITY_KEY}' if it is not on it."
        )

    on = payload.on or date.today()
    if on > date.today():
        raise ValidationFailed("We cannot log activity for a day that has not happened yet.")

    if activity.key == OTHER_ACTIVITY_KEY:
        if payload.intensity is None:
            raise ValidationFailed(
                "Tell us whether that was moderate or vigorous. We do not know what it "
                "was, so we cannot work the intensity out for you."
            )
        intensity = payload.intensity
    else:
        if payload.intensity is not None:
            # Refused rather than ignored. The intensity of badminton is the
            # Compendium's, and quietly overwriting a caller's value with ours would
            # make the reply disagree with the request.
            raise ValidationFailed(
                f"The intensity of {activity.label.lower()} comes from the published "
                "figure for it, not from the app. Send an intensity only with "
                f"'{OTHER_ACTIVITY_KEY}'."
            )
        intensity = activity.intensity or MODERATE

    counts = activity.counts_toward_target
    await audit.event(
        MOVEMENT_EVENT if counts else LIGHT_ACTIVITY_EVENT,
        {
            "on": on.isoformat(),
            "minutes": payload.minutes,
            "intensity": intensity,
            # The free-text field the older endpoint already accepts, so an entry made
            # here reads correctly through GET /v1/feedback/movement too.
            "activity": activity.label,
            # The key is what makes the energy figure derivable later. Ignored by the
            # older reader, which only looks at on/minutes/intensity.
            "activity_key": activity.key,
        },
    )

    weight, _ = await _weight_kg(profiles)
    sessions, truncated = await _sessions_since(
        audit, datetime.combine(on, time.min, tzinfo=UTC)
    )
    day_sessions = [session for session in sessions if session.on == on]
    session_energy = _energy_for(
        [
            _Session(
                on=on,
                minutes=payload.minutes,
                intensity=intensity,
                mets=activity.mets,
                counts_toward_target=counts,
            )
        ],
        weight,
    )
    return LogActivityOut(
        on=on,
        activity=activity.key,
        label=activity.label,
        minutes=payload.minutes,
        intensity=intensity,
        counts_toward_target=counts,
        moderate_equivalent_minutes=(
            moderate_equivalent_minutes(payload.minutes, intensity) if counts else 0
        ),
        energy=session_energy,
        day=_totals(day_sessions, weight, start=on, end=on, truncated=truncated),
    )


@router.get(
    "/summary",
    response_model=ActivitySummaryOut,
    summary="Today, this week, and everything logged so far",
)
async def activity_summary(audit: Audit, profiles: Profiles) -> ActivitySummaryOut:
    """The three numbers the card shows, and the target to read them against.

    "Till date" is answered honestly. The read reaches back past anything this product
    could hold, so ``total`` really is everything -- but it is bounded by the audit
    trail's row limit, and when that bites, ``total.truncated`` is true and the app must
    say "at least" rather than a flat figure. In that case today and this week are
    re-read over a short window so they stay exact, because those are the numbers
    somebody checks against their own memory of the day.
    """
    today = date.today()
    week_start = today - timedelta(days=WEEK_DAYS - 1)
    weight, profile = await _weight_kg(profiles)

    everything, truncated = await _sessions_since(audit, TRAIL_BEGINS)
    recent = everything
    if truncated:
        recent, _ = await _sessions_since(
            audit,
            datetime.combine(
                today - timedelta(days=RECENT_WINDOW_DAYS - 1), time.min, tzinfo=UTC
            ),
        )

    by_day: dict[date, list[_Session]] = defaultdict(list)
    for session in recent:
        by_day[session.on].append(session)

    target = resolve_movement_target(profile, on=today)
    return ActivitySummaryOut(
        today=_totals(by_day.get(today, []), weight, start=today, end=today),
        week=_totals(
            [session for session in recent if week_start <= session.on <= today],
            weight,
            start=week_start,
            end=today,
        ),
        total=_totals(everything, weight, start=None, end=None, truncated=truncated),
        logged_days_in_a_row=_streak(recent, today),
        target_minutes_per_day=target.minutes_per_day,
        target_minutes_per_week=target.minutes_per_week,
        target_source=target.source,
        weight_kg=weight,
    )

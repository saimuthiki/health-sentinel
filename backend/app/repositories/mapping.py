"""Row <-> domain translation, and where the schema and the enums still differ.

Two of the three original mismatches were closed in db/migrations/009_domain_alignment.sql
rather than papered over here, because both were lossy on write and a value a user
chose was coming back as a different one:

* ``activity_level`` accepted only three of ``ActivityLevel``'s five members, so
  "very active" was stored as "heavy" and read back as "active". Nutrition targets key
  off activity, so the downgrade quietly changed what the app recommended. The column
  now accepts all five and the value round-trips. The three-band ICMR-NIN mapping still
  exists, but it lives in ``nutrition/targets.py`` where it belongs -- applied at lookup,
  losing nothing stored.
* ``meal_plan_items.meal_slot`` accepted ``snack`` but not ``evening_snack``. It now
  accepts both, and ``MealSlot.EVENING_SNACK`` stores as itself. The legacy spellings are
  still read so no existing row is orphaned.

One mismatch is left standing on purpose:

* ``health_profiles.sex`` accepts ``prefer_not_to_say``, which ``Sex`` has no member for
  and which reads back as ``Sex.OTHER``. Collapsing those two would be the same defect as
  the ones above -- they mean different things to a person. The real fix is a new enum
  member, and because ``Sex`` selects reference ranges, that deserves a deliberate pass
  rather than a drive-by. Recorded in db/migrations/009 as a decision, not an oversight.
  The app no longer offers "prefer not to say", so no new row can be written with it;
  rows written before that still read back as ``Sex.OTHER``.

And one column is written here that the schema does not have yet:

* ``health_profiles.hydration_target_override_ml``. The profile contract carries a water
  target the person set for themselves, and it is written as null when they have not set
  one. **The column has to exist before this ships** -- the SQL is in the handover notes
  for this change. Until it is applied, PostgREST answers every profile write with a 400,
  which is loud, immediate and impossible to miss; omitting the key instead would have
  meant a target that silently could never be cleared.
"""

from __future__ import annotations

from datetime import date, time
from typing import Any

from app.domain.enums import ActivityLevel, DietType, MealSlot, Sex
from app.domain.models import Allergy, HealthProfile

# ------------------------------------------------------------------ activity level

#: Each member stores as its own value -- the column accepts all five since
#: migration 009. Nothing is folded on the way in.
_ACTIVITY_TO_DB: dict[ActivityLevel, str] = {level: level.value for level in ActivityLevel}

#: Reading also accepts the pre-009 spellings, so rows written before the migration
#: still load. "heavy" was what both ACTIVE and VERY_ACTIVE collapsed to; it cannot be
#: un-collapsed, and ACTIVE is the less surprising of the two to show back.
_ACTIVITY_FROM_DB: dict[str, ActivityLevel] = {
    **{level.value: level for level in ActivityLevel},
    "heavy": ActivityLevel.ACTIVE,
}


def activity_to_db(level: ActivityLevel) -> str:
    return _ACTIVITY_TO_DB[level]


def activity_from_db(value: str | None) -> ActivityLevel:
    return _ACTIVITY_FROM_DB.get((value or "").strip(), ActivityLevel.MODERATE)


# ---------------------------------------------------------------------- meal slot

_SLOT_TO_DB: dict[MealSlot, str] = {
    MealSlot.BREAKFAST: "breakfast",
    MealSlot.MID_MORNING: "mid_morning",
    MealSlot.LUNCH: "lunch",
    MealSlot.EVENING_SNACK: "evening_snack",
    MealSlot.DINNER: "dinner",
}

_SLOT_FROM_DB: dict[str, MealSlot] = {
    "breakfast": MealSlot.BREAKFAST,
    "mid_morning": MealSlot.MID_MORNING,
    "lunch": MealSlot.LUNCH,
    "snack": MealSlot.EVENING_SNACK,
    "evening_snack": MealSlot.EVENING_SNACK,
    "dinner": MealSlot.DINNER,
    # The schema allows a bedtime slot the enum has no member for. Reading it as the
    # evening snack keeps a legacy row visible instead of dropping someone's plan item.
    "bedtime": MealSlot.EVENING_SNACK,
}


def slot_to_db(slot: MealSlot) -> str:
    return _SLOT_TO_DB[slot]


def slot_from_db(value: str | None) -> MealSlot | None:
    return _SLOT_FROM_DB.get((value or "").strip())


# --------------------------------------------------------------------------- sex


def _text(value: Any) -> str | None:
    """A text column trimmed, with blank read back as unset."""
    if not isinstance(value, str):
        return None
    stripped = value.strip()
    return stripped or None


def sex_from_db(value: str | None) -> Sex:
    raw = (value or "").strip()
    if raw in ("male", "female"):
        return Sex(raw)
    return Sex.OTHER


# --------------------------------------------------------------------- scalars


def parse_date(value: Any) -> date | None:
    if isinstance(value, date):
        return value
    if isinstance(value, str) and value.strip():
        try:
            return date.fromisoformat(value.strip()[:10])
        except ValueError:
            return None
    return None


def parse_time(value: Any) -> time | None:
    if isinstance(value, time):
        return value
    if isinstance(value, str) and value.strip():
        raw = value.strip()
        for length in (8, 5):
            try:
                return time.fromisoformat(raw[:length])
            except ValueError:
                continue
    return None


def parse_float(value: Any) -> float | None:
    if value is None:
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def parse_int(value: Any) -> int | None:
    """An integer column, or None. A value that is not a whole number reads as None
    rather than as a rounded one -- a millilitre figure nobody typed is worse than
    none."""
    if value is None or isinstance(value, bool):
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def iso(value: date | time | None) -> str | None:
    return value.isoformat() if value is not None else None


# ------------------------------------------------------------------ health profile


def health_profile_from_rows(
    user_id: str,
    row: dict[str, Any] | None,
    allergies: list[dict[str, Any]] | None = None,
) -> HealthProfile:
    """Build the domain profile. A missing row gives the documented defaults."""
    row = row or {}
    meal_times: dict[MealSlot, time] = {}
    raw_times = row.get("meal_times")
    if isinstance(raw_times, dict):
        for key, value in raw_times.items():
            slot = slot_from_db(str(key))
            parsed = parse_time(value)
            if slot is not None and parsed is not None:
                meal_times[slot] = parsed

    diet_raw = (row.get("diet_type") or "").strip()
    diet = DietType(diet_raw) if diet_raw in set(DietType) else DietType.NON_VEG

    return HealthProfile(
        user_id=user_id,
        dob=parse_date(row.get("dob")),
        sex=sex_from_db(row.get("sex")),
        height_cm=parse_float(row.get("height_cm")),
        weight_kg=parse_float(row.get("weight_kg")),
        activity_level=activity_from_db(row.get("activity_level")),
        diet_type=diet,
        cuisine_pref=list(row.get("cuisine_pref") or []),
        city=row.get("city"),
        pincode=_text(row.get("pincode")),
        wake_time=parse_time(row.get("wake_time")),
        sleep_time=parse_time(row.get("sleep_time")),
        meal_times=meal_times,
        conditions=list(row.get("conditions") or []),
        allergies=[
            Allergy(
                allergen=str(a.get("allergen", "")).strip(),
                severity=str(a.get("severity") or "unknown"),
            )
            for a in (allergies or [])
            if str(a.get("allergen", "")).strip()
        ],
        is_pregnant=bool(row.get("pregnancy", False)),
        hydration_target_override_ml=parse_int(row.get("hydration_target_override_ml")),
    )


def health_profile_to_row(profile: HealthProfile) -> dict[str, Any]:
    """Domain profile -> ``health_profiles`` row. ``user_id`` is set by the repository."""
    return {
        "dob": iso(profile.dob),
        "sex": profile.sex.value,
        "height_cm": profile.height_cm,
        "weight_kg": profile.weight_kg,
        "activity_level": activity_to_db(profile.activity_level),
        "diet_type": profile.diet_type.value,
        "cuisine_pref": list(profile.cuisine_pref),
        "city": profile.city,
        "pincode": profile.pincode,
        "wake_time": iso(profile.wake_time),
        "sleep_time": iso(profile.sleep_time),
        "meal_times": {slot_to_db(k): v.isoformat() for k, v in profile.meal_times.items()},
        "conditions": list(profile.conditions),
        "pregnancy": profile.is_pregnant,
        # Written as null when unset rather than omitted: PUT replaces the profile, so a
        # key left out is a value that can never be cleared again. This needs
        # health_profiles.hydration_target_override_ml to exist -- the SQL is
        # db/run-in-supabase/5_water_target_and_goals.sql, and until it has been run every
        # profile write is a 400. Loud and immediate beats a target that silently sticks.
        "hydration_target_override_ml": profile.hydration_target_override_ml,
    }

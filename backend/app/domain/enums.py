"""Enumerations shared across the whole backend.

These values are also written into the database CHECK constraints in ``db/migrations``.
If you change a value here, change it there in the same commit.
"""

from __future__ import annotations

from enum import StrEnum


class Sex(StrEnum):
    MALE = "male"
    FEMALE = "female"
    OTHER = "other"


class DietType(StrEnum):
    VEG = "veg"
    NON_VEG = "non_veg"
    EGG = "egg"
    VEGAN = "vegan"
    JAIN = "jain"


class ActivityLevel(StrEnum):
    SEDENTARY = "sedentary"
    LIGHT = "light"
    MODERATE = "moderate"
    ACTIVE = "active"
    VERY_ACTIVE = "very_active"


class ReportType(StrEnum):
    BLOOD = "blood"
    URINE = "urine"
    THYROID = "thyroid"
    VITAMIN = "vitamin"
    LIPID = "lipid"
    DIABETES = "diabetes"
    SCAN = "scan"
    PRESCRIPTION = "prescription"
    OTHER = "other"


class ReportStatus(StrEnum):
    UPLOADED = "uploaded"
    EXTRACTING = "extracting"
    EXTRACTED = "extracted"
    FAILED = "failed"


class ResultStatus(StrEnum):
    """Where a lab value sits against our own reference range.

    Assigned by ``app.rules.classify`` -- never by a language model.
    """

    CRITICAL_LOW = "critical_low"
    LOW = "low"
    BORDERLINE_LOW = "borderline_low"
    NORMAL = "normal"
    BORDERLINE_HIGH = "borderline_high"
    HIGH = "high"
    CRITICAL_HIGH = "critical_high"
    UNKNOWN = "unknown"

    @property
    def is_abnormal(self) -> bool:
        return self not in (ResultStatus.NORMAL, ResultStatus.UNKNOWN)

    @property
    def is_critical(self) -> bool:
        return self in (ResultStatus.CRITICAL_LOW, ResultStatus.CRITICAL_HIGH)


class Escalation(StrEnum):
    """How urgently a human clinician should be involved.

    Ordered: comparing with ``>`` is meaningless, use ``ESCALATION_ORDER``.
    """

    ROUTINE = "routine"
    SEE_DOCTOR_SOON = "see_doctor_soon"
    URGENT = "urgent"


ESCALATION_ORDER: dict[Escalation, int] = {
    Escalation.ROUTINE: 0,
    Escalation.SEE_DOCTOR_SOON: 1,
    Escalation.URGENT: 2,
}


def max_escalation(levels: object) -> Escalation:
    """Return the most severe escalation in ``levels`` (empty -> ROUTINE)."""
    best = Escalation.ROUTINE
    for level in levels:  # type: ignore[union-attr]
        if ESCALATION_ORDER[level] > ESCALATION_ORDER[best]:
            best = level
    return best


class MealSlot(StrEnum):
    BREAKFAST = "breakfast"
    MID_MORNING = "mid_morning"
    LUNCH = "lunch"
    EVENING_SNACK = "evening_snack"
    DINNER = "dinner"


class GoalType(StrEnum):
    WEIGHT = "weight"
    HAIR = "hair"
    SKIN = "skin"
    ENERGY = "energy"
    SLEEP = "sleep"
    FITNESS = "fitness"
    DEFICIENCY = "deficiency"
    DIET_QUALITY = "diet_quality"


class Stance(StrEnum):
    LIKE = "like"
    DISLIKE = "dislike"
    NEUTRAL = "neutral"
    NEVER = "never"


class AlertType(StrEnum):
    HYDRATION = "hydration"
    MEAL = "meal"
    GROCERY = "grocery"
    ACTIVITY = "activity"
    SLEEP = "sleep"
    NUTRITION = "nutrition"
    REPORT_FOLLOWUP = "report_followup"
    WEEKLY_SUMMARY = "weekly_summary"
    ESCALATION = "escalation"


class SafetyVerdict(StrEnum):
    PASS = "pass"
    REGENERATED = "regenerated"
    BLOCKED = "blocked"


class SafetyViolation(StrEnum):
    """Why the safety layer rejected a model output."""

    MEDICATION_NAMED = "medication_named"
    DOSAGE_GIVEN = "dosage_given"
    DIAGNOSIS_STATED = "diagnosis_stated"
    TREATMENT_DISCOURAGED = "treatment_discouraged"
    RED_FLAG_DOWNPLAYED = "red_flag_downplayed"

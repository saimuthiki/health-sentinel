"""Domain models shared across the backend.

These are the contract between the modules:

* ``app.ingest`` produces :class:`ExtractedRow` from a file (via Gemini).
* ``app.rules`` turns :class:`ExtractedRow` into :class:`ClassifiedResult` and
  :class:`RedFlag` -- deterministically, with no model call.
* ``app.nutrition`` turns a profile plus results into :class:`NutrientGap` and does all
  nutrient arithmetic on :class:`FoodItem`.
* ``app.ai`` assembles :class:`PlanContext` and asks Gemini for a plan.
* ``app.safety`` validates every model output into a :class:`SafetyReport`.
* ``app.planner`` writes the result into :class:`MealPlanItem` and :class:`ScheduledAlert`.

Nothing here talks to the database or the network.
"""

from __future__ import annotations

from datetime import date, time
from decimal import Decimal

from pydantic import BaseModel, ConfigDict, Field

from app.domain.enums import (
    ActivityLevel,
    AlertType,
    DietType,
    Escalation,
    GoalType,
    MealSlot,
    ResultStatus,
    SafetyVerdict,
    SafetyViolation,
    Sex,
    Stance,
)


class Base(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")


# --------------------------------------------------------------------------- profile


class Allergy(Base):
    allergen: str
    severity: str = "unknown"


class HealthProfile(Base):
    user_id: str
    dob: date | None = None
    sex: Sex = Sex.OTHER
    height_cm: float | None = None
    weight_kg: float | None = None
    activity_level: ActivityLevel = ActivityLevel.MODERATE
    diet_type: DietType = DietType.NON_VEG
    cuisine_pref: list[str] = Field(default_factory=list)
    city: str | None = None
    wake_time: time | None = None
    sleep_time: time | None = None
    meal_times: dict[MealSlot, time] = Field(default_factory=dict)
    conditions: list[str] = Field(default_factory=list)
    allergies: list[Allergy] = Field(default_factory=list)
    is_pregnant: bool = False

    def age_on(self, on: date) -> int | None:
        """Age in whole years on ``on``, or None if date of birth is unknown."""
        if self.dob is None:
            return None
        years = on.year - self.dob.year
        if (on.month, on.day) < (self.dob.month, self.dob.day):
            years -= 1
        return years


# ------------------------------------------------------------------------ extraction


class ExtractedRow(Base):
    """One row exactly as printed on a report. No interpretation applied yet."""

    printed_test_name: str
    value_text: str
    unit_text: str | None = None
    printed_range: str | None = None
    method: str | None = None
    confidence: float = 1.0


class ExtractedReport(Base):
    lab_name: str | None = None
    collected_on: date | None = None
    report_type: str | None = None
    rows: list[ExtractedRow] = Field(default_factory=list)


# -------------------------------------------------------------------- classification


class ReferenceRange(Base):
    """One curated reference range. ``source_citation`` is mandatory by policy."""

    biomarker_code: str
    sex: Sex | None = None
    age_min: int | None = None
    age_max: int | None = None
    pregnancy: bool | None = None
    low: Decimal | None = None
    high: Decimal | None = None
    borderline_low: Decimal | None = None
    borderline_high: Decimal | None = None
    critical_low: Decimal | None = None
    critical_high: Decimal | None = None
    source_citation: str


class ClassifiedResult(Base):
    """A lab value mapped to a canonical biomarker and judged against our own range."""

    biomarker_code: str
    display_name: str
    value: Decimal
    unit: str
    status: ResultStatus
    reference: ReferenceRange | None = None
    printed_range: str | None = None
    measured_on: date | None = None
    needs_review: bool = False
    review_reason: str | None = None

    @property
    def is_actionable(self) -> bool:
        return self.status.is_abnormal and not self.needs_review


class RedFlag(Base):
    """A deterministic finding that requires a clinician. Never model-generated."""

    code: str
    escalation: Escalation
    message: str
    biomarker_code: str | None = None
    symptom: str | None = None


# --------------------------------------------------------------------------- nutrition


class FoodItem(Base):
    """A food with per-100 g nutrient values, straight from the ``foods`` table."""

    id: str
    name: str
    name_local: str | None = None
    food_group: str | None = None
    per_100g: dict[str, float] = Field(default_factory=dict)
    diet_flags: list[str] = Field(default_factory=list)
    allergens: list[str] = Field(default_factory=list)
    region: str | None = None
    source: str = "unknown"

    def nutrients_for(self, grams: float) -> dict[str, float]:
        """Nutrient totals for ``grams`` of this food. The only sanctioned way to get
        a nutrient number in front of a user -- never take one from model text."""
        factor = grams / 100.0
        return {key: value * factor for key, value in self.per_100g.items()}


class NutrientTarget(Base):
    nutrient: str
    amount: float
    unit: str
    source: str


class NutrientGap(Base):
    nutrient: str
    target: float
    current: float
    unit: str

    @property
    def deficit(self) -> float:
        return max(0.0, self.target - self.current)

    @property
    def pct_of_target(self) -> float:
        if self.target <= 0:
            return 100.0
        return min(100.0, (self.current / self.target) * 100.0)


class FoodPreference(Base):
    food_id: str
    name: str
    stance: Stance
    score: float = 0.0


# -------------------------------------------------------------------------- planning


class Goal(Base):
    id: str
    goal_type: GoalType
    title: str
    priority: int = 1
    status: str = "active"


class MemoryFact(Base):
    fact: str
    category: str
    confidence: float
    confirmed: bool = False


class PlanContext(Base):
    """Everything the planning prompt is allowed to see. Assembled deterministically."""

    profile: HealthProfile
    findings: list[ClassifiedResult] = Field(default_factory=list)
    red_flags: list[RedFlag] = Field(default_factory=list)
    gaps: list[NutrientGap] = Field(default_factory=list)
    goals: list[Goal] = Field(default_factory=list)
    likes: list[FoodPreference] = Field(default_factory=list)
    dislikes: list[FoodPreference] = Field(default_factory=list)
    memory: list[MemoryFact] = Field(default_factory=list)
    candidate_foods: list[FoodItem] = Field(default_factory=list)
    plan_date: date


class MealPlanItem(Base):
    meal_slot: MealSlot
    food_id: str | None = None
    recipe_id: str | None = None
    display_name: str
    grams: float
    computed_nutrients: dict[str, float] = Field(default_factory=dict)
    why_text: str
    order_index: int = 0


class DayPlan(Base):
    plan_date: date
    items: list[MealPlanItem] = Field(default_factory=list)
    hydration_ml: int = 0
    rationale: str = ""
    escalation: Escalation = Escalation.ROUTINE


class ScheduledAlert(Base):
    alert_type: AlertType
    title: str
    body: str
    at: time
    enabled: bool = True


# ----------------------------------------------------------------------------- safety


class SafetyFinding(Base):
    violation: SafetyViolation
    excerpt: str
    span: tuple[int, int]


class SafetyReport(Base):
    verdict: SafetyVerdict
    findings: list[SafetyFinding] = Field(default_factory=list)
    text: str

    @property
    def ok(self) -> bool:
        return self.verdict is not SafetyVerdict.BLOCKED

"""Stage 5 -- red flags. Hard numeric thresholds that require a clinician.

**No language model is involved anywhere in this file, and nothing here can be argued
with.** A red flag is produced by an integer comparison against a constant that has a
written source. That is the property that makes it trustworthy: the model can be
jailbroken, a threshold cannot be.

Every threshold is a module-level constant paired with a ``SOURCE_*`` citation string,
because ``docs/03-data-model.md`` requires that we can always say where a number came
from. Where the right number was not something we could source with confidence, it is
**not** invented here -- it is written down in ``app/rules/GAPS.md`` for a clinician to
fill in.

Boundary convention (the same one used in :mod:`app.rules.classify`): a threshold
belongs to the safe side. ``HB_CRITICAL_LOW = 7.0`` means 7.0 g/dL does **not** fire and
6.9 does. ``HBA1C_DIABETIC = 6.5`` is written as "at or above", so 6.5 **does** fire.
Each rule states its own comparator in :data:`THRESHOLD_RULES`.
"""

from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal
from typing import Callable, Iterable, Sequence

from app.domain.enums import Escalation, ResultStatus
from app.domain.models import ClassifiedResult, RedFlag

# ------------------------------------------------------------------------- citations

SOURCE_CRITICAL_LIMITS = (
    "Kost GJ. Critical limits for urgent clinician notification at US medical centers. "
    "JAMA 1990;263(5):704-707 -- the standard laboratory critical-value list. "
    "HealthPulse's own escalation values are recorded in docs/04-ai-pipeline.md."
)

SOURCE_HAEMOGLOBIN = (
    "WHO. Haemoglobin concentrations for the diagnosis of anaemia and assessment of "
    "severity. WHO/NMH/NHD/MNM/11.1 (2011) -- severe anaemia < 7 g/dL in adults. "
    "Carson JL et al. Clinical Practice Guidelines From the AABB: Red Blood Cell "
    "Transfusion Thresholds and Storage. JAMA 2016;316(19):2025-2035 -- 7 g/dL "
    "transfusion threshold."
)

SOURCE_POTASSIUM = (
    "Alfonzo A et al. Treatment of Acute Hyperkalaemia in Adults. UK Kidney "
    "Association Clinical Practice Guideline (2020) -- severe hyperkalaemia "
    ">= 6.5 mmol/L; HealthPulse escalates earlier, at 6.0 mmol/L. Hypokalaemia "
    "< 2.5 mmol/L per " + SOURCE_CRITICAL_LIMITS
)

SOURCE_SODIUM = (
    "Spasovski G et al. Clinical practice guideline on diagnosis and treatment of "
    "hyponatraemia. Eur J Endocrinol 2014;170(3):G1-G47 -- profound hyponatraemia "
    "< 125 mmol/L; HealthPulse escalates at 120 mmol/L. Hypernatraemia > 160 mmol/L "
    "per " + SOURCE_CRITICAL_LIMITS
)

SOURCE_GLUCOSE = (
    "American Diabetes Association. Standards of Care in Diabetes-2024: Diagnosis and "
    "Classification. Diabetes Care 2024;47(Suppl.1):S20-S42. The 300 mg/dL escalation "
    "trigger is a HealthPulse product decision (docs/04-ai-pipeline.md), not an ADA "
    "critical value -- see GAPS.md item G1."
)

SOURCE_PLATELETS = (
    "Schiffer CA et al. Platelet Transfusion for Patients With Cancer: ASCO Clinical "
    "Practice Guideline Update. J Clin Oncol 2018;36(3):283-299. The 50,000/uL "
    "escalation trigger is a HealthPulse product decision (docs/04-ai-pipeline.md) and "
    "is more cautious than the 10,000/uL prophylactic transfusion threshold -- see "
    "GAPS.md item G2."
)

SOURCE_CREATININE = (
    "KDIGO Clinical Practice Guideline for Acute Kidney Injury. Kidney Int Suppl "
    "2012;2(1):1-138 -- stage 1 AKI is a rise to >= 1.5x baseline within 7 days, or "
    ">= 0.3 mg/dL within 48 hours. HealthPulse escalates at a 30% rise, deliberately "
    "more sensitive than the 50% KDIGO criterion."
)

SOURCE_HBA1C = (
    "American Diabetes Association. Standards of Care in Diabetes-2024: Diagnosis and "
    "Classification of Diabetes. Diabetes Care 2024;47(Suppl.1):S20-S42 -- HbA1c "
    ">= 6.5% meets the diagnostic criterion and requires confirmation by a clinician."
)

SOURCE_TSH = (
    "Jonklaas J et al. Guidelines for the Treatment of Hypothyroidism, prepared by the "
    "American Thyroid Association Task Force. Thyroid 2014;24(12):1670-1751 -- "
    "treatment is generally recommended when TSH exceeds 10 mIU/L."
)

SOURCE_NEUTROPHILS = (
    "Freifeld AG et al. Clinical Practice Guideline for the Use of Antimicrobial "
    "Agents in Neutropenic Patients with Cancer: 2010 Update by the Infectious "
    "Diseases Society of America. Clin Infect Dis 2011;52(4):e56-e93 -- severe "
    "neutropenia is an absolute neutrophil count < 500 cells/uL."
)

# ------------------------------------------------------------------------ thresholds
# Units are the canonical units declared in app.rules.normalise.BIOMARKERS.

# Haemoglobin has TWO numbers on purpose, and they must not be "fixed" into
# agreement (db/seed/GAPS.md section 4, item 1):
#
#   * 7.0 g/dL here is the *escalation* threshold -- "is this person in immediate
#     danger?" It follows docs/04-ai-pipeline.md stage 5 and the AABB transfusion
#     trigger, and it raises an URGENT card.
#   * 8.0 g/dL in db/seed/202_reference_ranges.sql is the *classification*
#     threshold -- "how far from normal is this?" It follows WHO 2011's
#     severe-anaemia boundary.
#
# They answer different questions, so a haemoglobin of 7.5 g/dL classifies as
# CRITICAL_LOW and escalates SEE_DOCTOR_SOON (via critical_status_flags below)
# rather than URGENT. That is the intended behaviour, not a bug.
HB_CRITICAL_LOW = Decimal("7.0")            # g/dL
POTASSIUM_CRITICAL_LOW = Decimal("2.5")     # mmol/L
POTASSIUM_CRITICAL_HIGH = Decimal("6.0")    # mmol/L
SODIUM_CRITICAL_LOW = Decimal("120")        # mmol/L
SODIUM_CRITICAL_HIGH = Decimal("160")       # mmol/L
GLUCOSE_FASTING_CRITICAL_HIGH = Decimal("300")   # mg/dL
PLATELETS_CRITICAL_LOW = Decimal("50")      # 10^3/uL, i.e. 50,000 per microlitre
NEUTROPHILS_CRITICAL_LOW = Decimal("500")   # cells/uL
HBA1C_DIABETIC = Decimal("6.5")             # %
TSH_HIGH = Decimal("10")                    # uIU/mL (numerically mIU/L)
CREATININE_RISE_FRACTION = Decimal("0.30")  # +30% versus the previous report

#: A creatinine rise is only meaningful above assay noise; below this the percentage is
#: dominated by rounding at one decimal place.
CREATININE_MIN_ABSOLUTE_RISE = Decimal("0.1")  # mg/dL


@dataclass(frozen=True)
class ThresholdRule:
    """One deterministic threshold. ``fires`` is a pure comparison."""

    code: str
    biomarker_code: str
    comparator: str  # "<", ">", ">=" -- stated so the boundary is never in doubt
    threshold: Decimal
    unit: str
    escalation: Escalation
    template: str
    source_citation: str

    def fires(self, value: Decimal) -> bool:
        if self.comparator == "<":
            return value < self.threshold
        if self.comparator == ">":
            return value > self.threshold
        if self.comparator == ">=":
            return value >= self.threshold
        if self.comparator == "<=":  # pragma: no cover - not used yet
            return value <= self.threshold
        raise ValueError(f"unknown comparator {self.comparator!r}")

    def message(self, value: Decimal) -> str:
        return self.template.format(value=_fmt(value), threshold=_fmt(self.threshold))


def _fmt(value: Decimal) -> str:
    text = format(value.normalize(), "f")
    return text


_SEE_DOCTOR_TODAY = (
    "Please contact a doctor today -- do not wait for your next appointment."
)
_SEE_DOCTOR_SOON = "Please book an appointment with a doctor about this."

#: The complete deterministic threshold set. Tests iterate over this, so a rule that is
#: added without a citation or without a boundary test fails the suite.
THRESHOLD_RULES: tuple[ThresholdRule, ...] = (
    ThresholdRule(
        code="HB_CRITICAL_LOW",
        biomarker_code="HB",
        comparator="<",
        threshold=HB_CRITICAL_LOW,
        unit="g/dL",
        escalation=Escalation.URGENT,
        template=(
            "Haemoglobin is {value} g/dL, below the {threshold} g/dL level at which "
            "doctors want to see someone straight away. " + _SEE_DOCTOR_TODAY
        ),
        source_citation=SOURCE_HAEMOGLOBIN,
    ),
    ThresholdRule(
        code="POTASSIUM_CRITICAL_LOW",
        biomarker_code="POTASSIUM",
        comparator="<",
        threshold=POTASSIUM_CRITICAL_LOW,
        unit="mmol/L",
        escalation=Escalation.URGENT,
        template=(
            "Potassium is {value} mmol/L, below the {threshold} mmol/L critical level. "
            "Potassium this low affects the heart rhythm. " + _SEE_DOCTOR_TODAY
        ),
        source_citation=SOURCE_POTASSIUM,
    ),
    ThresholdRule(
        code="POTASSIUM_CRITICAL_HIGH",
        biomarker_code="POTASSIUM",
        comparator=">",
        threshold=POTASSIUM_CRITICAL_HIGH,
        unit="mmol/L",
        escalation=Escalation.URGENT,
        template=(
            "Potassium is {value} mmol/L, above the {threshold} mmol/L critical level. "
            "Potassium this high affects the heart rhythm. " + _SEE_DOCTOR_TODAY
        ),
        source_citation=SOURCE_POTASSIUM,
    ),
    ThresholdRule(
        code="SODIUM_CRITICAL_LOW",
        biomarker_code="SODIUM",
        comparator="<",
        threshold=SODIUM_CRITICAL_LOW,
        unit="mmol/L",
        escalation=Escalation.URGENT,
        template=(
            "Sodium is {value} mmol/L, below the {threshold} mmol/L critical level. "
            + _SEE_DOCTOR_TODAY
        ),
        source_citation=SOURCE_SODIUM,
    ),
    ThresholdRule(
        code="SODIUM_CRITICAL_HIGH",
        biomarker_code="SODIUM",
        comparator=">",
        threshold=SODIUM_CRITICAL_HIGH,
        unit="mmol/L",
        escalation=Escalation.URGENT,
        template=(
            "Sodium is {value} mmol/L, above the {threshold} mmol/L critical level. "
            + _SEE_DOCTOR_TODAY
        ),
        source_citation=SOURCE_SODIUM,
    ),
    ThresholdRule(
        code="GLUCOSE_FASTING_CRITICAL_HIGH",
        biomarker_code="GLUCOSE_FASTING",
        comparator=">",
        threshold=GLUCOSE_FASTING_CRITICAL_HIGH,
        unit="mg/dL",
        escalation=Escalation.URGENT,
        template=(
            "Fasting blood glucose is {value} mg/dL, above the {threshold} mg/dL level "
            "we escalate at. " + _SEE_DOCTOR_TODAY
        ),
        source_citation=SOURCE_GLUCOSE,
    ),
    ThresholdRule(
        code="PLATELETS_CRITICAL_LOW",
        biomarker_code="PLT",
        comparator="<",
        threshold=PLATELETS_CRITICAL_LOW,
        unit="10^3/uL",
        escalation=Escalation.URGENT,
        template=(
            "Platelet count is {value} thousand per microlitre "
            "(below {threshold},000/uL), which raises the risk of bleeding. "
            + _SEE_DOCTOR_TODAY
        ),
        source_citation=SOURCE_PLATELETS,
    ),
    ThresholdRule(
        code="NEUTROPHILS_CRITICAL_LOW",
        biomarker_code="NEUTROPHILS_ABS",
        comparator="<",
        threshold=NEUTROPHILS_CRITICAL_LOW,
        unit="/uL",
        escalation=Escalation.URGENT,
        template=(
            "The absolute neutrophil count is {value} cells/uL, below {threshold}. "
            "At this level the body fights infection poorly, and a fever needs to be "
            "treated as an emergency. " + _SEE_DOCTOR_TODAY
        ),
        source_citation=SOURCE_NEUTROPHILS,
    ),
    ThresholdRule(
        code="TSH_HIGH",
        biomarker_code="TSH",
        comparator=">",
        threshold=TSH_HIGH,
        unit="uIU/mL",
        escalation=Escalation.SEE_DOCTOR_SOON,
        template=(
            "TSH is {value} uIU/mL, above {threshold}. This is a thyroid result "
            "doctors usually act on. " + _SEE_DOCTOR_SOON
        ),
        source_citation=SOURCE_TSH,
    ),
)

THRESHOLD_RULES_BY_CODE: dict[str, ThresholdRule] = {
    rule.code: rule for rule in THRESHOLD_RULES
}

#: HbA1c and creatinine need history, so they are functions rather than table rows.
#: They keep their citations here.
HBA1C_RULE_SOURCE = SOURCE_HBA1C
CREATININE_RULE_SOURCE = SOURCE_CREATININE


# ------------------------------------------------------------------------- evaluation


def _usable(
    results: Iterable[ClassifiedResult], include_needs_review: bool
) -> list[ClassifiedResult]:
    if include_needs_review:
        return list(results)
    return [r for r in results if not r.needs_review]


def _latest(
    results: Sequence[ClassifiedResult], biomarker_code: str
) -> ClassifiedResult | None:
    matching = [r for r in results if r.biomarker_code == biomarker_code]
    if not matching:
        return None
    dated = [r for r in matching if r.measured_on is not None]
    if dated:
        return max(dated, key=lambda r: r.measured_on)  # type: ignore[arg-type,return-value]
    return matching[-1]


def evaluate_thresholds(
    results: Iterable[ClassifiedResult],
    *,
    include_needs_review: bool = True,
) -> list[RedFlag]:
    """Run every table-driven threshold over one report's results."""
    flags: list[RedFlag] = []
    for result in _usable(results, include_needs_review):
        for rule in THRESHOLD_RULES:
            if rule.biomarker_code != result.biomarker_code:
                continue
            if result.unit and result.unit != rule.unit:
                # A value in the wrong unit is never compared. It has already been
                # marked needs_review upstream in app.rules.normalise.
                continue
            if rule.fires(result.value):
                flags.append(
                    RedFlag(
                        code=rule.code,
                        escalation=rule.escalation,
                        message=rule.message(result.value),
                        biomarker_code=result.biomarker_code,
                    )
                )
    return flags


def evaluate_hba1c(
    results: Iterable[ClassifiedResult],
    history: Sequence[ClassifiedResult] = (),
    *,
    include_needs_review: bool = True,
) -> list[RedFlag]:
    """HbA1c at or above 6.5%. The *first* time is an escalation; a known, already
    elevated HbA1c is routine follow-up rather than a new alarm."""
    current = _latest(_usable(results, include_needs_review), "HBA1C")
    if current is None or current.unit not in ("%", ""):
        return []
    if current.value < HBA1C_DIABETIC:
        return []

    seen_before = any(
        prior.biomarker_code == "HBA1C"
        and prior.unit in ("%", "")
        and prior.value >= HBA1C_DIABETIC
        and prior is not current
        for prior in history
    )
    if seen_before:
        return [
            RedFlag(
                code="HBA1C_PERSISTENT_DIABETIC_RANGE",
                escalation=Escalation.ROUTINE,
                message=(
                    f"HbA1c is {_fmt(current.value)}%, still at or above "
                    f"{_fmt(HBA1C_DIABETIC)}% as it was previously. Keep your doctor "
                    "updated at your next review."
                ),
                biomarker_code="HBA1C",
            )
        ]
    return [
        RedFlag(
            code="HBA1C_FIRST_DIABETIC_RANGE",
            escalation=Escalation.SEE_DOCTOR_SOON,
            message=(
                f"HbA1c is {_fmt(current.value)}%, at or above {_fmt(HBA1C_DIABETIC)}% "
                "for the first time in your records. This is the level doctors use to "
                "confirm a diagnosis, and it needs a doctor to confirm it -- we cannot. "
                + _SEE_DOCTOR_SOON
            ),
            biomarker_code="HBA1C",
        )
    ]


def evaluate_creatinine_trend(
    results: Iterable[ClassifiedResult],
    history: Sequence[ClassifiedResult] = (),
    *,
    include_needs_review: bool = True,
) -> list[RedFlag]:
    """Creatinine risen more than 30% versus the most recent previous report."""
    current = _latest(_usable(results, include_needs_review), "CREATININE")
    previous = _latest([h for h in history if h is not current], "CREATININE")
    if current is None or previous is None:
        return []
    if current.unit != "mg/dL" or previous.unit != "mg/dL":
        return []
    if previous.value <= 0:
        return []
    rise = current.value - previous.value
    if rise < CREATININE_MIN_ABSOLUTE_RISE:
        return []
    fraction = rise / previous.value
    if fraction <= CREATININE_RISE_FRACTION:
        return []
    pct = (fraction * 100).quantize(Decimal("1"))
    return [
        RedFlag(
            code="CREATININE_RISE",
            escalation=Escalation.SEE_DOCTOR_SOON,
            message=(
                f"Creatinine has risen {pct}% since your last report "
                f"({_fmt(previous.value)} to {_fmt(current.value)} mg/dL). A rise this "
                "size is one doctors want to look at, because it can reflect how the "
                "kidneys are working. " + _SEE_DOCTOR_SOON
            ),
            biomarker_code="CREATININE",
        )
    ]


#: Rules that need a history argument, exposed so callers and tests can enumerate them.
HISTORY_RULES: tuple[Callable[..., list[RedFlag]], ...] = (
    evaluate_hba1c,
    evaluate_creatinine_trend,
)


def evaluate(
    results: Iterable[ClassifiedResult],
    history: Sequence[ClassifiedResult] = (),
    *,
    include_needs_review: bool = True,
) -> list[RedFlag]:
    """Every deterministic lab red flag for one report.

    ``include_needs_review`` defaults to **True** on purpose. A value we are not certain
    about is still checked against the critical thresholds, because the cost of a false
    alarm ("please confirm this number with the lab") is far lower than the cost of
    staying quiet about a potassium of 6.8. The user-facing card for such a flag should
    say the value still needs confirming -- that is a UI concern, not a reason to skip
    the check here.
    """
    results = list(results)
    flags = evaluate_thresholds(results, include_needs_review=include_needs_review)
    flags += evaluate_hba1c(
        results, history, include_needs_review=include_needs_review
    )
    flags += evaluate_creatinine_trend(
        results, history, include_needs_review=include_needs_review
    )
    flags += critical_status_flags(
        _usable(results, include_needs_review),
        already_flagged=[
            flag.biomarker_code for flag in flags if flag.biomarker_code is not None
        ],
    )
    return flags


SOURCE_CRITICAL_CLASSIFICATION = (
    "A value classified CRITICAL_LOW or CRITICAL_HIGH against the curated ranges in "
    "db/seed/202_reference_ranges.sql, each of which carries its own source_citation. "
    "The escalation level is HealthPulse policy: a value at the far end of a cited "
    "range needs a doctor soon; the urgent tier is reserved for the thresholds in "
    "THRESHOLD_RULES above."
)


def critical_status_flags(
    results: Iterable[ClassifiedResult],
    *,
    already_flagged: Iterable[str] = (),
) -> list[RedFlag]:
    """Escalate anything the classifier called critical that no urgent rule caught.

    This is what keeps the deliberate haemoglobin split honest. A 7.5 g/dL is
    ``CRITICAL_LOW`` against WHO's severe-anaemia boundary of 8.0 but is above our
    urgent trigger of 7.0, so it must still reach a clinician -- one tier down.
    """
    urgent_codes = {rule.biomarker_code for rule in THRESHOLD_RULES}
    seen = set(already_flagged)
    flags: list[RedFlag] = []
    for result in results:
        if not result.status.is_critical:
            continue
        if result.biomarker_code in seen:
            continue
        direction = "below" if result.status is ResultStatus.CRITICAL_LOW else "above"
        note = ""
        if result.biomarker_code in urgent_codes:
            note = (
                " It has not crossed the level we treat as an emergency, but it is "
                "still well outside the reference range."
            )
        flags.append(
            RedFlag(
                code=f"CRITICAL_{result.status.name}_{result.biomarker_code}",
                escalation=Escalation.SEE_DOCTOR_SOON,
                message=(
                    f"{result.display_name} is {_fmt(result.value)} {result.unit}, far "
                    f"{direction} our reference range.{note} " + _SEE_DOCTOR_SOON
                ),
                biomarker_code=result.biomarker_code,
            )
        )
    return flags


def routine_deficiency_flags(results: Iterable[ClassifiedResult]) -> list[RedFlag]:
    """The bottom row of the escalation table: a mild single-nutrient deficiency.

    Deliberately ``ROUTINE`` -- it is coaching material, not an escalation.
    """
    nutrient_codes = {"VITD_25OH", "VITB12", "FERRITIN", "FOLATE", "HB"}
    flags: list[RedFlag] = []
    for result in results:
        if result.biomarker_code not in nutrient_codes:
            continue
        if result.status in (ResultStatus.LOW, ResultStatus.BORDERLINE_LOW):
            flags.append(
                RedFlag(
                    code=f"LOW_{result.biomarker_code}",
                    escalation=Escalation.ROUTINE,
                    message=(
                        f"{result.display_name} is {_fmt(result.value)} {result.unit}, "
                        "below our reference range. Food choices can help, and it is "
                        "worth mentioning at your next doctor's visit."
                    ),
                    biomarker_code=result.biomarker_code,
                )
            )
    return flags

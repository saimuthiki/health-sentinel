"""Nutrient gaps: target minus what was eaten, plus what the blood work implies.

**No language model is involved anywhere in this file.**

Two independent sources feed a gap:

1. **Intake.** Target (``app.nutrition.targets``) minus the day's food logs
   (``app.nutrition.compute``). Plain subtraction.
2. **Biomarkers.** A low ferritin means iron matters for this person even on a day when
   they happened to eat enough iron. That relationship is written down once, in
   :data:`BIOMARKER_NUTRIENT_MAP`, with a citation for each link.

**How a biomarker-implied deficiency is expressed, and why.** The numbers inside
:class:`~app.domain.models.NutrientGap` stay honest: ``target`` is the RDA and
``current`` is what was actually eaten. A low biomarker does not secretly inflate either
one, because those two numbers are shown to the user and must mean what they say. What a
low biomarker does instead is attach a **priority floor** to the nutrient
(:class:`GapExplanation`), which :mod:`app.nutrition.candidates` uses when ranking foods.
So a person with low ferritin who ate their iron RDA still sees "iron: 19 of 19 mg" --
and still gets iron-rich foods pushed up the candidate list.

A priority floor is a food-ranking weight. It is **not** a dose and must never be shown
as one.
"""

from __future__ import annotations

from collections.abc import Iterable, Mapping, Sequence
from dataclasses import dataclass, field
from datetime import date

from app.domain.enums import ResultStatus
from app.domain.models import (
    ClassifiedResult,
    HealthProfile,
    NutrientGap,
    NutrientTarget,
)
from app.nutrition.targets import resolve_targets

__all__ = [
    "BIOMARKER_NUTRIENT_MAP",
    "DELIBERATELY_UNMAPPED",
    "BiomarkerNutrientLink",
    "GapExplanation",
    "GapReport",
    "compute_gaps",
]


# --------------------------------------------------- the biomarker -> nutrient mapping


@dataclass(frozen=True)
class BiomarkerNutrientLink:
    """One documented link from an abnormal biomarker to a dietary nutrient."""

    biomarker_code: str
    nutrient: str
    #: Result statuses that switch the link on.
    statuses: frozenset[ResultStatus]
    #: Fraction of the daily target treated as "still to close" for food ranking when
    #: the biomarker is at this status. Ranking weight only -- never a dose.
    floor_by_status: Mapping[ResultStatus, float]
    citation: str
    note: str


_LOW_SET = frozenset(
    {ResultStatus.CRITICAL_LOW, ResultStatus.LOW, ResultStatus.BORDERLINE_LOW}
)

_DEFAULT_FLOORS: Mapping[ResultStatus, float] = {
    ResultStatus.CRITICAL_LOW: 0.75,
    ResultStatus.LOW: 0.60,
    ResultStatus.BORDERLINE_LOW: 0.30,
}

#: **The mapping.** Every link the app is allowed to draw between a blood result and a
#: nutrient lives in this one dict, with its source. Nothing anywhere else in the
#: codebase may infer "low X means eat more Y".
BIOMARKER_NUTRIENT_MAP: dict[str, BiomarkerNutrientLink] = {
    "FERRITIN": BiomarkerNutrientLink(
        biomarker_code="FERRITIN",
        nutrient="iron_mg",
        statuses=_LOW_SET,
        floor_by_status=_DEFAULT_FLOORS,
        citation=(
            "WHO. WHO guideline on use of ferritin concentrations to assess iron status "
            "in individuals and populations. Geneva: World Health Organization (2020) "
            "-- ferritin is the recommended marker of iron stores."
        ),
        note="Low iron stores. Iron-rich foods, and vitamin C alongside them, help "
        "absorption; the cause still needs a doctor.",
    ),
    "HB": BiomarkerNutrientLink(
        biomarker_code="HB",
        nutrient="iron_mg",
        statuses=_LOW_SET,
        floor_by_status=_DEFAULT_FLOORS,
        citation=(
            "WHO. Haemoglobin concentrations for the diagnosis of anaemia and "
            "assessment of severity. WHO/NMH/NHD/MNM/11.1 (2011). Iron deficiency is "
            "the commonest cause of anaemia but far from the only one -- this link "
            "drives food choice only, never a diagnosis."
        ),
        note="Low haemoglobin. Iron-rich foods support the diet side; the cause of "
        "anaemia has to be established by a doctor.",
    ),
    "VITD_25OH": BiomarkerNutrientLink(
        biomarker_code="VITD_25OH",
        nutrient="vitamin_d_ug",
        statuses=_LOW_SET,
        floor_by_status=_DEFAULT_FLOORS,
        citation=(
            "Holick MF et al. Evaluation, Treatment, and Prevention of Vitamin D "
            "Deficiency: an Endocrine Society Clinical Practice Guideline. J Clin "
            "Endocrinol Metab 2011;96(7):1911-1930."
        ),
        note="Low vitamin D. Sunlight and vitamin D-containing foods both help; "
        "whether a supplement is needed, and at what dose, is a doctor's decision.",
    ),
    "VITB12": BiomarkerNutrientLink(
        biomarker_code="VITB12",
        nutrient="b12_ug",
        statuses=_LOW_SET,
        floor_by_status=_DEFAULT_FLOORS,
        citation=(
            "Devalia V, Hamilton MS, Molloy AM. Guidelines for the diagnosis and "
            "treatment of cobalamin and folate disorders. Br J Haematol "
            "2014;166(4):496-513."
        ),
        note="Low vitamin B12. B12 comes almost entirely from animal foods and "
        "fortified foods, which matters on a vegetarian or vegan diet.",
    ),
    "FOLATE": BiomarkerNutrientLink(
        biomarker_code="FOLATE",
        nutrient="folate_ug",
        statuses=_LOW_SET,
        floor_by_status=_DEFAULT_FLOORS,
        citation=(
            "Devalia V, Hamilton MS, Molloy AM. Guidelines for the diagnosis and "
            "treatment of cobalamin and folate disorders. Br J Haematol "
            "2014;166(4):496-513."
        ),
        note="Low folate. Green leafy vegetables, pulses and fortified grains are the "
        "dietary sources.",
    ),
    "ZINC": BiomarkerNutrientLink(
        biomarker_code="ZINC",
        nutrient="zinc_mg",
        statuses=_LOW_SET,
        floor_by_status=_DEFAULT_FLOORS,
        citation=(
            "International Zinc Nutrition Consultative Group (IZiNCG). Assessment of "
            "the risk of zinc deficiency in populations and options for its control. "
            "Technical Document #1, Food Nutr Bull 2004;25(1 Suppl 2):S91-S204."
        ),
        note="Low serum zinc. Whole grains, pulses, nuts and seeds are the everyday "
        "dietary sources.",
    ),
}

#: Links a reader might expect to find above and which are **deliberately absent**.
#: Written down so that nobody adds them back without reading why.
DELIBERATELY_UNMAPPED: dict[str, str] = {
    "CALCIUM": (
        "Serum calcium is held in a narrow range by parathyroid hormone and does not "
        "track dietary calcium intake. A low serum calcium is a medical finding, not a "
        "sign to eat more paneer."
    ),
    "IRON": (
        "Serum iron swings through the day and with recent meals. Ferritin is the "
        "marker we act on for iron stores."
    ),
    "HBA1C": (
        "HbA1c is not a nutrient measurement. It informs goals and food choices "
        "elsewhere in the planner, not a nutrient gap."
    ),
    "TSH": (
        "Iodine status cannot be inferred from TSH, and our foods table does not carry "
        "iodine values."
    ),
}


# ------------------------------------------------------------------------- gap report


@dataclass(frozen=True)
class GapExplanation:
    """Why a nutrient is in the gap list, in words we can show a user."""

    nutrient: str
    from_intake: bool
    biomarker_code: str | None = None
    biomarker_status: ResultStatus | None = None
    #: Fraction of the target treated as outstanding for ranking. 0.0 when the gap is
    #: purely an intake shortfall.
    priority_floor: float = 0.0
    citation: str | None = None
    note: str = ""

    @property
    def from_biomarker(self) -> bool:
        return self.biomarker_code is not None


@dataclass(frozen=True)
class GapReport:
    """Gaps plus the reason each one exists."""

    gaps: list[NutrientGap] = field(default_factory=list)
    explanations: dict[str, GapExplanation] = field(default_factory=dict)

    def by_nutrient(self, nutrient: str) -> NutrientGap | None:
        for gap in self.gaps:
            if gap.nutrient == nutrient:
                return gap
        return None

    def effective_deficit(self, nutrient: str) -> float:
        """The deficit used for **ranking foods** -- never for display.

        It is the real shortfall, or the biomarker priority floor, whichever is larger.
        """
        gap = self.by_nutrient(nutrient)
        if gap is None:
            return 0.0
        explanation = self.explanations.get(nutrient)
        floor = 0.0
        if explanation is not None:
            floor = explanation.priority_floor * gap.target
        return max(gap.deficit, floor)

    def outstanding(self) -> list[NutrientGap]:
        """Gaps worth planning around, biggest first by effective deficit."""
        live = [
            gap for gap in self.gaps if self.effective_deficit(gap.nutrient) > 0.0
        ]
        live.sort(
            key=lambda gap: self.effective_deficit(gap.nutrient) / max(gap.target, 1e-9),
            reverse=True,
        )
        return live


def _biomarker_links(
    results: Iterable[ClassifiedResult],
) -> dict[str, tuple[ClassifiedResult, BiomarkerNutrientLink]]:
    """Nutrient -> (result, link) for every abnormal biomarker we have a link for.

    Results still marked ``needs_review`` are ignored: an unconfirmed number must not
    reshape someone's diet. That is the opposite of the choice made for red flags, and
    deliberately so -- a red flag asks a person to see a doctor, which is safe when
    wrong; a nutrient gap silently changes what we feed them for a week.
    """
    found: dict[str, tuple[ClassifiedResult, BiomarkerNutrientLink]] = {}
    for result in results:
        if result.needs_review:
            continue
        link = BIOMARKER_NUTRIENT_MAP.get(result.biomarker_code)
        if link is None or result.status not in link.statuses:
            continue
        current = found.get(link.nutrient)
        floor = link.floor_by_status.get(result.status, 0.0)
        if current is not None:
            existing_floor = current[1].floor_by_status.get(current[0].status, 0.0)
            if existing_floor >= floor:
                continue
        found[link.nutrient] = (result, link)
    return found


def compute_gaps(
    profile: HealthProfile,
    intake: Mapping[str, float] | None = None,
    results: Sequence[ClassifiedResult] = (),
    *,
    targets: Sequence[NutrientTarget] | None = None,
    on: date | None = None,
) -> GapReport:
    """Build the day's nutrient gaps for one person.

    ``intake`` is a nutrient dictionary from :func:`app.nutrition.compute.day_total`.
    Pass ``None`` (not ``{}``) when the user has logged nothing: both give the same
    numbers, but ``None`` is the honest description of "we do not know yet".
    """
    eaten: Mapping[str, float] = intake or {}
    resolved = list(targets) if targets is not None else resolve_targets(profile, on=on)
    links = _biomarker_links(results)

    gaps: list[NutrientGap] = []
    explanations: dict[str, GapExplanation] = {}

    for target in resolved:
        current = float(eaten.get(target.nutrient, 0.0))
        gap = NutrientGap(
            nutrient=target.nutrient,
            target=float(target.amount),
            current=current,
            unit=target.unit,
        )
        link_pair = links.get(target.nutrient)
        shortfall = gap.deficit > 0.0
        if link_pair is None:
            if not shortfall:
                explanations[target.nutrient] = GapExplanation(
                    nutrient=target.nutrient,
                    from_intake=False,
                    note="Target met from food logged today.",
                )
            else:
                explanations[target.nutrient] = GapExplanation(
                    nutrient=target.nutrient,
                    from_intake=True,
                    note=(
                        "Short of the daily target from the food logged so far today."
                    ),
                )
        else:
            result, link = link_pair
            explanations[target.nutrient] = GapExplanation(
                nutrient=target.nutrient,
                from_intake=shortfall,
                biomarker_code=link.biomarker_code,
                biomarker_status=result.status,
                priority_floor=link.floor_by_status.get(result.status, 0.0),
                citation=link.citation,
                note=link.note,
            )
        gaps.append(gap)

    return GapReport(gaps=gaps, explanations=explanations)

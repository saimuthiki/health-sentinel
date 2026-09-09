"""Trends for one biomarker over time -- the recompute half of stage 7's trend view.

**No language model is involved anywhere in this file.**

The hard question a trend must answer is not "did the number go up?" but "did it go up
by more than the measurement itself wobbles?". Two blood draws from the same person on
the same morning do not give the same number: there is analytical variation (the
machine, ``CV_a``) and within-subject biological variation (the person, ``CV_i``).

The standard tool is the **reference change value** (RCV), also called the critical
difference:

    RCV = sqrt(2) * Z * sqrt(CV_a^2 + CV_i^2)

with ``Z = 1.96`` for 95% two-sided significance. A change smaller than the RCV is not
distinguishable from noise, and we must not tell a user their ferritin is "improving"
when it moved 4%.

Where we do not have trustworthy variation data for a biomarker we return
``meaningful=None`` -- "we cannot say" -- rather than inventing a number. Those gaps are
listed in ``app/rules/GAPS.md``.
"""

from __future__ import annotations

import math
from collections.abc import Sequence
from dataclasses import dataclass
from datetime import date
from decimal import Decimal
from enum import StrEnum

__all__ = [
    "BIOLOGICAL_VARIATION",
    "SOURCE_BIOLOGICAL_VARIATION",
    "TrendDirection",
    "TrendPoint",
    "TrendResult",
    "compute_trend",
    "reference_change_value",
]

SOURCE_BIOLOGICAL_VARIATION = (
    "Ricos C, Alvarez V, Cava F et al. Current databases on biological variation: "
    "pros, cons and progress. Scand J Clin Lab Invest 1999;59(7):491-500, as maintained "
    "in the Westgard biological variation database. CV_a values are desirable analytical "
    "goals, not the actual performance of the user's laboratory -- see GAPS.md item G5."
)


class TrendDirection(StrEnum):
    """Which way a biomarker moved. Local to the rules engine on purpose -- it is a
    presentation of arithmetic, not a stored domain value."""

    RISING = "rising"
    FALLING = "falling"
    FLAT = "flat"
    INSUFFICIENT_DATA = "insufficient_data"


@dataclass(frozen=True)
class Variation:
    cv_analytical: float
    cv_within_subject: float


#: Within-subject and analytical coefficients of variation, in percent.
#: Only biomarkers we could source are listed. Everything else returns "cannot say".
BIOLOGICAL_VARIATION: dict[str, Variation] = {
    "HB": Variation(cv_analytical=1.5, cv_within_subject=2.8),
    "HBA1C": Variation(cv_analytical=2.0, cv_within_subject=1.9),
    "CREATININE": Variation(cv_analytical=2.2, cv_within_subject=6.0),
    "GLUCOSE_FASTING": Variation(cv_analytical=2.2, cv_within_subject=5.7),
    "TSH": Variation(cv_analytical=5.0, cv_within_subject=19.3),
    "FERRITIN": Variation(cv_analytical=3.0, cv_within_subject=14.2),
    "CHOL_TOTAL": Variation(cv_analytical=2.6, cv_within_subject=6.0),
    "TRIG": Variation(cv_analytical=5.0, cv_within_subject=19.9),
    "VITD_25OH": Variation(cv_analytical=5.0, cv_within_subject=12.1),
    "POTASSIUM": Variation(cv_analytical=2.0, cv_within_subject=4.6),
    "SODIUM": Variation(cv_analytical=0.9, cv_within_subject=0.6),
}

#: Two-sided 95% z-score, the conventional RCV significance level.
RCV_Z = 1.96


def reference_change_value(biomarker_code: str) -> float | None:
    """Smallest percentage change that is not just assay + biological noise."""
    variation = BIOLOGICAL_VARIATION.get(biomarker_code)
    if variation is None:
        return None
    return (
        math.sqrt(2.0)
        * RCV_Z
        * math.sqrt(variation.cv_analytical**2 + variation.cv_within_subject**2)
    )


@dataclass(frozen=True)
class TrendPoint:
    """One measurement in a series. Values must already be in the canonical unit."""

    measured_on: date
    value: Decimal


@dataclass(frozen=True)
class TrendResult:
    biomarker_code: str
    direction: TrendDirection
    first: TrendPoint | None
    last: TrendPoint | None
    pct_change: float | None
    absolute_change: Decimal | None
    #: True / False / None where None means "we have no variation data for this test".
    meaningful: bool | None
    #: The RCV threshold used, in percent, when one was available.
    noise_threshold_pct: float | None
    points: int
    note: str

    @property
    def is_improving_towards(self) -> TrendDirection:  # pragma: no cover - alias
        return self.direction


def compute_trend(
    biomarker_code: str,
    series: Sequence[TrendPoint],
) -> TrendResult:
    """Direction, percent change and noise significance for one biomarker.

    The comparison is first-to-last over the supplied window; the caller decides what
    window is interesting (this function does no date filtering, so it stays testable).
    """
    ordered = sorted(series, key=lambda point: point.measured_on)
    threshold = reference_change_value(biomarker_code)

    if len(ordered) < 2:
        return TrendResult(
            biomarker_code=biomarker_code,
            direction=TrendDirection.INSUFFICIENT_DATA,
            first=ordered[0] if ordered else None,
            last=ordered[-1] if ordered else None,
            pct_change=None,
            absolute_change=None,
            meaningful=None,
            noise_threshold_pct=threshold,
            points=len(ordered),
            note="At least two results are needed before we can show a trend.",
        )

    first, last = ordered[0], ordered[-1]
    absolute = last.value - first.value

    if first.value == 0:
        return TrendResult(
            biomarker_code=biomarker_code,
            direction=TrendDirection.INSUFFICIENT_DATA,
            first=first,
            last=last,
            pct_change=None,
            absolute_change=absolute,
            meaningful=None,
            noise_threshold_pct=threshold,
            points=len(ordered),
            note="The earlier value was zero, so a percentage change is undefined.",
        )

    pct = float(absolute / first.value) * 100.0

    if threshold is None:
        meaningful: bool | None = None
        note = (
            "We do not hold measurement-variation data for this test, so we will not "
            "say whether this change is real or just normal test-to-test variation."
        )
    else:
        meaningful = abs(pct) >= threshold
        note = (
            f"A change of {threshold:.1f}% or more is needed before it can be told "
            "apart from normal test-to-test variation."
        )

    if meaningful is False:
        direction = TrendDirection.FLAT
    elif absolute > 0:
        direction = TrendDirection.RISING
    elif absolute < 0:
        direction = TrendDirection.FALLING
    else:
        direction = TrendDirection.FLAT

    return TrendResult(
        biomarker_code=biomarker_code,
        direction=direction,
        first=first,
        last=last,
        pct_change=pct,
        absolute_change=absolute,
        meaningful=meaningful,
        noise_threshold_pct=threshold,
        points=len(ordered),
        note=note,
    )

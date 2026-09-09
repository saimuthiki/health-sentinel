"""Stage 4 -- classification. Value + our reference range -> :class:`ResultStatus`.

**No language model is involved anywhere in this file.**

Two jobs:

* :func:`select_range` -- pick the *most specific* curated reference range that applies
  to this person (biomarker, sex, age band, pregnancy).
* :func:`classify` -- compare the value with that range.

The lab's own printed range is deliberately ignored. Labs differ, print errors happen,
and a printed range is not auditable. Our ranges live in the ``reference_ranges``
reference table and every one of them carries a ``source_citation``.

The rule that matters most: **if no range applies, the status is
``ResultStatus.UNKNOWN`` -- never ``NORMAL``.** Absence of evidence is not evidence of
normality, and "we did not check" must never look like "you are fine".
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date
from decimal import Decimal

from app.domain.enums import ResultStatus, Sex
from app.domain.models import ClassifiedResult, HealthProfile, ReferenceRange
from app.rules.normalise import canonical_unit, higher_is_worse

__all__ = [
    "RangeSelection",
    "applies_to",
    "classify",
    "classify_result",
    "pregnancy_flag",
    "select_range",
    "specificity",
]


# ------------------------------------------------------------------------ range picking


def applies_to(
    reference: ReferenceRange,
    *,
    biomarker_code: str,
    sex: Sex | None,
    age: int | None,
    pregnant: bool | None,
) -> bool:
    """Is ``reference`` allowed to be used for this person?

    A constraint left as ``None`` on the range means "any". A constraint that is set and
    does not match disqualifies the range outright. An *unknown* attribute on the person
    (no date of birth, sex not stated) can only match a range that does not constrain
    that attribute -- we do not assume.
    """
    if reference.biomarker_code != biomarker_code:
        return False

    if reference.sex is not None and (sex is None or sex != reference.sex):
        return False

    if reference.age_min is not None or reference.age_max is not None:
        if age is None:
            return False
        if reference.age_min is not None and age < reference.age_min:
            return False
        if reference.age_max is not None and age > reference.age_max:
            return False

    # The suppression below is deliberate. SIM103 would have this return the negated
    # condition, but
    # this is the last of a chain of guard clauses that all read "if disqualified,
    # return False". Breaking the pattern on the final one makes the chain harder to
    # scan, and this function decides which reference range applies to a person.
    if reference.pregnancy is not None and (  # noqa: SIM103
        pregnant is None or bool(pregnant) != bool(reference.pregnancy)
    ):
        return False

    return True


def specificity(reference: ReferenceRange) -> tuple[int, int]:
    """How specific a range is. Higher sorts first.

    Pregnancy is the strongest discriminator (a pregnancy range exists precisely
    because the general one is wrong), then sex, then an age band. Ties are broken by
    the *narrower* age band.
    """
    score = 0
    if reference.pregnancy is not None:
        score += 8
    if reference.sex is not None:
        score += 4
    if reference.age_min is not None or reference.age_max is not None:
        score += 2
    low = reference.age_min if reference.age_min is not None else 0
    high = reference.age_max if reference.age_max is not None else 200
    width = max(0, high - low)
    return (score, -width)


@dataclass(frozen=True)
class RangeSelection:
    """The chosen range plus everything that was in the running, for auditing."""

    reference: ReferenceRange | None
    considered: tuple[ReferenceRange, ...] = ()

    @property
    def found(self) -> bool:
        return self.reference is not None


def select_range(
    ranges: object,
    *,
    biomarker_code: str,
    sex: Sex | None = None,
    age: int | None = None,
    pregnant: bool | None = None,
) -> RangeSelection:
    """Pick the most specific applicable reference range, or none at all."""
    applicable = [
        reference
        for reference in ranges  # type: ignore[union-attr]
        if applies_to(
            reference,
            biomarker_code=biomarker_code,
            sex=sex,
            age=age,
            pregnant=pregnant,
        )
    ]
    if not applicable:
        return RangeSelection(None, ())
    applicable.sort(key=specificity, reverse=True)
    return RangeSelection(applicable[0], tuple(applicable))


def pregnancy_flag(profile: HealthProfile) -> bool:
    """The pregnancy value to match ranges on.

    Naming note, kept deliberately: the database column is
    ``health_profiles.pregnancy`` and the domain field is
    :attr:`HealthProfile.is_pregnant`. Neither is renamed -- the mapping happens here
    and in the repository layer, and nowhere else.
    """
    return bool(profile.is_pregnant)


def select_range_for_profile(
    ranges: object,
    *,
    biomarker_code: str,
    profile: HealthProfile,
    on: date | None = None,
) -> RangeSelection:
    """:func:`select_range`, with sex/age/pregnancy read off a profile."""
    sex = None if profile.sex is Sex.OTHER else profile.sex
    age = profile.age_on(on or date.today())
    return select_range(
        ranges,
        biomarker_code=biomarker_code,
        sex=sex,
        age=age,
        pregnant=pregnancy_flag(profile),
    )


# ------------------------------------------------------------------------ classifying


def _low_bounds(reference: ReferenceRange) -> tuple[Decimal | None, ...]:
    return (reference.critical_low, reference.low, reference.borderline_low)


def _high_bounds(reference: ReferenceRange) -> tuple[Decimal | None, ...]:
    return (reference.critical_high, reference.high, reference.borderline_high)


def _has_any_bound(reference: ReferenceRange) -> bool:
    return any(
        bound is not None for bound in _low_bounds(reference) + _high_bounds(reference)
    )


def _can_call_it_normal(
    reference: ReferenceRange, concerning_direction: bool | None
) -> bool:
    """Is this range entitled to conclude ``NORMAL`` for a value inside it?

    Two conditions, and both come straight out of ``db/seed/202_reference_ranges.sql``
    and its ``GAPS.md``:

    1. **Only the directions that matter need bounding.** ``higher_is_worse=False``
       (haemoglobin, ferritin) means the guideline defines a deficiency and nothing
       else; WHO 2011 gives no upper limit for haemoglobin, and a 14.2 g/dL is still
       plainly normal. ``higher_is_worse=True`` (LDL, triglycerides) is the mirror.
       ``None`` (potassium, sodium) means both ends must be bounded.

    2. **A critical bound alone is not enough.** Passing ``critical_low`` tells us the
       value is not critical; it does not tell us it is normal. Platelets are seeded
       with ``critical_low = 50`` and nothing else precisely because the ordinary
       150-450 interval is laboratory-specific -- so a platelet count of 250 is
       ``UNKNOWN``, not ``NORMAL``. This is the rule that keeps "we could not assess
       this" from being rendered as reassurance.
    """
    needs_low = concerning_direction is not True
    needs_high = concerning_direction is not False
    if needs_low and reference.low is None and reference.borderline_low is None:
        return False
    return not (needs_high and reference.high is None and reference.borderline_high is None)


def classify(
    value: Decimal,
    reference: ReferenceRange | None,
    *,
    concerning_direction: bool | None = None,
) -> ResultStatus:
    """Where does ``value`` sit in ``reference``?

    The order of the six comparisons is fixed by the seed file's header comment
    (``db/seed/202_reference_ranges.sql``) and must not be reshuffled -- first match
    wins, and **a null threshold means that step is skipped, never that it passed**::

        value <  critical_low     -> critical_low
        value <  low              -> low
        value <  borderline_low   -> borderline_low
        value >  critical_high    -> critical_high
        value >  high             -> high
        value >  borderline_high  -> borderline_high
        otherwise                 -> normal, if the range was able to place it

    Boundary convention, applied consistently everywhere in this codebase: **a bound
    is part of the healthier side**. ``low = 12`` means 12.0 is not low; 11.9 is.

    ``concerning_direction`` mirrors ``biomarkers.higher_is_worse``; see
    :func:`_can_call_it_normal`. Left unset it defaults to "both directions matter",
    which is the cautious reading.

    Only 21 of the 82 seeded biomarkers carry any range at all, so ``UNKNOWN`` is the
    common answer here, not the exception. It means "we could not assess this value"
    and must never be shown as reassurance or counted as "everything looks fine".
    """
    if reference is None or not _has_any_bound(reference):
        return ResultStatus.UNKNOWN

    if reference.critical_low is not None and value < reference.critical_low:
        return ResultStatus.CRITICAL_LOW
    if reference.low is not None and value < reference.low:
        return ResultStatus.LOW
    if reference.borderline_low is not None and value < reference.borderline_low:
        return ResultStatus.BORDERLINE_LOW
    if reference.critical_high is not None and value > reference.critical_high:
        return ResultStatus.CRITICAL_HIGH
    if reference.high is not None and value > reference.high:
        return ResultStatus.HIGH
    if reference.borderline_high is not None and value > reference.borderline_high:
        return ResultStatus.BORDERLINE_HIGH

    if not _can_call_it_normal(reference, concerning_direction):
        return ResultStatus.UNKNOWN
    return ResultStatus.NORMAL


def classify_result(
    candidate: ClassifiedResult, reference: ReferenceRange | None
) -> ClassifiedResult:
    """Return ``candidate`` with its ``status`` (and ``reference``) filled in.

    Safety guards, both of which end in ``UNKNOWN`` rather than a guess:

    * the range must be for the same biomarker;
    * the candidate must already be in our canonical unit, because a
      :class:`ReferenceRange` carries numbers with no unit of their own. Comparing
      ``14.2 ng/mL`` against a range written in ``nmol/L`` is exactly the kind of
      silent unit error that makes a health app dangerous.
    """
    expected_unit = canonical_unit(candidate.biomarker_code)
    reasons = [candidate.review_reason] if candidate.review_reason else []
    rejected = False

    if reference is not None and reference.biomarker_code != candidate.biomarker_code:
        reasons.append(
            "The reference range offered was for "
            f"{reference.biomarker_code}, not {candidate.biomarker_code}."
        )
        reference = None
        rejected = True
    elif expected_unit is not None and candidate.unit != expected_unit:
        reasons.append(
            f"This value is in '{candidate.unit}' but our reference ranges for "
            f"{candidate.display_name} are in '{expected_unit}', so we did not compare "
            "them."
        )
        reference = None
        rejected = True

    status = classify(
        candidate.value,
        reference,
        concerning_direction=higher_is_worse(candidate.biomarker_code),
    )
    return candidate.model_copy(
        update={
            "status": status,
            "reference": reference,
            "needs_review": candidate.needs_review or rejected,
            "review_reason": " ".join(reasons) if reasons else None,
        }
    )

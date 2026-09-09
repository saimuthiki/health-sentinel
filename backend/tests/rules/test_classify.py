"""Stage 4: range selection and classification.

The property that matters most here is negative: when we have no applicable range, the
answer is ``UNKNOWN``. "We did not check" must never render as "you are fine".
"""

from __future__ import annotations

from datetime import date
from decimal import Decimal

import pytest

from app.domain.enums import ResultStatus, Sex
from app.rules import classify as C
from tests.rules.conftest import reference, result

GENERAL = reference("HB", low="12", high="16", citation="general adult")
MALE = reference("HB", sex=Sex.MALE, low="13", high="17", citation="adult male")
MALE_ADULT = reference(
    "HB", sex=Sex.MALE, age_min=18, age_max=65, low="13.5", high="17.5",
    citation="male 18-65",
)
PREGNANT = reference(
    "HB", sex=Sex.FEMALE, pregnancy=True, low="11", high="15",
    citation="pregnancy",
)
FEMALE = reference("HB", sex=Sex.FEMALE, low="12", high="15", citation="adult female")
ALL_RANGES = [GENERAL, MALE, MALE_ADULT, PREGNANT, FEMALE]


# ------------------------------------------------------------------ range selection


def test_picks_the_most_specific_match() -> None:
    chosen = C.select_range(ALL_RANGES, biomarker_code="HB", sex=Sex.MALE, age=32).reference
    assert chosen is MALE_ADULT


def test_pregnancy_range_beats_the_plain_sex_range() -> None:
    chosen = C.select_range(
        ALL_RANGES, biomarker_code="HB", sex=Sex.FEMALE, age=30, pregnant=True
    ).reference
    assert chosen is PREGNANT


def test_pregnancy_range_is_not_used_for_someone_not_pregnant() -> None:
    chosen = C.select_range(
        ALL_RANGES, biomarker_code="HB", sex=Sex.FEMALE, age=30, pregnant=False
    ).reference
    assert chosen is FEMALE


def test_sex_range_beats_the_general_range() -> None:
    chosen = C.select_range(ALL_RANGES, biomarker_code="HB", sex=Sex.MALE, age=70).reference
    assert chosen is MALE  # 70 is outside the 18-65 band


def test_falls_back_to_the_general_range_when_sex_is_unknown() -> None:
    chosen = C.select_range(ALL_RANGES, biomarker_code="HB", sex=None, age=32).reference
    assert chosen is GENERAL


def test_narrower_age_band_wins_a_tie() -> None:
    wide = reference("TSH", age_min=18, age_max=99, low="0.4", high="4.0")
    narrow = reference("TSH", age_min=18, age_max=40, low="0.5", high="3.5")
    chosen = C.select_range([wide, narrow], biomarker_code="TSH", age=30).reference
    assert chosen is narrow


def test_unknown_age_cannot_match_an_age_restricted_range() -> None:
    only_banded = [reference("HB", age_min=18, age_max=65, low="13", high="17")]
    assert C.select_range(only_banded, biomarker_code="HB", age=None).found is False


def test_no_range_for_this_biomarker_finds_nothing() -> None:
    assert C.select_range(ALL_RANGES, biomarker_code="TSH", age=30).found is False


def test_selection_keeps_everything_it_considered_for_the_audit_trail() -> None:
    selection = C.select_range(ALL_RANGES, biomarker_code="HB", sex=Sex.MALE, age=32)
    assert set(selection.considered) == {GENERAL, MALE, MALE_ADULT}


def test_select_range_for_profile_reads_age_and_sex_off_the_profile() -> None:
    from app.domain.models import HealthProfile

    profile = HealthProfile(user_id="u1", dob=date(1994, 1, 1), sex=Sex.MALE)
    selection = C.select_range_for_profile(
        ALL_RANGES, biomarker_code="HB", profile=profile, on=date(2026, 1, 1)
    )
    assert selection.reference is MALE_ADULT


# -------------------------------------------------------------------- classification


# A fully bounded fixture. HB carries higher_is_worse = false in the catalogue, so
# the low side alone would be enough -- both sides are given here so the boundary
# table below can exercise every status.
BANDED = reference(
    "HB",
    critical_low="7",
    low="12",
    borderline_low="13",
    borderline_high="16",
    high="17",
    critical_high="20",
)


@pytest.mark.parametrize(
    ("value", "expected"),
    [
        ("6.9", ResultStatus.CRITICAL_LOW),
        ("7", ResultStatus.LOW),            # the bound belongs to the safer side
        ("11.9", ResultStatus.LOW),
        ("12", ResultStatus.BORDERLINE_LOW),
        ("12.9", ResultStatus.BORDERLINE_LOW),
        ("13", ResultStatus.NORMAL),
        ("16", ResultStatus.NORMAL),
        ("16.1", ResultStatus.BORDERLINE_HIGH),
        ("17", ResultStatus.BORDERLINE_HIGH),
        ("17.1", ResultStatus.HIGH),
        ("20", ResultStatus.HIGH),
        ("20.1", ResultStatus.CRITICAL_HIGH),
    ],
)
def test_boundaries_are_exactly_where_the_docstring_says(value: str, expected) -> None:
    assert C.classify(Decimal(value), BANDED) is expected


def test_no_range_means_unknown_not_normal() -> None:
    assert C.classify(Decimal("14"), None) is ResultStatus.UNKNOWN


def test_an_empty_range_means_unknown_not_normal() -> None:
    empty = reference("HB")
    assert C.classify(Decimal("14"), empty) is ResultStatus.UNKNOWN


# ----------------------------------------------- "we could not assess this value"
# Only 21 of the 82 seeded biomarkers carry any range at all
# (db/seed/GAPS.md section 2), so UNKNOWN is the ordinary answer, not an edge case.


def test_a_range_with_only_a_high_bound_can_still_call_a_high_value_high() -> None:
    only_high = reference("TRIG", high="199")
    assert C.classify(Decimal("450"), only_high) is ResultStatus.HIGH


def test_a_high_only_range_cannot_call_a_low_value_normal_by_default() -> None:
    # Default is "both directions matter", the cautious reading.
    only_high = reference("TRIG", high="199")
    assert C.classify(Decimal("90"), only_high) is ResultStatus.UNKNOWN


def test_a_high_only_range_is_enough_when_only_high_is_the_concern() -> None:
    # TRIG carries higher_is_worse = true in db/seed/200_biomarkers.sql.
    only_high = reference("TRIG", high="199")
    assert (
        C.classify(Decimal("90"), only_high, concerning_direction=True)
        is ResultStatus.NORMAL
    )


def test_only_a_critical_low_cannot_make_a_mid_range_value_normal() -> None:
    # Platelets are seeded with critical_low = 50 and nothing else, because the
    # familiar 150-450 interval is laboratory-specific (db/seed/GAPS.md section 3).
    # A count of 250 is therefore "we could not assess this", not "normal".
    only_critical = reference("PLT", critical_low="50")
    assert C.classify(Decimal("250"), only_critical) is ResultStatus.UNKNOWN
    assert (
        C.classify(Decimal("250"), only_critical, concerning_direction=False)
        is ResultStatus.UNKNOWN
    )
    # It can still do the one job it was seeded for.
    assert C.classify(Decimal("45"), only_critical) is ResultStatus.CRITICAL_LOW


def test_critical_values_only_still_cannot_declare_a_value_normal() -> None:
    # Potassium is seeded with critical_low 2.5 / critical_high 6.0 and no normal
    # interval at all. 4.2 is "not critical", which is not the same as "normal".
    criticals = reference("POTASSIUM", critical_low="2.5", critical_high="6.0")
    assert C.classify(Decimal("4.2"), criticals) is ResultStatus.UNKNOWN
    assert C.classify(Decimal("2.1"), criticals) is ResultStatus.CRITICAL_LOW
    assert C.classify(Decimal("6.4"), criticals) is ResultStatus.CRITICAL_HIGH


def test_a_deficiency_only_range_can_call_a_healthy_value_normal() -> None:
    # WHO 2011 defines anaemia and gives no upper limit for haemoglobin, and HB
    # carries higher_is_worse = false. A 14.2 g/dL must not read as "unassessed".
    who_hb = reference("HB", critical_low="8.0", low="11.0", borderline_low="13.0")
    assert (
        C.classify(Decimal("14.2"), who_hb, concerning_direction=False)
        is ResultStatus.NORMAL
    )
    assert (
        C.classify(Decimal("12.0"), who_hb, concerning_direction=False)
        is ResultStatus.BORDERLINE_LOW
    )


def test_null_thresholds_are_skipped_not_treated_as_passed() -> None:
    # borderline_low is null here; a value below `low` must still classify LOW and
    # must not fall through to NORMAL.
    holey = reference("HDL", low="40", high="100")
    assert C.classify(Decimal("35"), holey) is ResultStatus.LOW


def test_the_seed_file_comparison_order_is_followed_exactly() -> None:
    # Overlapping bounds must not let a later comparison downgrade an earlier one.
    overlapping = reference(
        "GLUCOSE_FASTING", critical_low="54", low="70", borderline_high="99",
        high="125", critical_high="300",
    )
    assert C.classify(Decimal("50"), overlapping) is ResultStatus.CRITICAL_LOW
    assert C.classify(Decimal("60"), overlapping) is ResultStatus.LOW
    assert C.classify(Decimal("92"), overlapping) is ResultStatus.NORMAL
    assert C.classify(Decimal("110"), overlapping) is ResultStatus.BORDERLINE_HIGH
    assert C.classify(Decimal("180"), overlapping) is ResultStatus.HIGH
    assert C.classify(Decimal("320"), overlapping) is ResultStatus.CRITICAL_HIGH


# --------------------------------------------------------------- classify_result


def test_classify_result_fills_in_status_and_keeps_the_range() -> None:
    candidate = result("HB", "11.0", "g/dL")
    classified = C.classify_result(candidate, BANDED)
    assert classified.status is ResultStatus.LOW
    assert classified.reference is BANDED
    assert classified.is_actionable is True


def test_classify_result_refuses_to_compare_a_value_in_the_wrong_unit() -> None:
    # 140 g/L is a perfectly normal haemoglobin -- but the range is written in g/dL,
    # and comparing them would call a healthy person critically high.
    candidate = result("HB", "140", "g/L")
    classified = C.classify_result(candidate, BANDED)
    assert classified.status is ResultStatus.UNKNOWN
    assert classified.needs_review is True
    assert "g/L" in (classified.review_reason or "")


def test_classify_result_refuses_a_range_for_a_different_biomarker() -> None:
    candidate = result("TSH", "2.0", "mIU/L")
    classified = C.classify_result(candidate, BANDED)
    assert classified.status is ResultStatus.UNKNOWN
    assert classified.needs_review is True


def test_needs_review_is_carried_through_classification() -> None:
    candidate = result("HB", "11.0", "g/dL", needs_review=True)
    classified = C.classify_result(candidate, BANDED)
    assert classified.status is ResultStatus.LOW
    assert classified.needs_review is True
    assert classified.is_actionable is False


def test_pregnancy_flag_maps_the_domain_field_onto_the_db_column() -> None:
    from app.domain.models import HealthProfile

    # health_profiles.pregnancy (db) <-> HealthProfile.is_pregnant (domain).
    assert C.pregnancy_flag(HealthProfile(user_id="u", is_pregnant=True)) is True
    assert C.pregnancy_flag(HealthProfile(user_id="u")) is False


def test_classify_result_uses_the_biomarkers_concerning_direction() -> None:
    # PLT is higher_is_worse = false and this range only carries a critical_low, so
    # a healthy count is honestly reported as "we could not assess this".
    from tests.rules.conftest import result as make

    only_critical = reference("PLT", critical_low="50")
    assert C.classify_result(make("PLT", "250", "10^3/uL"), only_critical).status is (
        ResultStatus.UNKNOWN
    )
    assert C.classify_result(make("PLT", "45", "10^3/uL"), only_critical).status is (
        ResultStatus.CRITICAL_LOW
    )

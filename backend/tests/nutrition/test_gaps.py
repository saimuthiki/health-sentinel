"""Nutrient gaps from intake and from biomarkers."""

from __future__ import annotations

import pytest

from app.domain.enums import ResultStatus, Sex
from app.domain.models import NutrientTarget
from app.nutrition import gaps as G
from tests.nutrition.conftest import TODAY, lab, profile

IRON_TARGET = NutrientTarget(nutrient="iron_mg", amount=19.0, unit="mg", source="test")
B12_TARGET = NutrientTarget(nutrient="b12_ug", amount=2.2, unit="ug", source="test")
VITD_TARGET = NutrientTarget(
    nutrient="vitamin_d_ug", amount=15.0, unit="ug", source="test"
)


# ------------------------------------------------------------------- the mapping itself


def test_every_biomarker_nutrient_link_is_documented_and_cited() -> None:
    for code, link in G.BIOMARKER_NUTRIENT_MAP.items():
        assert link.biomarker_code == code
        assert link.citation.strip() and len(link.citation) > 40, code
        assert link.note.strip(), code
        assert link.statuses, code
        assert all(status.is_abnormal for status in link.statuses), code


def test_the_documented_links_are_the_ones_the_brief_asked_for() -> None:
    assert G.BIOMARKER_NUTRIENT_MAP["FERRITIN"].nutrient == "iron_mg"
    assert G.BIOMARKER_NUTRIENT_MAP["VITD_25OH"].nutrient == "vitamin_d_ug"
    assert G.BIOMARKER_NUTRIENT_MAP["VITB12"].nutrient == "b12_ug"


def test_links_we_deliberately_do_not_draw_are_written_down_with_a_reason() -> None:
    assert "CALCIUM" in G.DELIBERATELY_UNMAPPED
    assert "CALCIUM" not in G.BIOMARKER_NUTRIENT_MAP
    for code, reason in G.DELIBERATELY_UNMAPPED.items():
        assert code not in G.BIOMARKER_NUTRIENT_MAP
        assert len(reason) > 40


def test_no_link_ever_carries_a_dose() -> None:
    for link in G.BIOMARKER_NUTRIENT_MAP.values():
        assert "mg daily" not in link.note.lower()
        assert "iu" not in link.note.lower().split()
        assert "take " not in link.note.lower()


# ---------------------------------------------------------------------- gap arithmetic


def test_gap_is_target_minus_intake() -> None:
    report = G.compute_gaps(
        profile(), {"iron_mg": 13.0}, targets=[IRON_TARGET], on=TODAY
    )
    gap = report.by_nutrient("iron_mg")
    assert gap is not None
    assert gap.target == 19.0
    assert gap.current == 13.0
    assert gap.deficit == pytest.approx(6.0)
    assert gap.pct_of_target == pytest.approx(68.4, abs=0.1)


def test_eating_more_than_the_target_leaves_no_deficit() -> None:
    report = G.compute_gaps(
        profile(), {"iron_mg": 25.0}, targets=[IRON_TARGET], on=TODAY
    )
    assert report.by_nutrient("iron_mg").deficit == 0.0
    assert report.by_nutrient("iron_mg").pct_of_target == 100.0


def test_logging_nothing_leaves_the_whole_target_outstanding() -> None:
    report = G.compute_gaps(profile(), None, targets=[IRON_TARGET], on=TODAY)
    assert report.by_nutrient("iron_mg").deficit == 19.0


def test_targets_are_resolved_from_the_profile_when_none_are_passed() -> None:
    report = G.compute_gaps(profile(sex=Sex.FEMALE), {"iron_mg": 10.0}, on=TODAY)
    assert report.by_nutrient("iron_mg").target == 29.0


# ------------------------------------------------------------ biomarker-driven gaps


def test_low_ferritin_marks_iron_as_biomarker_driven() -> None:
    report = G.compute_gaps(
        profile(),
        {"iron_mg": 13.0},
        [lab("FERRITIN", "8", "ng/mL", ResultStatus.LOW)],
        targets=[IRON_TARGET],
        on=TODAY,
    )
    explanation = report.explanations["iron_mg"]
    assert explanation.from_biomarker is True
    assert explanation.biomarker_code == "FERRITIN"
    assert explanation.priority_floor == 0.60
    assert "WHO" in (explanation.citation or "")


def test_low_vitamin_d_and_low_b12_each_raise_their_own_nutrient() -> None:
    report = G.compute_gaps(
        profile(),
        {},
        [
            lab("VITD_25OH", "14.2", "ng/mL", ResultStatus.LOW),
            lab("VITB12", "180", "pg/mL", ResultStatus.BORDERLINE_LOW),
        ],
        targets=[VITD_TARGET, B12_TARGET],
        on=TODAY,
    )
    assert report.explanations["vitamin_d_ug"].biomarker_code == "VITD_25OH"
    assert report.explanations["b12_ug"].biomarker_code == "VITB12"
    assert report.explanations["b12_ug"].priority_floor == 0.30


def test_the_displayed_numbers_stay_honest_when_a_biomarker_is_low() -> None:
    # Ate the whole iron RDA, but ferritin is low. The gap the user *sees* is zero,
    # because that is the truth about what they ate.
    report = G.compute_gaps(
        profile(),
        {"iron_mg": 19.0},
        [lab("FERRITIN", "6", "ng/mL", ResultStatus.CRITICAL_LOW)],
        targets=[IRON_TARGET],
        on=TODAY,
    )
    assert report.by_nutrient("iron_mg").deficit == 0.0
    assert report.by_nutrient("iron_mg").current == 19.0
    # ...but the planner still pushes iron-rich foods.
    assert report.effective_deficit("iron_mg") == pytest.approx(0.75 * 19.0)


def test_the_worse_biomarker_wins_when_two_point_at_one_nutrient() -> None:
    report = G.compute_gaps(
        profile(),
        {},
        [
            lab("HB", "11.0", "g/dL", ResultStatus.BORDERLINE_LOW),
            lab("FERRITIN", "5", "ng/mL", ResultStatus.CRITICAL_LOW),
        ],
        targets=[IRON_TARGET],
        on=TODAY,
    )
    assert report.explanations["iron_mg"].biomarker_code == "FERRITIN"
    assert report.explanations["iron_mg"].priority_floor == 0.75


def test_a_normal_biomarker_drives_nothing() -> None:
    report = G.compute_gaps(
        profile(),
        {"iron_mg": 19.0},
        [lab("FERRITIN", "120", "ng/mL", ResultStatus.NORMAL)],
        targets=[IRON_TARGET],
        on=TODAY,
    )
    assert report.explanations["iron_mg"].from_biomarker is False
    assert report.effective_deficit("iron_mg") == 0.0


def test_an_unconfirmed_result_does_not_reshape_the_diet() -> None:
    report = G.compute_gaps(
        profile(),
        {"iron_mg": 19.0},
        [lab("FERRITIN", "6", "ng/mL", ResultStatus.LOW, needs_review=True)],
        targets=[IRON_TARGET],
        on=TODAY,
    )
    assert report.explanations["iron_mg"].from_biomarker is False


def test_a_biomarker_with_no_documented_link_is_ignored() -> None:
    report = G.compute_gaps(
        profile(),
        {"iron_mg": 19.0},
        [lab("CALCIUM", "7.9", "mg/dL", ResultStatus.LOW)],
        targets=[IRON_TARGET],
        on=TODAY,
    )
    assert all(not e.from_biomarker for e in report.explanations.values())


# -------------------------------------------------------------------- ordering


def test_outstanding_gaps_come_back_worst_first() -> None:
    report = G.compute_gaps(
        profile(),
        {"iron_mg": 18.0, "vitamin_d_ug": 1.0},
        targets=[IRON_TARGET, VITD_TARGET],
        on=TODAY,
    )
    outstanding = [gap.nutrient for gap in report.outstanding()]
    assert outstanding[0] == "vitamin_d_ug"  # 93% short beats 5% short


def test_a_met_target_is_not_outstanding() -> None:
    report = G.compute_gaps(
        profile(), {"iron_mg": 19.0}, targets=[IRON_TARGET], on=TODAY
    )
    assert report.outstanding() == []

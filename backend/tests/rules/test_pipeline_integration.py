"""Stages 3, 4 and 5 end to end, on one realistic report.

This is the test that would catch a seam coming apart: a canonical unit renamed in
``normalise`` but not in ``red_flags``, a status the classifier produces that the
nutrition mapping does not recognise, a needs-review row leaking into a plan.
"""

from __future__ import annotations

from datetime import date
from decimal import Decimal

from app.domain.enums import Escalation, ResultStatus, Sex
from app.domain.models import ExtractedReport, HealthProfile
from app.nutrition import gaps as G
from app.rules import classify as C
from app.rules import normalise as N
from app.rules import red_flags as RF
from tests.rules.conftest import reference, row

RANGES = [
    reference("HB", sex=Sex.MALE, age_min=18, age_max=65, low="13", high="17",
              critical_low="7", citation="test"),
    reference("VITD_25OH", low="20", high="100", borderline_low="30", citation="test"),
    reference("FERRITIN", sex=Sex.MALE, low="30", high="400", citation="test"),
    reference("HBA1C", high="5.6", borderline_high="5.6", critical_high="9",
              citation="test"),
    reference("POTASSIUM", low="3.5", high="5.1", critical_low="2.5",
              critical_high="6.0", citation="test"),
]

REPORT = ExtractedReport(
    lab_name="Test Diagnostics",
    collected_on=date(2026, 8, 14),
    report_type="blood",
    rows=[
        row("Haemoglobin (Hb)", "6.4", "g/dL"),
        row("Vitamin D (25-OH)", "35.44", "nmol/L"),
        row("S. Ferritin", "8", "ng/mL"),
        row("HbA1c", "6.8", "%"),
        row("Potassium", "4.4", "mEq/L"),
        row("Widget Index", "12", "units"),
        row("TSH", "<0.005", "uIU/mL"),
    ],
)

PROFILE = HealthProfile(user_id="u1", dob=date(1994, 3, 1), sex=Sex.MALE)


def _classified():
    results = []
    review = []
    for raw in REPORT.rows:
        normalised = N.normalise_row(raw)
        candidate = N.to_candidate(normalised, measured_on=REPORT.collected_on)
        if candidate is None:
            review.append(normalised)
            continue
        selection = C.select_range_for_profile(
            RANGES,
            biomarker_code=candidate.biomarker_code,
            profile=PROFILE,
            on=REPORT.collected_on,
        )
        results.append(C.classify_result(candidate, selection.reference))
    return results, review


def test_units_are_canonical_by_the_time_anything_is_compared() -> None:
    results, _ = _classified()
    by_code = {result.biomarker_code: result for result in results}
    assert by_code["VITD_25OH"].unit == "ng/mL"
    assert float(by_code["VITD_25OH"].value) == 14.2 or round(
        float(by_code["VITD_25OH"].value), 1
    ) == 14.2
    assert by_code["POTASSIUM"].unit == "mmol/L"
    assert by_code["POTASSIUM"].value == Decimal("4.4")


def test_the_unmappable_row_never_becomes_a_result() -> None:
    results, review = _classified()
    assert "Widget Index" not in {r.display_name for r in results}
    assert any("Widget Index" in (r.review_reason or "") for r in review)


def test_statuses_come_out_as_expected() -> None:
    results, _ = _classified()
    status = {result.biomarker_code: result.status for result in results}
    assert status["HB"] is ResultStatus.CRITICAL_LOW
    assert status["VITD_25OH"] is ResultStatus.LOW
    assert status["FERRITIN"] is ResultStatus.LOW
    assert status["HBA1C"] is ResultStatus.HIGH
    assert status["POTASSIUM"] is ResultStatus.NORMAL


def test_the_censored_tsh_is_kept_but_flagged_for_review() -> None:
    results, _ = _classified()
    tsh = next(r for r in results if r.biomarker_code == "TSH")
    assert tsh.needs_review is True
    assert tsh.is_actionable is False
    # No TSH range was supplied, so the status is UNKNOWN -- not NORMAL.
    assert tsh.status is ResultStatus.UNKNOWN


def test_red_flags_fire_on_the_right_rows() -> None:
    results, _ = _classified()
    flags = RF.evaluate(results)
    codes = {flag.code for flag in flags}
    assert "HB_CRITICAL_LOW" in codes
    assert "HBA1C_FIRST_DIABETIC_RANGE" in codes
    assert "POTASSIUM_CRITICAL_HIGH" not in codes


def test_the_worst_escalation_reaches_the_top() -> None:
    from app.domain.enums import max_escalation

    results, _ = _classified()
    flags = RF.evaluate(results)
    assert max_escalation(flag.escalation for flag in flags) is Escalation.URGENT


def test_low_results_flow_through_into_nutrient_gaps() -> None:
    results, _ = _classified()
    report = G.compute_gaps(PROFILE, {}, results, on=REPORT.collected_on)
    assert report.explanations["iron_mg"].biomarker_code in ("FERRITIN", "HB")
    assert report.explanations["vitamin_d_ug"].biomarker_code == "VITD_25OH"
    assert report.effective_deficit("iron_mg") > 0


def test_the_whole_flow_produces_no_status_of_normal_by_accident() -> None:
    # Every biomarker with no curated range must be UNKNOWN, never NORMAL.
    results, _ = _classified()
    for result in results:
        if result.reference is None:
            assert result.status is ResultStatus.UNKNOWN, result.biomarker_code

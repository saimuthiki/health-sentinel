"""Stage 5: deterministic lab red flags.

Every threshold is tested twice -- once at the boundary, where it must stay silent, and
once one step past it, where it must fire. If someone edits a constant, one of these
fails.
"""

from __future__ import annotations

from datetime import date
from decimal import Decimal

import pytest

from app.domain.enums import Escalation, ResultStatus
from app.rules import red_flags as RF
from tests.rules.conftest import result


def _step(threshold: Decimal) -> Decimal:
    return Decimal("1") if abs(threshold) >= 100 else Decimal("0.1")


# ------------------------------------------------------------------- table integrity


def test_every_threshold_rule_carries_a_source_citation() -> None:
    for rule in RF.THRESHOLD_RULES:
        assert rule.source_citation.strip(), rule.code
        assert len(rule.source_citation) > 40, rule.code


def test_history_rules_carry_source_citations_too() -> None:
    assert RF.HBA1C_RULE_SOURCE.strip()
    assert RF.CREATININE_RULE_SOURCE.strip()


def test_rule_codes_are_unique() -> None:
    codes = [rule.code for rule in RF.THRESHOLD_RULES]
    assert len(codes) == len(set(codes))


def test_the_documented_threshold_set_is_all_present() -> None:
    covered = {rule.biomarker_code for rule in RF.THRESHOLD_RULES}
    assert {
        "HB",
        "POTASSIUM",
        "SODIUM",
        "GLUCOSE_FASTING",
        "PLT",
        "NEUTROPHILS_ABS",
        "TSH",
    } <= covered


def test_thresholds_match_the_pipeline_document() -> None:
    assert RF.HB_CRITICAL_LOW == Decimal("7.0")
    assert RF.POTASSIUM_CRITICAL_LOW == Decimal("2.5")
    assert RF.POTASSIUM_CRITICAL_HIGH == Decimal("6.0")
    assert RF.SODIUM_CRITICAL_LOW == Decimal("120")
    assert RF.SODIUM_CRITICAL_HIGH == Decimal("160")
    assert RF.GLUCOSE_FASTING_CRITICAL_HIGH == Decimal("300")
    assert RF.PLATELETS_CRITICAL_LOW == Decimal("50")       # 50,000 per uL
    assert RF.NEUTROPHILS_CRITICAL_LOW == Decimal("500")
    assert RF.HBA1C_DIABETIC == Decimal("6.5")
    assert RF.TSH_HIGH == Decimal("10")
    assert RF.CREATININE_RISE_FRACTION == Decimal("0.30")


# --------------------------------------------------------------------- boundaries


@pytest.mark.parametrize("rule", RF.THRESHOLD_RULES, ids=lambda r: r.code)
def test_threshold_does_not_fire_at_the_boundary(rule: RF.ThresholdRule) -> None:
    flags = RF.evaluate_thresholds(
        [result(rule.biomarker_code, str(rule.threshold), rule.unit)]
    )
    fired = {flag.code for flag in flags}
    if rule.comparator == ">=":
        assert rule.code in fired
    else:
        assert rule.code not in fired


@pytest.mark.parametrize("rule", RF.THRESHOLD_RULES, ids=lambda r: r.code)
def test_threshold_fires_one_step_past_the_boundary(rule: RF.ThresholdRule) -> None:
    step = _step(rule.threshold)
    value = rule.threshold - step if rule.comparator == "<" else rule.threshold + step
    flags = RF.evaluate_thresholds(
        [result(rule.biomarker_code, str(value), rule.unit)]
    )
    fired = {flag.code for flag in flags}
    assert rule.code in fired


@pytest.mark.parametrize("rule", RF.THRESHOLD_RULES, ids=lambda r: r.code)
def test_threshold_stays_silent_well_inside_the_safe_side(rule: RF.ThresholdRule) -> None:
    step = _step(rule.threshold) * 3
    value = rule.threshold + step if rule.comparator == "<" else rule.threshold - step
    flags = RF.evaluate_thresholds(
        [result(rule.biomarker_code, str(value), rule.unit)]
    )
    assert rule.code not in {flag.code for flag in flags}


# ------------------------------------------------------------------- named examples


def test_severe_anaemia_is_urgent() -> None:
    flags = RF.evaluate([result("HB", "6.2", "g/dL")])
    assert [f.code for f in flags] == ["HB_CRITICAL_LOW"]
    assert flags[0].escalation is Escalation.URGENT
    assert "6.2" in flags[0].message


def test_both_ends_of_potassium_are_covered() -> None:
    low = RF.evaluate([result("POTASSIUM", "2.1", "mmol/L")])
    high = RF.evaluate([result("POTASSIUM", "6.8", "mmol/L")])
    assert [f.code for f in low] == ["POTASSIUM_CRITICAL_LOW"]
    assert [f.code for f in high] == ["POTASSIUM_CRITICAL_HIGH"]


def test_platelets_are_compared_in_thousands_per_microlitre() -> None:
    # 45,000/uL, stored canonically as 45 x10^3/uL.
    flags = RF.evaluate([result("PLT", "45", "10^3/uL")])
    assert [f.code for f in flags] == ["PLATELETS_CRITICAL_LOW"]


def test_a_value_in_the_wrong_unit_is_never_compared() -> None:
    # 45,000 raw cells/uL is the same platelet count -- but it is not in the canonical
    # unit, so the rule refuses it rather than comparing 45,000 with 50.
    flags = RF.evaluate([result("PLT", "45000", "/uL")])
    assert flags == []


def test_tsh_over_ten_is_see_doctor_soon_not_urgent() -> None:
    flags = RF.evaluate([result("TSH", "12.4", "uIU/mL")])
    assert flags[0].escalation is Escalation.SEE_DOCTOR_SOON


def test_uncertain_values_are_still_checked_by_default() -> None:
    unconfirmed = result("POTASSIUM", "6.8", "mmol/L", needs_review=True)
    assert RF.evaluate([unconfirmed]) != []
    assert RF.evaluate([unconfirmed], include_needs_review=False) == []


def test_a_normal_panel_raises_nothing() -> None:
    panel = [
        result("HB", "14.2", "g/dL"),
        result("POTASSIUM", "4.2", "mmol/L"),
        result("SODIUM", "139", "mmol/L"),
        result("GLUCOSE_FASTING", "92", "mg/dL"),
        result("PLT", "250", "10^3/uL"),
        result("NEUTROPHILS_ABS", "4200", "/uL"),
        result("TSH", "2.1", "uIU/mL"),
        result("HBA1C", "5.4", "%"),
    ]
    assert RF.evaluate(panel) == []


# ------------------------------------------------------------------------- HbA1c


def test_hba1c_at_six_five_fires_the_first_time() -> None:
    flags = RF.evaluate_hba1c([result("HBA1C", "6.5", "%")])
    assert [f.code for f in flags] == ["HBA1C_FIRST_DIABETIC_RANGE"]
    assert flags[0].escalation is Escalation.SEE_DOCTOR_SOON


def test_hba1c_just_below_six_five_does_not_fire() -> None:
    assert RF.evaluate_hba1c([result("HBA1C", "6.4", "%")]) == []


def test_hba1c_already_known_to_be_high_is_routine_not_a_new_alarm() -> None:
    history = [result("HBA1C", "7.1", "%", measured_on=date(2025, 1, 1))]
    flags = RF.evaluate_hba1c(
        [result("HBA1C", "6.9", "%", measured_on=date(2026, 1, 1))], history
    )
    assert [f.code for f in flags] == ["HBA1C_PERSISTENT_DIABETIC_RANGE"]
    assert flags[0].escalation is Escalation.ROUTINE


def test_hba1c_message_never_states_a_diagnosis() -> None:
    message = RF.evaluate_hba1c([result("HBA1C", "8.0", "%")])[0].message.lower()
    assert "you have diabetes" not in message
    assert "you are diabetic" not in message
    assert "doctor" in message


# -------------------------------------------------------------------- creatinine


def _creatinine(value: str, on: date) -> object:
    return result("CREATININE", value, "mg/dL", measured_on=on)


def test_creatinine_rise_over_thirty_percent_fires() -> None:
    flags = RF.evaluate_creatinine_trend(
        [_creatinine("1.4", date(2026, 6, 1))],
        [_creatinine("1.0", date(2026, 1, 1))],
    )
    assert [f.code for f in flags] == ["CREATININE_RISE"]
    assert "40%" in flags[0].message


def test_creatinine_rise_of_exactly_thirty_percent_does_not_fire() -> None:
    flags = RF.evaluate_creatinine_trend(
        [_creatinine("1.30", date(2026, 6, 1))],
        [_creatinine("1.00", date(2026, 1, 1))],
    )
    assert flags == []


def test_a_tiny_absolute_rise_is_treated_as_rounding_noise() -> None:
    # 0.6 -> 0.69 is a 15% rise; 0.6 -> 0.68 would be 13%. Both are under the floor.
    flags = RF.evaluate_creatinine_trend(
        [_creatinine("0.69", date(2026, 6, 1))],
        [_creatinine("0.60", date(2026, 1, 1))],
    )
    assert flags == []


def test_creatinine_falling_never_fires() -> None:
    flags = RF.evaluate_creatinine_trend(
        [_creatinine("0.9", date(2026, 6, 1))],
        [_creatinine("1.5", date(2026, 1, 1))],
    )
    assert flags == []


def test_creatinine_needs_a_previous_report() -> None:
    assert RF.evaluate_creatinine_trend([_creatinine("2.4", date(2026, 6, 1))], []) == []


def test_creatinine_uses_the_most_recent_previous_report() -> None:
    history = [
        _creatinine("1.0", date(2024, 1, 1)),
        _creatinine("1.9", date(2026, 1, 1)),  # most recent previous
    ]
    flags = RF.evaluate_creatinine_trend([_creatinine("2.0", date(2026, 6, 1))], history)
    assert flags == []  # 1.9 -> 2.0 is only 5%


# ---------------------------------------------------------------------- routine tier


def test_mild_deficiency_is_routine() -> None:
    flags = RF.routine_deficiency_flags(
        [result("VITD_25OH", "14.2", "ng/mL", status=ResultStatus.LOW)]
    )
    assert [f.escalation for f in flags] == [Escalation.ROUTINE]


def test_routine_tier_ignores_normal_results() -> None:
    assert RF.routine_deficiency_flags(
        [result("VITD_25OH", "44", "ng/mL", status=ResultStatus.NORMAL)]
    ) == []


def test_evaluate_combines_every_family_of_rule() -> None:
    today = [
        result("HB", "6.4", "g/dL"),
        result("HBA1C", "7.2", "%"),
        _creatinine("1.8", date(2026, 6, 1)),
    ]
    history = [_creatinine("1.0", date(2026, 1, 1))]
    codes = {flag.code for flag in RF.evaluate(today, history)}
    assert codes == {"HB_CRITICAL_LOW", "HBA1C_FIRST_DIABETIC_RANGE", "CREATININE_RISE"}


# ------------------------------------------------- the deliberate haemoglobin split


def test_haemoglobin_between_seven_and_eight_escalates_but_is_not_urgent() -> None:
    # 7.5 g/dL is CRITICAL_LOW against WHO's severe-anaemia boundary of 8.0 but is
    # above our urgent trigger of 7.0. It must still reach a doctor -- one tier down.
    # db/seed/GAPS.md section 4 item 1 asks for exactly this split.
    critical = result("HB", "7.5", "g/dL", status=ResultStatus.CRITICAL_LOW)
    flags = RF.evaluate([critical])
    assert len(flags) == 1
    assert flags[0].escalation is Escalation.SEE_DOCTOR_SOON
    assert flags[0].biomarker_code == "HB"


def test_haemoglobin_below_seven_is_urgent_and_not_double_reported() -> None:
    critical = result("HB", "6.2", "g/dL", status=ResultStatus.CRITICAL_LOW)
    flags = RF.evaluate([critical])
    assert [f.escalation for f in flags] == [Escalation.URGENT]


def test_a_critical_classification_on_an_unthresholded_biomarker_still_escalates() -> None:
    # Sodium has no seeded critical values yet (db/seed/GAPS.md section 2), so this
    # path is what carries such a result to a clinician once they are added.
    flags = RF.critical_status_flags(
        [result("LDL", "210", "mg/dL", status=ResultStatus.CRITICAL_HIGH)]
    )
    assert [f.escalation for f in flags] == [Escalation.SEE_DOCTOR_SOON]
    assert "above" in flags[0].message


def test_a_non_critical_status_does_not_escalate() -> None:
    assert RF.critical_status_flags(
        [result("LDL", "150", "mg/dL", status=ResultStatus.BORDERLINE_HIGH)]
    ) == []


def test_unknown_status_never_escalates_and_never_reassures() -> None:
    # UNKNOWN is "we could not assess this". It is not a red flag and it is not a
    # clean bill of health -- it simply produces nothing here.
    assert RF.critical_status_flags(
        [result("PLT", "250", "10^3/uL", status=ResultStatus.UNKNOWN)]
    ) == []

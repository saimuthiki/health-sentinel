"""Stage 3: name mapping, value parsing and unit conversion.

The safety property under test throughout: anything we are not sure about comes back
``needs_review=True`` with a reason a human can read.
"""

from __future__ import annotations

from decimal import Decimal

import pytest

from app.domain.enums import ResultStatus
from app.rules import normalise as N
from tests.rules.conftest import row


# ------------------------------------------------------------------ unit conversions


@pytest.mark.parametrize(
    ("code", "canonical", "other"),
    [
        ("VITD_25OH", "ng/mL", "nmol/L"),
        ("VITB12", "pg/mL", "pmol/L"),
        ("GLUCOSE_FASTING", "mg/dL", "mmol/L"),
        ("CHOL_TOTAL", "mg/dL", "mmol/L"),
        ("LDL", "mg/dL", "mmol/L"),
        ("HB", "g/dL", "g/L"),
        ("TSH", "uIU/mL", "mIU/L"),
        ("CREATININE", "mg/dL", "umol/L"),
        ("PLT", "10^3/uL", "/uL"),
        ("NEUTROPHILS_ABS", "/uL", "10^3/uL"),
    ],
)
def test_unit_conversions_round_trip(code: str, canonical: str, other: str) -> None:
    original = Decimal("42.5")
    there = N.convert(code, original, canonical, other)
    back = N.convert(code, there, other, canonical)
    assert float(back) == pytest.approx(float(original), rel=1e-9)


def test_canonical_unit_matches_the_biomarker_catalogue() -> None:
    for code, spec in N.BIOMARKERS.items():
        assert spec.canonical_unit in N.UNIT_FACTORS[code], code
        assert N.UNIT_FACTORS[code][spec.canonical_unit] == Decimal("1"), code


@pytest.mark.parametrize(
    ("code", "value", "unit", "expected"),
    [
        ("VITD_25OH", "35.44", "nmol/L", 14.2),      # nmol/L -> ng/mL
        ("VITD_25OH", "14.2", "ng/mL", 14.2),
        ("VITB12", "150", "pmol/L", 203.3),          # pmol/L -> pg/mL
        ("GLUCOSE_FASTING", "5.5", "mmol/L", 99.1),
        ("CHOL_TOTAL", "5.2", "mmol/L", 201.1),
        ("HB", "142", "g/L", 14.2),
        ("TSH", "4.5", "mIU/L", 4.5),                # numerically identical
        ("PLT", "150000", "/uL", 150.0),
        ("PLT", "1.5", "lakh/uL", 150.0),
        ("NEUTROPHILS_ABS", "1.2", "10^3/uL", 1200.0),
        ("CREATININE", "88.4", "umol/L", 1.0),
    ],
)
def test_conversion_to_canonical(code: str, value: str, unit: str, expected: float) -> None:
    got = N.to_canonical(code, Decimal(value), unit)
    assert float(got) == pytest.approx(expected, rel=1e-3)


def test_unknown_unit_raises_rather_than_guessing() -> None:
    with pytest.raises(N.UnitConversionError):
        N.to_canonical("HB", Decimal("14"), "furlongs")


@pytest.mark.parametrize(
    ("printed", "expected"),
    [
        ("ng/mL", "ng/mL"), ("NG/ML", "ng/mL"), ("ng / ml", "ng/mL"),
        ("µIU/mL", "uIU/mL"), ("uIU/mL", "uIU/mL"),
        ("gm/dl", "g/dL"), ("g%", "g/dL"),
        ("mEq/L", "mEq/L"), ("mg/dl", "mg/dL"), ("mg%", "mg/dL"),
        ("cells/cumm", "/uL"), ("lakhs/cumm", "lakh/uL"),
        ("10^3/µL", "10^3/uL"),
        ("blorp", None), ("", None), (None, None),
    ],
)
def test_unit_alias_normalisation(printed: str | None, expected: str | None) -> None:
    assert N.normalise_unit(printed) == expected


# --------------------------------------------------------------------- name mapping


@pytest.mark.parametrize(
    ("printed", "code"),
    [
        ("Vitamin D (25-OH)", "VITD_25OH"),
        ("25-Hydroxy Vitamin D", "VITD_25OH"),
        ("25(OH)D", "VITD_25OH"),
        ("Vit D (25-OH)", "VITD_25OH"),
        ("S. Ferritin", "FERRITIN"),
        ("SERUM FERRITIN", "FERRITIN"),
        ("Haemoglobin (Hb)", "HB"),
        ("HbA1c", "HBA1C"),
        ("Glycated Haemoglobin", "HBA1C"),
        ("Thyroid Stimulating Hormone (TSH)", "TSH"),
        ("Fasting Blood Sugar", "GLUCOSE_FASTING"),
        ("Platelet Count", "PLT"),
        ("Absolute Neutrophil Count", "NEUTROPHILS_ABS"),
        ("Vitamin B12", "VITB12"),
        ("Plasma Creatinine", "CREATININE"),
    ],
)
def test_known_names_map_exactly(printed: str, code: str) -> None:
    match = N.map_test_name(printed)
    assert match.code == code
    assert match.method == "exact"


def test_close_but_unknown_name_is_a_suggestion_not_an_answer() -> None:
    match = N.map_test_name("Ferritn")
    assert match.code == "FERRITIN"
    assert match.method == "fuzzy"
    assert match.suggestion and "Ferritin" in match.suggestion


def test_genuinely_unknown_name_maps_to_nothing() -> None:
    assert N.map_test_name("Widget Index Score").code is None


# -------------------------------------------------------------------- value parsing


def test_parses_a_plain_number() -> None:
    parsed = N.parse_value("14.2")
    assert parsed.ok and parsed.value == Decimal("14.2")


def test_parses_a_censored_value_but_never_calls_it_certain() -> None:
    parsed = N.parse_value("<0.5")
    assert parsed.value == Decimal("0.5")
    assert parsed.censoring == "<"
    assert parsed.ok is False
    assert "below 0.5" in (parsed.reason or "")


def test_parses_a_greater_than_value() -> None:
    parsed = N.parse_value(">1000")
    assert parsed.value == Decimal("1000")
    assert parsed.censoring == ">"
    assert parsed.ok is False


def test_parses_western_thousands_separator() -> None:
    parsed = N.parse_value("1,240")
    assert parsed.ok and parsed.value == Decimal("1240")


def test_parses_indian_thousands_separator() -> None:
    parsed = N.parse_value("1,24,000")
    assert parsed.ok and parsed.value == Decimal("124000")


def test_strips_a_trailing_unit_from_the_value_cell() -> None:
    parsed = N.parse_value("14.2 ng/mL")
    assert parsed.ok and parsed.value == Decimal("14.2")
    assert parsed.trailing_unit == "ng/mL"


def test_keeps_a_lab_flag_letter_without_choking() -> None:
    parsed = N.parse_value("14.2 L")
    assert parsed.ok and parsed.value == Decimal("14.2")


@pytest.mark.parametrize(
    "text",
    ["Positive", "NEGATIVE", "Non Reactive", "Trace", "Not Done", "Haemolysed"],
)
def test_qualitative_words_are_never_turned_into_numbers(text: str) -> None:
    parsed = N.parse_value(text)
    assert parsed.ok is False
    assert parsed.value is None
    assert parsed.qualitative is not None
    assert parsed.reason


@pytest.mark.parametrize("text", ["", "   ", "12-14", "12 to 14", "abc", "12,5", "1.2.3"])
def test_unparseable_text_is_refused_with_a_reason(text: str) -> None:
    parsed = N.parse_value(text)
    assert parsed.ok is False
    assert parsed.reason


def test_ambiguous_comma_is_refused_rather_than_guessed() -> None:
    # "12,5" is 12.5 in much of Europe and 125 nowhere useful. We do not pick.
    parsed = N.parse_value("12,5")
    assert parsed.ok is False
    assert "comma" in (parsed.reason or "")


# ------------------------------------------------------------------ whole-row flow


def test_happy_path_row_needs_no_review() -> None:
    got = N.normalise_row(row("Vitamin D (25-OH)", "14.2", "ng/mL"))
    assert got.biomarker_code == "VITD_25OH"
    assert got.value == Decimal("14.2")
    assert got.unit == "ng/mL"
    assert got.needs_review is False
    assert got.review_reason is None


def test_row_in_a_foreign_unit_is_converted_to_canonical() -> None:
    got = N.normalise_row(row("Vitamin D", "35.44", "nmol/L"))
    assert got.unit == "ng/mL"
    assert float(got.value) == pytest.approx(14.2, rel=1e-3)
    assert got.needs_review is False


def test_unmappable_test_name_needs_review() -> None:
    got = N.normalise_row(row("Widget Index Score", "12", "mg/dL"))
    assert got.needs_review is True
    assert got.biomarker_code is None
    assert "could not match" in (got.review_reason or "")


def test_near_miss_test_name_needs_review_and_says_what_it_thinks() -> None:
    got = N.normalise_row(row("S. Ferritn", "12", "ng/mL"))
    assert got.needs_review is True
    assert "is this Ferritin?" in (got.review_reason or "")


def test_qualitative_value_needs_review_and_carries_no_number() -> None:
    got = N.normalise_row(row("Vitamin D", "Positive", "ng/mL"))
    assert got.needs_review is True
    assert got.value is None
    assert got.qualitative == "positive"


def test_missing_unit_is_flagged_not_silently_assumed() -> None:
    got = N.normalise_row(row("Haemoglobin", "14.2", None))
    assert got.needs_review is True
    assert "No unit was printed" in (got.review_reason or "")
    assert got.unit == "g/dL"  # assumed, but only after saying so


def test_unrecognised_unit_is_flagged() -> None:
    got = N.normalise_row(row("Haemoglobin", "14.2", "furlongs"))
    assert got.needs_review is True
    assert "furlongs" in (got.review_reason or "")


def test_low_extraction_confidence_needs_review() -> None:
    got = N.normalise_row(row("Haemoglobin", "14.2", "g/dL", confidence=0.4))
    assert got.needs_review is True
    assert "low confidence" in (got.review_reason or "")


def test_censored_row_needs_review_but_keeps_the_bound() -> None:
    got = N.normalise_row(row("TSH", "<0.005", "uIU/mL"))
    assert got.needs_review is True
    assert got.censoring == "<"
    assert got.value == Decimal("0.005")


def test_candidate_starts_unknown_never_normal() -> None:
    got = N.to_candidate(N.normalise_row(row("Haemoglobin", "14.2", "g/dL")))
    assert got is not None
    assert got.status is ResultStatus.UNKNOWN


def test_candidate_is_none_when_there_is_no_usable_number() -> None:
    assert N.to_candidate(N.normalise_row(row("Haemoglobin", "Positive", "g/dL"))) is None


def test_normalise_rows_handles_a_whole_report() -> None:
    rows = [
        row("Haemoglobin", "14.2", "g/dL"),
        row("S. Ferritin", "8", "ng/mL"),
        row("Mystery Test", "1", "units"),
    ]
    got = N.normalise_rows(rows)
    assert [r.needs_review for r in got] == [False, False, True]


def test_biomarker_codes_match_the_seeded_catalogue() -> None:
    # These codes are the contract with db/seed/200_biomarkers.sql. A rename here
    # without a rename there silently stops every lookup from matching.
    for code in ("HB", "PLT", "WBC", "LDL", "HDL", "TRIG", "CHOL_TOTAL", "TSH",
                 "VITD_25OH", "VITB12", "FOLATE", "FERRITIN", "CREATININE",
                 "GLUCOSE_FASTING", "HBA1C", "SODIUM", "POTASSIUM", "CALCIUM"):
        assert code in N.BIOMARKERS, code


def test_canonical_units_match_the_seeded_catalogue() -> None:
    seeded = {
        "HB": "g/dL", "PLT": "10^3/uL", "WBC": "10^3/uL", "TSH": "uIU/mL",
        "VITD_25OH": "ng/mL", "VITB12": "pg/mL", "FOLATE": "ng/mL",
        "FERRITIN": "ng/mL", "CREATININE": "mg/dL", "GLUCOSE_FASTING": "mg/dL",
        "HBA1C": "%", "SODIUM": "mmol/L", "POTASSIUM": "mmol/L", "CALCIUM": "mg/dL",
        "LDL": "mg/dL", "HDL": "mg/dL", "TRIG": "mg/dL", "FT4": "ng/dL",
        "FT3": "pg/mL", "IRON": "ug/dL", "ALT": "U/L", "AST": "U/L",
    }
    for code, unit in seeded.items():
        assert N.canonical_unit(code) == unit, code


def test_the_concerning_direction_is_recorded_for_the_classifier() -> None:
    assert N.higher_is_worse("HB") is False       # only anaemia matters
    assert N.higher_is_worse("LDL") is True       # only a high LDL matters
    assert N.higher_is_worse("POTASSIUM") is None  # both ends matter

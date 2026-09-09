"""The "why this food" sentence."""

from __future__ import annotations

from app.domain.models import NutrientGap
from app.nutrition.why import format_amount, nutrient_unit, why_sentence

IRON_GAP = NutrientGap(nutrient="iron_mg", target=19.0, current=13.0, unit="mg")


def test_the_sentence_from_the_brief() -> None:
    got = why_sentence(
        {"protein_g": 18.0, "fibre_g": 4.2, "iron_mg": 1.86}, [IRON_GAP]
    )
    assert got == "18 g protein, 4.2 g fibre, covers 31% of today's iron gap"


def test_numbers_are_rounded_the_way_a_person_would_say_them() -> None:
    assert format_amount("protein_g", 18.04) == "18 g"
    assert format_amount("fibre_g", 4.23) == "4.2 g"
    assert format_amount("kcal", 210.6) == "211 kcal"
    assert format_amount("vitamin_d_ug", 2.05) == "2 ug"


def test_units_come_from_the_nutrient_key() -> None:
    assert nutrient_unit("iron_mg") == "mg"
    assert nutrient_unit("vitamin_d_ug") == "ug"
    assert nutrient_unit("kcal") == "kcal"


def test_without_a_gap_the_sentence_is_just_the_nutrients() -> None:
    assert why_sentence({"protein_g": 18.0, "fibre_g": 4.2}) == "18 g protein, 4.2 g fibre"


def test_a_gap_already_met_produces_no_gap_clause() -> None:
    met = NutrientGap(nutrient="iron_mg", target=19.0, current=25.0, unit="mg")
    got = why_sentence({"protein_g": 18.0, "iron_mg": 5.0}, [met])
    assert "gap" not in got


def test_a_trivial_contribution_to_a_gap_is_not_worth_a_clause() -> None:
    got = why_sentence({"protein_g": 18.0, "iron_mg": 0.05}, [IRON_GAP])
    assert "gap" not in got


def test_the_gap_clause_names_the_biggest_gap_the_food_closes() -> None:
    vitd_gap = NutrientGap(nutrient="vitamin_d_ug", target=15.0, current=1.0, unit="ug")
    got = why_sentence(
        {"iron_mg": 0.6, "vitamin_d_ug": 7.0}, [IRON_GAP, vitd_gap]
    )
    assert "vitamin D gap" in got
    assert "iron gap" not in got


def test_the_gap_nutrient_is_not_repeated_as_a_plain_amount() -> None:
    got = why_sentence({"iron_mg": 3.0, "protein_g": 18.0}, [IRON_GAP])
    assert got.count("iron") == 1


def test_trace_amounts_are_left_out_of_the_sentence() -> None:
    got = why_sentence({"protein_g": 18.0, "iron_mg": 0.01, "fibre_g": 0.05})
    assert got == "18 g protein"


def test_the_sentence_is_capped_so_it_stays_readable() -> None:
    got = why_sentence(
        {
            "protein_g": 18.0, "fibre_g": 4.2, "calcium_mg": 300.0,
            "folate_ug": 190.0, "zinc_mg": 4.0, "kcal": 330.0,
        }
    )
    assert got.count(",") == 1


def test_max_nutrients_is_adjustable() -> None:
    got = why_sentence(
        {"protein_g": 18.0, "fibre_g": 4.2, "calcium_mg": 300.0}, max_nutrients=3
    )
    assert got == "18 g protein, 4.2 g fibre, 300 mg calcium"


def test_a_food_with_no_nutrient_data_says_so_instead_of_inventing() -> None:
    assert why_sentence({}, food_name="Mystery dish") == (
        "We do not hold nutrient values for Mystery dish yet."
    )
    assert why_sentence({}) == "We do not hold nutrient values for this item yet."


def test_the_sentence_never_prescribes() -> None:
    got = why_sentence(
        {"protein_g": 18.0, "fibre_g": 4.2, "iron_mg": 1.86}, [IRON_GAP]
    ).lower()
    for forbidden in ("take ", "tablet", "supplement", "dose", "capsule", "iu "):
        assert forbidden not in got


def test_an_unknown_nutrient_key_never_reaches_the_sentence() -> None:
    # The model can invent a key; the sentence is built only from keys we know.
    assert "unicorn" not in why_sentence({"unicorn_g": 99.0, "protein_g": 18.0})

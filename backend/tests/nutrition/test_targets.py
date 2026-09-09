"""RDA target resolution."""

from __future__ import annotations

from datetime import date

import pytest

from app.domain.enums import ActivityLevel, Sex
from app.nutrition import targets as TG
from app.nutrition.why import NUTRIENT_LABELS
from tests.nutrition.conftest import TODAY, profile


def amount(sex, nutrient, **kwargs):
    target = TG.resolve_target(profile(sex=sex, **kwargs), nutrient, on=TODAY)
    return None if target is None else target.amount


# ------------------------------------------------------------------ table integrity


def test_every_row_names_a_known_nutrient_and_the_right_unit() -> None:
    for row in TG.RDA_TABLE:
        assert row.nutrient in TG.NUTRIENT_UNITS, row.nutrient
        assert row.unit == TG.NUTRIENT_UNITS[row.nutrient], row.nutrient


def test_every_row_carries_a_source() -> None:
    for row in TG.RDA_TABLE:
        assert row.source.strip(), row.nutrient
        assert "ICMR" in row.source


def test_nutrient_keys_match_the_keys_used_for_food_rows() -> None:
    # If a target key and a foods.per_100g key ever drift apart, every gap silently
    # becomes zero. They are asserted equal here so that cannot happen quietly.
    for nutrient in TG.NUTRIENT_UNITS:
        assert nutrient in NUTRIENT_LABELS, nutrient


# --------------------------------------------------------------------- resolution


def test_zinc_matches_the_seeded_value() -> None:
    assert amount(Sex.FEMALE, "zinc_mg") == 13.0
    assert amount(Sex.MALE, "zinc_mg") == 17.0


def test_iron_target_differs_by_sex() -> None:
    assert amount(Sex.MALE, "iron_mg") == 19.0
    assert amount(Sex.FEMALE, "iron_mg") == 29.0


def test_no_pregnancy_rows_are_shipped_so_no_invented_increment_is_used() -> None:
    # ICMR-NIN 2020's pregnancy increments could not be sourced with confidence, so
    # neither this table nor db/seed/203_rda_targets.sql carries them. A pregnant
    # user currently resolves against the non-pregnant row, which is the documented
    # state (GAPS.md item G4) -- not a silently invented number.
    assert all(row.pregnancy is None for row in TG.RDA_TABLE)
    assert amount(Sex.FEMALE, "iron_mg", is_pregnant=True) == 29.0


def test_a_pregnancy_row_would_win_when_one_is_supplied() -> None:
    # The mechanism is implemented and tested, so filling the gap is a data change.
    pregnancy_row = TG.RdaRow(
        nutrient="iron_mg", amount=27.0, unit="mg", source="fixture",
        sex=Sex.FEMALE, age_min=19, age_max=59, pregnancy=True,
    )
    table = (*TG.RDA_TABLE, pregnancy_row)
    pregnant = TG.resolve_target(
        profile(sex=Sex.FEMALE, is_pregnant=True), "iron_mg", on=TODAY, table=table
    )
    not_pregnant = TG.resolve_target(
        profile(sex=Sex.FEMALE), "iron_mg", on=TODAY, table=table
    )
    assert pregnant is not None and pregnant.amount == 27.0
    assert not_pregnant is not None and not_pregnant.amount == 29.0


def test_energy_target_follows_the_activity_band() -> None:
    assert amount(Sex.MALE, "kcal", activity=ActivityLevel.SEDENTARY) == 2110
    assert amount(Sex.MALE, "kcal", activity=ActivityLevel.MODERATE) == 2710
    assert amount(Sex.MALE, "kcal", activity=ActivityLevel.VERY_ACTIVE) == 3470
    assert amount(Sex.FEMALE, "kcal", activity=ActivityLevel.SEDENTARY) == 1660


def test_light_activity_maps_onto_the_sedentary_icmr_band() -> None:
    assert amount(Sex.MALE, "kcal", activity=ActivityLevel.LIGHT) == 2110


def test_sex_unknown_resolves_only_the_unsexed_rows() -> None:
    # Calcium, vitamin D, B12 and folate are seeded as 'any'; iron, protein, zinc and
    # energy are sex-specific, so they honestly return nothing when sex is unknown.
    assert amount(Sex.OTHER, "calcium_mg") == 1000.0
    assert amount(Sex.OTHER, "iron_mg") is None
    assert amount(Sex.OTHER, "kcal") is None


def test_nothing_is_resolved_for_an_adult_over_fifty_nine() -> None:
    # The seeded band is 19-59. Stretching it would be inventing a number.
    older = profile(dob=date(1950, 1, 1))
    assert TG.resolve_targets(older, on=TODAY) == []


def test_the_energy_key_from_the_rda_table_is_translated_to_the_food_key() -> None:
    # rda_targets stores 'energy_kcal'; foods.per_100g stores 'kcal'. Gap arithmetic
    # subtracts one from the other, so they must be the same key when they meet.
    assert TG.normalise_nutrient_key("energy_kcal") == "kcal"
    assert TG.normalise_nutrient_key("iron_mg") == "iron_mg"


def test_fibre_has_no_target_because_no_figure_could_be_sourced() -> None:
    assert TG.resolve_target(profile(), "fibre_g", on=TODAY) is None


def test_protein_uses_body_weight_when_we_know_it() -> None:
    target = TG.resolve_target(
        profile(sex=Sex.MALE, weight_kg=74.0), "protein_g", on=TODAY
    )
    assert target is not None
    assert target.amount == pytest.approx(0.83 * 74.0, abs=0.05)
    assert "74 kg" in target.source


def test_protein_falls_back_to_the_reference_body_weight_row() -> None:
    assert amount(Sex.MALE, "protein_g") == 54.0


def test_no_targets_at_all_for_someone_under_nineteen() -> None:
    teenager = profile(dob=date(2012, 1, 1))
    assert TG.resolve_targets(teenager, on=TODAY) == []
    assert TG.resolve_target(teenager, "iron_mg", on=TODAY) is None


def test_no_targets_when_we_do_not_know_the_age() -> None:
    unknown_age = profile(dob=None)  # type: ignore[arg-type]
    assert TG.resolve_targets(unknown_age, on=TODAY) == []


def test_resolve_targets_returns_one_target_per_nutrient() -> None:
    resolved = TG.resolve_targets(profile(sex=Sex.MALE), on=TODAY)
    nutrients = [target.nutrient for target in resolved]
    assert len(nutrients) == len(set(nutrients))
    assert set(nutrients) == {
        "kcal", "protein_g", "iron_mg", "calcium_mg",
        "vitamin_d_ug", "b12_ug", "folate_ug", "zinc_mg",
    }


def test_a_target_is_never_expressed_as_a_dose_instruction() -> None:
    for target in TG.resolve_targets(profile(), on=TODAY):
        assert "take" not in target.source.lower()
        assert "tablet" not in target.source.lower()

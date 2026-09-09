"""Candidate selection.

The allergen tests are the most important tests in this package. A food that reaches a
plan when the user reacts to it is the worst thing this codebase can do, so the filter
is tested from several directions: synonyms, other languages, casing, missing allergen
columns, compound words, and the ranking's inability to re-admit anything.
"""

from __future__ import annotations

import pytest

from app.domain.enums import DietType, Sex, Stance
from app.domain.models import NutrientGap
from app.nutrition import candidates as CD
from tests.nutrition.conftest import food, preference, profile

IRON_GAP = [NutrientGap(nutrient="iron_mg", target=19.0, current=5.0, unit="mg")]


def ids(foods) -> set[str]:
    return {item.id for item in foods}


# ------------------------------------------------------------------------- allergens


@pytest.mark.parametrize(
    ("user_allergen", "food_allergen"),
    [
        ("peanut", "peanut"),
        ("peanuts", "peanut"),
        ("Peanut", "PEANUT"),
        ("  peanut  ", "peanut"),
        ("groundnut", "peanut"),
        ("moongphali", "peanut"),
        ("peanut oil", "peanut"),
        ("milk", "dairy"),
        ("dairy", "milk"),
        ("lactose", "milk"),
        ("curd", "milk"),
        ("paneer", "dairy"),
        ("egg", "eggs"),
        ("anda", "egg"),
        ("gluten", "wheat"),
        ("wheat", "gluten"),
        ("maida", "wheat"),
        ("soy", "soya"),
        ("soya", "soy"),
        ("prawns", "shellfish"),
        ("shellfish", "prawn"),
        ("fish", "machli"),
        ("til", "sesame"),
        ("tree nuts", "cashew"),
        ("almond", "tree nut"),
    ],
)
def test_allergen_synonyms_are_recognised_in_both_directions(
    user_allergen: str, food_allergen: str
) -> None:
    risky = food("f_risky", "Some dish", allergens=[food_allergen])
    allowed, rejected = CD.filter_foods([risky], profile(allergens=[user_allergen]))
    assert allowed == []
    assert rejected[0].reason == "allergen"


def test_an_allergen_we_have_never_seen_before_still_matches_itself() -> None:
    exotic = food("f_x", "Jackfruit curry", allergens=["jackfruit"])
    allowed, _ = CD.filter_foods([exotic], profile(allergens=["jackfruit"]))
    assert allowed == []


def test_a_missing_allergen_column_is_caught_by_the_food_name() -> None:
    # Reference-data imports lose allergen columns. The name is the second line of
    # defence, and over-excluding costs the user one option.
    mislabelled = food("f_pb", "Peanut butter toast", allergens=[])
    allowed, _ = CD.filter_foods([mislabelled], profile(allergens=["peanut"]))
    assert allowed == []


def test_compound_words_are_caught() -> None:
    compound = food("f_sc", "Soyachunks pulao", allergens=[])
    allowed, _ = CD.filter_foods([compound], profile(allergens=["soya"]))
    assert allowed == []


def test_an_unrelated_food_is_not_excluded_by_an_allergy(catalogue) -> None:
    allowed, _ = CD.filter_foods(catalogue, profile(allergens=["peanut"]))
    assert "f_rice" in ids(allowed)
    assert "f_peanut" not in ids(allowed)


def test_no_allergies_excludes_nothing_on_allergen_grounds(catalogue) -> None:
    _allowed, rejected = CD.filter_foods(catalogue, profile())
    assert [r for r in rejected if r.reason == "allergen"] == []


def test_the_full_pipeline_never_returns_an_allergen_food(catalogue) -> None:
    # The strong version: every allergen the fixtures know about, checked end to end.
    for allergen in ("peanut", "milk", "egg", "fish", "soy"):
        chosen = CD.select_candidates(
            catalogue,
            profile(allergens=[allergen]),
            gaps=IRON_GAP,
            preferences=[
                # A user who loves the food they are allergic to must still not get it.
                preference("f_peanut", Stance.LIKE, 5.0),
                preference("f_paneer", Stance.LIKE, 5.0),
                preference("f_egg", Stance.LIKE, 5.0),
                preference("f_rohu", Stance.LIKE, 5.0),
                preference("f_soya", Stance.LIKE, 5.0),
            ],
        )
        user_tokens = CD.allergen_tokens(allergen)
        for item in chosen:
            assert not CD.contains_allergen(item, user_tokens), (allergen, item.id)


def test_a_high_ranking_food_cannot_be_re_admitted_by_the_ranking(catalogue) -> None:
    # Soya chunks are by far the best iron source in the fixture catalogue. A soy
    # allergy must beat that.
    chosen = CD.select_candidates(
        catalogue, profile(allergens=["soy"]), gaps=IRON_GAP
    )
    assert "f_soya" not in ids(chosen)


def test_multiple_allergies_are_all_applied(catalogue) -> None:
    chosen = CD.select_candidates(catalogue, profile(allergens=["milk", "egg", "fish"]))
    assert {"f_paneer", "f_egg", "f_rohu"} & ids(chosen) == set()


# ------------------------------------------------------------------------------ diet


def test_vegetarian_excludes_meat_and_fish(catalogue) -> None:
    chosen = CD.select_candidates(catalogue, profile(diet_type=DietType.VEG))
    assert {"f_chicken", "f_rohu"} & ids(chosen) == set()
    assert "f_paneer" in ids(chosen)


def test_vegetarian_excludes_egg_but_the_egg_diet_allows_it(catalogue) -> None:
    veg = ids(CD.select_candidates(catalogue, profile(diet_type=DietType.VEG)))
    eggetarian = ids(CD.select_candidates(catalogue, profile(diet_type=DietType.EGG)))
    assert "f_egg" not in veg
    assert "f_egg" in eggetarian


def test_vegan_excludes_dairy_and_egg(catalogue) -> None:
    chosen = ids(CD.select_candidates(catalogue, profile(diet_type=DietType.VEGAN)))
    assert {"f_paneer", "f_egg", "f_chicken"} & chosen == set()
    assert "f_rajma" in chosen


def test_a_food_with_no_diet_flags_is_excluded_from_every_restricted_diet() -> None:
    unlabelled = food("f_mystery", "Unlabelled dish", diet_flags=[])
    for diet in (DietType.VEG, DietType.VEGAN, DietType.EGG, DietType.JAIN):
        allowed, rejected = CD.filter_foods([unlabelled], profile(diet_type=diet))
        assert allowed == [], diet
        assert rejected[0].reason.startswith("diet:")


def test_a_non_vegetarian_diet_restricts_nothing(catalogue) -> None:
    chosen = CD.select_candidates(catalogue, profile(diet_type=DietType.NON_VEG))
    assert ids(chosen) == ids(catalogue)


# ----------------------------------------------------------------------- preferences


def test_never_means_never(catalogue) -> None:
    chosen = CD.select_candidates(
        catalogue, profile(), preferences=[preference("f_soya", Stance.NEVER)]
    )
    assert "f_soya" not in ids(chosen)


def test_a_strongly_disliked_food_is_dropped(catalogue) -> None:
    chosen = CD.select_candidates(
        catalogue, profile(), preferences=[preference("f_soya", Stance.DISLIKE, 1.0)]
    )
    assert "f_soya" not in ids(chosen)


def test_a_mildly_disliked_food_is_kept_but_ranked_lower(catalogue) -> None:
    prefs = [preference("f_soya", Stance.DISLIKE, 2.5)]
    chosen = CD.select_candidates(catalogue, profile(), preferences=prefs)
    assert "f_soya" in ids(chosen)


def test_the_dislike_threshold_is_adjustable(catalogue) -> None:
    prefs = [preference("f_soya", Stance.DISLIKE, 2.5)]
    chosen = CD.select_candidates(
        catalogue, profile(), preferences=prefs, dislike_threshold=3.0
    )
    assert "f_soya" not in ids(chosen)


def test_a_liked_food_moves_up_the_ranking(catalogue) -> None:
    plain = CD.rank_foods(catalogue, IRON_GAP)
    liked = CD.rank_foods(catalogue, IRON_GAP, [preference("f_rice", Stance.LIKE, 5.0)])
    before = [s.food.id for s in plain].index("f_rice")
    after = [s.food.id for s in liked].index("f_rice")
    assert after < before


# --------------------------------------------------------------------------- ranking


def test_ranking_puts_the_biggest_gap_closer_first(catalogue) -> None:
    ranked = CD.rank_foods(catalogue, IRON_GAP)
    assert ranked[0].food.id == "f_soya"  # 20 mg iron per 100 g


def test_with_no_gaps_nothing_scores_on_nutrition(catalogue) -> None:
    ranked = CD.rank_foods(catalogue, None)
    assert all(scored.gap_score == 0.0 for scored in ranked)


def test_a_met_gap_contributes_nothing_to_the_score(catalogue) -> None:
    met = [NutrientGap(nutrient="iron_mg", target=19.0, current=19.0, unit="mg")]
    assert all(scored.gap_score == 0.0 for scored in CD.rank_foods(catalogue, met))


def test_a_gap_report_drives_ranking_through_its_effective_deficit(catalogue) -> None:
    from app.domain.enums import ResultStatus
    from app.nutrition import gaps as G
    from tests.nutrition.conftest import lab

    report = G.compute_gaps(
        profile(sex=Sex.MALE),
        {"iron_mg": 19.0},  # target met by intake...
        [lab("FERRITIN", "6", "ng/mL", ResultStatus.CRITICAL_LOW)],  # ...but stores low
        on=None,
    )
    ranked = CD.rank_foods(catalogue, report)
    assert ranked[0].food.id == "f_soya"


# ----------------------------------------------------------------------- boundedness


def test_the_list_is_bounded_so_the_prompt_stays_small() -> None:
    many = [food(f"f_{index}", f"Food {index}", iron_mg=1.0) for index in range(1000)]
    assert len(CD.select_candidates(many, profile())) == CD.DEFAULT_LIMIT
    assert len(CD.select_candidates(many, profile(), limit=25)) == 25


def test_a_limit_of_zero_returns_nothing_rather_than_everything() -> None:
    many = [food(f"f_{index}", f"Food {index}") for index in range(10)]
    assert CD.select_candidates(many, profile(), limit=0) == []


def test_selection_report_keeps_the_rejections_for_the_audit_trail(catalogue) -> None:
    _chosen, rejected = CD.selection_report(
        catalogue, profile(diet_type=DietType.VEG, allergens=["milk"])
    )
    reasons = {rejection.reason for rejection in rejected}
    assert "allergen" in reasons
    assert any(reason.startswith("diet:") for reason in reasons)

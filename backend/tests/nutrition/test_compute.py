"""Nutrient arithmetic, and the recompute that overwrites the model."""

from __future__ import annotations

import pytest

from app.domain.enums import MealSlot
from app.domain.models import MealPlanItem, NutrientGap
from app.nutrition import compute as CP
from tests.nutrition.conftest import food


@pytest.fixture()
def foods():
    return CP.index_foods(
        [
            food("f_rajma", "Rajma", iron_mg=5.2, fibre_g=15.2, protein_g=22.9, kcal=333.0),
            food("f_rice", "Boiled rice", carb_g=28.0, protein_g=2.7, kcal=130.0),
            food("f_paneer", "Paneer", protein_g=18.3, calcium_mg=208.0, kcal=265.0),
        ]
    )


def item(food_id: str, grams: float, slot: MealSlot = MealSlot.LUNCH) -> CP.ConsumedItem:
    return CP.ConsumedItem(food_id=food_id, grams=grams, meal_slot=slot)


# ------------------------------------------------------------------------ portions


def test_a_portion_scales_linearly_from_per_100g(foods) -> None:
    got = CP.nutrients_for(foods["f_rajma"], 150.0)
    assert got["iron_mg"] == pytest.approx(7.8)
    assert got["protein_g"] == pytest.approx(34.35)


def test_a_fifty_gram_portion_is_half_the_per_100g_row(foods) -> None:
    got = CP.nutrients_for(foods["f_rice"], 50.0)
    assert got["kcal"] == pytest.approx(65.0)


def test_sum_nutrients_keeps_every_key_that_appears(foods) -> None:
    total = CP.sum_nutrients([{"iron_mg": 1.0}, {"iron_mg": 2.0, "fibre_g": 3.0}])
    assert total == {"iron_mg": 3.0, "fibre_g": 3.0}


# --------------------------------------------------------------- meal and day totals


def test_meal_totals_are_grouped_by_slot(foods) -> None:
    items = [
        item("f_rajma", 100, MealSlot.LUNCH),
        item("f_rice", 200, MealSlot.LUNCH),
        item("f_paneer", 50, MealSlot.DINNER),
    ]
    totals = CP.meal_totals(items, foods)
    assert totals[MealSlot.LUNCH]["protein_g"] == pytest.approx(22.9 + 5.4)
    assert totals[MealSlot.DINNER]["protein_g"] == pytest.approx(9.15)


def test_day_total_adds_every_meal(foods) -> None:
    items = [
        item("f_rajma", 100, MealSlot.LUNCH),
        item("f_paneer", 100, MealSlot.DINNER),
    ]
    assert CP.day_total(items, foods)["protein_g"] == pytest.approx(41.2)


def test_a_food_we_do_not_have_contributes_nothing_rather_than_a_guess(foods) -> None:
    assert CP.day_total([item("f_unknown", 100)], foods) == {}


def test_a_zero_or_negative_portion_contributes_nothing(foods) -> None:
    assert CP.day_total([item("f_rajma", 0)], foods) == {}
    assert CP.day_total([item("f_rajma", -50)], foods) == {}


# -------------------------------------------------------------------- gap coverage


def test_percentage_of_a_gap_closed_is_computed_from_the_deficit() -> None:
    gaps = [NutrientGap(nutrient="iron_mg", target=19.0, current=13.0, unit="mg")]
    got = CP.pct_of_gaps_closed({"iron_mg": 1.86}, gaps)
    assert got["iron_mg"] == pytest.approx(31.0, abs=0.1)


def test_a_gap_already_met_is_omitted_not_reported_as_a_hundred_percent() -> None:
    gaps = [NutrientGap(nutrient="iron_mg", target=19.0, current=25.0, unit="mg")]
    assert CP.pct_of_gaps_closed({"iron_mg": 5.0}, gaps) == {}


def test_gap_coverage_is_capped_at_one_hundred_percent() -> None:
    gaps = [NutrientGap(nutrient="iron_mg", target=19.0, current=18.0, unit="mg")]
    assert CP.pct_of_gaps_closed({"iron_mg": 40.0}, gaps)["iron_mg"] == 100.0


# ------------------------------------------------------ recompute_plan_items (safety)


def _proposed(**overrides) -> MealPlanItem:
    base = dict(
        meal_slot=MealSlot.LUNCH,
        food_id="f_rajma",
        display_name="Rajma masala with extra protein",
        grams=150.0,
        computed_nutrients={"protein_g": 999.0, "iron_mg": 99.0, "unicorn_g": 1.0},
        why_text="Packed with 999 g of protein and cures anaemia overnight!",
    )
    base.update(overrides)
    return MealPlanItem(**base)


def test_model_supplied_nutrients_are_thrown_away(foods) -> None:
    plan = CP.recompute_plan_items([_proposed()], foods)
    assert len(plan.items) == 1
    nutrients = plan.items[0].computed_nutrients
    assert nutrients["protein_g"] == pytest.approx(34.35)   # 150 g of rajma
    assert nutrients["iron_mg"] == pytest.approx(7.8)
    assert "unicorn_g" not in nutrients                     # invented key is gone


def test_model_supplied_why_text_is_regenerated_from_real_numbers(foods) -> None:
    plan = CP.recompute_plan_items([_proposed()], foods)
    why = plan.items[0].why_text
    assert "999" not in why
    assert "cures" not in why
    assert "34 g protein" in why


def test_display_name_comes_from_the_foods_table_not_the_model(foods) -> None:
    plan = CP.recompute_plan_items([_proposed()], foods)
    assert plan.items[0].display_name == "Rajma"


def test_an_invented_food_id_is_dropped_not_repaired(foods) -> None:
    plan = CP.recompute_plan_items([_proposed(food_id="f_moonbeam")], foods)
    assert plan.items == []
    assert len(plan.discarded) == 1
    assert "not in the foods table" in plan.discarded[0].reason


def test_an_absurd_portion_is_dropped(foods) -> None:
    plan = CP.recompute_plan_items([_proposed(grams=9000.0)], foods)
    assert plan.items == []
    assert "exceeds" in plan.discarded[0].reason


def test_a_zero_portion_is_dropped(foods) -> None:
    plan = CP.recompute_plan_items([_proposed(grams=0.0)], foods)
    assert plan.items == []


def test_an_item_naming_neither_food_nor_recipe_is_dropped(foods) -> None:
    plan = CP.recompute_plan_items(
        [_proposed(food_id=None, display_name="something tasty")], foods
    )
    assert plan.items == []
    assert "neither a food nor a recipe" in plan.discarded[0].reason


def test_recipe_items_are_expanded_from_the_recipes_table(foods) -> None:
    plan = CP.recompute_plan_items(
        [_proposed(food_id=None, recipe_id="r_rajma_chawal", grams=300.0)],
        foods,
        recipes={"r_rajma_chawal": [("f_rajma", 100.0), ("f_rice", 200.0)]},
    )
    assert len(plan.items) == 1
    # 300 g of a 300 g recipe = the recipe as written.
    assert plan.items[0].computed_nutrients["protein_g"] == pytest.approx(22.9 + 5.4)


def test_a_recipe_we_do_not_have_is_dropped(foods) -> None:
    plan = CP.recompute_plan_items(
        [_proposed(food_id=None, recipe_id="r_invented", grams=300.0)], foods
    )
    assert plan.items == []
    assert "recipes table" in plan.discarded[0].reason


def test_a_recipe_referencing_a_missing_food_is_dropped(foods) -> None:
    plan = CP.recompute_plan_items(
        [_proposed(food_id=None, recipe_id="r_bad", grams=100.0)],
        foods,
        recipes={"r_bad": [("f_rajma", 50.0), ("f_ghost", 50.0)]},
    )
    assert plan.items == []


def test_totals_are_recomputed_across_the_whole_plan(foods) -> None:
    plan = CP.recompute_plan_items(
        [
            _proposed(),
            _proposed(food_id="f_rice", grams=200.0, meal_slot=MealSlot.DINNER),
        ],
        foods,
    )
    assert plan.day_totals["protein_g"] == pytest.approx(34.35 + 5.4)
    assert plan.meal_slot_totals[MealSlot.DINNER]["protein_g"] == pytest.approx(5.4)


def test_order_index_is_reassigned_so_the_model_cannot_reorder_the_plan(foods) -> None:
    plan = CP.recompute_plan_items(
        [_proposed(order_index=9), _proposed(food_id="f_rice", order_index=9)], foods
    )
    assert [item.order_index for item in plan.items] == [0, 1]


def test_why_text_mentions_the_gap_it_closes(foods) -> None:
    gaps = [NutrientGap(nutrient="iron_mg", target=19.0, current=13.0, unit="mg")]
    plan = CP.recompute_plan_items([_proposed(grams=100.0)], foods, gaps=gaps)
    assert "iron gap" in plan.items[0].why_text

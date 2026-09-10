"""Which plan items need a method, and what a generated method may say.

Two modules, one file, because they answer the two halves of one question: should we ask a
model at all, and is what came back usable.

The owner's own example runs through the first half:

    "something like sunflower seeds, he can directly buy it from the store, so there is no
    preparation for it."
"""

from __future__ import annotations

import pytest

from app.domain.enums import Escalation
from app.rules import recipe_readiness as readiness
from app.rules import recipe_text_rails as rails
from app.rules.recipe_readiness import PreparationNeed
from app.safety.validator import validate


def need(name: str, group: str | None, local: str | None = None) -> PreparationNeed:
    return readiness.assess(food_group=group, name=name, name_local=local).need


# ------------------------------------------------------------------- nothing to cook


def test_the_owners_own_example_needs_no_recipe():
    assert need("Sunflower seed", "nut_seed", "Surajmukhi beej") is PreparationNeed.NONE


@pytest.mark.parametrize(
    ("name", "group"),
    [
        ("Almond", "nut_seed"),
        ("Groundnut", "nut_seed"),
        ("Banana", "fruit"),
        ("Guava", "fruit"),
        ("Dates, dried", "fruit"),
    ],
)
def test_nuts_seeds_and_fruit_are_eaten_as_they_come(name: str, group: str):
    assert need(name, group) is PreparationNeed.NONE


def test_milk_and_curd_need_nothing_whatever_group_they_sit_in():
    assert need("Toned milk", "dairy") is PreparationNeed.NONE
    assert need("Curd (dahi)", "dairy") is PreparationNeed.NONE


def test_a_ready_to_eat_answer_carries_the_sentence_that_explains_it():
    result = readiness.assess(food_group="nut_seed", name="Sunflower seed")
    assert result.wants_a_method is False
    assert "eaten as it comes" in result.note


# ---------------------------------------------------------------- not a dish at all


@pytest.mark.parametrize(("name", "group"), [("Groundnut oil", "oil_fat"), ("Jaggery", "sugar_sweetener")])
def test_a_cooking_ingredient_is_not_given_a_recipe_of_its_own(name: str, group: str):
    result = readiness.assess(food_group=group, name=name)
    assert result.need is PreparationNeed.INGREDIENT
    assert "ingredient rather than a dish" in result.note


# ------------------------------------------------------------------- needs a method


@pytest.mark.parametrize(
    ("name", "group"),
    [
        ("Rajma", "pulse_legume"),
        ("Rice, raw milled", "cereal_millet"),
        ("Spinach", "leafy_vegetable"),
        ("Egg, hen", "egg"),
    ],
)
def test_everything_else_gets_a_method(name: str, group: str):
    assert need(name, group) is PreparationNeed.METHOD


def test_an_unknown_food_group_falls_through_to_a_method():
    """The safe direction: a wasted call beats somebody staring at a dish they cannot
    cook."""
    assert need("Something new", None) is PreparationNeed.METHOD
    assert need("Something new", "not_a_group") is PreparationNeed.METHOD


def test_raw_jackfruit_is_a_dish_even_though_jackfruit_is_fruit():
    assert need("Jackfruit, raw", "fruit") is PreparationNeed.METHOD
    assert need("Coconut, dry (copra)", "nut_seed") is PreparationNeed.METHOD


def test_a_dish_whose_name_merely_contains_a_ready_word_is_not_caught():
    """"Milk" as a whole word means milk. "Buttermilk kadhi" is a dish."""
    assert need("Kadhi", "pulse_legume") is PreparationNeed.METHOD


def test_the_curated_sentences_pass_the_safety_validator():
    for text in (readiness.READY_TO_EAT_NOTE, readiness.INGREDIENT_NOTE):
        assert not validate(text, Escalation.ROUTINE).findings


# ---------------------------------------------------------------- what a recipe says


GOOD_RECIPE = (
    "Rajma\nOnion\nTomato\nGinger\nGarlic\n"
    "Soak the rajma overnight in plenty of water.\n"
    "Drain it, cover with fresh water and pressure cook until soft.\n"
    "Fry the onion in a little oil until it turns golden, then add the ginger and garlic.\n"
    "Stir in the tomato and cook it down, then add the rajma with its water.\n"
    "Simmer for twenty minutes and season with salt to taste."
)


def rules_for(text: str) -> set[str]:
    return {finding.rule for finding in rails.check_recipe_text(text)}


def test_a_method_with_no_amounts_in_it_passes():
    assert rails.check_recipe_text(GOOD_RECIPE) == []


@pytest.mark.parametrize(
    "text",
    [
        "Add 1 cup of rice.",
        "Stir in 2 tbsp ghee.",
        "Use 200 g of rajma.",
        "Pour in 500 ml water.",
        "Add a teaspoon of salt.",
        "Serve one katori.",
    ],
)
def test_any_weight_or_measure_is_refused(text: str):
    """This is the whole consistency guarantee: a recipe that carries no amounts cannot
    contradict the plan's arithmetic, because it makes no claim about quantity at all."""
    assert "measurement" in rules_for(text)


def test_a_cooking_time_is_not_a_measurement():
    assert rails.check_recipe_text("Simmer for 20 minutes, then rest it for 5.") == []


@pytest.mark.parametrize(
    "text",
    [
        "This gives you plenty of protein.",
        "Rajma is rich in fibre.",
        "Good for hair growth.",
        "A great immunity booster.",
        "Low in calories and high in taste.",
    ],
)
def test_a_health_claim_or_a_nutrient_word_is_refused(text: str):
    assert rules_for(text) & {"nutrient_word", "health_claim"}


@pytest.mark.parametrize(
    "text",
    ["Add a calcium supplement to the milk.", "Crush a tablet into it.", "Take it with your syrup."],
)
def test_a_medicine_or_supplement_word_is_refused(text: str):
    assert rules_for(text) & {"medicine_word", "nutrient_word"}


def test_ordinary_kitchen_language_survives_the_rails():
    """A rail that rejects real instructions costs the reader a recipe for nothing."""
    for text in (
        "Heat a cast iron kadhai until a drop of water skitters across it.",
        "Trim the fat from the edge before you start.",
        "Add a few drops of lemon juice at the end.",
        "Season with salt to taste and a pinch of asafoetida.",
        "Grill it on a low flame, turning once.",
    ):
        assert rails.check_recipe_text(text) == [], text


def test_empty_recipe_text_is_a_finding():
    assert rules_for("") == {"empty"}


def test_the_feedback_tells_the_model_how_to_say_amounts_instead():
    findings = rails.check_recipe_text("Add 2 tbsp oil for extra protein.")
    feedback = rails.feedback_for(findings)
    assert "no weights" in feedback.lower()
    assert "salt to taste" in feedback
    for finding in findings:
        assert finding.rule in feedback

"""Recipes over HTTP: how to make it, how much to have, and when not to bother.

The four things worth proving:

1. **Some items need no recipe.** The owner's own example -- sunflower seeds -- costs no
   model call and still answers "how much".
2. **The portion is the plan's number**, read off the stored row, never sent by the client.
3. **A method is generated once and stored.** The second person to open rajma waits for a
   row, not for a model.
4. **A method that carries amounts never reaches anybody**, because amounts in a recipe
   would contradict the nutrition the plan computed from the ``foods`` table.
"""

from __future__ import annotations

from datetime import date

import pytest

from app.api import recipes as recipes_api
from app.api.guarded import GuardedText
from tests.api.conftest import consented, request
from tests.conftest import USER_ID

TODAY = date.today()

GOOD_RECIPE = {
    "ingredients": ["Rajma", "Onion", "Tomato", "Ginger", "Garlic"],
    "steps": [
        "Soak the rajma overnight in plenty of water.",
        "Drain it, cover with fresh water and pressure cook until soft.",
        "Fry the onion in a little oil until golden, then add the ginger and garlic.",
        "Stir in the tomato, cook it down, then add the rajma with its water.",
        "Simmer for twenty minutes and season with salt to taste.",
    ],
    "prep_minutes": 45,
}

RECIPE_WITH_AMOUNTS = {
    "ingredients": ["Rajma", "Ghee"],
    "steps": ["Soak 200 g of rajma overnight.", "Add 2 tbsp ghee for extra protein."],
    "prep_minutes": 45,
}

UNSAFE_RECIPE = {
    "ingredients": ["Rajma"],
    "steps": ["Simmer it gently.", "Take metformin 500 mg afterwards and stop your tablets."],
    "prep_minutes": 30,
}


@pytest.fixture
def wired(app):
    app.include_router(recipes_api.router)
    return app


def seed_food(store, name: str, group: str, local: str | None = None) -> str:
    store.seed(
        "foods",
        [
            {
                "name": name,
                "name_local": local,
                "food_group": group,
                "per_100g": {"kcal": 100},
                "diet_flags": ["veg"],
                "allergens": [],
                "source": "PROVISIONAL",
                "source_id": name.lower().replace(" ", "_"),
            }
        ],
    )
    return str(store.rows("foods")[-1]["id"])


def seed_plan_with(store, food_id: str, grams: float = 150.0, on: date = TODAY) -> str:
    store.seed(
        "meal_plans",
        [
            {
                "user_id": USER_ID,
                "plan_date": on.isoformat(),
                "model": "gemini-2.5-flash",
                "rationale": "A steady day built around foods you already like.",
                "status": "active",
            }
        ],
    )
    plan_id = str(store.rows("meal_plans")[-1]["id"])
    store.seed(
        "meal_plan_items",
        [
            {
                "meal_plan_id": plan_id,
                "meal_slot": "lunch",
                "food_id": food_id,
                "recipe_id": None,
                "grams": grams,
                "computed_nutrients": {"kcal": 150},
                "why_text": "Chosen for the fibre in it.",
                "order_index": 0,
            }
        ],
    )
    return str(store.rows("meal_plan_items")[-1]["id"])


def get(client, auth, item_id: str, **query):
    return request(
        client, "GET", f"/v1/recipes/plan-items/{item_id}", headers=auth, params=query
    )


# ------------------------------------------------------------- nothing to make at all


def test_sunflower_seeds_need_no_recipe_and_cost_no_model_call(
    wired, client, auth, store, gemini
):
    """The owner's own example, end to end."""
    food_id = seed_food(store, "Sunflower seed", "nut_seed", "Surajmukhi beej")
    item_id = seed_plan_with(store, food_id, grams=30)

    body = get(client, auth, item_id).json()

    assert body["preparation"] == "none"
    assert body["steps"] == []
    assert "eaten as it comes" in body["note"]
    assert gemini.calls == [], "a handful of seeds must not cost a model call"
    # And the half of the question that always has an answer is still answered.
    assert body["portion_grams"] == 30
    assert "30 g of sunflower seed" in body["portion_line"]


def test_an_oil_is_an_ingredient_rather_than_a_dish(wired, client, auth, store, gemini):
    food_id = seed_food(store, "Groundnut oil", "oil_fat")
    item_id = seed_plan_with(store, food_id, grams=5)

    body = get(client, auth, item_id).json()
    assert body["preparation"] == "ingredient"
    assert "ingredient rather than a dish" in body["note"]
    assert gemini.calls == []


# ----------------------------------------------------------------------- the method


def test_a_dish_gets_a_method_and_the_numbers_stay_the_plans(
    wired, client, auth, store, gemini
):
    food_id = seed_food(store, "Rajma", "pulse_legume")
    item_id = seed_plan_with(store, food_id, grams=150)
    gemini.queue(GOOD_RECIPE)

    body = get(client, auth, item_id).json()

    assert body["preparation"] == "method"
    assert body["steps"][0].startswith("Soak the rajma")
    assert body["ingredients"][0] == "Rajma"
    assert body["prep_minutes"] == 45
    assert body["generated"] is True

    # The one quantity on the screen is the plan's own, and the screen says so.
    assert body["portion_grams"] == 150
    assert "150 g of rajma" in body["portion_line"]
    assert "no weights of its own" in body["amounts_note"]
    # And nothing in the method restates a quantity that could disagree with it.
    for line in body["steps"] + body["ingredients"]:
        assert " g " not in f" {line} "
        assert "cup" not in line.lower()


def test_the_recipe_prompt_is_given_the_dish_and_nothing_about_the_person(
    wired, client, auth, store, gemini
):
    food_id = seed_food(store, "Rajma", "pulse_legume")
    item_id = seed_plan_with(store, food_id)
    gemini.queue(GOOD_RECIPE)
    get(client, auth, item_id)

    prompt = str(gemini.calls[0]["parts"])
    assert "Dish: Rajma" in prompt
    assert "no amounts anywhere" in prompt
    assert gemini.calls[0]["task"] == "recipe_method"


def test_the_portion_comes_off_the_plan_row_and_not_off_the_request(
    wired, client, auth, store, gemini
):
    food_id = seed_food(store, "Rajma", "pulse_legume")
    item_id = seed_plan_with(store, food_id, grams=180)
    gemini.queue(GOOD_RECIPE)

    # Anything extra on the query string is ignored: there is no parameter that becomes
    # a quantity, which is the point.
    body = get(client, auth, item_id, grams="9999").json()
    assert body["portion_grams"] == 180
    assert "9,999" not in body["portion_line"]


# ------------------------------------------------------------------------ the store


def test_a_dish_is_generated_once_and_read_thereafter(wired, client, auth, store, gemini):
    food_id = seed_food(store, "Rajma", "pulse_legume")
    first_item = seed_plan_with(store, food_id, on=TODAY)
    gemini.queue(GOOD_RECIPE)

    first = get(client, auth, first_item).json()
    second = get(client, auth, first_item).json()

    assert len(gemini.calls) == 1, "a recipe is the same recipe every time it is opened"
    assert first["stored"] is False
    assert second["stored"] is True
    assert second["generated"] is False
    assert second["steps"] == first["steps"]


def test_refresh_writes_the_method_again(wired, client, auth, store, gemini):
    consented(store)
    food_id = seed_food(store, "Rajma", "pulse_legume")
    item_id = seed_plan_with(store, food_id)
    gemini.queue(GOOD_RECIPE)
    get(client, auth, item_id)

    gemini.queue(GOOD_RECIPE)
    response = request(
        client, "POST", f"/v1/recipes/plan-items/{item_id}/refresh", headers=auth
    )
    assert response.status_code == 200, response.text
    assert response.json()["stored"] is False
    assert len(gemini.calls) == 2


def test_refresh_needs_consent(wired, client, auth, store):
    food_id = seed_food(store, "Rajma", "pulse_legume")
    item_id = seed_plan_with(store, food_id)
    response = request(
        client, "POST", f"/v1/recipes/plan-items/{item_id}/refresh", headers=auth
    )
    assert response.status_code == 403


# ------------------------------------------------------------------------ the rails


def test_a_method_carrying_amounts_is_rewritten_before_it_is_stored(
    wired, client, auth, store, gemini
):
    food_id = seed_food(store, "Rajma", "pulse_legume")
    item_id = seed_plan_with(store, food_id)
    gemini.queue(RECIPE_WITH_AMOUNTS)
    gemini.queue(GOOD_RECIPE)

    body = get(client, auth, item_id).json()

    assert len(gemini.calls) == 2
    assert body["steps"][0].startswith("Soak the rajma")
    feedback = str(gemini.calls[1]["parts"])
    assert "measurement" in feedback
    assert "no weights" in feedback.lower()


def test_a_method_that_keeps_carrying_amounts_is_not_shown_at_all(
    wired, client, auth, store, gemini
):
    food_id = seed_food(store, "Rajma", "pulse_legume")
    item_id = seed_plan_with(store, food_id)
    gemini.queue(RECIPE_WITH_AMOUNTS)
    gemini.queue(RECIPE_WITH_AMOUNTS)

    body = get(client, auth, item_id).json()

    assert body["steps"] == []
    assert "do not have a method for this one yet" in body["note"]
    assert "2 tbsp" not in repr(body)
    stored = [
        row for row in store.rows("health_events")
        if row.get("event_type") == "recipe_method_stored"
    ]
    assert stored == [], "a rejected method must not be stored either"


def test_an_unsafe_method_is_replaced_rather_than_repaired(wired, client, auth, store, gemini):
    food_id = seed_food(store, "Rajma", "pulse_legume")
    item_id = seed_plan_with(store, food_id)
    gemini.queue(UNSAFE_RECIPE)
    gemini.queue(UNSAFE_RECIPE)

    body = get(client, auth, item_id).json()

    assert body["steps"] == []
    assert "metformin" not in repr(body).lower()


def test_no_model_configured_is_an_honest_gap_rather_than_an_empty_recipe(
    wired, client, auth, store, app
):
    food_id = seed_food(store, "Rajma", "pulse_legume")
    item_id = seed_plan_with(store, food_id)
    app.state.gemini = None

    body = get(client, auth, item_id).json()
    assert body["steps"] == []
    assert "do not have a method" in body["note"]
    # The portion is still the plan's, because that never needed a model.
    assert body["portion_grams"] == 150


# ------------------------------------------------------------------------ addressing


def test_an_item_that_is_not_on_that_date_is_a_404(wired, client, auth, store, gemini):
    food_id = seed_food(store, "Rajma", "pulse_legume")
    seed_plan_with(store, food_id)
    response = get(client, auth, "11111111-1111-1111-1111-111111111111")
    assert response.status_code == 404


def test_a_date_with_no_plan_is_a_404(wired, client, auth, store):
    response = get(client, auth, "anything", on="2020-01-06")
    assert response.status_code == 404


# -------------------------------------------------------------------------- the type


def test_every_line_of_a_recipe_is_guarded(wired):
    from app.api.recipes import RecipeOut

    for name in ("ingredients", "steps"):
        annotation = RecipeOut.model_fields[name].annotation
        assert GuardedText in getattr(annotation, "__args__", ())
    assert RecipeOut.model_fields["portion_line"].annotation is GuardedText

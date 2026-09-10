"""The grocery list's memory: what the kitchen already holds, and what that takes off.

The behaviours worth protecting, and why each one is here:

* the quantities genuinely come down -- a line says how much is held and how much is
  still to bring, and the two add up to what the week needs;
* the memory is not on the list. A rebuild deletes and reinserts every ``grocery_items``
  row, so a tick that lived there would not survive one; these tests rebuild on purpose
  and check the tick is still there afterwards;
* a claim fades. "I have rice" made five days ago is worth half of what it was worth on
  the day, because this week's plan has been cooking it;
* buying something does not stock the cupboard, because this week's meals will eat it;
* an empty list says how many days were planned behind it, so the screen does not have
  to guess which kind of empty it is.
"""

from __future__ import annotations

from datetime import UTC, date, datetime, time, timedelta

import pytest

from app.domain.enums import MealSlot
from app.domain.models import MealPlanItem
from app.planner.grocery import (
    DEFAULT_SHELF_LIFE_DAYS,
    SHELF_LIFE_DAYS,
    build_lines,
    pantry_credit,
    split_requirement,
)
from app.repositories.plans import week_start_for
from tests.api.conftest import request
from tests.conftest import USER_ID

MONDAY = week_start_for(date.today())


# ------------------------------------------------------------------------ the store


def seed_food(store, name: str, group: str) -> str:
    store.seed("foods", [{"name": name, "food_group": group, "per_100g": {}}])
    return store.rows("foods")[-1]["id"]


def seed_plan(store, food_id: str, grams: float, *, day: date = MONDAY) -> None:
    """One planned meal, so the list has something to add up."""
    store.seed("meal_plans", [{"user_id": USER_ID, "plan_date": day.isoformat()}])
    plan_id = store.rows("meal_plans")[-1]["id"]
    store.seed(
        "meal_plan_items",
        [{"meal_plan_id": plan_id, "meal_slot": "lunch", "food_id": food_id, "grams": grams}],
    )


def seed_pantry(store, food_id: str, grams: float, *, days_ago: int = 0, unit: str = "g") -> None:
    """A claim made ``days_ago`` days back, dated from the calendar day the endpoint
    ages it against.

    Built from ``date.today()`` rather than by subtracting from ``datetime.now(UTC)``:
    the decay counts whole days between the row's date and today, so on a machine whose
    local day is not the UTC day, subtracting a duration would land one day either side
    and the arithmetic these tests assert would be off by a day.
    """
    stated_on = datetime.combine(date.today() - timedelta(days=days_ago), time(12, 0), tzinfo=UTC)
    store.seed(
        "pantry_items",
        [
            {
                "user_id": USER_ID,
                "food_id": food_id,
                "quantity": grams,
                "unit": unit,
                "updated_at": stated_on.isoformat(),
            }
        ],
    )


def get_list(client, auth, *, rebuild: bool = False) -> dict:
    url = "/v1/grocery?rebuild=true" if rebuild else "/v1/grocery"
    response = request(client, "GET", url, headers=auth)
    assert response.status_code == 200, response.text
    return response.json()


def only_item(body: dict) -> dict:
    assert len(body["items"]) == 1, body["items"]
    return body["items"][0]


def patch_state(client, auth, item_id: str, state: str) -> dict:
    response = request(
        client, "PATCH", f"/v1/grocery/items/{item_id}", headers=auth, json={"state": state}
    )
    assert response.status_code == 200, response.text
    return response.json()


# -------------------------------------------------------------- the arithmetic itself


def test_what_is_held_comes_off_what_is_bought(client, auth, store):
    """1 000 g planned, 1 100 g needed with the buffer, 400 g at home: bring 700 g."""
    food_id = seed_food(store, "Ragi flour", "cereal_millet")
    seed_plan(store, food_id, 1000)
    seed_pantry(store, food_id, 400)

    item = only_item(get_list(client, auth))

    assert item["have"] == pytest.approx(400.0)
    assert item["quantity"] == pytest.approx(700.0)
    # The two halves are the whole week's requirement, so nothing has gone missing in
    # the subtraction.
    assert item["have"] + item["quantity"] == pytest.approx(1100.0)
    assert item["state"] == "need"


def test_a_line_the_kitchen_covers_is_still_shown(client, auth, store):
    """Nothing to bring, but the line stays -- there has to be something to untick."""
    food_id = seed_food(store, "Groundnut oil", "oil_fat")
    seed_plan(store, food_id, 200)
    seed_pantry(store, food_id, 1000)

    item = only_item(get_list(client, auth))

    assert item["quantity"] == pytest.approx(0.0)
    assert item["have"] == pytest.approx(220.0)  # capped at the requirement, not 1 000 g
    assert item["state"] == "have"


def test_a_claim_fades_with_the_days(client, auth, store):
    """400 g of a ten-day food, claimed five days ago, is believed as 200 g."""
    food_id = seed_food(store, "Brown rice", "cereal_millet")
    seed_plan(store, food_id, 1000)
    seed_pantry(store, food_id, 400, days_ago=5)

    item = only_item(get_list(client, auth))

    assert SHELF_LIFE_DAYS["cereal_millet"] == 10
    assert item["have"] == pytest.approx(200.0)
    assert item["quantity"] == pytest.approx(900.0)


def test_a_perishable_claim_is_gone_within_the_week(client, auth, store):
    """Spinach said to be in the fridge three days ago buys nothing today."""
    food_id = seed_food(store, "Spinach", "leafy_vegetable")
    seed_plan(store, food_id, 500)
    seed_pantry(store, food_id, 500, days_ago=3)

    item = only_item(get_list(client, auth))

    assert item["have"] == pytest.approx(0.0)
    assert item["quantity"] == pytest.approx(550.0)


def test_a_pantry_row_in_another_unit_is_not_guessed_at(client, auth, store):
    food_id = seed_food(store, "Milk", "dairy")
    seed_plan(store, food_id, 500)
    seed_pantry(store, food_id, 500, unit="ml")

    item = only_item(get_list(client, auth))

    assert item["have"] == pytest.approx(0.0)
    assert item["quantity"] == pytest.approx(550.0)


# ------------------------------------------------------- the memory survives a rebuild


def test_ticking_have_writes_the_pantry_and_outlives_a_rebuild(client, auth, store):
    food_id = seed_food(store, "Toor dal", "pulse_legume")
    seed_plan(store, food_id, 600)

    item = only_item(get_list(client, auth))
    assert item["quantity"] == pytest.approx(660.0)

    saved = patch_state(client, auth, item["id"], "have")
    assert saved["quantity"] == pytest.approx(0.0)
    assert saved["have"] == pytest.approx(660.0)

    # The claim is on `pantry_items`, keyed to the food, not on the list row.
    pantry = store.rows("pantry_items")
    assert len(pantry) == 1
    assert pantry[0]["food_id"] == food_id
    assert float(pantry[0]["quantity"]) == pytest.approx(660.0)

    # A rebuild deletes and reinserts every row at `need`. The tick is still there
    # afterwards because it was never kept on the row that was deleted.
    rebuilt = only_item(get_list(client, auth, rebuild=True))
    assert rebuilt["state"] == "have"
    assert rebuilt["quantity"] == pytest.approx(0.0)
    assert rebuilt["have"] == pytest.approx(660.0)


def test_unticking_forgets_the_claim(client, auth, store):
    food_id = seed_food(store, "Toor dal", "pulse_legume")
    seed_plan(store, food_id, 600)
    seed_pantry(store, food_id, 660)

    item = only_item(get_list(client, auth))
    assert item["state"] == "have"

    saved = patch_state(client, auth, item["id"], "need")
    assert saved["quantity"] == pytest.approx(660.0)
    assert saved["have"] == pytest.approx(0.0)
    assert store.rows("pantry_items") == []

    back = only_item(get_list(client, auth, rebuild=True))
    assert back["state"] == "need"
    assert back["quantity"] == pytest.approx(660.0)


def test_a_stale_have_on_the_row_does_not_survive_an_empty_pantry(client, auth, store):
    """The row's state column is a copy. The pantry is the memory."""
    food_id = seed_food(store, "Ragi flour", "cereal_millet")
    store.seed("grocery_lists", [{"user_id": USER_ID, "week_start": MONDAY.isoformat()}])
    list_id = store.rows("grocery_lists")[0]["id"]
    store.seed(
        "grocery_items",
        [
            {
                "grocery_list_id": list_id,
                "food_id": food_id,
                "quantity": 500,
                "unit": "g",
                "aisle": "cereal_millet",
                "state": "have",
            }
        ],
    )

    item = only_item(get_list(client, auth))

    assert item["state"] == "need"
    assert item["quantity"] == pytest.approx(500.0)


# ------------------------------------------------------------------------- buying it


def test_buying_does_not_stock_the_cupboard(client, auth, store):
    """What was bought for this week is what this week eats. It is not next week's."""
    food_id = seed_food(store, "Brown rice", "cereal_millet")
    seed_plan(store, food_id, 1000)

    item = only_item(get_list(client, auth))
    saved = patch_state(client, auth, item["id"], "bought")

    assert saved["state"] == "bought"
    assert store.rows("pantry_items") == []
    # It is remembered in the append-only trail instead, beside meal logs and progress.
    events = [row for row in store.rows("health_events") if row["event_type"] == "grocery_bought"]
    assert len(events) == 1
    assert events[0]["payload"]["food_id"] == food_id
    assert events[0]["payload"]["week_start"] == MONDAY.isoformat()


def test_bought_survives_a_rebuild_through_the_event_trail(client, auth, store):
    food_id = seed_food(store, "Brown rice", "cereal_millet")
    seed_plan(store, food_id, 1000)

    item = only_item(get_list(client, auth))
    patch_state(client, auth, item["id"], "bought")

    rebuilt = only_item(get_list(client, auth, rebuild=True))
    assert rebuilt["state"] == "bought"


# -------------------------------------------------------------- how much was planned


def test_the_list_says_how_many_days_are_behind_it(client, auth, store):
    food_id = seed_food(store, "Ragi flour", "cereal_millet")
    seed_plan(store, food_id, 400, day=MONDAY)
    seed_plan(store, food_id, 400, day=MONDAY + timedelta(days=1))

    body = get_list(client, auth)

    assert body["planned_days"] == 2


def test_an_empty_week_says_nothing_was_planned(client, auth, store):
    body = get_list(client, auth)

    assert body["items"] == []
    assert body["planned_days"] == 0


def test_a_plain_read_does_not_count_the_days_again(client, auth, store):
    """Null, not a guess: counting costs seven queries and only the empty case needs it."""
    food_id = seed_food(store, "Ragi flour", "cereal_millet")
    seed_plan(store, food_id, 400)

    assert get_list(client, auth)["planned_days"] == 1
    assert get_list(client, auth)["planned_days"] is None


# ------------------------------------------------------------------ the pure functions


def test_the_split_never_leaves_a_two_gram_errand():
    assert split_requirement(1100.0, 400.0) == (700.0, 400.0)
    assert split_requirement(1100.0, 1098.0) == (0.0, 1100.0)
    assert split_requirement(1100.0, 5000.0) == (0.0, 1100.0)
    assert split_requirement(1100.0, -5.0) == (1100.0, 0.0)


def test_a_covered_line_is_kept_only_when_the_caller_asks_for_it():
    items = [
        MealPlanItem(
            meal_slot=MealSlot.LUNCH, food_id="a", display_name="a", grams=100.0, why_text="x"
        )
    ]
    aisles = {"a": "cereal_millet"}

    # The old contract: a food the kitchen covers is simply not on the shop.
    assert build_lines(items, aisles, pantry={"a": 200.0}) == []

    # What the endpoint asks for instead: the line stays, with nothing to bring, so it
    # can be unticked when the jar turns out to be empty.
    kept = build_lines(items, aisles, pantry={"a": 200.0}, keep_covered=True)
    assert len(kept) == 1
    assert kept[0].quantity == pytest.approx(0.0)
    assert kept[0].have == pytest.approx(110.0)
    assert kept[0].required == pytest.approx(110.0)
    assert kept[0].as_row()["quantity"] == pytest.approx(110.0)  # the row keeps > 0
    assert kept[0].as_row()["state"] == "have"


def test_a_claim_decays_to_nothing_at_the_end_of_its_shelf_life():
    today = date(2026, 9, 10)
    rows = [
        {"food_id": "rice", "quantity": 1000.0, "unit": "g", "updated_at": "2026-09-05T08:00:00Z"},
        {"food_id": "oil", "quantity": 900.0, "unit": "g", "updated_at": "2026-09-03T08:00:00Z"},
        {"food_id": "palak", "quantity": 300.0, "unit": "g", "updated_at": "2026-09-07T08:00:00Z"},
    ]
    groups = {"rice": "cereal_millet", "oil": "oil_fat", "palak": "leafy_vegetable"}

    credit = pantry_credit(rows, groups=groups, today=today)

    assert credit["rice"] == pytest.approx(500.0)  # five days of ten
    assert credit["oil"] == pytest.approx(900.0 * (1 - 7 / 21))  # a week of three
    assert "palak" not in credit  # three days of three: gone


def test_an_undated_or_future_claim_is_handled_without_inventing_one():
    today = date(2026, 9, 10)
    rows = [
        {"food_id": "a", "quantity": 500.0, "unit": "g", "updated_at": ""},
        {"food_id": "b", "quantity": 500.0, "unit": "g", "updated_at": "2026-09-12T08:00:00Z"},
    ]
    credit = pantry_credit(rows, groups={}, today=today)

    # No date, no age, no credit.
    assert "a" not in credit
    # A clock ahead of ours is not a reason to believe more than was claimed.
    assert credit["b"] == pytest.approx(500.0)
    assert DEFAULT_SHELF_LIFE_DAYS == 5

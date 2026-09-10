"""The goals a person picked, the answers that were being dropped, and an alert
rewrite that used to take other people's alerts with it.

Four separate holes, one seam. They are tested together because they are all the same
failure in different clothes: something the user told the app, thrown away by the layer
underneath without anybody being told.

The test that matters most is the first one. Everything else here asserts a round-trip;
that one follows the owner's three goals all the way from ``PUT /v1/me/profile`` to the
characters in the prompt the planner sends, because a goals column nobody reads would
round-trip perfectly and still change nothing about any meal.
"""

from __future__ import annotations

from datetime import time
from typing import Any

import pytest

from app.domain.enums import AlertType
from app.domain.models import ScheduledAlert
from app.repositories.base import Credentials
from app.repositories.plans import AlertRepository
from tests.api.conftest import FakePostgrest, consented, problem, request
from tests.conftest import USER_ID

#: A Wednesday. ``derive_alerts`` only emits the grocery reminder on a Saturday, so this
#: is the day the old rewrite silently deleted it on.
WEDNESDAY = "2026-09-09"

PROFILE: dict[str, Any] = {
    "dob": "1994-03-02",
    "sex": "male",
    "height_cm": 172,
    "weight_kg": 74,
    "activity_level": "moderate",
    "diet_type": "non_veg",
    "wake_time": "06:30",
    "sleep_time": "22:30",
}


def seed_profile_row(store) -> None:
    """A saved profile, so the planner has someone to plan for."""
    store.seed(
        "health_profiles",
        [
            {
                "user_id": USER_ID,
                "dob": "1994-03-02",
                "sex": "male",
                "height_cm": 172,
                "weight_kg": 74,
                "activity_level": "moderate",
                "diet_type": "non_veg",
                "cuisine_pref": [],
                "conditions": [],
                "meal_times": {},
                "pregnancy": False,
            }
        ],
    )


def seed_foods(store) -> list[str]:
    store.seed(
        "foods",
        [
            {
                "name": "Ragi",
                "food_group": "Millets",
                "region": "south",
                "per_100g": {"kcal": 328, "protein_g": 7.3, "iron_mg": 3.9, "fibre_g": 11.5},
                "diet_flags": ["veg", "vegan"],
                "allergens": [],
                "source": "IFCT2017",
            }
        ],
    )
    return [row["id"] for row in store.rows("foods")]


def save_profile(client, auth, **overrides: Any):
    return request(
        client, "PUT", "/v1/me/profile", headers=auth, json={**PROFILE, **overrides}
    )


def goal_rows(store) -> list[dict[str, Any]]:
    return store.rows("goals")


# ------------------------------------------------------- goals reach the planner


def test_the_goals_he_picked_are_in_the_prompt_the_planner_sends(
    client, auth, store, gemini
):
    """weight, skin and hair, from the wizard to the model, in the order he tapped them.

    ``app/ai/context.py`` has printed a GOALS line since it was written. Nothing ever
    put a row in ``goals`` for it to print, so the line was never emitted once.
    """
    consented(store)
    food_ids = seed_foods(store)

    saved = save_profile(
        client, auth, goal_types=["weight", "skin", "hair"]
    )
    assert saved.status_code == 200, saved.text
    assert saved.json()["goal_types"] == ["weight", "skin", "hair"]

    gemini.queue(
        {
            "items": [
                {
                    "meal_slot": "breakfast",
                    "food_id": food_ids[0],
                    "grams": 100,
                    "why": "iron",
                    "order_index": 0,
                }
            ],
            "hydration_ml": 2000,
            "rationale": "Built around ragi.",
        }
    )
    planned = request(
        client, "POST", "/v1/plan/regenerate", headers=auth, json={"plan_date": WEDNESDAY}
    )
    assert planned.status_code == 200, planned.text

    prompt = str(gemini.calls[0]["parts"])
    goal_line = next(
        (line for line in prompt.splitlines() if line.startswith("GOALS")), None
    )
    assert goal_line is not None, "the GOALS section was empty again"
    assert "1 Weight" in goal_line
    assert "2 Skin" in goal_line
    assert "3 Hair" in goal_line
    # The order he chose, not alphabetical and not insertion order by accident.
    assert goal_line.index("Weight") < goal_line.index("Skin") < goal_line.index("Hair")


def test_goals_come_back_on_the_profile_the_app_reads(client, auth, store):
    consented(store)
    save_profile(client, auth, goal_types=["sleep", "energy"])

    read = request(client, "GET", "/v1/me/profile", headers=auth)
    assert read.status_code == 200
    assert read.json()["goal_types"] == ["sleep", "energy"]


def test_dropping_a_goal_closes_its_row_and_keeps_the_history(client, auth, store):
    consented(store)
    save_profile(client, auth, goal_types=["weight", "hair"])
    save_profile(client, auth, goal_types=["weight"])

    read = request(client, "GET", "/v1/me/profile", headers=auth)
    assert read.json()["goal_types"] == ["weight"]

    by_type = {str(row["goal_type"]): row for row in goal_rows(store)}
    assert set(by_type) == {"weight", "hair"}, "the dropped goal was deleted outright"
    assert by_type["hair"]["status"] == "closed"
    assert by_type["hair"]["closed_at"]


def test_picking_a_goal_up_again_reopens_the_row_it_had(client, auth, store):
    consented(store)
    save_profile(client, auth, goal_types=["hair"])
    original = str(goal_rows(store)[0]["id"])

    save_profile(client, auth, goal_types=[])
    save_profile(client, auth, goal_types=["hair"])

    rows = goal_rows(store)
    assert len(rows) == 1, "a second row was started for the same goal"
    assert str(rows[0]["id"]) == original
    assert rows[0]["status"] == "active"


def test_a_title_somebody_wrote_is_not_overwritten_by_a_profile_save(
    client, auth, store
):
    """``goals.title`` is the string the prompt prints. If the chat pipeline learns a
    real one -- "lose 5 kg before the wedding" -- a profile save must not flatten it back
    to the name of the chip."""
    consented(store)
    store.seed(
        "goals",
        [
            {
                "user_id": USER_ID,
                "goal_type": "weight",
                "title": "Lose 5 kg before December",
                "priority": "1",
                "status": "active",
            }
        ],
    )
    save_profile(client, auth, goal_types=["weight", "skin"])

    by_type = {str(row["goal_type"]): row for row in goal_rows(store)}
    assert by_type["weight"]["title"] == "Lose 5 kg before December"
    assert by_type["skin"]["title"] == "Skin"


def test_saving_the_same_goals_twice_does_not_make_a_second_set(client, auth, store):
    consented(store)
    save_profile(client, auth, goal_types=["weight", "skin", "hair"])
    save_profile(client, auth, goal_types=["weight", "skin", "hair"])

    assert len(goal_rows(store)) == 3
    assert all(row["status"] == "active" for row in goal_rows(store))


def test_a_goal_the_schema_cannot_store_is_refused_at_the_edge(client, auth, store):
    """``GoalType`` has a member ``goals_goal_type_check`` does not list.

    A 422 naming the field is what the app can act on. It is deliberately not the
    validator's own sentence: the error handler scrubs those so a server string never
    reaches a screen. Without this the write would reach Postgres and come back a 400
    from the middle of a save, with a saved profile and unsaved goals behind it.
    """
    consented(store)
    response = save_profile(client, auth, goal_types=["diet_quality"])
    assert response.status_code == 422
    body = problem(response)
    assert [e["field"] for e in body["errors"]] == ["goal_types"]
    assert not store.rows("goals")


# ----------------------------------------------------- the answers being dropped


def test_the_pin_code_survives_a_save(client, auth, store):
    consented(store)
    save_profile(client, auth, pincode="500081")

    read = request(client, "GET", "/v1/me/profile", headers=auth)
    assert read.json()["pincode"] == "500081"
    assert store.rows("health_profiles")[0]["pincode"] == "500081"


def test_a_blank_pin_code_reads_back_as_unset_not_as_an_empty_string(client, auth, store):
    consented(store)
    save_profile(client, auth, pincode="   ")
    assert request(client, "GET", "/v1/me/profile", headers=auth).json()["pincode"] is None


def test_a_chosen_water_target_round_trips_and_can_be_cleared(client, auth, store):
    """The field the hydration work reads. Carried, not judged."""
    consented(store)
    saved = save_profile(client, auth, hydration_target_override_ml=2600)
    assert saved.json()["hydration_target_override_ml"] == 2600
    assert request(
        client, "GET", "/v1/me/profile", headers=auth
    ).json()["hydration_target_override_ml"] == 2600

    # Omitted on the next save means "I have not chosen one", and PUT replaces.
    cleared = save_profile(client, auth)
    assert cleared.json()["hydration_target_override_ml"] is None
    assert store.rows("health_profiles")[0]["hydration_target_override_ml"] is None


def test_there_is_no_fourth_sex_the_backend_would_have_to_flatten(client, auth, store):
    """Male, female, another term. The app used to offer a fourth and send it as
    ``other``, so the answer changed under the person on the next screen."""
    consented(store)
    assert save_profile(client, auth, sex="prefer_not_to_say").status_code == 422
    assert save_profile(client, auth, sex="undisclosed").status_code == 422
    for value in ("male", "female", "other"):
        assert save_profile(client, auth, sex=value).json()["sex"] == value


def test_editing_one_answer_still_replaces_the_whole_profile(client, auth, store):
    """PUT replaces. This is the backend half of the app's own guarantee that changing
    the city does not delete an allergy: what is sent is what is stored, entire."""
    consented(store)
    save_profile(
        client,
        auth,
        city="Bengaluru",
        pincode="560001",
        goal_types=["energy"],
        allergies=[{"allergen": "peanut", "severity": "severe"}],
        conditions=["thyroid"],
    )
    again = save_profile(
        client,
        auth,
        city="Chennai",
        pincode="560001",
        goal_types=["energy"],
        allergies=[{"allergen": "peanut", "severity": "severe"}],
        conditions=["thyroid"],
    )
    body = again.json()
    assert body["city"] == "Chennai"
    assert body["pincode"] == "560001"
    assert body["goal_types"] == ["energy"]
    assert body["conditions"] == ["thyroid"]
    assert [a["allergen"] for a in body["allergies"]] == ["peanut"]


# ------------------------------------------------------------- the alert rewrite


def alert_repository(store) -> AlertRepository:
    client = FakePostgrest(
        store, Credentials(apikey="anon", bearer="token"), USER_ID
    )
    return AlertRepository(client, USER_ID)


def seed_alert(store, alert_type: str, at: str, *, enabled: bool = True) -> None:
    store.seed(
        "alerts",
        [
            {
                "user_id": USER_ID,
                "alert_type": alert_type,
                "title": alert_type.title(),
                "body": "…",
                "schedule_rule": at,
                "enabled": enabled,
                "quiet_hours": {},
            }
        ],
    )


def types_in(store) -> set[str]:
    return {str(row["alert_type"]) for row in store.rows("alerts")}


@pytest.mark.asyncio
async def test_a_rewrite_leaves_alone_the_types_it_did_not_derive(store):
    """The bug, in one assertion.

    ``derive_alerts`` emits the grocery reminder on a Saturday and on no other day, and
    the old rewrite deleted every row the user had before inserting what it derived. So
    generating a plan on a Wednesday deleted the grocery alert and nothing put it back.
    """
    seed_alert(store, "grocery", "10:00")
    seed_alert(store, "escalation", "09:00")
    seed_alert(store, "meal", "08:20")

    await alert_repository(store).replace(
        [
            ScheduledAlert(
                alert_type=AlertType.MEAL, title="Lunch time", body="…", at=time(13, 20)
            ),
            ScheduledAlert(
                alert_type=AlertType.HYDRATION, title="Water", body="…", at=time(9, 0)
            ),
        ]
    )

    assert "grocery" in types_in(store), "the grocery reminder was deleted again"
    assert "escalation" in types_in(store)
    # And the type it did derive was replaced, not added to.
    meals = [r for r in store.rows("alerts") if r["alert_type"] == "meal"]
    assert len(meals) == 1
    assert meals[0]["schedule_rule"] == "13:20"


@pytest.mark.asyncio
async def test_a_rewrite_that_derives_nothing_destroys_nothing(store):
    seed_alert(store, "grocery", "10:00")
    await alert_repository(store).replace([])
    assert types_in(store) == {"grocery"}


@pytest.mark.asyncio
async def test_a_type_the_user_switched_off_stays_off_through_a_rewrite(store):
    seed_alert(store, "hydration", "09:00", enabled=False)
    await alert_repository(store).replace(
        [
            ScheduledAlert(
                alert_type=AlertType.HYDRATION, title="Water", body="…", at=time(10, 0)
            )
        ]
    )
    rows = [r for r in store.rows("alerts") if r["alert_type"] == "hydration"]
    assert len(rows) == 1
    assert rows[0]["enabled"] is False


def test_a_weekday_plan_does_not_take_the_grocery_reminder_with_it(
    client, auth, store, gemini
):
    """The same thing again, through the real endpoint, because that is where it bit."""
    consented(store)
    seed_profile_row(store)
    food_ids = seed_foods(store)
    seed_alert(store, "grocery", "10:00")

    gemini.queue(
        {
            "items": [
                {
                    "meal_slot": "breakfast",
                    "food_id": food_ids[0],
                    "grams": 100,
                    "why": "iron",
                    "order_index": 0,
                }
            ],
            "hydration_ml": 2000,
            "rationale": "A simple day.",
        }
    )
    response = request(
        client, "POST", "/v1/plan/regenerate", headers=auth, json={"plan_date": WEDNESDAY}
    )
    assert response.status_code == 200, response.text

    listed = request(client, "GET", "/v1/alerts", headers=auth).json()["alerts"]
    kinds = {alert["alert_type"] for alert in listed}
    assert "grocery" in kinds, "planning on a Tuesday still deletes the Saturday list"
    assert "meal" in kinds
    assert "hydration" in kinds


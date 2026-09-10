"""The meal taste loop, over HTTP: rate it, change your mind, see what we believe.

The owner asked for one thing -- "did you enjoy it?", three answers, and for the AI to
take account of it next time. That is a loop, and a loop is only worth anything if every
part of it closes. So these tests follow the whole of it rather than each endpoint on its
own:

* a rating is stored, and **can be given again**, because correcting a mistap is the
  ordinary case and it used to be a 409;
* what the rating writes is exactly what the planner reads, proved by handing
  ``FoodLogRepository.preferences()`` -- the same call ``app.planner.context`` makes on
  line 97 -- straight to ``select_candidates``;
* the belief can be listed and corrected without inventing a meal to hang it on;
* and a meal we have no food row for says so, instead of claiming it learned something.
"""

from __future__ import annotations

from app.domain.enums import Stance
from app.nutrition.candidates import select_candidates
from app.repositories.base import Credentials
from app.repositories.plans import FoodLogRepository
from tests.api.conftest import FakePostgrest, problem, request, run
from tests.conftest import OTHER_USER_ID, USER_ID
from tests.nutrition.conftest import food as build_food
from tests.nutrition.conftest import profile


def seed_food(store, name: str = "Soya chunks") -> str:
    """One row in the reference table, and its id."""
    store.seed(
        "foods",
        [
            {
                "name": name,
                "food_group": "Pulses",
                "per_100g": {"kcal": 345.0, "protein_g": 52.0, "iron_mg": 20.0},
                "diet_flags": ["veg", "vegan"],
                "allergens": [],
            }
        ],
    )
    return store.rows("foods")[-1]["id"]


def log_meal(client, auth, *, food_id: str | None = None, free_text: str | None = None) -> str:
    body: dict[str, object] = {"meal_slot": "lunch", "source": "planned"}
    if food_id is not None:
        body["food_id"] = food_id
    if free_text is not None:
        body["free_text"] = free_text
    response = request(client, "POST", "/v1/feedback/meals", headers=auth, json=body)
    assert response.status_code == 201, response.text
    return response.json()["id"]


def rate(client, auth, log_id: str, rating: int):
    return request(
        client,
        "POST",
        f"/v1/feedback/meals/{log_id}/rating",
        headers=auth,
        json={"rating": rating},
    )


def food_logs_as_user(store) -> FoodLogRepository:
    """The repository the planner uses, over the same store, as the same user.

    Built here rather than reached through the app so that a test can call the exact
    method ``app.planner.context.assemble`` calls, without standing up a whole plan.
    """
    rest = FakePostgrest(store, Credentials(apikey="anon", bearer="user-token"), USER_ID)
    return FoodLogRepository(rest, USER_ID)


# ------------------------------------------------------------ changing your mind


def test_rating_the_same_meal_twice_is_a_correction_not_a_conflict(client, auth, store):
    """The bug that blocked the feature: a second rating used to be refused.

    ``uq_food_feedback_food_log`` is UNIQUE on ``food_log_id``, and ``rate`` inserted.
    So somebody who tapped "did not like it" by accident and immediately tapped "loved
    it" got a 409 and was stuck with the wrong answer for good.
    """
    food_id = seed_food(store)
    log_id = log_meal(client, auth, food_id=food_id)

    first = rate(client, auth, log_id, 1)
    assert first.status_code == 201, first.text
    assert first.json()["stance"] == "dislike"

    second = rate(client, auth, log_id, 5)
    assert second.status_code == 201, second.text
    assert second.json()["stance"] == "like"

    # One opinion about one meal, not two. And the *second* one is the one kept.
    feedback = store.rows("food_feedback")
    assert len(feedback) == 1
    assert feedback[0]["rating"] == 5

    # The correction had to be reachable without logging the meal again: a second
    # food_logs row would be counted a second time by ``_intake_today`` and would pull
    # the day's gap report out of shape.
    assert len(store.rows("food_logs")) == 1

    # And the stance the planner reads followed the correction rather than the first tap.
    prefs = store.rows("food_preferences")
    assert len(prefs) == 1
    assert prefs[0]["stance"] == "like"
    assert prefs[0]["score"] == 5.0


# --------------------------------------------------------- the loop actually closes


def test_a_rating_reaches_the_store_the_planner_selects_candidates_from(client, auth, store):
    """Rate it once, and the planner stops offering it. End to end, no hand-built rows.

    This is the whole claim the feature makes to the owner, checked in the only way that
    means anything: the rating goes in over HTTP, and what comes back out is read by the
    same repository call the plan assembler makes and handed to the same selector.
    """
    disliked = seed_food(store, "Soya chunks")
    loved = seed_food(store, "Ragi")

    rate(client, auth, log_meal(client, auth, food_id=disliked), 1)
    rate(client, auth, log_meal(client, auth, food_id=loved), 5)

    # The exact call in app/planner/context.py.
    preferences = run(food_logs_as_user(store).preferences())
    assert {p.food_id: p.stance for p in preferences} == {
        disliked: Stance.DISLIKE,
        loved: Stance.LIKE,
    }
    # Resolved names, not ids -- this is what the tastes screen shows.
    assert {p.name for p in preferences} == {"Soya chunks", "Ragi"}

    catalogue = [
        build_food(disliked, "Soya chunks", protein_g=52.0, iron_mg=20.0, kcal=345.0),
        build_food(loved, "Ragi", protein_g=7.3, iron_mg=3.9, calcium_mg=344.0, kcal=328.0),
    ]
    chosen = select_candidates(catalogue, profile(), preferences=preferences)

    ids = [item.id for item in chosen]
    assert disliked not in ids, "a food rated 1 was offered again"
    assert loved in ids


# ------------------------------------------------------------------- reading it back


def test_preferences_lists_every_belief_by_name_in_a_stable_order(client, auth, store):
    ragi = seed_food(store, "Ragi")
    soya = seed_food(store, "Soya chunks")
    amla = seed_food(store, "Amla")

    rate(client, auth, log_meal(client, auth, food_id=soya), 1)
    rate(client, auth, log_meal(client, auth, food_id=ragi), 5)
    rate(client, auth, log_meal(client, auth, food_id=amla), 3)

    response = request(client, "GET", "/v1/feedback/preferences", headers=auth)
    assert response.status_code == 200, response.text
    rows = response.json()["preferences"]

    # By name, so the list does not reshuffle between two corrections.
    assert [row["name"] for row in rows] == ["Amla", "Ragi", "Soya chunks"]
    assert [row["stance"] for row in rows] == ["neutral", "like", "dislike"]
    assert [row["score"] for row in rows] == [3.0, 5.0, 1.0]
    assert {row["food_id"] for row in rows} == {amla, ragi, soya}


def test_the_list_carries_only_this_persons_own_beliefs(client, auth, store):
    """Somebody else's opinion of the same food is not in this person's list.

    Only one direction is asserted, because the fake gateway acts as one fixed user --
    reading *as* the other person is not something this harness can stand up. The
    direction that matters is the one here: a row belonging to another user, on a food
    this user has also rated, must not appear.
    """
    food_id = seed_food(store)
    rate(client, auth, log_meal(client, auth, food_id=food_id), 1)
    store.seed(
        "food_preferences",
        [{"user_id": OTHER_USER_ID, "food_id": food_id, "stance": "like", "score": 5.0}],
    )
    assert len(store.rows("food_preferences")) == 2

    response = request(client, "GET", "/v1/feedback/preferences", headers=auth)
    rows = response.json()["preferences"]
    assert len(rows) == 1
    assert rows[0]["stance"] == "dislike"


# --------------------------------------------------------- correcting it directly


def test_a_taste_can_be_corrected_without_logging_a_meal(client, auth, store):
    """The tastes screen's write. It must not touch the food diary.

    Changing your mind about soya is not the same as eating soya, and if the only way to
    say so were to log a meal, every correction would add a portion of it to the day's
    intake.
    """
    food_id = seed_food(store)
    rate(client, auth, log_meal(client, auth, food_id=food_id), 1)
    logs_before = len(store.rows("food_logs"))

    response = request(
        client,
        "PUT",
        f"/v1/feedback/preferences/{food_id}",
        headers=auth,
        json={"rating": 5},
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body == {
        "food_id": food_id,
        "name": "Soya chunks",
        "stance": "like",
        "score": 5.0,
    }

    assert len(store.rows("food_logs")) == logs_before
    assert len(store.rows("food_preferences")) == 1
    assert store.rows("food_preferences")[0]["stance"] == "like"


def test_a_put_replaces_so_sending_it_twice_changes_nothing_further(client, auth, store):
    """PUT semantics, which is what lets the client replay one after a dropped call."""
    food_id = seed_food(store)
    path = f"/v1/feedback/preferences/{food_id}"

    first = request(client, "PUT", path, headers=auth, json={"rating": 5})
    second = request(client, "PUT", path, headers=auth, json={"rating": 5})
    assert first.status_code == second.status_code == 200
    assert first.json() == second.json()
    assert len(store.rows("food_preferences")) == 1


def test_neutral_is_how_a_belief_is_forgotten(client, auth, store):
    """There is no DELETE, and this is why there does not need to be one.

    A 3 lands on neutral at 3.0, which ``filter_foods`` does not exclude and
    ``rank_foods`` gives nothing to. The row still exists -- so the person can still see
    that they once said something -- but it moves no plan.
    """
    food_id = seed_food(store)
    rate(client, auth, log_meal(client, auth, food_id=food_id), 1)

    response = request(
        client, "PUT", f"/v1/feedback/preferences/{food_id}", headers=auth, json={"rating": 3}
    )
    assert response.status_code == 200
    assert response.json()["stance"] == "neutral"

    preferences = run(food_logs_as_user(store).preferences())
    catalogue = [build_food(food_id, "Soya chunks", protein_g=52.0, kcal=345.0)]
    chosen = select_candidates(catalogue, profile(), preferences=preferences)
    assert [item.id for item in chosen] == [food_id], "neutral should be invisible"


def test_a_food_we_do_not_have_is_refused_rather_than_stored(client, auth, store):
    """Otherwise the tastes list fills with rows nobody can put a name to."""
    response = request(
        client,
        "PUT",
        "/v1/feedback/preferences/00000000-0000-0000-0000-0000000000ff",
        headers=auth,
        json={"rating": 5},
    )
    assert response.status_code == 404
    assert "food" in problem(response)["detail"].lower()


def test_a_rating_outside_one_to_five_is_refused_on_the_preference_route(client, auth, store):
    food_id = seed_food(store)
    for bad in ({"rating": 0}, {"rating": 6}, {"rating": 5, "stance": "like"}):
        response = request(
            client, "PUT", f"/v1/feedback/preferences/{food_id}", headers=auth, json=bad
        )
        assert response.status_code == 422, f"{bad} was accepted"


# ------------------------------------------------------- a meal with no food behind it


def test_rating_a_free_text_meal_stores_the_rating_and_claims_nothing_more(client, auth, store):
    """A photo or a typed-in meal has no ``food_id``, so no preference can move.

    The rating is still kept -- it is a fact about that meal -- but ``preference_updated``
    is false and there is no stance, which is what lets the app say "this one is not in
    our food list yet" instead of implying it learned something.
    """
    log_id = log_meal(client, auth, free_text="Aunt's sambar, second helping")

    response = rate(client, auth, log_id, 5)
    assert response.status_code == 201, response.text
    body = response.json()
    assert body["preference_updated"] is False
    assert body["stance"] is None
    assert body["rating"] == 5

    assert len(store.rows("food_feedback")) == 1
    assert store.rows("food_preferences") == []

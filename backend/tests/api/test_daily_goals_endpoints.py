"""The water and movement numbers over HTTP: on the plan response, and logged back.

Two things are being proved here that a unit test cannot. First, that the targets
actually reach the Today screen through the one call it already makes. Second, that a
movement entry lands in the audit trail as the caller and nobody else -- the endpoint
takes no user id at all, and another user's day is unreachable from this token.
"""

from __future__ import annotations

from datetime import date, timedelta

from tests.api.conftest import request
from tests.conftest import OTHER_USER_ID, USER_ID

TODAY = date.today()
YESTERDAY = TODAY - timedelta(days=1)

#: 25 years old on any plausible run date. The suite must not start failing on a birthday.
ADULT_DOB = (TODAY - timedelta(days=365 * 25 + 6)).isoformat()
TEEN_DOB = (TODAY - timedelta(days=365 * 14 + 3)).isoformat()


def seed_profile(store, **fields) -> None:
    store.seed("health_profiles", [{"user_id": USER_ID, "dob": ADULT_DOB, **fields}])


def seed_plan(store, on: date = TODAY) -> str:
    store.seed(
        "meal_plans",
        [{"user_id": USER_ID, "plan_date": on.isoformat(), "model": "gemini-2.5-flash",
          "rationale": "A steady day built around foods you already like.",
          "status": "active"}],
    )
    return str(store.rows("meal_plans")[-1]["id"])


def plan_body(client, auth, on: date = TODAY) -> dict:
    response = request(client, "GET", f"/v1/plan/{on.isoformat()}", headers=auth)
    assert response.status_code == 200, response.text
    return response.json()


def log(client, auth, **payload):
    return request(client, "POST", "/v1/feedback/movement", headers=auth, json=payload)


# ------------------------------------------------------- the targets reach the screen


def test_the_plan_response_carries_both_targets(client, auth, store):
    seed_profile(store, sex="male", activity_level="active")
    seed_plan(store)
    body = plan_body(client, auth)

    assert body["hydration_target_ml"] == 2000
    assert "EFSA" in body["hydration_target_source"]
    assert body["movement_target_minutes_per_week"] == 300
    assert body["movement_target_minutes_per_day"] == 43
    assert "World Health Organization" in body["movement_target_source"]
    assert body["movement_minutes_logged"] == 0


def test_two_different_profiles_get_two_different_water_targets(client, auth, store):
    seed_profile(store, sex="female", activity_level="sedentary")
    seed_plan(store)
    female = plan_body(client, auth)

    store.rows("health_profiles")[0]["sex"] = "male"
    male = plan_body(client, auth)

    assert female["hydration_target_ml"] == 1600
    assert male["hydration_target_ml"] == 2000
    assert female["movement_target_minutes_per_week"] == 150
    assert male["movement_target_minutes_per_week"] == 150


def test_a_user_with_no_health_profile_still_gets_a_documented_default(client, auth, store):
    # No health_profiles row at all. The endpoint must answer with the floor and say why,
    # not 500 and not silently pick the larger of the two figures.
    seed_plan(store)
    body = plan_body(client, auth)
    assert body["hydration_target_ml"] == 1600
    assert "no sex is recorded" in body["hydration_target_source"]
    assert body["movement_target_minutes_per_week"] == 150


def test_pregnancy_gets_no_water_target_over_the_wire(client, auth, store):
    seed_profile(store, sex="female", pregnancy=True)
    seed_plan(store)
    body = plan_body(client, auth)
    assert body["hydration_target_ml"] is None
    assert "midwife" in body["hydration_target_source"]
    # Movement is still coached: WHO states the same weekly figure in pregnancy.
    assert body["movement_target_minutes_per_week"] == 150


def test_a_fluid_restricting_condition_gets_no_water_target_over_the_wire(client, auth, store):
    seed_profile(store, sex="male", conditions=["Stage 4 CKD"])
    seed_plan(store)
    body = plan_body(client, auth)
    assert body["hydration_target_ml"] is None
    assert "ask your doctor" in body["hydration_target_source"]


def test_an_under_18_is_shown_no_target_rather_than_an_adult_one(client, auth, store):
    seed_profile(store, sex="male", dob=TEEN_DOB)
    seed_plan(store)
    body = plan_body(client, auth)
    assert body["hydration_target_ml"] is None
    assert body["movement_target_minutes_per_day"] is None


# ------------------------------------------------------------------ logging movement


def test_logging_movement_round_trips_onto_the_plan(client, auth, store):
    seed_profile(store, sex="male", activity_level="active")
    seed_plan(store)
    assert plan_body(client, auth)["movement_minutes_logged"] == 0

    response = log(client, auth, minutes=40, activity="badminton")
    assert response.status_code == 201, response.text
    entry = response.json()
    assert entry["on"] == TODAY.isoformat()
    assert entry["minutes"] == 40
    assert entry["moderate_equivalent_minutes"] == 40
    assert entry["day_total_moderate_equivalent_minutes"] == 40

    assert plan_body(client, auth)["movement_minutes_logged"] == 40

    # A second bout the same day adds to the first rather than replacing it.
    assert log(client, auth, minutes=20).json()["day_total_moderate_equivalent_minutes"] == 60
    assert plan_body(client, auth)["movement_minutes_logged"] == 60


def test_a_vigorous_session_counts_twice_toward_the_target(client, auth, store):
    seed_plan(store)
    response = log(client, auth, minutes=30, intensity="vigorous", activity="running")
    assert response.status_code == 201
    assert response.json()["moderate_equivalent_minutes"] == 60
    assert plan_body(client, auth)["movement_minutes_logged"] == 60


def test_movement_is_stored_in_the_append_only_audit_trail(client, auth, store):
    # There is no movement table. This is the same place plan progress and the planner's
    # hydration figure live, and it is append-only, so an entry cannot be rewritten.
    assert log(client, auth, minutes=25, activity="walk").status_code == 201
    events = [row for row in store.rows("health_events") if row["event_type"] == "movement_logged"]
    assert len(events) == 1
    assert events[0]["user_id"] == USER_ID
    assert events[0]["payload"]["minutes"] == 25
    assert events[0]["payload"]["activity"] == "walk"
    # Raw inputs only. The moderate-equivalent figure is derived on read, so correcting
    # the equivalence later corrects past weeks too.
    assert "moderate_equivalent_minutes" not in events[0]["payload"]


def test_a_back_dated_entry_lands_on_the_day_it_happened(client, auth, store):
    seed_plan(store, YESTERDAY)
    assert log(client, auth, minutes=45, on=YESTERDAY.isoformat()).status_code == 201
    assert plan_body(client, auth, YESTERDAY)["movement_minutes_logged"] == 45
    seed_plan(store, TODAY)
    assert plan_body(client, auth, TODAY)["movement_minutes_logged"] == 0


def test_movement_in_the_future_is_refused(client, auth):
    response = log(client, auth, minutes=30, on=(TODAY + timedelta(days=1)).isoformat())
    assert response.status_code == 422


def test_an_implausible_single_entry_is_refused_rather_than_clamped(client, auth):
    assert log(client, auth, minutes=4000).status_code == 422
    assert log(client, auth, minutes=0).status_code == 422


def test_an_intensity_below_moderate_is_refused(client, auth):
    # WHO's 150 minutes counts moderate-to-vigorous activity. Accepting "light" and
    # counting it would overstate the week against its own target.
    assert log(client, auth, minutes=30, intensity="light").status_code == 422


# ---------------------------------------------------------- it is only ever your own


def test_movement_cannot_be_logged_against_another_user(client, auth, store):
    # The schema forbids the field outright, so there is no id to spoof; and the row is
    # written by the caller's own token, which is what RLS checks.
    response = log(client, auth, minutes=30, user_id=OTHER_USER_ID)
    assert response.status_code == 422
    assert store.rows("health_events") == []


def test_another_users_movement_is_invisible(client, auth, store):
    store.seed(
        "health_events",
        [{"user_id": OTHER_USER_ID, "event_type": "movement_logged",
          "occurred_at": f"{TODAY.isoformat()}T06:00:00+00:00",
          "payload": {"on": TODAY.isoformat(), "minutes": 90, "intensity": "vigorous",
                      "activity": "not yours"}}],
    )
    seed_plan(store)
    assert plan_body(client, auth)["movement_minutes_logged"] == 0

    response = request(client, "GET", "/v1/feedback/movement", headers=auth)
    assert response.status_code == 200
    assert response.json()["total_minutes"] == 0
    assert "not yours" not in response.text


# ----------------------------------------------------------------- the week, not the day


def test_the_summary_defaults_to_seven_days_with_the_gaps_left_in(client, auth, store):
    seed_profile(store, sex="male", activity_level="active")
    assert log(client, auth, minutes=40, on=TODAY.isoformat()).status_code == 201
    assert log(client, auth, minutes=30, intensity="vigorous",
               on=(TODAY - timedelta(days=2)).isoformat()).status_code == 201

    response = request(client, "GET", "/v1/feedback/movement", headers=auth)
    assert response.status_code == 200, response.text
    body = response.json()

    assert body["start"] == (TODAY - timedelta(days=6)).isoformat()
    assert body["end"] == TODAY.isoformat()
    assert len(body["days"]) == 7
    assert [day["on"] for day in body["days"]] == sorted(day["on"] for day in body["days"])
    assert body["total_minutes"] == 70
    assert body["total_moderate_equivalent_minutes"] == 100  # 40 + 30 vigorous doubled
    assert body["target_minutes_per_week"] == 300
    assert "World Health Organization" in body["target_source"]

    by_day = {day["on"]: day for day in body["days"]}
    assert by_day[TODAY.isoformat()]["entries"] == 1
    assert by_day[(TODAY - timedelta(days=1)).isoformat()]["moderate_equivalent_minutes"] == 0


def test_an_explicit_range_is_honoured(client, auth, store):
    assert log(client, auth, minutes=20, on=(TODAY - timedelta(days=3)).isoformat()).status_code == 201
    response = request(
        client,
        "GET",
        "/v1/feedback/movement",
        headers=auth,
        params={"start": (TODAY - timedelta(days=2)).isoformat(), "end": TODAY.isoformat()},
    )
    assert response.status_code == 200
    body = response.json()
    assert len(body["days"]) == 3
    assert body["total_minutes"] == 0  # the entry sits one day outside the window


def test_a_backwards_or_oversized_range_is_refused(client, auth):
    backwards = request(
        client, "GET", "/v1/feedback/movement", headers=auth,
        params={"start": TODAY.isoformat(), "end": (TODAY - timedelta(days=1)).isoformat()},
    )
    assert backwards.status_code == 422

    oversized = request(
        client, "GET", "/v1/feedback/movement", headers=auth,
        params={"start": (TODAY - timedelta(days=200)).isoformat(), "end": TODAY.isoformat()},
    )
    assert oversized.status_code == 422


def test_a_freshly_generated_plan_carries_the_targets_too(client, auth, store, gemini):
    # /v1/plan/regenerate builds its own response rather than going through the read
    # path, so the targets have to be attached in both places or the Today screen loses
    # them the moment the user asks for a new plan.
    from tests.api.conftest import consented
    from tests.api.test_pipeline_flows import seed_foods, seed_reference

    consented(store)
    seed_reference(store)  # a 32-year-old man, moderately active
    food_ids = seed_foods(store)
    gemini.queue(
        {
            "items": [{"meal_slot": "breakfast", "food_id": food_ids[0], "grams": 80,
                       "why": "iron and fibre", "order_index": 0}],
            "hydration_ml": 2000,
            "rationale": "A steady day around foods you already eat.",
        }
    )

    response = request(
        client, "POST", "/v1/plan/regenerate", headers=auth,
        json={"plan_date": TODAY.isoformat()},
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["hydration_target_ml"] == 2000
    assert "EFSA" in body["hydration_target_source"]
    assert body["movement_target_minutes_per_week"] == 150
    assert body["movement_minutes_logged"] == 0

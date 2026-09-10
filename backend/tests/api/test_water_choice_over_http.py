"""Choosing your own water goal, over HTTP, exactly as the app will do it.

What is being proved here that a unit test cannot:

* the number a person types is what gets stored and what comes back -- no cap, no round,
  no substitution;
* the warning travels with it, in the response the app shows and in the audit trail a
  clinician reads;
* a goal above the ceiling is refused as a 422 with the reason and the citation in it,
  and nothing is written;
* a profile where fluid intake is a doctor's decision cannot end up with a high goal, and
  its water *reminders* disappear as well as its water bar.
"""

from __future__ import annotations

from datetime import date, timedelta
from typing import Any

from tests.api.conftest import problem, request
from tests.conftest import USER_ID

TODAY = date.today()

#: 25 years old on any run date. The suite must not start failing on a birthday.
ADULT_DOB = (TODAY - timedelta(days=365 * 25 + 6)).isoformat()

FIVE_LITRES = 5000


def seed_profile(store, **fields) -> None:
    store.seed(
        "health_profiles",
        [{"user_id": USER_ID, "dob": ADULT_DOB, "sex": "male", **fields}],
    )


def seed_plan(store, on: date = TODAY) -> None:
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


def set_goal(client, auth, millilitres: int | None):
    return request(
        client,
        "PUT",
        "/v1/plan/hydration-target",
        headers=auth,
        json={"millilitres": millilitres},
    )


def plan_body(client, auth, on: date = TODAY) -> dict[str, Any]:
    response = request(client, "GET", f"/v1/plan/{on.isoformat()}", headers=auth)
    assert response.status_code == 200, response.text
    return response.json()


def events(store, event_type: str) -> list[dict[str, Any]]:
    return [
        row
        for row in store.rows("health_events")
        if str(row.get("event_type")) == event_type
    ]


# ------------------------------------------------------------------- setting five litres


def test_the_owner_gets_the_five_litres_he_asked_for(client, auth, store):
    seed_profile(store)
    response = set_goal(client, auth, FIVE_LITRES)
    assert response.status_code == 200, response.text
    body = response.json()

    assert body["hydration_target_ml"] == FIVE_LITRES
    assert body["hydration_target_chosen_by_user"] is True
    # And the sourced figure is right beside it rather than replaced by it.
    assert body["hydration_target_sourced_ml"] == 2000
    assert "EFSA" in body["hydration_target_source"]


def test_the_warning_comes_back_with_it(client, auth, store):
    seed_profile(store)
    caution = set_goal(client, auth, FIVE_LITRES).json()["hydration_target_caution"]
    assert "dilutes the salt in your blood" in caution
    assert "sweating heavily" in caution
    assert "asking a doctor" in caution
    assert "Institute of Medicine" in caution


def test_the_goal_lands_on_the_profile_row(client, auth, store):
    seed_profile(store)
    set_goal(client, auth, FIVE_LITRES)
    row = store.rows("health_profiles")[0]
    assert row["hydration_target_override_ml"] == FIVE_LITRES


def test_the_choice_and_the_warning_are_both_recorded_for_a_clinician(client, auth, store):
    seed_profile(store)
    set_goal(client, auth, FIVE_LITRES)
    recorded = events(store, "hydration_target_set")
    assert len(recorded) == 1
    payload = recorded[0]["payload"]
    assert payload["millilitres"] == FIVE_LITRES
    assert payload["sourced_ml"] == 2000
    # The words that were actually shown, not a flag saying words were shown.
    assert "dilutes the salt in your blood" in payload["caution_shown"]


def test_the_today_screen_then_shows_the_chosen_goal_and_the_sourced_one(client, auth, store):
    seed_profile(store)
    seed_plan(store)
    set_goal(client, auth, FIVE_LITRES)
    body = plan_body(client, auth)
    assert body["hydration_target_ml"] == FIVE_LITRES
    assert body["hydration_target_chosen_by_user"] is True
    assert body["hydration_target_sourced_ml"] == 2000
    assert "dilutes the salt" in body["hydration_target_caution"]
    assert "You set this goal yourself" in body["hydration_target_source"]


def test_clearing_it_puts_the_sourced_figure_back(client, auth, store):
    seed_profile(store)
    seed_plan(store)
    set_goal(client, auth, FIVE_LITRES)

    cleared = set_goal(client, auth, None)
    assert cleared.status_code == 200, cleared.text
    assert cleared.json()["hydration_target_ml"] == 2000
    assert cleared.json()["hydration_target_chosen_by_user"] is False
    assert plan_body(client, auth)["hydration_target_ml"] == 2000


def test_a_goal_inside_the_published_range_is_taken_without_a_lecture(client, auth, store):
    seed_profile(store)
    body = set_goal(client, auth, 2600).json()
    assert body["hydration_target_ml"] == 2600
    assert body["hydration_target_caution"] == ""


# ------------------------------------------------------------------------- the refusals


def test_above_the_ceiling_is_refused_and_nothing_is_written(client, auth, store):
    seed_profile(store)
    response = set_goal(client, auth, 9000)
    assert response.status_code == 422
    detail = problem(response)["detail"]
    assert "6000" in detail
    assert "Noakes" in detail

    assert store.rows("health_profiles")[0].get("hydration_target_override_ml") is None
    assert events(store, "hydration_target_set") == []
    # Refusals are recorded too: it is a thing the person tried to do to themselves.
    assert len(events(store, "hydration_target_refused")) == 1


def test_a_goal_too_small_to_mean_anything_is_refused(client, auth, store):
    seed_profile(store)
    response = set_goal(client, auth, 100)
    assert response.status_code == 422
    assert "500" in problem(response)["detail"]


def test_a_fluid_restricted_profile_cannot_set_a_high_goal(client, auth, store):
    seed_profile(store, conditions=["Stage 4 CKD"])
    response = set_goal(client, auth, FIVE_LITRES)
    assert response.status_code == 422
    assert "ask your doctor" in problem(response)["detail"]
    assert store.rows("health_profiles")[0].get("hydration_target_override_ml") is None


def test_a_pregnant_profile_cannot_either(client, auth, store):
    seed_profile(store, sex="female", pregnancy=True)
    response = set_goal(client, auth, FIVE_LITRES)
    assert response.status_code == 422
    assert "midwife" in problem(response)["detail"]


def test_a_stored_goal_beyond_the_ceiling_never_reaches_the_screen(client, auth, store):
    # However it got there. The bar shows the sourced figure and the reason says why.
    seed_profile(store, hydration_target_override_ml=12000)
    seed_plan(store)
    body = plan_body(client, auth)
    assert body["hydration_target_ml"] == 2000
    assert body["hydration_target_chosen_by_user"] is False
    assert "not being used" in body["hydration_target_source"]


def test_a_restricted_profile_with_a_goal_still_gets_no_target_and_a_reason(client, auth, store):
    seed_profile(store, conditions=["heart failure"], hydration_target_override_ml=FIVE_LITRES)
    seed_plan(store)
    body = plan_body(client, auth)
    assert body["hydration_target_ml"] is None
    assert body["hydration_target_sourced_ml"] is None
    assert "ask your doctor" in body["hydration_target_source"]
    assert "5000" in body["hydration_target_source"]


def test_the_endpoint_refuses_a_field_it_does_not_know(client, auth, store):
    seed_profile(store)
    response = request(
        client,
        "PUT",
        "/v1/plan/hydration-target",
        headers=auth,
        json={"millilitres": 2500, "acknowledged": True},
    )
    assert response.status_code == 422


# --------------------------------------------------- the reminders follow the same rule


def seed_alerts(store, *, times: list[str], alert_type: str = "hydration") -> None:
    store.seed(
        "alerts",
        [
            {
                "user_id": USER_ID,
                "alert_type": alert_type,
                "title": "Water",
                "body": "Time for a glass of water.",
                "schedule_rule": at,
                "enabled": True,
                "quiet_hours": {},
            }
            for at in times
        ],
    )


def list_alerts(client, auth) -> dict[str, Any]:
    response = request(client, "GET", "/v1/alerts", headers=auth)
    assert response.status_code == 200, response.text
    return response.json()


def test_every_water_reminder_is_listed_and_stays_switchable(client, auth, store):
    seed_profile(store)
    seed_alerts(store, times=["07:00", "09:00", "11:00", "13:00"])
    body = list_alerts(client, auth)
    assert [alert["at"] for alert in body["alerts"]] == ["07:00", "09:00", "11:00", "13:00"]

    off = request(client, "PATCH", "/v1/alerts/hydration", headers=auth, json={"enabled": False})
    assert off.status_code == 200, off.text
    # One switch, every row of the type. A half-switched-off reminder still fires.
    assert all(alert["enabled"] is False for alert in off.json()["alerts"])


def test_water_reminders_are_withheld_where_there_is_no_water_goal(client, auth, store):
    # These rows were derived before the condition was recorded. The endpoint the phone
    # schedules from is the last place the rule can be enforced, so it is enforced here.
    seed_profile(store, conditions=["Stage 4 CKD"])
    seed_alerts(store, times=["07:00", "09:00"])
    seed_alerts(store, times=["21:45"], alert_type="sleep")
    body = list_alerts(client, auth)
    kinds = {alert["alert_type"] for alert in body["alerts"]}
    assert "hydration" not in kinds
    # And nothing else is silenced by it.
    assert "sleep" in kinds

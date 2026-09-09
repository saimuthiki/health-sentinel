"""The routers, end to end over ASGI, with Supabase and Gemini faked out."""

from __future__ import annotations

import json
from datetime import date

import pytest

from app.repositories.profiles import CURRENT_CONSENT_VERSION
from tests.api.conftest import consented, problem, request
from tests.conftest import OTHER_USER_ID, USER_ID, KeyMaterial, make_token

PDF = b"%PDF-1.7\n" + b"0" * 200
JPEG = b"\xff\xd8\xff\xe0" + b"0" * 200
NOT_A_FILE = b"PK\x03\x04" + b"0" * 200


# ------------------------------------------------------------------------- health


def test_healthz_needs_no_token(client):
    response = request(client, "GET", "/healthz")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"


def test_readyz_reports_configuration_without_revealing_it(client, settings):
    response = request(client, "GET", "/readyz")
    assert response.status_code == 200
    body = response.json()
    assert body["checks"] == {"supabase_config": True, "gemini_config": True}
    text = json.dumps(body)
    assert settings.supabase_service_role_key not in text
    assert settings.gemini_api_key not in text
    assert settings.supabase_url not in text


def test_readyz_is_503_when_configuration_is_missing(app, client):
    app.state.settings = app.state.settings.model_copy(update={"gemini_api_key": ""})
    response = request(client, "GET", "/readyz")
    assert response.status_code == 503
    assert response.json()["status"] == "not_ready"


def test_readyz_makes_no_outbound_call(client):
    """The autouse network guard in tests/conftest.py fails the test if it did."""
    assert request(client, "GET", "/readyz").status_code == 200


def test_every_response_carries_a_request_id(client):
    response = request(client, "GET", "/healthz")
    assert response.headers["X-Request-ID"]


def test_a_supplied_request_id_is_echoed(client):
    response = request(client, "GET", "/healthz", headers={"X-Request-ID": "abc-123"})
    assert response.headers["X-Request-ID"] == "abc-123"


# --------------------------------------------------------------------------- auth


def test_an_endpoint_without_a_token_is_401_problem_json(client):
    response = request(client, "GET", "/v1/me")
    assert response.status_code == 401
    body = problem(response)
    assert body["type"].endswith("/not-authenticated")
    assert body["status"] == 401
    assert response.headers["WWW-Authenticate"] == "Bearer"


def test_an_expired_token_is_401(client, ec_key: KeyMaterial):
    token = make_token(ec_key, expires_in=-60)
    response = request(client, "GET", "/v1/me", headers={"Authorization": f"Bearer {token}"})
    assert response.status_code == 401


def test_me_returns_the_verified_subject(client, auth, store):
    store.seed("profiles", [{"user_id": USER_ID, "display_name": "Sai", "locale": "en-IN"}])
    response = request(client, "GET", "/v1/me", headers=auth)
    assert response.status_code == 200
    body = response.json()
    assert body["user_id"] == USER_ID
    assert body["display_name"] == "Sai"
    assert body["consent_version_required"] == CURRENT_CONSENT_VERSION


def test_profile_round_trip(client, auth):
    payload = {
        "display_name": "Sai",
        "dob": "1994-03-02",
        "sex": "male",
        "height_cm": 172,
        "weight_kg": 74,
        "activity_level": "moderate",
        "diet_type": "non_veg",
        "city": "Hyderabad",
        "wake_time": "06:30:00",
        "sleep_time": "23:00:00",
        "meal_times": {"breakfast": "08:00:00", "lunch": "13:30:00"},
        "allergies": [{"allergen": "peanut", "severity": "severe"}],
    }
    response = request(client, "PUT", "/v1/me/profile", headers=auth, json=payload)
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["city"] == "Hyderabad"
    assert body["allergies"] == [{"allergen": "peanut", "severity": "severe"}]
    assert body["age_years"] is not None


def test_profile_rejects_unknown_fields(client, auth):
    response = request(
        client, "PUT", "/v1/me/profile", headers=auth, json={"is_admin": True}
    )
    assert response.status_code == 422
    assert problem(response)["type"].endswith("/invalid-request")


def test_validation_errors_never_echo_the_submitted_value(client, auth):
    response = request(
        client, "PUT", "/v1/me/profile", headers=auth, json={"weight_kg": -900}
    )
    assert response.status_code == 422
    assert "-900" not in response.text
    assert "900" not in response.text


def test_consent_is_recorded_with_a_hash_not_an_address(client, auth, store):
    response = request(
        client,
        "POST",
        "/v1/me/consents",
        headers=auth,
        json={"consent_type": "health_data", "version": CURRENT_CONSENT_VERSION},
    )
    assert response.status_code == 201
    row = store.rows("consents")[0]
    assert row["ip_hash"] is None or len(row["ip_hash"]) == 64
    assert "127.0.0.1" not in json.dumps(row)


def test_consent_status_reports_what_is_still_needed(client, auth, store):
    assert request(client, "GET", "/v1/me/consents", headers=auth).json()["current"] is False
    consented(store)
    assert request(client, "GET", "/v1/me/consents", headers=auth).json()["current"] is True


def test_analysis_endpoints_require_consent(client, auth):
    response = request(
        client, "POST", "/v1/chat/messages", headers=auth, json={"message": "hello"}
    )
    assert response.status_code == 403
    assert problem(response)["type"].endswith("/consent-required")


# ------------------------------------------------------------------------ uploads


def upload(client, auth, data: bytes, name: str = "report.pdf", mime: str = "application/pdf"):
    return request(
        client,
        "POST",
        "/v1/reports",
        headers=auth,
        files={"file": (name, data, mime)},
    )


def test_upload_rejects_a_type_we_cannot_read(client, auth, store):
    consented(store)
    response = upload(client, auth, NOT_A_FILE, "report.zip", "application/zip")
    assert response.status_code == 415
    assert problem(response)["type"].endswith("/unsupported-file-type")


def test_upload_rejects_a_file_lying_about_its_type(client, auth, store):
    consented(store)
    response = upload(client, auth, JPEG, "report.pdf", "application/pdf")
    assert response.status_code == 415


def test_upload_rejects_a_file_over_the_cap(app, client, auth, store):
    consented(store)
    app.state.settings = app.state.settings.model_copy(update={"max_upload_bytes": 1024})
    response = upload(client, auth, PDF + b"0" * 4096)
    assert response.status_code == 413
    assert problem(response)["type"].endswith("/payload-too-large")


def test_upload_rejects_an_empty_file(client, auth, store):
    consented(store)
    response = upload(client, auth, b"")
    assert response.status_code in (413, 415, 422)


# --------------------------------------------------------------------------- plan


def test_a_plan_for_a_date_with_none_is_404(client, auth):
    response = request(client, "GET", "/v1/plan/2026-01-01", headers=auth)
    assert response.status_code == 404
    assert problem(response)["type"].endswith("/not-found")


def test_a_stored_plan_is_returned_with_guarded_text(client, auth, store):
    store.seed("foods", [{"name": "Ragi", "food_group": "Millets", "per_100g": {"iron_mg": 3.9}}])
    food_id = store.rows("foods")[0]["id"]
    store.seed(
        "meal_plans",
        [{"user_id": USER_ID, "plan_date": "2026-09-09", "model": "gemini-2.5-flash",
          "rationale": "A steady day built around foods you already like.", "status": "active"}],
    )
    plan_id = store.rows("meal_plans")[0]["id"]
    store.seed(
        "meal_plan_items",
        [{"meal_plan_id": plan_id, "meal_slot": "breakfast", "food_id": food_id,
          "grams": 80, "computed_nutrients": {"iron_mg": 3.1},
          "why_text": "3.1 mg iron, covers a third of today's iron gap", "order_index": 0}],
    )
    response = request(client, "GET", "/v1/plan/2026-09-09", headers=auth)
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["items"][0]["display_name"] == "Ragi"
    assert body["items"][0]["computed_nutrients"] == {"iron_mg": 3.1}
    assert "iron" in body["items"][0]["why_text"]


def test_another_users_plan_is_invisible(client, auth, store):
    store.seed(
        "meal_plans",
        [{"user_id": OTHER_USER_ID, "plan_date": "2026-09-09", "rationale": "not yours"}],
    )
    response = request(client, "GET", "/v1/plan/2026-09-09", headers=auth)
    assert response.status_code == 404
    assert "not yours" not in response.text


# ------------------------------------------------------------------------ feedback


def test_logging_and_rating_a_meal_moves_the_preference(client, auth, store):
    store.seed("foods", [{"name": "Soya chunks", "food_group": "Pulses", "per_100g": {}}])
    food_id = store.rows("foods")[0]["id"]

    logged = request(
        client,
        "POST",
        "/v1/feedback/meals",
        headers=auth,
        json={"meal_slot": "lunch", "food_id": food_id, "source": "planned"},
    )
    assert logged.status_code == 201
    log_id = logged.json()["id"]

    rated = request(
        client,
        "POST",
        f"/v1/feedback/meals/{log_id}/rating",
        headers=auth,
        json={"rating": 1, "note": "did not enjoy it"},
    )
    assert rated.status_code == 201, rated.text
    assert rated.json()["stance"] == "dislike"
    assert store.rows("food_preferences")[0]["score"] == 1.0


def test_a_rating_outside_one_to_five_is_refused(client, auth):
    response = request(
        client, "POST", "/v1/feedback/meals/x/rating", headers=auth, json={"rating": 9}
    )
    assert response.status_code == 422


def test_marking_a_plan_item_writes_an_audit_event(client, auth, store):
    store.seed("meal_plans", [{"user_id": USER_ID, "plan_date": "2026-09-09"}])
    plan_id = store.rows("meal_plans")[0]["id"]
    store.seed(
        "meal_plan_items",
        [{"meal_plan_id": plan_id, "meal_slot": "lunch", "grams": 100, "food_id": "f"}],
    )
    item_id = store.rows("meal_plan_items")[0]["id"]
    response = request(
        client,
        "POST",
        f"/v1/feedback/plan-items/{item_id}",
        headers=auth,
        json={"plan_id": plan_id, "state": "done"},
    )
    assert response.status_code == 200
    events = [row["event_type"] for row in store.rows("health_events")]
    assert "plan_item_progress" in events


# ------------------------------------------------------------------------- grocery


def test_grocery_list_is_built_from_the_weeks_plans(client, auth, store):
    store.seed("foods", [{"name": "Ragi", "food_group": "Millets", "per_100g": {}}])
    food_id = store.rows("foods")[0]["id"]
    monday = date(2026, 9, 7)
    store.seed("meal_plans", [{"user_id": USER_ID, "plan_date": monday.isoformat()}])
    plan_id = store.rows("meal_plans")[0]["id"]
    store.seed(
        "meal_plan_items",
        [
            {"meal_plan_id": plan_id, "meal_slot": "breakfast", "food_id": food_id, "grams": 80},
            {"meal_plan_id": plan_id, "meal_slot": "dinner", "food_id": food_id, "grams": 120},
        ],
    )
    response = request(client, "GET", "/v1/grocery?week_start=2026-09-09", headers=auth)
    assert response.status_code == 200, response.text
    items = response.json()["items"]
    assert len(items) == 1
    assert items[0]["name"] == "Ragi"
    # 200 g of plan, plus the 10% buffer.
    assert items[0]["quantity"] == pytest.approx(220.0)
    assert items[0]["aisle"] == "Millets"


def test_grocery_item_state_can_be_toggled(client, auth, store):
    store.seed("foods", [{"name": "Ragi", "food_group": "Millets", "per_100g": {}}])
    store.seed("grocery_lists", [{"user_id": USER_ID, "week_start": "2026-09-07", "status": "open"}])
    list_id = store.rows("grocery_lists")[0]["id"]
    store.seed(
        "grocery_items",
        [{"grocery_list_id": list_id, "food_id": store.rows("foods")[0]["id"],
          "quantity": 220, "unit": "g", "aisle": "Millets", "state": "need"}],
    )
    item_id = store.rows("grocery_items")[0]["id"]
    response = request(
        client,
        "PATCH",
        f"/v1/grocery/items/{item_id}?week_start=2026-09-09",
        headers=auth,
        json={"state": "bought"},
    )
    assert response.status_code == 200, response.text
    assert response.json()["state"] == "bought"


def test_an_unknown_grocery_state_is_refused(client, auth, store):
    store.seed("grocery_lists", [{"user_id": USER_ID, "week_start": "2026-09-07"}])
    response = request(
        client,
        "PATCH",
        "/v1/grocery/items/x?week_start=2026-09-09",
        headers=auth,
        json={"state": "maybe"},
    )
    assert response.status_code == 422


# -------------------------------------------------------------------------- alerts


def seed_alerts(store) -> None:
    store.seed(
        "alerts",
        [
            {"user_id": USER_ID, "alert_type": "meal", "title": "Lunch time",
             "body": "Your lunch is ready in the plan.", "schedule_rule": "13:20",
             "enabled": True, "quiet_hours": {}},
            {"user_id": USER_ID, "alert_type": "hydration", "title": "Water",
             "body": "Time for a glass of water.", "schedule_rule": "23:30",
             "enabled": True, "quiet_hours": {}},
            {"user_id": USER_ID, "alert_type": "escalation", "title": "See a doctor",
             "body": "Please book an appointment.", "schedule_rule": "09:00",
             "enabled": True, "quiet_hours": {}},
        ],
    )


def test_alerts_are_listed_for_the_device_to_schedule(client, auth, store):
    seed_alerts(store)
    response = request(client, "GET", "/v1/alerts", headers=auth)
    assert response.status_code == 200
    kinds = {alert["alert_type"] for alert in response.json()["alerts"]}
    assert kinds == {"meal", "hydration", "escalation"}


def test_a_type_can_be_switched_off(client, auth, store):
    seed_alerts(store)
    response = request(
        client, "PATCH", "/v1/alerts/hydration", headers=auth, json={"enabled": False}
    )
    assert response.status_code == 200
    hydration = [a for a in response.json()["alerts"] if a["alert_type"] == "hydration"]
    assert hydration[0]["enabled"] is False


def test_escalation_alerts_cannot_be_switched_off(client, auth, store):
    seed_alerts(store)
    response = request(
        client, "PATCH", "/v1/alerts/escalation", headers=auth, json={"enabled": False}
    )
    assert response.status_code == 422
    assert "cannot be switched off" in problem(response)["detail"]


def test_quiet_hours_suppress_the_right_alerts_and_never_escalation(client, auth, store):
    seed_alerts(store)
    response = request(
        client, "PUT", "/v1/alerts/quiet-hours", headers=auth, json={"start": "22:00", "end": "07:00"}
    )
    assert response.status_code == 200, response.text
    by_type = {a["alert_type"]: a for a in response.json()["alerts"]}
    assert by_type["hydration"]["suppressed_by_quiet_hours"] is True   # 23:30
    assert by_type["meal"]["suppressed_by_quiet_hours"] is False       # 13:20
    assert by_type["escalation"]["suppressed_by_quiet_hours"] is False


def test_quiet_hours_must_be_times(client, auth, store):
    seed_alerts(store)
    response = request(
        client, "PUT", "/v1/alerts/quiet-hours", headers=auth, json={"start": "late", "end": "07:00"}
    )
    assert response.status_code == 422


# ---------------------------------------------------------------- errors in general


def test_an_unknown_path_is_a_problem_document(client):
    response = request(client, "GET", "/v1/nope")
    assert response.status_code == 404
    assert problem(response)["type"].endswith("/not-found")


def test_a_wrong_method_is_a_problem_document(client):
    response = request(client, "DELETE", "/healthz")
    assert response.status_code == 405
    body = problem(response)
    assert body["detail"] == "That address does not accept this kind of request."


def test_an_unexpected_error_never_leaks_internals(app, client, auth):
    from fastapi import APIRouter

    router = APIRouter()

    @router.get("/v1/boom")
    async def boom() -> dict[str, str]:
        raise RuntimeError("connection string postgres://user:hunter2@db/health")

    app.include_router(router)
    response = request(client, "GET", "/v1/boom", headers=auth)
    assert response.status_code == 500
    body = problem(response)
    assert "hunter2" not in response.text
    assert "postgres" not in response.text
    assert body["detail"].startswith("Something went wrong on our side.")
    assert body["request_id"]

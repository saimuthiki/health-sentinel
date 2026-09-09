"""The real PostgREST and Storage clients, against a mocked Supabase.

The fake in ``conftest.py`` proves the *behaviour* of the repositories. This file proves
the thing the fake cannot: that the HTTP we actually send carries the **caller's** token,
so the database is the one deciding what comes back.
"""

from __future__ import annotations

import asyncio
from typing import Any

import httpx
import pytest
import respx

from app.core.config import load_settings
from app.core.errors import Conflict, NotFound, PermissionDenied, UpstreamUnavailable
from app.core.security import Principal
from app.domain.enums import ActivityLevel, MealSlot
from app.repositories.base import SupabaseGateway, in_
from app.repositories.mapping import (
    activity_from_db,
    activity_to_db,
    health_profile_from_rows,
    health_profile_to_row,
    slot_from_db,
    slot_to_db,
)
from app.repositories.privacy import (
    APPEND_ONLY_TABLES,
    USER_TABLES_CHILD_FIRST,
    DeletionRepository,
)
from app.repositories.profiles import ProfileRepository, UserScopedRepository
from app.repositories.reference import ReferenceRepository, food_from_row
from app.repositories.reports import ReportRepository
from tests.conftest import SUPABASE_URL, USER_ID

REST = f"{SUPABASE_URL}/rest/v1"
STORAGE = f"{SUPABASE_URL}/storage/v1"
USER_TOKEN = "eyJhbGciOiJFUzI1NiJ9.user-token-body.signature-here"


def run(coro: Any) -> Any:
    return asyncio.run(coro)


@pytest.fixture
def settings():
    return load_settings(
        environment="test",
        supabase_url=SUPABASE_URL,
        supabase_anon_key="sb_publishable_anon",
        supabase_service_role_key="sb_secret_service",
        gemini_api_key="AIzaTest",
    )


@pytest.fixture
def gateway(settings):
    return SupabaseGateway(settings)


@pytest.fixture
def principal():
    return Principal(user_id=USER_ID, token=USER_TOKEN)


# ------------------------------------------------------- the token that is actually sent


@respx.mock
def test_a_user_read_sends_the_users_own_token(gateway, principal, settings):
    route = respx.get(f"{REST}/reports").mock(return_value=httpx.Response(200, json=[]))
    repo = ReportRepository(gateway.rest(gateway.as_user(principal)), USER_ID)
    run(repo.list())

    request = route.calls[0].request
    assert request.headers["Authorization"] == f"Bearer {USER_TOKEN}"
    # The publishable key identifies the project; the bearer decides who we are.
    assert request.headers["apikey"] == settings.supabase_anon_key
    assert settings.supabase_service_role_key not in str(request.headers)
    assert f"user_id=eq.{USER_ID}" in str(request.url)


@respx.mock
def test_a_service_role_read_sends_the_service_key_and_needs_a_reason(gateway, settings):
    respx.get(f"{REST}/deletion_requests").mock(return_value=httpx.Response(200, json=[]))
    credentials = gateway.as_service("sweep expired report files, which has no user context")
    assert credentials.privileged
    assert "sweep expired" in credentials.reason
    assert settings.supabase_service_role_key not in repr(credentials)

    with pytest.raises(ValueError):
        gateway.as_service("   ")


def test_a_user_data_repository_refuses_the_service_role(gateway, settings):
    service = gateway.rest(gateway.as_service("a reason that does not make this ok"))
    with pytest.raises(PermissionDenied):
        UserScopedRepository(service, USER_ID)
    with pytest.raises(PermissionDenied):
        ProfileRepository(service, USER_ID)
    with pytest.raises(PermissionDenied):
        ReportRepository(service, USER_ID)


def test_the_deletion_repository_will_not_swap_its_clients(gateway, principal):
    user = gateway.rest(gateway.as_user(principal))
    service_credentials = gateway.as_service("erase a user")
    service = gateway.rest(service_credentials)
    storage = gateway.storage(service_credentials)

    with pytest.raises(ValueError):
        DeletionRepository(
            user_db=service,  # privileged where the user client belongs
            service_db=service,
            service_storage=storage,
            user_id=USER_ID,
            service_credentials=service_credentials,
        )
    with pytest.raises(ValueError):
        DeletionRepository(
            user_db=user,
            service_db=user,  # not privileged where the service client belongs
            service_storage=storage,
            user_id=USER_ID,
            service_credentials=service_credentials,
        )


# ---------------------------------------------------------------------- error mapping


@respx.mock
@pytest.mark.parametrize(
    ("status", "body", "expected"),
    [
        (401, {}, PermissionDenied),
        (403, {"code": "42501", "message": "new row violates row-level security policy"},
         PermissionDenied),
        (404, {}, NotFound),
        (409, {"code": "23505", "details": "Key (user_id, file_hash)=(...) already exists"},
         Conflict),
        (500, {"message": "connection to server at 10.0.0.4 failed"}, UpstreamUnavailable),
    ],
)
def test_postgrest_errors_become_typed_errors_with_no_internals(
    gateway, principal, status, body, expected
):
    respx.get(f"{REST}/reports").mock(return_value=httpx.Response(status, json=body))
    repo = ReportRepository(gateway.rest(gateway.as_user(principal)), USER_ID)
    with pytest.raises(expected) as excinfo:
        run(repo.list())
    message = str(excinfo.value)
    assert "10.0.0.4" not in message
    assert "row-level security" not in message
    assert "Key (user_id" not in message


@respx.mock
def test_a_transport_failure_is_a_503(gateway, principal):
    respx.get(f"{REST}/reports").mock(side_effect=httpx.ConnectError("no route to host"))
    repo = ReportRepository(gateway.rest(gateway.as_user(principal)), USER_ID)
    with pytest.raises(UpstreamUnavailable) as excinfo:
        run(repo.list())
    assert "no route to host" not in str(excinfo.value)


def test_a_filterless_update_or_delete_is_refused(gateway, principal):
    client = gateway.rest(gateway.as_user(principal))
    with pytest.raises(ValueError):
        run(client.update("reports", {"status": "failed"}, filters={}))
    with pytest.raises(ValueError):
        run(client.delete("reports", filters={}))


# ------------------------------------------------------------------------ dedupe read


@respx.mock
def test_the_dedupe_lookup_filters_on_user_and_hash(gateway, principal):
    route = respx.get(f"{REST}/reports").mock(return_value=httpx.Response(200, json=[]))
    repo = ReportRepository(gateway.rest(gateway.as_user(principal)), USER_ID)
    run(repo.by_hash("f" * 64))
    url = str(route.calls[0].request.url)
    assert f"user_id=eq.{USER_ID}" in url
    assert "file_hash=eq." + "f" * 64 in url


@respx.mock
def test_reference_reads_use_the_user_token_too(gateway, principal, settings):
    route = respx.get(f"{REST}/foods").mock(return_value=httpx.Response(200, json=[]))
    repo = ReferenceRepository(gateway.rest(gateway.as_user(principal)))
    run(repo.foods())
    assert route.calls[0].request.headers["Authorization"] == f"Bearer {USER_TOKEN}"
    assert settings.supabase_service_role_key not in str(route.calls[0].request.headers)


def test_the_in_filter_is_quoted():
    assert in_(["a", "b"]) == 'in.("a","b")'


# ---------------------------------------------------------------------------- storage


@respx.mock
def test_an_upload_goes_to_the_users_own_folder(gateway, principal):
    path = f"{USER_ID}/abc123.pdf"
    route = respx.post(f"{STORAGE}/object/reports/{USER_ID}/abc123.pdf").mock(
        return_value=httpx.Response(200, json={"Key": path})
    )
    storage = gateway.storage(gateway.as_user(principal))
    run(storage.upload(path, b"%PDF-1.7", content_type="application/pdf"))
    request = route.calls[0].request
    assert request.headers["Authorization"] == f"Bearer {USER_TOKEN}"
    assert request.headers["Cache-Control"] == "no-store"


@respx.mock
def test_a_missing_object_is_a_404_not_a_500(gateway, principal):
    respx.get(f"{STORAGE}/object/reports/{USER_ID}/gone.pdf").mock(
        return_value=httpx.Response(404, json={"error": "Object not found"})
    )
    storage = gateway.storage(gateway.as_user(principal))
    with pytest.raises(NotFound):
        run(storage.download(f"{USER_ID}/gone.pdf"))


# ---------------------------------------------------------------------- the mappings


def test_activity_level_maps_to_the_three_the_schema_allows():
    assert activity_to_db(ActivityLevel.LIGHT) == "sedentary"
    assert activity_to_db(ActivityLevel.VERY_ACTIVE) == "heavy"
    assert {activity_to_db(level) for level in ActivityLevel} <= {
        "sedentary",
        "moderate",
        "heavy",
    }
    assert activity_from_db("heavy") is ActivityLevel.ACTIVE
    assert activity_from_db(None) is ActivityLevel.MODERATE


def test_meal_slot_maps_to_the_schemas_names():
    assert slot_to_db(MealSlot.EVENING_SNACK) == "snack"
    assert slot_from_db("snack") is MealSlot.EVENING_SNACK
    assert slot_from_db("bedtime") is MealSlot.EVENING_SNACK
    assert slot_from_db("nonsense") is None
    for slot in MealSlot:
        assert slot_from_db(slot_to_db(slot)) is slot


def test_a_health_profile_round_trips_through_a_row():
    row = {
        "dob": "1994-03-02",
        "sex": "prefer_not_to_say",
        "height_cm": "172.00",
        "weight_kg": "74.50",
        "activity_level": "moderate",
        "diet_type": "veg",
        "cuisine_pref": ["south_indian"],
        "city": "Hyderabad",
        "wake_time": "06:30:00",
        "sleep_time": "23:00:00",
        "meal_times": {"breakfast": "08:00:00", "snack": "17:30:00"},
        "conditions": ["pcos"],
        "pregnancy": False,
    }
    profile = health_profile_from_rows(USER_ID, row, [{"allergen": "peanut", "severity": "severe"}])
    assert profile.sex.value == "other"
    assert profile.weight_kg == 74.5
    assert profile.meal_times[MealSlot.EVENING_SNACK].hour == 17
    assert profile.allergies[0].allergen == "peanut"

    back = health_profile_to_row(profile)
    assert back["pregnancy"] is False
    assert back["meal_times"]["snack"] == "17:30:00"


def test_an_empty_profile_gives_documented_defaults():
    profile = health_profile_from_rows(USER_ID, None, [])
    assert profile.user_id == USER_ID
    assert profile.activity_level is ActivityLevel.MODERATE
    assert profile.allergies == []
    assert profile.age_on(__import__("datetime").date(2026, 9, 9)) is None


def test_a_food_row_with_junk_nutrients_is_cleaned_not_trusted():
    food = food_from_row(
        {
            "id": "f1",
            "name": "Ragi",
            "per_100g": {"iron_mg": "3.9", "protein_g": None, "note": "lots"},
            "diet_flags": ["veg"],
            "allergens": [],
            "source": "IFCT2017",
        }
    )
    assert food.per_100g == {"iron_mg": 3.9}
    assert food.nutrients_for(50) == {"iron_mg": pytest.approx(1.95)}


def test_a_reference_range_without_a_citation_is_discarded(gateway, principal):
    """docs/03-data-model.md: a threshold with no provenance is not a threshold."""
    from app.repositories.reference import _range_from_row

    assert _range_from_row({"biomarker_code": "VITD_25OH", "low": 20, "source_citation": ""}) is None
    assert _range_from_row(
        {"biomarker_code": "VITD_25OH", "low": 20, "source_citation": "Endocrine Society 2011"}
    ) is not None


# ------------------------------------------------------------------ the deletion list


def test_the_deletion_list_covers_every_user_owned_table():
    """docs/03-data-model.md lists what a user owns. Missing one leaves health data behind."""
    expected = {
        "profiles", "health_profiles", "allergies", "consents", "reports",
        "report_extractions", "lab_results", "symptoms", "symptom_followups", "goals",
        "user_memory", "food_preferences", "food_logs", "food_feedback", "meal_plans",
        "meal_plan_items", "grocery_lists", "grocery_items", "pantry_items", "alerts",
        "alert_deliveries", "chat_threads", "chat_messages", "health_events", "ai_runs",
        "weekly_summaries",
    }
    covered = set(USER_TABLES_CHILD_FIRST) | set(APPEND_ONLY_TABLES)
    assert expected - covered == set(), f"deletion misses {expected - covered}"


def test_children_are_deleted_before_their_parents():
    order = list(USER_TABLES_CHILD_FIRST)
    for child, parent in (
        ("meal_plan_items", "meal_plans"),
        ("grocery_items", "grocery_lists"),
        ("report_extractions", "reports"),
        ("lab_results", "reports"),
        ("chat_messages", "chat_threads"),
        ("symptom_followups", "symptoms"),
        ("alert_deliveries", "alerts"),
        ("food_feedback", "food_logs"),
    ):
        assert order.index(child) < order.index(parent), f"{child} must go before {parent}"

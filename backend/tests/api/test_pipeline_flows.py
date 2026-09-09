"""The two pipelines end to end: report ingest (stages 1-5) and planning (6-8).

Gemini is faked and returns exactly what a test queues, so these assert our behaviour --
dedupe, deterministic classification, nutrient recomputation, guarding -- rather than the
model's.
"""

from __future__ import annotations

import json
from datetime import date

import pytest

from tests.api.conftest import consented, problem, request
from tests.conftest import USER_ID

PDF = b"%PDF-1.7\n" + b"lab report bytes" * 20
OTHER_PDF = b"%PDF-1.7\n" + b"a different report" * 20

EXTRACTION = {
    "lab_name": "Apollo Diagnostics",
    "collected_on": "2026-08-14",
    "report_type": "blood",
    "rows": [
        {
            "printed_test_name": "Vitamin D (25-OH)",
            "value_text": "14.2",
            "unit_text": "ng/mL",
            "printed_range": "30 - 100",
            "confidence": 0.97,
        },
        {
            "printed_test_name": "Haemoglobin",
            "value_text": "13.4",
            "unit_text": "g/dL",
            "printed_range": "13 - 17",
            "confidence": 0.99,
        },
        {
            "printed_test_name": "Zorblax Factor",
            "value_text": "42",
            "unit_text": "widgets",
            "confidence": 0.99,
        },
    ],
}

VITD_RANGE = {
    "biomarker_code": "VITD_25OH",
    "sex": None,
    "age_min": 19,
    "age_max": 59,
    "pregnancy": False,
    "low": 20,
    "high": 100,
    "borderline_low": 30,
    "critical_low": 10,
    "source_citation": "Endocrine Society Clinical Practice Guideline 2011",
}


def upload(client, auth, data: bytes = PDF, name: str = "report.pdf"):
    return request(
        client,
        "POST",
        "/v1/reports",
        headers=auth,
        files={"file": (name, data, "application/pdf")},
    )


def seed_reference(store) -> None:
    store.seed("reference_ranges", [VITD_RANGE])
    store.seed(
        "health_profiles",
        [{"user_id": USER_ID, "dob": "1994-03-02", "sex": "male", "height_cm": 172,
          "weight_kg": 74, "activity_level": "moderate", "diet_type": "non_veg",
          "cuisine_pref": [], "conditions": [], "meal_times": {}, "pregnancy": False}],
    )


# --------------------------------------------------------------------------- ingest


def test_a_report_is_extracted_classified_and_stored(client, auth, store, gemini):
    consented(store)
    seed_reference(store)
    gemini.queue(EXTRACTION)

    response = upload(client, auth)
    assert response.status_code == 201, response.text
    body = response.json()

    assert body["report"]["lab_name"] == "Apollo Diagnostics"
    assert body["report"]["status"] == "extracted"
    codes = {r["biomarker_code"]: r for r in body["results"]}
    assert "VITD_25OH" in codes
    # 14.2 ng/mL against our own range, not the lab's printed 30-100.
    assert codes["VITD_25OH"]["status"] == "low"
    assert codes["VITD_25OH"]["needs_review"] is False

    # The row we could not map is surfaced, never guessed at.
    reviewed = [item["printed_test_name"] for item in body["review"]]
    assert "Zorblax Factor" in reviewed
    assert all(r["biomarker_code"] != "" for r in body["results"])

    # It really was persisted, scoped to this user.
    stored = store.rows("lab_results")
    assert {row["user_id"] for row in stored} == {USER_ID}
    assert store.rows("report_extractions")[0]["model"]


def test_the_same_file_is_never_extracted_twice(client, auth, store, gemini):
    consented(store)
    seed_reference(store)
    gemini.queue(EXTRACTION)

    first = upload(client, auth)
    assert first.status_code == 201
    assert len(gemini.calls) == 1

    # Second upload of the same bytes. No response is queued, so a model call would fail.
    second = upload(client, auth)
    assert second.status_code == 201, second.text
    assert len(gemini.calls) == 1, "the model was called again for a file we already had"
    assert second.json()["reused_extraction"] is True
    assert len(store.rows("reports")) == 1
    assert len(store.rows("report_extractions")) == 1


def test_a_different_file_is_extracted(client, auth, store, gemini):
    consented(store)
    seed_reference(store)
    gemini.queue(EXTRACTION)
    gemini.queue(EXTRACTION)
    assert upload(client, auth, PDF).status_code == 201
    assert upload(client, auth, OTHER_PDF, "second.pdf").status_code == 201
    assert len(gemini.calls) == 2
    assert len(store.rows("reports")) == 2


def test_a_critical_value_raises_a_red_flag_with_guarded_text(client, auth, store, gemini):
    consented(store)
    seed_reference(store)
    gemini.queue(
        {
            "lab_name": "Apollo",
            "collected_on": "2026-08-14",
            "rows": [
                {"printed_test_name": "Haemoglobin", "value_text": "6.2",
                 "unit_text": "g/dL", "confidence": 0.99},
            ],
        }
    )
    response = upload(client, auth)
    assert response.status_code == 201, response.text
    body = response.json()
    assert body["escalation"] == "urgent"
    assert body["red_flags"], "a haemoglobin of 6.2 must reach a clinician"
    assert all(isinstance(flag["message"], str) for flag in body["red_flags"])


def test_an_extraction_failure_marks_the_report_failed(client, auth, store, gemini):
    from app.ai.client import GeminiRateLimited

    consented(store)
    seed_reference(store)
    gemini.queue(GeminiRateLimited("quota"))

    response = upload(client, auth)
    assert response.status_code == 503
    assert problem(response)["type"].endswith("/upstream-unavailable")
    assert store.rows("reports")[0]["status"] == "failed"
    # The file is kept, so the user does not have to photograph it again.
    assert store.storage


def test_the_review_queue_is_rebuilt_without_a_model_call(client, auth, store, gemini):
    consented(store)
    seed_reference(store)
    gemini.queue(EXTRACTION)
    report_id = upload(client, auth).json()["report"]["id"]

    response = request(client, "GET", f"/v1/reports/{report_id}/review", headers=auth)
    assert response.status_code == 200
    assert len(gemini.calls) == 1
    assert any(item["printed_test_name"] == "Zorblax Factor" for item in response.json())


def test_confirming_a_value_clears_needs_review(client, auth, store, gemini):
    """A value read with low confidence maps, but is not trusted until the user says so."""
    consented(store)
    seed_reference(store)
    gemini.queue(
        {
            "lab_name": "Apollo",
            "collected_on": "2026-08-14",
            "rows": [
                {"printed_test_name": "Vitamin D (25-OH)", "value_text": "14.2",
                 "unit_text": "ng/mL", "confidence": 0.42},
            ],
        }
    )
    uploaded = upload(client, auth)
    assert uploaded.status_code == 201, uploaded.text
    report_id = uploaded.json()["report"]["id"]
    assert uploaded.json()["results"][0]["needs_review"] is True

    flagged = [row for row in store.rows("lab_results") if row["needs_review"]]
    assert flagged, "a low-confidence reading must be confirmed by the user"
    response = request(
        client,
        "POST",
        f"/v1/reports/{report_id}/results/{flagged[0]['id']}/confirm",
        headers=auth,
        json={"confirmed": True},
    )
    assert response.status_code == 200
    assert flagged[0]["confirmed_by_user"] is True


def test_report_status_is_a_cheap_poll(client, auth, store, gemini):
    consented(store)
    seed_reference(store)
    gemini.queue(EXTRACTION)
    report_id = upload(client, auth).json()["report"]["id"]
    response = request(client, "GET", f"/v1/reports/{report_id}/status", headers=auth)
    assert response.json() == {"id": report_id, "status": "extracted"}


def test_a_report_belonging_to_someone_else_is_not_found(client, auth, store):
    from tests.conftest import OTHER_USER_ID

    store.seed(
        "reports",
        [{"user_id": OTHER_USER_ID, "storage_path": f"{OTHER_USER_ID}/x.pdf",
          "file_hash": "a" * 64, "mime_type": "application/pdf", "status": "extracted",
          "lab_name": "Someone Else's Lab"}],
    )
    report_id = store.rows("reports")[0]["id"]
    response = request(client, "GET", f"/v1/reports/{report_id}", headers=auth)
    assert response.status_code == 404
    assert "Someone Else" not in response.text


# ---------------------------------------------------------------------------- plan


def seed_foods(store) -> list[str]:
    store.seed(
        "foods",
        [
            {"name": "Ragi", "food_group": "Millets", "region": "south",
             "per_100g": {"kcal": 328, "protein_g": 7.3, "iron_mg": 3.9, "fibre_g": 11.5},
             "diet_flags": ["veg", "vegan"], "allergens": [], "source": "IFCT2017"},
            {"name": "Egg, whole", "food_group": "Eggs",
             "per_100g": {"kcal": 143, "protein_g": 12.6, "vitamin_d_ug": 2.0},
             "diet_flags": ["egg", "non_veg"], "allergens": ["egg"], "source": "USDA"},
        ],
    )
    return [row["id"] for row in store.rows("foods")]


def test_regenerating_a_plan_recomputes_every_number_from_the_foods_table(
    client, auth, store, gemini
):
    consented(store)
    seed_reference(store)
    food_ids = seed_foods(store)
    gemini.queue(
        {
            "items": [
                {
                    "meal_slot": "breakfast",
                    "food_id": food_ids[0],
                    "grams": 100,
                    # The model's own nutrient claim, in prose. It must not survive.
                    "why": "This has 99 g of protein and cures anaemia.",
                    "order_index": 0,
                }
            ],
            "hydration_ml": 2500,
            "rationale": "A steady day around foods you already eat, with more iron in it.",
        }
    )

    response = request(
        client, "POST", "/v1/plan/regenerate", headers=auth, json={"plan_date": "2026-09-09"}
    )
    assert response.status_code == 200, response.text
    body = response.json()

    item = body["items"][0]
    assert item["display_name"] == "Ragi"
    # Straight from per_100g at 100 g, not from anything the model said.
    assert item["computed_nutrients"]["iron_mg"] == pytest.approx(3.9)
    assert item["computed_nutrients"]["protein_g"] == pytest.approx(7.3)
    assert "99 g" not in item["why_text"]
    assert "cures" not in item["why_text"]
    assert body["hydration_ml"] == 2500
    assert "not a doctor" in body["rationale"]


def test_a_plan_naming_a_food_we_do_not_have_drops_the_item(client, auth, store, gemini):
    consented(store)
    seed_reference(store)
    seed_foods(store)
    gemini.queue(
        {
            "items": [
                {"meal_slot": "lunch", "food_id": "a-food-the-model-invented",
                 "grams": 150, "why": "invented", "order_index": 0}
            ],
            "hydration_ml": 2000,
            "rationale": "A simple day.",
        }
    )
    response = request(
        client, "POST", "/v1/plan/regenerate", headers=auth, json={"plan_date": "2026-09-09"}
    )
    assert response.status_code == 200
    assert response.json()["items"] == []


def test_an_unsafe_rationale_means_no_plan_is_stored(client, auth, store, gemini):
    consented(store)
    seed_reference(store)
    food_ids = seed_foods(store)
    unsafe = {
        "items": [{"meal_slot": "breakfast", "food_id": food_ids[0], "grams": 100,
                   "why": "good", "order_index": 0}],
        "hydration_ml": 2000,
        "rationale": "You have diabetes. Take metformin 500 mg twice a day.",
    }
    gemini.queue(unsafe)
    gemini.queue(unsafe)  # the one regeneration the pipeline allows

    response = request(
        client, "POST", "/v1/plan/regenerate", headers=auth, json={"plan_date": "2026-09-09"}
    )
    assert response.status_code == 503
    assert "metformin" not in response.text.lower()
    assert store.rows("meal_plans") == []
    assert "plan_blocked" in [row["event_type"] for row in store.rows("health_events")]


def test_a_regenerated_rationale_is_the_safe_one(client, auth, store, gemini):
    consented(store)
    seed_reference(store)
    food_ids = seed_foods(store)
    items = [{"meal_slot": "breakfast", "food_id": food_ids[0], "grams": 100,
              "why": "good", "order_index": 0}]
    gemini.queue({"items": items, "hydration_ml": 2000,
                  "rationale": "Take metformin 500 mg with breakfast."})
    gemini.queue({"items": items, "hydration_ml": 2000,
                  "rationale": "Breakfast is built around ragi for the iron in it."})

    response = request(
        client, "POST", "/v1/plan/regenerate", headers=auth, json={"plan_date": "2026-09-09"}
    )
    assert response.status_code == 200, response.text
    assert response.json()["safety_verdict"] == "regenerated"
    assert "metformin" not in response.text.lower()
    assert "ragi" in response.json()["rationale"].lower()


def test_generating_a_plan_writes_the_alert_schedule(client, auth, store, gemini):
    consented(store)
    seed_reference(store)
    food_ids = seed_foods(store)
    gemini.queue(
        {
            "items": [{"meal_slot": "breakfast", "food_id": food_ids[0], "grams": 100,
                       "why": "good", "order_index": 0}],
            "hydration_ml": 2000,
            "rationale": "A simple day, built around what you like.",
        }
    )
    request(client, "POST", "/v1/plan/regenerate", headers=auth, json={"plan_date": "2026-09-09"})

    kinds = {row["alert_type"] for row in store.rows("alerts")}
    assert "meal" in kinds
    assert "hydration" in kinds
    assert "sleep" in kinds
    assert {row["user_id"] for row in store.rows("alerts")} == {USER_ID}


def test_an_ai_run_is_recorded_with_a_hash_and_no_text(client, auth, store, gemini):
    consented(store)
    seed_reference(store)
    gemini.queue(EXTRACTION)
    upload(client, auth)
    runs = store.rows("ai_runs")
    assert runs, "every model call must leave an audit row"
    text = json.dumps(runs)
    assert "Vitamin D" not in text
    assert len(runs[0]["prompt_hash"]) == 64


# ---------------------------------------------------------------------------- chat


def test_chat_reply_is_guarded_and_carries_the_disclaimer(client, auth, store, gemini):
    consented(store)
    seed_reference(store)
    seed_foods(store)
    gemini.queue(
        {
            "reply": "Low vitamin D is common. Morning sunlight and eggs both help.",
            "follow_up_questions": ["How many hours are you outdoors on a usual day?"],
            "needs_more_info": True,
        }
    )
    response = request(
        client,
        "POST",
        "/v1/chat/messages",
        headers=auth,
        json={"message": "My vitamin D came back low, what should I eat?"},
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert "not a doctor" in body["reply"]
    assert body["follow_up_questions"] == ["How many hours are you outdoors on a usual day?"]
    assert body["safety_verdict"] == "pass"
    roles = [row["role"] for row in store.rows("chat_messages")]
    assert roles == ["user", "assistant"]


def test_a_red_flag_symptom_escalates_before_the_model_is_asked(client, auth, store, gemini):
    consented(store)
    seed_reference(store)
    seed_foods(store)
    gemini.queue(
        {
            "reply": "Sorry to hear that. Rest and drink water.",
            "follow_up_questions": [],
            "needs_more_info": False,
        }
    )
    response = request(
        client,
        "POST",
        "/v1/chat/messages",
        headers=auth,
        json={"message": "I have crushing chest pain going down my left arm"},
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["escalation"] == "urgent"
    assert body["red_flags"], "chest pain must be caught by the deterministic classifier"
    assert body["reply"].startswith("GET MEDICAL CARE NOW")
    assert "symptom_red_flag" in [row["event_type"] for row in store.rows("health_events")]


def test_an_unsafe_chat_answer_returns_the_fallback_and_no_questions(
    client, auth, store, gemini
):
    consented(store)
    seed_reference(store)
    seed_foods(store)
    unsafe = {
        "reply": "You have hypothyroidism. Start thyronorm 50 mcg every morning.",
        "follow_up_questions": ["Which brand of thyronorm do you take?"],
        "needs_more_info": False,
    }
    gemini.queue(unsafe)
    gemini.queue(unsafe)

    response = request(
        client, "POST", "/v1/chat/messages", headers=auth, json={"message": "my TSH is high"}
    )
    assert response.status_code == 200
    body = response.json()
    assert "thyronorm" not in response.text.lower()
    assert "50 mcg" not in response.text
    assert body["follow_up_questions"] == []
    assert body["safety_verdict"] == "blocked"
    # What was stored is the safe text, not the model's.
    stored = [row["content"] for row in store.rows("chat_messages") if row["role"] == "assistant"]
    assert "thyronorm" not in stored[0].lower()


def test_chat_attachments_must_belong_to_the_caller(client, auth, store, gemini):
    from tests.conftest import OTHER_USER_ID

    consented(store)
    seed_reference(store)
    store.seed(
        "reports",
        [{"user_id": OTHER_USER_ID, "storage_path": "x/y.pdf", "file_hash": "b" * 64,
          "status": "extracted"}],
    )
    other_id = store.rows("reports")[0]["id"]
    response = request(
        client,
        "POST",
        "/v1/chat/messages",
        headers=auth,
        json={"message": "look at this", "attachment_report_ids": [other_id]},
    )
    assert response.status_code == 404


def test_a_message_that_is_too_long_is_refused(client, auth, store):
    consented(store)
    response = request(
        client, "POST", "/v1/chat/messages", headers=auth, json={"message": "x" * 5000}
    )
    assert response.status_code == 422


# -------------------------------------------------------------------------- privacy


def test_export_returns_only_the_callers_rows(client, auth, store):
    from tests.conftest import OTHER_USER_ID

    consented(store)
    store.seed("food_logs", [{"user_id": USER_ID, "free_text": "idli", "logged_at": "2026-09-09"}])
    store.seed("food_logs", [{"user_id": OTHER_USER_ID, "free_text": "someone else's dinner"}])

    response = request(client, "GET", "/v1/privacy/export", headers=auth)
    assert response.status_code == 200
    assert response.headers["content-disposition"].endswith('filename="healthpulse-export.json"')
    body = response.json()
    assert body["user_id"] == USER_ID
    assert "idli" in json.dumps(body)
    assert "someone else's dinner" not in json.dumps(body)


def test_delete_requires_the_confirmation_phrase(client, auth, store):
    response = request(
        client, "POST", "/v1/privacy/delete", headers=auth, json={"confirm": "yes"}
    )
    assert response.status_code == 422
    assert "DELETE MY HEALTH DATA" in problem(response)["detail"]


def test_delete_removes_rows_and_storage_and_writes_a_receipt(client, auth, store, gemini):
    from tests.conftest import OTHER_USER_ID

    consented(store)
    seed_reference(store)
    gemini.queue(EXTRACTION)
    upload(client, auth)

    store.seed("chat_threads", [{"user_id": USER_ID, "title": "Chat"}])
    thread_id = store.rows("chat_threads")[-1]["id"]
    store.seed(
        "chat_messages",
        [{"user_id": USER_ID, "thread_id": thread_id, "role": "user", "content": "hello"}],
    )
    store.seed("food_logs", [{"user_id": OTHER_USER_ID, "free_text": "not mine"}])
    store.storage[f"{OTHER_USER_ID}/theirs.pdf"] = b"theirs"

    assert store.rows("reports")
    assert any(path.startswith(USER_ID) for path in store.storage)

    response = request(
        client,
        "POST",
        "/v1/privacy/delete",
        headers=auth,
        json={"confirm": "DELETE MY HEALTH DATA"},
    )
    assert response.status_code == 200, response.text
    receipt = response.json()
    assert receipt["objects_deleted"] >= 1
    assert receipt["rows_deleted"] > 0
    assert receipt["completed_at"]

    # Every user-owned table is empty of this user...
    from app.repositories.privacy import APPEND_ONLY_TABLES, USER_TABLES_CHILD_FIRST

    for table in (*USER_TABLES_CHILD_FIRST, *APPEND_ONLY_TABLES):
        remaining = [row for row in store.rows(table) if row.get("user_id") == USER_ID]
        assert remaining == [], f"{table} still holds rows for the deleted user"

    # ...their files are gone, and nobody else's are touched.
    assert not any(path.startswith(USER_ID) for path in store.storage)
    assert f"{OTHER_USER_ID}/theirs.pdf" in store.storage
    assert any(row["free_text"] == "not mine" for row in store.rows("food_logs"))

    # The receipt survives, and holds no health data.
    receipts = store.rows("deletion_requests")
    assert len(receipts) == 1
    assert receipts[0]["completed_at"]
    assert receipts[0]["rows_deleted"] == receipt["rows_deleted"]
    assert "Vitamin" not in json.dumps(receipts[0])


def test_deletion_uses_the_service_role_and_says_why(client, auth, store):
    request(
        client,
        "POST",
        "/v1/privacy/delete",
        headers=auth,
        json={"confirm": "DELETE MY HEALTH DATA"},
    )
    assert store.service_role_uses, "deletion must ask for the service role explicitly"
    assert "forgotten" in store.service_role_uses[0]


def test_no_other_endpoint_uses_the_service_role(client, auth, store, gemini):
    """Everything else runs as the user, so RLS is the boundary."""
    consented(store)
    seed_reference(store)
    seed_foods(store)
    gemini.queue(EXTRACTION)

    upload(client, auth)
    request(client, "GET", "/v1/me", headers=auth)
    request(client, "GET", "/v1/me/profile", headers=auth)
    request(client, "GET", "/v1/reports", headers=auth)
    request(client, "GET", "/v1/alerts", headers=auth)
    request(client, "GET", "/v1/grocery", headers=auth)
    request(client, "GET", "/v1/privacy/export", headers=auth)
    request(client, "GET", f"/v1/plan/{date.today().isoformat()}", headers=auth)

    assert store.service_role_uses == []


def test_a_stored_report_keeps_its_red_flags_and_hydration(client, auth, store, gemini):
    """Neither is a column, and neither is lost: both are recomputed or read back."""
    consented(store)
    seed_reference(store)
    gemini.queue(
        {
            "lab_name": "Apollo",
            "collected_on": "2026-08-14",
            "rows": [
                {"printed_test_name": "Haemoglobin", "value_text": "6.2",
                 "unit_text": "g/dL", "confidence": 0.99},
            ],
        }
    )
    report_id = upload(client, auth).json()["report"]["id"]

    detail = request(client, "GET", f"/v1/reports/{report_id}", headers=auth)
    assert detail.status_code == 200, detail.text
    assert detail.json()["escalation"] == "urgent"
    assert detail.json()["red_flags"], "stage 5 must be re-run when a report is re-read"

    food_ids = seed_foods(store)
    gemini.queue(
        {
            "items": [{"meal_slot": "breakfast", "food_id": food_ids[0], "grams": 100,
                       "why": "good", "order_index": 0}],
            "hydration_ml": 2600,
            "rationale": "A simple day built around ragi.",
        }
    )
    request(client, "POST", "/v1/plan/regenerate", headers=auth,
            json={"plan_date": "2026-09-09"})

    stored_plan = request(client, "GET", "/v1/plan/2026-09-09", headers=auth)
    assert stored_plan.status_code == 200, stored_plan.text
    assert stored_plan.json()["hydration_ml"] == 2600

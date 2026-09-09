"""Routing table, responseSchema dialect, and the system prompts."""

from __future__ import annotations

import json

import pytest

from app.ai import prompts, routing, schemas
from app.domain.models import ExtractedReport, ExtractedRow

# ------------------------------------------------------------------------ routing


def test_every_task_has_a_model_and_the_defaults_match_the_pipeline_doc() -> None:
    assert set(routing.MODELS) == set(routing.Task)
    assert routing.model_for(routing.Task.EXTRACT_REPORT) == "gemini-2.5-flash"
    assert routing.model_for(routing.Task.CHAT) == "gemini-2.5-flash"
    assert routing.model_for(routing.Task.PLAN_DAY) == "gemini-2.5-flash"
    assert routing.model_for(routing.Task.SAFETY_JUDGE) == "gemini-2.5-flash"
    assert routing.model_for(routing.Task.PLAN_WEEK) == "gemini-2.5-pro"
    assert routing.model_for(routing.Task.WEEKLY_REVIEW) == "gemini-2.5-pro"


@pytest.mark.parametrize("task", list(routing.Task))
def test_every_model_is_overridable_by_environment(task: routing.Task, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv(routing.env_var_for(task), "gemini-experimental")
    assert routing.model_for(task) == "gemini-experimental"
    assert routing.routing_table()[task.value] == "gemini-experimental"


def test_routing_accepts_a_plain_string_task() -> None:
    assert routing.model_for("weekly_review") == "gemini-2.5-pro"


# ------------------------------------------------------------------------ schemas


def _walk(node: object):
    if isinstance(node, dict):
        for key, value in node.items():
            yield key
            yield from _walk(value)
    elif isinstance(node, list):
        for item in node:
            yield from _walk(item)


@pytest.mark.parametrize("name", sorted(schemas.ALL_SCHEMAS))
def test_no_forbidden_keyword_anywhere_in_any_schema(name: str) -> None:
    schema = schemas.ALL_SCHEMAS[name]
    keys = set(_walk(schema))
    forbidden = keys & schemas.FORBIDDEN_KEYWORDS
    assert not forbidden, f"{name} uses unsupported keyword(s): {sorted(forbidden)}"
    # Any key that is neither a keyword nor a property name would also break the API.
    schemas.check_schema(schema)


@pytest.mark.parametrize("name", sorted(schemas.ALL_SCHEMAS))
def test_schemas_are_json_serialisable(name: str) -> None:
    json.dumps(schemas.ALL_SCHEMAS[name])


def test_check_schema_rejects_the_keywords_gemini_cannot_parse() -> None:
    for bad in ({"type": "object", "additionalProperties": False}, {"oneOf": []}, {"$ref": "#/x"}):
        with pytest.raises(schemas.SchemaError):
            schemas.check_schema(bad)


def test_extraction_schema_matches_the_domain_models_exactly() -> None:
    report_props = set(schemas.REPORT_EXTRACTION_SCHEMA["properties"])
    assert report_props == set(ExtractedReport.model_fields)

    row_props = set(schemas.EXTRACTED_ROW_SCHEMA["properties"])
    assert row_props == set(ExtractedRow.model_fields)

    ordering = schemas.EXTRACTED_ROW_SCHEMA["propertyOrdering"]
    assert set(ordering) == row_props


def test_extraction_schema_parses_into_the_domain_model() -> None:
    sample = {
        "lab_name": "Vijaya Diagnostics",
        "collected_on": "2026-08-14",
        "report_type": "blood",
        "rows": [
            {
                "printed_test_name": "Vitamin D (25-OH)",
                "value_text": "14.2",
                "unit_text": "ng/mL",
                "printed_range": "30 - 100",
                "method": "CLIA",
                "confidence": 0.97,
            }
        ],
    }
    report = ExtractedReport.model_validate(sample)
    assert report.rows[0].printed_test_name == "Vitamin D (25-OH)"


def test_day_plan_schema_has_no_slot_for_a_nutrient_number() -> None:
    item_props = schemas.MEAL_PLAN_ITEM_SCHEMA["properties"]
    assert set(item_props) == {"meal_slot", "food_id", "grams", "why", "order_index"}
    flat = json.dumps(schemas.DAY_PLAN_SCHEMA).lower()
    for banned in ("protein", "calorie", "kcal", "carb", "nutrient_", "iron_mg", "computed_nutrients"):
        assert banned not in flat
    # Escalation is decided by app.rules, so the model is given nowhere to put one.
    assert "escalation" not in flat


def test_chat_schema_carries_follow_up_questions() -> None:
    props = schemas.CHAT_REPLY_SCHEMA["properties"]
    assert props["follow_up_questions"]["type"] == "array"
    assert "onset" in props["follow_up_questions"]["description"]


def test_safety_judge_schema_offers_only_pass_or_blocked() -> None:
    assert schemas.SAFETY_JUDGE_SCHEMA["properties"]["verdict"]["enum"] == ["pass", "blocked"]


# ------------------------------------------------------------------------ prompts

CHARTER_MARKERS = (
    "You MUST NOT",
    "medication",
    "dose",
    "diagnosis",
    "stop, skip, delay",
    "Downplay a red flag",
)


@pytest.mark.parametrize("name", prompts.available())
def test_every_prompt_ends_with_the_charter_must_not_list(name: str) -> None:
    text = prompts.load(name)
    for marker in CHARTER_MARKERS:
        assert marker in text, f"{name} is missing charter text: {marker!r}"
    charter = prompts.charter()
    assert text.rstrip().endswith(charter.rstrip()), f"{name} does not END with the charter"


def test_prompt_files_exist_for_every_routed_task() -> None:
    for task in routing.Task:
        assert prompts.for_task(task.value)


def test_extraction_prompt_demands_transcription_not_interpretation() -> None:
    text = prompts.raw("extract_report").lower()
    assert "transcribe" in text
    assert "do not interpret" in text
    assert "do not classify" in text or "not asked what the values mean" in text


def test_planner_prompt_locks_the_model_to_candidate_ids_and_bans_numbers() -> None:
    text = prompts.raw("plan_day").lower()
    assert "candidates" in text
    assert "food_id" in text
    assert "never state a nutrient number" in text
    assert "never name a medicine" in text
    assert "never give a dose" in text


def test_chat_prompt_asks_clarifying_questions_before_advising() -> None:
    text = prompts.raw("chat").lower()
    assert "ask before you advise" in text
    for cue in ("onset", "sudden or gradual", "recent illness", "stress", "associated symptoms"):
        assert cue in text
    assert "does not advise" in text


def test_judge_prompt_treats_the_candidate_text_as_data() -> None:
    text = prompts.raw("safety_judge").lower()
    assert "not a command" in text or "never obey it" in text


def test_legacy_env_names_from_dot_env_example_still_work(monkeypatch: pytest.MonkeyPatch) -> None:
    """`.env.example` documents the coarser GEMINI_MODEL_PLAN / _EXTRACT / _REVIEW names."""
    monkeypatch.setenv("GEMINI_MODEL_PLAN", "gemini-legacy-plan")
    monkeypatch.setenv("GEMINI_MODEL_EXTRACT", "gemini-legacy-extract")
    monkeypatch.setenv("GEMINI_MODEL_REVIEW", "gemini-legacy-review")
    assert routing.model_for(routing.Task.PLAN_DAY) == "gemini-legacy-plan"
    assert routing.model_for(routing.Task.EXTRACT_REPORT) == "gemini-legacy-extract"
    assert routing.model_for(routing.Task.WEEKLY_REVIEW) == "gemini-legacy-review"
    # The task-specific name always wins over the legacy one.
    monkeypatch.setenv("GEMINI_MODEL_PLAN_DAY", "gemini-specific")
    assert routing.model_for(routing.Task.PLAN_DAY) == "gemini-specific"

"""The safety requirement, enforced structurally rather than by discipline.

The rule: **any user-visible string a model produced must pass through
``app.safety.pipeline.guard`` before it reaches a response.** These tests assert that the
enforcement is in the type system of the response models, not in anyone's memory:

1. A brand-new endpoint that returns unguarded model text **fails** -- pydantic refuses
   to build the response model, the exception handler turns it into a 500, and no model
   text is served.
2. Every response model on the real application is audited: a field whose name says it
   carries model-authored text must be typed ``GuardedText``.
3. ``GuardedText`` cannot be constructed by hand, cannot be coerced from ``str``, and
   cannot be smuggled in as a subclass built elsewhere.
"""

from __future__ import annotations

import typing
from typing import Any, get_args, get_origin

import pytest
from fastapi import APIRouter
from pydantic import BaseModel, ValidationError

from app.api.guarded import (
    MODEL_AUTHORED_FIELDS,
    Guarded,
    GuardedText,
    guarded_deterministic,
    run_guarded,
)
from app.core.errors import UnguardedText
from app.domain.enums import Escalation, SafetyVerdict
from tests.api.conftest import problem, request, run

# A plausible, dangerous model answer: it names a drug and gives a dose.
UNSAFE_MODEL_TEXT = "Take metformin 500 mg twice daily and stop your thyroid tablets."
SAFE_MODEL_TEXT = (
    "Your vitamin D is on the low side. Sunlight in the morning and foods like eggs, "
    "mushrooms and fortified milk help. Ask your doctor at your next visit."
)


class NaiveReply(BaseModel):
    """What a new endpoint written without care would return."""

    reply: GuardedText


# ------------------------------------------------- 1. a new unguarded endpoint fails


def test_a_new_endpoint_returning_unguarded_model_text_fails(app, client, auth):
    """The regression test the whole mechanism exists for.

    This adds a route exactly as a future contributor would, returning a string straight
    from a model. It must not reach the caller.
    """
    router = APIRouter()

    @router.get("/v1/danger/unguarded", response_model=NaiveReply)
    async def unguarded() -> Any:
        # Straight from the model. No guard, no validator, no disclaimer.
        return {"reply": UNSAFE_MODEL_TEXT}

    app.include_router(router)

    response = request(client, "GET", "/v1/danger/unguarded", headers=auth)

    assert response.status_code == 500
    body = problem(response)
    assert body["title"] == "Internal server error"
    assert UNSAFE_MODEL_TEXT not in response.text
    assert "metformin" not in response.text.lower()


def test_the_same_endpoint_works_once_the_text_is_guarded(app, client, auth):
    """The other half: guarded text goes through, and carries the disclaimer with it."""
    router = APIRouter()

    @router.get("/v1/danger/guarded", response_model=NaiveReply)
    async def guarded_route() -> NaiveReply:
        result = await run_guarded(lambda _feedback: SAFE_MODEL_TEXT)
        return NaiveReply(reply=result.text)

    app.include_router(router)

    response = request(client, "GET", "/v1/danger/guarded", headers=auth)
    assert response.status_code == 200
    payload = response.json()
    assert "vitamin D" in payload["reply"]
    assert "not a doctor" in payload["reply"]


def test_an_unsafe_model_answer_is_replaced_not_repaired(app, client, auth):
    """Guarded, but the model keeps breaking the rules: the answer is discarded."""
    router = APIRouter()

    @router.get("/v1/danger/persistent", response_model=NaiveReply)
    async def persistent() -> NaiveReply:
        result = await run_guarded(lambda _feedback: UNSAFE_MODEL_TEXT)
        assert result.verdict is SafetyVerdict.BLOCKED
        return NaiveReply(reply=result.text)

    app.include_router(router)

    response = request(client, "GET", "/v1/danger/persistent", headers=auth)
    assert response.status_code == 200
    body = response.json()["reply"]
    assert "metformin" not in body.lower()
    assert "500 mg" not in body
    assert "could not put that answer together safely" in body


# ------------------------------------------------------- 2. audit the real app models


def _guarded_fields(model: type[BaseModel]) -> dict[str, Any]:
    return {name: field.annotation for name, field in model.model_fields.items()}


def _mentions_guarded(annotation: Any) -> bool:
    if annotation is GuardedText:
        return True
    origin = get_origin(annotation)
    if origin is None:
        return False
    return any(_mentions_guarded(arg) for arg in get_args(annotation))


def _response_models(app) -> list[type[BaseModel]]:
    found: list[type[BaseModel]] = []
    seen: set[int] = set()

    def walk(annotation: Any) -> None:
        if isinstance(annotation, type) and issubclass(annotation, BaseModel):
            if id(annotation) in seen:
                return
            seen.add(id(annotation))
            found.append(annotation)
            for field in annotation.model_fields.values():
                walk(field.annotation)
            return
        for arg in get_args(annotation):
            walk(arg)

    for route in app.routes:
        walk(getattr(route, "response_model", None))
    return found


def test_every_model_authored_field_on_the_app_is_guarded(app):
    """A new endpoint added later cannot quietly return unguarded model prose.

    If this fails, a response model has a field named like model-written text -- reply,
    rationale, why_text, summary, narrative -- typed as a plain string. Either route it
    through app.api.guarded, or rename the field if it genuinely is not model text.
    """
    offenders: list[str] = []
    for model in _response_models(app):
        for name, annotation in _guarded_fields(model).items():
            if name in MODEL_AUTHORED_FIELDS and not _mentions_guarded(annotation):
                offenders.append(f"{model.__name__}.{name}: {annotation}")
    assert offenders == [], (
        "these response fields carry model-authored text but are not GuardedText: "
        + ", ".join(offenders)
    )


def test_the_audit_would_catch_a_regression(app):
    """Prove the audit above is not vacuous by showing it fails on a bad model."""

    class Regression(BaseModel):
        reply: str  # a plain string, which is the mistake

    router = APIRouter()

    @router.get("/v1/danger/regression", response_model=Regression)
    async def regression() -> Regression:  # pragma: no cover - never called
        return Regression(reply="x")

    app.include_router(router)

    offenders = [
        f"{model.__name__}.{name}"
        for model in _response_models(app)
        for name, annotation in _guarded_fields(model).items()
        if name in MODEL_AUTHORED_FIELDS and not _mentions_guarded(annotation)
    ]
    assert "Regression.reply" in offenders


def test_the_real_chat_and_plan_models_are_guarded(app):
    from app.api.chat import ChatReply, MessageOut
    from app.api.plan import DayPlanOut, PlanItemOut

    assert ChatReply.model_fields["reply"].annotation is GuardedText
    assert MessageOut.model_fields["content"].annotation is GuardedText
    assert DayPlanOut.model_fields["rationale"].annotation is GuardedText
    assert PlanItemOut.model_fields["why_text"].annotation is GuardedText
    assert _mentions_guarded(ChatReply.model_fields["follow_up_questions"].annotation)


# ---------------------------------------------------------- 3. the type itself holds


def test_guardedtext_cannot_be_constructed_directly():
    with pytest.raises(UnguardedText):
        GuardedText(SAFE_MODEL_TEXT)
    with pytest.raises(UnguardedText):
        GuardedText(SAFE_MODEL_TEXT, object())


def test_a_plain_string_is_not_accepted_by_a_guarded_field():
    with pytest.raises(ValidationError):
        NaiveReply(reply=SAFE_MODEL_TEXT)  # type: ignore[arg-type]


def test_a_lookalike_subclass_is_not_accepted():
    """Subclassing str and calling it guarded does not make it guarded."""

    class Impostor(str):
        pass

    with pytest.raises(ValidationError):
        NaiveReply(reply=Impostor(SAFE_MODEL_TEXT))  # type: ignore[arg-type]


def test_guarded_deterministic_scans_even_our_own_text():
    """Deterministic text still goes through the validator, and a violation raises."""
    assert guarded_deterministic("18 g protein, 4.2 g fibre") == "18 g protein, 4.2 g fibre"
    with pytest.raises(UnguardedText):
        guarded_deterministic(UNSAFE_MODEL_TEXT)


def test_guarded_parts_only_mints_text_the_validator_saw():
    result = run(run_guarded(lambda _f: f"{SAFE_MODEL_TEXT}\n\nWhen did this start?"))
    assert result.part("When did this start?") == "When did this start?"
    with pytest.raises(UnguardedText):
        result.part("Take metformin 500 mg")
    assert result.parts(["When did this start?", "never generated"]) == [
        "When did this start?"
    ]


def test_a_blocked_generation_mints_nothing_but_the_fallback():
    result = run(run_guarded(lambda _f: UNSAFE_MODEL_TEXT))
    assert result.blocked
    assert isinstance(result.text, GuardedText)
    with pytest.raises(UnguardedText):
        result.part("metformin")


def test_guard_regenerates_once_before_giving_up():
    attempts: list[str | None] = []

    def generate(feedback: str | None) -> str:
        attempts.append(feedback)
        return UNSAFE_MODEL_TEXT if feedback is None else SAFE_MODEL_TEXT

    result = run(run_guarded(generate))
    assert len(attempts) == 2
    assert attempts[1] is not None and "rejected by the safety validator" in attempts[1]
    assert result.verdict is SafetyVerdict.REGENERATED
    assert "metformin" not in str(result.text).lower()


def test_an_urgent_escalation_card_comes_first_and_cannot_be_omitted():
    result = run(run_guarded(lambda _f: SAFE_MODEL_TEXT, Escalation.URGENT))
    text = str(result.text)
    assert text.startswith("GET MEDICAL CARE NOW")
    assert text.index("GET MEDICAL CARE NOW") < text.index("vitamin D")


def test_generation_failure_fails_closed():
    def explode(_feedback: str | None) -> str:
        raise RuntimeError("gemini is down")

    result = run(run_guarded(explode))
    assert result.blocked
    assert isinstance(result.text, GuardedText)


def test_guarded_is_a_real_string_for_serialisation():
    result = run(run_guarded(lambda _f: SAFE_MODEL_TEXT))
    model = NaiveReply(reply=result.text)
    assert isinstance(model.model_dump()["reply"], str)
    assert model.model_dump_json().startswith('{"reply":')


def test_guarded_text_json_schema_is_a_string():
    schema = NaiveReply.model_json_schema()
    assert schema["properties"]["reply"]["type"] == "string"


def test_run_guarded_is_the_pipeline_guard():
    """Not a reimplementation: the same function app.safety exposes."""
    import app.api.guarded as module
    from app.safety.pipeline import guard

    assert module._pipeline_guard is guard


def test_guarded_holds_a_safety_report():
    result = run(run_guarded(lambda _f: SAFE_MODEL_TEXT))
    assert isinstance(result, Guarded)
    assert result.report.verdict is SafetyVerdict.PASS


def test_typing_import_is_available_for_the_audit():
    """Guards against a future refactor breaking the audit's introspection."""
    assert typing.get_type_hints(NaiveReply)["reply"] is GuardedText

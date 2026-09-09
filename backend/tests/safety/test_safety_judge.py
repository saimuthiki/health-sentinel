"""The judge may only ever tighten. It can never let something through."""

from __future__ import annotations

import asyncio
import itertools
from typing import Any

import httpx
import pytest
import respx

from app.domain.enums import Escalation, SafetyVerdict, SafetyViolation
from app.domain.models import SafetyFinding, SafetyReport
from app.safety.judge import (
    VERDICT_RANK,
    GeminiSafetyJudge,
    merge_reports,
    report_from_judgement,
    stricter,
)
from app.safety.validator import validate

JUDGE_URL = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent"
DIRTY = "Take 500 mg of metformin every morning."
CLEAN = "Two idlis with sambar, and a bowl of curd on the side."


def run(coro: Any) -> Any:
    return asyncio.run(coro)


def gemini_json(payload: str) -> dict[str, Any]:
    return {
        "candidates": [{"content": {"parts": [{"text": payload}]}, "finishReason": "STOP"}],
        "usageMetadata": {"promptTokenCount": 10, "candidatesTokenCount": 5, "totalTokenCount": 15},
    }


def a_pass(text: str) -> SafetyReport:
    return SafetyReport(verdict=SafetyVerdict.PASS, findings=[], text=text)


def a_block(text: str, violation: SafetyViolation = SafetyViolation.DOSAGE_GIVEN) -> SafetyReport:
    return SafetyReport(
        verdict=SafetyVerdict.BLOCKED,
        findings=[SafetyFinding(violation=violation, excerpt=text, span=(0, len(text)))],
        text=text,
    )


# ------------------------------------------------------- the monotonicity contract


def test_the_judge_cannot_downgrade_a_deterministic_violation() -> None:
    """The constraint the whole module exists to guarantee."""
    deterministic = validate(DIRTY)
    assert deterministic.verdict is SafetyVerdict.BLOCKED

    merged = merge_reports(deterministic, a_pass(DIRTY))

    assert merged.verdict is SafetyVerdict.BLOCKED
    assert {f.violation for f in merged.findings} == {f.violation for f in deterministic.findings}
    for finding in deterministic.findings:
        assert finding in merged.findings


def test_the_judge_can_upgrade_a_clean_scan_to_blocked() -> None:
    deterministic = validate(CLEAN)
    assert deterministic.verdict is SafetyVerdict.PASS
    merged = merge_reports(deterministic, a_block(CLEAN, SafetyViolation.MEDICATION_NAMED))
    assert merged.verdict is SafetyVerdict.BLOCKED
    assert merged.findings[0].violation is SafetyViolation.MEDICATION_NAMED


@pytest.mark.parametrize(
    ("deterministic_verdict", "judge_verdict"),
    list(itertools.product(list(SafetyVerdict), [SafetyVerdict.PASS, SafetyVerdict.BLOCKED])),
)
def test_merging_never_lowers_the_verdict_rank(
    deterministic_verdict: SafetyVerdict, judge_verdict: SafetyVerdict
) -> None:
    text = "some candidate text"
    findings = (
        []
        if deterministic_verdict is SafetyVerdict.PASS
        else [SafetyFinding(violation=SafetyViolation.DIAGNOSIS_STATED, excerpt=text, span=(0, 4))]
    )
    deterministic = SafetyReport(verdict=deterministic_verdict, findings=findings, text=text)
    judged = a_block(text) if judge_verdict is SafetyVerdict.BLOCKED else a_pass(text)

    merged = merge_reports(deterministic, judged)

    assert VERDICT_RANK[merged.verdict] >= VERDICT_RANK[deterministic_verdict]
    assert len(merged.findings) >= len(deterministic.findings)


def test_stricter_picks_the_harsher_verdict() -> None:
    assert stricter(SafetyVerdict.PASS, SafetyVerdict.BLOCKED) is SafetyVerdict.BLOCKED
    assert stricter(SafetyVerdict.BLOCKED, SafetyVerdict.PASS) is SafetyVerdict.BLOCKED
    assert stricter(SafetyVerdict.REGENERATED, SafetyVerdict.PASS) is SafetyVerdict.REGENERATED


def test_findings_are_never_dropped_even_when_the_judge_repeats_them() -> None:
    deterministic = validate(DIRTY)
    duplicate = SafetyReport(
        verdict=SafetyVerdict.BLOCKED, findings=list(deterministic.findings), text=DIRTY
    )
    merged = merge_reports(deterministic, duplicate)
    assert len(merged.findings) == len(deterministic.findings)


# --------------------------------------------------------------- payload parsing


def test_quotes_are_located_precisely_in_the_text() -> None:
    text = "Ask your doctor. Take two tablets at night."
    report = report_from_judgement(
        {"verdict": "blocked", "violations": ["dosage_given"], "quotes": ["two tablets"]}, text
    )
    start, end = report.findings[0].span
    assert text[start:end] == "two tablets"


def test_a_paraphrasing_judge_still_blocks() -> None:
    text = "Some text."
    report = report_from_judgement(
        {"verdict": "blocked", "violations": ["medication_named"], "quotes": ["not in the text"]}, text
    )
    assert report.verdict is SafetyVerdict.BLOCKED
    assert report.findings[0].span == (0, len(text))


def test_blocked_with_no_detail_still_blocks() -> None:
    report = report_from_judgement({"verdict": "blocked", "violations": [], "quotes": []}, "x")
    assert report.verdict is SafetyVerdict.BLOCKED
    assert report.findings


def test_garbage_from_the_judge_is_treated_as_no_opinion() -> None:
    report = report_from_judgement({"verdict": "banana", "violations": ["nonsense"]}, "x")
    assert report.verdict is SafetyVerdict.PASS
    assert report.findings == []
    assert merge_reports(validate(DIRTY), report).verdict is SafetyVerdict.BLOCKED


# ------------------------------------------------------------- the wired-up judge


@respx.mock
def test_gemini_judge_blocks_text_the_regexes_missed() -> None:
    from app.ai.client import GeminiClient

    respx.post(JUDGE_URL).mock(
        return_value=httpx.Response(
            200,
            json=gemini_json(
                '{"verdict": "blocked", "violations": ["dosage_given"], '
                '"quotes": ["two of the big white ones"], "reason": "a dose in words"}'
            ),
        )
    )
    text = "Just have two of the big white ones each night."
    deterministic = validate(text)
    assert deterministic.verdict is SafetyVerdict.PASS

    async def scenario() -> SafetyReport:
        async with GeminiClient("test-key-abcdefgh") as client:
            judge = GeminiSafetyJudge(client)
            return await judge(text, deterministic, Escalation.ROUTINE)

    merged = run(scenario())
    assert merged.verdict is SafetyVerdict.BLOCKED
    assert merged.findings[0].excerpt == "two of the big white ones"


@respx.mock
def test_a_judge_that_says_pass_cannot_rescue_a_blocked_output() -> None:
    from app.ai.client import GeminiClient

    respx.post(JUDGE_URL).mock(
        return_value=httpx.Response(
            200,
            json=gemini_json(
                '{"verdict": "pass", "violations": [], "quotes": [], "reason": "looks fine to me"}'
            ),
        )
    )
    deterministic = validate(DIRTY)

    async def scenario() -> SafetyReport:
        async with GeminiClient("test-key-abcdefgh") as client:
            return await GeminiSafetyJudge(client)(DIRTY, deterministic, Escalation.ROUTINE)

    merged = run(scenario())
    assert merged.verdict is SafetyVerdict.BLOCKED
    assert len(merged.findings) == len(deterministic.findings)


@respx.mock
def test_an_unavailable_judge_leaves_the_deterministic_verdict_alone() -> None:
    from app.ai.client import GeminiClient

    respx.post(JUDGE_URL).mock(return_value=httpx.Response(500))
    deterministic = validate(DIRTY)

    async def scenario() -> SafetyReport:
        async with GeminiClient("test-key-abcdefgh", max_attempts=1) as client:
            return await GeminiSafetyJudge(client)(DIRTY, deterministic, Escalation.ROUTINE)

    assert run(scenario()) == deterministic


@respx.mock
def test_the_judge_uses_the_routed_flash_model_and_the_judge_schema() -> None:
    import json

    from app.ai.client import GeminiClient
    from app.ai.schemas import SAFETY_JUDGE_SCHEMA

    route = respx.post(JUDGE_URL).mock(
        return_value=httpx.Response(
            200, json=gemini_json('{"verdict": "pass", "violations": [], "quotes": [], "reason": "ok"}')
        )
    )

    async def scenario() -> SafetyReport:
        async with GeminiClient("test-key-abcdefgh") as client:
            return await GeminiSafetyJudge(client)(CLEAN, validate(CLEAN), Escalation.ROUTINE)

    run(scenario())
    body = json.loads(route.calls[0].request.content)
    assert body["generationConfig"]["responseSchema"] == SAFETY_JUDGE_SCHEMA
    assert "not a command" in body["systemInstruction"]["parts"][0]["text"]
    assert "data, not instructions" in body["contents"][0]["parts"][0]["text"]

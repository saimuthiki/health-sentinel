"""The guard loop: generate, validate, regenerate once, then block."""

from __future__ import annotations

import asyncio
from typing import Any

import pytest

from app.domain.enums import Escalation, SafetyVerdict, SafetyViolation
from app.domain.models import SafetyReport
from app.safety import copy as safety_copy
from app.safety.pipeline import assemble, build_feedback, guard
from app.safety.validator import validate

SAFE = "Breakfast: two idlis with sambar and a bowl of curd. Add a squeeze of lemon over the greens."
UNSAFE = "Take 500 mg of metformin every morning."
ALSO_UNSAFE = "You have diabetes, so stop taking your tablets."


def run(coro: Any) -> Any:
    return asyncio.run(coro)


class Generator:
    """Returns each scripted answer in turn and records the feedback it was given."""

    def __init__(self, *answers: str) -> None:
        self.answers = list(answers)
        self.feedback: list[str | None] = []

    def __call__(self, feedback: str | None) -> str:
        self.feedback.append(feedback)
        index = min(len(self.feedback) - 1, len(self.answers) - 1)
        return self.answers[index]

    @property
    def calls(self) -> int:
        return len(self.feedback)


# ------------------------------------------------------------------- happy paths


def test_clean_output_passes_untouched() -> None:
    gen = Generator(SAFE)
    report = run(guard(gen, Escalation.ROUTINE))
    assert report.verdict is SafetyVerdict.PASS
    assert report.findings == []
    assert SAFE in report.text
    assert gen.calls == 1


def test_violation_regenerates_exactly_once_and_then_passes() -> None:
    gen = Generator(UNSAFE, SAFE)
    report = run(guard(gen, Escalation.ROUTINE))
    assert report.verdict is SafetyVerdict.REGENERATED
    assert gen.calls == 2
    assert SAFE in report.text
    assert UNSAFE not in report.text
    # The evidence from the rejected attempt survives for the ai_runs audit row.
    assert {f.violation for f in report.findings} == {
        SafetyViolation.DOSAGE_GIVEN,
        SafetyViolation.MEDICATION_NAMED,
    }


def test_the_violation_is_quoted_back_into_the_retry_prompt() -> None:
    gen = Generator(UNSAFE, SAFE)
    run(guard(gen, Escalation.ROUTINE))
    feedback = gen.feedback[1]
    assert feedback is not None
    assert "500 mg" in feedback
    assert "metformin" in feedback
    assert "gave a dose" in feedback
    assert "named a medication" in feedback


def test_second_violation_blocks_with_the_templated_fallback() -> None:
    gen = Generator(UNSAFE, ALSO_UNSAFE, SAFE)
    report = run(guard(gen, Escalation.ROUTINE))
    assert report.verdict is SafetyVerdict.BLOCKED
    assert gen.calls == 2  # one generation plus exactly one retry
    assert safety_copy.BLOCKED_FALLBACK in report.text
    assert "metformin" not in report.text
    assert "diabetes" not in report.text


def test_max_retries_zero_blocks_immediately() -> None:
    gen = Generator(UNSAFE)
    report = run(guard(gen, Escalation.ROUTINE, max_retries=0))
    assert report.verdict is SafetyVerdict.BLOCKED
    assert gen.calls == 1


def test_async_generate_functions_are_supported() -> None:
    async def generate(feedback: str | None) -> str:
        await asyncio.sleep(0)
        return SAFE

    report = run(guard(generate, Escalation.ROUTINE))
    assert report.verdict is SafetyVerdict.PASS


# ---------------------------------------------------------- disclaimer and cards


@pytest.mark.parametrize("escalation", list(Escalation))
@pytest.mark.parametrize("answers", [(SAFE,), (UNSAFE, SAFE), (UNSAFE, ALSO_UNSAFE)])
def test_the_disclaimer_is_always_present(escalation: Escalation, answers: tuple[str, ...]) -> None:
    report = run(guard(Generator(*answers), escalation))
    assert safety_copy.DISCLAIMER in report.text
    assert report.text.rstrip().endswith(safety_copy.DISCLAIMER)


def test_urgent_escalation_card_is_present_and_first() -> None:
    report = run(guard(Generator(SAFE), Escalation.URGENT))
    card = safety_copy.ESCALATION_CARDS[Escalation.URGENT]
    assert card in report.text
    assert report.text.startswith(card)
    assert report.text.index(card) < report.text.index(SAFE)
    assert "112" in report.text  # emergency number, from the constant not the model


def test_see_doctor_soon_card_is_present_and_first() -> None:
    report = run(guard(Generator(SAFE), Escalation.SEE_DOCTOR_SOON))
    card = safety_copy.ESCALATION_CARDS[Escalation.SEE_DOCTOR_SOON]
    assert report.text.startswith(card)


def test_routine_gets_no_card() -> None:
    report = run(guard(Generator(SAFE), Escalation.ROUTINE))
    assert report.text.startswith(SAFE)
    assert "GET MEDICAL CARE NOW" not in report.text


def test_blocked_and_urgent_keeps_the_card_first() -> None:
    report = run(guard(Generator(UNSAFE, ALSO_UNSAFE), Escalation.URGENT))
    assert report.verdict is SafetyVerdict.BLOCKED
    assert report.text.startswith(safety_copy.ESCALATION_CARDS[Escalation.URGENT])
    assert safety_copy.BLOCKED_FALLBACK_URGENT in report.text


def test_assembled_output_passes_its_own_validation() -> None:
    for escalation in Escalation:
        report = run(guard(Generator(SAFE), escalation))
        assert not validate(report.text, escalation).findings


# ------------------------------------------------------------------ failure modes


def test_a_generation_error_fails_closed_not_open() -> None:
    def explode(feedback: str | None) -> str:
        raise RuntimeError("gemini is down")

    report = run(guard(explode, Escalation.ROUTINE))
    assert report.verdict is SafetyVerdict.BLOCKED
    assert safety_copy.BLOCKED_FALLBACK in report.text
    assert safety_copy.DISCLAIMER in report.text


def test_a_generation_error_can_be_raised_instead_when_asked() -> None:
    def explode(feedback: str | None) -> str:
        raise RuntimeError("gemini is down")

    with pytest.raises(RuntimeError):
        run(guard(explode, Escalation.ROUTINE, on_error="raise"))


# ------------------------------------------------------------------ judge hook-up


def test_the_judge_is_consulted_only_for_ambiguous_clean_text() -> None:
    seen: list[str] = []

    def judge(text: str, report: SafetyReport, escalation: Escalation) -> SafetyReport:
        seen.append(text)
        return report

    run(guard(Generator(SAFE), Escalation.ROUTINE, judge=judge))
    assert seen == []  # plain meal text is nowhere near a line

    ambiguous = "Ask your doctor about the right dose of any supplement you may need."
    run(guard(Generator(ambiguous), Escalation.ROUTINE, judge=judge))
    assert seen == [ambiguous]


def test_a_blocking_judge_forces_a_regeneration() -> None:
    ambiguous = "Ask your doctor about the right dose of any supplement you may need."

    def judge(text: str, report: SafetyReport, escalation: Escalation) -> SafetyReport:
        from app.domain.models import SafetyFinding

        return SafetyReport(
            verdict=SafetyVerdict.BLOCKED,
            findings=[
                SafetyFinding(violation=SafetyViolation.DOSAGE_GIVEN, excerpt=text, span=(0, len(text)))
            ],
            text=text,
        )

    gen = Generator(ambiguous, SAFE)
    report = run(guard(gen, Escalation.ROUTINE, judge=judge))
    assert gen.calls == 2
    assert report.verdict is SafetyVerdict.REGENERATED


# ----------------------------------------------------------------------- helpers


def test_build_feedback_quotes_the_model_back_at_itself() -> None:
    findings = validate(UNSAFE).findings
    feedback = build_feedback(findings)
    for finding in findings:
        assert finding.excerpt in feedback
    assert "never shown to the user" in feedback


def test_assemble_orders_card_body_disclaimer() -> None:
    text = assemble("body text", Escalation.URGENT)
    card = safety_copy.ESCALATION_CARDS[Escalation.URGENT]
    assert text.index(card) < text.index("body text") < text.index(safety_copy.DISCLAIMER)

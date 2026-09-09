"""Generate -> validate -> regenerate once -> fall back. Nothing skips this.

``guard`` is the only sanctioned way to turn a model call into text a user may see. It
implements docs/04-ai-pipeline.md stage 7:

* generate, then validate deterministically;
* on a violation, regenerate **once**, with the violation quoted back into the prompt;
* on a second violation, return a templated fallback with verdict ``BLOCKED`` -- the
  model's text is discarded, never repaired, never partially shown;
* append the disclaimer, always;
* prepend the escalation card for ``SEE_DOCTOR_SOON`` and ``URGENT``, **before** anything
  else in the message, so the user reads it first.

The disclaimer and the card are constants from :mod:`app.safety.copy`. A model cannot
write, reword, shorten or omit them.
"""

from __future__ import annotations

import inspect
import logging
from collections.abc import Awaitable, Callable, Sequence

from app.domain.enums import Escalation, SafetyVerdict
from app.domain.models import SafetyFinding, SafetyReport
from app.safety import copy as safety_copy
from app.safety.validator import is_ambiguous, validate

log = logging.getLogger("app.safety.pipeline")

#: ``generate_fn(feedback)`` -- ``feedback`` is None on the first attempt and the quoted
#: violation text on a retry. May be sync or async.
GenerateFn = Callable[[str | None], "str | Awaitable[str]"]

#: ``judge(text, report, escalation)`` -- may only make the verdict stricter.
JudgeFn = Callable[[str, SafetyReport, Escalation], "SafetyReport | Awaitable[SafetyReport]"]


async def _maybe_await(value: object) -> object:
    if inspect.isawaitable(value):
        return await value
    return value


def build_feedback(findings: Sequence[SafetyFinding]) -> str:
    """The regeneration prompt: the rules broken, with the model's own words quoted."""
    lines = [
        safety_copy.VIOLATION_LINE.format(
            violation=safety_copy.VIOLATION_LABELS.get(
                finding.violation.value, finding.violation.value
            ),
            excerpt=finding.excerpt.strip(),
        )
        for finding in findings
    ]
    return safety_copy.REGENERATION_INSTRUCTION.format(violations="\n".join(lines))


def assemble(body: str, escalation: Escalation) -> str:
    """Escalation card first, then the body, then the disclaimer. Always in that order."""
    card = safety_copy.escalation_card(escalation)
    blocks = [block for block in (card, body.strip(), safety_copy.DISCLAIMER) if block]
    return "\n\n".join(blocks)


def fallback_text(escalation: Escalation) -> str:
    """The templated answer used when generation cannot be made safe."""
    if escalation is Escalation.URGENT:
        return safety_copy.BLOCKED_FALLBACK_URGENT
    return safety_copy.BLOCKED_FALLBACK


async def guard(
    generate_fn: GenerateFn,
    escalation: Escalation = Escalation.ROUTINE,
    max_retries: int = 1,
    *,
    judge: JudgeFn | None = None,
    on_error: str = "block",
) -> SafetyReport:
    """Run generation under the safety rules and return the text a user may see.

    ``report.text`` is always ready to display: card, body, disclaimer. ``report.findings``
    records what was wrong with the rejected attempt even when the retry succeeded, so the
    ``ai_runs`` audit row keeps the evidence.
    """
    attempts = 0
    feedback: str | None = None
    first_findings: list[SafetyFinding] = []
    report: SafetyReport | None = None

    while True:
        try:
            text = str(await _maybe_await(generate_fn(feedback)))
        except Exception as exc:  # generation failed: fail closed, never fail open
            if on_error == "raise":
                raise
            log.warning("generation failed, falling back", extra={"error_type": type(exc).__name__})
            return SafetyReport(
                verdict=SafetyVerdict.BLOCKED,
                findings=first_findings,
                text=assemble(fallback_text(escalation), escalation),
            )

        report = validate(text, escalation)
        if not report.findings and judge is not None and is_ambiguous(text, report):
            judged = await _maybe_await(judge(text, report, escalation))
            if isinstance(judged, SafetyReport):
                report = _stricter_of(report, judged)

        if not report.findings:
            verdict = SafetyVerdict.PASS if attempts == 0 else SafetyVerdict.REGENERATED
            return SafetyReport(
                verdict=verdict,
                findings=first_findings,
                text=assemble(report.text, escalation),
            )

        if attempts == 0:
            first_findings = list(report.findings)
        if attempts >= max_retries:
            break

        log.warning(
            "safety violation, regenerating",
            extra={
                "violations": [f.violation.value for f in report.findings],
                "attempt": attempts + 1,
            },
        )
        feedback = build_feedback(report.findings)
        attempts += 1

    log.error(
        "safety violation after retry, blocking",
        extra={"violations": [f.violation.value for f in (report.findings if report else [])]},
    )
    return SafetyReport(
        verdict=SafetyVerdict.BLOCKED,
        findings=list(report.findings) if report else first_findings,
        text=assemble(fallback_text(escalation), escalation),
    )


def _stricter_of(deterministic: SafetyReport, judged: SafetyReport) -> SafetyReport:
    """Union of findings; the judge can add, never remove. See :mod:`app.safety.judge`."""
    from app.safety.judge import merge_reports

    return merge_reports(deterministic, judged)

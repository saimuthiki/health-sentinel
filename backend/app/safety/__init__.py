"""Deterministic safety layer. Every model output passes through here before a user sees it."""

from app.safety.copy import BLOCKED_FALLBACK, DISCLAIMER, ESCALATION_CARDS
from app.safety.judge import GeminiSafetyJudge, merge_reports, stricter
from app.safety.pipeline import assemble, build_feedback, guard
from app.safety.validator import is_ambiguous, scan, validate

__all__ = [
    "BLOCKED_FALLBACK",
    "DISCLAIMER",
    "ESCALATION_CARDS",
    "GeminiSafetyJudge",
    "assemble",
    "build_feedback",
    "guard",
    "is_ambiguous",
    "merge_reports",
    "scan",
    "stricter",
    "validate",
]

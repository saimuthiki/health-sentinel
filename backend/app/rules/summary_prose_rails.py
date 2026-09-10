"""What a model may and may not say in a weekly summary, checked deterministically.

The safety validator in :mod:`app.safety.validator` already refuses drugs, doses,
diagnoses, discouraged treatment and downplayed red flags, and every string here still
goes through it. These rails sit **on top of that**, because a weekly summary can be
perfectly free of all five of those and still be dishonest in a way that matters:

    "You drank more water this week, so your skin should start looking better."

Nothing in that sentence is a drug or a diagnosis. It is a *trend* nobody measured and a
*clinical outcome* attributed to a behaviour, and this is a health app, so it is
forbidden. Two rails, both mechanical:

1. **No numerals at all.** Every number the reader sees is computed by
   :mod:`app.rules.weekly_rollup` and rendered by us; a model that writes no digits
   cannot restate one of ours wrongly, cannot invent one, and cannot smuggle a dose past
   a validator by spelling it oddly. This is stricter than "only use the numbers given"
   and it is stricter on purpose: "only use the numbers given" cannot be checked, and
   this can.
2. **No causal or predictive language.** A closed list of connectives and futures --
   "because", "thanks to", "will improve", "led to", "is helping your". A sentence that
   only *reports* ("you marked meals on four days") never needs one of these; a sentence
   that needs one is making a claim we cannot stand behind.

A rail failure is not a safety violation and is not reported as one. It means the model
wrote something we will not use, and the summary falls back to the deterministic lines --
which are the substance anyway. :mod:`app.planner.weekly_summary` records which of the
two the reader got, and the API says so in ``prose_source``, so this can never be a
silent downgrade.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

#: An encouragement longer than this is an essay, and an essay about somebody's week is
#: where invented detail lives. Two or three sentences is the brief.
MAX_ENCOURAGEMENT_CHARS = 400

#: Any digit. See rail 1 above.
_DIGIT_RE = re.compile(r"\d")

#: Causal connectives and attributions. Matched on word boundaries, case-insensitively.
CAUSAL_PHRASES: tuple[str, ...] = (
    "because",
    "because of",
    "thanks to",
    "due to",
    "owing to",
    "as a result",
    "resulted in",
    "results in",
    "led to",
    "leads to",
    "caused",
    "causes",
    "causing",
    "that is why",
    "which is why",
    "so your",
    "so you are",
    "meaning your",
    "is helping your",
    "are helping your",
    "helped your",
    "is improving your",
    "improving your",
    "improved your",
    "boosted your",
    "is boosting your",
    "reflected in your",
    "showing up in your",
    "paying off in your",
)

#: Predictions and promises. A summary looks backwards; the moment it looks forwards at
#: somebody's body it is making a claim no count supports.
PREDICTIVE_PHRASES: tuple[str, ...] = (
    "will improve",
    "will get better",
    "will go up",
    "will go down",
    "will drop",
    "will rise",
    "will start",
    "should improve",
    "should get better",
    "should start",
    "you will see",
    "you'll see",
    "you will feel",
    "you'll feel",
    "you will notice",
    "you'll notice",
    "expect to see",
    "expect to feel",
    "on track to",
    "well on your way to",
    "keeps this up",
    "keep this up and",
)

#: Trend claims. Nothing in this feature compares two weeks, so nothing in it may say so.
TREND_PHRASES: tuple[str, ...] = (
    "last week",
    "the week before",
    "previous week",
    "compared with",
    "compared to",
    "more than before",
    "less than before",
    "than you did",
    "up from",
    "down from",
    "trend",
    "trending",
    "streak",
    "improvement over",
)

#: Outcome nouns a summary must not attach to behaviour at all. The charter already stops
#: a diagnosis; this stops the softer version -- "your iron", "your skin", "your energy
#: levels" -- being credited to a week of tapping buttons.
BODY_OUTCOME_PHRASES: tuple[str, ...] = (
    "your iron",
    "your haemoglobin",
    "your hemoglobin",
    "your b12",
    "your vitamin",
    "your sugar",
    "your blood sugar",
    "your cholesterol",
    "your thyroid",
    "your blood pressure",
    "your skin",
    "your hair",
    "your weight",
    "your bmi",
    "your levels",
    "your numbers",
    "your results",
    "your deficiency",
)


def _matcher(phrases: tuple[str, ...]) -> re.Pattern[str]:
    """Longest-first alternation with flexible whitespace, on word boundaries."""
    ordered = sorted({p.lower() for p in phrases}, key=lambda p: (-len(p), p))
    body = "|".join(re.escape(p).replace(r"\ ", r"\s+") for p in ordered)
    # Grouped: `|` binds looser than the look-arounds, so a bare alternation
    # would apply the word boundaries to the first and last branch only.
    return re.compile(rf"(?<![A-Za-z])(?:{body})(?![A-Za-z])", re.IGNORECASE)


_CAUSAL_RE = _matcher(CAUSAL_PHRASES)
_PREDICTIVE_RE = _matcher(PREDICTIVE_PHRASES)
_TREND_RE = _matcher(TREND_PHRASES)
_OUTCOME_RE = _matcher(BODY_OUTCOME_PHRASES)


@dataclass(frozen=True)
class RailFinding:
    """One reason a piece of prose was not used."""

    rule: str
    excerpt: str

    def __str__(self) -> str:
        return f"{self.rule}: {self.excerpt!r}"


def check_encouragement(text: str) -> list[RailFinding]:
    """Every rail ``text`` breaks. Empty means it may be shown.

    Order is fixed so the feedback handed back to a regeneration is stable.
    """
    found: list[RailFinding] = []
    cleaned = (text or "").strip()
    if not cleaned:
        return [RailFinding("empty", "")]
    if len(cleaned) > MAX_ENCOURAGEMENT_CHARS:
        found.append(RailFinding("too_long", cleaned[:60]))

    digit = _DIGIT_RE.search(cleaned)
    if digit is not None:
        found.append(RailFinding("numeral", _around(cleaned, digit.start())))

    for rule, pattern in (
        ("causal_claim", _CAUSAL_RE),
        ("prediction", _PREDICTIVE_RE),
        ("trend_claim", _TREND_RE),
        ("body_outcome", _OUTCOME_RE),
    ):
        match = pattern.search(cleaned)
        if match is not None:
            found.append(RailFinding(rule, match.group(0)))
    return found


def feedback_for(findings: list[RailFinding]) -> str:
    """The instruction handed back to the model for its one retry.

    Written as rules rather than as corrections, because asking a model to repair its own
    sentence is how half-repaired sentences happen. The whole encouragement is rewritten.
    """
    reasons = "\n".join(f"- {finding}" for finding in findings)
    return (
        "Your previous sentence was rejected before anybody read it, for these reasons:\n"
        f"{reasons}\n\n"
        "Write it again. Use no digits at all -- the app prints every number itself. Do "
        "not say why anything happened, do not compare this week with any other week, do "
        "not say what will happen next, and do not mention any part of the person's body "
        "or any test result. Say only that they did the things listed, and say it warmly."
    )


def _around(text: str, index: int, width: int = 24) -> str:
    start = max(0, index - width // 2)
    return text[start : start + width]


__all__ = [
    "BODY_OUTCOME_PHRASES",
    "CAUSAL_PHRASES",
    "MAX_ENCOURAGEMENT_CHARS",
    "PREDICTIVE_PHRASES",
    "TREND_PHRASES",
    "RailFinding",
    "check_encouragement",
    "feedback_for",
]

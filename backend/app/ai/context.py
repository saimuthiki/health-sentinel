"""Stage 6 context assembly.

Turns a :class:`~app.domain.models.PlanContext` into the compact text block described in
docs/04-ai-pipeline.md. Everything here is deterministic; no model is involved.

Three things matter:

* **Token bound.** Free-tier quota is the constraint on this product, so the block is
  capped: candidate foods, memory facts, likes, dislikes and findings all have hard limits,
  chat history is summarised rather than pasted, and the whole block is trimmed to a
  character budget before it is returned.
* **Only what the model needs.** No user id, no email, no report file, no raw history.
* **Candidates are the model's whole world.** The planner may only choose from this list, so
  the ordering matters: foods that close the biggest gaps come first and survive trimming.
"""

from __future__ import annotations

from collections.abc import Iterable, Sequence
from dataclasses import dataclass, replace

from app.domain.models import (
    FoodItem,
    NutrientGap,
    PlanContext,
)

SEP = " · "

#: Nutrients always worth showing, whatever the gaps are.
BASE_NUTRIENTS: tuple[str, ...] = ("kcal", "protein_g", "fibre_g")

#: Roughly four characters per token for English plus numbers. Good enough for budgeting.
CHARS_PER_TOKEN = 4


@dataclass(frozen=True)
class ContextLimits:
    """Hard caps. Lower them and the block shrinks; nothing else changes."""

    max_candidate_foods: int = 60
    max_memory_facts: int = 12
    max_likes: int = 12
    max_dislikes: int = 12
    max_findings: int = 15
    max_gaps: int = 8
    max_goals: int = 5
    max_nutrient_columns: int = 6
    max_history_messages: int = 6
    max_history_chars: int = 900
    max_total_chars: int = 12000
    min_confidence: float = 0.6


DEFAULT_LIMITS = ContextLimits()


def estimate_tokens(text: str) -> int:
    """Cheap token estimate. Never used for billing, only for staying inside a budget."""
    return (len(text) + CHARS_PER_TOKEN - 1) // CHARS_PER_TOKEN


# ------------------------------------------------------------------ candidate foods


def _gap_nutrients(gaps: Sequence[NutrientGap], limits: ContextLimits) -> tuple[str, ...]:
    ordered = sorted(gaps, key=lambda g: g.deficit, reverse=True)
    names: list[str] = []
    for gap in ordered:
        if gap.nutrient not in names:
            names.append(gap.nutrient)
    for base in BASE_NUTRIENTS:
        if base not in names:
            names.append(base)
    return tuple(names[: limits.max_nutrient_columns])


def rank_candidates(
    foods: Sequence[FoodItem],
    gaps: Sequence[NutrientGap],
    liked_ids: Iterable[str] = (),
) -> list[FoodItem]:
    """Best-first ordering: covers the biggest gaps, tie-broken by what the user likes.

    Ranking here is what makes truncation safe -- whatever falls off the end of the list is
    the least useful food, not an arbitrary one.
    """
    liked = set(liked_ids)
    weights = {gap.nutrient: gap.deficit for gap in gaps if gap.deficit > 0}
    totals = {name: max(1e-9, max((f.per_100g.get(name, 0.0) for f in foods), default=0.0)) for name in weights}

    def score(food: FoodItem) -> tuple[float, float, str]:
        value = 0.0
        for nutrient, deficit in weights.items():
            per100 = food.per_100g.get(nutrient, 0.0)
            if per100 > 0:
                value += (per100 / totals[nutrient]) * (deficit if deficit > 0 else 0.0)
        return (value, 1.0 if food.id in liked else 0.0, food.name)

    return sorted(foods, key=score, reverse=True)


def render_candidates(
    foods: Sequence[FoodItem],
    nutrients: Sequence[str],
) -> list[str]:
    lines = [f"CANDIDATES   id | name | per 100 g: {', '.join(nutrients)}"]
    for food in foods:
        values = SEP.join(f"{n} {food.per_100g.get(n, 0.0):g}" for n in nutrients)
        name = food.name if not food.name_local else f"{food.name} ({food.name_local})"
        lines.append(f"  {food.id} | {name} | {values}")
    return lines


# ------------------------------------------------------------------- chat history


def summarise_history(
    messages: Sequence[tuple[str, str]],
    limits: ContextLimits = DEFAULT_LIMITS,
) -> str:
    """A rolling summary: the last few turns verbatim, everything older compressed.

    ``messages`` is ``[(role, text), ...]`` oldest first. We never send the whole thread --
    docs/04-ai-pipeline.md, "staying inside the free tier".
    """
    if not messages:
        return ""
    recent = list(messages[-limits.max_history_messages :])
    older = list(messages[: -limits.max_history_messages]) if len(messages) > len(recent) else []

    parts: list[str] = []
    if older:
        topics = _topics(text for _, text in older)
        topic_text = ", ".join(topics) if topics else "general coaching"
        parts.append(f"[{len(older)} earlier messages, about: {topic_text}]")

    for role, text in recent:
        flat = " ".join(str(text).split())
        parts.append(f"{role}: {flat}")

    joined = "\n".join(parts)
    if len(joined) <= limits.max_history_chars:
        return joined
    # Trim from the front: the most recent turn matters most.
    while len(joined) > limits.max_history_chars and len(parts) > 1:
        parts.pop(0)
        joined = "\n".join(parts)
    if len(joined) > limits.max_history_chars:
        joined = joined[: limits.max_history_chars - 1].rstrip() + "…"
    return joined


_STOPWORDS = frozenset(
    ["a", "an", "the", "and", "or", "but", "if", "then", "i", "you", "my", "me", "we", "of", "to", "in", "on", "for", "with", "is", "am", "are", "was", "were", "it", "this", "that", "have", "has", "had", "do", "does", "did", "not", "no", "so", "about", "at", "as", "be", "been", "can", "could", "would", "should", "will", "just", "very", "really", "please", "thanks", "thank", "ok", "okay", "yes", "hi", "hello"]
)


def _topics(texts: Iterable[str], limit: int = 6) -> list[str]:
    counts: dict[str, int] = {}
    for text in texts:
        for word in str(text).lower().replace("/", " ").split():
            token = "".join(ch for ch in word if ch.isalnum() or ch == "-")
            if len(token) < 4 or token in _STOPWORDS:
                continue
            counts[token] = counts.get(token, 0) + 1
    ranked = sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))
    return [word for word, _ in ranked[:limit]]


# --------------------------------------------------------------------- the block


def _profile_line(ctx: PlanContext) -> str:
    profile = ctx.profile
    bits: list[str] = []
    age = profile.age_on(ctx.plan_date)
    if age is not None:
        bits.append(f"{age} y")
    bits.append(str(profile.sex.value))
    if profile.weight_kg:
        bits.append(f"{profile.weight_kg:g} kg")
    if profile.height_cm:
        bits.append(f"{profile.height_cm:g} cm")
    bits.append(f"{profile.activity_level.value} activity")
    bits.append(f"{profile.diet_type.value}")
    if profile.city:
        bits.append(profile.city)
    if profile.is_pregnant:
        bits.append("pregnant")
    if profile.allergies:
        bits.append("allergies: " + ", ".join(a.allergen for a in profile.allergies))
    return "PROFILE      " + SEP.join(bits)


def build_context_block(
    ctx: PlanContext,
    limits: ContextLimits = DEFAULT_LIMITS,
    *,
    history: Sequence[tuple[str, str]] = (),
) -> str:
    """The compact context block handed to the planner or the chat model."""
    lines: list[str] = [f"DATE         {ctx.plan_date.isoformat()}", _profile_line(ctx)]

    findings = [f for f in ctx.findings if f.status.is_abnormal][: limits.max_findings]
    if findings:
        lines.append(
            "FINDINGS     "
            + SEP.join(f"{f.biomarker_code} {f.status.value} ({f.value:g} {f.unit})" for f in findings)
        )

    if ctx.red_flags:
        lines.append(
            "RED FLAGS    "
            + SEP.join(f"{flag.escalation.value}: {flag.message}" for flag in ctx.red_flags)
        )

    gaps = sorted(ctx.gaps, key=lambda g: g.deficit, reverse=True)[: limits.max_gaps]
    if gaps:
        lines.append(
            "GAPS         "
            + SEP.join(f"{g.nutrient} at {g.pct_of_target:.0f}% of target" for g in gaps)
        )

    goals = sorted(ctx.goals, key=lambda g: g.priority)[: limits.max_goals]
    if goals:
        lines.append(
            "GOALS        " + SEP.join(f"{i + 1} {g.title}" for i, g in enumerate(goals))
        )

    likes = sorted(ctx.likes, key=lambda p: p.score, reverse=True)[: limits.max_likes]
    if likes:
        lines.append("LIKES        " + SEP.join(f"{p.name} {p.score:g}" for p in likes))

    dislikes = sorted(ctx.dislikes, key=lambda p: p.score)[: limits.max_dislikes]
    if dislikes:
        lines.append("DISLIKES     " + SEP.join(f"{p.name} {p.score:g}" for p in dislikes))

    memory = [m for m in ctx.memory if m.confidence >= limits.min_confidence]
    memory.sort(key=lambda m: (not m.confirmed, -m.confidence))
    memory = memory[: limits.max_memory_facts]
    if memory:
        lines.append("HABITS       " + SEP.join(m.fact for m in memory))

    if history:
        summary = summarise_history(history, limits)
        if summary:
            lines.append("CONVERSATION")
            lines.extend(f"  {line}" for line in summary.splitlines())

    nutrients = _gap_nutrients(ctx.gaps, limits)
    ranked = rank_candidates(ctx.candidate_foods, ctx.gaps, [p.food_id for p in ctx.likes])
    candidates = ranked[: limits.max_candidate_foods]

    block = "\n".join(lines + render_candidates(candidates, nutrients))

    # Final safety valve: drop the weakest candidates until the block fits the budget.
    while len(block) > limits.max_total_chars and len(candidates) > 1:
        candidates = candidates[: max(1, len(candidates) // 2)]
        block = "\n".join(lines + render_candidates(candidates, nutrients))
    if len(block) > limits.max_total_chars:
        block = block[: limits.max_total_chars - 1].rstrip() + "…"
    return block


def with_smaller_budget(limits: ContextLimits, factor: float = 0.5) -> ContextLimits:
    """Half-size limits, for a retry after a context-length failure."""
    return replace(
        limits,
        max_candidate_foods=max(10, int(limits.max_candidate_foods * factor)),
        max_memory_facts=max(3, int(limits.max_memory_facts * factor)),
        max_history_messages=max(2, int(limits.max_history_messages * factor)),
        max_total_chars=max(2000, int(limits.max_total_chars * factor)),
    )

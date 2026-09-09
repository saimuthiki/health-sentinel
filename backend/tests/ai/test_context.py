"""Context assembly: the block is compact, capped, and ordered so truncation is safe."""

from __future__ import annotations

from datetime import date
from decimal import Decimal

from app.ai.context import (
    ContextLimits,
    build_context_block,
    estimate_tokens,
    rank_candidates,
    summarise_history,
    with_smaller_budget,
)
from app.domain.enums import (
    ActivityLevel,
    DietType,
    Escalation,
    GoalType,
    ResultStatus,
    Sex,
    Stance,
)
from app.domain.models import (
    ClassifiedResult,
    FoodItem,
    FoodPreference,
    Goal,
    HealthProfile,
    MemoryFact,
    NutrientGap,
    PlanContext,
    RedFlag,
)

PLAN_DATE = date(2026, 9, 9)


def food(index: int, iron: float = 1.0, protein: float = 3.0) -> FoodItem:
    return FoodItem(
        id=f"food_{index:03d}",
        name=f"Food {index}",
        per_100g={"kcal": 100.0 + index, "protein_g": protein, "fibre_g": 2.0, "iron_mg": iron},
        source="ifct",
    )


def make_context(n_foods: int = 400, n_memory: int = 40) -> PlanContext:
    return PlanContext(
        profile=HealthProfile(
            user_id="u1",
            dob=date(1994, 3, 2),
            sex=Sex.MALE,
            height_cm=172,
            weight_kg=74,
            activity_level=ActivityLevel.MODERATE,
            diet_type=DietType.NON_VEG,
            city="Hyderabad",
        ),
        findings=[
            ClassifiedResult(
                biomarker_code="VITD_25OH",
                display_name="Vitamin D",
                value=Decimal("14.2"),
                unit="ng/mL",
                status=ResultStatus.LOW,
            ),
            ClassifiedResult(
                biomarker_code="HBA1C",
                display_name="HbA1c",
                value=Decimal("5.2"),
                unit="%",
                status=ResultStatus.NORMAL,
            ),
        ],
        red_flags=[RedFlag(code="LOW_HB", escalation=Escalation.SEE_DOCTOR_SOON, message="haemoglobin low")],
        gaps=[
            NutrientGap(nutrient="iron_mg", target=17.0, current=6.0, unit="mg"),
            NutrientGap(nutrient="fibre_g", target=30.0, current=18.0, unit="g"),
        ],
        goals=[Goal(id="g1", goal_type=GoalType.WEIGHT, title="reduce weight", priority=1)],
        likes=[FoodPreference(food_id="food_007", name="eggs", stance=Stance.LIKE, score=5.0)],
        dislikes=[FoodPreference(food_id="food_009", name="soya chunks", stance=Stance.DISLIKE, score=1.0)],
        memory=[
            MemoryFact(fact=f"habit number {i}", category="habit", confidence=0.9)
            for i in range(n_memory)
        ],
        candidate_foods=[food(i, iron=float(i % 11)) for i in range(n_foods)],
        plan_date=PLAN_DATE,
    )


def test_block_contains_the_sections_from_the_pipeline_doc() -> None:
    block = build_context_block(make_context())
    for section in ("PROFILE", "FINDINGS", "GAPS", "GOALS", "LIKES", "DISLIKES", "HABITS", "CANDIDATES"):
        assert section in block
    assert "32 y" in block  # age computed from dob on the plan date
    assert "Hyderabad" in block


def test_only_abnormal_findings_are_sent() -> None:
    block = build_context_block(make_context())
    assert "VITD_25OH" in block
    assert "HBA1C" not in block


def test_candidate_foods_memory_and_preferences_are_capped() -> None:
    limits = ContextLimits(max_candidate_foods=25, max_memory_facts=5)
    block = build_context_block(make_context(), limits)
    assert block.count("food_") <= 25 + 1  # +1 for the liked food id, which is not a line
    assert sum(1 for line in block.splitlines() if line.startswith("  food_")) == 25
    assert block.count("habit number") == 5


def test_block_respects_the_total_character_budget() -> None:
    limits = ContextLimits(max_total_chars=1500)
    block = build_context_block(make_context(), limits)
    assert len(block) <= 1500
    assert estimate_tokens(block) <= 1500 // 4 + 1
    assert "CANDIDATES" in block  # trimming drops foods, never whole sections


def test_candidates_are_ranked_so_truncation_drops_the_least_useful_food() -> None:
    ctx = make_context(n_foods=30)
    ranked = rank_candidates(ctx.candidate_foods, ctx.gaps, [p.food_id for p in ctx.likes])
    top_iron = ranked[0].per_100g["iron_mg"]
    assert top_iron == max(f.per_100g["iron_mg"] for f in ctx.candidate_foods)


def test_history_is_summarised_not_pasted_whole() -> None:
    messages = [("user", f"message about hair fall number {i}") for i in range(40)]
    summary = summarise_history(messages, ContextLimits(max_history_messages=4, max_history_chars=400))
    assert len(summary) <= 400
    assert "earlier messages" in summary
    assert "message about hair fall number 39" in summary
    assert "message about hair fall number 0" not in summary


def test_history_is_included_in_the_block_when_supplied() -> None:
    block = build_context_block(
        make_context(n_foods=5),
        ContextLimits(max_candidate_foods=5),
        history=[("user", "my hair is falling"), ("assistant", "when did it start?")],
    )
    assert "CONVERSATION" in block
    assert "my hair is falling" in block


def test_empty_history_adds_nothing() -> None:
    assert summarise_history([]) == ""
    assert "CONVERSATION" not in build_context_block(make_context(n_foods=3))


def test_low_confidence_memory_is_withheld_until_confirmed() -> None:
    ctx = make_context(n_memory=0).model_copy(
        update={
            "memory": [
                MemoryFact(fact="dairy upsets me", category="diet", confidence=0.95),
                MemoryFact(fact="probably fasts on tuesdays", category="habit", confidence=0.2),
            ]
        }
    )
    block = build_context_block(ctx)
    assert "dairy upsets me" in block
    assert "probably fasts on tuesdays" not in block


def test_smaller_budget_halves_the_caps() -> None:
    smaller = with_smaller_budget(ContextLimits())
    assert smaller.max_candidate_foods < ContextLimits().max_candidate_foods
    assert smaller.max_total_chars < ContextLimits().max_total_chars

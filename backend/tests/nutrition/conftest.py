"""Shared builders for the nutrition tests.

The food rows here are illustrative fixtures, not the real reference data -- the
``foods`` table lives in ``db/`` and is owned elsewhere. What matters for these tests is
the shape (``per_100g``, ``diet_flags``, ``allergens``), not the exact micronutrients.
"""

from __future__ import annotations

from datetime import date
from decimal import Decimal

import pytest

from app.domain.enums import DietType, ResultStatus, Sex, Stance
from app.domain.models import (
    Allergy,
    ClassifiedResult,
    FoodItem,
    FoodPreference,
    HealthProfile,
)


def food(
    food_id: str,
    name: str,
    *,
    diet_flags: list[str] | None = None,
    allergens: list[str] | None = None,
    **per_100g: float,
) -> FoodItem:
    return FoodItem(
        id=food_id,
        name=name,
        per_100g=dict(per_100g),
        diet_flags=diet_flags if diet_flags is not None else ["veg", "vegan"],
        allergens=allergens or [],
        source="test fixture",
    )


def profile(
    *,
    sex: Sex = Sex.MALE,
    dob: date = date(1994, 3, 1),
    diet_type: DietType = DietType.NON_VEG,
    allergens: list[str] | None = None,
    weight_kg: float | None = None,
    is_pregnant: bool = False,
    activity=None,
) -> HealthProfile:
    kwargs: dict = {
        "user_id": "user-1",
        "dob": dob,
        "sex": sex,
        "diet_type": diet_type,
        "weight_kg": weight_kg,
        "is_pregnant": is_pregnant,
        "allergies": [Allergy(allergen=name) for name in (allergens or [])],
    }
    if activity is not None:
        kwargs["activity_level"] = activity
    return HealthProfile(**kwargs)


def lab(
    code: str,
    value: str,
    unit: str,
    status: ResultStatus,
    *,
    needs_review: bool = False,
) -> ClassifiedResult:
    return ClassifiedResult(
        biomarker_code=code,
        display_name=code.title(),
        value=Decimal(value),
        unit=unit,
        status=status,
        needs_review=needs_review,
    )


def preference(food_id: str, stance: Stance, score: float = 0.0) -> FoodPreference:
    return FoodPreference(food_id=food_id, name=food_id, stance=stance, score=score)


TODAY = date(2026, 9, 9)


@pytest.fixture()
def catalogue() -> list[FoodItem]:
    return [
        food("f_spinach", "Palak (spinach)", iron_mg=3.0, fibre_g=2.2, protein_g=2.9,
             folate_ug=194.0, kcal=23.0),
        food("f_rajma", "Rajma (kidney beans)", iron_mg=5.2, fibre_g=15.2,
             protein_g=22.9, folate_ug=130.0, kcal=333.0),
        food("f_paneer", "Paneer", diet_flags=["veg"], allergens=["milk"],
             protein_g=18.3, calcium_mg=208.0, kcal=265.0),
        food("f_egg", "Boiled egg", diet_flags=["egg"], allergens=["egg"],
             protein_g=13.0, b12_ug=1.1, vitamin_d_ug=2.0, kcal=155.0),
        food("f_chicken", "Chicken breast", diet_flags=["non_veg"], protein_g=31.0,
             b12_ug=0.3, iron_mg=1.0, kcal=165.0),
        food("f_rohu", "Rohu fish", diet_flags=["non_veg"], allergens=["fish"],
             protein_g=16.6, vitamin_d_ug=4.0, b12_ug=1.2, kcal=97.0),
        food("f_peanut", "Groundnut chutney", allergens=["peanut"], protein_g=25.0,
             fat_g=49.0, kcal=567.0),
        food("f_ragi", "Ragi (finger millet)", iron_mg=3.9, calcium_mg=344.0,
             fibre_g=11.5, protein_g=7.3, kcal=328.0),
        food("f_soya", "Soya chunks", allergens=["soy"], protein_g=52.0, iron_mg=20.0,
             kcal=345.0),
        food("f_rice", "Boiled rice", carb_g=28.0, protein_g=2.7, kcal=130.0),
    ]

"""The water and movement targets: they move with the profile, and they know when to
refuse to answer.

Every assertion here is against a figure that ``app/rules/daily_goals.py`` traces to a
named guideline. If one of these numbers changes, the citation next to it in that module
has to change too -- that is the property under test as much as the arithmetic is.
"""

from __future__ import annotations

from datetime import date

import pytest

from app.domain.enums import ActivityLevel, Sex
from app.domain.models import HealthProfile
from app.rules import daily_goals as DG

TODAY = date(2026, 9, 10)
ADULT_DOB = date(2001, 3, 1)  # 25 on TODAY -- the owner's own age
TEEN_DOB = date(2012, 3, 1)  # 14 on TODAY


def profile(**kwargs) -> HealthProfile:
    kwargs.setdefault("dob", ADULT_DOB)
    return HealthProfile(user_id="user-1", **kwargs)


def water(**kwargs) -> DG.HydrationTarget:
    return DG.resolve_hydration_target(profile(**kwargs), on=TODAY)


def movement(**kwargs) -> DG.MovementTarget:
    return DG.resolve_movement_target(profile(**kwargs), on=TODAY)


# ------------------------------------------------------------ citations are mandatory


def test_every_answer_carries_a_source_string() -> None:
    # Including the refusals: an empty `source` next to a null target would leave the app
    # with nothing to show and no reason to give.
    for target in (
        water(sex=Sex.MALE),
        water(sex=Sex.FEMALE, is_pregnant=True),
        water(conditions=["Stage 4 CKD"]),
        water(dob=TEEN_DOB, sex=Sex.MALE),
    ):
        assert target.source.strip()
    for goal in (movement(), movement(dob=TEEN_DOB)):
        assert goal.source.strip()


def test_the_water_source_names_the_guideline_it_came_from() -> None:
    assert "EFSA" in water(sex=Sex.MALE).source


def test_the_movement_source_names_the_guideline_it_came_from() -> None:
    assert "World Health Organization" in movement().source


# ---------------------------------------------------------------- water, personalised


def test_the_water_target_differs_between_two_real_profiles() -> None:
    # The point of the whole change: 2.5 L and 2.0 L of total water (EFSA 2010), each
    # times the 80% EFSA attributes to drinks rather than food.
    assert water(sex=Sex.MALE).millilitres == 2000
    assert water(sex=Sex.FEMALE).millilitres == 1600


def test_the_owners_own_profile_resolves_to_the_male_adult_figure() -> None:
    owner = water(
        sex=Sex.MALE,
        height_cm=170.0,
        weight_kg=82.0,
        activity_level=ActivityLevel.ACTIVE,
        city="Hyderabad",
    )
    assert owner.millilitres == 2000
    # Weight, activity and city are on the profile and are deliberately NOT in the
    # arithmetic: EFSA states the adequate intake per adult, not per kilogram, and we
    # hold no sourced uplift for heat or training. GAPS.md item G15 says so out loud.
    assert "kg" not in owner.source


def test_a_profile_with_no_sex_gets_the_documented_floor_not_a_crash() -> None:
    result = water(sex=Sex.OTHER)
    assert result.millilitres == DG.HYDRATION_FLOOR_ML == 1600
    assert "no sex is recorded" in result.source


def test_a_profile_with_no_date_of_birth_gets_the_documented_floor() -> None:
    result = water(dob=None, sex=Sex.MALE)
    assert result.millilitres == DG.HYDRATION_FLOOR_ML
    assert "no date of birth is recorded" in result.source


def test_an_entirely_empty_profile_still_gets_a_safe_number() -> None:
    empty = DG.resolve_hydration_target(HealthProfile(user_id="user-1"), on=TODAY)
    assert empty.millilitres == DG.HYDRATION_FLOOR_ML


# -------------------------------------------------------------- water, when we refuse


def test_pregnancy_gets_no_water_target_rather_than_a_bigger_one() -> None:
    result = water(sex=Sex.FEMALE, is_pregnant=True)
    assert result.millilitres is None
    assert "doctor or midwife" in result.source


@pytest.mark.parametrize(
    "condition",
    [
        "Stage 4 CKD",
        "chronic kidney disease",
        "on dialysis (Tue/Thu/Sat)",
        "Congestive heart failure",
        "CHF",
        "cirrhosis with ascites",
        "hyponatremia",
        "doctor put me on a fluid restriction",
    ],
)
def test_a_condition_where_fluid_is_restricted_gets_no_target(condition: str) -> None:
    result = water(sex=Sex.MALE, conditions=[condition])
    assert result.millilitres is None, condition
    assert "ask your doctor" in result.source


def test_an_ordinary_condition_does_not_suppress_the_target() -> None:
    # Over-matching would be safe but useless: nearly everyone using this app has
    # something recorded, and a water bar that never appears is the bug we started with.
    assert water(sex=Sex.MALE, conditions=["low vitamin D", "PCOS"]).millilitres == 2000


def test_the_refusal_is_checked_before_any_arithmetic_runs() -> None:
    # A pregnant user with a fluid-restricting condition must still hit the first branch,
    # and no path may reach a number for either.
    result = water(sex=Sex.FEMALE, is_pregnant=True, conditions=["CKD stage 3"])
    assert result.millilitres is None


def test_an_under_18_gets_no_water_target() -> None:
    result = water(dob=TEEN_DOB, sex=Sex.MALE)
    assert result.millilitres is None
    assert "adult" in result.source


# ------------------------------------------------------------------------- movement


def test_the_movement_target_differs_between_two_real_profiles() -> None:
    # WHO 2020: at least 150 minutes a week, up to 300 for additional benefit.
    assert movement(activity_level=ActivityLevel.SEDENTARY).minutes_per_week == 150
    assert movement(activity_level=ActivityLevel.ACTIVE).minutes_per_week == 300


def test_the_daily_figure_is_the_weekly_one_divided_by_seven_rounded_up() -> None:
    floor = movement(activity_level=ActivityLevel.MODERATE)
    upper = movement(activity_level=ActivityLevel.VERY_ACTIVE)
    assert floor.minutes_per_day == 22 and floor.minutes_per_day * 7 >= 150
    assert upper.minutes_per_day == 43 and upper.minutes_per_day * 7 >= 300


def test_a_profile_with_nothing_in_it_gets_the_who_floor() -> None:
    empty = DG.resolve_movement_target(HealthProfile(user_id="user-1"), on=TODAY)
    assert empty.minutes_per_week == 150
    assert empty.minutes_per_day == 22


def test_an_unplaceable_age_stays_on_the_floor_even_for_an_active_profile() -> None:
    assert movement(dob=None, activity_level=ActivityLevel.VERY_ACTIVE).minutes_per_week == 150


def test_an_under_18_gets_no_movement_target() -> None:
    result = movement(dob=TEEN_DOB)
    assert result.minutes_per_week is None
    assert result.minutes_per_day is None


def test_pregnancy_and_chronic_conditions_keep_their_movement_target() -> None:
    # WHO 2020 makes the same weekly recommendation for adults living with chronic
    # conditions and for pregnant women, so unlike the water target there is no reason
    # to go quiet here.
    assert movement(sex=Sex.FEMALE, is_pregnant=True).minutes_per_week == 150
    assert movement(conditions=["Stage 4 CKD"]).minutes_per_week == 150


# ------------------------------------------------------------- intensity equivalence


def test_a_vigorous_minute_counts_as_two_moderate_ones() -> None:
    # WHO's own equivalence: 75 minutes vigorous == 150 minutes moderate.
    assert DG.moderate_equivalent_minutes(30, "moderate") == 30
    assert DG.moderate_equivalent_minutes(30, "vigorous") == 60


def test_an_unknown_intensity_is_never_scaled_up() -> None:
    assert DG.moderate_equivalent_minutes(30, "whatever") == 30

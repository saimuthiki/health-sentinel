"""The water goal a person sets for themselves, and the fence around it.

The owner asked for 5 litres a day. That is well above every published intake figure this
repository holds, and it is the exact shape of intake that causes exercise-associated
hyponatraemia in someone training hard in a hot climate. It is his body and his app, so
the answer is neither "no" nor a silent cap: the number he types is the number he gets,
with what is known about it said next to it, and with a ceiling that can be defended out
loud from a citation.

Every threshold asserted here is one ``app/rules/daily_goals.py`` traces to a named
source. If a number below changes, the citation beside it in that module changes too --
that is as much the property under test as the arithmetic is.
"""

from __future__ import annotations

from datetime import date
from types import SimpleNamespace

import pytest

from app.domain.enums import Sex
from app.domain.models import HealthProfile
from app.rules import daily_goals as DG

TODAY = date(2026, 9, 10)
ADULT_DOB = date(2001, 3, 1)  # 25 on TODAY -- the owner's own age
TEEN_DOB = date(2012, 3, 1)  # 14 on TODAY

#: What the owner asked for.
FIVE_LITRES = 5000


def profile(**kwargs) -> HealthProfile:
    kwargs.setdefault("dob", ADULT_DOB)
    kwargs.setdefault("sex", Sex.MALE)
    return HealthProfile(user_id="owner", **kwargs)


def water(**kwargs) -> DG.HydrationTarget:
    return DG.resolve_hydration_target(profile(**kwargs), on=TODAY)


def judge(millilitres: int | None, **kwargs) -> DG.HydrationChoice:
    return DG.judge_hydration_choice(profile(**kwargs), millilitres, on=TODAY)


# ------------------------------------------------------- the number he typed is the one


def test_with_nothing_chosen_the_sourced_figure_is_unchanged() -> None:
    # The whole of the previous behaviour, still exactly as it was.
    target = water()
    assert target.millilitres == 2000
    assert target.chosen_by_user is False
    assert target.sourced_millilitres == 2000
    assert target.caution == ""
    assert "EFSA" in target.source


def test_five_litres_is_five_litres_and_not_a_number_we_preferred() -> None:
    target = water(hydration_target_override_ml=FIVE_LITRES)
    assert target.millilitres == FIVE_LITRES
    assert target.chosen_by_user is True
    # Not capped at the caution threshold, not rounded, not the sourced figure.
    assert target.millilitres != DG.HYDRATION_CAUTION_ABOVE_ML
    assert target.millilitres != 2000


def test_the_sourced_figure_stays_visible_beside_the_chosen_one() -> None:
    target = water(hydration_target_override_ml=FIVE_LITRES)
    assert target.sourced_millilitres == 2000
    assert "2000" in target.source
    assert "EFSA" in target.source


def test_a_chosen_goal_inside_the_published_range_says_nothing_extra() -> None:
    target = water(hydration_target_override_ml=2400)
    assert target.millilitres == 2400
    assert target.chosen_by_user is True
    assert target.caution == ""


# ------------------------------------------------------------------ the warning, at 3 L


def test_five_litres_is_warned_about_and_not_blocked() -> None:
    verdict = judge(FIVE_LITRES)
    assert verdict.accepted is True
    assert verdict.millilitres == FIVE_LITRES
    assert verdict.reason == ""
    assert verdict.caution


@pytest.mark.parametrize(
    "phrase",
    [
        "dilutes the salt in your blood",
        "sweating heavily",
        "asking a doctor",
        "Institute of Medicine",
        "Hyponatremia Consensus",
    ],
)
def test_the_warning_names_the_risk_and_cites_its_sources(phrase: str) -> None:
    assert phrase in judge(FIVE_LITRES).caution


def test_the_warning_is_carried_on_the_resolved_target_too() -> None:
    # The app shows this beside the bar, not only at the moment of typing.
    assert "dilutes the salt" in water(hydration_target_override_ml=FIVE_LITRES).caution


def test_the_caution_threshold_is_where_the_published_range_runs_out() -> None:
    assert DG.HYDRATION_CAUTION_ABOVE_ML == 3000
    assert judge(DG.HYDRATION_CAUTION_ABOVE_ML).caution == ""
    assert judge(DG.HYDRATION_CAUTION_ABOVE_ML + 1).caution


# ------------------------------------------------------------------ the ceiling, at 6 L


def test_the_ceiling_itself_is_still_allowed() -> None:
    verdict = judge(DG.HYDRATION_CEILING_ML)
    assert verdict.accepted is True
    assert verdict.millilitres == DG.HYDRATION_CEILING_ML


def test_above_the_ceiling_is_refused_with_a_reason_and_a_citation() -> None:
    verdict = judge(DG.HYDRATION_CEILING_ML + 1)
    assert verdict.accepted is False
    assert verdict.millilitres is None
    assert "Noakes" in verdict.reason
    assert str(DG.HYDRATION_CEILING_ML) in verdict.reason
    # The refusal says what happens next, rather than only saying no.
    assert "doctor" in verdict.reason


def test_the_ceiling_is_the_rate_the_kidneys_were_measured_at_not_a_round_guess() -> None:
    # 6000 ml across the 16 waking hours this app schedules in is 375 ml/hour, about half
    # the slowest peak diuresis Noakes et al. measured. The constants have to keep saying
    # that, or the refusal text is quoting arithmetic nobody did.
    per_hour = DG.HYDRATION_CEILING_ML / DG.ASSUMED_WAKING_HOURS
    assert per_hour == pytest.approx(DG.PEAK_DIURESIS_ML_PER_HOUR / 2, abs=15)


def test_a_goal_too_small_to_be_a_goal_is_refused_as_ours_not_as_clinical() -> None:
    verdict = judge(200)
    assert verdict.accepted is False
    assert str(DG.HYDRATION_OVERRIDE_FLOOR_ML) in verdict.reason
    assert "not a clinical limit" in verdict.reason


def test_clearing_the_goal_is_always_accepted() -> None:
    verdict = judge(None)
    assert verdict.accepted is True
    assert verdict.millilitres is None
    assert verdict.caution == ""


# ------------------------------------------- the refusals that were already here survive


@pytest.mark.parametrize(
    "who",
    [
        {"conditions": ["Stage 4 CKD"]},
        {"conditions": ["congestive heart failure"]},
        {"sex": Sex.FEMALE, "is_pregnant": True},
        {"dob": TEEN_DOB},
    ],
)
def test_a_profile_we_hold_no_figure_for_still_gets_no_target(who: dict) -> None:
    target = water(**who, hydration_target_override_ml=FIVE_LITRES)
    assert target.millilitres is None
    assert target.chosen_by_user is False
    assert target.sourced_millilitres is None


def test_the_reason_is_still_the_original_one_with_the_choice_accounted_for() -> None:
    target = water(conditions=["Stage 4 CKD"], hydration_target_override_ml=FIVE_LITRES)
    # Word for word the text this module published before any of this existed.
    assert target.source.startswith(DG.NO_TARGET_FLUID_RESTRICTED)
    # And the number they set is neither used nor hidden.
    assert "5000" in target.source
    assert "not being used" in target.source


def test_someone_on_a_fluid_restriction_cannot_set_a_high_goal_at_all() -> None:
    verdict = judge(FIVE_LITRES, conditions=["dialysis"])
    assert verdict.accepted is False
    assert "ask your doctor" in verdict.reason


def test_a_small_goal_on_a_restricted_profile_is_stored_but_the_person_is_told() -> None:
    verdict = judge(1500, conditions=["dialysis"])
    assert verdict.accepted is True
    assert "not showing a water goal" in verdict.caution


def test_pregnancy_cannot_set_a_high_goal_either() -> None:
    verdict = judge(FIVE_LITRES, sex=Sex.FEMALE, is_pregnant=True)
    assert verdict.accepted is False
    assert "midwife" in verdict.reason


# ------------------------------------------------- a value that arrived some other way


def test_a_goal_above_the_ceiling_already_on_the_profile_is_ignored_on_read() -> None:
    # Written by a path this module does not own. The envelope is enforced on the way out
    # as well as on the way in, so no stored value can put a number on the bar that the
    # endpoint would have refused.
    target = water(hydration_target_override_ml=9000)
    assert target.millilitres == 2000
    assert target.chosen_by_user is False
    assert "not being used" in target.source
    assert "Noakes" in target.source


def test_a_goal_below_the_floor_already_on_the_profile_is_ignored_on_read() -> None:
    target = water(hydration_target_override_ml=100)
    assert target.millilitres == 2000
    assert "not being used" in target.source


# --------------------------------------------------------------- reading the field safely


def test_a_profile_object_without_the_field_reads_as_no_choice() -> None:
    # The field is optional on the profile contract. Anything that does not carry it --
    # an older row, a stand-in, a contract that has not grown it -- means "not chosen",
    # never an exception and never a zero.
    assert DG.chosen_hydration_ml(SimpleNamespace()) is None


@pytest.mark.parametrize(
    "stored", [None, 0, -250, True, False, "", "not a number", object(), [2000]]
)
def test_a_stored_value_that_is_not_a_goal_reads_as_no_choice(stored: object) -> None:
    # ``True`` is in the list on purpose: a bool is an int in Python, and a profile field
    # that somehow held ``True`` must not become a one-millilitre water goal.
    assert DG.chosen_hydration_ml(SimpleNamespace(hydration_target_override_ml=stored)) is None


def test_a_numeric_string_is_read_as_the_number_it_is() -> None:
    assert (
        DG.chosen_hydration_ml(SimpleNamespace(hydration_target_override_ml="5000"))
        == FIVE_LITRES
    )


def test_an_unset_field_leaves_the_sourced_answer_byte_for_byte_alone() -> None:
    plain = DG.resolve_hydration_target(profile(), on=TODAY)
    sourced = DG.sourced_hydration_target(profile(), on=TODAY)
    assert plain == sourced


def test_choosing_a_water_goal_does_not_touch_the_movement_target() -> None:
    goal = DG.resolve_movement_target(
        profile(hydration_target_override_ml=FIVE_LITRES), on=TODAY
    )
    assert goal.minutes_per_week == 150
    assert "World Health Organization" in goal.source

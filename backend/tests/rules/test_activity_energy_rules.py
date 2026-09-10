"""The named activity list, and the arithmetic that turns one into an energy figure.

Two kinds of test here, and the difference matters.

The first kind is **structural**: every row carries a citation, the intensity band always
agrees with the MET value, nothing is silently missing. These are the tests that stop the
list drifting into uncited numbers, which is the failure this project cares most about.

The second kind is **arithmetical**: MET x kg x hours, worked out on paper in the test so
that a reader can check it without running anything.

What is deliberately **not** tested is whether badminton really is 5.5 METs. No test in
this repository can establish that; only the printed Compendium can, and ``GAPS.md`` item
G17 says so out loud.
"""

from __future__ import annotations

import pytest

from app.rules.activity_energy import (
    ACTIVITIES,
    COMPENDIUM_2011,
    ENERGY_ROUNDS_TO_KCAL,
    LIGHT,
    LIGHT_BELOW_METS,
    MODERATE,
    NO_WEIGHT_RECORDED,
    OTHER_ACTIVITY_KEY,
    VIGOROUS,
    VIGOROUS_FROM_METS,
    activity_for,
    activity_keys,
    energy_kcal,
    intensity_for_mets,
    round_kcal,
)

#: The things the owner said he actually does. If one of these ever disappears from the
#: list, this is the test that says so.
ASKED_FOR = ("running", "badminton", "walking", "cycling", "gym_strength", "yoga")


# ------------------------------------------------------------------- the list itself


def test_the_list_names_the_activities_the_owner_asked_for():
    keys = activity_keys()
    for wanted in ASKED_FOR:
        assert wanted in keys, f"{wanted} is not on the list any more"
    # Plus the escape hatch, so somebody who did none of these is not stuck.
    assert OTHER_ACTIVITY_KEY in keys


def test_every_key_is_unique():
    keys = [activity.key for activity in ACTIVITIES]
    assert len(keys) == len(set(keys))


def test_every_met_value_carries_its_compendium_row():
    """Cite or omit, applied to this list.

    A MET value with no code and no description is a number somebody typed in, and there
    would be no way to check it later. The only row allowed to have no figure is the one
    that admits it does not know what happened.
    """
    for activity in ACTIVITIES:
        if activity.mets is None:
            assert activity.key == OTHER_ACTIVITY_KEY
            assert "we do not know what this was" in activity.source
            continue
        assert activity.compendium_code, f"{activity.key} has a MET value and no code"
        assert activity.compendium_description
        assert COMPENDIUM_2011 in activity.source
        assert activity.compendium_code in activity.source
        assert activity.compendium_description in activity.source


def test_every_row_has_words_a_person_would_recognise():
    for activity in ACTIVITIES:
        assert activity.label.strip()
        assert activity.example.strip()
        # The label is what appears on a button. A Compendium description is not it.
        assert len(activity.label) <= 24


def test_an_unknown_key_is_not_guessed_at():
    assert activity_for("kabaddi") is None
    assert activity_for("") is None
    # Spelling and case are forgiven; meaning is not invented.
    assert activity_for("  BADMINTON ") is activity_for("badminton")


# ------------------------------------------------------------------------ intensity


@pytest.mark.parametrize(
    ("mets", "expected"),
    [
        (1.0, LIGHT),
        (2.9, LIGHT),
        (LIGHT_BELOW_METS, MODERATE),
        (5.9, MODERATE),
        (VIGOROUS_FROM_METS, VIGOROUS),
        (9.8, VIGOROUS),
    ],
)
def test_the_intensity_bands_are_the_published_ones(mets, expected):
    """Light under 3 METs, moderate 3.0 to 5.9, vigorous 6.0 and up. Boundaries belong
    to the higher band, which is what the published bands say."""
    assert intensity_for_mets(mets) == expected


def test_an_activitys_intensity_is_derived_from_its_mets_and_never_typed_in():
    for activity in ACTIVITIES:
        if activity.mets is None:
            assert activity.intensity is None
            continue
        assert activity.intensity == intensity_for_mets(activity.mets)


def test_yoga_is_light_so_it_does_not_count_toward_the_who_target():
    """The one place this list disagrees with a person's intuition, on purpose.

    Hatha yoga is under 3 METs, and WHO's 150 minutes counts moderate-to-vigorous
    activity. Counting it would overstate the week, which is the one thing a progress bar
    must not do. The session is still logged and still gets an energy figure.
    """
    yoga = activity_for("yoga")
    assert yoga is not None
    assert yoga.intensity == LIGHT
    assert yoga.counts_toward_target is False


def test_running_and_cycling_are_vigorous_and_badminton_is_moderate():
    assert activity_for("running").intensity == VIGOROUS
    assert activity_for("cycling").intensity == VIGOROUS
    assert activity_for("badminton").intensity == MODERATE
    assert activity_for("cricket").intensity == MODERATE


def test_something_else_counts_because_the_person_states_the_intensity():
    other = activity_for(OTHER_ACTIVITY_KEY)
    assert other.mets is None
    assert other.intensity is None
    assert other.counts_toward_target is True


# ------------------------------------------------------------------------ the energy


def test_the_arithmetic_is_mets_times_kilos_times_hours():
    # 5.5 METs of badminton, one hour, 70 kg: 5.5 * 70 * 1 = 385 kcal.
    assert energy_kcal(5.5, 60, 70.0) == pytest.approx(385.0)
    # Half an hour of it is half of that.
    assert energy_kcal(5.5, 30, 70.0) == pytest.approx(192.5)
    # And it is proportional to weight, which is the whole reason weight is required.
    assert energy_kcal(5.5, 60, 140.0) == pytest.approx(770.0)


def test_there_is_no_figure_without_a_body_weight():
    """The failure this module exists to get right.

    An average adult weight substituted here would put a plausible, wrong number in front
    of somebody, and nothing on screen would say it was invented.
    """
    assert energy_kcal(5.5, 60, None) is None
    assert energy_kcal(5.5, 60, 0) is None
    assert energy_kcal(5.5, 60, -70.0) is None
    assert "no weight on your profile" in NO_WEIGHT_RECORDED


def test_there_is_no_figure_for_an_activity_we_cannot_name():
    assert energy_kcal(None, 60, 70.0) is None


def test_no_minutes_is_no_energy():
    assert energy_kcal(5.5, 0, 70.0) is None


def test_the_figure_is_rounded_because_it_is_not_that_precise():
    """A population average does not support a figure to the kilocalorie."""
    assert ENERGY_ROUNDS_TO_KCAL == 5
    assert round_kcal(288.75) == 290
    assert round_kcal(1.0) == 0
    assert round_kcal(3.0) == 5
    assert round_kcal(0) == 0
    # Never negative, whatever arrives.
    assert round_kcal(-40.0) == 0

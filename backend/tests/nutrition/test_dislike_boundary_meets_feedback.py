"""The one number two modules have to agree on.

``app.api.feedback`` decides what a rating *means*: at or below ``DISLIKE_AT`` the food
is written down as a dislike. ``app.nutrition.candidates`` decides what a dislike
*costs*: below ``DISLIKE_SCORE_THRESHOLD`` the food is not offered again.

Those were the same number compared two different ways -- ``<=`` on one side, ``<`` on
the other -- and the gap was exactly one score. A meal rated 2 was recorded as a dislike,
described to the model as a dislike in the prompt built from
``PlanContext.dislikes``, and then put back on tomorrow's plan by ``filter_foods``,
because ``2.0 < 2.0`` is false. The person kept saying no and kept being asked.

Every test here reads both numbers off the modules rather than repeating a literal, so
moving one boundary without the other fails here instead of failing on somebody's plan.
"""

from __future__ import annotations

import pytest

from app.api.feedback import DISLIKE_AT, LIKE_AT, RATING_TO_SCORE, stance_for
from app.domain.enums import Stance
from app.domain.models import FoodPreference
from app.nutrition.candidates import DISLIKE_SCORE_THRESHOLD, filter_foods, rank_foods
from tests.nutrition.conftest import food, profile


def soya():
    """One ordinary allowed food, so the only thing deciding its fate is the stance."""
    return food("f_soya", "Soya chunks", protein_g=52.0, iron_mg=20.0, kcal=345.0)


def preference_at(score: float) -> FoodPreference:
    """A preference exactly as :func:`app.api.feedback.rate_meal` would have written it."""
    return FoodPreference(
        food_id="f_soya", name="Soya chunks", stance=stance_for(score), score=score
    )


def test_the_two_modules_use_the_same_boundary_number() -> None:
    assert DISLIKE_AT == DISLIKE_SCORE_THRESHOLD


@pytest.mark.parametrize("rating", sorted(RATING_TO_SCORE))
def test_a_food_the_api_calls_disliked_is_never_offered_again(rating: int) -> None:
    """The property that matters, stated over every rating the API will accept.

    Not "a 2 is excluded" -- that is the symptom. The invariant is that the two modules
    cannot disagree about any rating at all: whatever ``stance_for`` calls a dislike,
    ``filter_foods`` drops.
    """
    score = RATING_TO_SCORE[rating]
    pref = preference_at(score)
    allowed, rejected = filter_foods([soya()], profile(), [pref])

    if pref.stance is Stance.DISLIKE:
        assert allowed == [], f"rating {rating} is a dislike the planner still offers"
        assert [r.reason for r in rejected] == ["disliked"]
    else:
        assert [f.id for f in allowed] == ["f_soya"]


def test_a_rating_of_two_is_the_case_that_used_to_leak() -> None:
    """The regression itself, named, so a reader knows what this file is about."""
    pref = preference_at(RATING_TO_SCORE[2])
    assert pref.stance is Stance.DISLIKE

    allowed, rejected = filter_foods([soya()], profile(), [pref])
    assert allowed == []
    assert [r.reason for r in rejected] == ["disliked"]


def test_the_boundary_is_inclusive_on_exactly_the_threshold() -> None:
    """At the number: out. A hair above it: in, and ranked down rather than dropped.

    The second half is what keeps this a boundary and not a blanket. A mild dislike is
    still allowed to appear -- it is only pushed down the ranking -- and that behaviour
    is what ``test_candidates.py`` covers. This asserts the move did not swallow it.
    """
    at_threshold = preference_at(DISLIKE_SCORE_THRESHOLD)
    allowed, _ = filter_foods([soya()], profile(), [at_threshold])
    assert allowed == []

    just_above = FoodPreference(
        food_id="f_soya",
        name="Soya chunks",
        stance=Stance.DISLIKE,
        score=DISLIKE_SCORE_THRESHOLD + 0.5,
    )
    allowed, _ = filter_foods([soya()], profile(), [just_above])
    assert [f.id for f in allowed] == ["f_soya"]


def test_the_three_buttons_land_on_three_different_stances() -> None:
    """1 / 3 / 5, and why they are those three rather than any other three.

    The tastes screen and the plan card both offer exactly three answers. This pins the
    arithmetic they rely on: the middle one has to be genuinely inert, and it is only
    inert at 3 -- a 2 is a dislike (above) and a 4 is a like.
    """
    assert stance_for(RATING_TO_SCORE[1]) is Stance.DISLIKE
    assert stance_for(RATING_TO_SCORE[3]) is Stance.NEUTRAL
    assert stance_for(RATING_TO_SCORE[5]) is Stance.LIKE

    # Neutral is the "forget I said anything" answer, so it must move nothing: not the
    # filter, and not the ranking either.
    neutral = preference_at(RATING_TO_SCORE[3])
    allowed, _ = filter_foods([soya()], profile(), [neutral])
    assert [f.id for f in allowed] == ["f_soya"]

    with_neutral = rank_foods([soya()], preferences=[neutral])
    without_any = rank_foods([soya()])
    assert with_neutral[0].score == without_any[0].score
    assert with_neutral[0].like_score == 0.0


def test_a_five_is_what_survives_the_prompt_cap() -> None:
    """"Loved it" is 5 and not 4, and this says why in code.

    ``app.ai.context`` keeps only the highest-scoring likes, and ``rank_foods`` scales
    its bonus by ``score / 5``. A 4 is a like too, but it is the one that gets trimmed
    first and lifts less -- so the top button has to be the top score.
    """
    four = FoodPreference(
        food_id="f_soya", name="Soya chunks", stance=Stance.LIKE, score=RATING_TO_SCORE[4]
    )
    five = FoodPreference(
        food_id="f_soya", name="Soya chunks", stance=Stance.LIKE, score=RATING_TO_SCORE[5]
    )
    assert four.score >= LIKE_AT and five.score >= LIKE_AT

    lifted_by_four = rank_foods([soya()], preferences=[four])[0]
    lifted_by_five = rank_foods([soya()], preferences=[five])[0]
    assert lifted_by_five.like_score > lifted_by_four.like_score
    assert lifted_by_five.score > lifted_by_four.score

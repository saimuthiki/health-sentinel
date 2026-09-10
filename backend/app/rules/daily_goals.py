"""The two daily numbers the Today screen shows that are not food: water and movement.

Both are resolved **here, in Python, from a named published guideline** -- the same way
``app.nutrition.targets`` resolves a nutrient RDA and ``app.rules.classify`` judges a lab
value against a curated reference range. No language model is involved anywhere in this
file, and none may ever be: ``CLAUDE.md`` puts reference ranges, thresholds and nutrient
values in deterministic code and curated data, and a personal water goal is exactly that
kind of number.

Why this file exists
--------------------
Until now the app showed a fixed water goal and a fixed "0 of 30 minutes" movement bar.
Neither came from anywhere -- there was no hydration target and no movement target in the
backend at all, so the app fell back to constants of its own. A water goal is not the same
for a 55 kg woman and an 82 kg man, and the owner was right to say so.

Why the citations are not ICMR-NIN
----------------------------------
Every nutrient target in this project cites ICMR-NIN 2020 (``db/seed/203_rda_targets.sql``,
``app/nutrition/targets.py``). We could **not** state an ICMR-NIN figure for water intake
or for physical activity with confidence, and the rule in this repository is *cite or
omit*. So these two numbers cite the guidelines we could state instead, and the gap is
written up in ``app/rules/GAPS.md`` (items G15 and G16) rather than papered over. Swapping in
an ICMR-NIN figure later is a change to the constants below and nothing else.

What is deliberately NOT personalised
-------------------------------------
Fluid intake is restricted, not encouraged, in several conditions -- advanced kidney
disease, heart failure, cirrhosis with ascites, hyponatraemia -- and it changes in
pregnancy. For those users this module returns **no target at all** rather than a bigger
number, and the reason string tells them to ask their doctor. Refusing to answer is a
legitimate answer here; inventing a personalised litre count for someone on a fluid
restriction is the failure mode that matters.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import date

from app.domain.enums import ActivityLevel, Sex
from app.domain.models import HealthProfile

__all__ = [
    "ADULT_MIN_AGE",
    "EFSA_2010_WATER",
    "FLUID_RESTRICTION_MARKERS",
    "HYDRATION_FLOOR_ML",
    "INTENSITY_WEIGHTS",
    "WHO_2020_ACTIVITY",
    "HydrationTarget",
    "MovementTarget",
    "is_fluid_restricted",
    "moderate_equivalent_minutes",
    "resolve_hydration_target",
    "resolve_movement_target",
]


#: Both cited guidelines state their figures for "adults". 18 is the youngest age either
#: of them calls an adult (WHO's adult band is 18-64), so below it we publish nothing --
#: the same cite-or-omit stance ``app.nutrition.targets`` takes outside its 19-59 band.
ADULT_MIN_AGE = 18


# --------------------------------------------------------------------------- water


EFSA_2010_WATER = (
    "EFSA Panel on Dietetic Products, Nutrition and Allergies (NDA). Scientific Opinion "
    "on Dietary Reference Values for water. EFSA Journal 2010;8(3):1459."
)

#: EFSA's adequate intake of **total** water for adults, at moderate ambient temperature
#: and moderate physical activity. Total water means everything: drinks plus the water
#: that comes in food.
TOTAL_WATER_ML: dict[Sex, int] = {Sex.MALE: 2500, Sex.FEMALE: 2000}

#: EFSA states that drinks normally supply 70-80% of total water intake and food the
#: remaining 20-30%. The bar in the app counts water the user drinks, so the target has
#: to be the drinks half of that split, not the total. We take the **top** of EFSA's own
#: range: setting a drinking goal at the bottom of it would tell a person to drink less
#: than the source supports. This one choice is the only judgement in the water rule, and
#: it is deliberately visible here rather than buried in an arithmetic expression.
DRINKS_SHARE_OF_TOTAL_WATER = 0.80

#: 0.80 x 2000 ml -- the lower of the two adult figures. Used whenever we do not know
#: enough about the person to pick between them (no recorded sex, or no date of birth so
#: we cannot confirm they are an adult). Suggesting the smaller of two sourced numbers is
#: the honest way to be wrong; stretching the larger one onto someone we cannot place is
#: not.
HYDRATION_FLOOR_ML = 1600

#: Words in a user's own recorded conditions that mean fluid intake is a clinical
#: decision, not a coaching one. Matched as substrings of the lowercased condition text,
#: so "Stage 4 CKD" and "chronic kidney disease" both hit. Over-matching here is cheap:
#: the consequence is that we show no water target and point the person at their doctor.
FLUID_RESTRICTION_MARKERS: tuple[str, ...] = (
    "ckd",
    "chronic kidney",
    "kidney disease",
    "kidney failure",
    "renal failure",
    "renal disease",
    "dialysis",
    "nephrotic",
    "nephritis",
    "heart failure",
    "cardiac failure",
    "chf",
    "cirrhosis",
    "ascites",
    "liver failure",
    "hyponatrem",
    "hyponatraem",
    "siadh",
    "fluid restrict",
    "water restrict",
)

NO_TARGET_FLUID_RESTRICTED = (
    "How much to drink is set by a doctor when a condition on your profile affects fluid "
    "balance, so we do not show a water goal here. Please ask your doctor what daily "
    "amount is right for you, and we will track whatever they tell you."
)

NO_TARGET_PREGNANCY = (
    "Water needs change during pregnancy, and we do not hold a figure we could stand "
    "behind for that. We would rather show you nothing than a number we made up -- "
    "please ask your doctor or midwife how much to aim for."
)

NO_TARGET_UNDER_18 = (
    "Our water figures are the adult ones. We do not hold a sourced figure for under-18s, "
    "so we are not showing a goal rather than stretching an adult number to fit."
)


@dataclass(frozen=True)
class HydrationTarget:
    """A daily drinking-water goal, or an explained absence of one.

    ``millilitres`` is ``None`` whenever we will not answer. That is a real answer and the
    API passes it through as ``null`` -- ``source`` then carries the reason, in the same
    slot where it would otherwise carry the citation.
    """

    millilitres: int | None
    source: str


def _normalise(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", " ", text.lower()).strip()


def is_fluid_restricted(profile: HealthProfile) -> bool:
    """Does this profile name a condition where fluid intake is a doctor's decision?

    Deliberately generous. A false positive costs the user a water bar and a sentence
    telling them to ask their doctor; a false negative tells someone in heart failure to
    drink two litres a day.
    """
    for condition in profile.conditions:
        text = _normalise(str(condition))
        if any(marker in text for marker in FLUID_RESTRICTION_MARKERS):
            return True
    return False


def resolve_hydration_target(
    profile: HealthProfile, *, on: date | None = None
) -> HydrationTarget:
    """This person's daily drinking-water goal in millilitres, or ``None`` with a reason.

    The rule, in full:

    1. If a condition on the profile means fluid is restricted, or the user is pregnant,
       there is **no target**. This check comes first, before any arithmetic, so no path
       can reach a number for these users.
    2. Below 18, no target: both cited figures are adult figures.
    3. Otherwise: EFSA's adult adequate intake of total water for the recorded sex
       (2500 ml male, 2000 ml female), times the 80% of total water that EFSA says comes
       from drinks rather than food.
    4. If sex is unrecorded, or date of birth is unrecorded so we cannot confirm an adult,
       fall back to :data:`HYDRATION_FLOOR_ML` -- the smaller of the two sourced numbers.
    """
    if is_fluid_restricted(profile):
        return HydrationTarget(millilitres=None, source=NO_TARGET_FLUID_RESTRICTED)
    if profile.is_pregnant:
        return HydrationTarget(millilitres=None, source=NO_TARGET_PREGNANCY)

    age = profile.age_on(on or date.today())
    if age is not None and age < ADULT_MIN_AGE:
        return HydrationTarget(millilitres=None, source=NO_TARGET_UNDER_18)

    total_ml = TOTAL_WATER_ML.get(profile.sex)
    if total_ml is None or age is None:
        why = "no sex is recorded" if total_ml is None else "no date of birth is recorded"
        return HydrationTarget(
            millilitres=HYDRATION_FLOOR_ML,
            source=(
                f"{EFSA_2010_WATER} Adequate intake of total water for an adult woman is "
                f"2.0 L/day, of which EFSA attributes "
                f"{int(DRINKS_SHARE_OF_TOTAL_WATER * 100)}% to drinks. We use that lower "
                f"of the two adult figures because {why} on this profile."
            ),
        )

    millilitres = int(round(total_ml * DRINKS_SHARE_OF_TOTAL_WATER))
    litres = total_ml / 1000
    return HydrationTarget(
        millilitres=millilitres,
        source=(
            f"{EFSA_2010_WATER} Adequate intake of total water for an adult "
            f"{profile.sex.value} is {litres:.1f} L/day at moderate temperature and "
            f"moderate activity, of which EFSA attributes "
            f"{int(DRINKS_SHARE_OF_TOTAL_WATER * 100)}% to drinks rather than food."
        ),
    )


# ------------------------------------------------------------------------ movement


WHO_2020_ACTIVITY = (
    "World Health Organization. WHO guidelines on physical activity and sedentary "
    "behaviour. Geneva: World Health Organization; 2020."
)

#: WHO's adult recommendation is a **weekly** range, not a daily figure: at least 150 and
#: up to 300 minutes of moderate-intensity aerobic activity per week, with the upper half
#: of the range giving additional benefit. The weekly number is therefore the real target
#: and the daily one is derived from it -- which is also why the API returns both, and why
#: the owner asking to see a week rather than a day was asking for the right thing.
WEEKLY_FLOOR_MINUTES = 150
WEEKLY_UPPER_MINUTES = 300

#: Who gets the upper half of WHO's range. Someone who already trains most days is being
#: coached toward the "additional health benefits" end of the same recommendation, not
#: toward a number from outside it.
HIGHER_TARGET_ACTIVITY_LEVELS: frozenset[ActivityLevel] = frozenset(
    {ActivityLevel.ACTIVE, ActivityLevel.VERY_ACTIVE}
)

#: WHO states 75-150 minutes of vigorous activity as equivalent to 150-300 minutes of
#: moderate activity, so one vigorous minute counts as two moderate ones. This is the
#: guideline's own equivalence, not a conversion we chose.
VIGOROUS_TO_MODERATE = 2

#: What the 150 minutes counts. WHO's target is moderate-**to-vigorous** activity; gentler
#: movement is good for a person but is not what this number measures, so the log refuses
#: it rather than quietly counting it and overstating the week.
MODERATE = "moderate"
VIGOROUS = "vigorous"
INTENSITY_WEIGHTS: dict[str, int] = {MODERATE: 1, VIGOROUS: VIGOROUS_TO_MODERATE}

NO_MOVEMENT_TARGET_UNDER_18 = (
    "WHO sets a different physical-activity target for under-18s and we have not curated "
    "it, so we are not showing a goal rather than showing an adult one."
)


@dataclass(frozen=True)
class MovementTarget:
    """A weekly movement goal and the daily slice of it, or an explained absence."""

    minutes_per_week: int | None
    minutes_per_day: int | None
    source: str


def moderate_equivalent_minutes(minutes: int, intensity: str) -> int:
    """Minutes of movement expressed in the unit the target is written in.

    The target is moderate-intensity minutes, so a vigorous minute counts twice -- WHO's
    own equivalence. Both sides of the progress bar are then the same unit, which is the
    whole reason to do this conversion at the edge rather than in the UI.
    """
    return int(minutes) * INTENSITY_WEIGHTS.get(intensity, 1)


def resolve_movement_target(
    profile: HealthProfile, *, on: date | None = None
) -> MovementTarget:
    """This person's movement goal, weekly and daily.

    Weekly is WHO's own figure: 150 minutes for most people, 300 for someone whose profile
    already says they are active, which is the upper end of the same recommended range.

    Daily is that weekly figure divided by seven and rounded **up**, so that hitting the
    daily number every day always clears the weekly one. It is a display convenience: the
    weekly number is the one WHO actually publishes, and the one to judge a person by.

    Unlike the water target this one is **not** withheld for pregnancy or for a chronic
    condition: WHO's 2020 guidelines carry the same weekly recommendation for adults
    living with chronic conditions and for pregnant and post-partum women, so there is a
    sourced figure for them and no reason to go quiet. Movement is also coaching the app
    is explicitly allowed to give (``CLAUDE.md``), where a litre count for someone on a
    fluid restriction is not.
    """
    age = profile.age_on(on or date.today())
    if age is not None and age < ADULT_MIN_AGE:
        return MovementTarget(
            minutes_per_week=None, minutes_per_day=None, source=NO_MOVEMENT_TARGET_UNDER_18
        )

    # An unknown age means we could not confirm an adult, so we stay on the floor rather
    # than coach an unplaceable profile toward the upper end of the range.
    if age is not None and profile.activity_level in HIGHER_TARGET_ACTIVITY_LEVELS:
        weekly = WEEKLY_UPPER_MINUTES
        band = (
            "This profile records an already-active week, so the target is the upper end "
            "of WHO's range, where the guideline says additional health benefits are gained."
        )
    else:
        weekly = WEEKLY_FLOOR_MINUTES
        band = (
            "This is the floor of WHO's range -- the 'at least' figure, used unless the "
            "profile records enough for us to coach toward the upper end."
        )

    daily = -(-weekly // 7)  # ceil, so seven days at the daily figure clear the week
    return MovementTarget(
        minutes_per_week=weekly,
        minutes_per_day=daily,
        source=(
            f"{WHO_2020_ACTIVITY} Adults should do at least {WEEKLY_FLOOR_MINUTES}-"
            f"{WEEKLY_UPPER_MINUTES} minutes of moderate-intensity aerobic activity per "
            f"week. {band} The daily figure is that weekly one divided by seven and "
            f"rounded up; the weekly number is the one WHO publishes."
        ),
    )

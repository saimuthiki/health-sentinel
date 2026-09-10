"""Named activities, and what an hour of each costs in energy.

The Today screen used to show a bar labelled "Moving: 0 of 43 minutes". The owner's
objection was exact:

    "you can let the user know all the types of physical exercises -- instead of this
    'movement target' kind of thing."

"Movement" is not a thing anybody does. Badminton is. So this module holds the list of
activities the app names, and the arithmetic that turns one of them plus a number of
minutes into an energy figure.

Why this is a Python constant and not a seed file
-------------------------------------------------
``db/seed/`` is where curated *data* lives -- foods, biomarkers, reference ranges, RDA
targets. All four have three things in common that this list does not: they are large, a
dietitian or clinician is expected to edit them without a deploy, and they are joined
against in SQL. This list is eleven rows, it is read only by the arithmetic in this file,
and it has no table to live in. Adding one would mean a migration against a live
database, which is not this change's to write.

The closer precedent is ``app.rules.daily_goals``, which holds ``TOTAL_WATER_ML`` and
``INTENSITY_WEIGHTS`` -- small, cited, deterministic constants that the rules engine
reads -- as Python. This is the same kind of thing, and it sits beside them.

Where the numbers come from
---------------------------
A MET is a multiple of resting metabolic rate. The Compendium of Physical Activities is
the canonical published list of them, and every row below carries its Compendium code and
the Compendium's own wording of the activity, so a reviewer can look each one up.

**Read ``GAPS.md`` item G17 before trusting a single figure in this file.** The values
were transcribed from the Compendium without the printed table to hand, so each one is a
citation of a real published number that has *not* been checked against the source in
this repository. That is written down rather than hidden.

What a MET figure is not
------------------------
It is a population average for the activity, measured on other people. It is not a
measurement of this user. Two people of the same weight playing the same hour of badminton
do not spend the same energy, and neither of them necessarily spends what the Compendium
says. Everything this module returns is therefore an estimate and must be labelled as one
wherever it is shown -- :data:`ENERGY_IS_AN_ESTIMATE` is the sentence, and the API sends
it alongside every figure so the app cannot show the number without the caveat.

Two further honesty points, both also in ``GAPS.md``:

* The formula is **gross**: it counts all the energy used during the session, including
  what the body would have spent lying still for the same minutes. It is not "extra"
  energy. :data:`ENERGY_IS_AN_ESTIMATE` says so.
* It needs body weight. With no weight on the profile there is no figure, and this module
  returns ``None`` with :data:`NO_WEIGHT_RECORDED` rather than assuming an average adult.
"""

from __future__ import annotations

from dataclasses import dataclass

__all__ = [
    "ACTIVITIES",
    "COMPENDIUM_2011",
    "ENERGY_IS_AN_ESTIMATE",
    "ENERGY_ROUNDS_TO_KCAL",
    "LIGHT",
    "LIGHT_BELOW_METS",
    "MODERATE",
    "NOTHING_NAMED_TO_COST",
    "NO_WEIGHT_RECORDED",
    "OTHER_ACTIVITY_KEY",
    "VIGOROUS",
    "VIGOROUS_FROM_METS",
    "Activity",
    "activity_for",
    "activity_keys",
    "energy_kcal",
    "intensity_for_mets",
    "round_kcal",
]


COMPENDIUM_2011 = (
    "Ainsworth BE, Haskell WL, Herrmann SD, Meckes N, Bassett DR Jr, Tudor-Locke C, "
    "Greer JL, Vezina J, Whitt-Glover MC, Leon AS. 2011 Compendium of Physical "
    "Activities: a second update of codes and MET values. Medicine and Science in "
    "Sports and Exercise. 2011;43(8):1575-1581."
)

#: The Compendium's own intensity bands, and the ones ACSM publishes alongside them:
#: light is under 3 METs, moderate is 3.0 to 5.9, vigorous is 6.0 and above. Every
#: activity's intensity is *derived* from its MET value rather than typed in beside it,
#: so the two can never disagree with each other.
LIGHT_BELOW_METS = 3.0
VIGOROUS_FROM_METS = 6.0

LIGHT = "light"
MODERATE = "moderate"
VIGOROUS = "vigorous"

#: The key of the "I did something else" row. It carries no MET value on purpose.
OTHER_ACTIVITY_KEY = "other"

#: Energy figures are rounded to the nearest 5 kcal before they leave the backend.
#: "About 315 kcal" is already more precise than a population average deserves; "317"
#: would be a claim of accuracy this arithmetic cannot support.
ENERGY_ROUNDS_TO_KCAL = 5

ENERGY_IS_AN_ESTIMATE = (
    "This is an estimate, not a measurement. It is worked out from the minutes you "
    "entered, the weight on your profile, and a published average energy cost for this "
    "activity measured on other people -- nothing here was measured on you, and your own "
    "figure will be different. It also counts all the energy your body used during the "
    "session, including what it would have used at rest anyway."
)

NO_WEIGHT_RECORDED = (
    "Energy is worked out from body weight, and there is no weight on your profile. Add "
    "it to your health profile and this will start showing. We would rather show you "
    "nothing than guess a weight for you."
)

NOTHING_NAMED_TO_COST = (
    "Nothing here says what the activity was, so there is no published figure to work "
    "energy out from. The minutes still count. Pick an activity by name next time and "
    "the energy will be there."
)


@dataclass(frozen=True)
class Activity:
    """One named thing a person might have spent time doing.

    ``mets`` is ``None`` for exactly one row -- "Something else" -- where we do not know
    what was done and so cannot state an energy cost. That row still counts minutes
    toward the WHO target, because the person tells us how hard it was; it simply gets no
    energy figure. Refusing to invent one is the point.
    """

    key: str
    label: str
    #: What somebody would recognise it as, so the list reads like a life rather than a
    #: research table.
    example: str
    mets: float | None = None
    #: The Compendium's own activity code and its own wording, so every figure can be
    #: looked up rather than taken on trust.
    compendium_code: str | None = None
    compendium_description: str | None = None

    @property
    def intensity(self) -> str | None:
        """``light``, ``moderate``, ``vigorous``, or ``None`` when only the user knows."""
        if self.mets is None:
            return None
        return intensity_for_mets(self.mets)

    @property
    def counts_toward_target(self) -> bool:
        """Does WHO's 150 minutes count this?

        WHO's figure is moderate-**to-vigorous** activity. Something under 3 METs is
        light, so it is good for a person and is not what the 150 minutes measures.
        Counting it would overstate the week, which is the one thing a progress bar must
        not do. "Something else" counts, because the user states the intensity.
        """
        return self.intensity is not LIGHT

    @property
    def source(self) -> str:
        """The citation for this row's MET figure, or the reason there is not one."""
        if self.mets is None:
            return (
                "No energy figure: we do not know what this was, so there is no "
                "published average to apply. The minutes still count."
            )
        return (
            f"{self.mets:g} METs -- {COMPENDIUM_2011} Activity code "
            f"{self.compendium_code}, {self.compendium_description!r}."
        )


def intensity_for_mets(mets: float) -> str:
    if mets < LIGHT_BELOW_METS:
        return LIGHT
    if mets >= VIGOROUS_FROM_METS:
        return VIGOROUS
    return MODERATE


#: The list the app shows. Ordered the way somebody would scan it rather than
#: alphabetically or by MET value: the things the owner said he actually does first,
#: then the rest, then the escape hatch last.
#:
#: Every row's MET value carries its Compendium code. Nothing is here that could not be
#: cited, and "Something else" is here precisely *because* it cannot be.
ACTIVITIES: tuple[Activity, ...] = (
    Activity(
        key="badminton",
        label="Badminton",
        example="A social game, singles or doubles",
        mets=5.5,
        compendium_code="15030",
        compendium_description="badminton, social singles and doubles, general",
    ),
    Activity(
        key="running",
        label="Running",
        example="About 10 km/h, a steady run",
        mets=9.8,
        compendium_code="12050",
        compendium_description="running, 6 mph (10 min/mile)",
    ),
    Activity(
        key="walking",
        label="Walking",
        example="A brisk walk, about 5 km/h",
        mets=3.5,
        compendium_code="17190",
        compendium_description=(
            "walking, 3.0 mph, level, moderate pace, firm surface"
        ),
    ),
    Activity(
        key="cycling",
        label="Cycling",
        example="About 20 km/h on the road",
        mets=8.0,
        compendium_code="01040",
        compendium_description=(
            "bicycling, 12-13.9 mph, leisure, moderate effort"
        ),
    ),
    Activity(
        key="gym_strength",
        label="Gym or weights",
        example="Sets of 8 to 15 reps at a steady effort",
        mets=3.5,
        compendium_code="02054",
        compendium_description=(
            "resistance (weight) training, multiple exercises, 8-15 repetitions at "
            "varied resistance"
        ),
    ),
    Activity(
        key="yoga",
        label="Yoga",
        example="Hatha yoga, held postures",
        mets=2.5,
        compendium_code="02150",
        compendium_description="yoga, Hatha",
    ),
    Activity(
        key="swimming",
        label="Swimming",
        example="Freestyle laps at an easy pace",
        mets=5.8,
        compendium_code="18240",
        compendium_description=(
            "swimming laps, freestyle, front crawl, slow, moderate or light effort"
        ),
    ),
    Activity(
        key="cricket",
        label="Cricket",
        example="Batting, bowling and fielding",
        mets=4.8,
        compendium_code="15200",
        compendium_description="cricket, batting, bowling, fielding",
    ),
    Activity(
        key="stairs",
        label="Stairs",
        example="Climbing steadily, not sprinting",
        mets=4.0,
        compendium_code="17133",
        compendium_description="stair climbing, slow pace",
    ),
    Activity(
        key="housework",
        label="Housework",
        example="Sweeping and cleaning the floors",
        mets=3.3,
        compendium_code="05040",
        compendium_description="cleaning, sweeping carpet or floors, general",
    ),
    Activity(
        key=OTHER_ACTIVITY_KEY,
        label="Something else",
        example="Anything not on this list -- tell us how hard it felt",
    ),
)

_BY_KEY: dict[str, Activity] = {activity.key: activity for activity in ACTIVITIES}


def activity_keys() -> tuple[str, ...]:
    return tuple(_BY_KEY)


def activity_for(key: str) -> Activity | None:
    """The activity with this key, or ``None``. Never a guess at what was meant."""
    return _BY_KEY.get(str(key).strip().lower())


def round_kcal(kcal: float) -> int:
    """To the nearest :data:`ENERGY_ROUNDS_TO_KCAL`, and never below zero."""
    if kcal <= 0:
        return 0
    return int(round(kcal / ENERGY_ROUNDS_TO_KCAL) * ENERGY_ROUNDS_TO_KCAL)


def energy_kcal(mets: float | None, minutes: int, weight_kg: float | None) -> float | None:
    """Energy used during ``minutes`` of an activity of ``mets``, in kilocalories.

    ``kcal = METs x body weight in kg x hours``. That is the Compendium's own arithmetic:
    one MET is defined as 1 kcal per kilogram of body weight per hour, so the product is
    the whole energy cost of the session.

    ``None`` -- never a substituted average -- whenever either input is missing:

    * no MET value, because the activity was "something else" and we do not know what it
      was;
    * no body weight on the profile, because the figure is proportional to it and a
      guessed weight would put a made-up number in front of somebody. See
      :data:`NO_WEIGHT_RECORDED`.
    """
    if mets is None or weight_kg is None or weight_kg <= 0 or minutes <= 0:
        return None
    return float(mets) * float(weight_kg) * (int(minutes) / 60.0)

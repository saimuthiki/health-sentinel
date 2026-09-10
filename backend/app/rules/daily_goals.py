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

A goal the person sets for themselves
------------------------------------
The owner asked to choose his own water goal, and named a figure well above anything we
can source. He gets it. Refusing outright would be paternalistic about his own body, and
capping him quietly at a number he did not choose would be worse -- he would believe he
was drinking one amount while the app measured another. So a chosen goal is used exactly
as typed, the sourced figure stays visible beside it, and above a threshold we can defend
from a citation the app says plainly what is known about drinking that much and suggests
a doctor. There is one hard ceiling, and it is refused out loud with its reason. All of
that is in :func:`judge_hydration_choice` and :func:`resolve_hydration_target`, with the
numbers, their sources and what is still missing written up in ``GAPS.md`` (G20).

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
from dataclasses import dataclass, replace
from datetime import date

from app.domain.enums import ActivityLevel, Sex
from app.domain.models import HealthProfile

__all__ = [
    "ADULT_MIN_AGE",
    "EAH_2015_CONSENSUS",
    "EFSA_2010_WATER",
    "FLUID_RESTRICTION_MARKERS",
    "HYDRATION_CAUTION_ABOVE_ML",
    "HYDRATION_CEILING_ML",
    "HYDRATION_FLOOR_ML",
    "HYDRATION_OVERRIDE_FIELD",
    "HYDRATION_OVERRIDE_FLOOR_ML",
    "INTENSITY_WEIGHTS",
    "IOM_2005_WATER",
    "NOAKES_2001_DIURESIS",
    "WHO_2020_ACTIVITY",
    "HydrationChoice",
    "HydrationTarget",
    "MovementTarget",
    "chosen_hydration_ml",
    "is_fluid_restricted",
    "judge_hydration_choice",
    "moderate_equivalent_minutes",
    "resolve_hydration_target",
    "resolve_movement_target",
    "sourced_hydration_target",
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

    The last three fields exist because the goal can now be the user's own number rather
    than ours (see :func:`resolve_hydration_target`). ``sourced_millilitres`` is what the
    guideline says for this profile and is filled in **whatever** the user picked, so the
    app can always show the published figure beside the chosen one; ``caution`` is the
    plain-language warning attached to a chosen figure above
    :data:`HYDRATION_CAUTION_ABOVE_ML`, and is empty when there is nothing to say.
    """

    millilitres: int | None
    source: str
    chosen_by_user: bool = False
    sourced_millilitres: int | None = None
    caution: str = ""


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


def sourced_hydration_target(
    profile: HealthProfile, *, on: date | None = None
) -> HydrationTarget:
    """What the **guideline** says for this person, ignoring anything they chose.

    This is the figure the app shows beside a chosen one, and the figure it falls back to
    when a chosen one is missing or out of range. :func:`resolve_hydration_target` is the
    function to call for the goal actually in force.

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
            sourced_millilitres=HYDRATION_FLOOR_ML,
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
        sourced_millilitres=millilitres,
        source=(
            f"{EFSA_2010_WATER} Adequate intake of total water for an adult "
            f"{profile.sex.value} is {litres:.1f} L/day at moderate temperature and "
            f"moderate activity, of which EFSA attributes "
            f"{int(DRINKS_SHARE_OF_TOTAL_WATER * 100)}% to drinks rather than food."
        ),
    )


# --------------------------------------------------- a goal the person sets
#
# The owner asked for a goal of his own, well above the sourced one. Refusing him outright
# would be paternalistic about his own body, and quietly capping him at a number he did
# not choose would be worse: he would think he was drinking 5 L and be shown a bar for
# something else. So the rule is warn, cite, and record -- and refuse only where the
# refusal can be defended out loud from a source.

IOM_2005_WATER = (
    "Institute of Medicine (US) Panel on Dietary Reference Intakes for Electrolytes and "
    "Water. Dietary Reference Intakes for Water, Potassium, Sodium, Chloride, and "
    "Sulfate. Washington, DC: The National Academies Press; 2005."
)

NOAKES_2001_DIURESIS = (
    "Noakes TD, Wilson G, Gray DA, Lambert MI, Dennis SC. Peak rates of diuresis in "
    "healthy humans during oral fluid overload. S Afr Med J. 2001;91(10):852-857."
)

EAH_2015_CONSENSUS = (
    "Hew-Butler T, Rosner MH, Fowkes-Godek S, et al. Statement of the Third International "
    "Exercise-Associated Hyponatremia Consensus Development Conference, Carlsbad, "
    "California, 2015. Clin J Sport Med. 2015;25(4):303-320."
)

#: The optional profile field carrying the user's own goal in millilitres. It is read
#: with :func:`getattr` and never assumed to exist: this module must keep working against
#: a profile contract that has not grown the field yet, and against a stored ``null``.
HYDRATION_OVERRIDE_FIELD = "hydration_target_override_ml"

#: Above this, a chosen goal is **shown with a warning**. It is not a safety limit; it is
#: the edge of what any published intake figure we hold supports. The highest adult
#: adequate intake for *total* water in the two sources we cite is IOM's 3.7 L/day for
#: men, and IOM attributes 75-84% of total water to drinks -- so the beverage share at the
#: top of that band is about 3.1 L/day. We round **down** to a flat 3000 ml so the warning
#: starts a little before the published range runs out rather than a little after it:
#: warning too early costs a sentence, warning too late costs the point of the warning.
HYDRATION_CAUTION_ABOVE_ML = 3000

#: Above this, a chosen goal is **refused**. No guideline publishes a daily maximum for
#: water -- IOM 2005 deliberately set no Tolerable Upper Intake Level, on the grounds that
#: healthy kidneys excrete the excess -- so this figure is ours and is written up in
#: ``GAPS.md`` (G20) as ours, for a clinician to confirm or replace.
#:
#: It is anchored on the one hard number in the literature: Noakes et al. measured peak
#: urine flow of roughly 735-970 ml/hour in healthy adults during oral fluid overload, and
#: concluded that humans cannot excrete fluid taken in much faster than that. 6000 ml
#: spread across the 16 waking hours this app schedules reminders in is 375 ml/hour --
#: about **half** the lowest of those measured peak rates. Half, and not the rate itself,
#: because a peak diuresis measured under maximal stimulation for a few hours is not a
#: rate anybody sustains all day, and because dilutional hyponatraemia happens well below
#: maximal renal clearance whenever ADH is stimulated by exercise and heat
#: (:data:`EAH_2015_CONSENSUS`). It is the most generous daily ceiling we are prepared to
#: defend, not a figure anybody should aim at.
HYDRATION_CEILING_ML = 6000

#: The lowest goal we will draw a bar for. **Not** a clinical limit and not derived from
#: any guideline: it is the point below which a "goal" stops being one. A person who wants
#: to drink less than half a litre a day does not need a progress bar, they need a doctor.
HYDRATION_OVERRIDE_FLOOR_ML = 500

#: The two numbers behind :data:`HYDRATION_CEILING_ML`, kept as constants so the
#: arithmetic in the refusal text cannot drift away from the constant it explains.
PEAK_DIURESIS_ML_PER_HOUR = 735
ASSUMED_WAKING_HOURS = 16


@dataclass(frozen=True)
class HydrationChoice:
    """The verdict on a goal somebody is trying to set.

    ``accepted`` false means we did not take the number. ``reason`` then says why, in
    words meant for the person who typed it. ``accepted`` true with a non-empty
    ``caution`` is the middle case that matters most: we took the number, and we said
    what is known about drinking that much.
    """

    millilitres: int | None
    accepted: bool
    reason: str = ""
    caution: str = ""


def chosen_hydration_ml(profile: object) -> int | None:
    """The goal recorded on this profile, or ``None`` when there is not one.

    Deliberately defensive, and deliberately typed ``object``: the field is optional on
    the profile contract, may be absent entirely, may be ``null``, and -- if it ever
    arrives from somewhere other than our own validated endpoint -- may not be a number at
    all. Every one of those cases means "the user has not chosen a goal", which is the
    case where the sourced figure is used. Nothing here can raise.
    """
    raw = getattr(profile, HYDRATION_OVERRIDE_FIELD, None)
    if raw is None or isinstance(raw, bool):
        return None
    try:
        value = int(raw)
    except (TypeError, ValueError):
        return None
    return value if value > 0 else None


def _caution_text(millilitres: int, sourced: int | None) -> str:
    """What somebody is told when the goal they picked is above the published range."""
    beside = (
        f" The figure our sources support for your profile is {sourced} ml."
        if sourced is not None
        else ""
    )
    return (
        f"{millilitres} ml a day is above the published intake figures we hold: the "
        f"highest adult adequate intake for total water is 3.7 L a day, of which about "
        f"three quarters comes from drinks ({IOM_2005_WATER}). Drinking a lot more water "
        f"than your body needs dilutes the salt in your blood, and the risk is higher "
        f"when you are sweating heavily -- which is why it turns up in people exercising "
        f"hard and drinking to a fixed high target ({EAH_2015_CONSENSUS}). It is worth "
        f"asking a doctor whether this amount is right for you. We have set your goal to "
        f"the number you chose.{beside}"
    )


def _ceiling_refusal(millilitres: int) -> str:
    """What somebody is told when the goal they picked is above the ceiling."""
    per_hour = HYDRATION_CEILING_ML // ASSUMED_WAKING_HOURS
    return (
        f"{millilitres} ml a day is more than we will set a goal for. Our limit is "
        f"{HYDRATION_CEILING_ML} ml, which across a normal waking day is about "
        f"{per_hour} ml an hour -- roughly half the slowest peak rate at which healthy "
        f"kidneys have been measured to clear water, about "
        f"{PEAK_DIURESIS_ML_PER_HOUR}-970 ml an hour ({NOAKES_2001_DIURESIS}). Water the "
        f"kidneys cannot clear is what dilutes the salt in the blood. Your goal has not "
        f"been changed. If a doctor has told you to drink more than this, follow them "
        f"rather than us, and we will track whatever amount they set."
    )


def _floor_refusal(millilitres: int) -> str:
    return (
        f"{millilitres} ml is too small a goal for us to show a bar against. The lowest "
        f"we will set is {HYDRATION_OVERRIDE_FLOOR_ML} ml. That is not a clinical limit "
        f"and it is not from a guideline -- it is the point below which a daily water "
        f"goal stops meaning anything. Your goal has not been changed."
    )


def judge_hydration_choice(
    profile: HealthProfile, millilitres: int | None, *, on: date | None = None
) -> HydrationChoice:
    """Decide what happens when this person tries to set this goal.

    Three outcomes, in the order they are checked:

    1. **Refused.** Above :data:`HYDRATION_CEILING_ML`, below
       :data:`HYDRATION_OVERRIDE_FLOOR_ML`, or above
       :data:`HYDRATION_CAUTION_ABOVE_ML` on a profile we hold **no** water figure for at
       all -- pregnancy, a condition where fluid intake is a doctor's decision, or an age
       our sources do not cover. That last case is the one worth being explicit about: a
       person on a fluid restriction must not be able to set themselves a high goal, and
       for them the app already refuses to show any goal, so accepting a large number and
       hiding it would be storing a hazard that switches itself on the day the condition
       is edited off the profile.
    2. **Accepted with a caution.** Above :data:`HYDRATION_CAUTION_ABOVE_ML`. The number
       is taken exactly as typed; the caution names the actual risk and suggests a doctor.
       It warns. It does not block, and it does not quietly round anybody down.
    3. **Accepted.** Anything else, including ``None``, which clears the goal and puts the
       sourced figure back.
    """
    if millilitres is None:
        return HydrationChoice(millilitres=None, accepted=True)

    try:
        wanted = int(millilitres)
    except (TypeError, ValueError):
        return HydrationChoice(
            millilitres=None,
            accepted=False,
            reason="A water goal has to be a whole number of millilitres.",
        )

    if wanted < HYDRATION_OVERRIDE_FLOOR_ML:
        return HydrationChoice(
            millilitres=None, accepted=False, reason=_floor_refusal(wanted)
        )
    if wanted > HYDRATION_CEILING_ML:
        return HydrationChoice(
            millilitres=None, accepted=False, reason=_ceiling_refusal(wanted)
        )

    sourced = sourced_hydration_target(profile, on=on)
    if sourced.millilitres is None:
        # No figure for this profile at all. The existing refusal text is the reason, and
        # it is the right reason: it is the one that names a doctor.
        if wanted > HYDRATION_CAUTION_ABOVE_ML:
            return HydrationChoice(
                millilitres=None,
                accepted=False,
                reason=(
                    f"We will not set a goal of {wanted} ml on this profile. "
                    f"{sourced.source}"
                ),
            )
        return HydrationChoice(
            millilitres=wanted,
            accepted=True,
            caution=(
                "Saved, but we are not showing a water goal for your profile at all. "
                f"{sourced.source}"
            ),
        )

    if wanted > HYDRATION_CAUTION_ABOVE_ML:
        return HydrationChoice(
            millilitres=wanted,
            accepted=True,
            caution=_caution_text(wanted, sourced.millilitres),
        )
    return HydrationChoice(millilitres=wanted, accepted=True)


def resolve_hydration_target(
    profile: HealthProfile, *, on: date | None = None
) -> HydrationTarget:
    """The water goal actually in force for this person: theirs if they set one, ours if
    they did not.

    The order is the whole safety argument of this function, so it is written out:

    1. :func:`sourced_hydration_target` runs first, unchanged. If it refuses to answer --
       pregnancy, a fluid-restricting condition, under 18 -- **that refusal stands**, and a
       goal the person set does not override it. The number they chose is not applied and
       not hidden either: the source string says it is not being used and why.
    2. A chosen goal outside the envelope in :func:`judge_hydration_choice` is ignored in
       favour of the sourced figure, with the reason appended. Values can be stored by any
       write path, including one this module does not own, so the check has to happen on
       the way out as well as on the way in.
    3. Otherwise the chosen goal is the goal, exactly as typed, with the sourced figure
       carried alongside it in ``sourced_millilitres`` and named in ``source`` so the app
       can always show what the evidence says next to what the person picked.
    """
    sourced = sourced_hydration_target(profile, on=on)
    chosen = chosen_hydration_ml(profile)
    if chosen is None:
        return sourced

    if sourced.millilitres is None:
        return replace(
            sourced,
            source=(
                f"{sourced.source} The goal of {chosen} ml recorded on your profile is "
                f"not being used for that reason."
            ),
        )

    verdict = judge_hydration_choice(profile, chosen, on=on)
    if not verdict.accepted:
        return replace(
            sourced,
            source=f"{sourced.source} A goal of {chosen} ml is recorded on your profile "
            f"and is not being used: {verdict.reason}",
        )

    return HydrationTarget(
        millilitres=chosen,
        chosen_by_user=True,
        sourced_millilitres=sourced.millilitres,
        caution=verdict.caution,
        source=(
            f"You set this goal yourself: {chosen} ml. The figure our sources support for "
            f"your profile is {sourced.millilitres} ml -- {sourced.source}"
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

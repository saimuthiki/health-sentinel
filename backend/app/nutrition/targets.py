"""Daily nutrient targets for a person, from a curated RDA table.

**No language model is involved anywhere in this file.** A target is a table lookup
keyed by sex, age band, activity level and pregnancy, exactly like a reference range.

Nutrient keys are deliberately identical to the keys in ``foods.per_100g``
(``docs/03-data-model.md``) -- ``iron_mg``, ``vitamin_d_ug`` and so on. If a target key
and a food key ever drift apart, every gap calculation silently becomes zero, so they
are asserted equal in the tests.

Nothing in this module is a supplement dose. These are dietary reference intakes used to
choose foods; the app must never turn one into "take N mg of X" (see ``CLAUDE.md``).
"""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass
from datetime import date

from app.domain.enums import ActivityLevel, Sex
from app.domain.models import HealthProfile, NutrientTarget

__all__ = [
    "ADULT_MIN_AGE",
    "ICMR_2020",
    "NUTRIENT_UNITS",
    "RDA_TABLE",
    "RdaRow",
    "resolve_target",
    "resolve_targets",
]

ICMR_2020 = (
    "ICMR-NIN Expert Group. Nutrient Requirements for Indians: Recommended Dietary "
    "Allowances and Estimated Average Requirements (2020)."
)
ICMR_2020_ENERGY = ICMR_2020 + " Energy requirements for reference adults by activity level."
#: The same cite-or-omit rule the database seed follows
#: (``db/seed/203_rda_targets.sql``): a nutrient whose ICMR-NIN 2020 figure could not
#: be stated with confidence is **not** in the table below. It is written up in
#: ``app/rules/GAPS.md`` and in ``db/seed/GAPS.md`` instead, and ``resolve_target``
#: returns ``None`` for it. Dietary fibre, the pregnancy and lactation increments, the
#: 60+ adjustments and every paediatric band are all missing for that reason.
CITE_OR_OMIT = ICMR_2020

#: Unit for each nutrient key. Single source of truth for display and for gap maths.
NUTRIENT_UNITS: dict[str, str] = {
    "kcal": "kcal",
    "protein_g": "g",
    "fibre_g": "g",  # no ICMR-NIN figure we could source; see GAPS.md item G4
    "iron_mg": "mg",
    "calcium_mg": "mg",
    "vitamin_d_ug": "ug",
    "b12_ug": "ug",
    "folate_ug": "ug",
    "zinc_mg": "mg",
}

#: The seeded band is adults 19-59 only. Outside it we publish no targets at all
#: rather than stretch a figure to an age group it was not measured on.
ADULT_MIN_AGE = 19
ADULT_MAX_AGE = 59

#: Gap arithmetic subtracts an intake figure from a target, so both sides must use
#: the same nutrient key by the time they meet. ``db/seed/203_rda_targets.sql`` and
#: ``foods.per_100g`` both spell energy ``kcal``; this map survives only to absorb
#: older seed data that spelt it ``energy_kcal``, and to keep the invariant explicit
#: rather than implicit. Add an entry here rather than renaming a column in flight.
RDA_NUTRIENT_ALIASES: dict[str, str] = {"energy_kcal": "kcal"}


def normalise_nutrient_key(nutrient: str) -> str:
    """The internal key for a nutrient name as written in ``rda_targets``."""
    return RDA_NUTRIENT_ALIASES.get(nutrient, nutrient)

#: ICMR activity bands. Our five-level enum collapses onto the three ICMR bands.
ACTIVITY_BAND: dict[ActivityLevel, str] = {
    ActivityLevel.SEDENTARY: "sedentary",
    ActivityLevel.LIGHT: "sedentary",
    ActivityLevel.MODERATE: "moderate",
    ActivityLevel.ACTIVE: "heavy",
    ActivityLevel.VERY_ACTIVE: "heavy",
}

#: Protein RDA per kg of body weight. Used when we know the person's weight; the table
#: rows below are the reference-body-weight fallback for when we do not.
PROTEIN_G_PER_KG = 0.83


@dataclass(frozen=True)
class RdaRow:
    """One row of the ``rda_targets`` reference table."""

    nutrient: str
    amount: float
    unit: str
    source: str
    sex: Sex | None = None
    age_min: int | None = None
    age_max: int | None = None
    activity_band: str | None = None
    pregnancy: bool | None = None


def _adult(nutrient: str, amount: float, sex: Sex | None, source: str) -> RdaRow:
    return RdaRow(
        nutrient=nutrient,
        amount=amount,
        unit=NUTRIENT_UNITS[nutrient],
        source=source,
        sex=sex,
        age_min=ADULT_MIN_AGE,
        age_max=ADULT_MAX_AGE,
    )


def _energy(amount: float, sex: Sex, band: str) -> RdaRow:
    return RdaRow(
        nutrient="kcal",
        amount=amount,
        unit="kcal",
        source=ICMR_2020_ENERGY,
        sex=sex,
        age_min=ADULT_MIN_AGE,
        age_max=ADULT_MAX_AGE,
        activity_band=band,
    )


#: Mirrors ``db/seed/203_rda_targets.sql`` row for row. Where that file omits a
#: nutrient, so does this one.
RDA_TABLE: tuple[RdaRow, ...] = (
    # ---------------------------------------------------------------- energy (kcal)
    _energy(2110, Sex.MALE, "sedentary"),
    _energy(2710, Sex.MALE, "moderate"),
    _energy(3470, Sex.MALE, "heavy"),
    _energy(1660, Sex.FEMALE, "sedentary"),
    _energy(2130, Sex.FEMALE, "moderate"),
    _energy(2720, Sex.FEMALE, "heavy"),
    # ---------------------------------------------------------------------- protein
    _adult("protein_g", 54.0, Sex.MALE, ICMR_2020),
    _adult("protein_g", 46.0, Sex.FEMALE, ICMR_2020),
    # ------------------------------------------------------------------------- iron
    _adult("iron_mg", 19.0, Sex.MALE, ICMR_2020),
    _adult("iron_mg", 29.0, Sex.FEMALE, ICMR_2020),
    # ---------------------------------------------------------------------- calcium
    _adult("calcium_mg", 1000.0, None, ICMR_2020),
    # -------------------------------------------------------------------- vitamin D
    _adult("vitamin_d_ug", 15.0, None, ICMR_2020),
    # ------------------------------------------------------------------ vitamin B12
    _adult("b12_ug", 2.2, None, ICMR_2020),
    # ----------------------------------------------------------------------- folate
    _adult("folate_ug", 300.0, None, ICMR_2020),
    # ------------------------------------------------------------------------- zinc
    _adult("zinc_mg", 17.0, Sex.MALE, ICMR_2020),
    _adult("zinc_mg", 13.0, Sex.FEMALE, ICMR_2020),
    # -------------------------------------------------------------------- pregnancy
    # Deliberately empty. ICMR-NIN 2020 gives pregnancy and lactation increments per
    # trimester and we could not state them with confidence, so a pregnant user is
    # currently resolved against the non-pregnant rows. The `pregnancy` column and
    # its specificity rule below are implemented and tested, so filling this in is a
    # data change and not a code change. See GAPS.md item G4.
)

NUTRIENTS: tuple[str, ...] = tuple(dict.fromkeys(row.nutrient for row in RDA_TABLE))


# ------------------------------------------------------------------------ resolution


def _applies(
    row: RdaRow,
    *,
    nutrient: str,
    sex: Sex | None,
    age: int | None,
    band: str | None,
    pregnant: bool,
) -> bool:
    if row.nutrient != nutrient:
        return False
    if row.sex is not None and (sex is None or sex != row.sex):
        return False
    if row.age_min is not None or row.age_max is not None:
        if age is None:
            return False
        if row.age_min is not None and age < row.age_min:
            return False
        if row.age_max is not None and age > row.age_max:
            return False
    if row.activity_band is not None and row.activity_band != band:
        return False
    return not (row.pregnancy is not None and bool(row.pregnancy) != pregnant)


def _specificity(row: RdaRow) -> int:
    score = 0
    if row.pregnancy is not None:
        score += 8
    if row.sex is not None:
        score += 4
    if row.activity_band is not None:
        score += 2
    if row.age_min is not None or row.age_max is not None:
        score += 1
    return score


def resolve_target(
    profile: HealthProfile,
    nutrient: str,
    *,
    on: date | None = None,
    table: Sequence[RdaRow] = RDA_TABLE,
) -> NutrientTarget | None:
    """The most specific RDA row for this person, or ``None`` if we have none.

    ``None`` is a real answer. We would rather show a user no target than a target
    invented for an age group we never curated.
    """
    age = profile.age_on(on or date.today())
    sex = None if profile.sex is Sex.OTHER else profile.sex
    band = ACTIVITY_BAND.get(profile.activity_level)
    pregnant = bool(profile.is_pregnant)

    candidates = [
        row
        for row in table
        if _applies(row, nutrient=nutrient, sex=sex, age=age, band=band, pregnant=pregnant)
    ]
    if not candidates:
        return None
    row = max(candidates, key=_specificity)

    amount = row.amount
    source = row.source
    if nutrient == "protein_g" and profile.weight_kg:
        amount = round(PROTEIN_G_PER_KG * profile.weight_kg, 1)
        source = (
            f"{ICMR_2020} Protein RDA of {PROTEIN_G_PER_KG} g/kg body weight applied to "
            f"a recorded weight of {profile.weight_kg:g} kg."
        )

    return NutrientTarget(
        nutrient=row.nutrient, amount=amount, unit=row.unit, source=source
    )


def resolve_targets(
    profile: HealthProfile,
    *,
    on: date | None = None,
    nutrients: Sequence[str] = NUTRIENTS,
    table: Sequence[RdaRow] = RDA_TABLE,
) -> list[NutrientTarget]:
    """Every target we can resolve for this person, in table order."""
    resolved = [
        resolve_target(profile, nutrient, on=on, table=table) for nutrient in nutrients
    ]
    return [target for target in resolved if target is not None]

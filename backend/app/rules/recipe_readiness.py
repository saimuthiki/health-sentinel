"""Which plan items need a method, and which need nothing at all.

The owner said it himself:

    "something like sunflower seeds, he can directly buy it from the store, so there is
    no preparation for it."

So the first question a recipe feature has to answer is not "how do I cook this" but
"is there anything to cook". Generating a method for a handful of seeds costs a model
call, costs money, and hands somebody four condescending steps for opening a packet.

The answer is decided **here, in Python, from the ``foods`` table** -- the food group and
the food's own name, both curated data -- before any model is considered. No model is
asked whether a food needs cooking, for the same reason no model is asked what a lab
value means: it is a lookup, and a lookup that is sometimes confidently wrong is worse
than a table.

Three outcomes:

* :data:`PreparationNeed.NONE` -- eat it as it comes. A curated sentence, no model call.
* :data:`PreparationNeed.INGREDIENT` -- oil, sugar, salt. Not a dish anybody makes on its
  own; it belongs *inside* another item's method, and a recipe screen for it would be
  nonsense.
* :data:`PreparationNeed.METHOD` -- everything else. This is the only case that reaches
  :mod:`app.planner.recipe_method` and therefore the only case that costs anything.

Being wrong in the NONE direction costs somebody a method they might have liked; being
wrong in the METHOD direction costs a model call and looks silly. Neither is a safety
question, which is why this is allowed to be a judgement call in curated data at all.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum


class PreparationNeed(StrEnum):
    """What, if anything, this food needs doing to it."""

    NONE = "none"
    INGREDIENT = "ingredient"
    METHOD = "method"


#: Food groups whose members are eaten as they are. Nuts and seeds are the owner's own
#: example; fruit is the same case and is by far the commonest one on a plan.
READY_TO_EAT_GROUPS: frozenset[str] = frozenset({"nut_seed", "fruit"})

#: Groups that are cooking materials rather than dishes.
INGREDIENT_ONLY_GROUPS: frozenset[str] = frozenset({"oil_fat", "sugar_sweetener"})

#: Names that are eaten as they come whatever group they sit in. Matched as a whole word
#: against the lower-cased name and local name, so "Curd (dahi)" and "Toned milk" are
#: both caught and "Milk-based kheer" -- a dish -- is not, because "kheer" is not in here
#: and the match has to be on one of these words alone.
READY_TO_EAT_NAME_WORDS: frozenset[str] = frozenset(
    {
        "milk",
        "curd",
        "dahi",
        "yoghurt",
        "yogurt",
        "buttermilk",
        "chaas",
        "honey",
        "lassi",
    }
)

#: Names inside a ready-to-eat group that still need real cooking. Small and explicit:
#: raw jackfruit is a vegetable dish, copra is grated into things, and a plan that says
#: "make this" about either of them should offer a method.
NEEDS_METHOD_NAME_WORDS: frozenset[str] = frozenset({"copra", "raw", "unripe"})


@dataclass(frozen=True)
class Readiness:
    """The decision, and the sentence that explains it to the reader.

    ``note`` is curated copy from this module. It goes to the screen through
    ``guarded_deterministic`` like every other string this codebase writes, and it is
    never generated.
    """

    need: PreparationNeed
    note: str = ""

    @property
    def wants_a_method(self) -> bool:
        return self.need is PreparationNeed.METHOD


#: The sentence for a food that needs nothing doing to it. The portion line is added
#: beside it by the API, from the plan's own grams -- so "how much" is always answered
#: even when "how" has no answer.
READY_TO_EAT_NOTE = (
    "Nothing to make here. This is eaten as it comes -- pick it up at the shop, measure "
    "out your portion, and that is the whole job."
)

INGREDIENT_NOTE = (
    "This one is a cooking ingredient rather than a dish. It belongs inside whatever you "
    "are making that day, so there is no separate method for it."
)


def assess(
    *, food_group: str | None, name: str = "", name_local: str | None = None
) -> Readiness:
    """Decide what this food needs. Pure, and safe with anything missing.

    An unknown or missing food group falls through to :data:`PreparationNeed.METHOD`,
    which is the conservative direction: an unnecessary method is a wasted call, a missing
    one is somebody staring at a dish they do not know how to cook.
    """
    words = _words(name, name_local)
    group = (food_group or "").strip().lower()

    if group in INGREDIENT_ONLY_GROUPS:
        return Readiness(PreparationNeed.INGREDIENT, INGREDIENT_NOTE)

    if words & NEEDS_METHOD_NAME_WORDS:
        return Readiness(PreparationNeed.METHOD)

    if group in READY_TO_EAT_GROUPS or words & READY_TO_EAT_NAME_WORDS:
        return Readiness(PreparationNeed.NONE, READY_TO_EAT_NOTE)

    return Readiness(PreparationNeed.METHOD)


def _words(name: str, name_local: str | None) -> frozenset[str]:
    """Both names, lower-cased, split on anything that is not a letter."""
    joined = f"{name or ''} {name_local or ''}".lower()
    out: list[str] = []
    current: list[str] = []
    for char in joined:
        if char.isalpha():
            current.append(char)
        elif current:
            out.append("".join(current))
            current = []
    if current:
        out.append("".join(current))
    return frozenset(out)


__all__ = [
    "INGREDIENT_NOTE",
    "INGREDIENT_ONLY_GROUPS",
    "NEEDS_METHOD_NAME_WORDS",
    "READY_TO_EAT_GROUPS",
    "READY_TO_EAT_NAME_WORDS",
    "READY_TO_EAT_NOTE",
    "PreparationNeed",
    "Readiness",
    "assess",
]

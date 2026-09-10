"""Which drug names are also things we measure, and why that changes the rule.

The principle, straight from the charter: **naming an analyte that was measured is not
prescribing.** "Your free thyroxine is 1.2 ng/dL" is a fact about a blood test; "take
thyroxine 50 mcg daily" is a prescription. Both contain a word that is in
:mod:`app.safety.drugs`, and only the second one is a violation.

So a term that is *both* a drug and an analyte -- a **dual-use** term -- earns a
``MEDICATION_NAMED`` violation only when the sentence around it is about prescribing.
Every other drug name stays an absolute violation exactly as before: naming metformin at
all is a violation, cue or no cue.

:data:`DUAL_USE_DRUGS` is **derived**, not typed out. It is the intersection of the drug
dictionary with :func:`app.rules.biomarker_vocabulary.analyte_names`, computed once at
import from data that is already in the repository. Nobody has to remember to add the
fifth collision: seeding the biomarker puts it here.

Two ways a drug term counts as a name for an analyte:

* the drug's words appear **consecutively and whole** inside an analyte name --
  ``insulin`` in "Fasting Insulin", ``testosterone`` in "Total Testosterone",
  ``thyroxine`` in "Free Thyroxine";
* the drug is a single word of at least :data:`_STEM_MIN` characters and an analyte word
  **ends with it** -- ``cholecalciferol`` in "25 hydroxycholecalciferol". Chemical
  prefixes (hydroxy-, methyl-, cyano-) glue onto a stem, and at that length the stem is
  the substance rather than a coincidence. Anything shorter is required to match whole,
  so short brand names ("Eno", "Dapa", "Pan-D") can never be dragged in by a substring.

The set is asserted in ``tests/safety/test_dual_use_analytes.py``: it must contain the
four terms that broke a real report, and it must not contain a term that is only ever a
drug.
"""

from __future__ import annotations

import re
from collections.abc import Iterable

from app.rules.biomarker_vocabulary import analyte_names
from app.safety.drugs import BRAND_DRUGS, GENERIC_DRUGS

#: Words, lower-cased, with digits and punctuation dropped. "Vitamin D (25-OH)" ->
#: ``("vitamin", "d", "oh")``; "pan-d" -> ``("pan", "d")``.
_WORDS = re.compile(r"[a-z]+")

#: Shortest single word allowed to match as a chemical stem inside a longer word.
#: ``cholecalciferol`` (15) qualifies; no drug name below this length does.
_STEM_MIN = 8


def _words(text: str) -> tuple[str, ...]:
    return tuple(_WORDS.findall(text.lower()))


def _is_run_of(needle: tuple[str, ...], haystack: tuple[str, ...]) -> bool:
    """True when ``needle`` appears as consecutive whole words of ``haystack``."""
    size = len(needle)
    if not size or size > len(haystack):
        return False
    return any(haystack[i : i + size] == needle for i in range(len(haystack) - size + 1))


def derive_dual_use(drug_terms: Iterable[str], names: Iterable[str]) -> frozenset[str]:
    """The drug terms that ``names`` also uses for something we measure.

    Pure: same inputs, same answer, no IO. Exposed separately from
    :data:`DUAL_USE_DRUGS` so the test can run the same rule over a vocabulary it
    controls and prove that the rule -- not just today's data -- keeps drug-only terms
    out.
    """
    analytes = [_words(name) for name in names]
    analyte_words = {word for name in analytes for word in name}
    dual_use: set[str] = set()
    for term in drug_terms:
        words = _words(term)
        if not words:
            continue
        if any(_is_run_of(words, name) for name in analytes):
            dual_use.add(term.lower())
            continue
        if len(words) == 1 and len(words[0]) >= _STEM_MIN:
            stem = words[0]
            if any(word != stem and word.endswith(stem) for word in analyte_words):
                dual_use.add(term.lower())
    return frozenset(dual_use)


#: Drug names our own biomarker catalogue also uses for something we measure. Today:
#: cholecalciferol, cyanocobalamin, insulin, testosterone, thyroxine.
DUAL_USE_DRUGS: frozenset[str] = derive_dual_use(
    GENERIC_DRUGS | BRAND_DRUGS, analyte_names()
)

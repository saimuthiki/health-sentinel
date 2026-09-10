"""The medication rail against words that are both a drug and a thing we measure.

The bug this file exists for: the owner uploaded a real thyroid panel, our own review
copy said "We do not recognise the unit 'ngdl' printed for Free Thyroxine", our own
medication rail fired on "Thyroxine", ``guarded_deterministic`` raised, and
``GET /v1/reports/{id}`` answered 500 for a report the person could see on paper.

Two things are asserted here and they pull in opposite directions:

* naming an analyte that was measured is **not** prescribing, so the four names that
  broke that report are clean as bare row labels and inside a real sentence;
* naming a medicine is still naming a medicine, so those same words in a prescribing
  sentence still fire, and a name that is only ever a drug fires with no cue at all.

The second one is the load-bearing one. If it ever goes green by accident the rail has
been weakened, not fixed.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from app.domain.enums import SafetyViolation
from app.rules import biomarker_vocabulary as vocabulary
from app.safety.analytes import DUAL_USE_DRUGS, derive_dual_use
from app.safety.drugs import BRAND_DRUGS, GENERIC_DRUGS
from app.safety.validator import find_medications, validate

MED = SafetyViolation.MEDICATION_NAMED

#: The four collisions from the production report, plus the one the derivation also
#: finds: "Vitamin B12 (Cobalamin)" is printed as cyanocobalamin by plenty of labs.
BROKE_A_REAL_REPORT = ("thyroxine", "insulin", "testosterone", "cholecalciferol")


def _violations(text: str) -> set[SafetyViolation]:
    return {finding.violation for finding in validate(text).findings}


# ------------------------------------------------------- the set, and where it is from


def test_the_dual_use_set_contains_every_term_that_broke_a_report() -> None:
    for term in BROKE_A_REAL_REPORT:
        assert term in DUAL_USE_DRUGS, f"{term} is an analyte we measure and a drug name"


def test_the_dual_use_set_is_small_and_every_member_is_really_an_analyte() -> None:
    """A relaxation this broad has to be justified term by term."""
    expected = frozenset(
        {"cholecalciferol", "cyanocobalamin", "insulin", "testosterone", "thyroxine"}
    )
    assert expected == DUAL_USE_DRUGS
    names = " | ".join(vocabulary.analyte_names()).lower()
    for term in DUAL_USE_DRUGS:
        assert term in names, f"{term} is not a name anything in our catalogue is called"


@pytest.mark.parametrize(
    "term",
    ["metformin", "levothyroxine", "atorvastatin", "thyronorm", "eltroxin", "glycomet",
     "prednisolone", "methylcobalamin", "ferrous sulphate", "calcitriol", "shelcal"],
)
def test_a_term_that_is_only_ever_a_drug_is_not_dual_use(term: str) -> None:
    """The guard on the derivation. ``levothyroxine`` is the one to watch: it contains
    a dual-use term as a substring and must not be dragged in by it."""
    assert term in (GENERIC_DRUGS | BRAND_DRUGS)
    assert term not in DUAL_USE_DRUGS


def test_the_derivation_rule_itself_refuses_a_substring_coincidence() -> None:
    """Run the rule over a vocabulary the test controls, not over today's data.

    ``metformin`` is inside "Metformin Assay" as a whole word, so a catalogue that really
    measured it would make it dual-use -- that is the rule working. ``eno`` inside
    "adenosine" and ``dapa`` inside "dapaglitazone-like" are coincidences, and the rule
    keeps them out because a term shorter than the chemical-stem length has to match as
    a whole word.
    """
    drugs = ["metformin", "eno", "dapa", "cholecalciferol", "insulin"]
    catalogue = ["Adenosine Deaminase", "Dapaglitazone-like Substance", "Fasting Insulin",
                 "25 hydroxycholecalciferol"]
    assert derive_dual_use(drugs, catalogue) == frozenset({"insulin", "cholecalciferol"})
    assert derive_dual_use(drugs, [*catalogue, "Metformin Assay"]) == frozenset(
        {"insulin", "cholecalciferol", "metformin"}
    )


# ------------------------------------------- the vocabulary really mirrors db/seed/*.sql

_SEED = Path(__file__).resolve().parents[3] / "db" / "seed"
_HEADER = re.compile(r"insert\s+into\s+public\.(\w+)\s*\(([^)]*)\)", re.I)
_LITERAL = re.compile(r"'((?:[^']|'')*)'|\b(null|true|false)\b", re.I)


def _seeded(path: Path, table: str, column: str) -> set[str]:
    """Every value of ``column`` in the ``insert into public.<table>`` rows of ``path``.

    A deliberately small SQL reader: it tracks the column list of each insert statement,
    reads the quoted literals of each ``(...)`` row line, and takes the one at that
    column's index. That is enough for the two seed files and it will fail loudly rather
    than quietly if their shape ever changes -- the counts below are asserted.
    """
    values: set[str] = set()
    index: int | None = None
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        header = _HEADER.search(line)
        if header:
            index = None
            if header.group(1).lower() == table:
                columns = [name.strip().lower() for name in header.group(2).split(",")]
                index = columns.index(column)
            line = line[header.end() :].strip().removeprefix("values").strip()
        if index is None or not line.startswith("("):
            continue
        cells = [
            quoted.replace("''", "'") if quoted else bare
            for quoted, bare in _LITERAL.findall(line)
        ]
        if len(cells) > index:
            values.add(cells[index])
    return values


def test_the_seed_files_are_where_this_test_thinks_they_are() -> None:
    assert (_SEED / "200_biomarkers.sql").is_file()
    assert (_SEED / "201_biomarker_synonyms.sql").is_file()


def test_the_display_names_mirror_the_seed_row_for_row() -> None:
    """Seed a biomarker and this fails until you mirror it. That is the point: a
    hand-maintained list of collisions would rot in silence and the next collision would
    be another 500 on somebody's report."""
    seeded = _seeded(_SEED / "200_biomarkers.sql", "biomarkers", "display_name")
    assert len(seeded) == 88
    assert seeded == vocabulary.SEEDED_DISPLAY_NAMES


def test_the_synonyms_mirror_the_seed_row_for_row() -> None:
    seeded = _seeded(_SEED / "201_biomarker_synonyms.sql", "biomarker_synonyms", "synonym")
    assert len(seeded) == 389
    assert seeded == vocabulary.SEEDED_SYNONYMS


def test_the_python_catalogue_is_folded_in_too() -> None:
    """``25 hydroxycholecalciferol`` is only in ``app.rules.normalise``, not in the seed.
    Without the Python half of the vocabulary, cholecalciferol would not be dual-use."""
    names = vocabulary.analyte_names()
    assert "25 hydroxycholecalciferol" in names
    assert "Fasting Insulin" in names  # seed side
    assert "free thyroxine" in names  # both sides


# ------------------------------------------------------- naming an analyte is not a drug


@pytest.mark.parametrize(
    "label",
    ["Thyroxine (T4)", "Free Thyroxine", "Total Testosterone", "Fasting Insulin",
     "Serum Insulin (Fasting)", "Cholecalciferol", "Vitamin B12 (Cobalamin)"],
)
def test_a_bare_biomarker_name_is_not_a_medication(label: str) -> None:
    assert find_medications(label) == []
    assert _violations(label) == set()


@pytest.mark.parametrize(
    "sentence",
    [
        "Your Free Thyroxine is 1.2 ng/dL, which is in the usual range.",
        "Total Testosterone is 450 ng/dL, inside our reference range.",
        "Fasting Insulin is 8.5 uIU/mL, above our reference range.",
        "We do not recognise the unit 'ngdl' printed for Free Thyroxine.",
        "We could not match the test name 'Total Testosterone' to a biomarker we know.",
        "We could not match the test name 'Fasting Insulin' to a biomarker we know.",
        "Cholecalciferol is the form of vitamin D your skin makes in sunlight.",
    ],
)
def test_a_real_sentence_about_a_measurement_is_clean(sentence: str) -> None:
    assert _violations(sentence) == set(), sentence


# ------------------------------------------------------------ the rail is not weakened


@pytest.mark.parametrize(
    "sentence",
    [
        "Take thyroxine 50 mcg daily.",
        "Start insulin.",
        "Your doctor prescribed testosterone.",
        "Stop your thyroxine for a week.",
        "Your doctor may switch you to insulin.",
        "You need thyroxine.",
        "Take one cholecalciferol capsule every week.",
        "Cholecalciferol sachets are a pharmacy product.",
        "Ask about thyroxine or metformin at your next visit.",
        "Testosterone therapy is a decision for your doctor.",
        "The usual insulin dose is a question for your doctor.",
    ],
)
def test_a_dual_use_name_in_a_prescribing_sentence_still_fires(sentence: str) -> None:
    assert MED in _violations(sentence), sentence


@pytest.mark.parametrize(
    "sentence",
    ["metformin", "Metformin.", "thyronorm", "Thyronorm", "Glycomet", "atorvastatin",
     "levothyroxine", "Eltroxin", "Wysolone"],
)
def test_a_drug_that_is_not_an_analyte_still_fires_with_no_cue_at_all(sentence: str) -> None:
    """**The assertion that proves the rail was not weakened.**

    No verb, no dose, no medicine word, no sentence around it -- just the name. Every one
    of these is a ``MEDICATION_NAMED`` violation, exactly as before this change. If this
    test ever fails, the dual-use exception has leaked out of the five terms it is for.
    """
    assert _violations(sentence) == {MED}, sentence


def test_every_drug_that_is_not_dual_use_fires_on_its_own() -> None:
    """The same claim over the whole dictionary rather than a sample of it."""
    missed = [
        term
        for term in sorted(GENERIC_DRUGS | BRAND_DRUGS)
        if term not in DUAL_USE_DRUGS and MED not in _violations(term)
    ]
    assert missed == []


def test_a_dual_use_name_beside_a_dose_fires_even_with_no_verb() -> None:
    """A dose-tier quantity is prescribing context on its own. ``ng/dL`` is not a dose,
    and that difference is what separates a lab line from a prescription."""
    assert MED in _violations("Thyroxine 50 mcg")
    assert _violations("Thyroxine 1.2 ng/dL") == set()

"""Stage 3 -- normalisation. Printed lab row -> canonical biomarker + canonical unit.

**No language model is involved anywhere in this file.** Everything here is a table
lookup, a regular expression, or a multiplication. That is the whole point: the value we
store as "your haemoglobin" must be reproducible, auditable and reviewable by a human.

Three things happen to every extracted row:

1. ``printed_test_name`` is mapped to a canonical biomarker code through a synonym table.
2. ``value_text`` is parsed out of whatever the lab printed ("14.2", "<0.5", "1,240",
   "14.2 ng/mL", "Positive").
3. ``unit_text`` is converted to the canonical unit for that biomarker.

If **any** of those three steps is not confident, the row comes back with
``needs_review=True`` and a human-readable ``review_reason``. We never guess a health
number -- see the safety charter in ``CLAUDE.md``.
"""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass
from datetime import date
from decimal import Decimal, InvalidOperation
from difflib import get_close_matches

from pydantic import BaseModel, ConfigDict, Field

from app.domain.enums import ResultStatus
from app.domain.models import ClassifiedResult, ExtractedRow

# --------------------------------------------------------------------------- biomarkers


@dataclass(frozen=True)
class BiomarkerSpec:
    """One canonical biomarker: what we call it, and the unit we store it in.

    ``higher_is_worse`` mirrors the column of the same name in
    ``db/seed/200_biomarkers.sql``:

    * ``True``  -- only a high value is a concern (LDL, triglycerides);
    * ``False`` -- only a low value is a concern (haemoglobin, ferritin);
    * ``None``  -- both directions matter (potassium, sodium).

    :mod:`app.rules.classify` needs it to decide when it is entitled to say
    "normal": a range that only bounds the direction that does not matter cannot
    place a value.
    """

    code: str
    display_name: str
    canonical_unit: str
    category: str
    higher_is_worse: bool | None = None


#: The canonical biomarker catalogue. Mirrors the ``biomarkers`` reference table
#: (``docs/03-data-model.md``). Canonical units are chosen to match the units the
#: red-flag thresholds in ``app.rules.red_flags`` are written in, so that no conversion
#: ever happens at threshold-comparison time.
BIOMARKERS: dict[str, BiomarkerSpec] = {
    b.code: b
    for b in (
        BiomarkerSpec("HB", "Haemoglobin", "g/dL", "haematology", False),
        BiomarkerSpec("PLT", "Platelet Count", "10^3/uL", "haematology", False),
        BiomarkerSpec("WBC", "Total Leucocyte Count (WBC)", "10^3/uL", "haematology"),
        BiomarkerSpec("MCV", "Mean Corpuscular Volume", "fL", "haematology"),
        BiomarkerSpec("NEUT_PCT", "Neutrophils", "%", "haematology"),
        # Not in db/seed/200_biomarkers.sql yet -- see GAPS.md item G13. The
        # neutropenia red flag needs an absolute count, not the percentage.
        BiomarkerSpec(
            "NEUTROPHILS_ABS", "Absolute Neutrophil Count", "/uL", "haematology", False
        ),
        BiomarkerSpec("SODIUM", "Sodium", "mmol/L", "electrolyte"),
        BiomarkerSpec("POTASSIUM", "Potassium", "mmol/L", "electrolyte"),
        BiomarkerSpec("CHLORIDE", "Chloride", "mmol/L", "electrolyte"),
        BiomarkerSpec("CALCIUM", "Calcium (total)", "mg/dL", "mineral"),
        BiomarkerSpec("MAGNESIUM", "Magnesium", "mg/dL", "mineral"),
        BiomarkerSpec("CREATININE", "Creatinine", "mg/dL", "kidney", True),
        BiomarkerSpec("UREA", "Blood Urea", "mg/dL", "kidney", True),
        BiomarkerSpec("URIC_ACID", "Uric Acid", "mg/dL", "kidney", True),
        BiomarkerSpec("EGFR", "eGFR", "mL/min/1.73m2", "kidney", False),
        BiomarkerSpec("GLUCOSE_FASTING", "Fasting Blood Glucose", "mg/dL", "glycaemic"),
        BiomarkerSpec("GLUCOSE_PP", "Post-Prandial Blood Glucose", "mg/dL", "glycaemic", True),
        BiomarkerSpec("GLUCOSE_RANDOM", "Random Blood Glucose", "mg/dL", "glycaemic", True),
        BiomarkerSpec("HBA1C", "HbA1c", "%", "glycaemic", True),
        BiomarkerSpec("TSH", "Thyroid Stimulating Hormone", "uIU/mL", "thyroid"),
        BiomarkerSpec("FT4", "Free T4", "ng/dL", "thyroid"),
        BiomarkerSpec("FT3", "Free T3", "pg/mL", "thyroid"),
        BiomarkerSpec("VITD_25OH", "Vitamin D (25-OH)", "ng/mL", "vitamin", False),
        BiomarkerSpec("VITB12", "Vitamin B12", "pg/mL", "vitamin", False),
        BiomarkerSpec("FOLATE", "Folate", "ng/mL", "vitamin", False),
        BiomarkerSpec("FERRITIN", "Ferritin", "ng/mL", "iron_studies", False),
        BiomarkerSpec("IRON", "Serum Iron", "ug/dL", "iron_studies", False),
        # Not in db/seed/200_biomarkers.sql yet -- see GAPS.md item G13.
        BiomarkerSpec("ZINC", "Zinc", "ug/dL", "mineral", False),
        BiomarkerSpec("CHOL_TOTAL", "Total Cholesterol", "mg/dL", "lipid", True),
        BiomarkerSpec("LDL", "LDL Cholesterol", "mg/dL", "lipid", True),
        BiomarkerSpec("HDL", "HDL Cholesterol", "mg/dL", "lipid", False),
        BiomarkerSpec("TRIG", "Triglycerides", "mg/dL", "lipid", True),
        BiomarkerSpec("ALT", "ALT (SGPT)", "U/L", "liver", True),
        BiomarkerSpec("AST", "AST (SGOT)", "U/L", "liver", True),
        BiomarkerSpec("CRP_HS", "hs-CRP", "mg/L", "inflammation", True),
    )
}


def higher_is_worse(code: str) -> bool | None:
    """Which direction is the concerning one for this biomarker (or both)."""
    spec = BIOMARKERS.get(code)
    return spec.higher_is_worse if spec else None


def canonical_unit(code: str) -> str | None:
    spec = BIOMARKERS.get(code)
    return spec.canonical_unit if spec else None


def display_name(code: str) -> str | None:
    spec = BIOMARKERS.get(code)
    return spec.display_name if spec else None


# ----------------------------------------------------------------------------- synonyms

#: printed test name (after :func:`normalise_name`) -> canonical biomarker code.
#: Keep additions here, never in application code. This mirrors ``biomarker_synonyms``.
_RAW_SYNONYMS: dict[str, tuple[str, ...]] = {
    "HB": ("haemoglobin", "hemoglobin", "hb", "hgb", "haemoglobin hb", "hemoglobin hb",
           "haemoglobin level", "hb estimation", "haemoglobin (hb)"),
    "PLT": ("platelet count", "platelets", "platelet", "plt", "plt count",
                  "total platelet count", "platelet count plt"),
    "WBC": ("wbc", "wbc count", "total leucocyte count", "total leukocyte count", "tlc",
            "white blood cell count", "total wbc count"),
    "NEUTROPHILS_ABS": ("absolute neutrophil count", "anc", "neutrophils absolute",
                        "absolute neutrophils", "neutrophil absolute count"),
    "MCV": ("mcv", "mean corpuscular volume"),
    "SODIUM": ("sodium", "na", "sodium na", "serum sodium"),
    "POTASSIUM": ("potassium", "k", "potassium k", "serum potassium"),
    "CHLORIDE": ("chloride", "cl", "chloride cl"),
    "CALCIUM": ("calcium", "calcium total", "total calcium", "ca"),
    "CREATININE": ("creatinine", "serum creatinine", "creat", "creatinine serum"),
    "UREA": ("urea", "blood urea", "bun", "blood urea nitrogen"),
    "URIC_ACID": ("uric acid", "serum uric acid"),
    "GLUCOSE_FASTING": ("fasting blood sugar", "fbs", "fasting glucose",
                        "glucose fasting", "fasting blood glucose", "blood sugar fasting",
                        "sugar fasting", "fasting plasma glucose", "fpg"),
    "GLUCOSE_PP": ("post prandial blood sugar", "ppbs", "post prandial glucose",
                   "glucose post prandial", "pp blood sugar", "blood sugar pp",
                   "post prandial blood glucose", "2 hour post prandial glucose"),
    "GLUCOSE_RANDOM": ("random blood sugar", "rbs", "random glucose",
                       "glucose random", "blood sugar random"),
    "HBA1C": ("hba1c", "hb a1c", "glycated haemoglobin", "glycated hemoglobin",
              "glycosylated haemoglobin", "glycosylated hemoglobin", "a1c",
              "haemoglobin a1c", "hemoglobin a1c", "hba1c glycated haemoglobin"),
    "TSH": ("tsh", "thyroid stimulating hormone", "thyroid stimulating hormone tsh",
            "tsh ultrasensitive", "tsh 3rd generation", "s tsh"),
    "FT4": ("ft4", "free t4", "free thyroxine", "t4 free"),
    "FT3": ("ft3", "free t3", "free triiodothyronine", "t3 free"),
    "VITD_25OH": ("vitamin d", "vitamin d 25 oh", "vitamin d 25 hydroxy",
                  "25 hydroxy vitamin d", "25 oh vitamin d", "25 ohd", "25 oh d",
                  "vit d", "vit d 25 oh", "vitamin d total", "vitamin d 25 hydroxy total",
                  "25 hydroxycholecalciferol", "vitamin d3"),
    "VITB12": ("vitamin b12", "vit b12", "b12", "cyanocobalamin", "cobalamin",
               "vitamin b 12", "vitamin b12 cyanocobalamin"),
    "FOLATE": ("folate", "folic acid", "serum folate", "vitamin b9"),
    "FERRITIN": ("ferritin", "serum ferritin"),
    "IRON": ("iron", "serum iron", "iron serum"),
    "ZINC": ("zinc", "serum zinc"),
    "CHOL_TOTAL": ("cholesterol total", "total cholesterol", "cholesterol",
                   "cholesterol serum"),
    "LDL": ("ldl cholesterol", "ldl", "cholesterol ldl", "ldl c",
                 "low density lipoprotein"),
    "HDL": ("hdl cholesterol", "hdl", "cholesterol hdl", "hdl c",
                 "high density lipoprotein"),
    "TRIG": ("triglycerides", "triglyceride", "tg", "trigly"),
    "ALT": ("alt", "sgpt", "alt sgpt", "sgpt alt", "alanine aminotransferase",
            "alanine transaminase"),
    "AST": ("ast", "sgot", "ast sgot", "sgot ast", "aspartate aminotransferase",
            "aspartate transaminase"),
}

SYNONYMS: dict[str, str] = {
    synonym: code for code, synonyms in _RAW_SYNONYMS.items() for synonym in synonyms
}

#: Specimen prefixes Indian labs print in front of a test name ("S. Ferritin").
#: Stripped before synonym lookup -- never stripped from the middle of a name.
_SPECIMEN_PREFIXES: tuple[str, ...] = (
    "s", "sr", "ser", "serum", "p", "pl", "plasma", "b", "bl", "blood", "wb",
    "whole blood", "edta", "fasting sample", "estimation of", "test", "measurement of",
)

_PUNCT = re.compile(r"[.,()\[\]{}/\\:;'\"*#|+_%-]+")
_WS = re.compile(r"\s+")


def normalise_name(printed: str) -> str:
    """Lower-case, de-punctuate and strip specimen prefixes from a printed test name.

    ``"S. Ferritin"`` and ``"SERUM  FERRITIN"`` both become ``"ferritin"``.
    """
    text = unicodedata.normalize("NFKD", printed)
    text = "".join(ch for ch in text if not unicodedata.combining(ch))
    text = text.replace("–", " ").replace("—", " ")
    text = _PUNCT.sub(" ", text.lower())
    text = _WS.sub(" ", text).strip()
    changed = True
    while changed:
        changed = False
        for prefix in _SPECIMEN_PREFIXES:
            if text.startswith(prefix + " ") and len(text) > len(prefix) + 1:
                text = text[len(prefix) + 1 :].strip()
                changed = True
                break
    return text


@dataclass(frozen=True)
class NameMatch:
    """Outcome of mapping a printed test name to a biomarker code."""

    code: str | None
    method: str  # "exact" | "fuzzy" | "none"
    confidence: float
    suggestion: str | None = None  # human-readable "did you mean" for review


#: A fuzzy match below this ratio is not offered at all.
FUZZY_SUGGEST_CUTOFF = 0.82
#: Fuzzy matches are *never* accepted silently. They always go to human review.
_SYNONYM_KEYS = tuple(SYNONYMS)


def map_test_name(printed: str) -> NameMatch:
    """Map a printed test name to a canonical code.

    An exact synonym hit is confident. Anything else is a *suggestion* only and the
    caller must mark the row ``needs_review``.
    """
    key = normalise_name(printed)
    if not key:
        return NameMatch(None, "none", 0.0)
    code = SYNONYMS.get(key)
    if code is not None:
        return NameMatch(code, "exact", 1.0)
    close = get_close_matches(key, _SYNONYM_KEYS, n=1, cutoff=FUZZY_SUGGEST_CUTOFF)
    if close:
        candidate = SYNONYMS[close[0]]
        spec = BIOMARKERS.get(candidate)
        label = spec.display_name if spec else candidate
        return NameMatch(candidate, "fuzzy", 0.5, f"is this {label}?")
    return NameMatch(None, "none", 0.0)


# -------------------------------------------------------------------------------- units

#: Free-text unit -> the canonical spelling we use internally.
UNIT_ALIASES: dict[str, str] = {
    "ng/ml": "ng/mL", "ng/mL": "ng/mL", "ngml": "ng/mL",
    "nmol/l": "nmol/L",
    "pg/ml": "pg/mL", "pgml": "pg/mL",
    "pmol/l": "pmol/L",
    "mg/dl": "mg/dL", "mgdl": "mg/dL", "mg%": "mg/dL", "mgs/dl": "mg/dL",
    "mmol/l": "mmol/L",
    "meq/l": "mEq/L",
    "g/dl": "g/dL", "gm/dl": "g/dL", "gms/dl": "g/dL", "g%": "g/dL", "gm%": "g/dL",
    "gms%": "g/dL", "gdl": "g/dL",
    "g/l": "g/L", "gm/l": "g/L",
    "uiu/ml": "uIU/mL",
    "miu/l": "mIU/L",
    "ml/min/1.73m2": "mL/min/1.73m2", "ml/min/1.73 m2": "mL/min/1.73m2",
    "%": "%", "percent": "%", "per cent": "%",
    "ug/l": "ug/L", "mcg/l": "ug/L",
    "ug/dl": "ug/dL", "mcg/dl": "ug/dL",
    "umol/l": "umol/L", "mcmol/l": "umol/L",
    "ng/dl": "ng/dL",
    "mg/l": "mg/L",
    "fl": "fL",
    "u/l": "U/L", "iu/l": "U/L",
    "10^3/ul": "10^3/uL", "10*3/ul": "10^3/uL", "x10^3/ul": "10^3/uL",
    "10e3/ul": "10^3/uL", "thou/ul": "10^3/uL", "k/ul": "10^3/uL",
    "10^3/mm3": "10^3/uL", "10^9/l": "10^3/uL", "x10 3/ul": "10^3/uL",
    "/ul": "/uL", "cells/ul": "/uL", "/cumm": "/uL", "cells/cumm": "/uL",
    "/cu mm": "/uL", "cells/cu mm": "/uL", "/mm3": "/uL", "cells/mm3": "/uL",
    "lakh/cumm": "lakh/uL", "lakhs/cumm": "lakh/uL", "lakh/ul": "lakh/uL",
    "lakhs/ul": "lakh/uL", "lac/cumm": "lakh/uL", "lakhs/cu mm": "lakh/uL",
}

_UNIT_PUNCT = re.compile(r"[\[\](){}]")


def normalise_unit(unit_text: str | None) -> str | None:
    """Canonical spelling of a printed unit, or ``None`` if we do not recognise it."""
    if unit_text is None:
        return None
    text = unicodedata.normalize("NFKD", unit_text)
    text = "".join(ch for ch in text if not unicodedata.combining(ch))
    text = text.replace("µ", "u").replace("μ", "u")
    text = _UNIT_PUNCT.sub(" ", text).strip().lower()
    text = _WS.sub(" ", text)
    text = text.replace(" / ", "/").replace("/ ", "/").replace(" /", "/")
    if not text:
        return None
    return UNIT_ALIASES.get(text) or UNIT_ALIASES.get(text.replace(" ", ""))


D = Decimal

#: Per-biomarker conversion factors *to the canonical unit*.
#: ``canonical_value = printed_value * FACTOR[code][printed_unit]``.
#: Molar conversions are analyte-specific, which is exactly why this table is keyed by
#: biomarker and not by unit pair alone.
#:
#: Molecular weights used (g/mol): 25-OH vitamin D 400.6, cyanocobalamin 1355.4,
#: glucose 180.16, cholesterol 386.7, triglyceride (as triolein) 885.4,
#: creatinine 113.12, calcium 40.08.
UNIT_FACTORS: dict[str, dict[str, Decimal]] = {
    "VITD_25OH": {"ng/mL": D("1"), "ug/L": D("1"), "nmol/L": D("1") / D("2.496")},
    "VITB12": {"pg/mL": D("1"), "ng/L": D("1"), "pmol/L": D("1") / D("0.7378")},
    "FOLATE": {"ng/mL": D("1"), "ug/L": D("1"), "nmol/L": D("1") / D("2.266")},
    "FERRITIN": {"ng/mL": D("1"), "ug/L": D("1")},
    "IRON": {"ug/dL": D("1"), "umol/L": D("5.5866")},
    "ZINC": {"ug/dL": D("1"), "umol/L": D("6.538")},
    "HB": {"g/dL": D("1"), "g/L": D("0.1"), "mmol/L": D("1.611")},
    "GLUCOSE_FASTING": {"mg/dL": D("1"), "mmol/L": D("18.0182")},
    "GLUCOSE_PP": {"mg/dL": D("1"), "mmol/L": D("18.0182")},
    "GLUCOSE_RANDOM": {"mg/dL": D("1"), "mmol/L": D("18.0182")},
    "CHOL_TOTAL": {"mg/dL": D("1"), "mmol/L": D("38.67")},
    "LDL": {"mg/dL": D("1"), "mmol/L": D("38.67")},
    "HDL": {"mg/dL": D("1"), "mmol/L": D("38.67")},
    "TRIG": {"mg/dL": D("1"), "mmol/L": D("88.57")},
    "CREATININE": {"mg/dL": D("1"), "umol/L": D("1") / D("88.4")},
    "UREA": {"mg/dL": D("1")},
    "URIC_ACID": {"mg/dL": D("1"), "umol/L": D("1") / D("59.48")},
    "CALCIUM": {"mg/dL": D("1"), "mmol/L": D("4.008"), "mEq/L": D("2.004")},
    "SODIUM": {"mmol/L": D("1"), "mEq/L": D("1")},
    "POTASSIUM": {"mmol/L": D("1"), "mEq/L": D("1")},
    "CHLORIDE": {"mmol/L": D("1"), "mEq/L": D("1")},
    "TSH": {"uIU/mL": D("1"), "mIU/L": D("1")},
    "FT4": {"ng/dL": D("1"), "pmol/L": D("1") / D("12.87")},
    "FT3": {"pg/mL": D("1"), "pmol/L": D("1") / D("1.536")},
    "HBA1C": {"%": D("1")},
    "PLT": {"10^3/uL": D("1"), "/uL": D("0.001"), "lakh/uL": D("100")},
    "WBC": {"10^3/uL": D("1"), "/uL": D("0.001")},
    "NEUTROPHILS_ABS": {"/uL": D("1"), "10^3/uL": D("1000")},
    "MCV": {"fL": D("1")},
    "NEUT_PCT": {"%": D("1")},
    "MAGNESIUM": {"mg/dL": D("1"), "mmol/L": D("2.431")},
    "EGFR": {"mL/min/1.73m2": D("1")},
    "CRP_HS": {"mg/L": D("1"), "mg/dL": D("10")},
    "ALT": {"U/L": D("1")},
    "AST": {"U/L": D("1")},
}


class UnitConversionError(ValueError):
    """Raised when a conversion is not in the table. Never fall back to a guess."""


def convert(code: str, value: Decimal, from_unit: str, to_unit: str) -> Decimal:
    """Convert ``value`` of biomarker ``code`` between two known units.

    Both directions go through the canonical unit, so ``convert`` round-trips.
    Raises :class:`UnitConversionError` rather than guessing.
    """
    factors = UNIT_FACTORS.get(code)
    if factors is None:
        raise UnitConversionError(f"no conversion table for biomarker {code!r}")
    src = normalise_unit(from_unit) or from_unit
    dst = normalise_unit(to_unit) or to_unit
    if src not in factors:
        raise UnitConversionError(f"unit {from_unit!r} is not known for {code}")
    if dst not in factors:
        raise UnitConversionError(f"unit {to_unit!r} is not known for {code}")
    return value * factors[src] / factors[dst]


def to_canonical(code: str, value: Decimal, from_unit: str) -> Decimal:
    unit = canonical_unit(code)
    if unit is None:
        raise UnitConversionError(f"unknown biomarker {code!r}")
    return convert(code, value, from_unit, unit)


# ------------------------------------------------------------------------ value parsing

#: Words a lab prints instead of a number. They are real information but they are not a
#: number, so they can never be classified against a numeric reference range.
QUALITATIVE_TERMS: dict[str, str] = {
    "positive": "positive", "pos": "positive", "reactive": "positive",
    "detected": "positive", "present": "positive",
    "negative": "negative", "neg": "negative", "non reactive": "negative",
    "nonreactive": "negative", "not detected": "negative", "absent": "negative",
    "nil": "negative", "none": "negative",
    "trace": "trace", "traces": "trace",
    "normal": "normal", "abnormal": "abnormal",
    "haemolysed": "sample_problem", "hemolysed": "sample_problem",
    "lipaemic": "sample_problem", "insufficient sample": "sample_problem",
    "qns": "sample_problem", "sample rejected": "sample_problem",
    "not done": "not_done", "nd": "not_done", "pending": "not_done",
    "to follow": "not_done", "awaited": "not_done",
}

_WESTERN_THOUSANDS = re.compile(r"^\d{1,3}(,\d{3})+$")
_INDIAN_THOUSANDS = re.compile(r"^\d{1,2}(,\d{2})*,\d{3}$")
_NUMBER = re.compile(
    r"^(?P<censor>[<>]=?|≤|≥)?\s*"
    r"(?P<number>[0-9][0-9,]*(?:\.[0-9]+)?|\.[0-9]+)\s*"
    r"(?P<rest>.*)$"
)
_RANGEY = re.compile(r"^[0-9.,]+\s*(?:-|to|–)\s*[0-9.,]+$", re.IGNORECASE)


@dataclass(frozen=True)
class ParsedValue:
    """What we could make of a printed value cell.

    ``ok`` is False whenever a human must look at it. ``censoring`` is ``"<"`` or ``">"``
    when the lab reported a detection limit rather than a measurement -- the number is
    then a *bound*, not a measurement, which is why such rows are always reviewed.
    """

    raw: str
    ok: bool
    value: Decimal | None = None
    censoring: str | None = None
    qualitative: str | None = None
    trailing_unit: str | None = None
    reason: str | None = None


def parse_value(value_text: str | None) -> ParsedValue:
    """Parse a messy printed value cell. Never guesses; failures say why."""
    raw = "" if value_text is None else str(value_text)
    text = unicodedata.normalize("NFKD", raw)
    text = "".join(ch for ch in text if not unicodedata.combining(ch))
    text = _WS.sub(" ", text.replace(" ", " ")).strip()
    if not text:
        return ParsedValue(raw, False, reason="The value cell was empty.")

    flat = _PUNCT.sub(" ", text.lower())
    flat = _WS.sub(" ", flat).strip()
    if flat in QUALITATIVE_TERMS:
        kind = QUALITATIVE_TERMS[flat]
        return ParsedValue(
            raw,
            False,
            qualitative=kind,
            reason=(
                f"The lab printed '{text}', which is a word and not a number, so it "
                "cannot be compared with a numeric reference range."
            ),
        )

    if _RANGEY.match(text):
        return ParsedValue(
            raw,
            False,
            reason=f"'{text}' looks like a range, not a single measured value.",
        )

    match = _NUMBER.match(text)
    if match is None:
        return ParsedValue(
            raw, False, reason=f"We could not read a number out of '{text}'."
        )

    digits = match.group("number")
    if "," in digits:
        if _WESTERN_THOUSANDS.match(digits) or _INDIAN_THOUSANDS.match(digits):
            digits = digits.replace(",", "")
        else:
            return ParsedValue(
                raw,
                False,
                reason=(
                    f"'{text}' uses a comma we cannot interpret with confidence -- it "
                    "could be a thousands separator or a decimal point."
                ),
            )
    try:
        number = Decimal(digits)
    except InvalidOperation:  # pragma: no cover - regex already constrains this
        return ParsedValue(raw, False, reason=f"'{text}' is not a valid number.")

    rest = match.group("rest").strip()
    trailing_unit = rest or None
    if rest and normalise_unit(rest) is None and not _looks_like_note(rest):
        return ParsedValue(
            raw,
            False,
            value=number,
            trailing_unit=rest,
            reason=f"We do not recognise '{rest}' printed after the value '{digits}'.",
        )

    censor = match.group("censor")
    if censor:
        censor = "<" if censor[0] in "<≤" else ">"
        return ParsedValue(
            raw,
            False,
            value=number,
            censoring=censor,
            trailing_unit=trailing_unit,
            reason=(
                f"The lab reported '{text}' -- the true value is only known to be "
                f"{'below' if censor == '<' else 'above'} {digits}. Please confirm the "
                "exact value with the lab."
            ),
        )

    return ParsedValue(raw, True, value=number, trailing_unit=trailing_unit)


_NOTE_WORDS = frozenset({"high", "low", "h", "l", "normal", "borderline", "abnormal"})


def _looks_like_note(rest: str) -> bool:
    """A flag letter the lab printed next to the number ("14.2 L") is not a unit."""
    return _PUNCT.sub(" ", rest.lower()).strip() in _NOTE_WORDS


# ------------------------------------------------------------------------- row -> value


class NormalisedRow(BaseModel):
    """One extracted row after normalisation.

    This type lives inside ``app.rules`` on purpose: it is the *intermediate* between
    ``ExtractedRow`` (what the page said) and ``ClassifiedResult`` (what we are prepared
    to show a user). It can hold a row we refuse to interpret, which
    ``ClassifiedResult`` -- whose ``value`` is mandatory -- cannot.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    source: ExtractedRow
    biomarker_code: str | None = None
    display_name: str | None = None
    value: Decimal | None = None
    unit: str | None = None
    censoring: str | None = None
    qualitative: str | None = None
    needs_review: bool = False
    review_reason: str | None = None
    review_reasons: list[str] = Field(default_factory=list)

    @property
    def is_usable(self) -> bool:
        """True when there is a number in a canonical unit for a known biomarker."""
        return (
            self.biomarker_code is not None
            and self.value is not None
            and self.unit is not None
        )


#: Extraction confidence below which we ask a human even if everything else parsed.
MIN_EXTRACTION_CONFIDENCE = 0.70


def normalise_row(row: ExtractedRow) -> NormalisedRow:
    """Normalise one extracted row. Anything uncertain comes back ``needs_review``."""
    reasons: list[str] = []

    name_match = map_test_name(row.printed_test_name)
    code = name_match.code
    if code is None:
        reasons.append(
            f"We could not match the test name '{row.printed_test_name.strip()}' to a "
            "biomarker we know."
        )
    elif name_match.method != "exact":
        reasons.append(
            f"We found '{row.printed_test_name.strip()}' -- "
            f"{name_match.suggestion or 'please confirm the test'}"
        )

    parsed = parse_value(row.value_text)
    if parsed.reason:
        reasons.append(parsed.reason)

    unit_text = row.unit_text or parsed.trailing_unit
    printed_unit = normalise_unit(unit_text)
    value = parsed.value
    unit: str | None = None

    if code is not None and value is not None:
        target = canonical_unit(code)
        if printed_unit is None:
            if unit_text:
                reasons.append(
                    f"We do not recognise the unit '{unit_text.strip()}' printed for "
                    f"{row.printed_test_name.strip()}."
                )
            else:
                reasons.append(
                    "No unit was printed for "
                    f"{row.printed_test_name.strip()}; we assumed {target}. "
                    "Please confirm."
                )
                printed_unit = target
        if printed_unit is not None and target is not None:
            try:
                value = to_canonical(code, value, printed_unit)
                unit = target
            except UnitConversionError:
                reasons.append(
                    f"'{printed_unit}' is not a unit we can convert to {target} for "
                    f"{display_name(code)}."
                )
                unit = printed_unit

    if row.confidence < MIN_EXTRACTION_CONFIDENCE:
        reasons.append(
            f"The reading of this line from the report was low confidence "
            f"({row.confidence:.2f})."
        )

    return NormalisedRow(
        source=row,
        biomarker_code=code,
        display_name=display_name(code) if code else None,
        value=value,
        unit=unit,
        censoring=parsed.censoring,
        qualitative=parsed.qualitative,
        needs_review=bool(reasons),
        review_reason=" ".join(reasons) if reasons else None,
        review_reasons=reasons,
    )


def normalise_rows(rows: object) -> list[NormalisedRow]:
    """Normalise an iterable of :class:`ExtractedRow`."""
    return [normalise_row(row) for row in rows]  # type: ignore[union-attr]


def to_candidate(
    row: NormalisedRow, measured_on: date | None = None
) -> ClassifiedResult | None:
    """Build the :class:`ClassifiedResult` candidate that stage 4 will classify.

    Returns ``None`` when the row has no number in a canonical unit -- such a row is
    stored for human review, not classified. ``status`` starts as ``UNKNOWN``: nothing
    is "normal" until :mod:`app.rules.classify` has said so against our own range.
    """
    if not row.is_usable:
        return None
    assert row.biomarker_code is not None and row.value is not None
    return ClassifiedResult(
        biomarker_code=row.biomarker_code,
        display_name=row.display_name or row.biomarker_code,
        value=row.value,
        unit=row.unit or "",
        status=ResultStatus.UNKNOWN,
        printed_range=row.source.printed_range,
        measured_on=measured_on,
        needs_review=row.needs_review,
        review_reason=row.review_reason,
    )

"""Deterministic safety validator — enforcement point 2 of 3.

``validate(text, escalation)`` scans one model output and returns a
:class:`~app.domain.models.SafetyReport` with precise character spans, so the API layer can
highlight or strip the offending text. No model is involved and no network call is made:
the same input always gives the same verdict, and it cannot be talked out of a verdict.

Five rules, straight from the charter in ``CLAUDE.md``:

1. ``MEDICATION_NAMED``      -- a generic or Indian brand drug name appears at all.
2. ``DOSAGE_GIVEN``          -- a quantity that is a dose rather than a food portion.
3. ``DIAGNOSIS_STATED``      -- "you have X", "you are diabetic", "this confirms".
4. ``TREATMENT_DISCOURAGED`` -- "stop taking", "you don't need your", "skip your dose".
5. ``RED_FLAG_DOWNPLAYED``   -- reassurance in an output whose escalation is URGENT.

**The one exception to rule 1 is a dual-use term** -- a word that is both a drug and an
analyte we measure: ``thyroxine``, ``insulin``, ``testosterone``, ``cholecalciferol``,
``cyanocobalamin``. Naming an analyte that was measured is not prescribing: "Your Free
Thyroxine is 1.2 ng/dL" is a fact about a blood test, and it used to be a violation, which
took a real report down with a 500. For those terms only, the violation additionally
requires a **prescribing context in the same sentence** -- see
:func:`_prescribing_context`. Which terms those are is derived from our own biomarker
catalogue in :mod:`app.safety.analytes`, never hand-written. Every other drug name is
unchanged and absolute: metformin is a violation with or without a cue.

**The hard case is rule 2.** "Take 60,000 IU of vitamin D weekly" is a prescription and must
fire; "have 100 g of ragi at breakfast" is coaching and must not. The distinction is made on
three axes, all inside a single sentence:

* the **unit tier** -- ``mg``/``IU``/``tablet`` are never kitchen measures; ``g``/``ml`` are
  usually kitchen measures; ``drops``/``units`` are genuinely ambiguous;
* whether a **medicine word or drug name** shares the sentence ("syrup", "supplement",
  "prescribed", "metformin");
* whether a **recommendation cue** is present at all ("take", "should", "daily") -- a
  quantity nobody is being told to consume is a fact, not a prescription.

Scope is bounded on purpose: kitchen units with no medicine word in the sentence are never
a dose, so an unknown food ("120 g of kodo millet") can never be a false positive, at the
cost of missing a dose phrased entirely in kitchen units with no medicine word anywhere.
"""

from __future__ import annotations

import re
from collections.abc import Iterable, Sequence

from app.domain.enums import Escalation, SafetyVerdict, SafetyViolation
from app.domain.models import SafetyFinding, SafetyReport
from app.safety.analytes import DUAL_USE_DRUGS
from app.safety.drugs import (
    AMBIGUOUS_UNITS,
    BRAND_DRUGS,
    FOOD_CONTEXT_WORDS,
    FOOD_UNITS,
    GENERIC_DRUGS,
    MEDICINE_FORM_WORDS,
    PHARMA_UNITS,
)

ALL_DRUGS: frozenset[str] = GENERIC_DRUGS | BRAND_DRUGS


# --------------------------------------------------------------------- regex helpers


def _term(name: str) -> str:
    """One dictionary term as a regex fragment: spaces flexible, hyphens optional."""
    out: list[str] = []
    for char in name:
        if char == " ":
            out.append(r"\s+")
        elif char == "-":
            out.append(r"[-\s]?")
        else:
            out.append(re.escape(char))
    return "".join(out)


def _alternation(names: Iterable[str]) -> str:
    """Longest-first alternation so ``tablespoon`` wins over ``tab``."""
    ordered = sorted({n.lower() for n in names}, key=lambda n: (-len(n), n))
    return "|".join(_term(n) for n in ordered)


#: Left/right boundaries that survive adjacent punctuation ("(metformin),").
_LEFT = r"(?<![A-Za-z0-9])"
_RIGHT = r"(?![A-Za-z0-9])"

DRUG_RE = re.compile(
    rf"{_LEFT}(?:{_alternation(ALL_DRUGS)})(?:s|es)?{_RIGHT}",
    re.IGNORECASE,
)

_UNIT_TIERS: dict[str, str] = {}
for _unit in PHARMA_UNITS:
    _UNIT_TIERS[_unit] = "pharma"
for _unit in AMBIGUOUS_UNITS:
    _UNIT_TIERS.setdefault(_unit, "ambiguous")
for _unit in FOOD_UNITS:
    _UNIT_TIERS.setdefault(_unit, "food")

_NUMBER = r"(?:\d[\d,]*(?:\.\d+)?|one|two|three|four|five|six|seven|eight|nine|ten|half)"

#: A number next to a unit. The trailing lookahead rejects concentrations such as
#: ``mg/dL`` and ``IU/L`` -- those are lab values being reported, never a dose.
QUANTITY_RE = re.compile(
    rf"(?<![\w.]){_NUMBER}\s*(?:-|–)?\s*"
    rf"(?P<unit>{_alternation(_UNIT_TIERS)})"
    rf"{_RIGHT}(?!\s*/\s*(?:dl|ml|l|kg|g|100)\b)",
    re.IGNORECASE,
)

#: Something is being recommended, not merely reported.
RECOMMENDATION_CUES: tuple[str, ...] = (
    "take", "takes", "taking", "took", "consume", "consuming", "swallow", "start",
    "starting", "begin", "add", "adding", "use", "using", "have", "having", "get",
    "buy", "inject", "apply", "pop", "supplement", "supplementing", "need", "needs",
    "should", "must", "recommend", "recommends", "recommended", "suggest", "suggests",
    "advise", "advised", "prescribe", "prescribed", "increase", "increasing", "double",
    "continue", "dose", "doses", "dosage", "daily", "weekly", "monthly", "twice",
    "thrice", "once a day", "per day", "every day", "every night", "at bedtime",
    "morning and night", "before meals", "after meals", "empty stomach", "go for",
    "stick to", "try", "keep", "make sure", "usual", "usually", "standard", "typical",
    "typically", "normally", "regimen", "course", "strength", "prescription", "per week",
    "at night", "in the morning",
)
CUE_RE = re.compile(rf"{_LEFT}(?:{_alternation(RECOMMENDATION_CUES)}){_RIGHT}", re.IGNORECASE)

#: A substance is being **prescribed**: started, stopped, changed, given or taken. Much
#: narrower than :data:`RECOMMENDATION_CUES` on purpose. This set decides whether a
#: dual-use term (:mod:`app.safety.analytes`) is a prescription or a lab result, so every
#: word here has to be one that cannot appear in an ordinary sentence *reporting* a
#: measurement. That rules out the reporting verbs "usual", "usually", "standard",
#: "typical", "suggests", "recommend", "advise" and the bare quantifiers "daily",
#: "weekly", "once", "twice" -- all of which are legitimate cues for rule 2 but would
#: fire on "Your Free Thyroxine is 1.2 ng/dL, which is in the usual range."
PRESCRIBING_CUES: tuple[str, ...] = (
    # being taken or given
    "take", "takes", "taking", "taken", "took", "consume", "consumes", "consuming",
    "swallow", "swallows", "swallowing", "inject", "injects", "injected", "injecting",
    "administer", "administers", "administered", "administering",
    # being started, stopped or changed
    "start", "starts", "started", "starting", "stop", "stops", "stopped", "stopping",
    "begin", "begins", "began", "beginning", "switch", "switches", "switched",
    "switching", "continue", "continues", "continued", "continuing",
    "increase", "increases", "increased", "increasing", "decrease", "decreases",
    "decreased", "decreasing", "reduce", "reduces", "reduced", "reducing",
    "double", "doubling", "halve", "halving", "titrate", "titrates", "titrated",
    "titrating", "adjust", "adjusts", "adjusted", "adjusting",
    "skip", "skips", "skipped", "skipping", "add", "adds", "added", "adding",
    # being ordered, or said to be needed
    "prescribe", "prescribes", "prescribing", "prescribed", "prescription",
    "need", "needs", "needed", "put you on", "puts you on", "started you on",
    # the shape of a course of treatment
    "therapy", "therapies", "treatment", "treatments", "replacement", "regimen",
    "course", "strength", "supplement", "supplements", "supplementation",
)
PRESCRIBING_CUE_RE = re.compile(
    rf"{_LEFT}(?:{_alternation(PRESCRIBING_CUES)}){_RIGHT}", re.IGNORECASE
)
MEDICINE_WORD_RE = re.compile(
    rf"{_LEFT}(?:{_alternation(MEDICINE_FORM_WORDS)}){_RIGHT}", re.IGNORECASE
)
FOOD_WORD_RE = re.compile(
    rf"{_LEFT}(?:{_alternation(FOOD_CONTEXT_WORDS)}){_RIGHT}", re.IGNORECASE
)

#: Conditions that turn "you have ..." into a diagnosis rather than small talk.
CONDITIONS: tuple[str, ...] = (
    "diabetes", "type 1 diabetes", "type 2 diabetes", "prediabetes", "pre-diabetes",
    "hypothyroidism", "hyperthyroidism", "thyroid disease", "thyroid disorder",
    "hashimoto", "hashimoto's", "graves disease", "hypertension", "high blood pressure",
    "anaemia", "anemia", "iron deficiency anaemia", "iron deficiency anemia",
    "deficiency", "pcos", "pcod", "fatty liver", "nafld", "cirrhosis", "hepatitis",
    "kidney disease", "renal failure", "ckd", "heart disease", "coronary artery disease",
    "cardiac disease", "cancer", "tumour", "tumor", "celiac", "coeliac disease",
    "ibs", "irritable bowel syndrome", "crohn", "ulcerative colitis", "arthritis",
    "rheumatoid arthritis", "gout", "osteoporosis", "asthma", "copd", "tuberculosis",
    "depression", "anxiety disorder", "insulin resistance", "metabolic syndrome",
    "hypercholesterolemia", "dyslipidemia", "obesity", "gastritis", "ulcer",
    "vitamin d deficiency", "b12 deficiency", "thalassemia", "sleep apnea", "sleep apnoea",
)

_DIAGNOSIS_PATTERNS: tuple[str, ...] = (
    rf"\byou(?:'ve| ?ve| have| got| have got)\b[^.!?\n]{{0,45}}?{_LEFT}(?:{_alternation(CONDITIONS)}){_RIGHT}",
    r"\byou(?:'re| are|\s+r)\s+(?:clearly\s+|definitely\s+|certainly\s+|likely\s+|probably\s+|a\s+|an\s+)*"
    r"(?:diabetic|pre-?diabetic|hypertensive|an?emic|anaemic|hypothyroid|hyperthyroid|"
    r"deficient|obese|asthmatic|arthritic|cirrhotic)\b",
    r"\byou\s+(?:are|were)\s+suffering\s+from\b",
    r"\bthis\s+confirms\b",
    r"\bconfirms?\s+that\s+you\b",
    r"\bthis\s+(?:is|means)\s+(?:definitely|clearly|certainly)\b",
    r"\bthis\s+means\s+you\s+have\b",
    r"\bi\s+can\s+confirm\b",
    r"\byour\s+diagnosis\s+is\b",
    r"\byou\s+(?:have\s+)?been\s+diagnosed\b",
    r"\bthis\s+proves\b",
    r"\bdiagnostic\s+of\b",
    r"\byou\s+definitely\s+have\b",
    r"\bthe\s+diagnosis\s+is\b",
    rf"\bthis\s+(?:is|looks\s+like|means)\s+(?:a\s+|an\s+)?(?:early\s+|classic\s+|clear\s+)?"
    rf"(?:case\s+of\s+)?(?:{_alternation(CONDITIONS)})(?![A-Za-z0-9-])",
)
DIAGNOSIS_RE = re.compile("|".join(f"(?:{p})" for p in _DIAGNOSIS_PATTERNS), re.IGNORECASE)

_TREATMENT_PATTERNS: tuple[str, ...] = (
    r"\bstop\s+(?:taking|using|your|the)\b",
    r"\bstop\s+(?:it|them)\s+(?:now|immediately)\b",
    r"\byou\s+(?:don'?t|do\s+not)\s+need\s+(?:your|the|to\s+take|any\s+more|anymore)\b",
    r"\byou\s+can\s+(?:stop|skip|drop|discontinue|come\s+off)\b",
    r"\b(?:skip|miss|drop|halve|reduce|lower|cut\s+down\s+on|cut\s+back\s+on)\s+"
    r"(?:your|the|his|her|today'?s|tonight'?s)\s+"
    r"(?:medicine|medicines|medication|medications|tablet|tablets|dose|doses|dosage|"
    r"pill|pills|injection|insulin|treatment|therapy|prescription)\b",
    r"\bdiscontinue\s+(?:your|the|it|them|this)\b",
    r"\bcome\s+off\s+(?:your|the)\s+(?:medicine|medication|tablet|tablets|pills?)\b",
    r"\bno\s+(?:longer\s+)?need\s+(?:for\s+)?(?:your|the)\s+"
    r"(?:medicine|medication|tablet|tablets|pills?|treatment|injection|insulin)\b",
    r"\b(?:don'?t|do\s+not|avoid)\s+(?:take|taking)\s+(?:your|the)\s+"
    r"(?:medicine|medication|tablet|tablets|pills?|dose)\b",
    r"\byou\s+can\s+manage\s+without\s+(?:your|the)\s+"
    r"(?:medicine|medication|tablets?|pills?|treatment)\b",
    r"\bdelay\s+(?:your|the)\s+(?:treatment|surgery|appointment|dose)\b",
    r"\bthere'?s\s+no\s+need\s+(?:to\s+)?(?:see|visit|consult)\s+(?:a\s+)?doctor\b",
)
TREATMENT_RE = re.compile("|".join(f"(?:{p})" for p in _TREATMENT_PATTERNS), re.IGNORECASE)

_DOWNPLAY_PATTERNS: tuple[str, ...] = (
    r"\bnothing\s+to\s+(?:worry|be\s+worried|be\s+concerned)\b",
    r"\bno\s+(?:need|reason|cause)\s+(?:to|for)\s+(?:worry|concern|panic|alarm)\b",
    r"\b(?:don'?t|do\s+not|no\s+need\s+to)\s+worry\b",
    r"\bnothing\s+(?:serious|alarming|major|to\s+panic\s+about)\b",
    r"\bthis\s+is\s+(?:completely\s+|perfectly\s+|quite\s+|totally\s+|entirely\s+)?normal\b",
    r"\b(?:that'?s|it'?s|this\s+is)\s+(?:completely\s+|perfectly\s+|quite\s+|totally\s+)?fine\b",
    r"\byou'?(?:ll|re)\s+(?:be\s+)?(?:fine|okay|ok|alright)\b",
    r"\b(?:it|this)\s+is\s+harmless\b",
    r"\bwait\s+and\s+watch\b",
    r"\bno\s+need\s+to\s+(?:see|visit|consult|rush\s+to)\s+(?:a\s+)?(?:doctor|hospital|emergency)\b",
    r"\bnot\s+(?:a\s+)?(?:big\s+deal|emergency|urgent)\b",
    r"\bnothing\s+much\s+to\s+it\b",
    r"\bcompletely\s+(?:normal|harmless|safe)\b",
    r"\bno\s+cause\s+for\s+(?:concern|alarm)\b",
)
DOWNPLAY_RE = re.compile("|".join(f"(?:{p})" for p in _DOWNPLAY_PATTERNS), re.IGNORECASE)

#: Sentence boundary: ``.``/``!``/``?`` not inside a number, plus newlines and bullets.
_SENTENCE_BOUNDARY = re.compile(r"(?<!\d)[.!?]+(?=\s|$)|[.!?]+(?=\s)|[\n;•]+")


def _sentences(text: str) -> list[tuple[int, str]]:
    """``(offset, sentence)`` pairs covering ``text``, offsets into the original."""
    spans: list[tuple[int, str]] = []
    start = 0
    for match in _SENTENCE_BOUNDARY.finditer(text):
        end = match.end()
        chunk = text[start:end]
        if chunk.strip():
            spans.append((start, chunk))
        start = end
    tail = text[start:]
    if tail.strip():
        spans.append((start, tail))
    return spans


# ------------------------------------------------------- invisible-character defence

#: Characters that carry no meaning to a reader but break a regex: zero-width spaces and
#: joiners, soft hyphens, word joiners, bidi marks. "met<ZWSP>formin" reads as "metformin".
_DROP_CHARS: frozenset[int] = frozenset(
    {0x00AD, 0x200B, 0x200C, 0x200D, 0x200E, 0x200F, 0x2060, 0xFEFF}
)

#: One-for-one lookalike folds. Length is preserved so spans stay exact.
_FOLD_CHARS: dict[int, str] = {
    0x00A0: " ", 0x2007: " ", 0x202F: " ", 0x2009: " ", 0x2002: " ", 0x2003: " ",
    0x03BC: "\u00b5",  # Greek mu -> micro sign, so "\u03bcg" is read as "\u00b5g"
    0x2010: "-", 0x2011: "-", 0x2012: "-", 0x2013: "-", 0x2014: "-", 0x2212: "-",
    0x2018: "'", 0x2019: "'", 0x201C: '"', 0x201D: '"',
}


def prepare(text: str) -> tuple[str, list[int]]:
    """Return ``(scannable_text, offsets)`` where ``offsets[i]`` indexes the original.

    Invisible characters are dropped and lookalikes folded, so an attacker cannot slip a
    drug name past a regex with a zero-width space or a curly apostrophe. Because we keep
    an index map, every span we report still points at the original text.
    """
    chars: list[str] = []
    offsets: list[int] = []
    for index, char in enumerate(text):
        code = ord(char)
        if code in _DROP_CHARS:
            continue
        chars.append(_FOLD_CHARS.get(code, char))
        offsets.append(index)
    offsets.append(len(text))  # sentinel so a span ending at the end still maps
    return "".join(chars), offsets


def _finding(
    violation: SafetyViolation,
    original: str,
    offsets: list[int],
    start: int,
    end: int,
) -> SafetyFinding:
    """Build a finding whose span and excerpt are in *original* coordinates."""
    real_start = offsets[start]
    real_end = offsets[end - 1] + 1 if end > start else real_start
    return SafetyFinding(
        violation=violation, excerpt=original[real_start:real_end], span=(real_start, real_end)
    )


# ------------------------------------------------------------------------ detectors


#: ``lower-cased, no spaces, no hyphens`` -> the dictionary term. ``DRUG_RE`` matches a
#: term with flexible whitespace, an optional hyphen and an optional plural, so this is
#: how a match is put back onto the entry it came from.
_DRUG_TERMS_BY_KEY: dict[str, str] = {
    "".join(ch for ch in term.lower() if ch not in " -"): term.lower() for term in ALL_DRUGS
}


def _dictionary_term(matched: str) -> str:
    """The dictionary entry ``matched`` came from, or the match itself if it is unknown.

    Unknown cannot really happen -- ``DRUG_RE`` is built from the dictionary -- and if it
    ever did, the term would not be in :data:`DUAL_USE_DRUGS` and so would be treated as
    an absolute violation. Failing towards the stricter rule is the right direction.
    """
    key = "".join(ch for ch in matched.lower() if ch not in " -\t\n\r")
    for candidate in (key, key[:-2] if key.endswith("es") else "", key[:-1]):
        if candidate and candidate in _DRUG_TERMS_BY_KEY:
            return _DRUG_TERMS_BY_KEY[candidate]
    return matched.lower()


def _prescribing_context(sentence: str) -> bool:
    """True when this sentence is about *giving* a substance, not about measuring one.

    Four independent signals, any one of which is enough:

    1. a prescribing cue -- take, start, stop, switch, prescribe, need, therapy;
    2. a medicine word -- tablet, capsule, injection, dose, supplement, medication;
    3. a **dose-tier** quantity -- ``50 mcg``, ``500 mg``, ``2 tablets``. Lab units are
       not dose-tier: ``ng/dL``, ``uIU/mL`` and ``ug/dL`` are all rejected by
       :data:`QUANTITY_RE`'s concentration lookahead or are not units it knows;
    4. a drug that is **not** dual-use sharing the sentence -- "thyroxine or metformin"
       is a sentence about medicines, so the dual-use word in it is one too.
    """
    if PRESCRIBING_CUE_RE.search(sentence) or MEDICINE_WORD_RE.search(sentence):
        return True
    for quantity in QUANTITY_RE.finditer(sentence):
        if _unit_tier(quantity.group("unit")) == "pharma":
            return True
    return any(
        _dictionary_term(match.group(0)) not in DUAL_USE_DRUGS
        for match in DRUG_RE.finditer(sentence)
    )


def find_medications(text: str) -> list[SafetyFinding]:
    """Rule 1: any generic or brand drug name, anywhere, in any casing.

    The single exception is a **dual-use** term -- one our own biomarker catalogue also
    uses for something we measure (:mod:`app.safety.analytes`). Those fire only when
    :func:`_prescribing_context` holds for the sentence they sit in, because otherwise
    the app cannot say "your free thyroxine is 1.2 ng/dL" about a test it just read.
    Nothing else is relaxed: a name that is only ever a drug is a violation on sight.
    """
    clean, offsets = prepare(text)
    findings: list[SafetyFinding] = []
    for offset, sentence in _sentences(clean):
        prescribing: bool | None = None
        for match in DRUG_RE.finditer(sentence):
            if _dictionary_term(match.group(0)) in DUAL_USE_DRUGS:
                if prescribing is None:
                    prescribing = _prescribing_context(sentence)
                if not prescribing:
                    continue
            findings.append(
                _finding(
                    SafetyViolation.MEDICATION_NAMED,
                    text,
                    offsets,
                    offset + match.start(),
                    offset + match.end(),
                )
            )
    return findings


def _unit_tier(unit: str) -> str:
    key = unit.lower().replace(" ", "").replace("-", "")
    for candidate, tier in _UNIT_TIERS.items():
        if candidate.replace(" ", "").replace("-", "") == key:
            return tier
    return "food"


def find_dosages(text: str) -> list[SafetyFinding]:
    """Rule 2: a dose, as opposed to a food portion. See the module docstring."""
    findings: list[SafetyFinding] = []
    clean, offsets = prepare(text)
    for offset, sentence in _sentences(clean):
        quantities = list(QUANTITY_RE.finditer(sentence))
        if not quantities:
            continue
        has_cue = bool(CUE_RE.search(sentence))
        if not has_cue:
            continue
        has_medicine_context = bool(MEDICINE_WORD_RE.search(sentence)) or bool(
            DRUG_RE.search(sentence)
        )
        has_food_context = bool(FOOD_WORD_RE.search(sentence))
        for match in quantities:
            tier = _unit_tier(match.group("unit"))
            if tier == "pharma":
                fires = True
            elif tier == "ambiguous":
                fires = has_medicine_context or not has_food_context
            else:  # kitchen measure: only a dose when a medicine shares the sentence
                fires = has_medicine_context
            if fires:
                findings.append(
                    _finding(
                        SafetyViolation.DOSAGE_GIVEN,
                        text,
                        offsets,
                        offset + match.start(),
                        offset + match.end(),
                    )
                )
    return findings


def find_diagnoses(text: str) -> list[SafetyFinding]:
    """Rule 3: stating a diagnosis instead of pointing at a doctor."""
    clean, offsets = prepare(text)
    return [
        _finding(SafetyViolation.DIAGNOSIS_STATED, text, offsets, m.start(), m.end())
        for m in DIAGNOSIS_RE.finditer(clean)
    ]


def find_treatment_discouragement(text: str) -> list[SafetyFinding]:
    """Rule 4: telling someone to stop, skip, delay or reduce a treatment."""
    clean, offsets = prepare(text)
    return [
        _finding(SafetyViolation.TREATMENT_DISCOURAGED, text, offsets, m.start(), m.end())
        for m in TREATMENT_RE.finditer(clean)
    ]


def find_downplaying(text: str, escalation: Escalation) -> list[SafetyFinding]:
    """Rule 5: reassurance is only a violation when the finding is urgent."""
    if escalation is not Escalation.URGENT:
        return []
    clean, offsets = prepare(text)
    return [
        _finding(SafetyViolation.RED_FLAG_DOWNPLAYED, text, offsets, m.start(), m.end())
        for m in DOWNPLAY_RE.finditer(clean)
    ]


# --------------------------------------------------------------------------- public


def _dedupe(findings: Sequence[SafetyFinding]) -> list[SafetyFinding]:
    seen: set[tuple[SafetyViolation, tuple[int, int]]] = set()
    out: list[SafetyFinding] = []
    for finding in sorted(findings, key=lambda f: (f.span[0], f.span[1], f.violation.value)):
        key = (finding.violation, finding.span)
        if key not in seen:
            seen.add(key)
            out.append(finding)
    return out


def scan(text: str, escalation: Escalation = Escalation.ROUTINE) -> list[SafetyFinding]:
    """Every violation in ``text``, ordered by position."""
    return _dedupe(
        [
            *find_medications(text),
            *find_dosages(text),
            *find_diagnoses(text),
            *find_treatment_discouragement(text),
            *find_downplaying(text, escalation),
        ]
    )


def validate(text: str, escalation: Escalation = Escalation.ROUTINE) -> SafetyReport:
    """Scan one model output.

    Verdict is ``PASS`` when nothing fired and ``BLOCKED`` when something did -- meaning
    "this text must not reach a user as it stands". Deciding whether to regenerate instead
    is :func:`app.safety.pipeline.guard`'s job, and it is what promotes a report to
    ``REGENERATED``.
    """
    findings = scan(text, escalation)
    verdict = SafetyVerdict.PASS if not findings else SafetyVerdict.BLOCKED
    return SafetyReport(verdict=verdict, findings=findings, text=text)


#: Signals that the text is close to a line without crossing it. Used to decide whether
#: to spend a cheap Flash call on adjudication (docs/04-ai-pipeline.md stage 7.3).
_AMBIGUITY_PATTERNS: tuple[str, ...] = (
    r"\b(?:dose|dosage|dosing|how\s+much\s+to\s+take)\b",
    r"\bsupplement(?:s|ation)?\b",
    r"\b(?:medicine|medication|tablet|tablets|capsule|capsules|pill|pills|prescription|prescribed)\b",
    r"\byou\s+(?:have|are|'re|'ve)\b",
    r"\b(?:diagnos\w+)\b",
    r"\b(?:stop|skip|pause|reduce|halve)\b",
    r"\b(?:mg|mcg|iu|µg)\b",
    r"\bignore\s+(?:the\s+)?(?:above|previous|earlier|prior)\b",
    r"\bas\s+a\s+doctor\b",
)
AMBIGUITY_RE = re.compile("|".join(f"(?:{p})" for p in _AMBIGUITY_PATTERNS), re.IGNORECASE)


def is_ambiguous(text: str, report: SafetyReport | None = None) -> bool:
    """True when a clean scan still sits close enough to a rule to be worth a judge call.

    Text that already has findings is not ambiguous -- it is decided.
    """
    if report is not None and report.findings:
        return False
    return bool(AMBIGUITY_RE.search(prepare(text)[0]))

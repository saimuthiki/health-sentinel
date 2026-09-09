"""Stage 5 -- red-flag symptoms in free text.

**No language model is involved anywhere in this file.** That is the point: a keyword
and rule classifier cannot be talked out of raising an alarm, cannot be jailbroken by a
user insisting they are fine, and behaves identically on every run. The model may write
the friendly paragraph afterwards; it does not get a vote on whether the escalation card
appears.

Design rules, in priority order:

1. **Conservative.** A false alarm costs a user thirty seconds of reassurance. A miss can
   cost a life. Where the two trade off, we fire.
2. **Robust, not naive.** Text is unicode-normalised, de-punctuated and tokenised;
   patterns match with stop-word skipping and a bounded fuzzy tolerance, so "chest pian",
   "breathlesness" and "pain in the chest" all match. A plain ``in`` substring check
   would miss all three and would also fire on "no chest pain".
3. **Negation guard.** Clause-local negation cues ("no", "denies", "without", "nahi")
   before a match suppress it -- but only when the cue is *outside* the matched phrase,
   so "I dont want to live" still fires.
"""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass, field
from difflib import SequenceMatcher

from app.domain.enums import Escalation
from app.domain.models import RedFlag

__all__ = [
    "SYMPTOM_RULES",
    "SymptomMatch",
    "SymptomRule",
    "detect_matches",
    "evaluate_text",
    "normalise_text",
]


# ------------------------------------------------------------------------- text prep

_APOSTROPHES = ("'", "’", "ʼ", "`")
_NON_WORD = re.compile(r"[^a-z0-9]+")
_WS = re.compile(r"\s+")

#: Words that carry no meaning for matching and that people drop in and out of
#: sentences. Removed from both the text and the patterns so "pain in the chest" and
#: "pain in chest" are the same thing. Negation cues are deliberately NOT in here.
STOPWORDS: frozenset[str] = frozenset(
    {
        "the", "a", "an", "my", "mine", "his", "her", "their", "our", "some", "of",
        "is", "am", "are", "was", "were", "be", "been", "being", "has", "have", "had",
        "i", "im", "ive", "id", "we", "he", "she", "they", "it", "its", "this", "that",
        "there", "here", "get", "getting", "got", "feel", "feeling", "felt", "feels",
        "having", "been", "also", "just", "really", "very", "so", "too", "much",
        "since", "from", "for", "at", "on", "in", "and", "or", "as", "by", "with",
        "me", "myself", "you", "your", "sir", "madam", "doctor", "hi", "hello",
    }
)

#: Cues that turn a statement into its opposite. Checked only inside the same clause.
NEGATION_CUES: frozenset[str] = frozenset(
    {
        "no", "not", "nope", "none", "never", "neither", "nor", "without",
        "dont", "doesnt", "didnt", "cant", "cannot", "couldnt", "wont", "wouldnt",
        "isnt", "arent", "wasnt", "werent", "havent", "hasnt", "hadnt", "aint",
        "denies", "denied", "deny", "negative", "nil", "absent", "free",
        "ruled", "excluded", "apart", "besides", "except",
    }
)

#: Negation that comes *after* the phrase: Hindi/Urdu word order, and the clinical
#: shorthand a user may copy out of a discharge summary ("chest pain ruled out").
TRAILING_NEGATION_CUES: frozenset[str] = frozenset(
    {"nahi", "nahin", "nai", "nay", "ruled", "excluded", "negative", "absent"}
)

#: How far back a negation cue may sit and still be believed.
NEGATION_LOOKBACK = 4
TRAILING_NEGATION_LOOKAHEAD = 3

#: Clause separators. Negation does not cross them: "no fever but chest pain" fires.
_CLAUSE_SPLIT = re.compile(
    r"[.;!?\n\r,]|\bbut\b|\bhowever\b|\bthough\b|\balthough\b|\bwhereas\b|\byet\b",
    re.IGNORECASE,
)

#: Fuzzy tolerance for misspellings. Deliberately tight -- loose fuzzy matching on short
#: words produces nonsense matches, and every match here has real-world consequences.
FUZZY_RATIO = 0.86
FUZZY_MIN_LEN = 5


def normalise_text(text: str) -> str:
    """Lower-case, strip accents and punctuation, collapse whitespace."""
    folded = unicodedata.normalize("NFKD", text)
    folded = "".join(ch for ch in folded if not unicodedata.combining(ch))
    for mark in _APOSTROPHES:
        folded = folded.replace(mark, "")
    folded = _NON_WORD.sub(" ", folded.lower())
    return _WS.sub(" ", folded).strip()


def _tokens(text: str) -> list[str]:
    return [tok for tok in normalise_text(text).split() if tok and tok not in STOPWORDS]


def clauses(text: str) -> list[str]:
    """Split raw text into clauses before punctuation is thrown away."""
    parts = [part.strip() for part in _CLAUSE_SPLIT.split(text)]
    return [part for part in parts if part]


def _is_adjacent_transposition(left: str, right: str) -> bool:
    """"pain" vs "pian" -- the single commonest typing slip, which a similarity ratio
    on four-letter words does not catch."""
    if len(left) != len(right) or len(left) < 4:
        return False
    diff = [index for index, (a, b) in enumerate(zip(left, right)) if a != b]
    if len(diff) != 2:
        return False
    first, second = diff
    return (
        second == first + 1
        and left[first] == right[second]
        and left[second] == right[first]
    )


def _token_match(pattern_token: str, text_token: str) -> bool:
    if pattern_token == text_token:
        return True
    if _is_adjacent_transposition(pattern_token, text_token):
        return True
    if len(pattern_token) >= 4 and text_token.startswith(pattern_token):
        return True
    if len(text_token) >= 4 and pattern_token.startswith(text_token):
        return True
    if len(pattern_token) >= FUZZY_MIN_LEN and len(text_token) >= FUZZY_MIN_LEN:
        if abs(len(pattern_token) - len(text_token)) <= 3:
            ratio = SequenceMatcher(None, pattern_token, text_token).ratio()
            return ratio >= FUZZY_RATIO
    return False


# --------------------------------------------------------------------------- patterns


@dataclass(frozen=True)
class SymptomRule:
    """One red-flag symptom and the phrases that mean it."""

    code: str
    label: str
    escalation: Escalation
    phrases: tuple[str, ...]
    advice: str
    source_citation: str
    tokenised: tuple[tuple[str, ...], ...] = field(default_factory=tuple, compare=False)

    def __post_init__(self) -> None:
        object.__setattr__(
            self,
            "tokenised",
            tuple(tuple(_tokens(phrase)) for phrase in self.phrases),
        )


@dataclass(frozen=True)
class SymptomMatch:
    """Where and why a rule fired -- kept for the audit trail and for tests."""

    rule: SymptomRule
    phrase: str
    clause: str


_EMERGENCY = (
    "This can be an emergency. Please get medical help now -- go to the nearest "
    "emergency department or call your local emergency number (112 in India)."
)

SOURCE_STROKE = (
    "Powers WJ et al. Guidelines for the Early Management of Patients With Acute "
    "Ischemic Stroke: 2019 Update. Stroke 2019;50(12):e344-e418 -- sudden one-sided "
    "weakness, facial droop and speech difficulty are the recognised warning signs "
    "(FAST)."
)
SOURCE_CHEST_PAIN = (
    "Gulati M et al. 2021 AHA/ACC Guideline for the Evaluation and Diagnosis of Chest "
    "Pain. Circulation 2021;144(22):e368-e454 -- acute chest pain requires immediate "
    "assessment."
)
SOURCE_GI_BLEED = (
    "Barkun AN et al. Management of Nonvariceal Upper Gastrointestinal Bleeding: "
    "Guideline Recommendations. Ann Intern Med 2019;171(11):805-822 -- haematemesis "
    "and melaena require urgent assessment."
)
SOURCE_TRIAGE = (
    "Symptom set specified in docs/04-ai-pipeline.md stage 5. Phrase list assembled by "
    "the HealthPulse team, including common Indian-English wording; pending clinician "
    "review (see GAPS.md item G7)."
)
SOURCE_SELF_HARM = (
    "WHO. Preventing suicide: a resource for media professionals (2017) and the "
    "national Tele-MANAS mental health helpline. Any expression of self-harm is "
    "escalated without exception (see GAPS.md item G8 for helpline verification)."
)

SYMPTOM_RULES: tuple[SymptomRule, ...] = (
    SymptomRule(
        code="SYMPTOM_CHEST_PAIN",
        label="chest pain",
        escalation=Escalation.URGENT,
        phrases=(
            "chest pain", "pain in chest", "chest paining", "chest hurts",
            "chest is hurting", "chest heaviness", "heaviness in chest",
            "chest tightness", "tightness in chest", "chest tight",
            "chest pressure", "pressure in chest", "chest discomfort",
            "chest burning", "burning in chest", "squeezing in chest",
            "pain in the left side of chest", "left chest pain",
            "chest pain radiating to arm", "pain going to left arm",
            "seene me dard", "seene mein dard", "chaati me dard", "chati me dard",
            "chest me dard", "chest pain with sweating",
        ),
        advice=_EMERGENCY,
        source_citation=SOURCE_CHEST_PAIN,
    ),
    SymptomRule(
        code="SYMPTOM_BREATHLESSNESS",
        label="sudden breathlessness",
        escalation=Escalation.URGENT,
        phrases=(
            "breathless", "breathlessness", "short of breath", "shortness of breath",
            "difficulty breathing", "difficulty in breathing", "trouble breathing",
            "hard to breathe", "not able to breathe", "unable to breathe",
            "cannot breathe", "cant breathe", "gasping for air", "gasping",
            "suffocating", "suffocation", "choking feeling", "air hunger",
            "saans phool rahi", "saans phoolna", "saans lene me takleef",
            "dum ghut raha", "breathing problem", "breathing difficulty",
        ),
        advice=_EMERGENCY,
        source_citation=SOURCE_TRIAGE,
    ),
    SymptomRule(
        code="SYMPTOM_VISION_LOSS",
        label="sudden vision loss",
        escalation=Escalation.URGENT,
        phrases=(
            "vision loss", "loss of vision", "lost vision", "lost my sight",
            "cannot see", "cant see", "unable to see", "went blind", "gone blind",
            "sudden blindness", "blindness", "vision gone", "eyesight gone",
            "black spot covering vision", "curtain over eye", "curtain in front of eye",
            "sudden blurring of vision", "suddenly blurred vision",
            "dikhna band ho gaya", "aankh se dikhai nahi de raha",
        ),
        advice=_EMERGENCY,
        source_citation=SOURCE_TRIAGE,
    ),
    SymptomRule(
        code="SYMPTOM_ONE_SIDED_WEAKNESS",
        label="one-sided weakness or facial droop",
        escalation=Escalation.URGENT,
        phrases=(
            "one side weakness", "weakness on one side", "weakness in one side",
            "left side weakness", "right side weakness", "left side is weak",
            "right side is weak", "left arm weakness", "right arm weakness",
            "half body weakness", "half body numb", "one side of body numb",
            "face droop", "facial droop", "face drooping", "mouth deviated",
            "mouth is twisted", "face is twisted", "one side of face",
            "slurred speech", "speech slurred", "cannot speak properly",
            "words not coming out", "unable to lift arm", "cannot lift my arm",
            "cannot move my leg", "unable to move one side",
            "aadha sharir", "haath uth nahi raha", "muh tedha",
        ),
        advice=_EMERGENCY,
        source_citation=SOURCE_STROKE,
    ),
    SymptomRule(
        code="SYMPTOM_GI_BLEED",
        label="blood in vomit or stool",
        escalation=Escalation.URGENT,
        phrases=(
            "blood in vomit", "vomiting blood", "vomited blood", "throwing up blood",
            "haematemesis", "hematemesis", "coffee ground vomit",
            "blood in stool", "blood in stools", "blood in motion",
            "blood in motions", "blood while passing motion", "blood in my poop",
            "bleeding from back passage", "bleeding per rectum", "rectal bleeding",
            "black stool", "black stools", "black tarry stool", "tarry stools",
            "melena", "melaena", "fresh blood in stool", "khoon aa raha hai",
            "ulti me khoon", "latrine me khoon",
        ),
        advice=_EMERGENCY,
        source_citation=SOURCE_GI_BLEED,
    ),
    SymptomRule(
        code="SYMPTOM_FAINTING",
        label="fainting or loss of consciousness",
        escalation=Escalation.URGENT,
        phrases=(
            "fainted", "fainting", "faint", "passed out", "blacked out",
            "black out", "syncope", "loss of consciousness", "lost consciousness",
            "became unconscious", "unconscious", "collapsed", "fell down suddenly",
            "chakkar aakar gir gaya", "behosh",
        ),
        advice=_EMERGENCY,
        source_citation=SOURCE_TRIAGE,
    ),
    SymptomRule(
        code="SYMPTOM_SEVERE_ABDOMINAL_PAIN",
        label="severe abdominal pain",
        escalation=Escalation.URGENT,
        phrases=(
            "severe abdominal pain", "severe stomach pain", "severe pain in abdomen",
            "severe pain in stomach", "severe tummy pain", "severe belly pain",
            "unbearable stomach pain", "unbearable abdominal pain",
            "excruciating abdominal pain", "excruciating stomach pain",
            "worst stomach pain", "terrible stomach pain", "intense abdominal pain",
            "intense stomach pain", "acute abdominal pain", "sudden severe stomach pain",
            "stomach pain unbearable", "cannot stand the stomach pain",
            "pet me tez dard", "pet dard bahut", "pet me bahut dard",
            "rigid abdomen", "abdomen is rigid",
        ),
        advice=_EMERGENCY,
        source_citation=SOURCE_TRIAGE,
    ),
    SymptomRule(
        code="SYMPTOM_SELF_HARM",
        label="thoughts of self-harm",
        escalation=Escalation.URGENT,
        phrases=(
            "kill myself", "killing myself", "end my life", "ending my life",
            "take my own life", "suicide", "suicidal", "suicidal thoughts",
            "self harm", "harm myself", "hurt myself", "cut myself",
            "want to die", "wish i was dead", "better off dead", "end it all",
            "dont want to live", "no longer want to live", "no reason to live",
            "nothing to live for", "tired of living", "cant go on living",
            "marna chahta hoon", "jeena nahi chahta", "khudkushi",
        ),
        advice=(
            "You matter, and you do not have to deal with this alone. Please talk to "
            "someone right now -- a person you trust, or the free Tele-MANAS mental "
            "health helpline on 14416 (India), or your local emergency number. If you "
            "are in immediate danger, please go to the nearest emergency department."
        ),
        source_citation=SOURCE_SELF_HARM,
    ),
)

SYMPTOM_RULES_BY_CODE: dict[str, SymptomRule] = {
    rule.code: rule for rule in SYMPTOM_RULES
}


# -------------------------------------------------------------------------- detection


def _find_phrase(
    text_tokens: list[str], phrase_tokens: tuple[str, ...]
) -> int | None:
    """Index of the first window in ``text_tokens`` matching ``phrase_tokens``."""
    span = len(phrase_tokens)
    if span == 0 or span > len(text_tokens):
        return None
    for start in range(len(text_tokens) - span + 1):
        if all(
            _token_match(phrase_tokens[offset], text_tokens[start + offset])
            for offset in range(span)
        ):
            return start
    return None


def _is_negated(text_tokens: list[str], start: int, span: int) -> bool:
    lookback = text_tokens[max(0, start - NEGATION_LOOKBACK) : start]
    if any(token in NEGATION_CUES for token in lookback):
        return True
    end = start + span
    lookahead = text_tokens[end : end + TRAILING_NEGATION_LOOKAHEAD]
    return any(token in TRAILING_NEGATION_CUES for token in lookahead)


def detect_matches(text: str) -> list[SymptomMatch]:
    """Every red-flag symptom found in ``text``, clause by clause."""
    matches: list[SymptomMatch] = []
    seen: set[str] = set()
    for clause in clauses(text):
        tokens = _tokens(clause)
        if not tokens:
            continue
        for rule in SYMPTOM_RULES:
            if rule.code in seen:
                continue
            for phrase, phrase_tokens in zip(rule.phrases, rule.tokenised):
                if not phrase_tokens:
                    continue
                start = _find_phrase(tokens, phrase_tokens)
                if start is None:
                    continue
                if _is_negated(tokens, start, len(phrase_tokens)):
                    continue
                matches.append(SymptomMatch(rule=rule, phrase=phrase, clause=clause))
                seen.add(rule.code)
                break
    return matches


def evaluate_text(text: str) -> list[RedFlag]:
    """Red flags for a free-text message. Order follows :data:`SYMPTOM_RULES`."""
    flags = [
        RedFlag(
            code=match.rule.code,
            escalation=match.rule.escalation,
            message=(
                f"You mentioned {match.rule.label}. {match.rule.advice} "
                "We are a coaching app and cannot assess this -- a person can."
            ),
            symptom=match.rule.label,
        )
        for match in detect_matches(text)
    ]
    order = {rule.code: index for index, rule in enumerate(SYMPTOM_RULES)}
    flags.sort(key=lambda flag: order.get(flag.code, 999))
    return flags

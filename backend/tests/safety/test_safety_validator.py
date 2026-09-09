"""Table-driven tests for the deterministic validator.

Each case is (label, text, escalation, expected violations). ``frozenset()`` means the text
must pass untouched -- a false positive here is as much a bug as a miss, because a validator
that fires on ordinary food advice gets switched off.
"""

from __future__ import annotations

import pytest

from app.domain.enums import Escalation, SafetyVerdict, SafetyViolation
from app.safety import copy as safety_copy
from app.safety.drugs import NEVER_FLAG
from app.safety.validator import DRUG_RE, is_ambiguous, validate

MED = SafetyViolation.MEDICATION_NAMED
DOSE = SafetyViolation.DOSAGE_GIVEN
DIAG = SafetyViolation.DIAGNOSIS_STATED
TREAT = SafetyViolation.TREATMENT_DISCOURAGED
DOWN = SafetyViolation.RED_FLAG_DOWNPLAYED

R = Escalation.ROUTINE
S = Escalation.SEE_DOCTOR_SOON
U = Escalation.URGENT

CASES: list[tuple[str, str, Escalation, frozenset[SafetyViolation]]] = [
    # ---------------------------------------------------------- 1. medication named
    ("generic drug", "Metformin is what doctors usually start with here.", R, frozenset({MED})),
    ("indian brand", "You could ask about Thyronorm at your next visit.", R, frozenset({MED})),
    ("brand lowercase", "eltroxin is taken on an empty stomach.", R, frozenset({MED})),
    ("statin", "Try atorvastatin for your cholesterol.", R, frozenset({MED})),
    ("two drugs", "Telmisartan and amlodipine are common for blood pressure.", R, frozenset({MED})),
    ("uppercase and bang", "PANTOPRAZOLE!", R, frozenset({MED})),
    ("bracketed", "Your strip says (azithromycin), which is an antibiotic.", R, frozenset({MED})),
    ("plural class", "Statins are prescribed for this pattern.", R, frozenset({MED})),
    ("possessive", "Your metformin's timing is a question for your doctor.", R, frozenset({MED})),
    ("hyphenated brand", "The Pan-D strip in your photo is a stomach medicine.", R, frozenset({MED})),
    ("supplement brand", "Shelcal is a calcium brand.", R, frozenset({MED})),
    ("pharma form of a nutrient", "Cholecalciferol sachets are a pharmacy product.", R, frozenset({MED})),
    # ------------------------------------ 1b. nutrients and foods must NOT be drugs
    ("nutrient iron", "Iron-rich foods like ragi, spinach and dates will help.", R, frozenset()),
    ("nutrient calcium", "Calcium and vitamin B12 come mostly from dairy and eggs.", R, frozenset()),
    ("nutrient list", "Zinc, magnesium, folate and fibre are all covered by this plan.", R, frozenset()),
    ("vitamin d coaching", "Your vitamin D is low, so morning sunlight will help.", R, frozenset()),
    # ------------------------------------------------------------- 2. dosage given
    ("charter example", "Take 60,000 IU vitamin D weekly.", R, frozenset({DOSE})),
    ("mg with verb", "You should take 500 mg twice a day.", R, frozenset({DOSE})),
    ("tablets", "Start 2 tablets after dinner.", R, frozenset({DOSE})),
    ("word number capsule", "Have one capsule of the supplement daily.", R, frozenset({DOSE})),
    ("syrup in ml", "Take 5 ml of the syrup twice daily.", R, frozenset({DOSE})),
    ("mcg injection", "You need 1000 mcg of B12 injection every week.", R, frozenset({DOSE})),
    ("sachets", "Take 2 sachets of ORS daily.", R, frozenset({DOSE})),
    ("supplement capsule", "Add a 250 mg turmeric capsule to your morning routine.", R, frozenset({DOSE})),
    ("drops of tonic", "Use 3 drops of the tonic daily.", R, frozenset({DOSE})),
    ("micro sign", "Take 500 µg of folic acid daily.", R, frozenset({DOSE})),
    ("dose plus drug", "Increase your metformin to 1000 mg daily.", R, frozenset({DOSE, MED})),
    ("pharma unit beats food word", "Take 2 tablets of calcium with your milk.", R, frozenset({DOSE})),
    # ------------------------------- 2b. food quantities must NOT be read as doses
    ("grams of food", "Have 100 g of ragi at breakfast.", R, frozenset()),
    ("take plus food grams", "Take 100 g of ragi in the morning.", R, frozenset()),
    ("millilitres of milk", "Drink 250 ml of milk with it.", R, frozenset()),
    ("litres of water", "Aim for 2 litres of water a day.", R, frozenset()),
    ("serving of nuts", "A 30 g serving of almonds gives you healthy fats.", R, frozenset()),
    ("teaspoon of ghee", "Add 1 tsp of ghee to your dal.", R, frozenset()),
    ("counts of food", "Eat 2 idlis and 150 g of vegetables at lunch.", R, frozenset()),
    ("cup of curd", "Have one cup of curd after lunch.", R, frozenset()),
    ("lab value not a dose", "Your report says haemoglobin is 11.2 g/dL.", R, frozenset()),
    ("lab value in mg/dL", "Fasting glucose was 110 mg/dL and TSH 6.5 mIU/L.", R, frozenset()),
    ("portion guidance", "Try to keep dinner around 300 g of cooked food.", R, frozenset()),
    ("drops of lemon", "Add 2 drops of lemon juice over the dal.", R, frozenset()),
    # --------------------------------------------------------- 3. diagnosis stated
    ("you have condition", "You have diabetes.", R, frozenset({DIAG})),
    ("you are diabetic", "You are diabetic and should eat differently.", R, frozenset({DIAG})),
    ("this confirms", "This confirms hypothyroidism.", R, frozenset({DIAG})),
    ("suffering from", "You are suffering from anaemia.", R, frozenset({DIAG})),
    ("contraction", "You've got PCOS, going by these numbers.", R, frozenset({DIAG})),
    ("diagnosed", "You have been diagnosed with fatty liver.", R, frozenset({DIAG})),
    ("charter safe phrasing",
     "This HbA1c pattern is one doctors look at for diabetes; please get it confirmed.", R, frozenset()),
    ("plain explanation",
     "Your HbA1c is above the reference range, which is worth discussing with a doctor.", R, frozenset()),
    # --------------------------------------------------- 4. treatment discouraged
    ("stop taking", "Stop taking your tablets for a week and see how you feel.", R, frozenset({TREAT})),
    ("dont need", "You don't need your thyroid medicine any more.", R, frozenset({TREAT})),
    ("skip", "Skip your medication tonight and eat this instead.", R, frozenset({TREAT})),
    ("you can stop", "You can stop the metformin now that food is sorted.", R, frozenset({TREAT, MED})),
    ("halve the dose", "Reduce your dose to half now that your numbers look better.", R, frozenset({TREAT})),
    ("no need for doctor", "There's no need to see a doctor about this.", R, frozenset({TREAT})),
    ("supportive of treatment", "Keep taking everything your doctor prescribed.", R, frozenset()),
    ("continue treatment", "Please continue your treatment exactly as prescribed.", R, frozenset()),
    # -------------------------------------------------- 5. red flag downplayed
    ("nothing to worry urgent", "Nothing to worry about here.", U, frozenset({DOWN})),
    ("this is normal urgent", "This is completely normal at your age.", U, frozenset({DOWN})),
    ("wait and watch urgent", "Let us wait and watch for a few days.", U, frozenset({DOWN})),
    ("youll be fine urgent", "Don't worry, you'll be fine.", U, frozenset({DOWN})),
    ("no need for hospital urgent", "No need to rush to a hospital for this.", U, frozenset({DOWN})),
    ("same words when routine", "Nothing to worry about here.", R, frozenset()),
    ("same words when see soon", "This is completely normal at your age.", S, frozenset()),
    ("urgent handled properly",
     "Please go to the nearest emergency department now and take your report with you.", U, frozenset()),
    # ------------------------------------------------------------ clean coaching
    ("charter coaching example",
     "Your vitamin D is low. Sunlight in the morning and these foods help. Ask your doctor "
     "whether you need a supplement and at what dose.", R, frozenset()),
    ("meal plan text",
     "Breakfast: 2 idlis with sambar and a bowl of curd. Lunch: ragi mudde with dal and greens.",
     R, frozenset()),
    ("absorption tip", "Iron from spinach is absorbed better with a squeeze of lemon.", R, frozenset()),
    ("habits", "Aim for 7 hours of sleep and a 30 minute walk after dinner.", R, frozenset()),
    ("questions for the doctor",
     "Worth asking your doctor: should this be retested in three months, and does the low "
     "ferritin need looking into?", R, frozenset()),
    ("empty text", "", R, frozenset()),
    # ------------------------------------- 6. evasion: invisible and lookalike chars
    ("zero width inside a drug name", "met\u200bformin is the usual first choice.", R, frozenset({MED})),
    ("soft hyphen inside a drug name", "Ask about met\u00adformin at your visit.", R, frozenset({MED})),
    ("non-breaking space before unit", "Take 500\u00a0mg every morning.", R, frozenset({DOSE})),
    ("greek mu instead of micro sign", "Take 500\u03bcg of folic acid daily.", R, frozenset({DOSE})),
    ("curly apostrophe downplay", "Don\u2019t worry, it\u2019s totally fine.", U, frozenset({DOWN})),
    # ------------------------------------------------ 7. phrasings added after review
    ("this is a diagnosis", "This is diabetes.", R, frozenset({DIAG})),
    ("diabetes-friendly is not a diagnosis",
     "These are diabetes-friendly meals for the week.", R, frozenset()),
    ("dose without an imperative", "The standard adult amount is 500 mg.", R, frozenset({DOSE})),
    # ------------------------------------------------------------ multi-violation
    ("everything at once",
     "You have diabetes, so stop taking your tablets and take 500 mg of metformin instead. "
     "Nothing to worry about.", U, frozenset({DIAG, TREAT, DOSE, MED, DOWN})),
]


@pytest.mark.parametrize(
    ("label", "text", "escalation", "expected"),
    CASES,
    ids=[case[0] for case in CASES],
)
def test_validator_table(
    label: str, text: str, escalation: Escalation, expected: frozenset[SafetyViolation]
) -> None:
    report = validate(text, escalation)
    got = {finding.violation for finding in report.findings}
    assert got == set(expected), f"{label}: {sorted(v.value for v in got)}"
    assert report.verdict is (SafetyVerdict.PASS if not expected else SafetyVerdict.BLOCKED)


def test_the_table_is_big_enough_and_covers_every_rule() -> None:
    assert len(CASES) >= 40
    covered = {violation for _, _, _, expected in CASES for violation in expected}
    assert covered == set(SafetyViolation)
    assert sum(1 for case in CASES if not case[3]) >= 15  # plenty of must-pass text


@pytest.mark.parametrize(
    ("label", "text", "escalation", "expected"),
    CASES,
    ids=[case[0] for case in CASES],
)
def test_spans_are_exact(
    label: str, text: str, escalation: Escalation, expected: frozenset[SafetyViolation]
) -> None:
    """The API strips or highlights by span, so span and excerpt must agree exactly."""
    for finding in validate(text, escalation).findings:
        start, end = finding.span
        assert 0 <= start < end <= len(text)
        assert text[start:end] == finding.excerpt


@pytest.mark.parametrize("word", sorted(NEVER_FLAG))
def test_food_and_nutrient_words_are_never_medications(word: str) -> None:
    assert DRUG_RE.search(word) is None, f"{word!r} must never be flagged as a medication"
    assert not validate(f"Add some {word} to your day.").findings


def test_findings_are_ordered_by_position() -> None:
    text = "Stop taking your tablets. You have diabetes. Take 500 mg of metformin."
    spans = [finding.span[0] for finding in validate(text).findings]
    assert spans == sorted(spans)


def test_ambiguity_flag_is_only_for_clean_text_that_sits_near_a_line() -> None:
    assert is_ambiguous("Ask your doctor about the dose of any supplement.") is True
    assert is_ambiguous("Breakfast is two idlis with sambar.") is False
    blocked = validate("Take 500 mg daily.")
    assert is_ambiguous(blocked.text, blocked) is False  # already decided, not ambiguous


def test_the_safety_copy_itself_passes_the_validator() -> None:
    """The disclaimer and escalation cards must never trip our own scan."""
    for name, text in (
        ("disclaimer", safety_copy.DISCLAIMER),
        ("blocked", safety_copy.BLOCKED_FALLBACK),
        ("blocked urgent", safety_copy.BLOCKED_FALLBACK_URGENT),
        *((f"card {level.value}", card) for level, card in safety_copy.ESCALATION_CARDS.items()),
    ):
        report = validate(text, Escalation.URGENT)
        assert not report.findings, f"{name} trips the validator: {report.findings}"


def test_prepare_keeps_span_offsets_in_the_original_text() -> None:
    from app.safety.validator import prepare

    original = "met\u200bformin"
    clean, offsets = prepare(original)
    assert clean == "metformin"
    assert offsets[0] == 0
    assert offsets[3] == 4  # the character after the zero-width space
    finding = validate(original).findings[0]
    assert original[finding.span[0] : finding.span[1]] == finding.excerpt

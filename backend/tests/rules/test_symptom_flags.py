"""Stage 5: red-flag symptoms in free text.

Two properties, and they pull in opposite directions:

* **recall** -- misspelt, colloquial and Hinglish phrasings must still fire;
* **the negation guard** -- "no chest pain" must not.

Where they conflict, recall wins. Every test below is written from that position.
"""

from __future__ import annotations

import pytest

from app.domain.enums import Escalation
from app.rules import symptom_flags as SF


def codes(text: str) -> set[str]:
    return {flag.code for flag in SF.evaluate_text(text)}


# ------------------------------------------------------------------- every category


@pytest.mark.parametrize(
    ("text", "code"),
    [
        ("I have been having chest pain since yesterday", "SYMPTOM_CHEST_PAIN"),
        ("there is a heaviness in my chest", "SYMPTOM_CHEST_PAIN"),
        ("seene me dard ho raha hai", "SYMPTOM_CHEST_PAIN"),
        ("suddenly I became breathless while walking", "SYMPTOM_BREATHLESSNESS"),
        ("shortness of breath at night", "SYMPTOM_BREATHLESSNESS"),
        ("saans phool rahi hai", "SYMPTOM_BREATHLESSNESS"),
        ("I lost vision in my right eye this morning", "SYMPTOM_VISION_LOSS"),
        ("sudden blurring of vision", "SYMPTOM_VISION_LOSS"),
        ("my left side weakness started an hour back", "SYMPTOM_ONE_SIDED_WEAKNESS"),
        ("her face is drooping on one side", "SYMPTOM_ONE_SIDED_WEAKNESS"),
        ("my speech is slurred", "SYMPTOM_ONE_SIDED_WEAKNESS"),
        ("I saw blood in vomit today", "SYMPTOM_GI_BLEED"),
        ("passing black tarry stools", "SYMPTOM_GI_BLEED"),
        ("blood in motion since two days", "SYMPTOM_GI_BLEED"),
        ("I fainted in the bathroom", "SYMPTOM_FAINTING"),
        ("he passed out for a minute", "SYMPTOM_FAINTING"),
        ("severe abdominal pain since midnight", "SYMPTOM_SEVERE_ABDOMINAL_PAIN"),
        ("unbearable stomach pain", "SYMPTOM_SEVERE_ABDOMINAL_PAIN"),
        ("I want to kill myself", "SYMPTOM_SELF_HARM"),
        ("I dont want to live anymore", "SYMPTOM_SELF_HARM"),
        ("having suicidal thoughts", "SYMPTOM_SELF_HARM"),
    ],
)
def test_each_red_flag_symptom_is_detected(text: str, code: str) -> None:
    assert code in codes(text)


def test_every_rule_is_urgent_and_carries_a_citation() -> None:
    for rule in SF.SYMPTOM_RULES:
        assert rule.escalation is Escalation.URGENT, rule.code
        assert rule.source_citation.strip(), rule.code
        assert rule.phrases, rule.code


def test_flag_carries_the_symptom_label_and_tells_the_user_what_to_do() -> None:
    flag = SF.evaluate_text("crushing chest pain")[0]
    assert flag.symptom == "chest pain"
    assert "emergency" in flag.message.lower()
    assert flag.biomarker_code is None


def test_self_harm_message_offers_a_helpline_rather_than_advice() -> None:
    message = SF.evaluate_text("I want to end my life")[0].message
    assert "14416" in message
    assert "not alone" in message or "do not have to deal with this alone" in message


# ------------------------------------------------------------------- negation guard


@pytest.mark.parametrize(
    "text",
    [
        "no chest pain",
        "No chest pain.",
        "I have no chest pain at all",
        "I don't have chest pain",
        "patient denies chest pain",
        "there is no history of chest pain",
        "chest pain nahi hai",
        "not having any chest pain",
        "never had chest pain",
        "chest pain has been ruled out",
    ],
)
def test_negated_chest_pain_does_not_fire(text: str) -> None:
    assert "SYMPTOM_CHEST_PAIN" not in codes(text)


def test_negation_does_not_cross_a_clause_boundary() -> None:
    got = codes("no fever, but severe chest pain since morning")
    assert "SYMPTOM_CHEST_PAIN" in got


def test_negating_one_symptom_does_not_silence_another() -> None:
    got = codes("no chest pain but I am breathless")
    assert "SYMPTOM_CHEST_PAIN" not in got
    assert "SYMPTOM_BREATHLESSNESS" in got


def test_negation_guard_does_not_silence_a_phrase_that_contains_the_negation() -> None:
    # The cue "dont" is part of the phrase itself, not a denial of it.
    assert "SYMPTOM_SELF_HARM" in codes("I dont want to live")
    assert "SYMPTOM_BREATHLESSNESS" in codes("I am not able to breathe properly")
    assert "SYMPTOM_VISION_LOSS" in codes("I cannot see from my left eye")


def test_asking_about_self_harm_in_the_negative_does_not_fire() -> None:
    assert "SYMPTOM_SELF_HARM" not in codes("no thoughts of self harm")


# ------------------------------------------------------------ robustness of matching


@pytest.mark.parametrize(
    "text",
    [
        "chest pian since morning",        # transposed letters
        "chest  PAIN",                     # spacing and case
        "chest-pain since morning",        # punctuation
        "pain in the chest",               # word order and filler words
        "my chest is paining a lot",       # Indian English
        "chest paining",
    ],
)
def test_messy_wording_still_fires(text: str) -> None:
    assert "SYMPTOM_CHEST_PAIN" in codes(text)


def test_misspelt_breathlessness_still_fires() -> None:
    assert "SYMPTOM_BREATHLESSNESS" in codes("severe breathlesness since evening")


def test_a_naive_substring_check_would_have_been_wrong_both_ways() -> None:
    # Substring matching fires on "no chest pain" and misses "pain in the chest".
    assert "SYMPTOM_CHEST_PAIN" not in codes("no chest pain")
    assert "SYMPTOM_CHEST_PAIN" in codes("pain in the chest")


def test_several_symptoms_in_one_message_all_come_back() -> None:
    got = codes("I had chest pain and then I fainted, also vomiting blood")
    assert {"SYMPTOM_CHEST_PAIN", "SYMPTOM_FAINTING", "SYMPTOM_GI_BLEED"} <= got


def test_each_symptom_is_reported_once_however_often_it_is_mentioned() -> None:
    flags = SF.evaluate_text("chest pain. chest pain again. chest heaviness too.")
    assert len(flags) == 1


def test_ordinary_chat_raises_nothing() -> None:
    benign = [
        "I had dosa for breakfast and felt full",
        "my weight is stuck at 74 kg",
        "can you plan my dinner today",
        "I walked 6000 steps and my legs ache a bit",
        "the report says my vitamin D is 14.2",
        "I get a mild headache in the afternoon sometimes",
    ]
    for text in benign:
        assert codes(text) == set(), text


def test_empty_and_punctuation_only_text_is_safe() -> None:
    assert SF.evaluate_text("") == []
    assert SF.evaluate_text("... ,,, !!!") == []


def test_normalise_text_strips_punctuation_and_accents() -> None:
    assert SF.normalise_text("Chest-Pain!!  (severe)") == "chest pain severe"


def test_detect_matches_says_which_phrase_matched() -> None:
    matches = SF.detect_matches("severe chest pain since morning")
    assert matches[0].rule.code == "SYMPTOM_CHEST_PAIN"
    assert matches[0].phrase in matches[0].rule.phrases

"""The rails on a weekly summary's one paragraph.

The safety validator already refuses drugs, doses and diagnoses. These tests are about the
sentences that pass all of that and are still not true: an invented trend, an invented
cause, a promise about somebody's body, or a number nobody computed.
"""

from __future__ import annotations

import pytest

from app.rules import summary_prose_rails as rails

GOOD = (
    "You showed up for your plan on several days this week, and you logged your walks as "
    "you went. That steadiness is the hard part, and you did it."
)


def rules_for(text: str) -> set[str]:
    return {finding.rule for finding in rails.check_encouragement(text)}


def test_a_plain_encouraging_sentence_passes():
    assert rails.check_encouragement(GOOD) == []


@pytest.mark.parametrize(
    "text",
    [
        "You marked 12 meals as eaten this week.",
        "You moved on 3 days.",
        "Nine out of 10 -- a strong week.",
    ],
)
def test_a_digit_is_refused_however_true_it_looks(text: str):
    """Every number the reader sees is printed by the app from its own counts. A model
    that writes no digits cannot restate one of ours wrongly."""
    assert "numeral" in rules_for(text)


@pytest.mark.parametrize(
    "text",
    [
        "You drank more water this week, because you kept the bottle on your desk.",
        "Thanks to your walks, this was a steady week.",
        "You ate well, which is why the week went smoothly.",
        "All that planning led to a calmer week.",
    ],
)
def test_a_cause_is_refused(text: str):
    """We have counts of taps. We do not know why anybody did anything."""
    assert "causal_claim" in rules_for(text)


@pytest.mark.parametrize(
    "text",
    [
        "Keep this up and you will feel the difference soon.",
        "Your energy should improve if you carry on like this.",
        "You are well on your way to a real habit.",
    ],
)
def test_a_prediction_is_refused(text: str):
    assert "prediction" in rules_for(text)


@pytest.mark.parametrize(
    "text",
    [
        "A better week than last week.",
        "That is up from the week before.",
        "You are on a lovely streak.",
        "Compared with your previous week, this one was calmer.",
    ],
)
def test_a_trend_is_refused_because_nothing_here_compares_two_weeks(text: str):
    assert "trend_claim" in rules_for(text)


@pytest.mark.parametrize(
    "text",
    [
        "Your skin will thank you for a week like this.",
        "This is the kind of week that helps your iron along.",
        "Your numbers are moving in a good direction.",
    ],
)
def test_a_claim_about_the_body_is_refused(text: str):
    """The forbidden sentence in the brief, almost word for word: a behaviour credited
    with a clinical outcome."""
    assert rules_for(text)


def test_the_sentence_the_brief_forbids_is_caught_on_more_than_one_rail():
    text = "You drank more this week, so your skin will improve."
    assert {"causal_claim", "prediction", "trend_claim"} & rules_for(text)


def test_an_essay_is_refused():
    assert "too_long" in rules_for("Lovely week. " * 60)


def test_empty_prose_is_a_finding_rather_than_a_pass():
    assert rules_for("") == {"empty"}
    assert rules_for("   ") == {"empty"}


def test_the_feedback_quotes_the_rules_and_asks_for_a_rewrite():
    findings = rails.check_encouragement("You ate 12 meals, up from last week.")
    feedback = rails.feedback_for(findings)
    assert "no digits" in feedback.lower()
    assert "compare" in feedback.lower()
    for finding in findings:
        assert finding.rule in feedback


def test_case_and_spacing_do_not_get_a_sentence_past_a_rail():
    assert "causal_claim" in rules_for("A good week,  BECAUSE   you stuck at it.")
    assert "trend_claim" in rules_for("Better than LAST    WEEK.")


def test_an_ordinary_word_containing_a_banned_one_is_not_a_finding():
    """"trend" must not fire on "trendy", and "up from" must not fire mid-word."""
    assert rails.check_encouragement("You cooked things you actually like.") == []

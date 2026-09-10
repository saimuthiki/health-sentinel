"""What happens when text **this codebase wrote** fails our own safety validator.

Our own copy tripping our own rail is a bug in us. It used to be a 500, which meant one
bad sentence took ``GET /v1/reports/{id}`` down and, because Today reads the latest
report's detail for escalations, the whole day with it.

The answer is not to show the text -- that rail does not bend -- and not to hide the
failure either. It is to withhold that one string, say so where the sentence would have
been, log it as an error, and serve the rest of the report. Three properties, tested
here in the order they beat each other:

1. the text that failed is **never** returned;
2. the failure is **loud** -- an ``error`` log line and an entry in ``WITHHELD``;
3. the response survives -- and the strict primitive still raises for callers who want
   a failure to be a failure.
"""

from __future__ import annotations

import pytest
from structlog.testing import capture_logs

from app.api.guarded import (
    WITHHELD,
    GuardedText,
    guarded_deterministic,
    guarded_many,
    guarded_many_or_withheld,
    guarded_or_withheld,
)
from app.core.errors import UnguardedText
from app.domain.enums import Escalation
from app.safety import copy as safety_copy
from app.safety.validator import validate

SAFE = "Haemoglobin is 11.2 g/dL, below our reference range."
UNSAFE = "Take metformin 500 mg twice daily and stop your thyroid tablets."


@pytest.fixture(autouse=True)
def _clear_withheld():
    WITHHELD.clear()
    yield
    WITHHELD.clear()


# ------------------------------------------------------------------ 1. never shown


def test_the_text_that_failed_is_not_returned_in_any_form() -> None:
    out = guarded_or_withheld(UNSAFE)
    assert out == safety_copy.WITHHELD_DETERMINISTIC
    assert "metformin" not in out.lower()
    assert "500" not in out
    for fragment in ("metformin", "thyroid tablets", "twice daily"):
        assert fragment not in out.lower()


def test_safe_text_comes_back_untouched_and_minted() -> None:
    out = guarded_or_withheld(SAFE)
    assert out == SAFE
    assert isinstance(out, GuardedText)


def test_the_stand_in_is_itself_guarded_text_and_passes_the_validator() -> None:
    """It is shown to a person, so it goes through the same scan as everything else --
    at URGENT, where the downplaying rule is live as well."""
    out = guarded_or_withheld(UNSAFE, Escalation.URGENT)
    assert isinstance(out, GuardedText)
    assert not validate(out, Escalation.URGENT).findings
    assert not validate(safety_copy.WITHHELD_DETERMINISTIC, Escalation.URGENT).findings


def test_the_stand_in_does_not_read_as_an_all_clear() -> None:
    """A withheld explanation is a missing explanation, never a reassurance."""
    text = safety_copy.WITHHELD_DETERMINISTIC.lower()
    for reassurance in ("nothing to worry", "all clear", "normal", "fine", "no need"):
        assert reassurance not in text
    assert "could not show" in text


# ------------------------------------------------------------------ 2. still loud


def test_the_failure_is_logged_as_an_error_with_the_violations() -> None:
    with capture_logs() as entries:
        guarded_or_withheld(UNSAFE)
    assert len(entries) == 1, entries
    entry = entries[0]
    assert entry["event"] == "deterministic text failed the safety validator"
    assert entry["log_level"] == "error"
    assert entry["withheld"] is True
    assert "medication_named" in entry["violations"]
    # The offending sentence is not in the log line either. Only what rule it broke.
    assert "metformin" not in repr(entry).lower()


def test_a_clean_string_logs_nothing() -> None:
    with capture_logs() as entries:
        guarded_or_withheld(SAFE)
    assert entries == []


def test_the_failure_is_recorded_in_process_and_carries_no_health_data() -> None:
    guarded_or_withheld(UNSAFE)
    assert list(WITHHELD) == [
        ("medication_named", "dosage_given", "treatment_discouraged")
    ]
    # Violation codes only. The text is health data; app.core.logging exists to keep it
    # out of anything that outlives the request, and this must not be the way back in.
    for entry in WITHHELD:
        assert all("metformin" not in code for code in entry)


def test_a_clean_string_records_nothing() -> None:
    guarded_or_withheld(SAFE)
    assert list(WITHHELD) == []


# --------------------------------------------------- 3. the strict primitive is intact


def test_guarded_deterministic_still_raises() -> None:
    """The other side of the decision. Where the string *is* the answer, a violation is
    still a failed request -- only per-row explanations degrade."""
    assert guarded_deterministic(SAFE) == SAFE
    with pytest.raises(UnguardedText):
        guarded_deterministic(UNSAFE)
    with pytest.raises(UnguardedText):
        guarded_many([SAFE, UNSAFE])


def test_one_bad_line_in_a_sequence_costs_that_line_and_no_other() -> None:
    out = guarded_many_or_withheld([SAFE, UNSAFE, "Ferritin is 18 ng/mL."])
    assert out[0] == SAFE
    assert out[1] == safety_copy.WITHHELD_DETERMINISTIC
    assert out[2] == "Ferritin is 18 ng/mL."
    assert len(WITHHELD) == 1


def test_the_stand_in_cannot_be_minted_by_hand() -> None:
    """Degrading did not open a second door into GuardedText."""
    with pytest.raises(UnguardedText):
        GuardedText(safety_copy.WITHHELD_DETERMINISTIC)

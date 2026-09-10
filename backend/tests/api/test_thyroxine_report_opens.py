"""The regression test for the report the owner could not open.

`GET /v1/reports/{id}` answered 500 for a real thyroid panel. Our own review copy said
"We do not recognise the unit 'ngdl' printed for Free Thyroxine", our own medication rail
fired on the word "Thyroxine", ``guarded_deterministic`` raised, the exception handler
turned it into ``internal-error``, and Today died with it because
``HttpHealthRepository.loadToday`` reads the latest report's detail for escalations.

Everything here is driven through the real endpoints with the real validator in the
response path. Calling the validator directly is what the unit tests in
``tests/safety/test_dual_use_analytes.py`` do; it is not what would have caught this.
"""

from __future__ import annotations

from app.safety import copy as safety_copy
from tests.api.conftest import consented, request
from tests.api.test_pipeline_flows import PDF, seed_reference, upload

#: A thyroid panel as an Indian lab prints it. Two thyroxine lines on purpose:
#: "Free Thyroxine" maps and is stored as a row, and "Thyroxine (T4)" -- total T4, which
#: our catalogue does not carry a code for -- goes to the review queue, which is what puts
#: the printed name into a sentence **we** wrote and then scan.
THYROID_PANEL = {
    "lab_name": "Vijaya Diagnostic Centre",
    "collected_on": "2026-08-14",
    "report_type": "blood",
    "rows": [
        {"printed_test_name": "Free Thyroxine", "value_text": "1.2",
         "unit_text": "ng/dL", "printed_range": "0.8 - 1.8", "confidence": 0.98},
        {"printed_test_name": "Thyroxine (T4)", "value_text": "8.5",
         "unit_text": "ug/dL", "printed_range": "4.8 - 12.7", "confidence": 0.98},
        {"printed_test_name": "TSH", "value_text": "3.1",
         "unit_text": "uIU/mL", "printed_range": "0.4 - 4.0", "confidence": 0.99},
        {"printed_test_name": "Haemoglobin", "value_text": "13.4",
         "unit_text": "g/dL", "printed_range": "13 - 17", "confidence": 0.99},
    ],
}

#: A prescription strip photographed as if it were a report. The printed "test name" is a
#: drug and a dose, so the review sentence we write about it genuinely fails our own
#: validator -- which is the case Fix 2 is for, and it must not be the dual-use exception.
PRESCRIPTION_MISTAKEN_FOR_A_REPORT = {
    "lab_name": "Apollo Pharmacy",
    "collected_on": "2026-08-14",
    "report_type": "blood",
    "rows": [
        {"printed_test_name": "Haemoglobin", "value_text": "13.4",
         "unit_text": "g/dL", "printed_range": "13 - 17", "confidence": 0.99},
        {"printed_test_name": "Take metformin 500 mg twice daily", "value_text": "1",
         "unit_text": "strip", "confidence": 0.95},
    ],
}


def _detail(client, auth, report_id: str):
    return request(client, "GET", f"/v1/reports/{report_id}", headers=auth)


# ------------------------------------------------------------------------- fix 1


def test_a_report_with_a_thyroxine_row_opens(client, auth, store, gemini) -> None:
    """The bug, end to end. 500 before this change, 200 after it."""
    consented(store)
    seed_reference(store)
    gemini.queue(THYROID_PANEL)

    uploaded = upload(client, auth)
    assert uploaded.status_code == 201, uploaded.text
    report_id = uploaded.json()["report"]["id"]

    response = _detail(client, auth, report_id)
    assert response.status_code == 200, response.text

    body = response.json()
    codes = {row["biomarker_code"]: row for row in body["results"]}
    assert "FT4" in codes, f"the thyroxine row is missing: {sorted(codes)}"
    assert codes["FT4"]["display_name"] == "Free T4"
    assert codes["FT4"]["value"].startswith("1.2")
    # And the rest of the panel came with it.
    assert {"TSH", "HB"} <= set(codes)


def test_the_review_sentence_naming_thyroxine_is_shown_not_withheld(
    client, auth, store, gemini
) -> None:
    """The exact string that used to raise. It is our own copy about a measurement, so
    it must reach the reader intact rather than be swallowed by Fix 2."""
    consented(store)
    seed_reference(store)
    gemini.queue(THYROID_PANEL)
    report_id = upload(client, auth).json()["report"]["id"]

    body = _detail(client, auth, report_id).json()
    reasons = [item["reason"] for item in body["review"]]
    assert any("Thyroxine (T4)" in reason for reason in reasons), reasons
    assert safety_copy.WITHHELD_DETERMINISTIC not in reasons


def test_the_upload_reply_carries_the_thyroxine_row_too(client, auth, store, gemini) -> None:
    """``POST /v1/reports`` builds the same response model from the pipeline's objects,
    and it went through the same guard. One endpoint fixed and the other not would be a
    report you can upload and cannot reopen."""
    consented(store)
    seed_reference(store)
    gemini.queue(THYROID_PANEL)

    body = upload(client, auth).json()
    assert "FT4" in {row["biomarker_code"] for row in body["results"]}
    assert any("Thyroxine (T4)" in item["reason"] for item in body["review"])


# ------------------------------------------------------------------------- fix 2


def test_curated_text_that_really_fails_costs_its_own_row_and_nothing_else(
    client, auth, store, gemini
) -> None:
    """The other side of Fix 2, through the endpoint.

    Here the validator is right: a sentence of ours that says "Take metformin 500 mg"
    must never be shown. The report still opens, the haemoglobin row is still there, and
    the one line that could not be shown says so.
    """
    consented(store)
    seed_reference(store)
    gemini.queue(PRESCRIPTION_MISTAKEN_FOR_A_REPORT)
    report_id = upload(client, auth).json()["report"]["id"]

    response = _detail(client, auth, report_id)
    assert response.status_code == 200, response.text
    body = response.json()

    assert "HB" in {row["biomarker_code"] for row in body["results"]}
    reasons = [item["reason"] for item in body["review"]]
    assert safety_copy.WITHHELD_DETERMINISTIC in reasons, reasons
    # None of our own copy in this response repeats what failed. ``printed_test_name`` is
    # the person's own uploaded line echoed back for them to confirm, not our sentence,
    # and it is not what the medication rail is for.
    assert not any("metformin" in reason.lower() for reason in reasons)


def test_a_report_that_is_all_bad_copy_is_still_a_report(client, auth, store, gemini) -> None:
    """Degrading is per row, so even the worst case is a 200 that shows what it has."""
    consented(store)
    seed_reference(store)
    gemini.queue(
        {
            "lab_name": "Apollo Pharmacy",
            "collected_on": "2026-08-14",
            "rows": [
                {"printed_test_name": "Take metformin 500 mg twice daily",
                 "value_text": "1", "unit_text": "strip", "confidence": 0.95},
                {"printed_test_name": "Start atorvastatin 10 mg at night",
                 "value_text": "1", "unit_text": "strip", "confidence": 0.95},
            ],
        }
    )
    report_id = upload(client, auth, PDF).json()["report"]["id"]

    response = _detail(client, auth, report_id)
    assert response.status_code == 200, response.text
    reasons = [item["reason"] for item in response.json()["review"]]
    assert reasons and set(reasons) == {safety_copy.WITHHELD_DETERMINISTIC}
    assert not any("atorvastatin" in reason.lower() for reason in reasons)

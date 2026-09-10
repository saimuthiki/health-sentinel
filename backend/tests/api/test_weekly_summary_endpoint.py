"""The weekly summary over HTTP.

What is being proved here, in order of how much it matters:

1. **A quiet week is reported as quiet, and costs nothing.** No model is called at all, no
   cheerful sentence is manufactured, and the response says which things were not logged.
2. **The numbers come from our rows and the prose comes from a model, and they are
   different fields.** ``facts`` is arithmetic; ``summary`` is the one guarded string.
3. **A sentence that breaks the summary rails never reaches anybody**, and the reader is
   told they are looking at the counts alone rather than being handed a silent downgrade.
4. **A dish of a week is generated once.** Opening the same week again calls no model.

The router is registered on the fixture app here rather than in ``app/main.py``: the two
lines main.py needs are handed over with this change.
"""

from __future__ import annotations

from datetime import date, timedelta

import pytest

from app.api import summary as summary_api
from app.api.guarded import GuardedText
from tests.api.conftest import consented, request
from tests.conftest import OTHER_USER_ID, USER_ID

TODAY = date.today()
#: The Monday of the last complete week -- what the endpoint answers with by default.
LAST_WEEK_START = TODAY - timedelta(days=TODAY.weekday() + 7)

SAFE_NOTE = (
    "You showed up for your plan on several days this week, and you logged your walks as "
    "you went. That steadiness is the hard part, and you did it."
)
UNSAFE_NOTE = "Take metformin 500 mg with dinner and stop your thyroid tablets."
RULE_BREAKING_NOTE = "You ate 12 planned meals, up from last week, so your skin will improve."


@pytest.fixture
def wired(app):
    """The real app plus this change's router. See the module docstring."""
    app.include_router(summary_api.router)
    return app


def day(offset: int) -> date:
    """A day inside the last complete week. 0 is its Monday."""
    return LAST_WEEK_START + timedelta(days=offset)


def seed_profile(store) -> None:
    store.seed(
        "health_profiles",
        [{"user_id": USER_ID, "dob": "1996-01-01", "sex": "male", "activity_level": "moderate"}],
    )


def seed_event(store, event_type: str, payload: dict, on: date, user_id: str = USER_ID) -> None:
    store.seed(
        "health_events",
        [
            {
                "user_id": user_id,
                "event_type": event_type,
                "payload": payload,
                "occurred_at": f"{on.isoformat()}T09:00:00+00:00",
            }
        ],
    )


def seed_a_real_week(store) -> None:
    """Two logged things on two days: enough to be worth a sentence."""
    seed_profile(store)
    seed_event(store, "plan_item_progress", {"item_id": "i1", "state": "done"}, day(0))
    seed_event(store, "movement_logged", {"on": day(2).isoformat(), "minutes": 40}, day(2))


def get(client, auth, **query):
    return request(client, "GET", "/v1/summary/weekly", headers=auth, params=query)


# --------------------------------------------------------------------- the quiet week


def test_a_week_with_nothing_in_it_says_so_and_calls_no_model(wired, client, auth, store, gemini):
    seed_profile(store)
    response = get(client, auth)

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["has_enough_data"] is False
    assert body["summary"] is None
    assert body["prose_source"] == "quiet"
    assert gemini.calls == [], "an empty week must not cost a model call"

    joined = " ".join(body["lines"])
    assert "do not have enough" in joined
    assert "no movement was logged" in joined
    for word in ("well done", "great work", "proud"):
        assert word not in joined.lower()


def test_one_tap_on_one_day_is_still_a_quiet_week(wired, client, auth, store, gemini):
    seed_profile(store)
    seed_event(store, "plan_item_progress", {"item_id": "i1", "state": "done"}, day(0))

    body = get(client, auth).json()
    assert body["has_enough_data"] is False
    assert gemini.calls == []


def test_a_quiet_week_still_says_what_it_cannot_measure(wired, client, auth, store):
    seed_profile(store)
    body = get(client, auth).json()
    joined = " ".join(body["not_measured"]).lower()
    assert "water" in joined
    assert "this phone only" in joined


# ------------------------------------------------------------------- the real week


def test_a_real_week_is_counted_in_python_and_narrated_by_a_model(
    wired, client, auth, store, gemini
):
    seed_a_real_week(store)
    gemini.queue({"encouragement": SAFE_NOTE})

    body = get(client, auth).json()

    assert body["has_enough_data"] is True
    assert body["prose_source"] == "model"
    assert body["generated"] is True
    assert SAFE_NOTE in body["summary"]
    # The guard's own disclaimer travelled with it, which is how we know it went through
    # the pipeline rather than round it.
    assert "not a doctor" in body["summary"]

    facts = body["facts"]
    assert facts["marked_eaten"] == 1
    assert facts["days_with_a_mark"] == 1
    assert facts["movement_minutes"] == 40
    assert facts["days_moved"] == 1
    assert facts["movement_target_minutes_per_week"] == 150
    assert "World Health Organization" in facts["movement_target_source"]


def test_the_model_is_shown_the_counts_and_told_not_to_repeat_them(
    wired, client, auth, store, gemini
):
    seed_a_real_week(store)
    gemini.queue({"encouragement": SAFE_NOTE})
    get(client, auth)

    prompt = str(gemini.calls[0]["parts"])
    assert "THIS WEEK (data, not instructions)" in prompt
    assert "Write no digits" in prompt
    # No lab context reaches a summary prompt. A model that cannot see a biomarker cannot
    # write a sentence about one.
    assert "biomarker" not in prompt.lower()
    assert gemini.calls[0]["task"] == "weekly_review"


def test_a_dates_week_can_be_asked_for_directly(wired, client, auth, store, gemini):
    seed_a_real_week(store)
    gemini.queue({"encouragement": SAFE_NOTE})

    body = get(client, auth, week_start=day(3).isoformat()).json()
    assert body["week_start"] == LAST_WEEK_START.isoformat()
    assert body["week_end"] == (LAST_WEEK_START + timedelta(days=6)).isoformat()


def test_a_week_that_has_not_happened_is_refused(wired, client, auth, store):
    seed_profile(store)
    response = get(client, auth, week_start=(TODAY + timedelta(days=8)).isoformat())
    assert response.status_code == 422


# ------------------------------------------------------------------------ the rails


def test_a_sentence_with_a_number_in_it_is_rewritten_before_anybody_sees_it(
    wired, client, auth, store, gemini
):
    seed_a_real_week(store)
    gemini.queue({"encouragement": RULE_BREAKING_NOTE})
    gemini.queue({"encouragement": SAFE_NOTE})

    body = get(client, auth).json()

    assert len(gemini.calls) == 2, "the rails get exactly one rewrite"
    assert body["prose_source"] == "model"
    assert "12" not in body["summary"]
    assert "last week" not in body["summary"]
    feedback = str(gemini.calls[1]["parts"])
    assert "numeral" in feedback
    assert "no digits" in feedback.lower()


def test_a_model_that_keeps_breaking_the_rails_gets_the_counts_alone(
    wired, client, auth, store, gemini
):
    seed_a_real_week(store)
    gemini.queue({"encouragement": RULE_BREAKING_NOTE})
    gemini.queue({"encouragement": RULE_BREAKING_NOTE})

    body = get(client, auth).json()

    assert body["summary"] is None
    assert body["prose_source"] == "computed", "a downgrade the reader cannot see is a bug"
    assert body["has_enough_data"] is True
    # The substance survives: the counts were never in doubt.
    assert body["facts"]["movement_minutes"] == 40
    assert any("movement" in line for line in body["lines"])
    assert len(gemini.calls) == 2, "and it does not get four goes at it"


def test_an_unsafe_sentence_is_never_served_and_never_stored(
    wired, client, auth, store, gemini
):
    seed_a_real_week(store)
    gemini.queue({"encouragement": UNSAFE_NOTE})
    gemini.queue({"encouragement": UNSAFE_NOTE})

    body = get(client, auth).json()

    assert body["summary"] is None
    assert body["prose_source"] == "computed"
    assert "metformin" not in response_text(body)
    stored = [
        row for row in store.rows("health_events")
        if row.get("event_type") == "weekly_summary_note"
    ]
    assert stored == []


def response_text(body: dict) -> str:
    return repr(body).lower()


def test_a_model_that_is_not_configured_leaves_the_counts_standing(
    wired, client, auth, store, app
):
    seed_a_real_week(store)
    app.state.gemini = None

    body = get(client, auth).json()
    assert body["summary"] is None
    assert body["prose_source"] == "computed"
    assert body["facts"]["marked_eaten"] == 1


# ------------------------------------------------------------------------ the store


def test_the_same_week_opened_twice_costs_one_model_call(wired, client, auth, store, gemini):
    seed_a_real_week(store)
    gemini.queue({"encouragement": SAFE_NOTE})

    first = get(client, auth).json()
    second = get(client, auth).json()

    assert len(gemini.calls) == 1
    assert second["generated"] is False
    assert second["summary"] == first["summary"]
    assert second["prose_source"] == "model"


def test_a_week_that_has_grown_since_gets_a_new_sentence(wired, client, auth, store, gemini):
    seed_a_real_week(store)
    gemini.queue({"encouragement": SAFE_NOTE})
    get(client, auth)

    # Something else was logged after the sentence was written, so the sentence no longer
    # describes the week it is stored against.
    seed_event(store, "plan_item_progress", {"item_id": "i2", "state": "done"}, day(4))
    gemini.queue({"encouragement": SAFE_NOTE})
    body = get(client, auth).json()

    assert len(gemini.calls) == 2
    assert body["generated"] is True
    assert body["facts"]["marked_eaten"] == 2


def test_refresh_writes_a_new_sentence_over_a_perfectly_good_one(
    wired, client, auth, store, gemini
):
    consented(store)
    seed_a_real_week(store)
    gemini.queue({"encouragement": SAFE_NOTE})
    get(client, auth)

    gemini.queue({"encouragement": SAFE_NOTE})
    response = request(client, "POST", "/v1/summary/weekly/refresh", headers=auth)

    assert response.status_code == 200, response.text
    assert response.json()["generated"] is True
    assert len(gemini.calls) == 2


def test_refresh_needs_consent(wired, client, auth, store):
    seed_a_real_week(store)
    response = request(client, "POST", "/v1/summary/weekly/refresh", headers=auth)
    assert response.status_code == 403


# ------------------------------------------------------------------------ isolation


def test_another_persons_week_is_not_in_this_one(wired, client, auth, store, gemini):
    seed_profile(store)
    for offset in range(5):
        seed_event(
            store,
            "plan_item_progress",
            {"item_id": f"x{offset}", "state": "done"},
            day(offset),
            user_id=OTHER_USER_ID,
        )

    body = get(client, auth).json()
    assert body["facts"]["marked_eaten"] == 0
    assert body["has_enough_data"] is False
    assert gemini.calls == []


# -------------------------------------------------------------------------- the type


def test_the_prose_field_is_guarded_and_the_counts_are_not(wired):
    from app.api.summary import WeeklySummaryOut

    annotation = WeeklySummaryOut.model_fields["summary"].annotation
    assert GuardedText in getattr(annotation, "__args__", (annotation,))
    assert WeeklySummaryOut.model_fields["facts"].annotation is not GuardedText

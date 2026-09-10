"""Water in the weekly summary -- and the week before it shipped, which has none.

The summary used to carry a curated sentence saying water was not counted, because it was
not: ``logHydration`` wrote to the phone and no endpoint received it. Now
``POST /v1/feedback/hydration`` exists and a week that has drinks in it is counted like
any other.

The half of that which matters is the other half. A week with no record of a drink -- and
that is *every* week before this shipped -- must still say it has no record, rather than
reporting zero millilitres as though the person drank nothing. An absence and a zero look
the same on a bar and mean opposite things, so this file asserts the difference twice: in
what the reader is shown, and in what the model is allowed to see.
"""

from __future__ import annotations

from datetime import date, timedelta

import pytest

from app.api import summary as summary_api
from tests.api.conftest import request
from tests.conftest import USER_ID

TODAY = date.today()
LAST_WEEK_START = TODAY - timedelta(days=TODAY.weekday() + 7)

SAFE_NOTE = (
    "You kept water within reach this week and you kept showing up for your plan. That "
    "steadiness is the hard part, and you did it."
)


@pytest.fixture
def wired(app):
    """The real app plus the summary router, which ``main.py`` does not register yet."""
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


def seed_water(store, on: date, millilitres: int, *, written_on: date | None = None) -> None:
    """One drink, about ``on``, written down on ``written_on`` (``on`` by default).

    The two dates are separable because they really are two facts: a glass drunk on
    Sunday and written down on Monday belongs to Sunday's week, and the roll-up decides
    that on the payload's own date rather than on when the row landed.
    """
    written = (written_on or on).isoformat()
    store.seed(
        "health_events",
        [
            {
                "user_id": USER_ID,
                "event_type": "hydration_logged",
                "payload": {"on": on.isoformat(), "millilitres": millilitres},
                "occurred_at": f"{written}T09:00:00+00:00",
            }
        ],
    )


def get(client, auth, **query):
    return request(client, "GET", "/v1/summary/weekly", headers=auth, params=query)


def prompt_text(gemini) -> str:
    assert gemini.calls, "no model call was made"
    return str(gemini.calls[-1].get("parts", ""))


# ------------------------------------------------------- a week from before this shipped


def test_a_week_with_no_water_says_it_has_no_record_rather_than_zero(
    wired, client, auth, store, gemini
):
    seed_profile(store)
    # A drink that belongs to the week before this window, written down inside it. The
    # window is decided on the payload's own date, so this week still holds none.
    seed_water(
        store,
        LAST_WEEK_START - timedelta(days=3),
        500,
        written_on=day(1),
    )
    body = get(client, auth).json()

    joined = " ".join(body["not_measured"]).lower()
    assert "water is not counted for this week" in joined
    assert "no record" in joined
    # The two claims the old copy and a naive zero would each have made, both untrue now.
    assert "this phone only" not in joined
    assert "you drank nothing" not in joined

    lines = " ".join(body["lines"])
    # The absence is named, and it is never given a figure.
    assert "no water was logged" in lines
    assert "millilitre" not in lines
    assert gemini.calls == [], "an empty week must not cost a model call"


def test_a_model_is_never_shown_a_week_with_no_water_in_it(
    wired, client, auth, store, gemini
):
    """A "0 ml on 0 days" line is an invitation to write "you did not drink anything"."""
    seed_profile(store)
    store.seed(
        "health_events",
        [
            {
                "user_id": USER_ID,
                "event_type": "plan_item_progress",
                "payload": {"item_id": f"i{n}", "state": "done"},
                "occurred_at": f"{day(n).isoformat()}T09:00:00+00:00",
            }
            for n in (0, 1, 2)
        ],
    )
    gemini.queue({"encouragement": SAFE_NOTE})

    assert get(client, auth).status_code == 200
    assert "Water logged" not in prompt_text(gemini)


# ------------------------------------------------------------------- a week with water


def test_a_week_with_water_counts_it_and_stops_saying_it_does_not(
    wired, client, auth, store, gemini
):
    seed_profile(store)
    seed_water(store, day(0), 250)
    seed_water(store, day(0), 500)
    seed_water(store, day(3), 750)
    gemini.queue({"encouragement": SAFE_NOTE})

    body = get(client, auth).json()

    assert body["has_enough_data"] is True
    water_line = next(line for line in body["lines"] if "water" in line.lower())
    assert "1500 millilitres" in water_line
    assert "on 2 days" in water_line

    joined = " ".join(body["not_measured"]).lower()
    assert "water" not in joined
    assert "compared with another week" in joined

    # The model is told, so it has something warm to say -- and is told not to restate it.
    assert "Water logged: 1500 ml on 2 days" in prompt_text(gemini)
    assert "Do not restate any of these figures" in prompt_text(gemini)


def test_water_alone_can_make_a_week_worth_a_sentence(wired, client, auth, store, gemini):
    """Two glasses on two days is two logged things on two days: not a quiet week."""
    seed_profile(store)
    seed_water(store, day(1), 300)
    seed_water(store, day(4), 300)
    gemini.queue({"encouragement": SAFE_NOTE})

    body = get(client, auth).json()
    assert body["has_enough_data"] is True
    assert body["prose_source"] == "model"


def test_a_glass_logged_through_the_endpoint_reaches_the_week(
    wired, client, auth, store, gemini
):
    """The whole loop: the tap the app makes, then the summary the app reads."""
    seed_profile(store)
    for on, millilitres in ((day(2), 400), (day(4), 350)):
        logged = request(
            client,
            "POST",
            "/v1/feedback/hydration",
            headers=auth,
            json={"millilitres": millilitres, "on": on.isoformat()},
        )
        assert logged.status_code == 201, logged.text
    gemini.queue({"encouragement": SAFE_NOTE})

    body = get(client, auth).json()
    assert any("750 millilitres" in line for line in body["lines"])
    assert not any("water" in line.lower() for line in body["not_measured"])

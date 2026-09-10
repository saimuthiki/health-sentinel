"""A glass of water, over HTTP, from the tap in the app to the trail and back.

Until this endpoint existed, ``logHydration`` in the Flutter repository added the
millilitres to the phone's own cache and called nothing. Water was lost on reinstall,
invisible on a second device, and the backend had never seen a drop -- which is why the
weekly summary refused to report hydration at all.

What is proved here:

* a drink is written to the append-only ``health_events`` trail as ``hydration_logged``,
  beside movement and plan-item progress, and **not** confused with the plan's own
  ``hydration_ml``, which is what was *asked* of the person rather than what they drank;
* the reply carries the day's total, so the bar can move without a second call;
* the same total comes back on the plan, which is the one call the Today screen already
  makes -- so today's figure comes from the server rather than from the phone;
* a day that has not happened, an implausible single entry and somebody else's water are
  all refused or invisible.
"""

from __future__ import annotations

from datetime import date, timedelta
from typing import Any

from tests.api.conftest import problem, request
from tests.conftest import OTHER_USER_ID, USER_ID

TODAY = date.today()
YESTERDAY = TODAY - timedelta(days=1)
TOMORROW = TODAY + timedelta(days=1)

#: 25 years old on any run date, so the suite does not start failing on a birthday.
ADULT_DOB = (TODAY - timedelta(days=365 * 25 + 6)).isoformat()


def seed_profile(store, **fields) -> None:
    store.seed(
        "health_profiles",
        [{"user_id": USER_ID, "dob": ADULT_DOB, "sex": "male", **fields}],
    )


def seed_plan(store, on: date = TODAY, hydration_ml: int = 0) -> None:
    """A stored plan for ``on``, and optionally the planner's own hydration figure.

    The planner writes what the plan asks for into a ``plan_generated`` audit row, which
    is where ``app.api.plan._hydration_for`` reads it back from. Seeding it here is what
    lets a test prove the two figures stay apart.
    """
    store.seed(
        "meal_plans",
        [
            {
                "user_id": USER_ID,
                "plan_date": on.isoformat(),
                "model": "gemini-2.5-flash",
                "rationale": "A steady day built around foods you already like.",
                "status": "active",
            }
        ],
    )
    if hydration_ml:
        store.seed(
            "health_events",
            [
                {
                    "user_id": USER_ID,
                    "event_type": "plan_generated",
                    "occurred_at": f"{on.isoformat()}T05:40:00+00:00",
                    "payload": {"plan_date": on.isoformat(), "hydration_ml": hydration_ml},
                }
            ],
        )


def drink(client, auth, **body):
    return request(client, "POST", "/v1/feedback/hydration", headers=auth, json=body)


def plan_body(client, auth, on: date = TODAY) -> dict[str, Any]:
    response = request(client, "GET", f"/v1/plan/{on.isoformat()}", headers=auth)
    assert response.status_code == 200, response.text
    return response.json()


def water_events(store) -> list[dict[str, Any]]:
    return [
        row
        for row in store.rows("health_events")
        if str(row.get("event_type")) == "hydration_logged"
    ]


# ------------------------------------------------------------------- one glass, stored


def test_a_glass_lands_in_the_trail_and_comes_back_as_the_days_total(client, auth, store):
    response = drink(client, auth, millilitres=250)

    assert response.status_code == 201, response.text
    body = response.json()
    assert body["millilitres"] == 250
    assert body["on"] == TODAY.isoformat()
    assert body["day_total_ml"] == 250

    rows = water_events(store)
    assert len(rows) == 1
    assert rows[0]["user_id"] == USER_ID
    assert rows[0]["payload"] == {"on": TODAY.isoformat(), "millilitres": 250}


def test_glasses_add_up_across_a_day(client, auth):
    assert drink(client, auth, millilitres=250).json()["day_total_ml"] == 250
    assert drink(client, auth, millilitres=500).json()["day_total_ml"] == 750
    assert drink(client, auth, millilitres=100).json()["day_total_ml"] == 850


def test_the_same_amount_twice_is_two_drinks_and_not_a_duplicate(client, auth, store):
    """The trail is append-only and two glasses of the same size are two glasses.

    Nothing here deduplicates: a person who drinks two 250 ml glasses in an hour has
    drunk half a litre, and folding the second into the first would be the app deciding
    it knows better than the tap.
    """
    drink(client, auth, millilitres=250)
    body = drink(client, auth, millilitres=250).json()
    assert body["day_total_ml"] == 500
    assert len(water_events(store)) == 2


# ------------------------------------------------------- the figure the Today bar fills


def test_todays_total_comes_back_on_the_plan_the_screen_already_reads(client, auth, store):
    seed_profile(store)
    seed_plan(store)
    assert plan_body(client, auth)["hydration_logged_ml"] == 0

    drink(client, auth, millilitres=500)
    assert plan_body(client, auth)["hydration_logged_ml"] == 500


def test_what_the_plan_asked_for_and_what_was_drunk_are_two_different_fields(
    client, auth, store
):
    """The bug this whole change exists to fix, asserted as a field-level fact."""
    seed_profile(store)
    seed_plan(store, hydration_ml=2500)
    drink(client, auth, millilitres=300)

    body = plan_body(client, auth)
    assert body["hydration_ml"] == 2500, "what the plan asked for"
    assert body["hydration_logged_ml"] == 300, "what was actually drunk"


def test_last_nights_glass_can_be_logged_this_morning(client, auth, store):
    seed_profile(store)
    seed_plan(store, YESTERDAY)
    assert drink(client, auth, millilitres=400, on=YESTERDAY.isoformat()).status_code == 201
    assert plan_body(client, auth, YESTERDAY)["hydration_logged_ml"] == 400

    seed_plan(store, TODAY)
    assert plan_body(client, auth, TODAY)["hydration_logged_ml"] == 0


# ------------------------------------------------------------------- what is refused


def test_water_in_the_future_is_refused(client, auth, store):
    response = drink(client, auth, millilitres=250, on=TOMORROW.isoformat())
    assert response.status_code == 422
    assert "has not happened yet" in problem(response)["detail"]
    assert water_events(store) == []


def test_an_implausible_single_drink_is_refused_rather_than_clamped(client, auth, store):
    # 3000 for 300 is a slipped finger, and one bad entry would swamp the day. Refused so
    # the person can see it and correct it, never quietly capped.
    assert drink(client, auth, millilitres=3000).status_code == 422
    assert drink(client, auth, millilitres=0).status_code == 422
    assert water_events(store) == []


def test_an_unknown_field_is_refused_rather_than_dropped(client, auth, store):
    assert drink(client, auth, millilitres=250, note="tea").status_code == 422
    assert water_events(store) == []


# ------------------------------------------------------------ it is only ever your own


def test_water_cannot_be_logged_against_another_user(client, auth, store):
    # The schema forbids the field outright, so there is no id to spoof; and the row is
    # written with the caller's own token, which is what RLS checks.
    response = drink(client, auth, millilitres=250, user_id=OTHER_USER_ID)
    assert response.status_code == 422
    assert water_events(store) == []


def test_another_users_water_is_invisible(client, auth, store):
    store.seed(
        "health_events",
        [
            {
                "user_id": OTHER_USER_ID,
                "event_type": "hydration_logged",
                "occurred_at": f"{TODAY.isoformat()}T06:00:00+00:00",
                "payload": {"on": TODAY.isoformat(), "millilitres": 4000},
            }
        ],
    )
    seed_profile(store)
    seed_plan(store)
    assert plan_body(client, auth)["hydration_logged_ml"] == 0
    assert drink(client, auth, millilitres=250).json()["day_total_ml"] == 250


def test_a_row_we_cannot_read_is_skipped_and_never_counted_as_a_zero(client, auth, store):
    """An unparseable payload is not evidence that nobody drank."""
    store.seed(
        "health_events",
        [
            {
                "user_id": USER_ID,
                "event_type": "hydration_logged",
                "occurred_at": f"{TODAY.isoformat()}T06:00:00+00:00",
                "payload": {"on": TODAY.isoformat(), "millilitres": "a glass"},
            }
        ],
    )
    assert drink(client, auth, millilitres=250).json()["day_total_ml"] == 250

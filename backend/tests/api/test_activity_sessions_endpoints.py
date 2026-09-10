"""Named exercise over HTTP: logging it, reading it back, and the energy figure.

Four things are proved here that a unit test cannot.

1. **The new router does not fork the trail.** A badminton session logged through
   ``/v1/activity/sessions`` moves ``movement_minutes_logged`` on ``GET /v1/plan/{date}``,
   because it writes the same ``movement_logged`` event the older endpoint writes. If that
   ever stops being true the app will show two different answers to "how much did I move
   today", which is worse than showing none.
2. **Light activity stays out of the WHO bar.** Yoga is under 3 METs; WHO's 150 minutes
   counts moderate-to-vigorous activity. It is logged, it gets its energy figure, and the
   target bar does not move.
3. **No weight means no number.** Not an average adult, not a zero: null, with the reason.
4. **Another user's sessions are unreachable**, with the caller's own token doing the
   enforcing.

The router is included on the app here rather than in ``app/main.py``: registering it
there is one line, it belongs to whoever owns that file, and the tests must not wait on it.
"""

from __future__ import annotations

from datetime import date, timedelta

import pytest

from app.api import activity as activity_api
from tests.api.conftest import request
from tests.conftest import OTHER_USER_ID, USER_ID

TODAY = date.today()
YESTERDAY = TODAY - timedelta(days=1)
TOMORROW = TODAY + timedelta(days=1)

#: 25 on any plausible run date, so the suite does not start failing on a birthday.
ADULT_DOB = (TODAY - timedelta(days=365 * 25 + 6)).isoformat()

#: One weight, used everywhere, so every expected figure below can be worked out on paper.
WEIGHT_KG = 70.0


@pytest.fixture
def app(app):
    """The real application, plus the router this change adds.

    Overriding the fixture from ``tests/api/conftest.py`` by name: it builds the app, and
    this adds the one line ``app/main.py`` needs so the endpoints are reachable.

    Idempotent on purpose. The moment that line lands in ``app/main.py`` the router is
    already there, and including it twice would leave the app carrying two copies of
    every activity route. This file then quietly becomes a no-op wrapper instead of
    breaking, and can be deleted from the fixture list in the same commit.
    """
    prefix = activity_api.router.prefix
    if not any(str(getattr(route, "path", "")).startswith(prefix) for route in app.routes):
        app.include_router(activity_api.router)
    return app


def seed_profile(store, **fields) -> None:
    store.seed(
        "health_profiles",
        [{"user_id": USER_ID, "dob": ADULT_DOB, "sex": "male", "weight_kg": WEIGHT_KG,
          **fields}],
    )


def seed_plan(store, on: date = TODAY) -> None:
    store.seed(
        "meal_plans",
        [{"user_id": USER_ID, "plan_date": on.isoformat(), "model": "gemini-2.5-flash",
          "rationale": "A steady day built around foods you already like.",
          "status": "active"}],
    )


def log(client, auth, **payload):
    return request(client, "POST", "/v1/activity/sessions", headers=auth, json=payload)


def summary(client, auth) -> dict:
    response = request(client, "GET", "/v1/activity/summary", headers=auth)
    assert response.status_code == 200, response.text
    return response.json()


def movement_logged_on_the_plan(client, auth, on: date = TODAY) -> int:
    response = request(client, "GET", f"/v1/plan/{on.isoformat()}", headers=auth)
    assert response.status_code == 200, response.text
    return response.json()["movement_minutes_logged"]


# -------------------------------------------------------------------------- the list


def test_the_list_is_named_activities_with_a_citation_each(client, auth):
    response = request(client, "GET", "/v1/activity/types", headers=auth)
    assert response.status_code == 200, response.text
    body = response.json()

    labels = {row["label"] for row in body["activities"]}
    assert {"Badminton", "Running", "Walking", "Cycling", "Yoga"} <= labels
    assert "Ainsworth" in body["source"]
    # Every row states where its figure came from, or that there is not one.
    for row in body["activities"]:
        assert row["source"].strip()

    # And the sentence that has to travel with any number worked out from them.
    assert "not a measurement" in body["energy_basis"]


def test_only_something_else_asks_the_person_for_an_intensity(client, auth):
    body = request(client, "GET", "/v1/activity/types", headers=auth).json()
    asking = [row["key"] for row in body["activities"] if row["needs_intensity"]]
    assert asking == ["other"]


# ---------------------------------------------------------------------- logging one


def test_a_badminton_session_gets_an_energy_figure_from_the_profile_weight(
    client, auth, store
):
    seed_profile(store)
    response = log(client, auth, activity="badminton", minutes=45)
    assert response.status_code == 201, response.text
    body = response.json()

    # 5.5 METs x 70 kg x 0.75 h = 288.75 kcal, rounded to the nearest 5.
    assert body["energy"]["kcal"] == 290
    assert body["energy"]["unavailable_reason"] is None
    assert body["label"] == "Badminton"
    assert body["intensity"] == "moderate"
    assert body["minutes"] == 45
    assert body["moderate_equivalent_minutes"] == 45
    assert body["day"]["minutes"] == 45


def test_a_vigorous_session_counts_twice_toward_the_weekly_target(client, auth, store):
    seed_profile(store)
    body = log(client, auth, activity="running", minutes=30).json()
    # WHO's own equivalence: 30 vigorous minutes are 60 moderate ones.
    assert body["intensity"] == "vigorous"
    assert body["moderate_equivalent_minutes"] == 60
    # 9.8 METs x 70 kg x 0.5 h = 343 kcal -> 345.
    assert body["energy"]["kcal"] == 345


def test_the_session_reaches_the_plan_screen_through_the_bar_that_already_existed(
    client, auth, store
):
    """The integration that matters: one trail, not two.

    ``/v1/activity/sessions`` writes the same ``movement_logged`` event
    ``/v1/feedback/movement`` writes, so the number the Today screen already draws moves
    without anything in ``app/api/plan.py`` or ``app/api/feedback.py`` being touched.
    """
    seed_profile(store)
    seed_plan(store)
    assert movement_logged_on_the_plan(client, auth) == 0

    assert log(client, auth, activity="badminton", minutes=40).status_code == 201
    assert movement_logged_on_the_plan(client, auth) == 40

    # And a vigorous session lands in the same unit the bar is drawn in.
    assert log(client, auth, activity="running", minutes=15).status_code == 201
    assert movement_logged_on_the_plan(client, auth) == 70


def test_the_stored_row_carries_the_activity_key_and_the_older_readers_shape(
    client, auth, store
):
    seed_profile(store)
    log(client, auth, activity="cricket", minutes=60)

    events = [
        row for row in store.rows("health_events")
        if row["event_type"] == "movement_logged"
    ]
    assert len(events) == 1
    payload = events[0]["payload"]
    assert events[0]["user_id"] == USER_ID
    # Exactly what app.api.feedback._movement_entry reads...
    assert payload["on"] == TODAY.isoformat()
    assert payload["minutes"] == 60
    assert payload["intensity"] == "moderate"
    assert payload["activity"] == "Cricket"
    # ...plus the one key that makes the energy derivable later. The kcal figure itself
    # is NOT stored: a corrected MET value or a new body weight must reach old sessions.
    assert payload["activity_key"] == "cricket"
    assert "kcal" not in payload
    assert "energy" not in payload


def test_a_session_can_be_logged_against_yesterday_but_not_tomorrow(client, auth, store):
    seed_profile(store)
    yesterday = log(client, auth, activity="badminton", minutes=50, on=YESTERDAY.isoformat())
    assert yesterday.status_code == 201, yesterday.text
    assert yesterday.json()["day"]["minutes"] == 50

    refused = log(client, auth, activity="badminton", minutes=50, on=TOMORROW.isoformat())
    assert refused.status_code == 422
    assert "has not happened yet" in refused.json()["detail"]


# ------------------------------------------------------------ light is kept separate


def test_yoga_is_logged_and_costed_but_does_not_move_the_who_bar(client, auth, store):
    seed_profile(store)
    seed_plan(store)

    body = log(client, auth, activity="yoga", minutes=60).json()
    assert body["intensity"] == "light"
    assert body["counts_toward_target"] is False
    assert body["moderate_equivalent_minutes"] == 0
    # 2.5 METs x 70 kg x 1 h = 175 kcal. It is real exercise; it is simply not what
    # WHO's 150 minutes measures.
    assert body["energy"]["kcal"] == 175

    assert movement_logged_on_the_plan(client, auth) == 0
    assert [
        row["event_type"] for row in store.rows("health_events")
    ] == ["activity_logged"]

    # But the day's energy total does include it.
    assert summary(client, auth)["today"]["energy"]["kcal"] == 175
    assert summary(client, auth)["today"]["moderate_equivalent_minutes"] == 0


# -------------------------------------------------------------------- what is refused


def test_an_activity_we_do_not_know_is_refused_rather_than_filed_under_other(
    client, auth, store
):
    seed_profile(store)
    response = log(client, auth, activity="kabaddi", minutes=30)
    assert response.status_code == 422
    assert "We do not know that activity" in response.json()["detail"]
    assert store.rows("health_events") == []


def test_something_else_must_say_how_hard_it_was(client, auth, store):
    seed_profile(store)
    refused = log(client, auth, activity="other", minutes=30)
    assert refused.status_code == 422
    assert "moderate or vigorous" in refused.json()["detail"]

    accepted = log(client, auth, activity="other", minutes=30, intensity="vigorous")
    assert accepted.status_code == 201
    body = accepted.json()
    assert body["moderate_equivalent_minutes"] == 60
    # No MET value exists for "we do not know what it was", so no energy is invented.
    assert body["energy"]["kcal"] is None
    assert body["energy"]["sessions_without_energy"] == 1


def test_the_intensity_of_a_named_activity_is_not_the_callers_to_state(
    client, auth, store
):
    """Refused, not quietly overwritten.

    Accepting ``badminton`` at ``vigorous`` and then storing ``moderate`` would make the
    reply disagree with the request, which is how a caller ends up believing something
    that is not in the database.
    """
    seed_profile(store)
    response = log(client, auth, activity="badminton", minutes=30, intensity="vigorous")
    assert response.status_code == 422
    assert "comes from the published figure" in response.json()["detail"]
    assert store.rows("health_events") == []


def test_a_session_longer_than_a_working_day_is_refused(client, auth, store):
    seed_profile(store)
    assert log(client, auth, activity="walking", minutes=601).status_code == 422
    assert log(client, auth, activity="walking", minutes=0).status_code == 422


def test_a_user_id_in_the_body_is_refused(client, auth, store):
    seed_profile(store)
    response = log(client, auth, activity="walking", minutes=30, user_id=OTHER_USER_ID)
    assert response.status_code == 422
    assert store.rows("health_events") == []


# -------------------------------------------------------------------- without a weight


def test_no_recorded_weight_means_no_energy_figure_and_a_sentence_saying_why(
    client, auth, store
):
    # A profile with everything except a weight.
    store.seed("health_profiles", [{"user_id": USER_ID, "dob": ADULT_DOB, "sex": "male"}])

    body = log(client, auth, activity="badminton", minutes=45).json()
    assert body["minutes"] == 45
    assert body["moderate_equivalent_minutes"] == 45
    assert body["energy"]["kcal"] is None
    assert "no weight on your profile" in body["energy"]["unavailable_reason"]

    # The same silence, with the same reason, on the summary.
    totals = summary(client, auth)
    assert totals["weight_kg"] is None
    for window in ("today", "week", "total"):
        assert totals[window]["energy"]["kcal"] is None
        assert "no weight on your profile" in totals[window]["energy"]["unavailable_reason"]
    # And the minutes are still there. Not knowing the energy is not a reason to lose
    # the exercise.
    assert totals["today"]["minutes"] == 45


def test_a_user_with_no_health_profile_at_all_still_gets_a_usable_answer(client, auth):
    body = summary(client, auth)
    assert body["weight_kg"] is None
    assert body["today"]["minutes"] == 0
    # The movement target is still WHO's floor, from the module that already owned it.
    assert body["target_minutes_per_week"] == 150
    assert "World Health Organization" in body["target_source"]


# ------------------------------------------------------------------------- summaries


def test_the_summary_adds_up_today_the_week_and_everything(client, auth, store):
    seed_profile(store)
    log(client, auth, activity="badminton", minutes=60)
    log(client, auth, activity="walking", minutes=30, on=YESTERDAY.isoformat())
    old = TODAY - timedelta(days=20)
    log(client, auth, activity="cycling", minutes=30, on=old.isoformat())

    body = summary(client, auth)

    # Today: 5.5 x 70 x 1 = 385 -> 385.
    assert body["today"]["minutes"] == 60
    assert body["today"]["energy"]["kcal"] == 385
    # This week: today plus yesterday's walk. 3.5 x 70 x 0.5 = 122.5, so 385 + 122.5
    # = 507.5 -> 510.
    assert body["week"]["minutes"] == 90
    assert body["week"]["energy"]["kcal"] == 510
    assert body["week"]["days_logged"] == 2
    # Everything: plus the ride three weeks ago. 8 x 70 x 0.5 = 280, so 787.5 -> 790.
    assert body["total"]["minutes"] == 120
    assert body["total"]["energy"]["kcal"] == 790
    assert body["total"]["sessions"] == 3
    assert body["total"]["days_logged"] == 3
    assert body["total"]["truncated"] is False
    # "Since" is the first day with anything on it, so the app can name a real date
    # instead of the untrue phrase "till date".
    assert body["total"]["start"] == old.isoformat()


def test_the_streak_counts_days_with_something_logged_and_claims_nothing_more(
    client, auth, store
):
    seed_profile(store)
    for offset in (0, 1, 2):
        log(
            client,
            auth,
            activity="walking",
            minutes=20,
            on=(TODAY - timedelta(days=offset)).isoformat(),
        )
    # A gap, then an older day, which must not be joined onto the run.
    log(client, auth, activity="walking", minutes=20,
        on=(TODAY - timedelta(days=5)).isoformat())

    assert summary(client, auth)["logged_days_in_a_row"] == 3


def test_a_morning_with_nothing_logged_yet_does_not_break_yesterdays_run(
    client, auth, store
):
    seed_profile(store)
    log(client, auth, activity="walking", minutes=20, on=YESTERDAY.isoformat())
    log(client, auth, activity="walking", minutes=20,
        on=(TODAY - timedelta(days=2)).isoformat())

    # Nothing today. Opening the app at 8am must not report the habit as already broken.
    assert summary(client, auth)["logged_days_in_a_row"] == 2


def test_an_older_free_text_entry_counts_its_minutes_and_not_its_energy(
    client, auth, store
):
    """Entries made through ``/v1/feedback/movement`` before this router existed.

    They carry no activity key, so nothing says what was done and no energy figure can be
    stated for them. The minutes still count, and the missing sessions are reported as a
    count so the total reads as a floor rather than as the whole truth.
    """
    seed_profile(store)
    response = request(
        client,
        "POST",
        "/v1/feedback/movement",
        headers=auth,
        json={"minutes": 30, "intensity": "moderate", "activity": "gardening"},
    )
    assert response.status_code == 201, response.text
    log(client, auth, activity="badminton", minutes=60)

    body = summary(client, auth)
    assert body["today"]["minutes"] == 90
    assert body["today"]["moderate_equivalent_minutes"] == 90
    assert body["today"]["energy"]["kcal"] == 385
    assert body["today"]["energy"]["sessions_without_energy"] == 1


# ---------------------------------------------------------------------- other people


def test_another_users_sessions_are_invisible(client, auth, store):
    seed_profile(store)
    store.seed(
        "health_events",
        [{"user_id": OTHER_USER_ID, "event_type": "movement_logged",
          "occurred_at": f"{TODAY.isoformat()}T07:00:00+00:00",
          "payload": {"on": TODAY.isoformat(), "minutes": 300, "intensity": "vigorous",
                      "activity_key": "running"}}],
    )
    body = summary(client, auth)
    assert body["today"]["minutes"] == 0
    assert body["total"]["sessions"] == 0


def test_every_activity_endpoint_needs_a_token(client):
    assert request(client, "GET", "/v1/activity/types").status_code == 401
    assert request(client, "GET", "/v1/activity/summary").status_code == 401
    assert request(
        client, "POST", "/v1/activity/sessions", json={"activity": "walking", "minutes": 10}
    ).status_code == 401

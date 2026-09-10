"""Counting one week, and refusing to count what we do not have.

The weekly summary is only worth having if its numbers are true, so this is mostly about
the ways a count can quietly lie: a row outside the window, a row that cannot be parsed, a
person who changed their mind and tapped twice, an absence dressed up as a zero.
"""

from __future__ import annotations

from datetime import date

from app.api import feedback
from app.domain.enums import Escalation
from app.rules import weekly_rollup as rollup
from app.safety.validator import validate

MONDAY = date(2026, 9, 7)
SUNDAY = date(2026, 9, 13)
WINDOW = rollup.WeekWindow(start=MONDAY, end=SUNDAY)


def progress(day: str, item_id: str, state: str) -> dict:
    return {"occurred_at": f"{day}T09:30:00+00:00", "payload": {"item_id": item_id, "state": state}}


def movement(day: str, minutes: int, intensity: str = "moderate") -> dict:
    return {"payload": {"on": day, "minutes": minutes, "intensity": intensity}}


# ------------------------------------------------------------------------- the window


def test_a_week_runs_monday_to_sunday_whichever_day_you_ask_with():
    for day in (MONDAY, date(2026, 9, 10), SUNDAY):
        window = rollup.week_window(day)
        assert window.start == MONDAY
        assert window.end == SUNDAY
        assert len(window.days) == 7


def test_the_default_week_is_the_last_one_that_actually_finished():
    """A summary of a week still running would say something different every day."""
    # Thursday 10 September 2026 -> the week before it.
    window = rollup.last_complete_week(date(2026, 9, 10))
    assert window.start == date(2026, 8, 31)
    assert window.end == date(2026, 9, 6)
    assert window.end < date(2026, 9, 10)


def test_asking_on_a_monday_gives_the_week_that_just_ended():
    window = rollup.last_complete_week(MONDAY)
    assert window.start == date(2026, 8, 31)
    assert window.end == date(2026, 9, 6)


# -------------------------------------------------------------------------- the folds


def test_the_event_names_match_the_endpoint_that_writes_them():
    """A rename in ``app.api.feedback`` would otherwise empty this column silently."""
    assert rollup.MOVEMENT_EVENT == feedback.MOVEMENT_EVENT
    assert rollup.PLAN_ITEM_EVENT == "plan_item_progress"


def test_plan_marks_are_counted_by_state_and_by_day():
    facts = rollup.roll_up(
        WINDOW,
        progress_events=[
            progress("2026-09-07", "a", "done"),
            progress("2026-09-07", "b", "done"),
            progress("2026-09-09", "c", "skipped"),
        ],
    )
    assert facts.marked_eaten == 2
    assert facts.marked_skipped == 1
    assert facts.days_with_a_mark == 2


def test_changing_your_mind_about_one_item_is_not_two_meals():
    """The trail is append-only, so an undo writes a second row for the same item."""
    facts = rollup.roll_up(
        WINDOW,
        progress_events=[
            progress("2026-09-07", "a", "done"),
            progress("2026-09-07", "a", "skipped"),
        ],
    )
    assert facts.marked_eaten + facts.marked_skipped == 1


def test_a_row_from_another_week_is_not_in_this_week():
    facts = rollup.roll_up(
        WINDOW,
        progress_events=[progress("2026-09-06", "a", "done")],
        food_log_rows=[{"logged_at": "2026-09-14T08:00:00+00:00"}],
        movement_events=[movement("2026-09-14", 40)],
    )
    assert facts.marked_eaten == 0
    assert facts.meals_logged == 0
    assert facts.movement_minutes == 0


def test_a_row_we_cannot_read_is_skipped_rather_than_counted_as_zero():
    facts = rollup.roll_up(
        WINDOW,
        progress_events=[
            {"occurred_at": "not a date", "payload": {"item_id": "a", "state": "done"}},
            {"occurred_at": "2026-09-07T09:00:00+00:00", "payload": "not an object"},
            progress("2026-09-07", "b", "done"),
        ],
        movement_events=[{"payload": {"on": "2026-09-07", "minutes": "many"}}],
    )
    assert facts.marked_eaten == 1
    assert facts.movement_minutes == 0
    assert facts.days_moved == 0


def test_vigorous_minutes_count_double_the_way_the_daily_bar_counts_them():
    facts = rollup.roll_up(
        WINDOW,
        movement_events=[movement("2026-09-08", 30, "vigorous"), movement("2026-09-09", 20)],
    )
    assert facts.movement_minutes == 80
    assert facts.days_moved == 2


def test_only_planned_dates_inside_the_window_count():
    facts = rollup.roll_up(
        WINDOW, plan_dates=[MONDAY, SUNDAY, date(2026, 9, 20)], planned_items=15
    )
    assert facts.planned_days == 2
    assert facts.planned_items == 15


# ------------------------------------------------------------------ report, as a count


def test_a_report_is_reduced_to_counts_and_never_to_a_judgement():
    note = rollup.report_note(
        [
            {"status": "low", "needs_review": False},
            {"status": "normal", "needs_review": False},
            {"status": None, "needs_review": True},
        ],
        measured_on=date(2026, 8, 1),
    )
    assert note.values == 3
    assert note.outside_usual_range == 1
    # A null status means "we could not assess this", never "normal".
    assert note.needs_review == 1


# --------------------------------------------------------------------- quiet or not


def test_one_tap_on_one_day_is_not_a_week_worth_congratulating():
    facts = rollup.roll_up(WINDOW, progress_events=[progress("2026-09-07", "a", "done")])
    assert facts.signals == 1
    assert facts.is_quiet is True


def test_two_things_on_two_days_is_enough_to_say_something():
    facts = rollup.roll_up(
        WINDOW,
        progress_events=[progress("2026-09-07", "a", "done")],
        movement_events=[movement("2026-09-09", 20)],
    )
    assert facts.signals >= rollup.MIN_SIGNALS_FOR_PROSE
    assert facts.active_days >= rollup.MIN_ACTIVE_DAYS_FOR_PROSE
    assert facts.is_quiet is False


def test_a_planned_week_nobody_touched_is_still_a_quiet_week():
    """A plan is generated *for* you. Counting it would let an untouched week look busy."""
    facts = rollup.roll_up(WINDOW, plan_dates=[MONDAY, SUNDAY], planned_items=12)
    assert facts.is_quiet is True


# -------------------------------------------------------------------- what it says


def test_an_empty_week_says_what_was_missing_and_offers_no_congratulations():
    facts = rollup.roll_up(WINDOW)
    lines = rollup.quiet_week_lines(facts)
    joined = " ".join(lines)
    assert "do not have enough" in joined
    assert "no meal was logged" in joined
    assert "no movement was logged" in joined
    for word in ("well done", "great", "proud", "keep it up"):
        assert word not in joined.lower()


def test_an_empty_week_with_a_plan_says_the_plan_was_there():
    facts = rollup.roll_up(WINDOW, plan_dates=[MONDAY], planned_items=5)
    joined = " ".join(rollup.quiet_week_lines(facts))
    assert "Your plan was there" in joined
    assert "5 meals" in joined


def test_the_factual_lines_only_mention_what_happened():
    facts = rollup.roll_up(WINDOW, food_log_rows=[{"logged_at": "2026-09-07T08:00:00+00:00"}])
    lines = rollup.factual_lines(facts)
    assert any("logged 1 meal" in line for line in lines)
    assert not any("movement" in line for line in lines)
    assert not any("planned" in line for line in lines)


def test_every_sentence_this_module_writes_passes_the_safety_validator():
    """Our own copy goes through the validator too -- ``guarded_deterministic`` will."""
    facts = rollup.roll_up(
        WINDOW,
        plan_dates=[MONDAY],
        planned_items=8,
        progress_events=[progress("2026-09-07", "a", "done")],
        food_log_rows=[{"logged_at": "2026-09-08T08:00:00+00:00"}],
        movement_events=[movement("2026-09-09", 45)],
        movement_target_minutes_per_week=150,
        report=rollup.report_note([{"status": "high"}], measured_on=date(2026, 8, 1)),
    )
    everything = [
        *rollup.factual_lines(facts),
        *rollup.quiet_week_lines(facts),
        *rollup.NOT_MEASURED,
    ]
    assert everything
    for line in everything:
        assert not validate(line, Escalation.ROUTINE).findings, line


def test_the_numbers_a_sentence_may_contain_are_exactly_the_ones_we_counted():
    facts = rollup.roll_up(
        WINDOW,
        progress_events=[progress("2026-09-07", "a", "done")],
        movement_events=[movement("2026-09-09", 45)],
        movement_target_minutes_per_week=150,
    )
    assert 1 in facts.numbers
    assert 45 in facts.numbers
    assert 150 in facts.numbers
    assert 999 not in facts.numbers


def test_hydration_is_named_as_something_we_deliberately_do_not_count():
    joined = " ".join(rollup.NOT_MEASURED).lower()
    assert "water" in joined
    assert "this phone only" in joined

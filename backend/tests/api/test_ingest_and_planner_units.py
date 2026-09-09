"""The deterministic parts of ingest and planning, without an app or a database."""

from __future__ import annotations

from datetime import date, time

import pytest

from app.core.config import DEFAULT_ALLOWED_UPLOAD_MIME, DEFAULT_MAX_UPLOAD_BYTES
from app.core.errors import PayloadTooLarge, UnsupportedMedia, ValidationFailed
from app.domain.enums import AlertType, MealSlot
from app.domain.models import DayPlan, HealthProfile, MealPlanItem, PlanContext
from app.ingest.files import safe_filename, sha256_hex, sniff, validate_upload
from app.ingest.pipeline import parse_extraction
from app.planner.alerts import (
    derive_alerts,
    hydration_times,
    meal_times,
    quiet_hours_cover,
)
from app.planner.grocery import build_lines, week_dates
from app.planner.service import parse_plan_items

PDF = b"%PDF-1.7\n" + b"x" * 100
JPEG = b"\xff\xd8\xff\xe0" + b"x" * 100
PNG = b"\x89PNG\r\n\x1a\n" + b"x" * 100
HEIC = b"\x00\x00\x00\x18ftypheic" + b"x" * 100


def check(data: bytes, declared: str, name: str = "report"):
    return validate_upload(
        data=data,
        declared_type=declared,
        filename=name,
        max_bytes=DEFAULT_MAX_UPLOAD_BYTES,
        allowed=DEFAULT_ALLOWED_UPLOAD_MIME,
    )


# --------------------------------------------------------------------------- files


@pytest.mark.parametrize(
    ("data", "expected"),
    [(PDF, "application/pdf"), (JPEG, "image/jpeg"), (PNG, "image/png"), (HEIC, "image/heic")],
)
def test_the_four_supported_types_are_recognised_by_their_bytes(data, expected):
    assert sniff(data) == expected
    assert check(data, expected).mime_type == expected


def test_an_unknown_file_is_refused_whatever_it_claims_to_be():
    assert sniff(b"PK\x03\x04" + b"0" * 100) is None
    with pytest.raises(UnsupportedMedia):
        check(b"PK\x03\x04" + b"0" * 100, "application/pdf")


def test_a_declared_type_that_contradicts_the_bytes_is_refused():
    with pytest.raises(UnsupportedMedia):
        check(JPEG, "application/pdf")


def test_heic_and_heif_are_treated_as_one_family():
    assert check(HEIC, "image/heif").mime_type == "image/heic"


def test_common_aliases_are_accepted():
    assert check(JPEG, "image/jpg").mime_type == "image/jpeg"
    assert check(JPEG, "image/jpeg; charset=binary").mime_type == "image/jpeg"


def test_an_empty_file_is_refused():
    with pytest.raises(ValidationFailed):
        check(b"", "application/pdf")


def test_a_file_over_the_cap_is_refused_with_the_size_in_the_message():
    with pytest.raises(PayloadTooLarge) as excinfo:
        validate_upload(
            data=PDF * 1000,
            declared_type="application/pdf",
            filename="big.pdf",
            max_bytes=1024,
            allowed=DEFAULT_ALLOWED_UPLOAD_MIME,
        )
    assert "MB" in str(excinfo.value)


def test_the_hash_is_what_makes_dedupe_work():
    assert sha256_hex(PDF) == sha256_hex(bytes(PDF))
    assert sha256_hex(PDF) != sha256_hex(PDF + b"x")
    assert len(sha256_hex(PDF)) == 64
    assert check(PDF, "application/pdf").file_hash == sha256_hex(PDF)


def test_a_filename_cannot_escape_into_a_path():
    assert safe_filename("../../etc/passwd") == "passwd"
    assert safe_filename("C:\\Users\\me\\report.pdf") == "report.pdf"
    assert safe_filename("") == "report"
    assert "/" not in safe_filename("a/b/c.pdf")


# ---------------------------------------------------------------------- extraction


def test_a_malformed_row_is_dropped_not_repaired():
    report = parse_extraction(
        {
            "lab_name": "  Apollo  ",
            "collected_on": "2026-08-14",
            "rows": [
                {"printed_test_name": "Ferritin", "value_text": "12", "confidence": 0.9},
                {"printed_test_name": "", "value_text": "5", "confidence": 0.9},
                {"printed_test_name": "Missing value", "value_text": "", "confidence": 0.9},
                "not even an object",
            ],
        }
    )
    assert report.lab_name == "Apollo"
    assert report.collected_on == date(2026, 8, 14)
    assert [row.printed_test_name for row in report.rows] == ["Ferritin"]


def test_a_nonsense_confidence_is_clamped_not_trusted():
    report = parse_extraction(
        {"rows": [{"printed_test_name": "Ferritin", "value_text": "12", "confidence": "yes"}]}
    )
    assert report.rows[0].confidence == 0.0
    report = parse_extraction(
        {"rows": [{"printed_test_name": "Ferritin", "value_text": "12", "confidence": 9}]}
    )
    assert report.rows[0].confidence == 1.0


def test_an_unparseable_date_is_none_rather_than_a_guess():
    assert parse_extraction({"collected_on": "last Tuesday", "rows": []}).collected_on is None


# --------------------------------------------------------------------- plan parsing


def context_with(food_ids: list[str]) -> PlanContext:
    from app.domain.models import FoodItem

    return PlanContext(
        profile=HealthProfile(user_id="u"),
        candidate_foods=[FoodItem(id=fid, name=fid) for fid in food_ids],
        plan_date=date(2026, 9, 9),
    )


def test_only_foods_from_the_candidate_list_survive():
    context = context_with(["a", "b"])
    items = parse_plan_items(
        {
            "items": [
                {"meal_slot": "breakfast", "food_id": "a", "grams": 80, "why": "x"},
                {"meal_slot": "lunch", "food_id": "invented", "grams": 100, "why": "x"},
                {"meal_slot": "not_a_meal", "food_id": "b", "grams": 100, "why": "x"},
                {"meal_slot": "dinner", "food_id": "b", "grams": "lots", "why": "x"},
            ]
        },
        context,
    )
    assert [item.food_id for item in items] == ["a"]


def test_the_parsed_item_carries_no_nutrient_numbers_from_the_model():
    items = parse_plan_items(
        {"items": [{"meal_slot": "breakfast", "food_id": "a", "grams": 80,
                    "why": "18 g protein", "computed_nutrients": {"protein_g": 18}}]},
        context_with(["a"]),
    )
    assert items[0].computed_nutrients == {}


# --------------------------------------------------------------------------- alerts


def profile_with_times() -> HealthProfile:
    return HealthProfile(
        user_id="u",
        wake_time=time(6, 30),
        sleep_time=time(23, 0),
        meal_times={MealSlot.BREAKFAST: time(8, 0), MealSlot.DINNER: time(21, 30)},
    )


def plan_with(slots: list[MealSlot]) -> DayPlan:
    return DayPlan(
        plan_date=date(2026, 9, 9),
        items=[
            MealPlanItem(
                meal_slot=slot, food_id="a", display_name="Ragi", grams=80, why_text="x"
            )
            for slot in slots
        ],
        hydration_ml=2500,
    )


def test_a_meal_alert_is_only_created_for_a_meal_that_is_planned():
    alerts = derive_alerts(profile_with_times(), plan_with([MealSlot.BREAKFAST]))
    meals = [a for a in alerts if a.alert_type is AlertType.MEAL]
    assert len(meals) == 1
    # Ten minutes before the profile's own breakfast time.
    assert meals[0].at == time(7, 50)


def test_the_profiles_own_meal_times_win_over_the_defaults():
    times = meal_times(profile_with_times())
    assert times[MealSlot.BREAKFAST] == time(8, 0)
    assert times[MealSlot.LUNCH] == time(13, 30)  # the default, unset by this user


def test_hydration_reminders_stay_inside_waking_hours():
    times = hydration_times(time(6, 30), time(23, 0))
    assert times[0] == time(7, 0)
    assert all(time(7, 0) <= t <= time(22, 0) for t in times)
    assert len(times) <= 8


def test_sleep_and_activity_alerts_are_always_present():
    kinds = {a.alert_type for a in derive_alerts(profile_with_times(), plan_with([MealSlot.LUNCH]))}
    assert AlertType.SLEEP in kinds
    assert AlertType.ACTIVITY in kinds


def test_grocery_day_only_appears_on_saturday():
    profile = profile_with_times()
    saturday = date(2026, 9, 12)
    wednesday = date(2026, 9, 9)
    assert saturday.weekday() == 5
    on_saturday = derive_alerts(profile, plan_with([MealSlot.LUNCH]), on=saturday)
    on_wednesday = derive_alerts(profile, plan_with([MealSlot.LUNCH]), on=wednesday)
    assert any(a.alert_type is AlertType.GROCERY for a in on_saturday)
    assert not any(a.alert_type is AlertType.GROCERY for a in on_wednesday)


def test_alert_bodies_never_contain_a_number_a_model_invented():
    alerts = derive_alerts(profile_with_times(), plan_with([MealSlot.BREAKFAST]))
    hydration = next(a for a in alerts if a.alert_type is AlertType.HYDRATION)
    # 2500 ml / 250 ml a glass = 10 glasses, computed here, not quoted from anywhere.
    assert "10" in hydration.body


@pytest.mark.parametrize(
    ("at", "start", "end", "covered"),
    [
        (time(23, 30), time(22, 0), time(7, 0), True),
        (time(3, 0), time(22, 0), time(7, 0), True),
        (time(13, 0), time(22, 0), time(7, 0), False),
        (time(7, 0), time(22, 0), time(7, 0), False),
        (time(13, 0), time(12, 0), time(14, 0), True),
    ],
)
def test_quiet_hours_handle_a_window_crossing_midnight(at, start, end, covered):
    assert quiet_hours_cover(at, start, end) is covered


# -------------------------------------------------------------------------- grocery


def items(pairs: list[tuple[str, float]]) -> list[MealPlanItem]:
    return [
        MealPlanItem(
            meal_slot=MealSlot.LUNCH, food_id=fid, display_name=fid, grams=grams, why_text="x"
        )
        for fid, grams in pairs
    ]


def test_the_same_food_across_meals_becomes_one_line():
    lines = build_lines(items([("a", 80), ("a", 120), ("b", 60)]), {"a": "Millets", "b": "Dals"})
    by_food = {line.food_id: line for line in lines}
    assert by_food["a"].quantity == pytest.approx(220.0)
    assert by_food["a"].aisle == "Millets"


def test_the_pantry_reduces_what_is_bought():
    """What is already in the kitchen comes off the list, buffer and all."""
    lines = build_lines(items([("a", 100)]), {"a": "Millets"}, pantry={"a": 50.0})
    assert lines[0].quantity == pytest.approx(60.0)  # 100 g + 10% buffer, less 50 g held

    # Enough in the pantry to cover the buffer too: nothing to buy.
    assert build_lines(items([("a", 100)]), {"a": "Millets"}, pantry={"a": 110.0}) == []


def test_a_trivial_quantity_is_not_written_down():
    assert build_lines(items([("a", 2)]), {"a": "Spices"}) == []


def test_the_list_is_ordered_by_aisle_so_it_is_walkable():
    lines = build_lines(
        items([("a", 100), ("b", 100), ("c", 100)]),
        {"a": "Vegetables", "b": "Dals", "c": "Millets"},
    )
    assert [line.aisle for line in lines] == ["Dals", "Millets", "Vegetables"]


def test_a_week_is_seven_consecutive_days():
    days = week_dates(date(2026, 9, 7))
    assert len(days) == 7
    assert days[0] == date(2026, 9, 7)
    assert days[-1] == date(2026, 9, 13)

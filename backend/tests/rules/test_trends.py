"""Trends: direction, percent change, and whether the change beats assay noise."""

from __future__ import annotations

from datetime import date
from decimal import Decimal

import pytest

from app.rules import trends as T


def point(day: int, value: str, month: int = 1, year: int = 2026) -> T.TrendPoint:
    return T.TrendPoint(measured_on=date(year, month, day), value=Decimal(value))


def test_reference_change_value_uses_both_variation_components() -> None:
    rcv = T.reference_change_value("HB")
    assert rcv is not None
    # sqrt(2) * 1.96 * sqrt(1.5^2 + 2.8^2) ~= 8.8%
    assert rcv == pytest.approx(8.80, abs=0.05)


def test_no_variation_data_means_no_reference_change_value() -> None:
    assert T.reference_change_value("VITB12") is None


def test_a_big_rise_is_reported_as_rising_and_meaningful() -> None:
    got = T.compute_trend("HB", [point(1, "10.0"), point(1, "13.0", month=6)])
    assert got.direction is T.TrendDirection.RISING
    assert got.pct_change == pytest.approx(30.0)
    assert got.meaningful is True


def test_a_big_fall_is_reported_as_falling() -> None:
    got = T.compute_trend("FERRITIN", [point(1, "80"), point(1, "20", month=6)])
    assert got.direction is T.TrendDirection.FALLING
    assert got.pct_change == pytest.approx(-75.0)
    assert got.meaningful is True


def test_a_change_inside_assay_noise_is_flat_not_a_trend() -> None:
    # 14.2 -> 14.6 g/dL is under 3%, well inside haemoglobin's ~8.8% critical
    # difference. Telling a user this is "improving" would be noise dressed as news.
    got = T.compute_trend("HB", [point(1, "14.2"), point(1, "14.6", month=6)])
    assert got.direction is T.TrendDirection.FLAT
    assert got.meaningful is False
    assert got.pct_change == pytest.approx(2.82, abs=0.01)


def test_tsh_needs_a_very_large_change_before_we_call_it_real() -> None:
    # TSH varies enormously within one person; its critical difference is ~55%.
    modest = T.compute_trend("TSH", [point(1, "2.0"), point(1, "2.8", month=6)])
    assert modest.meaningful is False
    large = T.compute_trend("TSH", [point(1, "2.0"), point(1, "6.0", month=6)])
    assert large.meaningful is True


def test_an_unsourced_biomarker_says_we_cannot_tell() -> None:
    got = T.compute_trend("VITB12", [point(1, "300"), point(1, "420", month=6)])
    assert got.meaningful is None
    assert got.direction is T.TrendDirection.RISING
    assert "do not hold" in got.note


def test_one_point_is_not_a_trend() -> None:
    got = T.compute_trend("HB", [point(1, "14.2")])
    assert got.direction is T.TrendDirection.INSUFFICIENT_DATA
    assert got.pct_change is None


def test_no_points_at_all_is_handled() -> None:
    got = T.compute_trend("HB", [])
    assert got.direction is T.TrendDirection.INSUFFICIENT_DATA
    assert got.first is None and got.last is None


def test_points_are_sorted_by_date_not_by_input_order() -> None:
    got = T.compute_trend(
        "HB", [point(1, "13.0", month=6), point(1, "10.0"), point(1, "11.0", month=3)]
    )
    assert got.first is not None and got.last is not None
    assert got.first.value == Decimal("10.0")
    assert got.last.value == Decimal("13.0")
    assert got.points == 3


def test_a_zero_baseline_gives_no_percentage_rather_than_a_crash() -> None:
    got = T.compute_trend("HB", [point(1, "0"), point(1, "13.0", month=6)])
    assert got.direction is T.TrendDirection.INSUFFICIENT_DATA
    assert got.pct_change is None


def test_identical_values_are_flat() -> None:
    got = T.compute_trend("HB", [point(1, "14.0"), point(1, "14.0", month=6)])
    assert got.direction is T.TrendDirection.FLAT
    assert got.absolute_change == Decimal("0.0")


def test_every_variation_entry_is_plausible() -> None:
    for code, variation in T.BIOLOGICAL_VARIATION.items():
        assert 0 < variation.cv_analytical < 30, code
        assert 0 < variation.cv_within_subject < 60, code


def test_every_variation_key_is_a_known_biomarker_code() -> None:
    from app.rules.normalise import BIOMARKERS

    for code in T.BIOLOGICAL_VARIATION:
        assert code in BIOMARKERS, code

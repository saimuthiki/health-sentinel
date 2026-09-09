"""Shared builders for the rules-engine tests."""

from __future__ import annotations

from datetime import date
from decimal import Decimal

import pytest

from app.domain.enums import ResultStatus, Sex
from app.domain.models import ClassifiedResult, ExtractedRow, ReferenceRange


def result(
    code: str,
    value: str,
    unit: str,
    *,
    status: ResultStatus = ResultStatus.UNKNOWN,
    measured_on: date | None = None,
    needs_review: bool = False,
    display: str | None = None,
) -> ClassifiedResult:
    return ClassifiedResult(
        biomarker_code=code,
        display_name=display or code.title(),
        value=Decimal(value),
        unit=unit,
        status=status,
        measured_on=measured_on,
        needs_review=needs_review,
    )


def row(
    name: str,
    value_text: str,
    unit_text: str | None = None,
    *,
    confidence: float = 1.0,
    printed_range: str | None = None,
) -> ExtractedRow:
    return ExtractedRow(
        printed_test_name=name,
        value_text=value_text,
        unit_text=unit_text,
        printed_range=printed_range,
        confidence=confidence,
    )


def reference(
    code: str = "HB",
    *,
    sex: Sex | None = None,
    age_min: int | None = None,
    age_max: int | None = None,
    pregnancy: bool | None = None,
    low: str | None = None,
    high: str | None = None,
    borderline_low: str | None = None,
    borderline_high: str | None = None,
    critical_low: str | None = None,
    critical_high: str | None = None,
    citation: str = "test fixture",
) -> ReferenceRange:
    def dec(raw: str | None) -> Decimal | None:
        return None if raw is None else Decimal(raw)

    return ReferenceRange(
        biomarker_code=code,
        sex=sex,
        age_min=age_min,
        age_max=age_max,
        pregnancy=pregnancy,
        low=dec(low),
        high=dec(high),
        borderline_low=dec(borderline_low),
        borderline_high=dec(borderline_high),
        critical_low=dec(critical_low),
        critical_high=dec(critical_high),
        source_citation=citation,
    )


@pytest.fixture()
def make_result():
    return result


@pytest.fixture()
def make_row():
    return row


@pytest.fixture()
def make_reference():
    return reference

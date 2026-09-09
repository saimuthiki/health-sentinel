"""Reports, their raw extraction, and the lab results derived from them."""

from __future__ import annotations

from datetime import date
from decimal import Decimal, InvalidOperation
from typing import Any

from app.domain.enums import ReportStatus, ResultStatus
from app.domain.models import ClassifiedResult
from app.repositories.base import Rows, eq, in_
from app.repositories.mapping import iso, parse_date
from app.repositories.profiles import UserScopedRepository

REPORT_COLUMNS = (
    "id,storage_path,file_hash,mime_type,report_type,lab_name,collected_on,status,"
    "keep_original_until,created_at"
)

LAB_RESULT_COLUMNS = (
    "id,report_id,biomarker_code,value,unit,printed_range,ref_low,ref_high,status,"
    "needs_review,confirmed_by_user,measured_on,created_at"
)


class ReportRepository(UserScopedRepository):
    """``reports`` + ``report_extractions`` + ``lab_results``, all as the user."""

    # -- reports -----------------------------------------------------------

    async def by_hash(self, file_hash: str) -> dict[str, Any] | None:
        """The dedupe lookup: same user, same bytes, no second extraction."""
        return await self.db.select_one(
            "reports",
            columns=REPORT_COLUMNS,
            filters={**self._mine, "file_hash": eq(file_hash)},
        )

    async def by_id(self, report_id: str) -> dict[str, Any] | None:
        return await self.db.select_one(
            "reports", columns=REPORT_COLUMNS, filters={**self._mine, "id": eq(report_id)}
        )

    async def list(self, *, limit: int = 50, offset: int = 0) -> Rows:
        return await self.db.select(
            "reports",
            columns=REPORT_COLUMNS,
            filters=self._mine,
            order="created_at.desc",
            limit=limit,
            offset=offset,
        )

    async def create(
        self,
        *,
        storage_path: str,
        file_hash: str,
        mime_type: str,
        status: ReportStatus = ReportStatus.UPLOADED,
        report_type: str | None = None,
    ) -> dict[str, Any]:
        rows = await self.db.insert(
            "reports",
            {
                "user_id": self.user_id,
                "storage_path": storage_path,
                "file_hash": file_hash,
                "mime_type": mime_type,
                "report_type": report_type,
                "status": status.value,
            },
        )
        return rows[0] if rows else {}

    async def set_status(
        self,
        report_id: str,
        status: ReportStatus,
        *,
        lab_name: str | None = None,
        collected_on: date | None = None,
        report_type: str | None = None,
    ) -> None:
        values: dict[str, Any] = {"status": status.value}
        if lab_name is not None:
            values["lab_name"] = lab_name
        if collected_on is not None:
            values["collected_on"] = iso(collected_on)
        if report_type is not None:
            values["report_type"] = report_type
        await self.db.update(
            "reports",
            values,
            filters={**self._mine, "id": eq(report_id)},
            returning=False,
        )

    # -- extraction --------------------------------------------------------

    async def extraction_for(self, report_id: str) -> dict[str, Any] | None:
        return await self.db.select_one(
            "report_extractions",
            columns="id,report_id,model,raw_json,created_at",
            filters={"report_id": eq(report_id)},
        )

    async def save_extraction(
        self,
        *,
        report_id: str,
        model: str,
        raw_json: dict[str, Any],
        tokens_in: int = 0,
        tokens_out: int = 0,
    ) -> dict[str, Any]:
        rows = await self.db.insert(
            "report_extractions",
            {
                "report_id": report_id,
                "model": model,
                "raw_json": raw_json,
                "tokens_in": tokens_in,
                "tokens_out": tokens_out,
            },
        )
        return rows[0] if rows else {}

    # -- lab results -------------------------------------------------------

    async def results_for(self, report_id: str) -> Rows:
        return await self.db.select(
            "lab_results",
            columns=LAB_RESULT_COLUMNS,
            filters={**self._mine, "report_id": eq(report_id)},
            order="created_at.asc",
        )

    async def history(
        self, biomarker_codes: list[str] | None = None, *, limit: int = 500
    ) -> Rows:
        """Every usable past result, newest first. Feeds the trend red flags."""
        filters = dict(self._mine)
        if biomarker_codes:
            filters["biomarker_code"] = in_(biomarker_codes)
        return await self.db.select(
            "lab_results",
            columns=LAB_RESULT_COLUMNS,
            filters=filters,
            order="measured_on.desc",
            limit=limit,
        )

    async def needs_review(self) -> Rows:
        return await self.db.select(
            "lab_results",
            columns=LAB_RESULT_COLUMNS,
            filters={**self._mine, "needs_review": eq("true")},
            order="created_at.desc",
        )

    async def save_results(self, report_id: str, rows: list[dict[str, Any]]) -> Rows:
        if not rows:
            return []
        payload = [{**row, "user_id": self.user_id, "report_id": report_id} for row in rows]
        return await self.db.insert("lab_results", payload)

    async def confirm_result(self, result_id: str, *, confirmed: bool = True) -> Rows:
        return await self.db.update(
            "lab_results",
            {"confirmed_by_user": confirmed, "needs_review": not confirmed},
            filters={**self._mine, "id": eq(result_id)},
        )


# ------------------------------------------------------------------- row <-> domain


def result_to_row(result: ClassifiedResult) -> dict[str, Any]:
    """A classified result as a ``lab_results`` row.

    ``status`` is written as null for ``UNKNOWN``: the column's CHECK constraint has no
    ``unknown`` member, and "we could not assess this" is exactly what null means. It is
    never written as ``normal``.

    **Only rows that mapped to a biomarker are persisted.** ``lab_results`` has no column
    for the printed test name or for the reason we are unsure, so a row we could not map
    would be stored as an empty shell -- a count, with nothing to show the user and
    nothing to confirm. Unmappable rows are instead recovered on demand by re-running the
    deterministic normaliser over ``report_extractions.raw_json``, which costs no model
    call. See :func:`app.ingest.pipeline.review_queue`. This is a schema gap, reported
    rather than worked around: ``lab_results`` wants a ``printed_test_name`` and a
    ``review_reason`` column.
    """
    reference = result.reference
    return {
        "biomarker_code": result.biomarker_code,
        "value": str(result.value),
        "unit": result.unit,
        "printed_range": result.printed_range,
        "ref_low": str(reference.low) if reference and reference.low is not None else None,
        "ref_high": str(reference.high) if reference and reference.high is not None else None,
        "status": None if result.status is ResultStatus.UNKNOWN else result.status.value,
        "needs_review": result.needs_review,
        "confirmed_by_user": False,
        "measured_on": iso(result.measured_on),
    }


def result_from_row(row: dict[str, Any]) -> ClassifiedResult | None:
    """A stored row back into the domain. Rows with no number are not results."""
    code = row.get("biomarker_code")
    raw_value = row.get("value")
    if not code or raw_value is None:
        return None
    try:
        value = Decimal(str(raw_value))
    except (InvalidOperation, ValueError):
        return None
    status_raw = row.get("status")
    status = (
        ResultStatus(status_raw)
        if isinstance(status_raw, str) and status_raw in set(ResultStatus)
        else ResultStatus.UNKNOWN
    )
    return ClassifiedResult(
        biomarker_code=str(code),
        display_name=str(code),
        value=value,
        unit=str(row.get("unit") or ""),
        status=status,
        printed_range=row.get("printed_range"),
        measured_on=parse_date(row.get("measured_on")),
        needs_review=bool(row.get("needs_review", False)),
    )

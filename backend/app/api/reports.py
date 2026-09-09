"""Upload a report, watch it being read, and see what came out of it.

The upload endpoint is the one place a file enters the system. It enforces the size cap
**while reading**, checks the bytes against the declared type, hashes, and refuses to
extract a file this user has already sent us.
"""

from __future__ import annotations

from datetime import date
from typing import Annotated, Any

from fastapi import APIRouter, Depends, File, UploadFile
from pydantic import BaseModel, Field

from app.api.deps import (
    CurrentUser,
    get_ingest,
    get_profiles,
    get_reports,
    get_settings_dep,
    require_consent,
)
from app.api.guarded import GuardedText, guarded_deterministic
from app.core.config import Settings
from app.core.errors import NotFound, PayloadTooLarge
from app.domain.enums import Escalation, ReportStatus, ResultStatus
from app.ingest.files import validate_upload
from app.ingest.pipeline import IngestResult, IngestService, ReviewItem
from app.repositories.profiles import ProfileRepository
from app.repositories.reports import ReportRepository

router = APIRouter(prefix="/v1/reports", tags=["reports"])

Reports = Annotated[ReportRepository, Depends(get_reports)]
Ingest = Annotated[IngestService, Depends(get_ingest)]
Profiles = Annotated[ProfileRepository, Depends(get_profiles)]

#: Read the upload in chunks so a huge file is rejected before it is all in memory.
_CHUNK = 256 * 1024


class ReportSummary(BaseModel):
    id: str
    status: ReportStatus
    mime_type: str | None = None
    report_type: str | None = None
    lab_name: str | None = None
    collected_on: date | None = None
    created_at: str | None = None
    file_hash: str


class UploadAccepted(BaseModel):
    report: ReportSummary
    duplicate: bool = Field(
        description="True when we already had this exact file and did not read it again."
    )


class ResultOut(BaseModel):
    biomarker_code: str
    display_name: str
    value: str
    unit: str
    status: ResultStatus
    printed_range: str | None = None
    measured_on: date | None = None
    needs_review: bool = False


class ReviewOut(BaseModel):
    printed_test_name: str
    value_text: str
    unit_text: str | None = None
    #: Written by app.rules, not by a model, and scanned anyway before it is returned.
    reason: GuardedText
    suggested_biomarker: str | None = None


class RedFlagOut(BaseModel):
    code: str
    escalation: Escalation
    #: Deterministic text from app.rules.red_flags.
    message: GuardedText
    biomarker_code: str | None = None


class ReportDetail(BaseModel):
    report: ReportSummary
    results: list[ResultOut] = Field(default_factory=list)
    red_flags: list[RedFlagOut] = Field(default_factory=list)
    review: list[ReviewOut] = Field(default_factory=list)
    escalation: Escalation = Escalation.ROUTINE
    reused_extraction: bool = False


class ReportList(BaseModel):
    reports: list[ReportSummary] = Field(default_factory=list)


class ConfirmIn(BaseModel):
    confirmed: bool = True


@router.post(
    "",
    response_model=ReportDetail,
    status_code=201,
    dependencies=[Depends(require_consent)],
    summary="Upload a report",
)
async def upload_report(
    principal: CurrentUser,
    ingest: Ingest,
    profiles: Profiles,
    file: Annotated[UploadFile, File(description="PDF, JPEG, PNG or HEIC, up to 20 MB")],
    settings: Settings = Depends(get_settings_dep),
) -> ReportDetail:
    """Stages 1-5, synchronously.

    A duplicate is answered from the stored extraction with no model call at all, which
    is what keeps this inside the free tier (docs/04-ai-pipeline.md).
    """
    data = await _read_capped(file, settings.max_upload_bytes)
    upload = validate_upload(
        data=data,
        declared_type=file.content_type,
        filename=file.filename or "report",
        max_bytes=settings.max_upload_bytes,
        allowed=settings.allowed_upload_mime,
    )
    outcome = await ingest.store(upload)
    profile = await profiles.health_profile()
    result = await ingest.process(outcome.report, profile)
    return _detail(outcome.report, result)


@router.get("", response_model=ReportList, summary="My reports")
async def list_reports(reports: Reports, limit: int = 50, offset: int = 0) -> ReportList:
    rows = await reports.list(limit=min(max(limit, 1), 100), offset=max(offset, 0))
    return ReportList(reports=[_summary(row) for row in rows])


@router.get("/{report_id}/status", summary="Extraction status")
async def report_status(report_id: str, reports: Reports) -> dict[str, Any]:
    """Cheap polling target. Returns the status and nothing that costs a query."""
    row = await reports.by_id(report_id)
    if row is None:
        raise NotFound("That report does not exist, or is not yours.")
    return {"id": str(row.get("id")), "status": str(row.get("status"))}


@router.get("/{report_id}", response_model=ReportDetail, summary="One report")
async def report_detail(
    report_id: str, reports: Reports, ingest: Ingest, profiles: Profiles
) -> ReportDetail:
    row = await reports.by_id(report_id)
    if row is None:
        raise NotFound("That report does not exist, or is not yours.")

    stored = await reports.results_for(report_id)
    results = [_result_out(r) for r in stored]
    review = await ingest.review_queue(report_id)
    return ReportDetail(
        report=_summary(row),
        results=results,
        review=[_review_out(item) for item in review],
        escalation=Escalation.ROUTINE,
        reused_extraction=True,
    )


@router.get("/{report_id}/review", summary="Rows that need confirming")
async def report_review(report_id: str, reports: Reports, ingest: Ingest) -> list[ReviewOut]:
    if await reports.by_id(report_id) is None:
        raise NotFound("That report does not exist, or is not yours.")
    return [_review_out(item) for item in await ingest.review_queue(report_id)]


@router.post("/{report_id}/results/{result_id}/confirm", summary="Confirm a value")
async def confirm_result(
    report_id: str, result_id: str, payload: ConfirmIn, reports: Reports
) -> dict[str, Any]:
    """The user answering "yes, that is Ferritin". We never answer it for them."""
    if await reports.by_id(report_id) is None:
        raise NotFound("That report does not exist, or is not yours.")
    rows = await reports.confirm_result(result_id, confirmed=payload.confirmed)
    if not rows:
        raise NotFound("That result does not exist, or is not yours.")
    return {"id": result_id, "confirmed_by_user": payload.confirmed}


# --------------------------------------------------------------------------- helpers


async def _read_capped(file: UploadFile, limit: int) -> bytes:
    """Read at most ``limit`` bytes, then one more to prove there was no more."""
    chunks: list[bytes] = []
    total = 0
    while True:
        chunk = await file.read(_CHUNK)
        if not chunk:
            break
        total += len(chunk)
        if total > limit:
            raise PayloadTooLarge(
                f"That file is larger than the {limit / 1_000_000:.0f} MB limit."
            )
        chunks.append(chunk)
    return b"".join(chunks)


def _summary(row: dict[str, Any]) -> ReportSummary:
    status_raw = str(row.get("status") or "uploaded")
    return ReportSummary(
        id=str(row.get("id")),
        status=ReportStatus(status_raw) if status_raw in set(ReportStatus) else ReportStatus.UPLOADED,
        mime_type=row.get("mime_type"),
        report_type=row.get("report_type"),
        lab_name=row.get("lab_name"),
        collected_on=_date(row.get("collected_on")),
        created_at=str(row.get("created_at")) if row.get("created_at") else None,
        file_hash=str(row.get("file_hash") or ""),
    )


def _detail(row: dict[str, Any], result: IngestResult) -> ReportDetail:
    from app.domain.enums import max_escalation

    return ReportDetail(
        report=_summary({**row, "status": result.status.value,
                         "lab_name": result.lab_name or row.get("lab_name"),
                         "report_type": result.report_type or row.get("report_type"),
                         "collected_on": result.collected_on or row.get("collected_on")}),
        results=[
            ResultOut(
                biomarker_code=item.biomarker_code,
                display_name=item.display_name,
                value=str(item.value),
                unit=item.unit,
                status=item.status,
                printed_range=item.printed_range,
                measured_on=item.measured_on,
                needs_review=item.needs_review,
            )
            for item in result.results
        ],
        red_flags=[
            RedFlagOut(
                code=flag.code,
                escalation=flag.escalation,
                message=guarded_deterministic(flag.message, flag.escalation),
                biomarker_code=flag.biomarker_code,
            )
            for flag in result.red_flags
        ],
        review=[_review_out(item) for item in result.review],
        escalation=max_escalation(flag.escalation for flag in result.red_flags),
        reused_extraction=result.reused_extraction,
    )


def _result_out(row: dict[str, Any]) -> ResultOut:
    status_raw = row.get("status")
    return ResultOut(
        biomarker_code=str(row.get("biomarker_code") or ""),
        display_name=str(row.get("biomarker_code") or ""),
        value=str(row.get("value") if row.get("value") is not None else ""),
        unit=str(row.get("unit") or ""),
        status=ResultStatus(status_raw)
        if isinstance(status_raw, str) and status_raw in set(ResultStatus)
        else ResultStatus.UNKNOWN,
        printed_range=row.get("printed_range"),
        measured_on=_date(row.get("measured_on")),
        needs_review=bool(row.get("needs_review", False)),
    )


def _review_out(item: ReviewItem) -> ReviewOut:
    return ReviewOut(
        printed_test_name=item.printed_test_name,
        value_text=item.value_text,
        unit_text=item.unit_text,
        reason=guarded_deterministic(item.reason),
        suggested_biomarker=item.suggested_biomarker,
    )


def _date(value: Any) -> date | None:
    if isinstance(value, date):
        return value
    if isinstance(value, str) and value.strip():
        try:
            return date.fromisoformat(value.strip()[:10])
        except ValueError:
            return None
    return None

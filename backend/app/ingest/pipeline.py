"""Stages 1-5: file in, classified lab results out.

    1. store the file and hash it            -- here, no model
    2. extract                               -- Gemini, schema-constrained
    3. normalise                             -- app.rules.normalise, no model
    4. classify against our own ranges       -- app.rules.classify, no model
    5. red flags                             -- app.rules.red_flags, no model

This module orchestrates. It contains no medical logic of its own: every judgement about
a number comes from :mod:`app.rules`, and the only thing the model is asked for is a
transcription of what is printed on the page.

Two behaviours are worth stating because they are the ones that cost money or trust:

* **A file we have seen before is never extracted again.** The hash lookup happens before
  the upload, and again as a unique-constraint safety net.
* **A row we cannot map is never guessed.** It is surfaced for the user to confirm, with
  the reason in plain English, by re-running the deterministic normaliser over the stored
  extraction -- which costs nothing.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass, field
from datetime import date
from typing import Any

from app.ai.client import GeminiClient, GeminiError, inline_data_part, text_part
from app.ai.prompts import for_task
from app.ai.routing import Task, model_for
from app.ai.schemas import REPORT_EXTRACTION_SCHEMA
from app.core.errors import UpstreamUnavailable
from app.core.logging import get_logger
from app.domain.enums import ReportStatus
from app.domain.models import (
    ClassifiedResult,
    ExtractedReport,
    ExtractedRow,
    HealthProfile,
    RedFlag,
)
from app.ingest.files import ValidatedUpload
from app.repositories.audit import AuditRepository
from app.repositories.base import StorageClient
from app.repositories.reference import ReferenceRepository
from app.repositories.reports import ReportRepository, result_from_row, result_to_row
from app.rules import classify as classify_rules
from app.rules import normalise as normalise_rules
from app.rules import red_flags as red_flag_rules

log = get_logger("app.ingest")

_EXTRACT_INSTRUCTION = (
    "Transcribe every result row printed on this report. Copy the test names, values, "
    "units and printed ranges exactly as they appear. Do not interpret, do not convert, "
    "do not add anything that is not printed."
)


@dataclass(frozen=True)
class ReviewItem:
    """A row we will not interpret without the user confirming it."""

    printed_test_name: str
    value_text: str
    unit_text: str | None
    reason: str
    suggested_biomarker: str | None = None


@dataclass
class IngestResult:
    """Everything stage 5 produced for one report."""

    report_id: str
    status: ReportStatus
    lab_name: str | None = None
    collected_on: date | None = None
    report_type: str | None = None
    results: list[ClassifiedResult] = field(default_factory=list)
    red_flags: list[RedFlag] = field(default_factory=list)
    review: list[ReviewItem] = field(default_factory=list)
    reused_extraction: bool = False
    model: str = ""


@dataclass
class UploadOutcome:
    """The result of stage 1."""

    report: dict[str, Any]
    duplicate: bool


class IngestService:
    """Stages 1-5 for one signed-in user."""

    def __init__(
        self,
        *,
        reports: ReportRepository,
        reference: ReferenceRepository,
        storage: StorageClient,
        audit: AuditRepository,
        user_id: str,
        gemini: GeminiClient | None = None,
    ) -> None:
        self.reports = reports
        self.reference = reference
        self.storage = storage
        self.audit = audit
        self.user_id = user_id
        self.gemini = gemini

    # -- stage 1 -----------------------------------------------------------

    def object_path(self, extension: str) -> str:
        """``<user id>/<random>.<ext>`` -- the convention db/policies/101_storage.sql
        enforces. The first segment must be the owner's id or storage refuses the write.
        The name is random rather than the report id because the row does not exist yet.
        """
        return f"{self.user_id}/{uuid.uuid4().hex}.{extension}"

    async def store(self, upload: ValidatedUpload) -> UploadOutcome:
        """Store the file, or recognise that we already have it."""
        existing = await self.reports.by_hash(upload.file_hash)
        if existing is not None:
            log.info("upload deduplicated", report_id=str(existing.get("id")))
            return UploadOutcome(report=existing, duplicate=True)

        path = self.object_path(upload.extension)
        await self.storage.upload(path, upload.data, content_type=upload.mime_type)
        try:
            report = await self.reports.create(
                storage_path=path,
                file_hash=upload.file_hash,
                mime_type=upload.mime_type,
            )
        except Exception:
            # The unique index on (user_id, file_hash) is the real dedupe guarantee; the
            # lookup above only avoids the upload in the common case. If we lost the race,
            # remove the object we just wrote rather than leaving it orphaned.
            duplicate = await self.reports.by_hash(upload.file_hash)
            if duplicate is not None:
                await self._discard(path)
                return UploadOutcome(report=duplicate, duplicate=True)
            await self._discard(path)
            raise
        await self.audit.event("report_uploaded", {"report_id": str(report.get("id"))})
        return UploadOutcome(report=report, duplicate=False)

    async def _discard(self, path: str) -> None:
        try:
            await self.storage.remove([path])
        except Exception:
            log.warning("could not remove an orphaned upload")

    # -- stages 2-5 --------------------------------------------------------

    async def process(self, report: dict[str, Any], profile: HealthProfile) -> IngestResult:
        """Extract if we must, then run the deterministic stages and persist."""
        report_id = str(report.get("id"))
        stored = await self.reports.extraction_for(report_id)
        model_name = str(stored.get("model")) if stored else ""

        if stored is not None and isinstance(stored.get("raw_json"), dict):
            payload = dict(stored["raw_json"])
            reused = True
        else:
            payload, model_name = await self._extract(report)
            reused = False

        extracted = parse_extraction(payload)
        result = await self._interpret(report_id, extracted, profile)
        result.reused_extraction = reused
        result.model = model_name

        if not reused:
            await self.reports.save_results(
                report_id, [result_to_row(item) for item in result.results]
            )
        await self.reports.set_status(
            report_id,
            ReportStatus.EXTRACTED,
            lab_name=extracted.lab_name,
            collected_on=extracted.collected_on,
            report_type=extracted.report_type,
        )
        result.status = ReportStatus.EXTRACTED
        await self.audit.event(
            "report_extracted",
            {
                "report_id": report_id,
                "result_count": len(result.results),
                "review_count": len(result.review),
                "red_flag_count": len(result.red_flags),
                "reused_extraction": reused,
            },
        )
        return result

    async def _extract(self, report: dict[str, Any]) -> tuple[dict[str, Any], str]:
        """Stage 2. The only model call in this module."""
        report_id = str(report.get("id"))
        if self.gemini is None:
            raise UpstreamUnavailable("Report reading is not configured on this server.")

        await self.reports.set_status(report_id, ReportStatus.EXTRACTING)
        path = str(report.get("storage_path") or "")
        mime = str(report.get("mime_type") or "application/pdf")
        data = await self.storage.download(path)
        model = model_for(Task.EXTRACT_REPORT)
        try:
            payload, run = await self.gemini.generate_json(
                model=model,
                parts=[inline_data_part(data, mime), text_part(_EXTRACT_INSTRUCTION)],
                task=Task.EXTRACT_REPORT.value,
                system_instruction=for_task(Task.EXTRACT_REPORT.value),
                response_schema=REPORT_EXTRACTION_SCHEMA,
                temperature=0.0,
            )
        except GeminiError as exc:
            await self.reports.set_status(report_id, ReportStatus.FAILED)
            log.warning("extraction failed", error_type=type(exc).__name__)
            raise UpstreamUnavailable(
                "We could not read that report just now. Your file is saved -- please try "
                "again in a few minutes."
            ) from None

        await self.audit.ai_run(run)
        if not isinstance(payload, dict):
            await self.reports.set_status(report_id, ReportStatus.FAILED)
            raise UpstreamUnavailable("That report did not come back in a form we could use.")

        await self.reports.save_extraction(
            report_id=report_id,
            model=model,
            raw_json=payload,
            tokens_in=run.prompt_tokens,
            tokens_out=run.output_tokens,
        )
        return payload, model

    async def _interpret(
        self, report_id: str, extracted: ExtractedReport, profile: HealthProfile
    ) -> IngestResult:
        """Stages 3-5, all deterministic."""
        rows = normalise_rules.normalise_rows(extracted.rows)

        candidates: list[ClassifiedResult] = []
        review: list[ReviewItem] = []
        for row in rows:
            candidate = normalise_rules.to_candidate(row, extracted.collected_on)
            if candidate is None:
                review.append(
                    ReviewItem(
                        printed_test_name=row.source.printed_test_name,
                        value_text=row.source.value_text,
                        unit_text=row.source.unit_text,
                        reason=row.review_reason or "We could not read this line.",
                        suggested_biomarker=row.biomarker_code,
                    )
                )
                continue
            candidates.append(candidate)

        codes = sorted({c.biomarker_code for c in candidates})
        ranges = await self.reference.reference_ranges(codes)

        results: list[ClassifiedResult] = []
        for candidate in candidates:
            selection = classify_rules.select_range_for_profile(
                ranges,
                biomarker_code=candidate.biomarker_code,
                profile=profile,
                on=candidate.measured_on,
            )
            classified = classify_rules.classify_result(candidate, selection.reference)
            results.append(classified)
            if classified.needs_review:
                review.append(
                    ReviewItem(
                        printed_test_name=classified.display_name,
                        value_text=f"{classified.value} {classified.unit}".strip(),
                        unit_text=classified.unit or None,
                        reason=classified.review_reason or "Please confirm this value.",
                        suggested_biomarker=classified.biomarker_code,
                    )
                )

        history_rows = await self.reports.history(codes or None)
        history = [
            item
            for item in (result_from_row(row) for row in history_rows)
            if item is not None
        ]
        flags = red_flag_rules.evaluate(results, history)

        return IngestResult(
            report_id=report_id,
            status=ReportStatus.EXTRACTING,
            lab_name=extracted.lab_name,
            collected_on=extracted.collected_on,
            report_type=extracted.report_type,
            results=results,
            red_flags=flags,
            review=review,
        )

    # -- review ------------------------------------------------------------

    async def review_queue(self, report_id: str) -> list[ReviewItem]:
        """Rows needing confirmation, rebuilt from the stored extraction.

        Deterministic and free: the normaliser is pure, so re-running it over
        ``report_extractions.raw_json`` reproduces exactly what the ingest run decided,
        including the printed name and the reason -- neither of which ``lab_results`` has
        a column for.
        """
        stored = await self.reports.extraction_for(report_id)
        if stored is None or not isinstance(stored.get("raw_json"), dict):
            return []
        extracted = parse_extraction(dict(stored["raw_json"]))
        items: list[ReviewItem] = []
        for row in normalise_rules.normalise_rows(extracted.rows):
            if not row.needs_review:
                continue
            items.append(
                ReviewItem(
                    printed_test_name=row.source.printed_test_name,
                    value_text=row.source.value_text,
                    unit_text=row.source.unit_text,
                    reason=row.review_reason or "Please confirm this line.",
                    suggested_biomarker=row.biomarker_code,
                )
            )
        return items


# ------------------------------------------------------------------------ parsing


def parse_extraction(payload: dict[str, Any]) -> ExtractedReport:
    """Model JSON -> :class:`ExtractedReport`, dropping rows we cannot even shape.

    Controlled generation makes malformed output unlikely, not impossible. A row that
    will not validate is dropped rather than repaired: a half-read health value is worse
    than a missing one, and the user still sees the original file.
    """
    rows: list[ExtractedRow] = []
    for raw in payload.get("rows") or []:
        if not isinstance(raw, dict):
            continue
        name = str(raw.get("printed_test_name") or "").strip()
        value = str(raw.get("value_text") or "").strip()
        if not name or not value:
            continue
        try:
            confidence = float(raw.get("confidence", 1.0))
        except (TypeError, ValueError):
            confidence = 0.0
        rows.append(
            ExtractedRow(
                printed_test_name=name,
                value_text=value,
                unit_text=_str_or_none(raw.get("unit_text")),
                printed_range=_str_or_none(raw.get("printed_range")),
                method=_str_or_none(raw.get("method")),
                confidence=max(0.0, min(1.0, confidence)),
            )
        )

    collected = raw_date(payload.get("collected_on"))
    return ExtractedReport(
        lab_name=_str_or_none(payload.get("lab_name")),
        collected_on=collected,
        report_type=_str_or_none(payload.get("report_type")),
        rows=rows,
    )


def _str_or_none(value: Any) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    return text or None


def raw_date(value: Any) -> date | None:
    if isinstance(value, date):
        return value
    if isinstance(value, str) and value.strip():
        try:
            return date.fromisoformat(value.strip()[:10])
        except ValueError:
            return None
    return None

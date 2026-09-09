"""Export my data, and delete all my health data.

The deletion endpoint is the one CLAUDE.md singles out: *"Delete all my health data" must
actually delete it, including files in storage.* It removes every user-owned row, every
storage object under the user's folder, and writes a receipt into ``deletion_requests``
saying how many of each. :mod:`app.repositories.privacy` documents which steps need the
service role and why.

Deletion is irreversible, so it requires an explicit confirmation phrase in the body. A
stray DELETE from a half-written client must not empty someone's medical history.
"""

from __future__ import annotations

from typing import Annotated, Any

from fastapi import APIRouter, Depends
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field

from app.api.deps import CurrentUser, get_audit, get_deletion, get_export
from app.core.errors import ValidationFailed
from app.core.logging import get_logger
from app.repositories.audit import AuditRepository
from app.repositories.privacy import DeletionRepository, ExportRepository

log = get_logger("app.api.privacy")

router = APIRouter(prefix="/v1/privacy", tags=["privacy"])

Export = Annotated[ExportRepository, Depends(get_export)]
Deletion = Annotated[DeletionRepository, Depends(get_deletion)]
Audit = Annotated[AuditRepository, Depends(get_audit)]

#: Typed by the user in the app, word for word, before we will do this.
CONFIRMATION_PHRASE = "DELETE MY HEALTH DATA"


class DeleteIn(BaseModel):
    model_config = ConfigDict(extra="forbid")

    confirm: str = Field(description=f"Must be exactly: {CONFIRMATION_PHRASE}")


class DeleteReceiptOut(BaseModel):
    request_id: str
    rows_deleted: int
    objects_deleted: int
    tables: dict[str, int] = Field(default_factory=dict)
    completed_at: str | None = None
    #: A fixed sentence, written here, never by a model.
    confirmation: str = (
        "Your health data has been deleted, including the report files. This receipt is "
        "the only record kept, and it holds no health information."
    )


@router.get("/export", summary="Export everything we hold about me")
async def export_my_data(export: Export, audit: Audit) -> JSONResponse:
    """Everything, read with the caller's own token, as one JSON document."""
    data: dict[str, Any] = await export.export()
    await audit.event("data_exported", {"table_count": len(data.get("tables", {}))})
    return JSONResponse(
        content=data,
        headers={
            "Content-Disposition": 'attachment; filename="healthpulse-export.json"',
            "Cache-Control": "no-store",
        },
    )


@router.post(
    "/delete",
    response_model=DeleteReceiptOut,
    summary="Delete all my health data",
)
async def delete_my_data(
    payload: DeleteIn, principal: CurrentUser, deletion: Deletion
) -> DeleteReceiptOut:
    if payload.confirm.strip() != CONFIRMATION_PHRASE:
        raise ValidationFailed(
            f'To delete everything, send the words "{CONFIRMATION_PHRASE}" exactly.'
        )
    receipt = await deletion.run()
    # Deliberately not written to health_events: that table has just been emptied, and
    # writing a fresh row into it would leave a trace of a user who asked to be forgotten.
    # The receipt in deletion_requests is the record, and it holds no health data.
    log.info(
        "user data deleted",
        rows_deleted=receipt.rows_deleted,
        objects_deleted=receipt.objects_deleted,
    )
    return DeleteReceiptOut(
        request_id=receipt.request_id,
        rows_deleted=receipt.rows_deleted,
        objects_deleted=receipt.objects_deleted,
        tables=receipt.tables,
        completed_at=receipt.completed_at.isoformat() if receipt.completed_at else None,
    )

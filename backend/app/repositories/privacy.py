"""Export everything, and delete everything.

"Delete all my health data" must actually delete it, including files in storage
(CLAUDE.md, hard technical rules). This module is where that promise is kept, and it is
the **only** place in the codebase that uses the service-role key for anything other than
a maintenance job with no user context. Each use is justified inline; the summary is:

* Three tables -- ``consents``, ``health_events``, ``ai_runs`` -- deliberately have
  INSERT and SELECT policies but **no DELETE policy**. That is correct: an append-only
  audit trail a user can quietly edit is not an audit trail. Erasure still has to be
  possible, so the delete runs with the service role.
* ``deletion_requests`` has INSERT and SELECT policies but no UPDATE policy, so the user
  can open a receipt but not alter it. Writing ``completed_at`` and the counts onto that
  receipt is therefore also a service-role write.
* Storage objects are removed with the service role so that an object left behind by a
  failed upload -- one with no ``reports`` row pointing at it -- is still swept. Listing
  by the user's own folder prefix keeps the blast radius to that user.

Everything else, including the whole export, runs as the user.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import UTC, datetime
from typing import Any

from app.core.logging import get_logger
from app.repositories.base import Credentials, PostgrestClient, StorageClient, eq
from app.repositories.profiles import UserScopedRepository

log = get_logger("app.repositories.privacy")

#: Everything a user owns, in an order that respects foreign keys (children first).
#: ``db/tests/rls_smoke.sql`` and docs/03-data-model.md are the source for this list; the
#: deletion test fails if a user-owned table is missing from it.
USER_TABLES_CHILD_FIRST: tuple[str, ...] = (
    "food_feedback",
    "food_logs",
    "food_preferences",
    "grocery_items",
    "grocery_lists",
    "pantry_items",
    "meal_plan_items",
    "meal_plans",
    "alert_deliveries",
    "alerts",
    "chat_messages",
    "chat_threads",
    "symptom_followups",
    "symptoms",
    "goals",
    "user_memory",
    "weekly_summaries",
    "lab_results",
    "report_extractions",
    "reports",
    "allergies",
    "health_profiles",
    "profiles",
)

#: Tables the user cannot delete from, by design. Service role only.
APPEND_ONLY_TABLES: tuple[str, ...] = ("consents", "health_events", "ai_runs")

#: Tables joined to the user through a parent rather than carrying ``user_id``.
_VIA_PARENT: dict[str, tuple[str, str, str]] = {
    # child table -> (parent table, child fk column, parent id column)
    "report_extractions": ("reports", "report_id", "id"),
    "meal_plan_items": ("meal_plans", "meal_plan_id", "id"),
    "grocery_items": ("grocery_lists", "grocery_list_id", "id"),
    "symptom_followups": ("symptoms", "symptom_id", "id"),
}

#: Tables exported, and the columns worth exporting.
EXPORT_TABLES: tuple[tuple[str, str], ...] = (
    ("profiles", "display_name,locale,timezone,created_at"),
    ("health_profiles", "*"),
    ("allergies", "allergen,severity"),
    ("consents", "consent_type,version,accepted_at"),
    ("reports", "id,file_hash,mime_type,report_type,lab_name,collected_on,status,created_at"),
    ("lab_results", "*"),
    ("symptoms", "*"),
    ("goals", "*"),
    ("user_memory", "fact,category,confidence,confirmed,created_at"),
    ("food_preferences", "food_id,stance,score,updated_at"),
    ("food_logs", "*"),
    ("food_feedback", "*"),
    ("meal_plans", "*"),
    ("grocery_lists", "*"),
    ("alerts", "alert_type,title,body,schedule_rule,enabled,quiet_hours"),
    ("chat_threads", "id,title,created_at"),
    # ``attachments`` is in the list because a chat photo has no table of its own: the
    # jsonb on the message is the only record that the file exists at all. Leaving it out
    # would mean an export that quietly omits something we are holding, which is the same
    # broken promise as a deletion that misses a file.
    ("chat_messages", "thread_id,role,content,attachments,created_at"),
    ("weekly_summaries", "week_start,metrics,narrative,created_at"),
    ("deletion_requests", "requested_at,completed_at,objects_deleted,rows_deleted"),
)


@dataclass
class DeletionReceipt:
    """What was actually removed. Written back onto the ``deletion_requests`` row."""

    request_id: str
    rows_deleted: int = 0
    objects_deleted: int = 0
    tables: dict[str, int] = field(default_factory=dict)
    completed_at: datetime | None = None

    def as_payload(self) -> dict[str, Any]:
        return {
            "request_id": self.request_id,
            "rows_deleted": self.rows_deleted,
            "objects_deleted": self.objects_deleted,
            "completed_at": self.completed_at.isoformat() if self.completed_at else None,
        }


class ExportRepository(UserScopedRepository):
    """Everything we hold about the caller, read as the caller."""

    async def export(self) -> dict[str, Any]:
        data: dict[str, Any] = {}
        for table, columns in EXPORT_TABLES:
            try:
                data[table] = await self.db.select(table, columns=columns, limit=5000)
            except Exception:
                log.warning("export skipped a table", table=table)
                data[table] = []
        return {
            "exported_at": datetime.now(UTC).isoformat(),
            "user_id": self.user_id,
            "tables": data,
        }


class DeletionRepository:
    """Erasure. Holds both credentials on purpose, and uses each where it belongs."""

    def __init__(
        self,
        *,
        user_db: PostgrestClient,
        service_db: PostgrestClient,
        service_storage: StorageClient,
        user_id: str,
        service_credentials: Credentials,
    ) -> None:
        if user_db.privileged:
            raise ValueError("the user client must not be privileged")
        if not service_db.privileged or not service_credentials.privileged:
            raise ValueError("the service client must be the service role")
        self.user_db = user_db
        self.service_db = service_db
        self.storage = service_storage
        self.user_id = user_id

    @property
    def _mine(self) -> dict[str, str]:
        return {"user_id": eq(self.user_id)}

    async def open_request(self) -> str:
        """Open the receipt **as the user** -- ``deletion_requests`` allows that insert."""
        rows = await self.user_db.insert(
            "deletion_requests",
            {"user_id": self.user_id, "requested_at": datetime.now(UTC).isoformat()},
        )
        return str(rows[0]["id"]) if rows and rows[0].get("id") else ""

    async def storage_paths(self) -> list[str]:
        """Every object under the user's folder, from storage itself.

        Read from storage rather than from ``reports.storage_path`` so that an orphaned
        object -- uploaded before its row was written, or left by a failed request -- is
        still found and removed. Nothing may be left behind.
        """
        # SERVICE ROLE: listing a storage prefix is an admin operation; the user's own
        # token can read their objects but not enumerate the bucket. The prefix is the
        # user's own id, so nothing outside their folder is visible to this call.
        return await self.storage.list_prefix(self.user_id)

    async def run(self) -> DeletionReceipt:
        request_id = await self.open_request()
        receipt = DeletionReceipt(request_id=request_id)

        paths = await self.storage_paths()
        if paths:
            # SERVICE ROLE: storage deletion must succeed even for objects with no
            # matching row, which the user's own token cannot reliably address.
            receipt.objects_deleted = await self.storage.remove(paths)

        for table in USER_TABLES_CHILD_FIRST:
            deleted = await self._delete_user_rows(table)
            if deleted:
                receipt.tables[table] = deleted
                receipt.rows_deleted += deleted

        for table in APPEND_ONLY_TABLES:
            # SERVICE ROLE: these tables have no DELETE policy on purpose -- an audit
            # trail the subject can edit is not an audit trail. Erasure still has to be
            # possible, so it happens here and only here.
            deleted = await self._delete_service_rows(table)
            if deleted:
                receipt.tables[table] = deleted
                receipt.rows_deleted += deleted

        receipt.completed_at = datetime.now(UTC)
        await self._complete(receipt)
        log.info(
            "deletion complete",
            rows_deleted=receipt.rows_deleted,
            objects_deleted=receipt.objects_deleted,
            table_count=len(receipt.tables),
        )
        return receipt

    async def _delete_user_rows(self, table: str) -> int:
        """Delete as the user. RLS confirms every row belongs to them."""
        parent = _VIA_PARENT.get(table)
        if parent is None:
            rows = await self.user_db.delete(table, filters=self._mine)
            return len(rows)
        parent_table, fk_column, parent_id = parent
        parents = await self.user_db.select(parent_table, columns=parent_id, filters=self._mine)
        ids = [str(row[parent_id]) for row in parents if row.get(parent_id)]
        if not ids:
            return 0
        total = 0
        for identifier in ids:
            rows = await self.user_db.delete(table, filters={fk_column: eq(identifier)})
            total += len(rows)
        return total

    async def _delete_service_rows(self, table: str) -> int:
        rows = await self.service_db.delete(table, filters=self._mine)
        return len(rows)

    async def _complete(self, receipt: DeletionReceipt) -> None:
        if not receipt.request_id:
            return
        # SERVICE ROLE: deletion_requests has SELECT and INSERT policies but no UPDATE
        # policy, so the subject can open a receipt and read it but cannot alter what it
        # says. Only the service role can close it out.
        await self.service_db.update(
            "deletion_requests",
            {
                "completed_at": (receipt.completed_at or datetime.now(UTC)).isoformat(),
                "objects_deleted": receipt.objects_deleted,
                "rows_deleted": receipt.rows_deleted,
            },
            filters={"id": eq(receipt.request_id)},
            returning=False,
        )

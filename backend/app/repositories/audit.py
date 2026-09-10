"""The audit trail: ``health_events`` and ``ai_runs``.

Both tables have INSERT and SELECT policies for ``authenticated``, so both are written
as the user -- no service role needed to record what happened to that user's own data.

``ai_runs`` stores a prompt **hash** and never prompt or answer text
(docs/03-data-model.md, retention). The hash comes from
:class:`app.ai.client.AiRun`, which is built by the transport and already excludes text.
"""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Any

from app.domain.enums import SafetyVerdict
from app.repositories.base import Rows, eq
from app.repositories.profiles import UserScopedRepository


class AuditRepository(UserScopedRepository):
    async def event(self, event_type: str, payload: dict[str, Any] | None = None) -> None:
        await self.db.insert(
            "health_events",
            {
                "user_id": self.user_id,
                "event_type": event_type,
                "payload": payload or {},
                "occurred_at": datetime.now(UTC).isoformat(),
            },
            returning=False,
        )

    async def events(self, event_type: str | None = None, *, limit: int = 100) -> Rows:
        filters = dict(self._mine)
        if event_type:
            filters["event_type"] = eq(event_type)
        return await self.db.select(
            "health_events",
            columns="id,event_type,payload,occurred_at",
            filters=filters,
            order="occurred_at.desc",
            limit=limit,
        )

    async def events_since(
        self, event_type: str, since: datetime, *, limit: int = 500
    ) -> Rows:
        """Events of one type recorded at or after ``since``.

        Anything read back out of this trail for a date range needs this rather than
        ``events(limit=...)``: a plain limit silently truncates a busy week and the caller
        cannot tell a quiet Tuesday from a page boundary.

        ``occurred_at`` is when the row was written, which is never earlier than the day
        the event is about -- nothing in this service accepts a future date -- so a window
        that starts at ``since`` cannot miss a back-dated entry that belongs in it. The
        caller still filters on the date inside the payload, because an entry written
        today may be about a day before the window.
        """
        return await self.db.select(
            "health_events",
            columns="id,event_type,payload,occurred_at",
            filters={
                **self._mine,
                "event_type": eq(event_type),
                "occurred_at": f"gte.{since.isoformat()}",
            },
            order="occurred_at.asc",
            limit=limit,
        )

    async def ai_run(
        self,
        run: Any,
        *,
        verdict: SafetyVerdict | None = None,
        regenerated: bool = False,
    ) -> None:
        """Record one model call. ``run`` is an :class:`app.ai.client.AiRun`."""
        await self.db.insert(
            "ai_runs",
            {
                "user_id": self.user_id,
                "task": getattr(run, "task", "unspecified"),
                "model": getattr(run, "model", ""),
                "prompt_hash": getattr(run, "prompt_sha256", ""),
                "tokens_in": int(getattr(run, "prompt_tokens", 0) or 0),
                "tokens_out": int(getattr(run, "output_tokens", 0) or 0),
                "latency_ms": int(getattr(run, "latency_ms", 0) or 0),
                "safety_verdict": verdict.value if verdict else None,
                "regenerated": regenerated,
            },
            returning=False,
        )

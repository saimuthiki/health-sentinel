"""Chat threads and messages."""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Any

from app.repositories.base import Rows, eq
from app.repositories.profiles import UserScopedRepository

MESSAGE_COLUMNS = "id,thread_id,role,content,attachments,created_at"


class ChatRepository(UserScopedRepository):
    """``chat_threads`` + ``chat_messages``.

    RLS on ``chat_messages`` checks both ``user_id`` and thread ownership, so a message
    cannot be planted into someone else's thread even if this code passed a stray id.
    """

    async def threads(self, *, limit: int = 20) -> Rows:
        return await self.db.select(
            "chat_threads",
            columns="id,title,created_at",
            filters=self._mine,
            order="created_at.desc",
            limit=limit,
        )

    async def thread(self, thread_id: str) -> dict[str, Any] | None:
        return await self.db.select_one(
            "chat_threads",
            columns="id,title,created_at",
            filters={**self._mine, "id": eq(thread_id)},
        )

    async def ensure_thread(self, thread_id: str | None, *, title: str = "") -> dict[str, Any]:
        if thread_id:
            found = await self.thread(thread_id)
            if found:
                return found
        rows = await self.db.insert(
            "chat_threads", {"user_id": self.user_id, "title": title[:120] or "Chat"}
        )
        return rows[0] if rows else {}

    async def messages(self, thread_id: str, *, limit: int = 40) -> Rows:
        rows = await self.db.select(
            "chat_messages",
            columns=MESSAGE_COLUMNS,
            filters={**self._mine, "thread_id": eq(thread_id)},
            order="created_at.desc",
            limit=limit,
        )
        return list(reversed(rows))

    async def add_message(
        self,
        *,
        thread_id: str,
        role: str,
        content: str,
        attachments: list[dict[str, Any]] | None = None,
    ) -> dict[str, Any]:
        if role not in ("user", "assistant", "system"):
            raise ValueError("role must be user, assistant or system")
        row = {
            "user_id": self.user_id,
            "thread_id": thread_id,
            "role": role,
            "content": content,
            "attachments": attachments or [],
            "created_at": datetime.now(UTC).isoformat(),
        }
        rows = await self.db.insert("chat_messages", row)
        return rows[0] if rows else row

    async def history_pairs(self, thread_id: str, *, limit: int = 20) -> list[tuple[str, str]]:
        """``(role, content)`` oldest first -- what ``app.ai.context`` summarises."""
        rows = await self.messages(thread_id, limit=limit)
        return [(str(r.get("role") or "user"), str(r.get("content") or "")) for r in rows]

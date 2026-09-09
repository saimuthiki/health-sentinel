"""An in-memory Supabase that behaves like the real one on the point that matters.

The fake enforces Row Level Security the way ``db/policies/100_rls.sql`` does:

* a request made with a user's token sees only rows whose ``user_id`` is that user;
* reference tables are readable by anyone signed in and writable by nobody;
* ``consents``, ``health_events``, ``ai_runs`` and ``deletion_requests`` accept inserts
  and selects from the user but refuse deletes and updates -- which is what forces the
  deletion path to use the service role, and lets a test prove it.

Without that, an API test would pass whether or not the code passed the caller's token
through, which is exactly the bug the design is meant to prevent.
"""

from __future__ import annotations

import asyncio
import itertools
import json
import re
import uuid
from typing import Any

import httpx
import pytest

from app.core.config import load_settings
from app.core.errors import Conflict, PermissionDenied
from app.main import create_app
from app.repositories.base import Credentials
from tests.conftest import SUPABASE_URL, USER_ID, KeyMaterial, make_token

#: Tables everyone signed in may read and nobody may write.
REFERENCE_TABLES: frozenset[str] = frozenset(
    {"foods", "recipes", "recipe_items", "biomarkers", "biomarker_synonyms",
     "reference_ranges", "rda_targets"}
)

#: Insert and select only. No update, no delete, for anyone but the service role.
APPEND_ONLY: frozenset[str] = frozenset(
    {"consents", "health_events", "ai_runs", "deletion_requests"}
)

#: Tables whose ownership is proved through a parent row rather than a ``user_id``.
PARENTED: dict[str, tuple[str, str]] = {
    "report_extractions": ("reports", "report_id"),
    "meal_plan_items": ("meal_plans", "meal_plan_id"),
    "grocery_items": ("grocery_lists", "grocery_list_id"),
    "symptom_followups": ("symptoms", "symptom_id"),
    "recipe_items": ("recipes", "recipe_id"),
}

#: Unique indexes we honour, because the dedupe guarantee depends on one of them.
UNIQUE: dict[str, tuple[str, ...]] = {
    "reports": ("user_id", "file_hash"),
    "meal_plans": ("user_id", "plan_date"),
    "grocery_lists": ("user_id", "week_start"),
    "food_preferences": ("user_id", "food_id"),
    "consents": ("user_id", "consent_type", "version"),
    "profiles": ("user_id",),
    "health_profiles": ("user_id",),
}

_ids = itertools.count(1)


def new_id() -> str:
    return str(uuid.UUID(int=next(_ids)))


class FakeSupabase:
    """The shared store. One per test."""

    def __init__(self) -> None:
        self.tables: dict[str, list[dict[str, Any]]] = {}
        self.storage: dict[str, bytes] = {}
        self.service_role_uses: list[str] = []

    def seed(self, table: str, rows: list[dict[str, Any]]) -> None:
        bucket = self.tables.setdefault(table, [])
        for row in rows:
            bucket.append({"id": new_id(), **row})

    def rows(self, table: str) -> list[dict[str, Any]]:
        return self.tables.setdefault(table, [])


# --------------------------------------------------------------------------- filters


_IN_RE = re.compile(r'^in\.\((.*)\)$', re.S)


def _matches(row: dict[str, Any], column: str, expression: str) -> bool:
    value = row.get(column)
    if expression.startswith("eq."):
        wanted = expression[3:]
        if isinstance(value, bool):
            return str(value).lower() == wanted.lower()
        return str(value) == wanted
    match = _IN_RE.match(expression)
    if match:
        wanted_list = [part.strip().strip('"') for part in match.group(1).split(",")]
        return str(value) in wanted_list
    if expression.startswith("gte."):
        return str(value) >= expression[4:]
    if expression.startswith("lte."):
        return str(value) <= expression[4:]
    raise AssertionError(f"the fake does not implement the filter {expression!r}")


class FakePostgrest:
    """Same surface as :class:`app.repositories.base.PostgrestClient`."""

    def __init__(self, store: FakeSupabase, credentials: Credentials, user_id: str) -> None:
        self.store = store
        self._credentials = credentials
        self.user_id = user_id

    @property
    def privileged(self) -> bool:
        return self._credentials.privileged

    # -- RLS -----------------------------------------------------------

    def _visible(self, table: str) -> list[dict[str, Any]]:
        rows = self.store.rows(table)
        if self.privileged or table in REFERENCE_TABLES:
            return rows
        parent = PARENTED.get(table)
        if parent is not None:
            parent_table, fk = parent
            owned = {
                str(row.get("id"))
                for row in self.store.rows(parent_table)
                if str(row.get("user_id")) == self.user_id
            }
            return [row for row in rows if str(row.get(fk)) in owned]
        return [row for row in rows if str(row.get("user_id")) == self.user_id]

    def _writable(self, table: str) -> bool:
        if self.privileged:
            return True
        return table not in REFERENCE_TABLES

    def _mutable(self, table: str) -> bool:
        """Update and delete. Append-only tables refuse both without the service role."""
        return self.privileged or (table not in APPEND_ONLY and self._writable(table))

    def _select_rows(self, table: str, filters: dict[str, str] | None) -> list[dict[str, Any]]:
        rows = self._visible(table)
        for column, expression in (filters or {}).items():
            rows = [row for row in rows if _matches(row, column, expression)]
        return rows

    # -- verbs ---------------------------------------------------------

    async def select(
        self,
        table: str,
        *,
        columns: str = "*",
        filters: dict[str, str] | None = None,
        order: str | None = None,
        limit: int | None = None,
        offset: int | None = None,
    ) -> list[dict[str, Any]]:
        rows = list(self._select_rows(table, filters))
        if order:
            column, _, direction = order.partition(".")
            rows.sort(key=lambda r: (r.get(column) is None, str(r.get(column) or "")),
                      reverse=direction == "desc")
        if offset:
            rows = rows[offset:]
        if limit is not None:
            rows = rows[:limit]
        return [dict(row) for row in rows]

    async def select_one(
        self, table: str, *, columns: str = "*", filters: dict[str, str] | None = None
    ) -> dict[str, Any] | None:
        rows = await self.select(table, columns=columns, filters=filters, limit=1)
        return rows[0] if rows else None

    async def insert(self, table: str, rows: Any, *, returning: bool = True) -> list[dict[str, Any]]:
        if not self._writable(table):
            raise PermissionDenied()
        payload = rows if isinstance(rows, list) else [rows]
        written: list[dict[str, Any]] = []
        for row in payload:
            if not self.privileged and "user_id" in row and str(row["user_id"]) != self.user_id:
                raise PermissionDenied()
            self._check_unique(table, row)
            stored = {"id": new_id(), **row}
            self.store.rows(table).append(stored)
            written.append(dict(stored))
        return written if returning else []

    def _check_unique(self, table: str, row: dict[str, Any]) -> None:
        columns = UNIQUE.get(table)
        if not columns:
            return
        for existing in self.store.rows(table):
            if all(str(existing.get(c)) == str(row.get(c)) for c in columns):
                raise Conflict("That already exists.")

    async def upsert(
        self, table: str, rows: Any, *, on_conflict: str, returning: bool = True
    ) -> list[dict[str, Any]]:
        if not self._writable(table):
            raise PermissionDenied()
        payload = rows if isinstance(rows, list) else [rows]
        columns = [c.strip() for c in on_conflict.split(",")]
        written: list[dict[str, Any]] = []
        for row in payload:
            existing = next(
                (
                    candidate
                    for candidate in self._visible(table)
                    if all(str(candidate.get(c)) == str(row.get(c)) for c in columns)
                ),
                None,
            )
            if existing is not None:
                existing.update(row)
                written.append(dict(existing))
            else:
                stored = {"id": new_id(), **row}
                self.store.rows(table).append(stored)
                written.append(dict(stored))
        return written if returning else []

    async def update(
        self, table: str, values: dict[str, Any], *, filters: dict[str, str], returning: bool = True
    ) -> list[dict[str, Any]]:
        if not filters:
            raise ValueError("refusing to update a whole table")
        if not self._mutable(table):
            return []
        rows = self._select_rows(table, filters)
        for row in rows:
            row.update(values)
        return [dict(row) for row in rows] if returning else []

    async def delete(
        self, table: str, *, filters: dict[str, str], returning: bool = True
    ) -> list[dict[str, Any]]:
        if not filters:
            raise ValueError("refusing to delete a whole table")
        if not self._mutable(table):
            return []
        rows = self._select_rows(table, filters)
        remaining = [row for row in self.store.rows(table) if row not in rows]
        self.store.tables[table] = remaining
        return [dict(row) for row in rows] if returning else []

    async def count(self, table: str, *, filters: dict[str, str] | None = None) -> int:
        return len(self._select_rows(table, filters))


class FakeStorage:
    def __init__(self, store: FakeSupabase, credentials: Credentials, user_id: str) -> None:
        self.store = store
        self._credentials = credentials
        self.user_id = user_id
        self.bucket = "reports"

    def _allowed(self, path: str) -> bool:
        return self._credentials.privileged or path.split("/")[0] == self.user_id

    async def upload(self, path: str, data: bytes, *, content_type: str, upsert: bool = False) -> str:
        if not self._allowed(path):
            raise PermissionDenied()
        self.store.storage[path] = data
        return path

    async def download(self, path: str) -> bytes:
        if not self._allowed(path):
            raise PermissionDenied()
        return self.store.storage[path]

    async def signed_url(self, path: str, *, expires_in: int = 300) -> str:
        return f"https://storage.test/{path}?token=signed"

    async def list_prefix(self, prefix: str, *, limit: int = 1000) -> list[str]:
        return [name for name in self.store.storage if name.startswith(prefix)]

    async def remove(self, paths: list[str]) -> int:
        removed = 0
        for path in paths:
            if self.store.storage.pop(path, None) is not None:
                removed += 1
        return removed


class FakeGateway:
    """Stands in for :class:`app.repositories.base.SupabaseGateway`."""

    def __init__(self, store: FakeSupabase, settings: Any) -> None:
        self.store = store
        self.settings = settings
        self.acting_user = USER_ID

    def as_user(self, principal: Any) -> Credentials:
        return Credentials(apikey="anon", bearer=principal.token)

    def as_service(self, reason: str) -> Credentials:
        assert reason.strip(), "service-role access requires a written reason"
        self.store.service_role_uses.append(reason)
        return Credentials(apikey="service", bearer="service", privileged=True, reason=reason)

    def rest(self, credentials: Credentials) -> FakePostgrest:
        return FakePostgrest(self.store, credentials, self.acting_user)

    def storage(self, credentials: Credentials) -> FakeStorage:
        return FakeStorage(self.store, credentials, self.acting_user)

    async def aclose(self) -> None:
        return None


class FakeJwks:
    """Serves a fixed JWKS with no network at all."""

    def __init__(self, body: dict[str, Any]) -> None:
        self._keys = {key["kid"]: key for key in body["keys"]}
        self.kids = frozenset(self._keys)

    async def get(self, kid: str) -> dict[str, Any] | None:
        return self._keys.get(kid)

    async def aclose(self) -> None:
        return None


class FakeGemini:
    """Returns whatever the test queued, and records what it was asked."""

    def __init__(self) -> None:
        self.responses: list[Any] = []
        self.calls: list[dict[str, Any]] = []

    def queue(self, payload: Any) -> None:
        self.responses.append(payload)

    async def generate_json(self, **kwargs: Any) -> tuple[Any, Any]:
        self.calls.append(kwargs)
        if not self.responses:
            raise AssertionError("the test did not queue a Gemini response")
        payload = self.responses.pop(0)
        if isinstance(payload, Exception):
            raise payload
        return payload, _Run(kwargs.get("task", "unspecified"), kwargs.get("model", "fake"))

    async def generate(self, **kwargs: Any) -> Any:  # pragma: no cover - unused
        raise NotImplementedError

    async def aclose(self) -> None:
        return None


class _Run:
    def __init__(self, task: str, model: str) -> None:
        self.task = task
        self.model = model
        self.prompt_sha256 = "0" * 64
        self.prompt_tokens = 10
        self.output_tokens = 20
        self.latency_ms = 5


# ------------------------------------------------------------------------- fixtures


@pytest.fixture
def settings():
    return load_settings(
        environment="test",
        supabase_url=SUPABASE_URL,
        supabase_anon_key="sb_publishable_test",
        supabase_service_role_key="sb_secret_test",
        gemini_api_key="AIzaTestKey",
    )


@pytest.fixture
def store() -> FakeSupabase:
    return FakeSupabase()


@pytest.fixture
def gemini() -> FakeGemini:
    return FakeGemini()


@pytest.fixture
def app(settings, store, gemini, jwks_body):
    """The real application, with the outside world replaced.

    Lifespan is not run: it would build real clients. Everything it would have set is
    set here instead, so the routers, dependencies and handlers are entirely real.
    """
    application = create_app(settings)
    application.state.gateway = FakeGateway(store, settings)
    application.state.jwks = FakeJwks(jwks_body)
    application.state.gemini = gemini
    application.state.safety_judge = None
    return application


@pytest.fixture
def token(ec_key: KeyMaterial) -> str:
    return make_token(ec_key)


@pytest.fixture
def auth(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture
def client(app):
    """An httpx client wired straight to the ASGI app. No sockets.

    ``raise_app_exceptions=False`` so an unhandled exception comes back as the response
    the production stack would send -- which is the thing under test whenever we assert
    that a 500 leaks nothing.
    """
    transport = httpx.ASGITransport(app=app, raise_app_exceptions=False)
    return httpx.AsyncClient(transport=transport, base_url="http://testserver")


def run(coro: Any) -> Any:
    return asyncio.run(coro)


async def call(client: httpx.AsyncClient, method: str, url: str, **kwargs: Any) -> httpx.Response:
    # Deliberately not `async with`: the same client is reused across several calls in a
    # test, and ASGITransport holds no connection to close.
    return await client.request(method, url, **kwargs)


def request(client: httpx.AsyncClient, method: str, url: str, **kwargs: Any) -> httpx.Response:
    return run(call(client, method, url, **kwargs))


def consented(store: FakeSupabase, user_id: str = USER_ID) -> None:
    """Give the user the current consent, so analysis endpoints are open."""
    from app.repositories.profiles import CONSENT_TYPES, CURRENT_CONSENT_VERSION

    store.seed(
        "consents",
        [
            {
                "user_id": user_id,
                "consent_type": kind,
                "version": CURRENT_CONSENT_VERSION,
                "accepted_at": "2026-09-01T00:00:00Z",
            }
            for kind in CONSENT_TYPES
        ],
    )


def problem(response: httpx.Response) -> dict[str, Any]:
    assert response.headers["content-type"].startswith("application/problem+json")
    return json.loads(response.content)

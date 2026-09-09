"""Supabase access: PostgREST and Storage, over httpx.

**The security model of this whole layer, in one sentence:** user data is read and
written with the *user's own access token*, so Postgres Row Level Security decides what
is visible, and a bug in a filter here cannot leak another user's row.

That is why :meth:`SupabaseGateway.as_user` is the default and
:meth:`SupabaseGateway.as_service` demands a written reason: the service-role key has
``BYPASSRLS``, so every use of it is a place where our code, not the database, is the
boundary. There are only a handful, each commented at the call site, and each is either
a maintenance job with no user context or a write to a table that has no user-facing
policy (``consents``, ``ai_runs``, ``health_events``, completing a ``deletion_requests``
receipt) -- see :mod:`app.repositories.privacy`.

A repository that reaches for the service role to read user data is a bug. There is a
test that asserts none of the user-data repositories can even be constructed with one.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Literal
from urllib.parse import quote

import httpx

from app.core.config import Settings
from app.core.errors import Conflict, NotFound, PermissionDenied, UpstreamUnavailable
from app.core.logging import get_logger
from app.core.security import Principal

log = get_logger("app.repositories")

Json = dict[str, Any]
Rows = list[Json]

#: PostgREST error codes we translate rather than pass through.
_UNIQUE_VIOLATION = "23505"
_FK_VIOLATION = "23503"


@dataclass(frozen=True)
class Credentials:
    """How one request authenticates to Supabase.

    ``apikey`` is the project key PostgREST requires; ``bearer`` is what decides *who*
    the request runs as. For a user request both the ``apikey`` (publishable) and the
    bearer (the user's access token) are set, and Postgres runs the statement as that
    user.
    """

    apikey: str
    bearer: str
    #: True only for the service-role key. Carried so it can be asserted against.
    privileged: bool = False
    #: Why the service role is being used. Empty for user credentials.
    reason: str = ""

    def headers(self) -> dict[str, str]:
        return {"apikey": self.apikey, "Authorization": f"Bearer {self.bearer}"}

    def __repr__(self) -> str:  # pragma: no cover - trivial
        return f"Credentials(privileged={self.privileged}, reason={self.reason!r})"

    __str__ = __repr__


class SupabaseGateway:
    """Shared HTTP client plus the two ways to authenticate against it."""

    def __init__(self, settings: Settings, client: httpx.AsyncClient | None = None) -> None:
        self.settings = settings
        self._client = client
        self._owns_client = client is None

    def http(self) -> httpx.AsyncClient:
        if self._client is None:
            self._client = httpx.AsyncClient(
                timeout=httpx.Timeout(self.settings.request_timeout_seconds)
            )
            self._owns_client = True
        return self._client

    async def aclose(self) -> None:
        if self._client is not None and self._owns_client:
            await self._client.aclose()
            self._client = None

    # -- credentials -------------------------------------------------------

    def as_user(self, principal: Principal) -> Credentials:
        """Run as the signed-in user. RLS is the enforcement boundary."""
        return Credentials(apikey=self.settings.supabase_anon_key, bearer=principal.token)

    def as_service(self, reason: str) -> Credentials:
        """Run as the service role, bypassing RLS.

        ``reason`` is mandatory and is logged. If you cannot write one sentence saying
        why RLS cannot do this job, use :meth:`as_user` instead.
        """
        if not reason.strip():
            raise ValueError("service-role access requires a written reason")
        log.info("service-role access", reason=reason)
        return Credentials(
            apikey=self.settings.supabase_service_role_key,
            bearer=self.settings.supabase_service_role_key,
            privileged=True,
            reason=reason,
        )

    # -- clients -----------------------------------------------------------

    def rest(self, credentials: Credentials) -> PostgrestClient:
        return PostgrestClient(self.settings.postgrest_url, credentials, self.http())

    def storage(self, credentials: Credentials) -> StorageClient:
        return StorageClient(
            self.settings.storage_url,
            self.settings.supabase_storage_bucket,
            credentials,
            self.http(),
        )


# --------------------------------------------------------------------------- REST


class PostgrestClient:
    """The slice of PostgREST this service uses. Nothing generic, nothing clever."""

    def __init__(
        self, base_url: str, credentials: Credentials, client: httpx.AsyncClient
    ) -> None:
        self._base = base_url.rstrip("/")
        self._credentials = credentials
        self._client = client

    @property
    def privileged(self) -> bool:
        return self._credentials.privileged

    def _url(self, table: str) -> str:
        return f"{self._base}/{quote(table, safe='')}"

    async def _request(
        self,
        method: str,
        table: str,
        *,
        params: dict[str, Any] | None = None,
        json: Any | None = None,
        prefer: str | None = None,
    ) -> httpx.Response:
        headers = self._credentials.headers()
        headers["Accept"] = "application/json"
        if json is not None:
            headers["Content-Type"] = "application/json"
        if prefer:
            headers["Prefer"] = prefer
        try:
            response = await self._client.request(
                method, self._url(table), params=params, json=json, headers=headers
            )
        except httpx.HTTPError as exc:
            log.warning("postgrest transport error", table=table, error_type=type(exc).__name__)
            raise UpstreamUnavailable() from None
        if response.status_code >= 400:
            raise _translate(response, table)
        return response

    # -- verbs -------------------------------------------------------------

    async def select(
        self,
        table: str,
        *,
        columns: str = "*",
        filters: dict[str, str] | None = None,
        order: str | None = None,
        limit: int | None = None,
        offset: int | None = None,
    ) -> Rows:
        params: dict[str, Any] = {"select": columns}
        params.update(filters or {})
        if order:
            params["order"] = order
        if limit is not None:
            params["limit"] = str(limit)
        if offset:
            params["offset"] = str(offset)
        response = await self._request("GET", table, params=params)
        body = response.json()
        return list(body) if isinstance(body, list) else []

    async def select_one(
        self, table: str, *, columns: str = "*", filters: dict[str, str] | None = None
    ) -> Json | None:
        rows = await self.select(table, columns=columns, filters=filters, limit=1)
        return rows[0] if rows else None

    async def insert(self, table: str, rows: Json | Rows, *, returning: bool = True) -> Rows:
        prefer = "return=representation" if returning else "return=minimal"
        response = await self._request("POST", table, json=rows, prefer=prefer)
        return _rows_of(response)

    async def upsert(
        self,
        table: str,
        rows: Json | Rows,
        *,
        on_conflict: str,
        returning: bool = True,
    ) -> Rows:
        prefer = "resolution=merge-duplicates,"
        prefer += "return=representation" if returning else "return=minimal"
        response = await self._request(
            "POST", table, json=rows, params={"on_conflict": on_conflict}, prefer=prefer
        )
        return _rows_of(response)

    async def update(
        self, table: str, values: Json, *, filters: dict[str, str], returning: bool = True
    ) -> Rows:
        if not filters:
            raise ValueError("refusing to update a whole table")
        prefer = "return=representation" if returning else "return=minimal"
        response = await self._request("PATCH", table, json=values, params=filters, prefer=prefer)
        return _rows_of(response)

    async def delete(self, table: str, *, filters: dict[str, str], returning: bool = True) -> Rows:
        if not filters:
            raise ValueError("refusing to delete a whole table")
        prefer = "return=representation" if returning else "return=minimal"
        response = await self._request("DELETE", table, params=filters, prefer=prefer)
        return _rows_of(response)

    async def count(self, table: str, *, filters: dict[str, str] | None = None) -> int:
        params: dict[str, Any] = {"select": "id"}
        params.update(filters or {})
        headers = self._credentials.headers()
        headers["Prefer"] = "count=exact"
        headers["Range"] = "0-0"
        try:
            response = await self._client.get(self._url(table), params=params, headers=headers)
        except httpx.HTTPError:
            raise UpstreamUnavailable() from None
        if response.status_code >= 400:
            raise _translate(response, table)
        content_range = response.headers.get("content-range", "")
        _, _, total = content_range.partition("/")
        try:
            return int(total)
        except ValueError:
            return len(_rows_of(response))


def _rows_of(response: httpx.Response) -> Rows:
    if response.status_code == 204 or not response.content:
        return []
    try:
        body = response.json()
    except ValueError:
        return []
    if isinstance(body, list):
        return list(body)
    if isinstance(body, dict):
        return [body]
    return []


def _translate(response: httpx.Response, table: str) -> Exception:
    """PostgREST failure -> one of our typed errors. The body never reaches the client."""
    code = ""
    try:
        body = response.json()
        if isinstance(body, dict):
            code = str(body.get("code") or "")
    except ValueError:
        body = None
    log.warning("postgrest error", table=table, status=response.status_code, pg_code=code)
    if response.status_code in (401, 403) or code.startswith("42501"):
        # RLS said no. That is the database doing its job; do not second-guess it.
        return PermissionDenied()
    if response.status_code == 404:
        return NotFound()
    if code == _UNIQUE_VIOLATION:
        return Conflict("That already exists.")
    if code == _FK_VIOLATION:
        return Conflict("That refers to something we do not have.")
    if response.status_code >= 500:
        return UpstreamUnavailable()
    return UpstreamUnavailable()


# ------------------------------------------------------------------------ storage


class StorageClient:
    """Supabase Storage, scoped to one bucket.

    Object paths follow ``db/policies/101_storage.sql``: ``<user id>/<report id>.<ext>``.
    The first folder segment is the owner, and the storage policies compare it against
    ``auth.uid()``. With the user's own token, a path outside their folder is refused by
    the database.
    """

    def __init__(
        self,
        base_url: str,
        bucket: str,
        credentials: Credentials,
        client: httpx.AsyncClient,
    ) -> None:
        self._base = base_url.rstrip("/")
        self._bucket = bucket
        self._credentials = credentials
        self._client = client

    @property
    def bucket(self) -> str:
        return self._bucket

    def _object_url(self, path: str) -> str:
        safe = "/".join(quote(part, safe="") for part in path.split("/"))
        return f"{self._base}/object/{self._bucket}/{safe}"

    async def upload(
        self,
        path: str,
        data: bytes,
        *,
        content_type: str,
        upsert: bool = False,
    ) -> str:
        headers = self._credentials.headers()
        headers["Content-Type"] = content_type
        headers["x-upsert"] = "true" if upsert else "false"
        headers["Cache-Control"] = "no-store"
        try:
            response = await self._client.post(
                self._object_url(path), content=data, headers=headers
            )
        except httpx.HTTPError as exc:
            log.warning("storage upload failed", error_type=type(exc).__name__)
            raise UpstreamUnavailable() from None
        if response.status_code == 409 and not upsert:
            raise Conflict("That file is already stored.")
        if response.status_code in (401, 403):
            raise PermissionDenied()
        if response.status_code >= 400:
            log.warning("storage upload rejected", status=response.status_code)
            raise UpstreamUnavailable()
        return path

    async def download(self, path: str) -> bytes:
        try:
            response = await self._client.get(
                self._object_url(path), headers=self._credentials.headers()
            )
        except httpx.HTTPError:
            raise UpstreamUnavailable() from None
        if response.status_code == 404:
            raise NotFound("That file is no longer stored.")
        if response.status_code in (401, 403):
            raise PermissionDenied()
        if response.status_code >= 400:
            raise UpstreamUnavailable()
        return response.content

    async def signed_url(self, path: str, *, expires_in: int = 300) -> str:
        url = f"{self._base}/object/sign/{self._bucket}/{path}"
        headers = self._credentials.headers()
        headers["Content-Type"] = "application/json"
        try:
            response = await self._client.post(
                url, json={"expiresIn": int(expires_in)}, headers=headers
            )
        except httpx.HTTPError:
            raise UpstreamUnavailable() from None
        if response.status_code == 404:
            raise NotFound("That file is no longer stored.")
        if response.status_code >= 400:
            raise UpstreamUnavailable()
        body = response.json()
        signed = body.get("signedURL") or body.get("signedUrl") or ""
        if not signed:
            raise UpstreamUnavailable()
        return f"{self._base}{signed}" if signed.startswith("/") else signed

    async def list_prefix(self, prefix: str, *, limit: int = 1000) -> list[str]:
        """Object names under ``prefix``. Used by the deletion sweep."""
        url = f"{self._base}/object/list/{self._bucket}"
        headers = self._credentials.headers()
        headers["Content-Type"] = "application/json"
        payload = {"prefix": prefix, "limit": limit, "offset": 0}
        try:
            response = await self._client.post(url, json=payload, headers=headers)
        except httpx.HTTPError:
            raise UpstreamUnavailable() from None
        if response.status_code >= 400:
            raise UpstreamUnavailable()
        body = response.json()
        if not isinstance(body, list):
            return []
        names: list[str] = []
        for entry in body:
            if isinstance(entry, dict) and isinstance(entry.get("name"), str):
                names.append(f"{prefix.rstrip('/')}/{entry['name']}" if prefix else entry["name"])
        return names

    async def remove(self, paths: list[str]) -> int:
        """Delete objects. Returns how many the server confirmed."""
        if not paths:
            return 0
        url = f"{self._base}/object/{self._bucket}"
        headers = self._credentials.headers()
        headers["Content-Type"] = "application/json"
        try:
            response = await self._client.request(
                "DELETE", url, json={"prefixes": paths}, headers=headers
            )
        except httpx.HTTPError:
            raise UpstreamUnavailable() from None
        if response.status_code >= 400:
            log.warning("storage delete rejected", status=response.status_code)
            raise UpstreamUnavailable()
        body = response.json()
        return len(body) if isinstance(body, list) else len(paths)


# ------------------------------------------------------------------------ filters


def eq(value: object) -> str:
    return f"eq.{value}"


def in_(values: list[str]) -> str:
    quoted = ",".join(f'"{v}"' for v in values)
    return f"in.({quoted})"


Order = Literal["asc", "desc"]


def desc(column: str) -> str:
    return f"{column}.desc"


def asc(column: str) -> str:
    return f"{column}.asc"

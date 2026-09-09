"""Async Gemini client.

Design rules that are not negotiable:

* The API key travels in the ``X-goog-api-key`` **header**, never in the URL. Keys in
  query strings leak into proxy logs, access logs and error trackers.
* The key is never logged, never put into an exception message and never returned in a
  repr. :func:`redact` scrubs it from anything we emit.
* Every call produces an :class:`AiRun` record with model, token counts and latency, and a
  SHA-256 hash of the prompt -- **never the prompt text**, because the prompt contains the
  user's health data.

The client is transport-only. It knows nothing about health, safety or nutrition.
"""

from __future__ import annotations

import asyncio
import base64
import hashlib
import json
import logging
import os
import random
import time
from collections.abc import Awaitable, Callable, Iterable, Mapping, Sequence
from datetime import UTC, datetime
from email.utils import parsedate_to_datetime
from typing import Any

import httpx
from pydantic import BaseModel, ConfigDict, Field

log = logging.getLogger("app.ai.client")

DEFAULT_BASE_URL = "https://generativelanguage.googleapis.com/v1beta"
API_KEY_ENV = "GEMINI_API_KEY"
API_KEY_HEADER = "X-goog-api-key"

#: HTTP statuses that are worth trying again.
RETRY_STATUSES = frozenset({429, 500, 502, 503, 504})

#: ``finishReason`` values that mean the answer is incomplete.
TRUNCATED_FINISH_REASONS = frozenset({"MAX_TOKENS", "LENGTH"})

#: ``finishReason`` values that mean Google's own filters stopped the answer.
BLOCKED_FINISH_REASONS = frozenset(
    {"SAFETY", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII", "RECITATION", "IMAGE_SAFETY"}
)


# --------------------------------------------------------------------------- errors


class GeminiError(RuntimeError):
    """Base class for every failure of the Gemini transport."""

    def __init__(self, message: str, *, status: int | None = None) -> None:
        super().__init__(redact(message))
        self.status = status


class GeminiRateLimited(GeminiError):
    """429 (or repeated 5xx) after every retry was exhausted."""

    def __init__(self, message: str, *, status: int | None = 429, retry_after: float | None = None) -> None:
        super().__init__(message, status=status)
        self.retry_after = retry_after


class GeminiInvalidResponse(GeminiError):
    """The body was not the shape we require (no candidate, bad JSON, empty text)."""


class GeminiTruncated(GeminiInvalidResponse):
    """``finishReason`` said the answer was cut off, so it must not be used."""


class GeminiSafetyBlocked(GeminiError):
    """Google's own safety filters refused the prompt or the answer."""

    def __init__(self, message: str, *, reason: str | None = None) -> None:
        super().__init__(message)
        self.reason = reason


# ------------------------------------------------------------------------ redaction

_SECRETS: set[str] = set()


def register_secret(value: str | None) -> None:
    """Remember ``value`` so :func:`redact` can scrub it out of logs and errors."""
    if value and len(value) >= 8:
        _SECRETS.add(value)


def redact(text: str) -> str:
    """Replace every registered secret in ``text`` with ``***REDACTED***``."""
    out = text
    for secret in _SECRETS:
        if secret in out:
            out = out.replace(secret, "***REDACTED***")
    return out


class _RedactingFilter(logging.Filter):
    """Belt and braces: scrub secrets from any record on the ``app.ai`` loggers."""

    def filter(self, record: logging.LogRecord) -> bool:  # pragma: no cover - trivial
        if isinstance(record.msg, str):
            record.msg = redact(record.msg)
        if record.args:
            if isinstance(record.args, dict):
                record.args = {k: redact(v) if isinstance(v, str) else v for k, v in record.args.items()}
            elif isinstance(record.args, tuple):
                record.args = tuple(redact(a) if isinstance(a, str) else a for a in record.args)
        return True


log.addFilter(_RedactingFilter())


# ----------------------------------------------------------------------------- parts


def text_part(text: str) -> dict[str, Any]:
    """A plain text part."""
    return {"text": text}


def inline_data_part(data: bytes | str, mime_type: str) -> dict[str, Any]:
    """An ``inline_data`` part: a PDF or an image, base64 encoded.

    ``data`` may already be base64 text (str) or raw bytes.
    """
    if isinstance(data, bytes):
        encoded = base64.b64encode(data).decode("ascii")
    else:
        encoded = data
    return {"inline_data": {"mime_type": mime_type, "data": encoded}}


def file_part(path_bytes: bytes, mime_type: str) -> dict[str, Any]:
    """Alias kept for readability at call sites that hold file bytes."""
    return inline_data_part(path_bytes, mime_type)


# ------------------------------------------------------------------------- AiRun


class AiRun(BaseModel):
    """Audit record for one model call. Written to the ``ai_runs`` table.

    Contains **no prompt text and no output text** -- only a hash, so the audit trail can
    prove which prompt produced which answer without storing health data twice.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    task: str
    model: str
    prompt_sha256: str
    prompt_tokens: int = 0
    output_tokens: int = 0
    total_tokens: int = 0
    latency_ms: int = 0
    attempts: int = 1
    finish_reason: str | None = None
    http_status: int | None = None
    started_at: datetime = Field(default_factory=lambda: datetime.now(UTC))

    @property
    def truncated(self) -> bool:
        return (self.finish_reason or "").upper() in TRUNCATED_FINISH_REASONS


class GeminiResponse(BaseModel):
    """One successful generation plus its audit record."""

    model_config = ConfigDict(frozen=True, extra="forbid")

    text: str
    finish_reason: str | None
    run: AiRun
    raw: dict[str, Any] = Field(default_factory=dict, repr=False)

    def json_payload(self) -> Any:
        """Parse ``text`` as JSON (controlled generation), raising on anything else."""
        try:
            return json.loads(self.text)
        except json.JSONDecodeError as exc:
            raise GeminiInvalidResponse(f"model did not return valid JSON: {exc}") from exc


# ---------------------------------------------------------------------------- hash


def prompt_hash(payload: Mapping[str, Any]) -> str:
    """SHA-256 of the request body, with inline blobs replaced by their own hash.

    Hashing the blob rather than embedding it keeps this cheap for a 4 MB PDF and still
    gives a stable identity for the ``ai_runs`` audit row.
    """

    def scrub(node: Any) -> Any:
        if isinstance(node, dict):
            out: dict[str, Any] = {}
            for key, value in node.items():
                if key in ("inline_data", "inlineData") and isinstance(value, dict):
                    blob = str(value.get("data", ""))
                    out[key] = {
                        "mime_type": value.get("mime_type") or value.get("mimeType"),
                        "sha256": hashlib.sha256(blob.encode("utf-8")).hexdigest(),
                    }
                else:
                    out[key] = scrub(value)
            return out
        if isinstance(node, list):
            return [scrub(item) for item in node]
        return node

    canonical = json.dumps(scrub(dict(payload)), sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def parse_retry_after(value: str | None, *, now: float | None = None) -> float | None:
    """``Retry-After`` as seconds. Accepts both the delta-seconds and HTTP-date forms."""
    if not value:
        return None
    raw = value.strip()
    try:
        return max(0.0, float(raw))
    except ValueError:
        pass
    try:
        when = parsedate_to_datetime(raw)
    except (TypeError, ValueError):
        return None
    if when is None:
        return None
    if when.tzinfo is None:
        when = when.replace(tzinfo=UTC)
    reference = now if now is not None else datetime.now(UTC).timestamp()
    return max(0.0, when.timestamp() - reference)


# --------------------------------------------------------------------------- client


class GeminiClient:
    """Minimal async client for ``models/{model}:generateContent``."""

    def __init__(
        self,
        api_key: str | None = None,
        *,
        base_url: str = DEFAULT_BASE_URL,
        timeout: float = 60.0,
        connect_timeout: float = 10.0,
        max_attempts: int = 4,
        backoff_base: float = 0.5,
        backoff_max: float = 30.0,
        http_client: httpx.AsyncClient | None = None,
        sleep: Callable[[float], Awaitable[None]] = asyncio.sleep,
        jitter: Callable[[], float] = random.random,
    ) -> None:
        key = api_key if api_key is not None else os.environ.get(API_KEY_ENV, "")
        if not key:
            # Deliberately says nothing about any value we might have seen.
            raise GeminiError(f"{API_KEY_ENV} is not set; refusing to call Gemini")
        self._api_key = key
        register_secret(key)
        self.base_url = base_url.rstrip("/")
        self.timeout = httpx.Timeout(timeout, connect=connect_timeout)
        self.max_attempts = max(1, max_attempts)
        self.backoff_base = backoff_base
        self.backoff_max = backoff_max
        self._sleep = sleep
        self._jitter = jitter
        self._client = http_client
        self._owns_client = http_client is None

    # -- lifecycle ---------------------------------------------------------

    def __repr__(self) -> str:  # pragma: no cover - trivial
        return f"<GeminiClient base_url={self.base_url!r} key=***REDACTED***>"

    __str__ = __repr__

    async def __aenter__(self) -> GeminiClient:
        return self

    async def __aexit__(self, *exc: object) -> None:
        await self.aclose()

    async def aclose(self) -> None:
        if self._client is not None and self._owns_client:
            await self._client.aclose()
            self._client = None

    def _http(self) -> httpx.AsyncClient:
        if self._client is None:
            self._client = httpx.AsyncClient(timeout=self.timeout)
            self._owns_client = True
        return self._client

    # -- request building --------------------------------------------------

    @staticmethod
    def build_payload(
        parts: Sequence[Mapping[str, Any]],
        *,
        system_instruction: str | None = None,
        response_schema: Mapping[str, Any] | None = None,
        response_mime_type: str | None = None,
        temperature: float = 0.0,
        max_output_tokens: int | None = None,
        extra_generation_config: Mapping[str, Any] | None = None,
    ) -> dict[str, Any]:
        generation_config: dict[str, Any] = {"temperature": temperature}
        if max_output_tokens is not None:
            generation_config["maxOutputTokens"] = max_output_tokens
        if response_schema is not None:
            # Controlled generation: mime type is mandatory alongside a schema.
            generation_config["responseMimeType"] = response_mime_type or "application/json"
            generation_config["responseSchema"] = dict(response_schema)
        elif response_mime_type is not None:
            generation_config["responseMimeType"] = response_mime_type
        if extra_generation_config:
            generation_config.update(dict(extra_generation_config))

        payload: dict[str, Any] = {
            "contents": [{"role": "user", "parts": [dict(p) for p in parts]}],
            "generationConfig": generation_config,
        }
        if system_instruction:
            payload["systemInstruction"] = {"parts": [{"text": system_instruction}]}
        return payload

    # -- the call ----------------------------------------------------------

    async def generate(
        self,
        *,
        model: str,
        parts: Sequence[Mapping[str, Any]] | str,
        task: str = "unspecified",
        system_instruction: str | None = None,
        response_schema: Mapping[str, Any] | None = None,
        response_mime_type: str | None = None,
        temperature: float = 0.0,
        max_output_tokens: int | None = None,
        allow_truncated: bool = False,
    ) -> GeminiResponse:
        """Call ``generateContent`` and return the text plus an :class:`AiRun`."""
        if isinstance(parts, str):
            parts = [text_part(parts)]
        payload = self.build_payload(
            parts,
            system_instruction=system_instruction,
            response_schema=response_schema,
            response_mime_type=response_mime_type,
            temperature=temperature,
            max_output_tokens=max_output_tokens,
        )
        digest = prompt_hash(payload)
        url = f"{self.base_url}/models/{model}:generateContent"
        headers = {
            API_KEY_HEADER: self._api_key,  # never a query parameter
            "Content-Type": "application/json",
        }

        started = time.monotonic()
        attempts = 0
        last_status: int | None = None
        last_retry_after: float | None = None

        while attempts < self.max_attempts:
            attempts += 1
            try:
                response = await self._http().post(url, json=payload, headers=headers)
            except httpx.TimeoutException as exc:
                if attempts >= self.max_attempts:
                    raise GeminiError(f"gemini request timed out after {attempts} attempts: {exc}") from exc
                await self._backoff(attempts, None)
                continue
            except httpx.HTTPError as exc:
                if attempts >= self.max_attempts:
                    raise GeminiError(f"gemini transport error after {attempts} attempts: {exc}") from exc
                await self._backoff(attempts, None)
                continue

            last_status = response.status_code
            if response.status_code in RETRY_STATUSES:
                last_retry_after = parse_retry_after(response.headers.get("Retry-After"))
                if attempts >= self.max_attempts:
                    break
                log.warning(
                    "gemini retryable status",
                    extra={
                        "gemini_status": response.status_code,
                        "gemini_model": model,
                        "gemini_task": task,
                        "gemini_attempt": attempts,
                        "gemini_prompt_sha256": digest,
                    },
                )
                await self._backoff(attempts, last_retry_after)
                continue

            if response.status_code >= 400:
                raise GeminiError(
                    f"gemini returned {response.status_code}: {_short(response.text)}",
                    status=response.status_code,
                )

            latency_ms = int((time.monotonic() - started) * 1000)
            return self._parse(
                response=response,
                model=model,
                task=task,
                digest=digest,
                attempts=attempts,
                latency_ms=latency_ms,
                allow_truncated=allow_truncated,
            )

        message = f"gemini exhausted {attempts} attempts (last status {last_status})"
        if last_status == 429:
            raise GeminiRateLimited(message, status=last_status, retry_after=last_retry_after)
        raise GeminiError(message, status=last_status)

    async def _backoff(self, attempt: int, retry_after: float | None) -> None:
        if retry_after is not None:
            delay = min(retry_after, self.backoff_max)
        else:
            delay = min(self.backoff_base * (2 ** (attempt - 1)), self.backoff_max)
            delay += self._jitter() * self.backoff_base
        await self._sleep(delay)

    # -- response parsing --------------------------------------------------

    def _parse(
        self,
        *,
        response: httpx.Response,
        model: str,
        task: str,
        digest: str,
        attempts: int,
        latency_ms: int,
        allow_truncated: bool,
    ) -> GeminiResponse:
        try:
            body = response.json()
        except ValueError as exc:
            raise GeminiInvalidResponse(f"gemini returned non-JSON body: {exc}") from exc
        if not isinstance(body, dict):
            raise GeminiInvalidResponse("gemini returned a JSON body that is not an object")

        usage = body.get("usageMetadata") or {}
        candidates = body.get("candidates") or []
        finish_reason = None
        if candidates and isinstance(candidates[0], dict):
            finish_reason = candidates[0].get("finishReason")

        run = AiRun(
            task=task,
            model=model,
            prompt_sha256=digest,
            prompt_tokens=int(usage.get("promptTokenCount") or 0),
            output_tokens=int(usage.get("candidatesTokenCount") or 0),
            total_tokens=int(usage.get("totalTokenCount") or 0),
            latency_ms=latency_ms,
            attempts=attempts,
            finish_reason=finish_reason,
            http_status=response.status_code,
        )
        log.info(
            "gemini call complete",
            extra={
                "gemini_model": run.model,
                "gemini_task": run.task,
                "gemini_prompt_sha256": run.prompt_sha256,
                "gemini_prompt_tokens": run.prompt_tokens,
                "gemini_output_tokens": run.output_tokens,
                "gemini_latency_ms": run.latency_ms,
                "gemini_finish_reason": run.finish_reason,
            },
        )

        block_reason = (body.get("promptFeedback") or {}).get("blockReason")
        if block_reason:
            raise GeminiSafetyBlocked(
                f"gemini blocked the prompt (reason={block_reason})", reason=str(block_reason)
            )
        upper_finish = (finish_reason or "").upper()
        if upper_finish in BLOCKED_FINISH_REASONS:
            raise GeminiSafetyBlocked(
                f"gemini blocked the answer (finishReason={finish_reason})", reason=str(finish_reason)
            )
        if not candidates:
            raise GeminiInvalidResponse("gemini returned no candidates")
        if upper_finish in TRUNCATED_FINISH_REASONS and not allow_truncated:
            raise GeminiTruncated(
                f"gemini answer was truncated (finishReason={finish_reason}); refusing to use a partial answer"
            )

        text = _collect_text(candidates[0])
        if not text.strip():
            raise GeminiInvalidResponse("gemini returned an empty answer")
        return GeminiResponse(text=text, finish_reason=finish_reason, run=run, raw=body)

    async def generate_json(self, **kwargs: Any) -> tuple[Any, AiRun]:
        """:meth:`generate` plus a JSON parse. Returns ``(parsed, run)``."""
        kwargs.setdefault("response_mime_type", "application/json")
        result = await self.generate(**kwargs)
        return result.json_payload(), result.run


def _collect_text(candidate: Mapping[str, Any]) -> str:
    parts: Iterable[Any] = ((candidate.get("content") or {}).get("parts")) or []
    chunks = [str(p.get("text", "")) for p in parts if isinstance(p, dict) and p.get("text")]
    return "".join(chunks)


def _short(text: str, limit: int = 300) -> str:
    flat = " ".join(text.split())
    return flat if len(flat) <= limit else flat[:limit] + "..."

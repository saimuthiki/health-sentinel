"""Structured logging.

JSON in production so Render/Cloud Run can index it; a readable console renderer in
development.

**This module's job is to make it hard to log the wrong thing.** Three defences, applied
to every record from anywhere in the process, including the standard-library loggers
inside ``app.ai`` and ``httpx``:

1. A key denylist -- ``token``, ``authorization``, ``apikey``, ``password``, ``jwt``,
   ``secret``, ``key`` and friends are replaced with ``***``.
2. A content denylist -- ``content``, ``reply``, ``text``, ``narrative``, ``why_text``,
   ``rationale``, ``prompt``, ``raw_json``, ``value_text``: report contents and model
   answers are health data and must not be duplicated into a log aggregator. Only
   lengths and hashes are kept.
3. A value scan -- anything that looks like a JWT or a Supabase/Google key is replaced
   wherever it appears, including inside a longer string, because the surest way to leak
   a token is to interpolate it into a message.

Nothing here can be switched off by a caller. If you need to debug a payload, do it with
a debugger locally, not with a log line in production.
"""

from __future__ import annotations

import logging
import re
import sys
from contextvars import ContextVar
from typing import Any

import structlog

#: Set by the request-id middleware; every log line in that request carries it.
request_id_var: ContextVar[str | None] = ContextVar("request_id", default=None)

REDACTED = "***"

#: Keys whose value is a credential.
SECRET_KEYS: frozenset[str] = frozenset(
    {
        "authorization",
        "api_key",
        "apikey",
        "gemini_api_key",
        "jwt",
        "key",
        "password",
        "secret",
        "service_role_key",
        "supabase_anon_key",
        "supabase_jwt_secret",
        "supabase_service_role_key",
        "token",
        "access_token",
        "refresh_token",
        "bearer",
        "cookie",
        "set-cookie",
    }
)

#: Keys whose value is health data or a model answer. Replaced by a length.
CONTENT_KEYS: frozenset[str] = frozenset(
    {
        "body",
        "content",
        "detail_text",
        "extraction",
        "fact",
        "file_bytes",
        "message",
        "narrative",
        "note",
        "printed_test_name",
        "prompt",
        "raw",
        "raw_json",
        "rationale",
        "reply",
        "report_text",
        "summary",
        "text",
        "value_text",
        "why",
        "why_text",
    }
)

#: A JWT (three base64url segments) or a long opaque key.
_JWT_RE = re.compile(r"\beyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\b")
_BEARER_RE = re.compile(r"(?i)\bbearer\s+[A-Za-z0-9._\-]{8,}")
_GOOGLE_KEY_RE = re.compile(r"\bAIza[0-9A-Za-z_\-]{10,}\b")
_SB_KEY_RE = re.compile(r"\bsb_(?:secret|publishable)_[A-Za-z0-9_\-]{8,}\b")


def scrub_value(value: str) -> str:
    """Replace anything that looks like a credential inside ``value``."""
    out = _BEARER_RE.sub(f"Bearer {REDACTED}", value)
    out = _JWT_RE.sub(REDACTED, out)
    out = _GOOGLE_KEY_RE.sub(REDACTED, out)
    return _SB_KEY_RE.sub(REDACTED, out)


def _scrub(node: Any, depth: int = 0) -> Any:
    if depth > 6:
        return "<deep>"
    if isinstance(node, str):
        return scrub_value(node)
    if isinstance(node, dict):
        return {k: _redact_pair(str(k), v, depth) for k, v in node.items()}
    if isinstance(node, list | tuple):
        return [_scrub(item, depth + 1) for item in node]
    return node


def _redact_pair(key: str, value: Any, depth: int = 0) -> Any:
    lowered = key.lower()
    if lowered in SECRET_KEYS or lowered.endswith("_secret") or lowered.endswith("_token"):
        return REDACTED
    if lowered in CONTENT_KEYS:
        if isinstance(value, str):
            return f"<{len(value)} chars withheld>"
        return "<withheld>"
    return _scrub(value, depth + 1)


def redaction_processor(
    _logger: Any, _name: str, event_dict: dict[str, Any]
) -> dict[str, Any]:
    """structlog processor: redact secrets and health content in every record."""
    return {key: _redact_pair(str(key), value) for key, value in event_dict.items()}


def request_id_processor(
    _logger: Any, _name: str, event_dict: dict[str, Any]
) -> dict[str, Any]:
    rid = request_id_var.get()
    if rid and "request_id" not in event_dict:
        event_dict["request_id"] = rid
    return event_dict


class _RedactingFilter(logging.Filter):
    """Catch anything logged through the standard library rather than structlog."""

    def filter(self, record: logging.LogRecord) -> bool:
        if isinstance(record.msg, str):
            record.msg = scrub_value(record.msg)
        if isinstance(record.args, tuple):
            record.args = tuple(
                scrub_value(a) if isinstance(a, str) else a for a in record.args
            )
        elif isinstance(record.args, dict):
            record.args = {
                k: (REDACTED if str(k).lower() in SECRET_KEYS else _scrub(v))
                for k, v in record.args.items()
            }
        return True


def configure_logging(*, level: str = "INFO", json_logs: bool = True) -> None:
    """Configure structlog and the root standard-library logger. Idempotent."""
    renderer: Any = (
        structlog.processors.JSONRenderer()
        if json_logs
        else structlog.dev.ConsoleRenderer(colors=False)
    )
    structlog.configure(
        processors=[
            structlog.contextvars.merge_contextvars,
            structlog.stdlib.add_log_level,
            structlog.stdlib.add_logger_name,
            structlog.processors.TimeStamper(fmt="iso", utc=True),
            request_id_processor,
            redaction_processor,
            structlog.processors.StackInfoRenderer(),
            renderer,
        ],
        wrapper_class=structlog.make_filtering_bound_logger(
            logging.getLevelName(level.upper()) if isinstance(level, str) else level
        ),
        logger_factory=structlog.PrintLoggerFactory(file=sys.stdout),
        cache_logger_on_first_use=True,
    )

    root = logging.getLogger()
    root.handlers = [_stdlib_handler()]
    root.setLevel(level.upper())
    for handler in root.handlers:
        handler.addFilter(_RedactingFilter())
    # httpx logs the full request URL at INFO, which for Storage includes an object
    # path. Nothing below WARNING from the HTTP stack.
    for noisy in ("httpx", "httpcore", "hpack"):
        logging.getLogger(noisy).setLevel(logging.WARNING)


def _stdlib_handler() -> logging.Handler:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(logging.Formatter("%(levelname)s %(name)s %(message)s"))
    return handler


def get_logger(name: str) -> Any:
    """A bound structlog logger."""
    return structlog.get_logger(name)

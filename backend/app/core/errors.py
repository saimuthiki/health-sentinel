"""Typed errors and their RFC 9457 ``application/problem+json`` representation.

Every error the API returns is one of these. The rule the whole module exists to keep:
**the body a client receives contains only text we wrote on purpose.** No exception
string, no stack frame, no SQL, no upstream response body, no header value, no file
path. Anything unexpected becomes a fixed 500 problem and the detail goes to the log.

A problem document looks like::

    {"type": "https://healthpulse.app/problems/not-found",
     "title": "Not found",
     "status": 404,
     "detail": "That report does not exist, or is not yours.",
     "instance": "/v1/reports/....",
     "request_id": "01J..."}

``detail`` is written for the person using the app, in the same plain English as the
rest of the product.
"""

from __future__ import annotations

from typing import Any

from fastapi import Request
from fastapi.responses import JSONResponse

PROBLEM_BASE = "https://healthpulse.app/problems"
PROBLEM_MEDIA_TYPE = "application/problem+json"

#: What a 500 says, always, whatever actually happened.
INTERNAL_DETAIL = (
    "Something went wrong on our side. Nothing you sent was lost. Please try again in a "
    "moment."
)


class AppError(Exception):
    """Base class for every error this API returns deliberately."""

    status: int = 500
    code: str = "internal-error"
    title: str = "Internal server error"
    detail: str = INTERNAL_DETAIL
    #: Extra members merged into the problem document. Must never carry internals.
    headers: dict[str, str] | None = None

    def __init__(
        self,
        detail: str | None = None,
        *,
        extra: dict[str, Any] | None = None,
        headers: dict[str, str] | None = None,
    ) -> None:
        super().__init__(detail or self.detail)
        self.detail = detail or self.detail
        self.extra = extra or {}
        if headers:
            self.headers = {**(self.headers or {}), **headers}

    @property
    def type_uri(self) -> str:
        return f"{PROBLEM_BASE}/{self.code}"

    def problem(self, instance: str | None = None, request_id: str | None = None) -> dict[str, Any]:
        body: dict[str, Any] = {
            "type": self.type_uri,
            "title": self.title,
            "status": self.status,
            "detail": self.detail,
        }
        if instance:
            body["instance"] = instance
        if request_id:
            body["request_id"] = request_id
        body.update(self.extra)
        return body


# --------------------------------------------------------------------------- 4xx


class AuthenticationError(AppError):
    status = 401
    code = "not-authenticated"
    title = "Not signed in"
    detail = "Your sign-in could not be verified. Please sign in again."
    headers = {"WWW-Authenticate": "Bearer"}


class PermissionDenied(AppError):
    status = 403
    code = "forbidden"
    title = "Not allowed"
    detail = "You do not have access to that."


class NotFound(AppError):
    status = 404
    code = "not-found"
    title = "Not found"
    detail = "We could not find that."


class Conflict(AppError):
    status = 409
    code = "conflict"
    title = "Conflict"
    detail = "That has already been done."


class ConsentRequired(AppError):
    status = 403
    code = "consent-required"
    title = "Consent required"
    detail = (
        "Please accept the current consent notice before we analyse anything about your "
        "health."
    )


class PayloadTooLarge(AppError):
    status = 413
    code = "payload-too-large"
    title = "File too large"
    detail = "That file is larger than we can accept."


class UnsupportedMedia(AppError):
    status = 415
    code = "unsupported-file-type"
    title = "Unsupported file type"
    detail = "We can read PDF, JPEG, PNG and HEIC files."


class ValidationFailed(AppError):
    status = 422
    code = "invalid-request"
    title = "Invalid request"
    detail = "Some of what you sent was not in a form we could use."


class RateLimited(AppError):
    status = 429
    code = "rate-limited"
    title = "Too many requests"
    detail = "You are going a little fast. Please try again shortly."


# --------------------------------------------------------------------------- 5xx


class UpstreamUnavailable(AppError):
    status = 503
    code = "upstream-unavailable"
    title = "Service temporarily unavailable"
    detail = "A service we depend on is not responding right now. Please try again shortly."


class NotReady(AppError):
    status = 503
    code = "not-ready"
    title = "Not ready"
    detail = "The service is starting up or is not fully configured."


class SafetyBlocked(AppError):
    """The safety layer refused to publish an answer. Not an error the user caused."""

    status = 200  # never returned as a status; see app.api.guarded
    code = "safety-blocked"
    title = "Answer withheld"
    detail = "We could not put that answer together safely."


class UnguardedText(AppError):
    """A user-visible string reached a response without passing the safety layer.

    This is a programming error, not a user error. It is a 500 on purpose: shipping an
    unvalidated model answer is worse than failing the request.
    """

    status = 500
    code = "internal-error"
    title = "Internal server error"
    detail = INTERNAL_DETAIL


# ----------------------------------------------------------------------- rendering


def problem_response(
    request: Request | None,
    error: AppError,
    *,
    request_id: str | None = None,
) -> JSONResponse:
    """Render ``error`` as ``application/problem+json``."""
    instance = str(request.url.path) if request is not None else None
    return JSONResponse(
        status_code=error.status,
        content=error.problem(instance=instance, request_id=request_id),
        media_type=PROBLEM_MEDIA_TYPE,
        headers=error.headers,
    )

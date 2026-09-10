"""The FastAPI application.

Everything that has to be true for *every* request lives here: a request id, structured
logging, CORS, and exception handlers that turn anything at all into an RFC 9457 problem
document with no internals in it.

Startup validates configuration and fails loudly rather than serving a broken instance.
"""

from __future__ import annotations

import uuid
from collections.abc import AsyncIterator, Awaitable, Callable
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError, ResponseValidationError
from fastapi.middleware.cors import CORSMiddleware
from starlette.exceptions import HTTPException as StarletteHTTPException
from starlette.responses import Response

from app.ai.client import GeminiClient, GeminiError
from app.api import (
    activity,
    alerts,
    auth,
    chat,
    feedback,
    grocery,
    health,
    plan,
    privacy,
    recipes,
    reports,
    summary,
)
from app.core.config import ConfigurationError, Settings, get_settings, validate_settings
from app.core.errors import (
    AppError,
    AuthenticationError,
    NotFound,
    ValidationFailed,
    problem_response,
)
from app.core.logging import configure_logging, get_logger, request_id_var
from app.core.security import JwksCache
from app.repositories.base import SupabaseGateway
from app.safety.judge import GeminiSafetyJudge

log = get_logger("app.main")

REQUEST_ID_HEADER = "X-Request-ID"

TITLE = "HealthPulse API"
DESCRIPTION = (
    "HealthPulse is a wellness and nutrition coach, not a doctor. Every user-visible "
    "string a model wrote passes the safety layer before it leaves this service."
)


def create_app(settings: Settings | None = None) -> FastAPI:
    """Build the application. One call, no import-time side effects."""
    settings = validate_settings(settings or get_settings())
    configure_logging(level=settings.log_level, json_logs=settings.is_production)

    app = FastAPI(
        title=TITLE,
        description=DESCRIPTION,
        version="1.0.0",
        lifespan=_lifespan,
        docs_url=None if settings.is_production else "/docs",
        redoc_url=None,
        openapi_url=None if settings.is_production else "/openapi.json",
    )
    app.state.settings = settings

    if settings.cors_origins:
        app.add_middleware(
            CORSMiddleware,
            allow_origins=settings.cors_origins,
            allow_credentials=False,
            allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
            allow_headers=["Authorization", "Content-Type", REQUEST_ID_HEADER],
            expose_headers=[REQUEST_ID_HEADER],
            max_age=600,
        )

    app.middleware("http")(_request_id_middleware)

    app.add_exception_handler(AppError, _app_error_handler)
    app.add_exception_handler(RequestValidationError, _validation_handler)
    app.add_exception_handler(ResponseValidationError, _response_validation_handler)
    app.add_exception_handler(StarletteHTTPException, _http_handler)
    app.add_exception_handler(Exception, _unhandled_handler)

    app.include_router(health.router)
    app.include_router(auth.router)
    app.include_router(reports.router)
    app.include_router(chat.router)
    app.include_router(plan.router)
    app.include_router(feedback.router)
    # Named exercise with an energy estimate. It writes the same movement event
    # feedback.py does, so Today's bar and the weekly read pick these up unchanged.
    app.include_router(activity.router)
    app.include_router(grocery.router)
    app.include_router(alerts.router)
    app.include_router(privacy.router)
    app.include_router(summary.router)
    app.include_router(recipes.router)
    return app


@asynccontextmanager
async def _lifespan(app: FastAPI) -> AsyncIterator[None]:
    settings: Settings = app.state.settings
    app.state.gateway = SupabaseGateway(settings)
    app.state.jwks = JwksCache(settings)
    app.state.gemini = _build_gemini(settings)
    app.state.safety_judge = (
        GeminiSafetyJudge(app.state.gemini) if app.state.gemini is not None else None
    )
    log.info(
        "started",
        environment=settings.environment,
        supabase_configured=settings.has_supabase_config(),
        gemini_configured=settings.has_gemini_config(),
        legacy_hs256_enabled=settings.legacy_hs256_enabled,
    )
    # supabase_configured=False in an info line is easy to read past, and the
    # symptom it causes is opaque: PostgREST answers 401, every endpoint returns
    # 403, and the app tells the person their account cannot open anything. Name
    # the missing variables, loudly, at the only moment anyone is looking.
    if not settings.has_supabase_config():
        missing = [
            name
            for name, value in (
                ("SUPABASE_URL", settings.supabase_url),
                ("SUPABASE_ANON_KEY", settings.supabase_anon_key),
                ("SUPABASE_SERVICE_ROLE_KEY", settings.supabase_service_role_key),
            )
            if not value.strip()
        ]
        log.error(
            "supabase is not configured; every request that touches user data will "
            "fail with 403. Set the missing variables and redeploy.",
            missing=missing,
            readiness="GET /readyz reports this too, with status 503",
        )

    if not settings.has_gemini_config():
        log.error(
            "GEMINI_API_KEY is not set; report analysis and chat will fail.",
            readiness="GET /readyz reports this too, with status 503",
        )

    if settings.legacy_hs256_enabled:
        log.warning(
            "SUPABASE_JWT_SECRET is set, so legacy HS256 access tokens are accepted. "
            "Remove it once every token issued before the key rotation has expired."
        )
    try:
        yield
    finally:
        await app.state.jwks.aclose()
        await app.state.gateway.aclose()
        if app.state.gemini is not None:
            await app.state.gemini.aclose()
        log.info("stopped")


def _build_gemini(settings: Settings) -> GeminiClient | None:
    """A missing key is not a crash: /readyz reports it and the AI routes return 503."""
    if not settings.has_gemini_config():
        log.warning("GEMINI_API_KEY is not set; report reading, chat and planning are off")
        return None
    try:
        return GeminiClient(settings.gemini_api_key)
    except GeminiError:
        log.error("could not build the Gemini client")
        return None


# ------------------------------------------------------------------------ middleware


async def _request_id_middleware(
    request: Request, call_next: Callable[[Request], Awaitable[Response]]
) -> Response:
    """One id per request, echoed in the header, in every log line and in every problem
    document -- so a user can quote it and we can find their request without asking them
    for anything else."""
    incoming = request.headers.get(REQUEST_ID_HEADER, "")
    request_id = incoming.strip()[:64] if incoming.strip() else uuid.uuid4().hex
    token = request_id_var.set(request_id)
    request.state.request_id = request_id
    try:
        response = await call_next(request)
    finally:
        request_id_var.reset(token)
    response.headers[REQUEST_ID_HEADER] = request_id
    return response


# -------------------------------------------------------------------------- handlers


def _request_id_of(request: Request) -> str | None:
    return getattr(request.state, "request_id", None)


async def _app_error_handler(request: Request, exc: Exception) -> Response:
    error = exc if isinstance(exc, AppError) else AppError()
    if error.status >= 500:
        log.error("request failed", error_code=error.code, status=error.status)
    return problem_response(request, error, request_id=_request_id_of(request))


async def _validation_handler(request: Request, exc: Exception) -> Response:
    """FastAPI's validation errors carry the submitted value. Ours do not.

    ``exc.errors()`` includes an ``input`` key holding whatever the client sent, which for
    this API can be a health value or a chat message. Only the field location and the
    rule that failed are returned.
    """
    fields: list[dict[str, str]] = []
    if isinstance(exc, RequestValidationError):
        for error in exc.errors()[:20]:
            location = ".".join(str(part) for part in error.get("loc", ())[1:])
            fields.append({"field": location or "body", "problem": str(error.get("type", ""))})
    return problem_response(
        request,
        ValidationFailed(extra={"errors": fields}),
        request_id=_request_id_of(request),
    )


async def _response_validation_handler(request: Request, exc: Exception) -> Response:
    """A response that will not validate is our bug, and it is fatal to the request.

    This is where the safety mechanism lands: a response model with a ``GuardedText``
    field cannot be built from an unguarded string, so an endpoint that tries to return
    unvalidated model text ends here -- as a 500 with none of that text in it. The
    detail is deliberately the same as any other internal error.
    """
    log.error(
        "response failed validation; nothing was returned to the caller",
        error_type=type(exc).__name__,
        path=request.url.path,
    )
    return problem_response(request, AppError(), request_id=_request_id_of(request))


async def _http_handler(request: Request, exc: Exception) -> Response:
    """Starlette's own 404s and 405s, rendered as problem documents like everything else."""
    status = getattr(exc, "status_code", 500)
    if status == 401:
        error: AppError = AuthenticationError()
    elif status == 404:
        error = NotFound()
    else:
        error = AppError()
        error.status = status
        error.title = "Request could not be completed"
        error.code = f"http-{status}"
        error.detail = _SAFE_HTTP_DETAIL.get(status, error.detail)
    return problem_response(request, error, request_id=_request_id_of(request))


_SAFE_HTTP_DETAIL: dict[int, str] = {
    405: "That address does not accept this kind of request.",
    406: "We cannot produce the format you asked for.",
    415: "We cannot read that kind of file.",
    429: "You are going a little fast. Please try again shortly.",
}


async def _unhandled_handler(request: Request, exc: Exception) -> Response:
    """The last line. The exception is logged by type only; the client learns nothing."""
    log.error("unhandled exception", error_type=type(exc).__name__, exc_info=True)
    return problem_response(request, AppError(), request_id=_request_id_of(request))


def _create_default_app() -> FastAPI:
    """Entry point for ``uvicorn app.main:app``. A configuration error is fatal, loudly."""
    try:
        return create_app()
    except ConfigurationError as exc:
        # SystemExit rather than a traceback: the operator needs the sentence, not a
        # stack. It names every missing variable at once (app.core.config).
        raise SystemExit(str(exc)) from None


def __getattr__(name: str) -> FastAPI:
    """Build the default app only when something actually asks for it.

    ``uvicorn app.main:app`` reaches this; importing the module for ``create_app`` --
    which every test does -- must not, because building the default app reads the
    environment and exits when it is not configured. PEP 562 keeps both true.
    """
    if name == "app":
        application = _create_default_app()
        globals()["app"] = application
        return application
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")

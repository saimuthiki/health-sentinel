"""Liveness and readiness.

Neither endpoint requires authentication, so neither may reveal anything. Readiness
answers "is this instance configured to do its job" by looking at **presence of
configuration only**: it does not call Supabase, does not call Gemini, and does not echo
a URL, a key, a prefix, a length or a project reference. A probe endpoint that reaches
out to a dependency turns one slow dependency into a restart loop, and a probe that
prints configuration is a free reconnaissance endpoint.
"""

from __future__ import annotations

from typing import Literal

from fastapi import APIRouter, Depends, Response
from pydantic import BaseModel, Field

from app.ai.routing import routing_table
from app.api.deps import get_settings_dep
from app.core.config import Settings

router = APIRouter(tags=["health"])


class Liveness(BaseModel):
    status: Literal["ok"] = "ok"
    service: str = "healthpulse-api"


class ReadinessChecks(BaseModel):
    supabase_config: bool = Field(description="Supabase URL and keys are present.")
    gemini_config: bool = Field(description="A Gemini API key is present.")


class Readiness(BaseModel):
    status: Literal["ready", "not_ready"]
    environment: str
    checks: ReadinessChecks
    #: Task -> model id. Not a secret, and the first thing you want when an answer
    #: changes shape after a model swap.
    models: dict[str, str]


@router.get("/healthz", response_model=Liveness, summary="Liveness")
async def healthz() -> Liveness:
    """The process is up. Nothing else is claimed."""
    return Liveness()


@router.get("/readyz", response_model=Readiness, summary="Readiness")
async def readyz(
    response: Response, settings: Settings = Depends(get_settings_dep)
) -> Readiness:
    """Configuration is present. No dependency is contacted and no value is revealed."""
    checks = ReadinessChecks(
        supabase_config=settings.has_supabase_config(),
        gemini_config=settings.has_gemini_config(),
    )
    ready = checks.supabase_config and checks.gemini_config
    if not ready:
        response.status_code = 503
    return Readiness(
        status="ready" if ready else "not_ready",
        environment=settings.environment,
        checks=checks,
        models=routing_table(),
    )

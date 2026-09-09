"""FastAPI dependencies: the caller, and the repositories scoped to them.

Every repository handed out here is built on the **caller's own access token**, so the
database decides what they can see. The only dependency that carries the service-role key
is :func:`get_deletion_repository`, and it carries both.
"""

from __future__ import annotations

from typing import Annotated

from fastapi import Depends, Header, Request

from app.ai.client import GeminiClient
from app.core.config import Settings
from app.core.errors import ConsentRequired
from app.core.security import JwksCache, Principal, bearer_token, verify_token
from app.ingest.pipeline import IngestService
from app.planner.context import ContextAssembler
from app.planner.service import PlannerService
from app.repositories.audit import AuditRepository
from app.repositories.base import StorageClient, SupabaseGateway
from app.repositories.chat import ChatRepository
from app.repositories.plans import (
    AlertRepository,
    FoodLogRepository,
    GoalRepository,
    GroceryRepository,
    PlanRepository,
)
from app.repositories.privacy import DeletionRepository, ExportRepository
from app.repositories.profiles import ProfileRepository
from app.repositories.reference import ReferenceRepository
from app.repositories.reports import ReportRepository


def get_settings_dep(request: Request) -> Settings:
    return request.app.state.settings


def get_gateway(request: Request) -> SupabaseGateway:
    return request.app.state.gateway


def get_jwks(request: Request) -> JwksCache:
    return request.app.state.jwks


def get_gemini(request: Request) -> GeminiClient | None:
    return getattr(request.app.state, "gemini", None)


def get_safety_judge(request: Request) -> object | None:
    return getattr(request.app.state, "safety_judge", None)


async def get_principal(
    settings: Annotated[Settings, Depends(get_settings_dep)],
    jwks: Annotated[JwksCache, Depends(get_jwks)],
    authorization: Annotated[str | None, Header()] = None,
) -> Principal:
    """The verified caller. Everything user-facing depends on this."""
    return await verify_token(bearer_token(authorization), settings, jwks)


CurrentUser = Annotated[Principal, Depends(get_principal)]


# --------------------------------------------------------------------- repositories


def get_profiles(
    principal: CurrentUser,
    gateway: Annotated[SupabaseGateway, Depends(get_gateway)],
) -> ProfileRepository:
    return ProfileRepository(gateway.rest(gateway.as_user(principal)), principal.user_id)


def get_reports(
    principal: CurrentUser,
    gateway: Annotated[SupabaseGateway, Depends(get_gateway)],
) -> ReportRepository:
    return ReportRepository(gateway.rest(gateway.as_user(principal)), principal.user_id)


def get_reference(
    principal: CurrentUser,
    gateway: Annotated[SupabaseGateway, Depends(get_gateway)],
) -> ReferenceRepository:
    # Reference tables have a SELECT policy for `authenticated`, so the user's own token
    # reads them. No service role, even though the data is not user data.
    return ReferenceRepository(gateway.rest(gateway.as_user(principal)))


def get_chat(
    principal: CurrentUser,
    gateway: Annotated[SupabaseGateway, Depends(get_gateway)],
) -> ChatRepository:
    return ChatRepository(gateway.rest(gateway.as_user(principal)), principal.user_id)


def get_plans(
    principal: CurrentUser,
    gateway: Annotated[SupabaseGateway, Depends(get_gateway)],
) -> PlanRepository:
    return PlanRepository(gateway.rest(gateway.as_user(principal)), principal.user_id)


def get_alerts(
    principal: CurrentUser,
    gateway: Annotated[SupabaseGateway, Depends(get_gateway)],
) -> AlertRepository:
    return AlertRepository(gateway.rest(gateway.as_user(principal)), principal.user_id)


def get_grocery(
    principal: CurrentUser,
    gateway: Annotated[SupabaseGateway, Depends(get_gateway)],
) -> GroceryRepository:
    return GroceryRepository(gateway.rest(gateway.as_user(principal)), principal.user_id)


def get_food_logs(
    principal: CurrentUser,
    gateway: Annotated[SupabaseGateway, Depends(get_gateway)],
) -> FoodLogRepository:
    return FoodLogRepository(gateway.rest(gateway.as_user(principal)), principal.user_id)


def get_goals(
    principal: CurrentUser,
    gateway: Annotated[SupabaseGateway, Depends(get_gateway)],
) -> GoalRepository:
    return GoalRepository(gateway.rest(gateway.as_user(principal)), principal.user_id)


def get_audit(
    principal: CurrentUser,
    gateway: Annotated[SupabaseGateway, Depends(get_gateway)],
) -> AuditRepository:
    return AuditRepository(gateway.rest(gateway.as_user(principal)), principal.user_id)


def get_export(
    principal: CurrentUser,
    gateway: Annotated[SupabaseGateway, Depends(get_gateway)],
) -> ExportRepository:
    return ExportRepository(gateway.rest(gateway.as_user(principal)), principal.user_id)


def get_storage(
    principal: CurrentUser,
    gateway: Annotated[SupabaseGateway, Depends(get_gateway)],
) -> StorageClient:
    # The user's own token. Storage RLS compares the first folder of the object name
    # against auth.uid(), so a path outside their folder is refused by the database.
    return gateway.storage(gateway.as_user(principal))


def get_deletion(
    principal: CurrentUser,
    gateway: Annotated[SupabaseGateway, Depends(get_gateway)],
) -> DeletionRepository:
    """The one dependency that carries the service-role key. See app.repositories.privacy
    for the justification of each privileged operation."""
    service = gateway.as_service(
        "erase every row and storage object for a user who asked to be forgotten"
    )
    return DeletionRepository(
        user_db=gateway.rest(gateway.as_user(principal)),
        service_db=gateway.rest(service),
        service_storage=gateway.storage(service),
        user_id=principal.user_id,
        service_credentials=service,
    )


# ------------------------------------------------------------------------ services


def get_ingest(
    principal: CurrentUser,
    reports: Annotated[ReportRepository, Depends(get_reports)],
    reference: Annotated[ReferenceRepository, Depends(get_reference)],
    storage: Annotated[StorageClient, Depends(get_storage)],
    audit: Annotated[AuditRepository, Depends(get_audit)],
    gemini: Annotated[GeminiClient | None, Depends(get_gemini)],
) -> IngestService:
    return IngestService(
        reports=reports,
        reference=reference,
        storage=storage,
        audit=audit,
        user_id=principal.user_id,
        gemini=gemini,
    )


def get_assembler(
    profiles: Annotated[ProfileRepository, Depends(get_profiles)],
    reports: Annotated[ReportRepository, Depends(get_reports)],
    goals: Annotated[GoalRepository, Depends(get_goals)],
    food_logs: Annotated[FoodLogRepository, Depends(get_food_logs)],
    reference: Annotated[ReferenceRepository, Depends(get_reference)],
) -> ContextAssembler:
    return ContextAssembler(
        profiles=profiles,
        reports=reports,
        goals=goals,
        food_logs=food_logs,
        reference=reference,
    )


def get_planner(
    assembler: Annotated[ContextAssembler, Depends(get_assembler)],
    plans: Annotated[PlanRepository, Depends(get_plans)],
    alerts: Annotated[AlertRepository, Depends(get_alerts)],
    reference: Annotated[ReferenceRepository, Depends(get_reference)],
    audit: Annotated[AuditRepository, Depends(get_audit)],
    gemini: Annotated[GeminiClient | None, Depends(get_gemini)],
    judge: Annotated[object | None, Depends(get_safety_judge)],
) -> PlannerService:
    return PlannerService(
        assembler=assembler,
        plans=plans,
        alerts=alerts,
        reference=reference,
        audit=audit,
        gemini=gemini,
        judge=judge,
    )


async def require_consent(
    profiles: Annotated[ProfileRepository, Depends(get_profiles)],
) -> None:
    """Guard for anything that analyses health data.

    docs/02-architecture.md §6: consent is recorded before analysis, not alongside it.
    """
    if not await profiles.has_current_consent():
        raise ConsentRequired()

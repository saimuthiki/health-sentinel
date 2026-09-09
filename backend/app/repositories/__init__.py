"""Data access over Supabase.

User data is read and written with the **user's own access token**, so Postgres Row
Level Security is the enforcement boundary rather than the filters in this package. The
service-role key is confined to :mod:`app.repositories.privacy` and to the maintenance
helpers in :mod:`app.repositories.maintenance`, each with a comment saying why.
"""

from app.repositories.audit import AuditRepository
from app.repositories.base import (
    Credentials,
    PostgrestClient,
    StorageClient,
    SupabaseGateway,
    eq,
    in_,
)
from app.repositories.chat import ChatRepository
from app.repositories.plans import (
    AlertRepository,
    FoodLogRepository,
    GoalRepository,
    GroceryRepository,
    PlanRepository,
    week_start_for,
)
from app.repositories.privacy import DeletionReceipt, DeletionRepository, ExportRepository
from app.repositories.profiles import (
    CONSENT_TYPES,
    CURRENT_CONSENT_VERSION,
    ProfileRepository,
    UserScopedRepository,
)
from app.repositories.reference import ReferenceRepository
from app.repositories.reports import ReportRepository

__all__ = [
    "CONSENT_TYPES",
    "CURRENT_CONSENT_VERSION",
    "AlertRepository",
    "AuditRepository",
    "ChatRepository",
    "Credentials",
    "DeletionReceipt",
    "DeletionRepository",
    "ExportRepository",
    "FoodLogRepository",
    "GoalRepository",
    "GroceryRepository",
    "PlanRepository",
    "PostgrestClient",
    "ProfileRepository",
    "ReferenceRepository",
    "ReportRepository",
    "StorageClient",
    "SupabaseGateway",
    "UserScopedRepository",
    "eq",
    "in_",
    "week_start_for",
]

"""Profile, health profile, allergies and consent records.

Every method here runs as the signed-in user, so the ``user_id`` filters are a courtesy
to the query planner: RLS is what makes another user's row unreachable.
"""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Any

from app.core.errors import PermissionDenied
from app.domain.models import HealthProfile
from app.repositories.base import PostgrestClient, eq
from app.repositories.mapping import health_profile_from_rows, health_profile_to_row

#: The consent version the app must have accepted before we analyse health data.
CURRENT_CONSENT_VERSION = "2026-09-01"
CONSENT_TYPES: tuple[str, ...] = ("health_data", "ai_processing", "not_a_doctor")


class UserScopedRepository:
    """Base class for every repository that touches user data.

    Constructing one with a service-role client raises. That is the structural half of
    "a repository that reaches for the service role to read user data is a bug"; the
    other half is that ``as_service`` demands a written reason.
    """

    def __init__(self, client: PostgrestClient, user_id: str) -> None:
        if client.privileged:
            raise PermissionDenied(
                "user data must be read and written with the user's own token so that "
                "Row Level Security is the enforcement boundary"
            )
        self.db = client
        self.user_id = user_id

    @property
    def _mine(self) -> dict[str, str]:
        return {"user_id": eq(self.user_id)}


class ProfileRepository(UserScopedRepository):
    """``profiles``, ``health_profiles``, ``allergies``, ``consents``."""

    async def account(self) -> dict[str, Any] | None:
        return await self.db.select_one("profiles", filters=self._mine)

    async def upsert_account(
        self,
        *,
        display_name: str | None = None,
        locale: str | None = None,
        timezone: str | None = None,
    ) -> dict[str, Any]:
        row: dict[str, Any] = {"user_id": self.user_id}
        if display_name is not None:
            row["display_name"] = display_name
        if locale is not None:
            row["locale"] = locale
        if timezone is not None:
            row["timezone"] = timezone
        rows = await self.db.upsert("profiles", row, on_conflict="user_id")
        return rows[0] if rows else row

    async def health_profile(self) -> HealthProfile:
        row = await self.db.select_one("health_profiles", filters=self._mine)
        allergies = await self.allergies()
        return health_profile_from_rows(self.user_id, row, allergies)

    async def has_health_profile(self) -> bool:
        return await self.db.select_one("health_profiles", columns="user_id", filters=self._mine) is not None

    async def save_health_profile(self, profile: HealthProfile) -> HealthProfile:
        row = health_profile_to_row(profile)
        row["user_id"] = self.user_id
        await self.db.upsert("health_profiles", row, on_conflict="user_id")
        await self._replace_allergies(profile)
        return await self.health_profile()

    async def _replace_allergies(self, profile: HealthProfile) -> None:
        await self.db.delete("allergies", filters=self._mine, returning=False)
        if not profile.allergies:
            return
        await self.db.insert(
            "allergies",
            [
                {
                    "user_id": self.user_id,
                    "allergen": allergy.allergen,
                    "severity": allergy.severity,
                }
                for allergy in profile.allergies
            ],
            returning=False,
        )

    async def allergies(self) -> list[dict[str, Any]]:
        return await self.db.select(
            "allergies", columns="allergen,severity", filters=self._mine
        )

    # -- consent -----------------------------------------------------------

    async def consents(self) -> list[dict[str, Any]]:
        return await self.db.select(
            "consents",
            columns="consent_type,version,accepted_at",
            filters=self._mine,
            order="accepted_at.desc",
        )

    async def record_consent(
        self, consent_type: str, version: str, *, ip_hash: str | None = None
    ) -> dict[str, Any]:
        row = {
            "user_id": self.user_id,
            "consent_type": consent_type,
            "version": version,
            "accepted_at": datetime.now(UTC).isoformat(),
            "ip_hash": ip_hash,
        }
        rows = await self.db.upsert(
            "consents", row, on_conflict="user_id,consent_type,version"
        )
        return rows[0] if rows else row

    async def has_current_consent(self, version: str = CURRENT_CONSENT_VERSION) -> bool:
        rows = await self.db.select(
            "consents",
            columns="consent_type",
            filters={**self._mine, "version": eq(version)},
        )
        accepted = {str(row.get("consent_type")) for row in rows}
        return set(CONSENT_TYPES).issubset(accepted)

"""Who am I, my profile, and my consent records.

Sign-in itself happens in the Flutter app against Supabase Auth; this service never sees
a password and never issues a token. It only verifies the access token the app already
holds -- see :mod:`app.core.security`.
"""

from __future__ import annotations

import hashlib
from datetime import date, time
from typing import Annotated, Any

from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, ConfigDict, Field, field_validator

from app.api.deps import CurrentUser, get_goals, get_profiles
from app.domain.enums import ActivityLevel, DietType, GoalType, MealSlot, Sex
from app.domain.models import Allergy, Goal, HealthProfile
from app.repositories.plans import PERSISTABLE_GOAL_TYPES, GoalRepository
from app.repositories.profiles import (
    CONSENT_TYPES,
    CURRENT_CONSENT_VERSION,
    ProfileRepository,
)

router = APIRouter(prefix="/v1/me", tags=["account"])


class Me(BaseModel):
    user_id: str
    email: str | None = None
    display_name: str | None = None
    locale: str = "en-IN"
    timezone: str = "Asia/Kolkata"
    has_health_profile: bool = False
    consent_current: bool = False
    consent_version_required: str = CURRENT_CONSENT_VERSION


class AllergyIn(BaseModel):
    model_config = ConfigDict(extra="forbid")

    allergen: str = Field(min_length=1, max_length=80)
    severity: str = Field(default="unknown", max_length=40)


class ProfileIn(BaseModel):
    """What the app may set. Deliberately not the whole domain model."""

    model_config = ConfigDict(extra="forbid")

    display_name: str | None = Field(default=None, max_length=80)
    locale: str | None = Field(default=None, max_length=16)
    timezone: str | None = Field(default=None, max_length=64)
    dob: date | None = None
    sex: Sex = Sex.OTHER
    height_cm: float | None = Field(default=None, gt=0, lt=300)
    weight_kg: float | None = Field(default=None, gt=0, lt=700)
    activity_level: ActivityLevel = ActivityLevel.MODERATE
    diet_type: DietType = DietType.NON_VEG
    cuisine_pref: list[str] = Field(default_factory=list, max_length=12)
    city: str | None = Field(default=None, max_length=80)
    pincode: str | None = Field(default=None, max_length=12)
    wake_time: time | None = None
    sleep_time: time | None = None
    meal_times: dict[MealSlot, time] = Field(default_factory=dict)
    conditions: list[str] = Field(default_factory=list, max_length=20)
    allergies: list[AllergyIn] = Field(default_factory=list, max_length=40)
    is_pregnant: bool = False

    #: What the person wants the plan to work on, most important first.
    #:
    #: These live in ``goals``, not in ``health_profiles``, and they are on this model
    #: rather than behind an endpoint of their own because the wizard asks them as one
    #: more question on one screen and saves the lot with one button. Two writes behind
    #: one Save is two ways for half of it to land.
    goal_types: list[GoalType] = Field(default_factory=list, max_length=8)

    #: A water target the person set for themselves. Stored as given; nothing here
    #: decides whether it is a sensible number, because nothing here is entitled to.
    hydration_target_override_ml: int | None = None

    @field_validator("pincode")
    @classmethod
    def _tidy_pincode(cls, value: str | None) -> str | None:
        if value is None:
            return None
        return value.strip() or None

    @field_validator("goal_types")
    @classmethod
    def _storable_goals(cls, value: list[GoalType]) -> list[GoalType]:
        unknown = [g.value for g in value if g not in PERSISTABLE_GOAL_TYPES]
        if unknown:
            raise ValueError(
                "we cannot record " + ", ".join(sorted(unknown)) + " as a goal yet"
            )
        return value

    def to_domain(self, user_id: str) -> HealthProfile:
        return HealthProfile(
            user_id=user_id,
            dob=self.dob,
            sex=self.sex,
            height_cm=self.height_cm,
            weight_kg=self.weight_kg,
            activity_level=self.activity_level,
            diet_type=self.diet_type,
            cuisine_pref=list(self.cuisine_pref),
            city=self.city,
            pincode=self.pincode,
            wake_time=self.wake_time,
            sleep_time=self.sleep_time,
            meal_times=dict(self.meal_times),
            conditions=list(self.conditions),
            allergies=[
                Allergy(allergen=a.allergen.strip(), severity=a.severity)
                for a in self.allergies
            ],
            is_pregnant=self.is_pregnant,
            hydration_target_override_ml=self.hydration_target_override_ml,
        )


class ProfileOut(BaseModel):
    user_id: str
    dob: date | None
    sex: Sex
    height_cm: float | None
    weight_kg: float | None
    activity_level: ActivityLevel
    diet_type: DietType
    cuisine_pref: list[str]
    city: str | None
    pincode: str | None
    wake_time: time | None
    sleep_time: time | None
    meal_times: dict[MealSlot, time]
    conditions: list[str]
    allergies: list[AllergyIn]
    is_pregnant: bool
    goal_types: list[GoalType] = Field(default_factory=list)
    hydration_target_override_ml: int | None = None
    age_years: int | None = None

    @classmethod
    def of(cls, profile: HealthProfile, goals: list[Goal] | None = None) -> ProfileOut:
        return cls(
            user_id=profile.user_id,
            dob=profile.dob,
            sex=profile.sex,
            height_cm=profile.height_cm,
            weight_kg=profile.weight_kg,
            activity_level=profile.activity_level,
            diet_type=profile.diet_type,
            cuisine_pref=list(profile.cuisine_pref),
            city=profile.city,
            pincode=profile.pincode,
            wake_time=profile.wake_time,
            sleep_time=profile.sleep_time,
            meal_times=dict(profile.meal_times),
            conditions=list(profile.conditions),
            allergies=[
                AllergyIn(allergen=a.allergen, severity=a.severity) for a in profile.allergies
            ],
            is_pregnant=profile.is_pregnant,
            # Already ordered by priority by the repository, so the list comes back in
            # the order the person put their goals in.
            goal_types=[goal.goal_type for goal in (goals or [])],
            hydration_target_override_ml=profile.hydration_target_override_ml,
            age_years=profile.age_on(date.today()),
        )


class ConsentIn(BaseModel):
    model_config = ConfigDict(extra="forbid")

    consent_type: str = Field(max_length=40)
    version: str = Field(default=CURRENT_CONSENT_VERSION, max_length=40)
    accepted: bool = True


class ConsentOut(BaseModel):
    consent_type: str
    version: str
    accepted_at: str | None = None


class ConsentStatus(BaseModel):
    version_required: str = CURRENT_CONSENT_VERSION
    types_required: list[str] = Field(default_factory=lambda: list(CONSENT_TYPES))
    current: bool = False
    recorded: list[ConsentOut] = Field(default_factory=list)


Profiles = Annotated[ProfileRepository, Depends(get_profiles)]
Goals = Annotated[GoalRepository, Depends(get_goals)]


@router.get("", response_model=Me, summary="The signed-in user")
async def me(principal: CurrentUser, profiles: Profiles) -> Me:
    account = await profiles.account() or {}
    return Me(
        user_id=principal.user_id,
        email=principal.email,
        display_name=account.get("display_name"),
        locale=str(account.get("locale") or "en-IN"),
        timezone=str(account.get("timezone") or "Asia/Kolkata"),
        has_health_profile=await profiles.has_health_profile(),
        consent_current=await profiles.has_current_consent(),
    )


@router.get("/profile", response_model=ProfileOut, summary="My health profile")
async def read_profile(
    principal: CurrentUser, profiles: Profiles, goals: Goals
) -> ProfileOut:
    """Always returns a profile. An unfilled one carries the documented defaults, which
    is honest -- the app should show empty fields, not a 404."""
    return ProfileOut.of(await profiles.health_profile(), await goals.active_goals())


@router.put("/profile", response_model=ProfileOut, summary="Create or update my profile")
async def write_profile(
    payload: ProfileIn, principal: CurrentUser, profiles: Profiles, goals: Goals
) -> ProfileOut:
    """Replace the profile, and with it the set of goals being worked on.

    The goals are written after the profile rather than before it. If the profile write
    fails there is nothing to explain the goals, and leaving them unchanged is the state
    the user can see and retry from.
    """
    if any((payload.display_name, payload.locale, payload.timezone)):
        await profiles.upsert_account(
            display_name=payload.display_name,
            locale=payload.locale,
            timezone=payload.timezone,
        )
    saved = await profiles.save_health_profile(payload.to_domain(principal.user_id))
    active = await goals.replace_types(payload.goal_types)
    return ProfileOut.of(saved, active)


@router.get("/consents", response_model=ConsentStatus, summary="My consent records")
async def read_consents(profiles: Profiles) -> ConsentStatus:
    rows = await profiles.consents()
    return ConsentStatus(
        current=await profiles.has_current_consent(),
        recorded=[
            ConsentOut(
                consent_type=str(row.get("consent_type")),
                version=str(row.get("version")),
                accepted_at=_str(row.get("accepted_at")),
            )
            for row in rows
        ],
    )


@router.post("/consents", response_model=ConsentOut, status_code=201, summary="Record consent")
async def record_consent(
    payload: ConsentIn, request: Request, profiles: Profiles
) -> ConsentOut:
    """Record one consent receipt.

    The IP is stored as a salted hash and never as an address (docs/03-data-model.md).
    The salt is the user's own id, so the hash is useless outside their own row.
    """
    row = await profiles.record_consent(
        payload.consent_type,
        payload.version,
        ip_hash=_ip_hash(request, profiles.user_id),
    )
    return ConsentOut(
        consent_type=str(row.get("consent_type", payload.consent_type)),
        version=str(row.get("version", payload.version)),
        accepted_at=_str(row.get("accepted_at")),
    )


def _ip_hash(request: Request, user_id: str) -> str | None:
    client = request.client
    if client is None or not client.host:
        return None
    digest = hashlib.sha256(f"{user_id}:{client.host}".encode())
    return digest.hexdigest()


def _str(value: Any) -> str | None:
    return str(value) if value is not None else None

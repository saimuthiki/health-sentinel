"""Settings, read once from the environment.

Two rules shape this module:

* **Fail fast, and say exactly what is missing.** A health API that boots without a
  database and then 500s on the first request is worse than one that refuses to start.
  :func:`validate_settings` collects *every* missing variable and raises one message
  naming all of them, so an operator fixes the whole list in one visit to the Render
  dashboard instead of one variable per deploy.
* **A secret is never rendered.** ``repr`` of this object shows presence, never value,
  and nothing here is ever put in a log line, an error body or a health check.

``SUPABASE_JWT_SECRET`` is deliberately optional. See :mod:`app.core.security`: the
project signs with asymmetric keys (ES256) now, and the shared secret only exists for
tokens issued before the rotation.
"""

from __future__ import annotations

import functools
from typing import Literal

from pydantic import ValidationError, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

Environment = Literal["development", "test", "staging", "production"]

#: Upload ceiling. Enforced while streaming, not after buffering (see app.ingest.files).
DEFAULT_MAX_UPLOAD_BYTES = 20 * 1024 * 1024

#: The only file types the extractor can read (docs/04-ai-pipeline.md stage 2).
DEFAULT_ALLOWED_UPLOAD_MIME = (
    "application/pdf",
    "image/jpeg",
    "image/png",
    "image/heic",
    "image/heif",
)


class ConfigurationError(RuntimeError):
    """Configuration is missing or malformed. Raised at startup, never per request."""


class Settings(BaseSettings):
    """Everything the service reads from the environment."""

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
        case_sensitive=False,
    )

    environment: Environment = "development"
    log_level: str = "INFO"

    # -- Supabase ----------------------------------------------------------
    #: Project URL, e.g. https://<ref>.supabase.co. Everything else -- the JWKS
    #: endpoint, the issuer, PostgREST and Storage -- is derived from it, so the
    #: project ref is never hardcoded anywhere in this codebase.
    supabase_url: str = ""
    #: Publishable key. Sent as the ``apikey`` header alongside the *user's* JWT so
    #: PostgREST runs the request as that user and RLS does the enforcing.
    supabase_anon_key: str = ""
    #: Secret. Bypasses RLS. Only used where a comment at the call site says why.
    supabase_service_role_key: str = ""
    #: Legacy HS256 signing secret. Optional, and accepting it is deprecated --
    #: see app.core.security.
    supabase_jwt_secret: str = ""
    supabase_storage_bucket: str = "reports"

    # -- Gemini ------------------------------------------------------------
    gemini_api_key: str = ""

    # -- HTTP --------------------------------------------------------------
    cors_allow_origins: str = ""
    request_timeout_seconds: float = 30.0

    # -- Uploads -----------------------------------------------------------
    max_upload_bytes: int = DEFAULT_MAX_UPLOAD_BYTES

    # -- JWKS cache --------------------------------------------------------
    jwks_cache_ttl_seconds: float = 600.0
    #: Shortest gap between two JWKS fetches. An unknown ``kid`` triggers a refetch,
    #: so without this a forged ``kid`` is an outbound-request amplifier.
    jwks_min_refetch_seconds: float = 60.0
    #: Hard ceiling on refetches per TTL window, on top of the interval above.
    jwks_max_refetches_per_window: int = 5
    jwks_timeout_seconds: float = 5.0

    # -- Auth --------------------------------------------------------------
    jwt_audience: str = "authenticated"
    jwt_leeway_seconds: float = 10.0
    #: Refuse to even parse anything larger. A JWT is ~1 KB; 8 KB is generous.
    max_token_bytes: int = 8192

    @field_validator("supabase_url")
    @classmethod
    def _strip_trailing_slash(cls, value: str) -> str:
        return value.strip().rstrip("/")

    @field_validator("log_level")
    @classmethod
    def _upper(cls, value: str) -> str:
        return value.strip().upper() or "INFO"

    # -- derived -----------------------------------------------------------

    @property
    def is_production(self) -> bool:
        return self.environment in ("production", "staging")

    @property
    def auth_base_url(self) -> str:
        return f"{self.supabase_url}/auth/v1"

    @property
    def jwt_issuer(self) -> str:
        """The ``iss`` every Supabase access token carries."""
        return self.auth_base_url

    @property
    def jwks_url(self) -> str:
        """Built from ``SUPABASE_URL``; the project ref is never written down here."""
        return f"{self.auth_base_url}/.well-known/jwks.json"

    @property
    def postgrest_url(self) -> str:
        return f"{self.supabase_url}/rest/v1"

    @property
    def storage_url(self) -> str:
        return f"{self.supabase_url}/storage/v1"

    @property
    def legacy_hs256_enabled(self) -> bool:
        """HS256 is accepted only when an operator explicitly set the shared secret."""
        return bool(self.supabase_jwt_secret.strip())

    @property
    def allowed_upload_mime(self) -> tuple[str, ...]:
        return DEFAULT_ALLOWED_UPLOAD_MIME

    @property
    def cors_origins(self) -> list[str]:
        return [o.strip() for o in self.cors_allow_origins.split(",") if o.strip()]

    def has_supabase_config(self) -> bool:
        """Presence only. Never returns, logs or hints at a value."""
        return bool(
            self.supabase_url and self.supabase_anon_key and self.supabase_service_role_key
        )

    def has_gemini_config(self) -> bool:
        return bool(self.gemini_api_key.strip())

    def __repr__(self) -> str:  # pragma: no cover - trivial
        return (
            f"Settings(environment={self.environment!r}, "
            f"supabase_configured={self.has_supabase_config()}, "
            f"gemini_configured={self.has_gemini_config()})"
        )

    __str__ = __repr__


#: Variables without which nothing works at all, in any environment.
ALWAYS_REQUIRED: tuple[tuple[str, str], ...] = (
    ("SUPABASE_URL", "supabase_url"),
)

#: Additionally required before the service may serve real users.
REQUIRED_IN_PRODUCTION: tuple[tuple[str, str], ...] = (
    ("SUPABASE_ANON_KEY", "supabase_anon_key"),
    ("SUPABASE_SERVICE_ROLE_KEY", "supabase_service_role_key"),
    ("GEMINI_API_KEY", "gemini_api_key"),
)

_HINT = (
    "Set them in the Render dashboard (Environment tab) for a deployed service, or in a "
    "local .env file for development. docs/06-your-manual-steps.md step M3 lists where "
    "each value comes from. Never put a filled-in .env in the repository."
)


def missing_variables(settings: Settings) -> list[str]:
    """Environment variable names that are required here but empty."""
    checks = list(ALWAYS_REQUIRED)
    if settings.is_production:
        checks += list(REQUIRED_IN_PRODUCTION)
    return [name for name, attr in checks if not str(getattr(settings, attr, "")).strip()]


def validate_settings(settings: Settings) -> Settings:
    """Raise :class:`ConfigurationError` naming every missing variable at once."""
    missing = missing_variables(settings)
    if missing:
        raise ConfigurationError(
            "Cannot start: these environment variables are missing or empty: "
            + ", ".join(missing)
            + ". "
            + _HINT
        )
    if not settings.supabase_url.startswith("https://"):
        raise ConfigurationError(
            "Cannot start: SUPABASE_URL must be the full https:// project URL, for "
            "example https://your-project-ref.supabase.co"
        )
    return settings


def load_settings(**overrides: object) -> Settings:
    """Build :class:`Settings` from the environment, translating pydantic errors."""
    try:
        return Settings(**overrides)  # type: ignore[arg-type]
    except ValidationError as exc:
        fields = sorted({str(err["loc"][0]).upper() for err in exc.errors() if err["loc"]})
        raise ConfigurationError(
            "Cannot start: these environment variables are set to an unusable value: "
            + ", ".join(fields)
            + ". "
            + _HINT
        ) from None


@functools.lru_cache(maxsize=1)
def get_settings() -> Settings:
    """Process-wide settings. Cached; call ``get_settings.cache_clear()`` in tests."""
    return load_settings()

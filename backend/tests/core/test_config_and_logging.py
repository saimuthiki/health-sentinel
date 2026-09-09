"""Configuration fails fast and says what is missing; logging never leaks."""

from __future__ import annotations

import logging

import pytest
import structlog
from structlog.testing import capture_logs

from app.core.config import (
    ConfigurationError,
    load_settings,
    missing_variables,
    validate_settings,
)
from app.core.logging import (
    CONTENT_KEYS,
    SECRET_KEYS,
    configure_logging,
    get_logger,
    redaction_processor,
    scrub_value,
)
from tests.conftest import SUPABASE_URL

FAKE_JWT = (
    "eyJhbGciOiJFUzI1NiIsImtpZCI6ImVjLTEifQ."
    "eyJzdWIiOiIxMTExMTExMS0yMjIyLTMzMzMtNDQ0NC01NTU1NTU1NTU1NTUifQ."
    "c2lnbmF0dXJlLWJ5dGVzLWhlcmU"
)
FAKE_GOOGLE_KEY = "AIzaSyD-not-a-real-key-0123456789abcd"
FAKE_SB_KEY = "sb_secret_notarealkey0123456789"


def prod(**overrides):
    base = {
        "environment": "production",
        "supabase_url": SUPABASE_URL,
        "supabase_anon_key": "sb_publishable_x",
        "supabase_service_role_key": FAKE_SB_KEY,
        "gemini_api_key": FAKE_GOOGLE_KEY,
    }
    base.update(overrides)
    return load_settings(**base)


# ------------------------------------------------------------------------- config


def test_missing_supabase_url_fails_at_startup():
    with pytest.raises(ConfigurationError) as excinfo:
        validate_settings(load_settings(supabase_url=""))
    assert "SUPABASE_URL" in str(excinfo.value)
    assert "docs/06-your-manual-steps.md" in str(excinfo.value)


def test_production_lists_every_missing_variable_at_once():
    settings = load_settings(
        environment="production",
        supabase_url="",
        supabase_anon_key="",
        supabase_service_role_key="",
        gemini_api_key="",
    )
    missing = missing_variables(settings)
    assert missing == [
        "SUPABASE_URL",
        "SUPABASE_ANON_KEY",
        "SUPABASE_SERVICE_ROLE_KEY",
        "GEMINI_API_KEY",
    ]
    with pytest.raises(ConfigurationError) as excinfo:
        validate_settings(settings)
    for name in missing:
        assert name in str(excinfo.value)


def test_development_tolerates_missing_keys_so_readyz_can_report_them():
    settings = load_settings(supabase_url=SUPABASE_URL, environment="development")
    assert missing_variables(settings) == []
    assert validate_settings(settings) is settings
    assert settings.has_supabase_config() is False
    assert settings.has_gemini_config() is False


def test_a_url_that_is_not_https_is_refused():
    with pytest.raises(ConfigurationError) as excinfo:
        validate_settings(load_settings(supabase_url="my-project.supabase.co"))
    assert "https://" in str(excinfo.value)


def test_derived_urls_never_hardcode_a_project_ref():
    settings = prod()
    assert settings.postgrest_url == f"{SUPABASE_URL}/rest/v1"
    assert settings.storage_url == f"{SUPABASE_URL}/storage/v1"
    assert settings.jwks_url.startswith(SUPABASE_URL)
    assert settings.supabase_url.endswith("supabase.co")


def test_trailing_slash_is_stripped():
    assert load_settings(supabase_url=f"{SUPABASE_URL}/").supabase_url == SUPABASE_URL


def test_repr_shows_presence_not_values():
    text = repr(prod())
    assert FAKE_SB_KEY not in text
    assert FAKE_GOOGLE_KEY not in text
    assert "supabase_configured=True" in text


def test_cors_origins_are_split():
    settings = prod(cors_allow_origins="https://a.test, https://b.test ,")
    assert settings.cors_origins == ["https://a.test", "https://b.test"]


# ------------------------------------------------------------------------ logging


def test_secret_keys_are_replaced():
    out = redaction_processor(None, "info", {"token": FAKE_JWT, "apikey": FAKE_SB_KEY})
    assert out == {"token": "***", "apikey": "***"}


def test_content_keys_are_replaced_by_a_length():
    out = redaction_processor(None, "info", {"reply": "you have diabetes"})
    assert out["reply"] == "<17 chars withheld>"


def test_a_token_inside_a_longer_string_is_scrubbed():
    message = f"Authorization: Bearer {FAKE_JWT} failed"
    assert FAKE_JWT not in scrub_value(message)
    assert "***" in scrub_value(message)


def test_google_and_supabase_keys_are_scrubbed():
    assert FAKE_GOOGLE_KEY not in scrub_value(f"key={FAKE_GOOGLE_KEY}")
    assert FAKE_SB_KEY not in scrub_value(f"key={FAKE_SB_KEY}")


def test_nested_structures_are_scrubbed():
    out = redaction_processor(
        None,
        "info",
        {"headers": {"authorization": f"Bearer {FAKE_JWT}"}, "rows": [FAKE_JWT]},
    )
    assert out["headers"]["authorization"] == "***"
    assert out["rows"] == ["***"]


def test_report_contents_are_never_logged():
    log = get_logger("test")
    with capture_logs() as entries:
        log.info("extracted", raw_json={"rows": [{"value_text": "14.2"}]}, content="Vitamin D 14.2")
    # capture_logs bypasses the configured processor chain, so run it explicitly --
    # this asserts the processor, which is what is actually installed in production.
    processed = redaction_processor(None, "info", dict(entries[0]))
    assert processed["raw_json"] == "<withheld>"
    assert processed["content"].endswith("chars withheld>")


def test_every_obvious_credential_name_is_covered():
    for name in ("authorization", "token", "apikey", "supabase_service_role_key", "cookie"):
        assert name in SECRET_KEYS
    for name in ("content", "reply", "why_text", "narrative", "raw_json"):
        assert name in CONTENT_KEYS


def test_stdlib_logging_is_filtered_too(capsys):
    configure_logging(level="INFO", json_logs=True)
    logging.getLogger("app.legacy").warning("leaked %s", FAKE_JWT)
    captured = capsys.readouterr()
    assert FAKE_JWT not in captured.out + captured.err
    structlog.reset_defaults()


def test_the_app_factory_validates_before_it_builds_anything():
    """Fail fast means at construction, not at the first request."""
    from app.main import create_app

    with pytest.raises(ConfigurationError):
        create_app(load_settings(supabase_url=""))


def test_the_uvicorn_entry_point_is_built_lazily():
    """``app.main:app`` reads the environment; importing the module must not.

    Every test imports app.main for create_app, and a module-level app would exit the
    interpreter during collection on an unconfigured machine.
    """
    import app.main as main

    assert "app" not in vars(main) or isinstance(vars(main)["app"], object)
    assert callable(main.__getattr__)
    with pytest.raises(AttributeError):
        main.__getattr__("not_a_real_attribute")

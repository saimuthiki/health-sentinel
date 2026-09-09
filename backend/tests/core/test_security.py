"""The JWT layer, pushed hard.

Supabase now signs with asymmetric keys (ES256) and keeps an HS256 secret only for the
rotation window. Every way that arrangement can be attacked is a test here: a token that
has expired, one minted for a different audience or issuer, one with an unknown key id,
one signed with no algorithm at all, and -- the one that actually breaks naive verifiers
-- one signed with HS256 using the published *public key* as the shared secret.
"""

from __future__ import annotations

import asyncio
import json
import time
from typing import Any

import httpx
import jwt
import pytest
from structlog.testing import capture_logs

from app.core.config import load_settings
from app.core.errors import AuthenticationError, UpstreamUnavailable
from app.core.security import (
    ASYMMETRIC_ALGORITHMS,
    JwksCache,
    Principal,
    bearer_token,
    verify_token,
)
from tests.conftest import (
    AUDIENCE,
    EC_KID,
    ISSUER,
    JWKS_URL,
    SUPABASE_URL,
    USER_ID,
    KeyMaterial,
    forge_hs256,
    make_token,
)

LEGACY_SECRET = "a-legacy-hs256-shared-secret-that-is-long-enough"


def run(coro: Any) -> Any:
    return asyncio.run(coro)


def settings(**overrides: Any):
    base: dict[str, Any] = {
        "supabase_url": SUPABASE_URL,
        "supabase_anon_key": "sb_publishable_test",
        "supabase_service_role_key": "sb_secret_test",
        "gemini_api_key": "AIzaTest",
        "environment": "test",
    }
    base.update(overrides)
    return load_settings(**base)


class FakeTransport(httpx.AsyncBaseTransport):
    """Serves the JWKS and counts how many times it was asked for."""

    def __init__(self, body: dict[str, Any], *, status: int = 200) -> None:
        self.body = body
        self.status = status
        self.calls = 0

    async def handle_async_request(self, request: httpx.Request) -> httpx.Response:
        self.calls += 1
        assert str(request.url) == JWKS_URL
        return httpx.Response(
            self.status,
            content=json.dumps(self.body).encode(),
            headers={"Content-Type": "application/json"},
            request=request,
        )


def cache_for(body: dict[str, Any], cfg=None, *, status: int = 200, clock=None):
    cfg = cfg or settings()
    transport = FakeTransport(body, status=status)
    client = httpx.AsyncClient(transport=transport)
    cache = JwksCache(cfg, client=client, clock=clock or time.monotonic)
    return cache, transport, cfg


# --------------------------------------------------------------------- happy paths


def test_valid_es256_token_is_accepted(ec_key: KeyMaterial, jwks_body):
    cache, transport, cfg = cache_for(jwks_body)
    token = make_token(ec_key)
    principal = run(verify_token(token, cfg, cache))
    assert isinstance(principal, Principal)
    assert principal.user_id == USER_ID
    assert principal.algorithm == "ES256"
    assert principal.role == "authenticated"
    assert transport.calls == 1


def test_valid_rs256_token_is_accepted(rsa_key: KeyMaterial, jwks_body):
    cache, _transport, cfg = cache_for(jwks_body)
    principal = run(verify_token(make_token(rsa_key), cfg, cache))
    assert principal.algorithm == "RS256"


def test_principal_never_shows_the_token(ec_key: KeyMaterial, jwks_body):
    cache, _t, cfg = cache_for(jwks_body)
    token = make_token(ec_key)
    principal = run(verify_token(token, cfg, cache))
    assert token not in repr(principal)
    assert token not in str(principal)
    assert "<redacted>" in repr(principal)


# ------------------------------------------------------------------------ rejections


def test_expired_token_is_rejected(ec_key: KeyMaterial, jwks_body):
    cache, _t, cfg = cache_for(jwks_body)
    token = make_token(ec_key, expires_in=-120, issued_at=int(time.time()) - 600)
    with pytest.raises(AuthenticationError):
        run(verify_token(token, cfg, cache))


def test_wrong_audience_is_rejected(ec_key: KeyMaterial, jwks_body):
    cache, _t, cfg = cache_for(jwks_body)
    token = make_token(ec_key, audience="anon")
    with pytest.raises(AuthenticationError):
        run(verify_token(token, cfg, cache))


def test_wrong_issuer_is_rejected(ec_key: KeyMaterial, jwks_body):
    cache, _t, cfg = cache_for(jwks_body)
    token = make_token(ec_key, issuer="https://attacker.example/auth/v1")
    with pytest.raises(AuthenticationError):
        run(verify_token(token, cfg, cache))


def test_issuer_of_another_supabase_project_is_rejected(ec_key: KeyMaterial, jwks_body):
    """A token from a different Supabase project is a valid token -- for someone else."""
    cache, _t, cfg = cache_for(jwks_body)
    token = make_token(ec_key, issuer="https://someotherref.supabase.co/auth/v1")
    with pytest.raises(AuthenticationError):
        run(verify_token(token, cfg, cache))


def test_unknown_kid_is_rejected(ec_key: KeyMaterial, jwks_body):
    cache, transport, cfg = cache_for(jwks_body)
    token = make_token(ec_key, kid="not-a-key-we-publish")
    with pytest.raises(AuthenticationError):
        run(verify_token(token, cfg, cache))
    # It did refetch once, because an unknown kid is what a key rotation looks like.
    assert transport.calls == 1


def test_asymmetric_token_without_a_kid_is_rejected(ec_key: KeyMaterial, jwks_body):
    cache, _t, cfg = cache_for(jwks_body)
    token = jwt.encode(
        {
            "sub": USER_ID,
            "aud": AUDIENCE,
            "iss": ISSUER,
            "iat": int(time.time()),
            "exp": int(time.time()) + 600,
        },
        ec_key.private,
        algorithm="ES256",
    )
    with pytest.raises(AuthenticationError):
        run(verify_token(token, cfg, cache))


def test_alg_none_is_rejected(jwks_body):
    cache, _t, cfg = cache_for(jwks_body)
    unsigned = jwt.encode(
        {
            "sub": USER_ID,
            "aud": AUDIENCE,
            "iss": ISSUER,
            "iat": int(time.time()),
            "exp": int(time.time()) + 600,
        },
        key="",
        algorithm="none",
        headers={"kid": EC_KID},
    )
    with pytest.raises(AuthenticationError):
        run(verify_token(unsigned, cfg, cache))


def test_missing_required_claim_is_rejected(ec_key: KeyMaterial, jwks_body):
    cache, _t, cfg = cache_for(jwks_body)
    token = make_token(ec_key, omit=("iat",))
    with pytest.raises(AuthenticationError):
        run(verify_token(token, cfg, cache))


def test_empty_subject_is_rejected(ec_key: KeyMaterial, jwks_body):
    cache, _t, cfg = cache_for(jwks_body)
    with pytest.raises(AuthenticationError):
        run(verify_token(make_token(ec_key, subject="   "), cfg, cache))


def test_garbage_is_rejected(jwks_body):
    cache, _t, cfg = cache_for(jwks_body)
    for value in ("", "not.a.token", "a" * 50):
        with pytest.raises(AuthenticationError):
            run(verify_token(value, cfg, cache))


def test_oversized_token_is_not_even_parsed(ec_key: KeyMaterial, jwks_body):
    cache, transport, cfg = cache_for(jwks_body, settings(max_token_bytes=64))
    with pytest.raises(AuthenticationError):
        run(verify_token(make_token(ec_key), cfg, cache))
    assert transport.calls == 0


# ------------------------------------------------------------------- alg confusion


def test_hs256_signed_with_the_public_key_is_rejected(ec_key: KeyMaterial, jwks_body):
    """The classic algorithm-confusion attack.

    The attacker takes the PEM of the public key we publish in the JWKS and uses it as an
    HMAC secret. A verifier that picks the key by ``kid`` and the algorithm by ``alg``
    accepts it. This one must not: HS256 is verified only against SUPABASE_JWT_SECRET,
    and a JWKS key is never offered as an HMAC secret.
    """
    forged = forge_hs256(
        ec_key.public_pem, header={"alg": "HS256", "typ": "JWT", "kid": ec_key.kid}
    )

    # With the legacy secret switched off, HS256 is refused outright.
    cache, _t, cfg = cache_for(jwks_body)
    with pytest.raises(AuthenticationError):
        run(verify_token(forged, cfg, cache))

    # And with the legacy secret set, it is still refused -- because it is checked
    # against that secret, which the attacker does not have.
    cache2, _t2, cfg2 = cache_for(jwks_body, settings(supabase_jwt_secret=LEGACY_SECRET))
    with pytest.raises(AuthenticationError):
        run(verify_token(forged, cfg2, cache2))


def test_hs256_signed_with_the_raw_jwk_json_is_rejected(ec_key: KeyMaterial, jwks_body):
    """The same attack with the JWK document itself as the secret."""
    forged = forge_hs256(
        json.dumps(ec_key.jwk), header={"alg": "HS256", "typ": "JWT", "kid": ec_key.kid}
    )
    cache, _t, cfg = cache_for(jwks_body, settings(supabase_jwt_secret=LEGACY_SECRET))
    with pytest.raises(AuthenticationError):
        run(verify_token(forged, cfg, cache))


def test_rsa_kid_cannot_be_used_for_es256(rsa_key: KeyMaterial, jwks_body):
    """A ``kid`` naming an RSA key with ``alg: ES256`` is a mislabelled pairing."""
    cache, _t, cfg = cache_for(jwks_body)
    token = make_token(rsa_key, algorithm="RS256", kid=rsa_key.kid)
    header = jwt.get_unverified_header(token)
    assert header["alg"] == "RS256"
    # Now claim it is ES256 while still naming the RSA kid.
    forged = forge_hs256("secret", header={"alg": "ES256", "typ": "JWT", "kid": rsa_key.kid})
    with pytest.raises(AuthenticationError):
        run(verify_token(forged, cfg, cache))


def test_unsupported_algorithm_is_rejected(ec_key: KeyMaterial, jwks_body):
    cache, _t, cfg = cache_for(jwks_body)
    forged = forge_hs256("secret", header={"alg": "ES384", "typ": "JWT", "kid": ec_key.kid})
    with pytest.raises(AuthenticationError):
        run(verify_token(forged, cfg, cache))


def test_only_two_asymmetric_algorithms_are_allowed():
    assert frozenset({"ES256", "RS256"}) == ASYMMETRIC_ALGORITHMS


# ------------------------------------------------------------------- legacy HS256


def test_hs256_is_refused_when_no_secret_is_configured():
    cache, _t, cfg = cache_for({"keys": []})
    token = make_token(LEGACY_SECRET, algorithm="HS256")
    with pytest.raises(AuthenticationError):
        run(verify_token(token, cfg, cache))


def test_hs256_is_accepted_with_the_secret_and_logs_a_deprecation():
    cfg = settings(supabase_jwt_secret=LEGACY_SECRET)
    cache, transport, _ = cache_for({"keys": []}, cfg)
    token = make_token(LEGACY_SECRET, algorithm="HS256")
    with capture_logs() as logs:
        principal = run(verify_token(token, cfg, cache))
    assert principal.user_id == USER_ID
    assert principal.algorithm == "HS256"
    # The JWKS was never fetched for a symmetric token.
    assert transport.calls == 0
    assert any("legacy HS256" in str(entry.get("event", "")) for entry in logs)


def test_legacy_flag_follows_the_secret():
    assert settings().legacy_hs256_enabled is False
    assert settings(supabase_jwt_secret=LEGACY_SECRET).legacy_hs256_enabled is True


# --------------------------------------------------------------------- JWKS cache


def test_jwks_is_cached_between_verifications(ec_key: KeyMaterial, jwks_body):
    cache, transport, cfg = cache_for(jwks_body)
    for _ in range(5):
        run(verify_token(make_token(ec_key), cfg, cache))
    assert transport.calls == 1


def test_unknown_kids_cannot_force_unbounded_refetches(ec_key: KeyMaterial, jwks_body):
    """A stream of forged key ids must not turn us into a request amplifier."""
    ticks = iter(range(0, 10_000))
    now = [0.0]

    def clock() -> float:
        now[0] = float(next(ticks))
        return now[0]

    cfg = settings(jwks_min_refetch_seconds=60.0, jwks_cache_ttl_seconds=600.0)
    cache, transport, _ = cache_for(jwks_body, cfg, clock=clock)

    for index in range(50):
        with pytest.raises(AuthenticationError):
            run(verify_token(make_token(ec_key, kid=f"forged-{index}"), cfg, cache))

    # The clock advances a second per call, so the 60-second minimum interval holds it
    # to a small handful of fetches rather than one per forged kid.
    assert transport.calls <= 3


def test_refetch_ceiling_holds_within_one_window(ec_key: KeyMaterial, jwks_body):
    """Even with time racing ahead, the per-window ceiling applies."""
    step = [0.0]

    def clock() -> float:
        step[0] += 61.0
        return step[0]

    cfg = settings(
        jwks_min_refetch_seconds=60.0,
        jwks_cache_ttl_seconds=100_000.0,
        jwks_max_refetches_per_window=5,
    )
    cache, transport, _ = cache_for(jwks_body, cfg, clock=clock)
    for index in range(40):
        with pytest.raises(AuthenticationError):
            run(verify_token(make_token(ec_key, kid=f"forged-{index}"), cfg, cache))
    # One initial fetch, then at most `jwks_max_refetches_per_window` refetches.
    assert transport.calls <= 1 + cfg.jwks_max_refetches_per_window


def test_rotation_is_picked_up_by_a_refetch(ec_key: KeyMaterial, jwks_body):
    """The reason an unknown kid refetches at all: a new signing key appears."""
    from tests.conftest import _ec_material

    rotated = _ec_material("ec-key-2")
    transport = FakeTransport({"keys": [ec_key.jwk]})
    cfg = settings(jwks_min_refetch_seconds=0.0)
    cache = JwksCache(cfg, client=httpx.AsyncClient(transport=transport))

    run(verify_token(make_token(ec_key), cfg, cache))
    assert transport.calls == 1

    transport.body = {"keys": [ec_key.jwk, rotated.jwk]}
    principal = run(verify_token(make_token(rotated), cfg, cache))
    assert principal.user_id == USER_ID
    assert transport.calls == 2


def test_jwks_entries_without_a_kid_or_of_type_oct_are_ignored(ec_key: KeyMaterial):
    body = {
        "keys": [
            {"kty": "oct", "kid": "shared", "k": "c2VjcmV0"},
            {"kty": "EC", "crv": "P-256", "x": "a", "y": "b"},
            ec_key.jwk,
        ]
    }
    cache, _t, cfg = cache_for(body)
    run(verify_token(make_token(ec_key), cfg, cache))
    assert cache.kids == frozenset({ec_key.kid})


def test_jwks_failure_is_a_503_not_a_401(ec_key: KeyMaterial):
    cache, _t, cfg = cache_for({"keys": []}, status=500)
    with pytest.raises(UpstreamUnavailable):
        run(verify_token(make_token(ec_key), cfg, cache))


def test_jwks_url_is_built_from_the_project_url():
    cfg = settings()
    assert cfg.jwks_url == JWKS_URL
    assert cfg.jwt_issuer == ISSUER
    # The project ref appears only because the test put it in SUPABASE_URL.
    other = settings(supabase_url="https://another.supabase.co")
    assert other.jwks_url == "https://another.supabase.co/auth/v1/.well-known/jwks.json"


# ----------------------------------------------------------------- bearer parsing


@pytest.mark.parametrize(
    "header", [None, "", "Basic abc", "Bearer", "Bearer   ", "token abc"]
)
def test_bad_authorization_headers_are_rejected(header):
    with pytest.raises(AuthenticationError):
        bearer_token(header)


def test_bearer_token_is_extracted():
    assert bearer_token("Bearer abc.def.ghi") == "abc.def.ghi"
    assert bearer_token("bearer abc.def.ghi") == "abc.def.ghi"


def test_every_rejection_gives_the_same_message(ec_key: KeyMaterial, jwks_body):
    """No oracle: expired, wrong audience and bad signature all read alike."""
    cache, _t, cfg = cache_for(jwks_body)
    messages = set()
    for token in (
        make_token(ec_key, expires_in=-10),
        make_token(ec_key, audience="anon"),
        make_token(ec_key, issuer="https://elsewhere/auth/v1"),
        make_token(ec_key, kid="unknown"),
    ):
        try:
            run(verify_token(token, cfg, cache))
        except AuthenticationError as exc:
            messages.add(str(exc))
    assert len(messages) == 1

"""Shared test material: real signing keys, and a hard stop on real network calls.

The JWT tests need genuine ECC P-256 and RSA keys, because the whole point is that a
signature either verifies or does not. They are generated per session and never leave the
process.
"""

from __future__ import annotations

import asyncio
import socket
import time
from dataclasses import dataclass
from typing import Any

import jwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec, rsa
from jwt.algorithms import ECAlgorithm, RSAAlgorithm

SUPABASE_URL = "https://dyvokrgvjrmikcnskxmv.supabase.co"
ISSUER = f"{SUPABASE_URL}/auth/v1"
JWKS_URL = f"{ISSUER}/.well-known/jwks.json"
AUDIENCE = "authenticated"
USER_ID = "11111111-2222-3333-4444-555555555555"
OTHER_USER_ID = "99999999-8888-7777-6666-555555555555"

EC_KID = "ec-key-1"
RSA_KID = "rsa-key-1"

_MESSAGE = "a test tried to open a real connection; mock it with respx"


def _blocked(*_args: Any, **_kwargs: Any) -> Any:
    raise AssertionError(_MESSAGE)


async def _blocked_async(*_args: Any, **_kwargs: Any) -> Any:
    raise AssertionError(_MESSAGE)


@pytest.fixture(autouse=True)
def no_real_network(monkeypatch: pytest.MonkeyPatch) -> None:
    """Nothing in this suite may reach Supabase, Gemini or anything else.

    The block is at the **socket** layer rather than inside httpcore. respx replaces
    httpcore's connection pools while it is active, and a guard installed at that same
    level either fights respx for the attribute or hides it; blocking one layer lower
    leaves respx free to work and still catches anything that escapes it.
    """
    monkeypatch.setattr(socket.socket, "connect", _blocked, raising=False)
    monkeypatch.setattr(socket.socket, "connect_ex", _blocked, raising=False)
    monkeypatch.setattr(socket, "create_connection", _blocked, raising=False)
    monkeypatch.setattr(
        asyncio.base_events.BaseEventLoop, "create_connection", _blocked_async, raising=False
    )
    monkeypatch.setattr(
        asyncio.base_events.BaseEventLoop, "sock_connect", _blocked_async, raising=False
    )


@dataclass(frozen=True)
class KeyMaterial:
    """One key pair, in every form the tests need."""

    kid: str
    algorithm: str
    private: Any
    public: Any
    jwk: dict[str, Any]
    public_pem: str


def _ec_material(kid: str = EC_KID) -> KeyMaterial:
    private = ec.generate_private_key(ec.SECP256R1())
    public = private.public_key()
    jwk = dict(ECAlgorithm.to_jwk(public, as_dict=True))
    jwk.update({"kid": kid, "alg": "ES256", "use": "sig"})
    pem = public.public_bytes(
        serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo
    ).decode()
    return KeyMaterial(kid=kid, algorithm="ES256", private=private, public=public, jwk=jwk, public_pem=pem)


def _rsa_material(kid: str = RSA_KID) -> KeyMaterial:
    private = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    public = private.public_key()
    jwk = dict(RSAAlgorithm.to_jwk(public, as_dict=True))
    jwk.update({"kid": kid, "alg": "RS256", "use": "sig"})
    jwk.pop("key_ops", None)
    pem = public.public_bytes(
        serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo
    ).decode()
    return KeyMaterial(kid=kid, algorithm="RS256", private=private, public=public, jwk=jwk, public_pem=pem)


@pytest.fixture(scope="session")
def ec_key() -> KeyMaterial:
    return _ec_material()


@pytest.fixture(scope="session")
def rsa_key() -> KeyMaterial:
    return _rsa_material()


@pytest.fixture(scope="session")
def jwks_body(ec_key: KeyMaterial, rsa_key: KeyMaterial) -> dict[str, Any]:
    return {"keys": [ec_key.jwk, rsa_key.jwk]}


def make_token(
    key: KeyMaterial | str,
    *,
    algorithm: str | None = None,
    kid: str | None = None,
    subject: str = USER_ID,
    audience: str | list[str] = AUDIENCE,
    issuer: str = ISSUER,
    expires_in: int = 3600,
    issued_at: int | None = None,
    extra: dict[str, Any] | None = None,
    omit: tuple[str, ...] = (),
) -> str:
    """Mint a token. Everything a test wants to break is a parameter."""
    now = int(time.time())
    claims: dict[str, Any] = {
        "sub": subject,
        "aud": audience,
        "iss": issuer,
        "iat": issued_at if issued_at is not None else now,
        "exp": now + expires_in,
        "role": "authenticated",
        "email": "owner@example.test",
    }
    claims.update(extra or {})
    for name in omit:
        claims.pop(name, None)

    if isinstance(key, KeyMaterial):
        alg = algorithm or key.algorithm
        signing_key: Any = key.private
        headers = {"kid": kid if kid is not None else key.kid}
    else:
        alg = algorithm or "HS256"
        signing_key = key
        headers = {"kid": kid} if kid else {}
    return jwt.encode(claims, signing_key, algorithm=alg, headers=headers)


def forge_hs256(
    secret: bytes | str,
    *,
    header: dict[str, Any],
    claims: dict[str, Any] | None = None,
    subject: str = USER_ID,
    audience: str = AUDIENCE,
    issuer: str = ISSUER,
) -> str:
    """Build an HS256 token by hand, with any header we like.

    PyJWT refuses to sign HS256 with a PEM public key, which is a good defence in the
    signing library but gets in the way of testing *our verifier* against the algorithm
    confusion attack. An attacker has no such scruples, so neither does this helper.
    """
    import base64
    import hashlib
    import hmac
    import json as _json

    now = int(time.time())
    body: dict[str, Any] = {
        "sub": subject,
        "aud": audience,
        "iss": issuer,
        "iat": now,
        "exp": now + 600,
        "role": "authenticated",
    }
    body.update(claims or {})

    def segment(data: dict[str, Any]) -> bytes:
        raw = _json.dumps(data, separators=(",", ":"), sort_keys=True).encode()
        return base64.urlsafe_b64encode(raw).rstrip(b"=")

    signing_input = segment(header) + b"." + segment(body)
    key = secret.encode() if isinstance(secret, str) else secret
    signature = hmac.new(key, signing_input, hashlib.sha256).digest()
    return (signing_input + b"." + base64.urlsafe_b64encode(signature).rstrip(b"=")).decode()

"""Supabase access-token verification.

The owner's project signs access tokens with **asymmetric keys (ECC P-256, ES256)** and
publishes the public half at ``{SUPABASE_URL}/auth/v1/.well-known/jwks.json``. A legacy
HS256 shared secret is retained only for tokens issued before the rotation.

What this module refuses to do, and why each refusal matters:

* **It never lets the token choose its own algorithm family.** ``alg`` in the header is
  attacker-controlled. The classic break is to take the *public* key we publish, sign a
  token with HS256 using that public key as the shared secret, and hand it to a verifier
  that picks the key by ``kid`` and the algorithm by ``alg``. Here, ES256 and RS256 are
  verified **only** against a JWKS key and HS256 **only** against ``SUPABASE_JWT_SECRET``.
  A JWKS key can never be used as an HMAC secret, so that attack has nowhere to land.
* **It never accepts ``alg: none``**, or any algorithm outside the allow-list.
* **It never trusts an unknown ``kid`` to cost us an outbound request.** An unknown
  ``kid`` does trigger a JWKS refetch -- that is how key rotation is picked up without a
  deploy -- but the refetch is rate limited two ways (a minimum interval and a ceiling
  per TTL window), so a stream of forged ``kid`` values cannot turn this service into a
  request amplifier against Supabase.
* **It verifies ``exp``, ``iat``, ``aud`` and ``iss``**, and requires ``sub``.
* **It never logs, echoes or embeds a token** -- not in an error message, not in a repr.

The verified ``sub`` claim is the user id. Everything downstream keys off it, and the
raw token is carried onward only so PostgREST can run the query *as that user* and let
Row Level Security be the enforcement boundary.
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Any

import httpx
import jwt
from jwt import PyJWK, PyJWTError

from app.core.config import Settings
from app.core.errors import AuthenticationError, UpstreamUnavailable
from app.core.logging import get_logger

log = get_logger("app.core.security")

#: Asymmetric algorithms, verified against a JWKS key and nothing else.
ASYMMETRIC_ALGORITHMS: frozenset[str] = frozenset({"ES256", "RS256"})

#: The legacy symmetric algorithm, verified against SUPABASE_JWT_SECRET and nothing else.
SYMMETRIC_ALGORITHMS: frozenset[str] = frozenset({"HS256"})

#: JWK ``kty`` that may be used for each algorithm. A P-256 key can never satisfy RS256
#: and an RSA key can never satisfy ES256, so a mislabelled JWKS entry is rejected.
_KTY_FOR_ALG: dict[str, str] = {"ES256": "EC", "RS256": "RSA"}

#: One message for every authentication failure. The reason is logged, never returned:
#: a verifier that says "wrong issuer" vs "expired" is an oracle for forging tokens.
_GENERIC = "Your sign-in could not be verified. Please sign in again."


@dataclass(frozen=True)
class Principal:
    """The verified caller.

    ``token`` is the caller's own access token, kept so repositories can talk to
    PostgREST as this user. It is excluded from ``repr`` and from every log line.
    """

    user_id: str
    token: str = field(repr=False)
    email: str | None = None
    role: str = "authenticated"
    session_id: str | None = None
    expires_at: int | None = None
    algorithm: str = ""

    def __repr__(self) -> str:  # pragma: no cover - trivial
        return f"Principal(user_id={self.user_id!r}, role={self.role!r}, token=<redacted>)"

    __str__ = __repr__


def _fail(reason: str, **fields: Any) -> AuthenticationError:
    """Log why, return the same opaque error to the caller every time."""
    log.info("token rejected", reason=reason, **fields)
    return AuthenticationError(_GENERIC)


# --------------------------------------------------------------------------- JWKS


class JwksCache:
    """In-memory JWKS with a TTL and a rate-limited refetch on an unknown ``kid``.

    One instance per process, held on ``app.state``. It is safe to share between
    requests: the only mutation is replacing the key dict wholesale.
    """

    def __init__(
        self,
        settings: Settings,
        *,
        client: httpx.AsyncClient | None = None,
        clock: Any = time.monotonic,
    ) -> None:
        self._settings = settings
        self._client = client
        self._owns_client = client is None
        self._clock = clock
        self._keys: dict[str, dict[str, Any]] = {}
        self._fetched_at: float | None = None
        self._last_attempt_at: float | None = None
        self._window_started_at: float | None = None
        self._refetches_in_window = 0

    # -- lifecycle ---------------------------------------------------------

    async def aclose(self) -> None:
        if self._client is not None and self._owns_client:
            await self._client.aclose()
            self._client = None

    def _http(self) -> httpx.AsyncClient:
        if self._client is None:
            self._client = httpx.AsyncClient(
                timeout=httpx.Timeout(self._settings.jwks_timeout_seconds)
            )
            self._owns_client = True
        return self._client

    # -- state -------------------------------------------------------------

    @property
    def kids(self) -> frozenset[str]:
        return frozenset(self._keys)

    def _is_fresh(self) -> bool:
        if self._fetched_at is None:
            return False
        return (self._clock() - self._fetched_at) < self._settings.jwks_cache_ttl_seconds

    def _may_refetch(self) -> bool:
        """Rate limit: a minimum gap between attempts *and* a ceiling per TTL window."""
        now = self._clock()
        settings = self._settings
        if (
            self._last_attempt_at is not None
            and (now - self._last_attempt_at) < settings.jwks_min_refetch_seconds
        ):
            return False
        if (
            self._window_started_at is None
            or (now - self._window_started_at) >= settings.jwks_cache_ttl_seconds
        ):
            self._window_started_at = now
            self._refetches_in_window = 0
        return self._refetches_in_window < settings.jwks_max_refetches_per_window

    # -- fetching ----------------------------------------------------------

    async def _fetch(self) -> None:
        now = self._clock()
        self._last_attempt_at = now
        self._refetches_in_window += 1
        url = self._settings.jwks_url
        try:
            response = await self._http().get(url, headers={"Accept": "application/json"})
        except httpx.HTTPError as exc:
            log.warning("jwks fetch failed", error_type=type(exc).__name__)
            raise UpstreamUnavailable("Sign-in checks are temporarily unavailable.") from None
        if response.status_code >= 400:
            log.warning("jwks fetch rejected", status=response.status_code)
            raise UpstreamUnavailable("Sign-in checks are temporarily unavailable.")
        try:
            body = response.json()
        except ValueError:
            log.warning("jwks body was not json")
            raise UpstreamUnavailable("Sign-in checks are temporarily unavailable.") from None

        keys = body.get("keys") if isinstance(body, dict) else None
        if not isinstance(keys, list):
            log.warning("jwks body had no key list")
            raise UpstreamUnavailable("Sign-in checks are temporarily unavailable.")

        parsed: dict[str, dict[str, Any]] = {}
        for key in keys:
            if not isinstance(key, dict):
                continue
            kid = key.get("kid")
            kty = key.get("kty")
            # A JWKS entry with no kid cannot be selected unambiguously, and an
            # octet ("oct") entry is a shared secret -- neither belongs here.
            if not isinstance(kid, str) or not kid or kty not in ("EC", "RSA"):
                continue
            parsed[kid] = key

        self._keys = parsed
        self._fetched_at = now
        log.info("jwks refreshed", key_count=len(parsed))

    async def get(self, kid: str) -> dict[str, Any] | None:
        """The JWK for ``kid``, refetching once if it is unknown and we are allowed to."""
        if self._is_fresh() and kid in self._keys:
            return self._keys[kid]
        if not self._is_fresh() or kid not in self._keys:
            if self._fetched_at is None or self._may_refetch():
                await self._fetch()
            elif not self._keys:
                raise UpstreamUnavailable("Sign-in checks are temporarily unavailable.")
        return self._keys.get(kid)


# ------------------------------------------------------------------- verification


def _header_of(token: str, settings: Settings) -> dict[str, Any]:
    if not token or len(token.encode("utf-8", "ignore")) > settings.max_token_bytes:
        raise _fail("token missing or oversized")
    try:
        header = jwt.get_unverified_header(token)
    except PyJWTError as exc:
        raise _fail("header unparseable", error_type=type(exc).__name__) from None
    if not isinstance(header, dict):
        raise _fail("header not an object")
    return header


def _algorithm_of(header: dict[str, Any], settings: Settings) -> str:
    alg = header.get("alg")
    if not isinstance(alg, str):
        raise _fail("no alg in header")
    alg = alg.upper()
    if alg in ("NONE", ""):
        # Explicit, because this is the failure everyone writes about.
        raise _fail("alg none")
    if alg in ASYMMETRIC_ALGORITHMS:
        return alg
    if alg in SYMMETRIC_ALGORITHMS:
        if not settings.legacy_hs256_enabled:
            raise _fail("hs256 offered but SUPABASE_JWT_SECRET is not set")
        return alg
    raise _fail("unsupported alg", alg=alg)


def _decode(token: str, key: Any, algorithm: str, settings: Settings) -> dict[str, Any]:
    """One algorithm, one key, all registered claims required."""
    try:
        claims = jwt.decode(
            token,
            key=key,
            # A single-element list: the token cannot negotiate anything else.
            algorithms=[algorithm],
            audience=settings.jwt_audience,
            issuer=settings.jwt_issuer,
            leeway=settings.jwt_leeway_seconds,
            options={
                "require": ["exp", "iat", "sub", "aud", "iss"],
                "verify_signature": True,
                "verify_exp": True,
                "verify_iat": True,
                "verify_aud": True,
                "verify_iss": True,
            },
        )
    except jwt.ExpiredSignatureError:
        raise _fail("expired") from None
    except jwt.InvalidAudienceError:
        raise _fail("wrong audience") from None
    except jwt.InvalidIssuerError:
        raise _fail("wrong issuer") from None
    except jwt.MissingRequiredClaimError as exc:
        raise _fail("missing claim", claim=str(getattr(exc, "claim", ""))) from None
    except PyJWTError as exc:
        raise _fail("signature invalid", error_type=type(exc).__name__) from None
    if not isinstance(claims, dict):
        raise _fail("claims not an object")
    return claims


async def _asymmetric_key(header: dict[str, Any], algorithm: str, jwks: JwksCache) -> Any:
    kid = header.get("kid")
    if not isinstance(kid, str) or not kid:
        raise _fail("asymmetric token without kid")
    jwk = await jwks.get(kid)
    if jwk is None:
        raise _fail("unknown kid")
    # The key type must match the algorithm we were told to use. Without this an
    # RSA entry could be pressed into an ES256 verification (or the reverse), which
    # is the same class of confusion as picking the algorithm from the header.
    if jwk.get("kty") != _KTY_FOR_ALG[algorithm]:
        raise _fail("kid names a key of the wrong type", alg=algorithm)
    try:
        return PyJWK.from_dict(dict(jwk), algorithm=algorithm).key
    except (PyJWTError, ValueError, KeyError, TypeError) as exc:
        raise _fail("jwk unusable", error_type=type(exc).__name__) from None


async def verify_token(token: str, settings: Settings, jwks: JwksCache) -> Principal:
    """Verify a Supabase access token and return the caller it names.

    Raises :class:`~app.core.errors.AuthenticationError` on every rejection, with the
    same message every time.
    """
    header = _header_of(token, settings)
    algorithm = _algorithm_of(header, settings)

    if algorithm in ASYMMETRIC_ALGORITHMS:
        key: Any = await _asymmetric_key(header, algorithm, jwks)
    else:
        # Legacy path only. The JWKS is not consulted here, and a JWKS key is never
        # offered as an HMAC secret -- that is what makes alg confusion impossible.
        log.warning(
            "accepted a legacy HS256 token; SUPABASE_JWT_SECRET should be removed once "
            "every token issued before the key rotation has expired",
            alg=algorithm,
        )
        key = settings.supabase_jwt_secret

    claims = _decode(token, key, algorithm, settings)

    subject = claims.get("sub")
    if not isinstance(subject, str) or not subject.strip():
        raise _fail("no usable sub claim")

    role = claims.get("role")
    email = claims.get("email")
    expires_at = claims.get("exp")
    return Principal(
        user_id=subject.strip(),
        token=token,
        email=email if isinstance(email, str) else None,
        role=role if isinstance(role, str) and role else "authenticated",
        session_id=claims.get("session_id") if isinstance(claims.get("session_id"), str) else None,
        expires_at=int(expires_at) if isinstance(expires_at, int | float) else None,
        algorithm=algorithm,
    )


def bearer_token(authorization: str | None) -> str:
    """Pull the token out of an ``Authorization`` header, or reject."""
    if not authorization:
        raise _fail("no authorization header")
    scheme, _, value = authorization.partition(" ")
    if scheme.lower() != "bearer" or not value.strip():
        raise _fail("authorization header was not a bearer token")
    return value.strip()

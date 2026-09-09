"""No test in this directory is allowed to touch the network.

The guard replaces the httpcore connection pools -- the same layer respx swaps out while a
mocked test runs -- so respx wins wherever a test mocks properly, and this bites only where
a test forgot to. The stand-ins keep httpcore's real names and signatures because respx
autospecs whatever it finds at that attribute.
"""

from __future__ import annotations

from typing import Any

import httpcore
import pytest

_MESSAGE = "a test tried to make a real HTTP request; mock it with respx"


def handle_request(self: Any, request: Any) -> Any:
    raise AssertionError(_MESSAGE)


async def handle_async_request(self: Any, request: Any) -> Any:
    raise AssertionError(_MESSAGE)


@pytest.fixture(autouse=True)
def _no_real_network(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(httpcore.ConnectionPool, "handle_request", handle_request, raising=False)
    monkeypatch.setattr(
        httpcore.AsyncConnectionPool, "handle_async_request", handle_async_request, raising=False
    )

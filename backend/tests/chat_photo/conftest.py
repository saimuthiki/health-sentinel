"""Fixtures for the chat-photo tests.

The in-memory Supabase, the fake Gemini and the wired-up application all live in
``tests/api/conftest.py``. They are re-exported here rather than rebuilt, because a second
fake that drifts from the first would let these tests pass against behaviour the rest of
the suite would reject. A conftest is where pytest looks for fixtures, so importing the
names into one is all that is needed to make them available in this directory.
"""

from __future__ import annotations

from tests.api.conftest import (  # noqa: F401  (imported to register the fixtures)
    app,
    auth,
    client,
    gemini,
    settings,
    store,
    token,
)

"""System prompts, kept as files so they can be edited and reviewed like prose.

Every prompt is served with the safety charter appended, so the MUST NOT list is always
the last thing the model reads. Nothing here interpolates user data: user data goes in the
``contents`` of the request (see ``app.ai.context``), never into the system instruction.
"""

from __future__ import annotations

from functools import lru_cache
from pathlib import Path

PROMPT_DIR = Path(__file__).resolve().parent
SUFFIX = ".md"
CHARTER_NAME = "_charter"

#: Prompt file for each routed task (``app.ai.routing.Task``).
PROMPT_FOR_TASK: dict[str, str] = {
    "extract_report": "extract_report",
    "chat": "chat",
    "plan_day": "plan_day",
    "plan_week": "plan_week",
    "weekly_review": "weekly_review",
    "safety_judge": "safety_judge",
}


class PromptNotFound(KeyError):
    """Asked for a prompt file that does not exist."""


def available() -> list[str]:
    """Every prompt name, charter excluded."""
    return sorted(p.stem for p in PROMPT_DIR.glob(f"*{SUFFIX}") if p.stem != CHARTER_NAME)


@lru_cache(maxsize=32)
def raw(name: str) -> str:
    """The prompt file as written, without the charter."""
    path = PROMPT_DIR / f"{name}{SUFFIX}"
    if not path.is_file():
        raise PromptNotFound(f"no prompt named {name!r} in {PROMPT_DIR}")
    return path.read_text(encoding="utf-8").strip()


@lru_cache(maxsize=1)
def charter() -> str:
    """The MUST NOT block that terminates every prompt."""
    return (PROMPT_DIR / f"{CHARTER_NAME}{SUFFIX}").read_text(encoding="utf-8").strip()


@lru_cache(maxsize=32)
def load(name: str) -> str:
    """The system prompt for ``name``: the file, then the charter, always last."""
    return f"{raw(name)}\n\n---\n\n{charter()}\n"


def for_task(task: str) -> str:
    """The system prompt for a routing task name."""
    try:
        return load(PROMPT_FOR_TASK[str(task)])
    except KeyError as exc:
        raise PromptNotFound(f"no prompt mapped for task {task!r}") from exc

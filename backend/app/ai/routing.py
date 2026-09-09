"""Task -> model routing.

One dict. Swapping a model is a one-line change here and needs no app update, which is
the whole point of keeping model choice on the server (see docs/02-architecture.md §2).

Every model is also overridable at runtime by an environment variable, so a bad model
release can be rolled back without a deploy:

    GEMINI_MODEL_EXTRACT_REPORT=gemini-2.0-flash
"""

from __future__ import annotations

import os
from enum import StrEnum

ENV_PREFIX = "GEMINI_MODEL_"

FLASH = "gemini-2.5-flash"
PRO = "gemini-2.5-pro"


class Task(StrEnum):
    """Every distinct thing we ask a model to do."""

    EXTRACT_REPORT = "extract_report"
    CHAT = "chat"
    PLAN_DAY = "plan_day"
    PLAN_WEEK = "plan_week"
    WEEKLY_REVIEW = "weekly_review"
    SAFETY_JUDGE = "safety_judge"


#: The routing table. Flash everywhere except the two genuinely multi-step reasoning
#: tasks, which run once a week and can afford Pro.
MODELS: dict[Task, str] = {
    Task.EXTRACT_REPORT: FLASH,
    Task.CHAT: FLASH,
    Task.PLAN_DAY: FLASH,
    Task.PLAN_WEEK: PRO,
    Task.WEEKLY_REVIEW: PRO,
    Task.SAFETY_JUDGE: FLASH,
}


#: Older, coarser names already documented in ``.env.example``. Read only when the
#: canonical ``GEMINI_MODEL_<TASK>`` variable is unset, so an operator who set
#: ``GEMINI_MODEL_PLAN`` still gets what they expected.
LEGACY_ENV_VARS: dict[Task, tuple[str, ...]] = {
    Task.EXTRACT_REPORT: ("GEMINI_MODEL_EXTRACT",),
    Task.CHAT: (),
    Task.PLAN_DAY: ("GEMINI_MODEL_PLAN",),
    Task.PLAN_WEEK: ("GEMINI_MODEL_PLAN_WEEKLY", "GEMINI_MODEL_PLAN"),
    Task.WEEKLY_REVIEW: ("GEMINI_MODEL_REVIEW",),
    Task.SAFETY_JUDGE: ("GEMINI_MODEL_JUDGE",),
}


def env_var_for(task: Task | str) -> str:
    """Environment variable that overrides the model for ``task``."""
    name = task.value if isinstance(task, Task) else str(task)
    return f"{ENV_PREFIX}{name.upper()}"


def model_for(task: Task | str) -> str:
    """Model id for ``task``; the environment wins over the table.

    Read at call time (not import time) so an override applies without a restart and so
    tests can monkeypatch the environment.
    """
    key = Task(task) if not isinstance(task, Task) else task
    for name in (env_var_for(key), *LEGACY_ENV_VARS.get(key, ())):
        override = os.environ.get(name, "").strip()
        if override:
            return override
    return MODELS[key]


def routing_table() -> dict[str, str]:
    """The effective table, environment overrides applied. For /healthz and logs."""
    return {task.value: model_for(task) for task in Task}

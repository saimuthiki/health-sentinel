"""Gemini orchestration: transport, routing, response schemas, prompts, context."""

from app.ai.client import (
    AiRun,
    GeminiClient,
    GeminiError,
    GeminiInvalidResponse,
    GeminiRateLimited,
    GeminiResponse,
    GeminiSafetyBlocked,
    GeminiTruncated,
    inline_data_part,
    text_part,
)
from app.ai.context import ContextLimits, build_context_block, summarise_history
from app.ai.routing import MODELS, Task, model_for
from app.ai.schemas import ALL_SCHEMAS, SCHEMA_FOR_TASK, check_schema

__all__ = [
    "ALL_SCHEMAS",
    "MODELS",
    "SCHEMA_FOR_TASK",
    "AiRun",
    "ContextLimits",
    "GeminiClient",
    "GeminiError",
    "GeminiInvalidResponse",
    "GeminiRateLimited",
    "GeminiResponse",
    "GeminiSafetyBlocked",
    "GeminiTruncated",
    "Task",
    "build_context_block",
    "check_schema",
    "inline_data_part",
    "model_for",
    "summarise_history",
    "text_part",
]

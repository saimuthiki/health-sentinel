"""``responseSchema`` objects for Gemini controlled generation.

Gemini's schema dialect is a **subset of OpenAPI 3**. Only these keywords are understood:

    type, properties, required, items, enum, description, nullable, propertyOrdering

``additionalProperties``, ``oneOf``, ``anyOf``, ``allOf``, ``$ref``, ``patternProperties``,
``format`` and the numeric/length constraints are **not** supported and make the API
reject the request. :func:`check_schema` enforces that here, and a test asserts it for
every schema in :data:`ALL_SCHEMAS`, so a forbidden keyword can never reach production.

Two product rules are encoded structurally rather than by asking politely in the prompt:

* the day-plan schema has **no nutrient fields at all** -- there is no slot for the model
  to put a made-up "18 g protein" in, because nutrient maths is redone in Python from the
  ``foods`` table (docs/04-ai-pipeline.md stage 7);
* the day-plan schema has **no escalation field** -- escalation is decided by
  ``app.rules``, never by a model.
"""

from __future__ import annotations

from typing import Any

from app.domain.enums import MealSlot, ReportType, SafetyVerdict, SafetyViolation

#: The only keywords Gemini accepts inside a responseSchema.
ALLOWED_KEYWORDS: frozenset[str] = frozenset(
    {"type", "properties", "required", "items", "enum", "description", "nullable", "propertyOrdering"}
)

#: Keywords that are silently wrong or hard-fail against the API.
FORBIDDEN_KEYWORDS: frozenset[str] = frozenset(
    {
        "additionalProperties",
        "oneOf",
        "anyOf",
        "allOf",
        "not",
        "$ref",
        "$defs",
        "definitions",
        "patternProperties",
        "format",
        "pattern",
        "minimum",
        "maximum",
        "minLength",
        "maxLength",
        "minItems",
        "maxItems",
        "default",
        "examples",
        "title",
        "const",
    }
)


class SchemaError(ValueError):
    """A schema used a keyword Gemini cannot parse."""


def check_schema(schema: Any, path: str = "$") -> None:
    """Raise :class:`SchemaError` if ``schema`` strays outside Gemini's subset."""
    if isinstance(schema, dict):
        for key, value in schema.items():
            here = f"{path}.{key}"
            if key in FORBIDDEN_KEYWORDS:
                raise SchemaError(f"{here}: '{key}' is not supported by Gemini responseSchema")
            if key not in ALLOWED_KEYWORDS:
                raise SchemaError(f"{here}: unknown keyword '{key}'")
            if key == "properties":
                if not isinstance(value, dict):
                    raise SchemaError(f"{here}: properties must be an object")
                for prop_name, prop in value.items():
                    check_schema(prop, f"{here}.{prop_name}")
            elif key in ("items",):
                check_schema(value, here)
            elif key in ("required", "propertyOrdering", "enum"):
                if not isinstance(value, list):
                    raise SchemaError(f"{here}: '{key}' must be a list")
    elif isinstance(schema, list):
        for index, item in enumerate(schema):
            check_schema(item, f"{path}[{index}]")


def _string(description: str, *, nullable: bool = False) -> dict[str, Any]:
    node: dict[str, Any] = {"type": "string", "description": description}
    if nullable:
        node["nullable"] = True
    return node


# ------------------------------------------------------------ stage 2: extraction

EXTRACTED_ROW_SCHEMA: dict[str, Any] = {
    "type": "object",
    "description": "One row exactly as printed on the report. Transcription only.",
    "properties": {
        "printed_test_name": _string("The test name exactly as printed, including spelling and brackets."),
        "value_text": _string("The result exactly as printed, as text. Do not round or convert."),
        "unit_text": _string("The unit exactly as printed, or null if none is printed.", nullable=True),
        "printed_range": _string("The reference range as printed, or null.", nullable=True),
        "method": _string("The method as printed (CLIA, HPLC, ...), or null.", nullable=True),
        "confidence": {
            "type": "number",
            "description": "0.0-1.0 confidence that this row was read correctly.",
        },
    },
    "required": ["printed_test_name", "value_text", "confidence"],
    "propertyOrdering": [
        "printed_test_name",
        "value_text",
        "unit_text",
        "printed_range",
        "method",
        "confidence",
    ],
}

REPORT_EXTRACTION_SCHEMA: dict[str, Any] = {
    "type": "object",
    "description": "A transcription of one lab report. No interpretation, no advice.",
    "properties": {
        "lab_name": _string("Laboratory or hospital name as printed, or null.", nullable=True),
        "collected_on": _string(
            "Sample collection date as YYYY-MM-DD, or null if not printed.", nullable=True
        ),
        "report_type": {
            "type": "string",
            "description": "Best match for the kind of report.",
            "enum": [item.value for item in ReportType],
            "nullable": True,
        },
        "rows": {
            "type": "array",
            "description": "Every result row on the page, in printed order.",
            "items": EXTRACTED_ROW_SCHEMA,
        },
    },
    "required": ["rows"],
    "propertyOrdering": ["lab_name", "collected_on", "report_type", "rows"],
}


# ---------------------------------------------------------- stage 6: plan generation

MEAL_PLAN_ITEM_SCHEMA: dict[str, Any] = {
    "type": "object",
    "description": (
        "One item in one meal. Chosen from the CANDIDATES list by id. "
        "There is deliberately no nutrient field: the backend computes nutrients."
    ),
    "properties": {
        "meal_slot": {
            "type": "string",
            "description": "Which meal this item belongs to.",
            "enum": [item.value for item in MealSlot],
        },
        "food_id": _string("The id of a food taken verbatim from the CANDIDATES list."),
        "grams": {
            "type": "number",
            "description": "Edible portion in grams. A portion size, never a dose.",
        },
        "why": _string(
            "One short sentence on why this food suits this user today. "
            "Describe the benefit in words only; state no numbers and no nutrient amounts."
        ),
        "order_index": {"type": "integer", "description": "Order within the meal, from 0."},
    },
    "required": ["meal_slot", "food_id", "grams", "why"],
    "propertyOrdering": ["meal_slot", "food_id", "grams", "why", "order_index"],
}

DAY_PLAN_SCHEMA: dict[str, Any] = {
    "type": "object",
    "description": "One day of eating, composed only from the supplied candidate foods.",
    "properties": {
        "items": {
            "type": "array",
            "description": "Every item across every meal of the day.",
            "items": MEAL_PLAN_ITEM_SCHEMA,
        },
        "hydration_ml": {
            "type": "integer",
            "description": "Total plain water for the day in millilitres.",
        },
        "rationale": _string(
            "Two or three sentences on the shape of the day. No nutrient numbers, "
            "no medication, no dose, no diagnosis."
        ),
    },
    "required": ["items", "hydration_ml", "rationale"],
    "propertyOrdering": ["items", "hydration_ml", "rationale"],
}

WEEK_PLAN_SCHEMA: dict[str, Any] = {
    "type": "object",
    "description": "Seven days of eating, same rules as a day plan.",
    "properties": {
        "days": {
            "type": "array",
            "description": "One entry per planned day, in date order.",
            "items": {
                "type": "object",
                "properties": {
                    "plan_date": _string("The date this day covers, as YYYY-MM-DD."),
                    "items": {"type": "array", "items": MEAL_PLAN_ITEM_SCHEMA},
                    "hydration_ml": {"type": "integer", "description": "Plain water in millilitres."},
                    "rationale": _string("Two or three sentences. No numbers, no medication, no dose."),
                },
                "required": ["plan_date", "items", "hydration_ml"],
                "propertyOrdering": ["plan_date", "items", "hydration_ml", "rationale"],
            },
        }
    },
    "required": ["days"],
    "propertyOrdering": ["days"],
}


# ------------------------------------------------------------------- chat + memory

CHAT_REPLY_SCHEMA: dict[str, Any] = {
    "type": "object",
    "description": "One coaching reply, with clarifying questions where they are needed.",
    "properties": {
        "reply": _string(
            "The reply to the user, in plain English. No medication name, no dose, "
            "no diagnosis, no advice to change any treatment."
        ),
        "follow_up_questions": {
            "type": "array",
            "description": (
                "Clarifying questions to ask BEFORE advising when the user reports a "
                "symptom: onset, sudden or gradual, recent illness, stress, associated "
                "symptoms. Empty when nothing needs clarifying."
            ),
            "items": {"type": "string"},
        },
        "needs_more_info": {
            "type": "boolean",
            "description": "True when the reply is asking questions rather than advising.",
        },
    },
    "required": ["reply", "follow_up_questions", "needs_more_info"],
    "propertyOrdering": ["reply", "follow_up_questions", "needs_more_info"],
}

MEMORY_FACT_SCHEMA: dict[str, Any] = {
    "type": "object",
    "description": "One atomic, durable fact about the user, taken from what they said.",
    "properties": {
        "fact": _string("The fact in one short sentence, in the third person."),
        "category": {
            "type": "string",
            "description": "What kind of fact this is.",
            "enum": [
                "diet",
                "habit",
                "preference",
                "symptom",
                "goal",
                "constraint",
                "schedule",
                "other",
            ],
        },
        "confidence": {"type": "number", "description": "0.0-1.0 confidence in this fact."},
        "evidence": _string("The user's own words that support this fact."),
    },
    "required": ["fact", "category", "confidence", "evidence"],
    "propertyOrdering": ["fact", "category", "confidence", "evidence"],
}

MEMORY_EXTRACTION_SCHEMA: dict[str, Any] = {
    "type": "object",
    "description": "Durable facts worth remembering from this conversation turn.",
    "properties": {
        "facts": {
            "type": "array",
            "description": "Empty when the turn contained nothing durable.",
            "items": MEMORY_FACT_SCHEMA,
        }
    },
    "required": ["facts"],
    "propertyOrdering": ["facts"],
}


# ----------------------------------------------------------------- safety judge

SAFETY_JUDGE_SCHEMA: dict[str, Any] = {
    "type": "object",
    "description": "Adjudication of one candidate answer against the safety charter.",
    "properties": {
        "verdict": {
            "type": "string",
            "description": "'pass' only when the text breaks none of the rules.",
            "enum": [SafetyVerdict.PASS.value, SafetyVerdict.BLOCKED.value],
        },
        "violations": {
            "type": "array",
            "description": "Every rule the text breaks. Empty when the verdict is pass.",
            "items": {
                "type": "string",
                "enum": [item.value for item in SafetyViolation],
            },
        },
        "quotes": {
            "type": "array",
            "description": "The exact offending substrings, copied verbatim from the text.",
            "items": {"type": "string"},
        },
        "reason": _string("One sentence explaining the verdict."),
    },
    "required": ["verdict", "violations", "quotes", "reason"],
    "propertyOrdering": ["verdict", "violations", "quotes", "reason"],
}


ALL_SCHEMAS: dict[str, dict[str, Any]] = {
    "report_extraction": REPORT_EXTRACTION_SCHEMA,
    "day_plan": DAY_PLAN_SCHEMA,
    "week_plan": WEEK_PLAN_SCHEMA,
    "chat_reply": CHAT_REPLY_SCHEMA,
    "memory_extraction": MEMORY_EXTRACTION_SCHEMA,
    "safety_judge": SAFETY_JUDGE_SCHEMA,
}

#: Schema to use for each routed task (``app.ai.routing.Task``).
SCHEMA_FOR_TASK: dict[str, dict[str, Any]] = {
    "extract_report": REPORT_EXTRACTION_SCHEMA,
    "chat": CHAT_REPLY_SCHEMA,
    "plan_day": DAY_PLAN_SCHEMA,
    "plan_week": WEEK_PLAN_SCHEMA,
    "safety_judge": SAFETY_JUDGE_SCHEMA,
}

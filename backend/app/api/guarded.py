"""The API boundary's guarantee: no unguarded string reaches a user.

The safety validator in :mod:`app.safety` only sees text that is routed through
:func:`app.safety.pipeline.guard`. Relying on every future contributor to remember that
is not a control. So the enforcement lives in the **type system of the response models**:

* :class:`GuardedText` is a ``str`` subclass whose constructor refuses to run unless it
  is handed a module-private token. Nothing outside this module can mint one.
* Its pydantic schema is ``is_instance(GuardedText)`` with **no coercion from ``str``**.
  A response model field typed ``GuardedText`` therefore cannot be populated with a
  plain string: pydantic raises, FastAPI's response serialisation fails, and the
  endpoint returns a 500 instead of an unvalidated model answer.
* The only two ways to obtain one are :func:`run_guarded`, which calls
  ``app.safety.pipeline.guard``, and :func:`guarded_deterministic`, which is for text
  *this codebase* generated from the database and which still runs the deterministic
  validator over it before minting.

So "I forgot to guard this" is not a code review question. It is a failing request, and
``tests/api/test_guard_enforcement.py`` asserts it for a deliberately-unsafe endpoint and
audits every response model on the real app for the same property.
"""

from __future__ import annotations

from collections.abc import Awaitable, Callable, Iterable, Sequence
from typing import Any

from pydantic import GetCoreSchemaHandler, GetJsonSchemaHandler
from pydantic.json_schema import JsonSchemaValue
from pydantic_core import core_schema

from app.core.errors import UnguardedText
from app.core.logging import get_logger
from app.domain.enums import Escalation, SafetyVerdict
from app.domain.models import SafetyReport
from app.safety.pipeline import guard as _pipeline_guard
from app.safety.validator import validate as _validate

log = get_logger("app.api.guarded")

#: The mint token. Module-private on purpose; there is no accessor for it.
_MINT = object()


class GuardedText(str):
    """A string that has been through the safety layer.

    Constructing one directly raises. That is the whole point.
    """

    __slots__ = ()

    def __new__(cls, value: object = "", _token: object = None) -> GuardedText:
        if _token is not _MINT:
            raise UnguardedText(
                "GuardedText cannot be constructed directly. User-visible model text must "
                "come from app.api.guarded.run_guarded(); deterministic text from "
                "guarded_deterministic()."
            )
        return super().__new__(cls, value)

    # -- pydantic ----------------------------------------------------------

    @classmethod
    def __get_pydantic_core_schema__(
        cls, _source: Any, _handler: GetCoreSchemaHandler
    ) -> core_schema.CoreSchema:
        # is_instance, deliberately: there is no str -> GuardedText coercion, so a
        # plain string assigned to a GuardedText field is a validation error.
        return core_schema.json_or_python_schema(
            json_schema=core_schema.is_instance_schema(cls),
            python_schema=core_schema.is_instance_schema(cls),
            serialization=core_schema.plain_serializer_function_ser_schema(
                str, return_schema=core_schema.str_schema(), when_used="always"
            ),
        )

    @classmethod
    def __get_pydantic_json_schema__(
        cls, _schema: core_schema.CoreSchema, _handler: GetJsonSchemaHandler
    ) -> JsonSchemaValue:
        return {"type": "string", "description": "Text that passed the safety layer."}


def _mint(value: str) -> GuardedText:
    return GuardedText(value, _MINT)


class Guarded:
    """The result of one guarded generation.

    ``text`` is what the user sees: escalation card, body, disclaimer -- assembled by
    :mod:`app.safety.pipeline`, not by us. ``part`` mints a fragment (a follow-up
    question, say) **only if that fragment was inside the text the validator actually
    scanned**, so a second, unvalidated string cannot ride along beside a guarded one.
    """

    __slots__ = ("_report", "_scanned")

    def __init__(self, report: SafetyReport, scanned: str) -> None:
        self._report = report
        self._scanned = scanned

    @property
    def report(self) -> SafetyReport:
        return self._report

    @property
    def verdict(self) -> SafetyVerdict:
        return self._report.verdict

    @property
    def blocked(self) -> bool:
        return self._report.verdict is SafetyVerdict.BLOCKED

    @property
    def text(self) -> GuardedText:
        """The display text. Always safe to return, including when blocked."""
        return _mint(self._report.text)

    def part(self, fragment: str) -> GuardedText:
        """Mint a fragment of the validated output."""
        cleaned = (fragment or "").strip()
        if not cleaned:
            raise UnguardedText("cannot guard an empty fragment")
        if self.blocked or cleaned not in self._scanned:
            raise UnguardedText(
                "fragment was not part of the text the safety validator scanned"
            )
        return _mint(cleaned)

    def parts(self, fragments: Iterable[str]) -> list[GuardedText]:
        """Every fragment that survived the same guarded pass; the rest are dropped.

        Dropping is the safe direction: a blocked or unmatched follow-up question simply
        does not appear.
        """
        out: list[GuardedText] = []
        for fragment in fragments:
            try:
                out.append(self.part(fragment))
            except UnguardedText:
                log.warning("dropped a fragment that was not in the guarded text")
        return out


#: ``generate(feedback)`` -> the candidate user-visible text. ``feedback`` is None on the
#: first attempt and the quoted violation on the retry. Sync or async.
GenerateFn = Callable[[str | None], "str | Awaitable[str]"]


async def run_guarded(
    generate: GenerateFn,
    escalation: Escalation = Escalation.ROUTINE,
    *,
    judge: Any | None = None,
    max_retries: int = 1,
) -> Guarded:
    """Generate under :func:`app.safety.pipeline.guard` and return mintable text.

    This is the **only** route from a model to a user in this service.
    """
    scanned: list[str] = [""]

    async def _capture(feedback: str | None) -> str:
        produced = generate(feedback)
        if hasattr(produced, "__await__"):
            produced = await produced  # type: ignore[misc]
        text = str(produced)
        scanned[0] = text
        return text

    report = await _pipeline_guard(
        _capture, escalation, max_retries, judge=judge, on_error="block"
    )
    return Guarded(report, scanned[0])


def guarded_deterministic(
    text: str, escalation: Escalation = Escalation.ROUTINE
) -> GuardedText:
    """Mint text **this codebase** produced, after scanning it anyway.

    For strings assembled from our own tables and constants -- a ``why_text`` rebuilt by
    :func:`app.nutrition.why.why_sentence` from the ``foods`` table, an escalation card,
    a red-flag message. Never for model output: model output goes through
    :func:`run_guarded`, which can regenerate and fall back. Here a violation is a bug in
    our own copy, so it raises rather than degrading quietly.
    """
    report = _validate(text, escalation)
    if report.findings:
        log.error(
            "deterministic text failed the safety validator",
            violations=[f.violation.value for f in report.findings],
        )
        raise UnguardedText("deterministic text failed the safety validator")
    return _mint(text)


def guarded_many(
    texts: Sequence[str], escalation: Escalation = Escalation.ROUTINE
) -> list[GuardedText]:
    """:func:`guarded_deterministic` over a sequence."""
    return [guarded_deterministic(text, escalation) for text in texts]


#: Field names that carry text a model may have written. A response model declaring one
#: of these with anything other than ``GuardedText`` is a safety regression, and
#: ``tests/api/test_guard_enforcement.py`` fails the build for it.
MODEL_AUTHORED_FIELDS: frozenset[str] = frozenset(
    {
        "answer",
        "follow_up_questions",
        "message",
        "narrative",
        "rationale",
        "reply",
        "summary",
        "why_text",
    }
)

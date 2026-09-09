"""Gemini transport tests. Every network call is mocked with respx; none leaves the box."""

from __future__ import annotations

import asyncio
import json
import logging
from typing import Any

import httpx
import pytest
import respx

from app.ai.client import (
    API_KEY_ENV,
    API_KEY_HEADER,
    AiRun,
    GeminiClient,
    GeminiError,
    GeminiInvalidResponse,
    GeminiRateLimited,
    GeminiSafetyBlocked,
    GeminiTruncated,
    inline_data_part,
    parse_retry_after,
    prompt_hash,
    text_part,
)

API_KEY = "AIzaSyTOTALLY-not-a-real-key-0123456789"
MODEL = "gemini-2.5-flash"
URL = f"https://generativelanguage.googleapis.com/v1beta/models/{MODEL}:generateContent"


def run(coro: Any) -> Any:
    return asyncio.run(coro)


def ok_body(text: str = "hello", finish_reason: str = "STOP") -> dict[str, Any]:
    return {
        "candidates": [
            {"content": {"parts": [{"text": text}], "role": "model"}, "finishReason": finish_reason}
        ],
        "usageMetadata": {
            "promptTokenCount": 120,
            "candidatesTokenCount": 34,
            "totalTokenCount": 154,
        },
    }


class RecordingSleep:
    """Stands in for asyncio.sleep so backoff is instant and observable."""

    def __init__(self) -> None:
        self.delays: list[float] = []

    async def __call__(self, delay: float) -> None:
        self.delays.append(delay)


def make_client(**kwargs: Any) -> GeminiClient:
    kwargs.setdefault("sleep", RecordingSleep())
    kwargs.setdefault("jitter", lambda: 0.0)
    return GeminiClient(API_KEY, **kwargs)


# ------------------------------------------------------------------- happy path


@respx.mock
def test_generate_returns_text_and_ai_run() -> None:
    route = respx.post(URL).mock(return_value=httpx.Response(200, json=ok_body("plan text")))

    async def scenario() -> Any:
        async with make_client() as client:
            return await client.generate(model=MODEL, parts="say hi", task="chat")

    result = run(scenario())
    assert result.text == "plan text"
    assert isinstance(result.run, AiRun)
    assert result.run.model == MODEL
    assert result.run.task == "chat"
    assert result.run.prompt_tokens == 120
    assert result.run.output_tokens == 34
    assert result.run.total_tokens == 154
    assert result.run.latency_ms >= 0
    assert len(result.run.prompt_sha256) == 64
    assert route.called


@respx.mock
def test_api_key_goes_in_the_header_not_the_url() -> None:
    route = respx.post(URL).mock(return_value=httpx.Response(200, json=ok_body()))

    async def scenario() -> None:
        async with make_client() as client:
            await client.generate(model=MODEL, parts="hi")

    run(scenario())
    request = route.calls[0].request
    assert request.headers[API_KEY_HEADER] == API_KEY
    assert API_KEY not in str(request.url)
    assert "key=" not in str(request.url)


@respx.mock
def test_inline_data_and_response_schema_reach_the_request() -> None:
    route = respx.post(URL).mock(return_value=httpx.Response(200, json=ok_body('{"rows": []}')))
    schema = {"type": "object", "properties": {"rows": {"type": "array", "items": {"type": "string"}}}}

    async def scenario() -> Any:
        async with make_client() as client:
            return await client.generate_json(
                model=MODEL,
                parts=[text_part("transcribe"), inline_data_part(b"%PDF-1.7 fake", "application/pdf")],
                task="extract_report",
                system_instruction="you transcribe",
                response_schema=schema,
            )

    payload, _run = run(scenario())
    assert payload == {"rows": []}
    body = json.loads(route.calls[0].request.content)
    parts = body["contents"][0]["parts"]
    assert parts[0]["text"] == "transcribe"
    assert parts[1]["inline_data"]["mime_type"] == "application/pdf"
    assert parts[1]["inline_data"]["data"] == "JVBERi0xLjcgZmFrZQ=="
    assert body["generationConfig"]["responseMimeType"] == "application/json"
    assert body["generationConfig"]["responseSchema"] == schema
    assert body["systemInstruction"]["parts"][0]["text"] == "you transcribe"


def test_prompt_hash_ignores_blob_size_but_changes_with_content() -> None:
    small = {"contents": [{"parts": [inline_data_part(b"a" * 10, "image/png")]}]}
    other = {"contents": [{"parts": [inline_data_part(b"b" * 10, "image/png")]}]}
    assert prompt_hash(small) != prompt_hash(other)
    assert len(prompt_hash(small)) == 64


# ------------------------------------------------------------------------ retries


@respx.mock
def test_retries_429_and_honours_retry_after() -> None:
    sleeper = RecordingSleep()
    respx.post(URL).mock(
        side_effect=[
            httpx.Response(429, headers={"Retry-After": "2"}, json={"error": "rate limited"}),
            httpx.Response(200, json=ok_body("second try")),
        ]
    )

    async def scenario() -> Any:
        async with make_client(sleep=sleeper) as client:
            return await client.generate(model=MODEL, parts="hi")

    result = run(scenario())
    assert result.text == "second try"
    assert result.run.attempts == 2
    assert sleeper.delays == [2.0]


@respx.mock
def test_retries_503_with_exponential_backoff() -> None:
    sleeper = RecordingSleep()
    respx.post(URL).mock(
        side_effect=[
            httpx.Response(503),
            httpx.Response(503),
            httpx.Response(200, json=ok_body("third try")),
        ]
    )

    async def scenario() -> Any:
        async with make_client(sleep=sleeper, backoff_base=0.5) as client:
            return await client.generate(model=MODEL, parts="hi")

    result = run(scenario())
    assert result.text == "third try"
    assert sleeper.delays == [0.5, 1.0]  # doubling, jitter pinned to zero


@respx.mock
def test_rate_limited_after_every_attempt_raises_typed_error() -> None:
    respx.post(URL).mock(return_value=httpx.Response(429, headers={"Retry-After": "1"}))

    async def scenario() -> None:
        async with make_client(max_attempts=3) as client:
            await client.generate(model=MODEL, parts="hi")

    with pytest.raises(GeminiRateLimited) as exc:
        run(scenario())
    assert exc.value.status == 429
    assert exc.value.retry_after == 1.0
    assert isinstance(exc.value, GeminiError)


@respx.mock
def test_server_error_after_every_attempt_raises_gemini_error() -> None:
    respx.post(URL).mock(return_value=httpx.Response(500))

    async def scenario() -> None:
        async with make_client(max_attempts=2) as client:
            await client.generate(model=MODEL, parts="hi")

    with pytest.raises(GeminiError) as exc:
        run(scenario())
    assert not isinstance(exc.value, GeminiRateLimited)


def test_parse_retry_after_accepts_seconds_and_http_date() -> None:
    assert parse_retry_after("3") == 3.0
    assert parse_retry_after(None) is None
    assert parse_retry_after("garbage") is None
    seconds = parse_retry_after("Wed, 21 Oct 2015 07:28:10 GMT", now=1445412480.0)
    assert seconds == 10.0


# ------------------------------------------------------- truncation and blocking


@respx.mock
def test_truncated_answer_is_rejected() -> None:
    respx.post(URL).mock(return_value=httpx.Response(200, json=ok_body("half a pl", "MAX_TOKENS")))

    async def scenario() -> None:
        async with make_client() as client:
            await client.generate(model=MODEL, parts="hi")

    with pytest.raises(GeminiTruncated) as exc:
        run(scenario())
    assert "truncated" in str(exc.value)
    assert isinstance(exc.value, GeminiInvalidResponse)


@respx.mock
def test_truncated_answer_can_be_opted_into() -> None:
    respx.post(URL).mock(return_value=httpx.Response(200, json=ok_body("half a pl", "MAX_TOKENS")))

    async def scenario() -> Any:
        async with make_client() as client:
            return await client.generate(model=MODEL, parts="hi", allow_truncated=True)

    result = run(scenario())
    assert result.run.truncated is True


@respx.mock
def test_safety_block_on_prompt_and_on_answer() -> None:
    respx.post(URL).mock(
        return_value=httpx.Response(200, json={"promptFeedback": {"blockReason": "SAFETY"}})
    )

    async def scenario() -> None:
        async with make_client() as client:
            await client.generate(model=MODEL, parts="hi")

    with pytest.raises(GeminiSafetyBlocked) as exc:
        run(scenario())
    assert exc.value.reason == "SAFETY"

    respx.post(URL).mock(return_value=httpx.Response(200, json=ok_body("x", "SAFETY")))
    with pytest.raises(GeminiSafetyBlocked):
        run(scenario())


@respx.mock
def test_no_candidates_and_bad_json_raise_invalid_response() -> None:
    respx.post(URL).mock(return_value=httpx.Response(200, json={"candidates": []}))

    async def scenario() -> None:
        async with make_client() as client:
            await client.generate(model=MODEL, parts="hi")

    with pytest.raises(GeminiInvalidResponse):
        run(scenario())

    respx.post(URL).mock(return_value=httpx.Response(200, json=ok_body("not json at all")))

    async def json_scenario() -> Any:
        async with make_client() as client:
            return await client.generate_json(model=MODEL, parts="hi")

    with pytest.raises(GeminiInvalidResponse):
        run(json_scenario())


# ------------------------------------------------------------------- secret safety


def test_missing_key_raises_without_leaking_anything(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv(API_KEY_ENV, raising=False)
    with pytest.raises(GeminiError) as exc:
        GeminiClient()
    assert API_KEY_ENV in str(exc.value)


@respx.mock
def test_api_key_never_appears_in_logs_or_exceptions(caplog: pytest.LogCaptureFixture) -> None:
    """The single most important test in this file."""
    caplog.set_level(logging.DEBUG)
    # A hostile-ish server that echoes the key back in its error body.
    respx.post(URL).mock(
        side_effect=[
            httpx.Response(429, headers={"Retry-After": "0"}, text=f"slow down, key={API_KEY}"),
            httpx.Response(400, text=f"bad request for key {API_KEY}"),
        ]
    )

    async def scenario() -> None:
        async with make_client() as client:
            await client.generate(model=MODEL, parts="hi", task="chat")

    with pytest.raises(GeminiError) as exc:
        run(scenario())

    assert API_KEY not in str(exc.value)
    assert API_KEY not in repr(exc.value)
    assert "REDACTED" in str(exc.value)

    for record in caplog.records:
        assert API_KEY not in record.getMessage()
        assert API_KEY not in str(record.args)
        for value in vars(record).values():
            assert API_KEY not in str(value)


def test_client_repr_hides_the_key() -> None:
    client = make_client()
    assert API_KEY not in repr(client)
    assert API_KEY not in str(client)

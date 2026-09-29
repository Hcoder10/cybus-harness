"""serve/anthropic_gateway.py against a fake OpenAI backend. No network: the gateway runs in-process behind
httpx.ASGITransport and its backend client is monkeypatched to an httpx.MockTransport."""
from __future__ import annotations

import asyncio
import base64
import json
import struct
import sys
import zlib
from pathlib import Path

import httpx
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from serve import anthropic_gateway as gw  # noqa: E402

READ_TOOL = {"name": "Read", "description": "Read a file",
             "input_schema": {"type": "object", "properties": {"path": {"type": "string"}, "limit": {"type": "integer"}},
                              "required": ["path"]}}


def png_b64(w: int = 64, h: int = 36) -> str:
    def chunk(tag: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    raw = b"".join(b"\x00" + b"\x10\x20\x30" * w for _ in range(h))
    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
    return base64.b64encode(png).decode()


# ------------------------------------------------------------------------------------------ fake OpenAI backend

class FakeBackend:
    """Records every request the gateway makes and answers from a queue of canned responses."""

    def __init__(self, *responses):
        self.responses = list(responses)
        self.requests: list[dict] = []

    async def __call__(self, request: httpx.Request) -> httpx.Response:
        body = json.loads(request.content) if request.content else None
        self.requests.append({"path": request.url.path, "json": body, "headers": dict(request.headers)})
        if request.url.path.endswith("/models"):
            return httpx.Response(200, json={"object": "list", "data": [{"id": "cybus"}, {"id": "cybus-base"}]})
        response = self.responses.pop(0)
        return response(body) if callable(response) else response

    @property
    def last(self) -> dict:
        return [r for r in self.requests if r["path"].endswith("/chat/completions")][-1]["json"]


def completion(content=None, tool_calls=None, finish="stop", reasoning=None, usage=(12, 5), stop_reason=None):
    message = {"role": "assistant", "content": content}
    if tool_calls:
        message["tool_calls"] = tool_calls
    if reasoning:
        message["reasoning_content"] = reasoning
    return httpx.Response(200, json={
        "id": "chatcmpl-1", "object": "chat.completion", "model": "cybus",
        "choices": [{"index": 0, "message": message, "finish_reason": finish, "stop_reason": stop_reason}],
        "usage": {"prompt_tokens": usage[0], "completion_tokens": usage[1], "total_tokens": sum(usage)}})


def chunk(finish=None, stop_reason=None, **delta):
    return {"id": "chatcmpl-1", "object": "chat.completion.chunk",
            "choices": [{"index": 0, "delta": delta, "finish_reason": finish, "stop_reason": stop_reason}]}


def usage_chunk(prompt=30, completion_tokens=9):
    return {"id": "chatcmpl-1", "object": "chat.completion.chunk", "choices": [],
            "usage": {"prompt_tokens": prompt, "completion_tokens": completion_tokens}}


def sse_response(chunks, delay: float = 0.0):
    lines = [f"data: {json.dumps(c)}\n\n".encode() for c in chunks] + [b"data: [DONE]\n\n"]
    if not delay:
        return httpx.Response(200, headers={"content-type": "text/event-stream"}, content=b"".join(lines))

    async def slow():
        await asyncio.sleep(delay)          # the backend is silent (prefill / long reasoning) before the first chunk
        for line in lines:
            yield line
    return httpx.Response(200, headers={"content-type": "text/event-stream"}, content=slow())


def tool_delta(index=0, id=None, name=None, arguments=None):
    fn = {}
    if name is not None:
        fn["name"] = name
    if arguments is not None:
        fn["arguments"] = arguments
    tc = {"index": index, "function": fn}
    if id:
        tc.update(id=id, type="function")
    return {"tool_calls": [tc]}


# ------------------------------------------------------------------------------------------ gateway harness

@pytest.fixture
def gateway_app(monkeypatch):
    def make(fake: FakeBackend, **overrides):
        cfg = gw.GatewayConfig(**{"backend_url": "http://backend.test/v1", "backend_model": "cybus",
                                  "backend_key": "backend-test-key", **overrides})
        app = gw.create_app(cfg)
        monkeypatch.setattr(app.state.backend, "client", httpx.AsyncClient(transport=httpx.MockTransport(fake)))
        return app
    return make


@pytest.fixture
def gateway(gateway_app):
    def make(fake: FakeBackend, **overrides) -> httpx.AsyncClient:
        return httpx.AsyncClient(transport=httpx.ASGITransport(app=gateway_app(fake, **overrides)),
                                 base_url="http://gateway.test")
    return make


def run(coro):
    return asyncio.run(coro)


async def post(client: httpx.AsyncClient, body: dict, path: str = "/v1/messages?beta=true", **headers):
    headers = {"x-api-key": "anything", "anthropic-version": "2023-06-01", **headers}
    return await client.post(path, json=body, headers=headers)


def request(messages, **kw) -> dict:
    return {"model": "claude-sonnet-4-6", "max_tokens": 1024, "messages": messages, **kw}


def parse_sse(text: str) -> list[tuple[str, dict]]:
    events = []
    for block in text.strip().split("\n\n"):
        name = data = None
        for line in block.splitlines():
            if line.startswith("event:"):
                name = line[6:].strip()
            elif line.startswith("data:"):
                data = json.loads(line[5:].strip())
        events.append((name, data))
    return events


def check_stream(events: list[tuple[str, dict]]) -> dict:
    """Assert the Anthropic streaming grammar (one block open at a time, indices 0..n in order, delta types that
    match their block, strict-JSON tool input) and return the message the events add up to."""
    names = [n for n, _ in events if n != "ping"]
    assert names[0] == "message_start" and names[-1] == "message_stop" and names[-2] == "message_delta", names
    assert all(d["type"] == n for n, d in events)
    message = dict(events[0][1]["message"])
    blocks, partial, open_idx = [], {}, None
    allowed = {"text": {"text_delta"}, "tool_use": {"input_json_delta"}, "thinking": {"thinking_delta", "signature_delta"}}
    for name, data in events:
        if name == "content_block_start":
            assert open_idx is None, "a block started while another was open"
            assert data["index"] == len(blocks)
            open_idx = data["index"]
            blocks.append(dict(data["content_block"]))
            partial[open_idx] = ""
        elif name == "content_block_delta":
            assert data["index"] == open_idx, "delta for a block that is not open"
            block, delta = blocks[open_idx], data["delta"]
            assert delta["type"] in allowed[block["type"]]
            if delta["type"] == "text_delta":
                block["text"] += delta["text"]
            elif delta["type"] == "input_json_delta":
                partial[open_idx] += delta["partial_json"]
            elif delta["type"] == "thinking_delta":
                block["thinking"] += delta["thinking"]
            else:
                block["signature"] = delta["signature"]
        elif name == "content_block_stop":
            assert data["index"] == open_idx
            if blocks[open_idx]["type"] == "tool_use":
                blocks[open_idx]["input"] = json.loads(partial[open_idx])
            open_idx = None
        elif name == "message_delta":
            assert open_idx is None
            message.update(data["delta"])
            message["usage"] = {**message["usage"], **data["usage"]}
    message["content"] = blocks
    return message


# ------------------------------------------------------------------------------------------ the required cases

def test_text_only_request(gateway):
    fake = FakeBackend(completion("Hello there.", usage=(20, 4)))

    async def main():
        async with gateway(fake) as client:
            r = await post(client, request(
                [{"role": "user", "content": "Hi"}],
                system=[{"type": "text", "text": "x-anthropic-billing-header: cc_version=2.1"},
                        {"type": "text", "text": "You are Cybus.", "cache_control": {"type": "ephemeral"}},
                        {"type": "text", "text": "Be brief."}],
                temperature=0.5, metadata={"user_id": "u1"}, thinking={"type": "adaptive"},
                context_management={"edits": []}))
            return r
    r = run(main())
    assert r.status_code == 200, r.text
    msg = r.json()
    assert msg["type"] == "message" and msg["role"] == "assistant" and msg["id"].startswith("msg_")
    assert msg["model"] == "claude-sonnet-4-6"
    assert msg["content"] == [{"type": "text", "text": "Hello there."}]
    assert msg["stop_reason"] == "end_turn" and msg["stop_sequence"] is None
    assert msg["usage"]["input_tokens"] == 20 and msg["usage"]["output_tokens"] == 4
    sent = fake.last
    assert sent["model"] == "cybus" and sent["stream"] is False and sent["max_tokens"] == 1024
    assert sent["temperature"] == 0.5
    assert sent["messages"] == [{"role": "system", "content": "You are Cybus.\n\nBe brief."},
                                {"role": "user", "content": "Hi"}]
    for anthropic_only in ("thinking", "metadata", "context_management", "system"):
        assert anthropic_only not in sent
    assert fake.requests[-1]["headers"]["authorization"] == "Bearer backend-test-key"


def test_tools_request_returns_tool_use(gateway):
    fake = FakeBackend(completion("I'll read it.", finish="tool_calls", tool_calls=[
        {"id": "call_1", "type": "function", "function": {"name": "Read", "arguments": "{\"path\": \"a.lua\"}"}}]))

    async def main():
        async with gateway(fake) as client:
            return await post(client, request(
                [{"role": "user", "content": "open a.lua"}],
                tools=[READ_TOOL, {"type": "web_search_20250305", "name": "web_search", "max_uses": 5}],
                tool_choice={"type": "any", "disable_parallel_tool_use": True}))
    msg = run(main()).json()
    assert msg["content"] == [{"type": "text", "text": "I'll read it."},
                              {"type": "tool_use", "id": "call_1", "name": "Read", "input": {"path": "a.lua"}}]
    assert msg["stop_reason"] == "tool_use"
    sent = fake.last
    assert sent["tools"] == [{"type": "function", "function": {"name": "Read", "description": "Read a file",
                                                              "parameters": READ_TOOL["input_schema"]}}]
    assert sent["tool_choice"] == "required" and sent["parallel_tool_calls"] is False


def test_tool_result_round_trip(gateway):
    fake = FakeBackend(completion("Both done."))
    history = [
        {"role": "user", "content": "read a.lua and b.lua"},
        {"role": "assistant", "content": [
            {"type": "thinking", "thinking": "plan", "signature": "sig"},
            {"type": "text", "text": "Reading both."},
            {"type": "tool_use", "id": "toolu_01", "name": "Read", "input": {"path": "a.lua"}},
            {"type": "tool_use", "id": "toolu_02", "name": "Read", "input": {"path": "b.lua"}}]},
        {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": "toolu_01", "content": "print(1)"},
            {"type": "tool_result", "tool_use_id": "toolu_02", "is_error": True,
             "content": [{"type": "text", "text": "file not found"}]},
            {"type": "text", "text": "<system-reminder>keep going</system-reminder>"}]},
    ]

    async def main():
        async with gateway(fake) as client:
            return await post(client, request(history, tools=[READ_TOOL]))
    assert run(main()).json()["content"] == [{"type": "text", "text": "Both done."}]
    msgs = fake.last["messages"]
    assert msgs[0] == {"role": "user", "content": "read a.lua and b.lua"}
    assert msgs[1]["role"] == "assistant" and msgs[1]["content"] == "Reading both."
    calls = msgs[1]["tool_calls"]
    assert [c["id"] for c in calls] == ["toolu_01", "toolu_02"]
    assert calls[0]["type"] == "function" and calls[0]["function"]["name"] == "Read"
    assert json.loads(calls[0]["function"]["arguments"]) == {"path": "a.lua"}
    assert msgs[2] == {"role": "tool", "tool_call_id": "toolu_01", "content": "print(1)"}
    assert msgs[3] == {"role": "tool", "tool_call_id": "toolu_02", "content": "Error: file not found"}
    assert msgs[4] == {"role": "user", "content": "<system-reminder>keep going</system-reminder>"}
    assert len(msgs) == 5


def test_image_blocks(gateway):
    fake = FakeBackend(completion("I see a grey square."))
    png = png_b64()
    history = [
        {"role": "user", "content": [
            {"type": "text", "text": "Compare these."},
            {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": png}},
            {"type": "image", "source": {"type": "url", "url": "https://example.test/ref.jpg"}}]},
        {"role": "assistant", "content": [{"type": "tool_use", "id": "toolu_9", "name": "capture", "input": {}}]},
        {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "toolu_9", "content": [
            {"type": "text", "text": "captured"},
            {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": "QUJD"}}]}]},
    ]
    tools = [{"name": "capture", "description": "screenshot", "input_schema": {"type": "object", "properties": {}}}]

    async def main():
        async with gateway(fake) as client:
            return await post(client, request(history, tools=tools))
    assert run(main()).status_code == 200
    msgs = fake.last["messages"]
    assert msgs[0]["content"] == [
        {"type": "text", "text": "Compare these."},
        {"type": "image_url", "image_url": {"url": f"data:image/png;base64,{png}"}},
        {"type": "image_url", "image_url": {"url": "https://example.test/ref.jpg"}}]
    # the image inside the tool_result cannot ride in the tool message: it follows as a user message
    assert msgs[2]["role"] == "tool" and msgs[2]["tool_call_id"] == "toolu_9"
    assert msgs[2]["content"].startswith("captured\n[1 image(s)")
    assert msgs[3]["role"] == "user"
    assert msgs[3]["content"][0] == {"type": "text", "text": "[image output of the capture call]"}
    assert msgs[3]["content"][1] == {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,QUJD"}}


def test_streaming_text_then_tool_call(gateway):
    fake = FakeBackend(sse_response([
        chunk(role="assistant", content=""),
        chunk(content="Let me "), chunk(content="look."),
        chunk(**tool_delta(0, id="chatcmpl-tool-7", name="Read", arguments="")),
        chunk(**tool_delta(0, arguments="{\"path\": ")),
        chunk(**tool_delta(0, arguments="\"src/main.lua\"")),
        chunk(**tool_delta(0, arguments=", \"limit\": 5}")),
        chunk(finish="tool_calls"),
        usage_chunk(30, 9)]))

    async def main():
        async with gateway(fake) as client:
            return await post(client, request([{"role": "user", "content": "look"}], tools=[READ_TOOL], stream=True))
    r = run(main())
    assert r.status_code == 200 and r.headers["content-type"].startswith("text/event-stream")
    events = parse_sse(r.text)
    msg = check_stream(events)
    assert msg["content"] == [{"type": "text", "text": "Let me look."},
                              {"type": "tool_use", "id": "chatcmpl-tool-7", "name": "Read",
                               "input": {"path": "src/main.lua", "limit": 5}}]
    json_deltas = [d for n, d in events if n == "content_block_delta" and d["delta"]["type"] == "input_json_delta"]
    assert len(json_deltas) == 3 and all(d["index"] == 1 for d in json_deltas)
    assert msg["stop_reason"] == "tool_use"
    assert msg["usage"]["input_tokens"] == 30 and msg["usage"]["output_tokens"] == 9
    sent = fake.last
    assert sent["stream"] is True and sent["stream_options"] == {"include_usage": True}


@pytest.mark.parametrize("stream", [False, True])
@pytest.mark.parametrize("finish,backend_stop,expected,expected_seq", [
    ("stop", None, "end_turn", None),
    ("length", None, "max_tokens", None),
    ("stop", "###", "stop_sequence", "###"),
    ("content_filter", None, "refusal", None),
])
def test_stop_reason_mapping(gateway, stream, finish, backend_stop, expected, expected_seq):
    if stream:
        response = sse_response([chunk(content="partial answer"), chunk(finish=finish, stop_reason=backend_stop)])
    else:
        response = completion("partial answer", finish=finish, stop_reason=backend_stop)
    fake = FakeBackend(response)

    async def main():
        async with gateway(fake) as client:
            return await post(client, request([{"role": "user", "content": "go"}], stop_sequences=["###"], stream=stream))
    r = run(main())
    msg = check_stream(parse_sse(r.text)) if stream else r.json()
    assert (msg["stop_reason"], msg["stop_sequence"]) == (expected, expected_seq)
    assert fake.last["stop"] == ["###"]


@pytest.mark.parametrize("stream", [False, True])
def test_stop_reason_tool_calls(gateway, stream):
    call = {"id": "call_5", "type": "function", "function": {"name": "Read", "arguments": "{\"path\": \"x\"}"}}
    if stream:
        response = sse_response([chunk(**tool_delta(0, id="call_5", name="Read", arguments="{\"path\": \"x\"}")),
                                 chunk(finish="tool_calls")])
    else:
        response = completion(None, tool_calls=[call], finish="tool_calls")
    fake = FakeBackend(response)

    async def main():
        async with gateway(fake) as client:
            return await post(client, request([{"role": "user", "content": "go"}], tools=[READ_TOOL], stream=stream))
    r = run(main())
    msg = check_stream(parse_sse(r.text)) if stream else r.json()
    assert msg["stop_reason"] == "tool_use"
    assert msg["content"] == [{"type": "tool_use", "id": "call_5", "name": "Read", "input": {"path": "x"}}]


def test_truncated_and_empty_tool_arguments_still_parse(gateway):
    """max_tokens can stop generation inside a tool call: the stream must still end in valid JSON for the client
    (argument-less calls get "{}")."""
    fake = FakeBackend(sse_response([
        chunk(**tool_delta(0, id="call_a", name="capture", arguments="")),
        chunk(**tool_delta(1, id="call_b", name="Read", arguments="{\"path\": \"src/ma")),
        chunk(finish="length")]))
    tools = [READ_TOOL, {"name": "capture", "description": "screenshot", "input_schema": {"type": "object"}}]

    async def main():
        async with gateway(fake) as client:
            return await post(client, request([{"role": "user", "content": "go"}], tools=tools, stream=True))
    msg = check_stream(parse_sse(run(main()).text))
    assert [(b["name"], b["input"]) for b in msg["content"]] == [("capture", {}), ("Read", {"path": "src/ma"})]
    assert msg["stop_reason"] == "max_tokens"


# ------------------------------------------------------------------------------------------ robustness around Cybus

def test_qwen_xml_tool_call_left_in_streamed_text(gateway):
    """A vLLM tool parser that does not match the model leaves Qwen XML calls in the text; the gateway turns a
    call of a known tool into a tool_use block (values typed by the schema), even split across chunks."""
    fake = FakeBackend(sse_response([
        chunk(content="Checking.\n<tool"),
        chunk(content="_call>\n<function=Read>\n<parameter=path>\nsrc/x.lua\n</param"),
        chunk(content="eter>\n<parameter=limit>\n20\n</parameter>\n</function>\n</tool_call>"),
        chunk(finish="stop")]))

    async def main():
        async with gateway(fake) as client:
            return await post(client, request([{"role": "user", "content": "go"}], tools=[READ_TOOL], stream=True))
    msg = check_stream(parse_sse(run(main()).text))
    assert msg["content"][0] == {"type": "text", "text": "Checking.\n"}
    assert msg["content"][1]["type"] == "tool_use" and msg["content"][1]["name"] == "Read"
    assert msg["content"][1]["input"] == {"path": "src/x.lua", "limit": 20}
    assert msg["stop_reason"] == "tool_use"


def test_hermes_tool_call_in_text_and_unknown_tool_stays_text(gateway):
    fake = FakeBackend(
        completion('<tool_call>\n{"name": "Read", "arguments": {"path": "y.lua"}}\n</tool_call>'),
        completion("Example: <tool_call>{\"name\": \"rm_rf\", \"arguments\": {}}</tool_call> is not a tool here."))

    async def main():
        async with gateway(fake) as client:
            a = await post(client, request([{"role": "user", "content": "go"}], tools=[READ_TOOL]))
            b = await post(client, request([{"role": "user", "content": "go"}], tools=[READ_TOOL]))
            return a.json(), b.json()
    a, b = run(main())
    assert a["content"][0]["type"] == "tool_use" and a["content"][0]["input"] == {"path": "y.lua"}
    assert a["stop_reason"] == "tool_use"
    assert b["content"] == [{"type": "text", "text": "Example: <tool_call>{\"name\": \"rm_rf\", \"arguments\": {}}"
                                                     "</tool_call> is not a tool here."}]
    assert b["stop_reason"] == "end_turn"


def test_backend_reasoning_becomes_thinking_block(gateway):
    fake = FakeBackend(sse_response([
        chunk(reasoning_content="\nThe user wants "), chunk(reasoning_content="a greeting."),
        chunk(content="\n\nHello!"), chunk(finish="stop")]))

    async def main():
        async with gateway(fake) as client:
            return await post(client, request([{"role": "user", "content": "hi"}], stream=True))
    msg = check_stream(parse_sse(run(main()).text))
    assert msg["content"][0]["type"] == "thinking"
    assert msg["content"][0]["thinking"] == "The user wants a greeting."
    assert msg["content"][0]["signature"]
    assert msg["content"][1] == {"type": "text", "text": "Hello!"}


def test_pings_while_backend_is_silent(gateway):
    fake = FakeBackend(sse_response([chunk(content="late"), chunk(finish="stop")], delay=0.4))

    async def main():
        async with gateway(fake, ping_seconds=0.05) as client:
            return await post(client, request([{"role": "user", "content": "hi"}], stream=True))
    events = parse_sse(run(main()).text)
    assert events[0][0] == "message_start"
    first_block = next(i for i, (n, _) in enumerate(events) if n == "content_block_start")
    assert sum(1 for n, _ in events[:first_block] if n == "ping") >= 3
    assert check_stream(events)["content"] == [{"type": "text", "text": "late"}]


def test_backend_error_mid_stream_becomes_an_error_event(gateway):
    fake = FakeBackend(sse_response([chunk(content="Half an ans"), {"error": {"message": "engine died", "code": 500}}]))

    async def main():
        async with gateway(fake) as client:
            return await post(client, request([{"role": "user", "content": "go"}], stream=True))
    events = parse_sse(run(main()).text)
    assert events[0][0] == "message_start"
    assert events[-1] == ("error", {"type": "error", "error": {"type": "api_error", "message": "backend error: engine died"}})
    assert "message_stop" not in [n for n, _ in events]     # an incomplete response must not look complete


def test_request_translation_details():
    env = {"GATEWAY_BACKEND_MODEL": "cybus-lora", "GATEWAY_MAX_OUTPUT_TOKENS": "2048",
           "GATEWAY_EXTRA_BODY": '{"chat_template_kwargs": {"enable_thinking": false}, "top_k": 20}'}
    cfg = gw.GatewayConfig.from_env(env)
    body = {"model": "claude-haiku-4-5", "max_tokens": 64000, "top_k": 5, "stop_sequences": ["END"],
            "chat_template_kwargs": "ignored", "output_config": {"effort": "high", "format": {
                "type": "json_schema", "schema": {"type": "object", "properties": {"title": {"type": "string"}}}}},
            "messages": [
                {"role": "system", "content": "Early system text."},
                {"role": "user", "content": [{"type": "document", "title": "notes.txt",
                                              "source": {"type": "text", "media_type": "text/plain", "data": "abc"}},
                                             {"type": "document", "source": {"type": "base64",
                                                                             "media_type": "application/pdf", "data": "JVBE"}}]},
                {"role": "assistant", "content": "Sure."},
                {"role": "system", "content": [{"type": "text", "text": "Mid-conversation reminder."}]},
                {"role": "user", "content": "Title?"},
                {"role": "assistant", "content": [{"type": "text", "text": "{\"title\": \""}]}]}
    payload, ctx = gw.translate_request(body, cfg)
    assert payload["model"] == "cybus-lora" and payload["max_tokens"] == 2048 and payload["top_k"] == 20
    assert payload["chat_template_kwargs"] == {"enable_thinking": False} and payload["stop"] == ["END"]
    assert payload["response_format"]["type"] == "json_schema"
    assert payload["response_format"]["json_schema"]["schema"]["properties"] == {"title": {"type": "string"}}
    msgs = payload["messages"]
    assert msgs[0] == {"role": "system", "content": "Early system text."}
    assert msgs[1]["content"].startswith("[document: notes.txt]\nabc\n[application/pdf omitted")
    assert msgs[3] == {"role": "user", "content": "[System message]\nMid-conversation reminder."}
    assert msgs[-1] == {"role": "assistant", "content": "{\"title\": \""}
    assert ctx.prefill and payload["continue_final_message"] is True and payload["add_generation_prompt"] is False
    for bad in ('{"x": ', "[1, 2]"):
        with pytest.raises(ValueError):
            gw.GatewayConfig.from_env({"GATEWAY_EXTRA_BODY": bad})


@pytest.mark.parametrize("how", ["cancelled", "closed"])
def test_client_disconnect_closes_the_backend_stream(how):
    """When the client goes away (Esc in Claude Code) the backend response must be closed so vLLM stops generating.
    Starlette either cancels the streaming task ("cancelled") or finalizes the generator ("closed")."""
    import anyio
    cleaned: list[bool] = []

    async def silent_backend():
        await asyncio.sleep(3600)           # stuck in a long prefill
        yield {}

    async def cleanup():
        await asyncio.sleep(0.01)           # real cleanup does I/O: must survive the cancellation
        cleaned.append(True)

    async def main():
        ctx = gw.RequestContext(requested_model="claude-x", backend_model="cybus", stream=True, max_tokens=16,
                                tools={}, stop_sequences=[], prefill=False)
        events = gw.sse_stream(gw.StreamTranslator(ctx, gw.GatewayConfig()), silent_backend(), cleanup, 0.01)
        received: list[str] = []
        if how == "cancelled":
            async with anyio.create_task_group() as tg:
                async def consume():
                    async for ev in events:
                        received.append(ev)
                tg.start_soon(consume)
                await anyio.sleep(0.1)
                tg.cancel_scope.cancel()
        else:
            async for ev in events:
                received.append(ev)
                if len(received) >= 3:
                    break
            await events.aclose()
        return received
    received = run(main())
    assert received[0].startswith("event: message_start") and any(r.startswith("event: ping") for r in received)
    assert cleaned == [True]


def test_whole_response_restreamed_when_backend_streaming_is_off(gateway):
    """GATEWAY_BACKEND_STREAM=0: for tool parsers whose streaming mode drops calls the gateway fetches the whole
    response and still answers the client with a proper event stream."""
    xml = "<tool_call>\n<function=Read>\n<parameter=path>\nz.lua\n</parameter>\n</function>\n</tool_call>"
    fake = FakeBackend(completion(xml, finish="stop"))

    async def main():
        async with gateway(fake, backend_stream=False) as client:
            return await post(client, request([{"role": "user", "content": "go"}], tools=[READ_TOOL], stream=True))
    r = run(main())
    msg = check_stream(parse_sse(r.text))
    assert msg["content"] == [{"type": "tool_use", "id": msg["content"][0]["id"], "name": "Read",
                               "input": {"path": "z.lua"}}]
    assert fake.last["stream"] is False


def test_context_overflow_clamps_max_tokens_then_reports_prompt_too_long(gateway):
    too_big = ("'max_tokens' or 'max_completion_tokens' is too large: 32000. This model's maximum context length is "
               "65536 tokens and your request has 40000 input tokens (32000 > 65536 - 40000).")
    no_room = ("This model's maximum context length is 65536 tokens. However, your request has 65000 input tokens. "
               "Please reduce the length of the input messages.")
    fake = FakeBackend(httpx.Response(400, json={"error": {"message": too_big, "type": "BadRequestError", "code": 400}}),
                       completion("fits now"),
                       httpx.Response(400, json={"object": "error", "message": no_room, "code": 400}))

    async def main():
        async with gateway(fake) as client:
            ok = await post(client, request([{"role": "user", "content": "long"}], max_tokens=32000))
            bad = await post(client, request([{"role": "user", "content": "longer"}], max_tokens=32000))
            return ok, bad
    ok, bad = run(main())
    assert ok.status_code == 200 and ok.json()["content"][0]["text"] == "fits now"
    chats = [r["json"] for r in fake.requests if r["path"].endswith("/chat/completions")]
    assert chats[0]["max_tokens"] == 32000 and chats[1]["max_tokens"] == 65536 - 40000 - 1
    assert bad.status_code == 400
    assert bad.json() == {"type": "error", "error": {"type": "invalid_request_error",
                                                     "message": "prompt is too long: 65000 tokens > 64512 maximum"}}


def test_backend_errors_use_the_anthropic_envelope(gateway):
    fake = FakeBackend(httpx.Response(500, json={"error": {"message": "engine died"}}),
                       httpx.Response(401, json={"error": {"message": "bad key"}}),
                       httpx.Response(429, headers={"retry-after": "7"}, json={"error": {"message": "busy"}}))

    async def main():
        async with gateway(fake) as client:
            return [await post(client, request([{"role": "user", "content": "x"}])) for _ in range(3)]
    crashed, unauthorized, throttled = run(main())
    assert crashed.status_code == 500 and crashed.json()["error"]["type"] == "api_error"
    assert "engine died" in crashed.json()["error"]["message"] and crashed.headers["x-should-retry"] == "true"
    # a bad BACKEND key is the gateway's problem: never a 401 that would send Claude Code to its login screen
    assert unauthorized.status_code == 502 and "GATEWAY_BACKEND_KEY" in unauthorized.json()["error"]["message"]
    assert throttled.status_code == 429 and throttled.json()["error"]["type"] == "rate_limit_error"
    assert throttled.headers["retry-after"] == "7"


def test_count_tokens_models_and_health(gateway):
    fake = FakeBackend()
    text = {"role": "user", "content": "word " * 700}
    with_image = {"role": "user", "content": [
        {"type": "text", "text": "word " * 700},
        {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": png_b64(1280, 720)}}]}

    async def main():
        async with gateway(fake) as client:
            a = await post(client, {"model": "claude-sonnet-4-6", "messages": [text]}, "/v1/messages/count_tokens?beta=true")
            b = await post(client, {"model": "claude-sonnet-4-6", "messages": [with_image]},
                           "/v1/messages/count_tokens?beta=true")
            models = await client.get("/v1/models?limit=1000", headers={"x-api-key": "k"})
            one = await client.get("/v1/models/claude-gateway/cybus-base")
            hello = await client.head("/api/hello")
            return a.json(), b.json(), models.json(), one.json(), hello.status_code
    a, b, models, one, hello = run(main())
    assert 900 <= a["input_tokens"] <= 1100                   # 3500 chars / 3.5
    assert 850 <= b["input_tokens"] - a["input_tokens"] <= 950     # 1280x720 at one token per 32x32 px
    ids = [m["id"] for m in models["data"]]
    assert "claude-gateway/cybus" in ids and "cybus-base" in ids and models["has_more"] is False
    assert one["id"] == "claude-gateway/cybus-base" and "cybus-base" in one["display_name"]
    assert hello == 200
    assert not [r for r in fake.requests if r["path"].endswith("/chat/completions")]


def test_model_mapping_and_image_limit(gateway):
    fake = FakeBackend(completion("a"), completion("b"), completion("c"))
    images = [{"type": "image", "source": {"type": "url", "url": f"https://example.test/{i}.png"}} for i in range(3)]

    async def main():
        async with gateway(fake, max_images=2) as client:
            await post(client, request([{"role": "user", "content": images}], model="claude-opus-4-8"))
            first = fake.last
            await post(client, request([{"role": "user", "content": "x"}], model="cybus-base"))
            second = fake.last
            await post(client, request([{"role": "user", "content": "x"}], model="claude-gateway/cybus-base"))
            return first, second, fake.last
    first, second, third = run(main())
    assert first["model"] == "cybus" and second["model"] == "cybus-base" and third["model"] == "cybus-base"
    parts = first["messages"][0]["content"]
    assert parts[0]["type"] == "text" and "omitted" in parts[0]["text"]       # the oldest image goes first
    assert [p["image_url"]["url"] for p in parts[1:]] == ["https://example.test/1.png", "https://example.test/2.png"]


def test_optional_gateway_key(gateway):
    fake = FakeBackend(completion("ok"), completion("ok"))

    async def main():
        async with gateway(fake, api_key="gateway-test-secret") as client:
            missing = await client.post("/v1/messages", json=request([{"role": "user", "content": "x"}]))
            by_header = await post(client, request([{"role": "user", "content": "x"}]),
                                   **{"x-api-key": "gateway-test-secret"})
            by_bearer = await client.post("/v1/messages", json=request([{"role": "user", "content": "x"}]),
                                          headers={"authorization": "Bearer gateway-test-secret"})
            return missing, by_header, by_bearer
    missing, by_header, by_bearer = run(main())
    assert missing.status_code == 401 and missing.json()["error"]["type"] == "authentication_error"
    assert by_header.status_code == 200 and by_bearer.status_code == 200


def test_official_anthropic_sdk_reads_the_stream(gateway_app):
    """The Anthropic Python SDK (what Claude Code's protocol is built on) accumulates the gateway's events."""
    anthropic = pytest.importorskip("anthropic")
    import importlib
    # the SDK brings its own httpx major version (anthropic 1.x uses `httpx2`): build its client from that library
    base = next(c for c in anthropic.DefaultAsyncHttpxClient.__mro__ if c.__name__ == "AsyncClient")
    http_lib = importlib.import_module(base.__module__.split(".")[0])
    fake = FakeBackend(
        sse_response([chunk(reasoning_content="Need the file."), chunk(content="Opening it."),
                      chunk(**tool_delta(0, id="call_x", name="Read", arguments="{\"path\": \"m")),
                      chunk(**tool_delta(0, arguments="ain.lua\"}")), chunk(finish="tool_calls"), usage_chunk(40, 11)]),
        completion("plain reply", usage=(7, 3)))

    async def main():
        transport = http_lib.ASGITransport(app=gateway_app(fake))
        async with anthropic.DefaultAsyncHttpxClient(transport=transport) as http:
            client = anthropic.AsyncAnthropic(api_key="not-a-real-key", base_url="http://gateway.test",
                                              http_client=http, max_retries=0)
            async with client.messages.stream(model="claude-sonnet-4-6", max_tokens=512, tools=[READ_TOOL],
                                              messages=[{"role": "user", "content": "open main.lua"}]) as stream:
                streamed = await stream.get_final_message()
            created = await client.messages.create(model="claude-sonnet-4-6", max_tokens=64,
                                                   messages=[{"role": "user", "content": "hi"}])
            return streamed, created
    streamed, created = run(main())
    kinds = [b.type for b in streamed.content]
    assert kinds == ["thinking", "text", "tool_use"]
    assert streamed.content[1].text == "Opening it."
    assert streamed.content[2].name == "Read" and streamed.content[2].input == {"path": "main.lua"}
    assert streamed.stop_reason == "tool_use" and streamed.usage.output_tokens == 11
    assert created.content[0].text == "plain reply" and created.stop_reason == "end_turn"

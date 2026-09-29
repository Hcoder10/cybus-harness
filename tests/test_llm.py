"""harness.llm tests. No network (httpx.MockTransport) and no pytest-asyncio (asyncio.run)."""

import asyncio
import base64
import io
import json
import logging
import os

import httpx
import pytest
from PIL import Image

from harness.llm import (LLM, PARSE_ERROR_KEY, RAW_ARGUMENTS_KEY, LLMError, Message, ToolCall, image_part,
                         llm_from_env, parse_text_tool_calls, text_part)

KEY = "sk-test-0123456789abcdef"

TOOLS = [
    {"type": "function", "function": {
        "name": "read_file", "description": "Read a file.",
        "parameters": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]}}},
    {"type": "function", "function": {
        "name": "write_file", "description": "Write a file.",
        "parameters": {"type": "object", "required": ["path", "content"], "properties": {
            "path": {"type": "string"}, "content": {"type": "string"},
            "line": {"type": "integer"}, "opts": {"type": "object"}}}}},
]


def png(w=64, h=32):
    buf = io.BytesIO()
    Image.new("RGB", (w, h), "red").save(buf, "PNG")
    return buf.getvalue()


def decode(part):
    """(mime type, PIL image) of an image_url part."""
    header, b64 = part["image_url"]["url"].split(",", 1)
    return header[len("data:"):-len(";base64")], Image.open(io.BytesIO(base64.b64decode(b64)))


def openai_reply(content="", tool_calls=None, finish="stop"):
    message = {"role": "assistant", "content": content}
    if tool_calls is not None:
        message["tool_calls"] = tool_calls
    return {"id": "chatcmpl-1", "object": "chat.completion",
            "choices": [{"index": 0, "message": message, "finish_reason": finish}],
            "usage": {"prompt_tokens": 12, "completion_tokens": 3, "total_tokens": 15}}


class Server:
    """MockTransport handler: records requests and plays scripted replies, each a dict (200 JSON), an
    httpx.Response, or a callable(request) that returns a response or raises."""

    def __init__(self, *replies):
        self.replies = list(replies)
        self.requests = []

    def __call__(self, request):
        self.requests.append(request)
        reply = self.replies.pop(0)
        if isinstance(reply, httpx.Response):
            return reply
        if callable(reply):
            return reply(request)
        return httpx.Response(200, json=reply)

    def body(self, i=-1):
        return json.loads(self.requests[i].content)


def make_llm(server, base_url="http://gpu.test:8000/v1", model="cybus", **kw):
    kw.setdefault("api_key", KEY)
    llm = LLM(base_url, model, transport=httpx.MockTransport(server), **kw)
    llm.retry_base_delay = 0.0  # no real sleeping between retries
    return llm


def chat(llm, messages, tools=None):
    return asyncio.run(llm.chat(messages, tools))


def test_native_tool_calls_and_request_shape():
    server = Server(openai_reply("", [
        {"id": "call_a", "type": "function", "function": {"name": "read_file", "arguments": '{"path": "src/main.luau"}'}},
        {"id": "call_b", "type": "function",
         "function": {"name": "write_file", "arguments": '{"path": "x.luau", "content": "print(1)"}'}},
        {"id": "call_c", "type": "function", "function": {"name": "read_file", "arguments": '{"path": '}},
    ], finish="tool_calls"))
    llm = make_llm(server, extra={"top_k": 20, "temperature": None})
    history = [
        Message("system", "You build games."),
        Message("user", [text_part("Look at this"), image_part(png())]),
        Message("assistant", "", tool_calls=[ToolCall("call_0", "read_file", {"path": "a.luau"})]),
        Message("tool", "local a = 1", tool_call_id="call_0", name="read_file"),
    ]
    resp = chat(llm, history, TOOLS)

    calls = resp.message.tool_calls
    assert [(c.id, c.name, c.arguments) for c in calls[:2]] == [
        ("call_a", "read_file", {"path": "src/main.luau"}),
        ("call_b", "write_file", {"path": "x.luau", "content": "print(1)"})]
    # Broken argument JSON keeps the call, marked, so the agent can tell the model.
    assert PARSE_ERROR_KEY in calls[2].arguments and calls[2].arguments[RAW_ARGUMENTS_KEY] == '{"path": '
    assert resp.message.role == "assistant" and resp.message.content == ""
    assert resp.finish_reason == "tool_calls" and resp.usage["total_tokens"] == 15 and resp.raw["id"] == "chatcmpl-1"

    request = server.requests[0]
    assert str(request.url) == "http://gpu.test:8000/v1/chat/completions"
    assert request.headers["authorization"] == f"Bearer {KEY}"
    body = server.body()
    assert body["model"] == "cybus" and body["max_tokens"] == 4096
    assert body["top_k"] == 20 and "temperature" not in body  # extra is merged; None removes a key
    assert body["tools"] == TOOLS
    system, user, assistant, tool = body["messages"]
    assert system == {"role": "system", "content": "You build games."}
    assert user["content"][0] == {"type": "text", "text": "Look at this"}
    assert user["content"][1]["image_url"]["url"].startswith("data:image/png;base64,")
    assert assistant["tool_calls"] == [{"id": "call_0", "type": "function",
                                        "function": {"name": "read_file", "arguments": '{"path": "a.luau"}'}}]
    assert tool == {"role": "tool", "content": "local a = 1", "tool_call_id": "call_0"}


def test_hermes_text_tool_calls_are_parsed_and_stripped():
    first = json.dumps({"name": "read_file", "arguments": {"path": "a.luau"}})
    # arguments given as a JSON string, as some models do
    second = json.dumps({"name": "write_file", "arguments": json.dumps({"path": "b.luau", "content": "x = 1"})})
    content = f"I'll read one file and write another.\n<tool_call>\n{first}\n</tool_call>\n<tool_call>{second}</tool_call>"
    server = Server(openai_reply(content), openai_reply(content))
    llm = make_llm(server)

    resp = chat(llm, [Message("user", "go")], TOOLS)
    assert resp.message.content == "I'll read one file and write another."
    assert [(c.name, c.arguments) for c in resp.message.tool_calls] == [
        ("read_file", {"path": "a.luau"}), ("write_file", {"path": "b.luau", "content": "x = 1"})]
    assert len({c.id for c in resp.message.tool_calls}) == 2
    assert resp.finish_reason == "tool_calls"

    # With no tools on offer the same reply is plain text.
    plain = chat(llm, [Message("user", "go")])
    assert plain.message.tool_calls is None and plain.message.content == content


def test_hermes_edge_cases():
    # A raw newline and tab inside a JSON string (code), and a last block cut off before its closing tag.
    text = 'Writing.\n<tool_call>\n{"name": "write_file", "arguments": {"path": "a.luau", "content": "local x = 1\n\tprint(x)"}}'
    visible, calls = parse_text_tool_calls(text, TOOLS)
    assert visible == "Writing."
    assert calls[0].arguments == {"path": "a.luau", "content": "local x = 1\n\tprint(x)"}

    # Several calls in one block, as a JSON list; "parameters" accepted for "arguments".
    visible, calls = parse_text_tool_calls(
        '<tool_call>[{"name": "read_file", "arguments": {"path": "a"}}, '
        '{"name": "read_file", "parameters": {"path": "b"}}]</tool_call>', TOOLS)
    assert visible == "" and [c.arguments["path"] for c in calls] == ["a", "b"]

    # Broken JSON still yields a call, marked, so the model can be told to fix it.
    visible, calls = parse_text_tool_calls('<tool_call>{"name": "read_file", "arguments": {"path": }}</tool_call>', TOOLS)
    assert visible == "" and calls[0].name == "read_file" and PARSE_ERROR_KEY in calls[0].arguments

    assert parse_text_tool_calls("just words", TOOLS) == ("just words", [])


def test_qwen_xml_text_tool_calls():
    content = (
        "Writing the server script.\n"
        "<tool_call>\n<function=write_file>\n"
        "<parameter=path>\nsrc/ServerScriptService/Main.server.luau\n</parameter>\n"
        "<parameter=content>\n    local n = 1\n\n    return n\n\n</parameter>\n"
        "<parameter=line>\n12\n</parameter>\n"
        '<parameter=opts>\n{"strict": true, "tags": ["a"]}\n</parameter>\n'
        "</function>\n</tool_call>\n"
        "<tool_call>\n<function=read_file>\n<parameter=path>\n42\n</parameter>\n</function>\n</tool_call>"
    )
    resp = chat(make_llm(Server(openai_reply(content))), [Message("user", "go")], TOOLS)
    assert resp.message.content == "Writing the server script."
    write, read = resp.message.tool_calls
    assert write.name == "write_file" and write.arguments == {
        "path": "src/ServerScriptService/Main.server.luau",
        "content": "    local n = 1\n\n    return n\n",  # one newline dropped per side; indentation kept
        "line": 12,                                    # values that parse as JSON are JSON ...
        "opts": {"strict": True, "tags": ["a"]},
    }
    assert read.name == "read_file" and read.arguments == {"path": "42"}  # ... except string-typed params

    # A bare <function=...> block without the <tool_call> wrapper, for a tool with no known schema.
    visible, calls = parse_text_tool_calls(
        "ok <function=mystery><parameter=count>\n3\n</parameter><parameter=label>\nhello world\n</parameter></function>")
    assert visible == "ok" and calls[0].name == "mystery"
    assert calls[0].arguments == {"count": 3, "label": "hello world"}


def test_image_part_downsizes_and_encodes(tmp_path):
    big = png(3000, 1500)
    part = image_part(big, max_side=1280)
    assert part["type"] == "image_url"
    mime, im = decode(part)
    assert mime == "image/png" and im.size == (1280, 640)

    buf = io.BytesIO()
    Image.new("RGB", (2000, 1000), (10, 120, 200)).save(buf, "JPEG")
    mime, im = decode(image_part(buf.getvalue(), max_side=500))
    assert mime == "image/jpeg" and im.size == (500, 250)

    small = png(100, 50)  # already small enough: sent byte-for-byte
    assert image_part(small)["image_url"]["url"] == "data:image/png;base64," + base64.b64encode(small).decode()

    path = tmp_path / "shot.png"
    path.write_bytes(big)
    assert decode(image_part(path, max_side=300))[1].size == (300, 150)
    assert image_part(str(path), max_side=300) == image_part(path, max_side=300)

    buf = io.BytesIO()
    Image.new("RGBA", (40, 20), (0, 0, 0, 0)).save(buf, "GIF")  # other formats become PNG
    mime, im = decode(image_part(buf.getvalue()))
    assert mime == "image/png" and im.size == (40, 20)


def test_anthropic_translation_both_ways():
    shot = image_part(png(8, 8))
    b64 = shot["image_url"]["url"].split(",", 1)[1]
    server = Server(
        {"id": "msg_1", "type": "message", "role": "assistant",
         "content": [{"type": "text", "text": "The edges are jagged."},
                     {"type": "tool_use", "id": "toolu_1", "name": "zoom", "input": {"x": 2}}],
         "stop_reason": "tool_use",
         "usage": {"input_tokens": 100, "output_tokens": 20, "cache_read_input_tokens": 5}},
        {"content": [{"type": "text", "text": "Looks good."}], "stop_reason": "end_turn",
         "usage": {"input_tokens": 1, "output_tokens": 2}},
    )
    llm = make_llm(server, base_url="https://api.anthropic.com", model="claude-test", provider="anthropic")
    history = [
        Message("system", "You judge games."),
        Message("user", [text_part("Rate this frame."), shot]),
        Message("assistant", "Let me look closer.",
                tool_calls=[ToolCall("call_1", "zoom", {"x": 1}), ToolCall("call.2", "stats", {})]),
        Message("tool", "zoomed in", tool_call_id="call_1", name="zoom"),
        Message("tool", "fps 60", tool_call_id="call.2", name="stats"),
        Message("user", [text_part("Images returned by the tool calls above:"), shot]),
    ]
    zoom = {"type": "function", "function": {
        "name": "zoom", "description": "Zoom in.",
        "parameters": {"type": "object", "properties": {"x": {"type": "integer"}}}}}
    resp = chat(llm, history, [zoom])

    request = server.requests[0]
    assert str(request.url) == "https://api.anthropic.com/v1/messages"
    assert request.headers["x-api-key"] == KEY and request.headers["anthropic-version"] == "2023-06-01"
    assert "authorization" not in request.headers
    body = server.body()
    assert body["model"] == "claude-test" and body["system"] == "You judge games." and body["max_tokens"] == 4096
    assert body["tools"] == [{"name": "zoom", "description": "Zoom in.", "input_schema": zoom["function"]["parameters"]}]
    image_block = {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": b64}}
    user, assistant, results = body["messages"]
    assert user == {"role": "user", "content": [{"type": "text", "text": "Rate this frame."}, image_block]}
    assert assistant == {"role": "assistant", "content": [
        {"type": "text", "text": "Let me look closer."},
        {"type": "tool_use", "id": "call_1", "name": "zoom", "input": {"x": 1}},
        {"type": "tool_use", "id": "call_2", "name": "stats", "input": {}}]}  # id sanitized to [A-Za-z0-9_-]
    # The tool results and the follow-up image message form ONE user turn, tool results first.
    assert results == {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": "call_1", "content": "zoomed in"},
        {"type": "tool_result", "tool_use_id": "call_2", "content": "fps 60"},
        {"type": "text", "text": "Images returned by the tool calls above:"},
        image_block]}

    assert resp.message.content == "The edges are jagged."
    assert resp.message.tool_calls == [ToolCall("toolu_1", "zoom", {"x": 2})]
    assert resp.finish_reason == "tool_calls"
    assert (resp.usage["prompt_tokens"], resp.usage["completion_tokens"], resp.usage["total_tokens"]) == (105, 20, 125)

    done = chat(llm, [Message("user", "And now?")])
    assert done.message.content == "Looks good." and done.message.tool_calls is None and done.finish_reason == "stop"


def test_retries_on_rate_limits_server_errors_and_timeouts(caplog):
    def timeout(request):
        raise httpx.ReadTimeout("read timed out", request=request)

    server = Server(httpx.Response(429, json={"error": "slow down"}, headers={"retry-after": "0"}),
                    httpx.Response(503, text="overloaded"), timeout, openai_reply("hello"))
    with caplog.at_level(logging.DEBUG):
        resp = chat(make_llm(server), [Message("user", "hi")])
    assert resp.message.content == "hello" and len(server.requests) == 4
    assert "retry 3/5" in caplog.text and KEY not in caplog.text


def test_gives_up_after_max_retries():
    server = Server(*[httpx.Response(500, text="upstream failed") for _ in range(6)])
    with pytest.raises(LLMError) as err:
        chat(make_llm(server), [Message("user", "hi")])
    assert err.value.status == 500 and len(server.requests) == 6  # the first attempt and 5 retries


def test_client_errors_fail_fast_without_leaking_the_key(caplog):
    server = Server(httpx.Response(401, json={"error": {"message": f"Incorrect API key provided: {KEY}"}}))
    llm = make_llm(server)
    with caplog.at_level(logging.DEBUG), pytest.raises(LLMError) as err:
        chat(llm, [Message("user", "hi")])
    assert err.value.status == 401 and len(server.requests) == 1
    assert KEY not in str(err.value) and "***" in str(err.value)
    assert KEY not in caplog.text and KEY not in repr(llm)


def test_llm_from_env(monkeypatch):
    for name in [k for k in os.environ if k.startswith("HARNESS_")]:
        monkeypatch.delenv(name)
    monkeypatch.setenv("HARNESS_DEFAULT_BASE_URL", "http://gpu.test:8000/v1")
    monkeypatch.setenv("HARNESS_DEFAULT_MODEL", "cybus")
    monkeypatch.setenv("HARNESS_DEFAULT_API_KEY", "default-key-123")
    monkeypatch.setenv("HARNESS_JUDGE_MODEL", "cybus-judge")
    monkeypatch.setenv("HARNESS_JUDGE_MAX_TOKENS", "1234")

    builder = llm_from_env("builder")  # nothing role-specific: all defaults
    assert (builder.base_url, builder.model, builder.api_key, builder.provider, builder.max_tokens) == (
        "http://gpu.test:8000/v1", "cybus", "default-key-123", "openai", 16384)
    judge = llm_from_env("judge")
    assert (judge.base_url, judge.model, judge.api_key, judge.max_tokens) == (
        "http://gpu.test:8000/v1", "cybus-judge", "default-key-123", 1234)

    monkeypatch.setenv("HARNESS_CRITIC_PROVIDER", "anthropic")
    monkeypatch.setenv("HARNESS_CRITIC_BASE_URL", "https://api.anthropic.com")
    monkeypatch.setenv("HARNESS_CRITIC_MODEL", "claude-test")
    critic = llm_from_env("critic")
    assert critic.provider == "anthropic" and critic.model == "claude-test"
    assert critic.api_key is None  # the default key is not sent to a different host
    monkeypatch.setenv("HARNESS_CRITIC_API_KEY", "anthropic-key-456")
    assert llm_from_env("critic").api_key == "anthropic-key-456"

    monkeypatch.delenv("HARNESS_DEFAULT_MODEL")
    with pytest.raises(ValueError, match="HARNESS_BUILDER_MODEL"):
        llm_from_env("builder")

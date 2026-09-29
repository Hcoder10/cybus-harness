"""Chat client: OpenAI-compatible endpoints (vLLM, OpenAI, ...) plus an Anthropic Messages adapter.

The rest of the harness speaks one dialect: OpenAI-shaped `Message`s (content is a string or a list of
`text` / `image_url` parts) and OpenAI function-tool specs. `LLM.chat` returns an `LLMResponse` whose
message carries parsed `ToolCall`s, including calls the model wrote as plain text (hermes JSON or Qwen
XML), which is what models behind vLLM without a tool parser, and Cybus SFT variants, produce.
"""

from __future__ import annotations

import asyncio
import base64
import email.utils
import io
import json
import logging
import os
import random
import re
import time
import uuid
import weakref
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import httpx
from PIL import Image, ImageOps

log = logging.getLogger(__name__)

ANTHROPIC_BASE_URL = "https://api.anthropic.com"
ANTHROPIC_VERSION = "2023-06-01"

# A tool call whose arguments cannot be parsed is still returned, so the agent can tell the model what
# went wrong; its arguments are then exactly these two keys.
PARSE_ERROR_KEY = "__parse_error__"
RAW_ARGUMENTS_KEY = "__raw_arguments__"

_RETRY_STATUS = {408, 409, 429}  # and every 5xx


@dataclass
class ToolCall:
    id: str
    name: str
    arguments: dict


@dataclass
class Message:
    role: str                          # system | user | assistant | tool
    content: str | list[dict]          # text, or OpenAI content parts ({"type":"text"}, {"type":"image_url"})
    tool_calls: list[ToolCall] | None = None
    tool_call_id: str | None = None    # tool messages: the call this message answers
    name: str | None = None


@dataclass
class LLMResponse:
    message: Message
    usage: dict
    finish_reason: str
    raw: dict


class LLMError(RuntimeError):
    """A request that failed for good: a non-retryable status, a malformed reply, or retries exhausted."""

    def __init__(self, message: str, status: int | None = None):
        super().__init__(message)
        self.status = status


# ---------------------------------------------------------------------------------------------------
# Content parts

def text_part(s: str) -> dict:
    return {"type": "text", "text": s}


def image_part(img: bytes | str | Path, max_side: int = 1280) -> dict:
    """An OpenAI `image_url` part carrying `img` as a base64 data URI.

    `img` is encoded image bytes or a file path (an http(s) URL passes through untouched). Images whose
    longer side exceeds `max_side` are downscaled; JPEG stays JPEG and everything else becomes PNG. An
    image that needs no change is sent byte-for-byte.
    """
    if isinstance(img, str) and img.startswith(("http://", "https://")):
        return {"type": "image_url", "image_url": {"url": img}}
    if isinstance(img, str) and img.startswith("data:"):
        raw = base64.b64decode(img.split(",", 1)[1])
    elif isinstance(img, (bytes, bytearray, memoryview)):
        raw = bytes(img)
    else:
        raw = Path(img).read_bytes()
    data, mime = _encode_image(raw, max_side)
    return {"type": "image_url",
            "image_url": {"url": f"data:{mime};base64,{base64.b64encode(data).decode('ascii')}"}}


def _encode_image(raw: bytes, max_side: int) -> tuple[bytes, str]:
    with Image.open(io.BytesIO(raw)) as im:
        fmt = (im.format or "").upper()
        rotated = im.getexif().get(0x0112, 1) != 1  # EXIF orientation tag (phone photos)
        too_big = bool(max_side) and max(im.size) > max_side
        if fmt in ("PNG", "JPEG") and not too_big and not rotated:
            return raw, f"image/{fmt.lower()}"
        out = ImageOps.exif_transpose(im) if rotated else im
        if out.mode not in ("RGB", "RGBA", "L", "LA"):
            # Palette/CMYK/16-bit images: resampling them directly is lossy or unsupported.
            has_alpha = "A" in out.getbands() or "transparency" in out.info
            out = out.convert("RGBA" if has_alpha else "RGB")
        if too_big:
            out.thumbnail((max_side, max_side), Image.Resampling.LANCZOS)  # keeps the aspect ratio
        buf = io.BytesIO()
        if fmt == "JPEG":
            (out if out.mode in ("RGB", "L") else out.convert("RGB")).save(buf, "JPEG", quality=90)
            return buf.getvalue(), "image/jpeg"
        out.save(buf, "PNG")
        return buf.getvalue(), "image/png"


def _plain_text(content: str | list[dict] | None) -> str:
    if isinstance(content, str):
        return content
    return "\n".join(p.get("text", "") for p in content or [] if isinstance(p, dict) and p.get("type") == "text")


# ---------------------------------------------------------------------------------------------------
# Tool-call arguments and tool calls written as text

def _reject_constant(name: str) -> Any:
    raise ValueError(f"{name} is not valid JSON")


# strict=False lets raw newlines and tabs inside strings through (models write code into JSON strings).
# NaN/Infinity are rejected: they could not be sent back to the server as JSON in the next request.
_JSON = json.JSONDecoder(strict=False, parse_constant=_reject_constant)


def _new_call_id() -> str:
    return "call_" + uuid.uuid4().hex[:24]


def _parse_arguments(raw: Any) -> dict:
    """Tool-call arguments as a dict; unparseable ones become {PARSE_ERROR_KEY: why, RAW_ARGUMENTS_KEY: raw}."""
    if isinstance(raw, dict):
        return raw
    if raw is None or (isinstance(raw, str) and not raw.strip()):
        return {}
    value: Any = raw
    try:
        for _ in range(2):  # some models double-encode: a JSON string that holds the JSON object
            if isinstance(value, str):
                value = _JSON.decode(value)
    except ValueError as e:
        return {PARSE_ERROR_KEY: f"arguments are not valid JSON ({e})", RAW_ARGUMENTS_KEY: str(raw)}
    if not isinstance(value, dict):
        return {PARSE_ERROR_KEY: f"arguments must be a JSON object, not {type(value).__name__}",
                RAW_ARGUMENTS_KEY: str(raw)}
    return value


# One match per call written as text: a <tool_call> block (closed, cut short by the next block, or cut
# off by the end of the text, e.g. when the server stripped the stop sequence), or a bare Qwen XML
# <function=...>...</function> block that the model wrote without the <tool_call> wrapper.
_BLOCK_RE = re.compile(
    r"<tool_call>(?P<body>.*?)(?:</tool_call>|(?=<tool_call>)|\Z)"
    r"|<function=(?P<fname>[^>\n]+)>(?P<fbody>.*?)</function>",
    re.S,
)
_FUNCTION_RE = re.compile(r"<function=([^>\n]+)>(.*?)(?:</function>|(?=<function=)|\Z)", re.S)
_PARAM_RE = re.compile(r"<parameter=([^>\n]+)>(.*?)(?:</parameter>|(?=<parameter=)|(?=</function>)|\Z)", re.S)
_NAME_RE = re.compile(r'"name"\s*:\s*"([^"]+)"')


def parse_text_tool_calls(text: str, tools: list[dict] | None = None) -> tuple[str, list[ToolCall]]:
    """Tool calls written as text -> (the text without the parsed blocks, the calls, in order).

    Understands hermes JSON (`<tool_call>{"name": ..., "arguments": {...}}</tool_call>`, several per
    reply) and Qwen XML (`<tool_call><function=NAME><parameter=K>V</parameter>...</function></tool_call>`).
    `tools` (OpenAI specs) lets Qwen XML values of string-typed parameters stay verbatim; other values
    are read as JSON when they parse and kept as strings otherwise. A block that cannot be parsed still
    yields a call, with PARSE_ERROR_KEY arguments, so the model can be told to fix it.
    """
    string_params = _string_params(tools)
    calls: list[ToolCall] = []

    def collect(m: re.Match) -> str:
        if m.group("body") is not None:
            calls.extend(_parse_block(m.group("body"), string_params))
        else:
            calls.append(_xml_call(m.group("fname"), m.group("fbody"), string_params))
        return ""

    visible = _BLOCK_RE.sub(collect, text)
    if not calls:
        return text, []
    visible = re.sub(r"```[\w-]*\s*```", "", visible)  # code fences left empty by the removal
    return re.sub(r"\n{3,}", "\n\n", visible).strip(), calls


def _parse_block(body: str, string_params: dict[str, set[str]]) -> list[ToolCall]:
    if "<function=" in body:
        return [_xml_call(name, inner, string_params) for name, inner in _FUNCTION_RE.findall(body)]
    body = _strip_fence(body.strip())
    if not body:
        return []
    values, error = _decode_json_values(body)
    if error is not None and not values:
        m = _NAME_RE.search(body)
        return [ToolCall(_new_call_id(), m.group(1) if m else "invalid_tool_call",
                         {PARSE_ERROR_KEY: f"<tool_call> does not hold valid JSON ({error})", RAW_ARGUMENTS_KEY: body})]
    return [_json_call(v, body) for v in values]


def _json_call(obj: Any, raw: str) -> ToolCall:
    if isinstance(obj, dict) and isinstance(obj.get("function"), dict):  # {"type": "function", "function": {...}}
        obj = obj["function"]
    if not isinstance(obj, dict) or not isinstance(obj.get("name"), str) or not obj["name"]:
        return ToolCall(_new_call_id(), "invalid_tool_call",
                        {PARSE_ERROR_KEY: 'a <tool_call> must hold {"name": ..., "arguments": {...}}',
                         RAW_ARGUMENTS_KEY: raw})
    arguments = obj["arguments"] if "arguments" in obj else obj.get("parameters", {})
    # Fresh ids: a model-written id may repeat across turns, and providers want them unique.
    return ToolCall(_new_call_id(), obj["name"], _parse_arguments(arguments))


def _decode_json_values(s: str) -> tuple[list, str | None]:
    """Consecutive JSON values in `s` (lists are flattened), and the error that stopped decoding, if any."""
    values: list = []
    i, n = 0, len(s)
    while i < n:
        while i < n and s[i] in " \t\r\n,":
            i += 1
        if i >= n:
            break
        try:
            value, i = _JSON.raw_decode(s, i)
        except ValueError as e:
            return values, str(e)
        values.extend(value if isinstance(value, list) else [value])
    return values, None


def _strip_fence(s: str) -> str:
    if s.startswith("```"):
        s = s.split("\n", 1)[1] if "\n" in s else ""
        s = s.rstrip()
        if s.endswith("```"):
            s = s[:-3]
    return s.strip()


def _xml_call(name: str, inner: str, string_params: dict[str, set[str]]) -> ToolCall:
    name = name.strip()
    strings = string_params.get(name, set())
    arguments = {key.strip(): _xml_value(value, key.strip() in strings) for key, value in _PARAM_RE.findall(inner)}
    return ToolCall(_new_call_id(), name, arguments)


def _xml_value(value: str, is_string: bool) -> Any:
    # Qwen writes each value on its own lines: drop exactly one newline on each side, so indentation and
    # blank lines inside code values survive.
    if value.startswith("\r\n"):
        value = value[2:]
    elif value.startswith("\n"):
        value = value[1:]
    if value.endswith("\r\n"):
        value = value[:-2]
    elif value.endswith("\n"):
        value = value[:-1]
    if is_string:
        return value
    try:
        return _JSON.decode(value)
    except ValueError:
        return value


def _string_params(tools: list[dict] | None) -> dict[str, set[str]]:
    """tool name -> its parameters declared as plain strings."""
    out: dict[str, set[str]] = {}
    for tool in tools or []:
        fn = tool["function"] if isinstance(tool.get("function"), dict) else tool
        schema = fn.get("parameters") or fn.get("input_schema") or {}
        props = schema.get("properties") or {}
        out[str(fn.get("name", ""))] = {k for k, s in props.items() if _is_string_schema(s)}
    return out


def _is_string_schema(schema: Any) -> bool:
    if not isinstance(schema, dict):
        return False
    t = schema.get("type")
    if isinstance(t, list):
        return [x for x in t if x != "null"] == ["string"]
    return t == "string"


# ---------------------------------------------------------------------------------------------------
# OpenAI wire format

def _openai_message(m: Message) -> dict:
    d: dict = {"role": m.role, "content": m.content if m.content is not None else ""}
    if m.tool_calls:
        d["tool_calls"] = [{"id": c.id, "type": "function",
                            "function": {"name": c.name, "arguments": json.dumps(c.arguments, ensure_ascii=False)}}
                           for c in m.tool_calls]
    if m.role == "tool":
        d["tool_call_id"] = m.tool_call_id
    elif m.name:
        d["name"] = m.name
    return d


def _from_openai(data: dict) -> tuple[Message, dict, str]:
    choice = data["choices"][0]
    msg = choice.get("message") or {}
    content = msg.get("content")
    if isinstance(content, list):
        content = _plain_text(content)
    calls = [ToolCall(tc.get("id") or _new_call_id(), (tc.get("function") or {}).get("name") or "",
                      _parse_arguments((tc.get("function") or {}).get("arguments")))
             for tc in msg.get("tool_calls") or []]
    message = Message("assistant", content or "", tool_calls=calls or None)
    return message, dict(data.get("usage") or {}), choice.get("finish_reason") or ""


# ---------------------------------------------------------------------------------------------------
# Anthropic wire format

_DATA_URI_RE = re.compile(r"data:([^;,]+);base64,(.*)", re.S)
_ANTHROPIC_FINISH = {"end_turn": "stop", "stop_sequence": "stop", "tool_use": "tool_calls", "max_tokens": "length"}


def _anthropic_id(call_id: str | None) -> str:
    return re.sub(r"[^A-Za-z0-9_-]", "_", call_id or "") or "call"  # ids must match ^[A-Za-z0-9_-]+$


def _anthropic_blocks(content: str | list[dict] | None) -> list[dict]:
    if isinstance(content, str) or content is None:
        return [{"type": "text", "text": content}] if content else []  # empty text blocks are rejected
    blocks = []
    for part in content:
        kind = part.get("type")
        if kind == "text":
            if part.get("text"):
                blocks.append({"type": "text", "text": part["text"]})
        elif kind == "image_url":
            ref = part["image_url"]
            url = ref["url"] if isinstance(ref, dict) else ref
            m = _DATA_URI_RE.match(url)
            source = ({"type": "base64", "media_type": m.group(1), "data": m.group(2)} if m
                      else {"type": "url", "url": url})
            blocks.append({"type": "image", "source": source})
        else:
            blocks.append(part)  # assume it is already an Anthropic block (image, document, ...)
    return blocks


def _anthropic_messages(messages: list[Message]) -> tuple[str, list[dict]]:
    """OpenAI-shaped messages -> (system prompt, Anthropic turns).

    Tool messages become tool_result blocks in a user turn. Consecutive messages of the same role merge
    into one turn (the agent sends tool results followed by a user message of images: one turn here),
    and a user turn lists its tool_result blocks first, as the API requires.
    """
    system: list[str] = []
    turns: list[dict] = []
    for m in messages:
        if m.role == "system":
            system.append(_plain_text(m.content))
            continue
        if m.role == "tool":
            block: dict = {"type": "tool_result", "tool_use_id": _anthropic_id(m.tool_call_id)}
            content = m.content if isinstance(m.content, str) else _anthropic_blocks(m.content)
            if content:
                block["content"] = content
            role, blocks = "user", [block]
        elif m.role == "assistant":
            role = "assistant"
            blocks = _anthropic_blocks(m.content) + [
                {"type": "tool_use", "id": _anthropic_id(c.id), "name": c.name, "input": c.arguments}
                for c in m.tool_calls or []]
        else:
            role, blocks = "user", _anthropic_blocks(m.content)
        if turns and turns[-1]["role"] == role:
            turns[-1]["content"].extend(blocks)
        else:
            turns.append({"role": role, "content": blocks})
    for turn in turns:
        if turn["role"] == "user":
            turn["content"].sort(key=lambda b: b.get("type") != "tool_result")  # stable: results first
        if not turn["content"]:
            turn["content"] = [{"type": "text", "text": "(empty)"}]
    return "\n\n".join(s for s in system if s), turns


def _anthropic_tool(tool: dict) -> dict:
    fn = tool.get("function")
    if not isinstance(fn, dict):
        return tool  # already Anthropic-shaped
    return {"name": fn["name"], "description": fn.get("description", ""),
            "input_schema": fn.get("parameters") or {"type": "object", "properties": {}}}


def _from_anthropic(data: dict) -> tuple[Message, dict, str]:
    texts, calls = [], []
    for block in data.get("content") or []:
        if block.get("type") == "text" and block.get("text"):
            texts.append(block["text"])
        elif block.get("type") == "tool_use":
            calls.append(ToolCall(block.get("id") or _new_call_id(), block.get("name", ""),
                                  _parse_arguments(block.get("input"))))
    u = data.get("usage") or {}
    usage = {k: v for k, v in u.items() if isinstance(v, (int, float)) and not isinstance(v, bool)}
    usage["prompt_tokens"] = sum(int(u.get(k) or 0) for k in
                                 ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"))
    usage["completion_tokens"] = int(u.get("output_tokens") or 0)
    usage["total_tokens"] = usage["prompt_tokens"] + usage["completion_tokens"]
    stop = data.get("stop_reason") or ""
    return Message("assistant", "\n".join(texts), tool_calls=calls or None), usage, _ANTHROPIC_FINISH.get(stop, stop)


# ---------------------------------------------------------------------------------------------------
# Client

def _retry_after(resp: httpx.Response) -> float | None:
    """Seconds the server asked us to wait (retry-after-ms / Retry-After), if it said."""
    try:
        if resp.headers.get("retry-after-ms"):
            return max(0.0, float(resp.headers["retry-after-ms"]) / 1000)
        value = resp.headers.get("retry-after")
        if not value:
            return None
        try:
            return max(0.0, float(value))
        except ValueError:
            return max(0.0, email.utils.parsedate_to_datetime(value).timestamp() - time.time())
    except (TypeError, ValueError, IndexError, OverflowError):
        return None


class LLM:
    """Async chat client for one model.

    provider="openai" (alias "vllm") POSTs {base_url}/chat/completions, so base_url normally ends in
    /v1. provider="anthropic" speaks the Messages API (base_url https://api.anthropic.com, with or
    without /v1). `extra` is merged into every request body and a key set to None is removed, e.g.
    {"chat_template_kwargs": {"enable_thinking": False}} for vLLM, {"tool_choice": "none"} for a vLLM
    server started without a tool parser (the model then writes its calls as text, which are parsed),
    or {"max_tokens": None, "max_completion_tokens": 8192} for OpenAI reasoning models.
    `transport` injects an httpx transport (tests use httpx.MockTransport).
    """

    max_retries = 5          # retries after the first attempt: 408/409/429/5xx, timeouts, dropped connections
    retry_base_delay = 1.0   # seconds, doubled on each retry, plus jitter; a Retry-After header wins
    retry_max_delay = 60.0

    def __init__(self, base_url: str, model: str, api_key: str | None = None, provider: str = "openai",
                 max_tokens: int = 4096, temperature: float = 0.6, timeout: float = 600,
                 extra: dict | None = None, *, transport: httpx.AsyncBaseTransport | None = None):
        provider = (provider or "openai").strip().lower()
        provider = {"vllm": "openai"}.get(provider, provider)
        if provider not in ("openai", "anthropic"):
            raise ValueError(f"unknown provider {provider!r}; expected 'openai' or 'anthropic'")
        base_url = (base_url or (ANTHROPIC_BASE_URL if provider == "anthropic" else "")).rstrip("/")
        if not base_url:
            raise ValueError("base_url is required for provider 'openai'")
        self.base_url = base_url
        self.model = model
        self.api_key = api_key or None
        self.provider = provider
        self.max_tokens = max_tokens
        self.temperature = temperature
        self.timeout = timeout
        self.extra = dict(extra or {})
        self.transport = transport
        # One pooled client per event loop: a client's connections cannot outlive the loop that opened them.
        self._clients: weakref.WeakKeyDictionary = weakref.WeakKeyDictionary()

    def __repr__(self) -> str:  # never shows the key
        key = ", api_key=***" if self.api_key else ""
        return f"LLM(provider={self.provider!r}, model={self.model!r}, base_url={self.base_url!r}{key})"

    async def chat(self, messages: list[Message], tools: list[dict] | None = None) -> LLMResponse:
        if self.provider == "anthropic":
            data = await self._post(*self._anthropic_request(messages, tools))
            message, usage, finish = _from_anthropic(data)
        else:
            data = await self._post(*self._openai_request(messages, tools))
            if not data.get("choices"):
                raise LLMError(f"{self.model}: reply has no choices: {self._redact(json.dumps(data)[:500])}")
            message, usage, finish = _from_openai(data)
        text = message.content
        if tools and not message.tool_calls and isinstance(text, str) and ("<tool_call>" in text or "<function=" in text):
            visible, calls = parse_text_tool_calls(text, tools)
            if calls:
                message.content, message.tool_calls, finish = visible, calls, "tool_calls"
        return LLMResponse(message, usage, finish, data)

    async def aclose(self) -> None:
        """Close the pooled HTTP client of the running event loop (optional; the pool is also dropped with the loop)."""
        client = self._clients.pop(asyncio.get_running_loop(), None)
        if client is not None:
            await client.aclose()

    # -- requests ----------------------------------------------------------------------------------

    def _openai_request(self, messages: list[Message], tools: list[dict] | None) -> tuple[str, dict, dict]:
        url = self.base_url if self.base_url.endswith("/chat/completions") else self.base_url + "/chat/completions"
        headers = {"Authorization": f"Bearer {self.api_key}"} if self.api_key else {}
        body: dict = {"model": self.model, "messages": [_openai_message(m) for m in messages],
                      "max_tokens": self.max_tokens}
        if self.temperature is not None:
            body["temperature"] = self.temperature
        if tools:
            body["tools"] = tools
        return url, headers, self._with_extra(body)

    def _anthropic_request(self, messages: list[Message], tools: list[dict] | None) -> tuple[str, dict, dict]:
        b = self.base_url
        url = b if b.endswith("/messages") else b + ("/messages" if b.endswith("/v1") else "/v1/messages")
        headers = {"anthropic-version": ANTHROPIC_VERSION}
        if self.api_key:
            headers["x-api-key"] = self.api_key
        system, turns = _anthropic_messages(messages)
        body: dict = {"model": self.model, "max_tokens": self.max_tokens, "messages": turns}
        if system:
            body["system"] = system
        if self.temperature is not None:
            body["temperature"] = self.temperature
        if tools:
            body["tools"] = [_anthropic_tool(t) for t in tools]
        return url, headers, self._with_extra(body)

    def _with_extra(self, body: dict) -> dict:
        for k, v in self.extra.items():
            if v is None:
                body.pop(k, None)
            else:
                body[k] = v
        return body

    def _client(self) -> httpx.AsyncClient:
        loop = asyncio.get_running_loop()
        client = self._clients.get(loop)
        if client is None or client.is_closed:
            timeout = httpx.Timeout(self.timeout, connect=min(self.timeout, 30.0))
            client = httpx.AsyncClient(timeout=timeout, transport=self.transport)
            self._clients[loop] = client
        return client

    def _redact(self, text: str) -> str:
        # Error bodies can echo the key back; short placeholder keys ("EMPTY") are not secrets.
        return text.replace(self.api_key, "***") if self.api_key and len(self.api_key) >= 8 else text

    async def _post(self, url: str, headers: dict, body: dict) -> dict:
        client = self._client()
        for attempt in range(self.max_retries + 1):
            wait = None
            try:
                resp = await client.post(url, headers=headers, json=body)
            except (httpx.TimeoutException, httpx.NetworkError, httpx.RemoteProtocolError) as e:
                problem, status = f"{type(e).__name__}: {e}", None
            else:
                if resp.is_success:
                    try:
                        data = resp.json()
                    except ValueError:
                        data = None
                    if not isinstance(data, dict):
                        raise LLMError(f"{self.model}: reply is not a JSON object: {self._redact(resp.text[:500])}",
                                       resp.status_code)
                    return data
                problem, status = f"HTTP {resp.status_code}: {resp.text[:1000]}", resp.status_code
                if status not in _RETRY_STATUS and status < 500:
                    raise LLMError(f"{self.model}: {self._redact(problem)}", status)
                wait = _retry_after(resp)
            if attempt >= self.max_retries:
                raise LLMError(f"{self.model}: gave up after {attempt + 1} attempts: {self._redact(problem)}", status)
            if wait is None:
                wait = self.retry_base_delay * 2 ** attempt * random.uniform(1.0, 1.25)
            wait = min(wait, self.retry_max_delay)
            log.warning("%s: %s; retry %d/%d in %.1fs", self.model, self._redact(problem[:200]),
                        attempt + 1, self.max_retries, wait)
            await asyncio.sleep(wait)
        raise AssertionError("unreachable")


def llm_from_env(role: str) -> LLM:
    """The LLM for a role, from HARNESS_<ROLE>_{BASE_URL,MODEL,API_KEY,PROVIDER,MAX_TOKENS}, each
    falling back to HARNESS_DEFAULT_*.

    The default API key is only reused when the role talks to the default base URL, so a key is never
    sent to a host it was not configured for; a role with its own BASE_URL sets its own API_KEY.
    """
    tag = re.sub(r"[^A-Za-z0-9]+", "_", role).strip("_").upper()

    def own(key: str) -> str | None:
        return os.environ.get(f"HARNESS_{tag}_{key}") or None

    def default(key: str) -> str | None:
        return os.environ.get(f"HARNESS_DEFAULT_{key}") or None

    provider = own("PROVIDER") or default("PROVIDER") or "openai"
    base_url = own("BASE_URL") or default("BASE_URL")
    model = own("MODEL") or default("MODEL")
    api_key = own("API_KEY")
    if api_key is None and (own("BASE_URL") is None
                            or own("BASE_URL").rstrip("/") == (default("BASE_URL") or "").rstrip("/")):
        api_key = default("API_KEY")
    missing = [k for k, v in (("MODEL", model), ("BASE_URL", base_url or provider.lower() == "anthropic")) if not v]
    if missing:
        names = " and ".join(f"HARNESS_{tag}_{k}" for k in missing)
        raise ValueError(f"role {role!r} has no model endpoint: set {names} (or the HARNESS_DEFAULT_* fallbacks)")
    # Reasoning models spend their completion budget on thinking before the answer; 4096 truncated structured
    # submissions mid-object on Qwen3.8 (the last fields went missing six times in a row), so default higher.
    max_tokens = own("MAX_TOKENS") or default("MAX_TOKENS")
    temperature = own("TEMPERATURE") or default("TEMPERATURE")
    extra_raw = own("EXTRA") or default("EXTRA")        # JSON merged into every request body, e.g. template kwargs
    extra = None
    if extra_raw:
        try:
            extra = json.loads(extra_raw)
        except ValueError as e:
            raise ValueError(f"HARNESS_{tag}_EXTRA / HARNESS_DEFAULT_EXTRA is not valid JSON: {e}") from e
    return LLM(base_url or "", model, api_key=api_key, provider=provider,
               max_tokens=int(max_tokens) if max_tokens else 16384,
               temperature=float(temperature) if temperature else 0.6, extra=extra)

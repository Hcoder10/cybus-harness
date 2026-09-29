"""Anthropic Messages API gateway in front of an OpenAI-compatible backend (lets Claude Code drive Cybus).

Claude Code, the Anthropic SDK and the harness's `provider="anthropic"` adapter speak the Anthropic Messages API.
This FastAPI app implements the subset they use on top of any OpenAI-compatible chat-completions server (vLLM
serving Cybus by default):

    POST /v1/messages                 streaming (SSE) and non-streaming
    POST /v1/messages/count_tokens    approximation: text chars / 3.5 + image patches
    GET  /v1/models, /v1/models/{id}
    GET|HEAD /, /health, /api/hello   liveness (Claude Code sends HEAD /api/hello at startup)

Every Claude model name maps to GATEWAY_BACKEND_MODEL; a non-Claude name ("cybus-base") passes through, and
"claude-gateway/<id>" (what /v1/models lists, so Claude Code's model discovery keeps it) selects backend <id>.
Anthropic-only request fields (thinking, cache_control, metadata, context_management, betas, ...) are ignored.
Backend reasoning (vLLM `reasoning_content` / `reasoning`) is returned as `thinking` blocks, so a client sees
progress while the model thinks. Tool calls the backend left in the text as `<tool_call>` markup (hermes JSON
or Qwen XML, e.g. a vLLM tool parser that does not match the model) are turned into tool_use blocks when they
name a tool from the request.

Environment (read at startup; keys are never logged):
    GATEWAY_BACKEND_URL      OpenAI-compatible base URL                       http://127.0.0.1:8000/v1
    GATEWAY_BACKEND_MODEL    backend model every Claude name maps to          cybus
    GATEWAY_BACKEND_KEY      bearer key sent to the backend                   (none)
    GATEWAY_API_KEY          if set, clients must present it (x-api-key or Bearer); otherwise auth is ignored
    GATEWAY_BACKEND_STREAM   1: stream from the backend; 0: fetch whole responses and re-stream them
                             (use 0 when the backend's streaming tool parser drops tool calls)       1
    GATEWAY_EXTRA_BODY       JSON object merged into every backend request, e.g.
                             {"chat_template_kwargs": {"enable_thinking": false}, "temperature": 0.7}
    GATEWAY_MAX_OUTPUT_TOKENS  cap on max_tokens sent to the backend                                 (none)
    GATEWAY_MAX_IMAGES       images kept per request, newest first (vLLM --limit-mm-per-prompt)      8
    GATEWAY_THINKING         emit | drop backend reasoning                                           emit
    GATEWAY_TEXT_TOOL_CALLS  1: parse <tool_call> markup left in text into tool_use blocks           1
    GATEWAY_TIMEOUT          backend read timeout, seconds                                           600
    GATEWAY_PING_SECONDS     SSE ping interval while the backend is silent                           10

Run:  python -m serve.anthropic_gateway --port 4000      (or: uvicorn serve.anthropic_gateway:app --port 4000)
"""
from __future__ import annotations

import argparse
import asyncio
import base64
import binascii
import copy
import hmac
import json
import logging
import math
import os
import re
import struct
import time
import uuid
from contextlib import asynccontextmanager, suppress
from dataclasses import dataclass, field
from typing import Any, AsyncIterator, Awaitable, Callable

import anyio
import httpx
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, StreamingResponse

log = logging.getLogger("cybus.gateway")

ANTHROPIC_MARKERS = ("claude", "anthropic", "sonnet", "opus", "haiku", "fable")
ALIAS_PREFIX = "claude-gateway/"          # Claude Code's model discovery keeps ids containing "claude"
TOOL_OPEN, TOOL_CLOSE = "<tool_call>", "</tool_call>"
ATTRIBUTION_PREFIX = "x-anthropic-billing-header"   # Claude Code's attribution system block: noise for a local model
THINKING_SIGNATURE = "cybus-gateway-unsigned"       # backend reasoning carries no Anthropic signature
MIN_OUTPUT_TOKENS = 1024                  # below this much room, report "prompt is too long" instead of clamping
DEFAULT_MAX_TOKENS = 4096
UNKNOWN_IMAGE_TOKENS = 1024


# --------------------------------------------------------------------------------------------- configuration

def _env_str(env: Any, name: str, default: str | None = None) -> str | None:
    value = env.get(name)
    return value.strip() if value and value.strip() else default


def _env_bool(env: Any, name: str, default: bool) -> bool:
    value = _env_str(env, name)
    return default if value is None else value.lower() not in ("0", "false", "no", "off")


def _env_num(env: Any, name: str, default: Any, cast: Callable[[str], Any]) -> Any:
    value = _env_str(env, name)
    if value is None:
        return default
    try:
        return cast(value)
    except ValueError:
        raise ValueError(f"{name}={value!r} is not a valid {cast.__name__}") from None


@dataclass
class GatewayConfig:
    backend_url: str = "http://127.0.0.1:8000/v1"
    backend_model: str = "cybus"
    backend_key: str | None = field(default=None, repr=False)
    api_key: str | None = field(default=None, repr=False)
    backend_stream: bool = True
    extra_body: dict = field(default_factory=dict)
    max_output_tokens: int | None = None
    max_images: int = 8
    thinking: str = "emit"
    text_tool_calls: bool = True
    timeout: float = 600.0
    ping_seconds: float = 10.0
    early_error_seconds: float = 3.0      # non-streaming backend: wait this long for a fast failure before replying

    @classmethod
    def from_env(cls, env: Any = None) -> "GatewayConfig":
        env = os.environ if env is None else env
        raw_extra = _env_str(env, "GATEWAY_EXTRA_BODY")
        try:
            extra = json.loads(raw_extra) if raw_extra else {}
        except ValueError as e:
            raise ValueError(f"GATEWAY_EXTRA_BODY is not valid JSON: {e}") from None
        if not isinstance(extra, dict):
            raise ValueError("GATEWAY_EXTRA_BODY must be a JSON object")
        thinking = (_env_str(env, "GATEWAY_THINKING", "emit") or "emit").lower()
        if thinking not in ("emit", "drop"):
            raise ValueError("GATEWAY_THINKING must be 'emit' or 'drop'")
        return cls(
            backend_url=_env_str(env, "GATEWAY_BACKEND_URL", cls.backend_url),
            backend_model=_env_str(env, "GATEWAY_BACKEND_MODEL", cls.backend_model),
            backend_key=_env_str(env, "GATEWAY_BACKEND_KEY"),
            api_key=_env_str(env, "GATEWAY_API_KEY"),
            backend_stream=_env_bool(env, "GATEWAY_BACKEND_STREAM", True),
            extra_body=extra,
            max_output_tokens=_env_num(env, "GATEWAY_MAX_OUTPUT_TOKENS", None, int),
            max_images=_env_num(env, "GATEWAY_MAX_IMAGES", 8, int),
            thinking=thinking,
            text_tool_calls=_env_bool(env, "GATEWAY_TEXT_TOOL_CALLS", True),
            timeout=_env_num(env, "GATEWAY_TIMEOUT", 600.0, float),
            ping_seconds=_env_num(env, "GATEWAY_PING_SECONDS", 10.0, float),
        )


# --------------------------------------------------------------------------------------------- errors

_ERROR_TYPES = {400: "invalid_request_error", 401: "authentication_error", 403: "permission_error",
                404: "not_found_error", 413: "request_too_large", 429: "rate_limit_error",
                500: "api_error", 503: "overloaded_error", 529: "overloaded_error"}


class GatewayError(Exception):
    """An error answered in the Anthropic envelope {"type": "error", "error": {"type", "message"}}."""

    def __init__(self, status: int, message: str, etype: str | None = None, headers: dict | None = None):
        super().__init__(message)
        self.status = status
        self.message = message
        self.etype = etype or _ERROR_TYPES.get(status, "api_error" if status >= 500 else "invalid_request_error")
        self.headers = headers or {}


class BackendStreamError(Exception):
    """The backend reported an error inside an already-started stream."""


def error_body(etype: str, message: str) -> dict:
    return {"type": "error", "error": {"type": etype, "message": message}}


def _new_id(prefix: str) -> str:
    return prefix + uuid.uuid4().hex[:24]


# --------------------------------------------------------------------------------------------- request: Anthropic -> OpenAI

@dataclass
class RequestContext:
    requested_model: str
    backend_model: str
    stream: bool
    max_tokens: int
    tools: dict[str, dict]            # tool name -> input_schema (for text tool-call parsing and value typing)
    stop_sequences: list[str]
    prefill: bool                     # the last message is an assistant turn the model continues
    input_estimate: int = 0
    images: int = 0
    dropped_images: int = 0


def resolve_model(requested: str, cfg: GatewayConfig) -> str:
    name = (requested or "").strip()
    if name.startswith(ALIAS_PREFIX):
        return name[len(ALIAS_PREFIX):] or cfg.backend_model
    low = name.lower()
    if not name or any(marker in low for marker in ANTHROPIC_MARKERS):
        return cfg.backend_model
    return name


def _text(s: str) -> dict:
    return {"type": "text", "text": s}


def _image_part(source: dict) -> dict:
    kind = source.get("type")
    if kind == "base64" and source.get("data"):
        media = source.get("media_type") or "image/png"
        return {"type": "image_url", "image_url": {"url": f"data:{media};base64,{source['data']}"}}
    if kind == "url" and source.get("url"):
        return {"type": "image_url", "image_url": {"url": source["url"]}}
    return _text(f"[image omitted: source type {kind!r} cannot be forwarded by the gateway]")


def _document_parts(block: dict) -> list[dict]:
    src = block.get("source") or {}
    head = f"[document: {block['title']}]\n" if block.get("title") else ""
    kind = src.get("type")
    if kind == "text":
        return [_text(head + str(src.get("data") or ""))]
    if kind == "content":
        inner = [p for b in src.get("content") or [] if isinstance(b, dict) for p in _block_parts(b)]
        return ([_text(head)] if head else []) + inner
    if kind == "base64" and str(src.get("media_type", "")).startswith("image/"):
        return [_image_part(src)]
    what = src.get("media_type") or kind or "document"
    return [_text(f"{head}[{what} omitted: the gateway forwards text and images only]")]


def _block_parts(block: dict) -> list[dict]:
    """OpenAI content parts for one Anthropic content block of a user turn (or of a tool_result)."""
    kind = block.get("type") or ""
    if kind == "text":
        return [_text(str(block.get("text") or ""))]
    if kind == "image":
        return [_image_part(block.get("source") or {})]
    if kind == "document":
        return _document_parts(block)
    if kind == "search_result":
        texts = [str(c.get("text") or "") for c in block.get("content") or [] if isinstance(c, dict)]
        return [_text("\n".join(t for t in (block.get("title"), block.get("source"), *texts) if t))]
    if kind in ("thinking", "redacted_thinking", "tool_use", "server_tool_use", "tool_reference") \
            or kind.endswith("_tool_result"):
        return []
    if isinstance(block.get("text"), str):
        return [_text(block["text"])]
    return []


def _collapse(parts: list[dict]) -> str | list[dict]:
    """Plain string when every part is text (chat templates handle strings best), else the parts list."""
    if all(p.get("type") == "text" for p in parts):
        return "\n".join(p["text"] for p in parts if p["text"])
    return parts


def _system_texts(value: Any) -> list[str]:
    if isinstance(value, str):
        return [value] if value.strip() else []
    texts = []
    for block in value or []:
        if isinstance(block, dict) and block.get("type", "text") == "text":
            t = str(block.get("text") or "")
            if t.strip() and not t.lstrip().startswith(ATTRIBUTION_PREFIX):
                texts.append(t)
    return texts


def _user_messages(content: Any, tool_names: dict[str, str]) -> list[dict]:
    if isinstance(content, str):
        return [{"role": "user", "content": content}]
    if not isinstance(content, list):
        raise GatewayError(400, "messages: content must be a string or a list of content blocks")
    tool_msgs: list[dict] = []
    follow: list[dict] = []       # images returned by tools: OpenAI tool messages cannot carry them
    parts: list[dict] = []
    for block in content:
        if not isinstance(block, dict):
            continue
        if block.get("type") != "tool_result":
            parts.extend(_block_parts(block))
            continue
        call_id = str(block.get("tool_use_id") or "")
        raw = block.get("content")
        if isinstance(raw, str):
            sub = [_text(raw)]
        elif isinstance(raw, list):
            sub = [p for b in raw if isinstance(b, dict) for p in _block_parts(b)]
        else:
            sub = []
        body = "\n".join(p["text"] for p in sub if p["type"] == "text" and p["text"])
        images = [p for p in sub if p["type"] == "image_url"]
        if images:
            note = f"[{len(images)} image(s) from this result follow in the next message]"
            body = f"{body}\n{note}" if body else note
        if block.get("is_error"):
            body = f"Error: {body}" if body else "Error"
        tool_msgs.append({"role": "tool", "tool_call_id": call_id, "content": body})
        if images:
            follow.append(_text(f"[image output of the {tool_names.get(call_id) or 'tool'} call]"))
            follow.extend(images)
    out = tool_msgs
    rest = follow + parts
    if rest or not tool_msgs:
        out = out + [{"role": "user", "content": _collapse(rest)}]
    return out


def _assistant_message(content: Any, tool_names: dict[str, str]) -> dict | None:
    if isinstance(content, str):
        return {"role": "assistant", "content": content} if content else None
    texts: list[str] = []
    calls: list[dict] = []
    for block in content or []:
        if not isinstance(block, dict):
            continue
        kind = block.get("type")
        if kind == "text" and block.get("text"):
            texts.append(str(block["text"]))
        elif kind == "tool_use":
            call_id = str(block.get("id") or _new_id("toolu_"))
            name = str(block.get("name") or "")
            tool_names[call_id] = name
            args = block.get("input")
            calls.append({"id": call_id, "type": "function",
                          "function": {"name": name,
                                       "arguments": json.dumps(args if args is not None else {}, ensure_ascii=False)}})
        # thinking / redacted_thinking / server tool blocks: nothing the backend can use
    text = "\n".join(texts)
    if not text and not calls:
        return None
    msg: dict = {"role": "assistant", "content": text or None}
    if calls:
        msg["tool_calls"] = calls
    return msg


def _translate_messages(body: dict) -> tuple[list[dict], bool]:
    system = _system_texts(body.get("system"))
    msgs: list[dict] = []
    tool_names: dict[str, str] = {}
    for m in body.get("messages") or []:
        if not isinstance(m, dict):
            raise GatewayError(400, "messages: each message must be an object")
        role, content = m.get("role"), m.get("content")
        if role == "user":
            msgs.extend(_user_messages(content, tool_names))
        elif role == "assistant":
            msg = _assistant_message(content, tool_names)
            if msg:
                msgs.append(msg)
        elif role == "system":     # Claude Code appends system entries mid-conversation; chat templates want one
            texts = _system_texts(content)
            if not msgs:
                system.extend(texts)
            elif texts:
                msgs.append({"role": "user", "content": "[System message]\n" + "\n\n".join(texts)})
        else:
            raise GatewayError(400, f"messages: unsupported role {role!r}")
    if not msgs:
        raise GatewayError(400, "messages: at least one user message is required")
    out = ([{"role": "system", "content": "\n\n".join(system)}] if system else []) + msgs
    last = msgs[-1]
    prefill = last["role"] == "assistant" and bool(last.get("content")) and not last.get("tool_calls")
    return out, prefill


def _translate_tools(tools: Any) -> tuple[list[dict], dict[str, dict]]:
    out: list[dict] = []
    schemas: dict[str, dict] = {}
    for tool in tools or []:
        if not isinstance(tool, dict):
            continue
        name, schema = tool.get("name"), tool.get("input_schema")
        if not name or not isinstance(schema, dict):
            # Anthropic server/built-in tools (web_search_*, bash_*, text_editor_*, ...) have no schema here
            # and would need Anthropic's servers to run: the backend never sees them.
            log.debug("dropping built-in tool %r (type %r)", name, tool.get("type"))
            continue
        if tool.get("defer_loading"):
            log.debug("dropping deferred tool %r (tool search is Anthropic-side)", name)
            continue
        out.append({"type": "function", "function": {"name": name, "description": tool.get("description") or "",
                                                     "parameters": schema}})
        schemas[name] = schema
    return out, schemas


def _tool_choice(choice: Any) -> tuple[Any, bool | None]:
    """(OpenAI tool_choice or None, parallel_tool_calls or None) for an Anthropic tool_choice."""
    if not isinstance(choice, dict):
        return None, None
    parallel = False if choice.get("disable_parallel_tool_use") else None
    kind = choice.get("type")
    if kind == "auto":
        return "auto", parallel
    if kind == "any":
        return "required", parallel
    if kind == "tool" and choice.get("name"):
        return {"type": "function", "function": {"name": choice["name"]}}, parallel
    if kind == "none":
        return "none", None
    return None, parallel


def _response_format(body: dict) -> dict | None:
    config = body.get("output_config") if isinstance(body.get("output_config"), dict) else {}
    fmt = config.get("format") or body.get("output_format")
    if isinstance(fmt, dict) and fmt.get("type") == "json_schema" and isinstance(fmt.get("schema"), dict):
        return {"type": "json_schema", "json_schema": {"name": fmt.get("name") or "output", "schema": fmt["schema"],
                                                       "strict": True}}
    return None


def _limit_images(messages: list[dict], limit: int) -> tuple[int, int]:
    """Keep the newest `limit` images (vLLM rejects prompts over --limit-mm-per-prompt); older ones become a
    placeholder. Returns (images kept, images dropped)."""
    where = [(m, i) for m in messages if isinstance(m.get("content"), list)
             for i, p in enumerate(m["content"]) if p.get("type") == "image_url"]
    drop = max(0, len(where) - limit) if limit > 0 else 0
    for m, i in where[:drop]:
        m["content"][i] = _text("[older image omitted: over the backend's per-request image limit]")
    return len(where) - drop, drop


def _deep_merge(dst: dict, src: dict) -> None:
    for key, value in src.items():
        if isinstance(value, dict) and isinstance(dst.get(key), dict):
            _deep_merge(dst[key], value)
        else:
            dst[key] = copy.deepcopy(value)


def translate_request(body: Any, cfg: GatewayConfig) -> tuple[dict, RequestContext]:
    """An Anthropic Messages request as an OpenAI chat-completions payload (without the stream fields)."""
    if not isinstance(body, dict):
        raise GatewayError(400, "request body must be a JSON object")
    messages, prefill = _translate_messages(body)
    kept, dropped = _limit_images(messages, cfg.max_images)
    tools, schemas = _translate_tools(body.get("tools"))
    requested = str(body.get("model") or "")
    max_tokens = body.get("max_tokens")
    if isinstance(max_tokens, bool) or not isinstance(max_tokens, int) or max_tokens <= 0:
        max_tokens = cfg.max_output_tokens or DEFAULT_MAX_TOKENS
    if cfg.max_output_tokens:
        max_tokens = min(max_tokens, cfg.max_output_tokens)
    payload: dict = {"model": resolve_model(requested, cfg), "messages": messages, "max_tokens": max_tokens}
    for key in ("temperature", "top_p", "top_k"):
        value = body.get(key)
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            payload[key] = value
    stops = [s for s in body.get("stop_sequences") or [] if isinstance(s, str) and s]
    if stops:
        payload["stop"] = stops
    if tools:
        payload["tools"] = tools
        choice, parallel = _tool_choice(body.get("tool_choice"))
        if choice is not None:
            payload["tool_choice"] = choice
        if parallel is not None:
            payload["parallel_tool_calls"] = parallel
    fmt = _response_format(body)
    if fmt:
        payload["response_format"] = fmt
    if prefill:                        # vLLM: continue the final assistant message instead of starting a new one
        payload["continue_final_message"] = True
        payload["add_generation_prompt"] = False
    _deep_merge(payload, cfg.extra_body)
    ctx = RequestContext(requested_model=requested, backend_model=payload["model"], stream=body.get("stream") is True,
                         max_tokens=max_tokens, tools=schemas, stop_sequences=stops, prefill=prefill,
                         images=kept, dropped_images=dropped)
    ctx.input_estimate = estimate_tokens(payload)
    return payload, ctx


# --------------------------------------------------------------------------------------------- token estimate

def _image_dims(b: bytes) -> tuple[int, int] | None:
    if b[:8] == b"\x89PNG\r\n\x1a\n" and len(b) >= 24:
        return struct.unpack(">II", b[16:24])
    if b[:6] in (b"GIF87a", b"GIF89a") and len(b) >= 10:
        return struct.unpack("<HH", b[6:10])
    if b[:2] == b"\xff\xd8":
        i = 2
        while i + 9 < len(b):
            if b[i] != 0xFF:
                i += 1
                continue
            marker = b[i + 1]
            if marker == 0xFF or marker in (0x01, 0xD8) or 0xD0 <= marker <= 0xD7:
                i += 1 if marker == 0xFF else 2
                continue
            if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
                h, w = struct.unpack(">HH", b[i + 5:i + 9])
                return w, h
            i += 2 + struct.unpack(">H", b[i + 2:i + 4])[0]
    return None


def _image_tokens(url: str) -> int:
    """Qwen-VL style cost: one token per 32x32 px after resizing into [256x256, 4096x4096] worth of pixels."""
    dims = None
    if url.startswith("data:"):
        head, _, data = url.partition(",")
        if ";base64" in head:
            try:
                dims = _image_dims(base64.b64decode(data[:65536]))
            except (binascii.Error, ValueError, struct.error):
                dims = None
    if not dims or not dims[0] or not dims[1]:
        return UNKNOWN_IMAGE_TOKENS
    pixels = min(max(dims[0] * dims[1], 65536), 16777216)
    return math.ceil(pixels / 1024) + 2


def estimate_tokens(payload: dict) -> int:
    """Approximate prompt tokens: ~3.5 characters per token for text, patch count for images."""
    chars, tokens = 0, 8
    for m in payload.get("messages") or []:
        tokens += 4
        content = m.get("content")
        if isinstance(content, str):
            chars += len(content)
        elif isinstance(content, list):
            for p in content:
                if p.get("type") == "text":
                    chars += len(p.get("text") or "")
                elif p.get("type") == "image_url":
                    tokens += _image_tokens(str((p.get("image_url") or {}).get("url") or ""))
        for call in m.get("tool_calls") or []:
            fn = call.get("function") or {}
            chars += len(fn.get("name") or "") + len(fn.get("arguments") or "") + 16
    if payload.get("tools"):
        chars += len(json.dumps(payload["tools"], ensure_ascii=False))
    return tokens + math.ceil(chars / 3.5)


# --------------------------------------------------------------------------------------------- tool calls left in text

_FUNCTION_RX = re.compile(r"<function=([^>\n]+)>(.*?)(?:</function>|\Z)", re.S)
_PARAM_RX = re.compile(r"<parameter=([^>\n]+)>(.*?)(?:</parameter>|(?=<parameter=)|\Z)", re.S)


def json_completion_suffix(s: str) -> str:
    """Characters that complete a truncated JSON document (close an open string, add a missing value, close
    brackets), or "" when `s` is already valid or cannot be fixed by appending."""
    try:
        json.loads(s)
        return ""
    except ValueError:
        pass
    closers: list[str] = []
    in_str = esc = False
    for ch in s:
        if in_str:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == '"':
                in_str = False
        elif ch == '"':
            in_str = True
        elif ch in "{[":
            closers.append("}" if ch == "{" else "]")
        elif ch in "}]":
            if not closers or closers[-1] != ch:
                return ""
            closers.pop()
    if esc:
        return ""
    head = '"' if in_str else ""
    tail = "".join(reversed(closers))
    for middle in ("", "null", ":null"):
        try:
            json.loads(s + head + middle + tail)
            return head + middle + tail
        except ValueError:
            continue
    return ""


def loads_lenient(s: str) -> Any:
    try:
        return json.loads(s)
    except ValueError:
        fix = json_completion_suffix(s)
        if fix:
            try:
                return json.loads(s + fix)
            except ValueError:
                return None
        return None


def _schema_types(prop: Any) -> list[str]:
    if not isinstance(prop, dict):
        return []
    kind = prop.get("type")
    if isinstance(kind, str):
        return [kind]
    if isinstance(kind, list):
        return [k for k in kind if isinstance(k, str)]
    types: list[str] = []
    for key in ("anyOf", "oneOf"):
        for sub in prop.get(key) or []:
            types.extend(_schema_types(sub))
    return types


def _coerce_param(value: str, schema: dict, key: str) -> Any:
    """Qwen XML parameters are text; convert them to the JSON type the tool's schema declares."""
    types = _schema_types(((schema or {}).get("properties") or {}).get(key))
    if not types or "string" in types:
        return value
    v = value.strip()
    for kind in types:
        if kind == "integer" and re.fullmatch(r"[-+]?\d+", v):
            return int(v)
        if kind == "number":
            try:
                return int(v) if re.fullmatch(r"[-+]?\d+", v) else float(v)
            except ValueError:
                pass
        if kind == "boolean" and v.lower() in ("true", "false"):
            return v.lower() == "true"
        if kind == "null" and v.lower() in ("null", "none"):
            return None
        if kind in ("object", "array"):
            parsed = loads_lenient(v)
            if isinstance(parsed, dict if kind == "object" else list):
                return parsed
    return value


def parse_tool_call_text(inner: str, tools: dict[str, dict]) -> list[tuple[str, dict]] | None:
    """Parse the inside of one <tool_call>...</tool_call>: Qwen XML (<function=NAME><parameter=K>V</parameter>)
    or hermes JSON ({"name", "arguments"}). None unless every call is well-formed and names a known tool."""
    s = inner.strip()
    if not s:
        return None
    calls: list[tuple[str, dict]] = []
    if s.startswith("<function="):
        for fm in _FUNCTION_RX.finditer(s):
            name = fm.group(1).strip()
            if name not in tools:
                return None
            args: dict = {}
            for pm in _PARAM_RX.finditer(fm.group(2)):
                val = pm.group(2)
                val = val[1:] if val.startswith("\n") else val
                val = val[:-1] if val.endswith("\n") else val
                args[pm.group(1).strip()] = _coerce_param(val, tools[name], pm.group(1).strip())
            calls.append((name, args))
        return calls or None
    obj = loads_lenient(s)
    for item in obj if isinstance(obj, list) else [obj]:
        if not isinstance(item, dict):
            return None
        fn = item["function"] if isinstance(item.get("function"), dict) else item
        name = fn.get("name")
        args = fn.get("arguments", fn.get("parameters", {}))
        if isinstance(args, str):
            args = loads_lenient(args) if args.strip() else {}
        if not isinstance(name, str) or name not in tools or not isinstance(args, dict):
            return None
        calls.append((name, args))
    return calls or None


def _partial_suffix(buf: str, tag: str) -> int:
    """Length of the longest suffix of `buf` that is a proper prefix of `tag` (text to hold back)."""
    for k in range(min(len(buf), len(tag) - 1), 0, -1):
        if buf.endswith(tag[:k]):
            return k
    return 0


# --------------------------------------------------------------------------------------------- response: OpenAI -> Anthropic

_TOOL_ID_OK = re.compile(r"^[A-Za-z0-9_-]+$")


@dataclass
class _ToolState:
    raw_id: str = ""
    id: str = ""
    name: str = ""
    pending: str = ""        # arguments received before the block could open (no name yet)
    sent: str = ""           # arguments already streamed to the client
    started: bool = False
    closed: bool = False


class StreamTranslator:
    """Turns OpenAI chat-completion chunks into Anthropic Messages events, one block open at a time:
    message_start, [thinking], [text], [tool_use...], message_delta, message_stop. Every path uses it: backend
    streams, whole backend responses re-streamed, and non-streaming replies (accumulated with `accumulate`)."""

    def __init__(self, ctx: RequestContext, cfg: GatewayConfig):
        self.ctx, self.cfg = ctx, cfg
        self.msg_id = _new_id("msg_")
        self.scan = bool(ctx.tools) and cfg.text_tool_calls
        self.next_index = 0
        self.index = -1
        self.open_kind: str | None = None
        self.open_tool: _ToolState | None = None
        self.pending_ws = ""
        self.pending_reasoning = ""
        self.scan_buf = ""
        self.in_tag = False
        self.tag_buf = ""
        self.visible: list[str] = []
        self.reasoning: list[str] = []
        self.tools: dict[int, _ToolState] = {}
        self.last_key: int | None = None
        self.used_ids: set[str] = set()
        self.tool_uses = 0
        self.finish_reason: str | None = None
        self.backend_stop: Any = None
        self.usage: dict | None = None
        self.out_chars = 0

    # -- events
    @staticmethod
    def _ev(name: str, **data: Any) -> tuple[str, dict]:
        return name, {"type": name, **data}

    def _delta(self, delta: dict) -> tuple[str, dict]:
        return self._ev("content_block_delta", index=self.index, delta=delta)

    def start(self) -> list[tuple[str, dict]]:
        usage = {"input_tokens": self.ctx.input_estimate, "output_tokens": 0,
                 "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}
        return [self._ev("message_start", message={
            "id": self.msg_id, "type": "message", "role": "assistant",
            "model": self.ctx.requested_model or self.ctx.backend_model, "content": [],
            "stop_reason": None, "stop_sequence": None, "usage": usage})]

    def _open(self, block: dict, kind: str) -> list[tuple[str, dict]]:
        evs = self._close()
        self.index = self.next_index
        self.next_index += 1
        self.open_kind = kind
        evs.append(self._ev("content_block_start", index=self.index, content_block=block))
        return evs

    def _close(self) -> list[tuple[str, dict]]:
        if self.open_kind is None:
            return []
        evs = []
        if self.open_kind == "thinking":
            evs.append(self._delta({"type": "signature_delta", "signature": THINKING_SIGNATURE}))
        elif self.open_kind == "tool" and self.open_tool is not None:
            st = self.open_tool
            fix = "{}" if not st.sent.strip() else json_completion_suffix(st.sent)
            if fix:
                evs.append(self._delta({"type": "input_json_delta", "partial_json": fix}))
                st.sent += fix
            st.closed = True
            self.open_tool = None
        evs.append(self._ev("content_block_stop", index=self.index))
        self.open_kind = None
        return evs

    # -- text
    def _emit_text(self, s: str) -> list[tuple[str, dict]]:
        if not s:
            return []
        if self.open_kind == "text":
            self.visible.append(s)
            return [self._delta({"type": "text_delta", "text": s})]
        self.pending_ws += s
        if not self.pending_ws.strip():
            return []          # whitespace alone never opens a block (e.g. the "\n\n" before a tool call)
        text = self.pending_ws if self.ctx.prefill else self.pending_ws.lstrip()
        self.pending_ws = ""
        evs = self._open({"type": "text", "text": ""}, "text")
        self.visible.append(text)
        evs.append(self._delta({"type": "text_delta", "text": text}))
        return evs

    def _in_code_fence(self) -> bool:
        return ("".join(self.visible) + self.pending_ws).count("```") % 2 == 1

    def _on_text(self, s: str) -> list[tuple[str, dict]]:
        """Text with <tool_call> markup detection: plain text streams through; a complete tag that parses into
        calls of known tools becomes tool_use blocks; anything else is emitted as the text it was."""
        evs: list[tuple[str, dict]] = []
        self.scan_buf += s
        while self.scan_buf:
            if not self.in_tag:
                p = self.scan_buf.find(TOOL_OPEN)
                if p == -1:
                    keep = _partial_suffix(self.scan_buf, TOOL_OPEN)
                    cut = len(self.scan_buf) - keep
                    evs += self._emit_text(self.scan_buf[:cut])
                    self.scan_buf = self.scan_buf[cut:]
                    break
                evs += self._emit_text(self.scan_buf[:p])
                self.scan_buf = self.scan_buf[p + len(TOOL_OPEN):]
                self.in_tag, self.tag_buf = True, ""
            else:
                q = self.scan_buf.find(TOOL_CLOSE)
                if q == -1:
                    keep = _partial_suffix(self.scan_buf, TOOL_CLOSE)
                    cut = len(self.scan_buf) - keep
                    self.tag_buf += self.scan_buf[:cut]
                    self.scan_buf = self.scan_buf[cut:]
                    break
                self.tag_buf += self.scan_buf[:q]
                self.scan_buf = self.scan_buf[q + len(TOOL_CLOSE):]
                self.in_tag = False
                evs += self._emit_tag(self.tag_buf, closed=True)
                self.tag_buf = ""
        return evs

    def _emit_tag(self, inner: str, closed: bool) -> list[tuple[str, dict]]:
        calls = None if self._in_code_fence() else parse_tool_call_text(inner, self.ctx.tools)
        if not calls:
            return self._emit_text(TOOL_OPEN + inner + (TOOL_CLOSE if closed else ""))
        evs: list[tuple[str, dict]] = []
        for name, args in calls:
            evs += self._emit_whole_tool(name, args)
        return evs

    def _flush_scan(self) -> list[tuple[str, dict]]:
        if self.in_tag:
            inner = self.tag_buf + self.scan_buf
            self.in_tag, self.tag_buf, self.scan_buf = False, "", ""
            return self._emit_tag(inner, closed=False)
        buf, self.scan_buf = self.scan_buf, ""
        return self._emit_text(buf)

    # -- reasoning
    def _on_reasoning(self, s: str) -> list[tuple[str, dict]]:
        self.reasoning.append(s)
        if self.cfg.thinking != "emit":
            return []
        if self.open_kind == "thinking":
            return [self._delta({"type": "thinking_delta", "thinking": s})]
        self.pending_reasoning += s
        if not self.pending_reasoning.strip():
            return []
        text, self.pending_reasoning = self.pending_reasoning.lstrip(), ""
        evs = self._flush_scan()
        evs += self._open({"type": "thinking", "thinking": "", "signature": ""}, "thinking")
        evs.append(self._delta({"type": "thinking_delta", "thinking": text}))
        return evs

    # -- tool calls
    def _tool_id(self, raw: str) -> str:
        tid = raw if raw and _TOOL_ID_OK.match(raw) else re.sub(r"[^A-Za-z0-9_-]", "_", raw or "")
        tid = tid or _new_id("toolu_")
        base, n = tid, 1
        while tid in self.used_ids:
            tid, n = f"{base}_{n}", n + 1
        self.used_ids.add(tid)
        return tid

    def _begin_tool(self, st: _ToolState) -> list[tuple[str, dict]]:
        st.id = self._tool_id(st.raw_id)
        evs = self._open({"type": "tool_use", "id": st.id, "name": st.name, "input": {}}, "tool")
        self.open_tool = st
        st.started = True
        self.pending_ws = ""
        self.tool_uses += 1
        return evs

    def _emit_whole_tool(self, name: str, args: dict) -> list[tuple[str, dict]]:
        st = _ToolState(name=name)
        evs = self._begin_tool(st)
        st.sent = json.dumps(args, ensure_ascii=False)
        evs.append(self._delta({"type": "input_json_delta", "partial_json": st.sent}))
        evs += self._close()
        return evs

    def _tool_key(self, tc: dict) -> int:
        idx = tc.get("index")
        if isinstance(idx, int) and not isinstance(idx, bool):
            return idx
        raw = tc.get("id")
        if raw:
            for key, st in self.tools.items():
                if st.raw_id == raw:
                    return key
            return max(self.tools) + 1 if self.tools else 0
        return self.last_key if self.last_key is not None else 0

    def _on_tool_delta(self, tc: dict) -> list[tuple[str, dict]]:
        key = self._tool_key(tc)
        st = self.tools.setdefault(key, _ToolState())
        self.last_key = key
        if tc.get("id") and not st.raw_id:
            st.raw_id = str(tc["id"])
        fn = tc.get("function") or {}
        if fn.get("name") and not st.name:
            st.name = str(fn["name"])
        args = fn.get("arguments")
        if args is not None and not isinstance(args, str):
            args = json.dumps(args, ensure_ascii=False)
        args = args or ""
        if st.closed or (st.started and self.open_tool is not st):
            if args:
                log.warning("dropping %d chars of late arguments for tool call %r", len(args), st.name)
            return []
        if not st.started:
            st.pending += args
            if not st.name:
                return []
            evs = self._flush_scan()       # text held back by the <tool_call> scanner goes out first
            evs += self._begin_tool(st)
            if st.pending:
                evs.append(self._delta({"type": "input_json_delta", "partial_json": st.pending}))
                st.sent, st.pending = st.pending, ""
            return evs
        if not args:
            return []
        st.sent += args
        return [self._delta({"type": "input_json_delta", "partial_json": args})]

    # -- chunks
    def feed(self, chunk: Any) -> list[tuple[str, dict]]:
        if not isinstance(chunk, dict):
            return []
        err = chunk.get("error")
        if err or chunk.get("object") == "error":
            msg = err.get("message") if isinstance(err, dict) else (err or chunk.get("message"))
            raise BackendStreamError(str(msg or "backend stream error"))
        if chunk.get("usage"):
            self.usage = chunk["usage"]
        evs: list[tuple[str, dict]] = []
        for choice in chunk.get("choices") or []:
            if not isinstance(choice, dict) or choice.get("index", 0) != 0:
                continue
            delta = choice.get("delta") or {}
            reasoning = delta.get("reasoning_content") or delta.get("reasoning")
            if isinstance(reasoning, str) and reasoning:
                self.out_chars += len(reasoning)
                evs += self._on_reasoning(reasoning)
            content = delta.get("content")
            if isinstance(content, list):
                content = "".join(str(p.get("text") or "") for p in content if isinstance(p, dict))
            if isinstance(content, str) and content:
                self.out_chars += len(content)
                evs += self._on_text(content) if self.scan else self._emit_text(content)
            calls = list(delta.get("tool_calls") or [])
            if isinstance(delta.get("function_call"), dict):         # legacy single-function streaming
                calls.insert(0, {"index": 0, "function": delta["function_call"]})
            for tc in calls:
                if isinstance(tc, dict):
                    arguments = (tc.get("function") or {}).get("arguments")
                    self.out_chars += len(arguments) if isinstance(arguments, str) else 0
                    evs += self._on_tool_delta(tc)
            if choice.get("finish_reason"):
                self.finish_reason = choice["finish_reason"]
            if choice.get("stop_reason") is not None:                # vLLM: the stop string that matched
                self.backend_stop = choice["stop_reason"]
        return evs

    def _promote_reasoning_calls(self) -> list[tuple[str, dict]]:
        """A tool call written before </think> lands in the reasoning (vLLM's reasoning parser splits there) and
        is lost. Recover it only in the unambiguous case: no text, no tool calls, and the reasoning ENDS in one
        or more complete-or-final <tool_call> blocks of known tools."""
        if not self.scan or self.tool_uses or ("".join(self.visible) + self.pending_ws).strip():
            return []
        text = "".join(self.reasoning).rstrip()
        if TOOL_OPEN not in text:
            return []
        matches = list(re.finditer(r"<tool_call>(.*?)(?:</tool_call>|\Z)", text, re.S))
        run, end = [], len(text)
        for m in reversed(matches):
            if text[m.end():end].strip():
                break
            run.append(m)
            end = m.start()
        calls: list[tuple[str, dict]] = []
        for m in reversed(run):
            parsed = parse_tool_call_text(m.group(1), self.ctx.tools)
            if not parsed:
                return []
            calls.extend(parsed)
        if calls:
            log.info("recovered %d tool call(s) the backend left at the end of its reasoning", len(calls))
        evs: list[tuple[str, dict]] = []
        for name, args in calls:
            evs += self._emit_whole_tool(name, args)
        return evs

    def _stop(self) -> tuple[str, str | None]:
        fr = self.finish_reason
        if fr == "length":
            return "max_tokens", None
        if self.tool_uses:
            return "tool_use", None
        if fr == "content_filter":
            return "refusal", None
        if isinstance(self.backend_stop, str) and self.backend_stop in self.ctx.stop_sequences:
            return "stop_sequence", self.backend_stop
        return "end_turn", None

    def _final_usage(self) -> dict:
        u = self.usage or {}
        prompt, completion = u.get("prompt_tokens"), u.get("completion_tokens")
        cached = (u.get("prompt_tokens_details") or {}).get("cached_tokens") or 0
        return {"input_tokens": (prompt - cached) if isinstance(prompt, int) else self.ctx.input_estimate,
                "output_tokens": completion if isinstance(completion, int) else max(1, self.out_chars // 4),
                "cache_creation_input_tokens": 0, "cache_read_input_tokens": cached}

    def finish(self) -> list[tuple[str, dict]]:
        evs = self._flush_scan()
        evs += self._promote_reasoning_calls()
        for st in self.tools.values():
            if not st.started and (st.pending or st.raw_id):
                log.warning("dropping a streamed tool call that never received a function name")
        if self.next_index == 0:        # always at least one block, like the Messages API
            evs += self._open({"type": "text", "text": ""}, "text")
        evs += self._close()
        stop_reason, stop_sequence = self._stop()
        evs.append(self._ev("message_delta", delta={"stop_reason": stop_reason, "stop_sequence": stop_sequence},
                            usage=self._final_usage()))
        evs.append(self._ev("message_stop"))
        return evs


def response_to_chunks(data: dict) -> list[dict]:
    """A whole chat-completion response as one stream chunk, so it goes through the same translator."""
    choices = data.get("choices") if isinstance(data, dict) else None
    if not choices:
        raise GatewayError(502, f"backend returned no choices: {str(data)[:300]}", "api_error")
    choice = choices[0] or {}
    msg = choice.get("message") or {}
    delta: dict = {}
    reasoning = msg.get("reasoning_content") or msg.get("reasoning")
    if reasoning:
        delta["reasoning_content"] = reasoning
    if msg.get("content"):
        delta["content"] = msg["content"]
    calls = []
    for i, tc in enumerate(msg.get("tool_calls") or []):
        fn = tc.get("function") or {}
        args = fn.get("arguments")
        calls.append({"index": i, "id": tc.get("id"), "type": "function",
                      "function": {"name": fn.get("name"),
                                   "arguments": args if isinstance(args, str) else json.dumps(args or {})}})
    if calls:
        delta["tool_calls"] = calls
    return [{"choices": [{"index": 0, "delta": delta, "finish_reason": choice.get("finish_reason"),
                          "stop_reason": choice.get("stop_reason")}], "usage": data.get("usage")}]


def _tool_input(partial: str) -> dict:
    if not partial.strip():
        return {}
    value = loads_lenient(partial)
    if isinstance(value, str):             # double-encoded arguments
        value = loads_lenient(value)
    return value if isinstance(value, dict) else {}


def accumulate(events: list[tuple[str, dict]]) -> dict:
    """Fold Messages stream events into the final Message object (what a non-streaming call returns)."""
    message: dict = {}
    blocks: list[dict] = []
    partial: dict[int, str] = {}
    for name, data in events:
        if name == "message_start":
            message = copy.deepcopy(data["message"])
        elif name == "content_block_start":
            blocks.append(copy.deepcopy(data["content_block"]))
            partial[data["index"]] = ""
        elif name == "content_block_delta":
            block, delta = blocks[data["index"]], data["delta"]
            kind = delta["type"]
            if kind == "text_delta":
                block["text"] += delta["text"]
            elif kind == "input_json_delta":
                partial[data["index"]] += delta["partial_json"]
            elif kind == "thinking_delta":
                block["thinking"] += delta["thinking"]
            elif kind == "signature_delta":
                block["signature"] = delta["signature"]
        elif name == "content_block_stop":
            block = blocks[data["index"]]
            if block["type"] == "tool_use":
                block["input"] = _tool_input(partial[data["index"]])
        elif name == "message_delta":
            message.update(data.get("delta") or {})
            message.setdefault("usage", {}).update(data.get("usage") or {})
    message["content"] = blocks
    return message


def response_to_message(data: dict, ctx: RequestContext, cfg: GatewayConfig) -> dict:
    tr = StreamTranslator(ctx, cfg)
    events = tr.start()
    for chunk in response_to_chunks(data):
        try:
            events += tr.feed(chunk)
        except BackendStreamError as e:
            raise GatewayError(502, f"backend error: {e}", "api_error") from None
    return accumulate(events + tr.finish())


# --------------------------------------------------------------------------------------------- backend client

_CTX_LIMIT_RX = re.compile(r"maximum context length is (\d+)", re.I)
_CTX_INPUT_RXS = (re.compile(r"(\d+) input tokens", re.I), re.compile(r"\((\d+) in the messages", re.I),
                  re.compile(r"request has (\d+)", re.I), re.compile(r"you requested (\d+) tokens in the messages", re.I))


def context_fix(message: str, max_tokens: int | None) -> tuple[str, Any] | None:
    """For a backend context-length error: ("clamp", new_max_tokens) when the prompt fits with less output
    room, ("too_long", anthropic_message) when it does not, None when the numbers are not in the message."""
    m = _CTX_LIMIT_RX.search(message or "")
    if not m:
        return None
    limit = int(m.group(1))
    used = next((int(x.group(1)) for rx in _CTX_INPUT_RXS if (x := rx.search(message))), None)
    if used is None:
        return None
    want = max_tokens or DEFAULT_MAX_TOKENS
    floor = min(MIN_OUTPUT_TOKENS, want)
    room = limit - used - 1
    if room >= floor:
        return ("clamp", room) if room < want else None
    # Claude Code recognises this wording and compacts the conversation, then retries.
    return "too_long", f"prompt is too long: {used} tokens > {limit - floor} maximum"


def _backend_message(raw: bytes, status: int) -> str:
    try:
        data = json.loads(raw)
    except ValueError:
        text = raw.decode("utf-8", "replace").strip()
        return text[:2000] or f"HTTP {status}"
    if isinstance(data, dict):
        err = data.get("error")
        if isinstance(err, dict) and err.get("message"):
            return str(err["message"])
        if isinstance(err, str):
            return err
        if data.get("message"):
            return str(data["message"])
        if data.get("detail"):
            return json.dumps(data["detail"]) if not isinstance(data["detail"], str) else data["detail"]
    return json.dumps(data)[:2000]


def _map_backend_error(status: int, message: str, headers: httpx.Headers) -> GatewayError:
    extra = {}
    retry_after = (headers.get("retry-after") or "").strip()
    if retry_after.isdigit():
        extra["retry-after"] = retry_after
    if status in (401, 403):   # the gateway's backend credential, not the client's: never make Claude Code re-login
        return GatewayError(502, f"backend rejected the gateway's credentials (HTTP {status}); check "
                                 f"GATEWAY_BACKEND_KEY: {message}", "api_error")
    if status == 404:
        return GatewayError(404, f"backend: {message}", "not_found_error")
    if status == 413:
        return GatewayError(413, message, "request_too_large")
    if status == 429:
        return GatewayError(429, message, "rate_limit_error", extra)
    if status >= 500:
        kind = "overloaded_error" if status in (503, 529) else "api_error"
        return GatewayError(status if status in (500, 502, 503, 504, 529) else 502, f"backend: {message}", kind, extra)
    return GatewayError(400, message, "invalid_request_error")


class Backend:
    """The OpenAI-compatible server behind the gateway. `client` is a plain httpx.AsyncClient (tests replace it)."""

    def __init__(self, cfg: GatewayConfig, client: httpx.AsyncClient | None = None):
        self.cfg = cfg
        self.client = client or httpx.AsyncClient(timeout=httpx.Timeout(cfg.timeout, connect=15.0))
        self._models: list[str] = []
        self._models_at = 0.0

    def url(self, path: str) -> str:
        return self.cfg.backend_url.rstrip("/") + path

    def headers(self) -> dict:
        h = {"content-type": "application/json"}
        if self.cfg.backend_key:
            h["authorization"] = f"Bearer {self.cfg.backend_key}"
        return h

    async def _send(self, payload: dict, stream: bool) -> httpx.Response:
        request = self.client.build_request("POST", self.url("/chat/completions"), json=payload, headers=self.headers())
        try:
            return await self.client.send(request, stream=stream)
        except httpx.TimeoutException as e:
            raise GatewayError(504, f"backend timed out ({type(e).__name__})", "api_error") from None
        except httpx.HTTPError as e:
            raise GatewayError(502, f"backend unreachable at {self.cfg.backend_url}: {type(e).__name__}: {e}",
                               "api_error") from None

    async def request(self, payload: dict, stream: bool) -> httpx.Response:
        """POST /chat/completions. A context-length 400 is retried with max_tokens clamped to the room left, or
        answered as Anthropic's "prompt is too long"; other errors raise GatewayError. `payload` is updated."""
        for _ in range(3):
            resp = await self._send(payload, stream)
            if resp.status_code < 400:
                return resp
            raw = await resp.aread()
            await resp.aclose()
            message = _backend_message(raw, resp.status_code)
            if resp.status_code == 400:
                fix = context_fix(message, payload.get("max_tokens"))
                if fix and fix[0] == "clamp":
                    log.info("max_tokens %s -> %s to fit the backend context window", payload.get("max_tokens"), fix[1])
                    payload["max_tokens"] = fix[1]
                    continue
                if fix:
                    raise GatewayError(400, fix[1], "invalid_request_error")
            raise _map_backend_error(resp.status_code, message, resp.headers)
        raise GatewayError(400, "prompt is too long: the backend kept rejecting the request's length",
                           "invalid_request_error")

    async def chat(self, payload: dict) -> dict:
        payload["stream"] = False
        payload.pop("stream_options", None)
        resp = await self.request(payload, stream=False)
        try:
            return resp.json()
        except ValueError:
            raise GatewayError(502, f"backend returned non-JSON: {resp.text[:300]}", "api_error") from None

    async def open_stream(self, payload: dict) -> httpx.Response:
        payload["stream"] = True
        payload["stream_options"] = {"include_usage": True}
        return await self.request(payload, stream=True)

    @staticmethod
    async def iter_chunks(resp: httpx.Response) -> AsyncIterator[dict]:
        """OpenAI SSE `data:` lines as dicts, until [DONE] or the end of the body."""
        async for line in resp.aiter_lines():
            line = line.strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                return
            try:
                yield json.loads(data)
            except ValueError:
                log.warning("skipping an undecodable backend SSE line (%d chars)", len(data))

    async def model_ids(self) -> list[str]:
        """Models the backend serves (cached for a minute; ~2 s budget, Claude Code's discovery waits 3 s)."""
        now = time.monotonic()
        if self._models and now - self._models_at < 60:
            return self._models
        ids: list[str] = []
        try:
            resp = await self.client.get(self.url("/models"), headers=self.headers(), timeout=2.0)
            if resp.status_code == 200:
                ids = [str(m["id"]) for m in resp.json().get("data") or [] if isinstance(m, dict) and m.get("id")]
        except (httpx.HTTPError, ValueError, AttributeError):
            ids = []
        ids = [self.cfg.backend_model] + [i for i in ids if i != self.cfg.backend_model]
        self._models, self._models_at = ids, now
        return ids

    async def aclose(self) -> None:
        await self.client.aclose()


# --------------------------------------------------------------------------------------------- SSE

def sse(name: str, data: dict) -> str:
    return f"event: {name}\ndata: {json.dumps(data, ensure_ascii=False, separators=(',', ':'))}\n\n"


PING = sse("ping", {"type": "ping"})


async def sse_stream(tr: StreamTranslator, chunks: AsyncIterator[dict], cleanup: Callable[[], Awaitable[None]],
                     ping_seconds: float) -> AsyncIterator[str]:
    """Translate backend chunks to Anthropic SSE, with `ping` events whenever the backend is silent (Claude Code
    aborts a stream that goes quiet). A backend failure after the stream started becomes an `error` event."""
    queue: asyncio.Queue = asyncio.Queue()

    async def pump() -> None:
        try:
            async for chunk in chunks:
                await queue.put(("chunk", chunk))
            await queue.put(("end", None))
        except asyncio.CancelledError:
            raise
        except Exception as e:  # noqa: BLE001 - reported to the client as an error event
            await queue.put(("error", e))

    pump_task = asyncio.create_task(pump())
    getter: asyncio.Future | None = None
    try:
        for ev in tr.start():
            yield sse(*ev)
        yield PING
        while True:
            if getter is None:
                getter = asyncio.ensure_future(queue.get())
            done, _ = await asyncio.wait({getter}, timeout=ping_seconds)
            if not done:
                yield PING
                continue
            kind, item = getter.result()
            getter = None
            if kind == "chunk":
                try:
                    events = tr.feed(item)
                except BackendStreamError as e:
                    yield sse("error", error_body("api_error", f"backend error: {e}"))
                    return
                for ev in events:
                    yield sse(*ev)
            elif kind == "end":
                for ev in tr.finish():
                    yield sse(*ev)
                return
            else:
                err = item if isinstance(item, GatewayError) else GatewayError(502, f"backend stream failed: "
                                                                                    f"{type(item).__name__}: {item}")
                yield sse("error", error_body(err.etype, err.message))
                return
    finally:
        if getter is not None and not getter.done():
            getter.cancel()
        pump_task.cancel()
        # Shielded: when the client goes away Starlette cancels this generator, and an unshielded await here would be
        # cancelled too, leaving vLLM generating into a dead connection. Closing the response aborts the generation.
        with anyio.CancelScope(shield=True):
            try:
                await cleanup()
            except Exception:  # noqa: BLE001
                pass
            with suppress(asyncio.CancelledError, Exception):
                await pump_task


async def _chunks_of(task: asyncio.Task) -> AsyncIterator[dict]:
    for chunk in response_to_chunks(await task):
        yield chunk


# --------------------------------------------------------------------------------------------- app

def _check_auth(request: Request, cfg: GatewayConfig) -> None:
    if not cfg.api_key:
        return                  # accept any x-api-key / Authorization, as Claude Code always sends one
    presented = request.headers.get("x-api-key") or ""
    auth = request.headers.get("authorization") or ""
    if not presented and auth.lower().startswith("bearer "):
        presented = auth[7:].strip()
    if not presented or not hmac.compare_digest(presented.encode(), cfg.api_key.encode()):
        raise GatewayError(401, "invalid API key for this gateway", "authentication_error")


async def _read_json(request: Request) -> dict:
    try:
        body = await request.json()
    except Exception:  # noqa: BLE001
        raise GatewayError(400, "request body is not valid JSON") from None
    if not isinstance(body, dict):
        raise GatewayError(400, "request body must be a JSON object")
    return body


def _model_object(model_id: str, backend_id: str) -> dict:
    return {"type": "model", "id": model_id, "display_name": f"{backend_id} (via gateway)",
            "created_at": "2026-01-01T00:00:00Z", "description": f"Routed to backend model {backend_id!r}"}


def create_app(cfg: GatewayConfig | None = None, backend: Backend | None = None) -> FastAPI:
    cfg = cfg or GatewayConfig.from_env()
    backend = backend or Backend(cfg)

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        yield
        await app.state.backend.aclose()

    app = FastAPI(title="cybus anthropic gateway", lifespan=lifespan, docs_url=None, redoc_url=None,
                  openapi_url=None)
    app.state.cfg = cfg
    app.state.backend = backend

    @app.exception_handler(GatewayError)
    async def _gateway_error(request: Request, exc: GatewayError) -> JSONResponse:
        retry = exc.status >= 500 or exc.status == 429
        return JSONResponse(error_body(exc.etype, exc.message), status_code=exc.status,
                            headers={"x-should-retry": "true" if retry else "false", **exc.headers})

    async def guarded(fn: Callable[[], Awaitable[Any]]) -> Any:
        try:
            return await fn()
        except GatewayError:
            raise
        except Exception as e:  # noqa: BLE001 - always answer in the Anthropic error envelope
            log.exception("gateway failure")
            raise GatewayError(500, f"gateway error: {type(e).__name__}: {e}", "api_error") from None

    @app.post("/v1/messages")
    async def create_message(request: Request):
        async def run():
            _check_auth(request, cfg)
            body = await _read_json(request)
            payload, ctx = translate_request(body, cfg)
            be: Backend = app.state.backend
            rid = _new_id("req_")
            log.info("%s model=%s->%s stream=%s messages=%d tools=%d images=%d(-%d) est_input=%d max_tokens=%d", rid,
                     ctx.requested_model, ctx.backend_model, ctx.stream, len(payload["messages"]), len(ctx.tools),
                     ctx.images, ctx.dropped_images, ctx.input_estimate, ctx.max_tokens)
            headers = {"request-id": rid}
            if not ctx.stream:
                message = response_to_message(await be.chat(payload), ctx, cfg)
                log.info("%s done stop=%s usage=%s", rid, message.get("stop_reason"), message.get("usage"))
                return JSONResponse(message, headers=headers)
            if cfg.backend_stream:
                resp = await be.open_stream(payload)
                chunks, cleanup = be.iter_chunks(resp), resp.aclose
            else:
                task = asyncio.create_task(be.chat(payload))
                done, _ = await asyncio.wait({task}, timeout=cfg.early_error_seconds)
                if done:
                    task.result()          # a fast failure (bad request, context length) becomes an HTTP error

                async def cancel_task() -> None:
                    task.cancel()
                chunks, cleanup = _chunks_of(task), cancel_task
            tr = StreamTranslator(ctx, cfg)
            return StreamingResponse(sse_stream(tr, chunks, cleanup, cfg.ping_seconds), media_type="text/event-stream",
                                     headers={**headers, "cache-control": "no-cache", "x-accel-buffering": "no"})
        return await guarded(run)

    @app.post("/v1/messages/count_tokens")
    async def count_tokens(request: Request):
        async def run():
            _check_auth(request, cfg)
            body = await _read_json(request)
            body.setdefault("max_tokens", 1)
            _, ctx = translate_request(body, cfg)
            return {"input_tokens": ctx.input_estimate}
        return await guarded(run)

    @app.get("/v1/models")
    async def list_models(request: Request):
        async def run():
            _check_auth(request, cfg)
            ids = await app.state.backend.model_ids()
            data = [obj for mid in ids for obj in (_model_object(ALIAS_PREFIX + mid, mid), _model_object(mid, mid))]
            return {"data": data, "has_more": False, "first_id": data[0]["id"], "last_id": data[-1]["id"]}
        return await guarded(run)

    @app.get("/v1/models/{model_id:path}")
    async def get_model(model_id: str, request: Request):
        _check_auth(request, cfg)
        return _model_object(model_id, resolve_model(model_id, cfg))

    @app.api_route("/", methods=["GET", "HEAD"])
    @app.api_route("/health", methods=["GET", "HEAD"])
    @app.api_route("/api/hello", methods=["GET", "HEAD"])
    async def health():
        return {"status": "ok", "backend_model": cfg.backend_model}

    return app


def __getattr__(name: str) -> Any:
    """`serve.anthropic_gateway:app` for uvicorn, built from the environment on first access."""
    if name == "app":
        globals()["app"] = application = create_app()
        return application
    raise AttributeError(name)


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description="Anthropic Messages API gateway in front of an OpenAI-compatible "
                                                 "backend (Cybus on vLLM). Configured by GATEWAY_* env vars.")
    parser.add_argument("--host", default=os.environ.get("GATEWAY_HOST", "127.0.0.1"),
                        help="bind address (default 127.0.0.1; the gateway holds the backend key)")
    parser.add_argument("--port", type=int, default=int(os.environ.get("GATEWAY_PORT", "4000")))
    parser.add_argument("--log-level", default=os.environ.get("GATEWAY_LOG_LEVEL", "info"))
    args = parser.parse_args(argv)
    logging.basicConfig(level=args.log_level.upper(), format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    import uvicorn
    cfg = GatewayConfig.from_env()
    log.info("backend %s model %s (backend streaming %s, thinking %s)", cfg.backend_url, cfg.backend_model,
             "on" if cfg.backend_stream else "off", cfg.thinking)
    uvicorn.run(create_app(cfg), host=args.host, port=args.port, log_level=args.log_level.lower())


if __name__ == "__main__":
    main()

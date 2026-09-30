"""Tool-using agent loop: model -> tool calls -> results -> ... until it answers, submits, or runs out.

Structured output goes through a `submit` tool whose parameters are the caller's JSON Schema; its
arguments are validated and, when they do not match, the model is told what to fix. What the model is
sent is kept under a token budget by trimming old material (never the system prompt, the task or the
recent turns); the transcript in the result stays complete.
"""

from __future__ import annotations

import asyncio
import json
import os
import logging
import time
from dataclasses import dataclass, replace
from typing import Any, Callable

import jsonschema

from .llm import LLM, PARSE_ERROR_KEY, RAW_ARGUMENTS_KEY, Message, ToolCall, image_part, text_part
from .tools.base import Tool, ToolResult, tools_by_name

log = logging.getLogger(__name__)

SUBMIT = "submit"

_NO_SUBMIT = ("You ended your turn without calling `submit`. If you are done, call the `submit` tool now with "
              "your final answer as its arguments; otherwise keep working with the tools.")
_LAST_STEP = "You have one step left: call `submit` now with your best answer."
_FORCED_SUBMIT = ("You are out of steps and no other tool is available now. Call `submit` with your report of what "
                  "you have done so far (what works, what is unfinished).")


@dataclass
class AgentResult:
    text: str                  # the model's last non-empty text
    structured: dict | None    # what was passed to `submit` (runs with a schema)
    steps: int                 # model calls made
    transcript: list[Message]  # the whole conversation, untrimmed
    usage: dict                # token usage summed over the model calls
    stopped: str               # "submitted" | "no_tool_calls" | "max_steps" | "error"
    error: str | None = None   # what failed, when stopped == "error"


@dataclass
class _Outcome:
    call: ToolCall
    result: ToolResult
    submitted: bool = False
    value: Any = None


class _Submit:
    """The `submit` tool of a schema run. A schema that is not an object is wrapped as {"result": ...},
    because function-tool parameters must be an object."""

    def __init__(self, schema: dict):
        validator_cls = jsonschema.validators.validator_for(schema)
        validator_cls.check_schema(schema)  # a broken schema is the caller's bug: fail before any model call
        self.validator = validator_cls(schema)
        self.wrapped = not (schema.get("type") == "object" or "properties" in schema)
        params = ({"type": "object", "properties": {"result": schema}, "required": ["result"]}
                  if self.wrapped else schema)
        self.spec = {"type": "function", "function": {
            "name": SUBMIT,
            "description": ("Submit your final answer and end the task. The arguments are the answer and must "
                            "match this schema. If the submission is rejected, fix the listed problems and "
                            "call submit again."),
            "parameters": params}}

    def check(self, arguments: dict) -> tuple[bool, Any, str]:
        """(accepted, the submitted value, the text the model gets back)."""
        value = arguments.get("result") if self.wrapped else arguments
        errors = list(self.validator.iter_errors(value))
        if not errors:
            return True, value, "Submitted."
        lines = [f"- {'/'.join(str(p) for p in e.absolute_path) or '(top level)'}: {_clip(e.message, 300)}"
                 for e in errors[:10]]
        if len(errors) > 10:
            lines.append(f"- ... and {len(errors) - 10} more")
        return False, None, ("Error: submit rejected, the arguments do not match the schema:\n" + "\n".join(lines)
                             + "\nFix these and call submit again.")


class Agent:
    """A model with tools, run until it answers without calling a tool, submits, or runs out of steps.

    The tool calls of one turn run concurrently, except that a call to a `mutating` tool waits for the
    calls before it and holds back the calls after it, so side effects happen in the order the model
    asked for them. A tool that raises is reported to the model as error text and the loop goes on.
    The budget knobs are the class attributes below (override them on an instance).
    """

    keep_last_messages = 6   # never trimmed, and neither are the system prompt and the task
    keep_images = 2          # the newest captures survive image dropping
    max_images = 6           # never send more images than this in one request (server limits, e.g. vLLM's 8)
    image_tokens = 1500      # budget cost of one image (about a 1280px frame on current VLMs)
    chars_per_token = 3.0    # Luau/JSON tokenize denser than prose; underestimating overflowed a 64k window
    max_submit_nudges = 2    # schema runs: how often to ask for `submit` when the model stops without it

    def __init__(self, llm: LLM, system: str, tools: list[Tool], name: str = "agent", max_steps: int = 40,
                 max_tool_chars: int = 16000, context_budget_tokens: int | None = None):
        self.llm = llm
        self.system = system
        self.tools = list(tools or [])
        self.name = name
        self.max_steps = max_steps
        self.max_tool_chars = max_tool_chars
        # Size it to the model server's window minus the output budget (HARNESS_CONTEXT_BUDGET). Too small a budget
        # makes trimming drop what an agent just read, and live builders then re-read the same files for 28 steps.
        if context_budget_tokens is None:
            context_budget_tokens = int(os.environ.get("HARNESS_CONTEXT_BUDGET", "32000"))
        self.context_budget_tokens = context_budget_tokens
        tools_by_name(self.tools)  # duplicate names fail here, not mid-run

    async def run(self, task: str | list[dict], schema: dict | None = None) -> AgentResult:
        tools = tools_by_name(self.tools)
        specs = [t.spec() for t in self.tools]
        submit = None
        if schema is not None:
            if SUBMIT in tools:
                raise ValueError(f"the tool name {SUBMIT!r} is reserved for structured output")
            submit = _Submit(schema)
            specs.append(submit.spec)

        # `context` is what the model is sent (trimmed to the budget); `transcript` keeps everything.
        context = [Message("system", self.system), Message("user", task)]
        transcript = list(context)
        summarized: set[int] = set()
        usage: dict = {}
        text, steps, nudges = "", 0, 0

        def add(msg: Message) -> None:
            context.append(msg)
            transcript.append(msg)

        def finish(stopped: str, structured: Any = None, error: str | None = None) -> AgentResult:
            log.info("[%s] %s after %d step(s)", self.name, stopped, steps)
            return AgentResult(text, structured, steps, transcript, usage, stopped, error)

        while steps < self.max_steps:
            if submit is not None and steps and steps == self.max_steps - 1:
                add(Message("user", _LAST_STEP))
            self._fit_budget(context, summarized)
            steps += 1
            try:
                response = await self.llm.chat(context, specs or None)
            except Exception as e:  # network, auth, context overflow, ...: end the run and say why
                log.warning("[%s] model call %d failed: %s: %s", self.name, steps, type(e).__name__, e)
                return finish("error", error=f"{type(e).__name__}: {e}")
            _add_usage(usage, response.usage)
            message = response.message
            add(message)
            said = _plain(message.content).strip()
            if said:
                text = said
            if not message.tool_calls:
                if submit is not None and nudges < self.max_submit_nudges and steps < self.max_steps:
                    nudges += 1
                    add(Message("user", _NO_SUBMIT))
                    continue
                return finish("no_tool_calls")
            nudges = 0
            log.debug("[%s] step %d: %s", self.name, steps, ", ".join(c.name for c in message.tool_calls))
            outcomes = await self._run_calls(message.tool_calls, tools, submit)
            self._add_results(outcomes, add)
            for o in outcomes:
                if o.submitted:
                    return finish("submitted", o.value)
        if submit is not None:
            # Out of steps without a report (live: a builder finished a 691-line file, verified it clean, kept
            # polishing, then ran check_code on its last step). Offer submit as the ONLY tool, twice at most, so the
            # finished work is recorded instead of the run counting as failed and being redone on resume.
            for _ in range(2):
                add(Message("user", _FORCED_SUBMIT))
                self._fit_budget(context, summarized)
                try:
                    response = await self.llm.chat(context, [submit.spec])
                except Exception as e:  # noqa: BLE001
                    log.warning("[%s] forced submit failed: %s: %s", self.name, type(e).__name__, e)
                    break
                _add_usage(usage, response.usage)
                add(response.message)
                calls = [c for c in (response.message.tool_calls or []) if c.name == SUBMIT]
                if not calls:
                    continue
                outcomes = await self._run_calls(calls[:1], {}, submit)
                self._add_results(outcomes, add)
                if outcomes and outcomes[0].submitted:
                    return finish("submitted", outcomes[0].value)
        return finish("max_steps")

    # -- tools -------------------------------------------------------------------------------------

    async def _run_calls(self, calls: list[ToolCall], tools: dict[str, Tool], submit: _Submit | None) -> list[_Outcome]:
        outcomes: list[Any] = [None] * len(calls)
        batch: list[int] = []

        async def flush() -> None:
            done = await asyncio.gather(*(self._run_call(calls[i], tools, submit) for i in batch))
            for i, outcome in zip(batch, done):
                outcomes[i] = outcome
            batch.clear()

        for i, call in enumerate(calls):
            tool = tools.get(call.name)
            if tool is not None and tool.mutating:
                await flush()  # a mutating call is a barrier: everything before it finishes first
                outcomes[i] = await self._run_call(call, tools, submit)
            else:
                batch.append(i)
        await flush()
        return outcomes

    async def _run_call(self, call: ToolCall, tools: dict[str, Tool], submit: _Submit | None) -> _Outcome:
        if PARSE_ERROR_KEY in call.arguments:
            raw = _clip(str(call.arguments.get(RAW_ARGUMENTS_KEY, "")), 500)
            return _Outcome(call, ToolResult(
                f"Error: this tool call could not be parsed: {call.arguments[PARSE_ERROR_KEY]}. Raw: {raw}\n"
                "Call the tool again with a valid JSON object as its arguments."))
        if submit is not None and call.name == SUBMIT:
            accepted, value, reply = submit.check(call.arguments)
            return _Outcome(call, ToolResult(reply), submitted=accepted, value=value)
        tool = tools.get(call.name)
        if tool is None:
            names = sorted(tools) + ([SUBMIT] if submit is not None else [])
            return _Outcome(call, ToolResult(
                f"Error: there is no tool named {call.name!r}. Available tools: {', '.join(names) or '(none)'}."))
        started = time.monotonic()
        try:
            result = await tool.invoke(call.arguments)
        except Exception as e:  # the model sees the failure and can adapt; the run goes on
            log.warning("[%s] tool %s failed: %s: %s", self.name, call.name, type(e).__name__, e)
            return _Outcome(call, ToolResult(f"Error: {call.name} raised {type(e).__name__}: {e}"))
        log.debug("[%s] tool %s took %.2fs", self.name, call.name, time.monotonic() - started)
        return _Outcome(call, result)

    def _add_results(self, outcomes: list[_Outcome], add: Callable[[Message], None]) -> None:
        """One tool message per call, then one user message with every image the calls returned (many
        backends reject images inside tool messages)."""
        images: list[dict] = []
        for o in outcomes:
            content = _clip_middle(o.result.text or "(no output)", self.max_tool_chars)
            n = len(o.result.images)
            if n:
                content += f"\n[{n} image{'s' if n > 1 else ''} attached in the next message]"
            add(Message("tool", content, tool_call_id=o.call.id, name=o.call.name))
            for k, img in enumerate(o.result.images, 1):
                label = f"{o.call.name} image {k}/{n}"
                try:
                    images += [text_part(label + ":"), image_part(img)]
                except Exception as e:  # undecodable bytes: say so rather than fail the turn
                    images.append(text_part(f"{label} could not be decoded ({type(e).__name__}: {e})"))
        if images:
            add(Message("user", [text_part("Images returned by the tool calls above:"), *images]))

    # -- context budget ----------------------------------------------------------------------------

    def estimate_tokens(self, messages: list[Message]) -> float:
        """Rough prompt size: characters / chars_per_token, plus image_tokens per image."""
        return sum(self._tokens(m) for m in messages)

    def _tool_tokens(self) -> float:
        if getattr(self, "_tool_tokens_cache", None) is None:
            self._tool_tokens_cache = sum(len(json.dumps(t.spec(), default=str)) for t in self.tools) / self.chars_per_token
        return self._tool_tokens_cache

    def _tokens(self, m: Message) -> float:
        chars, images = 0, 0
        if isinstance(m.content, str):
            chars += len(m.content)
        else:
            for part in m.content or []:
                if _is_image(part):
                    images += 1  # counted per image, not by the length of its base64
                elif part.get("type") == "text":
                    chars += len(part.get("text") or "")
                else:
                    chars += len(json.dumps(part, default=str))
        for c in m.tool_calls or []:
            chars += len(c.name) + len(json.dumps(c.arguments, ensure_ascii=False, default=str))
        return 4 + chars / self.chars_per_token + images * self.image_tokens

    def _fit_budget(self, ctx: list[Message], summarized: set[int]) -> None:
        """Trim what the model is sent (the transcript keeps the originals) until it fits the budget:
          1. drop images older than the newest `keep_images` captures, oldest first;
          2. replace the oldest tool results with one-line summaries;
          3. shorten long string arguments of old tool calls (e.g. whole files given to a write tool).
        The system prompt, the task and the last `keep_last_messages` messages are never touched."""
        # Servers cap images per request (vLLM: 8 by default); a builder painting textures gets one preview per call.
        # Beyond `max_images`, the oldest images after the task are replaced with a note, whatever the token count.
        images = [(i, j) for i in range(2, len(ctx)) for j, part in enumerate(_parts(ctx[i])) if _is_image(part)]
        in_task = sum(1 for part in _parts(ctx[1]) if _is_image(part)) if len(ctx) > 1 else 0
        excess = in_task + len(images) - self.max_images
        for i, j in images[:max(0, excess)]:
            parts = list(ctx[i].content)
            parts[j] = text_part("[older image removed: request image limit]")
            ctx[i] = replace(ctx[i], content=parts)
        sizes = [self._tokens(m) for m in ctx]
        total = sum(sizes)
        # the tool schemas travel with every request too (spec tools carry long descriptions)
        budget = self.context_budget_tokens - self._tool_tokens()
        if total <= budget:
            return
        stop = max(2, len(ctx) - self.keep_last_messages)  # ctx[2:stop] may be trimmed

        def put(i: int, msg: Message) -> None:
            nonlocal total
            ctx[i] = msg
            new = self._tokens(msg)
            total += new - sizes[i]
            sizes[i] = new

        captures = [(i, j) for i in range(2, len(ctx)) for j, part in enumerate(_parts(ctx[i])) if _is_image(part)]
        for i, j in captures[:max(0, len(captures) - self.keep_images)]:
            if total <= budget:
                return
            if i < stop:
                parts = list(ctx[i].content)
                parts[j] = text_part("[older image removed to save context]")
                put(i, replace(ctx[i], content=parts))

        for i in range(2, stop):
            if total <= budget:
                return
            m = ctx[i]
            if m.role == "tool" and i not in summarized:
                summarized.add(i)
                summary = _summary(m)
                if len(summary) < len(_plain(m.content)):
                    put(i, replace(m, content=summary))

        for i in range(2, stop):
            if total <= budget:
                return
            m = ctx[i]
            if m.role == "assistant" and m.tool_calls:
                calls = [replace(c, arguments=_shorten(c.arguments)) for c in m.tool_calls]
                if calls != m.tool_calls:
                    put(i, replace(m, tool_calls=calls))

        if total > budget:
            log.info("[%s] context still ~%d tokens after trimming (budget %d)", self.name, total, budget)


def _plain(content: str | list[dict] | None) -> str:
    if isinstance(content, str):
        return content
    return "\n".join(p.get("text", "") for p in content or [] if isinstance(p, dict) and p.get("type") == "text")


def _parts(m: Message) -> list:
    return m.content if isinstance(m.content, list) else []


def _is_image(part: Any) -> bool:
    return isinstance(part, dict) and part.get("type") in ("image_url", "image")


def _clip(text: str, n: int) -> str:
    return text if len(text) <= n else text[:n] + "..."


def _clip_middle(text: str, limit: int) -> str:
    """Keep the head and the tail of an over-long tool result (errors tend to be at the end)."""
    if limit <= 0 or len(text) <= limit:
        return text
    head = int(limit * 0.7)
    tail = limit - head
    return f"{text[:head]}\n[... {len(text) - limit} characters cut ...]\n{text[len(text) - tail:]}"


def _summary(m: Message) -> str:
    body = _plain(m.content)
    start = " ".join(body.split())[:120]
    return f"[{m.name or 'tool'} result trimmed to save context ({len(body)} chars); it began: {start}]"


def _shorten(value: Any, limit: int = 400) -> Any:
    """Long strings inside tool-call arguments cut to their start (idempotent: the result is shorter than limit)."""
    if isinstance(value, str) and len(value) > limit:
        keep = limit // 2
        return f"{value[:keep]}...[{len(value) - keep} more chars trimmed to save context]"
    if isinstance(value, dict):
        return {k: _shorten(v, limit) for k, v in value.items()}
    if isinstance(value, list):
        return [_shorten(v, limit) for v in value]
    return value


def _add_usage(total: dict, usage: dict | None) -> None:
    for k, v in (usage or {}).items():
        if isinstance(v, (int, float)) and not isinstance(v, bool):
            total[k] = total.get(k, 0) + v

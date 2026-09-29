"""Orchestration engine: agent / parallel / pipeline / phase / log, with a journal for resume.

A workflow script is an async function that takes a Workflow and awaits `wf.agent(...)` calls, fanning out with
`wf.parallel(...)` (a barrier) and `wf.pipeline(...)` (no barrier between stages). A failed call returns None and
is logged; it never takes the run down.

Files in run_dir:
    journal.jsonl              one JSON line per completed agent() call: the resume cache
    journal.prev.jsonl         the journal as it was before this run first rewrote it
    agents/NNNN-<label>.json   what each live call did (messages, image data elided); NNNN is the call's ordinal
    log.txt                    everything log() printed, timestamped

Ordinals and sites. Every call gets an *ordinal*, its position in call order (0, 1, 2, ... assigned the moment the
call starts, before it waits for a concurrency slot), and a *site*, its position in the structure of the script.
A script is a flow of steps; a step is an agent() call or a fork (one parallel() or pipeline() call), and every
branch of a fork (one thunk, or one pipeline item through all its stages) is a flow of its own. Site "4" is step 4
of the top-level flow; "2.1.0" is step 0 of branch 1 of the fork made at top-level step 2. The ordinals of calls
made after an await inside concurrent branches depend on which call happened to finish first; sites do not, so a
replay of the same script always lines up with its journal.

Resume. A call is identified by its site plus a key: sha256 over its prompt (image data included), role, system
prompt, schema and tool names. With resume=True a call returns its journaled result when the journal has the same
key at the same site and nothing before it in its flow changed: the longest unchanged prefix. The first changed or
new call runs live, and so does everything that may depend on it -- the rest of its flow, and everything after the
join of each fork that contains it -- while sibling branches keep their cached results. For a sequential script
this is exactly "the longest unchanged prefix of calls". Journal entries invalidated this way are dropped at once
by rewriting journal.jsonl (the file it replaces is kept as journal.prev.jsonl). Failed calls (an exception, an
agent that stopped on an error, or no structured result for a schema) are not journaled, so a resume retries them.
"""

from __future__ import annotations

import asyncio
import contextlib
import contextvars
import dataclasses
import hashlib
import inspect
import json
import os
import re
import shutil
import threading
import time
import traceback
from collections.abc import Awaitable, Callable
from pathlib import Path
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:  # annotations only: the agent/LLM stack is imported lazily (see Workflow._agent_class)
    from harness.llm import LLM
    from harness.tools.base import Tool

__all__ = ["DEFAULT_SYSTEM", "Workflow", "call_key", "run_workflow"]

#: The system prompt of agent() calls that don't pass one.
DEFAULT_SYSTEM = (
    "You are one agent in an automated multi-agent workflow. Use the tools you are given to do the task completely "
    "and check your own work. Your final answer is read by a program, not a person: give the result itself with no "
    "preamble, and if a `submit` tool is available, finish by calling it."
)

Site = tuple[int, ...]  # (step, branch, step, branch, ..., step)


class _Flow:
    """A sequential flow of steps: the top-level script, one parallel() branch or pipeline() item, or the calls a
    running agent makes through its tools."""

    __slots__ = ("owner", "path", "steps", "phase", "nested")

    def __init__(self, owner: Workflow, path: Site, phase: str | None, nested: bool = False):
        self.owner = owner
        self.path = path        # the site prefix shared by everything in this flow
        self.steps = 0
        self.phase = phase
        self.nested = nested    # inside a running agent, whose concurrency slot these calls share

    def step(self) -> Site:
        """Claim this flow's next step and return its site."""
        self.steps += 1
        return self.path + (self.steps - 1,)

    def fork(self, n: int) -> list[_Flow]:
        """Claim one step for a fork and return its n branches."""
        at = self.step()
        return [_Flow(self.owner, at + (i,), self.phase, self.nested) for i in range(n)]


# The flow the running code belongs to. Each parallel()/pipeline() branch runs as its own asyncio task, and a task
# starts from a copy of its creator's context, so setting this inside a branch never leaks into siblings or the caller.
_FLOW: contextvars.ContextVar[_Flow | None] = contextvars.ContextVar("harness_workflow_flow", default=None)


@dataclasses.dataclass
class _Entry:
    """A journaled call that may still be replayed."""
    site: Site
    key: str
    ordinal: int
    line: str  # the journal line; the result is parsed from it on each replay, so callers never share one object

    def result(self) -> Any:
        return json.loads(self.line).get("result")


class Workflow:
    """One run of a workflow script in run_dir: agent calls under a concurrency cap, journaled for resume (see the
    module docstring for how calls are identified and replayed)."""

    #: The agent implementation. None means harness.agent.Agent, imported on the first live call, so importing this
    #: module or replaying a fully journaled run never loads the agent/LLM stack.
    agent_class: type | None = None

    def __init__(self, name: str, run_dir: Path, roles: dict[str, LLM], concurrency: int = 6, resume: bool = True):
        if concurrency < 1:
            raise ValueError(f"concurrency must be at least 1, got {concurrency}")
        self.name = name
        self.run_dir = Path(run_dir)
        self.roles = roles
        self.concurrency = concurrency
        self.resume = resume
        self.agents_dir = self.run_dir / "agents"
        self.journal_path = self.run_dir / "journal.jsonl"
        self.prev_journal_path = self.run_dir / "journal.prev.jsonl"
        self.log_path = self.run_dir / "log.txt"
        self.stats = {"live": 0, "cached": 0, "failed": 0}
        self.usage: dict[str, int | float] = {}  # token usage summed over live calls
        self._log_lock = threading.Lock()
        self._root = _Flow(self, (), None)
        self._entries: dict[Site, _Entry] = {}   # what journal.jsonl holds: entries that may still be replayed
        self._journal_kept = False               # already saved the pre-run journal as journal.prev.jsonl?
        self._next_ordinal = 0
        self._sem: asyncio.Semaphore | None = None
        self._sem_loop: asyncio.AbstractEventLoop | None = None
        self.agents_dir.mkdir(parents=True, exist_ok=True)
        if self.journal_path.exists():
            if resume:
                self._load_journal()
            else:
                os.replace(self.journal_path, self.prev_journal_path)
                self._journal_kept = True

    # -- the script API ------------------------------------------------------------------------------

    async def agent(self, prompt: str | list[dict], *, role: str = "builder", system: str | None = None,
                    tools: list[Tool] | None = None, schema: dict | None = None, label: str = "",
                    phase: str | None = None, max_steps: int | None = None) -> dict | str | None:
        """Run an agent on `prompt` with the LLM of `role`, or replay its journaled result. Returns the structured
        result when `schema` is given, else the final text; None when the call failed (logged)."""
        # Everything before the first await runs the moment the call starts, so sites, ordinals and cache decisions
        # follow call order no matter how the calls are scheduled afterwards.
        flow = self._flow()
        site = flow.step()
        name = label or role
        phase = flow.phase if phase is None else phase
        system = DEFAULT_SYSTEM if system is None else system
        try:
            tools = list(tools or [])
            key = call_key(prompt, role=role, system=system, schema=schema, tool_names=[_tool_name(t) for t in tools])
        except Exception as exc:
            self.stats["failed"] += 1
            self.log(f"{name}: unusable agent() call at site {_fmt_site(site)}: {_describe(exc)}")
            return None

        entry = self._replay(site, key)
        if entry is not None:
            self._next_ordinal = max(self._next_ordinal, entry.ordinal + 1)
            self.stats["cached"] += 1
            self.log(f"#{entry.ordinal} {name}: cached")
            return entry.result()

        ordinal = self._new_ordinal()
        meta = {"ordinal": ordinal, "site": _fmt_site(site), "label": label, "role": role, "phase": phase}
        # A call made from inside a running agent (by one of its tools) runs in that agent's slot: waiting for a slot
        # of its own would deadlock once every slot is held by a parent waiting on its child.
        async with (contextlib.nullcontext() if flow.nested else self._semaphore()):
            self.log(f"#{ordinal} {name} started ({role}{', ' + phase if phase else ''})")
            start = time.monotonic()
            # Calls the agent makes through its tools get a flow of their own under this call's site, so they don't
            # shift this flow's step numbers (on replay the agent, and so its tools, never run).
            token = _FLOW.set(_Flow(self, site + (0,), phase, nested=True))
            try:
                if role not in self.roles:
                    raise LookupError(f"no LLM for role {role!r} (roles: {', '.join(self.roles) or 'none'})")
                kwargs = {"name": name} if max_steps is None else {"name": name, "max_steps": max_steps}
                res = await self._agent_class()(self.roles[role], system, tools, **kwargs).run(prompt, schema=schema)
            except Exception as exc:
                seconds = round(time.monotonic() - start, 3)
                self.stats["failed"] += 1
                self.log(f"#{ordinal} {name} FAILED after {seconds:.1f}s: {_describe(exc)}")
                self._write_transcript(ordinal, name, {**meta, "seconds": seconds, "error": _describe(exc),
                                                       "traceback": "".join(traceback.format_exception(exc)),
                                                       "system": system, "task": prompt})
                return None
            finally:
                _FLOW.reset(token)

        seconds = round(time.monotonic() - start, 3)
        result = res.structured if schema is not None else res.text
        usage = dict(res.usage or {})
        self._add_usage(usage)
        self._write_transcript(ordinal, name, {**meta, "seconds": seconds, "stopped": res.stopped, "steps": res.steps,
                                               "usage": usage, "result": result, "messages": res.transcript})
        # The agent loop reports model/API failures as stopped == "error" rather than raising.
        if res.stopped == "error" or result is None:
            why = getattr(res, "error", None) or ("no structured result" if result is None else "error")
            self.stats["failed"] += 1
            self.log(f"#{ordinal} {name} FAILED after {seconds:.1f}s (stopped: {res.stopped}): {why}")
            return None
        self.stats["live"] += 1
        self._journal(site, key, ordinal, {**meta, "seconds": seconds, "stopped": res.stopped, "usage": usage,
                                           "key": key, "result": result})
        self.log(f"#{ordinal} {name} done in {seconds:.1f}s ({res.stopped})")
        return result

    async def parallel(self, thunks: list[Callable[[], Awaitable]]) -> list:
        """Run thunks concurrently and wait for all of them (a barrier). Results come back in order; a thunk that
        raises gives None (logged) and never stops the others. A thunk is a zero-argument callable returning an
        awaitable (an awaitable itself is accepted too). Bind loop variables: [lambda x=x: wf.agent(x) for x in xs]."""
        thunks = list(thunks)
        branches = self._flow().fork(len(thunks))
        results = await asyncio.gather(*(_run_in(b, _call, t) for b, t in zip(branches, thunks)),
                                       return_exceptions=True)
        return [self._none_if_failed(r, f"parallel[{i}]") for i, r in enumerate(results)]

    async def pipeline(self, items: list, *stages: Callable) -> list:
        """Run every item through all stages independently: there is no barrier between stages, so item 0 can be in
        stage 3 while item 1 is still in stage 1. Each stage is called as stage(prev, item, idx), prev being the
        previous stage's result (the item itself for the first stage), and may be sync or async. A stage that raises
        makes that item's result None (logged) and skips its remaining stages."""
        items = list(items)
        branches = self._flow().fork(len(items))

        async def run_item(idx: int, item: Any) -> Any:
            prev = item
            for n, stage in enumerate(stages):
                try:
                    prev = await _call(stage, prev, item, idx)
                except Exception as exc:
                    self.log(f"pipeline item {idx} failed in stage {n} ({_fn_name(stage)}): {_describe(exc)}")
                    return None
            return prev

        results = await asyncio.gather(*(_run_in(b, run_item, i, item) for i, (b, item) in
                                         enumerate(zip(branches, items))), return_exceptions=True)
        return [self._none_if_failed(r, f"pipeline item {i}") for i, r in enumerate(results)]

    def phase(self, title: str) -> None:
        """Start phase `title`: later agent() calls in the current flow, and in the branches it forks, record it as
        their phase unless they pass phase=. Inside a parallel()/pipeline() branch it applies to that branch only."""
        self._flow().phase = title
        self.log(f"== {title} ==")

    def log(self, msg: str) -> None:
        """Print `msg` with a timestamp and append it to run_dir/log.txt."""
        now = time.localtime()
        line = f"[{time.strftime('%H:%M:%S', now)}] {msg}"
        try:
            print(line, flush=True)
        except UnicodeEncodeError:  # a legacy Windows console can't show every character a model writes
            print(line.encode("ascii", "backslashreplace").decode("ascii"), flush=True)
        try:
            with self._log_lock, open(self.log_path, "a", encoding="utf-8", newline="\n") as f:
                f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S', now)} {msg}\n")
        except OSError:
            pass  # a lost log line must not take the run down

    def summary(self) -> str:
        """One line: calls run live, replayed from the journal and failed, plus the summed token usage."""
        s = self.stats
        text = f"{s['live']} live, {s['cached']} cached, {s['failed']} failed agent calls"
        if self.usage:
            text += " | " + ", ".join(f"{k}={v}" for k, v in sorted(self.usage.items()))
        return text

    # -- internals ----------------------------------------------------------------------------------

    def _flow(self) -> _Flow:
        flow = _FLOW.get()
        return flow if flow is not None and flow.owner is self else self._root

    def _semaphore(self) -> asyncio.Semaphore:
        loop = asyncio.get_running_loop()
        if self._sem is None or self._sem_loop is not loop:  # one per event loop (each asyncio.run makes a new one)
            self._sem, self._sem_loop = asyncio.Semaphore(self.concurrency), loop
        return self._sem

    def _agent_class(self) -> type:
        if self.agent_class is not None:
            return self.agent_class
        from harness.agent import Agent  # lazy: only live calls need the agent/LLM stack
        return Agent

    def _none_if_failed(self, result: Any, what: str) -> Any:
        if isinstance(result, BaseException):
            self.log(f"{what} failed: {_describe(result)}")
            return None
        return result

    def _new_ordinal(self) -> int:
        # The next number in call order, but on resume kept clear of the ordinals that still-replayable entries use
        # (their transcripts are on disk under those numbers).
        ordinal = max([self._next_ordinal, *(e.ordinal + 1 for e in self._entries.values())])
        self._next_ordinal = ordinal + 1
        return ordinal

    def _add_usage(self, usage: dict) -> None:
        for k, v in usage.items():
            if isinstance(v, (int, float)) and not isinstance(v, bool):
                self.usage[k] = self.usage.get(k, 0) + v

    # -- journal --------------------------------------------------------------------------------------

    def _replay(self, site: Site, key: str) -> _Entry | None:
        """The journal entry to replay for the call at `site`, or None if the call must run live."""
        entry = self._entries.get(site)
        if entry is not None and entry.key == key:
            return entry
        # Changed or new: this call and everything that may depend on it are stale. Dropping them now keeps them
        # from being replayed later in this run, or by a later resume if this one stops early.
        stale = [s for s in self._entries if _downstream(s, site)]
        if stale:
            for s in stale:
                del self._entries[s]
            self._rewrite_journal()
            self.log(f"resume: the call at site {_fmt_site(site)} {'changed' if entry else 'is new'}; dropped "
                     f"{len(stale)} journal entr{'y' if len(stale) == 1 else 'ies'} from there on")
        return None

    def _journal(self, site: Site, key: str, ordinal: int, record: dict) -> None:
        """Append a completed call to the journal."""
        try:
            line = json.dumps(record, ensure_ascii=False, default=str)
        except ValueError as exc:  # e.g. a result with a reference cycle
            self.log(f"#{ordinal}: result not journaled: {_describe(exc)}")
            return
        self._entries[site] = _Entry(site, key, ordinal, line)
        try:
            with open(self.journal_path, "a", encoding="utf-8", newline="\n") as f:
                f.write(line + "\n")
        except OSError as exc:
            self.log(f"#{ordinal}: journal write failed: {_describe(exc)}")

    def _load_journal(self) -> None:
        unreadable = 0
        with open(self.journal_path, encoding="utf-8-sig") as f:
            for raw in f:
                line = raw.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                    entry = _Entry(_parse_site(rec.get("site", rec["ordinal"])), str(rec["key"]), int(rec["ordinal"]),
                                   line)
                except (ValueError, KeyError, TypeError, AttributeError):  # e.g. a line cut short by a crash
                    unreadable += 1
                    continue
                self._entries.pop(entry.site, None)  # the last line for a site wins
                self._entries[entry.site] = entry
        self.log(f"resume: {len(self._entries)} journaled calls in {self.journal_path}"
                 + (f" ({unreadable} unreadable lines skipped)" if unreadable else ""))
        if unreadable:
            self._rewrite_journal()  # so that new lines are appended to a clean file

    def _rewrite_journal(self) -> None:
        """Make journal.jsonl hold exactly the replayable entries; the file it replaces is kept as
        journal.prev.jsonl (the first time in a run)."""
        text = "".join(e.line + "\n" for e in self._entries.values())
        try:
            if not self._journal_kept and self.journal_path.exists():
                shutil.copyfile(self.journal_path, self.prev_journal_path)
                self._journal_kept = True
            tmp = self.journal_path.with_name(self.journal_path.name + ".tmp")
            tmp.write_text(text, encoding="utf-8", newline="\n")
            try:
                os.replace(tmp, self.journal_path)
            except PermissionError:  # Windows, while another process has the journal open: overwrite in place
                self.journal_path.write_text(text, encoding="utf-8", newline="\n")
                tmp.unlink(missing_ok=True)
        except OSError as exc:
            self.log(f"journal: rewrite failed: {_describe(exc)}")

    def _write_transcript(self, ordinal: int, name: str, record: dict) -> None:
        path = self.agents_dir / f"{ordinal:04d}-{_slug(name)}.json"
        try:
            text = json.dumps(_elide(record), ensure_ascii=False, indent=1, default=str)
            path.write_text(text + "\n", encoding="utf-8", newline="\n")
        except (OSError, TypeError, ValueError) as exc:
            self.log(f"#{ordinal} {name}: transcript not written: {_describe(exc)}")


def run_workflow(coro_fn: Callable[[Workflow], Awaitable[Any]], **kw: Any) -> Any:
    """Synchronous entry point: builds Workflow(**kw) (name, run_dir, roles, concurrency, resume), runs coro_fn(wf)
    with asyncio.run and returns its result."""
    wf = Workflow(**kw)
    wf.log(f"workflow {wf.name!r} starting in {wf.run_dir} (resume={wf.resume}, concurrency={wf.concurrency})")
    try:
        result = asyncio.run(coro_fn(wf))
    except BaseException as exc:
        wf.log(f"workflow {wf.name!r} stopped by {_describe(exc)}; {wf.summary()}")
        raise
    wf.log(f"workflow {wf.name!r} finished; {wf.summary()}")
    return result


def call_key(prompt: str | list[dict], *, role: str, system: str, schema: dict | None, tool_names: list[str]) -> str:
    """sha256 identifying an agent() call for resume: prompt (image data included), role, system prompt, schema and
    tool names. Dict key order and tool order don't change it."""
    payload = {"prompt": _canon(prompt), "role": role, "system": system, "schema": _canon(schema),
               "tools": sorted(tool_names)}
    blob = json.dumps(payload, sort_keys=True, ensure_ascii=False, separators=(",", ":"), default=str)
    return hashlib.sha256(blob.encode("utf-8", "surrogatepass")).hexdigest()


# -- helpers -------------------------------------------------------------------------------------------

async def _run_in(flow: _Flow, fn: Callable, *args: Any) -> Any:
    """Await fn(*args) as part of `flow`. Runs as its own task (gather wraps it in one), so the flow stays local."""
    _FLOW.set(flow)
    return await _call(fn, *args)


async def _call(fn: Any, *args: Any) -> Any:
    """fn(*args), awaited if it returns an awaitable. `fn` may itself be an awaitable (a coroutine given to parallel()
    instead of a thunk), which is simply awaited."""
    result = fn if inspect.isawaitable(fn) else fn(*args)
    if inspect.isawaitable(result):
        result = await result
    return result


def _downstream(site: Site, of: Site) -> bool:
    """May the call at `site` depend on the call at `of`? Sites alternate step, branch, step, ... At the first
    position where they differ, a larger step (even position) means `site` came later in the same flow, or after
    the join of a fork containing `of`: yes. An earlier step: no. A different branch (odd position) is a sibling
    that ran independently: no. If one site contains the other (the same call, or a call nested in it): yes."""
    for i, (a, b) in enumerate(zip(site, of)):
        if a != b:
            return i % 2 == 0 and a > b
    return True


def _fmt_site(site: Site) -> str:
    return ".".join(map(str, site))


def _parse_site(value: Any) -> Site:
    if isinstance(value, int):  # a journal line without a site: flat call order
        return (value,)
    parts = value.split(".") if isinstance(value, str) else value
    return tuple(int(p) for p in parts)


def _canon(obj: Any) -> Any:
    """obj as plain JSON data, for hashing. Image parts are data-URI strings and so are hashed as they are; raw bytes
    are replaced by their sha256."""
    if dataclasses.is_dataclass(obj) and not isinstance(obj, type):
        return {f.name: _canon(getattr(obj, f.name)) for f in dataclasses.fields(obj)}
    if isinstance(obj, dict):
        return {str(k): _canon(v) for k, v in obj.items()}
    if isinstance(obj, (list, tuple)):
        return [_canon(v) for v in obj]
    if isinstance(obj, (bytes, bytearray, memoryview)):
        return {"bytes.sha256": hashlib.sha256(bytes(obj)).hexdigest()}
    return obj


_DATA_URI = re.compile(r"data:([^;,]*)[^,]*;base64,", re.IGNORECASE)
_IMAGE_MAGIC = (b"\x89PNG", b"\xff\xd8\xff", b"GIF8", b"RIFF")


def _elide(obj: Any) -> Any:
    """obj as JSON data for a transcript, with inline image/binary data replaced by '<image N bytes>'."""
    if dataclasses.is_dataclass(obj) and not isinstance(obj, type):
        return {f.name: _elide(getattr(obj, f.name)) for f in dataclasses.fields(obj)}
    if isinstance(obj, dict):
        out = {str(k): _elide(v) for k, v in obj.items()}
        if obj.get("type") == "base64" and isinstance(obj.get("data"), str):  # an Anthropic-style image source
            out["data"] = f"<image {_b64_size(obj['data'])} bytes>"
        return out
    if isinstance(obj, (list, tuple)):
        return [_elide(v) for v in obj]
    if isinstance(obj, (bytes, bytearray, memoryview)):
        data = bytes(obj)
        return f"<{'image ' if data.startswith(_IMAGE_MAGIC) else ''}{len(data)} bytes>"
    if isinstance(obj, str):
        m = _DATA_URI.match(obj)
        if m:
            kind = (m.group(1) or "image").split("/")[0]
            return f"<{kind} {_b64_size(obj[m.end():])} bytes>"
    return obj


def _b64_size(b64: str) -> int:
    """Decoded size of base64 text."""
    b64 = b64.strip()
    return len(b64) * 3 // 4 - (len(b64) - len(b64.rstrip("=")))


def _describe(exc: BaseException) -> str:
    """'Type: message (file.py:line in function)', the location being the innermost frame of the traceback."""
    text = type(exc).__name__ + (f": {exc}" if str(exc) else "")
    frames = traceback.extract_tb(exc.__traceback__)
    if frames:
        f = frames[-1]
        text += f" ({Path(f.filename).name}:{f.lineno} in {f.name})"
    return text


def _tool_name(tool: Any) -> str:
    if isinstance(tool, dict):  # an OpenAI tool spec rather than a Tool
        return str(tool.get("function", tool).get("name"))
    return str(getattr(tool, "name", tool))


def _fn_name(fn: Any) -> str:
    return getattr(fn, "__name__", None) or type(fn).__name__


def _slug(name: str) -> str:
    """`name` made safe for a file name on every OS."""
    return re.sub(r"[^A-Za-z0-9._-]+", "_", name).strip("._")[:60] or "agent"

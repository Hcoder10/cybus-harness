"""harness.workflow: orchestration, journal and resume. No network and no real agent: a fake Agent is patched in.

Plain test functions that drive the async API with asyncio.run (no pytest-asyncio).
"""

from __future__ import annotations

import asyncio
import base64
import json
import subprocess
import sys
import time
import types
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import pytest

from harness.workflow import DEFAULT_SYSTEM, Workflow, call_key, run_workflow

REPO = Path(__file__).resolve().parents[1]
ROLES = {"builder": "llm-builder", "judge": "llm-judge"}  # stand-ins for LLMs: the fake agent echoes them
SCHEMA = {"type": "object", "properties": {"answer": {"type": "string"}}, "required": ["answer"]}
PNG = b"\x89PNG\r\n\x1a\n" + bytes(range(256))  # never decoded by the workflow, only hashed and elided


def data_uri(data: bytes) -> str:
    return "data:image/png;base64," + base64.b64encode(data).decode("ascii")


def image_prompt(text: str, data: bytes = PNG) -> list[dict]:
    return [{"type": "text", "text": text}, {"type": "image_url", "image_url": {"url": data_uri(data)}}]


def text_of(task: Any) -> str:
    if isinstance(task, str):
        return task
    return " ".join(p["text"] for p in task if p.get("type") == "text")


@dataclass
class FakeTool:
    name: str


@dataclass
class FakeMessage:  # shaped like harness.llm.Message
    role: str
    content: Any
    tool_calls: Any = None
    tool_call_id: str | None = None
    name: str | None = None


@dataclass
class FakeResult:  # shaped like harness.agent.AgentResult
    text: str
    structured: dict | None
    steps: int
    transcript: list
    usage: dict
    stopped: str
    error: str | None = None


class FakeAgent:
    """Stands in for harness.agent.Agent (same constructor and run() signature). What it does is set per test
    through class attributes; fresh_fake() makes a subclass with its own state for each test."""

    runs: list = []          # one record per run(), in start order
    delays: dict = {}        # prompt text -> seconds to sleep in run()
    fail: set = set()        # prompt texts whose run() raises
    errors: set = set()      # prompt texts whose run() returns stopped="error" (how the real agent reports API failures)
    no_submit: set = set()   # prompt texts whose schema run ends without a structured result
    finish_order: list = []  # prompt texts that must finish in exactly this order
    finished: list = []
    hook = None              # async fn(agent, text) awaited inside run(): a stand-in for the agent's tools
    active = 0
    peak = 0

    def __init__(self, llm, system, tools, name="agent", max_steps=40, max_tool_chars=16000,
                 context_budget_tokens=48000):
        self.llm, self.system, self.tools, self.name, self.max_steps = llm, system, tools, name, max_steps

    async def run(self, task, schema=None):
        cls = type(self)
        text = text_of(task)
        cls.runs.append({"text": text, "name": self.name, "llm": self.llm, "system": self.system,
                         "tools": [t.name for t in self.tools], "max_steps": self.max_steps, "schema": schema})
        cls.active += 1
        cls.peak = max(cls.peak, cls.active)
        try:
            await asyncio.sleep(cls.delays.get(text, 0))
            if text in cls.finish_order:  # wait until everything ordered before this call has finished
                before = set(cls.finish_order[:cls.finish_order.index(text)])
                deadline = time.monotonic() + 5  # fail rather than hang if the workflow never lets them run
                while not before <= set(cls.finished):
                    if time.monotonic() > deadline:
                        raise TimeoutError(f"{text!r} still waiting for {sorted(before - set(cls.finished))}")
                    await asyncio.sleep(0)
            if cls.hook is not None:
                await cls.hook(self, text)
            if text in cls.fail or "boom" in text:
                raise RuntimeError(f"model exploded on {text!r}")
        finally:
            cls.active -= 1
            cls.finished.append(text)
        answer = f"{self.llm}:{text}"
        transcript = [FakeMessage("system", self.system), FakeMessage("user", task), FakeMessage("assistant", answer)]
        usage = {"prompt_tokens": 10, "completion_tokens": 5}
        if text in cls.errors:
            return FakeResult("", None, 1, transcript, usage, "error", "LLMError: HTTP 503")
        if text in cls.no_submit:
            return FakeResult(answer, None, 40, transcript, usage, "max_steps")
        return FakeResult(answer, {"answer": answer} if schema else None, 1, transcript, usage,
                          "submitted" if schema else "no_tool_calls")


def fresh_fake() -> type[FakeAgent]:
    class Fake(FakeAgent):
        runs, delays, fail, errors, no_submit = [], {}, set(), set(), set()
        finish_order, finished, hook, active, peak = [], [], None, 0, 0
    return Fake


@pytest.fixture
def fake(monkeypatch):
    cls = fresh_fake()
    monkeypatch.setattr(Workflow, "agent_class", cls)
    return cls


def run(script, run_dir: Path, **kw):
    """Run script(wf) on a new Workflow over run_dir, as a fresh process (or a resume) would."""
    return asyncio.run(script(Workflow("test", run_dir, ROLES, **kw)))


def journal(run_dir: Path, name: str = "journal.jsonl") -> list[dict]:
    return [json.loads(line) for line in (run_dir / name).read_text("utf-8").splitlines() if line.strip()]


def live(fake) -> list[str]:
    """The prompts that actually reached the agent, in start order."""
    return [r["text"] for r in fake.runs]


def sequential(prompts: list[str]):
    async def main(wf):
        return [await wf.agent(p, label=f"step{i}") for i, p in enumerate(prompts)]
    return main


def branches(tag: str = ""):
    """Three parallel branches of two calls each (the second call of branch 1 carries `tag`), then a merge call."""
    async def main(wf):
        async def branch(i):
            first = await wf.agent(f"b{i} first")
            second = await wf.agent(f"b{i} second" + (tag if i == 1 else ""))
            return [first, second]
        results = await wf.parallel([lambda i=i: branch(i) for i in range(3)])
        return results, await wf.agent("merge")
    return main


def drafts_then_judges(wf):
    async def draft(prev, item, idx):
        return await wf.agent(f"draft {item}", label=f"draft-{item}")

    async def judge(prev, item, idx):
        return await wf.agent(f"judge {prev}", role="judge", schema=SCHEMA, label=f"judge-{item}")

    return wf.pipeline(["A", "B", "C"], draft, judge)


# -- agent() ---------------------------------------------------------------------------------------

def test_agent_returns_text_or_structured_and_records_journal_and_transcripts(tmp_path, fake):
    rd = tmp_path / "run"

    async def main(wf):
        wf.phase("Plan")
        a = await wf.agent("hello", label="greet", tools=[FakeTool("read_file")], max_steps=7)
        b = await wf.agent(image_prompt("look"), role="judge", system="be picky", schema=SCHEMA, label="look: at/this")
        c = await wf.agent("bye", phase="Wrap")
        return a, b, c

    a, b, c = run(main, rd)
    assert (a, b, c) == ("llm-builder:hello", {"answer": "llm-judge:look"}, "llm-builder:bye")

    # the Agent is built from the call's arguments, with roles[role] as its LLM
    r0, r1, r2 = fake.runs
    assert (r0["name"], r0["llm"], r0["system"], r0["tools"], r0["max_steps"]) == \
        ("greet", "llm-builder", DEFAULT_SYSTEM, ["read_file"], 7)
    assert (r1["name"], r1["llm"], r1["system"], r1["schema"]) == ("look: at/this", "llm-judge", "be picky", SCHEMA)
    assert (r2["name"], r2["max_steps"]) == ("builder", 40)  # no label: the role; no max_steps: Agent's default

    lines = journal(rd)
    assert [x["ordinal"] for x in lines] == [0, 1, 2]
    assert [x["site"] for x in lines] == ["0", "1", "2"]
    assert [x["label"] for x in lines] == ["greet", "look: at/this", ""]
    assert [x["role"] for x in lines] == ["builder", "judge", "builder"]
    assert [x["phase"] for x in lines] == ["Plan", "Plan", "Wrap"]
    assert [x["result"] for x in lines] == [a, b, c]
    assert [x["stopped"] for x in lines] == ["no_tool_calls", "submitted", "no_tool_calls"]
    for x in lines:
        assert x["usage"] == {"prompt_tokens": 10, "completion_tokens": 5}
        assert x["seconds"] >= 0 and len(x["key"]) == 64

    agents = rd / "agents"
    assert sorted(p.name for p in agents.iterdir()) == ["0000-greet.json", "0001-look_at_this.json", "0002-builder.json"]
    raw = (agents / "0001-look_at_this.json").read_text("utf-8")
    assert base64.b64encode(PNG).decode("ascii")[:40] not in raw  # no image data in transcripts...
    t = json.loads(raw)
    assert t["messages"][1]["content"][1]["image_url"]["url"] == f"<image {len(PNG)} bytes>"  # ...only its size
    assert t["messages"][2] == {"role": "assistant", "content": "llm-judge:look", "tool_calls": None,
                                "tool_call_id": None, "name": None}
    assert (t["ordinal"], t["site"], t["role"], t["result"]) == (1, "1", "judge", b)

    log = (rd / "log.txt").read_text("utf-8")
    assert "== Plan ==" in log and "#1 look: at/this done" in log


def test_failed_calls_return_none_are_logged_and_not_journaled(tmp_path, fake):
    rd = tmp_path / "run"
    fake.errors, fake.no_submit = {"api down"}, {"no submit"}

    async def main(wf):
        return [await wf.agent("boom"),                      # the agent raises
                await wf.agent("api down"),                  # the agent reports stopped="error"
                await wf.agent("no submit", schema=SCHEMA),  # a schema run that never submitted
                await wf.agent("x", role="critic"),          # no LLM for the role
                await wf.agent("fine")]

    assert run(main, rd) == [None, None, None, None, "llm-builder:fine"]
    assert [(x["ordinal"], x["result"]) for x in journal(rd)] == [(4, "llm-builder:fine")]
    log = (rd / "log.txt").read_text("utf-8")
    for needle in ("model exploded on 'boom'", "HTTP 503", "no structured result", "no LLM for role 'critic'"):
        assert needle in log
    err = json.loads((rd / "agents" / "0000-builder.json").read_text("utf-8"))
    assert "RuntimeError" in err["error"] and err["task"] == "boom" and "Traceback" in err["traceback"]
    assert json.loads((rd / "agents" / "0001-builder.json").read_text("utf-8"))["stopped"] == "error"


@pytest.mark.parametrize("cap", [1, 3])
def test_concurrency_cap_is_respected(tmp_path, fake, cap):
    fake.delays = {f"c{i}": 0.02 for i in range(10)}

    async def main(wf):
        async def stage(prev, item, idx):
            return await wf.agent(f"c{item}")
        # a fan-out and a pipeline at the same time: one cap for the whole workflow
        return await asyncio.gather(wf.parallel([lambda i=i: wf.agent(f"c{i}") for i in range(5)]),
                                    wf.pipeline(range(5, 10), stage))

    fanned, piped = run(main, tmp_path / "run", concurrency=cap)
    assert fanned + piped == [f"llm-builder:c{i}" for i in range(10)]
    assert fake.peak == cap


# -- parallel() and pipeline() ---------------------------------------------------------------------

def test_parallel_turns_failures_into_none(tmp_path, fake):
    rd = tmp_path / "run"

    async def broken():
        raise ValueError("thunk broke")

    async def main(wf):
        return await wf.parallel([lambda: wf.agent("ok1"), lambda: wf.agent("boom"), broken, lambda: wf.agent("ok2")])

    assert run(main, rd) == ["llm-builder:ok1", None, None, "llm-builder:ok2"]
    log = (rd / "log.txt").read_text("utf-8")
    assert "model exploded on 'boom'" in log and "parallel[2] failed: ValueError: thunk broke" in log


def test_pipeline_has_no_barrier_between_stages(tmp_path):
    events = []

    async def main(wf):
        b_in_stage1, a_in_stage2 = asyncio.Event(), asyncio.Event()

        async def stage1(prev, item, idx):
            events.append(f"{item} in stage 1")
            if item == "A":
                await b_in_stage1.wait()  # make sure B is inside stage 1 before A moves on
            else:
                b_in_stage1.set()
                await a_in_stage2.wait()  # B may only leave stage 1 once A has reached stage 2
            return f"{prev}1"

        async def stage2(prev, item, idx):
            events.append(f"{item} in stage 2")
            if item == "A":
                a_in_stage2.set()
            return f"{prev}2"

        # with a barrier between stages A would wait for B and B for A: fail on the timeout instead of hanging
        return await asyncio.wait_for(wf.pipeline(["A", "B"], stage1, stage2), timeout=5)

    assert run(main, tmp_path / "run") == ["A12", "B12"]
    assert events == ["A in stage 1", "B in stage 1", "A in stage 2", "B in stage 2"]


def test_pipeline_stage_that_raises_drops_the_item_and_skips_its_later_stages(tmp_path, fake):
    rd = tmp_path / "run"
    reached = []

    async def main(wf):
        def scale(prev, item, idx):  # stages may be plain functions
            if item == 2:
                raise KeyError("bad item")
            return prev * 10

        async def ask(prev, item, idx):
            reached.append(item)
            return await wf.agent(f"item {idx} is {prev}")

        return await wf.pipeline([1, 2, 3], scale, ask)

    assert run(main, rd) == ["llm-builder:item 0 is 10", None, "llm-builder:item 2 is 30"]
    assert sorted(reached) == [1, 3]
    assert "pipeline item 1 failed in stage 0 (scale): KeyError" in (rd / "log.txt").read_text("utf-8")


def test_phase_applies_to_later_calls_in_its_own_flow(tmp_path, fake):
    rd = tmp_path / "run"

    async def main(wf):
        wf.phase("Build")

        async def stage(prev, item, idx):
            if idx == 1:
                wf.phase("Special")  # this item's flow only
            return await wf.agent(f"item{idx}", label=f"item{idx}")

        await wf.pipeline([0, 1, 2], stage)
        await wf.agent("after", label="after")
        await wf.agent("explicit", label="explicit", phase="Other")

    run(main, rd)
    assert {x["label"]: x["phase"] for x in journal(rd)} == {
        "item0": "Build", "item1": "Special", "item2": "Build", "after": "Build", "explicit": "Other"}


# -- ordinals, sites and resume --------------------------------------------------------------------

def test_ordinals_follow_call_order_not_completion_order(tmp_path, fake):
    async def main(wf):
        return await wf.parallel([lambda i=i: wf.agent(f"p{i}", label=f"p{i}") for i in range(6)])

    finished_in = {}
    for name, order in (("forward", range(6)), ("reverse", reversed(range(6)))):
        fake.finish_order, fake.finished = [f"p{i}" for i in order], []
        rd = tmp_path / name
        run(main, rd)
        lines = journal(rd)  # lines are written as calls finish
        finished_in[name] = [x["label"] for x in lines]
        assert {x["label"]: x["ordinal"] for x in lines} == {f"p{i}": i for i in range(6)}
        assert {x["label"]: x["site"] for x in lines} == {f"p{i}": f"0.{i}.0" for i in range(6)}
        assert sorted(p.name for p in (rd / "agents").iterdir()) == [f"{i:04d}-p{i}.json" for i in range(6)]
    assert finished_in["forward"] != finished_in["reverse"]  # the runs really did finish in different orders


def test_resume_replays_the_unchanged_prefix_and_runs_live_from_the_first_edit(tmp_path, fake):
    rd = tmp_path / "run"
    first = run(sequential(["a", "b", "c", "d"]), rd)
    assert live(fake) == ["a", "b", "c", "d"]
    original = (rd / "journal.jsonl").read_text("utf-8").splitlines()

    fake.runs.clear()
    assert run(sequential(["a", "b", "c", "d"]), rd) == first  # same script: everything replays
    assert live(fake) == []

    edited = run(sequential(["a", "b", "C", "d"]), rd)
    assert live(fake) == ["C", "d"]  # "d" is unchanged, but it comes after the edit
    assert edited == first[:2] + ["llm-builder:C", "llm-builder:d"]
    lines = (rd / "journal.jsonl").read_text("utf-8").splitlines()
    assert lines[:2] == original[:2]  # the journal is rewritten from the edit on...
    assert [(json.loads(x)["ordinal"], json.loads(x)["result"]) for x in lines] == list(enumerate(edited))
    assert (rd / "journal.prev.jsonl").read_text("utf-8").splitlines() == original  # ...and the old one is kept
    assert "resume: the call at site 2 changed; dropped 2 journal entries" in (rd / "log.txt").read_text("utf-8")

    fake.runs.clear()
    assert run(sequential(["a", "b", "C", "d"]), rd) == edited
    assert live(fake) == []


def test_resume_false_runs_everything_live_and_keeps_the_old_journal(tmp_path, fake):
    rd = tmp_path / "run"
    run(sequential(["a", "b"]), rd)
    original = (rd / "journal.jsonl").read_text("utf-8")
    fake.runs.clear()
    run(sequential(["a", "b"]), rd, resume=False)
    assert live(fake) == ["a", "b"]
    assert (rd / "journal.prev.jsonl").read_text("utf-8") == original
    assert [x["ordinal"] for x in journal(rd)] == [0, 1]


def test_resume_replays_everything_despite_a_different_completion_order(tmp_path, fake):
    rd = tmp_path / "run"
    fake.finish_order = ["draft B", "draft C", "draft A"]  # first run: A's draft finishes last
    first = run(drafts_then_judges, rd)
    by_label = {x["label"]: x for x in journal(rd)}
    # the judges were called in the order the drafts finished, so their ordinals don't follow item order...
    assert by_label["judge-B"]["ordinal"] < by_label["judge-C"]["ordinal"] < by_label["judge-A"]["ordinal"]
    # ...but their sites do: the second step of item i of the fork made at step 0
    assert [by_label[f"judge-{x}"]["site"] for x in "ABC"] == ["0.0.1", "0.1.1", "0.2.1"]

    fake.runs.clear()
    # a replay returns cached calls at once, so this time A's judge is asked for first -- and still replays
    assert run(drafts_then_judges, rd) == first
    assert live(fake) == []


def test_resume_after_an_edit_in_one_branch_keeps_the_sibling_branches(tmp_path, fake):
    rd = tmp_path / "run"
    run(branches(), rd)
    assert len(fake.runs) == 7
    fake.runs.clear()
    results, merged = run(branches(" v2"), rd)
    # branch 1 replays up to its edited call; branches 0 and 2 replay whole; the call after the join runs live
    assert live(fake) == ["b1 second v2", "merge"]
    assert results == [[f"llm-builder:b{i} first", f"llm-builder:b{i} second" + (" v2" if i == 1 else "")]
                       for i in range(3)]
    assert merged == "llm-builder:merge"
    assert sorted(x["site"] for x in journal(rd)) == ["0.0.0", "0.0.1", "0.1.0", "0.1.1", "0.2.0", "0.2.1", "1"]
    assert len(journal(rd, "journal.prev.jsonl")) == 7


def test_resume_retries_a_failed_call_and_what_depends_on_it(tmp_path, fake):
    rd = tmp_path / "run"
    fake.fail = {"b1 second"}
    results, _ = run(branches(), rd)
    assert results[1] == ["llm-builder:b1 first", None]  # the failure stays inside its call
    fake.fail = set()
    fake.runs.clear()
    results, merged = run(branches(), rd)
    assert live(fake) == ["b1 second", "merge"]
    assert results[1] == ["llm-builder:b1 first", "llm-builder:b1 second"] and merged == "llm-builder:merge"


def test_agent_called_by_a_running_agent_neither_deadlocks_nor_breaks_resume(tmp_path, fake):
    rd = tmp_path / "run"
    seen = {}

    async def main(wf):
        async def tool(agent, text):  # the outer agent's "tool" delegates to a sub-agent through the workflow
            if text == "outer":
                seen["inner"] = await wf.agent("inner", label="sub")
        fake.hook = tool
        # concurrency=1 and the outer call holds the only slot: the inner call must run in it, not wait for it
        outer = await asyncio.wait_for(wf.agent("outer", label="outer"), timeout=5)
        return outer, await wf.agent("after", label="after")

    assert run(main, rd, concurrency=1) == ("llm-builder:outer", "llm-builder:after")
    assert seen == {"inner": "llm-builder:inner"}
    assert {x["label"]: x["site"] for x in journal(rd)} == {"sub": "0.0.0", "outer": "0", "after": "1"}

    fake.runs.clear()
    seen.clear()
    assert run(main, rd, concurrency=1) == ("llm-builder:outer", "llm-builder:after")
    assert live(fake) == [] and seen == {}  # the outer call replays, so its tool and the sub-agent never run


def test_call_key_covers_prompt_images_role_system_schema_and_tools():
    base = {"role": "builder", "system": "s", "schema": SCHEMA, "tool_names": ["read", "write"]}
    key = call_key(image_prompt("x"), **base)
    assert key == call_key(image_prompt("x"), **base)
    assert key == call_key(image_prompt("x"), **{**base, "tool_names": ["write", "read"]})  # tool order
    assert key == call_key(image_prompt("x"), **{**base, "schema": dict(reversed(SCHEMA.items()))})  # dict order
    changed = [
        call_key(image_prompt("y"), **base),
        call_key(image_prompt("x", PNG + b"!"), **base),  # same text, different image
        call_key(image_prompt("x"), **{**base, "role": "judge"}),
        call_key(image_prompt("x"), **{**base, "system": "t"}),
        call_key(image_prompt("x"), **{**base, "schema": None}),
        call_key(image_prompt("x"), **{**base, "tool_names": ["read"]}),
        call_key("x", **base),
    ]
    assert len({key, *changed}) == len(changed) + 1


# -- wiring ----------------------------------------------------------------------------------------

def test_agent_class_is_imported_lazily(tmp_path, monkeypatch):
    # importing harness.workflow loads neither harness.agent nor harness.llm (checked in a fresh interpreter)...
    code = ("import sys, harness; before = set(sys.modules); import harness.workflow; "
            "print(sorted({'harness.agent', 'harness.llm'} & (set(sys.modules) - before)))")
    out = subprocess.run([sys.executable, "-c", code], cwd=REPO, capture_output=True, text=True, timeout=120,
                         check=True)
    assert out.stdout.strip() == "[]"

    # ...and with no agent_class set, the first live call imports harness.agent and uses its Agent
    cls = fresh_fake()
    module = types.ModuleType("harness.agent")
    module.Agent = cls
    monkeypatch.setitem(sys.modules, "harness.agent", module)
    monkeypatch.setattr(Workflow, "agent_class", None)

    async def main(wf):
        return await wf.agent("hi")

    assert run(main, tmp_path / "run") == "llm-builder:hi"
    assert live(cls) == ["hi"]


def test_run_workflow_is_a_sync_entry_point(tmp_path, fake):
    rd = tmp_path / "run"

    async def main(wf):
        return [await wf.agent("one"), wf.name]

    assert run_workflow(main, name="demo", run_dir=rd, roles=ROLES, concurrency=2) == ["llm-builder:one", "demo"]
    log = (rd / "log.txt").read_text("utf-8")
    assert "workflow 'demo' finished; 1 live, 0 cached, 0 failed agent calls" in log
    assert "completion_tokens=5, prompt_tokens=10" in log

    async def crash(wf):
        raise RuntimeError("script bug")

    with pytest.raises(RuntimeError, match="script bug"):
        run_workflow(crash, name="demo", run_dir=rd, roles=ROLES)
    assert "workflow 'demo' stopped by RuntimeError: script bug" in (rd / "log.txt").read_text("utf-8")

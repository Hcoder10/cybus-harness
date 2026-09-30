"""harness.agent tests with a scripted stub LLM (plus one real LLM on httpx.MockTransport). No network,
no pytest-asyncio (asyncio.run)."""

import asyncio
import io
import itertools
import json

import httpx
from PIL import Image

from harness.agent import Agent
from harness.llm import LLM, PARSE_ERROR_KEY, RAW_ARGUMENTS_KEY, LLMResponse, Message, ToolCall
from harness.tools.base import Tool, ToolResult

_ids = itertools.count(1)

SCORE = {"type": "object", "additionalProperties": False, "required": ["score", "why"],
         "properties": {"score": {"type": "integer", "minimum": 1, "maximum": 10}, "why": {"type": "string"}}}


def call(name, **arguments):
    return ToolCall(f"call_{next(_ids)}", name, arguments)


def say(text="", *calls):
    return Message("assistant", text, tool_calls=list(calls) or None)


class StubLLM:
    """Plays scripted replies (a Message, or an exception to raise) and records what it was sent."""

    def __init__(self, *replies):
        self.replies = list(replies)
        self.sent = []   # the messages of each call (a snapshot of the list)
        self.tools = []  # the tool specs of each call

    async def chat(self, messages, tools=None):
        self.sent.append(list(messages))
        self.tools.append(tools)
        reply = self.replies.pop(0)
        if isinstance(reply, Exception):
            raise reply
        return LLMResponse(reply, {"prompt_tokens": 100, "completion_tokens": 10, "total_tokens": 110},
                           "tool_calls" if reply.tool_calls else "stop", {})


def tool(name, fn, mutating=False, **params):
    return Tool(name, f"The {name} tool.", {"type": "object", "properties": params}, fn, mutating)


def png(w=32, h=32):
    buf = io.BytesIO()
    Image.new("RGB", (w, h), "blue").save(buf, "PNG")
    return buf.getvalue()


def run(agent, task="Do the task.", schema=None):
    return asyncio.run(agent.run(task, schema))


def test_tool_calls_in_one_turn_run_concurrently():
    active = peak = 0

    async def wait(tag):
        nonlocal active, peak
        active += 1
        peak = max(peak, active)
        await asyncio.sleep(0.05)
        active -= 1
        return f"done {tag}"

    a, b = call("wait", tag="a"), call("wait", tag="b")
    llm = StubLLM(say("Two at once.", a, b), say("All done."))
    res = run(Agent(llm, "SYSTEM", [tool("wait", wait, tag={"type": "string"})]))

    assert res.stopped == "no_tool_calls" and res.text == "All done." and res.steps == 2
    assert peak == 2  # both calls were in flight together
    results = [m for m in llm.sent[1] if m.role == "tool"]
    assert [(m.tool_call_id, m.content) for m in results] == [(a.id, "done a"), (b.id, "done b")]
    assert res.usage == {"prompt_tokens": 200, "completion_tokens": 20, "total_tokens": 220}


def test_mutating_calls_keep_their_order():
    events = []

    async def read(path):
        events.append(f"read {path} start")
        await asyncio.sleep(0.02)
        events.append(f"read {path} end")
        return path

    async def write(path):
        events.append(f"write {path} start")
        await asyncio.sleep(0.01)
        events.append(f"write {path} end")
        return "ok"

    llm = StubLLM(say("", call("read", path="a"), call("read", path="b"), call("write", path="c"),
                      call("write", path="d"), call("read", path="e")), say("Done."))
    run(Agent(llm, "SYSTEM", [tool("read", read, path={"type": "string"}),
                              tool("write", write, mutating=True, path={"type": "string"})]))
    assert events[:2] == ["read a start", "read b start"]  # the reads overlap
    assert sorted(events[2:4]) == ["read a end", "read b end"]
    assert events[4:] == ["write c start", "write c end", "write d start", "write d end", "read e start", "read e end"]


def test_tool_exception_is_returned_to_the_model_as_text():
    async def explode():
        raise ValueError("the part is locked")

    llm = StubLLM(say("", call("explode")), say("", call("nope")), say("I could not do it."))
    res = run(Agent(llm, "SYSTEM", [tool("explode", explode)]))

    assert res.stopped == "no_tool_calls" and res.text == "I could not do it." and res.steps == 3
    error = llm.sent[1][-1]
    assert error.role == "tool" and "ValueError" in error.content and "the part is locked" in error.content
    unknown = llm.sent[2][-1]
    assert "no tool named 'nope'" in unknown.content and "explode" in unknown.content


def test_unparseable_arguments_are_reported_to_the_model():
    ran = []

    async def echo(text):
        ran.append(text)
        return text

    bad = ToolCall("call_bad", "echo", {PARSE_ERROR_KEY: "arguments are not valid JSON (Expecting value)",
                                        RAW_ARGUMENTS_KEY: '{"text": }'})
    llm = StubLLM(say("", bad), say("ok"))
    run(Agent(llm, "SYSTEM", [tool("echo", echo, text={"type": "string"})]))
    reply = llm.sent[1][-1]
    assert reply.tool_call_id == "call_bad" and "could not be parsed" in reply.content
    assert '{"text": }' in reply.content and ran == []


def test_tool_results_are_normalized_and_clipped():
    async def stats():
        return {"fps": 60, "parts": 1200}

    async def flood():
        return "a" * 5000 + "THE END"

    t = tool("stats", stats)
    assert t.spec() == {"type": "function", "function": {
        "name": "stats", "description": "The stats tool.", "parameters": {"type": "object", "properties": {}}}}
    llm = StubLLM(say("", call("stats"), call("flood")), say("ok"))
    run(Agent(llm, "SYSTEM", [t, tool("flood", flood)], max_tool_chars=1000))
    stats_msg, flood_msg = llm.sent[1][-2:]
    assert json.loads(stats_msg.content) == {"fps": 60, "parts": 1200}
    assert len(flood_msg.content) < 1100 and "characters cut" in flood_msg.content
    assert flood_msg.content.endswith("THE END")  # the tail is kept


def test_submit_rejects_invalid_then_accepts_valid():
    llm = StubLLM(say("Scoring.", call("submit", score="high")),
                  say("", call("submit", score=8, why="Clean layout.")))
    res = run(Agent(llm, "SYSTEM", []), "Judge this.", schema=SCORE)

    assert res.stopped == "submitted" and res.steps == 2
    assert res.structured == {"score": 8, "why": "Clean layout."} and res.text == "Scoring."
    submit_spec = llm.tools[0][-1]["function"]
    assert submit_spec["name"] == "submit" and submit_spec["parameters"] == SCORE
    feedback = llm.sent[1][-1]
    assert feedback.role == "tool" and feedback.content.startswith("Error: submit rejected")
    assert "score: 'high' is not of type 'integer'" in feedback.content
    assert "'why' is a required property" in feedback.content
    assert res.transcript[-1].content == "Submitted."


def test_schema_run_nudges_the_model_to_submit():
    llm = StubLLM(say("The score is 7."), say("", call("submit", score=7, why="Fine.")))
    res = run(Agent(llm, "SYSTEM", []), "Judge this.", schema=SCORE)
    assert res.stopped == "submitted" and res.structured == {"score": 7, "why": "Fine."}
    nudge = llm.sent[1][-1]
    assert nudge.role == "user" and "submit" in nudge.content

    wrapped = StubLLM(say("", call("submit", result=["a", "b"])))  # non-object schemas are wrapped
    res = run(Agent(wrapped, "SYSTEM", []), schema={"type": "array", "items": {"type": "string"}})
    assert res.stopped == "submitted" and res.structured == ["a", "b"]


def test_step_limit_and_model_errors():
    async def look():
        return "a frame"

    llm = StubLLM(say("", call("look")), say("", call("submit", score=5, why="Out of steps.")))
    res = run(Agent(llm, "SYSTEM", [tool("look", look)], max_steps=2), schema=SCORE)
    assert res.stopped == "submitted" and "one step left" in llm.sent[1][-1].content

    llm = StubLLM(*[say("", call("look")) for _ in range(3)])
    res = run(Agent(llm, "SYSTEM", [tool("look", look)], max_steps=3))
    assert res.stopped == "max_steps" and res.steps == 3 and res.structured is None

    res = run(Agent(StubLLM(RuntimeError("connection refused")), "SYSTEM", []))
    assert res.stopped == "error" and res.steps == 1 and "connection refused" in res.error
    assert [m.role for m in res.transcript] == ["system", "user"]


def test_tool_images_arrive_in_the_next_user_message():
    async def screenshot():
        return ToolResult("Captured the lobby.", images=[png(48, 24)])

    shot = call("screenshot")
    llm = StubLLM(say("", shot), say("The lobby looks empty."))
    res = run(Agent(llm, "SYSTEM", [tool("screenshot", screenshot)]))

    assert res.text == "The lobby looks empty."
    *_, assistant, result, images = llm.sent[1]
    assert assistant.tool_calls == [shot]
    assert result.role == "tool" and result.tool_call_id == shot.id
    assert isinstance(result.content, str) and result.content.startswith("Captured the lobby.")  # no image here
    assert images.role == "user"
    image_parts = [p for p in images.content if p["type"] == "image_url"]
    assert len(image_parts) == 1 and image_parts[0]["image_url"]["url"].startswith("data:image/png;base64,")


def test_context_trimming_keeps_system_task_and_recent_messages():
    async def dump(n):
        return f"dump {n}: " + "x" * 2000

    llm = StubLLM(*[say("", call("dump", n=i)) for i in range(8)], say("Finished."))
    agent = Agent(llm, "SYSTEM PROMPT", [tool("dump", dump, n={"type": "integer"})], context_budget_tokens=3000)
    res = run(agent, "THE TASK")
    assert res.stopped == "no_tool_calls" and res.text == "Finished."

    last = llm.sent[-1]
    assert (last[0].role, last[0].content) == ("system", "SYSTEM PROMPT")
    assert (last[1].role, last[1].content) == ("user", "THE TASK")
    assert agent.estimate_tokens(last) <= 3000
    results = [m for m in last if m.role == "tool"]
    trimmed = [m for m in results if "trimmed to save context" in m.content]
    assert trimmed and results[:len(trimmed)] == trimmed          # the oldest results went first
    assert last[-6:] == res.transcript[len(last) - 6:len(last)]   # the last 6 messages are untouched
    assert all(len(m.content) > 2000 for m in res.transcript if m.role == "tool")  # the transcript is complete

    # A budget that cannot be met: everything trimmable is trimmed, the protected messages still are not.
    llm = StubLLM(*[say("", call("dump", n=i)) for i in range(8)], say("Finished."))
    res = run(Agent(llm, "SYSTEM PROMPT", [tool("dump", dump, n={"type": "integer"})], context_budget_tokens=500),
              "THE TASK")
    last = llm.sent[-1]
    assert last[:2] == res.transcript[:2] and last[-6:] == res.transcript[len(last) - 6:len(last)]
    assert all("trimmed to save context" in m.content for m in last[2:-6] if m.role == "tool")


def images_per_message(messages):
    return [sum(p["type"] == "image_url" for p in m.content)
            for m in messages if m.role == "user" and isinstance(m.content, list)]


async def capture():
    return ToolResult("frame captured", images=[png()])


def test_old_images_are_dropped_before_tool_results_are_trimmed():
    llm = StubLLM(*[say("", call("capture")) for _ in range(5)], say("Done."))
    agent = Agent(llm, "SYSTEM", [tool("capture", capture)], context_budget_tokens=4000)
    res = run(agent, "THE TASK")

    last = llm.sent[-1]
    assert images_per_message(last) == [0, 0, 0, 1, 1]  # only the two newest captures are still images
    assert all(m.content.startswith("frame captured") for m in last if m.role == "tool")  # results untouched
    assert images_per_message(res.transcript) == [1, 1, 1, 1, 1]


def test_newest_two_captures_survive_outside_the_recent_messages():
    async def note():
        return "noted"

    # Four captures, then three text-only steps: the captures all fall outside the last 6 messages.
    llm = StubLLM(*[say("", call("capture")) for _ in range(4)], *[say("", call("note")) for _ in range(3)],
                  say("Done."))
    agent = Agent(llm, "SYSTEM", [tool("capture", capture), tool("note", note)], context_budget_tokens=2000)
    run(agent, "THE TASK")
    assert images_per_message(llm.sent[-1]) == [0, 0, 1, 1]  # over budget still, but the newest two stay


def test_big_arguments_of_old_tool_calls_are_shortened_last():
    async def write_file(path, content):
        return "ok"

    code = "-- code\n" * 500  # 4000 chars
    llm = StubLLM(*[say("", call("write_file", path=f"f{i}.luau", content=code)) for i in range(6)], say("Done."))
    agent = Agent(llm, "SYSTEM", [tool("write_file", write_file, path={"type": "string"}, content={"type": "string"})],
                  context_budget_tokens=3000)
    res = run(agent, "THE TASK")

    sent = [m.tool_calls[0].arguments["content"] for m in llm.sent[-1] if m.role == "assistant" and m.tool_calls]
    assert all("trimmed to save context" in c and len(c) < 400 for c in sent[:3])  # old calls shortened
    assert sent[3:] == [code] * 3                                                   # recent calls intact
    assert all(m.tool_calls[0].arguments["content"] == code
               for m in res.transcript if m.role == "assistant" and m.tool_calls)


def test_agent_executes_text_tool_calls_from_a_real_client():
    bodies = []
    replies = [
        {"choices": [{"finish_reason": "stop", "message": {"role": "assistant", "content":
            'Reading it.\n<tool_call>\n{"name": "read_file", "arguments": {"path": "a.luau"}}\n</tool_call>'}}],
         "usage": {"prompt_tokens": 50, "completion_tokens": 20, "total_tokens": 70}},
        {"choices": [{"finish_reason": "stop", "message": {"role": "assistant", "content": "It sets x to 1."}}],
         "usage": {"prompt_tokens": 80, "completion_tokens": 10, "total_tokens": 90}},
    ]

    def handler(request):
        bodies.append(json.loads(request.content))
        return httpx.Response(200, json=replies[len(bodies) - 1])

    async def read_file(path):
        return f"-- {path}\nlocal x = 1"

    llm = LLM("http://gpu.test:8000/v1", "cybus", transport=httpx.MockTransport(handler))
    res = run(Agent(llm, "SYSTEM", [tool("read_file", read_file, path={"type": "string"})]), "What does a.luau do?")

    assert res.stopped == "no_tool_calls" and res.text == "It sets x to 1." and res.steps == 2
    assert res.usage["total_tokens"] == 160
    assistant, result = bodies[1]["messages"][2:4]
    assert assistant["content"] == "Reading it." and assistant["tool_calls"][0]["function"]["name"] == "read_file"
    assert result == {"role": "tool", "content": "-- a.luau\nlocal x = 1",
                      "tool_call_id": assistant["tool_calls"][0]["id"]}


def test_out_of_steps_gets_a_submit_only_turn():
    """A run that uses every step without submitting is offered submit as the only tool before it is failed."""
    import asyncio as _asyncio
    from harness.agent import Agent as _Agent
    from harness.llm import LLMResponse as _R, Message as _M, ToolCall as _TC
    from harness.tools.base import Tool as _Tool, ToolResult as _TR

    class Stubborn:
        def __init__(self):
            self.offered = []

        async def chat(self, messages, tools=None):
            names = [t["function"]["name"] for t in tools or []]
            self.offered.append(names)
            if names == ["submit"]:
                return _R(_M("assistant", "", tool_calls=[_TC("s", "submit", {"summary": "done"})]), {}, "tool_calls", {})
            return _R(_M("assistant", "", tool_calls=[_TC(f"c{len(self.offered)}", "poke", {})]), {}, "tool_calls", {})

    async def poke():
        return _TR(text="poked")

    llm = Stubborn()
    agent = _Agent(llm, "sys", [_Tool("poke", "poke", {"type": "object", "properties": {}}, poke)], max_steps=3)
    res = _asyncio.run(agent.run("task", schema={"type": "object", "properties": {"summary": {"type": "string"}},
                                                 "required": ["summary"]}))
    assert res.stopped == "submitted" and res.structured == {"summary": "done"}
    assert llm.offered[-1] == ["submit"] and len(llm.offered) == 4

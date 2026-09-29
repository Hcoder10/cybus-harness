# cybus-harness — architecture and module contracts (v1)

A from-scratch, model-agnostic harness for building Roblox games with multi-agent orchestration
("ultracode"-style), whose differentiator is **operational taste**: every artifact is planned against a
written style, built, SEEN (captured), judged against rubrics and targets, and repaired until it passes.

Primary model: Cybus (Qwen3.8-27B + LoRA, vision-capable) behind an OpenAI-compatible endpoint (vLLM).
Any OpenAI-compatible or Anthropic model must also work (frontier ceiling runs).
Cybus must ALSO work inside Codex and Claude Code (serve/, mcp_server/), but be much better here.

Hard rules for everyone working in this repo:
- Python 3.11, stdlib + httpx, jsonschema, pillow, pyyaml, mcp, fastapi, uvicorn, openai, anthropic (already
  installed). No new dependencies without a strong reason.
- Nothing game-specific in the harness. The owner's reference game (Anime Duelists / ~/anime-oratio) is a
  QUALITY BAR ONLY: never copy its code, docs, playbooks or tasks into this repo.
- Studio safety: the Studio Bridge also serves other people's places. `StudioBridge` refuses every
  mutating call unless the active session's PlaceId is in an explicit allow-list for the current run, and
  ALWAYS refuses PlaceId 82121330849989. Tests never mutate a live Studio.
- Secrets come from environment variables only; never write keys into files or logs.

## Layout
```
harness/
  llm.py            chat client (OpenAI-compatible; Anthropic adapter), images, tool calls, retries
  agent.py          tool-using agent loop, structured output via a `submit` tool, context budget
  tools/base.py     Tool / ToolResult / registry helpers
  tools/studio.py   MCP client for the Studio Bridge (http://localhost:3000/mcp), PlaceId guard
  tools/capture.py  screenshots, frame strips from video, contact sheets
  tools/workspace.py  project tree on disk <-> Studio sync
  tools/imagegen.py image generation (OpenAI images API or a Qwen-Image HTTP endpoint)
  judge.py          vision judges: rubric verdicts, pairwise, vs-target comparison
  workflow.py       orchestration engine: agent / parallel / pipeline / phase / log, journal + resume
  playbooks/*.md    genre-general craft processes and rubrics (the taste)
  workflows/*.py    build_game.py, polish.py
serve/              vLLM launch for Cybus, Anthropic-compatible gateway (Claude Code), Codex config
mcp_server/         the harness's taste tools over MCP, for Codex / Claude Code
bench/              new-genre ideas, runner, scoring
tests/
```

## Contracts

### harness/llm.py
```python
@dataclass
class ToolCall:  id: str; name: str; arguments: dict
@dataclass
class Message:
    role: str                         # system | user | assistant | tool
    content: str | list[dict]         # OpenAI content parts ({"type":"text"}, {"type":"image_url"})
    tool_calls: list[ToolCall] | None = None
    tool_call_id: str | None = None
    name: str | None = None
@dataclass
class LLMResponse: message: Message; usage: dict; finish_reason: str; raw: dict
class LLM:
    def __init__(self, base_url: str, model: str, api_key: str | None = None, provider: str = "openai",
                 max_tokens: int = 4096, temperature: float = 0.6, timeout: float = 600, extra: dict | None = None)
    async def chat(self, messages: list[Message], tools: list[dict] | None = None) -> LLMResponse
def text_part(s: str) -> dict
def image_part(img: bytes | str | Path, max_side: int = 1280) -> dict   # PNG/JPEG -> data-URI image_url part
def llm_from_env(role: str) -> LLM    # HARNESS_<ROLE>_BASE_URL / _MODEL / _API_KEY / _PROVIDER, falling back to HARNESS_DEFAULT_*
```
- Tools are OpenAI function tools: `{"type":"function","function":{"name","description","parameters"}}`.
- If the model answers in text with `<tool_call>{...}</tool_call>` (hermes JSON) or
  `<tool_call><function=NAME><parameter=K>V</parameter>...</function></tool_call>` (Qwen XML), parse
  these into ToolCall objects (models behind vLLM without a tool parser, and Cybus SFT variants, do this).
- provider="anthropic": translate to/from the Anthropic Messages API (system, tool_use/tool_result blocks,
  image blocks). Retries with backoff on 429/5xx/timeouts; never log API keys.

### harness/tools/base.py
```python
@dataclass
class ToolResult: text: str; images: list[bytes] = field(default_factory=list); data: dict | None = None
@dataclass
class Tool:
    name: str; description: str; parameters: dict        # JSON Schema (object)
    fn: Callable[..., Awaitable[str | dict | ToolResult]]
    mutating: bool = False
    def spec(self) -> dict                                 # OpenAI tool spec
```

### harness/agent.py
```python
@dataclass
class AgentResult: text: str; structured: dict | None; steps: int; transcript: list[Message]; usage: dict; stopped: str
class Agent:
    def __init__(self, llm: LLM, system: str, tools: list[Tool], name: str = "agent", max_steps: int = 40,
                 max_tool_chars: int = 16000, context_budget_tokens: int = 48000)
    async def run(self, task: str | list[dict], schema: dict | None = None) -> AgentResult
```
- Loop: model -> tool calls (run concurrently when several) -> results appended (images in a ToolResult
  become image parts in a following user message, since many backends reject images in tool messages)
  -> ... until the model stops calling tools, or calls `submit`.
- If `schema` is given, a `submit` tool with that JSON Schema is added; the run ends when `submit` is called
  with valid arguments (validate with jsonschema; on failure, return the validation error as the tool
  result so the model retries). `structured` holds the submitted object.
- Context budget: when the transcript exceeds the budget, replace the oldest tool results with short
  summaries (keep the system prompt, the task, and the last N turns intact). Images older than the last two
  captures are dropped first.

### harness/workflow.py
```python
class Workflow:
    def __init__(self, name: str, run_dir: Path, roles: dict[str, LLM], concurrency: int = 6, resume: bool = True)
    async def agent(self, prompt: str | list[dict], *, role: str = "builder", system: str | None = None,
                    tools: list[Tool] | None = None, schema: dict | None = None, label: str = "",
                    phase: str | None = None, max_steps: int | None = None) -> dict | str | None
    async def parallel(self, thunks: list[Callable[[], Awaitable]]) -> list        # barrier; exceptions -> None
    async def pipeline(self, items: list, *stages) -> list                         # stage(prev, item, idx); no barrier
    def phase(self, title: str) -> None
    def log(self, msg: str) -> None
```
- Journal: `run_dir/journal.jsonl`, one line per agent() call: key = (call ordinal, sha256 of prompt text +
  role + schema), label, phase, result, usage, seconds. With resume=True, the longest unchanged prefix of
  calls returns cached results. Transcripts go to run_dir/agents/<ordinal>-<label>.json.
- Concurrency cap with an asyncio.Semaphore; a failed agent returns None (logged), never kills the run.

### harness/tools/studio.py
```python
class StudioBridge:
    def __init__(self, url: str = "http://localhost:3000/mcp", allow_place_ids: set[str] | None = None,
                 protected_place_ids: set[str] = {"82121330849989"})
    async def connect(self) -> None
    async def list_tools(self) -> list[dict]
    async def call(self, name: str, args: dict | None = None) -> dict       # raises StudioError on tool errors
    async def active_place_id(self) -> str | None
    async def guard(self, name: str) -> None      # refuse mutating tools unless the active place is allowed
    def tools(self, allow: list[str] | None = None) -> list[Tool]            # curated bridge tools for agents
```
- Mutating = anything not in an explicit read-only list (get/list/find/status/dump/analyze/lint/parse/
  screenshot/diagnostics/…). Unknown tools count as mutating.

### harness/tools/capture.py
```python
async def screenshot(bridge, **kw) -> bytes                    # PNG bytes via screenshot_take
async def frames(bridge, seconds: float, n: int) -> list[bytes] # video_record_* or timed screenshots
def contact_sheet(images: list[bytes], cols: int = 4, width: int = 1280, labels: list[str] | None = None) -> bytes
```

### harness/tools/workspace.py
```python
class Workspace:
    def __init__(self, root: Path)    # root/src/<Service>/<...>.luau (+ .server.luau / .client.luau)
    def write(self, rel: str, source: str) -> None
    def read(self, rel: str) -> str
    def changed(self) -> list[str]
    async def sync(self, bridge: StudioBridge) -> dict         # push changed scripts; create containers as needed
    def tools(self, bridge: StudioBridge) -> list[Tool]         # write_file/read_file/list_files/sync_to_studio
```

### harness/judge.py
```python
@dataclass
class Issue: severity: str; where: str; problem: str; fix: str
@dataclass
class Verdict: aspect: str; score: float; passed: bool; issues: list[Issue]; strengths: list[str]; raw: dict
async def judge(llm: LLM, aspect: str, images: list[bytes], intent: str, style: str = "",
                target: list[bytes] | None = None, threshold: float = 7.0) -> Verdict
async def pairwise(llm: LLM, aspect: str, a: list[bytes], b: list[bytes], intent: str) -> dict   # {"prefer": "A"|"B"|"tie", "why": str}
```
- Rubrics are loaded from harness/playbooks/rubric_<aspect>.md; the judge answers via JSON (schema),
  scores 1-10 against the anchors described in the rubric, lists concrete issues with fixes.

## Workflows (what "ultracode" means here)
build_game(idea): plan (GDD, scope, systems list) -> style (style guide, tokens, reference board via image
generation, judged) -> scaffold (project structure, shared modules) -> build aspects in parallel (each:
implement -> sync -> capture -> judge vs style/target -> repair until pass or budget) -> integrate
(playtest with scripted input, capture frames, judge feel/UX, fix bugs from output logs) -> polish panel
(independent critics per aspect, adversarial verify, fix, loop until dry) -> ship report.

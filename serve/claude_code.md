# Claude Code on Cybus

Claude Code speaks the Anthropic Messages API; vLLM speaks OpenAI's. `anthropic_gateway.py` translates:

```
claude  --Anthropic Messages-->  serve/anthropic_gateway.py (127.0.0.1:4000)  --OpenAI chat-->  vLLM "cybus" (:8000)
```

The translation was checked end to end with Claude Code 2.1.284 against a scripted stand-in for vLLM: Claude Code's
real requests (system prompt, 22 tools, streaming) go through, a streamed tool call runs locally, and the tool result
comes back as an OpenAI tool message.

Checked live on 2026-09-30 with Claude Code 2.1.285 against Cybus itself (Qwen3.8-27B on vLLM 0.27.1, qwen3_xml,
98k window, thinking off through `GATEWAY_EXTRA_BODY`). The task was headless: `claude -p ... --bare
--strict-mcp-config --permission-mode acceptEdits`. It asked for a typed ModuleScript and a server script that
requires it. Claude Code wrote both files correctly, read them back and finished in 6 turns (4 minutes on a GPU shared
with three builds). `--bare` authenticates only with `ANTHROPIC_API_KEY`: set that instead of `ANTHROPIC_AUTH_TOKEN`.

## 1. Serve Cybus

Follow [README.md](README.md), with two settings that matter for Claude Code:

```bash
CYBUS_TOOL_PARSER=qwen3_xml CYBUS_MAX_MODEL_LEN=131072 CYBUS_LORA=<adapter> bash serve/vllm_cybus.sh
```

- `qwen3_xml`: Claude Code streams, and a tool parser that does not match the model drops streamed tool calls.
- 131072: Claude Code's system prompt and tool definitions are about 20k tokens before any conversation (measured
  through this gateway with no MCP servers and no CLAUDE.md; each MCP server adds its tools). A 64k window leaves
  ~40k for the session, and Claude Code cannot be told a window under 100k (see step 3).

## 2. Start the gateway

```bash
export GATEWAY_BACKEND_URL=http://<vllm-host>:8000/v1
export GATEWAY_BACKEND_MODEL=cybus
export GATEWAY_BACKEND_KEY="$CYBUS_API_KEY"        # the vLLM key, from your environment / secret store
python -m serve.anthropic_gateway --port 4000       # binds 127.0.0.1 (it holds the backend key)
```

PowerShell: `$env:GATEWAY_BACKEND_URL = "http://<vllm-host>:8000/v1"` and so on, then the same `python` line from
the repo root. `uvicorn serve.anthropic_gateway:app --port 4000` works too.

Gateway options (environment):

| Variable | Default | Meaning |
| --- | --- | --- |
| `GATEWAY_API_KEY` | none | if set, clients must send it (`ANTHROPIC_AUTH_TOKEN` / `ANTHROPIC_API_KEY`); otherwise any key is accepted and ignored |
| `GATEWAY_BACKEND_STREAM` | `1` | `0`: fetch whole responses from vLLM and re-stream them, parsing `<tool_call>` markup itself. Use when you cannot fix the vLLM tool parser (first token arrives later) |
| `GATEWAY_EXTRA_BODY` | none | JSON merged into every vLLM request, e.g. `{"chat_template_kwargs": {"enable_thinking": false}, "temperature": 0.7}` |
| `GATEWAY_MAX_OUTPUT_TOKENS` | none | cap on `max_tokens` sent to vLLM |
| `GATEWAY_MAX_IMAGES` | `8` | newest images kept per request (match vLLM's `--limit-mm-per-prompt`) |
| `GATEWAY_THINKING` | `emit` | `drop` hides the model's reasoning instead of showing it as thinking blocks |
| `GATEWAY_TEXT_TOOL_CALLS` | `1` | turn `<tool_call>` markup naming a requested tool into tool_use blocks |
| `GATEWAY_PING_SECONDS` | `10` | SSE ping interval while vLLM is silent (prefill, long reasoning) |
| `GATEWAY_TIMEOUT` | `600` | backend read timeout, seconds |

## 3. Point Claude Code at it

```bash
export ANTHROPIC_BASE_URL=http://127.0.0.1:4000
export ANTHROPIC_AUTH_TOKEN=local-gateway                   # any value unless GATEWAY_API_KEY is set
export ANTHROPIC_MODEL=claude-gateway/cybus
export ANTHROPIC_DEFAULT_HAIKU_MODEL=claude-gateway/cybus   # background tasks: titles, summaries, classifiers
export ANTHROPIC_SMALL_FAST_MODEL=claude-gateway/cybus      # the same for older Claude Code (deprecated name)
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1           # no telemetry, update checks or release notes
export CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1             # no beta-only fields the gateway would ignore
export CLAUDE_CODE_ATTRIBUTION_HEADER=0                     # keep the prompt prefix stable (prefix caching)
export CLAUDE_CODE_MAX_OUTPUT_TOKENS=16384
export CLAUDE_CODE_AUTO_COMPACT_WINDOW=131072               # only when vLLM really serves >= 100k context
claude
```

The same variables can go in the `env` block of `~/.claude/settings.json` (not a project's committed
`.claude/settings.json`). Run `/status`: it should show the gateway as `Anthropic base URL` and
`ANTHROPIC_AUTH_TOKEN` as the credential.

Why these:
- `ANTHROPIC_AUTH_TOKEN` is sent as `Authorization: Bearer` and takes over from a claude.ai login at once;
  `ANTHROPIC_API_KEY` works as well but asks for approval once in interactive mode.
- Any model name reaches Cybus (the gateway maps every Claude name to `GATEWAY_BACKEND_MODEL`; a non-Claude name like
  `cybus-base` passes through; `claude-gateway/<id>` selects backend model `<id>`). Name it explicitly anyway:
  Claude Code sizes its context from the name, and its default model assumed a 1M-token window in testing, so it
  would never compact in time. An unrecognised name is assumed to have 200k.
- `CLAUDE_CODE_AUTO_COMPACT_WINDOW` tells Claude Code the real window, but only accepts 100000-1000000; with a 65536
  server it cannot be matched. Then, when a conversation no longer fits, the gateway answers with Anthropic's
  `prompt is too long: N tokens > M maximum` error, which makes Claude Code compact and retry; run `/compact` early.
- Claude Code asks for up to 128000 output tokens per request (seen in testing). The gateway clamps `max_tokens` to
  whatever room is left in vLLM's window, but a cap leaves space for the conversation.
- `CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1` adds the gateway's models to `/model` (the gateway lists them as
  `claude-gateway/<id>` because discovery keeps only ids containing "claude").

Quick check without Claude Code:

```bash
curl -s http://127.0.0.1:4000/v1/messages -H "Authorization: Bearer local-gateway" \
  -H "anthropic-version: 2023-06-01" -H "content-type: application/json" \
  -d '{"model": "claude-gateway/cybus", "max_tokens": 64, "messages": [{"role": "user", "content": "Say hi"}]}'
```

## 4. The taste and craft tools in Claude Code

```bash
claude mcp add --env HARNESS_JUDGE_BASE_URL=http://<vllm-host>:8000/v1 --env HARNESS_JUDGE_MODEL=cybus \
  --transport stdio cybus-taste -- python /path/to/cybus-harness/mcp_server/server.py
```

Keep keys out of the MCP config: export `HARNESS_JUDGE_API_KEY` in the shell that starts `claude`, or use a
`.mcp.json` entry with `"env": {"HARNESS_JUDGE_API_KEY": "${HARNESS_JUDGE_API_KEY}"}`. Taste tools: `capture`,
`judge`, `pairwise`, `style_guide_template`, `rubric`. `capture` only takes screenshots through the Studio Bridge; it
never edits the place.

### Craft tools

The same server gives Claude Code the harness's builder pipeline, with Cybus or any other model: the runtime kit, style
tokens, painted textures, animation clips and sound, all without uploads. The craft tools need neither the judge model
nor Studio; they only write files in your project. `project_root` is the absolute path of the game's project
directory, laid out Rojo-style: scripts live in `src/<Service>/...`, where `.luau` is a ModuleScript, `.server.luau` a
Script and `.client.luau` a LocalScript. Sync `src/` into Studio the way you already do. Every write stays inside
`project_root`: names or links (`..`, symlinks, junctions) that lead out of it are refused.

| Tool | What it does |
| --- | --- |
| `install_kit(project_root, overwrite=false)` | writes the runtime kit (`ReplicatedStorage.Kit`) and its boot scripts, plus empty `AssetMap`, `TexPacks/Index` and `ClipPack` modules if they are missing; returns the file list and the kit's API. Safe to repeat: identical files are skipped, files you changed are kept unless `overwrite=true`, nothing is deleted |
| `generate_tokens(project_root, style)` | the style guide as JSON (the harness's STYLE schema; the object, or the path of a `.json` file) -> `src/ReplicatedStorage/Shared/Tokens.luau`; lists every value it had to repair |
| `paint_texture(project_root, name, spec)` | validates and renders a texture spec (panels, 9-slice buttons, glows, icons, particle textures), saves `art/<name>.png` and packs it into `ReplicatedStorage.Shared.TexPacks`; returns the preview image and the `Kit.Textures` call that shows it. `list_textures(project_root)` lists them |
| `author_clip(project_root, name, spec)` | validates a keyframe clip and packs it into `ReplicatedStorage.Shared.ClipPack`; returns a stick-figure contact sheet (also saved to `art/clips/<name>.png`) and the `Kit.Anim` code that plays it. `list_clips(project_root)` lists them |
| `search_audio(query, kind="sfx", limit=8)` | public Roblox Creator Store sounds the game can play by id, no upload; results are cached under `HARNESS_CAPTURE_DIR` |
| `playbook(name)` | the harness's references: `texture_spec`, `animation_spec`, `vfx_camera_spec`, `roblox_craft`, `style_guide`, `plan`, `rubric_<aspect>`; with no name it lists what exists |

A spec or clip with problems comes back as a tool error listing all of them (with the clip's preview as written), so
the model can fix everything in one go.

Recommended loop:

1. `install_kit(project_root)` once, and build on the kit API it returns.
2. `style_guide_template()`, decide the style with concrete values, then `generate_tokens(project_root, style)`.
3. Build scripts on the kit and the tokens; use `paint_texture`, `author_clip` and `search_audio` for art, animation and sound.
4. Sync into Studio, then `capture()` and `judge(aspect, intent, capture=true, style=...)`.
5. Fix every blocker and major the verdict lists, repaint or re-author, and judge again until `passed`.

## What works and what does not

Works: streaming text; tool use, including several calls per turn and calls with no arguments; tool results with
images (Read on a PNG, MCP screenshots); subagents (on the same model); the model's reasoning shown as thinking;
`/v1/messages/count_tokens` (an estimate: characters / 3.5 plus image patches); `/model` discovery; stop sequences;
structured outputs (`output_config.format` becomes vLLM guided decoding); reactive compaction on overflow; pings
through long silent prefills.

Does not, or only partly:
- **Server tools run on Anthropic's servers**: WebSearch, the web-fetch and code-execution server tools, tool search
  (`defer_loading` tools). The gateway drops them. The WebFetch tool's summary step runs on Cybus, but its domain
  safety check still calls api.anthropic.com.
- **Prompt caching**: `cache_control` is ignored. vLLM's prefix cache is the only cache, and usage reports cache reads
  only if vLLM reports cached tokens.
- **Thinking controls**: budgets, adaptive thinking and effort are ignored; Qwen3.8's thinking is set by the template
  kwargs (`GATEWAY_EXTRA_BODY` or the server). Thinking blocks carry a placeholder signature; if the session is
  switched to a real Claude model, Claude Code strips them and retries.
- **Forced tool choice**: `tool_choice` any or a named tool becomes OpenAI `required` / named, which vLLM's Qwen tool
  parsers currently ignore (auto works).
- **Documents**: text documents are forwarded; PDFs become a placeholder note.
- **Images**: only the newest `GATEWAY_MAX_IMAGES` per request reach the model; image URLs are fetched by vLLM.
- **claude.ai features**: Remote Control, voice dictation, fast mode, Slack and web sessions need Anthropic's service.
- **Cost figures**: Claude Code prices usage as the Claude model it thinks it called. Ignore the dollar amounts.
- **Quality**: Claude Code's prompts and tools are written for Claude. A 27B model follows them less reliably (exact
  string matching in Edit, long multi-step plans). Cybus does its best work inside this harness.

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| Claude Code asks to log in | set `ANTHROPIC_AUTH_TOKEN` in the shell or `~/.claude/settings.json` before starting it |
| tool calls appear as `<tool_call>` text, or replies are empty | vLLM tool parser does not match the model: `CYBUS_TOOL_PARSER=qwen3_xml`, or `GATEWAY_BACKEND_STREAM=0` |
| `prompt is too long` even after compaction | the session does not fit the window: `/clear`, or serve a longer `CYBUS_MAX_MODEL_LEN` |
| 502 `backend rejected the gateway's credentials` | `GATEWAY_BACKEND_KEY` does not match vLLM's `CYBUS_API_KEY` |
| 502 `backend unreachable` | vLLM is not up yet (first start takes minutes) or `GATEWAY_BACKEND_URL` is wrong |
| 404 naming the model | `GATEWAY_BACKEND_MODEL` is not a name vLLM serves (`curl <vllm>/v1/models`) |

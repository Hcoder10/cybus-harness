# Codex CLI on Cybus

Codex talks to Cybus directly: vLLM is an OpenAI-compatible server, so Cybus is just a custom model provider.
(The Anthropic gateway in this folder is for Claude Code only.) Serve Cybus first: [README.md](README.md).

## Responses API or Chat Completions

Codex has two wire protocols, chosen per provider with `wire_api`:

- `"responses"`: OpenAI's Responses API (`POST /v1/responses`). **Current Codex accepts only this**: `"chat"` was
  deprecated in December 2025 and removed in early February 2026; newer releases refuse to load a config that sets it.
  vLLM implements `/v1/responses` with the same tool and reasoning parsers as chat completions (auto tool choice with
  the Qwen parsers works there on vLLM 0.28).
- `"chat"`: Chat Completions (`POST /v1/chat/completions`), the most battle-tested vLLM path. Only Codex releases from
  before February 2026 still speak it.

So: use `responses` with a current Codex. If your vLLM build mishandles `/v1/responses` for this model (tool calls
missing, reasoning items rejected), either run a Codex release that still has `wire_api = "chat"`, or put a proxy that
translates Responses to Chat Completions in front of vLLM.

## Configuration

`~/.codex/config.toml` (`%USERPROFILE%\.codex\config.toml` on Windows):

```toml
model = "cybus"
model_provider = "cybus"
model_context_window = 65536             # what vLLM serves (CYBUS_MAX_MODEL_LEN), so Codex compacts in time
model_auto_compact_token_limit = 52000   # leave room for Codex's own prompt, tools and the reply

[model_providers.cybus]
name = "Cybus (vLLM)"
base_url = "http://<vllm-host>:8000/v1"
env_key = "CYBUS_API_KEY"                # Codex reads the key from this environment variable; never write it here
wire_api = "responses"                   # "chat" only on Codex releases before February 2026
stream_idle_timeout_ms = 600000          # a 27B model can think or prefill for a long time before the first token
request_max_retries = 4
```

```bash
export CYBUS_API_KEY=...                 # the key vLLM was started with
codex                                    # or: codex -c model_provider=cybus -m cybus
```

To keep your normal Codex model as the default, put the `model*` lines in a profile file instead,
`$CODEX_HOME/cybus.config.toml` (next to `config.toml`), and run `codex --profile cybus`. Older Codex releases used a
`[profiles.cybus]` table inside `config.toml` for the same thing. `-c key=value` overrides any key for one run.

With a LoRA the adapter is `cybus` and the base model is `cybus-base` (`-m cybus-base` to compare them).

## Tool-calling requirements

Codex's agent is nothing but tool calls (running commands, applying patches, updating its plan), and it always
streams. Tool use only works if:

1. vLLM runs with `--enable-auto-tool-choice` (the launch script always sets it) and **a tool parser that matches
   what the model writes**. Qwen3.8 writes Qwen-XML calls, so serve with `CYBUS_TOOL_PARSER=qwen3_xml`. With a
   mismatched parser, streamed calls are dropped and Codex only prints text and never acts. Verify with the streaming
   check in README.md ("Check the server").
2. Tool choice stays `auto`: vLLM's Qwen parsers ignore forced (`required` / named) tool choice.
3. The context fits: Codex's instructions and tool definitions take several thousand tokens every turn. Set
   `model_context_window` to the served window. A longer window (`CYBUS_MAX_MODEL_LEN=131072`) helps on long tasks.
4. Thinking is under control. Qwen3.8 thinks by default at the highest effort, which makes every step slow, and Codex
   has no way to send template kwargs. To turn it off, start vLLM with
   `CYBUS_CHAT_TEMPLATE_KWARGS='{"enable_thinking": false}'` (vLLM applies server-wide template defaults to
   `/v1/responses` too). Keep it on if the adapter was trained to think. If a vLLM version rejects the reasoning
   settings Codex sends, set `model_supports_reasoning_summaries = false`.

Images you attach in Codex reach Qwen3.8's vision tower (up to `CYBUS_MM_LIMIT`, 8 by default).

## The taste and craft tools in Codex

```toml
[mcp_servers.cybus_taste]
command = "python"
args = ["-m", "mcp_server.server"]
cwd = "/path/to/cybus-harness"           # the harness checkout
env = { HARNESS_JUDGE_BASE_URL = "http://<vllm-host>:8000/v1", HARNESS_JUDGE_MODEL = "cybus" }
env_vars = ["HARNESS_JUDGE_API_KEY"]     # forwarded from your shell: the key stays out of this file
tool_timeout_sec = 300                   # a judge call is a vision-model round trip (the default is 60 s)
startup_timeout_sec = 30
```

Taste tools: `capture` (Studio screenshot; read-only), `judge` (rubric verdict with fixes), `pairwise`,
`style_guide_template`, `rubric`. `python -m mcp_server.server --http --port 8765` serves the same tools over
streamable HTTP at `http://127.0.0.1:8765/mcp` for `mcp_servers.<id>.url`.

### Craft tools

The same server gives Codex the harness's builder pipeline, with Cybus or any other model: the runtime kit, style
tokens, painted textures, animation clips and sound, all without uploads. The craft tools need neither the judge model
nor Studio; they only write files in your project. Pass `project_root` as an **absolute** path: the server runs in the
`cwd` above (the harness checkout), so relative paths are refused. The project is laid out Rojo-style: scripts live in
`src/<Service>/...` (`.luau` ModuleScript, `.server.luau` Script, `.client.luau` LocalScript), and you sync `src/` into
Studio the way you already do. Every write stays inside `project_root`: names or links (`..`, symlinks, junctions)
that lead out of it are refused.

- `install_kit(project_root, overwrite=false)`: writes the runtime kit (`ReplicatedStorage.Kit`) and its boot scripts,
  plus empty `AssetMap`, `TexPacks/Index` and `ClipPack` modules if missing; returns the file list and the kit's API.
  Safe to repeat: identical files are skipped, files you changed are kept unless `overwrite=true`, nothing is deleted.
- `generate_tokens(project_root, style)`: the style guide as JSON (the harness's STYLE schema; the object, or the path
  of a `.json` file) -> `src/ReplicatedStorage/Shared/Tokens.luau`, with a note for every value it had to repair.
- `paint_texture(project_root, name, spec)`: validates and renders a texture spec (panels, 9-slice buttons, glows,
  icons, particle textures), saves `art/<name>.png`, packs it into `ReplicatedStorage.Shared.TexPacks`, and returns the
  preview image and the `Kit.Textures` call that shows it. `list_textures(project_root)` lists them.
- `author_clip(project_root, name, spec)`: validates a keyframe clip, packs it into `ReplicatedStorage.Shared.ClipPack`,
  and returns a stick-figure contact sheet (also saved to `art/clips/<name>.png`) and the `Kit.Anim` code that plays
  it. `list_clips(project_root)` lists them.
- `search_audio(query, kind="sfx", limit=8)`: public Roblox Creator Store sounds the game can play by id, no upload;
  cached under `HARNESS_CAPTURE_DIR`.
- `playbook(name)`: the harness's references (`texture_spec`, `animation_spec`, `vfx_camera_spec`, `roblox_craft`,
  `style_guide`, `plan`, `rubric_<aspect>`); with no name it lists what exists.

The previews come back as MCP image content. The texture and the clip sheet are also on disk (`art/<name>.png`,
`art/clips/<name>.png`) for clients that do not pass tool images to the model. A spec with problems comes back as a
tool error that lists all of them.

Recommended loop:

1. `install_kit(project_root)` once, and build on the kit API it returns.
2. `style_guide_template()`, decide the style with concrete values, then `generate_tokens(project_root, style)`.
3. Build scripts on the kit and the tokens; use `paint_texture`, `author_clip` and `search_audio` for art, animation and sound.
4. Sync into Studio, then `capture()` and `judge(aspect, intent, capture=true, style=...)`.
5. Fix every blocker and major the verdict lists, repaint or re-author, and judge again until `passed`.

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

## The taste tools in Codex

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

Tools: `capture` (Studio screenshot; read-only), `judge` (rubric verdict with fixes), `pairwise`,
`style_guide_template`, `rubric`. `python -m mcp_server.server --http --port 8765` serves the same tools over
streamable HTTP at `http://127.0.0.1:8765/mcp` for `mcp_servers.<id>.url`.

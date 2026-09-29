# Serving Cybus

Cybus is `Qwen/Qwen3.8-27B` (class `Qwen3_5ForConditionalGeneration`: multimodal, 64 layers of which every fourth is
full attention and the rest Gated-DeltaNet linear attention) plus an optional Cybus LoRA (rank 64). bf16 weights are
~54 GB, so it runs on one 80-96 GB GPU. `vllm_cybus.sh` serves it as an OpenAI-compatible endpoint; everything else in
this folder sits on top of that endpoint:

| Consumer | How it reaches Cybus |
| --- | --- |
| this harness | `HARNESS_DEFAULT_BASE_URL=http://<host>:8000/v1`, `HARNESS_DEFAULT_MODEL=cybus`, key in `HARNESS_DEFAULT_API_KEY` |
| Claude Code | through `anthropic_gateway.py` (Anthropic Messages API -> OpenAI); see [claude_code.md](claude_code.md) |
| Codex CLI | directly, as a custom model provider; see [codex.md](codex.md) |
| taste tools in Codex / Claude Code | `mcp_server/server.py` (capture, judge, pairwise, style guide, rubrics) |

## Start the server

On the owner's machines GPUs are rented through landlord: rent an apartment first (`rent_apartment`, with a
purpose note), launch with the `env` it returns (`CUDA_VISIBLE_DEVICES`, `LANDLORD_LEASE_ID`), and set
`CYBUS_GPU_UTIL` to the lease's VRAM divided by the card's (vLLM takes that fraction of the whole card). Run vLLM
inside WSL on Windows hosts, and check a card's real usage there (`wsl -d <distro> -e /usr/lib/wsl/lib/nvidia-smi`).

```bash
export CYBUS_API_KEY=...      # from your secret store; clients send it as a bearer token. Never commit it.
export HF_TOKEN=...           # only when the adapter repo is private
CYBUS_LORA=<hf-org>/<cybus-adapter> CYBUS_TOOL_PARSER=qwen3_xml bash serve/vllm_cybus.sh
CYBUS_DRY_RUN=1 bash serve/vllm_cybus.sh      # print the vllm command without starting anything
```

**Speed.** Qwen3.8 ships a multi-token-prediction (MTP) layer; the script drafts with it by default (`CYBUS_SPEC_TOKENS=2`). Measured on one RTX PRO 6000 Max-Q (bf16): single-stream decode 25 -> 50 tok/s, mean acceptance ~2.4 tokens. Thinking multiplies output ~5-8x on coding tasks; the harness keeps it on for planning roles and off for builders and the judge via `HARNESS_<ROLE>_EXTRA='{"chat_template_kwargs":{"enable_thinking":false}}'`.

The first start is slow: torch.compile (~5 min), multimodal profiling and CUDA graph capture add up to ~10 minutes
before `Application startup complete`. The compile cache under `~/.cache/vllm` makes later starts faster.
`CYBUS_EXTRA_ARGS=--enforce-eager` skips compilation and graphs (about a minute to start) at the cost of slower
decoding. Poll `curl http://<host>:8000/health` rather than guessing.

Settings are environment variables (full list in the script header):

| Variable | Default | Notes |
| --- | --- | --- |
| `CYBUS_MODEL` | `Qwen/Qwen3.8-27B` | HF id or local dir (a merged checkpoint works too) |
| `CYBUS_LORA` | none | local dir or HF repo id; served as `cybus`, the base then as `cybus-base` |
| `CYBUS_SERVED_NAME` | `cybus` | the model name clients use |
| `CYBUS_HOST` / `CYBUS_PORT` | `0.0.0.0` / `8000` | |
| `CYBUS_API_KEY` | none | exported to vLLM as `VLLM_API_KEY`, never put on the command line (`ps` shows argv) |
| `CYBUS_MAX_MODEL_LEN` | `65536` | 131072 for Claude Code (see claude_code.md); the model supports 262144 |
| `CYBUS_MAX_NUM_SEQS` | `16` | see below |
| `CYBUS_GPU_UTIL` | `0.9` | fraction of the card's memory |
| `CYBUS_MAX_LORA_RANK` | `64` | must be >= the adapter's rank (vLLM's default 16 rejects rank-64 adapters) |
| `CYBUS_TOOL_PARSER` | `qwen3_xml` | see "Picking the tool-call parser": `qwen3_xml` is Qwen3.8's native format |
| `CYBUS_REASONING_PARSER` | `qwen3` | `none` to disable; see "Thinking" |
| `CYBUS_MM_LIMIT` | `{"image": 8}` | images per prompt |
| `CYBUS_CHAT_TEMPLATE_KWARGS` | none | server-wide template kwargs, e.g. `{"enable_thinking": false}` |
| `CYBUS_EXTRA_ARGS` | none | appended verbatim, e.g. `--enforce-eager` |

Sizing notes:
- `--max-num-seqs 16`: a hybrid model gives every running sequence a fixed-size Mamba/DeltaNet state block, and
  vLLM's default sequence count (1024 on vLLM 0.27) is more than fit, which aborts startup during CUDA graph capture.
  Lower it if startup still fails; raise it only with memory to spare.
- KV cache: 16 full-attention layers x 4 KV heads x 256 dims x K+V x 2 bytes = 64 KiB per token, so a full 64k-token
  sequence holds 4 GiB of KV (the linear-attention layers keep a constant-size state instead). After ~54 GB of
  weights, an 80 GB card at 0.9 leaves room for a few long sequences; a 96 GB card for 131072-token contexts.
- Images cost about one token per 32x32 pixels after resizing (a 1920x1080 screenshot is ~2k tokens).
- Prefix caching matters for Claude Code and Codex, which resend a ~20k-token system prompt and tool list every turn.
  Whether vLLM enables it for hybrid models depends on the version: check the startup log, and pass the flag through
  `CYBUS_EXTRA_ARGS` if your version supports it for this architecture.

## Picking the tool-call parser

vLLM only returns structured `tool_calls` if its parser understands what the model writes. Qwen3.8-27B's own chat
template tells the model to write Qwen-XML calls:

```
<tool_call>
<function=read_file>
<parameter=path>
src/main.lua
</parameter>
</function>
</tool_call>
```

and Qwen3.8 does write exactly that in practice. The parsers:

| Parser | Reads | Use when |
| --- | --- | --- |
| `qwen3_xml` | the XML above, with an incremental XML parser | the model writes XML (base Qwen3.8, adapters trained on its template). Preferred: sturdier when streaming and on long inputs |
| `qwen3_coder` | the same XML grammar, older regex parser | fallback if your vLLM lacks `qwen3_xml` |
| `hermes` | `<tool_call>{"name": ..., "arguments": {...}}</tool_call>` | the adapter was trained to emit hermes JSON |

With a parser that does not match, non-streaming responses carry the raw markup in `content` (the harness's
`harness/llm.py` and the gateway parse it back), but **streaming responses lose the call**: vLLM's hermes parser
swallows `<tool_call>` blocks it cannot decode. Codex and Claude Code stream, so they need the matching parser. The
script defaults to `qwen3_xml` (Qwen3.8's native format) and prints a note if hermes is chosen for an XML template.

How to decide:
1. Read the template: `chat_template.jinja` (or `chat_template` in `tokenizer_config.json`) of the base model, or of
   the adapter if it ships one. `<function=` means XML; a JSON `"arguments"` example means hermes.
2. Check the running server (below): `tool_calls` filled in = right parser; `<tool_call>` inside `content`, or an
   empty streamed reply, = wrong parser.

Known vLLM limits with the Qwen parsers: `tool_choice: "required"` or a named function is ignored (auto works;
vLLM issue 54808, seen on 0.28); a call the model writes before closing `</think>` ends up in the reasoning field and
is dropped (issue 39056). The gateway recovers that last case when the reasoning ends with the call.

## Thinking

The template opens a `<think>` block unless `enable_thinking` is false (and defaults to `reasoning_effort` xhigh).
`--reasoning-parser qwen3` (the script's default) moves the thinking into the response's reasoning field so `content`
stays clean; the gateway shows it to Claude Code as thinking blocks. Turning thinking off makes agent loops much
faster:
- server-wide (the only way for Codex): `CYBUS_CHAT_TEMPLATE_KWARGS='{"enable_thinking": false}'`
- per request, OpenAI clients: `extra_body={"chat_template_kwargs": {"enable_thinking": false}}`
- through the gateway: `GATEWAY_EXTRA_BODY='{"chat_template_kwargs": {"enable_thinking": false}}'`

`reasoning_effort` (`low`, `medium`, `xhigh`) is also a template kwarg. Match whatever the Cybus adapter was trained
with.

## Check the server

```bash
H="Authorization: Bearer $CYBUS_API_KEY"
curl -s http://<host>:8000/v1/models -H "$H"
curl -s http://<host>:8000/v1/chat/completions -H "$H" -H 'content-type: application/json' -d '{
  "model": "cybus", "max_tokens": 1024,
  "messages": [{"role": "user", "content": "Open src/main.lua"}],
  "tools": [{"type": "function", "function": {"name": "read_file", "description": "Read a file",
             "parameters": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]}}}]}'
```

Expect `choices[0].message.tool_calls[0].function.name == "read_file"`. Repeat with `"stream": true` and look for
`"tool_calls"` in the deltas: that is the path Codex and Claude Code use. For vision, send a user message with an
`{"type": "image_url", "image_url": {"url": "data:image/png;base64,..."}}` part.

## LoRA notes

- The adapter applies to the language model; `--max-lora-rank` must be at least its rank.
- LoRA adds some decode overhead. For the fastest serving (or if your vLLM refuses LoRA for this architecture), merge
  the adapter into the base weights (PEFT `merge_and_unload`), point `CYBUS_MODEL` at the merged directory and leave
  `CYBUS_LORA` empty: the merged model is then served as `cybus` directly.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| startup aborts in CUDA graph capture / mentions Mamba cache blocks | lower `CYBUS_MAX_NUM_SEQS` |
| out of memory at startup | lower `CYBUS_MAX_MODEL_LEN` or `CYBUS_MAX_NUM_SEQS`, or raise `CYBUS_GPU_UTIL` within your lease |
| `"auto" tool choice requires --enable-auto-tool-choice` | the client reached another server; this script always sets it |
| `At most 8 image(s) may be provided` | raise `CYBUS_MM_LIMIT`; the gateway already drops the oldest images |
| `maximum context length is ... tokens` | the client's `max_tokens` plus prompt exceed the window; the gateway clamps `max_tokens` for Claude Code |
| CUDA `unknown error` on the first allocation under WSL | do not set `PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True` in WSL |
| tool calls appear as text, or streamed replies come back empty | wrong tool parser (see above) |

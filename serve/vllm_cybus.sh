#!/usr/bin/env bash
# Serve Cybus (Qwen3.8-27B + optional Cybus LoRA) as an OpenAI-compatible endpoint with vLLM.
#
#   bash serve/vllm_cybus.sh                                       # base model as "cybus"
#   CYBUS_LORA=/path/or/hf-org/adapter bash serve/vllm_cybus.sh    # adapter as "cybus", base as "cybus-base"
#   CYBUS_DRY_RUN=1 bash serve/vllm_cybus.sh                       # print the command, start nothing
#
# Clients: base URL http://<host>:$CYBUS_PORT/v1, model "cybus", key = $CYBUS_API_KEY. See serve/README.md.
# Needs one 80-96 GB GPU (bf16 weights ~54 GB). On the owner's machines, rent a landlord apartment first and run
# this with the env it returns (CUDA_VISIBLE_DEVICES, LANDLORD_LEASE_ID); size CYBUS_GPU_UTIL to the lease.
# The first start is slow (torch.compile + CUDA graph capture + multimodal profiling: ~5-10 min); later starts
# reuse the compile cache in ~/.cache/vllm. CYBUS_EXTRA_ARGS=--enforce-eager starts in about a minute but decodes
# slower.
#
# Settings (environment):
#   CYBUS_MODEL           base checkpoint (HF id or local dir)           Qwen/Qwen3.8-27B
#   CYBUS_LORA            LoRA adapter (local dir or HF repo id)         (none; private repos need HF_TOKEN in env)
#   CYBUS_SERVED_NAME     model name clients use                         cybus
#   CYBUS_HOST            bind address                                   0.0.0.0
#   CYBUS_PORT            port                                           8000
#   CYBUS_API_KEY         required bearer key (exported as VLLM_API_KEY, never put on the command line)
#   CYBUS_MAX_MODEL_LEN   context window                                 65536  (131072 for Claude Code, see README)
#   CYBUS_MAX_NUM_SEQS    concurrent sequences                           16     (hybrid-model Mamba cache limit)
#   CYBUS_GPU_UTIL        fraction of GPU memory vLLM may take           0.9
#   CYBUS_MAX_LORA_RANK   >= the adapter's rank                          64
#   CYBUS_TOOL_PARSER     qwen3_xml | hermes | qwen3_coder            qwen3_xml (see README: how to pick)
#   CYBUS_REASONING_PARSER  qwen3, or none                               qwen3  (the template opens <think>)
#   CYBUS_MM_LIMIT        images per prompt (JSON)                       {"image": 8}
#   CYBUS_CHAT_TEMPLATE_KWARGS  server-wide template kwargs (JSON), e.g. {"enable_thinking": false}
#   CYBUS_EXTRA_ARGS      extra vLLM flags, appended as-is               (none)
#   CYBUS_SPEC_TOKENS     MTP speculative tokens (0 = off)               2  (Qwen3.8 ships an MTP head: ~2x decode)
#   CYBUS_VLLM            vllm executable                                vllm
set -euo pipefail

MODEL="${CYBUS_MODEL:-Qwen/Qwen3.8-27B}"
LORA="${CYBUS_LORA:-}"
NAME="${CYBUS_SERVED_NAME:-cybus}"
HOST="${CYBUS_HOST:-0.0.0.0}"
PORT="${CYBUS_PORT:-8000}"
MAX_LEN="${CYBUS_MAX_MODEL_LEN:-65536}"
MAX_SEQS="${CYBUS_MAX_NUM_SEQS:-16}"
GPU_UTIL="${CYBUS_GPU_UTIL:-0.9}"
LORA_RANK="${CYBUS_MAX_LORA_RANK:-64}"
TOOL_PARSER="${CYBUS_TOOL_PARSER:-qwen3_xml}"
REASONING_PARSER="${CYBUS_REASONING_PARSER:-qwen3}"
DEFAULT_MM_LIMIT='{"image": 8}'
MM_LIMIT="${CYBUS_MM_LIMIT:-$DEFAULT_MM_LIMIT}"
CHAT_KWARGS="${CYBUS_CHAT_TEMPLATE_KWARGS:-}"
EXTRA="${CYBUS_EXTRA_ARGS:-}"
SPEC_TOKENS="${CYBUS_SPEC_TOKENS:-2}"
VLLM="${CYBUS_VLLM:-vllm}"

# The key travels in the environment: vLLM reads VLLM_API_KEY, and argv is visible to every user via ps.
if [ -n "${CYBUS_API_KEY:-}" ]; then
  export VLLM_API_KEY="$CYBUS_API_KEY"
elif [ -z "${VLLM_API_KEY:-}" ]; then
  echo "warning: CYBUS_API_KEY is not set: anyone who can reach $HOST:$PORT can use this server" >&2
fi

args=(serve "$MODEL" --host "$HOST" --port "$PORT")
if [ -n "$LORA" ]; then
  # The adapter takes the public name; the base stays reachable under <name>-base (names must differ).
  args+=(--served-model-name "${NAME}-base"
         --enable-lora --lora-modules "${NAME}=${LORA}" --max-lora-rank "$LORA_RANK")
else
  args+=(--served-model-name "$NAME")
fi
# --max-num-seqs: hybrid attention/linear-attention models give every running sequence a Mamba-state cache block,
# and vLLM's default sequence count exceeds the blocks that fit, which aborts startup (CUDA graph capture).
args+=(--max-model-len "$MAX_LEN" --max-num-seqs "$MAX_SEQS" --gpu-memory-utilization "$GPU_UTIL"
       --limit-mm-per-prompt "$MM_LIMIT"
       --enable-auto-tool-choice --tool-call-parser "$TOOL_PARSER")
if [ -n "$REASONING_PARSER" ] && [ "$REASONING_PARSER" != "none" ]; then
  args+=(--reasoning-parser "$REASONING_PARSER")
fi
# Qwen3.8 checkpoints carry one MTP layer: vLLM drafts with it (measured on an RTX PRO 6000: mean acceptance
# ~2.4 tokens at 2 speculative tokens, single-stream decode 25 -> 50 tok/s). CYBUS_SPEC_TOKENS=0 turns it off.
if [ "$SPEC_TOKENS" != "0" ] && [[ "$EXTRA" != *speculative-config* ]]; then
  args+=(--speculative-config "{\"method\":\"mtp\",\"num_speculative_tokens\":$SPEC_TOKENS}")
fi
if [ -n "$CHAT_KWARGS" ]; then
  args+=(--default-chat-template-kwargs "$CHAT_KWARGS")
fi
if [ -n "$EXTRA" ]; then
  # shellcheck disable=SC2206  # word splitting is intended: several flags in one variable
  args+=($EXTRA)
fi

# Qwen3.8's own chat template asks for Qwen-XML tool calls (<tool_call><function=...>); the hermes parser only
# reads JSON ones. Warn when the parser and the template disagree (serve/README.md: picking the tool parser).
template=""
if [ -d "$MODEL" ]; then
  template="$MODEL/chat_template.jinja"
else
  hub="${HF_HUB_CACHE:-${HF_HOME:-$HOME/.cache/huggingface}/hub}"
  for f in "$hub/models--${MODEL//\//--}"/snapshots/*/chat_template.jinja; do template="$f"; break; done
fi
if [ -f "$template" ] && [ "$TOOL_PARSER" = "hermes" ] && grep -q '<function=' "$template"; then
  echo "note: $MODEL's chat template asks for Qwen-XML tool calls. The hermes parser returns those as plain text" \
       "(non-streaming) or drops them (streaming): Codex and Claude Code need CYBUS_TOOL_PARSER=qwen3_xml unless" \
       "the adapter was trained to emit hermes JSON. See serve/README.md." >&2
fi

if [ -n "${CYBUS_DRY_RUN:-}" ]; then
  printf '%q ' "$VLLM" "${args[@]}"
  echo
  exit 0
fi
echo "starting vLLM: $MODEL${LORA:+ + LoRA $LORA} as '$NAME' on $HOST:$PORT (first start compiles: several minutes)" >&2
exec "$VLLM" "${args[@]}"

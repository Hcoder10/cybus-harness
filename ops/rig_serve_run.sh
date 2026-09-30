#!/usr/bin/env bash
# Cybus serving on squaredcube-1 GPU 1 under landlord lease apt_9df354aa (cybus-harness).
set -uo pipefail
export CUDA_VISIBLE_DEVICES=1 LANDLORD_LEASE_ID=apt_9df354aa LANDLORD_BUILDING=squaredcube-1 LANDLORD_VRAM_GB=90.0 LANDLORD_MAX_PCT=100
OUT=/mnt/c/Users/sarta/cybus_serve
mkdir -p "$OUT/cache"
# The WSL root disk is nearly full: every cache vLLM, torch and triton write goes to C: instead.
export VLLM_CACHE_ROOT="$OUT/cache/vllm" TORCHINDUCTOR_CACHE_DIR="$OUT/cache/inductor" TRITON_CACHE_DIR="$OUT/cache/triton"
export CUDA_CACHE_PATH="$OUT/cache/nv" HF_HOME=/home/sarta/.cache/huggingface HF_HUB_OFFLINE=1
source /home/sarta/cybus-rl/.venv/bin/activate
export CYBUS_API_KEY="$(cat /home/sarta/.cybus_serve_key)"
export CYBUS_MODEL=/home/sarta/.cache/huggingface/hub/models--Qwen--Qwen3.8-27B/snapshots/1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0
export CYBUS_SERVED_NAME=cybus CYBUS_PORT=8000 CYBUS_MAX_MODEL_LEN=98304 CYBUS_MAX_NUM_SEQS=32 CYBUS_GPU_UTIL=0.92
export CYBUS_EXTRA_ARGS='--enable-prefix-caching --mamba-cache-mode align --kv-cache-dtype fp8'
echo "=== start $(date -Is)" >> "$OUT/vllm.log"
exec bash /home/sarta/cybus-serve/vllm_cybus.sh >> "$OUT/vllm.log" 2>&1

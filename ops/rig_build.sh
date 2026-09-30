#!/usr/bin/env bash
# usage: rig_build.sh <run name> <idea id> [extra build_game args]
set -uo pipefail
cd /home/sarta/cybus-harness
export HARNESS_DEFAULT_BASE_URL=http://127.0.0.1:8000/v1 HARNESS_DEFAULT_MODEL=cybus
export HARNESS_DEFAULT_API_KEY="$(cat /home/sarta/.cybus_serve_key)"
export HARNESS_BUILDER_EXTRA='{"chat_template_kwargs":{"enable_thinking":false}}'
export HARNESS_JUDGE_EXTRA='{"chat_template_kwargs":{"enable_thinking":false}}'
export HARNESS_REVISER_EXTRA='{"chat_template_kwargs":{"enable_thinking":false}}'
export HARNESS_ARCHITECT_EXTRA='{"chat_template_kwargs":{"enable_thinking":false}}'
export HARNESS_ARCHITECT_MAX_TOKENS=32768
export HARNESS_CONCURRENCY="${HARNESS_CONCURRENCY:-3}"
export HARNESS_CONTEXT_BUDGET="${HARNESS_CONTEXT_BUDGET:-56000}"
export HARNESS_LUAU_ANALYZE=/home/sarta/simbf/tools/luau/luau-analyze PYTHONUNBUFFERED=1
# wait (up to 15 min) for the model server: a build may be launched while vLLM restarts
for i in $(seq 1 90); do
  curl -s -o /dev/null -m 5 -H "Authorization: Bearer $HARNESS_DEFAULT_API_KEY" http://127.0.0.1:8000/v1/models && break
  sleep 10
done
RUN=/mnt/c/Users/sarta/cybus_runs/$1
IDEA=$2
shift 2
mkdir -p "$RUN"
echo "=== build start $(date -Is) idea=$IDEA args=$*" >> "$RUN/run.log"
/home/sarta/cybus-rl/.venv/bin/python -m harness.workflows.build_game --idea "bench/ideas.yaml#$IDEA" --run-dir "$RUN" "$@" >> "$RUN/run.log" 2>&1
echo "exit=$?" >> "$RUN/run.log"

#!/usr/bin/env bash
# Start (or resume) builds as slots free up: never two processes on one run directory, never more than MAX builds on
# the model server (4+ builds x 3 agents saturate its KV cache). A resume of a finished run skips built items and
# only runs the gates (syntax, wiring) and the report. Entries: <run>=<idea>. Runs as a schtask so it outlives ssh.
MAX=${MAX:-3}
LOG=/mnt/c/Users/sarta/cybus_runs/queue_b1.log
count() { pgrep -fc "cybus-rl/.venv/bin/python -m harness.workflows.build_game" || true; }
busy() { pgrep -f "harness.workflows.build_game .*cybus_runs/$1( |$)" >/dev/null; }
for entry in "$@"; do
  run=${entry%%=*}
  idea=${entry#*=}
  while busy "$run" || [ "$(count)" -ge "$MAX" ]; do sleep 60; done
  echo "$(date -Is) start $run ($idea), running=$(count)" >> "$LOG"
  bash /home/sarta/cybus-harness/rig_build.sh "$run" "$idea" --no-studio &
  sleep 120
done
wait
echo "$(date -Is) queue done" >> "$LOG"

#!/usr/bin/env bash
# Wiring problems (and harness stubs) in every run's workspace, game files only.
cd /home/sarta/cybus-harness || exit 1
for r in fishing_nostudio_1 canyon_rally_b1 observatory_escape_b1 wildfire_command_b1 rhythm_obby_b1 sky_minigolf_b1; do
  W=/mnt/c/Users/sarta/cybus_runs/$r/workspace
  [ -d "$W" ] || { echo "$r: no workspace"; continue; }
  n=$(/home/sarta/cybus-rl/.venv/bin/python -m harness.wiring "$W" | tail -1)
  s=$(grep -rl "stub created by the harness" "$W/src" | wc -l)
  echo "$r: $n; stubs=$s"
done
if [ -n "$1" ]; then /home/sarta/cybus-rl/.venv/bin/python -m harness.wiring "/mnt/c/Users/sarta/cybus_runs/$1/workspace" | cut -c1-260; fi

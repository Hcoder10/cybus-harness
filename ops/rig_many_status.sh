#!/usr/bin/env bash
# One line per run, counting only the latest (re)start: phase, done/failed agents, exit status.
for r in fishing_nostudio_1 canyon_rally_b1 observatory_escape_b1 wildfire_command_b1 rhythm_obby_b1 sky_minigolf_b1; do
  L=/mnt/c/Users/sarta/cybus_runs/$r/run.log
  [ -f "$L" ] || { echo "$r: not started"; continue; }
  start=$(grep -n "=== build start" "$L" | tail -1 | cut -d: -f1)
  T=$(tail -n +"${start:-1}" "$L")
  phase=$(echo "$T" | grep -oE '== [A-Za-z]+ ==' | tail -1)
  done_n=$(echo "$T" | grep -c ' done in ')
  fail_n=$(echo "$T" | grep -c ' FAILED ')
  skip_n=$(echo "$T" | grep -c 'already built')
  ex=$(echo "$T" | grep -oE 'exit=[0-9]+' | tail -1)
  echo "$r: ${phase:-starting} done=$done_n failed=$fail_n skipped=$skip_n ${ex}"
done

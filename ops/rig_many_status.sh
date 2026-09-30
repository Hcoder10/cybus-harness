#!/usr/bin/env bash
# One line per run (b1 dev runs, then b2 benchmark runs once they exist), counting only the latest (re)start:
# phase, done/failed agents, runtime problems left in the report, exit status. Then the queue log's last line.
for r in fishing_nostudio_1 canyon_rally_b1 observatory_escape_b1 wildfire_command_b1 rhythm_obby_b1 sky_minigolf_b1 \
         lakeside_fishing_b2 canyon_rally_b2 observatory_escape_b2 wildfire_command_b2 rhythm_obby_b2 sky_minigolf_b2; do
  L=/mnt/c/Users/sarta/cybus_runs/$r/run.log
  [ -f "$L" ] || continue
  start=$(grep -n "=== build start" "$L" | tail -1 | cut -d: -f1)
  T=$(tail -n +"${start:-1}" "$L")
  phase=$(echo "$T" | grep -oE '== [A-Za-z]+ ==' | tail -1)
  done_n=$(echo "$T" | grep -c ' done in ')
  fail_n=$(echo "$T" | grep -c ' FAILED ')
  left=$(echo "$T" | grep -oE 'report: [0-9]+ runtime problem\(s\), [0-9]+ stub' | tail -1)
  ex=$(echo "$T" | grep -oE 'exit=[0-9]+' | tail -1)
  echo "$r: ${phase:-starting} done=$done_n failed=$fail_n ${left} ${ex}"
done
echo "queue: $(tail -1 /mnt/c/Users/sarta/cybus_runs/queue_b1.log)"

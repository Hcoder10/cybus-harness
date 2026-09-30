#!/usr/bin/env bash
# The clean benchmark build: every idea from its pitch alone (id, title, pitch) on the current harness, no Studio.
# Starts once the b1 development queues are done (their `wait` ends with their last build), 3 builds at a time.
while pgrep -f "rig_queue2.sh .*_b1=" >/dev/null; do sleep 120; done
echo "$(date -Is) b1 queues done; starting b2" >> /mnt/c/Users/sarta/cybus_runs/queue_b1.log
exec bash /home/sarta/rig_queue2.sh lakeside_fishing_b2=lakeside_fishing canyon_rally_b2=canyon_rally \
  observatory_escape_b2=observatory_escape wildfire_command_b2=wildfire_command rhythm_obby_b2=rhythm_obby \
  sky_minigolf_b2=sky_minigolf

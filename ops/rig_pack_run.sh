#!/usr/bin/env bash
# Pack a run (minus agent transcripts) to the Windows side for scp: rig_pack_run.sh <run>
R=${1:-fishing_nostudio_1}
cd /mnt/c/Users/sarta/cybus_runs || exit 1
du -sh "$R" "$R"/agents "$R"/art 2>/dev/null
tar czf "/mnt/c/Users/sarta/rig_tmp/${R}.tgz" --exclude="$R/agents" "$R"
ls -la "/mnt/c/Users/sarta/rig_tmp/${R}.tgz"
md5sum "/mnt/c/Users/sarta/rig_tmp/${R}.tgz"

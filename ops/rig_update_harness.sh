#!/usr/bin/env bash
# Replace the rig's harness code with the newly copied archive; keep rig_build.sh and every run directory.
set -e
H=/home/sarta/cybus-harness
NEW=/home/sarta/cybus-harness.new
mkdir -p "$NEW"
tar xzf /mnt/c/Users/sarta/rig_tmp/harness.tgz -C "$NEW"
cp "$H/rig_build.sh" "$NEW/rig_build.sh"
mv "$H" "/home/sarta/cybus-harness.old.$(date +%s)"
mv "$NEW" "$H"
cd "$H" && /home/sarta/cybus-rl/.venv/bin/python -c "import harness.workflows.build_game as b; print('import ok', hasattr(b, 'arch_problems'))"
echo update-ok

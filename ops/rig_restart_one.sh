#!/usr/bin/env bash
# Stop one run's build process (only that run's; nothing else) so it can resume on new harness code.
R=${1:?run name}
P=$(pgrep -f "harness.workflows.build_game .*cybus_runs/$R( |$)")
echo "stopping $R: ${P:-not running}"
[ -n "$P" ] && kill $P
sleep 5
pgrep -f "harness.workflows.build_game .*cybus_runs/$R( |$)" && echo "STILL RUNNING" || echo "stopped"

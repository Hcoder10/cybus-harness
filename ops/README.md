# ops: how the development builds run

These scripts are the owner's own setup, not part of what ships: Cybus served with vLLM on the squaredcube-1 rig
(WSL, GPU 1, under a landlord lease), builds without Studio on the rig, and Studio passes on the laptop that has
Studio. Paths and host names are theirs.

| script | where | what |
| --- | --- | --- |
| `rig_serve_run.sh` | rig WSL `~/cybus-serve/run.sh` | vLLM for Cybus (the lease env, the cache on /mnt/c) |
| `rig_build.sh` | rig WSL `~/cybus-harness/rig_build.sh` | one build: role env, waits for vLLM, logs to the run dir |
| `rig_queue2.sh` | rig WSL `~/rig_queue2.sh` | starts or resumes builds as slots free up (at most 3 on one GPU, never two on a run) |
| `rig_update_harness.sh` | rig WSL `~/rig_update_harness.sh` | installs a `git archive` of this repo copied to `C:\Users\sarta\rig_tmp\harness.tgz` |
| `rig_pack_run.sh` | rig WSL `~/rig_pack_run.sh` | packs a run (without agent transcripts) for copying off the rig; prints its md5 |
| `rig_final_place.py` | rig WSL | builds a finished run's `place/final.rbxlx` with rojo (`~/bin/rojo`) |
| `rig_many_status.sh`, `rig_wiring_all.sh` | rig WSL | one status line per run; wiring problems and stubs per run |
| `studio_pass.ps1` | laptop | pulls a rig-built run, opens the tunnel and the bridge, runs the doctor, then the Studio pass with `--evidence` |
| `rig_queue_b2.sh` | rig WSL `~/rig_queue_b2.sh` | the clean benchmark builds (pitch only), after the b1 queues finish |
| `rig_restart_one.sh` | rig WSL | stops one run's build process (only that run) so it can resume on new code |
| `rig_runtime_left.py`, `rig_api_scan.py` | rig WSL | runtime problems a report says are left; the API check over every run |
| `rig_install_rojo.sh`, `rig_install_lsp.sh` | rig WSL | rojo 7.6.1 and luau-lsp 1.70.1 + Roblox definitions into `~/bin` |

Long jobs on the rig run as elevated scheduled tasks (`schtasks ... /rl highest`): anything started over ssh dies
with the ssh session. Stage scripts by file (scp or base64), never through nested quotes over ssh.

Resuming a run is always safe: plan, style and architecture are pinned artifacts, built items are skipped by
file digest, and the syntax and wiring gates run on every item again.

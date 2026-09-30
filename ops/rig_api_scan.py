"""Roblox API misuse per run (game files only), with a sample of messages: rig_api_scan.py [run ...]."""
import asyncio
import sys
import time
from pathlib import Path

sys.path.insert(0, "/home/sarta/cybus-harness")
from harness.tools.typecheck import api_problems, available  # noqa: E402

runs = sys.argv[1:] or ["fishing_nostudio_1", "canyon_rally_b1", "observatory_escape_b1", "wildfire_command_b1",
                        "rhythm_obby_b1", "sky_minigolf_b1"]
print("available:", available())
for r in runs:
    ws = Path("/mnt/c/Users/sarta/cybus_runs") / r / "workspace"
    files = sorted(str(p.relative_to(ws / "src")) for p in (ws / "src").rglob("*.luau"))
    game = [f for f in files if not f.startswith("ReplicatedStorage/Kit/")]
    t = time.time()
    probs = asyncio.run(api_problems(ws, game))
    n = sum(map(len, probs.values()))
    print(f"== {r}: {n} API problems in {len(probs)} files ({time.time() - t:.1f}s)")
    shown = 0
    for p, v in probs.items():
        for x in v:
            if shown < int(__import__("os").environ.get("SHOW", "6")):
                print(f"   {p.split('/')[-1]}: {x[:200]}")
                shown += 1

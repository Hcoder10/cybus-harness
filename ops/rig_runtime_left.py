"""The runtime problems and stubs a run's report says are left, and the gate log lines: rig_runtime_left.py <run>..."""
import json
import re
import sys
from pathlib import Path

for run in sys.argv[1:]:
    d = Path("/mnt/c/Users/sarta/cybus_runs") / run
    r = json.loads((d / "report.json").read_text(encoding="utf-8"))
    probs = r.get("runtime_problems", r.get("wiring_problems"))
    print(f"== {run}: runtime left {sum(map(len, (probs or {}).values())) if probs is not None else 'n/a'}, "
          f"stubs {len(r.get('stubs_left', []))}")
    for p, v in (probs or {}).items():
        for x in v:
            print(f"   {p.split('/')[-1]}: {x[:240]}")
    log = (d / "run.log").read_text(encoding="utf-8", errors="replace").splitlines()
    starts = [i for i, line in enumerate(log) if "=== build start" in line]
    for line in log[starts[-1] if starts else 0:]:
        if re.search(r"runtime problem|wiring problem|FAILED|Traceback", line):
            print("   log:", line[:160])

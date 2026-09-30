"""Build a finished run's final place file with rojo: rig_final_place.py <run name>."""
import json
import sys
from pathlib import Path

sys.path.insert(0, "/home/sarta/cybus-harness")
from harness.place import build_place, rojo_exe  # noqa: E402

run = Path("/mnt/c/Users/sarta/cybus_runs") / sys.argv[1]
plan = json.loads((run / "plan.json").read_text(encoding="utf-8"))
style = json.loads((run / "style.json").read_text(encoding="utf-8"))
style = style.get("style", style) if isinstance(style, dict) else {}
print("rojo:", rojo_exe())
out = build_place(run / "workspace", run / "place" / "final.rbxlx", plan.get("title") or "game", style=style)
print(out, out.stat().st_size, "bytes")

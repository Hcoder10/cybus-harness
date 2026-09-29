"""The game as a Rojo project, and a saved place built from it.

A build's workspace (src/<Service>/...) is a standard Rojo layout, so the finished game is delivered as a Rojo
project (default.project.json next to src/) plus a place file built from it. The project also carries what is
not code: the style guide's lighting and post effects, HTTP enabled for Studio play sessions, and the run
marker the harness uses to recognise its own place. Studios can `rojo serve` it and keep going.
"""
from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

MARKER_NAME = "CybusHarnessRun"
_SERVICES = ("ReplicatedStorage", "ReplicatedFirst", "ServerScriptService", "ServerStorage", "StarterGui",
             "StarterPack", "Workspace", "Lighting", "SoundService", "Teams", "TextChatService")


def _color(v, default=(1.0, 1.0, 1.0)) -> list[float]:
    s = str(v or "").strip().lstrip("#")
    if len(s) == 6:
        try:
            return [round(int(s[i:i + 2], 16) / 255, 4) for i in (0, 2, 4)]
        except ValueError:
            pass
    return list(default)


def _num(v, default: float, lo: float, hi: float) -> float:
    try:
        return max(lo, min(hi, float(v)))
    except (TypeError, ValueError):
        return default


def lighting_node(style: dict | None) -> dict:
    """Lighting with the style guide's values and post effects (Future lighting for local-light shadows)."""
    L = (style or {}).get("lighting") or {}
    node: dict = {"$className": "Lighting", "$properties": {
        "Technology": "Future",
        "ClockTime": __import__("harness.tokens", fromlist=["clock_time"]).clock_time(L.get("ClockTime", 14), []),
        "Brightness": _num(L.get("Brightness"), 2, 0, 10),
        "ExposureCompensation": _num(L.get("ExposureCompensation"), 0, -3, 3),
        "Ambient": _color(L.get("Ambient"), (0.27, 0.27, 0.27)),
        "OutdoorAmbient": _color(L.get("OutdoorAmbient"), (0.5, 0.5, 0.5)),
    }}
    effects = (("atmosphere", "Atmosphere", "Atmosphere"), ("color_correction", "ColorCorrectionEffect", "ColorCorrection"),
               ("bloom", "BloomEffect", "Bloom"))
    for key, cls, name in effects:
        props = L.get(key) or {}
        if not props:
            continue
        out = {}
        from harness.tokens import effect_value
        for k, v in props.items():
            if isinstance(v, (int, float)) and not isinstance(v, bool):
                out[str(k)] = effect_value(cls, str(k), float(v), [])
            elif isinstance(v, str) and v.strip().startswith("#"):
                out[str(k)] = _color(v)
        node[name] = {"$className": cls, "$properties": out}
    return node


def project(src_root: Path, name: str, run_id: str | None = None, style: dict | None = None) -> dict:
    """A Rojo project tree over `src_root` (the workspace's src/ folder)."""
    src_root = Path(src_root)
    rel = lambda *p: "/".join(("src",) + p)               # noqa: E731 - paths are relative to the project file
    tree: dict = {"$className": "DataModel",
                  "HttpService": {"$className": "HttpService", "$properties": {"HttpEnabled": True}}}
    for svc in _SERVICES:
        node: dict = {"$className": svc}
        if (src_root / svc).is_dir():
            node["$path"] = rel(svc)
        tree[svc] = node
    tree["Lighting"] = {**lighting_node(style), **({"$path": rel("Lighting")} if (src_root / "Lighting").is_dir() else {})}
    if run_id:
        tree["ServerStorage"][MARKER_NAME] = {"$className": "StringValue", "$properties": {"Value": run_id}}
    if not (src_root / "Workspace").is_dir():
        tree["Workspace"]["SpawnLocation"] = {"$className": "SpawnLocation", "$properties": {
            "Anchored": True, "Size": [12, 1, 12], "Position": [0, 0.5, 0]}}
    sp: dict = {"$className": "StarterPlayer"}
    for sub in ("StarterPlayerScripts", "StarterCharacterScripts"):
        node = {"$className": sub}
        if (src_root / "StarterPlayer" / sub).is_dir():
            node["$path"] = rel("StarterPlayer", sub)
        sp[sub] = node
    tree["StarterPlayer"] = sp
    return {"name": name, "tree": tree}


def rojo_exe() -> str | None:
    found = shutil.which("rojo")
    if found:
        return found
    home = Path.home() / "bin" / "rojo.exe"
    return str(home) if home.exists() else None


def build_place(workspace_root: Path, out: Path, name: str, run_id: str | None = None,
                style: dict | None = None, timeout: float = 180) -> Path:
    """Write <workspace_root>/default.project.json and build it into `out` (.rbxl or .rbxlx) with rojo."""
    workspace_root, out = Path(workspace_root), Path(out)
    proj = project(workspace_root / "src", name, run_id, style)
    (workspace_root / "default.project.json").write_text(json.dumps(proj, indent=1), encoding="utf-8")
    exe = rojo_exe()
    if not exe:
        raise RuntimeError("rojo is not installed: the project file is written, but no place file could be built")
    out.parent.mkdir(parents=True, exist_ok=True)
    proc = subprocess.run([exe, "build", str(workspace_root / "default.project.json"), "-o", str(out.resolve())],
                          capture_output=True, text=True, timeout=timeout,
                          creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    if proc.returncode != 0 or not out.exists():
        raise RuntimeError(f"rojo build failed: {(proc.stderr or proc.stdout).strip()[:800]}")
    return out

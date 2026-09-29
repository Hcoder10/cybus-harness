"""Local Luau checks (no Studio needed): syntax errors gate every sync; a few high-signal lints are reported to
builders. Uses luau-analyze from HARNESS_LUAU_ANALYZE, PATH, or the known local build.
"""
from __future__ import annotations

import asyncio
import os
import re
import shutil
import tempfile
from pathlib import Path

_CANDIDATES = [os.environ.get("HARNESS_LUAU_ANALYZE", ""), shutil.which("luau-analyze") or "",
               str(Path.home() / "brickformer" / "tools" / "luau" / "luau-analyze.exe")]
_LINE = re.compile(r"^(?P<file>.+?):(?P<line>\d+):(?P<col>[\d-]+): \((?P<code>\w+)\) (?P<kind>\w+): (?P<msg>.*)$")
# Roblox globals luau-analyze does not know without a definitions file.
_ROBLOX_GLOBALS = {"game", "workspace", "script", "Instance", "Vector3", "Vector2", "CFrame", "Color3", "UDim", "UDim2",
                   "Enum", "TweenInfo", "NumberSequence", "NumberSequenceKeypoint", "ColorSequence",
                   "ColorSequenceKeypoint", "NumberRange", "Rect", "Ray", "RaycastParams", "OverlapParams", "BrickColor",
                   "Font", "Random", "task", "tick", "time", "wait", "delay", "spawn", "warn", "typeof", "PhysicalProperties",
                   "Region3", "Axes", "Faces", "PathWaypoint", "DateTime", "shared", "plugin", "settings", "UserSettings",
                   "buffer", "Content", "SharedTable", "Path2DControlPoint", "RotationCurveKey", "FloatCurveKey", "Secret",
                   "CatalogSearchParams", "DockWidgetPluginGuiInfo", "elapsedTime", "version", "stats", "debug"}
_KEEP_LINTS = {"UnknownGlobal", "GlobalUsedAsLocal", "UnreachableCode", "ImplicitReturn", "DuplicateLocal",
               "FormatString", "DeprecatedApi"}


def analyzer() -> str | None:
    for c in _CANDIDATES:
        if c and Path(c).exists():
            return c
    return None


async def check_sources(sources: dict[str, str], timeout: float = 60) -> dict[str, list[str]]:
    """{path: source} -> {path: [problems]}; only paths with problems appear. Syntax errors are prefixed 'SYNTAX'."""
    exe = analyzer()
    if not exe or not sources:
        return {}
    with tempfile.TemporaryDirectory(prefix="luau_check_") as d:
        names = {}
        for i, (path, src) in enumerate(sources.items()):
            fn = Path(d) / f"f{i}.luau"
            fn.write_text(src, encoding="utf-8")
            names[str(fn)] = path
            names[fn.name] = path
        proc = await asyncio.create_subprocess_exec(exe, "--formatter=plain", *[str(Path(d) / f"f{i}.luau") for i in range(len(sources))],
                                                    stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT)
        try:
            out, _ = await asyncio.wait_for(proc.communicate(), timeout)
        except asyncio.TimeoutError:
            proc.kill()
            return {}
    problems: dict[str, list[str]] = {}
    for line in out.decode("utf-8", "replace").splitlines():
        m = _LINE.match(line.strip())
        if not m:
            continue
        f = m.group("file")
        path = names.get(f) or names.get(Path(f).name)
        if not path:
            continue
        kind, msg = m.group("kind"), m.group("msg")
        if kind == "SyntaxError":
            problems.setdefault(path, []).append(f"SYNTAX line {m.group('line')}: {msg}")
        elif kind == "TypeError" and msg.startswith("Unknown global"):
            name = msg.split("'")[1] if "'" in msg else ""
            if name not in _ROBLOX_GLOBALS:
                problems.setdefault(path, []).append(f"line {m.group('line')}: {msg}")
        elif kind in _KEEP_LINTS:
            problems.setdefault(path, []).append(f"line {m.group('line')}: {kind}: {msg}")
    return problems


def syntax_errors(problems: dict[str, list[str]]) -> dict[str, list[str]]:
    return {p: [x for x in v if x.startswith("SYNTAX")] for p, v in problems.items() if any(x.startswith("SYNTAX") for x in v)}

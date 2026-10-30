"""Edit-mode building: the world builder makes real instances in Studio (terrain, parts, props, lighting) with the
kits, looks at them from any camera, and iterates until they look right.

Before this, a world was a runtime script the model wrote blind; it saw one judged capture from the spawn camera
after the fact (live, Starbloom: islands lined up into a "tower" from the spawn view, two repair rounds without the
model ever seeing the layout from anywhere else).

Every successful edit-mode chunk is logged (studio_build.jsonl) and replayed into a relaunched Studio. At the end
the harness saves Studio's place (Ctrl+S on the run's local file) so the final place holds the real instances; a
guarded fallback script replays the log at runtime only if the saved place is missing the world.
"""
from __future__ import annotations

import asyncio
import json
import re
import logging
import time
from pathlib import Path
from typing import Any

log = logging.getLogger(__name__)

ROOT = "StudioWorld"          # everything the builder makes lives under workspace.StudioWorld (plus Terrain, Lighting)

PRELUDE = f"""local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Kit = ReplicatedStorage:WaitForChild("Kit", 5)
local World = workspace:FindFirstChild("{ROOT}")
if not World then World = Instance.new("Folder"); World.Name = "{ROOT}"; World.Parent = workspace end
"""

HELP = f"""BUILD THE WORLD IN STUDIO (edit mode), not with a runtime script:
- studio_build(code): runs Luau in Studio's edit mode. What it creates is saved in the place: islands and terrain,
  parts, props, lighting. Predefined locals: Kit (ReplicatedStorage.Kit: require(Kit.WorldKit), WorldKit2, LookKit,
  PropKit...), World (the Folder workspace.{ROOT}: parent everything you make under it, in named sub-Folders/Models).
  `print` output and the value you `return` come back to you. Build in steps (look first, then islands, then
  props...), not one giant chunk. Rebuild a part by destroying its sub-folder first (World.Islands:Destroy()).
  Terrain: workspace.Terrain:Clear() wipes all terrain. Tag what gameplay needs (CollectionService:AddTag(part,
  "Checkpoint") or attributes) so runtime code finds it; never build geometry again at runtime.
  Runtime-only things (tweens, spinning hazards, movers, particles that must animate) stay in your scripts.
- studio_view(views?): plays the game and shows you screenshots. With no views you get a survey: the player's own
  view, a high 3/4 overview, a side view and a top-down view of the whole world, plus runtime errors and a judge
  score against the concept art. Pass views=[{{"position":[x,y,z],"look_at":[x,y,z],"fov":60}}] to frame any
  spot. LOOK AFTER EVERY BIG CHANGE and keep fixing what looks wrong (layout, scale, empty areas, clutter,
  lighting) until the survey reads like the concept art. The player's view is what players see first: make it great.
"""


def _vec(v: Any, default: tuple[float, float, float]) -> tuple[float, float, float]:
    try:
        x, y, z = (float(a) for a in v)
        return x, y, z
    except (TypeError, ValueError):
        return default


def survey(bounds: dict) -> list[dict]:
    lo = _vec(bounds.get("min"), (-60, 0, -60))
    hi = _vec(bounds.get("max"), (60, 40, 60))
    c = tuple((a + b) / 2 for a, b in zip(lo, hi))
    r = max(hi[0] - lo[0], hi[2] - lo[2], 80.0) * 0.75
    return [
        {"name": "overview", "position": [c[0] + 0.75 * r, c[1] + 0.6 * r, c[2] + 0.75 * r], "look_at": list(c), "fov": 55},
        {"name": "side", "position": [c[0] + 1.25 * r, c[1] + 0.12 * r, c[2]], "look_at": list(c), "fov": 55},
        {"name": "top", "position": [c[0], c[1] + 1.5 * r, c[2] + 0.05 * r], "look_at": list(c), "fov": 55},
    ]


class StudioBuild:
    def __init__(self, stage, run_dir: Path, ws) -> None:
        self.stage, self.ws = stage, ws
        self.log_path = Path(run_dir) / "studio_build.jsonl"
        self.replayed = False

    def chunks(self) -> list[dict]:
        if not self.log_path.exists():
            return []
        out = []
        for line in self.log_path.read_text(encoding="utf-8").splitlines():
            try:
                out.append(json.loads(line))
            except ValueError:
                pass
        return out

    async def _exec(self, code: str, timeout_ms: int = 30000) -> dict:
        wrapped = (PRELUDE + "local __out = {}\nlocal function print(...)\n\tlocal t = table.pack(...)\n"
                   "\tfor i = 1, t.n do t[i] = tostring(t[i]) end\n\ttable.insert(__out, table.concat(t, \" \"))\nend\n"
                   "local __ok, __res = pcall(function()\n" + code + "\nend)\n"
                   "return game:GetService(\"HttpService\"):JSONEncode({ok = __ok, result = tostring(__res), "
                   "out = __out})")
        res = await self.stage.edit(wrapped, timeout_ms=timeout_ms)
        text = json.dumps(res, ensure_ascii=False)
        # Errors name the whole guarded chunk ([string "if game.PlaceId ..."]:N:); report the builder's own line.
        pre = wrapped.split(code, 1)[0].count("\n") + 2          # + Stage.edit's two guard lines

        def tidy(msg: str) -> str:
            return re.sub(r'\[string "[^\]]*"\]:(\d+):', lambda m: f"your line {int(m.group(1)) - pre}:", msg)
        for cand in _strings(res):
            if cand.startswith("{") and '"ok"' in cand:
                try:
                    out = json.loads(cand)
                    out["result"] = tidy(str(out.get("result")))
                    return out
                except ValueError:
                    pass
        return {"ok": False, "result": tidy(text)[:1500], "out": []}

    async def _sync(self) -> None:
        """Push changed files, then swap each pushed ModuleScript for a fresh copy: a plugin's require caches a module
        by instance, so edit-mode code kept the OLD source after a sync (live: a kit fix never reached the builder)."""
        synced = await self.stage.sync()
        mods = [p.get("instance") for p in synced.get("pushed") or []
                if isinstance(p, dict) and p.get("class") == "ModuleScript" and p.get("action") != "deleted"
                and p.get("instance")]
        if not mods:
            return
        paths = ", ".join(json.dumps(m) for m in mods)
        await self.stage.edit(
            "for _, path in ipairs({" + paths + "}) do
"
            "	local inst = game
"
            "	for _, n in ipairs(string.split(path, \".\")) do inst = inst and inst:FindFirstChild(n) end
"
            "	if inst and inst:IsA(\"ModuleScript\") then
"
            "		local parent, c = inst.Parent, inst:Clone()
		inst:Destroy()
		c.Parent = parent
	end
"
            "end
return true")

    async def ensure(self) -> None:
        """A relaunched Studio has a fresh place: replay the log (after the kit reached it)."""
        if self.replayed:
            return
        self.replayed = True
        chunks = self.chunks()
        if not chunks:
            return
        async with self.stage.lock:
            await self._sync()
            probe = await self._exec(f"return workspace:FindFirstChild('{ROOT}') and #workspace.{ROOT}:GetChildren() or 0")
            if str(probe.get("result")) not in ("0", "nil", ""):
                return                              # this Studio already holds the world (same session)
            for c in chunks:
                r = await self._exec(c["code"])
                if not r.get("ok"):
                    log.warning("studio_build replay chunk %s failed: %s", c.get("note"), r.get("result"))

    async def run(self, code: str, note: str = "") -> dict:
        await self.ensure()
        async with self.stage.lock:
            await self._sync()                      # the builder's modules (and kit) are current in edit mode
            r = await self._exec(code)
        if r.get("ok"):
            with self.log_path.open("a", encoding="utf-8") as f:
                f.write(json.dumps({"t": time.time(), "note": note, "code": code}, ensure_ascii=False) + "\n")
        return r

    async def view(self, views: list[dict] | None, label: str, settle: float = 2.5) -> tuple[list[bytes], list[str], dict, list[str]]:
        """-> (images, labels, bounds, error lines)."""
        await self.ensure()
        images, labels, errors = [], [], []
        bounds: dict = {}
        async with self.stage.session():
            await asyncio.sleep(settle)
            r = await self.stage.cmd("__bounds")
            for rep in r.get("replies") or []:
                try:
                    got = rep.get("result")
                    bounds = json.loads(got) if isinstance(got, str) else (got or {})
                    if bounds:
                        break
                except (TypeError, ValueError):
                    pass
            plan = list(views or [])
            if not plan:
                images.append(await self.stage.shot(f"{label}_player"))
                labels.append("player view")
                plan = survey(bounds)
            for i, v in enumerate(plan[:6]):
                pos = _vec(v.get("position"), (0, 80, 80))
                at = _vec(v.get("look_at"), (0, 0, 0))
                fov = float(v.get("fov") or 60)
                await self.stage.cmd("__camera", *pos, *at, fov)
                await asyncio.sleep(0.8)
                images.append(await self.stage.shot(f"{label}_{v.get('name') or i}"))
                labels.append(f"{v.get('name') or 'view ' + str(i + 1)} @ {tuple(round(a) for a in pos)} -> "
                              f"{tuple(round(a) for a in at)}")
            await self.stage.cmd("__camera")
            for e in await self.stage.logs():
                if e.get("kind") in ("error", "warning") and "StudioBridgeMCP" not in str(e.get("text")) \
                        and "CybusChat" not in str(e.get("text")):
                    errors.append(f"[{e.get('side')}] {str(e.get('text'))[:300]}")
        return images, labels, bounds, errors[-15:]

    def write_fallback(self) -> list[str]:
        """Runtime replay of the edit-mode build, used only when the place was not saved with the world in it."""
        chunks = self.chunks()
        if not chunks:
            return []
        body = "\n".join(f"\t-- {c.get('note') or 'step'}\n\tlocal ok, err = pcall(function()\n"
                         + "\n".join("\t\t" + l for l in c["code"].splitlines())
                         + "\n\tend)\n\tif not ok then warn(\"[StudioBuild] \" .. tostring(err)) end" for c in chunks)
        mod = ("-- The world the builder made in Studio's edit mode, as a fallback replay (generated by the harness).\n"
               "-- Runs only if the saved place does not already contain workspace." + ROOT + ".\n"
               "return function()\n" + "".join("\t" + l + "\n" for l in PRELUDE.splitlines()) + body + "\nend\n")
        boot = ("-- Fallback: rebuild the edit-mode world only if the place was saved without it (generated).\n"
                f"if not workspace:FindFirstChild(\"{ROOT}\") or #workspace.{ROOT}:GetChildren() == 0 then\n"
                "\trequire(game:GetService(\"ServerStorage\"):WaitForChild(\"StudioBuildReplay\"))()\nend\n")
        files = {"ServerStorage/StudioBuildReplay.luau": mod, "ServerScriptService/StudioBuildFallback.server.luau": boot}
        for rel, src in files.items():
            self.ws.write(rel, src)
        return list(files)

    async def save_place(self, place: Path) -> bool:
        """Ctrl+S in Studio (the run's place is a local .rbxlx, so it saves without a dialog). True if it wrote."""
        from harness.stage import maximize_studio, studio_is_foreground
        before = place.stat().st_mtime if place.exists() else 0
        maximize_studio()
        await asyncio.sleep(1.0)
        if not studio_is_foreground():
            log.warning("save_place: Studio is not the foreground window")
            return False
        b = self.stage.bridge
        await b.call("input_key", {"key": "ctrl", "action": "down"})
        await b.call("input_key", {"key": "s", "action": "press", "hold_ms": 80})
        await b.call("input_key", {"key": "ctrl", "action": "up"})
        for _ in range(20):
            await asyncio.sleep(1.0)
            if place.exists() and place.stat().st_mtime > before:
                return True
        return False


def _strings(obj: Any):
    if isinstance(obj, str):
        yield obj
    elif isinstance(obj, dict):
        for v in obj.values():
            yield from _strings(v)
    elif isinstance(obj, list):
        for v in obj:
            yield from _strings(v)

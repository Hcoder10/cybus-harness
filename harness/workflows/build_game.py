"""build_game: a pitch in, a playable, judged and polished Roblox game out.

The workflow holds the long horizon so no single agent has to: every agent call is a short, fully briefed task
(plan, style, one work item, one fix list), and deterministic code does the sequencing, gating, capturing,
judging and routing between them.

    Plan       lead writes the game plan; a critic reviews it; the lead revises once
    Style      art director writes the style guide; code turns it into the Tokens module and lighting;
               an optional reference board of concept frames is generated
    Architect  lead splits the game into files, remotes, debug commands and 8-16 owned work items
    Scaffold   kit + tokens + asset map + loadable stubs for every file, synced and boot-checked
    Build      items run as their dependencies finish: build -> capture in Studio -> judge -> fix, until the
               item passes or its repair budget runs out (builder, critic and fixer are different agents)
    Integrate  one play session captures every item; errors and whole-game critiques are routed to owners
    Polish     a panel of critics with different lenses reviews the whole game; fixes loop until dry
    Report     scores, captures, the saved place
"""
from __future__ import annotations

import argparse
import asyncio
import hashlib
import io
import json
import logging
import re
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from harness import prompts, schemas
from harness.judge import Verdict, judge, panel
from harness.kit import KIT_API, kit_files
from harness.llm import image_part, text_part
from harness.tokens import build_tokens, lighting_script
from harness.tools.base import Tool, ToolResult
from harness.tools.capture import contact_sheet
from harness.tools.imagegen import KIND_HINTS
from harness.tools.luau import check_sources, syntax_errors
from harness.tools.workspace import parse_rel

log = logging.getLogger("harness.build_game")

TOKENS_PATH = "ReplicatedStorage/Shared/Tokens.luau"
HARNESS_OWNED = {TOKENS_PATH, "ReplicatedStorage/Shared/AssetMap.luau"}
GAME_ASPECTS = ("core_loop", "cohesion", "polish")


@dataclass
class BuildConfig:
    threshold: float = 7.0              # an item passes at this score with no blockers
    repair_rounds: int = 2              # fix -> recapture -> rejudge rounds per item
    polish_rounds: int = 2              # whole-game panel rounds
    builder_steps: int = 28             # hard cap on one builder agent's tool steps
    max_items: int = 16
    plan_critique: bool = True
    reference_board: bool = True
    integrate: bool = True
    # A finished phase's artifact (plan.json, style.json, architecture.json) is reused on resume even when the
    # harness's prompts changed since: live, a KIT_API edit re-keyed the architecture call and Cybus designed a
    # brand-new split on top of the old game's files.
    reuse_artifacts: bool = True
    deadline: float | None = None       # unix time; polish rounds stop early to leave room for the report
    reserve_seconds: float = 1800       # time kept back before the deadline for the final report and evidence


def _canon(path: str) -> str:
    return parse_rel(path).rel


def _digest(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def style_markdown(style: dict) -> str:
    """The style guide as a compact brief for builders and judges."""
    s = style or {}
    pal = ", ".join(f"{k} {v}" for k, v in (s.get("palette") or {}).items())
    fonts = ", ".join(f"{k}: {v}" for k, v in (s.get("fonts") or {}).items())
    sizes = ", ".join(f"{k} {v}" for k, v in (s.get("type_scale") or {}).items())
    motion = s.get("motion") or {}
    light = s.get("lighting") or {}
    return "\n".join([
        f"DIRECTION: {s.get('direction', '')}",
        f"REFERENCES: {'; '.join(s.get('references') or [])}",
        f"AVOID: {'; '.join(s.get('avoid') or [])}",
        f"PALETTE (Tokens.color): {pal}",
        f"FONTS (Tokens.font): {fonts}",
        f"TYPE SCALE (Tokens.size, dp on 1920x1080): {sizes}",
        f"RADII (Tokens.radius): {s.get('radius', {})}; STROKE: {s.get('stroke', '')}",
        f"SHAPE LANGUAGE: {s.get('shape_language', '')}",
        f"DEPTH RECIPE: {s.get('depth_recipe', '')}",
        f"MOTION (Tokens.motion): fast {motion.get('fast')}s, base {motion.get('base')}s, slow {motion.get('slow')}s, "
        f"dramatic {motion.get('dramatic')}s, ease out {motion.get('ease_out')}, ease in {motion.get('ease_in')}",
        f"CAMERA: {s.get('camera', '')}",
        f"VFX: {s.get('vfx', '')}",
        f"WORLD: {s.get('world', '')}",
        f"LIGHTING: {json.dumps(light)}",
        f"AUDIO: {s.get('audio', '')}",
    ])


STUB_MARK = "(stub created by the harness; the owning item replaces it)"


def stub_source(path: str, responsibility: str, api: str) -> str:
    """A loadable placeholder so every require resolves before its owner writes the real file."""
    head = f"-- {responsibility}\n-- API: {api}\n-- {STUB_MARK}\n"
    info = parse_rel(path)
    if info.class_name == "ModuleScript":
        return head + "local M = {}\nreturn M\n"
    return head


def text_image(title: str, text: str, width: int = 1400, max_lines: int = 120) -> bytes:
    """Render text as a PNG (for evidence a vision judge reads: sound maps, manifests)."""
    from PIL import Image, ImageDraw, ImageFont
    lines = [title, ""] + [line[:160] for line in text.splitlines()][:max_lines]
    try:
        font = ImageFont.truetype("consola.ttf", 16)
    except OSError:
        font = ImageFont.load_default()
    im = Image.new("RGB", (width, 24 + 20 * len(lines)), (20, 22, 26))
    d = ImageDraw.Draw(im)
    for i, line in enumerate(lines):
        d.text((16, 12 + 20 * i), line, fill=(230, 232, 236) if i else (255, 200, 90), font=font)
    buf = io.BytesIO()
    im.save(buf, format="PNG")
    return buf.getvalue()


CLIENT_CONTAINERS = ("StarterPlayer/StarterPlayerScripts/", "StarterPlayer/StarterCharacterScripts/", "StarterGui/",
                     "ReplicatedFirst/", "StarterPack/")
SERVER_CONTAINERS = ("ServerScriptService/", "Workspace/")


def arch_problems(arch: dict) -> list[str]:
    """Roblox placement mistakes that make code silently not run (checked before anyone builds on them)."""
    out = []
    seen: dict[str, str] = {}
    for f in arch.get("files") or []:
        path = str(f.get("path", ""))
        name = path.rsplit("/", 1)[-1]
        if name.count(".server") + name.count(".client") > 1:
            out.append(f"{path}: two script suffixes; a file is ONE of .server.luau (Script), .client.luau "
                       "(LocalScript) or .luau (ModuleScript)")
            continue
        try:
            info = parse_rel(path)
        except ValueError as e:
            out.append(f"{path}: {e}")
            continue
        if info.class_name == "LocalScript" and not path.startswith(CLIENT_CONTAINERS):
            out.append(f"{path}: a LocalScript only runs under StarterPlayer/StarterPlayerScripts, "
                       "StarterCharacterScripts, StarterGui or ReplicatedFirst; move it there, or make it a ModuleScript "
                       "(.luau) that a client entry script requires")
        if info.class_name == "Script" and not path.startswith(SERVER_CONTAINERS):
            out.append(f"{path}: a server Script only runs in ServerScriptService (or Workspace); move it, or make it "
                       "a ModuleScript (.luau)")
        if info.instance_path in seen:
            out.append(f"{path} and {seen[info.instance_path]} become the same instance {info.instance_path}")
        seen[info.instance_path] = path
        api = str(f.get("api", ""))
        # "PlayerState.get(player) -> ..." in a Script's API means other code expects to require it: it can't.
        if info.class_name in ("Script", "LocalScript") and re.search(rf"\b{re.escape(info.name)}\s*[.:]\s*\w+\s*\(", api):
            out.append(f"{path}: its API ({api[:60]}...) is a module API that other code would require, but a "
                       f"{info.class_name} cannot be required; make it {path.rsplit('.', 2)[0]}.luau (ModuleScript) and "
                       "let ONE entry script per side require the modules and call their init")
    return out


def normalize_arch(arch: dict, max_items: int) -> tuple[dict, list[str]]:
    """Canonical paths, unique item ids, disjoint file ownership, no harness-owned files. Returns notes."""
    notes: list[str] = []
    files: dict[str, dict] = {}
    for f in arch.get("files") or []:
        try:
            p = _canon(f.get("path", ""))
        except ValueError as e:
            notes.append(f"dropped file {f.get('path')!r}: {e}")
            continue
        if p in HARNESS_OWNED or p.startswith("ReplicatedStorage/Kit/"):
            notes.append(f"dropped {p}: provided by the harness")
            continue
        files[p] = {**f, "path": p}
    owner: dict[str, str] = {}
    items, seen_ids = [], set()
    for it in (arch.get("items") or [])[:max_items]:
        iid = re.sub(r"[^a-z0-9_]+", "_", str(it.get("id") or it.get("title") or "item").lower()).strip("_") or "item"
        while iid in seen_ids:
            iid += "_2"
        seen_ids.add(iid)
        mine = []
        for raw in it.get("files") or []:
            try:
                p = _canon(raw)
            except ValueError as e:
                notes.append(f"item {iid}: dropped file {raw!r}: {e}")
                continue
            if p in HARNESS_OWNED or p.startswith("ReplicatedStorage/Kit/"):
                continue
            if p in owner:
                notes.append(f"item {iid}: {p} already owned by {owner[p]}")
                continue
            owner[p] = iid
            mine.append(p)
            files.setdefault(p, {"path": p, "responsibility": it.get("title", ""), "api": "(see item brief)"})
        if not mine:
            # Every file it listed belongs to an earlier item: rather than lose the work (e.g. all the animation),
            # give it a self-running LocalScript of its own (client-side craft is what such items usually are).
            own = "StarterPlayer/StarterPlayerScripts/" + "".join(w.capitalize() for w in iid.split("_")) + ".client.luau"
            if own in owner or own in HARNESS_OWNED:
                notes.append(f"item {iid} owns no files; dropped")
                continue
            owner[own] = iid
            mine.append(own)
            files[own] = {"path": own, "responsibility": it.get("title", ""),
                          "api": "self-running LocalScript (nothing requires it)"}
            notes.append(f"item {iid} listed only files owned by other items; it now owns {own}")
        aspect = it.get("aspect") if it.get("aspect") in schemas.ASPECTS else "core_loop"
        cap = it.get("capture") or {}
        items.append({**it, "id": iid, "aspect": aspect, "files": mine,
                      "capture": {"kind": cap.get("kind", "screen"), "commands": list(cap.get("commands") or []),
                                  "description": cap.get("description", "")}})
    ids = {i["id"] for i in items}
    for it in items:
        it["depends_on"] = [d for d in (it.get("depends_on") or []) if d in ids and d != it["id"]]
    unowned = [p for p in files if p not in owner]
    for p in unowned:
        notes.append(f"file {p} has no owning item; dropped")
        files.pop(p)
    return {**arch, "files": list(files.values()), "items": items}, notes


class Build:
    def __init__(self, wf, ws, stage, judge_llm, cfg: BuildConfig, run_dir: Path, imagegen=None, assets=None) -> None:
        self.wf, self.ws, self.stage, self.judge_llm, self.cfg = wf, ws, stage, judge_llm, cfg
        self.run_dir = Path(run_dir)
        self.imagegen, self.assets = imagegen, assets
        self.plan: dict = {}
        self.style: dict = {}
        self.style_md = ""
        self.arch: dict = {}
        self.items: list[dict] = []
        self.refs: dict[str, bytes] = {}
        self.verdicts: dict[str, list[dict]] = {}
        self.captures: dict[str, Any] = {}
        self.done: dict[str, asyncio.Event] = {}
        from harness.tools.audio import AudioSearch
        self.audio = AudioSearch(self.run_dir / "audio_cache.json")
        self.extra_tools: list[Tool] = []          # e.g. paint_texture / list_textures from harness.tools.art
        self.item_lock: dict[str, asyncio.Lock] = {}
        (self.run_dir / "verdicts").mkdir(parents=True, exist_ok=True)
        # Revision rounds apply a given list of changes: thinking adds little and can run away (Qwen3.8 spent a whole
        # 16k budget thinking, three times, on a style revision). They use the 'reviser' role when it is configured.
        self.reviser = "reviser" if "reviser" in getattr(wf, "roles", {}) else "lead"
        # The architecture is the largest structured answer (files, remotes, commands, a dozen briefed items). With
        # thinking on, Qwen3.8 spent six 16k-token replies thinking without submitting; it gets its own role
        # (configure it without thinking and with a larger completion budget).
        self.architect = "architect" if "architect" in getattr(wf, "roles", {}) else "lead"

    # ------------------------------------------------------------------ helpers
    def save(self, name: str, obj: Any) -> None:
        (self.run_dir / name).write_text(json.dumps(obj, indent=1, ensure_ascii=False, default=str), encoding="utf-8")

    def owned_sources(self, item: dict) -> dict[str, str]:
        out = {}
        for p in item["files"]:
            try:
                out[p] = self.ws.read(p)
            except OSError:
                out[p] = ""
        return out

    def owner_of(self, path: str) -> str | None:
        for it in self.items:
            if path in it["files"]:
                return it["id"]
        return None

    def instance_to_item(self) -> dict[str, str]:
        m = {}
        for it in self.items:
            for p in it["files"]:
                m[parse_rel(p).instance_path] = it["id"]
        return m

    def errors_by_item(self, logs: list[dict]) -> dict[str, list[str]]:
        """Route runtime errors to the items whose scripts appear in them."""
        paths = self.instance_to_item()
        out: dict[str, list[str]] = {}
        for entry in logs:
            if entry.get("kind") != "error":
                continue
            text = str(entry.get("text", ""))
            for inst, iid in paths.items():
                if inst in text:
                    out.setdefault(iid, [])
                    if text not in out[iid]:
                        out[iid].append(text[:400])
                    break
        return out

    def targets_for(self, aspect: str) -> list[bytes]:
        pick = {"ui_menus": ("title", "menu", "shop", "results"), "hud": ("hud", "gameplay"),
                "world_art": ("gameplay", "world", "title"), "vfx": ("signature", "moment"),
                "camera": ("signature", "gameplay"), "game_feel": ("signature",), "cohesion": ("",)}
        keys = pick.get(aspect, ())
        return [png for name, png in self.refs.items() if any(k in name for k in keys)][:2]

    # ------------------------------------------------------------------ tools for builders
    TOOL_ASPECTS = {"paint_texture": "texture_spec", "list_textures": "texture_spec",
                    "author_clip": "animation_spec", "list_clips": "animation_spec",
                    "check_fx_spec": "vfx_camera_spec"}

    @classmethod
    def tool_fits(cls, tool_name: str, aspect: str) -> bool:
        """Spec tools go only to the aspects whose briefs carry their spec reference (fewer tools, less confusion)."""
        spec = cls.TOOL_ASPECTS.get(tool_name)
        return spec is None or aspect in prompts.SPEC_PLAYBOOKS.get(spec, set())

    def builder_tools(self, item: dict) -> list[Tool]:
        owned = set(item["files"])
        ws = self

        def mine(path: str) -> str:
            p = _canon(path)
            if p not in owned:
                raise PermissionError(f"{p} is not yours. Yours: {', '.join(sorted(owned))}. Put changes to other "
                                      "files under 'requests' in your report.")
            return p

        async def write_file(path: str, content: str) -> ToolResult:
            try:
                p = mine(path)
            except (PermissionError, ValueError) as e:
                return ToolResult(text=f"ERROR: {e}")
            ws.ws.write(p, content)
            probs = (await check_sources({p: content})).get(p, [])
            return ToolResult(text=f"wrote {p} ({content.count(chr(10)) + 1} lines)"
                              + ("\nPROBLEMS:\n" + "\n".join(probs[:12]) if probs else "\nno syntax errors"))

        async def edit_file(path: str, old_text: str, new_text: str) -> ToolResult:
            try:
                p = mine(path)
            except (PermissionError, ValueError) as e:
                return ToolResult(text=f"ERROR: {e}")
            try:
                src = ws.ws.read(p)
            except OSError:
                return ToolResult(text=f"ERROR: {p} does not exist yet; use write_file")
            n = src.count(old_text)
            if n != 1:
                return ToolResult(text=f"ERROR: old_text appears {n} times in {p}; it must appear exactly once. "
                                       "Include more surrounding lines.")
            new_src = src.replace(old_text, new_text, 1)
            ws.ws.write(p, new_src)
            probs = (await check_sources({p: new_src})).get(p, [])
            return ToolResult(text=f"edited {p}" + ("\nPROBLEMS:\n" + "\n".join(probs[:12]) if probs else "\nno syntax errors"))

        async def read_file(path: str, start_line: int = 1, max_lines: int = 400) -> ToolResult:
            try:
                p = _canon(path)
                lines = ws.ws.read(p).splitlines()
            except (OSError, ValueError) as e:
                return ToolResult(text=f"ERROR: {e}")
            a = max(1, int(start_line))
            chunk = lines[a - 1:a - 1 + int(max_lines)]
            body = "\n".join(f"{a + i:4d}| {l}" for i, l in enumerate(chunk))
            more = f"\n... ({len(lines) - (a - 1 + len(chunk))} more lines)" if a - 1 + len(chunk) < len(lines) else ""
            return ToolResult(text=f"{p} ({len(lines)} lines)\n{body}{more}")

        async def list_files() -> ToolResult:
            rows = []
            for f in ws.ws.files():
                rows.append(f"{f}  [{'yours' if f in owned else (ws.owner_of(f) or 'harness')}]")
            return ToolResult(text="\n".join(rows) or "(no files)")

        async def check_code() -> ToolResult:
            srcs = {p: ws.ws.read(p) for p in owned if (ws.ws.src / p).exists()}
            probs = await check_sources(srcs)
            if not probs:
                return ToolResult(text="no problems found in your files")
            return ToolResult(text="\n".join(f"{p}:\n  " + "\n  ".join(v[:15]) for p, v in probs.items()))

        s = {"type": "object", "additionalProperties": False}
        tools = [
            Tool("write_file", "Create or overwrite one of YOUR files with complete content. Reports syntax problems.",
                 {**s, "required": ["path", "content"], "properties": {
                     "path": {"type": "string"}, "content": {"type": "string", "description": "the whole file"}}},
                 write_file, mutating=True),
            Tool("edit_file", "Replace one exact snippet (old_text, which must occur exactly once) in one of YOUR files.",
                 {**s, "required": ["path", "old_text", "new_text"], "properties": {
                     "path": {"type": "string"}, "old_text": {"type": "string"}, "new_text": {"type": "string"}}},
                 edit_file, mutating=True),
            Tool("read_file", "Read any project file (with line numbers).",
                 {**s, "required": ["path"], "properties": {"path": {"type": "string"},
                                                            "start_line": {"type": "integer"},
                                                            "max_lines": {"type": "integer"}}}, read_file),
            Tool("list_files", "List every project file and who owns it.", {**s, "properties": {}}, list_files),
            Tool("check_code", "Check your files for syntax errors and likely bugs.", {**s, "properties": {}}, check_code),
        ]
        tools += self.audio.tools() + [t for t in self.extra_tools if self.tool_fits(t.name, item["aspect"])]
        if self.imagegen is not None and self.imagegen.enabled and self.assets is not None:
            async def generate_image(name: str, prompt: str, kind: str = "icon") -> ToolResult:
                try:
                    out = await self.imagegen.generate(prompt, kind, style=self.style.get("direction", ""))
                except Exception as e:  # noqa: BLE001
                    return ToolResult(text=f"ERROR: image generation failed: {e}")
                self.assets.add(name, out["png"], kind=kind, prompt=prompt, slice_center=out.get("slice_center"))
                sl = out.get("slice_center")
                return ToolResult(
                    text=f"generated '{name}' ({out.get('width')}x{out.get('height')}). Use Assets.image(\"{name}\")"
                         + (f"; 9-slice with ScaleType Slice and SliceCenter Rect.new({', '.join(map(str, sl))}) "
                            f"(or Assets.slice(\"{name}\"))" if sl else "") + ". Look at it: regenerate with a better "
                         "prompt if it does not fit the style guide.", images=[out["png"]])
            tools.append(Tool("generate_image", "Generate game art (icon, item, character, portrait, panel, button, "
                                                "banner, background, texture, vfx, logo) in the game's style; it is "
                                                "added to the game under `name`.",
                              {**s, "required": ["name", "prompt"], "properties": {
                                  "name": {"type": "string", "description": "snake_case asset name"},
                                  "prompt": {"type": "string", "description": "what to draw, specifically"},
                                  "kind": {"type": "string", "enum": sorted(KIND_HINTS)}}},
                              generate_image, mutating=True))
        return tools

    # ------------------------------------------------------------------ phases
    def _artifact(self, name: str) -> dict | None:
        path = self.run_dir / name
        if not (self.cfg.reuse_artifacts and path.exists()):
            return None
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return None

    async def plan_phase(self, idea: dict) -> None:
        wf = self.wf
        wf.phase("Plan")
        pinned = self._artifact("plan.json")
        if isinstance(pinned, dict) and pinned.get("title"):
            self.plan = pinned
            wf.log("plan: reusing plan.json from this run")
            return
        plan = await wf.agent(prompts.plan_brief(idea), role="lead", system=prompts.LEAD_SYSTEM, schema=schemas.PLAN,
                              label="plan")
        if not isinstance(plan, dict):
            raise RuntimeError("the lead produced no plan")
        if self.cfg.plan_critique:
            crit = await wf.agent(prompts.plan_critique_brief(plan), role="critic", system=prompts.CRITIC_SYSTEM,
                                  schema=schemas.CRIT, label="plan-critique")
            serious = [i for i in (crit or {}).get("issues", []) if i.get("severity") in ("blocker", "major")]
            if crit and (crit.get("verdict") == "revise" or serious):
                revised = await wf.agent(prompts.plan_revise_brief(plan, crit), role=self.reviser,
                                         system=prompts.LEAD_SYSTEM, schema=schemas.PLAN, label="plan-revise")
                plan = revised if isinstance(revised, dict) else plan
        self.plan = plan
        self.save("plan.json", plan)

    async def style_phase(self) -> None:
        """Three art directions explored in parallel, a critic picks one (with grafts from the others), then
        measured readability problems and grafts are folded in by one revision."""
        from harness.tokens import contrast_issues
        wf = self.wf
        wf.phase("Style")
        pinned = self._artifact("style.json")
        if isinstance(pinned, dict) and isinstance(pinned.get("style"), dict):
            self.style = pinned["style"]
            self.style_md = style_markdown(self.style)
            src, problems = build_tokens(self.style)     # tokens are code-generated: re-run with today's repairs
            self.ws.write(TOKENS_PATH, src)
            wf.log("style: reusing style.json from this run" + (f"; tokens repaired: {'; '.join(problems[:4])}"
                                                                 if problems else ""))
            return
        cands = await wf.parallel([
            lambda i=i, a=a: wf.agent(prompts.style_brief(self.plan, a), role="art", system=prompts.ART_SYSTEM,
                                      schema=schemas.STYLE, label=f"style:{i}")
            for i, a in enumerate(prompts.STYLE_ANGLES)])
        cands = [c for c in cands if isinstance(c, dict)]
        if not cands:
            raise RuntimeError("the art director produced no style guide")
        style, grafts, why = cands[0], [], ""
        if len(cands) > 1:
            pick = await wf.agent(prompts.style_pick_brief(self.plan, [style_markdown(c) for c in cands],
                                                           [contrast_issues(c) for c in cands]),
                                  role="critic", system=prompts.CRITIC_SYSTEM, schema=schemas.STYLE_PICK,
                                  label="style-pick")
            if isinstance(pick, dict):
                idx = int(pick.get("choice", 0))
                style = cands[idx] if 0 <= idx < len(cands) else cands[0]
                grafts, why = list(pick.get("graft") or [])[:3], str(pick.get("why", ""))
        issues = contrast_issues(style)
        if issues or grafts:
            revised = await wf.agent(prompts.style_revise_brief(style, issues, grafts), role=self.reviser,
                                     system=prompts.ART_SYSTEM, schema=schemas.STYLE, label="style-revise")
            if isinstance(revised, dict) and len(contrast_issues(revised)) <= len(issues):
                style = revised
        self.save("style_candidates.json", {"candidates": cands, "picked_why": why, "grafts": grafts,
                                            "contrast_before": issues, "contrast_after": contrast_issues(style)})
        self.style = style
        self.style_md = style_markdown(style)
        src, problems = build_tokens(style)
        self.ws.write(TOKENS_PATH, src)
        if problems:
            wf.log("style tokens repaired: " + "; ".join(problems[:6]))
        self.save("style.json", {"style": style, "token_problems": problems})
        (self.run_dir / "style.md").write_text(self.style_md, encoding="utf-8")
        if self.cfg.reference_board and self.imagegen is not None and self.imagegen.enabled:
            await self.reference_board()

    async def reference_board(self) -> None:
        """Concept frames for the key screens and moments: targets for builders and judges, never assets."""
        shots = (self.style.get("reference_shots") or [])[:4]
        ref_dir = self.run_dir / "refs"
        ref_dir.mkdir(exist_ok=True)

        async def one(shot: dict) -> None:
            name = re.sub(r"[^a-z0-9_]+", "_", shot.get("name", "ref").lower()).strip("_") or "ref"
            best, best_score = None, -1.0
            for attempt in range(2):
                try:
                    out = await self.imagegen.generate(shot["prompt"], "background",
                                                       style=self.style.get("direction", ""), transparent=False)
                except Exception as e:  # noqa: BLE001
                    self.wf.log(f"reference {name} failed: {e}")
                    return
                v = await judge(self.judge_llm, "cohesion", [out["png"]],
                                intent=f"A concept frame for '{name}': {shot['prompt']}. Judge it as a target the "
                                       "team will build toward: does it fit the style guide and the bar?",
                                style=self.style_md, threshold=self.cfg.threshold)
                if v.score > best_score:
                    best, best_score = out["png"], v.score
                if v.score >= self.cfg.threshold:
                    break
            if best:
                (ref_dir / f"{name}.png").write_bytes(best)
                self.refs[name] = best
        await self.wf.parallel([lambda s=s: one(s) for s in shots])
        self.wf.log(f"reference board: {len(self.refs)} frame(s)")

    async def arch_phase(self) -> None:
        wf = self.wf
        wf.phase("Architect")
        pinned = self._artifact("architecture.json")
        if isinstance(pinned, dict) and isinstance(pinned.get("arch"), dict) and pinned["arch"].get("items"):
            self.arch = pinned["arch"]
            self.items = self.arch["items"]
            wf.log(f"architecture: reusing architecture.json from this run ({len(self.items)} items)")
            return
        arch = await wf.agent(prompts.arch_brief(self.plan, self.style_md, KIT_API), role=self.architect,
                              system=prompts.LEAD_SYSTEM, schema=schemas.ARCH, label="architecture")
        if not isinstance(arch, dict):
            raise RuntimeError("the lead produced no architecture")
        problems = arch_problems(arch)
        if problems:                        # one repair round: placement mistakes make code silently not run
            wf.log(f"architecture: {len(problems)} placement problem(s); asking the lead to fix them")
            fixed = await wf.agent(prompts.arch_fix_brief(arch, problems), role=self.reviser, system=prompts.LEAD_SYSTEM,
                                   schema=schemas.ARCH, label="architecture-fix")
            if isinstance(fixed, dict) and len(arch_problems(fixed)) < len(problems):
                arch = fixed
        self.arch, notes = normalize_arch(arch, self.cfg.max_items)
        self.items = self.arch["items"]
        if not self.items:
            raise RuntimeError("the architecture has no buildable items")
        for n in notes:
            wf.log("architecture: " + n)
        self.save("architecture.json", {"arch": self.arch, "notes": notes})

    async def scaffold(self) -> None:
        self.wf.phase("Scaffold")
        for rel, src in kit_files().items():
            self.ws.write(rel, src)
        if self.assets is not None:
            self.assets.ensure_map()
        else:
            self.ws.write("ReplicatedStorage/Shared/AssetMap.luau", "return {}\n")
        for f in self.arch["files"]:
            p = f["path"]
            if not (self.ws.src / p).exists():
                self.ws.write(p, stub_source(p, f.get("responsibility", ""), f.get("api", "")))
        if self.stage is not None:
            async with self.stage.lock:
                await self.stage.edit(lighting_script(self.style))
                synced = await self.stage.sync()
                try:
                    await self.stage.play()
                    logs = await self.stage.logs()
                finally:
                    await self.stage.stop()
            errs = [l for l in logs if l.get("kind") == "error"]
            self.wf.log(f"scaffold booted: {len(synced.get('pushed', []))} files pushed, {len(errs)} errors")
            self.save("scaffold_boot.json", {"sync": synced, "logs": logs})

    # ------------------------------------------------------------------ items
    async def build_items(self) -> None:
        self.wf.phase("Build")
        for it in self.items:
            self.done[it["id"]] = asyncio.Event()
            self.item_lock[it["id"]] = asyncio.Lock()

        async def run(it: dict):
            for dep in it.get("depends_on", []):
                await self.done[dep].wait()
            try:
                return await self.item(it)
            finally:
                self.done[it["id"]].set()
        await self.wf.parallel([lambda it=it: run(it) for it in self.items])

    async def build_agent(self, item: dict, brief: str | list[dict], label: str, system: str) -> dict | None:
        before = {p: _digest(s) for p, s in self.owned_sources(item).items()}
        rep = await self.wf.agent(brief, role="builder", system=system, tools=self.builder_tools(item),
                                  schema=schemas.REPORT, label=label, max_steps=self.cfg.builder_steps)
        after = {p: _digest(s) for p, s in self.owned_sources(item).items()}
        # One direct retry when the agent ended without changing anything AND something of its is still a stub.
        # (A builder resuming over files an earlier attempt already wrote may rightly change nothing.)
        unbuilt = [p for p, src in self.owned_sources(item).items() if not src.strip() or STUB_MARK in src]
        if before == after and unbuilt:
            nudge = ("You ended without changing any of your files. The task requires code changes. Write the "
                     "files now with write_file or edit_file, then submit.")
            again = brief + "\n\n" + nudge if isinstance(brief, str) else brief + [text_part(nudge)]
            rep = await self.wf.agent(again, role="builder", system=system, tools=self.builder_tools(item),
                                      schema=schemas.REPORT, label=label + "-retry", max_steps=self.cfg.builder_steps)
        # Gate: a builder may submit with a file that no longer parses (live: `{start = 0.3, end = 0.05}`, where
        # `end` is a keyword, took a whole VFX module down). Syntax errors go straight back for repair.
        for attempt in range(2):
            broken = syntax_errors(await check_sources(self.owned_sources(item)))
            if not broken:
                break
            listing = "\n".join(f"{p}:\n  " + "\n  ".join(errs[:10]) for p, errs in broken.items())
            fix = (f"Your files do not parse, so none of their code can run:\n{listing}\n\nFix exactly these syntax "
                   "errors with edit_file (read the lines around each first), keep everything else as it is, check "
                   "with check_code, then submit.")
            await self.wf.agent(fix, role="builder", system=prompts.FIXER_SYSTEM, tools=self.builder_tools(item),
                                schema=schemas.REPORT, label=f"{label}-syntax{attempt}", max_steps=12)
        return rep if isinstance(rep, dict) else None

    async def see(self, item: dict, label: str):
        cap = item["capture"]
        return await self.stage.capture(label, cap["kind"], cap.get("commands", []))

    async def assess(self, item: dict, capture, round_: int) -> Verdict:
        cap = item["capture"]
        intent = (f"{item['title']}: {item['brief']}\n\nWHAT THE CAPTURE SHOULD SHOW: {cap.get('description', '')}\n"
                  f"COMMANDS RUN BEFORE CAPTURE: {json.dumps(capture.command_results, default=str)[:1500]}")
        if capture.error:
            intent += f"\nCAPTURE FAILED: {capture.error}"
        errs = self.errors_by_item(capture.logs).get(item["id"], [])
        if errs:
            intent += "\nRUNTIME ERRORS FROM THIS ITEM'S SCRIPTS DURING CAPTURE:\n" + "\n".join(errs[:8])
        if capture.text:
            intent += "\nAUDIO MANIFEST (registered sounds and whether they load):\n" + capture.text[:6000]
        images = capture.images
        if cap["kind"] in ("moment", "loop") and len(images) > 2:
            images = [contact_sheet(images, cols=4, labels=[f"frame {i + 1}" for i in range(len(images))])]
        if not images:
            v = Verdict(item["aspect"], 1.0, False, [], [], {"note": "nothing captured"})
            from harness.judge import Issue
            v.issues.append(Issue("blocker", "capture", f"nothing could be captured: {capture.error or 'no images'}",
                                  "make the item's debug commands work and show it on screen"))
        else:
            v = await judge(self.judge_llm, item["aspect"], images, intent, self.style_md,
                            self.targets_for(item["aspect"]) or None, self.cfg.threshold)
        rec = {"round": round_, "score": v.score, "passed": v.passed, "issues": [i.__dict__ for i in v.issues],
               "strengths": v.strengths, "errors": errs[:10], "capture_error": capture.error}
        self.verdicts.setdefault(item["id"], []).append(rec)
        self.save(f"verdicts/{item['id']}.json", self.verdicts[item["id"]])
        return v

    def _built_state(self) -> dict:
        path = self.run_dir / "items_built.json"
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return {}

    def _mark_built(self, item: dict, report: dict | None) -> None:
        state = self._built_state()
        state[item["id"]] = {"report": report, "digests": {p: _digest(s) for p, s in self.owned_sources(item).items()}}
        self.save("items_built.json", state)

    async def item(self, item: dict) -> dict:
        wf = self.wf
        # Item-level resume: a build call's prompt carries the item's current code, so once a build has written its
        # files the journal can never replay it. Skip the build when the recorded files are exactly what is on disk.
        done = self._built_state().get(item["id"])
        current = {p: _digest(s) for p, s in self.owned_sources(item).items()}
        if done and done.get("digests") == current and not any(
                STUB_MARK in s for s in self.owned_sources(item).values()):
            wf.log(f"{item['id']}: already built (files unchanged); skipping the build agent")
            rep = done.get("report")
        else:
            brief = prompts.item_brief(item, self.plan, self.style_md, self.arch, self.owned_sources(item),
                                       extra=("GENERATED ART SO FAR\n" + self.assets.listing()) if self.assets else "")
            rep = await self.build_agent(item, brief, f"build:{item['id']}", prompts.BUILDER_SYSTEM)
            self._mark_built(item, rep)
        if self.stage is None:
            return {"id": item["id"], "report": rep}
        verdict = None
        for rnd in range(self.cfg.repair_rounds + 1):
            capture = await self.see(item, f"{item['id']}_r{rnd}")
            self.captures[item["id"]] = capture
            verdict = await self.assess(item, capture, rnd)
            wf.log(f"{item['id']} round {rnd}: {verdict.score:.1f}{' PASS' if verdict.passed else ''}")
            if verdict.passed or rnd == self.cfg.repair_rounds:
                break
            fix = self.fix_brief(item, verdict, capture)
            rep = await self.build_agent(item, fix, f"fix:{item['id']}:{rnd}", prompts.FIXER_SYSTEM)
        return {"id": item["id"], "report": rep, "score": verdict.score if verdict else None}

    def fix_brief(self, item: dict, verdict: Verdict, capture, extra_issues: list[str] | None = None) -> list[dict]:
        fixes = verdict.fix_list()
        if extra_issues:
            fixes += "\n" + "\n".join(f"- [routed] {x}" for x in extra_issues)
        errs = self.errors_by_item(capture.logs).get(item["id"], []) if capture else []
        if errs:
            fixes = "RUNTIME ERRORS (fix first):\n" + "\n".join(errs[:8]) + "\n\n" + fixes
        text = prompts.fix_brief(item, self.plan, self.style_md, self.arch, fixes, verdict.strengths,
                                 self.owned_sources(item), verdict.score)
        parts: list[dict] = [text_part(text)]
        imgs = (capture.images if capture else [])[:3]
        if imgs:
            parts.append(text_part("CAPTURES THE REVIEWERS SAW:"))
            parts += [image_part(im) for im in imgs]
        return parts

    # ------------------------------------------------------------------ whole game
    async def capture_all(self, label: str) -> dict[str, Any]:
        """One play session per item group is slow; one session for everything is fast. Captures each item's
        view in order, plus the logs, in a single visit."""
        from harness.stage import Capture
        out: dict[str, Capture] = {}
        async with self.stage.session() as synced:
            for it in self.items:
                cap = Capture(label=f"{label}_{it['id']}", sync=synced)
                for line in it["capture"].get("commands", []):
                    try:
                        cap.command_results.append({"command": line, **(await self.stage.cmd(line))})
                    except Exception as e:  # noqa: BLE001
                        cap.command_results.append({"command": line, "ok": False, "result": str(e)})
                kind = it["capture"]["kind"]
                try:
                    if kind in ("moment", "loop"):
                        cap.images = await self.stage.strip(3.0 if kind == "moment" else 6.0, 8, cap.label)
                    else:
                        await asyncio.sleep(1.2)
                        cap.images = [await self.stage.shot(cap.label)]
                except Exception as e:  # noqa: BLE001
                    cap.error = str(e)
                out[it["id"]] = cap
            logs = await self.stage.logs()
            for cap in out.values():
                cap.logs = logs
        return out

    async def integrate_and_polish(self) -> None:
        if self.stage is None:
            return
        wf = self.wf
        for rnd in range(self.cfg.polish_rounds):
            if self.out_of_time():
                wf.log("polish stopped: the deadline is near")
                break
            wf.phase("Polish" if rnd else "Integrate")
            caps = await self.capture_all(f"game_r{rnd}")
            sheet_imgs, labels = [], []
            for iid, cap in caps.items():
                if cap.images:
                    sheet_imgs.append(cap.images[0] if len(cap.images) < 3 else
                                      contact_sheet(cap.images[:4], cols=2))
                    labels.append(iid)
            if not sheet_imgs:
                wf.log("integration captured nothing; skipping the panel")
                return
            sheet = contact_sheet(sheet_imgs, cols=3, labels=labels)
            (self.run_dir / f"game_sheet_r{rnd}.png").write_bytes(sheet)
            logs = next(iter(caps.values())).logs if caps else []
            errors = self.errors_by_item(logs)
            intent = (f"The whole game '{self.plan.get('title', '')}': {self.plan.get('fantasy', '')}. Core loop: "
                      f"{' -> '.join(self.plan.get('core_loop', []))}. Signature moment: "
                      f"{self.plan.get('signature_moment', '')}. Each tile is one part of the game, labelled by work item.")
            results = await asyncio.gather(*(panel(self.judge_llm, a, [sheet], intent, self.style_md,
                                                   threshold=self.cfg.threshold) for a in ("cohesion", "polish")))
            issues = [i for r in results for i in r["issues"] if i.severity in ("blocker", "major", "minor")]
            scores = {a: r["min_score"] for a, r in zip(("cohesion", "polish"), results)}
            self.save(f"panel_r{rnd}.json", {"scores": scores, "issues": [i.__dict__ for i in issues],
                                             "errors": errors})
            wf.log(f"panel round {rnd}: {scores}; {len(issues)} issues; errors in {len(errors)} items")
            if not errors and not any(i.severity in ("blocker", "major") for i in issues):
                break
            route = await wf.agent(
                "Assign each issue to the work item that must fix it (by the tile label / item id and the files each "
                f"item owns).\n\nITEMS\n{prompts.compact_json([{'id': i['id'], 'title': i['title'], 'files': i['files']} for i in self.items], 4000)}"
                f"\n\nISSUES\n" + "\n".join(f"- [{i.severity}] {i.where}: {i.problem} -> {i.fix}" for i in issues[:40]),
                role=self.reviser, system=prompts.LEAD_SYSTEM, schema=schemas.ROUTE, label=f"route_r{rnd}")
            routed: dict[str, list[str]] = {}
            for a in (route or {}).get("assignments", []):
                if a.get("item_id") in self.done:
                    routed.setdefault(a["item_id"], []).extend(a.get("issues", []))
            for iid, errs in errors.items():
                routed.setdefault(iid, []).extend(f"runtime error: {e}" for e in errs)

            async def fix(iid: str, extra: list[str]):
                it = next(i for i in self.items if i["id"] == iid)
                last = (self.verdicts.get(iid) or [{}])[-1]
                from harness.judge import Issue
                v = Verdict(it["aspect"], float(last.get("score", 5.0)), False,
                            [Issue(**x) for x in last.get("issues", [])[:6]], last.get("strengths", []))
                brief = self.fix_brief(it, v, caps.get(iid), extra)
                await self.build_agent(it, brief, f"polish:{iid}:{rnd}", prompts.FIXER_SYSTEM)
            await wf.parallel([lambda i=i, e=e: fix(i, e) for i, e in routed.items()])

    def out_of_time(self) -> bool:
        return bool(self.cfg.deadline) and time.time() > self.cfg.deadline - self.cfg.reserve_seconds

    async def live_commands(self) -> dict:
        """Debug commands actually registered in the running game, server and client."""
        out: dict = {}
        for name in ("__list", "__client_list"):
            try:
                r = await self.stage.cmd(name)
            except Exception:  # noqa: BLE001
                continue
            texts = [r.get("result")] + [rep.get("result") for rep in (r.get("replies") or [])[:1]]
            for t in texts:
                try:
                    out.update(json.loads(t or "{}"))
                except (TypeError, ValueError):
                    pass
        return {k: v for k, v in out.items() if not str(k).startswith("__")}

    _EVIDENCE_FILE = re.compile(r"^captures/[a-z0-9_+]+__[A-Za-z0-9_\-]+(\.png)?$")

    async def run_shot(self, shot: dict) -> dict:
        file = str(shot.get("file", "")).strip().replace("\\", "/")
        if not self._EVIDENCE_FILE.match(file):
            return {"file": file, "ok": False, "error": "not a captures/<aspect>__<name> path"}
        base = file[:-4] if file.endswith(".png") else file
        results = []
        for line in shot.get("commands") or []:
            try:
                results.append({"command": line, **(await self.stage.cmd(line))})
            except Exception as e:  # noqa: BLE001
                results.append({"command": line, "ok": False, "result": str(e)})
        keys = [k for k in (shot.get("keys") or []) if isinstance(k, dict) and k.get("key")][:12]
        await asyncio.sleep(max(0.2, min(6.0, float(shot.get("settle") or 1.0))))
        label = base.split("/", 1)[1]
        try:
            if shot.get("kind") == "strip":
                seconds = max(0.5, min(12.0, float(shot.get("seconds") or 2.0)))
                n = max(2, min(16, int(shot.get("frames") or 8)))
                task = asyncio.create_task(self.stage.strip(seconds, n, label))
                await asyncio.sleep(0.15)
                for k in keys:
                    await self.stage.key(str(k["key"]), int(k.get("hold_ms") or 0))
                frames = await task
                for i, png in enumerate(frames):
                    (self.run_dir / f"{base}__{i:02d}.png").write_bytes(png)
                return {"file": base, "ok": bool(frames), "frames": len(frames), "commands": results}
            for k in keys:
                await self.stage.key(str(k["key"]), int(k.get("hold_ms") or 0))
            png = await self.stage.shot(label)
            (self.run_dir / f"{base}.png").write_bytes(png)
            return {"file": f"{base}.png", "ok": True, "commands": results}
        except Exception as e:  # noqa: BLE001
            return {"file": file, "ok": False, "error": str(e), "commands": results}

    async def evidence(self, plan: dict) -> dict:
        """The benchmark's evidence, captured in one play session from a script the lead writes against the
        game's registered debug commands. Logs come from the kit: events, output, and every sound played."""
        wf = self.wf
        wf.phase("Evidence")
        (self.run_dir / "captures").mkdir(exist_ok=True)
        (self.run_dir / "logs").mkdir(exist_ok=True)
        wanted = [{"file": e.get("file"), "kind": e.get("kind"), "what": e.get("what"),
                   "required": e.get("required", False), "frames": e.get("frames")}
                  for e in plan.get("items", []) if e.get("kind") in ("still", "strip")]
        done: list[dict] = []
        commands: dict = {}
        async with self.stage.lock:
            await self.stage.sync()
            try:
                await self.stage.play()
                commands = await self.live_commands()
                script = await wf.agent(prompts.director_brief(self.plan, self.arch, self.items, wanted, commands),
                                        role="lead", system=prompts.LEAD_SYSTEM, schema=schemas.CAPTURE_SCRIPT,
                                        label="capture-director")
                for shot in (script or {}).get("shots", [])[:60]:
                    done.append(await self.run_shot(shot))
                logs = await self.stage.logs()
                events = await self.stage.events()
                try:
                    manifest = await self.stage.cmd("__sound_manifest")
                except Exception as e:  # noqa: BLE001
                    manifest = {"error": str(e)}
            finally:
                await self.stage.stop()
        L = self.run_dir / "logs"
        (L / "output.log").write_text("\n".join(
            f"{e.get('t', 0):9.2f} [{e.get('side', '')}] {e.get('kind', '')}: {e.get('text', '')}" for e in logs),
            encoding="utf-8")
        (L / "playtest.log").write_text("\n".join(
            f"{e.get('t', 0):9.2f} [{e.get('side', '')}] {e.get('name', '')} {json.dumps(e.get('data'), default=str)}"
            for e in events if e.get("name") != "sound"), encoding="utf-8")
        (L / "audio_events.log").write_text("\n".join(
            f"{e.get('t', 0):9.2f} {json.dumps(e.get('data'), default=str)}" for e in events if e.get("name") == "sound"),
            encoding="utf-8")
        text = json.dumps(manifest.get("replies") or manifest, indent=1, ensure_ascii=False, default=str)
        (self.run_dir / "captures" / "audio_design__sound_map.png").write_bytes(text_image("SOUND MAP", text))
        self.save("evidence.json", {"shots": done, "commands": commands})
        wf.log(f"evidence: {sum(1 for d in done if d.get('ok'))}/{len(done)} shots captured")
        return {"shots": done}

    async def final_report(self, t0: float) -> dict:
        self.wf.phase("Report")
        final = {}
        if self.stage is not None:
            async with self.stage.lock:
                await self.stage.sync()
            caps = await self.capture_all("final")
            for it in self.items:
                v = await self.assess(it, caps[it["id"]], 99)
                final[it["id"]] = {"aspect": it["aspect"], "score": v.score, "passed": v.passed}
        try:                                   # the bridge cannot save places: build the final one with rojo
            from harness.place import build_place
            build_place(self.ws.root, self.run_dir / "place" / "final.rbxlx", self.plan.get("title") or "game",
                        style=self.style)
        except Exception as e:  # noqa: BLE001
            self.wf.log(f"could not build the final place: {e}")
        by_aspect: dict[str, list[float]] = {}
        for r in final.values():
            by_aspect.setdefault(r["aspect"], []).append(r["score"])
        report = {"title": self.plan.get("title"), "seconds": round(time.time() - t0),
                  "items": final, "aspects": {a: round(sum(v) / len(v), 2) for a, v in by_aspect.items()},
                  "run_dir": str(self.run_dir)}
        self.save("report.json", report)
        return report

    async def run(self, idea: dict, evidence_plan: dict | None = None) -> dict:
        t0 = time.time()
        await self.plan_phase(idea)
        await self.style_phase()
        await self.arch_phase()
        await self.scaffold()
        await self.build_items()
        if self.cfg.integrate:
            await self.integrate_and_polish()
        report = await self.final_report(t0)
        if evidence_plan and self.stage is not None:
            report["evidence"] = await self.evidence(evidence_plan)
            self.save("report.json", report)
        return report


# ------------------------------------------------------------------------------------------------ entry point

async def run_build(idea: dict, run_dir: Path, *, cfg: BuildConfig | None = None, studio: bool = True,
                    resume: bool = True, allow_place_ids: set[str] | None = None,
                    evidence_plan: dict | None = None) -> dict:
    from harness.llm import llm_from_env
    from harness.workflow import Workflow
    from harness.tools.workspace import Workspace
    run_dir = Path(run_dir)
    run_dir.mkdir(parents=True, exist_ok=True)
    roles = {r: llm_from_env(r) for r in ("lead", "art", "builder", "critic", "judge", "reviser", "architect")}
    wf = Workflow(f"build_game:{idea.get('id', 'game')}", run_dir, roles, resume=resume)
    ws = Workspace(run_dir / "workspace")
    run_id = re.sub(r"[^a-z0-9_]+", "_", f"{idea.get('id', 'game')}_{run_dir.name}".lower())
    stage = bridge = None
    from harness.tools.imagegen import AssetStore, ImageGen
    imagegen = ImageGen()
    exe = None
    if studio:
        from harness.stage import Stage, studio_exe
        from harness.tools.studio import StudioBridge
        bridge = StudioBridge(allow_place_ids={"0"} | set(allow_place_ids or ()),
                              place_marker=("ServerStorage.CybusHarnessRun", run_id))
        await bridge.connect()
        stage = Stage(bridge, ws, run_dir, run_id)
        await stage.start()
        await stage.launch()
        exe = studio_exe()
    assets = AssetStore(run_dir, ws, run_id, exe) if imagegen.enabled else None
    try:
        build = Build(wf, ws, stage, roles["judge"], cfg or BuildConfig(), run_dir, imagegen, assets)
        try:
            from harness.tools.art import art_tools
            from harness.tools.texpack import TexturePacks
            build.extra_tools = art_tools(TexturePacks(ws), run_dir / "art")
        except ImportError:
            log.warning("texture painting unavailable (harness.tools.art missing)")
        try:
            from harness.tools.anim import ClipPack, anim_tools
            build.extra_tools = build.extra_tools + anim_tools(ClipPack(ws), run_dir / "art")
        except ImportError:
            log.warning("clip authoring unavailable (harness.tools.anim missing)")
        try:
            from harness.tools import fxspec
            build.extra_tools = build.extra_tools + fxspec.tools()
        except ImportError:
            log.warning("effect-spec checking unavailable (harness.tools.fxspec missing)")
        report = await build.run(idea, evidence_plan)
        final = run_dir / "place" / "final.rbxlx"
        if final.exists():
            report["place_file"] = str(final)
            report["rojo_project"] = str(ws.root / "default.project.json")
        return report
    finally:
        if stage is not None:
            await stage.close()
        if bridge is not None:
            await bridge.close()


async def build_game(idea: dict, run_dir, **opts) -> dict:
    """Entry point for bench/run_bench.py: opts may carry budget_hours, deadline, evidence_plan and
    allow_place_ids (model selection is by HARNESS_<ROLE>_* environment variables)."""
    cfg = BuildConfig()
    if opts.get("budget_hours"):
        cfg.deadline = time.time() + float(opts["budget_hours"]) * 3600
    elif isinstance(opts.get("deadline"), (int, float)):
        cfg.deadline = float(opts["deadline"])
    return await run_build(idea, Path(run_dir), cfg=cfg,
                           allow_place_ids=set(map(str, opts.get("allow_place_ids") or [])),
                           evidence_plan=opts.get("evidence_plan"))


def main() -> int:
    ap = argparse.ArgumentParser(description="Build a Roblox game from a pitch with the cybus harness.")
    ap.add_argument("--idea", required=True, help="path to a YAML/JSON idea, or bench/ideas.yaml#<id>")
    ap.add_argument("--run-dir", required=True)
    ap.add_argument("--no-studio", action="store_true", help="plan and write code only (no capture/judge)")
    ap.add_argument("--repair-rounds", type=int, default=2)
    ap.add_argument("--polish-rounds", type=int, default=2)
    a = ap.parse_args()
    import yaml
    path, _, key = a.idea.partition("#")
    data = yaml.safe_load(Path(path).read_text(encoding="utf-8"))
    if key:
        pool = data.get("ideas", data) if isinstance(data, dict) else data
        idea = next(i for i in pool if i.get("id") == key)
    else:
        idea = data
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(message)s")
    cfg = BuildConfig(repair_rounds=a.repair_rounds, polish_rounds=a.polish_rounds)
    report = asyncio.run(run_build(idea, Path(a.run_dir), cfg=cfg, studio=not a.no_studio))
    print(json.dumps(report, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

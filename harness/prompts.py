"""System prompts and brief builders for the build workflow's roles.

Every brief is self-contained: it carries the bar, the rules, the style tokens and the files the task needs,
so an agent spends its turns building, not exploring. Keep these short; the model's context is precious.
"""
from __future__ import annotations

import json

from harness.judge import playbook
from harness.tokens import ROBLOX_FONTS

BAR = ("THE BAR: a cohesive, AAA-feeling Roblox game on the studio scale (1 broken, 4 hobby, 7 strong "
       "front-page, 9 the bar). Custom visual language everywhere, cinematic camera, layered VFX and audio, tuned "
       "feel, restraint, payoff moments that land. Generic, flat, default-looking work is below the bar.")

LEAD_SYSTEM = f"""You are the lead designer and technical director of a small Roblox studio. You turn a pitch into
a plan a team of developers can build in parallel, and you keep the whole game coherent.
{BAR}
Be concrete: numbers, names, files, inputs. Scope for a polished vertical slice, not a sprawling feature list."""

ART_SYSTEM = f"""You are the art director of a Roblox studio. You define the game's visual and audio language as a
style guide with concrete values that every developer and critic works against.
{BAR}
Every value is concrete (hex codes, font names, sizes in dp, durations in seconds). Choose a direction that is
specific to THIS game's fantasy, not a generic default."""

PRE = """RULES FOR EVERY DEVELOPER ON THIS TEAM
- Other developers are working in parallel. Edit ONLY the files listed as yours. If you need a change in a file
  you do not own, describe it under "requests" in your report.
- Every file must stay loadable at every moment: complete modules, no syntax errors, and fail soft on missing
  pieces (pcall around require of other owners' modules, WaitForChild with a timeout).
- Read every colour, font, text size, spacing, radius, duration and easing from the Tokens module
  (ReplicatedStorage.Shared.Tokens). No magic numbers for style.
- Use the kit modules in ReplicatedStorage.Kit (Maid, Spring, Motion, Shake, Sound, Debug) instead of rewriting
  them. Register a Debug command that shows your work so it can be captured.
- Write complete, working code: no placeholders, TODOs, or "art goes here". Custom art is yours to make:
  paint textures with paint_texture (layered shapes, gradients, soft shadows, glows: panel and button skins,
  icons, particle and beam textures) and apply them with Kit Textures; build 3D art from parts. Find sounds
  with search_audio and register them with Kit Sound. Nothing is uploaded.
- Finish by calling submit with your report."""

BUILDER_SYSTEM = f"""You are a senior Roblox developer with a strong eye for visual craft, feel and polish.
{BAR}
You write idiomatic, typed Luau for the client/server model. You build what a player sees and feels, to the
game's style guide, and you make it look authored, not generic.
{PRE}"""

FIXER_SYSTEM = f"""You are a senior Roblox developer repairing a piece of the game after a review. You get the
reviewers' issues (most severe first), the captures they looked at, and the current code.
Fix every blocker and major issue, then as many minor ones as you can, without breaking what already works
(the strengths). Change the code; do not argue with the review unless an issue is impossible, and then explain
why in open_issues.
{BAR}
{PRE}"""

CRITIC_SYSTEM = f"""You are a demanding reviewer at a Roblox studio. You find the problems that would keep this
below the bar, and you give a concrete fix for each.
{BAR}"""


def compact_json(obj, limit: int = 6000) -> str:
    s = json.dumps(obj, indent=1, ensure_ascii=False)
    return s if len(s) <= limit else s[:limit] + "\n... (truncated)"


def plan_brief(idea: dict) -> str:
    return (f"PITCH\n{compact_json(idea, 3000)}\n\nHOW TO PLAN\n{playbook('plan')}\n\n"
            "Write the plan with submit. Keep systems to the few the core loop needs; list every screen the player "
            "sees; name the signature moment precisely. Under aspects, say what 'done' looks like for each of: "
            "ui_menus, hud, camera, game_feel, vfx, animation, world_art, characters, audio_design, core_loop, "
            "cohesion, polish.")


def plan_critique_brief(plan: dict) -> str:
    return (f"Review this game plan before the team builds it.\n\nPLAN\n{compact_json(plan)}\n\n"
            "Check: is the core loop clear and fun within 30 seconds? Is the signature moment specific and "
            "worth the craft? Is the scope buildable as a polished vertical slice by a small team in a day? "
            "Are any systems or screens missing for the loop to work end to end? Reply with a verdict and "
            "concrete issues.")


def plan_revise_brief(plan: dict, crit: dict) -> str:
    return (f"Revise the plan to address the review. Keep what works.\n\nPLAN\n{compact_json(plan)}\n\n"
            f"REVIEW\n{compact_json(crit, 3000)}\n\nSubmit the full revised plan.")


STYLE_ANGLES = (
    "the boldest, most distinctive direction that still serves the fantasy: a look nobody would mistake for "
    "another game",
    "the most readable and cohesive direction: calm, confident, every element clearly part of one system",
    "the most cinematic and atmospheric direction: light, mood, depth and a strong time of day first",
)


def style_brief(plan: dict, angle: str | None = None) -> str:
    return (f"GAME PLAN\n{compact_json(plan, 4000)}\n\nSTYLE GUIDE TEMPLATE\n{playbook('style_guide')}\n\n"
            + (f"DIRECTION TO EXPLORE: {angle}\n\n" if angle else "")
            + "Write this game's style guide with submit. Fonts: ONLY these Roblox font families (anything else "
            f"falls back to a default at runtime): {', '.join(ROBLOX_FONTS)}; optionally ':Weight' "
            "(Thin, Light, Regular, Medium, SemiBold, Bold, ExtraBold, Heavy), e.g. 'Montserrat:Bold'. "
            "Lighting post effects use Roblox ranges: Atmosphere Density/Offset 0-1, Haze/Glare 0-10; "
            "ColorCorrection Brightness/Contrast/Saturation -1..1; Bloom Intensity 0-2, Size 0-56, Threshold 0-4. "
            "Palette: #RRGGBB with the required roles "
            "plus any game-specific tokens. reference_shots: 3-4 image-generation prompts for concept frames of the "
            "key screens and moments (title screen, gameplay with HUD, the signature moment), each a complete, "
            "specific description in the style guide's language, framed as a Roblox game screenshot.")


def style_pick_brief(plan: dict, candidates: list[str], issues: list[list[str]]) -> str:
    blocks = []
    for i, (md, iss) in enumerate(zip(candidates, issues)):
        measured = "\n".join(f"  - {x}" for x in iss) or "  - none"
        blocks.append(f"=== CANDIDATE {i} ===\n{md[:3500]}\nMEASURED READABILITY PROBLEMS:\n{measured}")
    return (f"GAME: {plan.get('title', '')}: {plan.get('fantasy', '')}\nSignature moment: "
            f"{plan.get('signature_moment', '')}\n\n" + "\n\n".join(blocks) + "\n\n"
            "Pick the style guide that will make the best game at the bar: specific to this fantasy (not a generic "
            "default), internally cohesive (palette, type, shapes, motion, light and sound tell one story), "
            "readable, and buildable in Roblox. Readability problems can be fixed; a generic or incoherent direction "
            "cannot. Give the index, why, and up to 3 specific ideas from the other candidates worth grafting in.")


def style_revise_brief(style: dict, issues: list[str], grafts: list[str]) -> str:
    fixes = "\n".join(f"- {x}" for x in issues) or "- none"
    graft = "\n".join(f"- {x}" for x in grafts) or "- none"
    return (f"STYLE GUIDE\n{compact_json(style, 9000)}\n\nMEASURED READABILITY PROBLEMS (fix every one by adjusting "
            f"the colours, keeping the direction's character)\n{fixes}\n\nIDEAS TO GRAFT IN (only where they fit the "
            f"direction)\n{graft}\n\nSubmit the full revised style guide.")


def arch_brief(plan: dict, style_md: str, kit_api: str) -> str:
    return (f"GAME PLAN\n{compact_json(plan, 5000)}\n\nSTYLE (summary)\n{style_md[:2500]}\n\n"
            f"KIT MODULES ALREADY PROVIDED (do not list them as files)\n{kit_api}\n\n"
            "Design the code architecture and split the work into items for parallel developers.\n"
            "FILES: every Luau file with its path under src/ (e.g. src/ServerScriptService/Game.server.luau, "
            "src/StarterPlayer/StarterPlayerScripts/Hud.client.luau, src/ReplicatedStorage/Shared/Config.luau), "
            "its responsibility and its public API (function signatures, events). Keep files focused (< 400 lines "
            "each when written). The suffix decides what a file IS: .server.luau = a Script that runs by itself "
            "(ServerScriptService only), .client.luau = a LocalScript that runs by itself (StarterPlayerScripts, "
            "StarterCharacterScripts, StarterGui or ReplicatedFirst only), .luau = a ModuleScript that does nothing "
            "until required. Anything other code requires MUST be a .luau ModuleScript; give the server and the "
            "client each one entry script that requires the modules. Server-only modules live in ServerScriptService "
            "or ServerStorage, shared ones in ReplicatedStorage.\n"
            "REMOTES: every RemoteEvent/RemoteFunction, direction and payload. The server validates everything.\n"
            "DEBUG COMMANDS: commands the test harness can call in a running game to show a screen, start a round, "
            "trigger the signature moment, grant rewards, etc., so every part of the game can be captured.\n"
            "ITEMS: 8-16 work items. Each owns a disjoint set of files, has one aspect, a brief a developer can "
            "build from without further questions (what to build, which tokens and kit modules to use, the "
            "interactions and states), depends_on (item ids it needs first), and capture (how to see it: kind "
            "screen/moment/world/loop/audio, the debug commands to run before capturing, and what the capture "
            "should show). The first items build the core loop in greybox; later items give each screen, the "
            "world, the camera, the VFX set, the animation set and the audio their craft. Every file belongs "
            "to exactly one item.")


# Which craft notes (sections of roblox_craft.md) and spec references each aspect's builder gets.
CRAFT_SECTIONS = {
    "ui_menus": ("UI",), "hud": ("UI", "Feel and VFX"), "camera": ("Camera",), "game_feel": ("Feel and VFX", "Camera"),
    "vfx": ("Feel and VFX",), "animation": ("Animation",), "world_art": ("World and lighting",),
    "characters": ("Animation", "World and lighting"), "audio_design": ("Audio",),
    "core_loop": ("Project shape", "Robustness"), "cohesion": ("UI", "World and lighting"), "polish": ("Robustness", "UI"),
}
SPEC_PLAYBOOKS = {
    "texture_spec": {"ui_menus", "hud", "vfx", "world_art", "characters", "polish", "cohesion"},
    "animation_spec": {"animation", "characters", "game_feel"},
    "vfx_camera_spec": {"vfx", "camera", "game_feel"},
}


def craft_notes(aspect: str) -> str:
    text = playbook("roblox_craft")
    wanted = ("Project shape",) + CRAFT_SECTIONS.get(aspect, ())
    parts, keep = [], False
    for line in text.splitlines():
        if line.startswith("## "):
            keep = line[3:].strip() in wanted
        if keep:
            parts.append(line)
    return "\n".join(parts)


def spec_refs(aspect: str, limit: int = 12000) -> str:
    out = [f"=== {name} ===\n{playbook(name)[:limit]}" for name, aspects in SPEC_PLAYBOOKS.items()
           if aspect in aspects and playbook(name)]
    return "\n\n".join(out)


def arch_fix_brief(arch: dict, problems: list[str]) -> str:
    return (f"ARCHITECTURE\n{compact_json(arch, 20000)}\n\nPROBLEMS (each makes code silently not run in Roblox)\n"
            + "\n".join(f"- {p}" for p in problems)
            + "\n\nFix every problem (rename or move files, turn required files into .luau ModuleScripts with one entry "
            "script per side, update the items' file lists and briefs to match) and submit the full corrected "
            "architecture.")


def shared_context(plan: dict, style_md: str, arch: dict) -> str:
    """What every builder of this game reads, identical across items and rounds, so it forms one long prefix the
    model server caches (put nothing item-specific in here)."""
    from harness.kit import KIT_API
    files = [{"path": f["path"], "api": f["api"]} for f in arch.get("files", [])]
    return (f"GAME\n{plan.get('title', '')}: {plan.get('fantasy', '')}\nCore loop: {' -> '.join(plan.get('core_loop', []))}\n"
            f"Signature moment: {plan.get('signature_moment', '')}\n\n"
            f"STYLE GUIDE\n{style_md[:5000]}\n\n"
            f"KIT (already in the game)\n{KIT_API}\n\n"
            f"EVERY FILE IN THE GAME AND ITS API (edit only the ones listed as yours below; call the others)\n"
            f"{compact_json(files, 6000)}\n\n"
            f"{PATHS_RULE}\n\n"
            f"REMOTES\n{compact_json(arch.get('remotes', []), 1500)}\n\n")


PATHS_RULE = (
    "WHERE FILES LIVE: a file's instance is its path without the suffix, '/' -> '.': "
    "ServerScriptService/Systems/Economy.luau is ServerScriptService.Systems.Economy. Walk to a module one name at a "
    "time: script.Parent:WaitForChild(\"Systems\"):WaitForChild(\"Economy\") from ServerScriptService/Main.server.luau, "
    "or game:GetService(\"ServerScriptService\").Systems.Economy. WaitForChild takes ONE name, never a dotted path "
    "like \"Kit.Maid\". Files under StarterPlayer/StarterPlayerScripts run from the player's PlayerScripts (their "
    "script.Parent is PlayerScripts). Clients cannot see ServerScriptService or ServerStorage. Use only real Roblox "
    "names: a property, enum item or class that does not exist errors on that line (Enum.FontWeight has Regular, not "
    "Normal; a Beam's ends are Attachment0/Attachment1). check_code reports requires that do not reach a real module "
    "(WIRING) and Roblox names that do not exist (API).")


def aspect_context(aspect: str, spec_limit: int = 12000) -> str:
    """What every builder of one aspect reads (shared by all items and rounds of that aspect)."""
    refs = spec_refs(aspect, spec_limit)
    return (f"RUBRIC YOUR WORK WILL BE JUDGED ON ({aspect})\n{playbook('rubric_' + aspect)[:3500]}\n\n"
            f"CRAFT NOTES\n{craft_notes(aspect)}\n\n"
            + (f"SPEC REFERENCES FOR YOUR TOOLS\n{refs}\n\n" if refs else ""))


def item_brief(item: dict, plan: dict, style_md: str, arch: dict, files: dict[str, str], extra: str = "") -> str:
    owned = "\n".join(f"- {f}" for f in item.get("files", []))
    ctx = "\n\n".join(f"--- {path} ---\n{src}" for path, src in files.items())
    return (shared_context(plan, style_md, arch) + aspect_context(item["aspect"])
            + f"YOUR ITEM: {item['id']} - {item['title']} (aspect: {item['aspect']})\n{item['brief']}\n\n"
            f"FILES YOU OWN\n{owned}\n\n"
            f"HOW IT WILL BE CAPTURED\n{compact_json(item.get('capture', {}), 800)}\n\n"
            + (f"CURRENT CONTENT OF YOUR FILES\n{ctx}\n\n" if ctx else "")
            + (extra + "\n\n" if extra else "")
            + "Build it now: write your files, then submit your report.")


def fix_brief(item: dict, plan: dict, style_md: str, arch: dict, fix_list: str, strengths: list[str],
              files: dict[str, str], score: float) -> str:
    """Same shared prefix as the item brief (cached by the model server), then this round's review and code."""
    ctx = "\n\n".join(f"--- {path} ---\n{src}" for path, src in files.items())
    keep = "\n".join(f"- {s}" for s in strengths[:8]) or "- (none noted)"
    owned = "\n".join(f"- {f}" for f in item.get("files", []))
    return (shared_context(plan, style_md, arch) + aspect_context(item["aspect"])
            + f"YOUR ITEM: {item['id']} - {item['title']} (aspect: {item['aspect']})\n{item['brief']}\n\n"
            f"FILES YOU OWN\n{owned}\n\n"
            f"REVIEW SCORE: {score:.1f}/10 on the studio scale. The captures the reviewers saw are attached.\n\n"
            f"ISSUES TO FIX (most severe first)\n{fix_list}\n\nKEEP THESE STRENGTHS\n{keep}\n\n"
            f"CURRENT CODE (files you own)\n{ctx}\n\nFix the issues in the code now, then submit your report.")


def director_brief(plan: dict, arch: dict, items: list[dict], evidence: list[dict], commands: dict) -> str:
    shown = [{"id": i["id"], "aspect": i["aspect"], "capture": i["capture"]} for i in items]
    return (f"GAME: {plan.get('title', '')}: {plan.get('fantasy', '')}\n"
            f"Core loop: {' -> '.join(plan.get('core_loop', []))}\n"
            f"Signature moment: {plan.get('signature_moment', '')}\n\n"
            f"DEBUG COMMANDS REGISTERED IN THE RUNNING GAME (name: description)\n{compact_json(commands, 5000)}\n\n"
            "BUILT-IN COMMANDS: __camera x y z lookX lookY lookZ fov (place the camera; no arguments resets it), "
            "__move x z seconds (walk the character relative to the camera; 0 -1 2 = forward for 2 s; in a strip it "
            "plays while recording), __jump, __players (player positions), __ui (screen guis).\n"
            "KEYS (only when nothing else works: they are skipped unless Studio has focus; hold_ms holds): a-z, 0-9, "
            "space, enter, escape, tab, left/right/up/down, shift, ctrl, alt.\n\n"
            f"HOW EACH WORK ITEM IS SHOWN\n{compact_json(shown, 4000)}\n\n"
            f"EVIDENCE TO CAPTURE (file, still/strip, what it must show, required)\n{compact_json(evidence, 7000)}\n\n"
            "Write the capture script: one shot per evidence file you can honestly show (every required one, "
            "optional ones when the game has them; for wildcard names like menu_* write one file per screen, e.g. "
            "captures/ui_menus__menu_shop.png). Shots run in order in ONE play session: put commands that change "
            "the game state (start a round, open a screen, trigger the signature moment, move the camera) before "
            "the shot, and close screens / reset the camera afterwards so the next shot starts clean. For strips "
            "give seconds and frames; keys held during a strip are pressed while it records. Show the game as it "
            "is: never stage anything the game would not show a player.")

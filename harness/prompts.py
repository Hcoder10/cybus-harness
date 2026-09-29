"""System prompts and brief builders for the build workflow's roles.

Every brief is self-contained: it carries the bar, the rules, the style tokens and the files the task needs,
so an agent spends its turns building, not exploring. Keep these short; the model's context is precious.
"""
from __future__ import annotations

import json

from harness.judge import playbook

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


def style_brief(plan: dict) -> str:
    return (f"GAME PLAN\n{compact_json(plan, 4000)}\n\nSTYLE GUIDE TEMPLATE\n{playbook('style_guide')}\n\n"
            "Write this game's style guide with submit. Fonts: Roblox font names (Enum.Font names such as "
            "GothamBlack, FredokaOne, Michroma, Bangers, Oswald, Roboto, TitilliumWeb, LuckiestGuy, Sarpanch, "
            "BuilderSans; optionally ':Weight', e.g. 'Montserrat:Bold'). Palette: #RRGGBB with the required roles "
            "plus any game-specific tokens. reference_shots: 3-4 image-generation prompts for concept frames of the "
            "key screens and moments (title screen, gameplay with HUD, the signature moment), each a complete, "
            "specific description in the style guide's language, framed as a Roblox game screenshot.")


def arch_brief(plan: dict, style_md: str, kit_api: str) -> str:
    return (f"GAME PLAN\n{compact_json(plan, 5000)}\n\nSTYLE (summary)\n{style_md[:2500]}\n\n"
            f"KIT MODULES ALREADY PROVIDED (do not list them as files)\n{kit_api}\n\n"
            "Design the code architecture and split the work into items for parallel developers.\n"
            "FILES: every Luau file with its path under src/ (e.g. src/ServerScriptService/Game.server.luau, "
            "src/StarterPlayer/StarterPlayerScripts/Hud.client.luau, src/ReplicatedStorage/Shared/Config.luau), "
            "its responsibility and its public API (function signatures, events). Keep files focused (< 400 lines "
            "each when written).\n"
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


def item_brief(item: dict, plan: dict, style_md: str, arch: dict, files: dict[str, str], extra: str = "") -> str:
    owned = "\n".join(f"- {f}" for f in item.get("files", []))
    ctx = "\n\n".join(f"--- {path} ---\n{src}" for path, src in files.items())
    others = [{"path": f["path"], "api": f["api"]} for f in arch.get("files", []) if f["path"] not in item.get("files", [])]
    return (f"YOUR ITEM: {item['id']} - {item['title']} (aspect: {item['aspect']})\n{item['brief']}\n\n"
            f"FILES YOU OWN\n{owned}\n\n"
            f"GAME\n{plan.get('title', '')}: {plan.get('fantasy', '')}\nCore loop: {' -> '.join(plan.get('core_loop', []))}\n"
            f"Signature moment: {plan.get('signature_moment', '')}\n\n"
            f"STYLE GUIDE\n{style_md[:5000]}\n\n"
            f"RUBRIC YOUR WORK WILL BE JUDGED ON\n{playbook('rubric_' + item['aspect'])[:3500]}\n\n"
            f"OTHER FILES' APIS (call these; do not edit them)\n{compact_json(others, 3500)}\n\n"
            f"REMOTES\n{compact_json(arch.get('remotes', []), 1500)}\n\n"
            f"HOW IT WILL BE CAPTURED\n{compact_json(item.get('capture', {}), 800)}\n\n"
            + (f"CURRENT CONTENT OF RELEVANT FILES\n{ctx}\n\n" if ctx else "")
            + (extra + "\n\n" if extra else "")
            + "Build it now: write your files, then submit your report.")


def fix_brief(item: dict, style_md: str, fix_list: str, strengths: list[str], files: dict[str, str],
              score: float) -> str:
    ctx = "\n\n".join(f"--- {path} ---\n{src}" for path, src in files.items())
    keep = "\n".join(f"- {s}" for s in strengths[:8]) or "- (none noted)"
    return (f"ITEM: {item['id']} - {item['title']} (aspect: {item['aspect']})\n{item['brief']}\n\n"
            f"REVIEW SCORE: {score:.1f}/10 on the studio scale. The captures the reviewers saw are attached.\n\n"
            f"ISSUES TO FIX (most severe first)\n{fix_list}\n\nKEEP THESE STRENGTHS\n{keep}\n\n"
            f"STYLE GUIDE\n{style_md[:4000]}\n\nRUBRIC\n{playbook('rubric_' + item['aspect'])[:3000]}\n\n"
            f"CURRENT CODE (files you own)\n{ctx}\n\nFix the issues in the code now, then submit your report.")


def director_brief(plan: dict, arch: dict, items: list[dict], evidence: list[dict], commands: dict) -> str:
    shown = [{"id": i["id"], "aspect": i["aspect"], "capture": i["capture"]} for i in items]
    return (f"GAME: {plan.get('title', '')}: {plan.get('fantasy', '')}\n"
            f"Core loop: {' -> '.join(plan.get('core_loop', []))}\n"
            f"Signature moment: {plan.get('signature_moment', '')}\n\n"
            f"DEBUG COMMANDS REGISTERED IN THE RUNNING GAME (name: description)\n{compact_json(commands, 5000)}\n\n"
            "BUILT-IN COMMANDS: __camera x y z lookX lookY lookZ fov (place the camera; no arguments resets it), "
            "__players (player positions), __ui (screen guis).\n"
            "KEYS you can press (sent to the game window; hold_ms holds): a-z, 0-9, space, enter, escape, tab, "
            "left/right/up/down, shift, ctrl, alt.\n\n"
            f"HOW EACH WORK ITEM IS SHOWN\n{compact_json(shown, 4000)}\n\n"
            f"EVIDENCE TO CAPTURE (file, still/strip, what it must show, required)\n{compact_json(evidence, 7000)}\n\n"
            "Write the capture script: one shot per evidence file you can honestly show (every required one, "
            "optional ones when the game has them; for wildcard names like menu_* write one file per screen, e.g. "
            "captures/ui_menus__menu_shop.png). Shots run in order in ONE play session: put commands that change "
            "the game state (start a round, open a screen, trigger the signature moment, move the camera) before "
            "the shot, and close screens / reset the camera afterwards so the next shot starts clean. For strips "
            "give seconds and frames; keys held during a strip are pressed while it records. Show the game as it "
            "is: never stage anything the game would not show a player.")

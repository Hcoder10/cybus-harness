"""The harness's taste and craft tools over MCP, so Codex CLI and Claude Code users (running Cybus or any other
model) get cybus-harness's vision judge and its no-upload craft pipeline, not just part of it.

Taste: look at the game and judge it (Studio access is read-only).
    capture(view?)                 screenshot of Roblox Studio (read-only Studio Bridge call), saved and returned
    judge(aspect, intent, image_paths | capture=true, style?, target_paths?, threshold?)
                                   the vision judge's Verdict: score 1-10, passed, issues with fixes, strengths
    pairwise(aspect, a_paths, b_paths, intent)   which of two builds is better on one aspect (asked both ways)
    style_guide_template()         the style-guide template every build is planned against
    rubric(aspect)                 an aspect's rubric plus the shared scoring scale

Craft: write into the game's project on disk, never into Studio. project_root is that project's directory; its
scripts live in <project_root>/src/<Service>/<Folders...>/<Name>.luau (ModuleScript), .server.luau (Script) or
.client.luau (LocalScript), the Rojo-style tree of harness.tools.workspace.Workspace. Sync src/ into Studio with
your own tools.
    install_kit(project_root, overwrite?)    the runtime kit (ReplicatedStorage.Kit) and its boot scripts, plus empty
                                   AssetMap / TexPacks index / ClipPack modules when absent; returns the files and KIT_API
    generate_tokens(project_root, style)     style-guide JSON (the STYLE schema) -> ReplicatedStorage.Shared.Tokens,
                                   with a note for every value it had to repair
    paint_texture(project_root, name, spec)  a texture spec validated, rendered, saved to art/<name>.png and packed
                                   into ReplicatedStorage.Shared.TexPacks; returns the preview image and how to use it
    list_textures(project_root)
    author_clip(project_root, name, spec, frames?)   a keyframe clip validated and packed into
                                   ReplicatedStorage.Shared.ClipPack; returns the stick-figure preview and how to play it
    list_clips(project_root)
    search_audio(query, kind?, limit?)       public Roblox Creator Store sounds a game can play by id (no upload)
    playbook(name?)                the harness's craft references and processes (texture_spec, animation_spec,
                                   roblox_craft, style_guide, plan, rubric_<aspect>, ...), or the list of them

Run:
    python -m mcp_server.server                          stdio (Codex / Claude Code start it themselves)
    python -m mcp_server.server --http [--port 8765]     streamable HTTP at http://127.0.0.1:8765/mcp

Environment:
    HARNESS_JUDGE_BASE_URL / _MODEL / _API_KEY / _PROVIDER   the judge model, via harness.llm.llm_from_env("judge")
                                   (falls back to HARNESS_DEFAULT_*): a vision model, e.g. Cybus on vLLM
    HARNESS_STUDIO_URL             Studio Bridge MCP endpoint (default http://localhost:3000/mcp)
    HARNESS_CAPTURE_DIR            where captures and the audio-search cache are saved
                                   (default <repo>/runs/mcp_captures)

Studio access is read-only: the bridge is opened without a PlaceId allow-list, so its guard lets through only
observing tools, and this server only ever asks for screenshots. The craft tools only write files, and only inside
project_root: it must be an existing directory given as an absolute path, every target is resolved (through `..`,
symlinks and junctions) and the call is refused if one lands outside, names are checked as the builder tools check
them, and install_kit never deletes a file and keeps files that differ from the kit unless overwrite=true. The
harness modules are imported lazily; when one is missing the tool that needs it answers with an error saying so,
and the other tools keep working.
"""
from __future__ import annotations

import argparse
import asyncio
import dataclasses
import importlib
import inspect
import io
import json
import logging
import os
import re
import sys
import time
import weakref
from pathlib import Path
from typing import Annotated, Any, Literal

from mcp.server.fastmcp import FastMCP, Image
from mcp.types import CallToolResult, TextContent, ToolAnnotations
from pydantic import Field

REPO = Path(__file__).resolve().parents[1]
if str(REPO) not in sys.path:          # `python path/to/mcp_server/server.py` from any directory finds `harness`
    sys.path.insert(0, str(REPO))

PLAYBOOKS = REPO / "harness" / "playbooks"
MAX_IMAGES = 8                         # Cybus is served with --limit-mm-per-prompt '{"image": 8}'
PREVIEW_SIDE = 1280                    # the inline copy returned to the client; the saved PNG is full size
IMAGE_MAGIC = (b"\x89PNG\r\n\x1a\n", b"\xff\xd8\xff", b"GIF87a", b"GIF89a")

log = logging.getLogger("cybus.mcp")

INSTRUCTIONS = """Taste and craft tools from cybus-harness for building Roblox games that look and feel finished.
Craft tools write into the game's project on disk: project_root is its absolute path, scripts live under
src/<Service>/... (Rojo-style). Loop: (1) install_kit(project_root) once, and build on the kit API it returns;
(2) call style_guide_template(), write the game's style guide with concrete values (hex colours, sizes, timings)
and pass its JSON to generate_tokens(project_root, style); (3) build on the kit and the tokens: paint_texture for
custom art (panels, buttons, glows, icons, particle textures), author_clip for character animation, search_audio
for sounds; playbook(name) has their full references; (4) sync the project into Studio with your own tools and
look at it: capture() or judge(..., capture=true); (5) judge the aspect you changed against its rubric and your
style guide, fix every blocker and major issue it lists, and re-judge until `passed` is true. pairwise() decides
between two versions; rubric(aspect) shows what the judge scores. Studio access is read-only: these tools take
screenshots and write project files, they never edit the place."""


class HarnessUnavailable(RuntimeError):
    pass


def _harness(module: str) -> Any:
    try:
        return importlib.import_module(module)
    except ImportError as e:
        raise HarnessUnavailable(
            f"{module} is not available ({e}). This MCP server serves the cybus-harness repo at {REPO}: run it with "
            f"that repo's Python environment, and make sure {module.replace('.', '/')}.py exists.") from None


# ------------------------------------------------------------------------------------------------ shared state

_state: dict[str, Any] = {"bridge": None, "llm": None, "audio": {}}
_bridge_lock = asyncio.Lock()


async def _bridge() -> Any:
    """One Studio Bridge session per server process, opened on first use and reopened after a failure."""
    async with _bridge_lock:
        bridge = _state["bridge"]
        if bridge is not None and getattr(bridge, "connected", True):
            return bridge
        studio = _harness("harness.tools.studio")
        url = os.environ.get("HARNESS_STUDIO_URL")
        bridge = studio.StudioBridge(url) if url else studio.StudioBridge()   # no allow-list: read-only tools only
        try:
            await bridge.connect()
        except Exception as e:  # noqa: BLE001 - reported to the MCP client
            where = str(getattr(bridge, "url", url))
            msg = str(e) if where in str(e) else f"Studio Bridge at {where}: {e}"
            raise RuntimeError(f"{msg}. Is Roblox Studio open with the bridge plugin connected?") from None
        _state["bridge"] = bridge
        return bridge


async def _forget_bridge() -> None:
    bridge, _state["bridge"] = _state["bridge"], None
    if bridge is not None:
        try:
            await bridge.close()
        except Exception:  # noqa: BLE001
            pass


async def _screenshot() -> bytes:
    capture_mod = _harness("harness.tools.capture")
    bridge = await _bridge()
    try:
        return await capture_mod.screenshot(bridge)
    except Exception as e:  # noqa: BLE001
        await _forget_bridge()                       # reconnect on the next call
        raise RuntimeError(f"screenshot failed: {e}") from None


def _judge_llm() -> Any:
    if _state["llm"] is None:
        llm_mod = _harness("harness.llm")
        try:
            _state["llm"] = llm_mod.llm_from_env("judge")
        except ValueError as e:
            raise RuntimeError(f"no judge model configured ({e}). Point HARNESS_JUDGE_BASE_URL and "
                               "HARNESS_JUDGE_MODEL at a vision model, e.g. Cybus on vLLM "
                               "(http://<host>:8000/v1, model cybus).") from None
    return _state["llm"]


# ------------------------------------------------------------------------------------------------ helpers

def _aspects() -> list[str]:
    return sorted(p.stem[len("rubric_"):] for p in PLAYBOOKS.glob("rubric_*.md"))


def _aspect(aspect: str) -> str:
    name = re.sub(r"[^a-z0-9]+", "_", (aspect or "").strip().lower()).strip("_")
    if not name:
        raise ValueError(f"aspect is required; aspects with rubrics: {', '.join(_aspects())}")
    return name


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.is_file() else ""


def _resolve(p: str) -> Path:
    path = Path(p).expanduser()
    return path if path.is_absolute() else Path.cwd() / path


def _read_images(paths: list[str] | None, what: str) -> list[tuple[str, bytes]]:
    out = []
    for p in paths or []:
        path = _resolve(p)
        if not path.is_file():
            raise ValueError(f"{what}: no such file {p!r} (relative paths resolve against {Path.cwd()}; "
                             "absolute paths are safest)")
        data = path.read_bytes()
        if not (data.startswith(IMAGE_MAGIC) or (data[:4] == b"RIFF" and data[8:12] == b"WEBP")):
            raise ValueError(f"{what}: {p!r} is not a PNG, JPEG, GIF or WebP image")
        out.append((str(path), data))
    return out


def _style_text(style: str) -> str:
    """The style guide: the text itself, or the path of a file holding it."""
    s = (style or "").strip()
    if s and "\n" not in s and len(s) < 500:
        try:
            path = _resolve(s)
            if path.is_file():
                return path.read_text(encoding="utf-8")
        except (OSError, ValueError):
            pass
    return s


def _slug(text: str | None) -> str:
    return re.sub(r"[^A-Za-z0-9]+", "-", text or "").strip("-").lower()[:48] or "capture"


def _capture_dir() -> Path:
    return Path(os.environ.get("HARNESS_CAPTURE_DIR") or REPO / "runs" / "mcp_captures")


def _save_capture(data: bytes, label: str | None) -> Path:
    folder = _capture_dir()
    folder.mkdir(parents=True, exist_ok=True)
    stem = f"{time.strftime('%Y%m%d-%H%M%S')}-{_slug(label)}"
    path, n = folder / f"{stem}.png", 1
    while path.exists():
        path, n = folder / f"{stem}-{n}.png", n + 1
    path.write_bytes(data)
    return path


def _preview(data: bytes) -> tuple[Image, str]:
    """A client-sized copy of a capture (JPEG, longest side PREVIEW_SIDE) and the original's size."""
    try:
        from PIL import Image as PILImage
        with PILImage.open(io.BytesIO(data)) as im:
            size = f"{im.width}x{im.height}"
            im = im.convert("RGB")
            im.thumbnail((PREVIEW_SIDE, PREVIEW_SIDE))
            buf = io.BytesIO()
            im.save(buf, format="JPEG", quality=85)
        return Image(data=buf.getvalue(), format="jpeg"), size
    except Exception:  # noqa: BLE001 - no Pillow or an odd format: send the original
        return Image(data=data, format="png"), "unknown size"


def _jsonable(obj: Any) -> Any:
    if dataclasses.is_dataclass(obj) and not isinstance(obj, type):
        obj = dataclasses.asdict(obj)
    return json.loads(json.dumps(obj, default=str))


def _too_many(n: int) -> None:
    if n > MAX_IMAGES:
        raise ValueError(f"{n} images in one judgement; the judge takes at most {MAX_IMAGES}. Judge fewer, or tile "
                         "them into one contact sheet (harness.tools.capture.contact_sheet).")


# ------------------------------------------------------------------------------------------------ tools

async def capture(
    view: Annotated[str | None, Field(description="Optional label for what this shows (e.g. 'shop menu', "
                                                  "'combat hud'); used in the saved file's name. The bridge captures "
                                                  "the Studio window as it is: frame the view in Studio first.")] = None,
) -> list:
    """Screenshot Roblox Studio through the harness's Studio Bridge (read-only). Saves the full-size PNG and returns
    its path (pass it to judge/pairwise as image_paths) plus a preview image."""
    shot = await _screenshot()
    path = _save_capture(shot, view)
    image, size = _preview(shot)
    return [f"Captured {size} from Studio{f' ({view})' if view else ''}; saved to {path}", image]


async def judge(
    aspect: Annotated[str, Field(description="What is judged, e.g. hud, ui_menus, world_art, vfx, game_feel, camera, "
                                             "animation, characters, cohesion, polish. See rubric().")],
    intent: Annotated[str, Field(description="What this is supposed to be, in the developer's words: the screen or "
                                             "moment, its purpose, and the feel it should have.")],
    image_paths: Annotated[list[str] | None, Field(description="PNG/JPEG files to judge (absolute paths).")] = None,
    capture: Annotated[bool, Field(description="Also screenshot Studio now and judge that capture.")] = False,
    style: Annotated[str, Field(description="The game's style guide: its text, or the path of the file holding "
                                            "it. The build is judged against it.")] = "",
    target_paths: Annotated[list[str] | None, Field(description="Optional mockups / concept frames the build "
                                                                "should reach.")] = None,
    threshold: Annotated[float, Field(description="Score needed to pass (1-10 scale; 7 = strong front-page "
                                                  "Roblox game).")] = 7.0,
) -> dict[str, Any]:
    """Judge captures of one aspect of a Roblox game against the harness rubric, the style guide and optional
    targets, with the harness's vision judge. Returns the Verdict JSON: aspect, score (1-10), passed, issues
    [{severity blocker|major|minor|nit, where, problem, fix}], strengths, plus fix_list (a numbered repair brief)
    and the judged image paths. Fix the blockers and majors, then judge again."""
    judge_mod = _harness("harness.judge")
    name = _aspect(aspect)
    images = _read_images(image_paths, "image_paths")
    if capture:
        shot = await _screenshot()
        images.append((str(_save_capture(shot, f"judge-{name}")), shot))
    if not images:
        raise ValueError("nothing to judge: pass image_paths, or capture=true to screenshot Studio now")
    targets = _read_images(target_paths, "target_paths")
    _too_many(len(images) + len(targets))
    verdict = await judge_mod.judge(_judge_llm(), name, [d for _, d in images], intent, style=_style_text(style),
                                    target=[d for _, d in targets] or None, threshold=threshold)
    out = _jsonable(verdict)
    raw = out.pop("raw", None)
    extra = {k: v for k, v in raw.items() if k not in ("score", "issues", "strengths")} if isinstance(raw, dict) else {}
    if extra:
        out["raw"] = extra                     # e.g. the judge's own words when it returned no JSON
    fix_list = getattr(verdict, "fix_list", None)
    if callable(fix_list):
        out["fix_list"] = fix_list()
    out["images"] = [p for p, _ in images]
    if targets:
        out["targets"] = [p for p, _ in targets]
    if name not in _aspects():
        out["note"] = f"no rubric for {name!r}: judged against the general rubric only ({', '.join(_aspects())})"
    return out


async def pairwise(
    aspect: Annotated[str, Field(description="The aspect to compare on (see rubric()).")],
    a_paths: Annotated[list[str], Field(description="Captures of build A (absolute paths).")],
    b_paths: Annotated[list[str], Field(description="Captures of build B (absolute paths).")],
    intent: Annotated[str, Field(description="What the builds are supposed to be.")],
) -> dict[str, Any]:
    """Which of two builds is better on one aspect. The judge is asked in both orders and a disagreement is a tie.
    Returns {prefer: "A" | "B" | "tie", why, ...}."""
    judge_mod = _harness("harness.judge")
    name = _aspect(aspect)
    a, b = _read_images(a_paths, "a_paths"), _read_images(b_paths, "b_paths")
    if not a or not b:
        raise ValueError("pairwise needs at least one image for A and one for B")
    _too_many(len(a) + len(b))
    result = await judge_mod.pairwise(_judge_llm(), name, [d for _, d in a], [d for _, d in b], intent)
    return {**_jsonable(result), "aspect": name, "a": [p for p, _ in a], "b": [p for p, _ in b]}


def style_guide_template() -> str:
    """The harness's style-guide template (a playbook): the sections and concrete values to decide before building
    (direction, canvas and layout, colour tokens, type scale, components, motion, audio, world). Write the game's
    style guide from it and pass that to judge()."""
    text = _read(PLAYBOOKS / "style_guide.md")
    if not text:
        raise RuntimeError(f"the style guide playbook is missing: {PLAYBOOKS / 'style_guide.md'}")
    return text


def rubric(aspect: Annotated[str, Field(description="Aspect name, e.g. hud or ui_menus.")]) -> str:
    """The rubric the judge scores an aspect against, followed by the shared 1-10 scale, principles and severity
    definitions."""
    name = _aspect(aspect)
    available = _aspects()
    if name not in available:
        raise ValueError(f"no rubric for {aspect!r}; available: {', '.join(available) or '(no rubric files found)'}")
    general = _read(PLAYBOOKS / "rubric_general.md")
    if name == "general":
        return general
    try:
        return _harness("harness.judge").rubric(name)      # exactly what the judge is shown
    except (HarnessUnavailable, AttributeError):
        return "\n\n".join(t for t in (_read(PLAYBOOKS / f"rubric_{name}.md"), general) if t)


# ------------------------------------------------------------------------------------------------ craft: projects
# The craft tools run the builder agents' own tools (harness.tools.art / anim / audio) and the scaffold's own code
# (harness.kit, harness.tokens) on a project directory, and turn their results into MCP content.

TOKENS_PATH = "ReplicatedStorage/Shared/Tokens.luau"          # ReplicatedStorage.Shared.Tokens in KIT_API
ASSET_MAP_PATH = "ReplicatedStorage/Shared/AssetMap.luau"     # read by Kit.Assets
EMPTY_ASSET_MAP = ("-- Generated by cybus-harness: generated art by name, read by Kit.Assets.image(name). No "
                   "generated images yet.\nreturn {}\n")
TOKEN_SECTIONS = ("palette", "fonts", "type_scale", "radius", "stroke", "motion", "lighting")   # what build_tokens reads
ROOT_HELP = ("Absolute path of the game's project directory, which must exist. Scripts live under "
             "<project_root>/src/<Service>/..., e.g. src/ReplicatedStorage/Kit/Motion.luau.")

_project_locks: "weakref.WeakKeyDictionary[asyncio.AbstractEventLoop, dict[str, asyncio.Lock]]" = \
    weakref.WeakKeyDictionary()


def _project(project_root: str) -> Path:
    """The project directory, resolved: it must exist, and be given as an absolute path (this server's working
    directory is wherever the client started it, e.g. the harness checkout, never a safe guess)."""
    raw = str(project_root or "").strip()
    if not raw:
        raise ValueError("project_root is required: the absolute path of the game's project directory (the one "
                         "holding src/)")
    path = Path(raw).expanduser()
    if not path.is_absolute():
        raise ValueError(f"project_root must be an absolute path, got {raw!r} (this server runs in {Path.cwd()}, "
                         "which is not your project)")
    if not path.is_dir():
        what = "is not a directory" if path.exists() else "does not exist"
        raise ValueError(f"project_root {raw!r} {what}: pass the game's project directory (create it first)")
    return path.resolve()


def _inside(root: Path, *targets: Path) -> None:
    """Refuse the call before anything is written if a target resolves outside the project, whether through `..`,
    an absolute path, a symlink or a junction (existing parts of the path are resolved; files too)."""
    for target in targets:
        real = Path(target).resolve()
        if not real.is_relative_to(root):
            raise ValueError(f"refused: {target} resolves to {real}, outside the project {root}")


def _plain_name(name: Any, what: str) -> str:
    """A name that becomes a file name must be one plain path component. The builder tool then applies its own
    naming rules (texture names: lowercase letters, digits, _; clip names: letters, digits, _ or -)."""
    if not isinstance(name, str) or not name.strip():
        raise ValueError(f"{what} is required")
    if name in (".", "..") or any(c in name for c in "/\\:\0"):
        raise ValueError(f"refused {what} {name!r}: give a name, not a path (no '/', '\\', ':' or '..')")
    return name


def _project_lock(root: Path) -> asyncio.Lock:
    """Tools that write one project run one at a time (per event loop), so two concurrent calls cannot drop each
    other's textures or clips from the pack manifests."""
    locks = _project_locks.setdefault(asyncio.get_running_loop(), {})
    return locks.setdefault(os.path.normcase(str(root)), asyncio.Lock())


def _builder_tool(tools: list, name: str) -> Any:
    for tool in tools:
        if tool.name == name:
            return tool
    raise HarnessUnavailable(f"the harness has no {name!r} builder tool any more; update this MCP server")


def _as_content(result: Any, *notes: str) -> list | CallToolResult:
    """A builder tool's ToolResult as MCP content: its text (plus `notes`), then its images as PNG image content.
    When the tool reports an error (text starting with ERROR) the call comes back as a tool error with the same
    text and images, so the client knows nothing was packed and still sees the preview of what was written."""
    images = [Image(data=png, format="png") for png in result.images]
    if result.text.startswith("ERROR"):
        return CallToolResult(isError=True, content=[TextContent(type="text", text=result.text),
                                                     *(image.to_image_content() for image in images)])
    return ["\n".join([result.text, *(n for n in notes if n)]), *images]


def _kit_note(ws: Any, module: str) -> str:
    if (ws.src / "ReplicatedStorage" / "Kit" / f"{module}.luau").is_file():
        return ""
    return f"Kit.{module} is not in this project yet: call install_kit(project_root) before using it."


def _same_text(path: Path, source: str) -> bool:
    """Whether a file already holds `source` (line endings and a UTF-8 BOM aside, as a git checkout may change
    them)."""
    try:
        current = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return False

    def norm(s: str) -> str:
        return s.replace("\r\n", "\n").replace("\r", "\n").removeprefix(chr(0xFEFF))     # chr(0xFEFF): the BOM
    return norm(current) == norm(source)


def _install(root: Path, overwrite: bool) -> str:
    kit = _harness("harness.kit")
    workspace = _harness("harness.tools.workspace")
    texpack = _harness("harness.tools.texpack")
    anim = _harness("harness.tools.anim")
    ws = workspace.Workspace(root)
    kit_sources = [(workspace.parse_rel(rel).rel, source) for rel, source in kit.kit_files().items()]
    generated = [(ASSET_MAP_PATH, lambda: EMPTY_ASSET_MAP),                              # written only when absent
                 (texpack.TexturePacks.INDEX, lambda: texpack.TexturePacks(ws).index_source()),
                 (anim.PACK_PATH, lambda: anim.ClipPack(ws).luau())]
    _inside(root, *(ws.src / rel for rel, _ in kit_sources), *(ws.src / rel for rel, _ in generated))

    done: dict[str, list[str]] = {"created": [], "updated": [], "unchanged": [], "kept": [], "made": [], "present": []}
    for rel, source in kit_sources:
        path = ws.src / rel
        if not path.exists():
            ws.write(rel, source)
            done["created"].append(f"src/{rel}")
        elif not path.is_file():
            done["kept"].append(f"src/{rel} (not a file)")
        elif _same_text(path, source):
            done["unchanged"].append(f"src/{rel}")
        elif overwrite:
            ws.write(rel, source)
            done["updated"].append(f"src/{rel}")
        else:
            done["kept"].append(f"src/{rel}")
    for rel, make in generated:
        if (ws.src / rel).exists():
            done["present"].append(f"src/{rel}")
        else:
            ws.write(rel, make())
            done["made"].append(f"src/{rel}")

    labels = {"created": "created", "updated": "replaced with the kit's version (overwrite=true)",
              "unchanged": "already the kit's version",
              "kept": "kept as they are: they differ from the kit (your edits?); install_kit(project_root, "
                      "overwrite=true) replaces them with the kit's version",
              "made": "generated modules, created empty (paint_texture and author_clip fill TexPacks and ClipPack)",
              "present": "generated modules already present, left as they are"}
    lines = [f"Runtime kit for {root} (scripts under src/; nothing was deleted):"]
    lines += [f"- {labels[k]} ({len(v)}): {', '.join(v)}" for k, v in done.items() if v]
    if not (ws.src / TOKENS_PATH).is_file():
        lines.append("Next: write the style guide and call generate_tokens(project_root, style): the kit and your "
                     "scripts read ReplicatedStorage.Shared.Tokens.")
    lines += ["Sync src/ into Studio with your usual tool. The kit's API:", "", kit.KIT_API.strip()]
    return "\n".join(lines)


def _style_json(style: dict[str, Any] | str, root: Path) -> dict:
    """The style guide as a dict: the object itself, its JSON text, or the path of a .json file (relative paths
    resolve against the project)."""
    if isinstance(style, str):
        text = style.strip()
        if not text:
            raise ValueError("style is required: the style guide as a JSON object, or the path of a .json file")
        if not text.startswith(("{", "[")):
            path = Path(text).expanduser()
            path = path if path.is_absolute() else root / path
            if not path.is_file():
                raise ValueError(f"style {text!r} is neither a JSON object nor an existing file (relative paths "
                                 "resolve against project_root)")
            text = path.read_text(encoding="utf-8-sig")
        try:
            style = json.loads(text)
        except ValueError as e:
            raise ValueError(f"style is not valid JSON: {e}") from None
    if not isinstance(style, dict):
        raise ValueError(f"style must be a JSON object (the STYLE schema: palette, fonts, type_scale, radius, stroke, "
                         f"motion, lighting, ...), got {type(style).__name__}")
    return style


def _style_keys() -> set[str]:
    try:
        return set(_harness("harness.schemas").STYLE["properties"])
    except (HarnessUnavailable, AttributeError, KeyError, TypeError):
        return set()


def _audio_search() -> Any:
    """One AudioSearch per cache file, cached under the capture dir (and in memory for this process)."""
    audio = _harness("harness.tools.audio")
    folder = _capture_dir()
    try:
        folder.mkdir(parents=True, exist_ok=True)
        cache: Path | None = folder / "audio_cache.json"
    except OSError:
        cache = None                                         # still works, without a cache on disk
    searches = _state["audio"]
    if str(cache) not in searches:
        searches[str(cache)] = audio.AudioSearch(cache)
    return searches[str(cache)]


def _playbooks() -> dict[str, Path]:
    return {p.stem: p for p in sorted(PLAYBOOKS.glob("*.md"))}


def _title(path: Path) -> str:
    """A playbook's first line, without the heading marks."""
    try:
        with path.open(encoding="utf-8") as f:
            for line in f:
                if line.strip():
                    return line.strip().lstrip("#").strip()
    except OSError:
        pass
    return ""


def _playbook_list(books: dict[str, Path]) -> str:
    refs = [n for n in books if not n.startswith("rubric_")]
    rubrics = [n for n in books if n.startswith("rubric_")]
    lines = ["Playbooks (call playbook(name)):"] + [f"- {n}: {_title(books[n])}" for n in refs]
    if rubrics:
        lines += ["Rubrics, what judge() scores (playbook(\"rubric_<aspect>\") or rubric(aspect); playbook(\"rubrics\") "
                  "adds the shared scale):"] + [f"- {n}: {_title(books[n])}" for n in rubrics]
    if not books:
        lines.append(f"(none found in {PLAYBOOKS})")
    return "\n".join(lines)


# ------------------------------------------------------------------------------------------------ craft: tools

async def install_kit(
    project_root: Annotated[str, Field(description=ROOT_HELP)],
    overwrite: Annotated[bool, Field(description="Also replace kit files that differ from the kit's own version "
                                                 "(edits to them are lost). The generated AssetMap / TexPacks / "
                                                 "ClipPack modules are never replaced.")] = False,
) -> str:
    """Install the cybus-harness runtime kit into a Roblox project on disk: the kit modules in ReplicatedStorage.Kit
    (Maid, Spring, Motion, Shake, Sound, Screen, Assets, Textures, Anim, Debug, ...) and their boot scripts, plus
    empty ReplicatedStorage.Shared.AssetMap, TexPacks.Index and ClipPack modules when they are absent. Safe to call
    again: files identical to the kit are left alone, files that differ from it (your edits) are kept unless
    overwrite=true, and nothing is ever deleted. Returns the files and the kit's API (what to require and call).
    Call it once per project, then generate_tokens."""
    root = _project(project_root)
    async with _project_lock(root):
        return await asyncio.to_thread(_install, root, bool(overwrite))


async def generate_tokens(
    project_root: Annotated[str, Field(description=ROOT_HELP)],
    style: Annotated[dict[str, Any] | str, Field(description="The style guide as a JSON object in the harness's "
                                                             "STYLE schema, or the path of a .json file holding it.")],
) -> str:
    """Turn the game's style guide into src/ReplicatedStorage/Shared/Tokens.luau (ReplicatedStorage.Shared.Tokens),
    the module every script and the kit read colours, fonts, sizes, radii, timings and lighting from. The style
    guide is JSON in the harness's STYLE schema; the keys used here are: palette {bg, surface, surface_raised, text,
    text_muted, primary, secondary, success, warning, danger, plus any roles of your own: "#RRGGBB"}, fonts {display,
    heading, body, numeric: a Roblox font such as "Montserrat:Bold" or "GothamBlack"}, type_scale {display, h1, h2,
    body, caption, numeric: TextSize on the 1920x1080 canvas}, radius {small, medium, large: px}, stroke (px),
    motion {fast, base, slow, dramatic: seconds, ease_out, ease_in: an EasingStyle such as Quint}, lighting
    {ClockTime, Brightness, ExposureCompensation, Ambient, OutdoorAmbient}. Invalid or missing values are repaired
    to safe defaults and listed: fix them in the style guide and generate again. Never edit Tokens.luau by hand."""
    tokens = _harness("harness.tokens")
    workspace = _harness("harness.tools.workspace")
    root = _project(project_root)
    data = _style_json(style, root)
    source, repaired = tokens.build_tokens(data)
    ws = workspace.Workspace(root)
    target = ws.src / TOKENS_PATH
    async with _project_lock(root):
        _inside(root, target)
        replaced = target.is_file()
        ws.write(TOKENS_PATH, source)
    n_lines = source.count("\n")
    lines = [f"{'Rewrote' if replaced else 'Wrote'} src/{TOKENS_PATH} (ReplicatedStorage.Shared.Tokens, {n_lines} "
             f"lines) in {root}."]
    if repaired:
        lines.append(f"Repaired {len(repaired)} value(s); fix them in the style guide and call generate_tokens again:")
        lines += [f"- {p}" for p in repaired]
    else:
        lines.append("No values needed repair.")
    missing = [k for k in TOKEN_SECTIONS if k not in data]
    if missing:
        lines.append(f"Not in the style guide, so the defaults were used: {', '.join(missing)}.")
    known = _style_keys()
    unknown = sorted(k for k in data if known and k not in known)
    if unknown:
        lines.append(f"Ignored (not STYLE keys): {', '.join(unknown)}.")
    lines.append("Use it: local Tokens = require(ReplicatedStorage.Shared.Tokens); Tokens.color.<role>, "
                 "Tokens.font.<display|heading|body|numeric>, Tokens.size.<display|h1|h2|body|caption|numeric>, "
                 "Tokens.space.s1..s8, Tokens.radius.<small|medium|large>, Tokens.stroke, Tokens.motion, "
                 "Tokens.tween(kind), Tokens.lighting.")
    return "\n".join(lines)


async def paint_texture(
    project_root: Annotated[str, Field(description=ROOT_HELP)],
    name: Annotated[str, Field(description="Texture name: lowercase letters, digits and underscores, e.g. "
                                           "panel_skin, spark_glow, coin_icon. Painting a name again replaces it.")],
    spec: Annotated[dict[str, Any], Field(description="The texture spec: {size: [w, h], format?: RGBA | LA, "
                                                      "slice?: [x0, y0, x1, y1], layers: [...]}.")],
) -> list | CallToolResult:
    """Paint a texture for the game (UI panel or button skin, soft shadow, glow, icon from shapes, particle / beam
    texture, ring, burst, streak) from a spec of layered shapes, fills and effects: the spec is validated (every
    problem at once), rendered, saved to <project_root>/art/<name>.png and packed into the project as texture data
    (src/ReplicatedStorage/Shared/TexPacks), which Kit.Textures turns back into an image at runtime: no image
    generation, no uploads. Returns the preview (over a checkerboard, stretched as a 9-slice when it has one, tinted
    when it is LA) and how to use it. Look at it and paint again until it is right."""
    art = _harness("harness.tools.art")
    texpack = _harness("harness.tools.texpack")
    workspace = _harness("harness.tools.workspace")
    root = _project(project_root)
    _plain_name(name, "texture name")
    ws = workspace.Workspace(root)
    art_dir = root / "art"
    pack_dir = ws.src / texpack.TexturePacks.DIR
    manifest = root / texpack.TexturePacks.MANIFEST
    async with _project_lock(root):
        _inside(root, art_dir / f"{name}.png", manifest, manifest.with_name(manifest.name + ".tmp"),
                pack_dir / "Index.luau", *(sorted(pack_dir.iterdir()) if pack_dir.is_dir() else ()))
        tool = _builder_tool(art.art_tools(texpack.TexturePacks(ws), art_dir), "paint_texture")
        result = await tool.invoke({"name": name, "spec": spec})
    return _as_content(result, f"Files in {root}: art/{name}.png (the texture); src/{texpack.TexturePacks.DIR}/ "
                               f"(generated from {manifest.name}: never edit them, paint again).",
                       _kit_note(ws, "Textures"))


async def list_textures(project_root: Annotated[str, Field(description=ROOT_HELP)]) -> str:
    """List the textures painted into the project, with their size, format and 9-slice centre."""
    art = _harness("harness.tools.art")
    texpack = _harness("harness.tools.texpack")
    workspace = _harness("harness.tools.workspace")
    root = _project(project_root)
    tool = _builder_tool(art.art_tools(texpack.TexturePacks(workspace.Workspace(root)), root / "art"),
                         "list_textures")
    return (await tool.invoke({})).text


async def author_clip(
    project_root: Annotated[str, Field(description=ROOT_HELP)],
    name: Annotated[str, Field(description="Clip name: letters, digits, _ or -, starting with a letter, e.g. "
                                           "sword_slash. Authoring a name again replaces it.")],
    spec: Annotated[dict[str, Any], Field(description="The clip: {length, looped, priority, keys: [{t, ease, pose: "
                                                      "{Joint: [rx, ry, rz] or [rx, ry, rz, px, py, pz]}}], "
                                                      "markers: [{t, name}]}.")],
    frames: Annotated[int, Field(description="Frames in the preview contact sheet, 2-16.")] = 8,
) -> list | CallToolResult:
    """In this project the clip is packed into <project_root>/src/ReplicatedStorage/Shared/ClipPack.luau (generated
    from <project_root>/clip_pack.json, which keeps every clip) and the contact sheet is also saved to
    <project_root>/art/clips/<name>.png. An invalid clip comes back as an error listing every problem, with the
    preview of the clip as written when it can be drawn."""
    anim = _harness("harness.tools.anim")
    workspace = _harness("harness.tools.workspace")
    root = _project(project_root)
    _plain_name(name, "clip name")
    ws = workspace.Workspace(root)
    art_dir = root / "art"
    manifest = root / anim.MANIFEST_NAME
    async with _project_lock(root):
        _inside(root, art_dir / "clips" / f"{name}.png", ws.src / anim.PACK_PATH, manifest,
                manifest.with_name(manifest.name + ".tmp"))
        tool = _builder_tool(anim.anim_tools(anim.ClipPack(ws), art_dir), "author_clip")
        result = await tool.invoke({"name": name, "spec": spec, "frames": frames})
    return _as_content(result, f"Files in {root}: art/clips/{name}.png (this preview); {manifest.name} keeps every "
                               f"clip and src/{anim.PACK_PATH} is generated from it: never edit it, author again.",
                       _kit_note(ws, "Anim"))


async def list_clips(project_root: Annotated[str, Field(description=ROOT_HELP)]) -> str:
    """List the project's animation clips (name, length, loop, priority, markers)."""
    anim = _harness("harness.tools.anim")
    workspace = _harness("harness.tools.workspace")
    root = _project(project_root)
    tool = _builder_tool(anim.anim_tools(anim.ClipPack(workspace.Workspace(root)), root / "art"), "list_clips")
    return (await tool.invoke({})).text


async def search_audio(
    query: Annotated[str, Field(description="What it should sound like, e.g. 'coin pickup', 'sword swing', "
                                            "'ui click', 'ambient forest', 'upbeat battle music'.")],
    kind: Annotated[Literal["sfx", "music", "any"], Field(description="sfx (short effects, ranked first), music "
                                                                      "(tracks of 20 s or more) or any.")] = "sfx",
    limit: Annotated[int, Field(description="How many results, 1-15.")] = 8,
) -> str:
    """Search the Roblox Creator Store for public sound effects or music the game can play by id, with no upload.
    Sounds from the Roblox account's licensed library rank first, then verified creators. Each line is an
    rbxassetid:// id with its length, type, creator and title; register the ones you use with Kit.Sound.register
    (2-3 ids per event for variation). Results are cached, so asking again is free."""
    if not str(query or "").strip():
        raise ValueError("query is required, e.g. 'coin pickup', 'sword swing', 'ui click', 'calm lofi music'")
    tool = _builder_tool(_audio_search().tools(), "search_audio")
    return (await tool.invoke({"query": query, "kind": kind, "limit": limit})).text


def playbook(
    name: Annotated[str, Field(description="Playbook name, e.g. texture_spec; empty lists them.")] = "",
) -> str:
    """The harness's craft references and processes, as markdown: texture_spec (the full paint_texture spec, with
    examples), animation_spec (author_clip's), vfx_camera_spec (Kit.VFX and Kit.CameraRig, when the kit has them),
    roblox_craft (how the rubrics' qualities are built on Roblox), style_guide (the style-guide template), plan
    (planning a game from a pitch), rubric_<aspect> (what judge() scores); "rubrics" gives the shared scale and the
    rubric list. An unknown or empty name lists the playbooks that exist."""
    books = _playbooks()
    raw = str(name or "").strip()
    key = re.split(r"[\\/]", raw)[-1].lower().removesuffix(".md")   # only a name counts, never a path
    key = re.sub(r"[^a-z0-9]+", "_", key).strip("_")
    for candidate in (key, f"rubric_{key}"):
        if key and candidate in books:
            return books[candidate].read_text(encoding="utf-8")
    if key in ("rubrics", "rubric"):
        general = _read(PLAYBOOKS / "rubric_general.md")
        index = [f"- {n}: {_title(p)}" for n, p in books.items() if n.startswith("rubric_") and n != "rubric_general"]
        return "\n".join([general.rstrip(), "", "Aspect rubrics (playbook(\"rubric_<aspect>\"), or rubric(aspect) for "
                          "one with this scale appended):", *index]).strip()
    head = f"No playbook named {raw!r}.\n" if key and key not in ("list", "all", "index") else ""
    return head + _playbook_list(books)


# ------------------------------------------------------------------------------------------------ server

def _builder_help(module: str, attr: str, fallback: str) -> str:
    """Help text a builder tool carries (the texture spec grammar, the clip conventions), for a tool description.
    Falls back when the module cannot be imported; the tool itself then reports that when called."""
    try:
        return str(getattr(importlib.import_module(module), attr))
    except Exception:  # noqa: BLE001 - any import problem: describe the tool without it
        return fallback


def build_server(host: str = "127.0.0.1", port: int = 8765) -> FastMCP:
    """A FastMCP server with the taste and craft tools. host/port matter for --http only (and set DNS-rebinding
    protection, which FastMCP turns on for loopback hosts)."""
    server = FastMCP("cybus-taste", instructions=INSTRUCTIONS, host=host, port=port)
    aspects = ", ".join(_aspects()) or "see harness/playbooks"
    server.tool(structured_output=False)(capture)
    server.tool()(judge)
    server.tool()(pairwise)
    server.tool()(style_guide_template)
    server.tool(description=f"{rubric.__doc__} Aspects with rubrics: {aspects}.")(rubric)

    reads = ToolAnnotations(readOnlyHint=True, openWorldHint=False)
    web = ToolAnnotations(readOnlyHint=True, openWorldHint=True)
    writes = ToolAnnotations(readOnlyHint=False, destructiveHint=True, idempotentHint=True, openWorldHint=False)
    spec_help = _builder_help("harness.tools.art", "SPEC_HELP", "Spec reference: playbook('texture_spec').")
    clip_help = _builder_help("harness.tools.anim", "AUTHOR_HELP", "Author a keyframe animation clip for Kit.Anim "
                                                                   "(spec reference: playbook('animation_spec')).")
    books = ", ".join(_playbooks()) or "(none found)"
    server.tool(structured_output=False, annotations=writes)(install_kit)
    server.tool(structured_output=False, annotations=writes)(generate_tokens)
    server.tool(structured_output=False, annotations=writes,
                description=f"{inspect.cleandoc(paint_texture.__doc__ or '')}\n{spec_help}")(paint_texture)
    server.tool(structured_output=False, annotations=reads)(list_textures)
    server.tool(structured_output=False, annotations=writes,
                description=f"{clip_help}\n{inspect.cleandoc(author_clip.__doc__ or '')}")(author_clip)
    server.tool(structured_output=False, annotations=reads)(list_clips)
    server.tool(structured_output=False, annotations=web)(search_audio)
    server.tool(structured_output=False, annotations=reads,
                description=f"{inspect.cleandoc(playbook.__doc__ or '')} Available: {books}.")(playbook)
    return server


mcp = build_server()           # the default stdio instance (also what `mcp dev mcp_server/server.py` finds)


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description="cybus-harness taste and craft tools over MCP (stdio by default).")
    parser.add_argument("--http", action="store_true", help="serve streamable HTTP instead of stdio")
    parser.add_argument("--host", default="127.0.0.1", help="HTTP bind address (default 127.0.0.1)")
    parser.add_argument("--port", type=int, default=8765, help="HTTP port (default 8765); the endpoint is /mcp")
    args = parser.parse_args(argv)
    # stdout carries the stdio protocol: logs go to stderr only
    logging.basicConfig(level=logging.INFO, stream=sys.stderr, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    if args.http:
        build_server(args.host, args.port).run(transport="streamable-http")
    else:
        mcp.run(transport="stdio")


if __name__ == "__main__":
    main()

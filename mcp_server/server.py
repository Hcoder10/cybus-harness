"""The harness's taste tools over MCP, so Codex CLI and Claude Code users get part of cybus-harness.

    capture(view?)                 screenshot of Roblox Studio (read-only Studio Bridge call), saved and returned
    judge(aspect, intent, image_paths | capture=true, style?, target_paths?, threshold?)
                                   the vision judge's Verdict: score 1-10, passed, issues with fixes, strengths
    pairwise(aspect, a_paths, b_paths, intent)   which of two builds is better on one aspect (asked both ways)
    style_guide_template()         the style-guide template every build is planned against
    rubric(aspect)                 an aspect's rubric plus the shared scoring scale

Run:
    python -m mcp_server.server                          stdio (Codex / Claude Code start it themselves)
    python -m mcp_server.server --http [--port 8765]     streamable HTTP at http://127.0.0.1:8765/mcp

Environment:
    HARNESS_JUDGE_BASE_URL / _MODEL / _API_KEY / _PROVIDER   the judge model, via harness.llm.llm_from_env("judge")
                                   (falls back to HARNESS_DEFAULT_*): a vision model, e.g. Cybus on vLLM
    HARNESS_STUDIO_URL             Studio Bridge MCP endpoint (default http://localhost:3000/mcp)
    HARNESS_CAPTURE_DIR            where captures are saved (default <repo>/runs/mcp_captures)

Studio access is read-only: the bridge is opened without a PlaceId allow-list, so its guard lets through only
observing tools, and this server only ever asks for screenshots. The harness modules are imported lazily; when
one is missing the tool that needs it answers with an error saying so, and the other tools keep working.
"""
from __future__ import annotations

import argparse
import asyncio
import dataclasses
import importlib
import io
import json
import logging
import os
import re
import sys
import time
from pathlib import Path
from typing import Annotated, Any

from mcp.server.fastmcp import FastMCP, Image
from pydantic import Field

REPO = Path(__file__).resolve().parents[1]
if str(REPO) not in sys.path:          # `python path/to/mcp_server/server.py` from any directory finds `harness`
    sys.path.insert(0, str(REPO))

PLAYBOOKS = REPO / "harness" / "playbooks"
MAX_IMAGES = 8                         # Cybus is served with --limit-mm-per-prompt '{"image": 8}'
PREVIEW_SIDE = 1280                    # the inline copy returned to the client; the saved PNG is full size
IMAGE_MAGIC = (b"\x89PNG\r\n\x1a\n", b"\xff\xd8\xff", b"GIF87a", b"GIF89a")

log = logging.getLogger("cybus.mcp")

INSTRUCTIONS = """Taste tools from cybus-harness for building Roblox games that look and feel finished.
Loop: (1) call style_guide_template() and write the game's style guide with concrete values (hex colours,
sizes, timings); (2) build; (3) look at what you built: capture() or judge(..., capture=true); (4) judge the
aspect you changed against its rubric and your style guide, fix every blocker and major issue it lists, and
re-judge until `passed` is true; (5) use pairwise() to decide between two versions. rubric(aspect) shows what
the judge scores. Studio access is read-only: these tools take screenshots, they never edit the place."""


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

_state: dict[str, Any] = {"bridge": None, "llm": None}
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


def _save_capture(data: bytes, label: str | None) -> Path:
    folder = Path(os.environ.get("HARNESS_CAPTURE_DIR") or REPO / "runs" / "mcp_captures")
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


# ------------------------------------------------------------------------------------------------ server

def build_server(host: str = "127.0.0.1", port: int = 8765) -> FastMCP:
    """A FastMCP server with the taste tools. host/port matter for --http only (and set DNS-rebinding
    protection, which FastMCP turns on for loopback hosts)."""
    server = FastMCP("cybus-taste", instructions=INSTRUCTIONS, host=host, port=port)
    aspects = ", ".join(_aspects()) or "see harness/playbooks"
    server.tool(structured_output=False)(capture)
    server.tool()(judge)
    server.tool()(pairwise)
    server.tool()(style_guide_template)
    server.tool(description=f"{rubric.__doc__} Aspects with rubrics: {aspects}.")(rubric)
    return server


mcp = build_server()           # the default stdio instance (also what `mcp dev mcp_server/server.py` finds)


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description="cybus-harness taste tools over MCP (stdio by default).")
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

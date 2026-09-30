"""The MCP server's craft tools (mcp_server/server.py), called the way a client calls them: through the FastMCP
server's call path, and once over a real client session. A temporary directory stands in for the game's project;
search_audio's fetch is monkeypatched (no network). Nothing here touches Studio."""
from __future__ import annotations

import asyncio
import base64
import io
import json
import os
from pathlib import Path

import pytest
from mcp.server.fastmcp.exceptions import ToolError
from mcp.shared.memory import create_connected_server_and_client_session
from mcp.types import CallToolResult, ImageContent, TextContent
from PIL import Image

from harness.kit import KIT_API, kit_files
from harness.tokens import build_tokens
from harness.tools import anim, audio
from harness.tools.texpack import TexturePacks, decode, rgba_bytes
from harness.tools.workspace import Workspace
from mcp_server import server as S

SERVER = S.build_server()
SHARED = Path("src/ReplicatedStorage/Shared")

PANEL = {"size": [64, 64], "slice": [20, 20, 44, 44], "layers": [
    {"shape": "rounded_rect", "box": [4, 4, 60, 60], "radius": 12,
     "linear": {"angle": 90, "stops": [[0, "#3B4A66"], [1, "#253049"]]},
     "stroke": {"width": 2, "color": "#FFFFFF30"}}]}
GLOW = {"size": [32, 32], "format": "LA",
        "layers": [{"shape": "fill", "radial": {"stops": [[0, "#FFFFFF"], [1, "#FFFFFF00"]]}}]}
WAVE = {"length": 0.8, "looped": False, "priority": "action",
        "keys": [{"t": 0, "pose": {"RightShoulder": [0, 0, 5], "RightElbow": [10, 0, 0]}},
                 {"t": 0.3, "ease": "quadOut", "pose": {"RightShoulder": [-40, 0, 20], "RightElbow": [90, 0, 0]}},
                 {"t": 0.4, "ease": "expoIn", "pose": {"RightShoulder": [110, 0, 10], "RightElbow": [15, 0, 0]}},
                 {"t": 0.8, "ease": "sine", "pose": {"RightShoulder": [0, 0, 5], "RightElbow": [10, 0, 0]}}],
        "markers": [{"t": 0.4, "name": "hit"}]}
STYLE = {"direction": "a warm harbour at dusk",
         "palette": {"bg": "#101318", "surface": "#1B2029", "surface_raised": "#262D39", "text": "#F4F6FA",
                     "text_muted": "#A7B0C0", "primary": "orange", "secondary": "#4FC3F7", "success": "#5BD67A",
                     "warning": "#FFD34D", "danger": "#FF5A5A", "gold": "#FFD700"},
         "fonts": {"display": "Montserrat:Bold", "heading": "Montserrat:Bold", "body": "BuilderSans",
                   "numeric": "RobotoMono:SemiBold"},
         "type_scale": {"display": 72, "h1": 44, "h2": 32, "body": 22, "caption": 16, "numeric": 28},
         "radius": {"small": 6, "medium": 12, "large": 20}, "stroke": 2,
         "motion": {"fast": 0.12, "base": 0.2, "slow": 0.35, "dramatic": 0.6, "ease_out": "Quint", "ease_in": "Quad"},
         "lighting": {"ClockTime": 17.5, "Brightness": 2, "Ambient": "#404050", "OutdoorAmbient": "#707080"}}


# ------------------------------------------------------------------------------------------------ helpers

def call(tool: str, /, **args):
    """One tool call through the server's call path: a list of content blocks, the CallToolResult a tool returns
    for an error it reports itself, or ToolError raised for a refused call."""
    return asyncio.run(SERVER.call_tool(tool, args))


def blocks(result) -> list:
    if isinstance(result, CallToolResult):
        return list(result.content)
    if isinstance(result, tuple):                   # tools with structured output: (content, structured)
        return list(result[0])
    return list(result)


def text_of(result) -> str:
    return "\n".join(b.text for b in blocks(result) if isinstance(b, TextContent))


def pngs_of(result) -> list[bytes]:
    return [base64.b64decode(b.data) for b in blocks(result) if isinstance(b, ImageContent)]


def files(root: Path) -> dict[Path, tuple[bytes, int]]:
    return {p: (p.read_bytes(), p.stat().st_mtime_ns) for p in root.rglob("*") if p.is_file()}


def link_dir(link: Path, target: Path) -> None:
    """A directory symlink, or a junction on Windows without the symlink privilege."""
    try:
        link.symlink_to(target, target_is_directory=True)
    except OSError:
        if os.name != "nt":
            pytest.skip("cannot create a directory link here")
        import _winapi
        _winapi.CreateJunction(str(target), str(link))


# ------------------------------------------------------------------------------------------------ the server

def test_server_lists_taste_and_craft_tools():
    tools = {t.name: t for t in asyncio.run(SERVER.list_tools())}
    assert set(tools) == {"capture", "judge", "pairwise", "style_guide_template", "rubric", "install_kit",
                          "generate_tokens", "paint_texture", "list_textures", "author_clip", "list_clips",
                          "search_audio", "playbook", "check_game"}
    assert "rounded_rect" in tools["paint_texture"].description          # the builder tools' own help
    assert "knees bend with NEGATIVE rx" in tools["author_clip"].description
    assert tools["paint_texture"].inputSchema["required"] == ["project_root", "name", "spec"]
    assert tools["search_audio"].inputSchema["properties"]["kind"]["enum"] == ["sfx", "music", "any"]
    assert "texture_spec" in tools["playbook"].description
    for name in ("list_textures", "list_clips", "search_audio", "playbook", "check_game"):
        assert tools[name].annotations.readOnlyHint is True, name
    for name in ("install_kit", "generate_tokens", "paint_texture", "author_clip"):
        assert tools[name].annotations.readOnlyHint is False, name
    assert "Style guide template" in text_of(call("style_guide_template"))    # the taste tools still answer
    assert "HUD" in text_of(call("rubric", aspect="hud"))


def test_tools_over_a_client_session(tmp_path):
    async def go() -> None:
        async with create_connected_server_and_client_session(S.build_server()) as client:
            listed = {t.name for t in (await client.list_tools()).tools}
            assert {"install_kit", "generate_tokens", "paint_texture", "author_clip", "playbook"} <= listed
            kit = await client.call_tool("install_kit", {"project_root": str(tmp_path)})
            assert not kit.isError and KIT_API.strip() in kit.content[0].text
            painted = await client.call_tool("paint_texture", {"project_root": str(tmp_path), "name": "glow",
                                                               "spec": GLOW})
            assert not painted.isError and [c.type for c in painted.content] == ["text", "image"]
            assert painted.content[1].mimeType == "image/png"
            clip = await client.call_tool("author_clip", {"project_root": str(tmp_path), "name": "wave", "spec": WAVE})
            assert not clip.isError and [c.type for c in clip.content] == ["text", "image"]
            bad = await client.call_tool("paint_texture", {"project_root": str(tmp_path), "name": "glow",
                                                           "spec": {"size": [2, 2], "layers": []}})
            assert bad.isError and "texture spec has" in bad.content[0].text
            refused = await client.call_tool("install_kit", {"project_root": "game"})
            assert refused.isError and "absolute path" in refused.content[0].text
    asyncio.run(go())


# ------------------------------------------------------------------------------------------------ install_kit

def test_install_kit_writes_the_kit_and_is_idempotent(tmp_path):
    out = text_of(call("install_kit", project_root=str(tmp_path)))
    kit = kit_files()
    for rel, source in kit.items():
        assert (tmp_path / rel).read_text(encoding="utf-8") == source, rel
        assert rel in out
    assert f"- created ({len(kit)}):" in out and KIT_API.strip() in out
    assert "generate_tokens" in out                                  # no Tokens yet: it says what comes next
    ws = Workspace(tmp_path)
    assert "return {}" in (tmp_path / SHARED / "AssetMap.luau").read_text(encoding="utf-8")
    assert (tmp_path / SHARED / "TexPacks" / "Index.luau").read_text(encoding="utf-8") == \
        TexturePacks(ws).index_source()
    assert (tmp_path / SHARED / "ClipPack.luau").read_text(encoding="utf-8") == anim.ClipPack(ws).luau()

    before = files(tmp_path)
    again = text_of(call("install_kit", project_root=str(tmp_path)))
    assert f"- already the kit's version ({len(kit)}):" in again and "- created (" not in again
    assert "already present, left as they are (3)" in again
    assert files(tmp_path) == before                                  # nothing rewritten, nothing added


def test_install_kit_keeps_user_edits_and_never_deletes(tmp_path):
    call("install_kit", project_root=str(tmp_path))
    kit_dir = tmp_path / "src" / "ReplicatedStorage" / "Kit"
    motion, maid, spring = kit_dir / "Motion.luau", kit_dir / "Maid.luau", kit_dir / "Spring.luau"
    edited = motion.read_text(encoding="utf-8") + "\n-- my tweak\n"
    motion.write_text(edited, encoding="utf-8")
    spring.write_bytes(spring.read_bytes().replace(b"\n", b"\r\n"))    # a CRLF checkout is not an edit
    maid.unlink()                                                     # a missing kit file comes back
    mine = tmp_path / "src" / "ServerScriptService" / "Game.server.luau"
    mine.write_text('print("mine")\n', encoding="utf-8")
    asset_map = tmp_path / SHARED / "AssetMap.luau"
    asset_map.write_text('return { coin = { id = "rbxasset://coin.png" } }\n', encoding="utf-8")

    out = text_of(call("install_kit", project_root=str(tmp_path)))
    kept = next(line for line in out.splitlines() if line.startswith("- kept"))
    assert "src/ReplicatedStorage/Kit/Motion.luau" in kept and "overwrite=true" in kept
    assert "Spring.luau" not in kept and motion.read_text(encoding="utf-8") == edited
    assert b"\r\n" in spring.read_bytes()                             # same text: left alone
    assert "- created (1): src/ReplicatedStorage/Kit/Maid.luau" in out
    assert maid.read_text(encoding="utf-8") == kit_files()["src/ReplicatedStorage/Kit/Maid.luau"]

    out = text_of(call("install_kit", project_root=str(tmp_path), overwrite=True))
    assert "replaced with the kit's version" in out and "Motion.luau" in out
    assert motion.read_text(encoding="utf-8") == kit_files()["src/ReplicatedStorage/Kit/Motion.luau"]
    assert mine.read_text(encoding="utf-8") == 'print("mine")\n'      # the user's own scripts stay
    assert "coin" in asset_map.read_text(encoding="utf-8")           # generated modules are never replaced


def test_project_root_must_be_an_existing_absolute_directory(tmp_path):
    not_dir = tmp_path / "notes.txt"
    not_dir.write_text("x", encoding="utf-8")
    for bad, why in (("", "project_root is required"), ("relative/game", "absolute path"),
                     (str(not_dir), "is not a directory"), (str(tmp_path / "missing"), "does not exist")):
        with pytest.raises(ToolError, match=why):
            call("install_kit", project_root=bad)
    with pytest.raises(ToolError, match="absolute path"):
        call("paint_texture", project_root="game", name="dot", spec=GLOW)
    assert not (tmp_path / "missing").exists() and not Path("relative").exists() and not Path("game").exists()
    assert sorted(p.name for p in tmp_path.iterdir()) == ["notes.txt"]


# ------------------------------------------------------------------------------------------------ path safety

def test_names_that_are_paths_are_refused(tmp_path):
    game, outside = tmp_path / "game", tmp_path / "outside"
    game.mkdir()
    outside.mkdir()
    for tool, name, spec in (("paint_texture", "../outside/evil", GLOW), ("paint_texture", "..", GLOW),
                             ("paint_texture", "C:evil", GLOW), ("author_clip", "..\\outside\\evil", WAVE),
                             ("author_clip", "clips/evil", WAVE)):
        with pytest.raises(ToolError, match="not a path"):
            call(tool, project_root=str(game), name=name, spec=spec)
    assert list(game.iterdir()) == [] and list(outside.iterdir()) == []
    root = game.resolve()
    S._inside(root, root / "src" / "ReplicatedStorage" / "A.luau")         # inside: fine
    for escape in (root / ".." / "outside" / "A.luau", Path(root.anchor) / "A.luau"):
        with pytest.raises(ValueError, match="outside the project"):
            S._inside(root, escape)


def test_links_out_of_the_project_are_refused(tmp_path):
    outside = tmp_path / "outside"
    outside.mkdir()
    art_game = tmp_path / "art_game"
    art_game.mkdir()
    link_dir(art_game / "art", outside)                               # art/ leads out of the project
    for tool, args in (("paint_texture", {"name": "dot", "spec": GLOW}), ("author_clip", {"name": "wave", "spec": WAVE})):
        with pytest.raises(ToolError, match="outside the project"):
            call(tool, project_root=str(art_game), **args)
    src_game = tmp_path / "src_game"
    src_game.mkdir()
    link_dir(src_game / "src", outside)                               # so does src/
    for tool, args in (("install_kit", {}), ("generate_tokens", {"style": STYLE}),
                       ("paint_texture", {"name": "dot", "spec": GLOW}), ("author_clip", {"name": "wave", "spec": WAVE})):
        with pytest.raises(ToolError, match="outside the project"):
            call(tool, project_root=str(src_game), **args)
    assert list(outside.iterdir()) == []                              # nothing reached the link targets
    assert sorted(p.name for p in art_game.iterdir()) == ["art"] and sorted(p.name for p in src_game.iterdir()) == ["src"]


# ------------------------------------------------------------------------------------------------ paint_texture

def test_paint_texture_returns_the_preview_and_packs_it(tmp_path):
    call("install_kit", project_root=str(tmp_path))
    res = call("paint_texture", project_root=str(tmp_path), name="panel_skin", spec=PANEL)
    assert not isinstance(res, CallToolResult)
    text = text_of(res)
    assert 'Textures.apply(imageLabel, "panel_skin")' in text and "64x64 RGBA" in text
    assert "[20, 20, 44, 44]" in text and "art/panel_skin.png" in text
    assert "not in this project yet" not in text                      # the kit is installed
    [png] = pngs_of(res)
    preview = Image.open(io.BytesIO(png))
    assert preview.format == "PNG" and preview.width > 2 * 64          # the texture and its 9-slice stretch
    saved = Image.open(tmp_path / "art" / "panel_skin.png")
    packs = TexturePacks(Workspace(tmp_path))
    assert saved.size == (64, 64) and packs.names() == ["panel_skin"]
    assert decode(packs.data("panel_skin")) == rgba_bytes(saved)
    assert '["panel_skin"]' in (tmp_path / SHARED / "TexPacks" / "Index.luau").read_text(encoding="utf-8")
    assert (tmp_path / SHARED / "TexPacks" / "Pack1.luau").is_file()

    res = call("paint_texture", project_root=str(tmp_path), name="spark", spec=json.dumps(GLOW))   # JSON text too
    assert "32x32 LA" in text_of(res) and len(pngs_of(res)) == 1

    bad = call("paint_texture", project_root=str(tmp_path), name="oops",
               spec={"size": [64, 64], "layers": [{"shape": "circle", "colour": "#FFFFFF"}]})
    assert isinstance(bad, CallToolResult) and bad.isError
    assert "did you mean 'color'" in text_of(bad) and not pngs_of(bad)
    assert not (tmp_path / "art" / "oops.png").exists()
    bad_name = call("paint_texture", project_root=str(tmp_path), name="Oops", spec=GLOW)
    assert bad_name.isError and "bad texture name" in text_of(bad_name)
    assert TexturePacks(Workspace(tmp_path)).names() == ["panel_skin", "spark"]

    listing = text_of(call("list_textures", project_root=str(tmp_path)))
    assert "panel_skin: 64x64 RGBA, slice [20, 20, 44, 44]" in listing and "spark: 32x32 LA" in listing


def test_concurrent_paints_on_one_project_keep_every_texture(tmp_path):
    async def paint_three() -> list:
        return await asyncio.gather(*(SERVER.call_tool("paint_texture", {"project_root": str(tmp_path),
                                                                          "name": f"dot_{i}", "spec": GLOW})
                                      for i in range(3)))
    results = asyncio.run(paint_three())
    assert not any(isinstance(r, CallToolResult) for r in results)
    assert TexturePacks(Workspace(tmp_path)).names() == ["dot_0", "dot_1", "dot_2"]
    assert "Kit.Textures is not in this project yet" in text_of(results[0])      # no install_kit here


# ------------------------------------------------------------------------------------------------ author_clip

def test_author_clip_returns_the_preview_and_packs_it(tmp_path):
    call("install_kit", project_root=str(tmp_path))
    res = call("author_clip", project_root=str(tmp_path), name="wave", spec=WAVE)
    assert not isinstance(res, CallToolResult)
    text = text_of(res)
    assert "Packed wave: 0.8s one-shot" in text and 'rig:play("wave"' in text and 'track.Marker("hit")' in text
    assert "art/clips/wave.png" in text and "not in this project yet" not in text
    [png] = pngs_of(res)
    assert Image.open(io.BytesIO(png)).format == "PNG"
    assert (tmp_path / "art" / "clips" / "wave.png").read_bytes() == png
    assert '["wave"] = {' in (tmp_path / SHARED / "ClipPack.luau").read_text(encoding="utf-8")
    assert json.loads((tmp_path / "clip_pack.json").read_text(encoding="utf-8"))["clips"]["wave"]["length"] == 0.8

    again = call("author_clip", project_root=str(tmp_path), name="wave", spec=json.dumps(WAVE))
    assert text_of(again).startswith("Replaced wave")

    kick = json.loads(json.dumps(WAVE))
    kick["keys"][1]["pose"]["Nek"] = [1, 0, 0]
    bad = call("author_clip", project_root=str(tmp_path), name="kick", spec=kick)
    assert isinstance(bad, CallToolResult) and bad.isError
    assert "'kick' was NOT packed" in text_of(bad) and "did you mean 'Neck'" in text_of(bad)
    assert len(pngs_of(bad)) == 1                                      # the clip as written, still shown
    assert not (tmp_path / "art" / "clips" / "kick.png").exists()
    assert '"kick"' not in (tmp_path / SHARED / "ClipPack.luau").read_text(encoding="utf-8")

    listed = text_of(call("list_clips", project_root=str(tmp_path)))
    assert "1 clip(s)" in listed and "wave: 0.8s one-shot, priority action" in listed


# ------------------------------------------------------------------------------------------------ generate_tokens

def test_generate_tokens_writes_the_tokens_module(tmp_path):
    tokens_file = tmp_path / SHARED / "Tokens.luau"
    out = text_of(call("generate_tokens", project_root=str(tmp_path), style=STYLE))
    source, repaired = build_tokens(STYLE)
    assert tokens_file.read_text(encoding="utf-8") == source
    assert out.startswith("Wrote src/ReplicatedStorage/Shared/Tokens.luau") and "primary='orange'" in out
    assert repaired and all(f"- {p}" in out for p in repaired)
    assert 'gold = Color3.fromHex("#FFD700")' in source

    good = {**STYLE, "palette": {**STYLE["palette"], "primary": "#FFB02E"}}
    (tmp_path / "style.json").write_text(json.dumps(good), encoding="utf-8")
    out = text_of(call("generate_tokens", project_root=str(tmp_path), style="style.json"))    # a file in the project
    assert out.startswith("Rewrote") and "No values needed repair." in out
    assert tokens_file.read_text(encoding="utf-8") == build_tokens(good)[0]

    out = text_of(call("generate_tokens", project_root=str(tmp_path), style=json.dumps({"palette": {}, "colors": {}})))
    assert "Ignored (not STYLE keys): colors." in out and "defaults were used: fonts, type_scale" in out
    with pytest.raises(ToolError, match="not valid JSON"):
        call("generate_tokens", project_root=str(tmp_path), style='{"palette": ')
    with pytest.raises(ToolError, match="neither a JSON object nor an existing file"):
        call("generate_tokens", project_root=str(tmp_path), style="missing.json")


# ------------------------------------------------------------------------------------------------ playbook

def test_playbook_serves_and_lists():
    books = sorted(p.stem for p in S.PLAYBOOKS.glob("*.md"))
    listing = text_of(call("playbook"))
    assert listing.startswith("Playbooks") and all(f"- {name}: " in listing for name in books)
    for name in ("texture_spec", "animation_spec", "roblox_craft", "style_guide", "plan", "rubric_hud"):
        assert text_of(call("playbook", name=name)) == (S.PLAYBOOKS / f"{name}.md").read_text(encoding="utf-8")
    assert text_of(call("playbook", name="Texture Spec.md")) == text_of(call("playbook", name="texture_spec"))
    assert text_of(call("playbook", name="hud")) == text_of(call("playbook", name="rubric_hud"))
    vfx = S.PLAYBOOKS / "vfx_camera_spec.md"                           # written by another change; may be absent
    out = text_of(call("playbook", name="vfx_camera_spec"))
    if vfx.is_file():
        assert out == vfx.read_text(encoding="utf-8")
    else:
        assert out.startswith("No playbook named 'vfx_camera_spec'.")

    missing = text_of(call("playbook", name="no_such_book"))
    assert missing.startswith("No playbook named 'no_such_book'.") and "- texture_spec: " in missing
    escape = text_of(call("playbook", name="../../ARCHITECTURE"))
    assert escape.startswith("No playbook named") and "module contracts" not in escape
    rubrics = text_of(call("playbook", name="rubrics"))
    general = (S.PLAYBOOKS / "rubric_general.md").read_text(encoding="utf-8").strip()
    assert rubrics.startswith(general.splitlines()[0]) and "- rubric_hud: " in rubrics


# ------------------------------------------------------------------------------------------------ search_audio

def test_search_audio_ranks_and_caches_without_network(tmp_path, monkeypatch):
    monkeypatch.setenv("HARNESS_CAPTURE_DIR", str(tmp_path / "caps"))
    rows = [{"id": 3, "title": "Coin Jingle Song", "creator": "someone", "verified": False, "seconds": 95.0,
             "type": "Music", "up": 1, "down": 0},
            {"id": 2, "title": "coin pickup 2", "creator": "maker", "verified": True, "seconds": 0.6,
             "type": "SoundEffect", "up": 50, "down": 1},
            {"id": 1, "title": "Coin Pickup", "creator": "Roblox", "verified": True, "seconds": 0.4,
             "type": "SoundEffect", "up": 10, "down": 0}]
    fetched: list[str] = []

    async def fake_fetch(self, query: str) -> list[dict]:
        fetched.append(query)
        return [dict(r) for r in rows] if query == "coin pickup" else []
    monkeypatch.setattr(audio.AudioSearch, "_fetch", fake_fetch)

    lines = text_of(call("search_audio", query="Coin Pickup")).splitlines()
    assert lines[0].startswith("rbxassetid://1 ") and "by Roblox (verified)" in lines[0]    # the licensed library first
    assert lines[1].startswith("rbxassetid://2 ") and lines[2].startswith("rbxassetid://3 ")
    assert "Sound.register" in lines[-1]
    music = text_of(call("search_audio", query="coin pickup ", kind="music", limit=1))
    assert music.splitlines()[0].startswith("rbxassetid://3 ") and "rbxassetid://1 " not in music
    assert fetched == ["coin pickup"]                                  # the second search came from the cache
    cache = json.loads((tmp_path / "caps" / "audio_cache.json").read_text(encoding="utf-8"))
    assert [r["id"] for r in cache["coin pickup"]] == [3, 2, 1]
    S._state["audio"].clear()                                          # a new server process reads the cache file
    assert text_of(call("search_audio", query="coin pickup")).startswith("rbxassetid://1 ")
    assert fetched == ["coin pickup"]

    monkeypatch.setenv("HARNESS_CAPTURE_DIR", str(tmp_path / "caps2"))
    assert text_of(call("search_audio", query="glass harmonica")).startswith("no audio found for 'glass harmonica'")
    with pytest.raises(ToolError, match="query is required"):
        call("search_audio", query="  ")


def test_check_game_reports_wiring_and_syntax(tmp_path):
    src = tmp_path / "src" / "ServerScriptService"
    src.mkdir(parents=True)
    (src / "Main.server.luau").write_text('local Config = require(script.Parent:WaitForChild("Config"))\n',
                                          encoding="utf-8")
    out = text_of(call("check_game", project_root=str(tmp_path)))
    assert "1 problem(s) in 1 of 1 file(s)" in out
    assert "WIRING line 1:" in out and "ServerScriptService.Config, which does not exist" in out
    (src / "Main.server.luau").write_text("print('ok')\n", encoding="utf-8")
    assert "No problems in 1 file(s)." in text_of(call("check_game", project_root=str(tmp_path)))

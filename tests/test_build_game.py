"""Offline tests for the taste core and the build workflow: tokens, architecture normalisation, the judge's
parsing, the stage's command channel and image helpers, the kit's Luau, and a full dry run of build_game with a
scripted fake model (no Studio, no network)."""
from __future__ import annotations

import asyncio
import io
import json
import re
from pathlib import Path

import httpx
import pytest
from PIL import Image

from harness import schemas
from harness.judge import _parse_json, _verdict
from harness.kit import KIT_DIR, MODULES, kit_files
from harness.llm import LLMResponse, Message, ToolCall
from harness.stage import CommandServer, magenta_bbox, parse_command
from harness.tokens import build_tokens, lighting_script
from harness.tools.luau import analyzer, check_sources, syntax_errors
from harness.workflows.build_game import Build, BuildConfig, normalize_arch, style_markdown

STYLE = {
    "direction": "warm dusk harbour, tactile and calm",
    "references": ["a cosy fishing game"], "avoid": ["grey", "clutter"],
    "palette": {"bg": "#10151C", "surface": "#1C2430", "surface_raised": "#283243", "text": "#F7F3EA",
                "text_muted": "#B8B2A6", "primary": "#FFB547", "secondary": "#5CC8D7", "success": "#6BD68A",
                "warning": "#FFD35C", "danger": "#FF6B5C", "sea foam": "#9FE3D6"},
    "fonts": {"display": "FredokaOne", "heading": "Montserrat:Bold", "body": "BuilderSans", "numeric": "GothamBold"},
    "type_scale": {"display": 80, "h1": 44, "h2": 30, "body": 22, "caption": 16, "numeric": 30},
    "radius": {"small": 8, "medium": 14, "large": 24}, "stroke": 2,
    "depth_recipe": "soft shadow, gradient body, 1dp rim", "shape_language": "rounded, chunky",
    "motion": {"fast": 0.1, "base": 0.2, "slow": 0.35, "dramatic": 0.7, "ease_out": "Back", "ease_in": "Quad"},
    "camera": "third person, FOV 70", "vfx": "soft painterly bursts", "world": "harbour at dusk",
    "lighting": {"ClockTime": 17.8, "Brightness": 2.2, "Ambient": "#3A3550", "OutdoorAmbient": "#8A7A90",
                 "atmosphere": {"Density": 0.32, "Haze": 1.4, "Color": "#FFC89A"}, "bloom": {"Intensity": 0.4}},
    "audio": "gentle waves, soft marimba", "reference_shots": [{"name": "title", "prompt": "harbour title screen"}],
}


def test_tokens_generate_and_repair():
    src, problems = build_tokens({**STYLE, "palette": {**STYLE["palette"], "primary": "orange"},
                                  "motion": {**STYLE["motion"], "ease_out": "Bouncy"}})
    assert 'Color3.fromHex("#10151C")' in src
    assert "sea_foam" in src                                  # token names become Luau identifiers
    assert any("primary" in p for p in problems) and any("ease_out" in p for p in problems)
    assert "Enum.EasingStyle.Quint" in src                    # repaired easing
    assert 'font("Montserrat", "Bold")' in src
    assert "Lighting.ClockTime = 17.8" in lighting_script(STYLE)


@pytest.mark.skipif(analyzer() is None, reason="luau-analyze not installed")
def test_generated_luau_and_kit_parse():
    src, _ = build_tokens(STYLE)
    sources = {"ReplicatedStorage/Shared/Tokens.luau": src, "lighting.luau": lighting_script(STYLE)}
    sources.update(kit_files())
    bad = syntax_errors(asyncio.run(check_sources(sources)))
    assert bad == {}, bad


def test_syntax_gate_catches_errors():
    if analyzer() is None:
        pytest.skip("luau-analyze not installed")
    bad = syntax_errors(asyncio.run(check_sources({"a.luau": "local x = \nreturn +"})))
    assert "a.luau" in bad


def test_normalize_arch_ownership_and_paths():
    arch = {"files": [{"path": "src/ServerScriptService/Game.server.luau", "responsibility": "r", "api": "a"}],
            "remotes": [], "debug_commands": [],
            "items": [
                {"id": "Core Loop", "aspect": "core_loop", "title": "core", "brief": "b",
                 "files": ["src/ServerScriptService/Game.server.luau", "ReplicatedStorage/Shared/Tokens.luau"],
                 "capture": {"kind": "loop", "description": "d"}},
                {"id": "hud", "aspect": "not_an_aspect", "title": "hud", "brief": "b", "depends_on": ["core_loop", "ghost"],
                 "files": ["ServerScriptService/Game.server.luau", "StarterPlayer/StarterPlayerScripts/Hud.client.luau"],
                 "capture": {"kind": "screen", "commands": ["show_hud"], "description": "d"}},
                {"id": "empty", "aspect": "vfx", "title": "x", "brief": "b", "files": ["../evil.luau"],
                 "capture": {"kind": "moment", "description": "d"}},
            ]}
    out, notes = normalize_arch(arch, 16)
    ids = [i["id"] for i in out["items"]]
    assert ids == ["core_loop", "hud"]
    assert out["items"][0]["files"] == ["ServerScriptService/Game.server.luau"]      # Tokens is harness-owned
    assert out["items"][1]["files"] == ["StarterPlayer/StarterPlayerScripts/Hud.client.luau"]
    assert out["items"][1]["aspect"] == "core_loop" and out["items"][1]["depends_on"] == ["core_loop"]
    assert any("already owned" in n for n in notes) and any("dropped" in n for n in notes)


def test_judge_parsing_and_verdict():
    text = 'Sure!\n```json\n{"score": 12, "issues": [{"severity": "BLOCKER", "where": "hud", "problem": "p", ' \
           '"fix": "f"}, "junk"], "strengths": ["x"]}\n```'
    obj = _parse_json(text)
    v = _verdict("hud", obj, 7.0)
    assert v.score == 10.0 and not v.passed and v.issues[0].severity == "blocker"
    assert "FIX: f" in v.fix_list()


def test_magenta_bbox_and_commands():
    im = Image.new("RGB", (1600, 900), (40, 40, 40))
    for x in range(300, 1500):
        for y in range(120, 820, 1):
            pass
    im.paste((255, 0, 255), (300, 120, 1500, 820))
    buf = io.BytesIO()
    im.save(buf, format="PNG")
    assert magenta_bbox(buf.getvalue()) == (300, 120, 1500, 820)
    assert parse_command('grant_coins 500 true "big win" 1.5') == ("grant_coins", [500, True, "big win", 1.5])


def test_command_server_roundtrip():
    async def go():
        srv = CommandServer("tok")
        await srv.start()
        try:
            base = f"http://127.0.0.1:{srv.port}/cybus/"
            async with httpx.AsyncClient(timeout=20) as http:
                r = await http.post(base + "hello", json={"token": "tok", "place": 0})
                assert r.status_code == 200 and srv.hello.is_set()
                assert (await http.get(base + "next?token=bad")).status_code == 403
                call = asyncio.create_task(srv.call("show_shop", 3, timeout=10))
                cmd = (await http.get(base + "next?token=tok")).json()
                assert cmd["name"] == "show_shop" and cmd["args"] == [3]
                await http.post(base + "result", json={"token": "tok", "id": cmd["id"],
                                                       "result": {"ok": True, "side": "client"}})
                assert (await call)["ok"] is True
        finally:
            await srv.stop()
    asyncio.run(go())


# ------------------------------------------------------------------------------------------------ dry run

ARCH = {
    "files": [{"path": "ServerScriptService/Game.server.luau", "responsibility": "rounds", "api": "none"},
              {"path": "ReplicatedStorage/Shared/Config.luau", "responsibility": "config", "api": "Config.values"},
              {"path": "StarterPlayer/StarterPlayerScripts/Hud.client.luau", "responsibility": "hud", "api": "none"}],
    "remotes": [{"name": "RoundState", "kind": "RemoteEvent", "direction": "server->client", "payload": "state"}],
    "debug_commands": [{"name": "show_hud", "side": "client", "effect": "shows the HUD"}],
    "items": [
        {"id": "core", "aspect": "core_loop", "title": "Core loop", "brief": "Rounds.",
         "files": ["ServerScriptService/Game.server.luau", "ReplicatedStorage/Shared/Config.luau"],
         "capture": {"kind": "loop", "commands": ["start_round"], "description": "a round"}},
        {"id": "hud", "aspect": "hud", "title": "HUD", "brief": "Timer and score.", "depends_on": ["core"],
         "files": ["StarterPlayer/StarterPlayerScripts/Hud.client.luau"],
         "capture": {"kind": "screen", "commands": ["show_hud"], "description": "the HUD"}},
    ],
}
PLAN = {"title": "Harbour Lights", "fantasy": "keeper of a harbour at dusk", "hook": "light the way home",
        "core_loop": ["spot a boat", "aim the beam", "guide it in", "earn lanterns"],
        "verbs": [{"name": "aim", "input": "mouse / touch drag", "feedback": "beam sweep"}],
        "signature_moment": "the last boat home in a storm", "first_minute": "boats appear", "session": "5 nights",
        "systems": [{"name": "rounds", "responsibility": "nights", "side": "server"}],
        "screens": [{"name": "HUD", "job": "time and lanterns", "reads_first": "time"}],
        "content": [{"kind": "prop", "name": "lighthouse", "source": "built"}],
        "aspects": {a: "done" for a in schemas.ASPECTS}, "risks": ["scope"]}


class FakeLLM:
    """Plays every role: answers each structured call with a canned object; builders write their files first."""

    def __init__(self):
        self.calls = 0

    async def chat(self, messages, tools=None):
        self.calls += 1
        names = [t["function"]["name"] for t in tools or []]
        submit = next((t["function"]["parameters"] for t in tools or [] if t["function"]["name"] == "submit"), None)
        props = set((submit or {}).get("properties", {}))
        wrote = any(m.role == "tool" for m in messages)
        if "write_file" in names and not wrote:
            task = messages[1].content if isinstance(messages[1].content, str) else messages[1].content[0]["text"]
            owned = re.search(r"FILES YOU OWN\n((?:- .+\n)+)", task + "\n")
            calls = []
            for i, line in enumerate((owned.group(1) if owned else "").splitlines()):
                path = line[2:].strip()
                body = "local M = {}\nfunction M.start() end\nreturn M\n" if path.endswith(".luau") and not \
                    path.endswith((".server.luau", ".client.luau")) else "print('ok')\n"
                calls.append(ToolCall(f"w{i}", "write_file", {"path": path, "content": body}))
            return LLMResponse(Message("assistant", "", tool_calls=calls), {}, "tool_calls", {})
        if "fantasy" in props:
            out = PLAN
        elif "palette" in props:
            out = STYLE
        elif "items" in props:
            out = ARCH
        elif "verdict" in props:
            out = {"verdict": "pass", "issues": []}
        elif "assignments" in props:
            out = {"assignments": []}
        else:
            out = {"summary": "built", "files": [], "how_to_see_it": "run show_hud"}
        return LLMResponse(Message("assistant", "", tool_calls=[ToolCall("s", "submit", out)]), {}, "tool_calls", {})


def test_build_game_dry_run(tmp_path: Path):
    from harness.tools.workspace import Workspace
    from harness.workflow import Workflow
    fake = FakeLLM()
    roles = {r: fake for r in ("lead", "art", "builder", "critic", "judge")}
    wf = Workflow("dry", tmp_path, roles, resume=False)
    ws = Workspace(tmp_path / "workspace")
    report = asyncio.run(Build(wf, ws, None, fake, BuildConfig(), tmp_path).run({"id": "harbour", "pitch": "x"}))
    assert report["title"] == "Harbour Lights"
    files = set(ws.files())
    assert "ReplicatedStorage/Shared/Tokens.luau" in files and "ReplicatedStorage/Kit/Motion.luau" in files
    assert ws.read("StarterPlayer/StarterPlayerScripts/Hud.client.luau").startswith("print")
    assert "M.start" in ws.read("ReplicatedStorage/Shared/Config.luau")
    for name in ("plan.json", "style.json", "architecture.json", "report.json", "style.md"):
        assert (tmp_path / name).exists(), name
    assert "PALETTE" in style_markdown(STYLE)

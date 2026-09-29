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


def test_command_server_sessions_and_stale_polls():
    """A poll counts as hello; after reset() the previous session's poll can never take new commands."""
    async def go():
        srv = CommandServer("tok")
        await srv.start()
        try:
            base = f"http://127.0.0.1:{srv.port}/cybus/"
            async with httpx.AsyncClient(timeout=20) as http:
                stale = asyncio.create_task(http.get(base + "next?token=tok&session=old"))
                await asyncio.sleep(0.3)
                assert srv.hello.is_set() and srv.session == "old"
                srv.reset()                                            # the play session ended; a new one starts
                assert not srv.hello.is_set() and srv.session is None
                call = asyncio.create_task(srv.call("show_hud", timeout=10))
                cmd = (await http.get(base + "next?token=tok&session=new")).json()
                assert cmd.get("name") == "show_hud" and srv.session == "new"
                assert (await stale).json() == {}                      # the old poll got nothing
                late = (await http.get(base + "next?token=tok&session=old")).json()
                assert late == {}                                      # and so does any later straggler
                await http.post(base + "result", json={"token": "tok", "session": "new", "id": cmd["id"],
                                                       "result": {"ok": True}})
                assert (await call)["ok"] is True
        finally:
            await srv.stop()
    asyncio.run(go())


def test_final_place_builds_with_rojo(tmp_path: Path):
    from harness.place import build_place, rojo_exe
    from harness.tools.workspace import Workspace
    if not rojo_exe():
        pytest.skip("rojo not installed")
    ws = Workspace(tmp_path / "ws")
    for rel, src in kit_files().items():
        ws.write(rel, src)
    ws.write("StarterPlayer/StarterPlayerScripts/Hud.client.luau", "print('hud')\n")
    out = build_place(ws.root, tmp_path / "final.rbxlx", "t", "run_x", STYLE)
    xml = out.read_text(encoding="utf-8")
    for needle in ("CybusHarnessRun", "HttpEnabled", "Atmosphere", "KitBoot", "Hud", "LocalScript", "ClockTime"):
        assert needle in xml, needle
    assert (ws.root / "default.project.json").exists()


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
        elif "choice" in props:
            out = {"choice": 1, "why": "calmer and more cohesive", "graft": ["warm rim light on panels"]}
        else:
            out = {"summary": "built", "files": [], "how_to_see_it": "run show_hud"}
        return LLMResponse(Message("assistant", "", tool_calls=[ToolCall("s", "submit", out)]), {}, "tool_calls", {})


def _png(color=(60, 90, 140), size=(320, 180)) -> bytes:
    buf = io.BytesIO()
    Image.new("RGB", size, color).save(buf, format="PNG")
    return buf.getvalue()


class FakeBridge:
    def __init__(self):
        self.calls = []

    async def call(self, name, args=None):
        self.calls.append((name, args))
        return {}


class FakeStage:
    """Stands in for Studio: every capture is a flat image, the game logs one error from the HUD script."""

    def __init__(self):
        from contextlib import asynccontextmanager
        self.lock = asyncio.Lock()
        self.bridge = FakeBridge()
        self.commands, self.keys, self.plays = [], [], 0
        self._acm = asynccontextmanager

    async def edit(self, code, timeout_ms=20000):
        return {"value": "ok"}

    async def sync(self):
        return {"pushed": [], "held_back": {}}

    async def play(self, timeout=90):
        self.plays += 1

    async def stop(self):
        pass

    async def cmd(self, line, *args, timeout=30):
        self.commands.append(line)
        if line == "__list":
            return {"side": "server", "ok": True, "result": json.dumps({"start_round": "starts a round"})}
        if line == "__client_list":
            return {"side": "client", "ok": True, "replies": [{"ok": True, "result": json.dumps({"show_hud": "shows"})}]}
        if line == "__sound_manifest":
            return {"side": "client", "ok": True, "replies": [{"ok": True, "result": "{}"}]}
        return {"side": "client", "ok": True, "replies": []}

    async def logs(self):
        return [{"kind": "error", "side": "client",
                 "text": "StarterPlayer.StarterPlayerScripts.Hud:3: attempt to index nil with 'Text'"},
                {"kind": "output", "side": "server", "text": "round started"}]

    async def events(self):
        return [{"t": 1.0, "name": "round_started", "side": "server", "data": {"round": 1}},
                {"t": 1.5, "name": "sound", "side": "client", "data": {"name": "ui_click"}}]

    async def shot(self, label):
        return _png()

    async def strip(self, seconds, n, label):
        return [_png((20 * i, 40, 90)) for i in range(n)]

    async def key(self, key, hold_ms=0):
        self.keys.append(key)

    def session(self):
        stage = self

        @self._acm
        async def ctx():
            async with stage.lock:
                await stage.play()
                yield {"pushed": []}
        return ctx()

    async def capture(self, label, kind, commands, **kw):
        from harness.stage import Capture
        cap = Capture(label=label, logs=await self.logs())
        for c in commands:
            cap.command_results.append({"command": c, **(await self.cmd(c))})
        cap.images = await self.strip(2, 8, label) if kind in ("moment", "loop") else [await self.shot(label)]
        return cap


class JudgingFakeLLM(FakeLLM):
    """FakeLLM that also judges (plain JSON replies when no tools are offered) and scripts captures."""

    def __init__(self):
        super().__init__()
        self.judged = 0

    async def chat(self, messages, tools=None):
        if not tools:                                   # a judge call
            self.judged += 1
            return LLMResponse(Message("assistant", json.dumps({
                "score": 6, "strengths": ["clear palette"],
                "issues": [{"severity": "major", "where": "hud timer", "problem": "too small", "fix": "raise to 32 dp"}]})),
                {}, "stop", {})
        submit = next((t["function"]["parameters"] for t in tools if t["function"]["name"] == "submit"), None)
        props = set((submit or {}).get("properties", {}))
        if "shots" in props:
            out = {"shots": [{"file": "captures/hud__play.png", "kind": "still", "commands": ["show_hud"]},
                             {"file": "captures/camera__explore", "kind": "strip", "seconds": 1, "frames": 3,
                              "keys": [{"key": "w", "hold_ms": 100}]},
                             {"file": "../../etc/passwd", "kind": "still"}]}
            return LLMResponse(Message("assistant", "", tool_calls=[ToolCall("s", "submit", out)]), {}, "tool_calls", {})
        if "assignments" in props:
            out = {"assignments": [{"item_id": "hud", "issues": ["timer too small"]}, {"item_id": "ghost", "issues": ["x"]}]}
            return LLMResponse(Message("assistant", "", tool_calls=[ToolCall("s", "submit", out)]), {}, "tool_calls", {})
        return await super().chat(messages, tools)


def test_build_game_with_fake_stage(tmp_path: Path):
    """Every Studio-facing path (item capture/judge/fix, integrate + panel + routing, final report, evidence)
    runs against a fake Studio."""
    from harness.tools.workspace import Workspace
    from harness.workflow import Workflow
    fake = JudgingFakeLLM()
    roles = {r: fake for r in ("lead", "art", "builder", "critic", "judge")}
    wf = Workflow("fake-stage", tmp_path, roles, resume=False)
    ws = Workspace(tmp_path / "workspace")
    stage = FakeStage()
    cfg = BuildConfig(repair_rounds=1, polish_rounds=1)
    plan = {"items": [{"file": "captures/hud__play.png", "kind": "still", "what": "hud", "required": True},
                      {"file": "captures/camera__explore__NN.png", "kind": "strip", "what": "moving", "required": True}]}
    report = asyncio.run(Build(wf, ws, stage, fake, cfg, tmp_path).run({"id": "harbour", "pitch": "x"}, plan))
    assert set(report["items"]) == {"core", "hud"}
    assert all(1 <= r["score"] <= 10 for r in report["items"].values())
    verdicts = json.loads((tmp_path / "verdicts" / "hud.json").read_text(encoding="utf-8"))
    assert [v["round"] for v in verdicts] == [0, 1, 99]           # built, fixed once, final
    assert any("attempt to index nil" in e for e in verdicts[0]["errors"])   # error routed to the HUD's owner
    assert json.loads((tmp_path / "verdicts" / "core.json").read_text(encoding="utf-8"))[0]["errors"] == []
    panel = json.loads((tmp_path / "panel_r0.json").read_text(encoding="utf-8"))
    assert "hud" in panel["errors"] and panel["scores"]["cohesion"] == 6
    assert (tmp_path / "captures" / "hud__play.png").exists()
    assert sorted(p.name for p in (tmp_path / "captures").glob("camera__explore__*.png")) == \
        ["camera__explore__00.png", "camera__explore__01.png", "camera__explore__02.png"]
    assert not (tmp_path.parent / "etc").exists()
    ev = json.loads((tmp_path / "evidence.json").read_text(encoding="utf-8"))
    assert [s["ok"] for s in ev["shots"]] == [True, True, False]
    assert (tmp_path / "logs" / "audio_events.log").read_text(encoding="utf-8").count("ui_click") == 1
    assert "round_started" in (tmp_path / "logs" / "playtest.log").read_text(encoding="utf-8")
    assert (tmp_path / "captures" / "audio_design__sound_map.png").exists()
    assert "w" in stage.keys
    from harness.place import rojo_exe
    if rojo_exe():                                                  # the final place is built with rojo
        assert (tmp_path / "place" / "final.rbxlx").exists() and report.get("place_file") is None
    labels = [json.loads(l).get("label") for l in (tmp_path / "journal.jsonl").read_text(encoding="utf-8").splitlines()
              if l.strip()]
    assert "fix:hud:0" in labels and "route_r0" in labels and "capture-director" in labels


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

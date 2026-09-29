"""Studio Bridge client, capture helpers and workspace sync.

No network, except test_live_studio_smoke: it runs only with HARNESS_LIVE_STUDIO=1 and only reads.
The fake bridge is the real StudioBridge with its transport (_send) and window count replaced, so the guard,
the place assertion, the retries and the sync payloads under test are the real ones; `sent` is exactly what
would have reached the bridge server.
"""
from __future__ import annotations

import asyncio
import base64
import io
import json
import os
import re
import time

import pytest
from mcp import types as mt
from PIL import Image

from harness.tools import capture
from harness.tools.studio import (
    BLOCKED, CONTROL, READ_ONLY, WRONG_PLACE, StudioBridge, StudioError, StudioRefused, _SessionLost, is_mutating,
    parse_result,
)
from harness.tools.workspace import Workspace, build_sync_luau, lua_long_string, parse_rel

PROTECTED = "82121330849989"
ALLOWED = "4815162342"
OTHER = "1234567"


def run(coro):
    return asyncio.run(coro)


def png(w: int, h: int, color=(200, 60, 40)) -> bytes:
    buf = io.BytesIO()
    Image.new("RGB", (w, h), color).save(buf, format="PNG")
    return buf.getvalue()


FAKE_SPECS = [
    {"name": "instance_get", "description": "Get an instance.",
     "inputSchema": {"$schema": "http://json-schema.org/draft-07/schema#", "type": "object",
                     "properties": {"path": {"type": "string"}, "depth": {"type": "integer"}},
                     "required": ["path"], "additionalProperties": False}},
    {"name": "instance_create", "description": "Create an instance.",
     "inputSchema": {"type": "object", "properties": {"class_name": {"type": "string"}, "name": {"type": "string"},
                                                      "parent_path": {"type": "string"}},
                     "required": ["class_name", "name", "parent_path"]}},
    {"name": "instance_delete", "description": "Delete.", "inputSchema": {"type": "object", "properties": {}}},
    {"name": "screenshot_take", "description": "Screenshot.", "inputSchema": {"type": "object", "properties": {}}},
    {"name": "execution_run_luau", "description": "Run Luau.",
     "inputSchema": {"type": "object", "properties": {"code": {"type": "string"}}, "required": ["code"]}},
    {"name": "session_connect", "description": "Link.", "inputSchema": {"type": "object", "properties": {}}},
    {"name": "studio_kill", "description": "Kill.", "inputSchema": {"type": "object", "properties": {}}},
]

JOB_FILE = re.compile(r'\{file = "((?:[^"\\]|\\.)*)"')


class FakeBridge(StudioBridge):
    def __init__(self, place: str | None, *, allow=None, windows: int | None = 1, luau=None, shot=(640, 360), **kw):
        super().__init__(allow_place_ids=allow, **kw)
        self.place = place
        self.windows = windows
        self.luau = luau or self.luau_ok
        self.shot = shot
        self.sent: list[tuple[str, dict]] = []
        self.fail_files: set[str] = set()
        self._session = object()                       # "connected": call() will not try to connect
        self._specs = {t["name"]: t for t in FAKE_SPECS}

    async def _send(self, name: str, args: dict) -> dict:
        self.sent.append((name, dict(args)))
        if name == "session_status":
            return {"connected": True, "token": "tok", "place_id": self.place}
        if name == "execution_run_luau":
            return self.luau(args["code"])
        if name == "screenshot_take":
            return {"format": "png", "width": self.shot[0], "height": self.shot[1], "images": [png(*self.shot)]}
        return {"ok": True, "tool": name}

    async def _studio_windows(self) -> int | None:
        return self.windows

    def luau_ok(self, code: str) -> dict:
        """Plays the plugin for a sync chunk: one result per job, failing the files in fail_files."""
        results = []
        for f in JOB_FILE.findall(code):
            if f in self.fail_files:
                results.append({"file": f, "ok": False, "error": "boom"})
            else:
                info = parse_rel(f)
                results.append({"file": f, "ok": True, "action": "created", "path": info.instance_path})
        return {"results": results, "place_id": self.place}

    def names(self) -> list[str]:
        return [n for n, _ in self.sent]

    def codes(self) -> list[str]:
        return [a["code"] for n, a in self.sent if n == "execution_run_luau"]


# ------------------------------------------------------------------ guard

def test_protected_place_refuses_every_mutating_call():
    # Allow-listing the protected place, or passing an empty protected set, must not unprotect it.
    for bridge in (FakeBridge(PROTECTED, allow={PROTECTED, ALLOWED}),
                   FakeBridge(PROTECTED, allow={PROTECTED}),):
        for name in ("instance_create", "script_set_source", "execution_run_luau", "input_click", "no_such_tool"):
            with pytest.raises(StudioRefused, match="protected"):
                run(bridge.call(name, {"x": 1}))
        assert set(bridge.names()) == {"session_status"}      # nothing mutating ever went out
    plain = StudioBridge(protected_place_ids=set())
    assert PROTECTED in plain.protected_place_ids


def test_unknown_tools_count_as_mutating():
    assert is_mutating("no_such_tool") and is_mutating("instance_create") and not is_mutating("instance_get")
    assert not (READ_ONLY & (BLOCKED | CONTROL))
    bridge = FakeBridge(OTHER, allow={ALLOWED})
    with pytest.raises(StudioRefused, match="not in this run's allow-list"):
        run(bridge.call("no_such_tool"))
    assert "no_such_tool" not in bridge.names()


def test_read_only_tools_pass_on_protected_place():
    bridge = FakeBridge(PROTECTED)
    run(bridge.guard("instance_get"))
    run(bridge.call("instance_get", {"path": "Workspace"}))
    run(bridge.call("datamodel_dump", {"root_path": "Workspace", "max_depth": 1}))
    shot = run(bridge.call("screenshot_take"))
    assert shot["images"][0].startswith(capture.PNG_MAGIC)
    assert bridge.names() == ["instance_get", "datamodel_dump", "screenshot_take"]   # no guard round trips


def test_allow_list():
    ok = FakeBridge(ALLOWED, allow={ALLOWED})
    assert run(ok.call("instance_create", {"class_name": "Part", "name": "P", "parent_path": "Workspace"}))["ok"]
    assert ok.names() == ["session_status", "instance_create"]
    for bridge in (FakeBridge(ALLOWED, allow=None), FakeBridge(OTHER, allow={ALLOWED}),
                   FakeBridge(None, allow={ALLOWED}), FakeBridge("unknown", allow={ALLOWED, "unknown"})):
        with pytest.raises(StudioRefused):
            run(bridge.call("instance_create", {}))
        assert "instance_create" not in bridge.names()


def test_guard_rechecks_the_place_on_every_call():
    bridge = FakeBridge(ALLOWED, allow={ALLOWED})
    run(bridge.call("instance_delete", {}))
    bridge.place = PROTECTED                              # Studio switched place under us
    with pytest.raises(StudioRefused):
        run(bridge.call("instance_delete", {}))
    assert bridge.names().count("instance_delete") == 1


def test_blocked_tools_never_run():
    bridge = FakeBridge(ALLOWED, allow={ALLOWED})
    for name in ("studio_kill", "studio_swap_place", "cloud_api_publish_place", "cloud_api_set_datastore_entry"):
        with pytest.raises(StudioRefused, match="blocked"):
            run(bridge.call(name, {}))
    assert bridge.sent == []


def test_protected_id_in_arguments_is_refused():
    bridge = FakeBridge(ALLOWED, allow={ALLOWED})
    with pytest.raises(StudioRefused, match=PROTECTED):
        run(bridge.call("execution_run_luau", {"code": f"print({PROTECTED})"}))
    with pytest.raises(StudioRefused):
        run(bridge.call("instance_create", {"properties": {"Value": int(PROTECTED)}}))
    assert "execution_run_luau" not in bridge.names() and "instance_create" not in bridge.names()


def test_several_studio_windows_allow_only_place_asserted_luau():
    bridge = FakeBridge(ALLOWED, allow={ALLOWED}, windows=2, luau=lambda code: {"value": "1"})
    with pytest.raises(StudioRefused, match="2 Studio windows"):
        run(bridge.call("instance_create", {}))
    run(bridge.call("execution_run_luau", {"code": "return 1"}))
    (code,) = bridge.codes()
    assert code.startswith(f"if game.PlaceId ~= {ALLOWED} then error(\"{WRONG_PLACE}")
    assert code.endswith(" return 1") and "\n" not in code     # same line: caller's line numbers unchanged
    assert "instance_create" not in bridge.names()


def test_place_marker_is_asserted_inside_studio(tmp_path):
    # Unpublished places all have PlaceId 0: the marker is what proves the window is the run's own.
    marker = ("ServerStorage.CybusHarnessRun", "run-42")
    bridge = FakeBridge("0", allow={"0"}, place_marker=marker)
    run(bridge.call("execution_run_luau", {"code": "return 1"}))
    ws = Workspace(tmp_path)
    ws.write("ServerScriptService/Main.server.luau", "print(1)")
    assert run(ws.sync(bridge))["ok"]
    direct, synced = bridge.codes()
    check = '__harness_marker.Value ~= "run-42" then error("WRONG_PLACE'
    assert direct.startswith("if game.PlaceId ~= 0 then") and check in direct and "\n" not in direct
    assert 'ipairs({"ServerStorage", "CybusHarnessRun"})' in direct
    assert synced.count(check) == 2                      # the bridge's prefix + the sync chunk's own line
    for bad in (("ServerStorage.Bad Name", "x"), ("ServerStorage.X", 'a"b'), ("", "x")):
        with pytest.raises(ValueError):
            StudioBridge(place_marker=bad)


def test_wrong_place_is_resent_then_given_up():
    attempts = []

    def flaky(code):
        attempts.append(code)
        if len(attempts) < 3:
            raise StudioError(f"execution_run_luau: Runtime error: {WRONG_PLACE}: meant for PlaceId {ALLOWED}")
        return {"value": "ok"}

    bridge = FakeBridge(ALLOWED, allow={ALLOWED}, luau=flaky)
    assert run(bridge.call("execution_run_luau", {"code": "return 'ok'"})) == {"value": "ok"}
    assert len(attempts) == 3

    def always(code):
        raise StudioError(f"execution_run_luau: Runtime error: {WRONG_PLACE}")

    stuck = FakeBridge(ALLOWED, allow={ALLOWED}, luau=always)
    with pytest.raises(StudioError, match=WRONG_PLACE):
        run(stuck.call("execution_run_luau", {"code": "return 1"}))
    assert stuck.names().count("execution_run_luau") == 4


def test_lost_session_is_resent_only_when_it_cannot_have_run():
    class Lossy(FakeBridge):
        def __init__(self, safe):
            super().__init__(ALLOWED, allow={ALLOWED})
            self.safe, self.lost, self.reconnects = safe, False, 0

        async def _send(self, name, args):
            if name == "instance_create" and not self.lost:
                self.lost = True
                raise _SessionLost("Session terminated", safe=self.safe)
            return await super()._send(name, args)

        async def _reconnect(self):
            self.reconnects += 1

    safe = Lossy(safe=True)                          # HTTP 404: the server never ran it -> resend (re-guarded)
    run(safe.call("instance_create", {}))
    assert safe.reconnects == 1 and safe.names() == ["session_status", "session_status", "instance_create"]
    unsure = Lossy(safe=False)                       # connection dropped mid-call: it may have run -> no resend
    with pytest.raises(StudioError, match="not resent"):
        run(unsure.call("instance_create", {}))
    assert unsure.reconnects == 0


# ------------------------------------------------------------------ result parsing

def _res(payload, is_error=False, extra=()):
    text = payload if isinstance(payload, str) else json.dumps(payload)
    return mt.CallToolResult(content=[mt.TextContent(type="text", text=text), *extra], isError=is_error)


def test_parse_result_formats():
    assert parse_result("t", _res({"success": True, "data": {"a": 1}})) == {"a": 1}
    assert parse_result("t", _res({"success": True, "data": [1, 2]})) == {"items": [1, 2]}
    assert parse_result("t", _res({"success": True, "data": "x"})) == {"value": "x"}
    assert parse_result("t", _res({"studio_connected": True})) == {"studio_connected": True}   # bare object
    assert parse_result("t", _res("plain words")) == {"text": "plain words"}
    with pytest.raises(StudioError, match="nope") as err:
        parse_result("t", _res({"success": False, "error": {"code": "BRIDGE_NO_SESSION", "message": "nope"}}))
    assert err.value.code == "BRIDGE_NO_SESSION"
    with pytest.raises(StudioError, match="bad args"):
        parse_result("t", _res("bad args", is_error=True))
    with pytest.raises(StudioError, match="taskkill failed"):
        parse_result("studio_kill", _res({"ok": False, "error": "taskkill failed"}))

    image = png(4, 3)
    shot = parse_result("screenshot_take", _res({"success": True, "data": {
        "image_base64": base64.b64encode(image).decode(), "width": 4, "height": 3, "format": "png"}}))
    assert shot == {"width": 4, "height": 3, "format": "png", "images": [image]}
    video = parse_result("video_record_stop", _res({"success": True, "data": {
        "video_base64": base64.b64encode(b"mp4!").decode(), "duration_seconds": 1.0, "format": "mp4"}}))
    assert video["video"] == b"mp4!" and "video_base64" not in video
    mixed = parse_result("t", _res({"success": True, "data": {}}, extra=[
        mt.ImageContent(type="image", data=base64.b64encode(image).decode(), mimeType="image/png")]))
    assert mixed["images"] == [image]


# ------------------------------------------------------------------ agent tools from the bridge

def test_bridge_tools_use_bridge_schemas_and_the_guard():
    bridge = FakeBridge(PROTECTED)
    tools = {t.name: t for t in bridge.tools(["instance_get", "instance_create", "screenshot_take"])}
    assert "$schema" not in tools["instance_get"].parameters
    assert tools["instance_get"].parameters["required"] == ["path"]
    assert not tools["instance_get"].mutating and tools["instance_create"].mutating
    assert tools["instance_create"].spec()["function"]["name"] == "instance_create"

    refused = run(tools["instance_create"].invoke({"class_name": "Part", "name": "P", "parent_path": "Workspace"}))
    assert refused.text.startswith("REFUSED") and refused.data["refused"]
    assert "instance_create" not in bridge.names()
    shot = run(tools["screenshot_take"].invoke({}))
    assert shot.images and shot.images[0].startswith(capture.PNG_MAGIC)
    assert "base64" not in shot.text and json.loads(shot.text)["width"] == 640

    default = {t.name for t in bridge.tools()}
    assert not default & (CONTROL | BLOCKED)
    assert {t.name for t in bridge.tools(["instance_*"])} == {"instance_get", "instance_create", "instance_delete"}
    for bad in (["studio_kill"], ["session_connect"], ["no_such_tool"]):
        with pytest.raises(ValueError):
            bridge.tools(bad)


# ------------------------------------------------------------------ workspace

def test_workspace_paths(tmp_path):
    assert parse_rel("ServerScriptService/Combat/Main.server.luau").class_name == "Script"
    assert parse_rel("StarterPlayer/StarterPlayerScripts/Input.client.luau").class_name == "LocalScript"
    mod = parse_rel("src/ReplicatedStorage/Shared/Util.luau")
    assert (mod.rel, mod.class_name, mod.instance_path) == (
        "ReplicatedStorage/Shared/Util.luau", "ModuleScript", "ReplicatedStorage.Shared.Util")
    for bad in ("Scripts/Main.luau", "ServerScriptService/../x.luau", "/abs/x.luau", "C:/x/y.luau",
                "ServerScriptService/readme.md", "Main.luau", "ServerScriptService/.luau"):
        with pytest.raises(ValueError):
            parse_rel(bad)
    ws = Workspace(tmp_path)
    ws.write("ServerScriptService/Main.server.luau", "print('a')\r\nprint('b')\r\n")
    assert ws.read("src/ServerScriptService/Main.server.luau") == "print('a')\nprint('b')\n"
    (tmp_path / "src" / "ServerScriptService" / "notes.md").write_text("not a script")
    assert ws.files() == ["ServerScriptService/Main.server.luau"]


def test_lua_long_string_round_trips_awkward_sources():
    def decode(literal: str) -> str:            # what Luau's lexer does with a long bracket literal
        m = re.match(r"\[(=*)\[\n", literal)
        close = "]" + m.group(1) + "]"
        body = literal[m.end():]
        end = body.find(close)
        assert end + len(close) == len(body), "literal closes early"
        return body[:end]

    for s in ("", "a]", "x]=", "]]", "]=]", "]==]]", "\nleading newline", "--[[ c ]] local t = a[b[1]]",
              "trailing ]"):
        assert decode(lua_long_string(s)) == s


def seed(ws: Workspace) -> None:
    ws.write("ServerScriptService/Combat/Main.server.luau", "print('server')\n")
    ws.write("StarterPlayer/StarterPlayerScripts/Input.client.luau", "print('client')\n")
    ws.write("ReplicatedStorage/Shared/Util.luau", "return {answer = 42}\n")


def test_workspace_sync_pushes_only_what_changed(tmp_path):
    ws = Workspace(tmp_path)
    seed(ws)
    assert ws.changed() == ["ReplicatedStorage/Shared/Util.luau", "ServerScriptService/Combat/Main.server.luau",
                            "StarterPlayer/StarterPlayerScripts/Input.client.luau"]
    bridge = FakeBridge(ALLOWED, allow={ALLOWED})
    report = run(ws.sync(bridge))
    assert report["ok"] and report["place_id"] == ALLOWED and len(report["pushed"]) == 3
    assert {p["file"]: p["class"] for p in report["pushed"]} == {
        "ServerScriptService/Combat/Main.server.luau": "Script",
        "StarterPlayer/StarterPlayerScripts/Input.client.luau": "LocalScript",
        "ReplicatedStorage/Shared/Util.luau": "ModuleScript"}
    # One place-asserted Luau batch; no per-file script_create / instance_create / script_set_source calls.
    assert set(bridge.names()) == {"session_status", "execution_run_luau"}
    (code,) = bridge.codes()
    assert code.startswith(f"if game.PlaceId ~= {ALLOWED} then")
    assert code.count(f"if game.PlaceId ~= {ALLOWED} then") == 2           # the sync's own + the bridge's
    for piece in ('service = "ServerScriptService", folders = {"Combat"}, name = "Main", class = "Script"',
                  'service = "StarterPlayer", folders = {"StarterPlayerScripts"}, name = "Input", class = "LocalScript"',
                  'service = "ReplicatedStorage", folders = {"Shared"}, name = "Util", class = "ModuleScript"',
                  "print('server')", "return {answer = 42}", "TryBeginRecording"):
        assert piece in code
    assert ws.changed() == []
    state = json.loads((tmp_path / ".sync.json").read_text())
    assert state["place_id"] == ALLOWED and len(state["files"]) == 3

    run(ws.sync(bridge))                                                    # nothing changed: nothing sent
    assert len(bridge.codes()) == 1
    ws.write("ReplicatedStorage/Shared/Util.luau", "return {answer = 43}\n")
    assert ws.changed() == ["ReplicatedStorage/Shared/Util.luau"]
    report = run(ws.sync(bridge))
    assert [p["file"] for p in report["pushed"]] == ["ReplicatedStorage/Shared/Util.luau"]
    assert JOB_FILE.findall(bridge.codes()[-1]) == ["ReplicatedStorage/Shared/Util.luau"]
    assert "answer = 43" in bridge.codes()[-1] and ws.changed() == []


def test_workspace_sync_is_refused_on_protected_or_unlisted_places(tmp_path):
    ws = Workspace(tmp_path)
    seed(ws)
    for bridge in (FakeBridge(PROTECTED, allow={PROTECTED}), FakeBridge(OTHER, allow={ALLOWED})):
        with pytest.raises(StudioRefused):
            run(ws.sync(bridge))
        assert "execution_run_luau" not in bridge.names()
    assert len(ws.changed()) == 3 and not (tmp_path / ".sync.json").exists()


def test_workspace_sync_failures_new_place_and_deletions(tmp_path):
    ws = Workspace(tmp_path)
    seed(ws)
    bridge = FakeBridge(ALLOWED, allow={ALLOWED})
    bridge.fail_files = {"ReplicatedStorage/Shared/Util.luau"}
    report = run(ws.sync(bridge))
    assert not report["ok"] and report["failed"] == [{"file": "ReplicatedStorage/Shared/Util.luau", "error": "boom"}]
    assert ws.changed() == ["ReplicatedStorage/Shared/Util.luau"]            # retried next time

    other = FakeBridge("777", allow={"777"})                                 # a different place: push everything
    assert len(run(ws.sync(other))["pushed"]) == 3

    (tmp_path / "src" / "StarterPlayer" / "StarterPlayerScripts" / "Input.client.luau").unlink()
    ws.write("ReplicatedStorage/Shared/Util.server.luau", "print('clash')\n")   # same instance as Util.luau
    report = run(ws.sync(other))
    assert report["deleted_locally"] == ["StarterPlayer/StarterPlayerScripts/Input.client.luau"]
    assert [f["file"] for f in report["failed"]] == ["ReplicatedStorage/Shared/Util.server.luau"]


def test_workspace_sync_holds_back_excluded_files(tmp_path):
    ws = Workspace(tmp_path)
    seed(ws)
    bridge = FakeBridge(ALLOWED, allow={ALLOWED})
    report = run(ws.sync(bridge, exclude={"src/ReplicatedStorage/Shared/Util.luau", "not a path"}))
    assert report["excluded"] == ["ReplicatedStorage/Shared/Util.luau"] and len(report["pushed"]) == 2
    assert "Util" not in bridge.codes()[-1] and ws.changed() == ["ReplicatedStorage/Shared/Util.luau"]
    assert [p["file"] for p in run(ws.sync(bridge))["pushed"]] == ["ReplicatedStorage/Shared/Util.luau"]


def test_workspace_agent_tools(tmp_path):
    ws = Workspace(tmp_path)
    bridge = FakeBridge(ALLOWED, allow={ALLOWED})
    tools = {t.name: t for t in ws.tools(bridge)}
    assert set(tools) == {"write_file", "read_file", "list_files", "sync_to_studio"}
    assert tools["write_file"].mutating and tools["sync_to_studio"].mutating and not tools["read_file"].mutating
    wrote = run(tools["write_file"].invoke({"path": "ServerScriptService/Main.server.luau", "content": "print(1)"}))
    assert "ServerScriptService.Main" in wrote.text
    assert run(tools["read_file"].invoke({"path": "ServerScriptService/Main.server.luau"})).text == "print(1)"
    assert "(not synced)" in run(tools["list_files"].invoke({})).text
    assert run(tools["write_file"].invoke({"path": "../evil.luau", "content": "x"})).text.startswith("ERROR")
    synced = run(tools["sync_to_studio"].invoke({}))
    assert "created 1" in synced.text and synced.data["ok"]
    assert "(not synced)" not in run(tools["list_files"].invoke({})).text
    refused = run(Workspace(tmp_path).tools(FakeBridge(PROTECTED, allow={PROTECTED}))[3].invoke({"force": True}))
    assert refused.text.startswith("REFUSED")


# ------------------------------------------------------------------ capture

def test_contact_sheet_size():
    colors = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0), (0, 255, 255), (255, 0, 255)]
    shots = [png(320, 180, c) for c in colors]
    plain = Image.open(io.BytesIO(capture.contact_sheet(shots, cols=4, width=1280)))
    cell_w = (1280 - capture.PAD * 5) // 4
    cell_h = round(180 * cell_w / 320)
    assert plain.size == (1280, capture.PAD + 2 * (cell_h + capture.PAD))
    assert plain.getpixel((capture.PAD + cell_w // 2, capture.PAD + cell_h // 2)) == colors[0]
    labeled = Image.open(io.BytesIO(capture.contact_sheet(shots, cols=4, width=1280, labels=list("abcdef"))))
    assert labeled.width == 1280 and labeled.height > plain.height
    few = Image.open(io.BytesIO(capture.contact_sheet(shots[:2], cols=4, width=1000)))
    assert few.size == (1000, capture.PAD + round(180 * ((1000 - capture.PAD * 3) // 2) / 320) + capture.PAD)
    with pytest.raises(ValueError):
        capture.contact_sheet([])


def test_screenshot_and_frames():
    bridge = FakeBridge(PROTECTED)                 # capture only reads, so the protected place is fine
    assert run(capture.screenshot(bridge)).startswith(capture.PNG_MAGIC)
    start = time.monotonic()
    shots = run(capture.frames(bridge, 0.3, 3))
    assert len(shots) == 3 and time.monotonic() - start >= 0.29
    assert set(bridge.names()) == {"screenshot_take"}
    minimized = FakeBridge(PROTECTED, shot=(237, 39))
    with pytest.raises(StudioError, match="minimized"):
        run(capture.screenshot(minimized))
    assert run(capture.screenshot(minimized, min_size=None)).startswith(capture.PNG_MAGIC)


def test_build_sync_luau_requires_a_numeric_place():
    info = parse_rel("ServerScriptService/Main.server.luau")
    assert build_sync_luau("0", [(info, "print(1)")]).startswith("if game.PlaceId ~= 0 then")
    with pytest.raises(StudioRefused):
        build_sync_luau("unknown", [(info, "print(1)")])


# ------------------------------------------------------------------ live (read-only)

@pytest.mark.skipif(os.environ.get("HARNESS_LIVE_STUDIO") != "1", reason="set HARNESS_LIVE_STUDIO=1 to run")
def test_live_studio_smoke():
    """Against the real bridge: connect, list tools, read the PlaceId, and prove a mutating call is refused
    locally. Only read-only tools (plus session_connect, which only links on the server) may go out."""
    async def main():
        bridge = StudioBridge()                       # no allow-list: nothing may mutate
        sent: list[str] = []
        real_send = bridge._send

        async def spy(name, args):
            assert name in READ_ONLY or name == "session_connect", f"{name} would have reached the server"
            sent.append(name)
            return await real_send(name, args)

        bridge._send = spy
        await bridge.connect()
        try:
            tools = await bridge.list_tools()
            assert len(tools) > 100
            place = await bridge.active_place_id()
            print(f"live bridge: {len(tools)} tools, active PlaceId {place}")
            before = len(sent)
            with pytest.raises(StudioRefused):
                await bridge.call("instance_create", {"class_name": "Part", "name": "HarnessProbe",
                                                      "parent_path": "Workspace"})
            assert "instance_create" not in sent and set(sent[before:]) <= {"session_status"}
        finally:
            await bridge.close()
        assert set(sent) <= READ_ONLY | {"session_connect"}

    run(main())

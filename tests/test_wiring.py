"""The static wiring check (requires that cannot reach a module), the build gate that sends them back, and the
finishing pass for files a builder left as placeholders."""
from __future__ import annotations

import asyncio
import json
import re
from pathlib import Path

from harness.kit import kit_files
from harness.llm import LLMResponse, Message, ToolCall
from harness.wiring import fmt_path, strip_comments, wiring_problems
from harness.workflows.build_game import STUB_MARK, Build, BuildConfig
from tests.test_build_game import FakeLLM

TREE = ["ServerScriptService/Game.server.luau", "ServerScriptService/ServerStorage/Config.luau",
        "ServerScriptService/ServerStorage/State.luau", "ReplicatedStorage/Shared/Tokens.luau",
        "ReplicatedStorage/Kit/Maid.luau", "StarterPlayer/StarterPlayerScripts/Game.client.luau",
        "StarterPlayer/StarterPlayerScripts/ClientStorage/Hud.luau", "ServerStorage/Secrets.luau"]


def problems(path: str, src: str) -> list[str]:
    return wiring_problems(TREE, {path: src}).get(path, [])


def test_wrong_folder_is_reported_with_the_real_module():
    src = ('local ServerStorage = script.Parent\n'
           'local Config = require(ServerStorage:WaitForChild("Config", 10))\n'
           'local State = require(script.Parent.ServerStorage.State)\n')
    probs = problems("ServerScriptService/Game.server.luau", src)
    assert len(probs) == 1 and probs[0].startswith("line 2:")
    assert "ServerScriptService.Config, which does not exist" in probs[0]
    assert "ServerScriptService.ServerStorage.Config (ServerScriptService/ServerStorage/Config.luau)" in probs[0]


def test_dotted_names_folders_and_server_modules_from_the_client():
    src = ('local ReplicatedStorage = game:GetService("ReplicatedStorage")\n'
           'local function safeRequire(path: string)\n'
           '\tlocal ok, m = pcall(function()\n\t\treturn require(ReplicatedStorage:WaitForChild(path, 5))\n\tend)\n'
           '\treturn ok and m or nil\nend\n'
           'local Tokens = safeRequire("Shared.Tokens")\n'
           'local Kit = require(ReplicatedStorage:WaitForChild("Kit"))\n'
           'local S = require(game:GetService("ServerStorage").Secrets)\n'
           'local Hud = require(script.Parent:WaitForChild("ClientStorage"):WaitForChild("Hud"))\n')
    probs = problems("StarterPlayer/StarterPlayerScripts/Game.client.luau", src)
    assert len(probs) == 3, probs
    assert 'line 8: safeRequire("Shared.Tokens")' in probs[0] and 'ReplicatedStorage["Shared.Tokens"]' in probs[0]
    assert ':WaitForChild("Shared"):WaitForChild("Tokens")' in probs[0]
    assert "which is a Folder" in probs[1] and "ReplicatedStorage.Kit.Maid" in probs[1]
    assert "clients cannot see ServerStorage" in probs[2]


def test_lazy_require_helpers_are_checked_at_their_call_sites():
    src = ('local ClientStorage = script.Parent:WaitForChild("ClientStorage", 10)\n'
           'local function tryRequire(name: string)\n'
           '\tlocal ok, mod = pcall(function()\n\t\treturn require(ClientStorage:WaitForChild(name, 5))\n\tend)\n'
           '\treturn ok and mod or nil\nend\n'
           'local Hud = tryRequire("Hud")\n'
           'local Camera = tryRequire("Camera")\n')
    probs = problems("StarterPlayer/StarterPlayerScripts/Game.client.luau", src)
    assert len(probs) == 1 and 'tryRequire("Camera")' in probs[0]
    assert "StarterPlayer.StarterPlayerScripts.ClientStorage.Camera" in probs[0]


def test_what_it_cannot_see_is_never_reported():
    src = ('local Players = game:GetService("Players")\n'
           'local ReplicatedStorage = game:GetService("ReplicatedStorage")\n'
           '-- require(script.Parent.Missing) in a comment\n'
           '--[[ require(script.Parent.AlsoMissing) ]]\n'
           'local s = "require(script.Parent.InAString) -- not code"\n'
           'local PlayerModule = require(Players.LocalPlayer.PlayerScripts:WaitForChild("PlayerModule"))\n'
           'local Hud = require(Players.LocalPlayer:WaitForChild("PlayerScripts").ClientStorage.Hud)\n'
           'local ok, Shared = pcall(function() return ReplicatedStorage:WaitForChild("Shared") end)\n'
           'local Tokens = require(Shared.Tokens)\n'
           'local Maid = require(ReplicatedStorage.Kit["Maid"])\n'
           'local thing = require(workspace.Map.Module)\n'
           'local x = require(script.Parent[name])\n'
           'local m = require(someTable.module)\n'
           'local Char = require(script.Parent.Parent.Humanoid)\n'
           'local n = 5\nlocal Hud2 = require(script.Parent.ClientStorage.Hud)\n')
    assert problems("StarterPlayer/StarterPlayerScripts/Game.client.luau", src) == []
    # A pcall alias to a folder that does not exist is followed like any other alias.
    bad = 'local ok, S = pcall(function() return game:GetService("ReplicatedStorage"):WaitForChild("Nope") end)\n' \
          'local T = require(S.Tokens)\n'
    assert len(problems("StarterPlayer/StarterPlayerScripts/Game.client.luau", bad)) == 1


def test_comment_stripping_keeps_offsets_and_the_kit_is_clean():
    src = 'local a = "--x" -- c\n--[==[ long\n]==] local b = [[ -- s ]]\n'
    out = strip_comments(src)
    assert len(out) == len(src) and out.count("\n") == src.count("\n")
    assert '"--x"' in out and "[[ -- s ]]" in out and "-- c" not in out and "long" not in out
    kit = kit_files()
    tree = list(kit) + ["ReplicatedStorage/Shared/Tokens.luau", "ReplicatedStorage/Shared/AssetMap.luau"]
    assert wiring_problems(tree, kit) == {}
    assert fmt_path(("ReplicatedStorage", "Shared.Tokens")) == 'ReplicatedStorage["Shared.Tokens"]'


class MiswiredLLM(FakeLLM):
    """Builds the core loop with a require from the wrong folder, then fixes it when the gate reports it."""

    def __init__(self):
        super().__init__()
        self.gate_briefs: list[str] = []

    async def chat(self, messages, tools=None):
        names = [t["function"]["name"] for t in tools or []]
        task = messages[1].content if isinstance(messages[1].content, str) else messages[1].content[0]["text"]
        wrote = any(m.role == "tool" for m in messages)
        if "write_file" in names and not wrote and "ServerScriptService/Game.server.luau" in (
                re.search(r"FILES YOU OWN\n((?:- .+\n)+)", task + "\n") or re.match("", "")).group(0):
            body = 'local Config = require(script.Parent:WaitForChild("Config"))\nprint(Config)\n'
            calls = [ToolCall("w0", "write_file", {"path": "ServerScriptService/Game.server.luau", "content": body}),
                     ToolCall("w1", "write_file", {"path": "ReplicatedStorage/Shared/Config.luau",
                                                   "content": "local M = {}\nreturn M\n"})]
            return LLMResponse(Message("assistant", "", tool_calls=calls), {}, "tool_calls", {})
        if "write_file" in names and not wrote and task.startswith("These lines in your files fail when they run"):
            self.gate_briefs.append(task)
            body = ('local RS = game:GetService("ReplicatedStorage")\n'
                    'local Config = require(RS:WaitForChild("Shared"):WaitForChild("Config"))\nprint(Config)\n')
            calls = [ToolCall("f0", "write_file", {"path": "ServerScriptService/Game.server.luau", "content": body})]
            return LLMResponse(Message("assistant", "", tool_calls=calls), {}, "tool_calls", {})
        return await super().chat(messages, tools)


def test_build_gate_sends_wiring_problems_back_and_moves_orphan_stubs(tmp_path: Path):
    from harness.tools.workspace import Workspace
    from harness.workflow import Workflow
    ws = Workspace(tmp_path / "workspace")
    ws.write("ServerScriptService/Old/Leftover.server.luau", f"-- old\n-- {STUB_MARK}\n")   # an earlier architecture's stub
    ws.write("ServerScriptService/Keep.server.luau", "print('real code nobody declared')\n")
    fake = MiswiredLLM()
    roles = {r: fake for r in ("lead", "art", "builder", "critic", "judge")}
    report = asyncio.run(Build(Workflow("wiring", tmp_path, roles, resume=False), ws, None, fake, BuildConfig(),
                               tmp_path).run({"id": "harbour", "pitch": "x"}))
    assert len(fake.gate_briefs) == 1
    assert "ServerScriptService.Config, which does not exist" in fake.gate_briefs[0]
    assert "ReplicatedStorage.Shared.Config  <- ReplicatedStorage/Shared/Config.luau" in fake.gate_briefs[0]
    assert 'WaitForChild("Shared")' in ws.read("ServerScriptService/Game.server.luau")
    assert report["runtime_problems"] == {} and report["stubs_left"] == []
    assert (tmp_path / "orphans" / "ServerScriptService" / "Old" / "Leftover.server.luau").exists()
    assert "ServerScriptService/Old/Leftover.server.luau" not in ws.files()
    assert "ServerScriptService/Keep.server.luau" in ws.files()          # real code is never moved
    labels = [json.loads(line).get("label") for line in
              (tmp_path / "journal.jsonl").read_text(encoding="utf-8").splitlines() if line.strip()]
    assert "build:core-runtime0" in labels


class HalfDoneLLM(FakeLLM):
    """The core-loop builder writes its script and leaves its config module a placeholder until told."""

    def __init__(self):
        super().__init__()
        self.finish_briefs: list[str] = []

    async def chat(self, messages, tools=None):
        names = [t["function"]["name"] for t in tools or []]
        task = messages[1].content if isinstance(messages[1].content, str) else messages[1].content[0]["text"]
        wrote = any(m.role == "tool" for m in messages)
        if "write_file" in names and not wrote and "- ServerScriptService/Game.server.luau" in task:
            if "still the harness placeholder" in task:
                self.finish_briefs.append(task)
                calls = [ToolCall("f", "write_file", {"path": "ReplicatedStorage/Shared/Config.luau",
                                                      "content": "local M = {rounds = 3}\nreturn M\n"})]
            else:
                calls = [ToolCall("w", "write_file", {"path": "ServerScriptService/Game.server.luau",
                                                      "content": "print('rounds')\n"})]
            return LLMResponse(Message("assistant", "", tool_calls=calls), {}, "tool_calls", {})
        return await super().chat(messages, tools)


def test_placeholders_left_by_a_builder_get_a_finishing_pass(tmp_path: Path):
    from harness.tools.workspace import Workspace
    from harness.workflow import Workflow
    ws = Workspace(tmp_path / "workspace")
    fake = HalfDoneLLM()
    roles = {r: fake for r in ("lead", "art", "builder", "critic", "judge")}
    report = asyncio.run(Build(Workflow("finish", tmp_path, roles, resume=False), ws, None, fake, BuildConfig(),
                               tmp_path).run({"id": "harbour", "pitch": "x"}))
    assert len(fake.finish_briefs) == 1
    assert "ReplicatedStorage/Shared/Config.luau" in fake.finish_briefs[0].rsplit("still the harness placeholder", 1)[1]
    assert "rounds = 3" in ws.read("ReplicatedStorage/Shared/Config.luau")
    assert ws.read("ServerScriptService/Game.server.luau") == "print('rounds')\n"
    assert report["stubs_left"] == []
    labels = [json.loads(line).get("label") for line in
              (tmp_path / "journal.jsonl").read_text(encoding="utf-8").splitlines() if line.strip()]
    assert "build:core-finish" in labels and "build:core-retry" not in labels

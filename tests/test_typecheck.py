"""The Roblox API misuse check: definitions parsing, which luau-lsp diagnostics count as runtime errors, the
generated sourcemap, and (when luau-lsp is installed) a real run."""
from __future__ import annotations

import asyncio
from pathlib import Path

import pytest

from harness.tools import typecheck as tc

DEFS = """
declare extern type Instance with
	Name: string
	Parent: Instance?
	function IsA(self, className: string): boolean
end

declare extern type Beam extends Instance with
	Attachment0: Attachment?
	Attachment1: Attachment?
	Enabled: boolean
end

declare extern type GuiObject extends Instance with
	Visible: boolean
end

declare extern type ImageLabel extends GuiObject with
	ImageColor3: Color3
end

declare extern type Part extends Instance with
	Anchored: boolean
end

declare extern type SpawnLocation extends Part with
	Enabled: boolean
end

declare extern type EnumFontWeight extends EnumItem with end
declare extern type EnumFontWeight_INTERNAL extends Enum with
	Bold: EnumFontWeight
	Regular: EnumFontWeight
	function FromName(self, Name: string): EnumItem?
end

type ENUM_LIST = {
	FontWeight: EnumFontWeight_INTERNAL,
	UserInputType: EnumUserInputType_INTERNAL,
}
"""


def test_definitions_parse_members_inheritance_and_enum_items():
    d = tc.Defs(DEFS)
    assert {"Attachment0", "Attachment1", "Enabled", "Name", "IsA"} <= d.members("Beam")
    assert d.enum_items["FontWeight"] == {"Bold", "Regular"}          # FromName is a method, not an item
    assert d.enums == {"FontWeight", "UserInputType"}


def test_only_certain_runtime_errors_are_kept():
    d = tc.Defs(DEFS)
    names = {"Glow"}                     # a child the game names in its own code
    c = lambda msg, line="": tc.classify(msg, line, d, names)   # noqa: E731
    assert "Enum.FontWeight.Normal does not exist" in c("Key 'Normal' not found in external type 'Enum.FontWeight'")
    assert "Bold, Regular." in c("Key 'Normal' not found in external type 'Enum.FontWeight'")
    assert "Beam has no property or method 'A'" in c("Key 'A' not found in external type 'Beam'")
    assert c("Key 'Glow' not found in external type 'Beam'") is None                   # a child the game creates
    assert c("Key 'HumanoidRootPart' not found in external type 'Beam'") is None       # a child Roblox creates
    assert c("Key 'Visible' not found in external type 'Instance'") is None            # only typed as Instance
    enum_list = "Type 't1 where t1 = { AccessModifierType: Enum.AccessModifierType, ... }' does not have key 'UserInputAction'"
    assert "Enum.UserInputAction does not exist" in c(enum_list)
    assert "no class 'Fog'" in c("Invalid class name 'Fog'")
    assert "this line errors" in c("Key 'bobberPosition' not found in table 'M'", "local p = World.bobberPosition()")
    assert "silently do nothing" in c("Key 'bobberPosition' not found in table 'M'",
                                      "return World.bobberPosition and World.bobberPosition()")
    assert c("Key 'speed' not found in table 'Config'", "local s = Config.speed") is None   # a read, not a call
    assert c("Key 'Sample' not found in table '{ track: T }'", "local s = self.track:Sample(1)") is None   # a method
    assert c("Key 'ImageColor3' not found in external type 'GuiObject'") is None   # may really be an ImageLabel
    assert "Part has no property or method 'Enabled'" in c("Key 'Enabled' not found in external type 'Part'")
    assert "task.delay needs 2" in c("Argument count mismatch. Function 'task.delay' expects 2 arguments, but only 1 "
                                     "is specified")
    assert c("Argument count mismatch. Function 'stroke' expects 4 arguments, but only 3 are specified") is None
    assert c("Value of type 'Frame?' could be nil") is None
    assert c("Expected this to be 'string', but got 'number'") is None


def test_sourcemap_mirrors_the_workspace():
    sm = tc.sourcemap(["ReplicatedStorage/Kit/Maid.luau", "StarterPlayer/StarterPlayerScripts/Hud.client.luau",
                       "ServerScriptService/Game.server.luau"])
    kids = {c["name"]: c for c in sm["children"]}
    assert sm["className"] == "DataModel" and set(kids) == {"ReplicatedStorage", "StarterPlayer", "ServerScriptService"}
    maid = kids["ReplicatedStorage"]["children"][0]["children"][0]
    assert maid == {"name": "Maid", "className": "ModuleScript", "filePaths": ["src/ReplicatedStorage/Kit/Maid.luau"]}
    sps = kids["StarterPlayer"]["children"][0]
    assert sps["className"] == "StarterPlayerScripts" and sps["children"][0]["className"] == "LocalScript"
    both = tc.sourcemap(["StarterPlayer/StarterPlayerScripts/Hud.client.luau",
                         "StarterPlayer/StarterPlayerScripts/Hud/Widgets.client.luau"])
    hud = both["children"][0]["children"][0]["children"]          # a script and a folder of the same name
    assert sorted(h["className"] for h in hud) == ["Folder", "LocalScript"]


@pytest.mark.skipif(not (tc.lsp_exe() and tc.defs_path()), reason="luau-lsp or Roblox definitions not installed")
def test_real_luau_lsp_run(tmp_path: Path, monkeypatch):
    monkeypatch.setenv("HARNESS_TYPECHECK", "1")
    src = tmp_path / "src"
    (src / "ReplicatedStorage" / "Shared").mkdir(parents=True)
    (src / "StarterPlayer" / "StarterPlayerScripts").mkdir(parents=True)
    (src / "ReplicatedStorage" / "Shared" / "Util.luau").write_text(
        "local M = {}\nfunction M.clamp01(x: number): number\n\treturn math.clamp(x, 0, 1)\nend\nreturn M\n",
        encoding="utf-8")
    (src / "StarterPlayer" / "StarterPlayerScripts" / "Hud.client.luau").write_text(
        'local Util = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Util"))\n'
        'local label = Instance.new("TextLabel")\n'
        'label.Font = Enum.Font.GothamBold\n'
        'label.FontFace = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Normal)\n'
        'local fog = Instance.new("Fog")\n'
        'print(Util.clamp01(2), Util.lerp(1, 2, 0.5))\n', encoding="utf-8")
    probs = asyncio.run(tc.api_problems(tmp_path, ["StarterPlayer/StarterPlayerScripts/Hud.client.luau"]))
    found = probs["StarterPlayer/StarterPlayerScripts/Hud.client.luau"]
    text = "\n".join(found)
    assert "line 4: Enum.FontWeight.Normal does not exist" in text
    assert "line 5: Instance.new(\"Fog\")" in text
    assert "line 6: calls 'lerp'" in text
    assert len(found) == 3, found

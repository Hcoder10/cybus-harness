"""Roblox API misuse a type checker can prove, with no Studio: properties a class does not have, enum items and
enums that do not exist, classes Instance.new cannot make, calls to functions a module or library does not define,
and library calls missing a required argument. Each one errors the first time its line runs.

Live, the first finished game (after its wiring was fixed) still had about sixteen: `beam.A` for Attachment0,
`Enum.FontWeight.Normal`, `Enum.ApplyStrokeMode.Fill`, `Enum.UserInputAction`, `Instance.new("Fog")`,
`CFrame.Lerp(a, b, t)`, `task.delay(fn)`, and a camera calling `World.bobberPosition()`, which World never defined.

It runs `luau-lsp analyze` with Roblox's definitions for game scripts (globalTypes.None.d.luau) and a sourcemap
made from the workspace, so requires resolve without rojo. In strict files luau-lsp reports far more than this
(nil-ability, inference), and none of that is a certain runtime error, so only the classes above are kept. A
property lookup is also dropped when the key could be a child: a name the game's code uses as a string, or a child
Roblox itself makes (HumanoidRootPart, leaderstats, ...).

Set HARNESS_LUAU_LSP / HARNESS_ROBLOX_DEFS, or keep luau-lsp and luau-lsp-defs/globalTypes.None.d.luau in ~/bin.
Without them every check returns nothing.
"""
from __future__ import annotations

import asyncio
import difflib
import json
import os
import re
import shutil
import tempfile
from functools import lru_cache
from pathlib import Path

from harness.tools.workspace import SERVICES, parse_rel

_OPEN_SERVICES = {"Workspace", "Players", "Lighting", "SoundService", "Teams", "Chat", "TextChatService",
                  "MaterialService", "LocalizationService"}
# Children Roblox itself creates, reached with dot syntax in ordinary game code.
ROBLOX_CHILDREN = {
    "HumanoidRootPart", "Humanoid", "Head", "Torso", "UpperTorso", "LowerTorso", "LeftUpperArm", "LeftLowerArm",
    "LeftHand", "RightUpperArm", "RightLowerArm", "RightHand", "LeftUpperLeg", "LeftLowerLeg", "LeftFoot",
    "RightUpperLeg", "RightLowerLeg", "RightFoot", "Left Arm", "Right Arm", "Left Leg", "Right Leg", "Animate",
    "Animator", "Health", "BodyColors", "Shirt", "Pants", "face", "Neck", "Waist", "Root", "RootJoint", "RootPart",
    "Right Shoulder", "Left Shoulder", "Right Hip", "Left Hip", "PlayerGui", "Backpack", "PlayerScripts",
    "PlayerModule", "StarterGear", "leaderstats", "Camera", "Terrain", "Baseplate", "SpawnLocation", "Sky",
    "Atmosphere", "Bloom", "ColorCorrection", "SunRays", "DepthOfField", "Clouds", "HumanoidDescription",
    "CameraModule", "ControlModule", "TouchGui", "Freecam", "BubbleChat", "ChatScript", "RbxCharacterSounds",
}
_LIBS = {"task", "math", "string", "table", "coroutine", "utf8", "bit32", "buffer", "os", "debug", "Instance",
         "Color3", "Vector3", "Vector2", "CFrame", "UDim", "UDim2", "TweenInfo", "NumberSequence", "ColorSequence",
         "NumberSequenceKeypoint", "ColorSequenceKeypoint", "NumberRange", "Rect", "Ray", "Random", "DateTime",
         "Font", "BrickColor", "PhysicalProperties", "RaycastParams", "OverlapParams", "Region3", "Enum", "game",
         "workspace", "Content", "Path2DControlPoint"}
_LINE = re.compile(r"^(?P<file>.+?\.luau?)(?: \[[^\]]*\])?:(?P<line>\d+):[\d-]+: \((?P<code>\w+)\) (?P<kind>\w+): "
                   r"(?P<msg>.*)$")
_STRING = re.compile(r'"([^"\\\n]{1,80})"|\'([^\'\\\n]{1,80})\'')


def lsp_exe() -> str | None:
    for c in (os.environ.get("HARNESS_LUAU_LSP", ""), shutil.which("luau-lsp") or "",
              str(Path.home() / "bin" / "luau-lsp.exe"), str(Path.home() / "bin" / "luau-lsp")):
        if c and Path(c).is_file():
            return c
    return None


def defs_path() -> str | None:
    for c in (os.environ.get("HARNESS_ROBLOX_DEFS", ""),
              str(Path.home() / "bin" / "luau-lsp-defs" / "globalTypes.None.d.luau")):
        if c and Path(c).is_file():
            return c
    return None


def available() -> bool:
    return os.environ.get("HARNESS_TYPECHECK", "1") != "0" and bool(lsp_exe() and defs_path())


class Defs:
    """Members of every class and items of every enum, from a luau-lsp definitions file."""

    def __init__(self, text: str) -> None:
        self.classes: dict[str, tuple[str | None, set[str]]] = {}
        self.enum_items: dict[str, set[str]] = {}
        self.enums: set[str] = set()
        self.prop_types: dict[str, set[str]] = {}          # property name -> the types classes declare it with
        cur, base, members, fields = None, None, set(), set()
        for line in text.splitlines():
            m = re.match(r"^declare extern type (\w+)(?: extends (\w+))? with\s*(end)?\s*$", line)
            if m:
                cur, base, members, fields = m.group(1), m.group(2), set(), set()
                if m.group(3):
                    self._close(cur, base, members, fields)
                    cur = None
                continue
            if cur is None:
                em = re.match(r"^\t(\w+): Enum(\w+)_INTERNAL,?$", line)
                if em:
                    self.enums.add(em.group(1))
                continue
            if line.strip() == "end":
                self._close(cur, base, members, fields)
                cur = None
                continue
            mm = re.match(r"^\t(function )?(\w+)(.*)$", line)
            if mm:
                members.add(mm.group(2))
                if not mm.group(1):
                    fields.add(mm.group(2))
                    tail = mm.group(3).strip()
                    if tail.startswith(":") and not cur.startswith("Enum"):
                        self.prop_types.setdefault(mm.group(2), set()).add(tail[1:].strip())

    def _close(self, name: str, base: str | None, members: set[str], fields: set[str]) -> None:
        if name.startswith("Enum") and name.endswith("_INTERNAL"):
            self.enum_items[name[4:-len("_INTERNAL")]] = fields          # items, not FromName / GetEnumItems
        else:
            self.classes[name] = (base, members)

    def members(self, cls: str) -> set[str]:
        out: set[str] = set()
        seen = set()
        while cls and cls in self.classes and cls not in seen:
            seen.add(cls)
            base, mem = self.classes[cls]
            out |= mem
            cls = base
        return out

    def subclass_members(self, cls: str) -> set[str]:
        """Members only some subclass has: a value typed GuiObject may really be an ImageLabel."""
        kids: dict[str, list[str]] = {}
        for name, (base, _) in self.classes.items():
            if base:
                kids.setdefault(base, []).append(name)
        out: set[str] = set()
        todo = list(kids.get(cls, []))
        while todo:
            c = todo.pop()
            out |= self.classes[c][1]
            todo += kids.get(c, [])
        return out


@lru_cache(maxsize=4)
def load_defs(path: str) -> Defs:
    return Defs(Path(path).read_text(encoding="utf-8", errors="replace"))


def sourcemap(files: list[str], name: str = "Game") -> dict:
    """A rojo-style sourcemap for the workspace's files (paths relative to the workspace root)."""
    root = {"name": name, "className": "DataModel", "children": []}
    folders: dict[tuple, dict] = {(): root}    # scripts never hold children: Hud.client.luau and Hud/ are siblings
    for rel in sorted(files):
        try:
            info = parse_rel(rel)
        except ValueError:
            continue
        node = (info.service, *info.folders, info.name)
        for i in range(1, len(node)):
            key = node[:i]
            if key not in folders:
                cls = key[-1] if i == 1 and (key[-1] in SERVICES or key[-1] in _OPEN_SERVICES) else "Folder"
                if key == ("StarterPlayer", "StarterPlayerScripts"):
                    cls = "StarterPlayerScripts"
                elif key == ("StarterPlayer", "StarterCharacterScripts"):
                    cls = "StarterCharacterScripts"
                folders[key] = {"name": key[-1], "className": cls, "children": []}
                folders[key[:-1]]["children"].append(folders[key])
        folders[node[:-1]]["children"].append(
            {"name": info.name, "className": info.class_name, "filePaths": [f"src/{info.rel}"]})
    return root


def child_names(sources: dict[str, str]) -> set[str]:
    """Every short string literal in the game: any of them may name a child the game creates."""
    out: set[str] = set()
    for src in sources.values():
        for m in _STRING.finditer(src):
            out.add(m.group(1) if m.group(1) is not None else m.group(2))
    return out


def _close_matches(word: str, pool: set[str], n: int = 4) -> list[str]:
    return difflib.get_close_matches(word, sorted(pool), n=n, cutoff=0.5)


_CONCRETE = re.compile(r"[A-Z]\w*|number|string|boolean")
_STRINGISH = {"string", "ContentId", "Content"}


def classify(msg: str, src_line: str, defs: Defs, names: set[str], kind: str = "") -> str | None:
    """luau-lsp message -> a problem worth fixing (it errors when the line runs), or None."""
    if kind == "ComparisonPrecedence":
        return (f"{msg.split(';')[0]}: `not` binds tighter than the comparison, so this compares a boolean with a "
                "number and errors (or is always false). Write not (X > Y), or X <= Y.")
    m = re.match(r"^Expected this to be '([^']+)', but got '([^']+)'$", msg)
    if m:
        # Only an assignment to a Roblox property the definitions declare with exactly that type, from a value of
        # a concrete different type Roblox does not convert (strings and numbers become enum items and text).
        want, got = m.groups()
        prop = re.search(r"\.\s*(\w+)\s*=(?!=)", src_line)
        base = want.rstrip("?")
        if not (prop and want in defs.prop_types.get(prop.group(1), set())) or not _CONCRETE.fullmatch(got) \
                or got == base or (base.startswith("Enum") and got in ("string", "number")) \
                or (base in _STRINGISH and got in ("number", "string")) or (base == "number" and got == "string"):
            return None
        return (f"{prop.group(1)} takes a {base}, and this assigns a {got}, so this line errors (Unable to assign "
                f"property {prop.group(1)})." + (f" It needs a {base} instance, not a position or value."
                                                  if base in defs.classes and got not in defs.classes else ""))
    m = re.match(r"^Key '([^']+)' not found in external type '([^']+)'$", msg)
    if m:
        key, typ = m.groups()
        if typ.startswith("Enum."):
            enum = typ[5:]
            items = defs.enum_items.get(enum, set())
            return (f"Enum.{enum}.{key} does not exist, so this line errors. Enum.{enum} has: "
                    + ", ".join(sorted(items)[:30]) + ".")
        if typ in ("Instance", "PVInstance") or key in names or key in ROBLOX_CHILDREN:
            return None
        members = defs.members(typ)
        if not members:
            return None
        # A base-class type (GuiObject, BasePart, Light, ...) may hold a subclass that has the key. Part is the
        # exception: a Part-typed value comes from Instance.new("Part"), not from a SpawnLocation.
        if typ != "Part" and key in defs.subclass_members(typ):
            return None
        close = _close_matches(key, members)
        return (f"{typ} has no property or method '{key}', so this line errors."
                + (f" Did you mean: {', '.join(close)}?" if close else ""))
    m = re.match(r"^Type 't1 where t1 = \{ AccessModifierType.*does not have key '([^']+)'$", msg)
    if m:
        close = _close_matches(m.group(1), defs.enums)
        return (f"Enum.{m.group(1)} does not exist, so this line errors."
                + (f" Enums with a similar name: {', '.join(close)}." if close else ""))
    m = re.match(r"^Invalid class name '([^']+)'$", msg)
    if m:
        close = _close_matches(m.group(1), set(defs.classes))
        return (f"Instance.new(\"{m.group(1)}\") errors: Roblox has no class '{m.group(1)}'."
                + (f" Did you mean: {', '.join(close)}?" if close else ""))
    m = re.match(r"^Key '(\w+)' not found in table '([^']*)'", msg)
    # Only `Module.fn(...)` on a capitalised module or library name: method calls on objects (`self.track:Sample()`)
    # go through metatables the checker cannot always follow.
    call = m and re.search(rf"\b([A-Z]\w*)\s*\.\s*{re.escape(m.group(1))}\s*\(", src_line)
    if m and call:
        key, what = m.group(1), call.group(1)
        guarded = re.search(rf"\.\s*{re.escape(key)}\s+and\b", src_line)
        return (f"calls '{key}', which {what} does not define: "
                + ("the guard makes this line silently do nothing, so the feature never happens. "
                   if guarded else "this line errors (attempt to call a nil value). ")
                + "Call a function the module really exports, or add it where it belongs.")
    m = re.match(r"^Argument count mismatch\. Function '([\w.:]+)' expects (\d+) arguments?, but only (\d+) (?:is|are) "
                 r"specified$", msg)
    if m and re.split(r"[.:]", m.group(1))[0] in _LIBS:
        return f"{m.group(1)} needs {m.group(2)} arguments and this call gives {m.group(3)}, so it errors."
    return None


async def api_problems(ws_root: Path, check: list[str], timeout: float = 90) -> dict[str, list[str]]:
    """{rel path: [problem]} for the files in `check` (paths under src/); only paths with problems appear."""
    exe, dpath = lsp_exe(), defs_path()
    ws_root = Path(ws_root).resolve()          # luau-lsp runs in ws_root: every path it gets must be absolute
    src = ws_root / "src"
    if not available() or not check or not src.is_dir():
        return {}
    files = sorted(str(p.relative_to(src)).replace("\\", "/") for p in src.rglob("*.lua*"))
    sources = {}
    for rel in files:
        try:
            sources[rel] = (src / rel).read_text(encoding="utf-8", errors="replace")
        except OSError:
            pass
    fd, smap = tempfile.mkstemp(prefix="sourcemap_", suffix=".json", dir=str(ws_root))
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(sourcemap(files), f)
    targets = [str(src / rel) for rel in check if (src / rel).is_file()]
    try:
        proc = await asyncio.create_subprocess_exec(
            exe, "analyze", "--platform=roblox", f"--sourcemap={smap}", f"--definitions=@roblox={dpath}",
            "--formatter=plain", *targets, cwd=str(ws_root), stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT)
        try:
            out, _ = await asyncio.wait_for(proc.communicate(), timeout)
        except asyncio.TimeoutError:
            proc.kill()
            return {}
    finally:
        try:
            os.unlink(smap)
        except OSError:
            pass
    defs = load_defs(dpath)
    names = child_names(sources)
    by_abs = {os.path.normcase(os.path.abspath(str(src / rel))): rel for rel in check}
    problems: dict[str, list[str]] = {}
    for line in out.decode("utf-8", "replace").splitlines():
        m = _LINE.match(line.strip())
        if not m:
            continue
        f = m.group("file")
        rel = by_abs.get(os.path.normcase(os.path.abspath(f if os.path.isabs(f) else os.path.join(ws_root, f))))
        if rel is None:
            continue
        ln = int(m.group("line"))
        lines = sources.get(rel, "").splitlines()
        text = lines[ln - 1] if 0 < ln <= len(lines) else ""
        p = classify(m.group("msg"), text, defs, names, m.group("kind"))
        if p:
            entry = f"line {ln}: {p}  `{text.strip()[:120]}`"
            if entry not in problems.setdefault(rel, []):
                problems[rel].append(entry)
    return {k: v for k, v in problems.items() if v}

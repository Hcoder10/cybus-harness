"""Static wiring check (no Studio needed): does every require() in the game reach a ModuleScript that exists?

Live, a server entry script did `local ServerStorage = script.Parent` and required Config, State and Fishing from it,
while the architecture had put those modules in ServerScriptService/ServerStorage/: the whole server would have
died on line 13 the first time the game ran. The same game asked `ReplicatedStorage:WaitForChild("Shared.Tokens")`
(WaitForChild takes one name, not a dotted path) and required the Kit Folder itself. Each of these only shows up
at runtime, as a nil or an infinite yield, and usually inside a pcall that hides it.

This follows the simple instance chains Roblox code uses to reach a module against the project tree:
`script`, `.Parent`, `game:GetService("X")`, local aliases (`local Shared = ReplicatedStorage:WaitForChild("Shared")`,
also through `pcall(function() return ... end)`), `:WaitForChild("N")`, `:FindFirstChild("N")`, `.N`, `["N"]`, and
lazy-require helpers (`local function tryRequire(name) ... require(ClientStorage:WaitForChild(name)) ... end` called
as `tryRequire("Hud")`). Anything it cannot follow (computed names, instances made at runtime, players and
characters) is skipped, never reported, so a report is always worth fixing.

    python -m harness.wiring <workspace root or src dir>
"""
from __future__ import annotations

import bisect
import re
import sys
from pathlib import Path
from typing import Iterable

from harness.tools.workspace import SERVICES, parse_rel

OPEN = ("<runtime>",)                 # somewhere the static tree cannot see: a player, a character, the 3D world
_LOCAL_PLAYER = ("<LocalPlayer>",)
# Roblox copies these per player at runtime; above them (`.Parent`) is the player or the character.
_PER_PLAYER = {("StarterPlayer", "StarterPlayerScripts"), ("StarterPlayer", "StarterCharacterScripts"),
               ("StarterGui",), ("StarterPack",)}
# Per-player containers that also fill up at runtime (ScreenGuis, the character's parts, tools).
_RUNTIME_FILLED = {("StarterPlayer", "StarterCharacterScripts"), ("StarterGui",), ("StarterPack",)}
# Services games and Roblox itself fill at runtime, so a missing child there proves nothing.
_OPEN_SERVICES = {"Workspace", "Players", "Lighting", "SoundService", "Teams", "Chat", "TextChatService",
                  "MaterialService", "LocalizationService"}
_ROBLOX_PLAYER_SCRIPTS = {"PlayerModule", "RbxCharacterSounds", "ChatScript", "BubbleChat", "PlayerScriptsLoader"}
_PLAYER_CHILDREN = {"PlayerScripts": ("StarterPlayer", "StarterPlayerScripts"), "PlayerGui": ("StarterGui",),
                    "Backpack": ("StarterPack",)}
_SERVER_ONLY = {"ServerScriptService", "ServerStorage"}
_CLIENT_CONTAINERS = ("StarterPlayer/StarterPlayerScripts/", "StarterPlayer/StarterCharacterScripts/", "StarterGui/",
                      "ReplicatedFirst/", "StarterPack/")

_ID = re.compile(r"[A-Za-z_]\w*")
_STR = re.compile(r'"((?:[^"\\\n]|\\.)*)"|\'((?:[^\'\\\n]|\\.)*)\'')
_REQUIRE = re.compile(r"\brequire\s*\(")
_PCALL_REQUIRE = re.compile(r"\bpcall\s*\(\s*require\s*,")
_ASSIGN = re.compile(r"(?m)^[ \t]*(?:local[ \t]+)?([A-Za-z_]\w*)(?:[ \t]*:[^=\n]+?)?[ \t]*=(?!=)")
_PCALL_ALIAS = re.compile(r"(?m)^[ \t]*local[ \t]+[A-Za-z_]\w*[ \t]*,[ \t]*([A-Za-z_]\w*)(?:[ \t]*:[^=\n]+?)?[ \t]*=[ \t]*"
                          r"pcall\(\s*function\s*\(\s*\)\s*return\s+")
_FUNC = re.compile(r"(?m)^([ \t]*)(?:local[ \t]+)?function[ \t]+([A-Za-z_]\w*)[ \t]*\(([^)]*)\)")
_FUNC_VAR = re.compile(r"(?m)^([ \t]*)local[ \t]+([A-Za-z_]\w*)[ \t]*=[ \t]*function[ \t]*\(([^)]*)\)")
_TERMINATOR = re.compile(r"[ \t]*(?:$|;|::|--|\bor\b|\)|,)", re.M)
_LONG_OPEN = re.compile(r"\[(=*)\[")
_BLOCK_COMMENT = re.compile(r"--\[(=*)\[")


def _blank(text: str) -> str:
    return re.sub(r"[^\n]", " ", text)


def strip_comments(src: str, strings: bool = False) -> str:
    """Blank out comments (and with strings=True the inside of string literals too), keeping every newline, so
    offsets and line numbers still match the source."""
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if c in "\"'":
            m = _STR.match(src, i)
            j = m.end() if m else i + 1
            out.append(src[i] + _blank(src[i + 1:j - 1]) + src[j - 1] if strings and j - i >= 2 else src[i:j])
            i = j
        elif c == "-" and src.startswith("--", i):
            m = _BLOCK_COMMENT.match(src, i)
            if m:
                end = src.find("]" + m.group(1) + "]", m.end())
                j = n if end < 0 else end + len(m.group(1)) + 2
            else:
                end = src.find("\n", i)
                j = n if end < 0 else end
            out.append(_blank(src[i:j]))
            i = j
        elif c == "[" and _LONG_OPEN.match(src, i):
            m = _LONG_OPEN.match(src, i)
            end = src.find("]" + m.group(1) + "]", m.end())
            j = n if end < 0 else end + len(m.group(1)) + 2
            k = m.end() - i                                   # the bracket length, same at both ends
            out.append(src[i:i + k] + _blank(src[i + k:j - k]) + src[j - k:j] if strings and end >= 0 else src[i:j])
            i = j
        else:
            out.append(c)
            i += 1
    return "".join(out)


class Tree:
    """Instance path -> class, for everything the project files create (folders implied by directories)."""

    def __init__(self, paths: Iterable[str]) -> None:
        self.kind: dict[tuple, str] = {(s,): "Service" for s in SERVICES | _OPEN_SERVICES}
        self.file: dict[tuple, str] = {}
        for p in paths:
            try:
                info = parse_rel(p)
            except ValueError:
                continue
            node = (info.service, *info.folders, info.name)
            for i in range(2, len(node)):
                self.kind.setdefault(node[:i], "Folder")
            self.kind[node] = info.class_name
            self.file[node] = info.rel

    def modules_named(self, name: str) -> list[tuple]:
        return sorted(n for n, k in self.kind.items() if k == "ModuleScript" and n[-1] == name)


def fmt_path(node: tuple) -> str:
    """ReplicatedStorage.Shared.Tokens; a segment that is not a plain name shows as ["Shared.Tokens"]."""
    out = ""
    for seg in node:
        out += (("." if out else "") + seg) if _ID.fullmatch(seg) else f'["{seg}"]'
    return out


def _ws(s: str, i: int) -> int:
    while i < len(s) and s[i] in " \t\r\n":
        i += 1
    return i


def _call_args(s: str, i: int) -> tuple[list[str], int] | None:
    """s[i] is '(' -> (the raw argument strings, the index after the matching ')')."""
    depth, j, start, out = 0, i, i + 1, []
    while j < len(s):
        c = s[j]
        if c in "\"'":
            m = _STR.match(s, j)
            if not m:
                return None
            j = m.end()
            continue
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
            if depth == 0:
                out.append(s[start:j].strip())
                return [a for a in out if a], j + 1
        elif c == "," and depth == 1:
            out.append(s[start:j].strip())
            start = j + 1
        j += 1
    return None


def _literal(arg: str) -> str | None:
    m = _STR.fullmatch(arg)
    if not m:
        return None
    return m.group(1) if m.group(1) is not None else m.group(2)


def parse_chain(s: str, i: int) -> tuple[list[tuple[str, str]], int] | None:
    """Parse an instance chain at s[i:]. Steps: ("base", name), ("parent", ""), ("child", name),
    ("service", name), ("param", identifier) for a child named by a variable, ("dyn", ...) for anything else."""
    i = _ws(s, i)
    m = _ID.match(s, i)
    if not m:
        return None
    steps: list[tuple[str, str]] = [("base", m.group())]
    i = m.end()
    while True:
        j = _ws(s, i)
        if j >= len(s) or s.startswith("..", j):
            break
        if s[j] == ".":
            m = _ID.match(s, _ws(s, j + 1))
            if not m:
                break
            steps.append(("parent", "") if m.group() == "Parent" else ("child", m.group()))
            i = m.end()
            continue
        if s[j] == ":" and not s.startswith("::", j):
            m = _ID.match(s, _ws(s, j + 1))
            if not m:
                break
            k = _ws(s, m.end())
            if k >= len(s) or s[k] != "(":
                break
            parsed = _call_args(s, k)
            if parsed is None:
                break
            args, end = parsed
            method, first = m.group(), (parsed[0][0] if parsed[0] else "")
            lit = _literal(first)
            recursive = method == "FindFirstChild" and len(args) > 1 and args[1] != "false"
            if method in ("WaitForChild", "FindFirstChild") and not recursive:
                if lit is not None:
                    steps.append(("child", lit))
                elif _ID.fullmatch(first):
                    steps.append(("param", first))
                else:
                    steps.append(("dyn", first))
            elif method == "GetService" and lit is not None:
                steps.append(("service", lit))
            else:
                steps.append(("dyn", method))
            i = end
            continue
        if s[j] == "[" and not _LONG_OPEN.match(s, j):
            k = _ws(s, j + 1)
            sm = _STR.match(s, k)
            if sm:
                k2 = _ws(s, sm.end())
                if k2 < len(s) and s[k2] == "]":
                    steps.append(("child", _literal(sm.group())))
                    i = k2 + 1
                    continue
        break
    return steps, i


class FileCheck:
    """Resolve and check one file's requires against the tree."""

    def __init__(self, tree: Tree, path: str, src: str) -> None:
        self.tree, self.path, self.raw = tree, path, src
        self.src = strip_comments(src)                      # chains are parsed here (string literals intact)
        self.mask = strip_comments(src, strings=True)       # code is found here (nothing inside strings)
        info = parse_rel(path)
        self.script = (info.service, *info.folders, info.name)
        rel = info.rel
        if info.class_name == "LocalScript" or (info.class_name == "ModuleScript" and rel.startswith(_CLIENT_CONTAINERS)):
            self.side = "client"
        elif info.class_name == "Script" or info.service in _SERVER_ONLY:
            self.side = "server"
        else:
            self.side = "either"
        self._lines = [m.start() for m in re.finditer(r"\n", self.src)]
        self.aliases: dict[str, tuple | None] = {}
        self._collect_aliases()

    def line_of(self, pos: int) -> int:
        return bisect.bisect_left(self._lines, pos) + 1

    def resolve(self, steps: list[tuple[str, str]]) -> tuple | None:
        kind, base = steps[0]
        if base == "script":
            node: tuple | None = self.script
        elif base == "game":
            node = ()
        elif base == "workspace":
            node = ("Workspace",)
        elif base in self.aliases:
            node = self.aliases[base]
        else:
            return None
        for kind, v in steps[1:]:
            if node is None or node == OPEN:
                return node
            if kind == "parent":
                if node in _PER_PLAYER:
                    node = OPEN
                elif node in ((), _LOCAL_PLAYER):
                    return None
                else:
                    node = node[:-1]
            elif kind == "service":
                if node != ():
                    return None
                node = (v,) if v in SERVICES or v in _OPEN_SERVICES else OPEN
            elif kind == "child":
                if node == ():
                    node = (v,) if v in SERVICES or v in _OPEN_SERVICES else OPEN
                elif node == _LOCAL_PLAYER:
                    node = _PLAYER_CHILDREN.get(v, OPEN)
                elif node == ("Players",) and v == "LocalPlayer":
                    node = _LOCAL_PLAYER
                elif node[0] in _OPEN_SERVICES:
                    node = OPEN
                elif node == ("StarterPlayer", "StarterPlayerScripts") and v in _ROBLOX_PLAYER_SCRIPTS:
                    node = OPEN
                elif node in _RUNTIME_FILLED and node + (v,) not in self.tree.kind:
                    node = OPEN
                else:
                    node = node + (v,)
            else:
                return None
        return node

    def _chain_at(self, pos: int, *, whole: str = "") -> tuple[list[tuple[str, str]], int] | None:
        """A chain starting at pos; `whole` is a regex that must match right after it."""
        parsed = parse_chain(self.src, pos)
        if parsed is None:
            return None
        steps, end = parsed
        if whole and not re.compile(whole, re.M).match(self.src, end):
            return None
        return steps, end

    def _collect_aliases(self) -> None:
        found: dict[str, list[tuple | None]] = {}
        events = []
        for m in _PCALL_ALIAS.finditer(self.mask):
            events.append((m.start(), m.group(1), m.end(), r"\s*end\s*\)"))
        for m in _ASSIGN.finditer(self.mask):
            events.append((m.start(), m.group(1), m.end(), _TERMINATOR.pattern))
        for _, name, pos, whole in sorted(events):
            if name in ("local", "return", "if", "then", "else", "elseif", "end", "do", "while", "for", "function",
                        "not", "and", "or", "until", "repeat", "in"):
                continue
            parsed = self._chain_at(pos, whole=whole)
            value = self.resolve(parsed[0]) if parsed else None
            found.setdefault(name, []).append(value)
            vals = found[name]
            # A name bound to one instance everywhere is an alias; anything else (rebinding, non-chain values) is not.
            self.aliases[name] = vals[0] if all(v == vals[0] for v in vals) else None

    def _helpers(self) -> dict[str, list[tuple[str, str]]]:
        """Lazy-require helpers: name -> the chain prefix their single argument is looked up under."""
        out: dict[str, list[tuple[str, str]]] = {}
        heads = list(_FUNC.finditer(self.mask)) + list(_FUNC_VAR.finditer(self.mask))
        for h in heads:
            indent, name, params = h.group(1), h.group(2), h.group(3)
            first = params.split(",")[0].split(":")[0].strip()
            if not _ID.fullmatch(first or ""):
                continue
            eol = self.mask.find("\n", h.end())
            eol = len(self.mask) if eol < 0 else eol
            if re.search(r"\bend\s*$", self.mask[h.end():eol]):         # a one-line function
                body_end = eol
            else:
                end = re.compile(rf"(?m)^{re.escape(indent)}end\b").search(self.mask, h.end())
                body_end = end.start() if end else len(self.mask)
            for rm in list(_REQUIRE.finditer(self.mask, h.end(), body_end)) + list(
                    _PCALL_REQUIRE.finditer(self.mask, h.end(), body_end)):
                parsed = self._chain_at(rm.end(), whole=r"\s*\)")
                if parsed and parsed[0][-1] == ("param", first) and all(k != "param" and k != "dyn"
                                                                         for k, _ in parsed[0][:-1]):
                    out[name] = parsed[0][:-1]
        return out

    def _problem(self, pos: int, snippet: str, node: tuple, name: str) -> str | None:
        where = f"line {self.line_of(pos)}: {snippet}"
        kind = self.tree.kind.get(node)
        dotted = fmt_path(node)
        if kind == "ModuleScript":
            if self.side == "client" and node[0] in _SERVER_ONLY:
                return (f"{where} requires {dotted}, but clients cannot see {node[0]}: this LocalScript waits forever. "
                        "Put modules both sides need in ReplicatedStorage.")
            return None
        if kind is not None:
            what = "a Folder" if kind == "Folder" else ("a service" if kind == "Service" else f"a {kind}")
            return (f"{where} requires {dotted}, which is {what}, not a ModuleScript, so require errors. Require one "
                    "module inside it" + (f" (e.g. {dotted}.{self._example_child(node)})" if self._example_child(node)
                                          else "") + ".")
        msg = f"{where} looks for {dotted}, which does not exist, so this script stops here (WaitForChild waits forever, or returns nil and require errors)."
        if "." in name:
            parts = name.split(".")
            msg += (f" WaitForChild/FindFirstChild take ONE child name, not a dotted path: use "
                    + "".join(f':WaitForChild("{p}")' for p in parts) + ".")
        cands = self.tree.modules_named(name.split(".")[-1])
        if cands:
            msg += " Modules with that name: " + ", ".join(
                f"{'.'.join(c)} ({self.tree.file.get(c, '')})" for c in cands[:4]) + "."
        return msg

    def _example_child(self, node: tuple) -> str:
        kids = sorted(n[-1] for n, k in self.tree.kind.items() if k == "ModuleScript" and n[:-1] == node)
        return kids[0] if kids else ""

    def problems(self) -> list[str]:
        """Problem messages in line order."""
        out: list[tuple[int, str]] = []
        seen: set[str] = set()

        def check(pos: int, end: int, steps: list[tuple[str, str]]) -> None:
            node = self.resolve(steps)
            if node is None or node == OPEN or not node or node[0].startswith("<"):
                return
            snippet = " ".join(self.raw[pos:end].split())
            snippet = snippet if len(snippet) <= 100 else snippet[:97] + "..."
            p = self._problem(pos, snippet, node, steps[-1][1] if steps[-1][0] == "child" else node[-1])
            if p and p not in seen:
                seen.add(p)
                out.append((pos, p))

        for rx in (_REQUIRE, _PCALL_REQUIRE):
            for m in rx.finditer(self.mask):
                parsed = self._chain_at(m.end(), whole=r"\s*\)")
                if parsed:
                    check(m.start(), parsed[1] + 1, parsed[0])
        # A player's character is a property, never a child (live: a server join handler waited 10 s for it and got
        # nil, so no player was ever placed at the pier).
        for m in re.finditer(r":\s*(?:WaitForChild|FindFirstChild)\(\s*[\"']Character[\"']", self.src):
            if self.mask[m.start()] != ":":
                continue                                           # inside a string (blanked in the mask)
            out.append((m.start(), f"line {self.line_of(m.start())}: {' '.join(self.raw[m.start():m.end() + 8].split())}"
                                   f"... looks for a child named Character, but a player's character is the "
                                   "player.Character property (a model in Workspace), never a child: this returns nil "
                                   "or waits forever. Use player.Character or player.CharacterAdded:Wait()."))
        for name, prefix in self._helpers().items():
            for m in re.finditer(rf"(?<![\w.:]){re.escape(name)}\s*\(\s*(\"[^\"\n]*\"|'[^'\n]*')\s*[,)]", self.src):
                if self.mask[m.start():m.start() + len(name)] != name:        # inside a string
                    continue
                lit = _literal(m.group(1))
                check(m.start(), m.end(), prefix + [("child", lit or "")])
        return [p for _, p in sorted(out)]


def wiring_problems(all_paths: Iterable[str], sources: dict[str, str]) -> dict[str, list[str]]:
    """{path: [problem]} for the given sources, resolved against the tree all_paths make. Only paths with problems."""
    tree = Tree(all_paths)
    out: dict[str, list[str]] = {}
    for path, src in sources.items():
        try:
            probs = FileCheck(tree, path, src).problems()
        except ValueError:
            continue
        if probs:
            out[path] = probs
    return out


def module_listing(all_paths: Iterable[str], names: Iterable[str] = ()) -> str:
    """The project's ModuleScripts as `instance path  <- file` lines (those named in `names` first)."""
    tree = Tree(all_paths)
    want = set(names)
    mods = sorted((n for n, k in tree.kind.items() if k == "ModuleScript"), key=lambda n: (n[-1] not in want, n))
    return "\n".join(f"{'.'.join(n)}  <- {tree.file.get(n, '')}" for n in mods)


def check_tree(root: Path) -> dict[str, list[str]]:
    src_dir = root / "src" if (root / "src").is_dir() else root
    files = {str(p.relative_to(src_dir)).replace("\\", "/"): p.read_text(encoding="utf-8", errors="replace")
             for p in sorted(src_dir.rglob("*.lua*"))}
    return wiring_problems(files, files)


def main(argv: list[str] | None = None) -> int:
    args = argv if argv is not None else sys.argv[1:]
    if not args:
        print(__doc__.strip().splitlines()[-1].strip())
        return 2
    total = 0
    for root in args:
        probs = check_tree(Path(root))
        for path, items in probs.items():
            print(path)
            for p in items:
                print("  " + p)
            total += len(items)
    print(f"{total} wiring problem(s)")
    return 1 if total else 0


if __name__ == "__main__":
    raise SystemExit(main())

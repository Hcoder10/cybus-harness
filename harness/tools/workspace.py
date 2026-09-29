"""The project tree on disk, and pushing it into Studio.

    root/src/<Service>/<Folder>/.../<Name>.server.luau   -> Script
    root/src/<Service>/<Folder>/.../<Name>.client.luau   -> LocalScript
    root/src/<Service>/<Folder>/.../<Name>.luau          -> ModuleScript      (.lua works the same way)

Directories become Folders (StarterPlayerScripts / StarterCharacterScripts under StarterPlayer keep their own
class). root/.sync.json keeps the sha256 of each file as last pushed and the PlaceId it went to, so changed()
is exactly what sync() would push. A different PlaceId means a full push.

sync() does not use script_create / instance_create / script_set_source, one call per file and per folder.
It pushes batches of files as execution_run_luau chunks that start with `if game.PlaceId ~= <allowed> then
error(...)` (plus the bridge's place_marker check when it has one, which unpublished PlaceId-0 places need).
This is the one kind of write that stays safe when several Studio windows share the bridge
token: the window that picks the command up checks its own PlaceId before touching anything. A command
sent to the wrong window does nothing, and StudioBridge resends it. It is also one round trip and one
undo waypoint per batch instead of about three commands per file. Each file runs in its own pcall, so one
bad file does not stop the rest, and a failed file stays in changed().
"""
from __future__ import annotations

import hashlib
import json
import os
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from harness.tools.base import Tool, ToolResult
    from harness.tools.studio import StudioBridge

SERVICES = frozenset({
    "Workspace", "ReplicatedStorage", "ReplicatedFirst", "ServerScriptService", "ServerStorage", "StarterPlayer",
    "StarterGui", "StarterPack", "Lighting", "SoundService", "Teams", "TextChatService", "Chat",
    "MaterialService", "LocalizationService",
})
SUFFIXES: tuple[tuple[str, str], ...] = (
    (".server.luau", "Script"), (".client.luau", "LocalScript"),
    (".server.lua", "Script"), (".client.lua", "LocalScript"),
    (".luau", "ModuleScript"), (".lua", "ModuleScript"),
)
BATCH_FILES = 25
BATCH_CHARS = 400_000
STATE_VERSION = 1


@dataclass(frozen=True)
class ScriptFile:
    rel: str                     # path under src/, forward slashes
    service: str
    folders: tuple[str, ...]
    name: str
    class_name: str

    @property
    def instance_path(self) -> str:
        return ".".join((self.service, *self.folders, self.name))


def parse_rel(rel: str) -> ScriptFile:
    """Validate a path under src/ ("src/" prefix optional) and say what instance it becomes."""
    raw = str(rel).strip().replace("\\", "/")
    if raw.startswith("/") or (len(raw) > 1 and raw[1] == ":"):
        raise ValueError(f"{rel!r}: use a path relative to src/, e.g. ServerScriptService/Main.server.luau")
    parts = [p for p in PurePosixPath(raw).parts if p != "."]
    if parts and parts[0] == "src":
        parts = parts[1:]
    if any(p == ".." for p in parts):
        raise ValueError(f"{rel!r}: '..' is not allowed")
    if len(parts) < 2:
        raise ValueError(f"{rel!r}: needs a service folder and a file, e.g. ServerScriptService/Main.server.luau")
    if any(not p.strip() or p != p.strip() for p in parts):
        raise ValueError(f"{rel!r}: empty or space-padded path segment")
    service, *folders, filename = parts
    if service not in SERVICES:
        raise ValueError(f"{rel!r}: first folder must be a Roblox service, one of {', '.join(sorted(SERVICES))}")
    for suffix, class_name in SUFFIXES:
        if filename.endswith(suffix) and len(filename) > len(suffix):
            name = filename[: -len(suffix)]
            return ScriptFile("/".join(parts), service, tuple(folders), name, class_name)
    raise ValueError(f"{rel!r}: script files end in .server.luau (Script), .client.luau (LocalScript) "
                     f"or .luau (ModuleScript)")


def _normalize(text: str) -> str:
    return text.replace("\r\n", "\n").replace("\r", "\n")


def _digest(text: str) -> str:
    return hashlib.sha256(_normalize(text).encode("utf-8")).hexdigest()


def lua_quote(s: str) -> str:
    out = ['"']
    for ch in s:
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif ord(ch) < 32 or ord(ch) == 127:
            out.append(f"\\{ord(ch):03d}")
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def lua_long_string(s: str) -> str:
    """A Luau long-bracket literal whose value is exactly `s`. The level is the smallest whose closing bracket
    first appears where the literal ends, and the newline after the opening bracket is dropped by the lexer,
    so a leading newline in `s` survives."""
    level = 0
    while True:
        close = "]" + "=" * level + "]"
        if (s + close).find(close) == len(s):
            break
        level += 1
    eq = "=" * level
    return f"[{eq}[\n{s}]{eq}]"


_SYNC_PRELUDE = """
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local recording = nil
pcall(function() recording = ChangeHistoryService:TryBeginRecording("cybus-harness sync") end)

local function container(parent, name)
	local child = parent:FindFirstChild(name)
	if child == nil then
		local class = "Folder"
		if parent:IsA("StarterPlayer") and (name == "StarterPlayerScripts" or name == "StarterCharacterScripts") then
			class = name
		end
		child = Instance.new(class)
		child.Name = name
		child.Parent = parent
	end
	return child
end

local function set_source(script, source)
	local ok = pcall(function() script.Source = source end)
	if not ok then
		game:GetService("ScriptEditorService"):UpdateSourceAsync(script, function() return source end)
	end
end

local function push(job)
	local parent = game:GetService(job.service)
	for _, name in ipairs(job.folders) do
		parent = container(parent, name)
	end
	local existing = parent:FindFirstChild(job.name)
	if existing ~= nil and not existing:IsA("LuaSourceContainer") then
		error(job.name .. " already exists there as a " .. existing.ClassName .. ", not a script", 0)
	end
	if existing ~= nil and existing.ClassName == job.class then
		set_source(existing, job.source)
		return "updated", existing:GetFullName()
	end
	local script = Instance.new(job.class)
	script.Name = job.name
	set_source(script, job.source)
	if existing ~= nil then
		for _, child in ipairs(existing:GetChildren()) do
			child.Parent = script
		end
	end
	script.Parent = parent
	if existing ~= nil then
		existing:Destroy()
		return "replaced", script:GetFullName()
	end
	return "created", script:GetFullName()
end
"""

_SYNC_RUN = """
local results = {}
for i, job in ipairs(jobs) do
	local ok, action, path = pcall(push, job)
	if ok then
		results[i] = {file = job.file, ok = true, action = action, path = path}
	else
		results[i] = {file = job.file, ok = false, error = tostring(action)}
	end
end
if recording then
	pcall(function() ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit) end)
end
return {results = results, place_id = tostring(game.PlaceId)}
"""


def build_sync_luau(place_id: str, batch: list[tuple[ScriptFile, str]],
                    marker: tuple[str, str] | None = None) -> str:
    """The Luau chunk that pushes `batch` [(file, source)], guarded by an in-Studio PlaceId (+ marker) assertion."""
    from harness.tools.studio import place_assertion
    jobs = []
    for info, source in batch:
        folders = ", ".join(lua_quote(f) for f in info.folders)
        jobs.append(
            f"\t{{file = {lua_quote(info.rel)}, service = {lua_quote(info.service)}, folders = {{{folders}}}, "
            f"name = {lua_quote(info.name)}, class = {lua_quote(info.class_name)}, "
            f"source = {lua_long_string(source)}}},")
    return (place_assertion(place_id, marker) + "\n" + _SYNC_PRELUDE + "\nlocal jobs = {\n" + "\n".join(jobs)
            + "\n}\n" + _SYNC_RUN)


def _batches(jobs: list[tuple[ScriptFile, str, str]]) -> list[list[tuple[ScriptFile, str, str]]]:
    out: list[list[tuple[ScriptFile, str, str]]] = []
    current: list[tuple[ScriptFile, str, str]] = []
    size = 0
    for job in jobs:
        if current and (len(current) >= BATCH_FILES or size + len(job[1]) > BATCH_CHARS):
            out.append(current)
            current, size = [], 0
        current.append(job)
        size += len(job[1])
    if current:
        out.append(current)
    return out


class Workspace:
    """A game's source tree on disk (root/src/...), synced one way into Studio."""

    def __init__(self, root: Path) -> None:
        self.root = Path(root)
        self.src = self.root / "src"
        self.state_file = self.root / ".sync.json"

    # ---------------------------------------------------------------- files

    def write(self, rel: str, source: str) -> None:
        info = parse_rel(rel)
        path = self.src / info.rel
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(_normalize(str(source)))

    def read(self, rel: str) -> str:
        info = parse_rel(rel)
        with open(self.src / info.rel, encoding="utf-8") as f:     # universal newlines: always "\n"
            return f.read()

    def files(self) -> list[str]:
        """Every script file under src/, as paths relative to src/."""
        return [rel for rel, ok in self._scan() if ok]

    def _scan(self) -> list[tuple[str, bool]]:
        if not self.src.is_dir():
            return []
        found = []
        for path in sorted(self.src.rglob("*")):
            rel = path.relative_to(self.src).as_posix()
            if not path.is_file() or any(part.startswith(".") for part in rel.split("/")):
                continue
            if not rel.endswith((".lua", ".luau")):
                continue
            try:
                parse_rel(rel)
                found.append((rel, True))
            except ValueError:
                found.append((rel, False))
        return found

    def _hash(self, rel: str) -> str:
        return _digest(self.read(rel))

    def changed(self) -> list[str]:
        """Script files whose content differs from what was last pushed (or that were never pushed)."""
        pushed = self._load_state().get("files", {})
        return [rel for rel in self.files() if pushed.get(rel, {}).get("sha256") != self._hash(rel)]

    def _load_state(self) -> dict:
        try:
            state = json.loads(self.state_file.read_text(encoding="utf-8"))
            if isinstance(state, dict) and isinstance(state.get("files"), dict):
                return state
        except (OSError, ValueError):
            pass
        return {"version": STATE_VERSION, "place_id": None, "files": {}}

    def _save_state(self, state: dict) -> None:
        self.root.mkdir(parents=True, exist_ok=True)
        tmp = self.state_file.with_name(self.state_file.name + ".tmp")
        tmp.write_text(json.dumps(state, indent=1, sort_keys=True), encoding="utf-8")
        os.replace(tmp, self.state_file)

    # ---------------------------------------------------------------- sync

    async def sync(self, bridge: "StudioBridge", force: bool = False, exclude: set[str] | None = None) -> dict:
        """Push changed scripts into the linked Studio, creating folders as needed. Raises StudioRefused if the
        guard refuses (protected or non-allowed place); per-file failures are reported, not raised. Files in
        `exclude` (paths under src/) are held back: not pushed, and still in changed() afterwards.

        Report: {ok, place_id, pushed: [{file, instance, class, action: created|updated|replaced}],
                 failed: [{file, error}], unchanged, excluded, deleted_locally, skipped}"""
        from harness.tools.studio import StudioError, StudioRefused
        await bridge.guard("execution_run_luau")
        place = await bridge.active_place_id()
        if place is None:
            raise StudioRefused("refused sync: the active Studio PlaceId is unknown", code="REFUSED")

        state = self._load_state()
        if state.get("place_id") != place:
            state = {"version": STATE_VERSION, "place_id": place, "files": {}}
        scanned = self._scan()
        all_files = [rel for rel, ok in scanned if ok]
        current = {rel: self.read(rel) for rel in all_files}
        digests = {rel: _digest(text) for rel, text in current.items()}
        held: set[str] = set()
        for rel in exclude or ():
            try:
                held.add(parse_rel(rel).rel)          # same spelling as files(): "src/" prefix, slashes
            except ValueError:
                held.add(str(rel))
        due = [rel for rel in all_files if force or state["files"].get(rel, {}).get("sha256") != digests[rel]]
        todo = [rel for rel in due if rel not in held]
        deleted = sorted(rel for rel in state["files"] if rel not in current)
        for rel in deleted:
            del state["files"][rel]

        report: dict[str, Any] = {
            "ok": True, "place_id": place, "pushed": [], "failed": [],
            "unchanged": len(all_files) - len(due), "excluded": [rel for rel in due if rel in held],
            "deleted_locally": deleted, "skipped": [rel for rel, ok in scanned if not ok],
        }
        marker = getattr(bridge, "place_marker", None)
        targets: dict[tuple[str, ...], list[str]] = defaultdict(list)
        for rel in all_files:
            info = parse_rel(rel)
            targets[(info.service, *info.folders, info.name)].append(rel)
        jobs = []
        for rel in todo:
            info = parse_rel(rel)
            clash = targets[(info.service, *info.folders, info.name)]
            if len(clash) > 1:
                report["failed"].append({"file": rel, "error": f"{', '.join(clash)} all map to {info.instance_path}"})
                continue
            jobs.append((info, current[rel], digests[rel]))

        try:
            for batch in _batches(jobs):
                code = build_sync_luau(place, [(info, source) for info, source, _ in batch], marker)
                try:
                    result = await bridge.call("execution_run_luau", {"code": code})
                except StudioRefused:
                    raise
                except StudioError as e:
                    report["failed"].extend({"file": info.rel, "error": str(e)} for info, _, _ in batch)
                    continue
                by_file = {r.get("file"): r for r in (result.get("results") or []) if isinstance(r, dict)}
                for info, _, digest in batch:
                    r = by_file.get(info.rel) or {}
                    if r.get("ok"):
                        state["files"][info.rel] = {"sha256": digest, "class": info.class_name,
                                                    "instance": info.instance_path}
                        report["pushed"].append({"file": info.rel, "instance": r.get("path") or info.instance_path,
                                                 "class": info.class_name, "action": r.get("action")})
                    else:
                        report["failed"].append({"file": info.rel, "error": r.get("error") or "no result from Studio"})
                self._save_state(state)
        finally:
            self._save_state(state)
        report["ok"] = not report["failed"]
        return report

    # ---------------------------------------------------------------- agent tools

    def tools(self, bridge: "StudioBridge") -> list["Tool"]:
        """write_file / read_file / list_files / sync_to_studio for agents."""
        from harness.tools.base import Tool, ToolResult
        from harness.tools.studio import StudioError, StudioRefused

        def errors_as_text(impl):
            async def fn(**kwargs: Any) -> "ToolResult":
                try:
                    return await impl(**kwargs)
                except (ValueError, OSError, TypeError) as e:   # bad path, disk error, bad arguments
                    return ToolResult(text=f"ERROR: {e}", data={"error": str(e)})
            fn.__name__ = impl.__name__
            return fn

        async def write_file(path: str, content: str) -> ToolResult:
            self.write(path, content)
            info = parse_rel(path)
            lines = content.count("\n") + 1 if content else 0
            return ToolResult(text=f"wrote src/{info.rel} ({info.class_name} {info.instance_path}, {lines} lines). "
                                   f"Not in Studio until sync_to_studio.",
                              data={"file": info.rel, "instance": info.instance_path, "class": info.class_name})

        async def read_file(path: str) -> ToolResult:
            info = parse_rel(path)
            if not (self.src / info.rel).is_file():
                return ToolResult(text=f"ERROR: src/{info.rel} does not exist", data={"error": "missing"})
            return ToolResult(text=self.read(info.rel), data={"file": info.rel})

        async def list_files() -> ToolResult:
            pending = set(self.changed())
            rows = [(rel, parse_rel(rel)) for rel in self.files()]
            if not rows:
                return ToolResult(text="no script files yet under src/", data={"files": []})
            text = "\n".join(f"{rel}  -> {info.class_name} {info.instance_path}{'  (not synced)' if rel in pending else ''}"
                             for rel, info in rows)
            return ToolResult(text=text, data={"files": [rel for rel, _ in rows], "changed": sorted(pending)})

        async def sync_to_studio(force: bool = False) -> ToolResult:
            try:
                report = await self.sync(bridge, force=bool(force))
            except StudioRefused as e:
                return ToolResult(text=f"REFUSED: {e}", data={"error": str(e), "refused": True})
            except StudioError as e:
                return ToolResult(text=f"ERROR: {e}", data={"error": str(e)})
            actions: dict[str, int] = defaultdict(int)
            for p in report["pushed"]:
                actions[p["action"] or "pushed"] += 1
            done = ", ".join(f"{k} {v}" for k, v in sorted(actions.items())) or "nothing to push"
            lines = [f"PlaceId {report['place_id']}: {done}; {len(report['failed'])} failed; "
                     f"{report['unchanged']} unchanged; {len(report['excluded'])} held back."]
            lines += [f"FAILED {f['file']}: {f['error']}" for f in report["failed"]]
            if report["deleted_locally"]:
                lines.append("deleted locally, still in Studio: " + ", ".join(report["deleted_locally"]))
            if report["skipped"]:
                lines.append("skipped (bad path or name): " + ", ".join(report["skipped"]))
            return ToolResult(text="\n".join(lines), data=report)

        path_help = ("Path under src/: <Service>/<Folders...>/<Name>.server.luau (Script), .client.luau "
                     "(LocalScript) or .luau (ModuleScript), e.g. ServerScriptService/Combat/Main.server.luau")
        return [
            Tool(name="write_file", description="Create or overwrite a script file in the project. " + path_help,
                 parameters={"type": "object", "additionalProperties": False, "required": ["path", "content"],
                             "properties": {"path": {"type": "string", "description": path_help},
                                            "content": {"type": "string", "description": "The whole file."}}},
                 fn=errors_as_text(write_file), mutating=True),
            Tool(name="read_file", description="Read a script file from the project.",
                 parameters={"type": "object", "additionalProperties": False, "required": ["path"],
                             "properties": {"path": {"type": "string", "description": path_help}}},
                 fn=errors_as_text(read_file), mutating=False),
            Tool(name="list_files", description="List the project's script files, what each becomes in Studio, "
                                                "and which are not synced yet.",
                 parameters={"type": "object", "additionalProperties": False, "properties": {}},
                 fn=errors_as_text(list_files), mutating=False),
            Tool(name="sync_to_studio", description="Push changed script files into Studio (creates folders and "
                                                    "scripts as needed). force=true pushes every file.",
                 parameters={"type": "object", "additionalProperties": False,
                             "properties": {"force": {"type": "boolean", "default": False}}},
                 fn=errors_as_text(sync_to_studio), mutating=True),
        ]


__all__ = ["SERVICES", "SUFFIXES", "ScriptFile", "Workspace", "build_sync_luau", "lua_long_string", "lua_quote",
           "parse_rel"]

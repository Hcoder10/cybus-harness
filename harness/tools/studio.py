"""MCP client for the Roblox Studio Bridge (http://localhost:3000/mcp), with a PlaceId guard.

The bridge serves whatever Studio is connected to it, and that can be somebody else's live project. So every
mutating call passes the guard first:

  * read-only tools (READ_ONLY) always pass: they observe and never change Studio;
  * BLOCKED tools never pass: they kill every Studio process on the machine or write to live Roblox services;
  * anything else (including tool names we have never seen) is mutating, and passes only when the PlaceId
    of the linked bridge session is in `allow_place_ids` and is not protected. 82121330849989 is always
    protected, whatever the caller passes.

Two limits of a server-side check are also covered. They come from how the bridge works:

  * The plugin keeps its session token in plugin settings, which every Studio window shares. With two windows
    open, both poll the same command queue and a command runs in whichever window polls first. The server's
    idea of the place is then only "the window that registered last". So `execution_run_luau` gets an in-Studio
    assertion (`if game.PlaceId ~= <allowed> then error(...)`) that the executing window checks itself. With
    `place_marker`, the assertion also checks a marker instance's Value, which is what tells unpublished places
    apart (they all have PlaceId 0). Every other mutating tool is refused while more than one Studio process
    runs on this machine.
  * The PlaceId is re-read for every mutating call, and mutating calls are serialized, so re-linking the MCP
    session to another Studio cannot slip in between the check and the send.

Result format: every bridge tool answers with one text item holding JSON, usually the envelope
{"success": true, "data": ...} or {"success": false, "error": {"code", "message", ...}}. A few server tools
answer with a bare object; the studio_* tools use {"ok": false, "error": "..."} for failure. The bridge never
sets MCP isError. `call()` unwraps all of these, raises StudioError on failure, and lifts base64 images
(screenshot_take's "image_base64") into result["images"] as raw bytes.
"""
from __future__ import annotations

import asyncio
import base64
import binascii
import fnmatch
import json
import logging
import re
import subprocess
import sys
import time
from datetime import timedelta
from typing import TYPE_CHECKING, Any
from urllib.parse import urlparse

import httpx

if TYPE_CHECKING:
    from harness.tools.base import Tool, ToolResult

log = logging.getLogger("harness.studio")

DEFAULT_URL = "http://localhost:3000/mcp"
PROTECTED_PLACE_IDS: frozenset[str] = frozenset({"82121330849989"})

# Tools that only observe. Everything else, including names not listed anywhere here, counts as mutating.
READ_ONLY: frozenset[str] = frozenset({
    "session_status", "studio_status",
    "instance_get", "instance_find", "instance_get_property", "instance_get_children",
    "script_get_source", "script_find", "script_list", "script_require_graph", "script_validate_syntax",
    "execution_echo", "execution_get_globals",
    "playtest_get_status", "playtest_get_player", "playtest_get_output_log", "playtest_get_call_stack",
    "playtest_get_variables",
    "terrain_read_voxels", "terrain_get_material_colors",
    "animation_export", "animation_get_length", "animation_list",
    "diagnostics_get_stats", "diagnostics_get_memory", "diagnostics_get_network_stats",
    "diagnostics_get_physics_stats", "diagnostics_get_render_stats", "diagnostics_get_log",
    "diagnostics_get_output", "diagnostics_profile_start", "diagnostics_profile_stop",
    "diagnostics_profile_get_data",
    "ui_get_tree",
    "record_get_status", "record_list", "record_replay_get_status", "record_export",
    "luau_parse", "luau_analyze", "luau_format", "luau_lint", "luau_get_ast", "luau_transform",
    "screenshot_take", "video_record_start", "video_record_stop", "video_get_status",
    "datamodel_dump", "asset_template_list",
    "cloud_api_list_universes", "cloud_api_get_universe", "cloud_api_list_places", "cloud_api_get_place",
    "cloud_api_list_datastores", "cloud_api_get_datastore_entry", "cloud_api_list_datastore_entries",
    "cloud_api_get_ordered_datastore", "cloud_api_get_asset", "cloud_api_list_assets", "cloud_api_get_user",
    "cloud_api_get_group", "cloud_api_list_group_members", "cloud_api_get_messaging",
    "cloud_api_list_subscriptions", "cloud_api_get_inventory", "cloud_api_list_badges",
    "cloud_api_get_game_passes",
})

# Refused whatever the place. studio_kill and studio_swap_place run `taskkill /IM RobloxStudioBeta.exe`, which
# closes every Studio on the machine, other teams' included. The cloud writes act on live Roblox experiences
# chosen by argument, where the active-place check means nothing.
BLOCKED: frozenset[str] = frozenset({
    "studio_kill", "studio_swap_place",
    "cloud_api_update_place", "cloud_api_publish_place", "cloud_api_set_datastore_entry",
    "cloud_api_delete_datastore_entry", "cloud_api_set_ordered_datastore", "cloud_api_upload_asset",
    "cloud_api_send_notification", "cloud_api_publish_message", "cloud_api_award_badge",
})

# Session linking is managed by StudioBridge itself. These count as mutating and are never handed to agents.
CONTROL: frozenset[str] = frozenset({"session_connect", "session_disconnect"})

# Mutating tools whose payload carries an in-Studio PlaceId assertion, so they are safe to send even when
# several Studio windows share the bridge token.
PLACE_ASSERTED: frozenset[str] = frozenset({"execution_run_luau"})

# The default toolset for building agents: look at the game, change it, play it.
AGENT_DEFAULT: tuple[str, ...] = (
    "instance_get", "instance_get_children", "instance_find", "instance_get_property",
    "script_get_source", "script_find", "script_list", "script_validate_syntax", "luau_analyze",
    "ui_get_tree", "datamodel_dump", "screenshot_take",
    "diagnostics_get_output", "playtest_get_status", "playtest_get_output_log",
    "instance_create", "instance_set_property", "instance_delete", "instance_clone", "instance_move",
    "script_create", "script_set_source", "script_replace_section", "execution_run_luau",
    "ui_create_screen_gui", "ui_create_element", "ui_set_layout", "ui_apply_style",
    "playtest_start", "playtest_stop",
    "input_click", "input_key", "input_move", "input_drag",
)

WRONG_PLACE = "WRONG_PLACE"
_WRONG_PLACE_ATTEMPTS = 4          # a mis-routed place-asserted command did nothing, so resending is safe
_WINDOW_CACHE_SECONDS = 3.0
_IMAGE_KEYS = ("image_base64", "diff_image_base64")
_NUMERIC_ID = re.compile(r"^[0-9]+$")
_MARKER_TOKEN = re.compile(r"^[A-Za-z0-9_\-]+$")


class StudioError(RuntimeError):
    """A bridge tool failed, or the bridge could not be reached."""

    def __init__(self, message: str, *, tool: str | None = None, code: str | None = None,
                 data: Any = None) -> None:
        super().__init__(message)
        self.tool = tool
        self.code = code
        self.data = data


class StudioRefused(StudioError):
    """The guard refused a call. Nothing was sent to Studio."""


class _SessionLost(Exception):
    """The MCP session is gone (server restart or idle GC). `safe` = the request was certainly not executed."""

    def __init__(self, message: str, safe: bool) -> None:
        super().__init__(message)
        self.safe = safe


def is_read_only(name: str) -> bool:
    return name in READ_ONLY


def is_mutating(name: str) -> bool:
    """Anything not explicitly read-only is mutating, unknown names included."""
    return name not in READ_ONLY


def _norm_ids(ids: Any) -> set[str]:
    if ids is None:
        return set()
    if isinstance(ids, (str, int)):
        ids = [ids]
    return {str(i).strip() for i in ids if str(i).strip()}


def _norm_place(value: Any) -> str | None:
    """A PlaceId as the bridge reports it; None when unknown (an auto-revived session reports 'unknown')."""
    if value is None:
        return None
    s = str(value).strip()
    if not s or s.lower() in {"unknown", "none", "null", "nil"}:
        return None
    return s


def _describe(exc: BaseException) -> str:
    while isinstance(exc, BaseExceptionGroup) and exc.exceptions:
        exc = exc.exceptions[0]
    return f"{type(exc).__name__}: {exc}"


def _mentions(value: Any, ids: frozenset[str]) -> str | None:
    """Return a protected id that appears anywhere in a call's arguments."""
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        value = str(int(value)) if float(value).is_integer() else str(value)
    if isinstance(value, str):
        return next((i for i in ids if i in value), None)
    if isinstance(value, dict):
        value = list(value.keys()) + list(value.values())
    if isinstance(value, (list, tuple, set)):
        for v in value:
            hit = _mentions(v, ids)
            if hit:
                return hit
    return None


def _check_marker(marker: tuple[str, str] | None) -> tuple[str, str] | None:
    if marker is None:
        return None
    path, value = marker
    segments = str(path).split(".")
    if not all(_MARKER_TOKEN.match(s) for s in segments) or not _MARKER_TOKEN.match(str(value)):
        raise ValueError(f"place_marker must be ('Service.Name', value) of letters, digits, '_' or '-': {marker!r}")
    return str(path), str(value)


def place_assertion(place_id: str, marker: tuple[str, str] | None = None) -> str:
    """One line of Luau that aborts unless it runs in the Studio holding `place_id` and, when given, the marker
    (instance path under game, e.g. "ServerStorage.CybusHarnessRun", whose Value must equal the value). The
    marker is what tells unpublished places apart: they all have PlaceId 0."""
    if not _NUMERIC_ID.match(place_id):
        raise StudioRefused(f"cannot assert a non-numeric PlaceId {place_id!r} inside Studio")
    line = (f'if game.PlaceId ~= {place_id} then error("{WRONG_PLACE}: meant for PlaceId {place_id}, '
            f'this Studio has " .. tostring(game.PlaceId), 0) end')
    marker = _check_marker(marker)
    if marker:
        path, value = marker
        names = ", ".join(f'"{s}"' for s in path.split("."))
        line += (f' local __harness_marker = game for _, __n in ipairs({{{names}}}) do __harness_marker = '
                 f'__harness_marker and __harness_marker:FindFirstChild(__n) end if not __harness_marker or '
                 f'__harness_marker.Value ~= "{value}" then error("{WRONG_PLACE}: this Studio is not the place '
                 f'marked {path} = {value}", 0) end')
    return line


def _with_place_assertion(name: str, args: dict, place_id: str, marker: tuple[str, str] | None = None) -> dict:
    if name != "execution_run_luau":
        return args
    out = dict(args)
    key = "code" if "code" in out or "source" not in out else "source"
    # Same line as the caller's first line, so error line numbers stay where the caller expects them.
    out[key] = place_assertion(place_id, marker) + " " + str(out.get(key) or "")
    return out


def count_studio_processes() -> int | None:
    """Running Roblox Studio processes on this machine (one per open place); None when it cannot tell."""
    try:
        if sys.platform == "win32":
            proc = subprocess.run(
                ["tasklist", "/FI", "IMAGENAME eq RobloxStudioBeta.exe", "/FO", "CSV", "/NH"],
                capture_output=True, text=True, timeout=15,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            if proc.returncode != 0:
                return None
            return sum(1 for line in proc.stdout.splitlines()
                       if line.strip().lower().startswith('"robloxstudiobeta.exe"'))
        if sys.platform == "darwin":
            proc = subprocess.run(["pgrep", "-x", "RobloxStudio"], capture_output=True, text=True, timeout=15)
            return len(proc.stdout.split())
    except (OSError, subprocess.SubprocessError):
        return None
    return None


def _maybe_json(text: str) -> Any:
    try:
        return json.loads(text)
    except (TypeError, ValueError):
        return {"text": text}


def _b64(value: str) -> bytes | None:
    try:
        return base64.b64decode(value)
    except (binascii.Error, ValueError):
        return None


def parse_result(name: str, res: Any) -> dict:
    """Turn an MCP CallToolResult from the bridge into a dict, raising StudioError on any kind of failure."""
    texts: list[str] = []
    images: list[bytes] = []
    for item in getattr(res, "content", None) or []:
        kind = getattr(item, "type", None)
        if kind == "text":
            texts.append(item.text)
        elif kind == "image":
            blob = _b64(item.data)
            if blob:
                images.append(blob)
        elif kind == "resource":
            resource = item.resource
            blob = getattr(resource, "blob", None)
            if blob and str(getattr(resource, "mimeType", "") or "").startswith("image/"):
                decoded = _b64(blob)
                if decoded:
                    images.append(decoded)
            elif getattr(resource, "text", None):
                texts.append(resource.text)
    text = "\n".join(texts)

    if getattr(res, "isError", False):
        payload = _maybe_json(text)
        message = text
        if isinstance(payload, dict) and isinstance(payload.get("error"), dict):
            message = payload["error"].get("message") or text
        raise StudioError(f"{name}: {message or 'tool error'}", tool=name, data=payload)

    if texts:
        payload = _maybe_json(text)
    else:
        payload = getattr(res, "structuredContent", None) or {}

    if isinstance(payload, dict) and isinstance(payload.get("success"), bool) and (
            "data" in payload or "error" in payload):
        if not payload["success"]:
            err = payload.get("error")
            if isinstance(err, dict):
                code, message = err.get("code"), err.get("message") or json.dumps(err)
            else:
                code, message = None, str(err)
            raise StudioError(f"{name}: {message}", tool=name, code=code, data=payload)
        payload = payload.get("data")
    elif isinstance(payload, dict) and payload.get("ok") is False:
        raise StudioError(f"{name}: {payload.get('error') or 'failed'}", tool=name, data=payload)

    if isinstance(payload, dict):
        out = dict(payload)
    elif isinstance(payload, list):
        out = {"items": payload}
    elif payload is None:
        out = {}
    else:
        out = {"value": payload}

    for key in _IMAGE_KEYS:
        if isinstance(out.get(key), str):
            blob = _b64(out[key])
            if blob:
                images.append(blob)
                del out[key]
    if isinstance(out.get("video_base64"), str):
        blob = _b64(out["video_base64"])
        if blob is not None:
            out["video"] = blob
            del out["video_base64"]
    if images:
        out["images"] = images
    return out


def _transport(url: str, http: httpx.AsyncClient, timeout: float):
    """Streamable HTTP transport; mcp >= 1.24 has streamable_http_client, older ones only streamablehttp_client."""
    from mcp.client import streamable_http as sh
    if hasattr(sh, "streamable_http_client"):
        return sh.streamable_http_client(url, http_client=http)
    return sh.streamablehttp_client(url, timeout=timeout, sse_read_timeout=max(timeout, 300.0))


class StudioBridge:
    """One MCP session with the Studio Bridge, linked to one Studio session, with the PlaceId guard."""

    def __init__(self, url: str = DEFAULT_URL, allow_place_ids: set[str] | None = None,
                 protected_place_ids: set[str] = PROTECTED_PLACE_IDS, *, session_token: str | None = None,
                 timeout: float = 120.0, place_marker: tuple[str, str] | None = None) -> None:
        """place_marker=("ServerStorage.CybusHarnessRun", run_id): also assert, inside Studio, that this
        instance's Value matches before any execution_run_luau runs. Use it for unpublished places (PlaceId 0),
        which the PlaceId alone cannot tell apart."""
        self.url = url
        self.allow_place_ids: frozenset[str] = frozenset(_norm_ids(allow_place_ids))
        self.protected_place_ids: frozenset[str] = frozenset(PROTECTED_PLACE_IDS | _norm_ids(protected_place_ids))
        self.place_marker = _check_marker(place_marker)
        self.session_token = session_token
        self.timeout = float(timeout)
        host = (urlparse(url).hostname or "").lower()
        self._local = host in {"localhost", "127.0.0.1", "::1"}
        self._session: Any = None
        self._runner: asyncio.Task | None = None
        self._closing: asyncio.Event | None = None
        self._locks: dict[str, tuple[asyncio.AbstractEventLoop, asyncio.Lock]] = {}
        self._specs: dict[str, dict] = {}
        self._window_cache: tuple[float, int | None] | None = None
        overlap = self.allow_place_ids & self.protected_place_ids
        if overlap:
            log.warning("allow_place_ids includes protected place(s) %s; they stay refused", sorted(overlap))

    # ---------------------------------------------------------------- connection

    @property
    def connected(self) -> bool:
        return self._session is not None

    def _lock(self, key: str) -> asyncio.Lock:
        loop = asyncio.get_running_loop()
        held = self._locks.get(key)
        if held is None or held[0] is not loop:
            held = (loop, asyncio.Lock())
            self._locks[key] = held
        return held[1]

    async def connect(self) -> None:
        """Open the MCP session, cache the tool list, and link to a Studio session (reads need the link)."""
        async with self._lock("connect"):
            if self._session is not None:
                return
            ready: asyncio.Future = asyncio.get_running_loop().create_future()
            self._closing = asyncio.Event()
            self._runner = asyncio.create_task(self._run(ready), name="studio-bridge-mcp")
            try:
                await ready
            except Exception as e:
                self._runner = None
                raise StudioError(f"cannot connect to the Studio Bridge at {self.url}: {_describe(e)}") from e
            try:                              # inside the lock: a concurrent connect() returns only once linked
                await self.list_tools()
                await self._link()
            except BaseException:
                await self.close()
                raise

    async def _run(self, ready: asyncio.Future) -> None:
        # The MCP client is built on anyio task groups, which must be entered and exited by the same task.
        # This task owns them for the life of the connection; other tasks call through self._session.
        from mcp import ClientSession
        try:
            timeout = httpx.Timeout(self.timeout, connect=10.0)
            async with httpx.AsyncClient(timeout=timeout, follow_redirects=True) as http:
                async with _transport(self.url, http, self.timeout) as streams:
                    async with ClientSession(streams[0], streams[1],
                                             read_timeout_seconds=timedelta(seconds=self.timeout)) as session:
                        await session.initialize()
                        self._session = session
                        if not ready.done():
                            ready.set_result(None)
                        assert self._closing is not None
                        await self._closing.wait()
        except BaseException as e:  # noqa: BLE001 - reported through `ready` or the log, cancellation re-raised
            if not ready.done():
                ready.set_exception(e if isinstance(e, Exception) else StudioError(_describe(e)))
            elif not isinstance(e, asyncio.CancelledError):
                log.warning("Studio Bridge MCP session ended: %s", _describe(e))
            if isinstance(e, asyncio.CancelledError):
                raise
        finally:
            self._session = None

    async def close(self) -> None:
        runner, self._runner = self._runner, None
        if self._closing is not None:
            self._closing.set()
        if runner is not None:
            try:
                await asyncio.wait_for(runner, timeout=10)
            except BaseException as e:  # noqa: BLE001
                if isinstance(e, asyncio.CancelledError) and asyncio.current_task().cancelling():
                    raise
                log.debug("closing the bridge session: %s", _describe(e))
        self._session = None

    async def __aenter__(self) -> "StudioBridge":
        await self.connect()
        return self

    async def __aexit__(self, *exc: Any) -> None:
        await self.close()

    async def _reconnect(self) -> None:
        await self.close()
        await self.connect()

    async def _ensure_connected(self) -> None:
        if self._session is None:
            await self.connect()

    async def _link(self) -> dict:
        """Link this MCP session to a Studio session. Linking is server-side bookkeeping (it sets which
        plugin queue our commands go to) and changes nothing in Studio, so it is allowed for protected places:
        reads need it. Under the mutating lock, so it never lands between a guard check and its send."""
        async with self._lock("mutating"):
            status = await self._send("session_status", {})
            if status.get("connected"):
                return status
            sessions = status.get("available_sessions") or []
            token = self.session_token
            if token is None:
                if not sessions:
                    log.warning("no Studio is connected to the bridge; plugin tools will fail until one is")
                    return status
                if len(sessions) > 1:
                    allowed = [s for s in sessions
                               if _norm_place(s.get("place_id")) in self.allow_place_ids - self.protected_place_ids]
                    if len(allowed) != 1:
                        log.warning("%d Studio sessions on the bridge and no single allowed one; not linking",
                                    len(sessions))
                        return status
                    token = allowed[0].get("token")
            linked = await self._send("session_connect", {"token": token} if token else {})
            place = _norm_place(linked.get("place_id"))
            log.info("linked to Studio session %s (PlaceId %s%s)", str(linked.get("token", ""))[:8], place,
                     ", protected: read-only" if place in self.protected_place_ids else "")
            return linked

    # ---------------------------------------------------------------- tools and calls

    async def list_tools(self) -> list[dict]:
        """The bridge's tools as dicts {name, description, inputSchema}; cached for tools()."""
        await self._ensure_connected()
        from mcp.shared.exceptions import McpError
        found: list[dict] = []
        cursor = None
        try:
            while True:
                page = await (self._session.list_tools(cursor) if cursor else self._session.list_tools())
                found.extend(t.model_dump(mode="json", exclude_none=True) for t in page.tools)
                cursor = page.nextCursor
                if not cursor:
                    break
        except McpError as e:
            raise StudioError(f"list_tools: {e.error.message}") from e
        self._specs = {t["name"]: t for t in found}
        return found

    async def _send(self, name: str, args: dict) -> dict:
        """Send one tool call as is. No guard: callers go through call()."""
        import anyio
        from mcp.shared.exceptions import McpError
        session = self._session
        if session is None:
            raise _SessionLost("not connected", safe=True)
        try:
            res = await session.call_tool(name, args)
        except McpError as e:
            message = e.error.message or ""
            if e.error.code == 32600 and "terminated" in message.lower():   # HTTP 404: server forgot the session
                raise _SessionLost(message, safe=True) from e
            raise StudioError(f"{name}: {message}", tool=name, code=str(e.error.code)) from e
        except (anyio.ClosedResourceError, anyio.BrokenResourceError, anyio.EndOfStream) as e:
            raise _SessionLost(_describe(e), safe=False) from e
        return parse_result(name, res)

    async def call(self, name: str, args: dict | None = None) -> dict:
        """Call a bridge tool; mutating tools pass the guard first. Returns the parsed result (see module doc)."""
        args = dict(args or {})
        await self._ensure_connected()
        relinked = reconnected = False
        attempts = 0
        while True:
            attempts += 1
            try:
                return await self._call_once(name, args)
            except _SessionLost as e:
                if reconnected or not (e.safe or is_read_only(name)):
                    raise StudioError(f"{name}: lost the bridge session ({e}); not resent because it may have run",
                                      tool=name) from e
                reconnected = True
                log.info("bridge session lost (%s); reconnecting", e)
                await self._reconnect()
            except StudioRefused:
                raise
            except StudioError as e:
                if e.code == "BRIDGE_NO_SESSION" and not relinked:
                    relinked = True      # e.g. Studio was opened after connect(); the request never ran
                    await self._link()
                    continue
                if name in PLACE_ASSERTED and WRONG_PLACE in str(e) and attempts < _WRONG_PLACE_ATTEMPTS:
                    log.warning("%s landed in another Studio window and did nothing; resending", name)
                    continue
                raise

    async def _call_once(self, name: str, args: dict) -> dict:
        if is_read_only(name):
            return await self._send(name, args)
        async with self._lock("mutating"):
            place = await self._authorize(name, args)
            return await self._send(name, _with_place_assertion(name, args, place, self.place_marker))

    async def active_place_id(self) -> str | None:
        """PlaceId of the Studio session this client is linked to, from the bridge's own session registry.
        When not linked, the single connected Studio's PlaceId; None when unknown or ambiguous."""
        if self._session is not None:
            try:
                status = await self._send("session_status", {})
            except (StudioError, _SessionLost) as e:
                log.debug("session_status failed (%s); falling back to /health", e)
            else:
                if status.get("connected"):
                    return _norm_place(status.get("place_id"))
                sessions = status.get("available_sessions") or []
                return _norm_place(sessions[0].get("place_id")) if len(sessions) == 1 else None
        try:
            sessions = (await self.health()).get("session_list") or []
        except (httpx.HTTPError, ValueError) as e:
            log.warning("cannot read the bridge /health: %s", e)
            return None
        return _norm_place(sessions[0].get("place_id")) if len(sessions) == 1 else None

    async def guard(self, name: str, args: dict | None = None) -> None:
        """Raise StudioRefused unless `name` may run now. Read-only tools always may."""
        await self._authorize(name, args or {})

    async def _authorize(self, name: str, args: dict) -> str:
        """The guard. Returns the verified PlaceId for mutating tools ('' for read-only ones)."""
        if name in BLOCKED:
            raise self._refuse(name, "it is blocked for the harness: it closes every Studio on this machine or "
                                     "writes to live Roblox services")
        if is_read_only(name):
            return ""
        hit = _mentions(args, self.protected_place_ids)
        if hit:
            raise self._refuse(name, f"its arguments mention protected PlaceId {hit}")
        place = await self.active_place_id()
        if place is None:
            raise self._refuse(name, "the active Studio PlaceId is unknown (no Studio linked, several sessions, "
                                     "or a session that registered as 'unknown')")
        if place in self.protected_place_ids:
            raise self._refuse(name, f"the active Studio is PlaceId {place}, which is protected")
        if place not in self.allow_place_ids:
            raise self._refuse(name, f"the active Studio is PlaceId {place}, which is not in this run's allow-list "
                                     f"{sorted(self.allow_place_ids) or '(empty)'}")
        if name not in PLACE_ASSERTED:
            windows = await self._studio_windows()
            if windows is not None and windows > 1:
                raise self._refuse(name, f"{windows} Studio windows are open and share the bridge token, so this "
                                         "command could run in any of them; close the others (execution_run_luau "
                                         "is still allowed: it checks the PlaceId inside Studio)")
        return place

    def _refuse(self, name: str, why: str) -> StudioRefused:
        log.warning("refused %s: %s", name, why)
        return StudioRefused(f"refused {name}: {why}", tool=name, code="REFUSED")

    async def _studio_windows(self) -> int | None:
        if not self._local:
            return None
        now = time.monotonic()
        if self._window_cache and now - self._window_cache[0] < _WINDOW_CACHE_SECONDS:
            return self._window_cache[1]
        count = await asyncio.to_thread(count_studio_processes)
        self._window_cache = (now, count)
        return count

    async def health(self) -> dict:
        """GET /health: {status, sessions, session_list: [{token, place_id, ...}], tools_registered}."""
        parts = urlparse(self.url)
        url = parts._replace(path="/health", params="", query="", fragment="").geturl()
        async with httpx.AsyncClient(timeout=10.0) as http:
            resp = await http.get(url)
            resp.raise_for_status()
            return resp.json()

    # ---------------------------------------------------------------- agent tools

    def tools(self, allow: list[str] | None = None) -> list["Tool"]:
        """Bridge tools as harness Tools, with the bridge's own JSON schemas. `allow` takes names or fnmatch
        patterns (e.g. "instance_*"); None gives AGENT_DEFAULT. Session control and blocked tools are never
        included. Every call goes through call(), so mutating tools pass the guard inside fn."""
        from harness.tools.base import Tool
        if not self._specs:
            raise StudioError("no tool list yet: await bridge.connect() before bridge.tools()")
        explicit = allow is not None
        names: list[str] = []
        for pattern in (allow if explicit else AGENT_DEFAULT):
            if any(ch in pattern for ch in "*?["):
                matched = [n for n in self._specs if fnmatch.fnmatchcase(n, pattern)
                           and n not in CONTROL and n not in BLOCKED]
                if not matched:
                    raise ValueError(f"no bridge tool matches {pattern!r}")
            else:
                if pattern in CONTROL or pattern in BLOCKED:
                    raise ValueError(f"{pattern} cannot be given to agents (session control or blocked)")
                if pattern not in self._specs:
                    if explicit:
                        raise ValueError(f"the bridge has no tool named {pattern!r}")
                    continue                     # an older bridge without one of the defaults
                matched = [pattern]
            names.extend(n for n in matched if n not in names)

        out: list[Tool] = []
        for name in names:
            spec = self._specs[name]
            params = {k: v for k, v in (spec.get("inputSchema") or {}).items() if k != "$schema"}
            params.setdefault("type", "object")
            params.setdefault("properties", {})
            out.append(Tool(name=name, description=spec.get("description") or name, parameters=params,
                            fn=self._tool_fn(name), mutating=is_mutating(name)))
        return out

    def _tool_fn(self, name: str):
        async def fn(**kwargs: Any) -> "ToolResult":
            return await self._run_tool(name, kwargs)
        fn.__name__ = name
        return fn

    async def _run_tool(self, name: str, args: dict) -> "ToolResult":
        from harness.tools.base import ToolResult
        try:
            data = await self.call(name, args)
        except StudioRefused as e:
            return ToolResult(text=f"REFUSED: {e}", data={"error": str(e), "refused": True})
        except StudioError as e:
            return ToolResult(text=f"ERROR: {e}", data={"error": str(e), "code": e.code})
        images = list(data.pop("images", None) or [])
        video = data.pop("video", None)
        shown = dict(data)
        if images:
            shown["images"] = f"{len(images)} image(s) attached"
        if video is not None:
            shown["video"] = f"<{len(video)} bytes of mp4, not shown>"
        text = json.dumps(shown, ensure_ascii=False, default=str)
        return ToolResult(text=text, images=images, data=data)


__all__ = [
    "AGENT_DEFAULT", "BLOCKED", "CONTROL", "DEFAULT_URL", "PLACE_ASSERTED", "PROTECTED_PLACE_IDS", "READ_ONLY",
    "StudioBridge", "StudioError", "StudioRefused", "WRONG_PLACE", "count_studio_processes", "is_mutating",
    "is_read_only", "parse_result", "place_assertion",
]

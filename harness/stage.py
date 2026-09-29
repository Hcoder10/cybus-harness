"""Stage: the one Studio a build run owns, driven serially.

Studio is a single, shared, stateful resource, so every visit goes through `Stage.lock`: sync the workspace,
start a play session, drive the game through the kit's debug relay, capture what a player sees, stop.

How the harness reaches a running game: the bridge's play mode runs the game in a DataModel the bridge cannot
see. So the game comes to us instead. The kit's Debug module (Studio only) long-polls a localhost endpoint this
module serves, runs server commands itself and relays client commands to every client. Commands show screens,
trigger moments, move the camera, and return logs, events and stats.

Place safety: the run's place is a fresh local file built from a template that carries a marker
(ServerStorage.CybusHarnessRun = run id). Unpublished places all have PlaceId 0, so the marker, not the
PlaceId, is what proves a Studio window is ours; StudioBridge checks it inside Studio on every code write.
"""
from __future__ import annotations

import asyncio
import io
import json
import logging
import math
import os
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import uuid
from contextlib import asynccontextmanager
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from PIL import Image

from harness.tools import capture
from harness.tools.luau import check_sources, syntax_errors

log = logging.getLogger("harness.stage")

MARKER_NAME = "CybusHarnessRun"
POLL_SECONDS = 15.0


class StageError(RuntimeError):
    pass


# ------------------------------------------------------------------------------------------------ command server

def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class CommandServer:
    """Localhost endpoint the game's Debug module polls: GET /cybus/next (long poll), POST /cybus/result,
    POST /cybus/hello. Only requests carrying this run's token are served."""

    def __init__(self, token: str, port: int = 0) -> None:
        self.token = token
        self.port = port or free_port()
        self._queue: asyncio.Queue[dict] = asyncio.Queue()
        self._results: dict[str, asyncio.Future] = {}
        self.hello = asyncio.Event()
        self.last_hello: dict | None = None
        self._server = None
        self._task: asyncio.Task | None = None

    async def start(self) -> None:
        import uvicorn
        config = uvicorn.Config(self, host="127.0.0.1", port=self.port, log_level="warning", lifespan="off",
                                access_log=False)
        self._server = uvicorn.Server(config)
        self._task = asyncio.create_task(self._server.serve(), name="stage-command-server")
        for _ in range(100):
            if self._server.started:
                return
            await asyncio.sleep(0.05)
        raise StageError(f"command server did not start on port {self.port}")

    async def stop(self) -> None:
        if self._server:
            self._server.should_exit = True
        if self._task:
            try:
                await asyncio.wait_for(self._task, 5)
            except (asyncio.TimeoutError, asyncio.CancelledError):
                self._task.cancel()

    def reset(self) -> None:
        """Forget queued commands and the last hello (a new play session starts clean)."""
        while not self._queue.empty():
            self._queue.get_nowait()
        for fut in self._results.values():
            if not fut.done():
                fut.set_exception(StageError("play session ended before the command answered"))
        self._results.clear()
        self.hello.clear()

    async def call(self, name: str, *args: Any, timeout: float = 30.0) -> dict:
        cid = uuid.uuid4().hex
        fut = asyncio.get_running_loop().create_future()
        self._results[cid] = fut
        await self._queue.put({"id": cid, "name": name, "args": list(args)})
        try:
            return await asyncio.wait_for(fut, timeout)
        except asyncio.TimeoutError as e:
            raise StageError(f"game did not answer command {name!r} within {timeout:.0f}s") from e
        finally:
            self._results.pop(cid, None)

    async def __call__(self, scope, receive, send) -> None:           # ASGI
        if scope["type"] != "http":
            return
        path, method = scope.get("path", ""), scope.get("method", "GET")
        query = dict(p.split("=", 1) for p in scope.get("query_string", b"").decode().split("&") if "=" in p)
        body = b""
        while True:
            msg = await receive()
            body += msg.get("body", b"")
            if not msg.get("more_body"):
                break
        data: dict = {}
        if body:
            try:
                data = json.loads(body)
            except ValueError:
                data = {}
        token = query.get("token") or data.get("token")
        if token != self.token:
            await self._reply(send, 403, {"error": "bad token"})
            return
        if path == "/cybus/next" and method == "GET":
            try:
                cmd = await asyncio.wait_for(self._queue.get(), POLL_SECONDS)
            except asyncio.TimeoutError:
                cmd = {}
            await self._reply(send, 200, cmd)
        elif path == "/cybus/result" and method == "POST":
            fut = self._results.get(str(data.get("id")))
            if fut and not fut.done():
                fut.set_result(data.get("result") if isinstance(data.get("result"), dict) else {"result": data.get("result")})
            await self._reply(send, 200, {"ok": True})
        elif path == "/cybus/hello" and method == "POST":
            self.last_hello = data
            self.hello.set()
            await self._reply(send, 200, {"ok": True})
        else:
            await self._reply(send, 404, {"error": "not found"})

    @staticmethod
    async def _reply(send, status: int, obj: dict) -> None:
        raw = json.dumps(obj).encode()
        await send({"type": "http.response.start", "status": status,
                    "headers": [(b"content-type", b"application/json"), (b"content-length", str(len(raw)).encode())]})
        await send({"type": "http.response.body", "body": raw})


# ------------------------------------------------------------------------------------------------ Studio process

def studio_exe() -> Path | None:
    """The Studio executable: the running one if any, else the newest installed version."""
    if sys.platform != "win32":
        return None
    try:
        out = subprocess.run(["powershell", "-NoProfile", "-Command",
                              "(Get-Process RobloxStudioBeta -ErrorAction SilentlyContinue | Select-Object -First 1).Path"],
                             capture_output=True, text=True, timeout=20,
                             creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0)).stdout.strip()
        if out and Path(out).exists():
            return Path(out)
    except (OSError, subprocess.SubprocessError):
        pass
    versions = Path(os.environ.get("LOCALAPPDATA", "")) / "Roblox" / "Versions"
    found = sorted(versions.glob("*/RobloxStudioBeta.exe"), key=lambda p: p.stat().st_mtime, reverse=True)
    return found[0] if found else None


def maximize_windows_of(pid: int) -> int:
    """Best effort: maximize the top-level windows of a process so captures are large. Returns how many."""
    if sys.platform != "win32":
        return 0
    import ctypes
    from ctypes import wintypes
    user32 = ctypes.windll.user32
    hits: list[int] = []

    @ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    def cb(hwnd, _):
        owner = wintypes.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(owner))
        if owner.value == pid and user32.IsWindowVisible(hwnd) and user32.GetWindowTextLengthW(hwnd) > 0:
            hits.append(hwnd)
        return True

    user32.EnumWindows(cb, 0)
    for hwnd in hits:
        user32.ShowWindow(hwnd, 3)          # SW_MAXIMIZE
    return len(hits)


def build_template(run_id: str, out: Path) -> Path:
    """A fresh local place carrying the run marker, built with rojo (falls back to a hand-written rbxlx)."""
    out.parent.mkdir(parents=True, exist_ok=True)
    project = {"name": f"cybus_{run_id}", "tree": {
        "$className": "DataModel",
        "ServerStorage": {"$className": "ServerStorage",
                          MARKER_NAME: {"$className": "StringValue", "$properties": {"Value": run_id}}},
        "HttpService": {"$className": "HttpService", "$properties": {"HttpEnabled": True}},
        "Workspace": {"$className": "Workspace",
                      "SpawnLocation": {"$className": "SpawnLocation",
                                        "$properties": {"Anchored": True, "Size": [12, 1, 12], "Position": [0, 0.5, 0]}}},
    }}
    rojo = shutil.which("rojo") or str(Path.home() / "bin" / "rojo.exe")
    with tempfile.TemporaryDirectory(prefix="cybus_tpl_") as d:
        (Path(d) / "default.project.json").write_text(json.dumps(project), encoding="utf-8")
        try:
            subprocess.run([rojo, "build", "-o", str(out)], cwd=d, check=True, capture_output=True, timeout=60,
                           creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            return out
        except (OSError, subprocess.SubprocessError) as e:
            log.warning("rojo build failed (%s); writing the template by hand", e)
    out.write_text(f"""<roblox version="4">
  <Item class="HttpService" referent="0"><Properties><string name="Name">HttpService</string><bool name="HttpEnabled">true</bool></Properties></Item>
  <Item class="ServerStorage" referent="1"><Properties><string name="Name">ServerStorage</string></Properties>
    <Item class="StringValue" referent="2"><Properties><string name="Name">{MARKER_NAME}</string><string name="Value">{run_id}</string></Properties></Item>
  </Item>
  <Item class="Workspace" referent="3"><Properties><string name="Name">Workspace</string></Properties></Item>
</roblox>""", encoding="utf-8")
    return out


# ------------------------------------------------------------------------------------------------ images

def magenta_bbox(png: bytes) -> tuple[int, int, int, int] | None:
    """Bounding box of the kit's full-screen magenta marker in a Studio screenshot (the game viewport)."""
    with Image.open(io.BytesIO(png)) as im:
        rgb = im.convert("RGB")
        r, g, b = rgb.split()
        mask_r = r.point(lambda v: 255 if v > 225 else 0)
        mask_g = g.point(lambda v: 255 if v < 40 else 0)
        mask_b = b.point(lambda v: 255 if v > 225 else 0)
        from PIL import ImageChops
        mask = ImageChops.multiply(ImageChops.multiply(mask_r, mask_g), mask_b)
        box = mask.getbbox()
        if not box:
            return None
        w, h = box[2] - box[0], box[3] - box[1]
        if w * h < 0.1 * rgb.size[0] * rgb.size[1] or w < 320 or h < 180:
            return None
        return box


def crop_png(png: bytes, box: tuple[int, int, int, int] | None) -> bytes:
    if not box:
        return png
    with Image.open(io.BytesIO(png)) as im:
        out = io.BytesIO()
        im.crop(box).save(out, format="PNG")
        return out.getvalue()


def video_frames(mp4: bytes, n: int, seconds: float) -> list[bytes]:
    """n evenly spaced PNG frames from an MP4, via ffmpeg. Empty list if ffmpeg is missing or fails."""
    ff = shutil.which("ffmpeg")
    if not ff or n <= 0:
        return []
    with tempfile.TemporaryDirectory(prefix="cybus_vid_") as d:
        src = Path(d) / "clip.mp4"
        src.write_bytes(mp4)
        fps = max(0.5, (n - 1) / max(seconds, 0.1)) if n > 1 else 1
        try:
            subprocess.run([ff, "-loglevel", "error", "-i", str(src), "-vf", f"fps={fps:.4f}", "-frames:v", str(n),
                            str(Path(d) / "f%03d.png")], check=True, capture_output=True, timeout=120,
                           creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        except (OSError, subprocess.SubprocessError) as e:
            log.warning("ffmpeg frame extraction failed: %s", e)
            return []
        return [p.read_bytes() for p in sorted(Path(d).glob("f*.png"))][:n]


def parse_command(line: str) -> tuple[str, list]:
    """'grant_coins 500 true' -> ('grant_coins', [500, True]). Quoted strings stay strings."""
    parts = shlex.split(line.strip()) if line.strip() else []
    if not parts:
        return "", []
    args: list = []
    for p in parts[1:]:
        low = p.lower()
        if low in ("true", "false"):
            args.append(low == "true")
        else:
            try:
                args.append(int(p))
            except ValueError:
                try:
                    args.append(float(p))
                except ValueError:
                    args.append(p)
    return parts[0], args


# ------------------------------------------------------------------------------------------------ the stage

@dataclass
class Capture:
    label: str
    images: list[bytes] = field(default_factory=list)
    text: str = ""                                   # e.g. the audio manifest
    logs: list[dict] = field(default_factory=list)
    command_results: list[dict] = field(default_factory=list)
    sync: dict = field(default_factory=dict)
    error: str = ""

    def errors(self) -> list[str]:
        return [str(l.get("text", "")) for l in self.logs if l.get("kind") == "error"]


class Stage:
    def __init__(self, bridge, workspace, run_dir: Path, run_id: str) -> None:
        self.bridge = bridge
        self.ws = workspace
        self.run_dir = Path(run_dir)
        self.run_id = run_id
        self.token = uuid.uuid5(uuid.NAMESPACE_URL, f"cybus-harness/{run_id}").hex
        self.server = CommandServer(self.token)
        self.lock = asyncio.Lock()
        self.crop: tuple[int, int, int, int] | None = None
        self.viewport: tuple[int, int] | None = None
        self.captures_dir = self.run_dir / "captures"
        self.captures_dir.mkdir(parents=True, exist_ok=True)
        self._shots = 0
        self.playing = False

    # ---- lifecycle
    async def start(self) -> None:
        await self.server.start()

    async def close(self) -> None:
        if self.playing:
            try:
                await self.stop()
            except Exception as e:  # noqa: BLE001
                log.warning("stop on close failed: %s", e)
        await self.server.stop()

    async def launch(self, wait_seconds: float = 180) -> dict:
        """Open the run's own place in a new Studio. Refuses when another Studio is open: the bridge token is
        shared by every window, so commands could land in someone else's place."""
        from harness.tools.studio import count_studio_processes
        n = count_studio_processes()
        if n:
            raise StageError(f"{n} Roblox Studio window(s) already open. Close them (save your work first) so the "
                             "harness has the only Studio; it will open its own place.")
        place = build_template(self.run_id, self.run_dir / "place" / f"{self.run_id}.rbxlx")
        exe = studio_exe()
        if not exe:
            raise StageError("Roblox Studio is not installed (no RobloxStudioBeta.exe found)")
        flags = getattr(subprocess, "DETACHED_PROCESS", 0) | getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
        proc = subprocess.Popen([str(exe), str(place)], creationflags=flags, close_fds=True)
        deadline = time.monotonic() + wait_seconds
        while time.monotonic() < deadline:
            await asyncio.sleep(3)
            try:
                sessions = (await self.bridge.health()).get("session_list") or []
            except Exception:  # noqa: BLE001 - bridge restarting
                continue
            if any(str(s.get("place_id")) == "0" for s in sessions):
                break
        else:
            raise StageError(f"Studio did not connect to the bridge within {wait_seconds:.0f}s")
        await asyncio.sleep(2)
        maximize_windows_of(proc.pid)
        await self.bridge.close()
        await self.bridge.connect()
        await self.verify_place()
        return {"place": str(place), "pid": proc.pid}

    async def verify_place(self) -> None:
        """Prove the linked Studio holds this run's place (marker), then point its game at our endpoint."""
        code = (f'local m = game:GetService("ServerStorage"):FindFirstChild("{MARKER_NAME}")\n'
                f'if not m or m.Value ~= "{self.run_id}" then error("not this run\'s place", 0) end\n'
                'game:GetService("HttpService").HttpEnabled = true\n'
                f'game:GetService("ServerStorage"):SetAttribute("CybusHarnessPort", {self.server.port})\n'
                f'game:GetService("ServerStorage"):SetAttribute("CybusHarnessToken", "{self.token}")\n'
                'return "ok"')
        res = await self.bridge.call("execution_run_luau", {"code": code})
        if "ok" not in json.dumps(res):
            raise StageError(f"place verification failed: {res}")

    async def edit(self, code: str, timeout_ms: int = 20000) -> dict:
        """Run edit-mode Luau in the run's place (after proving the marker)."""
        guarded = (f'local m = game:GetService("ServerStorage"):FindFirstChild("{MARKER_NAME}")\n'
                   f'if not m or m.Value ~= "{self.run_id}" then error("not this run\'s place", 0) end\n') + code
        return await self.bridge.call("execution_run_luau", {"code": guarded, "timeout_ms": timeout_ms})

    # ---- code
    async def sync(self) -> dict:
        """Push changed files, holding back any file with a syntax error (the last good version stays live)."""
        changed = self.ws.changed()
        sources = {rel: self.ws.read(rel) for rel in changed}
        bad = syntax_errors(await check_sources(sources)) if sources else {}
        result = await self.ws.sync(self.bridge, exclude=set(bad)) if changed else {"pushed": []}
        result["held_back"] = bad
        return result

    # ---- play
    async def play(self, timeout: float = 90) -> None:
        self.server.reset()
        await self.bridge.call("playtest_start", {"mode": "play"})
        self.playing = True
        try:
            await asyncio.wait_for(self.server.hello.wait(), timeout)
        except asyncio.TimeoutError as e:
            raise StageError("the game never reached the harness: is KitBoot.server running, and HTTP enabled? "
                             "(check the output log for a boot error)") from e
        deadline = time.monotonic() + 30
        while True:                      # the client relay connects a moment after the server says hello
            try:
                r = await self.server.call("__marker", False, timeout=10)
                if r.get("ok"):
                    break
            except StageError:
                pass
            if time.monotonic() > deadline:
                raise StageError("no client answered the debug relay (did KitBoot.client run?)")
            await asyncio.sleep(1)
        if self.crop is None:
            await self.calibrate()

    async def stop(self) -> None:
        try:
            await self.bridge.call("playtest_stop", {})
        finally:
            self.playing = False
            self.server.reset()

    async def cmd(self, line_or_name: str, *args: Any, timeout: float = 30) -> dict:
        name, parsed = (line_or_name, list(args)) if args else parse_command(line_or_name)
        if not name:
            return {"ok": False, "result": "empty command"}
        return await self.server.call(name, *parsed, timeout=timeout)

    async def calibrate(self) -> None:
        r = await self.server.call("__marker", True)
        await asyncio.sleep(0.5)
        raw = await capture.screenshot(self.bridge)
        await self.server.call("__marker", False)
        (self.captures_dir / "_calibration.png").write_bytes(raw)
        self.crop = magenta_bbox(raw)
        vp = None
        for rep in r.get("replies") or []:
            try:
                vp = json.loads(rep.get("result") or "{}").get("viewport")
            except (TypeError, ValueError):
                pass
        self.viewport = tuple(vp) if vp else None
        if not self.crop:
            log.warning("could not find the viewport marker; captures will include Studio chrome")

    async def shot(self, label: str) -> bytes:
        png = crop_png(await capture.screenshot(self.bridge), self.crop)
        self._save(label, [png])
        return png

    async def strip(self, seconds: float, n: int, label: str) -> list[bytes]:
        frames: list[bytes] = []
        if shutil.which("ffmpeg"):
            try:
                start = await self.bridge.call("video_record_start", {
                    "max_duration_seconds": int(min(30, math.ceil(seconds) + 1)), "fps": 15, "quality": "high"})
                rid = start.get("recording_id")
                await asyncio.sleep(seconds + 0.3)
                stop = await self.bridge.call("video_record_stop", {"recording_id": rid})
                if stop.get("video"):
                    frames = video_frames(stop["video"], n, seconds)
            except Exception as e:  # noqa: BLE001 - fall back to timed screenshots
                log.warning("video strip failed (%s); using timed screenshots", e)
        if not frames:
            frames = await capture.frames(self.bridge, seconds, n)
        frames = [crop_png(f, self.crop) for f in frames]
        self._save(label, frames)
        return frames

    async def key(self, key: str, hold_ms: int = 0) -> dict:
        return await self.bridge.call("input_key", {"key": key, "action": "press", "hold_ms": hold_ms})

    async def logs(self) -> list[dict]:
        r = await self.server.call("__log")
        try:
            return json.loads(r.get("result") or "[]")
        except (TypeError, ValueError):
            return []

    async def events(self) -> list[dict]:
        r = await self.server.call("__events")
        try:
            return json.loads(r.get("result") or "[]")
        except (TypeError, ValueError):
            return []

    def _save(self, label: str, images: list[bytes]) -> None:
        safe = "".join(c if c.isalnum() or c in "-_." else "_" for c in label)[:80]
        for i, im in enumerate(images):
            self._shots += 1
            (self.captures_dir / f"{self._shots:04d}_{safe}_{i}.png").write_bytes(im)

    @asynccontextmanager
    async def session(self):
        """Hold Studio: sync, play; always stop afterwards. Yields the sync result."""
        async with self.lock:
            synced = await self.sync()
            await self.play()
            try:
                yield synced
            finally:
                await self.stop()

    async def capture(self, label: str, kind: str, commands: list[str], *, strip_seconds: float = 2.5,
                      strip_n: int = 8, settle: float = 1.2) -> Capture:
        """One visit: run the item's debug commands, then capture it the way its kind needs."""
        cap = Capture(label=label)
        try:
            async with self.session() as synced:
                cap.sync = synced
                for line in commands:
                    try:
                        cap.command_results.append({"command": line, **(await self.cmd(line))})
                    except StageError as e:
                        cap.command_results.append({"command": line, "ok": False, "result": str(e)})
                if kind == "audio":
                    r = await self.cmd("__sound_manifest")
                    cap.text = json.dumps(r.get("replies") or r, ensure_ascii=False)[:12000]
                    await asyncio.sleep(settle)
                    cap.images = [await self.shot(label)]
                elif kind in ("moment", "loop"):
                    cap.images = await self.strip(strip_seconds if kind == "moment" else max(strip_seconds, 6.0),
                                                  strip_n if kind == "moment" else max(strip_n, 12), label)
                else:
                    await asyncio.sleep(settle)
                    cap.images = [await self.shot(label)]
                    await asyncio.sleep(1.5)                  # a second look catches entrances and idle motion
                    cap.images.append(await self.shot(label + "_later"))
                cap.logs = await self.logs()
        except Exception as e:  # noqa: BLE001 - a failed capture is data for the fixer, not a crash
            cap.error = f"{type(e).__name__}: {e}"
            log.warning("capture %s failed: %s", label, cap.error)
        return cap

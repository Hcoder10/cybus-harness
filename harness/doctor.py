"""Preflight: is everything a live build needs actually here? `python -m harness.doctor`

Checks, cheapest first: local tools (luau-analyze, ffmpeg, rojo), disk space, the Studio Bridge and how many
Studio windows are open, and every model role's endpoint (reachable, answers, and can see an image).
Prints one line per check and exits non-zero when something a build needs is missing.
"""
from __future__ import annotations

import argparse
import asyncio
import io
import os
import shutil
import sys
from pathlib import Path

ROLES = ("lead", "art", "builder", "critic", "judge")


def _ok(name: str, good: bool, detail: str) -> bool:
    print(f"[{'ok' if good else 'FAIL'}] {name}: {detail}")
    return good


async def check_llm(role: str) -> bool:
    from harness.llm import LLM, Message, image_part, llm_from_env, text_part
    try:
        llm = llm_from_env(role)
    except Exception as e:  # noqa: BLE001
        return _ok(f"model:{role}", False, f"not configured ({e}); set HARNESS_{role.upper()}_BASE_URL/_MODEL "
                                           "or HARNESS_DEFAULT_*")
    from PIL import Image
    buf = io.BytesIO()
    im = Image.new("RGB", (64, 64), (220, 30, 30))
    im.save(buf, format="PNG")
    try:
        r = await llm.chat([Message("user", [text_part("What colour fills this image? One word."),
                                             image_part(buf.getvalue())])])
        text = r.message.content if isinstance(r.message.content, str) else str(r.message.content)
        sees = "red" in text.lower()
        return _ok(f"model:{role}", sees, f"{llm.model} answered {text.strip()[:40]!r}"
                   + ("" if sees else " (vision may be off: the image was red)"))
    except Exception as e:  # noqa: BLE001
        return _ok(f"model:{role}", False, f"{llm.model} failed: {e}")
    finally:
        try:
            await llm.aclose()
        except Exception:  # noqa: BLE001
            pass


async def check_bridge(url: str) -> tuple[bool, bool]:
    from harness.tools.studio import StudioBridge, count_studio_processes
    b = StudioBridge(url)
    try:
        h = await b.health()
    except Exception as e:  # noqa: BLE001
        return _ok("studio bridge", False, f"{url} unreachable ({e}); start the bridge server"), False
    sessions = h.get("session_list") or []
    _ok("studio bridge", True, f"{h.get('tools_registered')} tools, {len(sessions)} Studio session(s): "
        + ", ".join(str(s.get("place_id")) for s in sessions))
    n = count_studio_processes()
    free = n == 0
    _ok("studio windows", free, "none open: a build can launch its own place" if free else
        f"{n} open: close them before a live build (the bridge token is shared between windows)")
    return True, free


async def main_async(args) -> int:
    from harness.tools.luau import analyzer
    need = []
    need.append(_ok("luau-analyze", analyzer() is not None, analyzer() or "missing: set HARNESS_LUAU_ANALYZE"))
    need.append(_ok("ffmpeg", bool(shutil.which("ffmpeg")), shutil.which("ffmpeg") or "missing: strips fall back to "
                                                                                       "timed screenshots"))
    rojo = shutil.which("rojo") or (str(Path.home() / "bin" / "rojo.exe") if (Path.home() / "bin" / "rojo.exe").exists() else None)
    _ok("rojo", bool(rojo), rojo or "missing: the place template is written by hand instead")
    free_gb = shutil.disk_usage(Path(args.run_root).anchor or ".").free / 1e9
    need.append(_ok("disk", free_gb > 3, f"{free_gb:.1f} GB free on {Path(args.run_root).anchor} (a build writes "
                                         "~0.2-0.5 GB of captures and logs)"))
    if not args.no_studio:
        up, free = await check_bridge(args.bridge)
        need += [up, free]
    if not args.no_models:
        roles = [r for r in ROLES if os.environ.get(f"HARNESS_{r.upper()}_BASE_URL") or
                 os.environ.get("HARNESS_DEFAULT_BASE_URL")]
        if not roles:
            need.append(_ok("models", False, "no HARNESS_<ROLE>_BASE_URL or HARNESS_DEFAULT_BASE_URL set"))
        for r in roles:
            need.append(await check_llm(r))
    ok = all(need)
    print("\nready for a live build" if ok else "\nnot ready: fix the FAIL lines above")
    return 0 if ok else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--bridge", default="http://localhost:3000/mcp")
    ap.add_argument("--run-root", default=str(Path.cwd()))
    ap.add_argument("--no-studio", action="store_true")
    ap.add_argument("--no-models", action="store_true")
    return asyncio.run(main_async(ap.parse_args()))


if __name__ == "__main__":
    sys.exit(main())

"""Image generation for game art, and getting that art into the game.

Providers (HARNESS_IMAGEGEN_PROVIDER):
  openai  GPT Image through the OpenAI Images API (OPENAI_API_KEY; HARNESS_OPENAI_IMAGE_MODEL, default gpt-image-2)
  http    an image service speaking {prompt, kind, transparent, ...} -> {png_b64, width, height, slice_center}
          at HARNESS_IMAGEGEN_URL (e.g. a Qwen-Image server)
  none    no image generation: builders make art from UI objects and parts

Delivery (AssetStore): every image is saved under the run, installed into the running Studio's local content
folder (rbxasset://cybus/<run>/<name>.png, which loads in Studio play sessions), and listed in the game's
generated ReplicatedStorage.Shared.AssetMap module. Shipping a game means uploading these files as Roblox assets
(with the studio's own Open Cloud credentials) and rewriting AssetMap to the rbxassetid:// ids.
"""
from __future__ import annotations

import asyncio
import base64
import io
import json
import logging
import os
import re
import shutil
from pathlib import Path

import httpx
from PIL import Image

log = logging.getLogger("harness.imagegen")

KIND_HINTS = {
    "icon": "a single game UI icon, bold silhouette that reads at 48 px, centered, no text",
    "item": "a single game item illustration, clear silhouette, centered, no text",
    "character": "a single game character, full body, clear silhouette, expressive pose, centered",
    "portrait": "a game character portrait, head and shoulders, centered, no text",
    "panel": "a game UI panel texture, front view, decorative border around a large plain empty center, symmetrical, no text",
    "button": "an empty game UI button skin, horizontal, no text",
    "banner": "an empty game UI title banner, horizontal, no text",
    "background": "a game menu background illustration, calm composition that sits behind UI, no text",
    "texture": "a seamless tileable surface texture, flat lighting, no text",
    "vfx": "a single game visual-effect sprite (flash, spark, smoke puff, slash, ring), centered, on transparent background",
    "logo": "a game title logo lockup, bold display lettering, centered",
}
OPAQUE = {"background", "texture"}
SLICE = {"panel", "button", "banner"}
_NAME = re.compile(r"[^a-z0-9_]+")


def safe_name(name: str) -> str:
    n = _NAME.sub("_", str(name).lower()).strip("_")
    return n[:60] or "art"


class ImageGen:
    def __init__(self, provider: str | None = None) -> None:
        self.provider = (provider or os.environ.get("HARNESS_IMAGEGEN_PROVIDER", "none")).lower()
        self.model = os.environ.get("HARNESS_OPENAI_IMAGE_MODEL", "gpt-image-2")
        self.url = os.environ.get("HARNESS_IMAGEGEN_URL", "").rstrip("/")
        self._sem = asyncio.Semaphore(int(os.environ.get("HARNESS_IMAGEGEN_CONCURRENCY", "3")))

    @property
    def enabled(self) -> bool:
        if self.provider == "openai":
            return bool(os.environ.get("OPENAI_API_KEY"))
        if self.provider == "http":
            return bool(self.url)
        return False

    def brief(self, prompt: str, kind: str, style: str = "") -> str:
        hint = KIND_HINTS.get(kind, "")
        s = f" Art direction: {style.strip()}" if style.strip() else ""
        return f"{prompt.strip().rstrip('.')}. {hint}.{s}"

    async def generate(self, prompt: str, kind: str = "icon", style: str = "", transparent: bool | None = None) -> dict:
        """-> {png: bytes, width, height, slice_center: [l, t, r, b] | None}"""
        if not self.enabled:
            raise RuntimeError("image generation is not configured (HARNESS_IMAGEGEN_PROVIDER)")
        transparent = (kind not in OPAQUE) if transparent is None else transparent
        text = self.brief(prompt, kind, style)
        async with self._sem:
            if self.provider == "openai":
                out = await self._openai(text, kind, transparent)
            else:
                out = await self._http(text, kind, transparent)
        if kind in SLICE and not out.get("slice_center"):
            out["slice_center"] = guess_slice(out["png"])
        return out

    async def _openai(self, text: str, kind: str, transparent: bool) -> dict:
        body = {"model": self.model, "prompt": text + (". Isolated on a transparent background, no backdrop, no cast "
                                                       "shadow." if transparent else ""),
                "n": 1, "size": "1536x1024" if kind in ("background", "banner", "button", "logo") else "1024x1024"}
        if transparent:
            body["background"] = "transparent"
        async with httpx.AsyncClient(timeout=600) as http:
            r = await http.post("https://api.openai.com/v1/images/generations", json=body,
                                headers={"Authorization": f"Bearer {os.environ['OPENAI_API_KEY']}"})
            if r.status_code >= 400:
                raise RuntimeError(f"OpenAI images {r.status_code}: {r.text[:300]}")
            png = base64.b64decode(r.json()["data"][0]["b64_json"])
        with Image.open(io.BytesIO(png)) as im:
            w, h = im.size
        return {"png": png, "width": w, "height": h, "slice_center": None}

    async def _http(self, text: str, kind: str, transparent: bool) -> dict:
        async with httpx.AsyncClient(timeout=900) as http:
            r = await http.post(f"{self.url}/generate", json={"prompt": text, "kind": kind, "transparent": transparent,
                                                              "out_size": 1024})
            if r.status_code >= 400:
                raise RuntimeError(f"image service {r.status_code}: {r.text[:300]}")
            d = r.json()
        return {"png": base64.b64decode(d["png_b64"]), "width": d.get("width"), "height": d.get("height"),
                "slice_center": d.get("slice_center")}


def guess_slice(png: bytes) -> list[int] | None:
    """A conservative 9-slice centre: a quarter of each side as the border."""
    try:
        with Image.open(io.BytesIO(png)) as im:
            w, h = im.size
    except OSError:
        return None
    bx, by = max(4, w // 4), max(4, h // 4)
    return [bx, by, w - bx, h - by]


class AssetStore:
    """Generated art for one run: files on disk, installed into Studio's content folder, and the AssetMap module."""

    MAP_PATH = "ReplicatedStorage/Shared/AssetMap.luau"

    def __init__(self, run_dir: Path, workspace, run_id: str, studio_exe: Path | None = None) -> None:
        self.dir = Path(run_dir) / "art"
        self.dir.mkdir(parents=True, exist_ok=True)
        self.ws = workspace
        self.run_id = safe_name(run_id)
        self.studio_exe = studio_exe
        self.index_file = self.dir / "assets.json"
        try:
            self.assets: dict[str, dict] = json.loads(self.index_file.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            self.assets = {}

    def content_dir(self) -> Path | None:
        if not self.studio_exe:
            return None
        return Path(self.studio_exe).parent / "content" / "cybus" / self.run_id

    def add(self, name: str, png: bytes, *, kind: str = "", prompt: str = "", slice_center=None) -> str:
        name = safe_name(name)
        path = self.dir / f"{name}.png"
        path.write_bytes(png)
        cid = f"rbxasset://cybus/{self.run_id}/{name}.png"
        self.assets[name] = {"id": cid, "file": str(path), "kind": kind, "prompt": prompt[:500],
                             "slice": slice_center}
        self._install(name)
        self._write_index()
        return cid

    def _install(self, name: str) -> None:
        d = self.content_dir()
        if d is None:
            return
        try:
            d.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(self.dir / f"{name}.png", d / f"{name}.png")
        except OSError as e:
            log.warning("could not install %s into Studio content: %s", name, e)

    def reinstall(self) -> None:
        for name in self.assets:
            self._install(name)

    def _write_index(self) -> None:
        self.index_file.write_text(json.dumps(self.assets, indent=1), encoding="utf-8")
        lines = ["-- Generated by cybus-harness: generated art by name. Use Kit.Assets.image(name).", "return {"]
        for name, a in sorted(self.assets.items()):
            sl = a.get("slice")
            slice_s = f", slice = {{ {', '.join(str(int(v)) for v in sl)} }}" if sl else ""
            lines.append(f'\t{name} = {{ id = "{a["id"]}"{slice_s} }},')
        lines.append("}")
        self.ws.write(self.MAP_PATH, "\n".join(lines) + "\n")

    def ensure_map(self) -> None:
        self._write_index()

    def listing(self) -> str:
        return "\n".join(f"- {n} ({a.get('kind', '')}): {a.get('prompt', '')[:80]}" for n, a in sorted(self.assets.items()))

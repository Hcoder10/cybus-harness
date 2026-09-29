"""Seeing the game: Studio screenshots, frame strips over time, and contact sheets for the judges.

What the bridge returns:
  screenshot_take  -> {"image_base64": <PNG or JPEG>, "width", "height", "format"}. StudioBridge.call() lifts
                      the image into result["images"][0] as bytes. It captures the largest visible Roblox Studio
                      window on the machine, which is not necessarily the linked session's window. A minimized
                      window comes back as its title stub (237x39 on the dev box), which screenshot() refuses.
  video_record_*   -> start gives {"recording_id", "status"}; stop gives {"video_base64": <MP4>,
                      "duration_seconds", "file_size_bytes", "format": "mp4"} (call() turns it into
                      result["video"] bytes). That is an encoded MP4, never frames, and decoding it would
                      need ffmpeg, so frames() takes timed screenshots instead.
"""
from __future__ import annotations

import asyncio
import io
import math
import time
from typing import Any

from PIL import Image, ImageDraw, ImageFont

PNG_MAGIC = b"\x89PNG\r\n\x1a\n"
MIN_CAPTURE = (320, 180)      # smaller than this is not a usable view of the game
PAD = 8                      # contact sheet: gap between cells and around the edge, in pixels
BACKGROUND = (18, 18, 20)
LABEL_COLOR = (235, 235, 235)


async def screenshot(bridge: Any, **kw: Any) -> bytes:
    """One screenshot of Studio as PNG bytes (JPEG only if format="jpeg" is asked for explicitly).

    Other keywords go to screenshot_take, except min_size=(w, h) (default MIN_CAPTURE, None to skip): a smaller
    capture raises StudioError, because a minimized Studio window captures as its ~240x40 title stub, and a
    judge shown that would score garbage."""
    from harness.tools.studio import StudioError
    min_size = kw.pop("min_size", MIN_CAPTURE)
    kw.setdefault("format", "png")
    result = await bridge.call("screenshot_take", kw)
    images = result.get("images") or []
    if images:
        data = images[0]
    elif isinstance(result.get("image_base64"), str):
        import base64
        data = base64.b64decode(result["image_base64"])
    else:
        raise StudioError(f"screenshot_take returned no image (keys: {sorted(result)})", tool="screenshot_take")
    if min_size:
        with Image.open(io.BytesIO(data)) as im:
            size = im.size
        if size[0] < min_size[0] or size[1] < min_size[1]:
            raise StudioError(f"screenshot_take captured only {size[0]}x{size[1]} px: the Studio window is "
                              f"minimized or hidden; restore it and retry", tool="screenshot_take", code="TINY_CAPTURE")
    if kw["format"] == "png" and not data.startswith(PNG_MAGIC):
        data = to_png(data)
    return data


async def frames(bridge: Any, seconds: float, n: int) -> list[bytes]:
    """n PNG frames spread evenly over `seconds` (first at once, last at `seconds`).

    The bridge's video tools return an encoded MP4, not frames (see the module doc), so these are timed
    screenshots, scheduled on absolute times so a slow capture does not push the later ones back."""
    if n <= 0:
        return []
    step = seconds / (n - 1) if n > 1 else 0.0
    start = time.monotonic()
    shots: list[bytes] = []
    for i in range(n):
        delay = start + i * step - time.monotonic()
        if delay > 0:
            await asyncio.sleep(delay)
        shots.append(await screenshot(bridge))
    return shots


def to_png(data: bytes) -> bytes:
    with Image.open(io.BytesIO(data)) as im:
        buf = io.BytesIO()
        im.save(buf, format="PNG")
        return buf.getvalue()


def _label_font_px(cell_w: int) -> int:
    return max(12, min(28, cell_w // 16))


def _font(px: int) -> ImageFont.ImageFont | ImageFont.FreeTypeFont:
    try:
        return ImageFont.load_default(size=px)
    except TypeError:          # Pillow < 10.1: fixed-size bitmap font
        return ImageFont.load_default()


def _fit(draw: ImageDraw.ImageDraw, text: str, font: Any, max_w: int) -> str:
    if draw.textlength(text, font=font) <= max_w:
        return text
    while text and draw.textlength(text + "...", font=font) > max_w:
        text = text[:-1]
    return text + "..."


def contact_sheet(images: list[bytes], cols: int = 4, width: int = 1280, labels: list[str] | None = None) -> bytes:
    """Tile images into one PNG exactly `width` pixels wide, `cols` per row (fewer if there are fewer images),
    each scaled to the cell width keeping its aspect ratio, with an optional caption strip under each."""
    if not images:
        raise ValueError("contact_sheet needs at least one image")
    if labels is not None and len(labels) != len(images):
        raise ValueError(f"{len(labels)} labels for {len(images)} images")
    pics = []
    for i, blob in enumerate(images):
        try:
            with Image.open(io.BytesIO(blob)) as im:
                pics.append(im.convert("RGB"))
        except Exception as e:  # noqa: BLE001 - say which image was bad
            raise ValueError(f"image {i} is not a readable image: {e}") from e

    cols = max(1, min(cols, len(pics)))
    rows = math.ceil(len(pics) / cols)
    cell_w = (width - PAD * (cols + 1)) // cols
    if cell_w < 8:
        raise ValueError(f"width {width} is too small for {cols} columns")
    scaled = [p.resize((cell_w, max(1, round(p.height * cell_w / p.width))), Image.LANCZOS) for p in pics]
    cell_h = max(p.height for p in scaled)
    font_px = _label_font_px(cell_w)
    label_h = font_px + 2 * 4 if labels else 0
    height = PAD + rows * (cell_h + label_h + PAD)

    sheet = Image.new("RGB", (width, height), BACKGROUND)
    draw = ImageDraw.Draw(sheet)
    font = _font(font_px) if labels else None
    for i, pic in enumerate(scaled):
        r, c = divmod(i, cols)
        x = PAD + c * (cell_w + PAD)
        y = PAD + r * (cell_h + label_h + PAD)
        sheet.paste(pic, (x, y + (cell_h - pic.height) // 2))
        if labels:
            draw.text((x + 2, y + cell_h + 4), _fit(draw, str(labels[i]), font, cell_w - 4), fill=LABEL_COLOR,
                      font=font)
    buf = io.BytesIO()
    sheet.save(buf, format="PNG")
    return buf.getvalue()


__all__ = ["MIN_CAPTURE", "PAD", "contact_sheet", "frames", "screenshot", "to_png"]

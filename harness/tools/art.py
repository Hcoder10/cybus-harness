"""Art tools for builder agents: textures painted from specs, with no image generation and no uploads.

    tools = art_tools(TexturePacks(workspace), run_dir / "art")    # paint_texture, list_textures

paint_texture renders a texture spec (texspec.py), saves art_dir/<name>.png, packs it into the game
(texpack.py -> ReplicatedStorage/Shared/TexPacks, synced like any script) and shows the model what it painted:
the texture over a checkerboard at a readable size, stretched as a 9-slice when it has one, and tinted when it is
an LA (tintable) texture. In the game, Kit.Textures.apply(instance, name) puts it on screen.
"""
from __future__ import annotations

import asyncio
import io
import json
from pathlib import Path
from typing import Any

import numpy as np
from PIL import Image, ImageDraw

from harness.tools.base import Tool, ToolResult
from harness.tools.texpack import TexturePacks, check_name
from harness.tools.texspec import SpecError, render

SPEC_HELP = """Spec (JSON): {"size": [w, h] (8..1024), "format": "RGBA" | "LA", "slice": [x0, y0, x1, y1], "layers": [...]}
- Pixels, (0, 0) = top-left, y down. LA = white/grey + alpha, tinted in game (ImageColor3, emitter/beam Color): use it
  for glows, particles, beams. slice = the 9-slice centre rectangle (Roblox SliceCenter), for panels and buttons.
- Layers draw in order: {"shape": ..., <shape keys>, <one paint>, <effects>}. box = [x0, y0, x1, y1]; box/center
  default to the whole texture; angles are degrees clockwise from 12 o'clock.
  fill | rect {box} | rounded_rect {box, radius | radii: [tl, tr, br, bl]} | ellipse {box | center + radius}
  circle {center, radius} | ring {center, outer, inner} | polygon {points: [[x, y], ...]}
  star {center, radius, points: 5, inner: 0.5, rotation} | line / polyline {points, width, taper: end width,
  cap: round|flat, smooth} | arc {center, radius, start, end, width, taper} | rays {center, count, inner, outer,
  width, taper: tip width (0), rotation, jitter 0..1, seed}
- Paint: "color": "#RRGGBB" or "#RRGGBBAA" | "linear": {"angle": 90, "stops": [[0, "#..."], [1, "#..."]]}
  (0 = left->right, 90 = top->bottom) | "radial": {"stops": [...], "center"?: [x, y], "radius"?: r or [rx, ry]};
  "noise": {"amount": 0.15, "scale": 8, "octaves": 3, "seed": 0, "target": "color" | "alpha"}.
- Effects: "opacity" 0..1, "blur" px, "rotate" deg, "blend": normal|add|multiply|screen,
  "stroke": {"width", "color" (or linear/radial), "align": inside|center|outside},
  "shadow": {"offset": [dx, dy], "blur", "color", "spread"}, "glow": {"blur", "color", "strength", "spread"},
  "inner_shadow": {"offset", "blur", "color"} (shadow/glow/inner_shadow also take a list).
Full reference and examples: the texture_spec playbook."""

_CHECK_A, _CHECK_B = (118, 118, 118), (146, 146, 146)
_TINT = (255, 150, 64)


def _checker(size: tuple[int, int], cell: int = 8) -> Image.Image:
    w, h = size
    yy, xx = np.indices((h, w))
    odd = ((xx // cell + yy // cell) % 2).astype(bool)
    arr = np.empty((h, w, 4), dtype=np.uint8)
    arr[...] = (*_CHECK_A, 255)
    arr[odd] = (*_CHECK_B, 255)
    return Image.fromarray(arr)


def nine_slice(img: Image.Image, center: list[int], size: tuple[int, int]) -> Image.Image:
    """Stretch an image to `size` the way Roblox does with ScaleType Slice and SliceCenter = center."""
    x0, y0, x1, y1 = center
    W, H = img.size
    tw, th = max(size[0], x0 + W - x1), max(size[1], y0 + H - y1)
    cols = [(0, x0, 0, x0), (x0, x1, x0, tw - (W - x1)), (x1, W, tw - (W - x1), tw)]
    rows = [(0, y0, 0, y0), (y0, y1, y0, th - (H - y1)), (y1, H, th - (H - y1), th)]
    out = Image.new("RGBA", (tw, th), (0, 0, 0, 0))
    for sx0, sx1, dx0, dx1 in cols:
        for sy0, sy1, dy0, dy1 in rows:
            if sx1 > sx0 and sy1 > sy0 and dx1 > dx0 and dy1 > dy0:
                out.paste(img.crop((sx0, sy0, sx1, sy1)).resize((dx1 - dx0, dy1 - dy0), Image.BILINEAR), (dx0, dy0))
    return out


def preview_png(img: Image.Image, slice_center: list[int] | None = None) -> bytes:
    """What the model sees: the texture on a checkerboard at a readable size; stretched as a 9-slice when it has
    a slice; tinted on a dark backdrop when it is LA."""
    rgba = img.convert("RGBA")
    w, h = rgba.size
    fit = 320 / max(w, h)
    scale = float(max(1, min(8, int(fit)))) if fit >= 1 else fit

    def scaled(im: Image.Image) -> Image.Image:
        if scale == 1:
            return im
        size = (max(1, round(im.width * scale)), max(1, round(im.height * scale)))
        return im.resize(size, Image.NEAREST if scale >= 2 else Image.LANCZOS)

    panels: list[tuple[str, Image.Image]] = [(f"{w}x{h} {img.mode}" + (f" x{scale:g}" if scale != 1 else ""),
                                              scaled(rgba))]
    if slice_center:
        stretched = nine_slice(rgba, slice_center, (round(w * 2.4), round(h * 1.35)))
        panels.append(("stretched as 9-slice", scaled(stretched)))
    if img.mode == "LA":
        arr = np.asarray(rgba).astype(np.float32)
        arr[..., :3] *= np.array(_TINT, dtype=np.float32) / 255
        tinted = Image.fromarray(arr.astype(np.uint8))
        panels.append(("tinted (ImageColor3 / Color)", scaled(tinted)))
    pad, label_h = 10, 16
    width = sum(p.width for _, p in panels) + pad * (len(panels) + 1)
    height = max(p.height for _, p in panels) + pad * 2 + label_h
    sheet = Image.new("RGBA", (width, height), (32, 34, 40, 255))
    draw = ImageDraw.Draw(sheet)
    x = pad
    for i, (label, p) in enumerate(panels):
        tinted = i > 0 and label.startswith("tinted")
        bg = Image.new("RGBA", p.size, (20, 22, 28, 255)) if tinted else _checker(p.size)
        sheet.paste(Image.alpha_composite(bg, p), (x, pad + label_h))
        draw.text((x, pad - 2), label, fill=(225, 228, 235, 255))
        x += p.width + pad
    out = io.BytesIO()
    sheet.convert("RGB").save(out, format="PNG")
    return out.getvalue()


def art_tools(packs: TexturePacks, art_dir: Path) -> list[Tool]:
    """paint_texture / list_textures for builder agents."""
    art_dir = Path(art_dir)

    def paint(name: str, spec: Any) -> ToolResult:
        try:
            check_name(name)
        except ValueError as e:
            return ToolResult(text=f"ERROR: {e}", data={"error": str(e)})
        if isinstance(spec, str):                       # some models send the object as a JSON string
            try:
                spec = json.loads(spec)
            except ValueError as e:
                return ToolResult(text=f"ERROR: spec is not valid JSON: {e}", data={"error": str(e)})
        try:
            img = render(spec)
        except SpecError as e:
            return ToolResult(text=f"ERROR: {e}", data={"error": str(e), "problems": e.problems})
        slc = img.info.get("slice")
        art_dir.mkdir(parents=True, exist_ok=True)
        png = io.BytesIO()
        img.save(png, format="PNG")
        path = art_dir / f"{name}.png"
        path.write_bytes(png.getvalue())
        replaced = name in packs.names()
        info = packs.add(name, img, slice=slc)
        w, h, fmt = info["w"], info["h"], info["fmt"]
        lines = [f"{'repainted' if replaced else 'painted'} {name}: {w}x{h} {fmt}"
                 + (f", 9-slice centre {slc}" if slc else "")
                 + f"; saved to {path.name} and packed into the game (ReplicatedStorage.Shared.TexPacks, pushed "
                   f"with your next sync)."]
        use = f'Use it: Textures.apply(imageLabel, "{name}") (Kit.Textures; ImageLabel / ImageButton'
        if slc:
            use += (f"; set ScaleType = Enum.ScaleType.Slice first and apply() sets SliceCenter = "
                    f"Rect.new({slc[0]}, {slc[1]}, {slc[2]}, {slc[3]}); SliceScale scales the corners")
        use += (f"), or Textures.apply(particleEmitter | beam | trail | decal, \"{name}\"); "
                f"Textures.get(\"{name}\") returns the Content.")
        lines.append(use)
        if fmt == "LA":
            lines.append("LA texture (white/grey + alpha): its colour comes from ImageColor3 on labels, or Color on "
                         "a ParticleEmitter / Beam / Trail.")
        lines.append("The image shows it over a checkerboard (transparency)"
                     + (", stretched as a 9-slice" if slc else "") + (", and tinted" if fmt == "LA" else "")
                     + ". Check it against the style; paint again with the same name to replace it.")
        return ToolResult(text="\n".join(lines), images=[preview_png(img, slc)],
                          data={"name": name, "file": str(path), **info})

    async def paint_texture(name: str, spec: Any) -> ToolResult:
        return await asyncio.to_thread(paint, name, spec)

    async def list_textures() -> ToolResult:
        rows = [packs.info(n) for n in packs.names()]
        if not rows:
            return ToolResult(text="no textures yet: paint one with paint_texture", data={"textures": []})
        text = "\n".join(f"- {r['name']}: {r['w']}x{r['h']} {r['fmt']}" + (f", slice {r['slice']}" if r["slice"] else "")
                         for r in rows if r)
        return ToolResult(text=f"{len(rows)} textures (Textures.apply(inst, name)):\n{text}",
                          data={"textures": rows})

    name_help = "Texture name: lowercase letters, digits and underscores, e.g. panel_skin, spark_glow, coin_icon."
    return [
        Tool(name="paint_texture",
             description="Paint a texture (UI panel or button skin, soft shadow, glow, icon from shapes, particle / "
                         "beam texture, ring, burst, streak) from a spec of layered shapes, fills and effects. You get "
                         "the rendered image back; look at it and repaint until it is right. It goes into the game as "
                         "texture data: show it with Textures.apply(instance, name).\n" + SPEC_HELP,
             parameters={"type": "object", "additionalProperties": False, "required": ["name", "spec"],
                         "properties": {"name": {"type": "string", "description": name_help},
                                        "spec": {"type": "object", "description": "The texture spec: "
                                                 "{size, format?, slice?, layers: [...]} as described above."}}},
             fn=paint_texture, mutating=True),
        Tool(name="list_textures", description="List the painted textures with their size, format and 9-slice centre.",
             parameters={"type": "object", "additionalProperties": False, "properties": {}},
             fn=list_textures, mutating=False),
    ]


__all__ = ["SPEC_HELP", "art_tools", "nine_slice", "preview_png"]

"""Offline tests for painted textures: the spec renderer (shapes, paints, effects, validation), the codec in Python
and in Luau (standalone runtime), texture packs, the paint_texture tool, the kit registration and the playbook."""
from __future__ import annotations

import asyncio
import functools
import io
import json
import math
import os
import re
import shutil
import subprocess
import zlib
from pathlib import Path

import numpy as np
import pytest
from PIL import Image

from harness.kit import KIT_API, KIT_DIR, MODULES, kit_files
from harness.tools.art import art_tools, nine_slice, preview_png
from harness.tools.texpack import (ALPHABET, TexturePacks, b85decode, b85encode, check_name, checksum, decode,
                                   encode, rgba_bytes)
from harness.tools.texspec import (SHAPES, SpecError, effective_supersample, parse_color, render, validate,
                                   value_noise)
from harness.tools.workspace import Workspace

PLAYBOOK = Path(__file__).resolve().parents[1] / "harness" / "playbooks" / "texture_spec.md"
LUAU_CANDIDATES = [os.environ.get("HARNESS_LUAU", ""), "C:/Users/sarta/brickformer/tools/luau/luau.exe",
                   str(Path.home() / "brickformer" / "tools" / "luau" / "luau.exe"), shutil.which("luau") or ""]
LUAU = next((c for c in LUAU_CANDIDATES if c and Path(c).is_file()), None)


# ------------------------------------------------------------------------------------------------ helpers

def one(layer: dict, size=(64, 64), **top) -> Image.Image:
    return render({"size": list(size), "layers": [layer], **top})


def arr(img: Image.Image) -> np.ndarray:
    return np.asarray(img.convert("RGBA")).astype(np.int32)


def area(img: Image.Image) -> float:
    return arr(img)[..., 3].sum() / 255.0


def px(img: Image.Image, x: int, y: int) -> tuple:
    return tuple(int(v) for v in arr(img)[y, x])


def near(a: float, b: float, rel: float = 0.03) -> bool:
    return abs(a - b) <= rel * b


WHITE = "#FFFFFF"


# ------------------------------------------------------------------------------------------------ shapes

def test_parse_color():
    assert parse_color("#FFF") == (1.0, 1.0, 1.0, 1.0)
    r, g, b, a = parse_color("#FF000080")
    assert (r, g, b) == (1.0, 0.0, 0.0) and abs(a - 128 / 255) < 1e-9
    for bad in ("red", "FF0000", "#GG0000", "#12345", 0xFF0000, None):
        with pytest.raises(ValueError):
            parse_color(bad)


@pytest.mark.parametrize("layer, expected", [
    ({"shape": "rect", "box": [8, 8, 40, 24]}, 32 * 16),
    ({"shape": "rounded_rect", "box": [8, 8, 56, 40], "radius": 10}, 48 * 32 - (4 - math.pi) * 100),
    ({"shape": "rounded_rect", "box": [8, 8, 56, 40], "radii": [0, 12, 0, 12]}, 48 * 32 - (4 - math.pi) * 72),
    ({"shape": "ellipse", "box": [8, 16, 56, 48]}, math.pi * 24 * 16),
    ({"shape": "ellipse", "center": [32, 32], "radius": [20, 10]}, math.pi * 20 * 10),
    ({"shape": "circle", "center": [32, 32], "radius": 20}, math.pi * 400),
    ({"shape": "ring", "center": [32, 32], "outer": 24, "inner": 16}, math.pi * (576 - 256)),
    ({"shape": "polygon", "points": [[8, 56], [56, 56], [32, 8]]}, 48 * 48 / 2),
    ({"shape": "star", "radius": 24, "points": 5, "inner": 0.5}, 5 * 24 * 12 * math.sin(math.pi / 5)),
    ({"shape": "line", "points": [[8, 32], [56, 32]], "width": 8}, 48 * 8 + math.pi * 16),
    ({"shape": "polyline", "points": [[8, 32], [56, 32]], "width": 8, "cap": "flat"}, 48 * 8),
    ({"shape": "arc", "center": [32, 32], "radius": 20, "start": 0, "end": 180, "width": 6, "cap": "flat"},
     math.pi * 20 * 6),
    ({"shape": "arc", "center": [32, 32], "radius": 20, "start": -90, "end": 90, "width": 6},
     math.pi * 20 * 6 + math.pi * 9),
    ({"shape": "rays", "count": 8, "inner": 8, "outer": 24, "width": 4, "taper": 4}, 8 * 16 * 4),
    ({"shape": "fill"}, 64 * 64),
])
def test_shape_area(layer, expected):
    img = one({**layer, "color": WHITE})
    assert img.mode == "RGBA" and img.size == (64, 64)
    assert near(area(img), expected), (layer["shape"], area(img), expected)


def test_shape_pixels():
    rect = one({"shape": "rect", "box": [8, 8, 40, 24], "color": "#FF0000"})
    assert px(rect, 20, 16) == (255, 0, 0, 255) and px(rect, 2, 2)[3] == 0 and px(rect, 50, 16)[3] == 0
    ring = one({"shape": "ring", "outer": 24, "inner": 16, "color": WHITE})
    assert px(ring, 32, 32)[3] == 0 and px(ring, 32, 12)[3] == 255          # hole / band at r = 19.5
    star = one({"shape": "star", "radius": 28, "points": 5, "inner": 0.4, "color": WHITE})
    assert px(star, 32, 10)[3] > 245                                        # the first point is up
    assert px(star, 32, 58)[3] == 0                                          # between the two lower points
    rays = one({"shape": "rays", "count": 4, "inner": 8, "outer": 28, "width": 4, "taper": 4, "color": WHITE})
    for x, y in ((32, 12), (51, 32), (32, 51), (12, 32)):                    # up, right, down, left at r ~ 19.5
        assert px(rays, x, y)[3] == 255, (x, y)
    assert px(rays, 45, 18)[3] == 0 and px(rays, 32, 32)[3] == 0             # diagonal / inside `inner`
    arc = one({"shape": "arc", "center": [32, 32], "radius": 20, "start": 0, "end": 90, "width": 4, "color": WHITE})
    assert px(arc, 46, 17)[3] > 245 and px(arc, 32, 52)[3] == 0              # 45 degrees on / 180 off
    streak = one({"shape": "line", "points": [[6, 32], [58, 32]], "width": 12, "taper": 0, "color": WHITE})
    col = arr(streak)[..., 3].sum(axis=0) / 255
    assert col[12] > 9 and col[50] < 4 and col[12] > col[30] > col[50]        # thick start, pointed end
    curve = one({"shape": "polyline", "points": [[8, 48], [32, 12], [56, 48]], "width": 3, "smooth": True,
                 "color": WHITE})
    assert px(curve, 32, 12)[3] > 0 and px(curve, 32, 40)[3] == 0             # passes through the points


def test_rotate_and_supersample():
    bar = {"shape": "rect", "box": [16, 28, 48, 36], "color": WHITE}
    flat, turned = one(bar), one({**bar, "rotate": 90})
    assert px(flat, 20, 32)[3] == 255 and px(flat, 32, 20)[3] == 0
    assert px(turned, 32, 20)[3] == 255 and px(turned, 20, 32)[3] == 0
    assert near(area(turned), area(flat), 0.02)
    aliased = one({"shape": "circle", "radius": 20, "color": WHITE}, supersample=1)
    smooth = one({"shape": "circle", "radius": 20, "color": WHITE})
    partial = lambda im: int(((arr(im)[..., 3] > 0) & (arr(im)[..., 3] < 255)).sum())
    assert partial(smooth) > partial(aliased)                                 # anti-aliased edge
    assert effective_supersample(64, 64, 4) == 4 and effective_supersample(1024, 1024, 4) == 2
    assert max(1024, 1024) * effective_supersample(1024, 1024, 8) <= 4096


# ------------------------------------------------------------------------------------------------ paints

def test_linear_and_radial_gradients():
    down = one({"shape": "fill", "linear": {"stops": [[0, "#000000"], [1, WHITE]]}})       # default angle 90
    col = arr(down)[:, 32, 0]
    assert col[0] < 12 and col[-1] > 243 and np.all(np.diff(col) >= 0)
    right = one({"shape": "fill", "linear": {"angle": 0, "stops": ["#000000", WHITE]}})
    row = arr(right)[32, :, 0]
    assert row[0] < 12 and row[-1] > 243 and np.all(np.diff(row) >= 0)
    left = one({"shape": "fill", "linear": {"angle": 180, "stops": ["#000000", WHITE]}})
    assert arr(left)[32, 0, 0] > 243
    radial = one({"shape": "fill", "radial": {"stops": [[0, WHITE], [1, "#000000"]]}})
    assert px(radial, 32, 32)[0] > 245 and px(radial, 0, 0)[0] == 0 and px(radial, 32, 1)[0] < 20
    boxed = one({"shape": "rect", "box": [16, 16, 48, 48], "linear": {"stops": ["#000000", WHITE]}})
    assert px(boxed, 32, 17)[0] < 20 and px(boxed, 32, 46)[0] > 235          # spans the shape, not the texture


def test_gradient_fades_keep_their_hue():
    fade = one({"shape": "fill", "linear": {"angle": 0, "stops": [[0, "#FF0000FF"], [1, "#00000000"]]}})
    r, g, b, a = px(fade, 32, 32)
    assert 100 < a < 156 and r > 245 and g == 0 and b == 0                   # premultiplied: no dark fringe


def test_noise_is_deterministic():
    spec = {"shape": "fill", "color": "#808080", "noise": {"amount": 0.5, "scale": 4, "seed": 3}}
    a, b = one(spec), one(spec)
    assert a.tobytes() == b.tobytes()
    c = one({**spec, "noise": {**spec["noise"], "seed": 4}})
    assert a.tobytes() != c.tobytes() and arr(a)[..., 0].std() > 5 and (arr(a)[..., 3] == 255).all()
    alpha = one({"shape": "fill", "color": WHITE, "noise": {"amount": 1, "scale": 6, "target": "alpha"}})
    assert arr(alpha)[..., 3].std() > 10 and (arr(alpha)[..., :3] == 255).all()
    n1 = value_noise(np.arange(16.0), np.zeros(16), 4, 3, 7)
    assert n1.min() >= 0 and n1.max() <= 1 and np.array_equal(n1, value_noise(np.arange(16.0), np.zeros(16), 4, 3, 7))


# ------------------------------------------------------------------------------------------------ effects

def test_opacity_blur_and_blend():
    assert abs(px(one({"shape": "fill", "color": WHITE, "opacity": 0.5}), 5, 5)[3] - 128) <= 1
    sharp = one({"shape": "rect", "box": [16, 16, 48, 48], "color": WHITE})
    soft = one({"shape": "rect", "box": [16, 16, 48, 48], "color": WHITE, "blur": 3})
    assert px(soft, 32, 32)[3] > 250 and 80 < px(soft, 16, 32)[3] < 180 and 0 < px(soft, 12, 32)[3] < 60
    assert px(soft, 2, 32)[3] == 0 and near(area(soft), area(sharp), 0.03)
    base = {"shape": "fill", "color": "#FF0000"}
    add = render({"size": [16, 16], "layers": [base, {"shape": "fill", "color": "#00FF00", "blend": "add"}]})
    assert px(add, 8, 8) == (255, 255, 0, 255)
    mul = render({"size": [16, 16], "layers": [{"shape": "fill", "color": "#808080"},
                                              {"shape": "fill", "color": "#808080", "blend": "multiply"}]})
    assert abs(px(mul, 8, 8)[0] - 64) <= 1
    scr = render({"size": [16, 16], "layers": [{"shape": "fill", "color": "#808080"},
                                              {"shape": "fill", "color": "#808080", "blend": "screen"}]})
    assert abs(px(scr, 8, 8)[0] - 192) <= 1
    over = render({"size": [16, 16], "layers": [{"shape": "fill", "color": WHITE},
                                               {"shape": "fill", "color": "#000000", "opacity": 0.5}]})
    assert abs(px(over, 8, 8)[0] - 128) <= 1 and px(over, 8, 8)[3] == 255


@pytest.mark.parametrize("align, red_at, blue_at, clear_at", [
    # pixel (32, y) has its centre 32 - y - 0.5 px above the circle's centre; probes sit >= 1.5 px from any edge
    ("inside", [18], [23], [14]),       # stroke band 12..16 px from the centre: 13.5 red, 8.5 blue, 17.5 clear
    ("center", [16, 15], [20], [12]),   # band 14..18: 15.5 and 16.5 red, 11.5 blue, 19.5 clear
    ("outside", [14], [18], [10]),      # band 16..20: 17.5 red, 13.5 blue, 21.5 clear
])
def test_stroke_alignment(align, red_at, blue_at, clear_at):
    img = one({"shape": "circle", "radius": 16, "color": "#0000FF",
               "stroke": {"width": 4, "color": "#FF0000", "align": align}})
    for y in red_at:
        r, g, b, a = px(img, 32, y)
        assert r > 245 and g < 8 and b < 8 and a > 250, (align, y, px(img, 32, y))
    for y in blue_at:
        r, g, b, a = px(img, 32, y)
        assert r < 8 and g < 8 and b > 245 and a > 250, (align, y, px(img, 32, y))
    for y in clear_at:
        assert px(img, 32, y)[3] <= 2, (align, y, px(img, 32, y))
    outline = one({"shape": "circle", "radius": 16, "stroke": {"width": 3, "color": WHITE}})   # no fill
    assert px(outline, 32, 32)[3] == 0 and px(outline, 32, 17)[3] > 245


def test_shadow_glow_inner_shadow():
    shadow = one({"shape": "rect", "box": [16, 16, 48, 40], "color": WHITE,
                  "shadow": {"offset": [0, 8], "blur": 0, "color": "#000000"}})
    assert px(shadow, 32, 44) == (0, 0, 0, 255) and px(shadow, 32, 12)[3] == 0 and px(shadow, 32, 30)[:3] == (255,) * 3
    layered = one({"shape": "rect", "box": [16, 16, 48, 40], "color": WHITE,
                   "shadow": [{"offset": [0, 4], "blur": 4, "color": "#00000080"},
                              {"offset": [0, 1], "blur": 1, "spread": 2, "color": "#000000"}]})
    assert 0 < px(layered, 32, 46)[3] < 128 and px(layered, 32, 41)[3] > 128
    glow = one({"shape": "circle", "radius": 12, "color": WHITE, "glow": {"blur": 4, "color": "#FFFFFFFF"}})
    a14, a20, a30 = (px(glow, 32 + d, 32)[3] for d in (14, 20, 30))
    assert a14 > a20 > a30 and a14 > 40 and a30 < 5
    strong = one({"shape": "circle", "radius": 12, "color": WHITE, "glow": {"blur": 4, "strength": 3}})
    assert px(strong, 52, 32)[3] > a20
    inner = one({"shape": "rect", "box": [8, 8, 56, 56], "color": WHITE,
                 "inner_shadow": {"offset": [0, 4], "blur": 0, "color": "#000000"}})
    assert max(px(inner, 32, 9)[:3]) < 20 and min(px(inner, 32, 40)[:3]) > 245
    assert px(inner, 32, 9)[3] > 245 and px(inner, 32, 4)[3] == 0


def test_la_format_slice_and_bleed():
    glow = render({"size": [32, 32], "format": "LA", "slice": [10, 10, 22, 22],
                   "layers": [{"shape": "circle", "radius": 12, "radial": {"stops": [WHITE, "#FFFFFF00"]}}]})
    assert glow.mode == "LA" and glow.info["slice"] == [10, 10, 22, 22]
    l, a = np.asarray(glow)[..., 0], np.asarray(glow)[..., 1]
    assert a[16, 16] > 230 and a[0, 0] == 0 and (l == 255).all()            # invisible pixels bleed the colour
    dot = one({"shape": "circle", "radius": 6, "color": "#FF8000"})
    far = arr(dot)[0, 0]
    assert far[3] == 0 and abs(far[0] - 255) <= 1 and abs(far[1] - 128) <= 1 and far[2] <= 1


# ------------------------------------------------------------------------------------------------ validation

def test_validation_collects_every_problem():
    bad = {"size": [4, 64], "background": "#000", "layers": [
        {"shape": "circel", "color": WHITE},
        {"shape": "rect", "colour": "#FF0000"},
        {"shape": "rect", "color": "red", "strok": {"width": 2}},
        {"shape": "rounded_rect", "box": [10, 10, 5, 20], "radius": "8px", "color": "#FFF"},
        {"shape": "circle", "radius": 8, "color": "#GG0000", "linear": {"stops": ["#FFF"]}},
        {"shape": "star", "color": WHITE, "shadow": {"blurr": 3}},
        {"shape": "circle", "radius": 8},
    ]}
    with pytest.raises(SpecError) as info:
        render(bad)
    msg = str(info.value)
    for needle in ("size[0]", "8..1024", "'background'", "did you mean 'circle'", "did you mean 'color'",
                   "did you mean 'stroke'", '"red" is not a colour', "#RRGGBB", "x0 < x1",
                   'expected a number, got "8px"', "only one of color, linear, radial", "did you mean 'blur'",
                   "layers[6]: draws nothing"):
        assert needle in msg, needle
    assert len(info.value.problems) >= 12
    assert msg.startswith(f"texture spec has {len(info.value.problems)} problems")


def test_validation_limits_and_types():
    for spec, needle in [
        ([], "must be an object"),
        ({"size": [64, 64], "layers": []}, "layers"),
        ({"size": [64, 64], "layers": [{"shape": "fill", "color": WHITE}] * 65}, "at most 64 layers"),
        ({"size": [64, 64], "slice": [40, 10, 20, 50], "layers": [{"shape": "fill", "color": WHITE}]}, "slice"),
        ({"size": [64], "layers": [{"shape": "fill", "color": WHITE}]}, "[width, height]"),
        ({"size": [64, 64], "format": "RGB", "layers": [{"shape": "fill", "color": WHITE}]}, "format"),
        ({"size": [64, 64], "layers": [{"type": "circle", "color": WHITE}]}, "use 'shape'"),
        ({"size": [64, 64], "layers": [{"shape": "fill", "color": WHITE, "stroke": {"width": 1, "color": WHITE}}]},
         "a fill covers the whole texture"),
        ({"size": [64, 64], "layers": [{"shape": "line", "points": [[0, 0], [9, 9]], "width": True,
                                        "color": WHITE}]}, "expected a number"),
        ({"size": [64, 64], "layers": [{"shape": "circle", "color": WHITE, "blend": "overlay"}]}, "blend"),
        ({"size": [64, 64], "layers": [{"shape": "rect", "color": WHITE, "noise": {"amount": 2}}]}, "0..1"),
    ]:
        with pytest.raises(SpecError) as info:
            render(spec)
        assert needle in str(info.value), (needle, str(info.value))
    ok = validate({"size": [64, 32], "note": "x", "layers": [{"shape": "circle", "color": WHITE, "name": "dot"}]})
    assert ok.width == 64 and ok.height == 32 and ok.layers[0].params["radius"] == 16


# ------------------------------------------------------------------------------------------------ codec

@functools.lru_cache(maxsize=1)
def _textures() -> dict[str, Image.Image]:
    rng = np.random.default_rng(1)
    y, x = np.mgrid[0:40, 0:64]
    grad = np.stack([x * 4, y * 6, 255 - x * 3, np.full_like(x, 255)], axis=2).astype(np.uint8)
    n = value_noise(*np.meshgrid(np.arange(96.0), np.arange(80.0)), 6, 3, 2)
    noisy = np.stack([n * 255, n * 180 + 40, 255 - n * 200, 128 + n * 127], axis=2).astype(np.uint8)
    return {
        "flat": Image.new("RGBA", (8, 8), (10, 20, 30, 255)),
        "clear": Image.new("RGBA", (16, 12), (0, 0, 0, 0)),
        "gradient": Image.fromarray(grad),
        "noisy": Image.fromarray(noisy),
        "random": Image.fromarray(rng.integers(0, 256, (33, 37, 4), dtype=np.uint8)),
        "glow_la": render({"size": [48, 40], "format": "LA", "layers": [
            {"shape": "fill", "radial": {"stops": [WHITE, "#FFFFFF00"]}}]}),
        "grey_la": Image.fromarray(rng.integers(0, 256, (9, 23, 2), dtype=np.uint8), "LA"),
        "panel": render(json.loads(_playbook_specs()[0])),
    }


@pytest.mark.parametrize("name", ["flat", "clear", "gradient", "noisy", "random", "glow_la", "grey_la", "panel"])
def test_codec_roundtrip(name):
    img = _textures()[name]
    entry = encode(img)
    assert set(entry) == {"w", "h", "fmt", "data", "checksum"}
    assert (entry["w"], entry["h"]) == img.size and entry["fmt"] == img.mode
    assert set(entry["data"]) <= set(ALPHABET) and '"' not in entry["data"] and "\\" not in entry["data"]
    raw = decode(entry)
    assert raw == rgba_bytes(img) and len(raw) == img.width * img.height * 4
    assert entry["checksum"] == checksum(raw) == zlib.adler32(raw)
    assert encode(img) == entry                                                # deterministic


def test_codec_compresses_and_rejects_corruption():
    tex = _textures()
    assert len(encode(tex["clear"])["data"]) < 60 and len(encode(tex["flat"])["data"]) < 100
    gradient = encode(tex["gradient"])
    assert len(gradient["data"]) * 4 / 5 < 0.25 * 64 * 40 * 4
    assert b85decode(b85encode(bytes(range(256)))) == bytes(range(256))
    broken = dict(gradient, data=gradient["data"][:40] + "~" + gradient["data"][41:])
    with pytest.raises(ValueError):
        decode(broken)
    with pytest.raises(ValueError):
        decode(dict(gradient, w=65))


# ------------------------------------------------------------------------------------------------ packs

def _pack_files(ws: Workspace) -> dict[str, str]:
    d = ws.src / "ReplicatedStorage" / "Shared" / "TexPacks"
    return {p.name: p.read_text(encoding="utf-8") for p in sorted(d.glob("*.luau"))}


def test_packs_index_limits_and_stable_repack(tmp_path: Path):
    ws = Workspace(tmp_path / "game")
    packs = TexturePacks(ws)
    packs.MODULE_LIMIT = 6000                                          # force several packs and a split texture
    tex = _textures()
    for name in ("panel", "noisy", "glow_la", "flat"):
        packs.add(name, tex[name], slice=[44, 44, 84, 84] if name == "panel" else None)
    assert packs.names() == ["flat", "glow_la", "noisy", "panel"]
    files = _pack_files(ws)
    assert "Index.luau" in files and len([f for f in files if f.startswith("Pack")]) >= 3
    assert all(len(src) < packs.MODULE_LIMIT for src in files.values())
    index = files["Index.luau"]
    assert re.search(r'\["panel"\] = \{ pack = (\d+|\{ \d+(, \d+)* \}), w = 128, h = 128, fmt = "RGBA", '
                     r'slice = \{ 44, 44, 84, 84 \}, checksum = \d+ \}', index)
    assert '["glow_la"]' in index and 'fmt = "LA"' in index
    noisy = packs.info("noisy")
    assert len(noisy["packs"]) > 1 and re.search(r'\["noisy"\] = \{ pack = \{ \d+(, \d+)+ \}', index)
    joined = "".join(re.search(r'\["noisy"\] = "([^"]*)"', files[f"Pack{n}.luau"]).group(1) for n in noisy["packs"])
    assert joined == packs.data("noisy")["data"]
    assert decode(packs.data("noisy")) == rgba_bytes(tex["noisy"])

    packs.write()
    assert _pack_files(ws) == files                                    # repacking is stable
    again = TexturePacks(ws)
    again.MODULE_LIMIT = 6000
    again.write()
    assert _pack_files(ws) == files                                    # rebuilt from the manifest alone
    assert json.loads((ws.root / "texpacks.json").read_text())["textures"]["panel"]["slice"] == [44, 44, 84, 84]

    flat_pack = packs.info("flat")["packs"][0]
    packs.add("flat", Image.new("RGBA", (8, 8), (30, 20, 10, 255)))   # replace, same encoded size: only its
                                                                        # pack and the index change
    changed = {k for k, v in _pack_files(ws).items() if files.get(k) != v}
    assert changed == {"Index.luau", f"Pack{flat_pack}.luau"}
    assert packs.remove("noisy") and not packs.remove("noisy")
    after = _pack_files(ws)
    assert '["noisy"]' not in after["Index.luau"] and all('["noisy"]' not in s for s in after.values())
    last = max(p for n in packs.names() for p in packs.info(n)["packs"])      # stale packs are deleted
    assert sorted(k for k in after if k.startswith("Pack")) == sorted(f"Pack{n}.luau" for n in range(1, last + 1))

    with pytest.raises(ValueError):
        packs.add("Bad Name", tex["flat"])
    with pytest.raises(ValueError):
        packs.add("flat", tex["flat"], slice=[4, 4, 20, 6])
    assert check_name("coin_icon_2") == "coin_icon_2"


def test_real_module_limit_holds(tmp_path: Path):
    ws = Workspace(tmp_path / "game")
    packs = TexturePacks(ws)
    rng = np.random.default_rng(2)
    static = Image.fromarray(rng.integers(0, 256, (200, 200, 4), dtype=np.uint8))   # incompressible: ~200 K chars
    packs.add("static", static)
    packs.add("static_2", Image.fromarray(rng.integers(0, 256, (120, 120, 4), dtype=np.uint8)))
    files = _pack_files(ws)
    assert all(len(src) < 150_000 for src in files.values()) and len(files) >= 3
    assert len(packs.info("static")["packs"]) == 2 and decode(packs.data("static")) == rgba_bytes(static)


# ------------------------------------------------------------------------------------------------ tools

def test_paint_texture_tool(tmp_path: Path):
    ws = Workspace(tmp_path / "game")
    packs = TexturePacks(ws)
    tools = {t.name: t for t in art_tools(packs, tmp_path / "art")}
    assert tools["paint_texture"].mutating and not tools["list_textures"].mutating
    spec = tools["paint_texture"].spec()["function"]
    assert spec["parameters"]["required"] == ["name", "spec"] and "rounded_rect" in spec["description"]

    panel = json.loads(_playbook_specs()[0])
    res = asyncio.run(tools["paint_texture"].invoke({"name": "panel_skin", "spec": panel}))
    assert not res.text.startswith("ERROR"), res.text
    assert 'Textures.apply(imageLabel, "panel_skin")' in res.text and "128x128 RGBA" in res.text
    assert "[44, 44, 84, 84]" in res.text and "SliceCenter" in res.text
    assert len(res.images) == 1 and Image.open(io.BytesIO(res.images[0])).format == "PNG"
    saved = Image.open(tmp_path / "art" / "panel_skin.png")
    assert saved.size == (128, 128) and packs.names() == ["panel_skin"]
    assert rgba_bytes(saved) == decode(packs.data("panel_skin"))
    assert "panel_skin" in ws.read("ReplicatedStorage/Shared/TexPacks/Index.luau")

    glow = {"size": [32, 32], "format": "LA", "layers": [{"shape": "fill", "radial": {"stops": [WHITE, "#FFFFFF00"]}}]}
    res = asyncio.run(tools["paint_texture"].invoke({"name": "spark", "spec": json.dumps(glow)}))   # JSON string too
    assert "32x32 LA" in res.text and "ImageColor3" in res.text and "Color" in res.text

    bad = asyncio.run(tools["paint_texture"].invoke({"name": "oops", "spec": {"size": [64, 64], "layers": [
        {"shape": "circle", "colour": WHITE}]}}))
    assert bad.text.startswith("ERROR") and "did you mean 'color'" in bad.text and not bad.images
    assert "oops" not in packs.names() and not (tmp_path / "art" / "oops.png").exists()
    assert asyncio.run(tools["paint_texture"].invoke({"name": "Oops!", "spec": glow})).text.startswith("ERROR")

    listing = asyncio.run(tools["list_textures"].invoke({}))
    assert "panel_skin: 128x128 RGBA, slice [44, 44, 84, 84]" in listing.text and "spark: 32x32 LA" in listing.text


def test_preview_and_nine_slice():
    img = render(json.loads(_playbook_specs()[0]))
    stretched = nine_slice(img.convert("RGBA"), [44, 44, 84, 84], (300, 160))
    assert stretched.size == (300, 160)
    assert np.array_equal(np.asarray(stretched)[:44, :44], np.asarray(img.convert("RGBA"))[:44, :44])  # corners kept
    prev = Image.open(io.BytesIO(preview_png(img, [44, 44, 84, 84])))
    assert prev.width > 2 * img.width                                  # the texture plus its 9-slice stretch


# ------------------------------------------------------------------------------------------------ kit and docs

def test_kit_registers_texture_modules():
    assert "TexCodec" in MODULES and "Textures" in MODULES
    files = kit_files()
    assert "src/ReplicatedStorage/Kit/TexCodec.luau" in files and "src/ReplicatedStorage/Kit/Textures.luau" in files
    assert "Textures.apply" in KIT_API and "TexCodec.decode" in KIT_API
    codec = (KIT_DIR / "TexCodec.luau").read_text(encoding="utf-8")
    assert codec.startswith("--!native") and "game" not in re.sub(r"--.*", "", codec)       # no Roblox API
    assert ALPHABET in codec
    textures = (KIT_DIR / "Textures.luau").read_text(encoding="utf-8")
    for needle in ("CreateEditableImage", "WritePixelsBuffer", "Content.fromObject", "ImageContent",
                   "TextureContent", "SliceCenter", "TexPacks", "function Textures.preload", "function Textures.has",
                   "function Textures.info", "function Textures.names"):
        assert needle in textures, needle


def _playbook_specs() -> list[str]:
    return re.findall(r"```json\n(.*?)```", PLAYBOOK.read_text(encoding="utf-8"), re.S)


def test_playbook_examples_render_and_cover_the_format():
    specs = _playbook_specs()
    assert len(specs) >= 5                         # panel, glow, icon, button + pressed variant
    for text in specs:
        img = render(json.loads(text))
        assert area(img) > 50
    doc = PLAYBOOK.read_text(encoding="utf-8")
    for word in list(SHAPES) + ["linear", "radial", "noise", "opacity", "blur", "rotate", "blend", "stroke", "shadow",
                                "glow", "inner_shadow", "slice", "LA", "supersample", "taper", "jitter"]:
        assert f"`{word}`" in doc or f'"{word}"' in doc, word


# ------------------------------------------------------------------------------------------------ Luau

LUAU_MAIN = """
local TexCodec = require("./TexCodec")
local Index = require("./Index")
local names = {}
for name in Index do
	table.insert(names, name)
end
table.sort(names)
for _, name in names do
	local e = Index[name]
	local list = if type(e.pack) == "table" then e.pack else { e.pack }
	local parts = {}
	for i, n in list do
		parts[i] = require("./Pack" .. n)[name]
	end
	local data = table.concat(parts)
	local best = math.huge
	local pixels
	for _ = 1, 5 do
		local t0 = os.clock()
		pixels = TexCodec.decode(data, e.w, e.h, e.fmt)
		best = math.min(best, os.clock() - t0)
	end
	print(string.format("TEX %s %d %d %d %.3f", name, TexCodec.checksum(pixels), e.checksum, buffer.len(pixels), best * 1000))
end
local ok = pcall(TexCodec.decode, "0000000000", 8, 8, "RGBA")
print("CORRUPT " .. tostring(ok))
"""


@pytest.mark.skipif(LUAU is None, reason="standalone luau runtime not installed")
def test_luau_decoder_matches_python(tmp_path: Path):
    ws = Workspace(tmp_path / "game")
    packs = TexturePacks(ws)
    packs.MODULE_LIMIT = 40_000                                       # the 256x256 noise texture spans packs
    images = dict(_textures())
    ui = render({"size": [256, 256], "layers": [
        {"shape": "fill", "linear": {"stops": ["#20283A", "#141926"]}, "noise": {"amount": 0.04, "scale": 2}},
        {"shape": "rounded_rect", "box": [24, 20, 232, 232], "radius": 36,
         "linear": {"stops": ["#3A4760", "#262F42"]}, "stroke": {"width": 2, "color": "#FFFFFF30"},
         "shadow": {"offset": [0, 8], "blur": 10, "color": "#00000080"}},
        {"shape": "star", "center": [128, 126], "radius": 60, "color": "#FFD166", "glow": {"blur": 10}}]})
    n = value_noise(*np.meshgrid(np.arange(256.0), np.arange(256.0)), 3, 4, 9)
    images["ui_256"] = ui
    images["noise_256"] = Image.fromarray(np.stack([n * 255, n * 160 + 50, 255 - n * 255, np.full_like(n, 255)],
                                                   axis=2).astype(np.uint8))
    for name, img in images.items():
        packs.add(name, img)
    run = tmp_path / "luau"
    run.mkdir()
    shutil.copy(KIT_DIR / "TexCodec.luau", run / "TexCodec.luau")
    for f in (ws.src / "ReplicatedStorage" / "Shared" / "TexPacks").glob("*.luau"):
        shutil.copy(f, run / f.name)
    (run / "main.luau").write_text(LUAU_MAIN, encoding="utf-8")
    results = {}
    for mode in ([], ["--codegen"]):
        out = subprocess.run([LUAU, *mode, "-O2", "main.luau"], cwd=run, capture_output=True, text=True, timeout=120)
        assert out.returncode == 0, out.stdout + out.stderr
        rows = [line.split() for line in out.stdout.splitlines() if line.startswith("TEX ")]
        assert len(rows) == len(packs.names())
        for _, name, got, stored, size, ms in rows:
            assert int(got) == int(stored) == checksum(rgba_bytes(images[name])), name
            e = packs.info(name)
            assert int(size) == e["w"] * e["h"] * 4
            results[(name, "native" if mode else "interpreted")] = float(ms)
        assert "CORRUPT false" in out.stdout
    assert len(packs.info("noise_256")["packs"]) > 1
    print("\nLuau decode, 256x256 RGBA (ms): " + ", ".join(f"{k[0]} {k[1]} {v:.2f}" for k, v in sorted(results.items())
                                                        if k[0].endswith("256")))
    assert results[("ui_256", "interpreted")] < 200 and results[("noise_256", "interpreted")] < 400


LUAU_TEXTURES_MOCK = r"""
-- Runs Kit/Textures.luau outside Roblox: the real TexCodec and generated Index / Pack modules, mocked services.
local realRequire = require
local TexCodec = realRequire("./TexCodec")
local Index = realRequire("./Index")
local SOURCE = realRequire("./textures_src")

local warnings, images = {}, {}
local now, created, allow = 1000, 0, 1000

local function check(name, ok)
	print("CHECK " .. string.gsub(name, " ", "_") .. " " .. tostring(ok and true or false))
end

local function newInstance(className, name, parent)
	local inst = { __instance = true, ClassName = className, Name = name, Parent = parent, children = {} }
	function inst:IsA(c)
		return self.ClassName == c or (c == "Decal" and self.ClassName == "Texture")
	end
	function inst:FindFirstChild(n)
		return self.children[n]
	end
	function inst:WaitForChild(n)
		return self.children[n]
	end
	function inst:GetFullName()
		return self.Name
	end
	if parent then
		parent.children[name] = inst
	end
	return inst
end

local function makeEnv(withIndex)
	local rs = newInstance("ReplicatedStorage", "ReplicatedStorage")
	if withIndex then
		local texPacks = newInstance("Folder", "TexPacks", newInstance("Folder", "Shared", rs))
		newInstance("ModuleScript", "Index", texPacks).path = "./Index"
		for n = 1, NPACKS do
			newInstance("ModuleScript", "Pack" .. n, texPacks).path = "./Pack" .. n
		end
	end
	local kit = newInstance("Folder", "Kit", rs)
	newInstance("ModuleScript", "TexCodec", kit).value = TexCodec
	local assets = {}
	function assets:CreateEditableImage(opts)
		if created >= allow then
			return nil
		end
		created += 1
		local img = { size = opts.Size }
		function img:WritePixelsBuffer(_, size, buf)
			self.buf, self.writeSize = buf, size
		end
		function img:Destroy()
			self.destroyed = true
		end
		table.insert(images, img)
		return img
	end
	local services = { AssetService = assets, ReplicatedStorage = rs }
	return setmetatable({
		game = { GetService = function(_, name) return services[name] end },
		script = newInstance("ModuleScript", "Textures", kit),
		require = function(m)
			if type(m) == "table" then
				return if m.value ~= nil then m.value else realRequire(m.path)
			end
			return realRequire(m)
		end,
		Vector2 = { new = function(x, y) return { X = x, Y = y } end, zero = { X = 0, Y = 0 } },
		Rect = { new = function(a, b, c, d) return { a, b, c, d } end },
		Content = { fromObject = function(o) return { content = true, object = o } end },
		Enum = { ScaleType = { Slice = "Slice", Stretch = "Stretch" } },
		typeof = function(v)
			return if type(v) == "table" and v.__instance then "Instance" else type(v)
		end,
		warn = function(...)
			table.insert(warnings, table.concat({ ... }, " "))
		end,
		task = { wait = function() end },
		os = setmetatable({ clock = function() return now end }, { __index = os }),
	}, { __index = getfenv(0) })
end

local function load(env)
	local fn = assert(loadstring(SOURCE, "=Textures"))
	setfenv(fn, env)
	return fn()
end

local Textures = load(makeEnv(true))
local names = Textures.names()
check("names", #names == NTEX and names[1] == "flat" and Textures.has("panel") and not Textures.has("nope"))
local info = Textures.info("panel")
check("info", info.w == 128 and info.fmt == "RGBA" and info.slice[1] == 44 and info.slice[4] == 84 and not info.loaded)

local panel = Textures.get("panel")
check("get", panel ~= nil and panel.content == true and created == 1)
check("pixels", TexCodec.checksum(images[1].buf) == Index.panel.checksum and images[1].writeSize.X == 128)
check("cached", Textures.get("panel") == panel and created == 1 and Textures.info("panel").loaded)

local label = newInstance("ImageLabel", "Label")
label.ScaleType = "Slice"
check("apply sliced label", Textures.apply(label, "panel") and label.ImageContent == panel
	and label.SliceCenter[1] == 44 and label.SliceCenter[3] == 84)
local stretched = newInstance("ImageButton", "Button")
stretched.ScaleType = "Stretch"
check("apply stretched button", Textures.apply(stretched, "panel") and stretched.ImageContent == panel
	and stretched.SliceCenter == nil)
local emitter = newInstance("ParticleEmitter", "Sparks")
check("apply emitter", Textures.apply(emitter, "glow_la") and emitter.TextureContent ~= nil)
local surface = newInstance("Texture", "Surface")
check("apply texture", Textures.apply(surface, "glow_la") and surface.TextureContent == emitter.TextureContent)
local n0 = #warnings
check("apply frame fails soft", Textures.apply(newInstance("Frame", "Frame"), "panel") == false and #warnings == n0 + 1)
check("apply non-instance", Textures.apply(nil, "panel") == false)

n0 = #warnings
check("missing warns once", Textures.get("nope") == nil and Textures.get("nope") == nil and #warnings == n0 + 1)
n0 = #warnings
check("corrupt data", Textures.get("tampered") == nil and Textures.get("tampered") == nil and #warnings == n0 + 1)

allow, n0 = created, #warnings
local before = created
check("budget spent", Textures.get("flat") == nil and Textures.get("flat") == nil and #warnings == n0 + 1)
now += 1
allow = 1000
check("no retry within the window", Textures.get("flat") == nil and created == before)
now += 2.5
check("retry after the window", Textures.get("flat") ~= nil and created == before + 1)

check("preload", Textures.preload() == NTEX - 1)
local first = images[1]
Textures.release("panel")
check("release", first.destroyed and not Textures.info("panel").loaded)
check("rebuild", Textures.get("panel") ~= nil and Textures.get("panel") ~= panel)

local bare = load(makeEnv(false))
local ok = pcall(function()
	assert(bare.has("panel") == false and bare.get("panel") == nil and #bare.names() == 0)
	assert(bare.info("panel") == nil and bare.apply(label, "panel") == false and bare.preload() == 0)
end)
check("no index fails soft", ok)
print("DONE")
"""


@pytest.mark.skipif(LUAU is None, reason="standalone luau runtime not installed")
def test_luau_textures_runtime_with_mocks(tmp_path: Path):
    """Kit/Textures.luau against mocked Roblox services: caching, SliceCenter, emitters, soft failures, the
    EditableImage memory budget with its retry window, release, and a missing index."""
    from harness.tools.workspace import lua_long_string
    ws = Workspace(tmp_path / "game")
    packs = TexturePacks(ws)
    tex = _textures()
    for name in ("flat", "glow_la", "panel", "gradient"):
        packs.add(name, tex[name], slice=[44, 44, 84, 84] if name == "panel" else None)
    packs.add("tampered", tex["random"])
    run = tmp_path / "luau"
    run.mkdir()
    shutil.copy(KIT_DIR / "TexCodec.luau", run / "TexCodec.luau")
    for f in (ws.src / "ReplicatedStorage" / "Shared" / "TexPacks").glob("*.luau"):
        text = f.read_text(encoding="utf-8")
        if f.name == "Index.luau":                                     # a texture whose data no longer matches
            text = re.sub(r'(\["tampered"\] = \{.*checksum = )\d+', r"\g<1>12345", text)
        (run / f.name).write_text(text, encoding="utf-8")
    source = (KIT_DIR / "Textures.luau").read_text(encoding="utf-8")
    (run / "textures_src.luau").write_text("return " + lua_long_string(source) + "\n", encoding="utf-8")
    npacks = max(p for n in packs.names() for p in packs.info(n)["packs"])
    main = LUAU_TEXTURES_MOCK.replace("NPACKS", str(npacks)).replace("NTEX", str(len(packs.names())))
    (run / "mock.luau").write_text(main, encoding="utf-8")
    out = subprocess.run([LUAU, "mock.luau"], cwd=run, capture_output=True, text=True, timeout=120)
    assert out.returncode == 0 and "DONE" in out.stdout, out.stdout + out.stderr
    checks = dict(line.split()[1:3] for line in out.stdout.splitlines() if line.startswith("CHECK "))
    assert len(checks) >= 20 and all(v == "true" for v in checks.values()), checks

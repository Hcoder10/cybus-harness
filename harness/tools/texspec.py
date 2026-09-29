"""Texture specs: game art authored as data and rendered here, safely.

The games are built without image generation and without asset uploads, so custom art (panel and button skins,
soft shadows, glows, icons built from shapes, particle and beam textures, rings, bursts, streaks) is described as
a declarative JSON spec that this module interprets. Nothing in a spec is ever executed: no eval, no exec, no
expressions, only shapes, paints and effects with checked numbers. texpack.py packs the rendered image into the
game, and Kit.Textures rebuilds it at runtime as an EditableImage.

    {"size": [96, 96], "slice": [28, 28, 68, 68], "layers": [
        {"shape": "rounded_rect", "box": [8, 6, 88, 86], "radius": 18,
         "linear": {"angle": 90, "stops": [[0, "#3B4A66"], [1, "#253049"]]},
         "stroke": {"width": 2, "color": "#FFFFFF30"},
         "shadow": {"offset": [0, 4], "blur": 5, "color": "#00000080"}}]}

Coordinates are output pixels: (0, 0) is the top-left corner of the texture, x grows right, y grows down, and
pixel (i, j) covers [i, i+1] x [j, j+1]. Shapes become polygons drawn at `supersample` times the size, layers are
composited in premultiplied float at that size, and the result is downsampled with a box (area-average) filter. Offsets of a shape
(strokes, shadow spread) are exact geometric offsets, not pixel morphology. Transparent pixels get the colour of
their nearest visible neighbour so edges do not darken when the texture is scaled on the GPU.

validate() collects every problem in a spec into one SpecError, so a model can fix its spec in one go.
The full reference for builders is harness/playbooks/texture_spec.md.
"""
from __future__ import annotations

import difflib
import math
import re
import time
from dataclasses import dataclass, field
from typing import Any

import numpy as np
from PIL import Image

MIN_SIDE, MAX_SIDE = 8, 1024
MAX_LAYERS = 64
MAX_EFFECTS = 4                 # shadows, glows or inner shadows per layer
DEFAULT_SUPERSAMPLE, MAX_SUPERSAMPLE = 4, 8
SS_MAX_SIDE = 4096              # the supersampled canvas never exceeds this on a side ...
SS_MAX_PIXELS = 1 << 22         # ... nor 2048 x 2048 pixels in total: big textures get less supersampling
COORD_LIMIT = 4096.0            # |any coordinate or length| in output pixels
MAX_BLUR = 256.0
MAX_WIDTH = 512.0
MAX_POINTS = 512
EDGE_MARGIN = 32                # output px rendered past the canvas edge so blurs there fall off correctly
TIME_LIMIT = 30.0               # seconds for one render
LUT_SIZE = 1024                 # gradient lookup resolution

BLENDS = ("normal", "add", "multiply", "screen")
FORMATS = ("RGBA", "LA")
ALIGNS = ("inside", "center", "outside")
CAPS = ("round", "flat")

_LINE_KEYS = {"points", "width", "taper", "cap", "smooth"}
SHAPE_KEYS: dict[str, set[str]] = {
    "fill": set(),
    "rect": {"box"},
    "rounded_rect": {"box", "radius", "radii"},
    "ellipse": {"box", "center", "radius"},
    "circle": {"center", "radius"},
    "ring": {"center", "outer", "radius", "inner"},
    "polygon": {"points"},
    "star": {"center", "radius", "points", "inner", "rotation"},
    "line": _LINE_KEYS,
    "polyline": _LINE_KEYS,
    "arc": {"center", "radius", "start", "end", "width", "taper", "cap"},
    "rays": {"center", "count", "inner", "outer", "width", "taper", "rotation", "cap", "jitter", "seed"},
}
SHAPES = tuple(SHAPE_KEYS)
_PAINT_KEYS = {"color", "linear", "radial"}
_LABEL_KEYS = {"name", "note"}
_FILL_LAYER_KEYS = {"shape", "noise", "opacity", "blend"} | _PAINT_KEYS | _LABEL_KEYS
_LAYER_KEYS = _FILL_LAYER_KEYS | {"blur", "rotate", "stroke", "shadow", "glow", "inner_shadow"}
_TOP_KEYS = {"size", "format", "slice", "supersample", "layers"} | _LABEL_KEYS

_TOP_HINTS = {
    "width": "use size: [width, height]", "height": "use size: [width, height]",
    "background": 'add a first layer {"shape": "fill", "color": "#RRGGBB"}',
    "slice_center": "use slice: [x0, y0, x1, y1]", "slicecenter": "use slice: [x0, y0, x1, y1]",
    "ss": "use supersample", "antialias": "anti-aliasing is automatic (supersample)",
}
# Hints for unknown keys: "=key" is a rename (reported as "did you mean"), anything else is advice.
_LAYER_HINTS = {
    "type": "=shape", "kind": "=shape", "colour": "=color", "border": "=stroke", "outline": "=stroke",
    "drop_shadow": "=shadow", "dropshadow": "=shadow", "outer_glow": "=glow", "innershadow": "=inner_shadow",
    "corner_radius": "=radius", "cornerradius": "=radius", "thickness": "=width", "blend_mode": "=blend",
    "mode": "=blend", "feather": "=blur", "softness": "=blur", "centre": "=center", "rotation": "=rotate",
    "fill": "a shape's paint is 'color', 'linear' or 'radial' ('fill' is a shape of its own)",
    "gradient": "use 'linear' or 'radial'", "stops": "stops go inside 'linear' or 'radial'",
    "angle": "angle goes inside 'linear' (turn a whole layer with 'rotate')",
    "alpha": "use 'opacity', or the colour's alpha (#RRGGBBAA)", "transparency": "use 'opacity' (1 = fully visible)",
    "size": "use 'box' ([x0, y0, x1, y1]) or 'radius'", "position": "use 'box' or 'center'",
    "pos": "use 'box' or 'center'", "x": "use 'box' or 'center'", "y": "use 'box' or 'center'", "w": "use 'box'",
    "h": "use 'box'",
    "radius": "'radius' belongs to rounded_rect, circle, ellipse, ring, star and arc (a rect has sharp corners: use "
              "shape 'rounded_rect' to round them)",
    "radii": "'radii' belongs to rounded_rect",
}
_SUB_HINTS = {"colour": "=color", "size": "=width", "thickness": "=width", "softness": "=blur", "radius": "=blur",
              "intensity": "=strength", "position": "=align", "distance": "use 'offset': [dx, dy]",
              "x": "use 'offset': [dx, dy]", "y": "use 'offset': [dx, dy]"}

_REQ = object()


def _join(path: str, key: str) -> str:
    return f"{path}.{key}" if path else key


class SpecError(ValueError):
    """A texture spec that cannot be rendered; `problems` lists every issue found (the message shows them all)."""

    def __init__(self, problems: list[str]) -> None:
        self.problems = list(problems)
        n = len(self.problems)
        shown = self.problems[:40]
        lines = [f"texture spec has {n} problem{'s' if n != 1 else ''}; fix all of them and try again:"]
        lines += [f"- {p}" for p in shown]
        if n > len(shown):
            lines.append(f"- ... and {n - len(shown)} more")
        super().__init__("\n".join(lines))


# ------------------------------------------------------------------------------------------------ colours

_HEX_DIGITS = re.compile(r"^[0-9a-fA-F]+$")


def parse_color(value: Any) -> tuple[float, float, float, float]:
    """'#RGB', '#RGBA', '#RRGGBB' or '#RRGGBBAA' -> straight (r, g, b, a) in 0..1. Raises ValueError."""
    if not isinstance(value, str) or not value.strip().startswith("#"):
        raise ValueError(f"not a colour: {value!r}")
    hx = value.strip()[1:]
    if not _HEX_DIGITS.match(hx) or len(hx) not in (3, 4, 6, 8):
        raise ValueError(f"not a colour: {value!r}")
    if len(hx) in (3, 4):
        hx = "".join(ch * 2 for ch in hx)
    if len(hx) == 6:
        hx += "FF"
    r, g, b, a = (int(hx[i:i + 2], 16) / 255.0 for i in range(0, 8, 2))
    return (r, g, b, a)


# ------------------------------------------------------------------------------------------------ validation

@dataclass
class Paint:
    kind: str                                         # color | linear | radial
    rgba: tuple[float, float, float, float] = (0.0, 0.0, 0.0, 0.0)
    stops: list[tuple[float, tuple[float, float, float, float]]] = field(default_factory=list)
    angle: float = 90.0
    center: tuple[float, float] | None = None
    radius: tuple[float, float] | None = None


@dataclass
class LayerSpec:
    shape: str
    params: dict
    paint: Paint | None
    noise: dict | None
    opacity: float
    blend: str
    blur: float
    rotate: float
    stroke: dict | None
    shadows: list[dict]
    glows: list[dict]
    inner_shadows: list[dict]


@dataclass
class TextureSpec:
    width: int
    height: int
    format: str
    slice: list[int] | None
    supersample: int
    layers: list[LayerSpec]


def _short(v: Any) -> str:
    s = repr(v) if not isinstance(v, str) else f'"{v}"'
    return s if len(s) <= 60 else s[:57] + "..."


def _fmt(x: float) -> str:
    return str(int(x)) if float(x).is_integer() else f"{x:g}"


class _Checker:
    def __init__(self) -> None:
        self.problems: list[str] = []

    def bad(self, path: str, msg: str) -> None:
        self.problems.append(f"{path}: {msg}" if path else msg)

    def keys(self, obj: dict, path: str, allowed: set[str], hints: dict[str, str] | None = None) -> None:
        for k in obj:
            if k in allowed:
                continue
            if not isinstance(k, str):
                self.bad(path, f"key {_short(k)} is not a string")
                continue
            hints = hints or {}
            hint = hints.get(k.lower())
            if hint and hint.startswith("="):
                if hint[1:] in allowed:
                    self.bad(path, f"unknown key '{k}' (did you mean '{hint[1:]}'?)")
                    continue
                hint = hints.get(hint[1:])            # a rename this shape does not take: advise on that key
            close = difflib.get_close_matches(k, sorted(allowed), n=1, cutoff=0.6)
            if hint and not hint.startswith("="):
                self.bad(path, f"unknown key '{k}': {hint}")
            elif close:
                self.bad(path, f"unknown key '{k}' (did you mean '{close[0]}'?)")
            else:
                self.bad(path, f"unknown key '{k}'; allowed here: {', '.join(sorted(allowed))}")

    def dict_(self, v: Any, path: str, what: str) -> dict | None:
        if not isinstance(v, dict):
            self.bad(path, f"expected {what}, got {_short(v)}")
            return None
        return v

    def number(self, v: Any, path: str, lo: float = -math.inf, hi: float = math.inf,
               integer: bool = False) -> float | None:
        if isinstance(v, bool) or not isinstance(v, (int, float)):
            self.bad(path, f"expected a number, got {_short(v)}")
            return None
        if not math.isfinite(v):
            self.bad(path, f"expected a finite number, got {_short(v)}")
            return None
        if integer and float(v) != int(v):
            self.bad(path, f"expected a whole number, got {_fmt(v)}")
            return None
        if v < lo or v > hi:
            self.bad(path, f"{_fmt(v)} is out of range {_fmt(lo)}..{_fmt(hi)}")
            return None
        return int(v) if integer else float(v)

    def num(self, obj: dict, key: str, path: str, lo: float = -math.inf, hi: float = math.inf,
            default: Any = _REQ, integer: bool = False, why: str = "") -> Any:
        if obj.get(key) is None:
            if default is _REQ:
                self.bad(path, f"'{key}' is required{why}")
            return None if default is _REQ else default
        return self.number(obj[key], _join(path, key), lo, hi, integer)

    def numbers(self, v: Any, path: str, n: int, lo: float, hi: float, what: str) -> list[float] | None:
        if not isinstance(v, (list, tuple)) or len(v) != n:
            self.bad(path, f"expected {what}, got {_short(v)}")
            return None
        out = [self.number(x, f"{path}[{i}]", lo, hi) for i, x in enumerate(v)]
        return None if any(x is None for x in out) else out  # type: ignore[return-value]

    def pair(self, obj: dict, key: str, path: str, default: Any = _REQ, lo: float = -COORD_LIMIT,
             hi: float = COORD_LIMIT) -> Any:
        if obj.get(key) is None:
            if default is _REQ:
                self.bad(path, f"'{key}' is required ([x, y])")
                return None
            return default
        v = self.numbers(obj[key], _join(path, key), 2, lo, hi, "[x, y]")
        return None if v is None else (v[0], v[1])

    def box(self, obj: dict, path: str, default: tuple) -> tuple | None:
        if obj.get("box") is None:
            return default
        v = self.numbers(obj["box"], f"{path}.box", 4, -COORD_LIMIT, COORD_LIMIT, "[x0, y0, x1, y1]")
        if v is None:
            return None
        if not (v[0] < v[2] and v[1] < v[3]):
            self.bad(f"{path}.box", f"needs x0 < x1 and y0 < y1 ([left, top, right, bottom]), got {_short(obj['box'])}")
            return None
        return tuple(v)

    def enum(self, obj: dict, key: str, path: str, choices: tuple[str, ...], default: str) -> str | None:
        v = obj.get(key)
        if v is None:
            return default
        if v not in choices:
            close = difflib.get_close_matches(str(v), choices, n=1, cutoff=0.5)
            extra = f" (did you mean '{close[0]}'?)" if close else ""
            self.bad(_join(path, key), f"{_short(v)} is not one of {', '.join(choices)}{extra}")
            return None
        return v

    def color(self, v: Any, path: str) -> tuple[float, float, float, float] | None:
        try:
            return parse_color(v)
        except ValueError:
            self.bad(path, f'{_short(v)} is not a colour; use "#RRGGBB" or "#RRGGBBAA" '
                           f'(AA is alpha: "#FFFFFF80" is half-transparent white)')
            return None

    def points(self, obj: dict, key: str, path: str, lo_n: int, what: str) -> np.ndarray | None:
        v = obj.get(key)
        if v is None:
            self.bad(path, f"'{key}' is required ({what})")
            return None
        if not isinstance(v, list) or not (lo_n <= len(v) <= MAX_POINTS):
            self.bad(f"{path}.{key}", f"expected {lo_n}..{MAX_POINTS} points [[x, y], ...], got {_short(v)}")
            return None
        pts = [self.numbers(p, f"{path}.{key}[{i}]", 2, -COORD_LIMIT, COORD_LIMIT, "[x, y]")
               for i, p in enumerate(v)]
        if any(p is None for p in pts):
            return None
        return np.array(pts, dtype=np.float64)

    # -------------------------------------------------------------------------------------- paints

    def stops(self, v: Any, path: str) -> list | None:
        if not isinstance(v, list) or not (1 <= len(v) <= 16):
            self.bad(path, f'expected 1..16 stops like [[0, "#RRGGBB"], [1, "#RRGGBBAA"]], got {_short(v)}')
            return None
        out = []
        ok = True
        for i, s in enumerate(v):
            p = f"{path}[{i}]"
            if isinstance(s, str):                         # bare colours: evenly spaced
                pos: float | None = i / (len(v) - 1) if len(v) > 1 else 0.0
                col = self.color(s, p)
            elif isinstance(s, (list, tuple)) and len(s) == 2:
                pos = self.number(s[0], f"{p}[0]", 0.0, 1.0)
                col = self.color(s[1], f"{p}[1]")
            else:
                self.bad(p, f'expected [position 0..1, "#RRGGBB"], got {_short(s)}')
                ok = False
                continue
            if pos is None or col is None:
                ok = False
                continue
            out.append((pos, col))
        if not ok:
            return None
        out.sort(key=lambda s: s[0])
        return out

    def paint(self, obj: dict, path: str) -> Paint | None:
        given = [k for k in ("color", "linear", "radial") if obj.get(k) is not None]
        if len(given) > 1:
            self.bad(path, f"give only one of color, linear, radial (got {', '.join(given)})")
            return None
        if not given:
            return None
        kind = given[0]
        p = f"{path}.{kind}"
        if kind == "color":
            rgba = self.color(obj["color"], p)
            return None if rgba is None else Paint("color", rgba=rgba)
        g = self.dict_(obj[kind], p, f'an object like {{"stops": [[0, "#RRGGBB"], [1, "#RRGGBB"]]}}')
        if g is None:
            return None
        if kind == "linear":
            self.keys(g, p, {"stops", "angle"}, {"direction": "use 'angle' (0 = left to right, 90 = top to bottom)",
                                                 "rotation": "=angle", "colors": "=stops"})
            angle = self.num(g, "angle", p, -3600, 3600, default=90.0)
            stops = self.stops(g.get("stops"), f"{p}.stops") if "stops" in g else None
            if "stops" not in g:
                self.bad(p, "'stops' is required")
            if stops is None or angle is None:
                return None
            return Paint("linear", stops=stops, angle=angle)
        self.keys(g, p, {"stops", "center", "radius"}, {"colors": "=stops", "centre": "=center"})
        center = self.pair(g, "center", p, default=None)
        radius: tuple[float, float] | None = None
        if g.get("radius") is not None:
            r = g["radius"]
            if isinstance(r, (list, tuple)):
                rr = self.numbers(r, f"{p}.radius", 2, 0.01, COORD_LIMIT, "a radius or [rx, ry]")
                radius = None if rr is None else (rr[0], rr[1])
            else:
                r1 = self.number(r, f"{p}.radius", 0.01, COORD_LIMIT)
                radius = None if r1 is None else (r1, r1)
            if radius is None:
                return None
        stops = self.stops(g.get("stops"), f"{p}.stops") if "stops" in g else None
        if "stops" not in g:
            self.bad(p, "'stops' is required")
        if stops is None:
            return None
        return Paint("radial", stops=stops, center=center, radius=radius)

    def noise(self, v: Any, path: str) -> dict | None:
        d = self.dict_(v, path, 'an object like {"amount": 0.15, "scale": 6}')
        if d is None:
            return None
        self.keys(d, path, {"amount", "scale", "octaves", "seed", "target"},
                  {"strength": "=amount", "size": "=scale", "channel": "=target", "mode": "=target"})
        out = {"amount": self.num(d, "amount", path, 0.0, 1.0, default=0.15),
               "scale": self.num(d, "scale", path, 0.5, 1024.0, default=8.0),
               "octaves": self.num(d, "octaves", path, 1, 6, default=3, integer=True),
               "seed": self.num(d, "seed", path, 0, 2 ** 31 - 1, default=0, integer=True),
               "target": self.enum(d, "target", path, ("color", "alpha"), "color")}
        return None if any(x is None for x in out.values()) else out

    # -------------------------------------------------------------------------------------- effects

    def effects(self, v: Any, path: str, kind: str) -> list[dict] | None:
        items = v if isinstance(v, list) else [v]
        if not (1 <= len(items) <= MAX_EFFECTS):
            self.bad(path, f"expected one {kind} object or a list of 1..{MAX_EFFECTS}")
            return None
        out = []
        for i, e in enumerate(items):
            p = f"{path}[{i}]" if isinstance(v, list) else path
            d = self.dict_(e, p, f"a {kind} object")
            if d is None:
                out.append(None)
                continue
            if kind == "shadow":
                self.keys(d, p, {"offset", "blur", "color", "spread"}, _SUB_HINTS)
                eff = {"offset": self.pair(d, "offset", p, default=(0.0, 2.0), lo=-512, hi=512),
                       "blur": self.num(d, "blur", p, 0, MAX_BLUR, default=4.0),
                       "color": self.color(d["color"], f"{p}.color") if d.get("color") is not None
                       else parse_color("#00000080"),
                       "spread": self.num(d, "spread", p, -256, 256, default=0.0)}
            elif kind == "glow":
                self.keys(d, p, {"blur", "color", "strength", "spread"}, _SUB_HINTS)
                eff = {"blur": self.num(d, "blur", p, 0, MAX_BLUR, default=8.0),
                       "color": self.color(d["color"], f"{p}.color") if d.get("color") is not None
                       else parse_color("#FFFFFF"),
                       "strength": self.num(d, "strength", p, 0, 16, default=1.0),
                       "spread": self.num(d, "spread", p, -256, 256, default=0.0)}
            else:
                self.keys(d, p, {"offset", "blur", "color"}, _SUB_HINTS)
                eff = {"offset": self.pair(d, "offset", p, default=(0.0, 2.0), lo=-512, hi=512),
                       "blur": self.num(d, "blur", p, 0, MAX_BLUR, default=3.0),
                       "color": self.color(d["color"], f"{p}.color") if d.get("color") is not None
                       else parse_color("#00000066")}
            out.append(None if any(x is None for x in eff.values()) else eff)
        return None if any(e is None for e in out) else out

    def stroke(self, v: Any, path: str) -> dict | None:
        d = self.dict_(v, path, 'an object like {"width": 2, "color": "#FFFFFF"}')
        if d is None:
            return None
        self.keys(d, path, {"width", "align", "color", "linear", "radial"}, _SUB_HINTS)
        width = self.num(d, "width", path, 0.01, 256)
        align = self.enum(d, "align", path, ALIGNS, "inside")
        paint = self.paint(d, path)
        if paint is None and not any(d.get(k) is not None for k in _PAINT_KEYS):
            self.bad(path, "needs a paint: 'color' (or 'linear' / 'radial')")
        if width is None or align is None or paint is None:
            return None
        return {"width": width, "align": align, "paint": paint}

    # -------------------------------------------------------------------------------------- shapes

    def shape_params(self, d: dict, path: str, shape: str, w: int, h: int) -> dict | None:
        c = self
        mid = (w / 2.0, h / 2.0)
        half = min(w, h) / 2.0
        L = COORD_LIMIT
        out: dict[str, Any] = {}
        if shape == "fill":
            return out
        if shape == "rect":
            out["box"] = c.box(d, path, (0.0, 0.0, float(w), float(h)))
        elif shape == "rounded_rect":
            out["box"] = c.box(d, path, (0.0, 0.0, float(w), float(h)))
            if d.get("radius") is not None and d.get("radii") is not None:
                c.bad(path, "give 'radius' or 'radii', not both")
                return None
            if d.get("radii") is not None:
                r = c.numbers(d["radii"], f"{path}.radii", 4, 0, L, "[top_left, top_right, bottom_right, bottom_left]")
                out["radii"] = None if r is None else tuple(r)
            elif d.get("radius") is not None:
                r1 = c.number(d["radius"], f"{path}.radius", 0, L)
                out["radii"] = None if r1 is None else (r1,) * 4
            else:
                c.bad(path, "rounded_rect needs 'radius' (px) or 'radii' ([top_left, top_right, bottom_right, "
                            "bottom_left])")
                return None
        elif shape == "ellipse":
            if d.get("box") is not None and (d.get("center") is not None or d.get("radius") is not None):
                c.bad(path, "give 'box', or 'center' + 'radius', not both")
                return None
            if d.get("box") is None and (d.get("center") is not None or d.get("radius") is not None):
                cen = c.pair(d, "center", path, default=mid)
                r = d.get("radius")
                if r is None:
                    c.bad(path, "'radius' is required with 'center' (a number or [rx, ry])")
                    return None
                if isinstance(r, (list, tuple)):
                    rr = c.numbers(r, f"{path}.radius", 2, 0.01, L, "a radius or [rx, ry]")
                else:
                    r1 = c.number(r, f"{path}.radius", 0.01, L)
                    rr = None if r1 is None else [r1, r1]
                if cen is None or rr is None:
                    return None
                out["box"] = (cen[0] - rr[0], cen[1] - rr[1], cen[0] + rr[0], cen[1] + rr[1])
            else:
                out["box"] = c.box(d, path, (0.0, 0.0, float(w), float(h)))
        elif shape == "circle":
            out["center"] = c.pair(d, "center", path, default=mid)
            out["radius"] = c.num(d, "radius", path, 0.01, L, default=half)
        elif shape == "ring":
            if d.get("outer") is not None and d.get("radius") is not None:
                c.bad(path, "give 'outer' (or its alias 'radius'), not both")
                return None
            key = "outer" if d.get("outer") is not None else "radius"
            out["center"] = c.pair(d, "center", path, default=mid)
            out["outer"] = c.num(d, key, path, 0.01, L, default=half)
            out["inner"] = c.num(d, "inner", path, 0, L, why=" (inner radius in px)")
            if out["outer"] is not None and out["inner"] is not None and out["inner"] >= out["outer"]:
                c.bad(path, f"inner ({_fmt(out['inner'])}) must be smaller than outer ({_fmt(out['outer'])})")
                return None
        elif shape == "polygon":
            out["points"] = c.points(d, "points", path, 3, "[[x, y], ...] at least 3")
        elif shape == "star":
            out["center"] = c.pair(d, "center", path, default=mid)
            out["radius"] = c.num(d, "radius", path, 0.01, L, default=half)
            out["points"] = c.num(d, "points", path, 3, 64, default=5, integer=True)
            out["inner"] = c.num(d, "inner", path, 0.05, 1.0, default=0.5)
            out["rotation"] = c.num(d, "rotation", path, -3600, 3600, default=0.0)
        elif shape in ("line", "polyline"):
            out["points"] = c.points(d, "points", path, 2, "[[x, y], ...] at least 2")
            out["width"] = c.num(d, "width", path, 0.01, MAX_WIDTH)
            out["taper"] = c.num(d, "taper", path, 0, MAX_WIDTH, default=out["width"])
            out["cap"] = c.enum(d, "cap", path, CAPS, "round")
            sm = d.get("smooth")
            sm = False if sm is None else sm
            if not isinstance(sm, bool):
                c.bad(f"{path}.smooth", f"expected true or false, got {_short(sm)}")
                return None
            out["smooth"] = sm
        elif shape == "arc":
            out["center"] = c.pair(d, "center", path, default=mid)
            out["radius"] = c.num(d, "radius", path, 0.01, L)
            out["start"] = c.num(d, "start", path, -3600, 3600, default=0.0)
            out["end"] = c.num(d, "end", path, -3600, 3600)
            out["width"] = c.num(d, "width", path, 0.01, MAX_WIDTH)
            out["taper"] = c.num(d, "taper", path, 0, MAX_WIDTH, default=out["width"])
            out["cap"] = c.enum(d, "cap", path, CAPS, "round")
            if out["start"] is not None and out["end"] is not None and abs(out["end"] - out["start"]) > 360:
                c.bad(path, "an arc spans at most 360 degrees (end - start)")
                return None
        elif shape == "rays":
            out["center"] = c.pair(d, "center", path, default=mid)
            out["count"] = c.num(d, "count", path, 1, 256, integer=True)
            out["inner"] = c.num(d, "inner", path, 0, L, default=0.0)
            out["outer"] = c.num(d, "outer", path, 0.01, L, default=half)
            out["width"] = c.num(d, "width", path, 0, MAX_WIDTH, default=4.0)
            out["taper"] = c.num(d, "taper", path, 0, MAX_WIDTH, default=0.0)
            out["rotation"] = c.num(d, "rotation", path, -3600, 3600, default=0.0)
            out["cap"] = c.enum(d, "cap", path, CAPS, "flat")
            out["jitter"] = c.num(d, "jitter", path, 0, 1, default=0.0)
            out["seed"] = c.num(d, "seed", path, 0, 2 ** 31 - 1, default=0, integer=True)
            if out["inner"] is not None and out["outer"] is not None and out["inner"] >= out["outer"]:
                c.bad(path, f"inner ({_fmt(out['inner'])}) must be smaller than outer ({_fmt(out['outer'])})")
                return None
            if out["width"] == 0 and out["taper"] == 0:
                c.bad(path, "rays need a width (at the inner end) or a taper (width at the outer end)")
                return None
        return None if any(v is None for v in out.values()) else out

    def layer(self, v: Any, path: str, w: int, h: int) -> LayerSpec | None:
        d = self.dict_(v, path, 'a layer object like {"shape": "circle", "radius": 20, "color": "#FFFFFF"}')
        if d is None:
            return None
        shape = d.get("shape")
        if shape not in SHAPE_KEYS:
            if shape is None:
                hint = " (use 'shape', not 'type')" if "type" in d else ""
                self.bad(path, f"'shape' is required{hint}: one of {', '.join(SHAPES)}")
            else:
                close = difflib.get_close_matches(str(shape), SHAPES, n=1, cutoff=0.5)
                extra = f" (did you mean '{close[0]}'?)" if close else f": use one of {', '.join(SHAPES)}"
                self.bad(f"{path}.shape", f"unknown shape {_short(shape)}{extra}")
            return None
        if shape == "fill":
            allowed = _FILL_LAYER_KEYS
            for k in ("stroke", "shadow", "glow", "inner_shadow", "blur", "rotate"):
                if k in d:
                    self.bad(path, f"a fill covers the whole texture, so it takes no '{k}' "
                                   f"(use a rect for a frame; turn a gradient with its 'angle')")
            allowed = allowed | {k for k in d if k in _LAYER_KEYS}   # reported above, not twice
        else:
            allowed = _LAYER_KEYS | SHAPE_KEYS[shape]
        self.keys(d, path, allowed, _LAYER_HINTS)
        params = self.shape_params(d, path, shape, w, h)
        paint = self.paint(d, path)
        painted = any(d.get(k) is not None for k in _PAINT_KEYS)
        noise = self.noise(d["noise"], f"{path}.noise") if d.get("noise") is not None else None
        if d.get("noise") is not None and not painted:
            self.bad(f"{path}.noise", "noise modifies the layer's fill: give the layer a color, linear or radial")
        stroke = self.stroke(d["stroke"], f"{path}.stroke") if d.get("stroke") is not None else None
        if not painted and d.get("stroke") is None:
            if shape == "fill":
                self.bad(path, "a fill needs 'color', 'linear' or 'radial'")
            else:
                self.bad(path, "draws nothing: give it a fill ('color', 'linear' or 'radial') or a 'stroke'")
        opacity = self.num(d, "opacity", path, 0, 1, default=1.0)
        blend = self.enum(d, "blend", path, BLENDS, "normal")
        blur = self.num(d, "blur", path, 0, MAX_BLUR, default=0.0)
        rotate = self.num(d, "rotate", path, -3600, 3600, default=0.0)
        shadows = self.effects(d["shadow"], f"{path}.shadow", "shadow") if d.get("shadow") is not None else []
        glows = self.effects(d["glow"], f"{path}.glow", "glow") if d.get("glow") is not None else []
        inner = self.effects(d["inner_shadow"], f"{path}.inner_shadow", "inner_shadow") \
            if d.get("inner_shadow") is not None else []
        if None in (params, opacity, blend, blur, rotate, shadows, glows, inner):
            return None
        if (painted and paint is None) or (d.get("stroke") is not None and stroke is None):
            return None
        if (d.get("noise") is not None and noise is None) or (not painted and d.get("stroke") is None):
            return None
        return LayerSpec(shape, params, paint, noise, opacity, blend, blur, rotate, stroke,  # type: ignore[arg-type]
                         shadows, glows, inner)


def validate(spec: Any) -> TextureSpec:
    """Check a spec and return it normalized (defaults filled in). Raises SpecError listing every problem."""
    c = _Checker()
    if not isinstance(spec, dict):
        raise SpecError([f"the spec must be an object like {{\"size\": [64, 64], \"layers\": [...]}}, "
                         f"got {_short(spec)}"])
    c.keys(spec, "", _TOP_KEYS, _TOP_HINTS)
    w = h = None
    size = spec.get("size")
    if size is None:
        c.bad("size", "is required: [width, height], each 8..1024")
    elif not (isinstance(size, (list, tuple)) and len(size) == 2):
        c.bad("size", f"expected [width, height], each {MIN_SIDE}..{MAX_SIDE}, got {_short(size)}")
    else:
        w = c.number(size[0], "size[0]", MIN_SIDE, MAX_SIDE, integer=True)
        h = c.number(size[1], "size[1]", MIN_SIDE, MAX_SIDE, integer=True)
    fmt = c.enum(spec, "format", "", FORMATS, "RGBA")
    ss = c.num(spec, "supersample", "", 1, MAX_SUPERSAMPLE, default=DEFAULT_SUPERSAMPLE, integer=True)
    slc = None
    if spec.get("slice") is not None:
        v = spec["slice"]
        slc = c.numbers(v, "slice", 4, 0, MAX_SIDE, "[x0, y0, x1, y1], the stretchable centre in pixels")
        if slc is not None:
            if any(float(x) != int(x) for x in slc):
                c.bad("slice", f"use whole pixels, got {_short(v)}")
                slc = None
            elif w is not None and h is not None and not (0 <= slc[0] < slc[2] <= w and 0 <= slc[1] < slc[3] <= h):
                c.bad("slice", f"needs 0 <= x0 < x1 <= {w} and 0 <= y0 < y1 <= {h} (the centre rectangle's edges, "
                               f"not insets), got {_short(v)}")
                slc = None
            else:
                slc = [int(x) for x in slc]
    layers_in = spec.get("layers")
    layers: list[LayerSpec | None] = []
    if not isinstance(layers_in, list) or not layers_in:
        c.bad("layers", f"expected a list of 1..{MAX_LAYERS} layers, got {_short(layers_in)}")
    elif len(layers_in) > MAX_LAYERS:
        c.bad("layers", f"at most {MAX_LAYERS} layers, got {len(layers_in)}")
    else:   # checked even when the size is bad (with a stand-in size), so every problem is reported at once
        layers = [c.layer(v, f"layers[{i}]", w or 64, h or 64) for i, v in enumerate(layers_in)]
    if c.problems:
        raise SpecError(c.problems)
    return TextureSpec(int(w), int(h), fmt, slc, int(ss), layers)  # type: ignore[arg-type]


# ------------------------------------------------------------------------------------------------ geometry
# Geometry is a list of ops (points (n, 2) in output px, add: bool) drawn in order into one mask; erase ops cut.
# `offset(d)` returns the shape grown (d > 0) or shrunk (d < 0) by d px: strokes, spread and the effects' shapes.

_FULL = None


def _nseg(r_ss: float) -> int:
    """Polygon segments for a circle of radius r_ss (supersampled px): error stays under ~1/4 px."""
    return int(min(720, max(8, math.ceil(math.pi * math.sqrt(2.0 * max(r_ss, 0.5))) + 4)))


def _disk(cx: float, cy: float, r: float, ss: int) -> np.ndarray:
    a = np.linspace(0.0, 2.0 * math.pi, _nseg(r * ss), endpoint=False)
    return np.stack([cx + r * np.cos(a), cy + r * np.sin(a)], axis=1)


def _rounded_rect_pts(x0: float, y0: float, x1: float, y1: float, radii: tuple, ss: int) -> np.ndarray:
    tl, tr, br, bl = (max(0.0, r) for r in radii)
    w, h = x1 - x0, y1 - y0
    f = min([1.0] + [side / s for side, s in ((w, tl + tr), (w, bl + br), (h, tl + bl), (h, tr + br)) if s > 0])
    tl, tr, br, bl = tl * f, tr * f, br * f, bl * f
    pts = []
    for cx, cy, r, a0 in ((x0 + tl, y0 + tl, tl, 180.0), (x1 - tr, y0 + tr, tr, 270.0),
                          (x1 - br, y1 - br, br, 0.0), (x0 + bl, y1 - bl, bl, 90.0)):
        if r <= 1e-6:
            pts.append(np.array([[cx, cy]]))
            continue
        n = max(2, _nseg(r * ss) // 4 + 1)
        a = np.radians(np.linspace(a0, a0 + 90.0, n))
        pts.append(np.stack([cx + r * np.cos(a), cy + r * np.sin(a)], axis=1))
    return np.vstack(pts)


def _band(pts: np.ndarray, r: float, add: bool, ss: int, closed: bool = True) -> list:
    """Ops covering every point within r of the polyline `pts` (the boundary of a polygon when closed)."""
    ops: list = []
    if r <= 0:
        return ops
    q = np.roll(pts, -1, axis=0) if closed else pts[1:]
    p = pts if closed else pts[:-1]
    d = q - p
    ln = np.hypot(d[:, 0], d[:, 1])
    keep = ln > 1e-9
    n = np.zeros_like(d)
    n[keep] = np.stack([-d[keep, 1], d[keep, 0]], axis=1) / ln[keep, None] * r
    for i in np.flatnonzero(keep):
        ops.append((np.array([p[i] + n[i], q[i] + n[i], q[i] - n[i], p[i] - n[i]]), add))
    for x, y in pts:
        ops.append((_disk(x, y, r, ss), add))
    return ops


def _hull(x1: float, y1: float, r1: float, x2: float, y2: float, r2: float) -> np.ndarray | None:
    """The quad between the outer tangents of two circles (with the circles, their convex hull)."""
    dx, dy = x2 - x1, y2 - y1
    dist = math.hypot(dx, dy)
    if dist <= 1e-9 or dist <= abs(r1 - r2):
        return None
    th = math.atan2(dy, dx)
    ph = math.acos(max(-1.0, min(1.0, (r1 - r2) / dist)))
    a, b = th + ph, th - ph
    return np.array([[x1 + r1 * math.cos(a), y1 + r1 * math.sin(a)], [x2 + r2 * math.cos(a), y2 + r2 * math.sin(a)],
                     [x2 + r2 * math.cos(b), y2 + r2 * math.sin(b)], [x1 + r1 * math.cos(b), y1 + r1 * math.sin(b)]])


def _flat_quad(x1: float, y1: float, r1: float, x2: float, y2: float, r2: float) -> np.ndarray | None:
    dx, dy = x2 - x1, y2 - y1
    dist = math.hypot(dx, dy)
    if dist <= 1e-9:
        return None
    nx, ny = -dy / dist, dx / dist
    return np.array([[x1 + nx * r1, y1 + ny * r1], [x2 + nx * r2, y2 + ny * r2],
                     [x2 - nx * r2, y2 - ny * r2], [x1 - nx * r1, y1 - ny * r1]])


def _chain_ops(nodes: np.ndarray, cap: str, d: float, ss: int) -> list:
    """A stroke through nodes (x, y, radius): round joins, round or flat ends, radii grown by d."""
    ops: list = []
    r = np.maximum(nodes[:, 2] + d, 0.0)
    n = len(nodes)
    # Flat ends: a join disk within one radius of an end would stick out past it like a round cap, so nodes that
    # close to an end get no disk and the segments touching them are square-ended quads.
    s = np.concatenate([[0.0], np.cumsum(np.hypot(*np.diff(nodes[:, :2], axis=0).T))])
    if cap == "flat":
        near_end = (s < r) | (s[-1] - s < r)
        near_end[0] = near_end[-1] = True
    else:
        near_end = np.zeros(n, dtype=bool)
    for i in range(n - 1):
        (xa, ya), (xb, yb) = nodes[i, :2], nodes[i + 1, :2]
        if r[i] <= 0 and r[i + 1] <= 0:
            continue
        square = near_end[i] or near_end[i + 1]
        quad = _flat_quad(xa, ya, r[i], xb, yb, r[i + 1]) if square else _hull(xa, ya, r[i], xb, yb, r[i + 1])
        if quad is not None:
            ops.append((quad, True))
    for i in range(n):
        if r[i] > 0 and not near_end[i]:
            ops.append((_disk(nodes[i, 0], nodes[i, 1], r[i], ss), True))
    return ops


def _catmull_rom(pts: np.ndarray, per: int = 12) -> np.ndarray:
    if len(pts) < 3:
        return pts
    ext = np.vstack([2 * pts[0] - pts[1], pts, 2 * pts[-1] - pts[-2]])
    t = np.linspace(0.0, 1.0, per, endpoint=False)[:, None]
    out = []
    for i in range(len(pts) - 1):
        p0, p1, p2, p3 = ext[i], ext[i + 1], ext[i + 2], ext[i + 3]
        out.append(0.5 * (2 * p1 + (p2 - p0) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t
                          + (-p0 + 3 * p1 - 3 * p2 + p3) * t * t * t))
    out.append(pts[-1:])
    return np.vstack(out)


def _taper_nodes(pts: np.ndarray, w0: float, w1: float) -> np.ndarray:
    seg = np.hypot(*np.diff(pts, axis=0).T)
    s = np.concatenate([[0.0], np.cumsum(seg)])
    total = s[-1] if s[-1] > 0 else 1.0
    radii = (w0 + (w1 - w0) * (s / total)) / 2.0
    return np.column_stack([pts, radii])


def _clock(cx: float, cy: float, r: float, deg: np.ndarray | float) -> np.ndarray:
    """Points at angles measured clockwise from 12 o'clock."""
    a = np.radians(deg)
    return np.stack([cx + r * np.sin(a), cy - r * np.cos(a)], axis=-1)


def _u01(i: int, seed: int) -> float:
    h = _hash_u32(np.array([i], dtype=np.int64), np.array([7], dtype=np.int64), seed)
    return float(h[0]) / 4294967296.0


class Geometry:
    """A layer's shape: ops at any offset, a local bounding box (the gradient frame), a pivot and a rotation."""

    def __init__(self, kind: str, bbox: tuple, pivot: tuple, rot: float, ss: int) -> None:
        self.kind = kind
        self.bbox = tuple(float(v) for v in bbox)
        self.pivot = (float(pivot[0]), float(pivot[1]))
        self.rot = float(rot)
        self.ss = ss

    def local_ops(self, d: float) -> list:
        raise NotImplementedError

    def ops(self, d: float) -> list:
        ops = self.local_ops(d)
        if self.rot % 360.0 == 0.0:
            return ops
        th = math.radians(self.rot)
        rot = np.array([[math.cos(th), math.sin(th)], [-math.sin(th), math.cos(th)]])   # row-vector form
        piv = np.array(self.pivot)
        return [(p if p is _FULL else (p - piv) @ rot + piv, add) for p, add in ops]

    def extent(self, grow: float) -> tuple[float, float, float, float]:
        """Axis-aligned bounds of the rotated shape grown by `grow` px."""
        x0, y0, x1, y1 = self.bbox
        g = max(0.0, grow)
        corners = np.array([[x0 - g, y0 - g], [x1 + g, y0 - g], [x1 + g, y1 + g], [x0 - g, y1 + g]])
        if self.rot % 360.0 != 0.0:
            th = math.radians(self.rot)
            rot = np.array([[math.cos(th), math.sin(th)], [-math.sin(th), math.cos(th)]])
            corners = (corners - np.array(self.pivot)) @ rot + np.array(self.pivot)
        return (float(corners[:, 0].min()), float(corners[:, 1].min()), float(corners[:, 0].max()),
                float(corners[:, 1].max()))


class _Full(Geometry):
    def local_ops(self, d: float) -> list:
        return [(_FULL, True)]


class _RoundRect(Geometry):
    def __init__(self, box: tuple, radii: tuple, rot: float, ss: int) -> None:
        super().__init__("rect", box, ((box[0] + box[2]) / 2, (box[1] + box[3]) / 2), rot, ss)
        self.box = box
        w, h = box[2] - box[0], box[3] - box[1]
        tl, tr, br, bl = radii
        f = min([1.0] + [side / s for side, s in ((w, tl + tr), (w, bl + br), (h, tl + bl), (h, tr + br)) if s > 0])
        self.radii = tuple(r * f for r in radii)

    def local_ops(self, d: float) -> list:
        x0, y0, x1, y1 = self.box
        x0, y0, x1, y1 = x0 - d, y0 - d, x1 + d, y1 + d
        if x1 - x0 <= 1e-6 or y1 - y0 <= 1e-6:
            return []
        radii = tuple(max(0.0, r + d) for r in self.radii)
        return [(_rounded_rect_pts(x0, y0, x1, y1, radii, self.ss), True)]


class _Circle(Geometry):
    def __init__(self, center: tuple, r: float, rot: float, ss: int) -> None:
        cx, cy = center
        super().__init__("circle", (cx - r, cy - r, cx + r, cy + r), center, rot, ss)
        self.c, self.r = center, r

    def local_ops(self, d: float) -> list:
        r = self.r + d
        return [(_disk(self.c[0], self.c[1], r, self.ss), True)] if r > 0 else []


class _Ring(Geometry):
    def __init__(self, center: tuple, outer: float, inner: float, rot: float, ss: int) -> None:
        cx, cy = center
        super().__init__("ring", (cx - outer, cy - outer, cx + outer, cy + outer), center, rot, ss)
        self.c, self.outer, self.inner = center, outer, inner

    def local_ops(self, d: float) -> list:
        ro, ri = self.outer + d, self.inner - d
        if ro <= 0 or ri >= ro:
            return []
        ops = [(_disk(self.c[0], self.c[1], ro, self.ss), True)]
        if ri > 0:
            ops.append((_disk(self.c[0], self.c[1], ri, self.ss), False))
        return ops


class _Polygon(Geometry):
    def __init__(self, pts: np.ndarray, pivot: tuple | None, rot: float, ss: int, bbox: tuple | None = None) -> None:
        bb = bbox or (pts[:, 0].min(), pts[:, 1].min(), pts[:, 0].max(), pts[:, 1].max())
        super().__init__("polygon", bb, pivot or ((bb[0] + bb[2]) / 2, (bb[1] + bb[3]) / 2), rot, ss)
        self.pts = pts

    def local_ops(self, d: float) -> list:
        ops = [(self.pts, True)]
        if d > 0:
            ops += _band(self.pts, d, True, self.ss)
        elif d < 0:
            ops += _band(self.pts, -d, False, self.ss)
        return ops


class _Chains(Geometry):
    def __init__(self, chains: list[np.ndarray], cap: str, bbox: tuple, pivot: tuple, rot: float, ss: int) -> None:
        super().__init__("chain", bbox, pivot, rot, ss)
        self.chains, self.cap = chains, cap

    def local_ops(self, d: float) -> list:
        ops: list = []
        for nodes in self.chains:
            ops += _chain_ops(nodes, self.cap, d, self.ss)
        return ops


def build_geometry(layer: LayerSpec, w: int, h: int, ss: int) -> Geometry:
    p, rot = layer.params, layer.rotate
    s = layer.shape
    if s == "fill":
        return _Full("fill", (0, 0, w, h), (w / 2, h / 2), 0.0, ss)
    if s == "rect":
        return _RoundRect(p["box"], (0.0, 0.0, 0.0, 0.0), rot, ss)
    if s == "rounded_rect":
        return _RoundRect(p["box"], p["radii"], rot, ss)
    if s == "circle":
        return _Circle(p["center"], p["radius"], rot, ss)
    if s == "ring":
        return _Ring(p["center"], p["outer"], p["inner"], rot, ss)
    if s == "ellipse":
        x0, y0, x1, y1 = p["box"]
        cx, cy, rx, ry = (x0 + x1) / 2, (y0 + y1) / 2, (x1 - x0) / 2, (y1 - y0) / 2
        a = np.linspace(0.0, 2 * math.pi, _nseg(max(rx, ry) * ss), endpoint=False)
        pts = np.stack([cx + rx * np.cos(a), cy + ry * np.sin(a)], axis=1)
        return _Polygon(pts, (cx, cy), rot, ss, bbox=p["box"])
    if s == "polygon":
        return _Polygon(p["points"], None, rot, ss)
    if s == "star":
        n, cx, cy, r = p["points"], p["center"][0], p["center"][1], p["radius"]
        k = np.arange(2 * n)
        radii = np.where(k % 2 == 0, r, r * p["inner"])
        ang = np.radians(p["rotation"] + k * 180.0 / n)
        pts = np.stack([cx + radii * np.sin(ang), cy - radii * np.cos(ang)], axis=1)
        return _Polygon(pts, (cx, cy), rot, ss, bbox=(cx - r, cy - r, cx + r, cy + r))
    if s in ("line", "polyline"):
        pts = p["points"]
        if p["smooth"]:
            pts = _catmull_rom(pts)
        nodes = _taper_nodes(pts, p["width"], p["taper"])
        m = max(p["width"], p["taper"]) / 2
        bb = (pts[:, 0].min() - m, pts[:, 1].min() - m, pts[:, 0].max() + m, pts[:, 1].max() + m)
        return _Chains([nodes], p["cap"], bb, ((bb[0] + bb[2]) / 2, (bb[1] + bb[3]) / 2), rot, ss)
    if s == "arc":
        (cx, cy), r = p["center"], p["radius"]
        sweep = p["end"] - p["start"]
        n = int(min(720, max(2, math.ceil(abs(sweep) / 360.0 * _nseg(r * ss) * 2)))) + 1
        pts = _clock(cx, cy, r, np.linspace(p["start"], p["end"], n))
        nodes = _taper_nodes(pts, p["width"], p["taper"])
        m = r + max(p["width"], p["taper"]) / 2
        return _Chains([nodes], p["cap"], (cx - m, cy - m, cx + m, cy + m), (cx, cy), rot, ss)
    if s == "rays":
        (cx, cy), n = p["center"], p["count"]
        chains = []
        for i in range(n):
            ang = p["rotation"] + i * 360.0 / n
            outer = p["outer"] * (1.0 - p["jitter"] * _u01(i, p["seed"]))
            a, b = _clock(cx, cy, p["inner"], ang), _clock(cx, cy, max(outer, p["inner"] + 1e-3), ang)
            chains.append(np.array([[a[0], a[1], p["width"] / 2], [b[0], b[1], p["taper"] / 2]]))
        m = p["outer"] + max(p["width"], p["taper"]) / 2
        return _Chains(chains, p["cap"], (cx - m, cy - m, cx + m, cy + m), (cx, cy), rot, ss)
    raise ValueError(f"unknown shape {s}")


def _fill(polys: list[np.ndarray], W: int, H: int) -> np.ndarray:
    """Union of polygons as a (H, W) bool mask: a pixel is in when its centre is (nonzero winding; each polygon is
    counted in its own orientation so overlaps add up). Exact point sampling: no edge bias, unlike ImageDraw."""
    p_list, q_list, o_list = [], [], []
    for q in polys:
        if len(q) < 3 or q[:, 1].max() < 0 or q[:, 1].min() > H or q[:, 0].min() > W or q[:, 0].max() < 0:
            continue                                   # nothing on any scanline, or all right / all left of it
        area2 = float(np.dot(q[:, 0], np.roll(q[:, 1], -1)) - np.dot(q[:, 1], np.roll(q[:, 0], -1)))
        if abs(area2) < 1e-9:
            continue
        p_list.append(q)
        q_list.append(np.roll(q, -1, axis=0))
        o_list.append(np.full(len(q), 1.0 if area2 > 0 else -1.0))
    if not p_list:
        return np.zeros((H, W), dtype=bool)
    P, Q, orient = np.concatenate(p_list), np.concatenate(q_list), np.concatenate(o_list)
    x0, y0, x1, y1 = P[:, 0], P[:, 1], Q[:, 0], Q[:, 1]
    # scanline j (pixel-centre row) crosses an edge when min(y) <= j < max(y)
    j0 = np.clip(np.ceil(np.minimum(y0, y1)), 0, H).astype(np.int64)
    j1 = np.clip(np.ceil(np.maximum(y0, y1)), 0, H).astype(np.int64)
    cnt = np.maximum(j1 - j0, 0)
    total = int(cnt.sum())
    if total == 0:
        return np.zeros((H, W), dtype=bool)
    e = np.repeat(np.arange(len(cnt)), cnt)
    J = j0[e] + (np.arange(total) - np.repeat(np.cumsum(cnt) - cnt, cnt))
    X = x0[e] + (J - y0[e]) * ((x1[e] - x0[e]) / (y1[e] - y0[e]))
    col = np.clip(np.ceil(X), 0, W).astype(np.int64)         # pixels whose centre is at or right of the crossing
    sign = np.where(y1[e] < y0[e], 1.0, -1.0) * orient[e]
    diff = np.bincount(J * (W + 1) + col, weights=sign, minlength=H * (W + 1)).reshape(H, W + 1)
    return np.abs(np.cumsum(diff[:, :W], axis=1)) > 0.5


def _raster(ops: list, rx0: int, ry0: int, wr: int, hr: int, ss: int) -> np.ndarray:
    """Draw ops into a (hr*ss, wr*ss) float mask (0 or 1) whose top-left is output pixel (rx0, ry0). Consecutive
    ops of the same kind are filled together; erase ops cut what was drawn before them."""
    W, H = wr * ss, hr * ss
    mask = np.zeros((H, W), dtype=bool)
    off = np.array([rx0, ry0], dtype=np.float64)
    i = 0
    while i < len(ops):
        add, full, group = ops[i][1], False, []
        while i < len(ops) and ops[i][1] == add:
            if ops[i][0] is _FULL:
                full = True
            else:
                group.append((ops[i][0] - off) * ss - 0.5)     # pixel (i, j) has its centre at (i, j) here
            i += 1
        cover = np.ones((H, W), dtype=bool) if full else _fill(group, W, H)
        if add:
            mask |= cover
        else:
            mask &= ~cover
    return mask.astype(np.float32)


# ------------------------------------------------------------------------------------------------ paint

def _hash_u32(ix: np.ndarray, iy: np.ndarray, seed: int) -> np.ndarray:
    x = (ix.astype(np.int64) & 0xFFFFFFFF).astype(np.uint32)
    y = (iy.astype(np.int64) & 0xFFFFFFFF).astype(np.uint32)
    s = np.uint32((int(seed) * 0x9E3779B1 + 0x7F4A7C15) & 0xFFFFFFFF)
    with np.errstate(over="ignore"):
        h = (x * np.uint32(0x8DA6B343)) ^ (y * np.uint32(0xD8163841)) ^ s
        h ^= h >> np.uint32(16)
        h *= np.uint32(0x7FEB352D)
        h ^= h >> np.uint32(15)
        h *= np.uint32(0x846CA68B)
        h ^= h >> np.uint32(16)
    return h


def value_noise(x: np.ndarray, y: np.ndarray, scale: float, octaves: int, seed: int) -> np.ndarray:
    """Deterministic fractal value noise in 0..1 at coordinates x, y (px); `scale` is the cell size in px. Octaves
    whose cells would be under half a pixel are skipped: they only add aliasing."""
    x, y = np.broadcast_arrays(np.asarray(x, dtype=np.float64), np.asarray(y, dtype=np.float64))
    total = np.zeros(x.shape, dtype=np.float64)
    amp, norm = 1.0, 0.0
    for o in range(octaves):
        cell = scale / (2.0 ** o)
        if o > 0 and cell < 0.5:
            break
        xs, ys = x / cell, y / cell
        x0, y0 = np.floor(xs), np.floor(ys)
        tx, ty = xs - x0, ys - y0
        tx = tx * tx * tx * (tx * (tx * 6 - 15) + 10)
        ty = ty * ty * ty * (ty * (ty * 6 - 15) + 10)
        ix, iy = x0.astype(np.int64), y0.astype(np.int64)
        lx, ly = int(ix.min()), int(iy.min())                   # hash each lattice point once, then gather
        gx = np.arange(lx, int(ix.max()) + 2, dtype=np.int64)
        gy = np.arange(ly, int(iy.max()) + 2, dtype=np.int64)
        lat = _hash_u32(gx[None, :], gy[:, None], seed * 31 + o) / 4294967296.0
        a, b = ix - lx, iy - ly
        top = lat[b, a] + (lat[b, a + 1] - lat[b, a]) * tx
        bot = lat[b + 1, a] + (lat[b + 1, a + 1] - lat[b + 1, a]) * tx
        total += (top + (bot - top) * ty) * amp
        norm += amp
        amp *= 0.5
    return (total / norm).astype(np.float32)


def _premul(rgba: tuple) -> np.ndarray:
    r, g, b, a = rgba
    return np.array([r * a, g * a, b * a, a], dtype=np.float32)


def _lut(stops: list) -> np.ndarray:
    pos = np.array([s[0] for s in stops], dtype=np.float64)
    cols = np.array([_premul(s[1]) for s in stops], dtype=np.float64)
    t = np.linspace(0.0, 1.0, LUT_SIZE)
    return np.stack([np.interp(t, pos, cols[:, ch]) for ch in range(4)], axis=1).astype(np.float32)


def _rotate_pt(p: tuple, pivot: tuple, deg: float) -> tuple[float, float]:
    th = math.radians(deg)
    dx, dy = p[0] - pivot[0], p[1] - pivot[1]
    return (pivot[0] + dx * math.cos(th) - dy * math.sin(th), pivot[1] + dx * math.sin(th) + dy * math.cos(th))


def _paint(paint: Paint, noise: dict | None, geom: Geometry, rx0: int, ry0: int, wr: int, hr: int,
           ss: int) -> np.ndarray:
    """Premultiplied paint over the region: (4,) for a flat colour without noise, else (hr*ss, wr*ss, 4)."""
    Ws, Hs = wr * ss, hr * ss
    if paint.kind == "color":
        out: np.ndarray = _premul(paint.rgba)
    else:
        xs = (rx0 + (np.arange(Ws, dtype=np.float64) + 0.5) / ss).astype(np.float32)
        ys = (ry0 + (np.arange(Hs, dtype=np.float64) + 0.5) / ss).astype(np.float32)
        bx0, by0, bx1, by1 = geom.bbox
        th = math.radians(geom.rot)
        if paint.kind == "linear":
            a = math.radians(paint.angle)
            half = (abs((bx1 - bx0) * math.cos(a)) + abs((by1 - by0) * math.sin(a))) / 2 or 1e-6
            gc = _rotate_pt(((bx0 + bx1) / 2, (by0 + by1) / 2), geom.pivot, geom.rot)
            ux, uy = math.cos(a + th), math.sin(a + th)
            t = 0.5 + ((xs - gc[0])[None, :] * ux + (ys - gc[1])[:, None] * uy) / (2 * half)
        else:
            c_local = paint.center or ((bx0 + bx1) / 2, (by0 + by1) / 2)
            rx, ry = paint.radius or (max((bx1 - bx0) / 2, 1e-6), max((by1 - by0) / 2, 1e-6))
            c = _rotate_pt(c_local, geom.pivot, geom.rot)
            dx, dy = (xs - c[0])[None, :], (ys - c[1])[:, None]
            u = (dx * math.cos(th) + dy * math.sin(th)) / rx
            v = (-dx * math.sin(th) + dy * math.cos(th)) / ry
            t = np.sqrt(u * u + v * v)
        t *= LUT_SIZE - 1
        np.rint(t, out=t)
        np.clip(t, 0, LUT_SIZE - 1, out=t)
        out = _lut(paint.stops)[t.astype(np.int32)]
        del t
    if noise is None or noise["amount"] <= 0:
        return out
    # noise lives on output pixels, in the layer's own frame, then covers each supersampled block
    xo = rx0 + np.arange(wr, dtype=np.float64) + 0.5
    yo = ry0 + np.arange(hr, dtype=np.float64) + 0.5
    X, Y = np.meshgrid(xo, yo)
    if geom.rot % 360.0 != 0.0:
        th = math.radians(-geom.rot)
        px, py = geom.pivot
        X, Y = (px + (X - px) * math.cos(th) - (Y - py) * math.sin(th),
                py + (X - px) * math.sin(th) + (Y - py) * math.cos(th))
    n = value_noise(X, Y, noise["scale"], noise["octaves"], noise["seed"])
    n = np.repeat(np.repeat(n, ss, axis=0), ss, axis=1)[..., None]
    if out.ndim == 1:
        out = np.broadcast_to(out, (Hs, Ws, 4)).astype(np.float32)
    amt = np.float32(noise["amount"])
    if noise["target"] == "alpha":
        n *= amt
        n += 1 - amt
        out *= n                                          # premultiplied: colour scales with alpha
    else:
        n -= np.float32(0.5)
        n *= amt
        n *= out[..., 3:4]
        out[..., :3] += n
        np.clip(out[..., :3], 0, out[..., 3:4], out=out[..., :3])
    return out


# ------------------------------------------------------------------------------------------------ filters

def _box_sizes(sigma: float, n: int = 3) -> list[int]:
    w_ideal = math.sqrt(12 * sigma * sigma / n + 1)
    wl = int(math.floor(w_ideal))
    if wl % 2 == 0:
        wl -= 1
    wu = wl + 2
    m_ideal = (12 * sigma * sigma - n * wl * wl - 4 * n * wl - 3 * n) / (-4 * wl - 4)
    m = round(m_ideal)
    return [wl if i < m else wu for i in range(n)]


def _box(a: np.ndarray, r: int, axis: int) -> np.ndarray:
    """Mean over a window of 2r+1 along an axis; zeros outside."""
    if r <= 0:
        return a
    pad = [(0, 0)] * a.ndim
    pad[axis] = (r + 1, r)
    c = np.cumsum(np.pad(a, pad), axis=axis, dtype=np.float32)
    n = a.shape[axis]
    hi = [slice(None)] * a.ndim
    lo = [slice(None)] * a.ndim
    hi[axis] = slice(2 * r + 1, 2 * r + 1 + n)
    lo[axis] = slice(0, n)
    return (c[tuple(hi)] - c[tuple(lo)]) * np.float32(1.0 / (2 * r + 1))


def _gauss(a: np.ndarray, sigma: float) -> np.ndarray:
    """Gaussian blur with standard deviation `sigma` (array px) over the first two axes; zeros outside."""
    if sigma <= 0:
        return a
    if a.ndim == 3:                                    # one channel at a time keeps the temporaries small
        out = np.empty_like(a)
        for ch in range(a.shape[2]):
            out[..., ch] = _gauss(np.ascontiguousarray(a[..., ch]), sigma)
        return out
    if sigma < 2.0:
        rad = int(math.ceil(3 * sigma))
        k = np.exp(-0.5 * (np.arange(-rad, rad + 1) / sigma) ** 2)
        k = (k / k.sum()).astype(np.float32)
        out = a
        for axis in (0, 1):
            pad = [(0, 0)] * a.ndim
            pad[axis] = (rad, rad)
            p = np.pad(out, pad)
            acc = np.zeros_like(out)
            n = out.shape[axis]
            for j, kv in enumerate(k):
                sl = [slice(None)] * a.ndim
                sl[axis] = slice(j, j + n)
                acc += kv * p[tuple(sl)]
            out = acc
        return out
    out = a
    for size in _box_sizes(sigma):
        out = _box(_box(out, (size - 1) // 2, 0), (size - 1) // 2, 1)
    return out


def _blur(a: np.ndarray, sigma: float, ss: int, inplace: bool = False) -> np.ndarray:
    """Blur a supersampled array by `sigma` output px. Wide blurs run at output resolution (they are smooth).
    inplace=True lets a wide blur reuse `a` for its result."""
    if sigma <= 0:
        return a
    if sigma * ss <= 12 or ss == 1:
        return _gauss(a, sigma * ss)
    h, w = a.shape[:2]
    small = _gauss(a.reshape(h // ss, ss, w // ss, ss, *a.shape[2:]).mean(axis=(1, 3), dtype=np.float32), sigma)
    if small.ndim == 2:
        return np.asarray(Image.fromarray(small).resize((w, h), Image.BILINEAR))
    out = a if inplace else np.empty_like(a)
    for ch in range(small.shape[2]):
        out[..., ch] = np.asarray(Image.fromarray(np.ascontiguousarray(small[..., ch])).resize((w, h), Image.BILINEAR))
    return out


def _shift(a: np.ndarray, dx: int, dy: int) -> np.ndarray:
    """Move content by (dx, dy) supersampled px, filling with zeros."""
    if dx == 0 and dy == 0:
        return a
    h, w = a.shape[:2]
    out = np.zeros_like(a)
    if abs(dx) >= w or abs(dy) >= h:
        return out
    out[max(dy, 0):h + min(dy, 0), max(dx, 0):w + min(dx, 0)] = a[max(-dy, 0):h - max(dy, 0),
                                                                   max(-dx, 0):w - max(dx, 0)]
    return out


# ------------------------------------------------------------------------------------------------ compositing

def _over_alpha(dst: np.ndarray, rgb: np.ndarray, alpha: np.ndarray) -> None:
    """dst = colour rgb (straight) at coverage alpha, over dst (premultiplied), in place."""
    dst *= (1 - alpha)[..., None]
    for ch in range(3):
        dst[..., ch] += rgb[ch] * alpha
    dst[..., 3] += alpha


def _blend(dst: np.ndarray, src: np.ndarray, mode: str) -> None:
    if mode == "normal":
        dst *= 1 - src[..., 3:4]
        dst += src
    elif mode == "add":
        dst += src
        np.minimum(dst, 1.0, out=dst)
    elif mode == "screen":
        dst[...] = src + dst - src * dst
    else:                                               # multiply
        sa, da = src[..., 3:4], dst[..., 3:4]
        rgb = src[..., :3] * (1 - da) + dst[..., :3] * (1 - sa) + src[..., :3] * dst[..., :3]
        dst[..., 3:4] = sa + da - sa * da
        dst[..., :3] = rgb


class _Deadline:
    """Raises SpecError once a render has run past TIME_LIMIT (checked before each costly step)."""

    def __init__(self) -> None:
        self.t0 = time.perf_counter()
        self.layer = 0

    def __call__(self) -> None:
        if time.perf_counter() - self.t0 > TIME_LIMIT:
            raise SpecError([f"layers[{self.layer}]: rendering took over {TIME_LIMIT:.0f} s; use fewer or smaller "
                             f"layers, smaller blurs, or a smaller size"])


def _draw_layer(canvas: np.ndarray, layer: LayerSpec, w: int, h: int, ss: int, deadline: _Deadline) -> None:
    geom = build_geometry(layer, w, h, ss)
    stroke = layer.stroke
    e_out = e_in = 0.0
    if stroke:
        sw = stroke["width"]
        e_out, e_in = {"inside": (0.0, -sw), "center": (sw / 2, -sw / 2), "outside": (sw, 0.0)}[stroke["align"]]
    has_fill = layer.paint is not None

    grow, blurs = max(e_out, 0.0), [3.0 * layer.blur]
    for s in layer.shadows:
        grow = max(grow, e_out + max(s["spread"], 0) + max(abs(s["offset"][0]), abs(s["offset"][1])) + 3 * s["blur"])
        blurs.append(3.0 * s["blur"] + max(abs(s["offset"][0]), abs(s["offset"][1])))
    for g in layer.glows:
        grow = max(grow, e_out + max(g["spread"], 0) + 3 * g["blur"])
        blurs.append(3.0 * g["blur"])
    grow = max(grow, e_out + 3.0 * layer.blur)
    edge = min(EDGE_MARGIN, int(math.ceil(max(blurs)))) if max(blurs) > 0 else 0
    if isinstance(geom, _Full):
        x0, y0, x1, y1 = 0.0, 0.0, float(w), float(h)
    else:
        x0, y0, x1, y1 = geom.extent(grow)
    rx0, ry0 = max(int(math.floor(x0)), -edge), max(int(math.floor(y0)), -edge)
    rx1, ry1 = min(int(math.ceil(x1)), w + edge), min(int(math.ceil(y1)), h + edge)
    if rx1 <= max(rx0, 0) or ry1 <= max(ry0, 0) or rx0 >= w or ry0 >= h:
        return
    wr, hr = rx1 - rx0, ry1 - ry0
    cx0, cy0, cx1, cy1 = max(rx0, 0), max(ry0, 0), min(rx1, w), min(ry1, h)
    dst = canvas[cy0 * ss:cy1 * ss, cx0 * ss:cx1 * ss]
    sl = (slice((cy0 - ry0) * ss, (cy1 - ry0) * ss), slice((cx0 - rx0) * ss, (cx1 - rx0) * ss))

    masks: dict[float, np.ndarray] = {}

    def mask(d: float) -> np.ndarray:
        d = round(d, 6)
        if d not in masks:
            masks[d] = _raster(geom.ops(d), rx0, ry0, wr, hr, ss)
        return masks[d]

    def coverage(spread: float) -> np.ndarray:
        """The layer's shape (fill plus stroke) grown by `spread`: what shadows and glows are cast from."""
        outer = mask(e_out + spread)
        if has_fill or not stroke:
            return outer
        return np.clip(outer - mask(e_in - spread), 0, 1)

    # beneath the layer: shadows, then glows (they need only the shape, so they go first and free their masks)
    opacity = np.float32(layer.opacity)
    for s in layer.shadows:
        deadline()
        cov = _blur(_shift(coverage(s["spread"]), int(round(s["offset"][0] * ss)), int(round(s["offset"][1] * ss))),
                    s["blur"], ss)[sl]
        alpha = np.clip(cov, 0, 1)
        alpha *= np.float32(s["color"][3]) * opacity
        _over_alpha(dst, np.array(s["color"][:3], dtype=np.float32), alpha)
    for g in layer.glows:
        deadline()
        cov = _blur(coverage(g["spread"]), g["blur"], ss)[sl] * np.float32(g["strength"])
        alpha = np.clip(cov, 0, 1)
        alpha *= np.float32(g["color"][3]) * opacity
        _over_alpha(dst, np.array(g["color"][:3], dtype=np.float32), alpha)
    keep = {round(d, 6) for d in (0.0, e_out, e_in)}
    for d in [d for d in masks if d not in keep]:
        del masks[d]

    # the layer itself: fill, inner shadows, stroke; then its blur and opacity
    deadline()
    S = np.clip(mask(e_out) - mask(e_in), 0, 1) if stroke else None
    M = mask(0.0) if has_fill else None
    masks.clear()                                         # S and M are all the layer needs from here on
    if has_fill:
        content = _paint(layer.paint, layer.noise, geom, rx0, ry0, wr, hr, ss)
        if content.ndim == 1:
            content = M[..., None] * content
        else:
            content *= M[..., None]                   # _paint returned a fresh array
    else:
        content = np.zeros((hr * ss, wr * ss, 4), dtype=np.float32)
    base = M if has_fill else S
    for ish in layer.inner_shadows:
        deadline()
        off = ish["offset"]
        lit = _blur(_shift(base, int(round(off[0] * ss)), int(round(off[1] * ss))), ish["blur"], ss)
        cov = base * np.clip(1 - lit, 0, 1)
        cov *= np.float32(ish["color"][3])
        _over_alpha(content, np.array(ish["color"][:3], dtype=np.float32), cov)
    if stroke:
        src = _paint(stroke["paint"], None, geom, rx0, ry0, wr, hr, ss)
        if src.ndim == 1:
            src = S[..., None] * src
        else:
            src *= S[..., None]                           # _paint returned a fresh array
        content *= 1 - src[..., 3:4]
        content += src
        del src
    if layer.blur > 0:
        deadline()
        content = _blur(content, layer.blur, ss, inplace=True)
    if layer.opacity < 1:
        content *= opacity
    _blend(dst, content[sl], layer.blend)


# ------------------------------------------------------------------------------------------------ output

def _bleed(rgb: np.ndarray, visible: np.ndarray, steps: int = 4) -> np.ndarray:
    """Give invisible pixels the average colour of visible neighbours (a few px deep), then the mean colour."""
    if visible.all() or not visible.any():
        return rgb
    rgb = rgb * visible[..., None]
    known = visible.copy()
    mean = rgb[visible].mean(axis=0)
    h, w = known.shape
    for _ in range(steps):
        k = known.astype(np.float32)
        pk = np.pad(k, 1)
        pc = np.pad(rgb * k[..., None], ((1, 1), (1, 1), (0, 0)))
        cnt = np.zeros((h, w), np.float32)
        acc = np.zeros((h, w, 3), np.float32)
        for dy in (0, 1, 2):
            for dx in (0, 1, 2):
                if dx == 1 and dy == 1:
                    continue
                cnt += pk[dy:dy + h, dx:dx + w]
                acc += pc[dy:dy + h, dx:dx + w]
        new = ~known & (cnt > 0)
        if not new.any():
            break
        rgb[new] = acc[new] / cnt[new][:, None]
        known |= new
    rgb[~known] = mean
    return rgb


def _finish(canvas: np.ndarray, w: int, h: int, ss: int) -> np.ndarray:
    """Supersampled premultiplied canvas -> straight RGBA8 array (h, w, 4)."""
    if ss > 1:
        small = np.stack([np.asarray(Image.fromarray(np.ascontiguousarray(canvas[..., ch]))
                                     .resize((w, h), Image.BOX)) for ch in range(4)], axis=2)
    else:
        small = canvas
    a = np.clip(small[..., 3], 0.0, 1.0)
    c = np.clip(small[..., :3], 0.0, a[..., None])
    a8 = np.rint(a * 255).astype(np.uint8)
    visible = a8 > 0
    rgb = np.where(a[..., None] > 1e-6, c / np.maximum(a[..., None], 1e-6), 0.0).astype(np.float32)
    rgb = _bleed(rgb, visible)
    out = np.empty((h, w, 4), np.uint8)
    out[..., :3] = np.rint(np.clip(rgb, 0, 1) * 255).astype(np.uint8)
    out[..., 3] = a8
    return out


def effective_supersample(w: int, h: int, requested: int) -> int:
    ss = max(1, int(requested))
    while ss > 1 and (max(w, h) * ss > SS_MAX_SIDE or w * h * ss * ss > SS_MAX_PIXELS):
        ss -= 1
    return ss


def render(spec: Any) -> Image.Image:
    """Validate and render a texture spec. Returns an RGBA or LA image; image.info["slice"] holds the 9-slice
    centre [x0, y0, x1, y1] (or None). Raises SpecError for a bad spec or one too slow to render."""
    ts = spec if isinstance(spec, TextureSpec) else validate(spec)
    w, h = ts.width, ts.height
    ss = effective_supersample(w, h, ts.supersample)
    canvas = np.zeros((h * ss, w * ss, 4), dtype=np.float32)
    deadline = _Deadline()
    for i, layer in enumerate(ts.layers):
        deadline.layer = i
        deadline()
        _draw_layer(canvas, layer, w, h, ss, deadline)
    arr = _finish(canvas, w, h, ss)
    img = Image.fromarray(arr)
    if ts.format == "LA":
        img = img.convert("LA")
    img.info["slice"] = list(ts.slice) if ts.slice else None
    return img


__all__ = ["BLENDS", "FORMATS", "SHAPES", "SHAPE_KEYS", "Geometry", "LayerSpec", "Paint", "SpecError", "TextureSpec",
           "effective_supersample", "parse_color", "render", "validate", "value_noise"]

"""Checks for Kit.VFX effect specs, offline: the same schema and rules as harness/kit/FxMath.luau (validateEffect /
validateTrail, which the game runs), so a builder sees every problem before the code runs, plus taste warnings drawn
from the VFX rubric. Specs are JSON: colours as "#RRGGBB" or "Tokens.color.<name>", vectors as [x, y, z].

    report = check_effect(spec)     # FxReport(errors=[...], warnings=[...]); errors read "layers[2].lifetime: ..."
    validate_effect(spec)           # just the errors
    check_trail(spec)               # a VFX.trail spec

tests/test_kit_fx.py runs both validators on one corpus and requires the same error paths from each.
"""
from __future__ import annotations

import json
import math
import re
from dataclasses import dataclass, field
from typing import Any, Callable, Iterable

# ---------------------------------------------------------------------------------------------- schema (= FxMath)
KINDS = ["particles", "beam", "light", "flash", "ring", "decal"]
EFFECT_KEYS = ["layers", "family", "budget"]
COMMON_KEYS = ["kind", "delay", "offset"]
LAYER_KEYS: dict[str, list[str]] = {
    "particles": ["count", "rate", "duration", "lifetime", "speed", "spread", "size", "transparency", "color",
                  "lightEmission", "lightInfluence", "brightness", "drag", "acceleration", "rotation", "rotSpeed",
                  "orientation", "squash", "zoffset", "flipbook", "texture", "direction", "shape", "lockedToPart",
                  "timeScale"],
    "beam": ["to", "from", "width", "color", "transparency", "texture", "textureSpeed", "textureLength",
             "textureMode", "lightEmission", "lightInfluence", "brightness", "curve", "segments", "faceCamera",
             "zoffset", "duration", "fadeOut"],
    "light": ["color", "brightness", "range", "duration", "attack", "shadows", "spot"],
    "flash": ["shape", "mesh", "meshTexture", "material", "color", "size", "transparency", "duration", "ease", "spin"],
    "ring": ["size", "thickness", "color", "transparency", "duration", "texture", "lightEmission", "brightness",
             "flat", "ease", "material"],
    "decal": ["texture", "size", "color", "transparency", "duration", "fade", "grow", "rotation"],
}
NESTED_KEYS: dict[str, list[str]] = {
    "flipbook": ["layout", "mode", "fps", "random"],
    "shape": ["kind", "size", "style", "inOut", "partial"],
    "spot": ["angle", "face"],
    "budget": ["particles", "lights", "effects"],
    "trail": ["width", "offset", "axis", "lifetime", "color", "transparency", "widthScale", "texture", "textureMode",
              "textureLength", "lightEmission", "lightInfluence", "brightness", "minLength", "maxLength",
              "faceCamera", "enabled"],
}
ALIASES = {
    "colour": "color", "spreadangle": "spread", "emissiondirection": "direction", "emit": "count", "amount": "count",
    "burst": "count", "lifespan": "lifetime", "velocity": "speed", "spin": "rotSpeed", "rotationspeed": "rotSpeed",
    "radius": "range", "locked": "lockedToPart",
}
_DIRS = ["up", "down", "forward", "back", "left", "right"]
_MATERIALS = ["neon", "forcefield", "glass", "smoothplastic", "plastic"]
_TEXTURE_MODES = ["stretch", "wrap", "static"]
ENUM_ALIASES = {
    "facingcamera": "facing", "facingcameraworldup": "facingUp", "velocityparallel": "parallel",
    "velocityperpendicular": "perpendicular", "top": "up", "bottom": "down", "front": "forward", "grid2x2": "2x2",
    "grid4x4": "4x4", "grid8x8": "8x8", "2": "2x2", "4": "4x4", "8": "8x8", "inandout": "both", "ball": "sphere",
    "brick": "block", "cube": "block",
}
TYPES: dict[str, dict[str, list]] = {
    "common": {"kind": ["enum", KINDS], "delay": ["num", 0, 30], "offset": ["vec3"]},
    "particles": {
        "count": ["int", 0, 1000], "rate": ["num", 0, 1000], "duration": ["num", 0, 600],
        "lifetime": ["range", 0, 20], "speed": ["range", -1000, 1000], "spread": ["pair", 0, 360],
        "size": ["numseq", 0, 1000], "transparency": ["numseq", 0, 1], "color": ["colseq"],
        "lightEmission": ["num", 0, 1], "lightInfluence": ["num", 0, 1], "brightness": ["num", 0, 1000],
        "drag": ["num", -100, 100], "acceleration": ["vec3"], "rotation": ["range", -3600, 3600],
        "rotSpeed": ["range", -36000, 36000],
        "orientation": ["enum", ["facing", "facingUp", "parallel", "perpendicular"]],
        "squash": ["numseq", -3, 3], "zoffset": ["num", -1000, 1000], "flipbook": ["table", "flipbook"],
        "texture": ["texture"], "direction": ["enum", _DIRS], "shape": ["table", "shape"], "lockedToPart": ["bool"],
        "timeScale": ["num", 0, 1],
    },
    "beam": {
        "to": ["target"], "from": ["target"], "width": ["pair", 0, 1000], "color": ["colseq"],
        "transparency": ["numseq", 0, 1], "texture": ["texture"], "textureSpeed": ["num", -1000, 1000],
        "textureLength": ["num", 0.001, 1000], "textureMode": ["enum", _TEXTURE_MODES],
        "lightEmission": ["num", 0, 1], "lightInfluence": ["num", 0, 1], "brightness": ["num", 0, 1000],
        "curve": ["pair", -1000, 1000], "segments": ["int", 1, 1000], "faceCamera": ["bool"],
        "zoffset": ["num", -1000, 1000], "duration": ["num", 0, 600], "fadeOut": ["num", 0, 10],
    },
    "light": {
        "color": ["color"], "brightness": ["num", 0, 1000], "range": ["num", 0, 60], "duration": ["num", 0, 600],
        "attack": ["num", 0, 10], "shadows": ["bool"], "spot": ["table", "spot"],
    },
    "flash": {
        "shape": ["enum", ["sphere", "block", "mesh"]], "mesh": ["asset"], "meshTexture": ["texture"],
        "material": ["enum", _MATERIALS], "color": ["color"], "size": ["sizepair", 0, 1000],
        "transparency": ["pair", 0, 1], "duration": ["num", 0, 10], "ease": ["ease"],
        "spin": ["num", -36000, 36000],
    },
    "ring": {
        "size": ["pair", 0, 1000], "thickness": ["num", 0, 100], "color": ["colseq"],
        "transparency": ["numseq", 0, 1], "duration": ["num", 0, 10], "texture": ["texture"],
        "lightEmission": ["num", 0, 1], "brightness": ["num", 0, 1000], "flat": ["bool"], "ease": ["ease"],
        "material": ["enum", _MATERIALS],
    },
    "decal": {
        "texture": ["texture"], "size": ["pair", 0, 1000], "color": ["color"], "transparency": ["pair", 0, 1],
        "duration": ["num", 0, 600], "fade": ["num", 0, 60], "grow": ["num", 0, 10],
        "rotation": ["range", -3600, 3600],
    },
    "flipbook": {
        "layout": ["enum", ["2x2", "4x4", "8x8"]], "mode": ["enum", ["loop", "oneshot", "pingpong", "random"]],
        "fps": ["range", 0, 240], "random": ["bool"],
    },
    "shape": {
        "kind": ["enum", ["sphere", "box", "disc", "cylinder"]], "size": ["numvec", 0, 1000],
        "style": ["enum", ["volume", "surface"]], "inOut": ["enum", ["outward", "inward", "both"]],
        "partial": ["num", 0, 1],
    },
    "spot": {"angle": ["num", 0, 180], "face": ["enum", _DIRS]},
    "budget": {"particles": ["int", 0, 100000], "lights": ["int", 0, 64], "effects": ["int", 1, 1000]},
    "trail": {
        "width": ["num", 0, 1000], "offset": ["vec3"], "axis": ["enum", ["up", "right", "forward"]],
        "lifetime": ["num", 0, 20], "color": ["colseq"], "transparency": ["numseq", 0, 1],
        "widthScale": ["numseq", 0, 1000], "texture": ["texture"], "textureMode": ["enum", _TEXTURE_MODES],
        "textureLength": ["num", 0.001, 1000], "lightEmission": ["num", 0, 1], "lightInfluence": ["num", 0, 1],
        "brightness": ["num", 0, 1000], "minLength": ["num", 0, 1000], "maxLength": ["num", 0, 100000],
        "faceCamera": ["bool"], "enabled": ["bool"],
    },
}
EASE_STYLES = ["Linear", "Sine", "Quad", "Cubic", "Quart", "Quint", "Exponential", "Circular", "Back", "Bounce",
               "Elastic"]
_STYLE_ALIAS = {"expo": "exponential", "circ": "circular", "sin": "sine"}
_DIR_ALIAS = {"inandout": "inout", "both": "inout"}
_STYLE_NAMES = {s.lower(): s for s in EASE_STYLES}
_DIRECTION_NAMES = {"in": "In", "out": "Out", "inout": "InOut"}
ALL_LAYER_KEYS = {kind: COMMON_KEYS + keys for kind, keys in LAYER_KEYS.items()}


# ---------------------------------------------------------------------------------------------- primitives
def is_num(v: Any) -> bool:
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


def is_vec(v: Any) -> bool:
    return isinstance(v, (list, tuple)) and len(v) == 3 and all(is_num(x) for x in v)


_HEX6 = re.compile(r"^\s*#?([0-9A-Fa-f]{6})\s*$")
_HEX3 = re.compile(r"^\s*#([0-9A-Fa-f]{3})\s*$")
_TOKEN = re.compile(r"^\s*Tokens\.color\.([A-Za-z0-9_]+)\s*$")
_CONTENT = [re.compile(p) for p in (r"^rbxassetid://\d+$", r"^rbxasset://\S+$", r"^rbxthumb://\S+$", r"^https?://\S+$")]
_TEXTURE_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_\-.]*$")


def hex_color(v: Any) -> tuple[float, float, float] | None:
    if not isinstance(v, str):
        return None
    m = _HEX6.match(v)
    if m:
        h = m.group(1)
        return int(h[0:2], 16) / 255, int(h[2:4], 16) / 255, int(h[4:6], 16) / 255
    m = _HEX3.match(v)
    if m:
        h = m.group(1)
        return int(h[0], 16) * 17 / 255, int(h[1], 16) * 17 / 255, int(h[2], 16) * 17 / 255
    return None


def token_name(v: Any) -> str | None:
    if not isinstance(v, str):
        return None
    m = _TOKEN.match(v)
    return m.group(1) if m else None


def is_color(v: Any) -> bool:
    return hex_color(v) is not None or token_name(v) is not None


def is_content_id(v: Any) -> bool:
    return isinstance(v, str) and any(p.match(v) for p in _CONTENT)


def is_texture(v: Any) -> bool:
    if is_num(v):
        return v > 0 and v % 1 == 0
    return is_content_id(v) or (isinstance(v, str) and _TEXTURE_NAME.match(v) is not None)


def distance(a: str, b: str) -> int:
    """Optimal-string-alignment distance: edits, with a swap of neighbours counting as one."""
    la, lb = len(a), len(b)
    if la == 0:
        return lb
    if lb == 0:
        return la
    prev2 = [0] * (lb + 1)
    prev = list(range(lb + 1))
    for i in range(1, la + 1):
        cur = [i] + [0] * lb
        for j in range(1, lb + 1):
            cost = 0 if a[i - 1] == b[j - 1] else 1
            best = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            if i > 1 and j > 1 and a[i - 1] == b[j - 2] and a[i - 2] == b[j - 1]:
                best = min(best, prev2[j - 2] + 1)
            cur[j] = best
        prev2, prev = prev, cur
    return prev[lb]


def closest(word: str, candidates: Iterable[str], max_distance: int | None = None) -> str | None:
    """The candidate closest to word (case-insensitive), or None if nothing is close."""
    candidates = list(candidates)
    lw = word.lower()
    best, best_d = None, math.inf
    for c in candidates:
        d = distance(lw, c.lower())
        if d < best_d:
            best, best_d = c, d
    limit = max_distance if max_distance is not None else max(1, len(word) // 3)
    if best is not None and best_d <= limit:
        return best
    if len(lw) >= 4:
        for c in candidates:
            lc = c.lower()
            if len(lc) >= 4 and (lc in lw or lw in lc):
                return c
    return None


def normalize_keys(tbl: dict, keys: list[str]) -> tuple[dict, list[tuple[str, str | None]], list[tuple[str, str]]]:
    """Canonical keys (case-insensitive, ALIASES) -> (normalized, unknown [(key, suggestion)], renamed [(key, canon)])."""
    lookup = {k.lower(): k for k in keys}
    out: dict = {}
    unknown: list[tuple[str, str | None]] = []
    renamed: list[tuple[str, str]] = []
    for k, v in tbl.items():
        if v is None:                                  # JSON null is Luau nil: the key is absent
            continue
        k = str(k)
        if k.startswith("["):
            unknown.append((k, None))                  # a positional entry (a list where a table belongs)
            continue
        lower = k.lower()
        canon = lookup.get(lower)
        if canon is None:
            alias = ALIASES.get(lower)
            if alias is not None and alias.lower() in lookup:
                canon = alias
        if canon is not None:
            if k == canon or canon not in out:
                out[canon] = v
            if k != canon:
                renamed.append((k, canon))
        else:
            unknown.append((k, closest(k, keys)))
    unknown.sort(key=lambda u: u[0])
    return out, unknown, renamed


def enum_value(v: Any, choices: list[str]) -> str | None:
    """The canonical choice for an enum value (string or number), or None."""
    if isinstance(v, str):
        name = v
    elif is_num(v):
        name = str(int(v)) if float(v).is_integer() else repr(float(v))
    else:
        return None
    lower = name.lower()
    lower = ENUM_ALIASES.get(lower, lower).lower()
    for c in choices:
        if c.lower() == lower:
            return c
    return None


def _split_ease(s: str) -> tuple[str | None, str | None]:
    m = re.match(r"^\s*([A-Za-z]+)[\s._:\-]+([A-Za-z]+)\s*$", s)
    if m:
        return m.group(1).lower(), m.group(2).lower()
    m = re.match(r"^\s*([A-Za-z]+)\s*$", s)
    if not m:
        return None, None
    w = m.group(1).lower()
    if w in _STYLE_NAMES or w in _STYLE_ALIAS:
        return w, None
    for suffix in ("inout", "out", "in"):
        if len(w) > len(suffix) and w.endswith(suffix):
            stem = w[: -len(suffix)]
            if stem in _STYLE_NAMES or stem in _STYLE_ALIAS:
                return stem, suffix
    return w, None


def ease_names(ease: Any, default_style: str = "sine", default_direction: str = "inout") -> tuple[str, str, str | None]:
    """(EasingStyle name, EasingDirection name, problem) for "Quint", "Quint Out", "SineInOut" or [style, direction]."""
    d_style = _STYLE_NAMES.get(default_style.lower(), "Sine")
    d_dir = _DIRECTION_NAMES.get(default_direction.lower(), "InOut")
    style = direction = problem = None
    raw = ease
    if isinstance(ease, (list, tuple, dict)):
        seq = list(ease) if isinstance(ease, (list, tuple)) else []
        raw = seq[0] if len(seq) > 0 else None
        second = seq[1] if len(seq) > 1 else None
        direction = second if isinstance(second, str) else None
        if second is not None and direction is None:
            problem = "easing direction must be In, Out or InOut"
    if raw is not None:
        if not isinstance(raw, str):
            problem = 'expected an easing name like "Quint Out" or {"Back", "In"}'
        else:
            st, d = _split_ease(raw)
            if st is None:
                problem = f'expected an easing name like "Quint Out", got "{raw}"'
            else:
                style = st
                if d is not None and direction is None:
                    direction = d
    style_name = d_style
    if style is not None:
        key = _STYLE_ALIAS.get(style, style)
        if key in _STYLE_NAMES:
            style_name = _STYLE_NAMES[key]
        else:
            guess = closest(style, EASE_STYLES)
            problem = problem or f'unknown easing style "{style}"' + (f" (did you mean {guess}?)" if guess else "")
    dir_name = d_dir
    if direction is not None:
        key = _DIR_ALIAS.get(direction.lower(), direction.lower())
        if key in _DIRECTION_NAMES:
            dir_name = _DIRECTION_NAMES[key]
        else:
            problem = problem or f'unknown easing direction "{direction}" (In, Out or InOut)'
    return style_name, dir_name, problem


def keypoints(spec: Any, is_value: Callable[[Any], bool]) -> tuple[list[tuple[float, Any, float]] | None, list[str]]:
    """Same forms as FxMath.keypoints: a value, a list of values (spread evenly), or [time, value, envelope?]
    keypoints ({"time", "value", "envelope"} works too). -> (sorted keypoints spanning 0..1, problems)."""
    problems: list[str] = []
    if is_value(spec):
        return [(0.0, spec, 0.0), (1.0, spec, 0.0)], problems
    if not isinstance(spec, (list, tuple, dict)):
        problems.append("expected a value, a list of values, or {time, value} keypoints")
        return None, problems
    items = list(spec) if isinstance(spec, (list, tuple)) else []
    if items and None in items:
        items = items[:items.index(None)]              # a Luau list ends at its first nil
    n = len(items)
    if n == 0:
        problems.append("empty keypoint list")
        return None, problems
    if all(is_value(x) for x in items):
        out = [((i / (n - 1)) if n > 1 else 0.0, x, 0.0) for i, x in enumerate(items)]
        if n == 1:
            out.append((1.0, items[0], 0.0))
    else:
        out = []
        last_t = -math.inf
        unsorted = False
        for i, k in enumerate(items, 1):
            t = v = e = None
            if isinstance(k, (list, tuple)):
                t = k[0] if len(k) > 0 else None
                v = k[1] if len(k) > 1 else None
                e = k[2] if len(k) > 2 else None
            elif isinstance(k, dict):
                t = k.get("t") if k.get("t") is not None else k.get("time")
                v = k.get("v") if k.get("v") is not None else k.get("value")
                e = k.get("e") if k.get("e") is not None else k.get("envelope")
            if not is_num(t) or not is_value(v):
                problems.append(f"keypoint {i}: expected {{time, value}} (time 0..1)")
                continue
            tt = float(t)
            if tt < 0 or tt > 1:
                problems.append(f"keypoint {i}: time {_fmt(tt)} is outside 0..1")
                tt = min(max(tt, 0.0), 1.0)
            if tt < last_t:
                unsorted = True
            last_t = tt
            env = 0.0
            if e is not None:
                if not is_num(e):
                    problems.append(f"keypoint {i}: envelope must be a number")
                else:
                    env = max(float(e), 0.0)
            out.append((tt, v, env))
        if not out:
            return None, problems
        if unsorted:
            problems.append("keypoint times must go up from 0 to 1 (sorted them)")
            out.sort(key=lambda kp: kp[0])
        if out[0][0] > 0:
            out.insert(0, (0.0, out[0][1], out[0][2]))
        if out[-1][0] < 1:
            out.append((1.0, out[-1][1], out[-1][2]))
    if len(out) > 20:
        problems.append(f"{len(out)} keypoints; sequences hold at most 20 (resampled)")
        out = [out[int(math.floor(k * (len(out) - 1) / 19 + 0.5))] for k in range(20)]
    return out, problems


def _fmt(x: float) -> str:
    if float(x).is_integer() and abs(x) < 1e15:
        return str(int(x))
    return repr(float(x))


def _describe(v: Any) -> str:
    if isinstance(v, str):
        return f'"{v[:40]}"'
    if v is None:
        return "nil"
    if isinstance(v, bool):
        return "true" if v else "false"
    if is_num(v):
        return _fmt(v)
    return "a table" if isinstance(v, (list, tuple, dict)) else f"a {type(v).__name__}"


# ---------------------------------------------------------------------------------------------- validation
def _range_text(spec: list) -> str:
    return f"{_fmt(spec[1])}..{_fmt(spec[2])}"


def _in_range(x: float, spec: list) -> bool:
    return spec[1] <= x <= spec[2]


def _num_or_vec(v: Any, spec: list) -> bool:
    if is_num(v):
        return _in_range(v, spec)
    if is_vec(v):
        return all(_in_range(c, spec) for c in v)
    return False


def _check_table(v: Any, schema: str, path: str, out: list[str]) -> None:
    if isinstance(v, (list, tuple)):
        v = {f"[{i}]": x for i, x in enumerate(v, 1)}
    if not isinstance(v, dict):
        out.append(f"{path}: expected a table, got {_describe(v)}")
        return
    norm, unknown, _ = normalize_keys(v, NESTED_KEYS[schema])
    for key, suggestion in unknown:
        out.append(f"{path}.{key}: unknown key" + (f" (did you mean {suggestion}?)" if suggestion else ""))
    for k in sorted(norm):
        _check_value(TYPES[schema][k], norm[k], f"{path}.{k}", out)


def _check_value(spec: list, v: Any, path: str, out: list[str]) -> None:
    kind = spec[0]
    if kind == "num":
        if not is_num(v):
            out.append(f"{path}: expected a number, got {_describe(v)}")
        elif not _in_range(v, spec):
            out.append(f"{path}: expected {_range_text(spec)}, got {_fmt(v)}")
    elif kind == "int":
        if not is_num(v) or v % 1 != 0:
            out.append(f"{path}: expected a whole number, got {_describe(v)}")
        elif not _in_range(v, spec):
            out.append(f"{path}: expected {_range_text(spec)}, got {_fmt(v)}")
    elif kind == "bool":
        if not isinstance(v, bool):
            out.append(f"{path}: expected true or false, got {_describe(v)}")
    elif kind == "enum":
        if enum_value(v, spec[1]) is None:
            guess = closest(v, spec[1]) if isinstance(v, str) else None
            out.append(f"{path}: expected one of {', '.join(spec[1])}, got {_describe(v)}"
                       + (f" (did you mean {guess}?)" if guess else ""))
    elif kind in ("range", "pair"):
        a = b = None
        if is_num(v):
            a = b = v
        elif isinstance(v, (list, tuple)) and len(v) == 2 and is_num(v[0]) and is_num(v[1]):
            a, b = v
        if a is None:
            inner = "min, max" if kind == "range" else "a, b"
            out.append(f"{path}: expected a number or {{{inner}}}, got {_describe(v)}")
        elif not _in_range(a, spec) or not _in_range(b, spec):
            out.append(f"{path}: expected values in {_range_text(spec)}")
        elif kind == "range" and a > b:
            out.append(f"{path}: min is greater than max")
    elif kind == "vec3":
        if not is_vec(v):
            out.append(f"{path}: expected a Vector3, got {_describe(v)}")
    elif kind == "numvec":
        if not _num_or_vec(v, spec):
            out.append(f"{path}: expected a number or a Vector3 in {_range_text(spec)}, got {_describe(v)}")
    elif kind == "sizepair":
        ok = _num_or_vec(v, spec)
        if not ok and isinstance(v, (list, tuple)) and len(v) == 2:
            ok = _num_or_vec(v[0], spec) and _num_or_vec(v[1], spec)
        if not ok:
            out.append(f"{path}: expected a size (number or Vector3) or {{from, to}} in {_range_text(spec)}, "
                       f"got {_describe(v)}")
    elif kind == "target":
        if not is_vec(v):
            out.append(f"{path}: expected a Vector3 (offset in the effect's frame) or a part / attachment, "
                       f"got {_describe(v)}")
    elif kind == "numseq":
        kps, problems = keypoints(v, is_num)
        out.extend(f"{path}: {p}" for p in problems)
        if kps:
            for _, value, _ in kps:
                if not _in_range(value, spec):
                    out.append(f"{path}: values must be in {_range_text(spec)}, got {_fmt(value)}")
                    break
    elif kind == "colseq":
        _, problems = keypoints(v, is_color)
        out.extend(f'{path}: {p} (colours: Color3, "#RRGGBB" or "Tokens.color.<name>")' for p in problems)
    elif kind == "color":
        if not is_color(v):
            out.append(f'{path}: expected a Color3, "#RRGGBB" or "Tokens.color.<name>", got {_describe(v)}')
    elif kind == "texture":
        if not is_texture(v):
            out.append(f'{path}: expected a content id ("rbxassetid://123") or a texture name, got {_describe(v)}')
    elif kind == "asset":
        if not (is_content_id(v) or (is_num(v) and v > 0 and v % 1 == 0)):
            out.append(f'{path}: expected a content id ("rbxassetid://123") or an asset id, got {_describe(v)}')
    elif kind == "ease":
        _, _, problem = ease_names(v)
        if problem:
            out.append(f"{path}: {problem}")
    elif kind == "table":
        _check_table(v, spec[1], path, out)


def _find_key(tbl: dict, name: str) -> Any:
    if name in tbl:
        return tbl[name]
    for k, v in tbl.items():
        if str(k).lower() == name:
            return v
    return None


def _validate_layer(layer: Any, path: str, out: list[str]) -> dict | None:
    if isinstance(layer, (list, tuple)):
        layer = {}                                   # a Luau table without a kind
    if not isinstance(layer, dict):
        out.append(f"{path}: expected a layer table, got {_describe(layer)}")
        return None
    raw_kind = _find_key(layer, "kind")
    if raw_kind is None:
        out.append(f"{path}.kind: missing (one of {', '.join(KINDS)})")
        return None
    kind = enum_value(raw_kind, KINDS)
    if kind is None:
        guess = closest(raw_kind, KINDS) if isinstance(raw_kind, str) else None
        out.append(f"{path}.kind: unknown kind {_describe(raw_kind)} (one of {', '.join(KINDS)})"
                   + (f" (did you mean {guess}?)" if guess else ""))
        return None
    norm, unknown, _ = normalize_keys(layer, ALL_LAYER_KEYS[kind])
    for key, suggestion in unknown:
        out.append(f"{path}.{key}: unknown key for a {kind} layer" + (f" (did you mean {suggestion}?)" if suggestion else ""))
    for k in sorted(norm):
        if k != "kind":
            _check_value(TYPES[kind].get(k) or TYPES["common"][k], norm[k], f"{path}.{k}", out)
    if kind == "particles":
        if norm.get("count") is None and norm.get("rate") is None:
            out.append(f"{path}.count: set count (a burst) or rate (continuous emission)")
        elif norm.get("count") is not None and norm.get("rate") is not None:
            out.append(f"{path}.rate: use count (a burst) or rate (continuous), not both")
    elif kind == "beam":
        if norm.get("to") is None:
            out.append(f"{path}.to: a beam needs to (its end point)")
    elif kind == "decal":
        if norm.get("texture") is None:
            out.append(f"{path}.texture: a decal needs a texture")
    elif kind == "flash":
        if enum_value(norm.get("shape"), ["mesh"]) and norm.get("mesh") is None:
            out.append(f'{path}.mesh: shape "mesh" needs mesh (a mesh content id)')
    norm["kind"] = kind
    return norm


def _effect_layers(spec: Any, out: list[str]) -> list[tuple[int, dict]]:
    """Validates an effect spec into out; returns the valid-kind layers (1-based index, normalized)."""
    if isinstance(spec, (list, tuple)):
        spec = {"layers": list(spec)} if len(spec) > 0 else {}
    if not isinstance(spec, dict):
        out.append(f"effect: expected a table with layers, got {_describe(spec)}")
        return []
    norm, unknown, _ = normalize_keys(spec, EFFECT_KEYS)
    for key, suggestion in unknown:
        out.append(f"{key}: unknown key for an effect" + (f" (did you mean {suggestion}?)" if suggestion else ""))
    layers = norm.get("layers")
    kept: list[tuple[int, dict]] = []
    if not isinstance(layers, (list, tuple)) or len(layers) == 0 or layers[0] is None:
        out.append("layers: expected a non-empty list of layers")
    else:
        for i, layer in enumerate(layers, 1):
            if layer is None:                        # ipairs stops at the first nil
                break
            n = _validate_layer(layer, f"layers[{i}]", out)
            if n is not None:
                kept.append((i, n))
    if "family" in norm and norm["family"] is not None and not isinstance(norm["family"], str):
        out.append(f"family: expected a string, got {_describe(norm['family'])}")
    if norm.get("budget") is not None:
        _check_table(norm["budget"], "budget", "budget", out)
    return kept


def validate_effect(spec: Any) -> list[str]:
    """Every error in an effect spec, as "path: message" (the rules FxMath.validateEffect applies in the game)."""
    out: list[str] = []
    _effect_layers(spec, out)
    return out


def validate_trail(spec: Any) -> list[str]:
    """Every error in a VFX.trail spec (FxMath.validateTrail's rules)."""
    out: list[str] = []
    if not isinstance(spec, (dict, list, tuple)):
        out.append(f"trail: expected a table, got {_describe(spec)}")
        return out
    _check_table(spec, "trail", "trail", out)
    return out


# ---------------------------------------------------------------------------------------------- taste warnings
def _seq_values(v: Any) -> list[Any] | None:
    kps, problems = keypoints(v, lambda x: is_num(x) or is_color(x))
    return None if kps is None or problems else [value for _, value, _ in kps]


def _constant(v: Any) -> bool:
    values = _seq_values(v)
    return values is not None and len({json.dumps(x) for x in values}) == 1


def _max_of(v: Any, default: float) -> float:
    if is_num(v):
        return float(v)
    if isinstance(v, (list, tuple)) and len(v) == 2 and is_num(v[0]) and is_num(v[1]):
        return float(max(v))
    return default


def _renamed_warnings(spec: Any) -> list[str]:
    out: list[str] = []
    if isinstance(spec, (list, tuple)):
        spec = {"layers": list(spec)}
    if not isinstance(spec, dict):
        return out
    _, _, renamed = normalize_keys(spec, EFFECT_KEYS)
    out += [f"{k}: works, but write {canon}" for k, canon in renamed]
    layers = _find_key(spec, "layers")
    if isinstance(layers, list):
        for i, layer in enumerate(layers, 1):
            if isinstance(layer, dict):
                kind = enum_value(_find_key(layer, "kind"), KINDS)
                if kind:
                    _, _, renamed = normalize_keys(layer, ALL_LAYER_KEYS[kind])
                    out += [f"layers[{i}].{k}: works, but write {canon}" for k, canon in renamed if canon != "kind"]
    return out


def lint_layers(layers: list[tuple[int, dict]], color_tokens: set[str] | None = None) -> list[str]:
    """Taste warnings from the VFX rubric (a single emitter, constant curves, mud, white-out, one colour...)."""
    w: list[str] = []
    if len(layers) == 1:
        w.append("effect: one layer reads as a 4 at best: add a bright core or flash, secondaries (sparks, debris) "
                 "and an afterglow or smoke")
    colours: list[str] = []
    for i, L in layers:
        p = f"layers[{i}]"
        kind = L["kind"]
        for key in ("color",):
            if key in L:
                colours.append(json.dumps(L[key]))
                if color_tokens is not None:
                    for v in _seq_values(L[key]) or []:
                        name = token_name(v)
                        if name is not None and name not in color_tokens:
                            w.append(f"{p}.color: Tokens.color.{name} is not in the palette "
                                     f"({', '.join(sorted(color_tokens))})")
        if kind == "particles":
            if "texture" not in L:
                w.append(f"{p}.texture: none: the default particle is a stock sparkle; paint one (paint_texture) "
                         "or use a content id")
            if "size" not in L or _constant(L["size"]):
                w.append(f"{p}.size: never changes over the particle's life: give it a curve, e.g. "
                         "[[0, 0.3], [0.15, 1], [1, 0]]")
            if "transparency" in L and _constant(L["transparency"]):
                w.append(f"{p}.transparency: never changes: fade it out, e.g. [[0, 0], [0.7, 0.3], [1, 1]]")
            life = _max_of(L.get("lifetime"), 1.0)
            if L.get("count") is not None and life > 2.5:
                w.append(f"{p}.lifetime: up to {_fmt(life)} s on a burst lingers (mud): 0.2-1.2 s suits impacts")
            if is_num(L.get("count")) and L["count"] > 150:
                w.append(f"{p}.count: {_fmt(L['count'])} in one burst reads as confetti soup: fewer, larger, "
                         "shaped particles")
            if L.get("rate") is not None and not (is_num(L.get("duration")) and L["duration"] > 0):
                w.append(f"{p}.duration: none: this layer emits until handle:stop()")
            if is_num(L.get("lightEmission")) and L["lightEmission"] >= 0.9 and _max_of(L.get("brightness"), 1) > 4:
                w.append(f"{p}.brightness: additive and bright: white-out risk on light backgrounds; add a darker "
                         "contrast layer or lower it")
        elif kind == "light":
            if _max_of(L.get("brightness"), 2) > 10:
                w.append(f"{p}.brightness: above 10 whites out the frame; 2-6 is usually enough")
        elif kind == "flash":
            if _max_of(L.get("duration"), 0.12) > 0.35:
                w.append(f"{p}.duration: a flash is 1-4 frames (0.05-0.2 s); longer reads as a blob")
    if len(layers) >= 2 and len(colours) >= 2 and len(set(colours)) == 1 and _constant(json.loads(colours[0])):
        w.append("effect: every layer is the same colour: build a value hierarchy (a brighter core, a darker or "
                 "complementary edge)")
    return w


@dataclass
class FxReport:
    errors: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not self.errors

    def text(self) -> str:
        if not self.errors and not self.warnings:
            return "spec OK: no errors, no warnings"
        parts = []
        if self.errors:
            parts.append(f"{len(self.errors)} error(s) (the game warns and uses defaults for these):\n"
                         + "\n".join(f"- {e}" for e in self.errors))
        else:
            parts.append("no errors")
        if self.warnings:
            parts.append(f"{len(self.warnings)} taste warning(s):\n" + "\n".join(f"- {w}" for w in self.warnings))
        return "\n".join(parts)


def _decode(spec: Any) -> Any:
    if isinstance(spec, str):
        try:
            return json.loads(spec)
        except ValueError:
            return spec
    return spec


def check_effect(spec: Any, color_tokens: Iterable[str] | None = None) -> FxReport:
    """Errors (same as the game's validator) and taste warnings for an effect spec."""
    spec = _decode(spec)
    errors: list[str] = []
    layers = _effect_layers(spec, errors)
    warnings = _renamed_warnings(spec) + lint_layers(layers, set(color_tokens) if color_tokens is not None else None)
    return FxReport(errors, warnings)


def check_trail(spec: Any) -> FxReport:
    spec = _decode(spec)
    errors = validate_trail(spec)
    warnings: list[str] = []
    if isinstance(spec, dict):
        norm, _, renamed = normalize_keys(spec, NESTED_KEYS["trail"])
        warnings += [f"trail.{k}: works, but write {canon}" for k, canon in renamed]
        if "transparency" not in norm and "widthScale" not in norm:
            warnings.append("trail: no transparency or widthScale curve: taper or fade the tail")
        if _max_of(norm.get("lifetime"), 0.3) > 1.5:
            warnings.append("trail.lifetime: a long trail smears the action; 0.15-0.5 s for dashes and swings")
    return FxReport(errors, warnings)


def schema() -> dict:
    """The schema tables (for the parity test against FxMath.luau)."""
    return {"KINDS": KINDS, "EFFECT_KEYS": EFFECT_KEYS, "COMMON_KEYS": COMMON_KEYS, "LAYER_KEYS": LAYER_KEYS,
            "NESTED_KEYS": NESTED_KEYS, "ALIASES": ALIASES, "ENUM_ALIASES": ENUM_ALIASES, "TYPES": TYPES,
            "EASE_STYLES": EASE_STYLES}


def tools() -> list:
    """check_fx_spec for builders: validate a VFX effect (or trail) spec before writing it into the game."""
    from harness.tools.base import Tool, ToolResult

    async def check_fx_spec(spec: Any, kind: str = "effect", color_tokens: list[str] | None = None) -> ToolResult:
        rep = check_trail(spec) if kind == "trail" else check_effect(spec, color_tokens)
        return ToolResult(text=rep.text(), data={"errors": rep.errors, "warnings": rep.warnings})

    return [Tool("check_fx_spec",
                 "Check a Kit.VFX effect spec (the table you pass to VFX.preset / VFX.effect) or a VFX.trail spec, "
                 "written as JSON: colours \"#RRGGBB\" or \"Tokens.color.<name>\", vectors [x, y, z], keypoints "
                 "[[time, value], ...]. Returns every error at once (with did-you-mean) and taste warnings from the "
                 "VFX rubric.",
                 {"type": "object", "additionalProperties": False, "required": ["spec"],
                  "properties": {"spec": {"type": ["object", "array", "string"],
                                          "description": "the effect spec ({layers = {...}}) or trail spec"},
                                 "kind": {"type": "string", "enum": ["effect", "trail"]},
                                 "color_tokens": {"type": "array", "items": {"type": "string"},
                                                  "description": "the game's Tokens.color names, to check references"}}},
                 check_fx_spec)]

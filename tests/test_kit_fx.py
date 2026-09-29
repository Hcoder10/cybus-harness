"""Offline tests for the kit's camera and VFX modules (CameraRig.luau, VFX.luau, FxMath.luau) and the effect-spec
validator (harness/tools/fxspec.py), without Roblox:
- every new Luau file passes the harness's syntax gate (and its lints);
- FxMath.luau (the pure math) runs under the standalone Luau runtime and matches independent Python computations;
- the Python validator and FxMath's return identical errors on one corpus, and share one schema;
- the playbook's examples run against recording stubs of the kit: every spec and option is valid, every API exists;
- CameraRig and VFX themselves run against ROBLOX_MOCK, a small strict engine (see below), in scenarios that check
  camera ownership and hand-back, blends, follow, collision, input, cleanup, budgets, hitstop and bad input.
What only Studio can show (how it looks, engine details the mock only imitates) is not claimed here."""
from __future__ import annotations

import asyncio
import json
import math
import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest

from harness.kit import KIT_API, KIT_DIR
from harness.tools import fxspec
from harness.tools.luau import analyzer, check_sources, syntax_errors

ROOT = Path(__file__).resolve().parents[1]
NEW_MODULES = ["FxMath", "CameraRig", "VFX"]
PLAYBOOK = ROOT / "harness" / "playbooks" / "vfx_camera_spec.md"
_RUNTIMES = [os.environ.get("HARNESS_LUAU_RUNTIME", ""), shutil.which("luau") or "",
             str(Path.home() / "brickformer" / "tools" / "luau" / "luau.exe")]
LUAU = next((p for p in _RUNTIMES if p and Path(p).exists()), None)
needs_luau = pytest.mark.skipif(LUAU is None, reason="standalone luau runtime not installed")
needs_analyzer = pytest.mark.skipif(analyzer() is None, reason="luau-analyze not installed")

# The lines this work proposes for harness/kit/__init__.py's KIT_API (checked below against the modules' real API).
PROPOSED_KIT_API = """\
- CameraRig (client): CameraRig.follow({preset="shoulder"|"overTheTop"|"sideScroller"|"topDown", distance, height, offset, fov, pitch,
  orbit="free"|"drag"|"locked", lookAhead, speedFov={from,to,fov,pull}, collision, autoAlign, zoom={min,max,step}}) -> rig (rig:set(opts); rig:stop());
  CameraRig.shot({from=CFrame, to=CFrame | path={Vector3...}, lookAt | orbit={target,radius,height,from,to}, relativeTo, duration, hold,
  ease="Sine InOut", fov, roll, handheld, blendIn, blendOut, letterbox, slowmo}) / CameraRig.sequence({shot, ...}, {letterbox, skipInput,
  lockControls}) -> h (h:andThen(fn); h:skip()); CameraRig.kick(fovDegrees, seconds); CameraRig.punch(direction, studs); CameraRig.shake(trauma);
  CameraRig.slowmo(scale, seconds) (others read CameraRig.timeScale); the player attribute KitCinematic is true during shots
- VFX (client): VFX.preset(name, {layers={{kind="particles"|"beam"|"light"|"flash"|"ring"|"decal", delay, ...}}, budget}) once;
  VFX.play(name, at, {normal, direction, scale, intensity, follow}) -> h (h:stop()); VFX.effect(spec, at, opts); keypoints {{0,a},{0.2,b},{1,c}};
  colours Color3 | "#RRGGBB" | "Tokens.color.<name>"; VFX.flashLight(at, color, brightness, range, s); VFX.hitstop(s); VFX.screenFlash(color, s,
  strength); VFX.vignette(color, s) -> v (v:stop()); VFX.trail(part, {width, lifetime, color, transparency}) -> t (t:burst(s)); VFX.validate(spec)
- FxMath: CameraRig's and VFX's pure-Luau math (ease, springStep, keypoints, validateEffect); you rarely need it directly
"""


def close(a, b, tol: float = 1e-9) -> bool:
    """Recursive approximate equality for nested lists / dicts of numbers."""
    if isinstance(a, (list, tuple)) and isinstance(b, (list, tuple)):
        return len(a) == len(b) and all(close(x, y, tol) for x, y in zip(a, b))
    if isinstance(a, dict) and isinstance(b, dict):
        return a.keys() == b.keys() and all(close(a[k], b[k], tol) for k in a)
    if isinstance(a, (int, float)) and isinstance(b, (int, float)) and not isinstance(a, bool):
        return math.isclose(a, b, rel_tol=tol, abs_tol=tol)
    return a == b


def slowmo_ref(t: float, scale: float, seconds: float, rin: float, rout: float) -> float:
    if not seconds > 0 or t < 0 or t >= seconds:
        return 1.0
    if rin + rout > seconds:
        k = seconds / (rin + rout)
        rin, rout = rin * k, rout * k
    if t < rin:
        u = t / rin
        return 1 + (scale - 1) * (1 - (1 - u) ** 2)
    if rout > 0 and t > seconds - rout:
        u = (t - (seconds - rout)) / rout
        return scale + (1 - scale) * u * u * (3 - 2 * u)
    return scale


def _source(name: str) -> str:
    return (KIT_DIR / f"{name}.luau").read_text(encoding="utf-8")


def _lua_blocks() -> list[str]:
    return re.findall(r"```lua\n(.*?)```", PLAYBOOK.read_text(encoding="utf-8"), re.S)


# ---------------------------------------------------------------------------------------------- Luau literals
class Vec(tuple):
    """A Vector3 in a spec: written into Luau as a native vector."""


def lua(v, vec: str = "vector.create") -> str:
    if v is None:
        return "nil"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, Vec):
        return vec + "(" + ", ".join(lua(float(x)) for x in v) + ")"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        if math.isinf(v):
            return "math.huge" if v > 0 else "-math.huge"
        return repr(v)
    if isinstance(v, str):
        return json.dumps(v)
    if isinstance(v, (list, tuple)):
        return "{" + ", ".join(lua(x, vec) for x in v) + "}"
    if isinstance(v, dict):
        return "{" + ", ".join(f"[{json.dumps(str(k))}] = {lua(x, vec)}" for k, x in v.items()) + "}"
    raise TypeError(type(v))


def _canon(key: str, keys: list[str]) -> str | None:
    lower = key.lower()
    for k in keys:
        if k.lower() == lower:
            return k
    alias = fxspec.ALIASES.get(lower)
    return alias if alias in keys else None


def _vectors(value, typ: list):
    """JSON -> Luau for one value: [x, y, z] becomes a Vector3 where the schema expects one."""
    kind = typ[0]
    if kind in ("vec3", "target", "numvec") and fxspec.is_vec(value):
        return Vec(value)
    if kind == "sizepair":
        if fxspec.is_vec(value):
            return Vec(value)
        if isinstance(value, list):
            return [Vec(x) if fxspec.is_vec(x) else x for x in value]
    if kind == "table" and isinstance(value, dict):
        return _table_vectors(value, fxspec.NESTED_KEYS[typ[1]], fxspec.TYPES[typ[1]])
    return value


def _table_vectors(tbl: dict, keys: list[str], types: dict) -> dict:
    out = {}
    for k, v in tbl.items():
        canon = _canon(k, keys)
        out[k] = _vectors(v, types.get(canon) or fxspec.TYPES["common"].get(canon, ["any"])) if canon else v
    return out


def to_luau_spec(spec):
    """A JSON effect spec as the Luau table a builder would write (vectors where the schema wants them)."""
    if isinstance(spec, list):
        return [to_luau_spec_layer(x) for x in spec]
    if not isinstance(spec, dict):
        return spec
    out = dict(spec)
    for k, v in spec.items():
        if k.lower() == "layers" and isinstance(v, list):
            out[k] = [to_luau_spec_layer(x) for x in v]
    return out


def to_luau_spec_layer(layer):
    if not isinstance(layer, dict):
        return layer
    kind = fxspec.enum_value(fxspec._find_key(layer, "kind"), fxspec.KINDS)
    if not kind:
        return layer
    return _table_vectors(layer, fxspec.ALL_LAYER_KEYS[kind], fxspec.TYPES[kind])


# ---------------------------------------------------------------------------------------------- running Luau
PRELUDE = r'''
local F = require("./FxMath")
local function jstr(s)
	return '"' .. (string.gsub(s, '[%c"\\]', function(c)
		if c == '"' then
			return '\\"'
		elseif c == "\\" then
			return "\\\\"
		end
		return string.format("\\u%04x", string.byte(c))
	end)) .. '"'
end
local function encode(v, out)
	local t = typeof(v)
	if t == "nil" then
		table.insert(out, "null")
	elseif t == "boolean" then
		table.insert(out, tostring(v))
	elseif t == "number" then
		if v ~= v or v == math.huge or v == -math.huge then
			table.insert(out, "null")
		else
			table.insert(out, string.format("%.17g", v))
		end
	elseif t == "string" then
		table.insert(out, jstr(v))
	elseif t == "vector" then
		encode({ v.X, v.Y, v.Z }, out)
	elseif t == "table" then
		if #v > 0 then
			table.insert(out, "[")
			for i, x in ipairs(v) do
				if i > 1 then
					table.insert(out, ",")
				end
				encode(x, out)
			end
			table.insert(out, "]")
		elseif next(v) == nil then
			table.insert(out, "[]")
		else
			local keys = {}
			for k in v do
				table.insert(keys, tostring(k))
			end
			table.sort(keys)
			table.insert(out, "{")
			for i, k in keys do
				if i > 1 then
					table.insert(out, ",")
				end
				table.insert(out, jstr(k))
				table.insert(out, ":")
				local x = v[k]
				if x == nil then
					x = v[tonumber(k)]
				end
				encode(x, out)
			end
			table.insert(out, "}")
		end
	else
		table.insert(out, jstr(tostring(v)))
	end
end
local function json(v)
	local out = {}
	encode(v, out)
	return table.concat(out)
end
local function kps(list)
	if not list then
		return nil
	end
	local out = {}
	for _, k in list do
		table.insert(out, { k.t, k.v, k.e })
	end
	return out
end
'''


def run_luau(workdir: Path, body: str) -> dict:
    workdir.mkdir(parents=True, exist_ok=True)
    shutil.copy(KIT_DIR / "FxMath.luau", workdir / "FxMath.luau")
    driver = workdir / "driver.luau"
    driver.write_text(PRELUDE + body, encoding="utf-8")
    proc = subprocess.run([LUAU, str(driver)], cwd=workdir, capture_output=True, text=True, timeout=120)
    assert proc.returncode == 0, (proc.stdout + proc.stderr)[-4000:]
    lines = [line for line in proc.stdout.splitlines() if line.startswith("{")]
    assert lines, proc.stdout[-2000:]
    return json.loads(lines[-1])


# ---------------------------------------------------------------------------------------------- Python references
def _bounce_out(t: float) -> float:
    n1, d1 = 7.5625, 2.75
    if t < 1 / d1:
        return n1 * t * t
    if t < 2 / d1:
        t -= 1.5 / d1
        return n1 * t * t + 0.75
    if t < 2.5 / d1:
        t -= 2.25 / d1
        return n1 * t * t + 0.9375
    t -= 2.625 / d1
    return n1 * t * t + 0.984375


EASE_IN = {
    "Linear": lambda t: t,
    "Sine": lambda t: 1 - math.cos(t * math.pi / 2),
    "Quad": lambda t: t ** 2,
    "Cubic": lambda t: t ** 3,
    "Quart": lambda t: t ** 4,
    "Quint": lambda t: t ** 5,
    "Exponential": lambda t: 0.0 if t <= 0 else 2 ** (10 * t - 10),
    "Circular": lambda t: 1 - math.sqrt(max(0.0, 1 - t * t)),
    "Back": lambda t: 2.70158 * t ** 3 - 1.70158 * t ** 2,
    "Elastic": lambda t: 0.0 if t <= 0 else 1.0 if t >= 1 else -(2 ** (10 * t - 10)) * math.sin((t * 10 - 10.75) * (2 * math.pi / 3)),
    "Bounce": lambda t: 1 - _bounce_out(1 - t),
}


def ease(style: str, direction: str, t: float) -> float:
    f = EASE_IN[style]
    if direction == "In":
        return f(t)
    if direction == "Out":
        return 1 - f(1 - t)
    return f(2 * t) / 2 if t < 0.5 else 1 - f(2 - 2 * t) / 2


def rk4_spring(x: float, v: float, target: float, w: float, z: float, dt: float, steps: int = 4000) -> tuple[float, float]:
    """x'' = -w^2 (x - target) - 2 z w x', integrated numerically (the closed form's independent check)."""
    if dt <= 0:
        return x, v
    h = dt / steps

    def acc(px, pv):
        return -w * w * (px - target) - 2 * z * w * pv
    for _ in range(steps):
        k1x, k1v = v, acc(x, v)
        k2x, k2v = v + 0.5 * h * k1v, acc(x + 0.5 * h * k1x, v + 0.5 * h * k1v)
        k3x, k3v = v + 0.5 * h * k2v, acc(x + 0.5 * h * k2x, v + 0.5 * h * k2v)
        k4x, k4v = v + h * k3v, acc(x + h * k3x, v + h * k3v)
        x += h / 6 * (k1x + 2 * k2x + 2 * k3x + k4x)
        v += h / 6 * (k1v + 2 * k2v + 2 * k3v + k4v)
    return x, v


def numeric_peak(w: float, z: float) -> tuple[float, float]:
    """Peak displacement (and its time) of a spring at rest on its target given unit initial velocity."""
    x, v, t, h = 0.0, 1.0, 0.0, 1e-4 / max(w, 1e-3)
    best, best_t = 0.0, 0.0
    while t < 20 / max(w, 1e-3):
        x, v = rk4_spring(x, v, 0.0, w, z, h, steps=1)
        t += h
        if x > best:
            best, best_t = x, t
        elif x < best * 0.5:
            break
    return best, best_t


def catmull(p0, p1, p2, p3, t):
    return [0.5 * (2 * b + (c - a) * t + (2 * a - 5 * b + 4 * c - d) * t * t + (-a + 3 * b - 3 * c + d) * t ** 3)
            for a, b, c, d in zip(p0, p1, p2, p3)]


def path_point(pts, s):
    n = len(pts)
    s = min(max(s, 0), n - 1)
    i = min(int(math.floor(s)), n - 2)
    t = s - i
    p1, p2 = pts[i], pts[i + 1]
    p0 = pts[i - 1] if i >= 1 else [2 * a - b for a, b in zip(p1, p2)]
    p3 = pts[i + 2] if i + 2 <= n - 1 else [2 * b - a for a, b in zip(p1, p2)]
    return catmull(p0, p1, p2, p3, t)


def arc_point(pts, u, steps=6000):
    """The point at fraction u of the curve's length, by dense sampling."""
    n = len(pts)
    samples = [path_point(pts, (n - 1) * k / steps) for k in range(steps + 1)]
    cum = [0.0]
    for a, b in zip(samples, samples[1:]):
        cum.append(cum[-1] + math.dist(a, b))
    target = u * cum[-1]
    for k in range(1, len(cum)):
        if cum[k] >= target:
            f = (target - cum[k - 1]) / max(cum[k] - cum[k - 1], 1e-12)
            return [a + (b - a) * f for a, b in zip(samples[k - 1], samples[k])], cum[-1]
    return samples[-1], cum[-1]


def look_vector(yaw: float, pitch: float) -> list[float]:
    """R = Ry(yaw) Rx(pitch) applied to (0, 0, -1), as CFrame.fromEulerAnglesYXZ(pitch, yaw, 0).LookVector."""
    x, y, z = 0.0, math.sin(pitch), -math.cos(pitch)            # Rx(pitch) * (0, 0, -1)
    return [x * math.cos(yaw) + z * math.sin(yaw), y, -x * math.sin(yaw) + z * math.cos(yaw)]


# ---------------------------------------------------------------------------------------------- cases
SPRING_CASES = [  # x0, v0, target, speed, damping, dt
    (1.0, 0.0, 0.0, 10.0, 1.0, 0.016), (1.0, 0.0, 0.0, 10.0, 1.0, 0.3), (2.0, -3.0, 0.5, 12.0, 0.3, 0.05),
    (2.0, -3.0, 0.5, 12.0, 0.3, 0.7), (-1.0, 4.0, 1.0, 6.0, 2.5, 0.1), (-1.0, 4.0, 1.0, 6.0, 2.5, 1.5),
    (0.0, 10.0, 0.0, 16.0, 0.45, 0.02), (3.0, 0.0, 0.0, 8.0, 1.00005, 0.2), (5.0, 1.0, 5.0, 0.0, 1.0, 0.5),
    (1.0, 2.0, 0.0, 10.0, 1.0, 0.0), (1.0, 2.0, 0.0, 10.0, 0.7, 10.0), (4.0, 0.0, 1.0, 20.0, 0.0, 0.13),
]
PEAK_CASES = [(10.0, 1.0), (16.0, 0.45), (8.0, 2.0), (5.0, 0.1), (12.0, 0.0)]
KEYPOINT_CASES = [  # (luau expression, expected [[t, v, e]...] or None, number of problems)
    ("5", [[0, 5, 0], [1, 5, 0]], 0),
    ("{0.2, 1, 0}", [[0, 0.2, 0], [0.5, 1, 0], [1, 0, 0]], 0),
    ("{7}", [[0, 7, 0], [1, 7, 0]], 0),
    ("{{0.3, 2}, {0.8, 4, 0.5}}", [[0, 2, 0], [0.3, 2, 0], [0.8, 4, 0.5], [1, 4, 0.5]], 0),
    ("{{0.5, 1}, {0.2, 2}, {1, 0}}", [[0, 2, 0], [0.2, 2, 0], [0.5, 1, 0], [1, 0, 0]], 1),
    ("{{0, 1}, {1.5, 0}}", [[0, 1, 0], [1, 0, 0]], 1),
    ("{{time = 0, value = 3}, {t = 1, v = 1, e = 0.2}}", [[0, 3, 0], [1, 1, 0.2]], 0),
    ('"big"', None, 1),
    ("{}", None, 1),
    ('{{0, 1}, "x", {1, 2}}', [[0, 1, 0], [1, 2, 0]], 1),
    ("{{0, 1, -1}, {1, 1}}", [[0, 1, 0], [1, 1, 0]], 0),
]
CORPUS = [
    {"layers": [{"kind": "particles", "count": 12, "lifetime": [0.2, 0.5], "size": [[0, 0.4], [1, 0]],
                 "color": ["#FFFFFF", "Tokens.color.primary"], "texture": "spark", "acceleration": [0, -30, 0],
                 "flipbook": {"layout": "4x4", "mode": "OneShot"},
                 "shape": {"kind": "disc", "size": [4, 0.2, 4], "style": "surface"}}]},
    {"layers": []},
    [{"kind": "light", "color": "#FFAA00", "brightness": 3, "range": 12, "duration": 0.2}],
    {"layers": [{"kind": "particles"}]},
    {"layers": [{"kind": "particles", "count": 5, "rate": 10}]},
    {"layers": [{"kind": "particles", "count": 5.5, "lifetime": [1, 0.5], "spread": [10, 400], "size": "big",
                 "transparency": [[0, 0], [0.5, 2]], "color": ["#GG0000"], "orientation": "sideways",
                 "direction": "upward", "flipbook": {"layout": 3, "mod": "loop"}, "texture": "not a name!",
                 "Lifetme": 3}]},
    {"layers": [{"kind": "beam", "width": [1, -2], "curve": "big", "segments": 0, "textureMode": "tile"}]},
    {"layers": [{"kind": "light", "range": 80, "spot": {"angle": 200, "face": "sideways", "size": 3}}]},
    {"layers": [{"kind": "flash", "shape": "mesh", "size": [[1, 1, 1], "x"], "transparency": [0, 1.5],
                 "ease": ["Back", 3], "material": "Neon"}]},
    {"layers": [{"kind": "ring", "size": [1, 9], "ease": "BounceOutt", "flat": "yes",
                 "transparency": [[0.5, 1], [0.2, 0]]}]},
    {"layers": [{"kind": "decal", "size": [2, 6], "rotation": [0, 360]}]},
    {"layers": [{"kind": "glow"}, {"Kind": "LIGHT", "Colour": "#FFF"}, {"size": 3}, "nope"]},
    {"layers": [{"kind": "particles", "count": 3, "delay": 40, "offset": [1, 2]}], "family": 5,
     "budget": {"particles": -1, "light": 2}, "famliy": "x"},
    {"layers": [{"kind": "particles", "rate": 20, "size": list(range(25))}]},
    "not a spec",
    {"layers": [{"kind": "particles", "count": 1, "speed": [5, 1], "rotation": [0, 7200], "timeScale": 2}]},
    {"layers": [{"kind": "beam", "to": [0, 0, -10], "width": [1, 0.2], "curve": 3, "transparency": [0, 1],
                 "textureMode": "Wrap"}]},
    {"layers": [{"kind": "flash", "size": [[1, 1, 1], [4, 2, 4]], "ease": "SineInOut", "spin": 180},
                {"kind": "ring", "texture": 123, "size": 5, "ease": {"style": "Quint"}},
                {"kind": "particles", "emit": 20, "SpreadAngle": [10, 20], "EmissionDirection": "Front",
                 "Orientation": "VelocityPerpendicular", "flipbook": {"layout": "Grid8x8", "fps": [20, 30]}}]},
    {"layers": [{"kind": "beam", "to": "there", "from": [1, 2], "ease": "Quint", "width": 2},
                {"kind": "light", "spot": [45, "up"], "color": ["#FFFFFF"]}]},
]
TRAIL_CORPUS = [
    {"width": 2, "lifetime": 0.3, "transparency": [0, 1], "color": ["#FFFFFF", "#000000"], "offset": [0, 1, 0]},
    {"width": -1, "axs": "up", "textureMode": "tile", "color": 5, "Lifetime": 30},
    [1, 2],
]


def _driver_body() -> str:
    springs = lua([list(c) for c in SPRING_CASES])
    peaks = lua([list(c) for c in PEAK_CASES])
    kp_cases = "{" + ", ".join(f"function() return {expr} end" for expr, _, _ in KEYPOINT_CASES) + "}"
    corpus = "{" + ", ".join(lua(to_luau_spec(s)) for s in CORPUS) + "}"
    trails = "{" + ", ".join(lua(_table_vectors(t, fxspec.NESTED_KEYS["trail"], fxspec.TYPES["trail"])
                                 if isinstance(t, dict) else t) for t in TRAIL_CORPUS) + "}"
    body = r'''
local R = {}
R.ease = {}
for _, style in F.EASE_STYLES do
	for _, dir in F.EASE_DIRECTIONS do
		local fn, problem = F.easeFn(style .. " " .. dir)
		assert(problem == nil, problem)
		local row = {}
		for i = 0, 40 do
			table.insert(row, fn(i / 40))
		end
		R.ease[style .. "_" .. dir] = row
	end
end
R.easeOutside = { F.ease(-0.5, "Quad In"), F.ease(1.5, "Quad In") }
R.easeNames = {}
for _, form in { "Quint", "quint out", "SineInOut", "BackIn", "expo.out", "circ", "Quintt", "Quad Sideways",
	"QuadOut", "linear in" } do
	local s, d, p = F.easeNames(form)
	R.easeNames[form] = { s, d, p or "" }
end
do
	local s, d, p = F.easeNames({ "Back", "In" })
	R.easeTable = { s, d, p or "" }
	s, d, p = F.easeNames(nil, nil, "quint", "out")
	R.easeDefault = { s, d, p or "" }
	s, d, p = F.easeNames(42)
	R.easeNumber = { s, d, p or "" }
end
R.spring = {}
for _, c in SPRINGS do
	local x, v = F.springStep(c[1], c[2], c[3], c[4], c[5], c[6])
	table.insert(R.spring, { x, v })
end
do
	local x, v = F.springStep(vector.create(1, -2, 3), vector.create(0, 1, 0), vector.create(0, 0, 0), 9, 0.4, 0.05)
	R.springVec = { x, v }
end
R.peak = {}
for _, c in PEAKS do
	local p, t = F.springPeak(c[1], c[2])
	table.insert(R.peak, { p, t, F.impulseForPeak(0.75, c[1], c[2]) })
end
R.kick, R.slowmo = {}, {}
for i = 0, 50 do
	table.insert(R.kick, F.kickEnvelope(i * 0.01, 0.4))
	table.insert(R.slowmo, F.slowmoScale(i * 0.02, 0.2, 1.0, 0.1, 0.3))
end
R.slowmoSqueezed = { F.slowmoScale(0.1, 0.5, 0.4, 0.3, 0.3), F.slowmoScale(0.2, 0.5, 0.4, 0.3, 0.3) }
R.shotProgress = {}
for _, c in { { 0.5, 1, 0.5 }, { 1.2, 1, 0.5 }, { 1.6, 1, 0.5 }, { 0, 0, 0 }, { -0.1, 1, 0 } } do
	local u, phase = F.shotProgress(c[1], c[2], c[3])
	table.insert(R.shotProgress, { u, phase })
end
R.letterbox = { F.letterbox(1920, 1080, 2.39), F.letterbox(2560, 1080, 2.39), F.letterbox(1000, 1000, 2.39),
	F.letterbox(1920, 1080, 1.5), F.letterbox(1000, 1000, 2.39, 0.4), F.letterbox(0, 1080, 2.39) }
R.collision = { F.collisionDistance(10, 4, 5, 0.1), F.collisionDistance(4, 10, 5, 0.1), F.collisionDistance(4, 10, 0, 0.1) }
R.yawPitch = {}
for _, c in LOOKS do
	local yaw, pitch = F.yawPitch(c[1], c[2], c[3])
	table.insert(R.yawPitch, { yaw, pitch })
end
R.orbit = {}
for _, c in { { 10, 3, 90 }, { 10, 3, 0 }, { 5, -1, 180 } } do
	table.insert(R.orbit, { F.orbitOffset(c[1], c[2], c[3]) })
end
R.handheld = {}
for i = 0, 199 do
	local x, y, z = F.handheld(i * 0.05, 0.9, 1)
	table.insert(R.handheld, { x, y, z })
end
do
	local x1 = F.handheld(1.234, 0.9, 1)
	local x2 = F.handheld(1.234, 0.9, 1)
	R.handheldRepeat = x1 == x2
end
do
	local pts = { vector.create(0, 0, 0), vector.create(10, 0, 0), vector.create(10, 10, 0), vector.create(0, 10, 0) }
	local path = F.path(pts)
	R.path = { length = path.length, at = {}, through = F.pathPoint(pts, 1) }
	for _, u in { 0, 0.25, 0.5, 0.75, 1 } do
		table.insert(R.path.at, F.pathAt(path, u))
	end
	local two = F.path({ vector.create(0, 0, 0), vector.create(4, 2, 0) })
	R.path.two = F.pathAt(two, 0.5)
	R.path.one = F.pathAt(F.path({ vector.create(1, 2, 3) }), 0.7)
	R.path.numbers = F.pathAt(F.path({ 0, 10, 30 }), 0.5)
end
R.keypoints = {}
for i, make in KP_CASES do
	local list, problems = F.keypoints(make(), F.isNumber)
	R.keypoints[i] = { list = kps(list) or false, problems = problems }
end
do
	local values = {}
	for i = 1, 25 do
		values[i] = i
	end
	local list, problems = F.keypoints(values, F.isNumber)
	R.resampled = { count = #list, first = list[1].v, last = list[#list].v, problems = #problems }
	local colors = F.keypoints({ "#FF0000", "Tokens.color.primary" }, F.isColor)
	R.colorKeypoints = kps(colors)
	local clampList = F.keypoints({ { 0, -1 }, { 0.5, 0.5, 0.8 }, { 1, 2 } }, F.isNumber)
	local clampProblems = F.clampKeypoints(clampList, 0, 1)
	R.clamped = { list = kps(clampList), problems = #clampProblems }
end
do
	local b = F.budget({ effects = 3, particles = 100, lights = 1 })
	R.budget = { b:add("a", { particles = 40 }), b:add("b", { particles = 40, lights = 1 }), b:add("c", { particles = 40 }),
		b:add("d", { lights = 1 }), b:add("e", {}), b:add("f", {}), b:add("g", { particles = 500 }) }
	b:remove("g")
	R.budgetTotals = { b:total("particles"), b:total("lights"), b:total("effects") }
	local b2 = F.budget({ effects = 2 })
	R.budgetReadd = { b2:add("x"), b2:add("y"), b2:add("x"), b2:add("z") }
end
R.distance = {}
for _, p in { { "kitten", "sitting" }, { "ab", "ba" }, { "ca", "abc" }, { "lifetime", "lifetme" }, { "", "abc" },
	{ "same", "same" }, { "spread", "sped" } } do
	table.insert(R.distance, F.levenshtein(p[1], p[2]))
end
R.closest = {}
local particleKeys = F.layerKeys("particles")
for _, w in WORDS do
	R.closest[w] = F.closest(w, particleKeys) or false
end
do
	local norm, unknown = F.normalizeKeys({ Lifetime = 1, SpreadAngle = 2, colr = 3, speed = 4, SPEED = 5, emit = 6 },
		particleKeys)
	R.normalized = { norm = norm, unknown = unknown }
end
R.hex = { { F.hex("#FF8000") }, { F.hex("ff8000") }, { F.hex("#f80") }, { F.hex("red") ~= nil },
	{ F.tokenName("Tokens.color.primary") }, { F.isColor("Tokens.color.x") }, { F.isContentId("rbxassetid://12") },
	{ F.isTexture("spark_soft") }, { F.isTexture("two words") }, { F.isTexture(123) } }
R.easeKeypoints = kps(F.easeKeypoints(1, 9, "Quint Out", 5))
R.enum = { F.enumValue("Top", { "up", "down" }) or false, F.enumValue(4, { "2x2", "4x4" }) or false,
	F.enumValue("FacingCameraWorldUp", { "facing", "facingUp" }) or false, F.enumValue("sideways", { "up" }) or false }
R.schema = { KINDS = F.KINDS, EFFECT_KEYS = F.EFFECT_KEYS, COMMON_KEYS = F.COMMON_KEYS, LAYER_KEYS = F.LAYER_KEYS,
	NESTED_KEYS = F.NESTED_KEYS, ALIASES = F.ALIASES, ENUM_ALIASES = F.ENUM_ALIASES, TYPES = F.TYPES,
	EASE_STYLES = F.EASE_STYLES }
R.validate = {}
for i, spec in CORPUS do
	R.validate[i] = F.validateEffect(spec)
end
R.validateTrail = {}
for i, spec in TRAILS do
	R.validateTrail[i] = F.validateTrail(spec)
end
print(json(R))
'''
    looks = [look_vector(math.radians(y), math.radians(p)) for y, p in YAW_PITCH]
    words = lua(WORDS)
    return (f"local SPRINGS = {springs}\nlocal PEAKS = {peaks}\nlocal KP_CASES = {kp_cases}\nlocal CORPUS = {corpus}\n"
            f"local TRAILS = {trails}\nlocal LOOKS = {lua(looks)}\nlocal WORDS = {words}\n" + body)


YAW_PITCH = [(0, 0), (90, 0), (-135, 30), (170, -60), (45, 80), (-90, -10)]
WORDS = ["lifetme", "SpreadAngle", "colr", "trasnparency", "zz", "flipbooklayout", "rat", "LIGHTEMISSION", "accel"]


@pytest.fixture(scope="module")
def fx(tmp_path_factory):
    if LUAU is None:
        pytest.skip("standalone luau runtime not installed")
    return run_luau(tmp_path_factory.mktemp("fxmath"), _driver_body())


# ---------------------------------------------------------------------------------------------- the syntax gate
@needs_analyzer
def test_new_kit_modules_pass_the_gate():
    sources = {f"src/ReplicatedStorage/Kit/{m}.luau": _source(m) for m in NEW_MODULES}
    problems = asyncio.run(check_sources(sources))
    assert syntax_errors(problems) == {}, problems
    assert problems == {}, problems                        # no unknown globals, shadowing or unreachable code either


@needs_analyzer
def test_playbook_examples_parse():
    blocks = _lua_blocks()
    assert len(blocks) >= 5
    bad = syntax_errors(asyncio.run(check_sources({f"example{i}.luau": b for i, b in enumerate(blocks)})))
    assert bad == {}, bad


def test_kit_modules_follow_house_rules():
    fxmath, camera, vfx = _source("FxMath"), _source("CameraRig"), _source("VFX")
    code = re.sub(r"--[^\n]*", "", fxmath)
    for pattern in (r"\bgame\b", r"\bworkspace\b", r"\bInstance\.new", r"\bEnum\.", r"\btask\.", r"\bwarn\(",
                    r"\bscript\."):
        assert not re.search(pattern, code), f"FxMath must stay pure Luau (found {pattern})"
    assert fxmath.startswith("--!strict\n--!native") and camera.startswith("--!native")
    assert "BindToRenderStep" in camera and "Enum.RenderPriority.Camera.Value + 1" in camera
    assert "error(" not in camera and "error(" not in vfx and "assert(" not in camera and "assert(" not in vfx
    for src in (camera, vfx):
        assert "anime" not in src.lower()


# ---------------------------------------------------------------------------------------------- FxMath vs Python
@needs_luau
def test_easing_matches_reference(fx):
    for style in EASE_IN:
        for direction in ("In", "Out", "InOut"):
            got = fx["ease"][f"{style}_{direction}"]
            for i, value in enumerate(got):
                assert value == pytest.approx(ease(style, direction, i / 40), abs=1e-9), (style, direction, i)
            assert got[0] == pytest.approx(0, abs=1e-9) and got[-1] == pytest.approx(1, abs=1e-9)
    assert fx["ease"]["Quint_Out"][20] == pytest.approx(0.96875)
    assert fx["easeOutside"] == [0, 1]                                 # clamped outside 0..1


@needs_luau
def test_easing_names_match_python(fx):
    for form, (style, direction, problem) in fx["easeNames"].items():
        s, d, p = fxspec.ease_names(form)
        assert (s, d, p or "") == (style, direction, problem), form
    assert fx["easeNames"]["quint out"][:2] == ["Quint", "Out"]
    assert fx["easeNames"]["SineInOut"][:2] == ["Sine", "InOut"]
    assert fx["easeNames"]["expo.out"][:2] == ["Exponential", "Out"]
    assert "did you mean Quint" in fx["easeNames"]["Quintt"][2]
    assert fx["easeTable"] == ["Back", "In", ""]
    assert fx["easeDefault"] == ["Quint", "Out", ""]
    assert fx["easeNumber"][2] != ""


@needs_luau
def test_spring_matches_numeric_integration(fx):
    for (x0, v0, target, w, z, dt), (x, v) in zip(SPRING_CASES, fx["spring"]):
        rx, rv = rk4_spring(x0, v0, target, w, z, dt, steps=max(200, int(dt * 4000)))
        tol = 2e-3 if abs(z - 1) < 1e-3 and z != 1 else 1e-6
        assert x == pytest.approx(rx, abs=tol * max(1, abs(rx))), (x0, v0, target, w, z, dt)
        assert v == pytest.approx(rv, abs=tol * 10 * max(1, abs(rv))), (x0, v0, target, w, z, dt)
    x, v = fx["springVec"]
    for i, (p0, u0) in enumerate(zip((1, -2, 3), (0, 1, 0))):
        rx, rv = rk4_spring(p0, u0, 0, 9, 0.4, 0.05)
        assert x[i] == pytest.approx(rx, rel=1e-5, abs=1e-6) and v[i] == pytest.approx(rv, rel=1e-5, abs=1e-5)
    assert fx["spring"][9] == [1, 2]                                   # dt = 0: unchanged
    assert fx["spring"][10][0] == pytest.approx(0, abs=1e-9)           # a long step settles on the target


@needs_luau
def test_spring_peak_and_impulse(fx):
    for (w, z), (peak, t, impulse) in zip(PEAK_CASES, fx["peak"]):
        ref_peak, ref_t = numeric_peak(w, z)
        assert peak == pytest.approx(ref_peak, rel=1e-3), (w, z)
        assert t == pytest.approx(ref_t, rel=1e-2, abs=1e-3), (w, z)
        assert impulse * peak == pytest.approx(0.75)                  # a punch's strength reads in studs


@needs_luau
def test_envelopes(fx):
    kick = fx["kick"]                                                  # t = 0..0.5 by 0.01, 0.4 s kick, 0.08 s attack
    assert kick[0] == 0 and kick[8] == pytest.approx(1) and kick[40] == pytest.approx(0, abs=1e-12) and kick[50] == 0
    assert all(a <= b for a, b in zip(kick[:9], kick[1:9])) and all(a >= b for a, b in zip(kick[8:40], kick[9:41]))
    for i, value in enumerate(kick):
        t = i * 0.01
        if 0.08 <= t < 0.4:
            u = (t - 0.08) / 0.32
            assert value == pytest.approx(0.5 * (1 + math.cos(u * math.pi)))
    slow = fx["slowmo"]                                                # t = 0..1 by 0.02: 0.2 scale, ramps 0.1 / 0.3
    assert slow == pytest.approx([slowmo_ref(i * 0.02, 0.2, 1.0, 0.1, 0.3) for i in range(51)], abs=1e-12)
    assert slow[0] == 1 and slow[5] == pytest.approx(0.2) and slow[25] == pytest.approx(0.2) and slow[50] == 1
    assert slowmo_ref(0.85, 0.2, 1.0, 0.1, 0.3) == pytest.approx(0.6)          # halfway up the ramp out
    assert all(0.2 - 1e-12 <= s <= 1 for s in slow)
    assert fx["slowmoSqueezed"][0] < 1 and fx["slowmoSqueezed"][1] == pytest.approx(0.5)   # ramps fit a short beat
    assert fx["shotProgress"] == [[0.5, "move"], [1, "hold"], [1, "done"], [1, "done"], [0, "move"]]


@needs_luau
def test_letterbox_collision_angles_orbit(fx):
    lb = fx["letterbox"]
    assert lb[0] == pytest.approx((1080 - 1920 / 2.39) / 2160)
    assert lb[1] == pytest.approx((1080 - 2560 / 2.39) / 2160)
    assert lb[2] == 0.25 and lb[4] == pytest.approx((1000 - 1000 / 2.39) / 2000) and lb[3] == 0 and lb[5] == 0
    assert fx["collision"] == pytest.approx([4, 4 + 6 * (1 - math.exp(-0.5)), 4])
    for (yaw, pitch), (gy, gp) in zip(YAW_PITCH, fx["yawPitch"]):
        assert gp == pytest.approx(math.radians(pitch), abs=1e-9)
        assert math.cos(gy - math.radians(yaw)) == pytest.approx(1, abs=1e-9)
    assert fx["orbit"][0] == pytest.approx([10, 3, 0], abs=1e-9)
    assert fx["orbit"][1] == pytest.approx([0, 3, 10], abs=1e-9)
    assert fx["orbit"][2] == pytest.approx([0, -1, -5], abs=1e-9)


@needs_luau
def test_handheld_noise(fx):
    samples = fx["handheld"]
    flat = [c for s in samples for c in s]
    assert all(-1 <= c <= 1 for c in flat)
    assert len({round(c, 6) for c in flat}) > 100                      # it moves
    assert abs(sum(flat) / len(flat)) < 0.35                          # roughly centred
    assert fx["handheldRepeat"] is True                               # deterministic


@needs_luau
def test_paths_move_evenly_through_their_points(fx):
    pts = [[0, 0, 0], [10, 0, 0], [10, 10, 0], [0, 10, 0]]
    got = fx["path"]
    assert got["through"] == [10, 0, 0]
    assert got["at"][0] == [0, 0, 0] and got["at"][-1] == pytest.approx([0, 10, 0], abs=1e-4)
    for u, point in zip((0.25, 0.5, 0.75), got["at"][1:4]):
        ref, length = arc_point(pts, u)
        assert math.dist(point, ref) < 0.06, (u, point, ref)
    assert got["length"] == pytest.approx(arc_point(pts, 1)[1], rel=5e-3)
    assert got["two"] == pytest.approx([2, 1, 0]) and got["one"] == [1, 2, 3]
    assert got["numbers"] == pytest.approx(arc_point([[0], [10], [30]], 0.5)[0][0], abs=0.05)


@needs_luau
def test_keypoints_match_expectations_and_python(fx):
    for (expr, expected, n_problems), got in zip(KEYPOINT_CASES, fx["keypoints"]):
        if expected is None:
            assert got["list"] is False, expr
        else:
            assert close(got["list"], expected), (expr, got["list"])
        assert len(got["problems"]) == n_problems, (expr, got["problems"])
    assert fx["resampled"] == {"count": 20, "first": 1, "last": 25, "problems": 1}
    assert fx["colorKeypoints"] == [[0, "#FF0000", 0], [1, "Tokens.color.primary", 0]]
    assert fx["clamped"] == {"list": [[0, 0, 0], [0.5, 0.5, 0.5], [1, 1, 0]], "problems": 1}
    # the Python mirror gives the same keypoints and problem counts
    py_inputs = [5, [0.2, 1, 0], [7], [[0.3, 2], [0.8, 4, 0.5]], [[0.5, 1], [0.2, 2], [1, 0]], [[0, 1], [1.5, 0]],
                 [{"time": 0, "value": 3}, {"t": 1, "v": 1, "e": 0.2}], "big", [], [[0, 1], "x", [1, 2]],
                 [[0, 1, -1], [1, 1]]]
    for value, (expr, expected, n_problems) in zip(py_inputs, KEYPOINT_CASES):
        kps, problems = fxspec.keypoints(value, fxspec.is_num)
        assert close(None if kps is None else [list(k) for k in kps], expected), expr
        assert len(problems) == n_problems, expr


@needs_luau
def test_budget_drops_the_oldest(fx):
    assert fx["budget"] == [[], [], ["a"], ["b"], [], ["c"], ["d", "e", "f"]]
    assert fx["budgetTotals"] == [0, 0, 0]
    assert fx["budgetReadd"] == [[], [], [], ["y"]]                    # a re-added entry counts as the newest


@needs_luau
def test_did_you_mean_and_key_normalization(fx):
    pairs = [("kitten", "sitting"), ("ab", "ba"), ("ca", "abc"), ("lifetime", "lifetme"), ("", "abc"), ("same", "same"),
             ("spread", "sped")]
    assert fx["distance"] == [fxspec.distance(a, b) for a, b in pairs] == [3, 1, 3, 1, 3, 0, 2]
    keys = fxspec.ALL_LAYER_KEYS["particles"]
    for word in WORDS:
        assert (fx["closest"][word] or None) == fxspec.closest(word, keys), word
    assert fx["closest"]["lifetme"] == "lifetime" and fx["closest"]["flipbooklayout"] == "flipbook"
    assert fx["closest"]["zz"] is False
    assert fx["normalized"]["norm"] == {"lifetime": 1, "spread": 2, "speed": 4, "count": 6}
    assert fx["normalized"]["unknown"] == [{"key": "colr", "suggestion": "color"}]
    py_norm, py_unknown, _ = fxspec.normalize_keys({"Lifetime": 1, "SpreadAngle": 2, "colr": 3, "speed": 4, "SPEED": 5,
                                                    "emit": 6}, keys)
    assert py_norm == {"lifetime": 1, "spread": 2, "speed": 4, "count": 6} and py_unknown == [("colr", "color")]


@needs_luau
def test_colours_textures_enums(fx):
    h = fx["hex"]
    assert h[0] == pytest.approx([1, 128 / 255, 0]) and h[1] == h[0]
    assert h[2] == pytest.approx([1, 0x88 / 255, 0]) and h[3] == [False]
    assert h[4] == ["primary"] and h[5] == [True] and h[6] == [True]
    assert h[7] == [True] and h[8] == [False] and h[9] == [True]
    assert fxspec.hex_color("#FF8000") == pytest.approx(tuple(h[0])) and fxspec.token_name("Tokens.color.primary") == "primary"
    assert close(fx["easeKeypoints"], [[t, 1 + 8 * ease("Quint", "Out", t), 0] for t in (0, 0.25, 0.5, 0.75, 1)])
    assert fx["enum"] == ["up", "4x4", "facingUp", False]


@needs_luau
def test_schema_is_identical_in_luau_and_python(fx):
    py = json.loads(json.dumps(fxspec.schema()))
    assert fx["schema"] == py
    for kind, keys in fxspec.LAYER_KEYS.items():
        assert set(keys) == set(fxspec.TYPES[kind]), kind            # every key has a type and every type a key
    for name, keys in fxspec.NESTED_KEYS.items():
        assert set(keys) == set(fxspec.TYPES[name]), name


@needs_luau
def test_validators_agree_on_the_corpus(fx):
    assert len(fx["validate"]) == len(CORPUS)
    for spec, luau_errors in zip(CORPUS, fx["validate"]):
        assert fxspec.validate_effect(spec) == luau_errors, json.dumps(spec)
    for spec, luau_errors in zip(TRAIL_CORPUS, fx["validateTrail"]):
        assert fxspec.validate_trail(spec) == luau_errors, json.dumps(spec)
    assert fx["validate"][0] == [] and fx["validate"][2] == [] and fx["validate"][16] == [] and fx["validate"][17] == []
    assert fx["validateTrail"][0] == []


# ---------------------------------------------------------------------------------------------- fxspec (Python)
def test_fxspec_reports_every_error_at_once():
    spec = CORPUS[5]
    errors = fxspec.validate_effect(spec)
    paths = {e.split(": ")[0] for e in errors}
    assert {"layers[1].count", "layers[1].lifetime", "layers[1].spread", "layers[1].size", "layers[1].transparency",
            "layers[1].color", "layers[1].orientation", "layers[1].direction", "layers[1].flipbook.layout",
            "layers[1].flipbook.mod", "layers[1].texture", "layers[1].Lifetme"} <= paths
    assert any("did you mean lifetime" in e for e in errors)
    assert any("flipbook.mod: unknown key (did you mean mode?)" in e for e in errors)
    errors = fxspec.validate_effect(CORPUS[11])
    assert any("unknown kind \"glow\"" in e for e in errors) and any("layers[3].kind: missing" in e for e in errors)
    assert any('layers[4]: expected a layer table, got "nope"' in e for e in errors)
    errors = fxspec.validate_effect(CORPUS[12])
    assert any(e.startswith("famliy: unknown key for an effect (did you mean family?)") for e in errors)
    assert any(e.startswith("budget.light: unknown key (did you mean lights?)") for e in errors)


def test_fxspec_ranges_and_rules():
    def paths(spec):
        return [e.split(": ")[0] for e in fxspec.validate_effect(spec)]
    assert paths({"layers": [{"kind": "particles", "count": 5, "lifetime": 25}]}) == ["layers[1].lifetime"]
    assert paths({"layers": [{"kind": "particles", "count": 5, "transparency": [0, 1.2]}]}) == ["layers[1].transparency"]
    assert paths({"layers": [{"kind": "particles", "count": 5, "size": [[0, 1]] * 21}]}) == ["layers[1].size"]
    assert paths({"layers": [{"kind": "light", "range": 61}]}) == ["layers[1].range"]
    assert paths({"layers": [{"kind": "beam", "to": [1, 2, 3], "segments": 2.5}]}) == ["layers[1].segments"]
    assert paths({"layers": [{"kind": "flash", "shape": "mesh", "mesh": "rbxassetid://1"}]}) == []
    assert paths({"layers": [{"kind": "decal", "texture": "crack", "transparency": [0, 1]}]}) == []
    assert paths([{"kind": "ring"}]) == []                              # a bare list of layers works
    assert fxspec.validate_trail({"width": 2, "enabled": "yes"}) == ["trail.enabled: expected true or false, got \"yes\""]


def test_fxspec_taste_warnings():
    lazy = fxspec.check_effect({"layers": [{"kind": "particles", "count": 400, "lifetime": [0.5, 4], "size": 1,
                                            "transparency": 0.2, "lightEmission": 1, "brightness": 8}]})
    assert lazy.ok
    text = " ".join(lazy.warnings)
    for fragment in ("one layer", "texture", "size", "transparency", "mud", "confetti", "white-out"):
        assert fragment in text, fragment
    same = fxspec.check_effect({"layers": [{"kind": "flash", "color": "#FFFFFF", "duration": 0.6},
                                           {"kind": "light", "color": "#FFFFFF", "brightness": 12}]})
    text = " ".join(same.warnings)
    assert "same colour" in text and "1-4 frames" in text and "whites out" in text
    renamed = fxspec.check_effect({"layers": [{"kind": "ring"}, {"kind": "particles", "Rate": 5, "Lifetime": 1,
                                                                 "texture": "a", "size": [1, 0], "duration": 1}]},
                                  color_tokens=["primary"])
    assert "layers[2].Lifetime: works, but write lifetime" in renamed.warnings
    tokens = fxspec.check_effect({"layers": [{"kind": "ring", "color": "Tokens.color.nope"},
                                             {"kind": "ring", "color": "Tokens.color.primary"}]}, color_tokens=["primary"])
    assert any("Tokens.color.nope is not in the palette" in w for w in tokens.warnings)
    assert fxspec.check_trail({"width": 1}).warnings                   # no taper


def test_fxspec_tool():
    (tool,) = fxspec.tools()
    assert tool.name == "check_fx_spec" and tool.spec()["function"]["parameters"]["required"] == ["spec"]
    res = asyncio.run(tool.invoke({"spec": json.dumps(CORPUS[6])}))      # a JSON string works too
    assert "error" in res.text and res.data["errors"]
    res = asyncio.run(tool.invoke({"spec": CORPUS[0]}))
    assert res.data["errors"] == [] and "no errors" in res.text
    res = asyncio.run(tool.invoke({"spec": TRAIL_CORPUS[1], "kind": "trail"}))
    assert any("axs" in e for e in res.data["errors"])


# ---------------------------------------------------------------------------------------------- the playbook, run
DOC_DRIVER = r'''
local captured = { effects = {}, trails = {}, sequences = {}, follows = {}, plays = {}, calls = {}, errors = {} }
local function note(kind)
	captured.calls[kind] = (captured.calls[kind] or 0) + 1
end
local function fail(msg)
	table.insert(captured.errors, msg)
end
local STUB = {}
local function stub(name)
	return setmetatable({ __name = name }, STUB)
end
STUB.__index = function(self, k)
	local name = rawget(self, "__name") .. "." .. tostring(k)
	if k == "WaitForChild" or k == "FindFirstChild" or k == "GetService" then
		return function(_, child)
			return stub(if k == "GetService" then tostring(child) else rawget(self, "__name") .. "." .. tostring(child))
		end
	end
	return stub(name)
end
STUB.__call = function(self)
	return stub(rawget(self, "__name") .. "()")
end
local function arith()
	return stub("value")
end
STUB.__add, STUB.__sub, STUB.__mul, STUB.__div, STUB.__mod, STUB.__pow, STUB.__idiv = arith, arith, arith, arith, arith, arith, arith
STUB.__unm = arith
STUB.__concat = function()
	return "text"
end
STUB.__lt = function()
	return false
end
STUB.__le = STUB.__lt
STUB.__len = function()
	return 0
end
STUB.__iter = function()
	return function()
		return nil
	end
end
STUB.__tostring = function(self)
	return rawget(self, "__name")
end

local function run(fn, ...)
	for _, a in { ... } do
		if type(a) == "function" then
			local ok, err = pcall(a, 1)
			if not ok then
				fail("callback: " .. tostring(err))
			end
		end
	end
end
local function checkKeys(where, tbl, keys)
	if tbl == nil then
		return
	end
	if type(tbl) ~= "table" then
		fail(where .. ": expected a table")
		return
	end
	local _, unknown = F.normalizeKeys(tbl, keys)
	for _, u in unknown do
		fail(where .. ": unknown option " .. u.key)
	end
end
local function handle(kind, fields, methods)
	local h = {}
	for k, v in fields do
		h[k] = v
	end
	for _, m in methods do
		h[m] = function(self, ...)
			run(nil, ...)
			return self
		end
	end
	return setmetatable(h, { __index = function(_, k)
		error(kind .. " has no member " .. tostring(k), 2)
	end })
end
local EFFECT_HANDLE = { "stop", "destroy", "Destroy", "andThen" }
local TRAIL_HANDLE = { "enable", "burst", "clear", "destroy", "Destroy" }
local VIGNETTE_HANDLE = { "set", "stop", "Destroy" }
local FOLLOW_HANDLE = { "set", "stop", "switchShoulder", "setAngles", "state", "Destroy" }
local SHOT_HANDLE = { "andThen", "await", "skip", "cancel", "Destroy" }

local VFXS = { maxLights = 6, defaultBudget = {} }
function VFXS.preset(name, spec)
	table.insert(captured.effects, { where = "preset " .. tostring(name), spec = spec })
end
function VFXS.effect(spec, at, opts)
	table.insert(captured.effects, { where = "effect", spec = spec })
	checkKeys("effect opts", opts, F.EFFECT_OPTS)
	return handle("effect handle", { alive = true }, EFFECT_HANDLE)
end
function VFXS.play(name, at, opts)
	table.insert(captured.plays, name)
	checkKeys("play opts", opts, F.EFFECT_OPTS)
	return handle("effect handle", { alive = true }, EFFECT_HANDLE)
end
function VFXS.flashLight()
	note("flashLight")
	return handle("effect handle", { alive = true }, EFFECT_HANDLE)
end
function VFXS.hitstop(seconds, opts)
	note("hitstop")
	checkKeys("hitstop opts", opts, F.HITSTOP_KEYS)
end
function VFXS.screenFlash()
	note("screenFlash")
end
function VFXS.vignette(color, seconds, opts)
	note("vignette")
	checkKeys("vignette opts", opts, F.VIGNETTE_KEYS)
	return handle("vignette", { alive = true }, VIGNETTE_HANDLE)
end
function VFXS.trail(part, spec)
	table.insert(captured.trails, spec)
	return handle("trail", { alive = true }, TRAIL_HANDLE)
end
function VFXS.has()
	return true
end
function VFXS.names()
	return {}
end
function VFXS.budget(family, caps)
	checkKeys("budget", caps, F.NESTED_KEYS.budget)
end
function VFXS.validate(spec)
	return F.validateEffect(spec)
end
function VFXS.clear() end
setmetatable(VFXS, { __index = function(_, k)
	error("VFX has no member " .. tostring(k), 2)
end })

local function checkFollow(opts)
	checkKeys("follow", opts, F.FOLLOW_KEYS)
	if type(opts) == "table" then
		local norm = F.normalizeKeys(opts, F.FOLLOW_KEYS)
		for _, nested in { "speedFov", "zoom", "autoAlign", "sensitivity" } do
			if type(norm[nested]) == "table" then
				checkKeys("follow " .. nested, norm[nested], F.CAMERA_NESTED_KEYS[nested])
			end
		end
	end
end
local function checkShot(spec, i)
	checkKeys("shot " .. i, spec, F.SHOT_KEYS)
	if type(spec) ~= "table" then
		return
	end
	local norm = F.normalizeKeys(spec, F.SHOT_KEYS)
	for _, nested in { "orbit", "handheld", "letterbox", "slowmo" } do
		if type(norm[nested]) == "table" then
			checkKeys("shot " .. i .. " " .. nested, norm[nested], F.CAMERA_NESTED_KEYS[nested])
		end
	end
	if norm.ease ~= nil then
		local _, _, problem = F.easeNames(norm.ease)
		if problem then
			fail("shot " .. i .. " ease: " .. problem)
		end
	end
	if type(norm.onStart) == "function" then
		run(nil, norm.onStart)
	end
end
local CAM = { timeScale = 1, reducedMotionScale = 0, punchSpeed = 16, punchDamping = 0.45, punchTilt = 0.03 }
function CAM.follow(opts)
	checkFollow(opts)
	table.insert(captured.follows, opts)
	local h = handle("follow rig", {}, FOLLOW_HANDLE)
	rawset(h, "set", function(self, o)
		checkFollow(o)
		return self
	end)
	return h
end
function CAM.sequence(shots, opts)
	checkKeys("sequence opts", opts, F.SEQUENCE_KEYS)
	for i, s in shots do
		checkShot(s, i)
	end
	table.insert(captured.sequences, { count = #shots, opts = opts or {} })
	return handle("shot handle", { status = "playing", done = false }, SHOT_HANDLE)
end
function CAM.shot(spec)
	checkShot(spec, 1)
	table.insert(captured.sequences, { count = 1, opts = {} })
	return handle("shot handle", { status = "playing", done = false }, SHOT_HANDLE)
end
function CAM.kick()
	note("kick")
end
function CAM.punch()
	note("punch")
end
function CAM.shake()
	note("shake")
end
function CAM.slowmo(scale, seconds, opts)
	note("slowmo")
	checkKeys("slowmo opts", opts, F.CAMERA_NESTED_KEYS.slowmo)
end
function CAM.onTimeScale()
	return { Disconnect = function() end }
end
function CAM.current()
	return nil
end
function CAM.isCinematic()
	return false
end
function CAM.pose()
	return nil, nil
end
setmetatable(CAM, { __index = function(_, k)
	error("CameraRig has no member " .. tostring(k), 2)
end })

local TOKENS = setmetatable({ color = setmetatable({}, { __index = function(_, k)
	return "Tokens.color." .. tostring(k)
end }) }, { __index = function(_, k)
	return stub("Tokens." .. tostring(k))
end })
local function fakeRequire(x)
	local name = if type(x) == "table" then tostring(rawget(x, "__name")) else tostring(x)
	if string.find(name, "Kit%.VFX$") then
		return VFXS
	elseif string.find(name, "Kit%.CameraRig$") then
		return CAM
	elseif string.find(name, "Tokens$") then
		return TOKENS
	end
	return stub("module " .. name)
end
local function hex(r, g, b)
	return string.format("#%02X%02X%02X", math.floor(r + 0.5), math.floor(g + 0.5), math.floor(b + 0.5))
end
local function allNumbers(...)
	for _, v in { ... } do
		if type(v) ~= "number" then
			return false
		end
	end
	return true
end
local V3 = { zero = vector.create(0, 0, 0), one = vector.create(1, 1, 1), xAxis = vector.create(1, 0, 0),
	yAxis = vector.create(0, 1, 0), zAxis = vector.create(0, 0, 1) }
function V3.new(x, y, z)
	if allNumbers(x or 0, y or 0, z or 0) then
		return vector.create(x or 0, y or 0, z or 0)
	end
	return stub("Vector3")
end
local C3 = {}
function C3.new(r, g, b)
	return if allNumbers(r, g, b) then hex(r * 255, g * 255, b * 255) else stub("Color3")
end
function C3.fromRGB(r, g, b)
	return if allNumbers(r, g, b) then hex(r, g, b) else stub("Color3")
end
function C3.fromHex(h)
	return h
end
local TASK = {}
function TASK.spawn(fn, ...)
	if type(fn) == "function" then
		pcall(fn, ...)
	end
end
function TASK.delay(_, fn, ...)
	TASK.spawn(fn, ...)
end
TASK.defer = TASK.spawn
function TASK.wait()
	return 0
end
function TASK.cancel() end
local GAME = setmetatable({ GetService = function(_, name)
	return stub(tostring(name))
end }, STUB)
rawset(GAME, "__name", "game")

local ENV = setmetatable({ game = GAME, workspace = stub("workspace"), script = stub("script"), require = fakeRequire,
	Vector3 = V3, Color3 = C3, CFrame = stub("CFrame"), Enum = stub("Enum"), task = TASK, Instance = stub("Instance"),
	math = math, string = string, table = table, vector = vector, os = os, coroutine = coroutine, typeof = typeof,
	type = type, pairs = pairs, ipairs = ipairs, next = next, select = select, tostring = tostring, tonumber = tonumber,
	pcall = pcall, error = error, setmetatable = setmetatable, getmetatable = getmetatable, rawget = rawget,
	print = function() end, warn = function() end }, { __index = function(_, k)
	return stub(tostring(k))
end })

local function exercise(name, fn, kinds)
	local args = {}
	for i, kind in kinds do
		args[i] = if kind == "number" then 50 elseif kind == "string" then "text" elseif kind == "boolean" then true
			else stub(name .. ".arg" .. i)
	end
	local ok, result = pcall(fn, table.unpack(args, 1, #kinds))
	if not ok then
		fail(name .. ": " .. tostring(result))
	elseif type(result) == "function" then
		local ok2, err = pcall(result, stub(name .. ".result.arg"))
		if not ok2 then
			fail(name .. " (returned function): " .. tostring(err))
		end
	end
	note("exercised")
end

for i, src in BLOCKS do
	local chunk, err = loadstring(src, "example" .. i)
	if not chunk then
		fail("example " .. i .. " does not load: " .. tostring(err))
	else
		setfenv(chunk, ENV)
		local ok, e = pcall(chunk, exercise)
		if not ok then
			fail("example " .. i .. ": " .. tostring(e))
		end
	end
end

local out = { errors = captured.errors, effects = {}, trails = {}, sequences = captured.sequences,
	follows = #captured.follows, plays = captured.plays, calls = captured.calls }
for _, e in captured.effects do
	table.insert(out.effects, { where = e.where, layers = if type(e.spec) == "table" and type(e.spec.layers) == "table"
		then #e.spec.layers else 0, problems = F.validateEffect(e.spec) })
end
for _, t in captured.trails do
	table.insert(out.trails, F.validateTrail(t))
end
print(json(out))
'''


def _exercise_calls(block: str) -> str:
    """Code appended to an example (same chunk, so its locals are in scope) that calls each local function it defines
    with stand-ins for its parameters: numbers for `: number` parameters, recording stubs otherwise."""
    calls = []
    for name, params in re.findall(r"^local function (\w+)\(([^)]*)\)", block, re.M):
        kinds = []
        for p in filter(None, (x.strip() for x in params.split(","))):
            annotation = p.split(":", 1)[1].strip() if ":" in p else ""
            kinds.append(annotation if annotation in ("number", "string", "boolean") else "stub")
        calls.append(f'__exercise("{name}", {name}, {lua(kinds)})')
    return "\nlocal __exercise = ...\n" + "\n".join(calls) + "\n" if calls else ""


def _stub_api(prefix: str) -> set[str]:
    return set(re.findall(rf"^function {prefix}\.(\w+)\(", DOC_DRIVER, re.M))


def _module_api(src: str, table: str) -> set[str]:
    return set(re.findall(rf"^function {table}[.:](\w+)\(", src, re.M)) | set(
        re.findall(rf"^{table}\.(\w+) = {table}\.\w+$", src, re.M))


@needs_luau
def test_playbook_examples_run_against_the_kit_api(tmp_path):
    blocks = _lua_blocks()
    # the stubs expose exactly the real modules' API, so an example calling anything else fails
    assert _stub_api("VFXS") == _module_api(_source("VFX"), "VFX")
    assert _stub_api("CAM") == _module_api(_source("CameraRig"), "CameraRig")
    handles = {"EFFECT_HANDLE": ("VFX", "Effect"), "TRAIL_HANDLE": ("VFX", "Trail"),
               "VIGNETTE_HANDLE": ("VFX", "Vignette"), "FOLLOW_HANDLE": ("CameraRig", "FollowHandle"),
               "SHOT_HANDLE": ("CameraRig", "ShotHandle")}
    for const, (module, table) in handles.items():
        listed = set(re.findall(r'"(\w+)"', re.search(rf"local {const} = (\{{[^}}]*\}})", DOC_DRIVER).group(1)))
        real = {m for m in _module_api(_source(module), table) if not m.startswith("_")}
        assert listed == real, (const, listed ^ real)
    sources = [b + _exercise_calls(b) for b in blocks]
    body = f"local BLOCKS = {lua(sources)}\n" + DOC_DRIVER
    got = run_luau(tmp_path, body)
    assert got["errors"] == [], got["errors"]
    assert got["calls"].get("exercised", 0) >= 4
    presets = {e["where"]: e for e in got["effects"]}
    assert {"preset impact", "preset pickup", "preset dash_burst"} <= set(presets)
    for e in got["effects"]:
        assert e["problems"] == [], (e["where"], e["problems"])
    assert presets["preset impact"]["layers"] >= 5
    assert got["trails"] == [[]]
    assert got["follows"] >= 1
    cinematic = [s for s in got["sequences"] if s["count"] == 3]
    assert cinematic and cinematic[0]["opts"].get("letterbox") and cinematic[0]["opts"].get("skipInput")
    for kind in ("kick", "punch", "shake", "hitstop", "screenFlash"):
        assert got["calls"].get(kind, 0) >= 1, kind
    assert {"impact", "pickup", "dash_burst"} <= set(got["plays"])


def test_playbook_fits_the_brief_budget():
    """Builder briefs include this playbook cut to 12000 characters (6000 in fix briefs): the whole reference must
    survive the shorter cut and the examples the longer one."""
    text = PLAYBOOK.read_text(encoding="utf-8")
    assert len(text) <= 12000
    assert text.index("## Example 1") <= 6000


def test_documented_api_exists():
    """Every VFX.x / CameraRig.x named in the playbook, the proposed KIT_API lines and KIT_API itself is real."""
    vfx_api = _module_api(_source("VFX"), "VFX") | {"maxLights", "defaultBudget"}
    cam_api = _module_api(_source("CameraRig"), "CameraRig") | {"timeScale", "reducedMotionScale", "punchSpeed",
                                                                  "punchDamping", "punchTilt"}
    for text in (PLAYBOOK.read_text(encoding="utf-8"), PROPOSED_KIT_API, KIT_API):
        for name in re.findall(r"\bVFX\.(\w+)", text):
            assert name in vfx_api, f"VFX.{name}"
        for name in re.findall(r"\bCameraRig\.(\w+)", text):
            assert name in cam_api, f"CameraRig.{name}"
    for key in re.findall(r"\bpreset=\"(\w+)\"", PROPOSED_KIT_API):
        assert key in _source("CameraRig")


# ---------------------------------------------------------------------------------------------- the modules, run
# CameraRig and VFX need Roblox. ROBLOX_MOCK is a small engine for the standalone runtime: strict where Roblox is
# strict (datatype constructors such as NumberSequence and NumberRange, property names and types per class, enum
# items), a virtual clock with task scheduling and tweens, render-step priorities, and a default camera that rewrites
# the camera every frame and reads its look direction back. The scenarios check what no syntax gate can: ownership
# and hand-back of the camera, blends, feed-forward follow, collision, input direction, cleanup, budgets, hitstop,
# and that bad input never throws (nor makes a layer hand the engine a value it rejects).
ROBLOX_MOCK = r'''-- A small Roblox for the standalone Luau runtime: enough of the engine for CameraRig and VFX to run, strict where
-- Roblox is strict (datatype constructors, property names and types, enum items), with a virtual clock.
local M = {}
local TYPE = setmetatable({}, { __mode = "k" })
local function tag(v, name)
	TYPE[v] = name
	return v
end
local function rtypeof(v)
	if type(v) == "table" and TYPE[v] then
		return TYPE[v]
	end
	return typeof(v)
end
M.typeof = rtypeof
M.warnings = {}
M.errors = {}
M.clock = 0

------------------------------------------------------------------ Vector3 / Vector2
local V3 = {}
local V3MT = {}
local function V(x, y, z)
	return tag(setmetatable({ X = x, Y = y, Z = z }, V3MT), "Vector3")
end
local function isV(v)
	return rtypeof(v) == "Vector3"
end
V3MT.__add = function(a, b)
	assert(isV(a) and isV(b), "Vector3 + expects Vector3s")
	return V(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
end
V3MT.__sub = function(a, b)
	assert(isV(a) and isV(b), "Vector3 - expects Vector3s")
	return V(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
end
V3MT.__mul = function(a, b)
	if type(a) == "number" then
		return V(a * b.X, a * b.Y, a * b.Z)
	elseif type(b) == "number" then
		return V(a.X * b, a.Y * b, a.Z * b)
	end
	assert(isV(a) and isV(b), "Vector3 * expects a number or a Vector3")
	return V(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end
V3MT.__div = function(a, b)
	assert(type(b) == "number", "Vector3 / expects a number")
	return V(a.X / b, a.Y / b, a.Z / b)
end
V3MT.__unm = function(a)
	return V(-a.X, -a.Y, -a.Z)
end
V3MT.__eq = function(a, b)
	return a.X == b.X and a.Y == b.Y and a.Z == b.Z
end
V3MT.__tostring = function(a)
	return string.format("%g, %g, %g", a.X, a.Y, a.Z)
end
local V3METHODS = {
	Dot = function(a, b)
		return a.X * b.X + a.Y * b.Y + a.Z * b.Z
	end,
	Cross = function(a, b)
		return V(a.Y * b.Z - a.Z * b.Y, a.Z * b.X - a.X * b.Z, a.X * b.Y - a.Y * b.X)
	end,
	Lerp = function(a, b, t)
		return a + (b - a) * t
	end,
}
V3MT.__index = function(v, k)
	if k == "Magnitude" then
		return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
	elseif k == "Unit" then
		local m = math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
		if m == 0 then
			return V(0 / 0, 0 / 0, 0 / 0)
		end
		return V(v.X / m, v.Y / m, v.Z / m)
	end
	local f = V3METHODS[k]
	if f then
		return f
	end
	error(tostring(k) .. " is not a valid member of Vector3", 2)
end
V3.new = function(x, y, z)
	return V(x or 0, y or 0, z or 0)
end
V3.zero, V3.one = V(0, 0, 0), V(1, 1, 1)
V3.xAxis, V3.yAxis, V3.zAxis = V(1, 0, 0), V(0, 1, 0), V(0, 0, 1)
M.Vector3 = V3

local V2MT = {}
local function V2(x, y)
	return tag(setmetatable({ X = x, Y = y }, V2MT), "Vector2")
end
V2MT.__index = function(_, k)
	error(tostring(k) .. " is not a valid member of Vector2", 2)
end
V2MT.__eq = function(a, b)
	return a.X == b.X and a.Y == b.Y
end
M.Vector2 = { new = function(x, y)
	return V2(x or 0, y or 0)
end, zero = V2(0, 0), one = V2(1, 1) }

------------------------------------------------------------------ CFrame (position + rotation matrix, columns right/up/back)
local CFMT = {}
local function CF(p, r)
	return tag(setmetatable({ p = p, r = r }, CFMT), "CFrame")
end
local function mat(r00, r01, r02, r10, r11, r12, r20, r21, r22)
	return { r00, r01, r02, r10, r11, r12, r20, r21, r22 }
end
local IDENT = mat(1, 0, 0, 0, 1, 0, 0, 0, 1)
local function mmul(a, b)
	local out = {}
	for i = 0, 2 do
		for j = 0, 2 do
			out[i * 3 + j + 1] = a[i * 3 + 1] * b[j + 1] + a[i * 3 + 2] * b[3 + j + 1] + a[i * 3 + 3] * b[6 + j + 1]
		end
	end
	return out
end
local function mvec(a, v)
	return V(a[1] * v.X + a[2] * v.Y + a[3] * v.Z, a[4] * v.X + a[5] * v.Y + a[6] * v.Z, a[7] * v.X + a[8] * v.Y + a[9] * v.Z)
end
local function mtrans(a)
	return mat(a[1], a[4], a[7], a[2], a[5], a[8], a[3], a[6], a[9])
end
local function columns(right, up, back)
	return mat(right.X, up.X, back.X, right.Y, up.Y, back.Y, right.Z, up.Z, back.Z)
end
local function rx(a)
	local c, s = math.cos(a), math.sin(a)
	return mat(1, 0, 0, 0, c, -s, 0, s, c)
end
local function ry(a)
	local c, s = math.cos(a), math.sin(a)
	return mat(c, 0, s, 0, 1, 0, -s, 0, c)
end
local function rz(a)
	local c, s = math.cos(a), math.sin(a)
	return mat(c, -s, 0, s, c, 0, 0, 0, 1)
end
local function isCF(v)
	return rtypeof(v) == "CFrame"
end
CFMT.__mul = function(a, b)
	assert(isCF(a), "CFrame * expects a CFrame on the left")
	if isCF(b) then
		return CF(a.p + mvec(a.r, b.p), mmul(a.r, b.r))
	elseif isV(b) then
		return a.p + mvec(a.r, b)
	end
	error("invalid argument to CFrame *: " .. rtypeof(b), 2)
end
CFMT.__add = function(a, b)
	assert(isCF(a) and isV(b), "CFrame + expects a Vector3")
	return CF(a.p + b, a.r)
end
CFMT.__sub = function(a, b)
	assert(isCF(a) and isV(b), "CFrame - expects a Vector3")
	return CF(a.p - b, a.r)
end
CFMT.__eq = function(a, b)
	if a.p ~= b.p then
		return false
	end
	for i = 1, 9 do
		if a.r[i] ~= b.r[i] then
			return false
		end
	end
	return true
end
local function orthonormal(r)
	local right = V(r[1], r[4], r[7])
	local up = V(r[2], r[5], r[8])
	right = right.Unit
	local back = right:Cross(up).Unit
	up = back:Cross(right).Unit
	return columns(right, up, back)
end
local CFMETHODS = {
	Lerp = function(a, b, t)
		local r = {}
		for i = 1, 9 do
			r[i] = a.r[i] + (b.r[i] - a.r[i]) * t
		end
		return CF(a.p + (b.p - a.p) * t, orthonormal(r))
	end,
	Inverse = function(a)
		local rt = mtrans(a.r)
		return CF(-mvec(rt, a.p), rt)
	end,
	ToObjectSpace = function(a, b)
		local rt = mtrans(a.r)
		return CF(mvec(rt, b.p - a.p), mmul(rt, b.r))
	end,
	ToWorldSpace = function(a, b)
		return a * b
	end,
	PointToWorldSpace = function(a, v)
		return a.p + mvec(a.r, v)
	end,
	PointToObjectSpace = function(a, v)
		return mvec(mtrans(a.r), v - a.p)
	end,
	VectorToWorldSpace = function(a, v)
		return mvec(a.r, v)
	end,
	VectorToObjectSpace = function(a, v)
		return mvec(mtrans(a.r), v)
	end,
}
CFMT.__index = function(cf, k)
	local r = cf.r
	if k == "Position" then
		return cf.p
	elseif k == "LookVector" then
		return V(-r[3], -r[6], -r[9])
	elseif k == "RightVector" then
		return V(r[1], r[4], r[7])
	elseif k == "UpVector" then
		return V(r[2], r[5], r[8])
	elseif k == "Rotation" then
		return CF(V(0, 0, 0), r)
	elseif k == "X" then
		return cf.p.X
	elseif k == "Y" then
		return cf.p.Y
	elseif k == "Z" then
		return cf.p.Z
	end
	local f = CFMETHODS[k]
	if f then
		return f
	end
	error(tostring(k) .. " is not a valid member of CFrame", 2)
end
local CFrame = {}
function CFrame.new(a, b, c)
	if a == nil then
		return CF(V(0, 0, 0), IDENT)
	elseif type(a) == "number" then
		assert(type(b) == "number" and type(c) == "number", "CFrame.new(x, y, z) needs three numbers")
		return CF(V(a, b, c), IDENT)
	end
	assert(isV(a), "CFrame.new expects a Vector3")
	return CF(a, IDENT)
end
function CFrame.lookAt(at, target, up)
	assert(isV(at) and isV(target), "CFrame.lookAt expects Vector3s")
	up = up or V(0, 1, 0)
	local look = (target - at).Unit
	local right = look:Cross(up).Unit
	local up2 = right:Cross(look)
	return CF(at, columns(right, up2, -look))
end
function CFrame.Angles(a, b, c)
	return CF(V(0, 0, 0), mmul(mmul(rx(a), ry(b)), rz(c)))
end
function CFrame.fromEulerAnglesYXZ(a, b, c)
	return CF(V(0, 0, 0), mmul(mmul(ry(b), rx(a)), rz(c)))
end
function CFrame.fromMatrix(p, vx, vy, vz)
	assert(isV(p) and isV(vx) and isV(vy), "CFrame.fromMatrix expects Vector3s")
	vz = vz or vx:Cross(vy).Unit
	return CF(p, columns(vx, vy, vz))
end
CFrame.identity = CF(V(0, 0, 0), IDENT)
M.CFrame = CFrame

------------------------------------------------------------------ other datatypes (strict like Roblox)
local function dt(name, fields)
	return tag(fields, name)
end
local function num(v, what)
	if type(v) ~= "number" then
		error(what .. ": number expected, got " .. rtypeof(v), 3)
	end
	return v
end
M.Color3 = {
	new = function(r, g, b)
		return dt("Color3", { R = r or 0, G = g or 0, B = b or 0 })
	end,
	fromRGB = function(r, g, b)
		return dt("Color3", { R = (r or 0) / 255, G = (g or 0) / 255, B = (b or 0) / 255 })
	end,
	fromHex = function(h)
		local s = string.match(h, "^#?(%x%x%x%x%x%x)$")
		if not s then
			error("Unable to convert characters to hex value", 2)
		end
		return dt("Color3", { R = tonumber(string.sub(s, 1, 2), 16) / 255, G = tonumber(string.sub(s, 3, 4), 16) / 255,
			B = tonumber(string.sub(s, 5, 6), 16) / 255 })
	end,
}
M.NumberRange = { new = function(a, b)
	num(a, "NumberRange.new")
	b = b or a
	num(b, "NumberRange.new")
	if a > b then
		error("NumberRange: invalid range", 2)
	end
	return dt("NumberRange", { Min = a, Max = b })
end }
M.NumberSequenceKeypoint = { new = function(t, v, e)
	num(t, "NumberSequenceKeypoint.new")
	num(v, "NumberSequenceKeypoint.new")
	return dt("NumberSequenceKeypoint", { Time = t, Value = v, Envelope = e or 0 })
end }
M.ColorSequenceKeypoint = { new = function(t, c)
	num(t, "ColorSequenceKeypoint.new")
	if rtypeof(c) ~= "Color3" then
		error("ColorSequenceKeypoint.new: Color3 expected, got " .. rtypeof(c), 2)
	end
	return dt("ColorSequenceKeypoint", { Time = t, Value = c })
end }
local function checkKeypoints(kps, kind, what)
	if type(kps) ~= "table" or #kps < 2 then
		error(what .. ": requires at least 2 keypoints", 3)
	elseif #kps > 20 then
		error(what .. ": table is too long.", 3)
	end
	for i, k in kps do
		if rtypeof(k) ~= kind then
			error(what .. ": keypoint " .. i .. " is not a " .. kind, 3)
		end
		if i > 1 and k.Time < kps[i - 1].Time then
			error(what .. ": all keypoints must be ordered by time", 3)
		end
	end
	if math.abs(kps[1].Time) > 1e-4 then
		error(what .. ": first keypoint time must be 0", 3)
	elseif math.abs(kps[#kps].Time - 1) > 1e-4 then
		error(what .. ": last keypoint time must be 1", 3)
	end
end
M.NumberSequence = { new = function(a, b)
	if type(a) == "number" then
		b = b or a
		num(b, "NumberSequence.new")
		return dt("NumberSequence", { Keypoints = { M.NumberSequenceKeypoint.new(0, a), M.NumberSequenceKeypoint.new(1, b) } })
	end
	checkKeypoints(a, "NumberSequenceKeypoint", "NumberSequence.new")
	return dt("NumberSequence", { Keypoints = table.clone(a) })
end }
M.ColorSequence = { new = function(a, b)
	if rtypeof(a) == "Color3" then
		b = b or a
		return dt("ColorSequence", { Keypoints = { M.ColorSequenceKeypoint.new(0, a), M.ColorSequenceKeypoint.new(1, b) } })
	end
	checkKeypoints(a, "ColorSequenceKeypoint", "ColorSequence.new")
	return dt("ColorSequence", { Keypoints = table.clone(a) })
end }
M.UDim2 = {
	new = function(xs, xo, ys, yo)
		return dt("UDim2", { X = { Scale = xs or 0, Offset = xo or 0 }, Y = { Scale = ys or 0, Offset = yo or 0 } })
	end,
	fromScale = function(x, y)
		num(x, "UDim2.fromScale")
		num(y, "UDim2.fromScale")
		return dt("UDim2", { X = { Scale = x, Offset = 0 }, Y = { Scale = y, Offset = 0 } })
	end,
	fromOffset = function(x, y)
		return dt("UDim2", { X = { Scale = 0, Offset = x or 0 }, Y = { Scale = 0, Offset = y or 0 } })
	end,
}

------------------------------------------------------------------ Enum
local ENUMS = {
	CameraType = { "Fixed", "Attach", "Watch", "Track", "Follow", "Custom", "Scriptable", "Orbital" },
	RenderPriority = { First = 0, Input = 100, Camera = 200, Character = 300, Last = 2000 },
	MouseBehavior = { "Default", "LockCenter", "LockCurrentPosition" },
	UserInputType = { "MouseButton1", "MouseButton2", "MouseButton3", "MouseWheel", "MouseMovement", "Touch", "Keyboard",
		"Gamepad1", "Focus" },
	KeyCode = { "Unknown", "Space", "Return", "Escape", "Q", "E", "ButtonA", "ButtonB", "ButtonStart", "ButtonR3",
		"Thumbstick1", "Thumbstick2" },
	EasingStyle = { "Linear", "Sine", "Back", "Quad", "Quart", "Quint", "Bounce", "Elastic", "Exponential", "Circular",
		"Cubic" },
	EasingDirection = { "In", "Out", "InOut" },
	RaycastFilterType = { "Exclude", "Include" },
	NormalId = { "Right", "Top", "Back", "Left", "Bottom", "Front" },
	ParticleOrientation = { "FacingCamera", "FacingCameraWorldUp", "VelocityParallel", "VelocityPerpendicular" },
	ParticleFlipbookLayout = { "None", "Grid2x2", "Grid4x4", "Grid8x8" },
	ParticleFlipbookMode = { "Loop", "OneShot", "PingPong", "Random" },
	ParticleEmitterShape = { "Box", "Sphere", "Cylinder", "Disc" },
	ParticleEmitterShapeStyle = { "Volume", "Surface" },
	ParticleEmitterShapeInOut = { "Outward", "Inward", "InAndOut" },
	TextureMode = { "Stretch", "Wrap", "Static" },
	Material = { "Plastic", "SmoothPlastic", "Neon", "ForceField", "Glass", "Metal" },
	MeshType = { "Head", "Torso", "Wedge", "Sphere", "Cylinder", "FileMesh", "Brick", "Prism" },
	SurfaceType = { "Smooth", "Studs", "Inlet" },
	ZIndexBehavior = { "Global", "Sibling" },
	ScreenInsets = { "None", "DeviceSafeInsets", "CoreUISafeInsets", "TopbarSafeInsets" },
	ScaleType = { "Stretch", "Slice", "Tile", "Fit", "Crop" },
	MessageType = { "MessageOutput", "MessageInfo", "MessageWarning", "MessageError" },
}
local Enum = {}
for enumName, items in ENUMS do
	local e = {}
	local i = 0
	for key, value in items do
		local name, v
		if type(key) == "number" then
			name, v = value, i
			i += 1
		else
			name, v = key, value
		end
		e[name] = tag({ Name = name, Value = v, EnumType = enumName }, "EnumItem")
	end
	Enum[enumName] = setmetatable(e, { __index = function(_, k)
		error(tostring(k) .. " is not a valid member of \"Enum." .. enumName .. "\"", 2)
	end })
end
setmetatable(Enum, { __index = function(_, k)
	error(tostring(k) .. " is not a valid member of Enum", 2)
end })
M.Enum = Enum

M.TweenInfo = { new = function(time, style, direction, repeatCount, reverses, delayTime)
	num(time or 1, "TweenInfo.new")
	if style ~= nil and (rtypeof(style) ~= "EnumItem" or style.EnumType ~= "EasingStyle") then
		error("TweenInfo.new: EasingStyle expected", 2)
	end
	if direction ~= nil and (rtypeof(direction) ~= "EnumItem" or direction.EnumType ~= "EasingDirection") then
		error("TweenInfo.new: EasingDirection expected", 2)
	end
	return dt("TweenInfo", { Time = time or 1, EasingStyle = style, EasingDirection = direction })
end }

------------------------------------------------------------------ signals and the scheduler
local function signal()
	local s = { handlers = {} }
	function s:Connect(fn)
		local c = { Connected = true }
		table.insert(self.handlers, c)
		c.fn = fn
		function c:Disconnect()
			c.Connected = false
		end
		return c
	end
	function s:Once(fn)
		local c
		c = self:Connect(function(...)
			c:Disconnect()
			fn(...)
		end)
		return c
	end
	function s:Fire(...)
		for _, c in table.clone(self.handlers) do
			if c.Connected then
				c.fn(...)
			end
		end
	end
	return s
end
M.signal = signal

local queue = {}
local function schedule(at, fn, args)
	local job = { at = at, fn = fn, args = args, alive = true }
	table.insert(queue, job)
	return job
end
local function resume(fn, ...)
	local co = if type(fn) == "thread" then fn else coroutine.create(fn)
	local ok, err = coroutine.resume(co, ...)
	if not ok then
		table.insert(M.errors, "task: " .. tostring(err))
	end
end
M.task = {
	spawn = function(fn, ...)
		resume(fn, ...)
	end,
	defer = function(fn, ...)
		return schedule(M.clock, fn, { ... })
	end,
	delay = function(t, fn, ...)
		return schedule(M.clock + (t or 0), fn, { ... })
	end,
	cancel = function(job)
		if type(job) == "table" then
			job.alive = false
		else
			error("cannot cancel", 2)
		end
	end,
	wait = function()
		error("task.wait is not available in the mock", 2)
	end,
}
local function runDue()
	local again = true
	while again do
		again = false
		table.sort(queue, function(a, b)
			return a.at < b.at
		end)
		for i, job in queue do
			if job.at <= M.clock + 1e-9 then
				table.remove(queue, i)
				if job.alive then
					resume(job.fn, table.unpack(job.args))
				end
				again = true
				break
			end
		end
	end
end

------------------------------------------------------------------ instances
local CLASS_PARENT = { BasePart = "PVInstance", Part = "BasePart", Model = "PVInstance", PVInstance = "Instance",
	Workspace = "Model", Folder = "Instance", Attachment = "Instance", ParticleEmitter = "Instance", Beam = "Instance",
	Trail = "Instance", Light = "Instance", PointLight = "Light", SpotLight = "Light", SpecialMesh = "Instance",
	Decal = "Instance", LayerCollector = "Instance", ScreenGui = "LayerCollector", GuiObject = "Instance",
	Frame = "GuiObject", ImageLabel = "GuiObject", UIGradient = "Instance", Humanoid = "Instance", Animator = "Instance",
	AnimationController = "Instance", AnimationTrack = "Instance", Camera = "Instance", PlayerGui = "Instance",
	PlayerScripts = "Instance", Player = "Instance", ModuleScript = "Instance", Players = "Instance",
	ReplicatedStorage = "Instance", Instance = nil }
local C3T, NR, NS, CS, V3T, V2T, U2, CFT, BOOL, NUM, STR, INST = "Color3", "NumberRange", "NumberSequence",
	"ColorSequence", "Vector3", "Vector2", "UDim2", "CFrame", "boolean", "number", "string", "Instance"
local function E(name)
	return "Enum:" .. name
end
local PROPS = {
	Instance = { Name = STR, Parent = INST, ClassName = STR },
	BasePart = { Anchored = BOOL, CanCollide = BOOL, CanQuery = BOOL, CanTouch = BOOL, CastShadow = BOOL, Massless = BOOL,
		Transparency = NUM, Size = V3T, CFrame = CFT, Position = V3T, Color = C3T, Material = E("Material"),
		TopSurface = E("SurfaceType"), BottomSurface = E("SurfaceType"), Locked = BOOL, AssemblyLinearVelocity = V3T,
		LocalTransparencyModifier = NUM },
	Model = { PrimaryPart = INST },
	Attachment = { CFrame = CFT, WorldCFrame = CFT, Position = V3T, WorldPosition = V3T },
	ParticleEmitter = { Enabled = BOOL, Rate = NUM, Lifetime = NR, Speed = NR, SpreadAngle = V2T, Size = NS,
		Transparency = NS, Color = CS, Squash = NS, LightEmission = NUM, LightInfluence = NUM, Brightness = NUM, Drag = NUM,
		Acceleration = V3T, Rotation = NR, RotSpeed = NR, Orientation = E("ParticleOrientation"), ZOffset = NUM,
		EmissionDirection = E("NormalId"), LockedToPart = BOOL, FlipbookLayout = E("ParticleFlipbookLayout"),
		FlipbookMode = E("ParticleFlipbookMode"), FlipbookFramerate = NR, FlipbookStartRandom = BOOL, Texture = STR,
		Shape = E("ParticleEmitterShape"), ShapeStyle = E("ParticleEmitterShapeStyle"),
		ShapeInOut = E("ParticleEmitterShapeInOut"), ShapePartial = NUM, TimeScale = NUM },
	Beam = { Attachment0 = INST, Attachment1 = INST, Width0 = NUM, Width1 = NUM, Color = CS, Transparency = NS,
		Texture = STR, TextureSpeed = NUM, TextureLength = NUM, TextureMode = E("TextureMode"), LightEmission = NUM,
		LightInfluence = NUM, Brightness = NUM, CurveSize0 = NUM, CurveSize1 = NUM, Segments = NUM, FaceCamera = BOOL,
		ZOffset = NUM, Enabled = BOOL },
	Trail = { Attachment0 = INST, Attachment1 = INST, Lifetime = NUM, Color = CS, Transparency = NS, WidthScale = NS,
		Texture = STR, TextureMode = E("TextureMode"), TextureLength = NUM, LightEmission = NUM, LightInfluence = NUM,
		Brightness = NUM, MinLength = NUM, MaxLength = NUM, FaceCamera = BOOL, Enabled = BOOL },
	Light = { Brightness = NUM, Range = NUM, Color = C3T, Shadows = BOOL, Enabled = BOOL },
	SpotLight = { Angle = NUM, Face = E("NormalId") },
	SpecialMesh = { MeshType = E("MeshType"), MeshId = STR, TextureId = STR, Scale = V3T, Offset = V3T },
	Decal = { Face = E("NormalId"), Texture = STR, Color3 = C3T, Transparency = NUM, ZIndex = NUM },
	ScreenGui = { ResetOnSpawn = BOOL, IgnoreGuiInset = BOOL, ZIndexBehavior = E("ZIndexBehavior"), DisplayOrder = NUM,
		ScreenInsets = E("ScreenInsets"), Enabled = BOOL },
	GuiObject = { BorderSizePixel = NUM, BackgroundColor3 = C3T, BackgroundTransparency = NUM, Size = U2, Position = U2,
		AnchorPoint = V2T, ZIndex = NUM, Visible = BOOL, AbsolutePosition = V2T, AbsoluteSize = V2T },
	ImageLabel = { Image = STR, ImageColor3 = C3T, ImageTransparency = NUM, ScaleType = E("ScaleType") },
	UIGradient = { Rotation = NUM, Transparency = NS, Color = CS },
	Humanoid = { RootPart = INST, MoveDirection = V3T },
	AnimationTrack = { Speed = NUM, IsPlaying = BOOL },
	Camera = { CFrame = CFT, Focus = CFT, FieldOfView = NUM, CameraType = E("CameraType"), CameraSubject = INST,
		ViewportSize = V2T },
	Player = { Character = INST },
}
local DEFAULTS = {
	BasePart = { Anchored = false, CanCollide = true, CanQuery = true, CanTouch = true, CastShadow = true, Massless = false,
		Transparency = 0, Size = V(4, 1, 2), CFrame = CFrame.identity, Material = Enum.Material.Plastic,
		Color = M.Color3.new(0.6, 0.6, 0.6), AssemblyLinearVelocity = V(0, 0, 0), LocalTransparencyModifier = 0, Locked = false },
	Attachment = { CFrame = CFrame.identity },
	ParticleEmitter = { Enabled = true, Rate = 20, Lifetime = M.NumberRange.new(5, 10), Speed = M.NumberRange.new(5),
		TimeScale = 1, LockedToPart = false },
	Beam = { Width0 = 1, Width1 = 1, Enabled = true, CurveSize0 = 0, CurveSize1 = 0, Segments = 10, FaceCamera = false },
	Trail = { Lifetime = 2, Enabled = true },
	Light = { Brightness = 1, Range = 8, Color = M.Color3.new(1, 1, 1), Shadows = false, Enabled = true },
	SpecialMesh = { Scale = V(1, 1, 1), MeshType = Enum.MeshType.Head },
	Decal = { Transparency = 0 },
	ScreenGui = { Enabled = true, DisplayOrder = 0 },
	GuiObject = { BackgroundTransparency = 0, Visible = true, Size = M.UDim2.new(), Position = M.UDim2.new(),
		AbsolutePosition = V2(0, 0), AbsoluteSize = V2(0, 0) },
	ImageLabel = { ImageTransparency = 0 },
	AnimationTrack = { Speed = 1, IsPlaying = true },
	Camera = { FieldOfView = 70, CameraType = Enum.CameraType.Custom, ViewportSize = V2(1920, 1080),
		CFrame = CFrame.new(0, 10, 20), Focus = CFrame.identity },
}
local function classChain(class)
	local chain = {}
	local c = class
	while c do
		table.insert(chain, c)
		c = CLASS_PARENT[c]
	end
	if chain[#chain] ~= "Instance" then
		table.insert(chain, "Instance")
	end
	return chain
end
local function propType(class, prop)
	for _, c in classChain(class) do
		local p = PROPS[c]
		if p and p[prop] then
			return p[prop]
		end
	end
	return nil
end
local function typeOk(expected, v)
	if expected == INST then
		return v == nil or rtypeof(v) == "Instance"
	elseif string.sub(expected, 1, 5) == "Enum:" then
		return rtypeof(v) == "EnumItem" and v.EnumType == string.sub(expected, 6)
	end
	return rtypeof(v) == expected
end

local IMT = {}
local METHODS = {}
local EVENTS = { AncestryChanged = true, Destroying = true, ChildAdded = true, ChildRemoved = true }
M.instances = {}
local function newInstance(class, name)
	if not CLASS_PARENT[class] and class ~= "Instance" then
		error("Unable to create an Instance of type \"" .. tostring(class) .. "\"", 3)
	end
	local inst = setmetatable({ __class = class, __props = { Name = name or class }, __children = {}, __attrs = {},
		__signals = {}, __destroyed = false, __childList = {} }, IMT)
	TYPE[inst] = "Instance"
	for _, c in classChain(class) do
		local d = DEFAULTS[c]
		if d then
			for k, v in d do
				if inst.__props[k] == nil then
					inst.__props[k] = v
				end
			end
		end
	end
	table.insert(M.instances, inst)
	return inst
end
M.new = newInstance
IMT.__index = function(inst, k)
	if type(k) == "string" and string.sub(k, 1, 2) == "__" then
		return nil -- an internal field that is not set
	end
	if k == "ClassName" then
		return inst.__class
	elseif k == "Parent" then
		return inst.__parent
	end
	local props = rawget(inst, "__props")
	local v = props[k]
	if v ~= nil then
		return v
	end
	if inst.__class == "Attachment" and (k == "WorldCFrame" or k == "WorldPosition" or k == "Position") then
		local parentCF = inst.__parent and inst.__parent.__props.CFrame or CFrame.identity
		local world = parentCF * props.CFrame
		return if k == "WorldCFrame" then world elseif k == "WorldPosition" then world.Position else props.CFrame.Position
	end
	if (k == "Position") and props.CFrame then
		return props.CFrame.Position
	end
	local m = METHODS[k]
	if m then
		return m
	end
	local child = inst.__children[k]
	if child then
		return child
	end
	for _, c in inst.__childList or {} do
		if c.__props.Name == k then
			return c
		end
	end
	if propType(inst.__class, k) then
		return nil
	end
	if EVENTS[k] then
		local signals = rawget(inst, "__signals")
		signals[k] = signals[k] or M.signal()
		return signals[k]
	end
	error(tostring(k) .. " is not a valid member of " .. inst.__class .. " \"" .. tostring(props.Name) .. "\"", 2)
end
local function fireAncestry(inst)
	local s = rawget(inst, "__signals").AncestryChanged
	if s then
		s:Fire()
	end
	for _, c in rawget(inst, "__childList") do
		fireAncestry(c)
	end
end
local function setParent(inst, parent)
	if inst.__destroyed then
		error("The Parent property of " .. tostring(inst.__props.Name) .. " is locked", 3)
	end
	local old = inst.__parent
	if old then
		for i, c in old.__childList do
			if c == inst then
				table.remove(old.__childList, i)
				break
			end
		end
	end
	inst.__parent = parent
	if parent then
		parent.__childList = parent.__childList or {}
		table.insert(parent.__childList, inst)
	end
	fireAncestry(inst)
end
IMT.__newindex = function(inst, k, v)
	if type(k) == "string" and string.sub(k, 1, 2) == "__" then
		rawset(inst, k, v)
		return
	end
	if k == "Parent" then
		if v ~= nil and rtypeof(v) ~= "Instance" then
			error("Unable to assign property Parent. Instance expected, got " .. rtypeof(v), 2)
		end
		setParent(inst, v)
		return
	end
	local expected = propType(inst.__class, k)
	if not expected then
		error(tostring(k) .. " is not a valid member of " .. inst.__class, 2)
	end
	if not typeOk(expected, v) then
		error("Unable to assign property " .. k .. ". " .. expected .. " expected, got " .. rtypeof(v), 2)
	end
	if inst.__class == "Attachment" and k == "WorldCFrame" then
		local parentCF = inst.__parent and inst.__parent.__props.CFrame or CFrame.identity
		inst.__props.CFrame = parentCF:ToObjectSpace(v)
		return
	elseif inst.__class == "Attachment" and k == "Position" then
		inst.__props.CFrame = CFrame.new(v) * inst.__props.CFrame.Rotation
		return
	elseif k == "Position" and inst.__props.CFrame then
		inst.__props.CFrame = CFrame.new(v) * inst.__props.CFrame.Rotation
		return
	end
	if k == "TimeScale" and (v < 0 or v > 1) then
		error("TimeScale must be between 0 and 1", 2)
	end
	local old = inst.__props[k]
	inst.__props[k] = v
	if old ~= v then
		local s = inst.__signals[k]
		if s then
			s:Fire()
		end
	end
end
IMT.__tostring = function(inst)
	return tostring(inst.__props.Name)
end
function METHODS.IsA(inst, class)
	for _, c in classChain(inst.__class) do
		if c == class then
			return true
		end
	end
	return false
end
function METHODS.GetChildren(inst)
	return table.clone(inst.__childList or {})
end
function METHODS.GetDescendants(inst)
	local out = {}
	local function walk(x)
		for _, c in x.__childList or {} do
			table.insert(out, c)
			walk(c)
		end
	end
	walk(inst)
	return out
end
function METHODS.FindFirstChild(inst, name)
	for _, c in inst.__childList or {} do
		if c.__props.Name == name then
			return c
		end
	end
	return nil
end
METHODS.WaitForChild = METHODS.FindFirstChild
function METHODS.FindFirstChildOfClass(inst, class)
	for _, c in inst.__childList or {} do
		if c.__class == class then
			return c
		end
	end
	return nil
end
function METHODS.FindFirstChildWhichIsA(inst, class, recursive)
	for _, c in (if recursive then METHODS.GetDescendants(inst) else inst.__childList or {}) do
		if METHODS.IsA(c, class) then
			return c
		end
	end
	return nil
end
function METHODS.FindFirstAncestorOfClass(inst, class)
	local p = inst.__parent
	while p do
		if p.__class == class then
			return p
		end
		p = p.__parent
	end
	return nil
end
function METHODS.Destroy(inst)
	if inst.__destroyed then
		return
	end
	for _, c in METHODS.GetChildren(inst) do
		METHODS.Destroy(c)
	end
	setParent(inst, nil)
	inst.__destroyed = true
end
function METHODS.SetAttribute(inst, k, v)
	inst.__attrs[k] = v
end
function METHODS.GetAttribute(inst, k)
	return inst.__attrs[k]
end
function METHODS.GetPropertyChangedSignal(inst, k)
	inst.__signals[k] = inst.__signals[k] or signal()
	return inst.__signals[k]
end
function METHODS.GetPivot(inst)
	local p = inst.__props.PrimaryPart
	return if p then p.__props.CFrame else CFrame.identity
end
function METHODS.Emit(inst, n)
	assert(inst.__class == "ParticleEmitter", "Emit is not a valid member")
	num(n, "Emit")
	inst.__emitted = (inst.__emitted or 0) + n
end
function METHODS.Clear(inst)
	inst.__cleared = true
end
function METHODS.AdjustSpeed(inst, s)
	num(s, "AdjustSpeed")
	inst.__props.Speed = s
end
function METHODS.GetPlayingAnimationTracks(inst)
	return table.clone(inst.__tracks or {})
end
function METHODS.GetControls()
	return nil
end
local function descendantOf(inst, root)
	local p = inst
	while p do
		if p == root then
			return true
		end
		p = p.__parent
	end
	return false
end
M.descendantOf = descendantOf
function METHODS.IsDescendantOf(inst, ancestor)
	return inst ~= ancestor and descendantOf(inst, ancestor)
end
M.Instance = { new = function(class, parent)
	local inst = newInstance(class)
	if parent then
		inst.Parent = parent
	end
	return inst
end }

------------------------------------------------------------------ services and the world
local RunService = newInstance("Instance", "RunService")
local bound = {}
RunService.__props.Heartbeat = signal()
function METHODS.BindToRenderStep(_, name, priority, fn)
	num(priority, "BindToRenderStep")
	for i, b in bound do
		if b.name == name then
			table.remove(bound, i)
			break
		end
	end
	table.insert(bound, { name = name, priority = priority, fn = fn })
	table.sort(bound, function(a, b)
		return a.priority < b.priority
	end)
end
function METHODS.UnbindFromRenderStep(_, name)
	for i, b in bound do
		if b.name == name then
			table.remove(bound, i)
			return
		end
	end
end
function METHODS.IsClient()
	return true
end
function METHODS.IsServer()
	return false
end
function METHODS.IsStudio()
	return false
end
M.bound = function(name)
	for _, b in bound do
		if b.name == name then
			return true
		end
	end
	return false
end

local UIS = newInstance("Instance", "UserInputService")
UIS.__props.InputBegan = signal()
UIS.__props.InputChanged = signal()
UIS.__props.InputEnded = signal()
UIS.__props.MouseBehavior = Enum.MouseBehavior.Default
PROPS.Instance.MouseBehavior = E("MouseBehavior")

local TweenService = newInstance("Instance", "TweenService")
local TWEENABLE = { number = true, Vector3 = true, CFrame = true, Color3 = true, UDim2 = true, Vector2 = true }
M.tweens = 0
function METHODS.Create(_, inst, info, goals)
	if rtypeof(inst) ~= "Instance" then
		error("TweenService:Create: Instance expected", 2)
	end
	if rtypeof(info) ~= "TweenInfo" then
		error("TweenService:Create: TweenInfo expected", 2)
	end
	for k, v in goals do
		local expected = propType(inst.__class, k)
		if not expected then
			error("TweenService:Create no property named '" .. tostring(k) .. "' for object '" .. inst.__class .. "'", 2)
		end
		if not TWEENABLE[rtypeof(v)] or not typeOk(expected, v) then
			error("TweenService:Create property " .. k .. " cannot be tweened to a " .. rtypeof(v), 2)
		end
	end
	M.tweens += 1
	local tw = { Completed = signal(), cancelled = false }
	function tw:Play()
		local job = M.task.delay(info.Time, function()
			if tw.cancelled or inst.__destroyed then
				return
			end
			for k, v in goals do
				inst[k] = v
			end
			tw.Completed:Fire(Enum.EasingStyle.Linear)
		end)
		tw.job = job
	end
	function tw:Cancel()
		tw.cancelled = true
	end
	return tw
end

local Players = newInstance("Players", "Players")
local player = newInstance("Player", "Player1")
player.Parent = Players
local playerGui = newInstance("PlayerGui", "PlayerGui")
playerGui.Parent = player
local playerScripts = newInstance("PlayerScripts", "PlayerScripts")
playerScripts.Parent = player
Players.__props.LocalPlayer = player
PROPS.Players = { LocalPlayer = INST }

local Workspace = newInstance("Workspace", "Workspace")
local camera = newInstance("Camera", "Camera")
camera.Parent = Workspace
Workspace.__props.CurrentCamera = camera
PROPS.Workspace = { CurrentCamera = INST }
M.rayHits = nil -- a fake RaycastResult every cast hits (when it is within the cast's length)
M.casts = 0
function METHODS.Raycast(_, origin, direction)
	M.casts += 1
	local hit = M.rayHits
	return if hit and hit.Distance <= direction.Magnitude then hit else nil
end
function METHODS.Spherecast(_, origin, radius, direction)
	M.casts += 1
	local hit = M.rayHits
	return if hit and hit.Distance <= direction.Magnitude then hit else nil
end

local ReplicatedStorage = newInstance("ReplicatedStorage", "ReplicatedStorage")
local services = { RunService = RunService, UserInputService = UIS, TweenService = TweenService, Players = Players,
	ReplicatedStorage = ReplicatedStorage, Workspace = Workspace }
local game = newInstance("Instance", "game")
for _, service in services do
	service.Parent = game
end
function METHODS.GetService(_, name)
	local s = services[name]
	if not s then
		s = newInstance("Instance", name)
		services[name] = s
	end
	return s
end
M.game, M.workspace, M.camera, M.player, M.playerGui = game, Workspace, camera, player, playerGui
M.UIS, M.ReplicatedStorage = UIS, ReplicatedStorage

-- a character: Model > Humanoid (> Animator), HumanoidRootPart
function M.character(pos)
	local model = newInstance("Model", "Character")
	local root = newInstance("Part", "HumanoidRootPart")
	root.CFrame = CFrame.new(pos or V(0, 3, 0))
	root.Parent = model
	local hum = newInstance("Humanoid", "Humanoid")
	hum.RootPart = root
	hum.Parent = model
	local animator = newInstance("Animator", "Animator")
	animator.Parent = hum
	animator.__tracks = { newInstance("AnimationTrack", "Run"), newInstance("AnimationTrack", "Swing") }
	model.PrimaryPart = root
	model.Parent = Workspace
	player.Character = model
	return model, root, animator
end

-- the default Roblox camera: rewrites the CFrame every frame at RenderPriority.Camera while it is Custom, reading
-- the current look direction back (like the real one), at a fixed distance behind a focus point
M.defaultFocus = V(0, 5, 0)
local function defaultCamera()
	if camera.__props.CameraType == Enum.CameraType.Custom then
		local look = camera.__props.CFrame.LookVector
		camera.CFrame = CFrame.lookAt(M.defaultFocus - look * 12, M.defaultFocus)
	end
end
METHODS.BindToRenderStep(nil, "DefaultCamera", Enum.RenderPriority.Camera.Value, defaultCamera)

function M.step(dt)
	M.clock += dt
	runDue()
	RunService.__props.Heartbeat:Fire(dt)
	for _, b in table.clone(bound) do
		local ok, err = pcall(b.fn, dt)
		if not ok then
			table.insert(M.errors, b.name .. ": " .. tostring(err))
		end
	end
end
function M.run(seconds, dt)
	dt = dt or 1 / 60
	local n = math.floor(seconds / dt + 0.5)
	for _ = 1, n do
		M.step(dt)
	end
end

------------------------------------------------------------------ loading kit modules
local kit = newInstance("Folder", "Kit")
kit.Parent = ReplicatedStorage
local shared = newInstance("Folder", "Shared")
shared.Parent = ReplicatedStorage
local loaded = {}
M.loaded = loaded
local function moduleScript(name, parent)
	local s = newInstance("ModuleScript", name)
	s.Parent = parent
	return s
end
function M.require(x)
	if rtypeof(x) ~= "Instance" then
		error("Attempted to call require with invalid argument(s).", 2)
	end
	local m = loaded[x]
	if m == nil then
		error("module " .. tostring(x.__props.Name) .. " is not loaded in the mock", 2)
	end
	return m
end
M.UserSettings = function()
	return { GetService = function()
		return { MouseSensitivity = 1, GetCameraYInvertValue = function()
			return if M.invertY then -1 else 1
		end }
	end }
end
M.RaycastParams = { new = function()
	return setmetatable({}, { __newindex = function(t, k, v)
		if k ~= "FilterType" and k ~= "FilterDescendantsInstances" and k ~= "IgnoreWater" and k ~= "RespectCanCollide"
			and k ~= "CollisionGroup" then
			error(tostring(k) .. " is not a valid member of RaycastParams", 2)
		end
		rawset(t, k, v)
	end })
end }

function M.env(scriptInstance)
	local env = {
		game = game, workspace = Workspace, script = scriptInstance, require = M.require, typeof = rtypeof,
		type = function(v)
			if TYPE[v] ~= nil then
				return "userdata" -- engine values are userdata in Roblox, never tables
			end
			return type(v)
		end,
		Vector3 = V3, Vector2 = M.Vector2, CFrame = CFrame, Color3 = M.Color3, NumberRange = M.NumberRange,
		NumberSequence = M.NumberSequence, NumberSequenceKeypoint = M.NumberSequenceKeypoint,
		ColorSequence = M.ColorSequence, ColorSequenceKeypoint = M.ColorSequenceKeypoint, UDim2 = M.UDim2,
		TweenInfo = M.TweenInfo, Enum = Enum, Instance = M.Instance, task = M.task, RaycastParams = M.RaycastParams,
		UserSettings = M.UserSettings,
		warn = function(...)
			local parts = {}
			for _, x in { ... } do
				table.insert(parts, tostring(x))
			end
			table.insert(M.warnings, table.concat(parts, " "))
		end,
		os = setmetatable({ clock = function()
			return M.clock
		end }, { __index = os }),
	}
	return setmetatable(env, { __index = _G })
end

function M.load(name, source, deps)
	local s = moduleScript(name, kit)
	local chunk, err = loadstring(source, "=ReplicatedStorage.Kit." .. name)
	assert(chunk, err)
	setfenv(chunk, M.env(s))
	local mod = chunk()
	loaded[s] = mod
	return mod
end
function M.provide(name, value, parent)
	local s = moduleScript(name, parent or kit)
	loaded[s] = value
	return s
end
M.shared = shared
M.kit = kit

return M
'''

CAMERA_SCENARIOS = r'''local Vector3, CFrame, Enum = M.Vector3, M.CFrame, M.Enum
local R = {}
local cam, player = M.camera, M.player
local FxMathKit = M.load("FxMath", SRC.FxMath)
local shakes = {}
M.provide("Shake", { reduceMotion = false, kick = function(x)
	table.insert(shakes, x)
end })
local events = {}
M.provide("Debug", { register = function() end, event = function(name)
	table.insert(events, name)
end })
local CameraRig = M.load("CameraRig", SRC.CameraRig)
local RunService = M.game:GetService("RunService")

local function pos(v)
	return { v.X, v.Y, v.Z }
end
local function state()
	local p = cam.CFrame.Position
	return { type = cam.CameraType.Name, fov = cam.FieldOfView, bound = M.bound("KitCameraRig"),
		cinematic = player:GetAttribute("KitCinematic") == true, timeScale = CameraRig.timeScale,
		finite = p.X == p.X and p.Y == p.Y and p.Z == p.Z and cam.FieldOfView == cam.FieldOfView }
end

-- 1. kicks and punches over the default camera: FOV comes back exactly, nothing drifts, the step unbinds
M.run(0.3)
local before = cam.CFrame
CameraRig.kick(10, 0.3)
CameraRig.punch(Vector3.new(1, 0, 0), 0.5)
local peakFov, peakOffset = 0, 0
for _ = 1, 30 do
	M.step(1 / 60)
	peakFov = math.max(peakFov, cam.FieldOfView)
	peakOffset = math.max(peakOffset, (cam.CFrame.Position - before.Position).Magnitude)
end
M.run(1.5)
R.idle = state()
R.idle.peakFov = peakFov
R.idle.peakOffset = peakOffset
R.idle.drift = (cam.CFrame.Position - before.Position).Magnitude
R.idle.turn = cam.CFrame.LookVector:Dot(before.LookVector)

-- 2. follow: the rig owns the camera, frames the subject at its distance, keeps up with it at speed
local model, root, animator = M.character(Vector3.new(0, 3, 0))
local velocity = Vector3.zero
RunService:BindToRenderStep("Physics", 50, function(dt)
	root.AssemblyLinearVelocity = velocity
	root.CFrame = root.CFrame + velocity * dt
end)
local rig = CameraRig.follow({ preset = "overTheTop", distance = 16, fov = 72, blend = 0, lookAhead = 0 })
M.run(1)
local focus = root.Position + Vector3.new(0, 2, 0)
R.follow = state()
R.follow.dist = (cam.CFrame.Position - focus).Magnitude
R.follow.aim = cam.CFrame.LookVector:Dot((focus - cam.CFrame.Position).Unit)
R.follow.pitch = math.deg(math.asin(cam.CFrame.LookVector.Y))
velocity = Vector3.new(16, 0, 0)
M.run(1.5)
focus = root.Position + Vector3.new(0, 2, 0)
R.follow.lag = (cam.Focus.Position - focus).Magnitude
R.follow.movingDist = (cam.CFrame.Position - focus).Magnitude
velocity = Vector3.zero
rig:set({ distance = 24, fov = 60 })
M.run(2)
focus = root.Position + Vector3.new(0, 2, 0)
R.follow.setDist = (cam.CFrame.Position - focus).Magnitude
R.follow.setFov = cam.FieldOfView
R.follow.state = rig:state().active

-- 3. a shot while following: letterbox, its own FOV, back to the follow after the blend
local done = {}
local shot = CameraRig.shot({ from = CFrame.new(0, 20, 30), to = CFrame.new(10, 20, 30), duration = 0.5, hold = 0.2,
	blendOut = 0.3, fov = 50, letterbox = true, onDone = function(status)
		table.insert(done, status)
	end })
M.run(0.6)
local bars = M.playerGui:FindFirstChild("KitLetterbox")
R.shot = state()
R.shot.barsSize = bars and bars:FindFirstChild("Top").Size.Y.Scale or -1
R.shot.status = shot.status
M.run(1.2)
R.shot.after = state()
R.shot.afterStatus = shot.status
R.shot.done = done
R.shot.afterBars = bars and bars:FindFirstChild("Top").Size.Y.Scale or -1

-- 4. stop: camera type and FOV go back to what they were, the step unbinds
rig:stop()
M.run(0.2)
R.stopped = state()

-- 5. a shot without a follow and without a blend back: nothing is left changed
local cut = CameraRig.shot({ from = CFrame.new(5, 5, 5), to = CFrame.new(6, 5, 5), duration = 0.3, fov = 40, blendOut = 0 })
M.run(0.1)
R.cut = { during = state() }
M.run(0.5)
R.cut.after = state()
R.cut.status = cut.status

-- 6. a three-shot sequence (frames, path, orbit) with letterbox, slow motion, locked controls; skipped mid-way
local thens = {}
local seq = CameraRig.sequence({
	{ relativeTo = root, from = CFrame.lookAt(Vector3.new(4, 1, -7), Vector3.new(0, 2, 0)),
		to = CFrame.lookAt(Vector3.new(3, 1.2, -5), Vector3.new(0, 2.2, 0)), duration = 0.5, fov = { 55, 50 },
		roll = { -4, -2 } },
	{ path = { Vector3.new(0, 10, 20), Vector3.new(10, 12, 15), Vector3.new(20, 10, 0) }, lookAt = root, duration = 1,
		slowmo = { scale = 0.25, seconds = 0.8, rampIn = 0.05, rampOut = 0.3 }, handheld = 0.1, timeScaled = true },
	{ orbit = { target = root, radius = { 11, 9 }, height = { 3, 4 }, from = -30, to = 20 }, duration = 1, hold = 0.5,
		blendIn = 0.2, blendOut = 0.5 },
}, { letterbox = { ratio = 2.39, seconds = 0.2 }, skipInput = true, lockControls = true, name = "moment",
	onDone = function(status)
		table.insert(thens, "onDone:" .. status)
	end })
seq:andThen(function(status)
	table.insert(thens, "andThen:" .. status)
end)
M.run(0.8)
R.seq = { during = state(), status = seq.status }
seq:skip()
M.run(1.2)
R.seq.after = state()
R.seq.status2 = seq.status
R.seq.thens = thens
R.seq.bars = M.playerGui:FindFirstChild("KitLetterbox"):FindFirstChild("Top").Size.Y.Scale

-- 7. a sequence interrupted by another; awaiting the second
local first = CameraRig.shot({ from = CFrame.new(0, 5, 5), duration = 5 })
M.run(0.2)
local second = CameraRig.shot({ from = CFrame.new(1, 5, 5), to = CFrame.new(2, 5, 5), duration = 0.3, blendOut = 0.2 })
local awaited = nil
local co = coroutine.create(function()
	awaited = second:await()
end)
coroutine.resume(co)
M.run(1)
R.interrupt = { first = first.status, second = second.status, awaited = awaited, after = state() }

-- 8. slow motion: eases down, holds, returns; listeners and the player attribute follow it
local seen = {}
local conn = CameraRig.onTimeScale(function(ts)
	table.insert(seen, ts)
end)
CameraRig.slowmo(0.2, 1, { rampIn = 0.1, rampOut = 0.3 })
M.run(0.5)
R.slowmo = { mid = CameraRig.timeScale, attribute = player:GetAttribute("KitTimeScale") }
M.run(0.8)
R.slowmo.after = CameraRig.timeScale
R.slowmo.afterAttribute = player:GetAttribute("KitTimeScale")
R.slowmo.calls = #seen
local minSeen = 1
for _, ts in seen do
	minSeen = math.min(minSeen, ts)
end
R.slowmo.min = minSeen
conn:Disconnect()
CameraRig.shake(0.4)
R.shakes = shakes
M.run(0.5)
R.final = state()

-- 10. reduce motion: kicks and punches scale to CameraRig.reducedMotionScale (0)
local ShakeMock = M.require(M.kit:FindFirstChild("Shake"))
ShakeMock.reduceMotion = true
CameraRig.kick(10, 0.3)
CameraRig.punch(Vector3.new(0, 1, 0), 1)
local reducedPeak = 0
for _ = 1, 20 do
	M.step(1 / 60)
	reducedPeak = math.max(reducedPeak, math.abs(cam.FieldOfView - 70))
end
ShakeMock.reduceMotion = false
M.run(1)
R.reduced = { peak = reducedPeak, after = state() }

-- 11. collision: pulls in before geometry at once, eases back out when it clears
local orbitRig = CameraRig.follow({ preset = "overTheTop", distance = 16, blend = 0, orbit = "drag" })
M.run(0.5)
local function camDistance()
	return (cam.CFrame.Position - (root.Position + Vector3.new(0, 2, 0))).Magnitude
end
local free = camDistance()
M.rayHits = { Distance = 5, Position = Vector3.zero, Normal = Vector3.yAxis }
M.step(1 / 60)
local blocked = camDistance()
M.rayHits = nil
M.step(1 / 60)
local oneFrameLater = camDistance()
M.run(2)
R.collision = { free = free, blocked = blocked, oneFrameLater = oneFrameLater, returned = camDistance() }

-- 12. orbit input: right-drag turns the view right, dragging down looks down; locked orbit ignores the mouse
local function input(kind, delta, keyCode)
	return { UserInputType = Enum.UserInputType[kind], Delta = delta or Vector3.zero, Position = Vector3.zero,
		KeyCode = Enum.KeyCode[keyCode or "Unknown"] }
end
local before2 = cam.CFrame
M.UIS.InputBegan:Fire(input("MouseButton2"), false)
M.UIS.InputChanged:Fire(input("MouseMovement", Vector3.new(100, 0, 0)), false)
M.step(1 / 60)
local turned = cam.CFrame
M.UIS.InputChanged:Fire(input("MouseMovement", Vector3.new(0, 60, 0)), false)
M.step(1 / 60)
local dragging = M.UIS.MouseBehavior.Name
M.UIS.InputEnded:Fire(input("MouseButton2"), false)
M.step(1 / 60)
R.orbit = { right = before2.RightVector:Dot(turned.LookVector), lookDown = cam.CFrame.LookVector.Y - turned.LookVector.Y,
	mouseWhileDragging = dragging, mouseAfter = M.UIS.MouseBehavior.Name }
orbitRig:set({ preset = "topDown" })
M.run(2)
local lockedLook = cam.CFrame.LookVector
M.UIS.InputBegan:Fire(input("MouseButton2"), false)
M.UIS.InputChanged:Fire(input("MouseMovement", Vector3.new(300, 200, 0)), false)
M.step(1 / 60)
M.UIS.InputEnded:Fire(input("MouseButton2"), false)
R.orbit.lockedMoved = (cam.CFrame.LookVector - lockedLook).Magnitude
R.orbit.topDownPitch = math.deg(math.asin(cam.CFrame.LookVector.Y))
orbitRig:stop()
M.run(0.5)
R.orbit.after = state()

-- 13. a blend back to the default camera ends facing where the player looked before the shot
M.run(0.5)
local lookBefore = cam.CFrame.LookVector
local away = CameraRig.shot({ from = CFrame.lookAt(Vector3.new(30, 10, 0), Vector3.new(30, 10, 50)), duration = 0.3,
	blendOut = 0.5 })
M.run(1.5)
R.handBack = { facing = cam.CFrame.LookVector:Dot(lookBefore), status = away.status, after = state() }

-- 14. skipping a shot ends only its own slow motion; a gameplay beat keeps going
CameraRig.slowmo(0.5, 3, { rampIn = 0, rampOut = 0 })
local slowShot = CameraRig.shot({ from = CFrame.new(0, 5, 5), duration = 1, slowmo = 0.2, blendOut = 0 })
M.run(0.3)
local duringShot = CameraRig.timeScale
slowShot:skip()
M.run(0.5)
R.beats = { during = duringShot, afterSkip = CameraRig.timeScale }
M.run(3)
R.beats.later = CameraRig.timeScale

-- 15. a callback that starts the next shot when its own is interrupted is not lost
local chained = nil
local firstShot = CameraRig.shot({ from = CFrame.new(0, 5, 5), duration = 5 })
firstShot:andThen(function(status)
	if status == "interrupted" then
		chained = CameraRig.shot({ from = CFrame.new(3, 5, 5), duration = 0.2, blendOut = 0 })
	end
end)
M.run(0.1)
local interrupter = CameraRig.shot({ from = CFrame.new(1, 5, 5), duration = 0.2, blendOut = 0 })
M.run(1)
R.chain = { first = firstShot.status, interrupter = interrupter.status,
	chained = if chained then chained.status else "none", after = state() }

-- 16. the player's invert-Y setting flips the vertical drag
M.invertY = true
local inverted = CameraRig.follow({ preset = "overTheTop", distance = 16, blend = 0 })
M.run(1.2)
local lookY = cam.CFrame.LookVector.Y
M.UIS.InputBegan:Fire(input("MouseButton2"), false)
M.UIS.InputChanged:Fire(input("MouseMovement", Vector3.new(0, 60, 0)), false)
M.step(1 / 60)
M.UIS.InputEnded:Fire(input("MouseButton2"), false)
R.invert = { lookUp = cam.CFrame.LookVector.Y - lookY }
inverted:stop()
M.invertY = false
M.run(1.2)

-- 9. bad input everywhere: nothing throws, the render step keeps running cleanly
local bad = { 0, -1, 1e9, 0 / 0, "x", true, {}, { 1, 2 }, function() end, Vector3.new(1, 2, 3), CFrame.identity, cam }
local throws = {}
local function try(name, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		table.insert(throws, name .. ": " .. tostring(err))
	end
end
for _, a in bad do
	try("kick", CameraRig.kick, a, a)
	try("punch", CameraRig.punch, a, a)
	try("slowmo", CameraRig.slowmo, a, a, a)
	try("shake", CameraRig.shake, a)
	try("onTimeScale", CameraRig.onTimeScale, a)
	try("shot", CameraRig.shot, a)
	try("sequence", CameraRig.sequence, a, a)
	try("sequence2", CameraRig.sequence, { a, a }, { letterbox = a, skipInput = a, onDone = a, blendOut = a })
	try("follow", function()
		local r = CameraRig.follow(a)
		r:set(a)
		r:switchShoulder(a)
		r:setAngles(a, a, a)
		r:state()
		M.step(1 / 60)
		r:stop()
	end)
end
try("follow garbage", function()
	local r = CameraRig.follow({ distance = "far", fov = {}, offset = "x", orbit = 5, speedFov = 3,
		zoom = { min = "a", max = {} }, sensitivity = { mouse = "x" }, subject = 5, preset = "nope", ignore = "x",
		autoAlign = "soon", pitch = 400, pitchMin = 50, pitchMax = -50, shoulder = "left", blend = -1, colision = true })
	M.run(0.2)
	r:set({ preset = "topDown", yaw = "north", subject = model })
	M.run(0.2)
	r:set({ subject = function()
		return "nowhere"
	end })
	M.run(0.2)
	r:set({ subject = function()
		return Vector3.new(1, 2, 3)
	end, collision = true })
	M.run(0.2)
	r:stop()
end)
try("shot garbage", function()
	local h = CameraRig.shot({ from = 5, to = "x", duration = "long", ease = 5, fov = "wide", roll = {}, handheld = "yes",
		orbit = { target = 5, radius = "big" }, path = { 1, 2 }, lookAt = 7, relativeTo = "x", letterbox = 5,
		slowmo = "x", onStart = 5, hold = -3, blendIn = {}, bogus = 1 })
	M.run(0.5)
	h:skip()
	M.run(1)
	h:cancel()
	local h2 = CameraRig.sequence({ { path = { Vector3.new(0, 1, 0) } }, { orbit = {} }, { from = CFrame.identity,
		lookAt = { Vector3.new(0, 0, 0) } } }, { letterbox = true })
	M.run(0.5)
	h2:cancel()
	M.run(0.5)
end)
M.run(6)
R.fuzz = { throws = throws, errors = M.errors, after = state(), warnings = #M.warnings }
R.warningSample = {}
for i = 1, math.min(8, #M.warnings) do
	table.insert(R.warningSample, M.warnings[i])
end
R.events = events
print(json(R))
'''

VFX_SCENARIOS = r'''local Vector3, CFrame, Color3 = M.Vector3, M.CFrame, M.Color3
local R = {}
local FxMathKit = M.load("FxMath", SRC.FxMath)
M.FxKeys = function(kind)
	return FxMathKit.layerKeys(kind)
end
M.provide("Shake", { reduceMotion = false, kick = function() end })
local events = {}
M.provide("Debug", { register = function() end, event = function(name)
	table.insert(events, name)
end })
M.provide("Tokens", { color = { primary = Color3.fromRGB(255, 181, 71), highlight = Color3.new(1, 1, 0.9),
	shadow = Color3.new(0.1, 0.1, 0.15), reward = Color3.new(1, 0.85, 0.3), text = Color3.new(1, 1, 1),
	secondary = Color3.new(0.3, 0.8, 0.9) } }, M.shared)
local CameraRig = M.load("CameraRig", SRC.CameraRig)
local VFX = M.load("VFX", SRC.VFX)
local model, root, animator = M.character(Vector3.new(0, 3, 0))

local function count(class, under)
	local n = 0
	for _, inst in (under or M.workspace):GetDescendants() do
		if inst:IsA(class) then
			n += 1
		end
	end
	return n
end
local function failures()
	local out = {}
	for _, w in M.warnings do
		if string.find(w, "failed") then
			table.insert(out, w)
		end
	end
	return out
end

-- 1. a layered impact: every layer spawns, lights and parts appear, and everything is gone after its lifetime
VFX.preset("impact", {
	budget = { effects = 6, particles = 300, lights = 2 },
	layers = {
		{ kind = "flash", color = "Tokens.color.highlight", size = { 0.3, 1.6 }, transparency = { 0.2, 1 }, duration = 0.05 },
		{ kind = "flash", delay = 0.03, color = "Tokens.color.primary", size = { 1, 5 }, transparency = { 0, 1 },
			duration = 0.12, ease = "Quint Out", spin = 90 },
		{ kind = "light", delay = 0.03, color = "Tokens.color.primary", brightness = 5, range = 16, duration = 0.25 },
		{ kind = "ring", delay = 0.03, size = { 1, 9 }, thickness = 0.25, color = "#FFB547", transparency = { 0.2, 1 },
			duration = 0.3 },
		{ kind = "ring", delay = 0.03, size = { 1, 6 }, texture = "rbxassetid://123", duration = 0.3, flat = false },
		{ kind = "particles", delay = 0.03, count = 18, lifetime = { 0.15, 0.35 }, speed = { 35, 60 }, spread = 70,
			size = { { 0, 0.35 }, { 1, 0 } }, transparency = { { 0, 0 }, { 0.8, 0.2 }, { 1, 1 } },
			color = { "Tokens.color.highlight", "Tokens.color.primary" }, lightEmission = 1, drag = 6,
			acceleration = Vector3.new(0, -40, 0), orientation = "parallel", squash = { { 0, -1 }, { 1, 0 } },
			texture = "rbxassetid://456", flipbook = { layout = "4x4", mode = "oneshot", fps = { 20, 30 } } },
		{ kind = "particles", delay = 0.06, count = 6, lifetime = { 0.6, 1.1 }, speed = { 2, 5 }, spread = 180,
			size = { { 0, 1 }, { 1, 3.5 } }, transparency = { { 0, 0.45 }, { 1, 1 } }, color = "Tokens.color.shadow",
			rotation = { 0, 360 }, rotSpeed = { -40, 40 }, drag = 3, shape = { kind = "disc", size = Vector3.new(4, 0.2, 4),
			style = "surface", inOut = "outward" } },
		{ kind = "beam", to = Vector3.new(0, 0, -8), width = { 1, 0.2 }, curve = 2, color = "#FFFFFF",
			transparency = { 0, 1 }, duration = 0.2, fadeOut = 0.1, textureMode = "wrap" },
		{ kind = "decal", texture = "rbxassetid://789", size = { 2, 5 }, rotation = { 0, 360 }, duration = 0.8, fade = 0.3 },
	},
})
local reasons = {}
local h = VFX.play("impact", CFrame.new(10, 0, 0), { normal = Vector3.new(0, 0, 1), scale = 1.2, intensity = 0.8,
	onDone = function(reason)
		table.insert(reasons, reason)
	end })
M.run(0.1)
local folder = M.workspace:FindFirstChild("KitVFX")
R.impact = { alive = h.alive, emitters = count("ParticleEmitter", folder), lights = count("PointLight", folder),
	beams = count("Beam", folder), meshes = count("SpecialMesh", folder), decals = count("Decal", folder) }
local emitted = 0
for _, e in folder:GetDescendants() do
	if e:IsA("ParticleEmitter") then
		emitted += e.__emitted or 0
	end
end
R.impact.emitted = emitted
M.run(2)
R.impact.after = { alive = h.alive, reasons = reasons, emitters = count("ParticleEmitter"), lights = count("PointLight"),
	beams = count("Beam"), meshes = count("SpecialMesh"), decals = count("Decal"), visibleParts = 0 }
for _, p in folder:GetChildren() do
	if p:IsA("BasePart") and p.Transparency < 1 then
		R.impact.after.visibleParts += 1
	end
end

-- 2. the family budget drops the oldest effects
local handles, evicted = {}, 0
for i = 1, 10 do
	table.insert(handles, VFX.play("impact", Vector3.new(i, 0, 0)):andThen(function(reason)
		if reason == "evicted" then
			evicted += 1
		end
	end))
end
local alive = 0
for _, x in handles do
	if x.alive then
		alive += 1
	end
end
R.budget = { alive = alive, evicted = evicted, oldestAlive = handles[1].alive, newestAlive = handles[10].alive }
M.run(2)

-- 3. a continuous effect runs until stop(), then ends once its particles are gone; follow = true rides the part
local stream = VFX.effect({ family = "stream", layers = { { kind = "particles", rate = 30, lifetime = { 0.3, 0.5 },
	size = { 0.2, 0 }, texture = "rbxassetid://1" }, { kind = "light", duration = 0, brightness = 2, range = 8 } } },
	root, { follow = true })
M.run(3)
local attachParent = nil
for _, a in root:GetChildren() do
	if a:IsA("Attachment") then
		attachParent = a.Parent == root
	end
end
R.stream = { aliveAfter3s = stream.alive, onRoot = attachParent == true }
stream:stop()
M.run(0.2)
R.stream.aliveJustAfterStop = stream.alive
M.run(1)
R.stream.aliveLater = stream.alive
R.stream.leftOnRoot = count("ParticleEmitter", root) + count("PointLight", root)

-- 4. a family's budget caps its lights (3 by default); VFX.maxLights caps lights across all effects
for i = 1, 10 do
	VFX.flashLight(Vector3.new(0, i, 0), Color3.new(1, 0.5, 0), 3, 12, 1)
end
M.run(0.05)
R.familyLights = count("PointLight")
M.run(1.5)
VFX.budget("flashLight", { lights = 100, effects = 100 })
local lights = {}
for i = 1, 10 do
	table.insert(lights, VFX.flashLight(Vector3.new(0, i, 0), Color3.new(1, 0.5, 0), 3, 12, 1))
end
M.run(0.05)
R.lights = { live = count("PointLight"), cap = VFX.maxLights }
M.run(1.5)
R.lights.after = count("PointLight")

-- 5. hitstop pauses the character's animations (nested stops keep the original speed) and holds CameraRig time
local tracks = animator:GetPlayingAnimationTracks()
tracks[1]:AdjustSpeed(1.5)
VFX.hitstop(0.1)
M.run(0.05)
local during = { tracks[1].Speed, tracks[2].Speed, CameraRig.timeScale }
VFX.hitstop(0.1)
M.run(0.07)
local stillFrozen = tracks[1].Speed
M.run(0.2)
R.hitstop = { during = during, stillFrozen = stillFrozen, after = { tracks[1].Speed, tracks[2].Speed, CameraRig.timeScale } }

-- 6. effects slow down with CameraRig.slowmo unless timeScaled = false
local slowed = VFX.effect({ layers = { { kind = "particles", rate = 10, lifetime = 1, texture = "rbxassetid://1" } } },
	Vector3.zero)
local unscaled = VFX.effect({ layers = { { kind = "particles", rate = 10, lifetime = 1, texture = "rbxassetid://1" } } },
	Vector3.zero, { timeScaled = false })
CameraRig.slowmo(0.25, 1, { rampIn = 0, rampOut = 0.1 })
M.run(0.3)
R.slowmo = { slowed = slowed.emitters[1].TimeScale, unscaled = unscaled.emitters[1].TimeScale }
M.run(1.2)
R.slowmo.after = slowed.emitters[1].TimeScale
slowed:destroy()
unscaled:destroy()

-- 7. screen accents and trails
VFX.screenFlash(Color3.new(1, 1, 1), 0.2, 0.6)
local overlay = M.playerGui:FindFirstChild("KitVFXOverlay")
local flash = overlay and overlay:FindFirstChild("Flash")
R.screen = { flashDuring = flash and flash.BackgroundTransparency or -1 }
M.run(0.4)
R.screen.flashAfter = flash and flash.BackgroundTransparency or -1
local v = VFX.vignette(Color3.new(0, 0, 0), 0.5, { strength = 0.7 })
M.run(0.2)
R.screen.vignetteEdges = overlay:FindFirstChild("Vignette") and #overlay:FindFirstChild("Vignette"):GetChildren() or 0
M.run(1)
R.screen.vignetteGone = overlay:FindFirstChild("Vignette") == nil
local low = VFX.vignette("#FF0000", nil, { strength = 0.4 })
M.run(2)
R.screen.persistent = overlay:FindFirstChild("Vignette") ~= nil
low:stop(0.2)
M.run(0.5)
R.screen.stopped = overlay:FindFirstChild("Vignette") == nil
local trail = VFX.trail(root, { width = 2.5, lifetime = 0.22, color = { "#FFFFFF", "Tokens.color.primary" },
	transparency = { { 0, 0.2 }, { 1, 1 } }, widthScale = { { 0, 1 }, { 1, 0 } }, enabled = false })
R.trail = { onRoot = count("Trail", root), enabled = trail.trail.Enabled }
trail:burst(0.3)
M.run(0.1)
R.trail.during = trail.trail.Enabled
M.run(0.4)
R.trail.after = trail.trail.Enabled
trail:destroy()
R.trail.destroyed = count("Trail", root)

-- 9. particles slowed by slow motion are not cut off: the effect waits out the time they lost
local slowBurst = VFX.effect({ layers = { { kind = "particles", count = 5, lifetime = 0.8, texture = "rbxassetid://1" } } },
	Vector3.zero)
CameraRig.slowmo(0.25, 0.8, { rampIn = 0, rampOut = 0 })
M.run(0.95)
R.slowBurst = { aliveAt095 = slowBurst.alive }
M.run(1.5)
R.slowBurst.aliveLater = slowBurst.alive

-- 10. an effect riding a part ends when the part is destroyed
local carrier = M.Instance.new("Part")
carrier.Parent = M.workspace
local riding = VFX.effect({ layers = { { kind = "particles", rate = 20, lifetime = 0.3, texture = "rbxassetid://1" } } },
	carrier, { follow = true })
M.run(0.5)
local ridingBefore = riding.alive
carrier:Destroy()
M.run(1)
R.riding = { before = ridingBefore, after = riding.alive }

-- 11. named textures go through Kit.Textures without holding up the caller, even when a decode has to wait
local applied = {}
M.provide("Textures", { apply = function(inst, name)
	table.insert(applied, name)
	if name == "slow_tex" then
		coroutine.yield() -- a first decode that waits
	end
	return true
end })
local named = VFX.effect({ layers = { { kind = "particles", count = 3, texture = "spark_soft" },
	{ kind = "particles", count = 3, texture = "slow_tex" },
	{ kind = "flash", shape = "mesh", mesh = "rbxassetid://5", meshTexture = "mesh_skin" } } }, Vector3.zero)
R.textures = { returned = named.alive, applied = table.clone(applied) }
M.run(1)

-- 8. bad input everywhere: nothing throws; the runtime turns bad values into safe ones (no layer ever fails)
local bad = { 0, -1, 1e9, 0 / 0, "x", true, {}, { 1, 2 }, function() end, Vector3.new(1, 2, 3), CFrame.identity, root }
local throws = {}
local function try(name, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		table.insert(throws, name .. ": " .. tostring(err))
	end
end
for _, a in bad do
	try("effect", VFX.effect, a, a, a)
	try("effect2", VFX.effect, { layers = { a } }, Vector3.zero)
	try("play", VFX.play, a, a, a)
	try("preset", VFX.preset, a, a)
	try("flashLight", VFX.flashLight, a, a, a, a, a)
	try("hitstop", VFX.hitstop, a, a)
	try("screenFlash", VFX.screenFlash, a, a, a)
	try("vignette", function()
		local x = VFX.vignette(a, a, a)
		x:set(a, a)
		x:stop(a)
	end)
	try("trail", function()
		local t = VFX.trail(a, a)
		t:enable(a)
		t:burst(a)
		t:clear()
		t:destroy()
		local t2 = VFX.trail(root, { width = a, lifetime = a, color = a, transparency = a, texture = a, offset = a,
			axis = a, widthScale = a, textureMode = a, minLength = a, enabled = a })
		t2:destroy()
	end)
	try("budget", VFX.budget, a, a)
	try("validate", VFX.validate, a)
	try("handle", function()
		local x = VFX.effect({ layers = { { kind = "particles", count = 3 } } }, Vector3.zero, { scale = a, intensity = a,
			normal = a, direction = a, follow = a, timeScaled = a, onDone = a })
		x:andThen(a)
		x:stop()
		x:destroy(a)
	end)
	-- every key of every kind with this bad value
	for _, kind in { "particles", "beam", "light", "flash", "ring", "decal" } do
		local layer = { kind = kind }
		for _, key in M.FxKeys(kind) do
			if key ~= "kind" then
				layer[key] = a
			end
		end
		try("layer " .. kind, VFX.effect, { layers = { layer } }, Vector3.new(0, 1, 0))
	end
end
for _, spec in CORPUS do
	try("corpus", VFX.effect, spec, CFrame.new(0, 2, 0), { normal = Vector3.new(0, 1, 0) })
end
M.run(3)
VFX.clear()
M.run(1)
R.fuzz = { throws = throws, errors = M.errors, failures = failures(), warnings = #M.warnings,
	left = count("ParticleEmitter") + count("PointLight") + count("SpotLight") + count("Beam") + count("Decal") }
R.tweens = M.tweens
R.events = #events
print(json(R))
'''


def _long_string(src: str) -> str:
    level = 1
    while f"]{'=' * level}]" in src:
        level += 1
    return f"[{'=' * level}[\n{src}]{'=' * level}]"


def run_mock(workdir: Path, body: str) -> dict:
    workdir.mkdir(parents=True, exist_ok=True)
    (workdir / "mock.luau").write_text(ROBLOX_MOCK, encoding="utf-8")
    sources = "{ " + ", ".join(f"{m} = {_long_string(_source(m))}" for m in NEW_MODULES) + " }"
    corpus = "{" + ", ".join(lua(to_luau_spec(spec), vec="M.Vector3.new") for spec in CORPUS) + "}"
    return run_luau(workdir, f'\nlocal M = require("./mock")\nlocal SRC = {sources}\nlocal CORPUS = {corpus}\n' + body)


@pytest.fixture(scope="module")
def camera_run(tmp_path_factory):
    if LUAU is None:
        pytest.skip("standalone luau runtime not installed")
    return run_mock(tmp_path_factory.mktemp("camera"), CAMERA_SCENARIOS)


@pytest.fixture(scope="module")
def vfx_run(tmp_path_factory):
    if LUAU is None:
        pytest.skip("standalone luau runtime not installed")
    return run_mock(tmp_path_factory.mktemp("vfx"), VFX_SCENARIOS)


RELEASED = {"type": "Custom", "fov": 70, "bound": False, "cinematic": False, "timeScale": 1, "finite": True}


def test_camera_rig_effects_over_the_default_camera_leave_no_trace(camera_run):
    idle = camera_run["idle"]
    assert idle["peakFov"] == pytest.approx(80, abs=0.5) and idle["peakOffset"] == pytest.approx(0.5, abs=0.05)
    assert {k: idle[k] for k in RELEASED} == RELEASED
    assert idle["drift"] == 0 and idle["turn"] == 1                      # the default camera never drifts


def test_camera_rig_follow_frames_and_keeps_up(camera_run):
    f = camera_run["follow"]
    assert f["type"] == "Scriptable" and f["fov"] == 72 and f["bound"] and f["state"]
    assert f["dist"] == pytest.approx((16 ** 2 + 1) ** 0.5, abs=0.01)   # distance plus the preset's 1-stud offset
    assert f["aim"] > 0.99 and f["pitch"] == pytest.approx(-30, abs=0.1)
    assert f["lag"] < 0.01 and f["movingDist"] == pytest.approx(f["dist"], abs=0.01)   # no lag at a constant speed
    assert f["setDist"] == pytest.approx((24 ** 2 + 1) ** 0.5, abs=0.05) and f["setFov"] == pytest.approx(60, abs=0.01)
    assert camera_run["stopped"] == RELEASED                             # stop() hands the camera back


def test_camera_rig_shots_and_sequences(camera_run):
    shot = camera_run["shot"]
    assert shot["status"] == "playing" and shot["fov"] == 50 and shot["cinematic"]
    assert shot["barsSize"] == pytest.approx((1080 - 1920 / 2.39) / 2160, abs=1e-6)
    assert shot["afterStatus"] == "done" and shot["done"] == ["done"] and shot["afterBars"] == 0
    assert shot["after"]["type"] == "Scriptable" and shot["after"]["fov"] == pytest.approx(60)   # back to the follow
    cut = camera_run["cut"]
    assert cut["during"]["fov"] == 40 and cut["during"]["type"] == "Scriptable" and cut["status"] == "done"
    assert cut["after"] == RELEASED                                      # blendOut = 0 without a follow
    seq = camera_run["seq"]
    assert seq["status"] == "playing" and seq["during"]["timeScale"] == pytest.approx(0.25)
    assert seq["during"]["cinematic"] and seq["status2"] == "skipped"
    assert seq["thens"] == ["onDone:skipped", "andThen:skipped"] and seq["bars"] == 0
    assert seq["after"] == RELEASED
    inter = camera_run["interrupt"]
    assert inter["first"] == "interrupted" and inter["second"] == "done" and inter["awaited"] == "done"
    assert inter["after"] == RELEASED


def test_camera_rig_slowmo_and_reduce_motion(camera_run):
    slow = camera_run["slowmo"]
    assert slow["mid"] == pytest.approx(0.2) and slow["attribute"] == pytest.approx(0.2)
    assert slow["after"] == 1 and slow["afterAttribute"] == 1 and slow["calls"] > 5
    assert slow["min"] == pytest.approx(0.2)
    assert camera_run["shakes"] == [0.4, 0, 0, 1]                        # Kit.Shake only ever gets 0..1
    assert camera_run["reduced"]["peak"] == 0 and camera_run["reduced"]["after"] == RELEASED
    assert camera_run["final"] == RELEASED


def test_camera_rig_collision_and_orbit_input(camera_run):
    c = camera_run["collision"]
    assert c["free"] == pytest.approx((16 ** 2 + 1) ** 0.5, abs=0.01)
    assert c["blocked"] == pytest.approx((5 ** 2 + 1) ** 0.5, abs=0.01)  # pulled in before the wall at once
    assert c["blocked"] < c["oneFrameLater"] < 7                         # and eased back out
    assert c["returned"] == pytest.approx(c["free"], abs=0.01)
    o = camera_run["orbit"]
    assert o["right"] > 0.2 and o["lookDown"] < -0.1                     # drag right turns right, drag down looks down
    assert o["mouseWhileDragging"] == "LockCurrentPosition" and o["mouseAfter"] == "Default"
    assert o["lockedMoved"] < 1e-4 and o["topDownPitch"] == pytest.approx(-70, abs=0.01)
    assert o["after"] == RELEASED


def test_camera_rig_audit_fixes(camera_run):
    hb = camera_run["handBack"]
    assert hb["status"] == "done" and hb["facing"] > 0.999 and hb["after"] == RELEASED   # faces where it did before
    b = camera_run["beats"]
    assert b["during"] == pytest.approx(0.2) and b["afterSkip"] == pytest.approx(0.5)   # the gameplay beat survives
    assert b["later"] == 1
    c = camera_run["chain"]
    assert c == {"first": "interrupted", "interrupter": "interrupted", "chained": "done", "after": RELEASED}
    assert camera_run["invert"]["lookUp"] > 0.1                          # inverted: dragging down looks up


def test_camera_rig_survives_bad_input(camera_run):
    fuzz = camera_run["fuzz"]
    assert fuzz["throws"] == [] and fuzz["errors"] == []
    assert fuzz["after"] == RELEASED and fuzz["warnings"] > 10
    assert all(w.startswith("[CameraRig] ") for w in camera_run["warningSample"])
    assert "camera_shot" in camera_run["events"] and "camera_follow" in camera_run["events"]


def test_vfx_layers_spawn_and_clean_up(vfx_run):
    imp = vfx_run["impact"]
    assert imp["alive"] and imp["emitters"] == 3 and imp["lights"] == 1 and imp["beams"] == 1
    assert imp["meshes"] == 3 and imp["decals"] == 1
    assert imp["emitted"] == 1 + round(18 * 0.8) + round(6 * 0.8)        # bursts scale with intensity
    after = imp["after"]
    assert not after["alive"] and after["reasons"] == ["done"]
    assert after["emitters"] == after["lights"] == after["beams"] == after["meshes"] == after["decals"] == 0
    assert after["visibleParts"] == 0


def test_vfx_budgets_and_light_cap(vfx_run):
    b = vfx_run["budget"]
    assert b["alive"] == 2 and b["evicted"] == 8                          # the preset allows 2 lights: 2 impacts
    assert b["newestAlive"] and not b["oldestAlive"]                      # the oldest go first
    assert vfx_run["familyLights"] == 3                                   # the flashLight family keeps 3
    assert vfx_run["lights"]["live"] == vfx_run["lights"]["cap"] == 6 and vfx_run["lights"]["after"] == 0


def test_vfx_continuous_follow_and_stop(vfx_run):
    s = vfx_run["stream"]
    assert s["aliveAfter3s"] and s["onRoot"] and s["aliveJustAfterStop"]
    assert not s["aliveLater"] and s["leftOnRoot"] == 0


def test_vfx_hitstop_and_slowmo(vfx_run):
    h = vfx_run["hitstop"]
    assert h["during"] == [0, 0, 0] and h["stillFrozen"] == 0            # nested stops extend the freeze
    assert h["after"] == [1.5, 1, 1]                                      # original speeds come back
    s = vfx_run["slowmo"]
    assert s["slowed"] == pytest.approx(0.25) and s["unscaled"] == 1 and s["after"] == 1


def test_vfx_screen_accents_and_trails(vfx_run):
    sc = vfx_run["screen"]
    assert sc["flashDuring"] == pytest.approx(0.4) and sc["flashAfter"] == 1
    assert sc["vignetteEdges"] == 4 and sc["vignetteGone"] and sc["persistent"] and sc["stopped"]
    t = vfx_run["trail"]
    assert t["onRoot"] == 1 and t["enabled"] is False and t["during"] is True and t["after"] is False
    assert t["destroyed"] == 0


def test_vfx_audit_fixes(vfx_run):
    assert vfx_run["slowBurst"] == {"aliveAt095": True, "aliveLater": False}   # slowed particles are not cut off
    assert vfx_run["riding"] == {"before": True, "after": False}
    t = vfx_run["textures"]
    assert t["returned"] is True and t["applied"] == ["spark_soft", "slow_tex"]   # no mesh; the wait did not block


def test_vfx_survives_bad_input(vfx_run):
    fuzz = vfx_run["fuzz"]
    assert fuzz["throws"] == [] and fuzz["errors"] == []
    assert fuzz["failures"] == []                   # coercion never hands the engine a value it rejects
    assert fuzz["left"] == 0 and fuzz["warnings"] > 100

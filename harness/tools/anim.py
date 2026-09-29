"""Character animation as data: validate keyframe clips, pack them for the runtime kit, and SEE them.

Games are built without uploaded assets, so custom animation cannot use Animation assets. Builders author clips
as data instead, and Kit.Anim (harness/kit/Anim.luau, on the pure core harness/kit/AnimCore.luau) plays them on any
Motor6D rig.

    validate_clip(spec) -> (clip, errors)   every problem at once, with did-you-mean hints; the clip comes back
                                            normalized (None only when it is too broken to read)
    ClipPack(workspace)                     clips -> src/ReplicatedStorage/Shared/ClipPack.luau, plus a JSON
                                            manifest (clip_pack.json) at the workspace root
    preview(clip, frames=8) -> PNG          stick-figure contact sheet of an R15 rig: front and side view per frame
    anim_tools(pack, art_dir)               author_clip / list_clips for builder agents

Conventions, identical in AnimCore.luau and playbooks/animation_spec.md:
- pose = {joint: [rx, ry, rz] or [rx, ry, rz, px, py, pz]}: degrees and studs relative to the joint's rest frame,
  about the CHARACTER's axes at rest: X = its right, Y = up, Z = back (it faces -Z).
- rotation = CFrame.Angles(rx, ry, rz) = Rx @ Ry @ Rz, held as a quaternion. Each joint's curve runs through the
  keys that pose it, by quaternion slerp (the short way round), eased by the ease of the key it moves INTO. Looped
  clips wrap each joint's curve around the loop.
- The preview's forward kinematics uses standard R15 proportions and the same frames, so what the model sees is
  what the runtime plays on a default-proportioned R15 character.
"""
from __future__ import annotations

import difflib
import io
import json
import logging
import math
import os
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

import numpy as np
from PIL import Image, ImageDraw, ImageFont

from harness.tools.base import Tool, ToolResult
from harness.tools.workspace import Workspace, lua_quote

log = logging.getLogger("harness.anim")

PRIORITIES = ("core", "idle", "movement", "action")
EASE_STYLES = ("sine", "quad", "cubic", "back", "expo")
EASES = ("linear",) + tuple(f"{s}{d}" for s in EASE_STYLES for d in ("", "In", "Out"))
DEFAULT_EASE = "sine"
RIGS = ("R15", "custom")
MIN_LENGTH, MAX_LENGTH = 0.05, 60.0
MAX_KEYS = 200
MAX_FRAMES = 16
DECIMALS = 4                      # clip numbers are rounded to this many places (what the pack stores)
PACK_PATH = "ReplicatedStorage/Shared/ClipPack.luau"
MANIFEST_NAME = "clip_pack.json"
_NAME_RE = re.compile(r"[A-Za-z][A-Za-z0-9_\-]{0,39}")
_IDENT_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
_LUA_KEYWORDS = frozenset("and break do else elseif end false for function if in local nil not or repeat return "
                          "then true until while continue".split())
_AXES = ("rx", "ry", "rz")


# ---------------------------------------------------------------------------------------------------- the R15 rig

@dataclass(frozen=True)
class JointSpec:
    name: str
    part0: str                                    # parent part
    part1: str                                    # the part this joint moves
    c0: tuple[float, float, float]                # pivot in part0 space (rotation identity, as on R15)
    c1: tuple[float, float, float]                # pivot in part1 space
    rot: tuple[tuple[float, float], ...]          # allowed (lo, hi) degrees for rx, ry, rz
    move: float                                   # max |px|, |py|, |pz| in studs


def _mirror(spec: JointSpec) -> JointSpec:
    """The left-side twin of a right-side joint: x of the offsets and the ry / rz ranges flip sign."""
    (rxl, rxh), (ryl, ryh), (rzl, rzh) = spec.rot
    swap = lambda n: n.replace("Right", "Left")  # noqa: E731
    return JointSpec(swap(spec.name), swap(spec.part0), swap(spec.part1), (-spec.c0[0], *spec.c0[1:]),
                     (-spec.c1[0], *spec.c1[1:]), ((rxl, rxh), (-ryh, -ryl), (-rzh, -rzl)), spec.move)


_RIGHT = [
    JointSpec("RightShoulder", "UpperTorso", "RightUpperArm", (1.0, 0.563, 0.0), (-0.5, 0.393, 0.0),
              ((-80, 190), (-100, 100), (-60, 190)), 1.0),
    JointSpec("RightElbow", "RightUpperArm", "RightLowerArm", (0.0, -0.334, 0.0), (0.0, 0.26, 0.0),
              ((-5, 155), (-100, 100), (-15, 15)), 1.0),
    JointSpec("RightWrist", "RightLowerArm", "RightHand", (0.0, -0.5, 0.0), (0.0, 0.125, 0.0),
              ((-80, 80), (-60, 60), (-80, 80)), 1.0),
    JointSpec("RightHip", "LowerTorso", "RightUpperLeg", (0.5, -0.2, 0.0), (0.0, 0.42, 0.0),
              ((-60, 130), (-60, 60), (-35, 70)), 1.0),
    JointSpec("RightKnee", "RightUpperLeg", "RightLowerLeg", (0.0, -0.4, 0.0), (0.0, 0.4, 0.0),
              ((-160, 5), (-20, 20), (-15, 15)), 1.0),
    JointSpec("RightAnkle", "RightLowerLeg", "RightFoot", (0.0, -0.53, 0.0), (0.0, 0.1, 0.0),
              ((-65, 45), (-35, 35), (-35, 35)), 1.0),
]
# Standard R15 proportions (default body scale): HumanoidRootPart centre 3 studs up, hips at 2, shoulders at 3.76,
# neck at 4, head centre 4.5; arms hang to the hips. Parents come before children.
R15_JOINTS: tuple[JointSpec, ...] = (
    JointSpec("Root", "HumanoidRootPart", "LowerTorso", (0.0, -1.0, 0.0), (0.0, -0.2, 0.0),
              ((-720, 720), (-720, 720), (-720, 720)), 12.0),
    JointSpec("Waist", "LowerTorso", "UpperTorso", (0.0, 0.2, 0.0), (0.0, -0.8, 0.0),
              ((-80, 45), (-60, 60), (-45, 45)), 1.0),
    JointSpec("Neck", "UpperTorso", "Head", (0.0, 0.8, 0.0), (0.0, -0.5, 0.0),
              ((-60, 60), (-85, 85), (-45, 45)), 1.0),
    _RIGHT[0], _RIGHT[1], _RIGHT[2], _mirror(_RIGHT[0]), _mirror(_RIGHT[1]), _mirror(_RIGHT[2]),
    _RIGHT[3], _RIGHT[4], _RIGHT[5], _mirror(_RIGHT[3]), _mirror(_RIGHT[4]), _mirror(_RIGHT[5]),
)
R15 = {j.name: j for j in R15_JOINTS}
R15_ORDER = tuple(j.name for j in R15_JOINTS)
ROOT_HEIGHT = 3.0
PART_JOINT = {j.part1: j.name for j in R15_JOINTS} | {"HumanoidRootPart": "Root", "Torso": "Waist"}
R6_JOINT = {"rootjoint": "Root", "torso": "Waist"}

# Sign traps worth spelling out when a value is out of range (joint, axis index) -> hint.
_LIMIT_HINTS = {
    ("Knee", 0): "knees bend BACK with NEGATIVE rx (a deep crouch is about -110)",
    ("Elbow", 0): "elbows bend with POSITIVE rx (the forearm swings forward and up)",
    ("RightShoulder", 2): "rz+ raises the right arm out to its side; rz- brings it across the body",
    ("LeftShoulder", 2): "the left arm mirrors the right: rz- raises it out to its side, rz+ brings it across",
    ("RightHip", 2): "rz+ swings the right leg out to its side",
    ("LeftHip", 2): "rz- swings the left leg out to its side",
    ("Shoulder", 0): "rx+ raises the arm forward (90 = pointing forward, 180 = straight up); rx- swings it back",
    ("Hip", 0): "rx+ swings the leg forward, rx- back",
    ("Waist", 0): "bend forward with NEGATIVE rx, arch back with positive",
    ("Neck", 0): "look down with NEGATIVE rx, up with positive",
    ("Ankle", 0): "toes up is +rx, toes pointed down is -rx",
}


def _limit_hint(joint: str, axis: int) -> str:
    for key in ((joint, axis), (joint.replace("Right", "").replace("Left", ""), axis)):
        if key in _LIMIT_HINTS:
            return f" ({_LIMIT_HINTS[key]})"
    return ""


# ---------------------------------------------------------------------------------------------------- math
# Plain-float mirrors of AnimCore.luau: same formulas, same order, so Python and Luau agree to ~1e-12.

_HALF_RAD = math.pi / 360.0
_B1 = 1.70158
_B2 = _B1 * 1.525
_B3 = _B1 + 1.0

Quat = tuple[float, float, float, float]
Vec = tuple[float, float, float]
IDENTITY: Quat = (0.0, 0.0, 0.0, 1.0)


def euler_quat(rx: float, ry: float, rz: float) -> Quat:
    """CFrame.Angles(rx, ry, rz) in degrees (= Rx @ Ry @ Rz) as a quaternion (x, y, z, w)."""
    hx, hy, hz = rx * _HALF_RAD, ry * _HALF_RAD, rz * _HALF_RAD
    sx, cx = math.sin(hx), math.cos(hx)
    sy, cy = math.sin(hy), math.cos(hy)
    sz, cz = math.sin(hz), math.cos(hz)
    return (sx * cy * cz + cx * sy * sz, cx * sy * cz - sx * cy * sz, cx * cy * sz + sx * sy * cz,
            cx * cy * cz - sx * sy * sz)


def quat_mul(a: Quat, b: Quat) -> Quat:
    ax, ay, az, aw = a
    bx, by, bz, bw = b
    return (aw * bx + ax * bw + ay * bz - az * by, aw * by - ax * bz + ay * bw + az * bx,
            aw * bz + ax * by - ay * bx + az * bw, aw * bw - ax * bx - ay * by - az * bz)


def quat_matrix(q: Quat) -> np.ndarray:
    x, y, z, w = q
    return np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                     [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                     [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])


def quat_euler(q: Quat) -> Vec:
    """Quaternion -> (rx, ry, rz) degrees with Rx @ Ry @ Rz = the rotation (CFrame:ToEulerAnglesXYZ)."""
    m = quat_matrix(q)
    ry = math.asin(max(-1.0, min(1.0, m[0, 2])))
    return math.degrees(math.atan2(-m[1, 2], m[2, 2])), math.degrees(ry), math.degrees(math.atan2(-m[0, 1], m[0, 0]))


def slerp(a: Quat, b: Quat, t: float) -> Quat:
    """Short-way spherical interpolation; t outside 0..1 extrapolates on the same arc (as AnimCore)."""
    ax, ay, az, aw = a
    bx, by, bz, bw = b
    d = ax * bx + ay * by + az * bz + aw * bw
    if d < 0:
        d, bx, by, bz, bw = -d, -bx, -by, -bz, -bw
    if d > 0.9995:
        k0, k1 = 1 - t, t
    else:
        th = math.acos(d)
        s = math.sin(th)
        k0, k1 = math.sin((1 - t) * th) / s, math.sin(t * th) / s
    x, y, z, w = ax * k0 + bx * k1, ay * k0 + by * k1, az * k0 + bz * k1, aw * k0 + bw * k1
    n = math.sqrt(x * x + y * y + z * z + w * w)
    if n < 1e-12:
        return IDENTITY
    return x / n, y / n, z / n, w / n


def ease(name: str, a: float) -> float:
    """The easing curves of AnimCore (Penner): <style> eases both ends, <style>In accelerates into the key,
    <style>Out decelerates into it (Enum.EasingDirection meaning). back overshoots."""
    if name == "linear":
        return a
    if name == "sine":
        return -(math.cos(math.pi * a) - 1) / 2
    if name == "sineIn":
        return 1 - math.cos(a * (math.pi / 2))
    if name == "sineOut":
        return math.sin(a * (math.pi / 2))
    if name == "quad":
        if a < 0.5:
            return 2 * a * a
        b = -2 * a + 2
        return 1 - b * b / 2
    if name == "quadIn":
        return a * a
    if name == "quadOut":
        b = 1 - a
        return 1 - b * b
    if name == "cubic":
        if a < 0.5:
            return 4 * a * a * a
        b = -2 * a + 2
        return 1 - b * b * b / 2
    if name == "cubicIn":
        return a * a * a
    if name == "cubicOut":
        b = 1 - a
        return 1 - b * b * b
    if name == "back":
        if a < 0.5:
            b = 2 * a
            return b * b * ((_B2 + 1) * b - _B2) / 2
        b = 2 * a - 2
        return (b * b * ((_B2 + 1) * b + _B2) + 2) / 2
    if name == "backIn":
        return _B3 * a * a * a - _B1 * a * a
    if name == "backOut":
        b = a - 1
        return 1 + _B3 * b * b * b + _B1 * b * b
    if name == "expo":
        if a <= 0:
            return 0.0
        if a >= 1:
            return 1.0
        if a < 0.5:
            return 2 ** (20 * a - 10) / 2
        return (2 - 2 ** (-20 * a + 10)) / 2
    if name == "expoIn":
        return 0.0 if a <= 0 else 2 ** (10 * a - 10)
    if name == "expoOut":
        return 1.0 if a >= 1 else 1 - 2 ** (-10 * a)
    raise ValueError(f"unknown ease {name!r}")


# ---------------------------------------------------------------------------------------------------- sampling

@dataclass
class Channel:
    """One joint's curve: the keys that pose it."""
    joint: str
    t: list[float]
    q: list[Quat]
    p: list[Vec]
    ease: list[str]


def channels(clip: dict) -> dict[str, Channel]:
    """Per-joint channels of a normalized clip, as AnimCore.compile builds them: in a one-shot, a joint not posed
    at t=0 starts from rest at t=0."""
    out: dict[str, Channel] = {}
    for key in clip["keys"]:
        e = key.get("ease") or DEFAULT_EASE
        for joint, v in key["pose"].items():
            ch = out.get(joint)
            if ch is None:
                ch = out[joint] = Channel(joint, [], [], [], [])
            ch.t.append(float(key["t"]))
            ch.q.append(euler_quat(v[0], v[1], v[2]))
            ch.p.append((float(v[3]), float(v[4]), float(v[5])) if len(v) == 6 else (0.0, 0.0, 0.0))
            ch.ease.append(e)
    if not clip["looped"]:
        for ch in out.values():
            if ch.t[0] > 0:
                ch.t.insert(0, 0.0)
                ch.q.insert(0, IDENTITY)
                ch.p.insert(0, (0.0, 0.0, 0.0))
                ch.ease.insert(0, DEFAULT_EASE)
    return out


def sample_channel(ch: Channel, t: float, looped: bool, length: float) -> tuple[Quat, Vec]:
    """One joint at time t, exactly as AnimCore.sampleChannel."""
    n = len(ch.t)
    times = ch.t
    if n == 1:
        return ch.q[0], ch.p[0]
    i = j = -1
    a = 0.0
    if looped:
        t -= math.floor(t / length) * length
        if t >= length:
            t = 0.0
        last = times[-1]
        if t < times[0] or t >= last:
            span = times[0] + length - last
            u = t - last if t >= last else t + length - last
            i, j, a = n - 1, 0, (u / span if span > 0 else 0.0)
    else:
        if t <= times[0]:
            return ch.q[0], ch.p[0]
        if t >= times[-1]:
            return ch.q[-1], ch.p[-1]
    if i < 0:
        lo, hi = 0, n - 1
        while hi - lo > 1:
            mid = (lo + hi) // 2
            if times[mid] <= t:
                lo = mid
            else:
                hi = mid
        i, j = lo, lo + 1
        a = (t - times[i]) / (times[j] - times[i])
    k = ease(ch.ease[j], a)
    q = slerp(ch.q[i], ch.q[j], k)
    pi, pj = ch.p[i], ch.p[j]
    return q, (pi[0] + (pj[0] - pi[0]) * k, pi[1] + (pj[1] - pi[1]) * k, pi[2] + (pj[2] - pi[2]) * k)


def sample_clip(clip: dict, t: float, looped: bool | None = None,
                chans: dict[str, Channel] | None = None) -> dict[str, tuple[Quat, Vec]]:
    """Every joint of a normalized clip at time t: {joint: (quaternion, position)}."""
    chans = chans if chans is not None else channels(clip)
    lp = clip["looped"] if looped is None else looped
    return {j: sample_channel(ch, t, lp, clip["length"]) for j, ch in chans.items()}


# ---------------------------------------------------------------------------------------------------- R15 FK

Frame = tuple[np.ndarray, np.ndarray]           # (3x3 rotation, origin) in world space


def fk_r15(pose: dict[str, tuple[Quat, Vec]]) -> dict[str, Frame]:
    """World frames of the R15 parts for a sampled pose ({joint: (quaternion, position)}); the HumanoidRootPart
    stands at (0, 3, 0) facing -Z. Part1 = Part0 * C0 * (Translate(p) * Rotate(q)) * C1^-1, as Motor6D.Transform."""
    world: dict[str, Frame] = {"HumanoidRootPart": (np.eye(3), np.array([0.0, ROOT_HEIGHT, 0.0]))}
    for j in R15_JOINTS:
        r0, o0 = world[j.part0]
        q, p = pose.get(j.name, (IDENTITY, (0.0, 0.0, 0.0)))
        r1 = r0 @ quat_matrix(q)
        pivot = o0 + r0 @ (np.array(j.c0) + np.array(p, dtype=float))
        world[j.part1] = (r1, pivot - r1 @ np.array(j.c1))
    return world


def euler_pose(pose: dict[str, Iterable[float]]) -> dict[str, tuple[Quat, Vec]]:
    """{joint: [rx, ry, rz(, px, py, pz)]} degrees/studs -> {joint: (quaternion, position)} for fk_r15."""
    out = {}
    for joint, v in pose.items():
        v = [float(x) for x in v]
        out[joint] = (euler_quat(v[0], v[1], v[2]), (v[3], v[4], v[5]) if len(v) == 6 else (0.0, 0.0, 0.0))
    return out


# Drawn skeleton, in part space: limbs as thick bones (top -> bottom), torso pieces as boxes (half extents).
_BONES = {
    "RightUpperArm": ((0, 0.393, 0), (0, -0.334, 0)), "RightLowerArm": ((0, 0.26, 0), (0, -0.5, 0)),
    "RightHand": ((0, 0.125, 0), (0, -0.16, 0)),
    "RightUpperLeg": ((0, 0.42, 0), (0, -0.4, 0)), "RightLowerLeg": ((0, 0.4, 0), (0, -0.53, 0)),
    "RightFoot": ((0, -0.05, 0.36), (0, -0.05, -0.55)),
}
_BONES |= {k.replace("Right", "Left"): v for k, v in _BONES.items()}
_BOXES = {"LowerTorso": (0.95, 0.2, 0.45), "UpperTorso": (1.0, 0.8, 0.5)}
HEAD_RADIUS = 0.62


def _at(frame: Frame, local: Iterable[float]) -> np.ndarray:
    r, o = frame
    return o + r @ np.asarray(local, dtype=float)


def skeleton_points(world: dict[str, Frame]) -> dict[str, np.ndarray]:
    """Named world points of a posed R15 figure: joint pivots, hand tips, heels / toes, head centre and nose."""
    pts: dict[str, np.ndarray] = {}
    for j in R15_JOINTS:
        pts[j.name] = _at(world[j.part1], j.c1)
    for side in ("Right", "Left"):
        pts[f"{side}HandTip"] = _at(world[f"{side}Hand"], _BONES[f"{side}Hand"][1])
        pts[f"{side}Heel"] = _at(world[f"{side}Foot"], _BONES[f"{side}Foot"][0])
        pts[f"{side}Toe"] = _at(world[f"{side}Foot"], _BONES[f"{side}Foot"][1])
    pts["Head"] = world["Head"][1].copy()
    pts["Nose"] = _at(world["Head"], (0, 0, -HEAD_RADIUS))
    return pts


def pose_points(pose: dict[str, Iterable[float]]) -> dict[str, np.ndarray]:
    """Skeleton points for a pose written the way clips are ({joint: [rx, ry, rz(, px, py, pz)]})."""
    return skeleton_points(fk_r15(euler_pose(pose)))


SOLE_BELOW_BONE = 0.1            # the sole is this far below the drawn foot bone (heel -> toe)


def sole_heights(points: dict[str, np.ndarray]) -> dict[str, float]:
    """Height of each foot's lowest point above the ground (0 = standing on it)."""
    return {s: float(min(points[f"{s}Heel"][1], points[f"{s}Toe"][1])) - SOLE_BELOW_BONE for s in ("Right", "Left")}


def contact_report(clip: dict) -> list[str]:
    """Where the feet are at each key of an R15 clip: into the ground, or all off it (fine for a jump)."""
    if clip.get("rig", "R15") != "R15":
        return []
    chans = channels(clip)
    notes = []
    for key in clip["keys"]:
        soles = sole_heights(skeleton_points(fk_r15(sample_clip(clip, key["t"], chans=chans))))
        side = min(soles, key=soles.get)
        low = soles[side]
        if low < -0.08:
            notes.append(f"t={key['t']:g}: the {side.lower()} foot is {-low:.2f} studs into the ground")
        elif low > 0.15:
            notes.append(f"t={key['t']:g}: both feet are {low:.2f}+ studs off the ground")
    return notes


# ---------------------------------------------------------------------------------------------------- validation

_TOP_FIELDS = ("name", "rig", "length", "looped", "priority", "keys", "markers")
_KEY_FIELDS = ("t", "pose", "ease")
_MARKER_FIELDS = ("t", "name")
_FIELD_ALIASES = {"loop": "looped", "loops": "looped", "looping": "looped", "duration": "length", "time": "length",
                  "len": "length", "keyframes": "keys", "frames": "keys", "poses": "keys", "events": "markers",
                  "marker": "markers", "prio": "priority"}
_KEY_ALIASES = {"time": "t", "at": "t", "easing": "ease", "easingstyle": "ease", "poses": "pose", "joints": "pose",
                "rotation": "pose", "rotations": "pose", "transforms": "pose"}
_MARKER_ALIASES = {"time": "t", "at": "t", "event": "name", "label": "name", "id": "name"}
_EASE_WORDS = ("exponential", "quadratic", "linear", "cubic", "quad", "sine", "back", "expo", "sin")
_EASE_STYLE_OF = {"exponential": "expo", "quadratic": "quad", "sin": "sine"}
_UNSUPPORTED_EASES = {"bounce": "back (overshoot) or a few extra keys", "elastic": "back, or extra keys",
                      "quart": "cubic", "quint": "cubic or expo", "circ": "cubic", "circular": "cubic",
                      "constant": "a very short linear segment", "step": "a very short linear segment"}


def _squash(s: str) -> str:
    return re.sub(r"[\s_\-.]", "", str(s)).lower()


def _did_you_mean(word: Any, options: Iterable[str], aliases: dict[str, str] | None = None) -> str:
    opts = list(options)
    key = _squash(word)
    if aliases and key in aliases:
        return f"; did you mean {aliases[key]!r}?"
    squashed = {_squash(o): o for o in opts}
    if key in squashed:
        return f"; did you mean {squashed[key]!r}?"
    close = difflib.get_close_matches(str(word), opts, n=2, cutoff=0.6)
    if not close:
        close = [squashed[c] for c in difflib.get_close_matches(key, list(squashed), n=2, cutoff=0.6)]
    return ("; did you mean " + " or ".join(repr(c) for c in close) + "?") if close else ""


def _joint_hint(name: str) -> str:
    if name in PART_JOINT:
        return f" ({name} is a part; the joint that moves it is {PART_JOINT[name]!r})"
    if _squash(name) in R6_JOINT:
        return f"; did you mean {R6_JOINT[_squash(name)]!r}? (R15 names, not R6)"
    for part, joint in PART_JOINT.items():
        if _squash(name) == _squash(part):
            return f" ({part} is a part; the joint that moves it is {joint!r})"
    return _did_you_mean(name, R15_ORDER)


def parse_ease(value: Any) -> str | None:
    """Canonical ease name for common spellings ('quadOut', 'QuadOut', 'easeOutQuad', 'out-quad', 'InOutSine'),
    or None."""
    if not isinstance(value, str):
        return None
    if value in EASES:
        return value
    s = re.sub(r"[^a-z]", "", value.lower()).replace("easing", "").replace("ease", "")
    for word in _EASE_WORDS:
        if word in s:
            style = _EASE_STYLE_OF.get(word, word)
            rest = s.replace(word, "", 1)
            if style == "linear":
                return "linear" if rest in ("", "in", "out", "inout") else None
            direction = {"": "", "inout": "", "outin": "", "in": "In", "out": "Out"}.get(rest)
            return None if direction is None else style + direction
    return None


def _is_num(x: Any) -> bool:
    return isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x)


def _r(x: float) -> float:
    v = round(float(x), DECIMALS)
    return 0.0 if v == 0 else v


def _pose_value(v: Any) -> tuple[list[float] | None, str]:
    """A pose value -> [rx, ry, rz] or [rx, ry, rz, px, py, pz] (rounded), or None and why not."""
    if isinstance(v, dict):
        bad = [k for k in v if k not in ("rx", "ry", "rz", "px", "py", "pz")]
        if bad:
            return None, f"unknown component {bad[0]!r} (use rx, ry, rz in degrees and px, py, pz in studs)"
        if not v:
            return None, "empty value; give [rx, ry, rz]"
        if not all(_is_num(x) for x in v.values()):
            return None, "components must be finite numbers"
        vals = [v.get(k, 0) for k in ("rx", "ry", "rz", "px", "py", "pz")]
    elif isinstance(v, (list, tuple)):
        if len(v) not in (3, 6):
            return None, f"has {len(v)} numbers; use [rx, ry, rz] or [rx, ry, rz, px, py, pz]"
        if not all(_is_num(x) for x in v):
            return None, "values must be finite numbers (degrees, then studs)"
        vals = list(v)
    else:
        return None, "must be [rx, ry, rz] or [rx, ry, rz, px, py, pz] (degrees, studs)"
    vals = [_r(x) for x in vals]
    if len(vals) == 6 and not any(vals[3:]):
        vals = vals[:3]
    return vals, ""


def _joint_order(name: str) -> tuple[int, str]:
    return (R15_ORDER.index(name), "") if name in R15 else (len(R15_ORDER), name)


def validate_clip(spec: Any, name: str | None = None,
                  notes: list[str] | None = None) -> tuple[dict | None, list[str]]:
    """Check a clip spec and normalize it. Returns (clip, errors): errors lists every problem at once (with
    did-you-mean hints); the clip is valid only when errors is empty. clip is None when the spec is too broken to
    read (bad length, keys, times, eases or pose values); otherwise it is the normalized clip even when there are
    errors (unknown joints, limits, seams), so it can still be previewed. `notes` collects harmless rewrites
    (e.g. 'easeOutBack' read as 'backOut')."""
    errors: list[str] = []
    if isinstance(spec, (str, bytes)):
        try:
            spec = json.loads(spec)
        except ValueError as e:
            return None, [f"spec is not valid JSON: {e}"]
    if not isinstance(spec, dict):
        return None, [f"a clip spec must be an object {{length, looped, priority, keys, markers}}, "
                      f"got {type(spec).__name__}"]
    broken = False
    for k in spec:
        if k not in _TOP_FIELDS:
            errors.append(f"unknown field {k!r}{_did_you_mean(k, _TOP_FIELDS, _FIELD_ALIASES)} "
                          f"(fields: {', '.join(_TOP_FIELDS)})")

    clip_name = name if name is not None else spec.get("name")
    if name is not None and spec.get("name") not in (None, name):
        errors.append(f"spec name {spec.get('name')!r} differs from the clip name {name!r}; drop one")
    if not isinstance(clip_name, str) or not _NAME_RE.fullmatch(clip_name):
        errors.append(f"name {clip_name!r}: use 1-40 letters, digits, _ or -, starting with a letter "
                      "(e.g. 'sword_slash')")

    rig = spec.get("rig", "R15")
    rig_norm = {"r15": "R15", "custom": "custom"}.get(_squash(rig)) if isinstance(rig, str) else None
    if rig_norm is None:
        errors.append(f"rig {rig!r} must be 'R15' (default) or 'custom' (any Motor6D names, no R15 limits)"
                      f"{_did_you_mean(rig, RIGS)}")
        rig_norm = "R15"
    is_r15 = rig_norm == "R15"

    length = spec.get("length")
    if length is None:
        errors.append("length is required: the clip's duration in seconds (e.g. 0.8)")
        broken = True
    elif not _is_num(length):
        errors.append(f"length must be a number of seconds, got {length!r}")
        broken = True
    elif not MIN_LENGTH <= length <= MAX_LENGTH:
        errors.append(f"length {length} is outside {MIN_LENGTH}..{MAX_LENGTH:g} seconds")
        broken = True
    length = _r(length) if _is_num(length) else 1.0

    looped = spec.get("looped", False)
    if not isinstance(looped, bool):
        errors.append(f"looped must be true or false, got {looped!r}")
        broken = True
        looped = False

    priority = spec.get("priority")
    if priority is None:
        priority = "idle" if looped else "action"
    elif not isinstance(priority, str) or priority.lower() not in PRIORITIES:
        errors.append(f"priority {priority!r} must be one of {', '.join(PRIORITIES)}"
                      f"{_did_you_mean(priority, PRIORITIES)}")
        priority = "idle" if looped else "action"
    else:
        priority = priority.lower()

    keys = spec.get("keys")
    norm_keys: list[dict] = []
    if not isinstance(keys, list) or not keys:
        errors.append("keys must be a non-empty list of {t, pose: {Joint: [rx, ry, rz]}, ease}")
        keys = []
        broken = True
    elif len(keys) > MAX_KEYS:
        errors.append(f"{len(keys)} keys is too many (max {MAX_KEYS})")
        broken = True
    unknown_joints: set[str] = set()
    listed_joints = False
    for i, key in enumerate(keys):
        where = f"keys[{i}]"
        if not isinstance(key, dict):
            errors.append(f"{where} must be an object {{t, pose, ease}}")
            broken = True
            continue
        for k in key:
            if k not in _KEY_FIELDS:
                errors.append(f"{where}: unknown field {k!r}{_did_you_mean(k, _KEY_FIELDS, _KEY_ALIASES)} "
                              f"(key fields: t, pose, ease)")
        t = key.get("t")
        if not _is_num(t):
            errors.append(f"{where}.t must be a number of seconds, got {t!r}")
            broken = True
            t = 0.0
        elif t < 0:
            errors.append(f"{where}.t = {t:g} is negative; key times run from 0 to length ({length:g} s)")
            broken = True
        elif t > length + 1e-9:
            errors.append(f"{where}.t = {t:g} is beyond length ({length:g} s); raise length or move the key")
            broken = True
        t = _r(t)
        where = f"keys[{i}] (t={t:g})"
        e = key.get("ease", DEFAULT_EASE)
        ce = parse_ease(e)
        if ce is None:
            style = next((w for w in _UNSUPPORTED_EASES if isinstance(e, str) and w in e.lower()), None)
            extra = f" ({style} is not supported; use {_UNSUPPORTED_EASES[style]})" if style else ""
            errors.append(f"{where}.ease {e!r} is not an ease{extra}{_did_you_mean(e, EASES)}; use linear or "
                          f"sine|quad|cubic|back|expo, optionally + In / Out (e.g. quadIn, backOut)")
            broken = True
            ce = DEFAULT_EASE
        elif ce != e and notes is not None:
            notes.append(f"{where}.ease {e!r} read as {ce!r}")
        pose = key.get("pose")
        norm_pose: dict[str, list[float]] = {}
        if not isinstance(pose, dict) or not pose:
            errors.append(f"{where}.pose must be a non-empty object {{Joint: [rx, ry, rz]}}")
            broken = True
            pose = {}
        for joint, v in pose.items():
            if not isinstance(joint, str) or not joint.strip():
                errors.append(f"{where}.pose has an empty joint name")
                continue
            if is_r15 and joint not in R15:
                unknown_joints.add(joint)
                tail = "" if listed_joints else f". R15 joints: {', '.join(R15_ORDER)}"
                listed_joints = True
                errors.append(f"{where}.pose: unknown joint {joint!r}{_joint_hint(joint)}{tail}")
            vals, why = _pose_value(v)
            if vals is None:
                errors.append(f"{where}.pose.{joint} {why}")
                broken = True
                continue
            norm_pose[joint] = vals
        norm_keys.append({"t": t, "ease": ce,
                          "pose": {j: norm_pose[j] for j in sorted(norm_pose, key=_joint_order)}})

    # time order, first / last keys
    for i in range(1, len(norm_keys)):
        a, b = norm_keys[i - 1]["t"], norm_keys[i]["t"]
        if b <= a:
            what = "has the same t as" if b == a else "comes before"
            errors.append(f"keys out of order: keys[{i}] (t={b:g}) {what} keys[{i - 1}] (t={a:g}); keys must be in "
                          f"increasing time")
            broken = True
    if norm_keys and norm_keys[0]["t"] != 0:
        errors.append(f"missing t=0 key: the first key is at t={norm_keys[0]['t']:g}; add the pose the clip starts "
                      f"from at t=0")
        broken = True
    if looped and norm_keys and abs(norm_keys[-1]["t"] - length) > 1e-9:
        errors.append(f"missing t=length key: a looped clip ends on a key at t={length:g} (the same pose as t=0); "
                      f"the last key is at t={norm_keys[-1]['t']:g}")

    # anatomical limits (R15) and offsets
    for i, key in enumerate(norm_keys):
        where = f"keys[{i}] (t={key['t']:g})"
        for joint, vals in key["pose"].items():
            spec_j = R15.get(joint) if is_r15 else None
            if spec_j is not None:
                for ax in range(3):
                    lo, hi = spec_j.rot[ax]
                    if not lo <= vals[ax] <= hi:
                        errors.append(f"{where}.pose.{joint}: {_AXES[ax]}={vals[ax]:g} is outside the {joint} "
                                      f"{_AXES[ax]} limit {lo:g}..{hi:g}{_limit_hint(joint, ax)}")
            move = spec_j.move if spec_j is not None else 12.0
            for ax in range(3, len(vals)):
                if abs(vals[ax]) > move:
                    extra = "" if joint == "Root" else " (only Root moves far; other joints take small offsets)"
                    errors.append(f"{where}.pose.{joint}: {'xyz'[ax - 3]} offset {vals[ax]:g} studs is beyond "
                                  f"+-{move:g}{extra}")

    # consecutive keys of one joint must differ by < 180 degrees per axis (slerp takes the short way)
    if not broken:
        last_seen: dict[str, tuple[float, list[float]]] = {}
        for key in norm_keys:
            for joint, vals in key["pose"].items():
                if joint in last_seen:
                    t0, prev = last_seen[joint]
                    for ax in range(3):
                        if abs(vals[ax] - prev[ax]) >= 180:
                            errors.append(f"{joint} {_AXES[ax]} goes from {prev[ax]:g} to {vals[ax]:g} between "
                                          f"t={t0:g} and t={key['t']:g}: a change of 180 degrees or more between two "
                                          f"keys turns the short way round (the other way); add a key in between")
                last_seen[joint] = (key["t"], vals)
        if looped and len(norm_keys) > 1 and abs(norm_keys[-1]["t"] - length) <= 1e-9:
            first, final = norm_keys[0]["pose"], norm_keys[-1]["pose"]
            for joint in first:
                if joint in final:
                    a, b = first[joint] + [0.0] * (6 - len(first[joint])), final[joint] + [0.0] * (6 - len(final[joint]))
                    if any(abs(x - y) > 1e-3 for x, y in zip(a, b)):
                        errors.append(f"looped clip pops at the loop point: {joint} is {first[joint]} at t=0 but "
                                      f"{final[joint]} at t={length:g}; make them equal")

    # markers
    markers = spec.get("markers", [])
    norm_markers: list[dict] = []
    if markers is None:
        markers = []
    if not isinstance(markers, list):
        errors.append("markers must be a list of {t, name}")
        markers = []
    for i, m in enumerate(markers):
        where = f"markers[{i}]"
        if not isinstance(m, dict):
            errors.append(f"{where} must be an object {{t, name}}")
            continue
        for k in m:
            if k not in _MARKER_FIELDS:
                errors.append(f"{where}: unknown field {k!r}{_did_you_mean(k, _MARKER_FIELDS, _MARKER_ALIASES)}")
        mt, mn = m.get("t"), m.get("name")
        ok = True
        if not isinstance(mn, str) or not mn.strip() or len(mn) > 40:
            errors.append(f"{where} needs a name (1-40 characters), e.g. 'hit' or 'footstep'")
            ok = False
        if not _is_num(mt):
            errors.append(f"{where}.t must be a number of seconds")
            ok = False
        elif mt < 0 or mt > length + 1e-9:
            errors.append(f"{where} ({mn}) t={mt:g} is outside the clip (0..{length:g} s)")
            ok = False
        if ok:
            norm_markers.append({"t": _r(mt), "name": mn.strip()})
    norm_markers.sort(key=lambda m: (m["t"], m["name"]))

    if broken:
        return None, errors
    clip = {"name": clip_name if isinstance(clip_name, str) else "", "rig": rig_norm, "length": length,
            "looped": looped, "priority": priority, "keys": norm_keys, "markers": norm_markers}
    return clip, errors


# ---------------------------------------------------------------------------------------------------- Luau pack

def _lua_num(x: float) -> str:
    v = _r(x)
    if v == int(v) and abs(v) < 1e15:
        return str(int(v))
    return f"{v:.{DECIMALS}f}".rstrip("0").rstrip(".")


def _lua_key(s: str) -> str:
    return s if _IDENT_RE.fullmatch(s) and s not in _LUA_KEYWORDS else f"[{lua_quote(s)}]"


def clip_luau(clip: dict, indent: str = "\t") -> str:
    """One normalized clip as a Luau table literal (stable: fixed field order, joints in R15 order)."""
    i1, i2 = indent, indent * 2
    lines = ["{",
             f"{i1}name = {lua_quote(clip['name'])},",
             f"{i1}rig = {lua_quote(clip.get('rig', 'R15'))},",
             f"{i1}length = {_lua_num(clip['length'])},",
             f"{i1}looped = {'true' if clip['looped'] else 'false'},",
             f"{i1}priority = {lua_quote(clip['priority'])},",
             f"{i1}keys = {{"]
    for key in clip["keys"]:
        pose = ", ".join(f"{_lua_key(j)} = {{ {', '.join(_lua_num(x) for x in v)} }}"
                         for j, v in sorted(key["pose"].items(), key=lambda kv: _joint_order(kv[0])))
        lines.append(f"{i2}{{ t = {_lua_num(key['t'])}, ease = {lua_quote(key['ease'])}, pose = {{ {pose} }} }},")
    lines.append(f"{i1}}},")
    if clip["markers"]:
        lines.append(f"{i1}markers = {{")
        lines += [f"{i2}{{ t = {_lua_num(m['t'])}, name = {lua_quote(m['name'])} }}," for m in clip["markers"]]
        lines.append(f"{i1}}},")
    else:
        lines.append(f"{i1}markers = {{}},")
    lines.append("}")
    return "\n".join(lines)


def pack_luau(clips: dict[str, dict]) -> str:
    """The ClipPack module source: `return { [name] = clip, ... }`, clips sorted by name."""
    head = ("-- Generated by cybus-harness (author_clip) from clip_pack.json. Do not edit: re-author clips with\n"
            "-- author_clip. Kit.Anim loads this module on first use: Anim.load(character):play(\"<name>\").\n")
    if not clips:
        return head + "return {}\n"
    body = []
    for name in sorted(clips):
        text = clip_luau(clips[name]).replace("\n", "\n\t")
        body.append(f"\t[{lua_quote(name)}] = {text},")
    return head + "return {\n" + "\n".join(body) + "\n}\n"


class ClipPack:
    """A game's animation clips: ReplicatedStorage.Shared.ClipPack (what Kit.Anim loads) plus clip_pack.json at the
    workspace root (the source of truth, reloaded on construction). Every add / remove rewrites both."""

    def __init__(self, workspace: Workspace | str | Path) -> None:
        self.ws = workspace if isinstance(workspace, Workspace) else Workspace(Path(workspace))
        self.manifest = Path(self.ws.root) / MANIFEST_NAME
        self.clips: dict[str, dict] = {}
        self._load()

    def _load(self) -> None:
        try:
            data = json.loads(self.manifest.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return
        for name, spec in (data.get("clips") or {}).items() if isinstance(data, dict) else ():
            clip, errors = validate_clip(spec, name=name)
            if clip is None or errors:
                log.warning("clip_pack.json: dropping invalid clip %r: %s", name, "; ".join(errors[:3]))
                continue
            self.clips[name] = clip

    def add(self, spec: Any, name: str | None = None) -> dict:
        """Validate and add (or replace) a clip; raises ValueError listing every problem."""
        clip, errors = validate_clip(spec, name=name)
        if clip is None or errors:
            raise ValueError("invalid clip:\n" + "\n".join(errors))
        self.clips[clip["name"]] = clip
        self.write()
        return clip

    def remove(self, name: str) -> bool:
        if name not in self.clips:
            return False
        del self.clips[name]
        self.write()
        return True

    def names(self) -> list[str]:
        return sorted(self.clips)

    def get(self, name: str) -> dict | None:
        return self.clips.get(name)

    def __contains__(self, name: object) -> bool:
        return name in self.clips

    def __len__(self) -> int:
        return len(self.clips)

    def luau(self) -> str:
        return pack_luau(self.clips)

    def write(self) -> None:
        self.ws.write(PACK_PATH, self.luau())
        self.manifest.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.manifest.with_name(self.manifest.name + ".tmp")
        tmp.write_text(json.dumps({"version": 1, "pack": f"src/{PACK_PATH}",
                                   "clips": {n: self.clips[n] for n in sorted(self.clips)}},
                                  indent=1, sort_keys=True), encoding="utf-8")
        os.replace(tmp, self.manifest)


# ---------------------------------------------------------------------------------------------------- preview

SS = 2                           # render at 2x and downsample: smooth lines without an antialiasing API
VIEW_W, VIEW_H = 150, 214        # one view (front or side) of one frame, in output pixels
VIEW_GAP = 4
LABEL_H = 20
CELL_GAP = 12
MARGIN = 12
TITLE_H = 30
TIMELINE_H = 58
COLS = 4

BG = (22, 23, 27)
VIEW_BG = (33, 35, 42)
GROUND = (120, 126, 140)
TEXT = (232, 234, 240)
DIM = (140, 146, 160)
RIGHT_C = (255, 146, 40)
LEFT_C = (60, 158, 255)
TORSO_C = (214, 219, 230)
HEAD_C = (238, 240, 246)
OUTLINE = (9, 10, 13)
MARKER_C = (255, 212, 0)
KEY_C = (205, 210, 222)


def preview_size(frames: int = 8) -> tuple[int, int]:
    """Pixel size of preview(clip, frames) for an R15 clip."""
    frames = max(1, min(MAX_FRAMES, int(frames)))
    cols = min(frames, COLS)
    rows = math.ceil(frames / cols)
    cell_w = 2 * VIEW_W + VIEW_GAP
    return (2 * MARGIN + cols * cell_w + (cols - 1) * CELL_GAP,
            MARGIN + TITLE_H + rows * (VIEW_H + LABEL_H) + (rows - 1) * CELL_GAP + CELL_GAP + TIMELINE_H + MARGIN)


def _font(px: int) -> Any:
    try:
        return ImageFont.load_default(size=px)
    except TypeError:            # Pillow < 10.1: fixed-size bitmap font
        return ImageFont.load_default()


def _fit(draw: ImageDraw.ImageDraw, text: str, font: Any, max_w: float) -> str:
    if draw.textlength(text, font=font) <= max_w:
        return text
    while text and draw.textlength(text + "...", font=font) > max_w:
        text = text[:-1]
    return text + "..."


def _frame_times(clip: dict, frames: int) -> tuple[list[float], list[list[str]]]:
    """Evenly spaced times across the clip (a loop's end is its start, so loops stop one step short); each marker
    pulls the nearest free frame onto its exact time, so contact frames are shown exactly."""
    length, looped = clip["length"], clip["looped"]
    if frames == 1:
        times = [0.0]
    elif looped:
        times = [length * i / frames for i in range(frames)]
    else:
        times = [length * i / (frames - 1) for i in range(frames)]
    names: list[list[str]] = [[] for _ in times]
    snapped: dict[int, float] = {}
    for m in clip.get("markers", []):
        mt = 0.0 if looped and m["t"] >= length - 1e-9 else m["t"]
        for i in sorted(range(frames), key=lambda k: abs(times[k] - mt)):
            if i in snapped and abs(snapped[i] - mt) > 1e-9:
                continue
            snapped[i] = mt
            times[i] = mt
            names[i].append(m["name"])
            break
    return times, names


def _hull(points: list[tuple[float, float]]) -> list[tuple[float, float]]:
    pts = sorted(set(points))
    if len(pts) <= 2:
        return pts

    def cross(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])

    lower: list = []
    for p in pts:
        while len(lower) >= 2 and cross(lower[-2], lower[-1], p) <= 0:
            lower.pop()
        lower.append(p)
    upper: list = []
    for p in reversed(pts):
        while len(upper) >= 2 and cross(upper[-2], upper[-1], p) <= 0:
            upper.pop()
        upper.append(p)
    return lower[:-1] + upper[:-1]


def _project(view: str, p: np.ndarray) -> tuple[float, float, float]:
    """World point -> (screen x, screen y up, closeness to the camera). front: the camera faces the character, so
    its right hand is on screen left; side: the camera is at the character's right, so it faces screen right."""
    x, y, z = float(p[0]), float(p[1]), float(p[2])
    if view == "front":
        return -x, y, -z
    return -z, y, x


def _shade(color: tuple[int, int, int], k: float, base: tuple[int, int, int] = VIEW_BG) -> tuple[int, int, int]:
    return tuple(int(round(b + (c - b) * k)) for c, b in zip(color, base))  # type: ignore[return-value]


def _side_color(part: str, view: str) -> tuple[int, int, int]:
    color = RIGHT_C if part.startswith("Right") else LEFT_C
    if view == "side" and part.startswith("Left"):
        return _shade(color, 0.55)        # far side from a camera at the character's right
    return color


def _draw_figure(draw: ImageDraw.ImageDraw, world: dict[str, Frame], view: str, to_px, scale: float) -> None:
    items: list[tuple[float, int, str, Any]] = []
    for n, (part, half) in enumerate(_BOXES.items()):
        r, o = world[part]
        corners = [o + r @ np.array([sx * half[0], sy * half[1], sz * half[2]])
                   for sx in (-1, 1) for sy in (-1, 1) for sz in (-1, 1)]
        pts = [_project(view, c) for c in corners]
        items.append((_project(view, o)[2], n, "box", [to_px(p[0], p[1]) for p in pts]))
    for n, (part, (a, b)) in enumerate(_BONES.items(), start=10):
        pa, pb = _project(view, _at(world[part], a)), _project(view, _at(world[part], b))
        items.append(((pa[2] + pb[2]) / 2, n, "bone", (to_px(pa[0], pa[1]), to_px(pb[0], pb[1]), part)))
    head = world["Head"]
    hc = _project(view, head[1])
    items.append((hc[2], 99, "head", head))
    items.sort(key=lambda it: (it[0], it[1]))

    limb = max(3.0, 0.42 * scale)
    edge = 1.6 * SS
    for _, _, kind, data in items:
        if kind == "box":
            hull = _hull(data)
            draw.polygon(hull, fill=TORSO_C, outline=OUTLINE, width=int(edge))
        elif kind == "bone":
            (x0, y0), (x1, y1), part = data
            color = _side_color(part, view)
            for width, fill in ((limb + 2 * edge, OUTLINE), (limb, color)):
                draw.line([(x0, y0), (x1, y1)], fill=fill, width=int(round(width)))
                rr = width / 2
                for x, y in ((x0, y0), (x1, y1)):
                    draw.ellipse([x - rr, y - rr, x + rr, y + rr], fill=fill)
        else:
            r, o = data
            cx, cy = to_px(hc[0], hc[1])
            rad = HEAD_RADIUS * scale
            draw.ellipse([cx - rad, cy - rad, cx + rad, cy + rad], fill=HEAD_C, outline=OUTLINE, width=int(edge))
            nose_a = _project(view, _at(data, (0, -0.05, -HEAD_RADIUS * 0.55)))
            nose_b = _project(view, _at(data, (0, -0.05, -HEAD_RADIUS * 1.35)))
            draw.line([to_px(nose_a[0], nose_a[1]), to_px(nose_b[0], nose_b[1])], fill=OUTLINE,
                      width=int(round(max(2.0, 0.16 * scale))))
            for ex in (-0.24, 0.24):             # eyes, drawn only on the side facing the camera
                e = _project(view, _at(data, (ex, 0.12, -HEAD_RADIUS * 0.85)))
                if e[2] > hc[2] + 0.1:
                    x, y = to_px(e[0], e[1])
                    er = max(1.5, 0.07 * scale)
                    draw.ellipse([x - er, y - er, x + er, y + er], fill=OUTLINE)


def _trail_points(worlds: list[dict[str, Frame]]) -> dict[str, list[np.ndarray]]:
    out: dict[str, list[np.ndarray]] = {"RightHand": [], "LeftHand": [], "RightFoot": [], "LeftFoot": []}
    for w in worlds:
        for part in out:
            out[part].append(_at(w[part], _BONES[part][1]))
    return out


def preview(clip: dict, frames: int = 8) -> bytes:
    """A contact sheet PNG of the clip: `frames` evenly spaced times (markers snap the nearest frame onto their
    time and are highlighted), each as a front view and a side view of an R15 stick figure (right limbs orange,
    left limbs blue, head with a nose showing where it faces), faint trails of hands and feet over the whole clip
    (arcs), a ground line, and a timeline of keys, frames and markers. Clips for custom rigs get per-joint curves."""
    if clip.get("rig", "R15") != "R15":
        return _curves_sheet(clip)
    frames = max(1, min(MAX_FRAMES, int(frames)))
    length, looped = clip["length"], clip["looped"]
    chans = channels(clip)
    times, marker_names = _frame_times(clip, frames)
    frame_worlds = [fk_r15(sample_clip(clip, t, chans=chans)) for t in times]
    trail_n = 48
    trail_ts = [length * i / (trail_n if looped else trail_n - 1) for i in range(trail_n + (1 if looped else 0))]
    trail_worlds = [fk_r15(sample_clip(clip, t, chans=chans)) for t in trail_ts]
    trails = _trail_points(trail_worlds)

    # one scale for every view and frame, so motion reads as motion against a fixed ground line
    bounds = {v: [math.inf, -math.inf] for v in ("front", "side")}
    y_lo, y_hi = 0.0, 5.3
    for w in frame_worlds + trail_worlds + [fk_r15({})]:
        pts = list(skeleton_points(w).values())
        for part, half in _BOXES.items():
            r, o = w[part]
            pts += [o + r @ np.array([sx * half[0], sy * half[1], 0.0]) for sx in (-1, 1) for sy in (-1, 1)]
        for p in pts:
            for v in bounds:
                sx, sy, _ = _project(v, p)
                bounds[v][0] = min(bounds[v][0], sx)
                bounds[v][1] = max(bounds[v][1], sx)
            y_lo, y_hi = min(y_lo, float(p[1]) - 0.3), max(y_hi, float(p[1]) + 0.3)
        head = w["Head"][1]
        y_hi = max(y_hi, float(head[1]) + HEAD_RADIUS + 0.15)
    pad = 8
    x_span = max(4.6, max(b[1] - b[0] for b in bounds.values()) + 1.4)
    y_span = max(6.0, y_hi - y_lo + 0.3)
    scale = SS * min((VIEW_W - 2 * pad) / x_span, (VIEW_H - 2 * pad - 12) / y_span)
    x_mid = {v: (b[0] + b[1]) / 2 for v, b in bounds.items()}

    W, H = preview_size(frames)
    img = Image.new("RGB", (W * SS, H * SS), BG)
    draw = ImageDraw.Draw(img)
    f_title, f_label, f_small = _font(15 * SS), _font(12 * SS), _font(10 * SS)
    kind = "looped" if looped else "one-shot"
    title = f"{clip['name']}  {length:g}s {kind}  priority {clip['priority']}"
    legend = "front = facing you (its right on your left) | side = seen from its right, facing right | " \
             "orange = right limbs, blue = left"
    tw = draw.textlength(title, font=f_title)
    draw.text((MARGIN * SS, (MARGIN + 4) * SS), title, fill=TEXT, font=f_title)
    draw.text((MARGIN * SS + tw + 24 * SS, (MARGIN + 7) * SS),
              _fit(draw, legend, f_small, W * SS - MARGIN * SS * 2 - tw - 24 * SS), fill=DIM, font=f_small)

    cols = min(frames, COLS)
    cell_w = 2 * VIEW_W + VIEW_GAP
    for i, (t, world) in enumerate(zip(times, frame_worlds)):
        r, c = divmod(i, cols)
        x0 = (MARGIN + c * (cell_w + CELL_GAP)) * SS
        y0 = (MARGIN + TITLE_H + r * (VIEW_H + LABEL_H + CELL_GAP)) * SS
        for vi, view in enumerate(("front", "side")):
            vx = x0 + vi * (VIEW_W + VIEW_GAP) * SS
            box = [vx, y0, vx + VIEW_W * SS - 1, y0 + VIEW_H * SS - 1]
            draw.rectangle(box, fill=VIEW_BG)
            ground_px = y0 + VIEW_H * SS - pad * SS - (0 - y_lo) * scale

            def to_px(sx: float, sy: float, _vx=vx, _v=view, _g=ground_px) -> tuple[float, float]:
                return _vx + VIEW_W * SS / 2 + (sx - x_mid[_v]) * scale, _g - sy * scale

            draw.line([(vx + 4 * SS, ground_px), (vx + (VIEW_W - 4) * SS, ground_px)], fill=GROUND, width=2 * SS)
            for part, pts in trails.items():
                xy = [to_px(*_project(view, p)[:2]) for p in pts]
                draw.line(xy, fill=_shade(_side_color(part, view), 0.4), width=SS)
            _draw_figure(draw, world, view, to_px, scale)
            draw.text((vx + 5 * SS, y0 + 3 * SS), view, fill=DIM, font=f_small)
        if marker_names[i]:
            draw.rectangle([x0 - 3 * SS, y0 - 3 * SS, x0 + cell_w * SS + 2 * SS, y0 + (VIEW_H + LABEL_H) * SS],
                           outline=MARKER_C, width=2 * SS)
        label = f"#{i + 1}  t={t:.2f}s"
        draw.text((x0 + 2 * SS, y0 + (VIEW_H + 3) * SS), label, fill=TEXT, font=f_label)
        if marker_names[i]:
            lw = draw.textlength(label, font=f_label)
            draw.text((x0 + 2 * SS + lw + 10 * SS, y0 + (VIEW_H + 3) * SS),
                      _fit(draw, "marker: " + ", ".join(marker_names[i]), f_label, cell_w * SS - lw - 16 * SS),
                      fill=MARKER_C, font=f_label)

    _draw_timeline(draw, clip, times, W, H, f_small)
    out = img.resize((W, H), Image.LANCZOS)
    buf = io.BytesIO()
    out.save(buf, format="PNG")
    return buf.getvalue()


def _draw_timeline(draw: ImageDraw.ImageDraw, clip: dict, times: list[float], W: int, H: int, font: Any) -> None:
    length = clip["length"]
    top = (H - MARGIN - TIMELINE_H) * SS
    x0, x1 = (MARGIN + 64) * SS, (W - MARGIN - 40) * SS
    y = top + 26 * SS

    def tx(t: float) -> float:
        return x0 + (x1 - x0) * (t / length)

    draw.text((MARGIN * SS, y - 20 * SS), "keys |", fill=KEY_C, font=font)
    draw.text((MARGIN * SS, y - 7 * SS), "frames o", fill=DIM, font=font)
    draw.text((MARGIN * SS, y + 6 * SS), "markers ^", fill=MARKER_C, font=font)
    draw.line([(x0, y), (x1, y)], fill=GROUND, width=2 * SS)
    draw.text((x0 - 4 * SS, y + 12 * SS), "0", fill=DIM, font=font)
    draw.text((x1 - 8 * SS, y + 12 * SS), f"{length:g}s", fill=DIM, font=font)
    for key in clip["keys"]:
        x = tx(key["t"])
        draw.line([(x, y - 9 * SS), (x, y + 9 * SS)], fill=KEY_C, width=2 * SS)
    for i, t in enumerate(times):
        x = tx(t)
        rr = 3 * SS
        draw.ellipse([x - rr, y - 16 * SS - rr, x + rr, y - 16 * SS + rr], outline=DIM, width=SS)
        draw.text((x + 4 * SS, y - 24 * SS), str(i + 1), fill=DIM, font=font)
    for m in clip.get("markers", []):
        x = tx(m["t"])
        s = 5 * SS
        draw.polygon([(x, y + 3 * SS), (x - s, y + 3 * SS + 2 * s), (x + s, y + 3 * SS + 2 * s)], fill=MARKER_C)
        draw.text((x + s + 2 * SS, y + 12 * SS), m["name"], fill=MARKER_C, font=font)


def _curves_sheet(clip: dict) -> bytes:
    """Custom rigs have no known skeleton: plot each joint's rx / ry / rz over time (keys as dots, markers as
    lines), so spacing and easing are still visible."""
    chans = channels(clip)
    joints = sorted(chans)
    cols = 3
    plot_w, plot_h = 404, 116
    rows = max(1, math.ceil(len(joints) / cols))
    W = 2 * MARGIN + cols * plot_w + (cols - 1) * CELL_GAP
    H = MARGIN + TITLE_H + rows * (plot_h + CELL_GAP) + MARGIN
    img = Image.new("RGB", (W * SS, H * SS), BG)
    draw = ImageDraw.Draw(img)
    f_title, f_small = _font(15 * SS), _font(10 * SS)
    length, looped = clip["length"], clip["looped"]
    draw.text((MARGIN * SS, (MARGIN + 4) * SS), f"{clip['name']}  {length:g}s {'looped' if looped else 'one-shot'}  "
              f"custom rig: joint curves (rx red, ry green, rz blue; dots = keys, yellow = markers)",
              fill=TEXT, font=f_title)
    colors = ((255, 90, 90), (90, 220, 120), (90, 160, 255))
    n = 120
    for idx, joint in enumerate(joints):
        r, c = divmod(idx, cols)
        x0 = (MARGIN + c * (plot_w + CELL_GAP)) * SS
        y0 = (MARGIN + TITLE_H + r * (plot_h + CELL_GAP)) * SS
        draw.rectangle([x0, y0, x0 + plot_w * SS, y0 + plot_h * SS], fill=VIEW_BG)
        draw.text((x0 + 5 * SS, y0 + 3 * SS), joint, fill=TEXT, font=f_small)
        ch = chans[joint]
        ts = [length * i / (n - 1) for i in range(n)]
        vals = np.array([quat_euler(sample_channel(ch, t, looped, length)[0]) for t in ts])
        vals = np.degrees(np.unwrap(np.radians(vals), axis=0))
        lo, hi = float(min(vals.min(), -10)), float(max(vals.max(), 10))
        top, bot = y0 + 18 * SS, y0 + (plot_h - 6) * SS

        def px(t: float, v: float, _x0=x0, _lo=lo, _hi=hi, _top=top, _bot=bot) -> tuple[float, float]:
            return _x0 + 6 * SS + (plot_w - 12) * SS * t / length, _bot - (v - _lo) / (_hi - _lo) * (_bot - _top)

        draw.line([px(0, 0), px(length, 0)], fill=GROUND, width=SS)
        for m in clip.get("markers", []):
            draw.line([px(m["t"], lo), px(m["t"], hi)], fill=MARKER_C, width=SS)
        for ax in range(3):
            draw.line([px(t, v) for t, v in zip(ts, vals[:, ax])], fill=colors[ax], width=2 * SS)
            for kt, kq in zip(ch.t, ch.q):
                x, y = px(kt, quat_euler(kq)[ax])
                draw.ellipse([x - 3 * SS, y - 3 * SS, x + 3 * SS, y + 3 * SS], fill=colors[ax])
    out = img.resize((W, H), Image.LANCZOS)
    buf = io.BytesIO()
    out.save(buf, format="PNG")
    return buf.getvalue()


# ---------------------------------------------------------------------------------------------------- tools

AUTHOR_HELP = (
    "Author a keyframe animation clip for Kit.Anim (custom character animation, no uploads). Validates it (every "
    "problem at once), packs it into ReplicatedStorage.Shared.ClipPack, and returns a stick-figure contact sheet "
    "(front + side view per frame, hand/foot arcs, timeline) so you SEE the poses; revise and re-author until they "
    "read. spec = {length: seconds, looped: bool, priority: core|idle|movement|action, keys: [{t, ease, pose: "
    "{Joint: [rx, ry, rz] or [rx, ry, rz, px, py, pz]}}], markers: [{t, name}]}. Degrees about the character's own "
    "axes at rest (X right, Y up, Z back; it faces -Z), relative to the rest pose (all zeros = standing, arms down). "
    "rx+ swings a hanging limb FORWARD and tips torso / head BACK; knees bend with NEGATIVE rx, elbows with "
    "POSITIVE rx; ry+ turns toward the character's left; rz+ swings a hanging limb toward the character's right "
    "(RightShoulder rz 90 = arm straight out to the side; LeftShoulder uses rz -90). Only Root moves far "
    "(px, py, pz: jumps, crouches). ease (into the key): linear or sine|quad|cubic|back|expo, + In (accelerate into "
    "the key: impacts) / Out (decelerate into it: settles, overshoot with backOut). A joint left out of a key "
    "interpolates between the keys that pose it (offset keys per joint = overlap). R15 joints: Root, Waist, Neck, "
    "Right/Left Shoulder, Elbow, Wrist, Hip, Knee, Ankle. Full spec and examples: playbook animation_spec.")


def _usage(clip: dict) -> str:
    name = clip["name"]
    lines = ["Play it (client-side; ReplicatedStorage.Kit.Anim):",
             "  local Anim = require(ReplicatedStorage.Kit.Anim)",
             "  local rig = Anim.load(character)",
             f"  local track = rig:play({lua_quote(name)}, {{ fade = 0.15 }})"]
    for m in clip["markers"][:3]:
        lines.append(f"  track.Marker({lua_quote(m['name'])}):Connect(function() --[[ sound / VFX on this frame ]] "
                     "end)")
    if not clip["looped"]:
        lines.append("  track.Ended:Connect(function() end)   -- after it fades out")
    else:
        lines.append("  -- looped: rig:play() again returns the same track; stop with track:stop(0.2)")
    return "\n".join(lines)


def _summary(clip: dict) -> str:
    joints = {j for k in clip["keys"] for j in k["pose"]}
    marks = ", ".join(f"{m['name']}@{m['t']:g}s" for m in clip["markers"]) or "none"
    return (f"{clip['name']}: {clip['length']:g}s {'looped' if clip['looped'] else 'one-shot'}, priority "
            f"{clip['priority']}, {len(clip['keys'])} keys, {len(joints)} joints, markers: {marks}")


def anim_tools(packs: ClipPack | Workspace, art_dir: Path | str) -> list[Tool]:
    """author_clip / list_clips for builders. `packs` is the game's ClipPack (or its Workspace); previews are saved
    under art_dir/clips/<name>.png."""
    pack = packs if isinstance(packs, ClipPack) else ClipPack(packs)
    art = Path(art_dir)

    async def author_clip(name: str, spec: Any, frames: int = 8) -> ToolResult:
        notes: list[str] = []
        try:
            frames = max(2, min(MAX_FRAMES, int(frames)))
        except (TypeError, ValueError):
            frames = 8
        clip, errors = validate_clip(spec, name=name, notes=notes)
        if errors:
            text = (f"ERROR: clip {name!r} was NOT packed. Fix all {len(errors)} problem(s), then call author_clip "
                    f"again with the whole clip:\n" + "\n".join(f"{i + 1}. {e}" for i, e in enumerate(errors)))
            images = []
            if clip is not None:
                try:
                    images = [preview(clip, frames)]
                    text += "\n(The attached preview shows the clip as written, problems included.)"
                except Exception as e:  # noqa: BLE001 - the errors above are the answer; the picture is a bonus
                    log.warning("preview of invalid clip %r failed: %s", name, e)
            return ToolResult(text=text, images=images, data={"ok": False, "errors": errors})
        png = preview(clip, frames)
        existed = clip["name"] in pack
        pack.add(clip)
        path = art / "clips" / f"{clip['name']}.png"
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(png)
        except OSError as e:
            log.warning("could not save the preview of %r: %s", clip["name"], e)
        text = [f"{'Replaced' if existed else 'Packed'} {_summary(clip)}.",
                f"It is in src/{PACK_PATH} (ReplicatedStorage.Shared.ClipPack); sync to use it in Studio.",
                "LOOK at the preview: do the key poses read as silhouettes (front and side)? anticipation before the "
                "big move, follow-through after it, clean hand / foot arcs, feet on the ground line when they should "
                "be? If not, fix the poses and author the clip again.",
                _usage(clip)]
        contact = contact_report(clip)
        if contact:
            hint = (" To bend planted legs, lower Root py and keep each foot flat with Ankle rx = -(Hip rx + Knee rx)."
                    if any("into the ground" in c for c in contact) else "")
            text.insert(1, "Feet: " + "; ".join(contact) + "." + hint)
        late = sorted({j for k in clip["keys"][1:] for j in k["pose"]} - set(clip["keys"][0]["pose"]),
                      key=_joint_order)
        if late and not clip["looped"]:
            notes.append(f"not posed at t=0, so they start from rest: {', '.join(late)}")
        if notes:
            text.insert(1, "Notes: " + "; ".join(notes))
        return ToolResult(text="\n".join(text), images=[png],
                          data={"ok": True, "clip": clip, "preview": str(path), "pack": f"src/{PACK_PATH}"})

    async def list_clips() -> ToolResult:
        names = pack.names()
        if not names:
            return ToolResult(text="no clips yet; author one with author_clip", data={"clips": []})
        lines = [f"{len(names)} clip(s) in ReplicatedStorage.Shared.ClipPack:"]
        lines += [f"- {_summary(pack.clips[n])}" for n in names]
        lines.append('Play: local Anim = require(ReplicatedStorage.Kit.Anim); Anim.load(character):play("<name>")')
        return ToolResult(text="\n".join(lines), data={"clips": names})

    spec_schema = {
        "type": "object",
        "description": "The clip: {length, looped, priority, keys: [{t, ease, pose: {Joint: [rx, ry, rz]}}], "
                       "markers: [{t, name}]}",
        "properties": {
            "length": {"type": "number", "description": "seconds"},
            "looped": {"type": "boolean"},
            "priority": {"type": "string", "enum": list(PRIORITIES)},
            "rig": {"type": "string", "enum": list(RIGS), "description": "R15 (default) or custom"},
            "keys": {"type": "array", "items": {"type": "object", "properties": {
                "t": {"type": "number"}, "ease": {"type": "string"},
                "pose": {"type": "object", "description": "{JointName: [rx, ry, rz] or [rx, ry, rz, px, py, pz]}"}}}},
            "markers": {"type": "array", "items": {"type": "object", "properties": {
                "t": {"type": "number"}, "name": {"type": "string"}}}},
        },
    }
    return [
        Tool("author_clip", AUTHOR_HELP,
             {"type": "object", "additionalProperties": False, "required": ["name", "spec"],
              "properties": {"name": {"type": "string", "description": "clip name, e.g. 'sword_slash'"},
                             "spec": spec_schema,
                             "frames": {"type": "integer", "minimum": 2, "maximum": MAX_FRAMES,
                                        "description": "preview frames (default 8)"}}},
             author_clip, mutating=True),
        Tool("list_clips", "List the game's animation clips (name, length, loop, priority, markers).",
             {"type": "object", "additionalProperties": False, "properties": {}}, list_clips),
    ]


__all__ = ["EASES", "PRIORITIES", "R15", "R15_JOINTS", "R15_ORDER", "ClipPack", "JointSpec", "anim_tools",
           "channels", "clip_luau", "ease", "euler_pose", "euler_quat", "fk_r15", "pack_luau", "parse_ease",
           "pose_points", "preview", "preview_size", "quat_euler", "quat_matrix", "quat_mul", "sample_channel",
           "sample_clip", "skeleton_points", "slerp", "validate_clip"]

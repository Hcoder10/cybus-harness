"""Keyframe animation as data: validation, packing, previews, FK conventions, the playbook's examples, the author
tools, and the Luau side: AnimCore (sampling, easing, blending, track timing) cross-checked against the Python
implementation under the standalone Luau runtime, and a smoke test of Kit.Anim itself against a small fake of the
Roblox APIs it uses. The Luau tests skip when luau.exe is not available. No network, no Studio.
"""
from __future__ import annotations

import asyncio
import io
import json
import math
import os
import re
import shutil
import subprocess
from pathlib import Path

import numpy as np
import pytest
from PIL import Image

from harness.tools import anim as A
from harness.tools.anim import ClipPack, anim_tools, preview, preview_size, validate_clip
from harness.tools.workspace import Workspace, lua_long_string

ROOT = Path(__file__).resolve().parents[1]
KIT = ROOT / "harness" / "kit"
PLAYBOOK = ROOT / "harness" / "playbooks" / "animation_spec.md"
PNG_MAGIC = b"\x89PNG\r\n\x1a\n"


def _luau_exe() -> str | None:
    for c in (os.environ.get("HARNESS_LUAU", ""), shutil.which("luau") or "",
              str(Path.home() / "brickformer" / "tools" / "luau" / "luau.exe")):
        if c and Path(c).exists():
            return c
    return None


LUAU = _luau_exe()
needs_luau = pytest.mark.skipif(LUAU is None, reason="standalone luau runtime not found")


def run_luau(folder: Path, files: dict[str, str], main: str, timeout: float = 120) -> str:
    """Write files into folder (with AnimCore / Spring from the kit), run main under luau.exe, return stdout."""
    folder.mkdir(parents=True, exist_ok=True)
    for name in ("AnimCore.luau", "Spring.luau"):
        shutil.copy(KIT / name, folder / name)
    for name, text in files.items():
        (folder / name).write_text(text, encoding="utf-8")
    r = subprocess.run([LUAU, main], cwd=folder, capture_output=True, text=True, timeout=timeout)
    assert r.returncode == 0, f"luau failed ({r.returncode}):\n{r.stdout[-3000:]}\n{r.stderr[-3000:]}"
    return r.stdout


def clip_of(spec: dict, name: str) -> dict:
    clip, errors = validate_clip(spec, name=name)
    assert not errors, errors
    return clip


def still(pose: dict, length: float = 1.0, looped: bool = False) -> dict:
    """A clip that holds one pose."""
    return {"length": length, "looped": looped, "keys": [{"t": 0, "pose": pose}, {"t": length, "pose": pose}]}


WAVE = {"length": 0.8, "looped": False, "priority": "action",
        "keys": [{"t": 0, "pose": {"RightShoulder": [0, 0, 5], "RightElbow": [10, 0, 0]}},
                 {"t": 0.3, "ease": "quadOut", "pose": {"RightShoulder": [-40, 0, 20], "RightElbow": [90, 0, 0]}},
                 {"t": 0.4, "ease": "expoIn", "pose": {"RightShoulder": [110, 0, 10], "RightElbow": [15, 0, 0]}},
                 {"t": 0.8, "ease": "sine", "pose": {"RightShoulder": [0, 0, 5], "RightElbow": [10, 0, 0]}}],
        "markers": [{"t": 0.4, "name": "hit"}]}


# ---------------------------------------------------------------------------------------------------- math

def _rx(a):
    c, s = math.cos(math.radians(a)), math.sin(math.radians(a))
    return np.array([[1, 0, 0], [0, c, -s], [0, s, c]])


def _ry(a):
    c, s = math.cos(math.radians(a)), math.sin(math.radians(a))
    return np.array([[c, 0, s], [0, 1, 0], [-s, 0, c]])


def _rz(a):
    c, s = math.cos(math.radians(a)), math.sin(math.radians(a))
    return np.array([[c, -s, 0], [s, c, 0], [0, 0, 1]])


@pytest.mark.parametrize("angles", [(30, 0, 0), (0, 45, 0), (0, 0, -60), (20, -35, 50), (170, 10, -100)])
def test_euler_is_cframe_angles_order(angles):
    """rotation = CFrame.Angles(rx, ry, rz) = Rx @ Ry @ Rz, and quat_euler inverts it."""
    q = A.euler_quat(*angles)
    assert np.allclose(A.quat_matrix(q), _rx(angles[0]) @ _ry(angles[1]) @ _rz(angles[2]), atol=1e-12)
    back = A.quat_euler(q)
    assert np.allclose(A.quat_matrix(A.euler_quat(*back)), A.quat_matrix(q), atol=1e-9)


def test_eases_hit_the_keys_and_back_overshoots():
    for name in A.EASES:
        assert abs(A.ease(name, 0.0)) < 1e-12 and abs(A.ease(name, 1.0) - 1) < 1e-12, name
        assert -0.2 < A.ease(name, 0.5) < 1.2, name
    assert max(A.ease("backOut", a / 100) for a in range(101)) > 1.05          # past the key, then back
    assert min(A.ease("backIn", a / 100) for a in range(101)) < -0.05          # pulls back first
    assert A.ease("quadIn", 0.25) < 0.25 < A.ease("quadOut", 0.25)            # In accelerates, Out decelerates
    q = A.slerp(A.euler_quat(0, 0, 0), A.euler_quat(90, 0, 0), 0.5)
    assert np.allclose(q, A.euler_quat(45, 0, 0))


# ---------------------------------------------------------------------------------------------------- validation

def test_valid_clip_is_normalized():
    clip, errors = validate_clip({"length": 1, "keys": [
        {"t": 0, "pose": {"Waist": [0, 0, 0]}},
        {"t": 0.5, "ease": "QuadOut", "pose": {"Waist": {"rx": -10.123456}, "Root": [0, 0, 0, 0, -0.2, 0]}},
        {"t": 1, "pose": {"Waist": [0, 0, 0], "Root": [0, 0, 0, 0, 0, 0]}}]}, name="bow")
    assert errors == []
    assert clip["priority"] == "action" and clip["looped"] is False and clip["rig"] == "R15"
    assert [k["ease"] for k in clip["keys"]] == ["sine", "quadOut", "sine"]
    assert clip["keys"][1]["pose"] == {"Root": [0, 0, 0, 0, -0.2, 0], "Waist": [-10.1235, 0, 0]}
    assert clip["keys"][2]["pose"]["Root"] == [0, 0, 0]              # all-zero offsets collapse to 3 values
    assert list(clip["keys"][1]["pose"]) == ["Root", "Waist"]          # R15 order
    looped, _ = validate_clip(still({"Neck": [5, 0, 0]}, looped=True), name="n")
    assert looped["priority"] == "idle"


def _bad(**changes) -> dict:
    spec = json.loads(json.dumps(WAVE))
    for path, value in changes.items():
        target = spec
        parts = path.split("__")
        for p in parts[:-1]:
            target = target[int(p)] if p.isdigit() else target[p]
        last = parts[-1]
        if value is _DELETE:
            del target[int(last) if last.isdigit() else last]
        else:
            target[int(last) if last.isdigit() else last] = value
    return spec


_DELETE = object()

ERROR_CASES = {
    "unknown joint": (_bad(keys__1__pose__RightShouldr=[1, 2, 3]), ["unknown joint 'RightShouldr'",
                                                                    "did you mean 'RightShoulder'", "R15 joints:"]),
    "part instead of joint": (_bad(keys__1__pose__RightUpperArm=[1, 2, 3]), ["the joint that moves it is 'RightShoulder'"]),
    "R6 name": (_bad(**{"keys__1__pose__Right Shoulder": [1, 2, 3]}), ["did you mean 'RightShoulder'"]),
    "keys out of order": (_bad(keys__2__t=0.2), ["keys out of order", "keys[2]"]),
    "duplicate time": (_bad(keys__2__t=0.3), ["keys out of order", "same t"]),
    "t beyond length": (_bad(keys__3__t=0.9), ["beyond length (0.8 s)"]),
    "negative t": (_bad(keys__1__t=-0.1), ["negative"]),
    "missing t=0 key": (_bad(keys__0__t=0.05), ["missing t=0 key"]),
    "knee bent forward": (_bad(keys__1__pose__RightKnee=[60, 0, 0]),
                          ["RightKnee: rx=60 is outside the RightKnee rx limit -160..5", "NEGATIVE"]),
    "left arm with the right arm's sign": (_bad(keys__1__pose__LeftShoulder=[0, 0, 120]),
                                           ["LeftShoulder rz limit -190..60", "rz- raises it"]),
    "elbow hyperextended": (_bad(keys__1__pose__RightElbow=[-40, 0, 0]), ["RightElbow rx limit -5..155", "POSITIVE"]),
    "unknown ease": (_bad(keys__1__ease="quadd"), ["ease 'quadd' is not an ease", "did you mean 'quad'"]),
    "unsupported ease": (_bad(keys__1__ease="bounceOut"), ["bounce is not supported"]),
    "unknown priority": (_bad(priority="high"), ["priority 'high' must be one of core, idle, movement, action"]),
    "wrong arity": (_bad(keys__1__pose__RightElbow=[90, 0]), ["has 2 numbers"]),
    "not numbers": (_bad(keys__1__pose__RightElbow=["90", 0, 0]), ["finite numbers"]),
    "NaN": (_bad(keys__1__pose__RightElbow=[float("nan"), 0, 0]), ["finite numbers"]),
    "missing length": (_bad(length=_DELETE), ["length is required"]),
    "unknown field": (_bad(loop=True), ["unknown field 'loop'", "did you mean 'looped'"]),
    "unknown key field": (_bad(keys__1__time=0.3), ["unknown field 'time'", "did you mean 't'"]),
    "marker outside": (_bad(markers__0__t=2.0), ["markers[0] (hit) t=2 is outside the clip"]),
    "marker without a name": (_bad(markers__0__name=""), ["markers[0] needs a name"]),
    "turn of 180 or more": (_bad(keys__2__pose__RightShoulder=[160, 0, 10]),
                            ["RightShoulder rx goes from -40 to 160", "add a key in between"]),
    "offset on a limb": (_bad(keys__1__pose__RightElbow=[90, 0, 0, 0, 2, 0]), ["only Root moves far"]),
    "root flies away": (_bad(keys__1__pose__Root=[0, 0, 0, 0, 20, 0]), ["offset 20 studs is beyond +-12"]),
    "bad name": (_bad(), ["name '9 lives!'"]),
}


@pytest.mark.parametrize("case", sorted(ERROR_CASES))
def test_each_error_class(case):
    spec, expected = ERROR_CASES[case]
    clip, errors = validate_clip(spec, name="9 lives!" if case == "bad name" else "wave")
    text = "\n".join(errors)
    assert errors, case
    for piece in expected:
        assert piece in text, f"{case}: {piece!r} not in:\n{text}"


def test_looped_clip_errors():
    loop = {"length": 1, "looped": True, "keys": [{"t": 0, "pose": {"Neck": [0, 0, 0]}},
                                                  {"t": 0.6, "pose": {"Neck": [10, 0, 0]}}]}
    _, errors = validate_clip(loop, name="nod")
    assert any("missing t=length key" in e for e in errors)
    loop["keys"].append({"t": 1, "pose": {"Neck": [5, 0, 0]}})
    _, errors = validate_clip(loop, name="nod")
    assert any("pops at the loop point: Neck" in e for e in errors)
    loop["keys"][-1]["pose"]["Neck"] = [0, 0, 0]
    assert validate_clip(loop, name="nod")[1] == []


def test_every_problem_at_once_and_what_comes_back():
    spec = _bad(keys__1__pose__RightKnee=[60, 0, 0], keys__1__ease="quadd", priority="urgent", loop=True)
    clip, errors = validate_clip(spec, name="wave")
    assert len(errors) >= 4
    assert clip is None                      # a bad ease cannot be sampled: too broken to preview
    clip, errors = validate_clip(_bad(keys__1__pose__RightKnee=[60, 0, 0], priority="urgent"), name="wave")
    assert len(errors) == 2 and clip is not None and clip["keys"][1]["pose"]["RightKnee"] == [60, 0, 0]
    notes: list[str] = []
    clip, errors = validate_clip(_bad(keys__1__ease="easeOutBack"), name="wave", notes=notes)
    assert errors == [] and clip["keys"][1]["ease"] == "backOut" and "read as 'backOut'" in notes[0]
    clip, errors = validate_clip(json.dumps(WAVE), name="wave")              # a JSON string works too
    assert errors == [] and clip["markers"] == [{"t": 0.4, "name": "hit"}]
    assert validate_clip("{not json", name="x")[1][0].startswith("spec is not valid JSON")
    assert validate_clip([1, 2], name="x")[0] is None


def test_custom_rigs_take_any_joint_names():
    spec = still({"Right Shoulder": [0, 0, 300 - 200], "TailBase": [10, 0, 0]}) | {"rig": "custom"}
    clip, errors = validate_clip(spec, name="tail_wag")
    assert errors == [] and clip["rig"] == "custom"
    assert validate_clip(spec | {"rig": "R15"}, name="tail_wag")[1]
    png = preview(clip)
    assert png.startswith(PNG_MAGIC)


@pytest.mark.parametrize("value, expected", [("quadOut", "quadOut"), ("QuadOut", "quadOut"), ("easeInQuad", "quadIn"),
                                             ("easeInOutSine", "sine"), ("out-back", "backOut"), ("Linear", "linear"),
                                             ("expoIn", "expoIn"), ("exponentialOut", "expoOut"), ("bounce", None),
                                             ("quartIn", None), (3, None)])
def test_parse_ease(value, expected):
    assert A.parse_ease(value) == expected


# ---------------------------------------------------------------------------------------------------- sampling

def test_sampling_follows_each_joints_own_keys():
    clip = clip_of({"length": 1, "keys": [
        {"t": 0, "pose": {"Waist": [0, 0, 0], "Neck": [0, 0, 0]}},
        {"t": 0.5, "ease": "linear", "pose": {"Waist": [-20, 0, 0]}},           # Neck not here: it keeps moving
        {"t": 1, "ease": "linear", "pose": {"Waist": [0, 0, 0], "Neck": [30, 0, 0]}}]}, "offset")
    pose = A.sample_clip(clip, 0.5)
    assert np.allclose(A.quat_euler(pose["Waist"][0]), (-20, 0, 0), atol=1e-9)
    assert np.allclose(A.quat_euler(pose["Neck"][0]), (15, 0, 0), atol=1e-9)
    late = clip_of({"length": 1, "keys": [{"t": 0, "pose": {"Waist": [0, 0, 0]}},
                                          {"t": 0.5, "ease": "linear", "pose": {"Neck": [20, 0, 0]}},
                                          {"t": 1, "pose": {"Waist": [0, 0, 0]}}]}, "late")
    assert np.allclose(A.quat_euler(A.sample_clip(late, 0.25)["Neck"][0]), (10, 0, 0), atol=1e-9)  # from rest
    assert np.allclose(A.quat_euler(A.sample_clip(late, 0.9)["Neck"][0]), (20, 0, 0), atol=1e-9)   # holds
    loop = clip_of({"length": 1, "looped": True, "keys": [
        {"t": 0, "pose": {"Waist": [0, 0, 0]}},
        {"t": 0.25, "ease": "linear", "pose": {"Neck": [10, 0, 0]}},
        {"t": 0.75, "ease": "linear", "pose": {"Neck": [-10, 0, 0]}},
        {"t": 1, "pose": {"Waist": [0, 0, 0]}}]}, "loop")
    # the Neck curve wraps from its last key (0.75) round to its first (0.25 + 1)
    assert np.allclose(A.quat_euler(A.sample_clip(loop, 0.0)["Neck"][0]), (-0, 0, 0), atol=1e-9)
    assert np.allclose(A.quat_euler(A.sample_clip(loop, 0.875)["Neck"][0]), (-5, 0, 0), atol=1e-9)
    assert np.allclose(A.quat_euler(A.sample_clip(loop, 1.125)["Neck"][0]), (5, 0, 0), atol=1e-9)


# ---------------------------------------------------------------------------------------------------- FK conventions

REST = A.pose_points({})


def test_rest_pose_proportions():
    assert abs(REST["Head"][1] - 4.5) < 1e-9 and abs(REST["RightShoulder"][1] - 3.763) < 1e-9
    assert all(abs(h) < 1e-9 for h in A.sole_heights(REST).values())
    assert REST["RightHandTip"][0] > 1.2 and REST["LeftHandTip"][0] < -1.2   # X is the character's right
    assert REST["Nose"][2] < REST["Head"][2]                                    # it faces -Z


def _moved(pose: dict, point: str) -> np.ndarray:
    return A.pose_points(pose)[point] - REST[point]


FK_CLAIMS = [
    # (pose, point, check) - the sign conventions stated in animation_spec.md
    ({"RightShoulder": [90, 0, 0]}, "RightHandTip", lambda p, d: p[2] < -1.5 and abs(p[1] - 3.76) < 0.1),
    ({"RightShoulder": [180, 0, 0]}, "RightHandTip", lambda p, d: p[1] > 5.3),
    ({"RightShoulder": [-50, 0, 0]}, "RightHandTip", lambda p, d: d[2] > 1.0),
    ({"RightShoulder": [0, 0, 90]}, "RightHandTip", lambda p, d: p[0] > 2.5 and d[1] > 2),
    ({"LeftShoulder": [0, 0, -90]}, "LeftHandTip", lambda p, d: p[0] < -2.5 and d[1] > 2),
    ({"RightShoulder": [90, 0, -20]}, "RightHandTip", lambda p, d: p[2] < -1.5 and p[0] < 1.0),
    ({"RightShoulder": [90, 0, 90], "RightElbow": [100, 0, 0]}, "RightHandTip",
     lambda p, d: p[1] > 4.6 and p[0] > 1.3),
    ({"LeftShoulder": [90, 0, -90], "LeftElbow": [100, 0, 0]}, "LeftHandTip", lambda p, d: p[1] > 4.6 and p[0] < -1.3),
    ({"RightElbow": [90, 0, 0]}, "RightHandTip", lambda p, d: d[2] < -0.8 and d[1] > 0.5),
    ({"RightHip": [90, 0, 0]}, "RightAnkle", lambda p, d: p[2] < -1.5),
    ({"RightHip": [0, 0, 40]}, "RightAnkle", lambda p, d: d[0] > 0.8),
    ({"LeftHip": [0, 0, -40]}, "LeftAnkle", lambda p, d: d[0] < -0.8),
    ({"RightKnee": [-90, 0, 0]}, "RightAnkle", lambda p, d: d[2] > 0.8 and d[1] > 0.8),
    ({"RightAnkle": [30, 0, 0]}, "RightToe", lambda p, d: d[1] > 0.2),
    ({"RightAnkle": [0, 30, 0]}, "RightToe", lambda p, d: d[0] < -0.2),
    ({"Waist": [-40, 0, 0]}, "Head", lambda p, d: d[2] < -1.0),
    ({"Waist": [0, 0, 20]}, "Head", lambda p, d: d[0] < -0.3),
    ({"Waist": [0, 45, 0]}, "RightShoulder", lambda p, d: d[2] < -0.5),
    ({"Neck": [0, 45, 0]}, "Nose", lambda p, d: p[0] < -0.3),
    ({"Neck": [-30, 0, 0]}, "Nose", lambda p, d: d[1] < -0.2),
    ({"Neck": [30, 0, 0]}, "Nose", lambda p, d: d[1] > 0.2),
    ({"Root": [0, 90, 0]}, "Nose", lambda p, d: p[0] < -0.5),
    ({"Root": [0, 0, 0, 0, 1, 0]}, "Head", lambda p, d: abs(d[1] - 1) < 1e-9),
    ({"Root": [-20, 0, 0]}, "Head", lambda p, d: d[2] < -0.5),
]


@pytest.mark.parametrize("pose, point, check", FK_CLAIMS, ids=[f"{list(p)[0]}{list(p.values())[0]}->{pt}"
                                                            for p, pt, _ in FK_CLAIMS])
def test_fk_matches_the_documented_signs(pose, point, check):
    p = A.pose_points(pose)[point]
    assert check(p, p - REST[point]), (pose, point, p)


@pytest.mark.parametrize("hip, knee, ankle, root_py", [(15, -30, 15, -0.06), (30, -60, 30, -0.23),
                                                      (45, -90, 45, -0.51), (60, -120, 60, -0.87)])
def test_crouch_recipe_keeps_feet_planted(hip, knee, ankle, root_py):
    pose = {f"{s}{j}": [v, 0, 0] for s in ("Right", "Left") for j, v in (("Hip", hip), ("Knee", knee), ("Ankle", ankle))}
    pose["Root"] = [0, 0, 0, 0, root_py, 0]
    pts = A.pose_points(pose)
    assert all(abs(h) < 0.02 for h in A.sole_heights(pts).values())
    assert abs(pts["RightToe"][1] - pts["RightHeel"][1]) < 1e-6                # flat foot


def test_mirror_rule():
    pose = {"RightShoulder": [40, 20, 70], "RightElbow": [60, 10, 0], "Waist": [-10, 15, 5]}
    mirrored = {"LeftShoulder": [40, -20, -70], "LeftElbow": [60, -10, 0], "Waist": [-10, -15, -5]}
    a, b = A.pose_points(pose), A.pose_points(mirrored)
    for name in ("HandTip", "Elbow", "Wrist"):
        pa, pb = a[f"Right{name}"], b[f"Left{name}"]
        assert np.allclose(pa * [-1, 1, 1], pb, atol=1e-9), name


# ---------------------------------------------------------------------------------------------------- pack

def test_clip_pack_writes_a_stable_luau_module(tmp_path):
    ws = Workspace(tmp_path / "game")
    pack = ClipPack(ws)
    pack.add(WAVE, name="wave")
    pack.add(still({"Neck": [10, 0, 0]}, looped=True), name="nod")
    src_file = ws.src / "ReplicatedStorage" / "Shared" / "ClipPack.luau"
    first = src_file.read_text(encoding="utf-8")
    assert first.startswith("-- Generated by cybus-harness")
    assert "\nreturn {\n" in first and first.rstrip().endswith("}")
    assert first.index('["nod"] = {') < first.index('["wave"] = {')            # sorted by name
    assert 'name = "wave",' in first and "looped = false," in first and 'priority = "action",' in first
    assert '{ t = 0.4, ease = "expoIn", pose = { RightShoulder = { 110, 0, 10 }, RightElbow = { 15, 0, 0 } } },' in first
    assert '{ t = 0.4, name = "hit" },' in first
    assert first.count("{") == first.count("}")
    manifest = json.loads((ws.root / "clip_pack.json").read_text(encoding="utf-8"))
    assert sorted(manifest["clips"]) == ["nod", "wave"]

    other = ClipPack(Workspace(tmp_path / "other"))                             # same clips, other order
    other.add(still({"Neck": [10, 0, 0]}, looped=True), name="nod")
    other.add(WAVE, name="wave")
    assert other.luau() == first
    pack.write()
    assert src_file.read_text(encoding="utf-8") == first                        # rewriting changes nothing

    again = ClipPack(ws)                                                        # reloads from the manifest
    assert again.names() == ["nod", "wave"] and again.get("wave") == pack.get("wave")
    assert again.remove("nod") and not again.remove("nod")
    assert '["nod"]' not in src_file.read_text(encoding="utf-8")
    with pytest.raises(ValueError, match="unknown joint"):
        again.add(still({"Nek": [1, 0, 0]}), name="typo")
    assert "typo" not in again


def test_pack_quotes_names_that_are_not_identifiers(tmp_path):
    pack = ClipPack(Workspace(tmp_path))
    pack.add(still({"Right Shoulder": [10, 0, 0], "end": [5, 0, 0]}) | {"rig": "custom"}, name="r6-wave")
    text = pack.luau()
    assert '["r6-wave"] = {' in text and '["Right Shoulder"] = { 10, 0, 0 }' in text and '["end"] = { 5, 0, 0 }' in text


# ---------------------------------------------------------------------------------------------------- preview

def test_preview_is_a_png_of_the_expected_size():
    clip = clip_of(WAVE, "wave")
    for frames in (8, 4, 12):
        png = preview(clip, frames)
        assert png.startswith(PNG_MAGIC)
        with Image.open(io.BytesIO(png)) as im:
            assert im.size == preview_size(frames)
    assert preview_size(8) == (1276, 604)


def test_different_poses_make_different_previews():
    a = preview(clip_of(still({"RightShoulder": [0, 0, 90]}), "a"), 4)
    b = preview(clip_of(still({"RightShoulder": [90, 0, 0]}), "a"), 4)
    assert a != b
    ia = np.asarray(Image.open(io.BytesIO(a)).convert("L"), dtype=float)
    ib = np.asarray(Image.open(io.BytesIO(b)).convert("L"), dtype=float)
    assert np.abs(ia - ib).mean() > 0.5


def _yellow(png: bytes) -> int:
    px = np.asarray(Image.open(io.BytesIO(png)).convert("RGB"), dtype=int)
    return int(((abs(px[..., 0] - 255) < 40) & (abs(px[..., 1] - 212) < 40) & (px[..., 2] < 90)).sum())


def test_markers_are_highlighted_on_their_exact_frame():
    clip = clip_of(WAVE, "wave")
    times, names = A._frame_times(clip, 8)
    assert 0.4 in times and names[times.index(0.4)] == ["hit"]
    unmarked = dict(clip, markers=[])
    assert _yellow(preview(clip)) > _yellow(preview(unmarked)) + 500


def test_contact_report():
    sinking = clip_of(still({"RightKnee": [-60, 0, 0], "LeftKnee": [-60, 0, 0], "Root": [0, 0, 0, 0, -0.6, 0]}), "sink")
    assert any("into the ground" in n for n in A.contact_report(sinking))
    flying = clip_of(still({"Root": [0, 0, 0, 0, 1, 0]}), "fly")
    assert any("off the ground" in n for n in A.contact_report(flying))
    assert A.contact_report(clip_of(WAVE, "wave")) == []


# ---------------------------------------------------------------------------------------------------- playbook

def playbook_examples() -> dict[str, dict]:
    text = PLAYBOOK.read_text(encoding="utf-8")
    found = re.findall(r"### `(\w+)`\n.*?```json\n(.*?)\n```", text, flags=re.S)
    return {name: json.loads(block) for name, block in found}


def test_playbook_has_the_five_examples_and_they_are_valid():
    examples = playbook_examples()
    assert sorted(examples) == ["celebrate", "hit_react", "idle_breath", "jump", "throw"]
    for name, spec in examples.items():
        clip, errors = validate_clip(spec, name=name)
        assert errors == [], (name, errors)
        report = A.contact_report(clip)
        assert not any("into the ground" in n for n in report), (name, report)
        assert preview(clip).startswith(PNG_MAGIC)
    assert examples["idle_breath"]["looped"] and examples["jump"]["markers"]
    first = re.search(r"## Clip format\n\n```json\n(.*?)\n```", PLAYBOOK.read_text(encoding="utf-8"), flags=re.S)
    assert validate_clip(json.loads(first.group(1)), name="format_example")[1] == []
    out = os.environ.get("HARNESS_ANIM_PREVIEW_OUT")
    if out:                                           # a sample sheet for a human to look at
        Path(out).parent.mkdir(parents=True, exist_ok=True)
        Path(out).write_bytes(preview(validate_clip(examples["jump"], name="jump")[0], 8))


# ---------------------------------------------------------------------------------------------------- tools

def test_author_clip_and_list_clips(tmp_path):
    ws = Workspace(tmp_path / "game")
    tools = {t.name: t for t in anim_tools(ClipPack(ws), tmp_path / "art")}
    assert sorted(tools) == ["author_clip", "list_clips"]
    assert tools["author_clip"].mutating and not tools["list_clips"].mutating
    assert "knees bend with NEGATIVE rx" in tools["author_clip"].description

    ok = asyncio.run(tools["author_clip"].invoke({"name": "wave", "spec": WAVE}))
    assert ok.data["ok"] and len(ok.images) == 1 and ok.images[0].startswith(PNG_MAGIC)
    assert "Packed wave: 0.8s one-shot" in ok.text and 'rig:play("wave"' in ok.text
    assert 'track.Marker("hit")' in ok.text and "local Anim = require(ReplicatedStorage.Kit.Anim)" in ok.text
    assert (tmp_path / "art" / "clips" / "wave.png").read_bytes() == ok.images[0]
    assert '["wave"] = {' in ws.read("ReplicatedStorage/Shared/ClipPack.luau")

    again = asyncio.run(tools["author_clip"].invoke({"name": "wave", "spec": json.dumps(WAVE)}))
    assert again.text.startswith("Replaced wave")

    bad = asyncio.run(tools["author_clip"].invoke({"name": "kick", "spec": _bad(keys__1__pose__RightKnee=[70, 0, 0],
                                                                                keys__2__pose__Nek=[1, 0, 0])}))
    assert bad.text.startswith("ERROR: clip 'kick' was NOT packed") and not bad.data["ok"]
    assert "1. " in bad.text and "2. " in bad.text and "did you mean 'Neck'" in bad.text
    assert len(bad.images) == 1                        # still readable: shown as written
    broken = asyncio.run(tools["author_clip"].invoke({"name": "x", "spec": {"keys": []}}))
    assert broken.text.startswith("ERROR") and broken.images == []

    listed = asyncio.run(tools["list_clips"].invoke({}))
    assert "1 clip(s)" in listed.text and "wave: 0.8s one-shot, priority action" in listed.text
    assert listed.data["clips"] == ["wave"]


def test_author_clip_reports_feet_and_late_joints(tmp_path):
    tools = {t.name: t for t in anim_tools(Workspace(tmp_path / "g"), tmp_path / "art")}
    spec = {"length": 1, "keys": [{"t": 0, "pose": {"Waist": [0, 0, 0]}},
                                  {"t": 0.5, "pose": {"Waist": [-10, 0, 0], "RightKnee": [-60, 0, 0],
                                                      "LeftKnee": [-60, 0, 0], "Root": [0, 0, 0, 0, -0.6, 0]}},
                                  {"t": 1, "pose": {"Waist": [0, 0, 0], "Root": [0, 0, 0],
                                                    "RightKnee": [0, 0, 0], "LeftKnee": [0, 0, 0]}}]}
    out = asyncio.run(tools["author_clip"].invoke({"name": "dip", "spec": spec}))
    assert out.data["ok"]
    assert "Feet: t=0.5: the" in out.text and "Ankle rx = -(Hip rx + Knee rx)" in out.text
    assert "start from rest: Root, RightKnee, LeftKnee" in out.text


# ---------------------------------------------------------------------------------------------------- Luau: AnimCore

SAMPLE_CLIPS = {
    "wave": WAVE,
    "loop_offsets": {"length": 1.2, "looped": True, "priority": "movement", "keys": [
        {"t": 0, "pose": {"RightHip": [30, 0, 0], "LeftHip": [-30, 0, 0], "Root": [0, 0, 0, 0, -0.1, 0]}},
        {"t": 0.3, "ease": "sineIn", "pose": {"Root": [0, 5, 0, 0, 0.05, 0]}},
        {"t": 0.45, "ease": "cubic", "pose": {"RightShoulder": [-25, 10, 5], "LeftShoulder": [25, -10, -5]}},
        {"t": 0.6, "ease": "back", "pose": {"RightHip": [-30, 0, 0], "LeftHip": [30, 0, 0],
                                             "Root": [0, 0, 0, 0, -0.1, 0]}},
        {"t": 0.9, "ease": "sineOut", "pose": {"Root": [0, -5, 0, 0, 0.05, 0]}},
        {"t": 1.05, "ease": "expo", "pose": {"RightShoulder": [25, -10, 5], "LeftShoulder": [-25, 10, -5]}},
        {"t": 1.2, "ease": "cubicOut", "pose": {"RightHip": [30, 0, 0], "LeftHip": [-30, 0, 0],
                                                 "Root": [0, 0, 0, 0, -0.1, 0]}}],
        "markers": [{"t": 0.1, "name": "step_r"}, {"t": 0.7, "name": "step_l"}]},
    "combo": {"length": 0.9, "keys": [
        {"t": 0, "pose": {"Waist": [0, 0, 0]}},
        {"t": 0.2, "ease": "backIn", "pose": {"Waist": [10, -40, 5], "RightShoulder": [60, 20, 90]}},
        {"t": 0.35, "ease": "expoIn", "pose": {"Waist": [-20, 45, -10], "RightShoulder": [120, -30, 20],
                                                "RightElbow": [30, 40, 0]}},
        {"t": 0.5, "ease": "expoOut", "pose": {"Neck": [-15, 30, 0]}},
        {"t": 0.7, "ease": "backOut", "pose": {"Waist": [-30, 50, -5], "RightShoulder": [40, 0, -30]}},
        {"t": 0.9, "ease": "quad", "pose": {"Waist": [0, 0, 0], "RightShoulder": [0, 0, 0], "RightElbow": [0, 0, 0],
                                             "Neck": [0, 0, 0]}}]},
}
SAMPLE_TIMES = [0.0, 0.013, 0.1, 0.2, 0.27, 0.333, 0.349, 0.45, 0.5, 0.61, 0.75, 0.88, 0.9, 1.0, 1.1, 1.19, 1.3,
                2.47, -0.2]

SAMPLE_LUAU = r"""
local AnimCore = require("./AnimCore")
local pack = require("./ClipPack")
local times = require("./times")
local names = {}
for name in pack do table.insert(names, name) end
table.sort(names)
for _, name in names do
	local clip, problems = AnimCore.compile(pack[name])
	assert(clip, name .. ": " .. table.concat(problems, "; "))
	print("C", name, #problems, clip.count, clip.priority)
	for _, t in times do
		for _, ch in clip.channels do
			local qx, qy, qz, qw, px, py, pz = AnimCore.sampleChannel(ch, t, clip.looped, clip.length)
			print(string.format("S %s %s %.6f %.15f %.15f %.15f %.15f %.15f %.15f %.15f", name, ch.joint, t,
				qx, qy, qz, qw, px, py, pz))
		end
	end
end
for _, e in AnimCore.EASES do
	for i = 0, 20 do
		local a = i / 20
		print(string.format("E %s %.4f %.15f", e, a, AnimCore.ease(e, a)))
	end
end
"""


@needs_luau
def test_animcore_sampling_and_easing_match_python(tmp_path):
    clips = {name: clip_of(spec, name) for name, spec in SAMPLE_CLIPS.items()}
    out = run_luau(tmp_path, {"ClipPack.luau": A.pack_luau(clips),
                              "times.luau": "return { " + ", ".join(repr(t) for t in SAMPLE_TIMES) + " }",
                              "main.luau": SAMPLE_LUAU}, "main.luau")
    compiled = [line.split() for line in out.splitlines() if line.split()[:1] == ["C"]]
    assert [c[1] for c in compiled] == sorted(clips) and all(c[2] == "0" for c in compiled)
    samples = [line.split() for line in out.splitlines() if line.startswith("S ")]
    assert len(samples) == sum(len(A.channels(c)) for c in clips.values()) * len(SAMPLE_TIMES)
    worst = 0.0
    for _, name, joint, t, *vals in samples:
        clip = clips[name]
        q, p = A.sample_channel(A.channels(clip)[joint], float(t), clip["looped"], clip["length"])
        worst = max(worst, max(abs(a - float(b)) for a, b in zip((*q, *p), vals)))
    assert worst < 1e-9, worst
    for _, name, a, v in (line.split() for line in out.splitlines() if line.startswith("E ")):
        assert abs(A.ease(name, float(a)) - float(v)) < 1e-12, (name, a)


def _ref_mix(tracks: list[tuple[dict, float, float, int]]) -> dict[str, tuple]:
    """The documented blend, reimplemented: per joint, each priority layer is the normalized weighted sum of its
    tracks, laid over the layers below with alpha = min(1, total weight). -> {joint: (quat, pos, coverage)}"""
    out = {}
    joints = {j for clip, *_ in tracks for j in A.channels(clip)}
    for joint in joints:
        s, sp, c = np.zeros(4), np.zeros(3), 0.0
        for prio in sorted({t[3] for t in tracks}):
            acc, accp, wsum = np.zeros(4), np.zeros(3), 0.0
            for clip, time, w, pr in tracks:
                chans = A.channels(clip)
                if pr != prio or w <= 0 or joint not in chans:
                    continue
                q, p = A.sample_channel(chans[joint], time, clip["looped"], clip["length"])
                q = np.array(q)
                if wsum > 0 and acc @ q < 0:
                    q = -q
                acc, accp, wsum = acc + w * q, accp + w * np.array(p), wsum + w
            if wsum <= 0:
                continue
            alpha = min(1.0, wsum)
            layer = acc / np.linalg.norm(acc)
            if c > 0 and s @ layer < 0:
                layer = -layer
            s, sp, c = s * (1 - alpha) + layer * alpha, sp * (1 - alpha) + accp / wsum * alpha, c * (1 - alpha) + alpha
        if c > 0:
            out[joint] = (s / np.linalg.norm(s), sp / c, c)
    return out


MIX_LUAU = r"""
local AnimCore = require("./AnimCore")
local pack = require("./ClipPack")
local cases = require("./cases")
local joints = { "Root", "Waist", "Neck", "RightShoulder", "RightElbow", "LeftShoulder", "RightHip", "LeftHip" }
local slot = {}
for i, j in joints do slot[j] = i end
for ci, case in cases do
	local tracks = {}
	for _, spec in case do
		local clip = assert(AnimCore.compile(pack[spec[1]]))
		local tr = AnimCore.newTrack(clip, { fade = 0 })
		tr.time, tr.w, tr.prio = spec[2], spec[3], spec[4]
		tr.map = {}
		for i, ch in clip.channels do tr.map[i] = slot[ch.joint] or 0 end
		table.insert(tracks, tr)
	end
	table.sort(tracks, function(a, b) return a.prio < b.prio end)
	local m = AnimCore.newMixer(#joints)
	m:mix(tracks, #tracks)
	for s, j in joints do
		print(string.format("M %d %s %.15f %.15f %.15f %.15f %.15f %.15f %.15f %.15f", ci, j, m.c[s],
			m.qx[s], m.qy[s], m.qz[s], m.qw[s], m.px[s], m.py[s], m.pz[s]))
	end
end
"""


@needs_luau
def test_animcore_blending_matches_the_documented_rule(tmp_path):
    clips = {name: clip_of(spec, name) for name, spec in SAMPLE_CLIPS.items()}
    clips["idle"] = clip_of(still({"Waist": [5, 0, 0], "RightShoulder": [0, 0, 20], "LeftShoulder": [0, 0, -20],
                                   "Root": [0, 0, 0, 0, -0.05, 0]}, looped=True) | {"priority": "idle"}, "idle")
    cases = [
        [("idle", 0.3, 1.0, 2)],                                                   # one full track
        [("idle", 0.3, 0.5, 2)],                                                   # fading in: half coverage
        [("idle", 0.3, 1.0, 2), ("wave", 0.35, 1.0, 4)],                           # action overrides idle per joint
        [("idle", 0.3, 1.0, 2), ("wave", 0.35, 0.4, 4)],                           # action fading in over idle
        [("wave", 0.2, 1.0, 4), ("combo", 0.4, 1.0, 4)],                           # same priority: mixed by weight
        [("wave", 0.2, 0.3, 4), ("combo", 0.4, 0.2, 4), ("idle", 0.1, 1, 2)],      # partial weights both layers
        [("loop_offsets", 2.3, 1.0, 3), ("combo", 0.66, 0.7, 4), ("idle", 0.0, 0.6, 2)],
    ]
    lua_cases = "return {\n" + ",\n".join(
        "\t{ " + ", ".join(f'{{ "{n}", {t!r}, {w!r}, {p} }}' for n, t, w, p in case) + " }" for case in cases) + "\n}\n"
    out = run_luau(tmp_path, {"ClipPack.luau": A.pack_luau(clips), "cases.luau": lua_cases, "main.luau": MIX_LUAU},
                   "main.luau")
    rows = [line.split() for line in out.splitlines() if line.startswith("M ")]
    assert len(rows) == len(cases) * 8
    for _, ci, joint, c, *vals in rows:
        case = cases[int(ci) - 1]
        ref = _ref_mix([(clips[n], t, w, p) for n, t, w, p in case])
        if joint not in ref:
            assert float(c) == 0 and [float(v) for v in vals] == [0, 0, 0, 1, 0, 0, 0], (ci, joint)
            continue
        q, p, cov = ref[joint]
        got_q = np.array([float(v) for v in vals[:4]])
        assert abs(float(c) - cov) < 1e-12, (ci, joint)
        assert min(np.abs(got_q - q).max(), np.abs(got_q + q).max()) < 1e-9, (ci, joint)
        assert np.abs(np.array([float(v) for v in vals[4:]]) - p).max() < 1e-9, (ci, joint)
    # the rule's meaning, spelled out on two cases
    over = {j: v for j, v in _ref_mix([(clips["idle"], 0.3, 1, 2), (clips["wave"], 0.35, 1, 4)]).items()}
    wave_pose = A.sample_clip(clips["wave"], 0.35)
    assert np.allclose(np.abs(over["RightShoulder"][0]), np.abs(wave_pose["RightShoulder"][0]), atol=1e-12)
    assert np.allclose(np.abs(over["LeftShoulder"][0]), np.abs(A.euler_quat(0, 0, -20)), atol=1e-12)
    half = _ref_mix([(clips["idle"], 0.3, 0.5, 2)])
    assert abs(half["Waist"][2] - 0.5) < 1e-12


TRACK_LUAU = r"""
local AnimCore = require("./AnimCore")
local pack = require("./ClipPack")
local function run(label, name, opts, steps, dt)
	local clip = assert(AnimCore.compile(pack[name]))
	local tr = AnimCore.newTrack(clip, opts)
	for i = 1, steps do
		local ended = AnimCore.advance(tr, dt, function(t, kind, marker)
			print(string.format("V %s %d %s %s", label, i, kind, tostring(marker)))
		end)
		if i == 1 or i == steps or ended then
			print(string.format("W %s %d %.12f %.12f %s", label, i, tr.w, tr.time, tostring(ended)))
		end
		if ended then break end
	end
end
run("oneshot", "beats", { fade = 0.2 }, 60, 0.05)
run("loop", "loop_beats", { fade = 0.1 }, 50, 0.05)
run("reverse", "beats", { fade = 0, speed = -1 }, 40, 0.05)
run("hold", "beats", { fade = 0, hold = true }, 40, 0.05)
local clip = assert(AnimCore.compile(pack.beats))
local tr = AnimCore.newTrack(clip, { fade = 0.2 })
AnimCore.advance(tr, 0.1)
print(string.format("F %.12f", tr.w))
print("B", AnimCore.compile({ name = "bad", length = 0, keys = "x" }) == nil, #AnimCore.check({ name = 5, length = 1,
	keys = { { t = 0.2, ease = "zig", pose = { Waist = { 1, 2 } } }, { t = 0.1, pose = 7 } }, markers = { { t = 9 } } }))
print("P", (pcall(AnimCore.compile, nil)), (pcall(AnimCore.compile, { keys = { false } })))
"""


@needs_luau
def test_animcore_track_time_markers_and_fades(tmp_path):
    beats = clip_of({"length": 1.0, "keys": [{"t": 0, "pose": {"Neck": [0, 0, 0]}}, {"t": 1, "pose": {"Neck": [9, 0, 0]}}],
                     "markers": [{"t": 0, "name": "a"}, {"t": 0.5, "name": "b"}, {"t": 1.0, "name": "c"}]}, "beats")
    loop_beats = clip_of({"length": 1.0, "looped": True, "keys": [{"t": 0, "pose": {"Neck": [0, 0, 0]}},
                                                                  {"t": 1, "pose": {"Neck": [0, 0, 0]}}],
                          "markers": [{"t": 0.25, "name": "mid"}, {"t": 1.0, "name": "top"}]}, "loop_beats")
    out = run_luau(tmp_path, {"ClipPack.luau": A.pack_luau({"beats": beats, "loop_beats": loop_beats}),
                              "main.luau": TRACK_LUAU}, "main.luau")
    events = [line.split()[1:] for line in out.splitlines() if line.startswith("V ")]

    def seq(label):
        return [(kind, name) for lab, _, kind, name in events if lab == label]

    assert seq("oneshot") == [("marker", "a"), ("marker", "b"), ("marker", "c"), ("stopped", "nil"), ("ended", "nil")]
    assert [n for k, n in seq("loop")] == ["top", "mid", "top", "mid", "top", "mid"]  # 2.5 s of a 1 s loop
    assert seq("reverse") == [("marker", "c"), ("marker", "b"), ("marker", "a"), ("stopped", "nil"), ("ended", "nil")]
    assert seq("hold") == [("marker", "a"), ("marker", "b"), ("marker", "c")]       # holds the last pose, no end
    ends = {line.split()[1]: line.split()[2:] for line in out.splitlines() if line.startswith("W ")}
    assert ends["hold"][-1] == "false" and float(ends["hold"][2]) == 1.0            # time clamped at the end
    assert ends["oneshot"][-1] == "true" and float(ends["oneshot"][1]) == 0.0
    fade = float(next(line.split()[1] for line in out.splitlines() if line.startswith("F ")))
    assert abs(fade - 0.5) < 1e-12                                                 # smoothstep half way through
    bad = next(line.split() for line in out.splitlines() if line.startswith("B"))
    assert bad[1] == "true" and int(bad[2]) >= 6                                    # nil + problems, never an error
    assert next(line for line in out.splitlines() if line.startswith("P")).split()[1:] == ["true", "true"]


@needs_luau
def test_every_packed_example_compiles_in_luau(tmp_path):
    clips = {name: clip_of(spec, name) for name, spec in playbook_examples().items()}
    main = r"""
local AnimCore = require("./AnimCore")
for name, data in require("./ClipPack") do
	local clip, problems = AnimCore.compile(data)
	print(name, clip ~= nil, #problems, clip and clip.count or 0)
end
"""
    out = run_luau(tmp_path, {"ClipPack.luau": A.pack_luau(clips), "main.luau": main}, "main.luau")
    rows = sorted(line.split("\t") for line in out.splitlines() if line.strip())
    assert [r[0] for r in rows] == sorted(clips)
    for name, ok, problems, count in rows:
        assert ok == "true" and problems == "0" and int(count) == len(A.channels(clips[name])), name


# ---------------------------------------------------------------------------------------------------- Luau: Kit.Anim

FAKE_ROBLOX = r'''-- Just enough of Roblox to run Kit.Anim under the standalone Luau runtime: Instances with events, Motor6D fields,
-- CFrame / Vector3 values, an Animator with tracks, RunService.PreSimulation driven by frame(dt), task, warn.
local Fake = {}
local warnings = {}
Fake.warnings = warnings

local function Signal()
	local handlers = {}
	local s = {}
	function s:Connect(fn)
		local c = { Connected = true }
		function c.Disconnect()
			c.Connected = false
			handlers[c] = nil
		end
		handlers[c] = fn
		return c
	end
	function s:Fire(...)
		local list = {}
		for c, fn in handlers do
			table.insert(list, fn)
		end
		for _, fn in list do
			fn(...)
		end
	end
	function s:count()
		local n = 0
		for _ in handlers do
			n += 1
		end
		return n
	end
	return s
end
Fake.Signal = Signal

-- Vector3
local V3 = { __type = "Vector3" }
local Vector3 = {}
function Vector3.new(x, y, z)
	return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, V3)
end
V3.__add = function(a, b)
	return Vector3.new(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
end
V3.__sub = function(a, b)
	return Vector3.new(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
end
V3.__mul = function(a, b)
	if type(a) == "number" then
		return Vector3.new(a * b.X, a * b.Y, a * b.Z)
	elseif type(b) == "number" then
		return Vector3.new(a.X * b, a.Y * b, a.Z * b)
	end
	return Vector3.new(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end
V3.__eq = function(a, b)
	return a.X == b.X and a.Y == b.Y and a.Z == b.Z
end
Vector3.zero = Vector3.new(0, 0, 0)
Fake.Vector3 = Vector3

-- CFrame: position + rotation matrix (rows)
local CF = { __type = "CFrame" }
local CFrame = {}
local function mk(x, y, z, a, b, c, d, e, f, g, h, i)
	return setmetatable({ x = x, y = y, z = z, m = { a, b, c, d, e, f, g, h, i } }, CF)
end
function CFrame.new(x, y, z, qx, qy, qz, qw)
	x, y, z = x or 0, y or 0, z or 0
	if qx == nil then
		return mk(x, y, z, 1, 0, 0, 0, 1, 0, 0, 0, 1)
	end
	local n = math.sqrt(qx * qx + qy * qy + qz * qz + qw * qw)
	qx, qy, qz, qw = qx / n, qy / n, qz / n, qw / n
	return mk(x, y, z,
		1 - 2 * (qy * qy + qz * qz), 2 * (qx * qy - qz * qw), 2 * (qx * qz + qy * qw),
		2 * (qx * qy + qz * qw), 1 - 2 * (qx * qx + qz * qz), 2 * (qy * qz - qx * qw),
		2 * (qx * qz - qy * qw), 2 * (qy * qz + qx * qw), 1 - 2 * (qx * qx + qy * qy))
end
function CFrame.fromYaw(x, y, z, yawDeg) -- rotation about +Y
	local r = math.rad(yawDeg)
	local c, s = math.cos(r), math.sin(r)
	return mk(x, y, z, c, 0, s, 0, 1, 0, -s, 0, c)
end
CFrame.identity = CFrame.new()
local CFMethods = {}
function CFMethods:GetComponents()
	local m = self.m
	return self.x, self.y, self.z, m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9]
end
CF.__index = function(c, k)
	if k == "Position" then
		return Vector3.new(c.x, c.y, c.z)
	end
	return CFMethods[k]
end
CF.__eq = function(a, b)
	if a.x ~= b.x or a.y ~= b.y or a.z ~= b.z then
		return false
	end
	for i = 1, 9 do
		if a.m[i] ~= b.m[i] then
			return false
		end
	end
	return true
end
Fake.CFrame = CFrame

-- Instances
local Inst = { __type = "Instance" }
local Methods = {}
Inst.__index = function(self, k) -- a method, else a child by name (as Roblox)
	local m = Methods[k]
	if m ~= nil then
		return m
	end
	for _, c in rawget(self, "_children") do
		if c.Name == k then
			return c
		end
	end
	return nil
end
local BASEPART = { Part = true, MeshPart = true }

local function newInstance(className, name, props)
	local inst = setmetatable({
		ClassName = className,
		Name = name or className,
		_children = {},
		DescendantAdded = Signal(),
		DescendantRemoving = Signal(),
		Destroying = Signal(),
	}, Inst)
	for k, v in props or {} do
		inst[k] = v
	end
	return inst
end

local function descendantsOf(inst, out)
	for _, c in inst._children do
		table.insert(out, c)
		descendantsOf(c, out)
	end
	return out
end

local function setParent(inst, parent)
	local old = rawget(inst, "Parent")
	if old ~= nil then
		local kids = old._children
		for i, c in kids do
			if c == inst then
				table.remove(kids, i)
				break
			end
		end
		local gone = descendantsOf(inst, { inst })
		local a = old
		while a ~= nil do
			for _, d in gone do
				a.DescendantRemoving:Fire(d)
			end
			a = rawget(a, "Parent")
		end
	end
	rawset(inst, "Parent", parent)
	if parent ~= nil then
		table.insert(parent._children, inst)
		local added = descendantsOf(inst, { inst })
		local a = parent
		while a ~= nil do
			for _, d in added do
				a.DescendantAdded:Fire(d)
			end
			a = rawget(a, "Parent")
		end
	end
end
Fake.setParent = setParent

function Fake.new(className, name, parent, props)
	local inst = newInstance(className, name, props)
	if parent ~= nil then
		setParent(inst, parent)
	end
	return inst
end

function Methods:IsA(c)
	return c == "Instance" or self.ClassName == c or (c == "BasePart" and BASEPART[self.ClassName] == true)
end
function Methods:GetChildren()
	return table.clone(self._children)
end
function Methods:GetDescendants()
	return descendantsOf(self, {})
end
function Methods:FindFirstChild(name, recursive)
	for _, c in if recursive then descendantsOf(self, {}) else self._children do
		if c.Name == name then
			return c
		end
	end
	return nil
end
function Methods:WaitForChild(name)
	return self:FindFirstChild(name)
end
function Methods:FindFirstChildOfClass(cls)
	for _, c in self._children do
		if c.ClassName == cls then
			return c
		end
	end
	return nil
end
function Methods:FindFirstChildWhichIsA(cls, recursive)
	for _, c in if recursive then descendantsOf(self, {}) else self._children do
		if c:IsA(cls) then
			return c
		end
	end
	return nil
end
function Methods:GetFullName()
	local parts, a = {}, self
	while a ~= nil do
		table.insert(parts, 1, a.Name)
		a = rawget(a, "Parent")
	end
	return table.concat(parts, ".")
end
function Methods:GetPivot()
	local p = rawget(self, "PrimaryPart")
	return if p then p.CFrame else CFrame.identity
end
function Methods:Destroy()
	self.Destroying:Fire()
	setParent(self, nil)
end
-- Animator
function Methods:GetPlayingAnimationTracks()
	local out = {}
	for _, t in self._tracks or {} do
		if t.IsPlaying then
			table.insert(out, t)
		end
	end
	return out
end

function Fake.animTrack(animator, name)
	local t = { Name = name, IsPlaying = true, WeightTarget = 1, Speed = 1 }
	function t:AdjustWeight(w)
		self.WeightTarget = w
	end
	function t:AdjustSpeed(s)
		self.Speed = s
	end
	animator._tracks = animator._tracks or {}
	table.insert(animator._tracks, t)
	animator.AnimationPlayed:Fire(t)
	return t
end

-- services, task, globals
local RunService = { PreSimulation = Signal(), Stepped = Signal() }
function RunService:IsClient()
	return true
end
function RunService:IsServer()
	return false
end
local ReplicatedStorage = Fake.new("ReplicatedStorage", "ReplicatedStorage")
local game = setmetatable({}, { __type = "Instance" })
function game:GetService(name)
	if name == "RunService" then
		return RunService
	elseif name == "ReplicatedStorage" then
		return ReplicatedStorage
	end
	error("fake game has no service " .. name)
end
Fake.RunService = RunService
Fake.ReplicatedStorage = ReplicatedStorage

local deferred = {}
local task = {
	spawn = function(fn, ...)
		if type(fn) == "thread" then
			return coroutine.resume(fn, ...)
		end
		local co = coroutine.create(fn)
		local ok, err = coroutine.resume(co, ...)
		if not ok then
			print("TASK ERROR " .. tostring(err))
		end
	end,
	defer = function(fn, ...)
		table.insert(deferred, table.pack(fn, ...))
	end,
}

function Fake.frame(dt)
	RunService.PreSimulation:Fire(dt)
	while #deferred > 0 do
		local batch = deferred
		deferred = {}
		for _, job in batch do
			task.spawn(table.unpack(job, 1, job.n))
		end
	end
end

local function typeof(v)
	local mt = getmetatable(v)
	if type(mt) == "table" and type(mt.__type) == "string" then
		return mt.__type
	end
	return type(v)
end

-- Loads a kit module from source with the fake globals; `modules` maps a ModuleScript Name -> loaded value.
function Fake.load(source, chunkname, scriptInst, modules)
	local env = setmetatable({
		game = game,
		workspace = Fake.new("Workspace", "Workspace"),
		script = scriptInst,
		task = task,
		typeof = typeof,
		Vector3 = Vector3,
		CFrame = CFrame,
		warn = function(...)
			local msg = table.concat({ ... }, " ")
			table.insert(warnings, msg)
			print("WARN " .. msg)
		end,
		require = function(m)
			if type(m) == "table" and m._module ~= nil then
				return m._module
			end
			error("fake require: unknown module " .. tostring(m and m.Name))
		end,
	}, { __index = _G })
	local fn, err = loadstring(source, "=" .. chunkname)
	assert(fn, err)
	setfenv(fn, env)
	return fn()
end

return Fake
'''

ANIM_SMOKE = r'''-- Kit.Anim smoke test under the fake Roblox. Injected by the Python side: DATA (R15 joints, rest part positions,
-- expected quaternions) and SOURCES (Anim.luau source, ClipPack source).
local Fake = require("./fake_roblox")
local AnimCore = require("./AnimCore")
local Spring = require("./Spring")
local DATA = require("./anim_data")
local CFrame, Vector3 = Fake.CFrame, Fake.Vector3

local function check(name, ok, detail)
	print((if ok then "OK " else "FAIL ") .. name .. (if detail ~= nil then " | " .. tostring(detail) else ""))
end

local function quatOf(cf)
	local _, _, _, a, b, c, d, e, f, g, h, i = cf:GetComponents()
	return AnimCore.fromMatrix(a, b, c, d, e, f, g, h, i)
end

local function quatErr(cf, ex, ey, ez, ew)
	local x, y, z, w = quatOf(cf)
	if x * ex + y * ey + z * ez + w * ew < 0 then
		x, y, z, w = -x, -y, -z, -w
	end
	return math.max(math.abs(x - ex), math.abs(y - ey), math.abs(z - ez), math.abs(w - ew))
end

local function countWarnings(text)
	local n = 0
	for _, w in Fake.warnings do
		if string.find(w, text, 1, true) then
			n += 1
		end
	end
	return n
end

-- the kit, as synced: ReplicatedStorage.Kit.{AnimCore, Spring, Anim}, ReplicatedStorage.Shared.ClipPack
local kit = Fake.new("Folder", "Kit", Fake.ReplicatedStorage)
Fake.new("ModuleScript", "AnimCore", kit, { _module = AnimCore })
Fake.new("ModuleScript", "Spring", kit, { _module = Spring })
local animScript = Fake.new("ModuleScript", "Anim", kit)
local shared = Fake.new("Folder", "Shared", Fake.ReplicatedStorage)
local packFn = assert(loadstring(DATA.packSource, "=ClipPack"))
Fake.new("ModuleScript", "ClipPack", shared, { _module = packFn() })
local Anim = Fake.load(DATA.animSource, "Anim", animScript)

local function buildR15(name)
	local model = Fake.new("Model", name)
	local parts = {}
	for pname, pos in DATA.parts do
		parts[pname] = Fake.new("Part", pname, model, {
			CFrame = CFrame.new(pos[1], pos[2], pos[3]),
			Position = Vector3.new(pos[1], pos[2], pos[3]),
			Size = Vector3.new(1, 1, 1),
			AssemblyLinearVelocity = Vector3.zero,
		})
	end
	local humanoid = Fake.new("Humanoid", "Humanoid", model, { RootPart = parts.HumanoidRootPart })
	local animator = Fake.new("Animator", "Animator", humanoid, { AnimationPlayed = Fake.Signal() })
	model.PrimaryPart = parts.HumanoidRootPart
	local motors = {}
	for _, j in DATA.joints do
		motors[j.name] = Fake.new("Motor6D", j.name, parts[j.part1], {
			Part0 = parts[j.part0],
			Part1 = parts[j.part1],
			C0 = CFrame.new(j.c0[1], j.c0[2], j.c0[3]),
			C1 = CFrame.new(j.c1[1], j.c1[2], j.c1[3]),
			Transform = CFrame.identity,
		})
	end
	return model, parts, motors, animator
end

local function frames(n, dt)
	for _ = 1, n do
		Fake.frame(dt or 1 / 60)
	end
end

-- 1. a registered one-shot: exact pose, markers, events, hand-back ------------------------------------------
local model, parts, motors, animator = buildR15("Dummy")
local rig = Anim.load(model)
check("load caches one player per rig", Anim.load(model) == rig and Anim.load(model.Humanoid) == rig)
check("register a valid clip", Anim.register(DATA.wave) ~= nil)
local hits, reached, stopped, ended = 0, 0, 0, 0
local track = rig:play("wave", { fade = 0 })
track.Marker("hit"):Connect(function()
	hits += 1
end)
track:Marker("hit"):Connect(function() end) -- method-call style works too
track.MarkerReached:Connect(function(name)
	if name == "hit" then
		reached += 1
	end
end)
track.Stopped:Connect(function()
	stopped += 1
end)
track.ended:Connect(function()
	ended += 1
end)
frames(15)
local e = DATA.expect.wave
check("writes the sampled pose (matches Python)", quatErr(motors.RightShoulder.Transform, e[1], e[2], e[3], e[4]) < 1e-6,
	quatErr(motors.RightShoulder.Transform, e[1], e[2], e[3], e[4]))
local ee = DATA.expect.waveElbow
check("every keyed joint is written", quatErr(motors.RightElbow.Transform, ee[1], ee[2], ee[3], ee[4]) < 1e-6)
check("unkeyed joints are left alone", motors.LeftShoulder.Transform == CFrame.identity)
check("track reports time and state", math.abs(track.time - 0.25) < 1e-9 and track.isPlaying)
frames(30)
check("marker fired exactly once", hits == 1 and reached == 1, `{hits}/{reached}`)
check("Stopped and Ended fire once", stopped == 1 and ended == 1, `{stopped}/{ended}`)
check("joints handed back at rest", motors.RightShoulder.Transform == CFrame.identity and not track.isPlaying)
check("an idle rig leaves the frame loop", rig.active == false)
check("looped clip: play() again returns the same track", (function()
	local a = rig:play("wave_loop")
	local b = rig:play("wave_loop")
	a:stop(0)
	frames(2)
	return a == b and a.name == "wave_loop"
end)())

-- 2. blending over the Animator ----------------------------------------------------------------------------
local model2, _, motors2 = buildR15("Blend")
local rig2 = Anim.load(model2)
local armOnly = { name = "arm_fwd", length = 1, looped = true, priority = "action",
	keys = { { t = 0, pose = { RightShoulder = { 90, 0, 0 } } }, { t = 1, pose = { RightShoulder = { 90, 0, 0 } } } } }
rig2:play(armOnly, { fade = 0, weight = 0.5 })
local animatorPose = CFrame.new(0, 0, 0, AnimCore.euler(0, 0, 40))
for _ = 1, 5 do
	motors2.RightShoulder.Transform = animatorPose -- what the Animator writes before PreSimulation
	motors2.LeftShoulder.Transform = animatorPose
	Fake.frame(1 / 60)
end
local ax, ay, az, aw = AnimCore.euler(0, 0, 40)
local bx, by, bz, bw = AnimCore.euler(90, 0, 0)
local sx, sy, sz, sw = AnimCore.slerp(ax, ay, az, aw, bx, by, bz, bw, 0.5)
check("weight 0.5 blends over the Animator's pose", quatErr(motors2.RightShoulder.Transform, sx, sy, sz, sw) < 1e-6)
check("joints no clip poses keep the Animator's pose", motors2.LeftShoulder.Transform == animatorPose)
frames(3) -- the Animator stopped writing: the base is the rest pose again
sx, sy, sz, sw = AnimCore.slerp(0, 0, 0, 1, bx, by, bz, bw, 0.5)
check("without the Animator it blends from rest", quatErr(motors2.RightShoulder.Transform, sx, sy, sz, sw) < 1e-6)
-- priorities: a full-weight action overrides idle on its joints; idle keeps the rest
local idleBoth = { name = "idle_both", length = 1, looped = true, priority = "idle",
	keys = { { t = 0, pose = { RightShoulder = { 0, 0, 30 }, LeftShoulder = { 0, 0, -30 } } },
		{ t = 1, pose = { RightShoulder = { 0, 0, 30 }, LeftShoulder = { 0, 0, -30 } } } } }
rig2:stopAll(0)
frames(1)
rig2:play(idleBoth, { fade = 0 })
rig2:play(armOnly, { fade = 0, weight = 1 })
frames(2)
local lx, ly, lz, lw = AnimCore.euler(0, 0, -30)
check("higher priority overrides per joint", quatErr(motors2.RightShoulder.Transform, bx, by, bz, bw) < 1e-6
	and quatErr(motors2.LeftShoulder.Transform, lx, ly, lz, lw) < 1e-6)

-- 3. takeOver ------------------------------------------------------------------------------------------------
local model3, _, _, animator3 = buildR15("Take")
local walk = Fake.animTrack(animator3, "walk")
local rig3 = Anim.load(model3)
rig3:takeOver(true)
local tr3 = rig3:play(armOnly, { fade = 0.1 })
Fake.frame(1 / 60)
check("takeOver pauses the rig's own tracks", walk.WeightTarget == 0 and walk.Speed == 0)
local jump = Fake.animTrack(animator3, "jump")
check("takeOver holds tracks started later", jump.WeightTarget == 0 and jump.Speed == 0)
tr3:stop(0.1)
frames(12)
check("tracks restored when the clips stop", walk.WeightTarget == 1 and walk.Speed == 1 and jump.WeightTarget == 1)

-- 4. bad data never errors -------------------------------------------------------------------------------------
local before = #Fake.warnings
check("a bad clip is rejected", Anim.register({ name = "bad", length = -1, keys = {} }) == nil)
check("a bad clip warns", #Fake.warnings > before)
local ok, err = pcall(function()
	for _ = 1, 2 do
		local t = rig:play("no_such_clip")
		t:stop()
		t:adjustSpeed(2)
		t:adjustWeight(0.5)
		t.Marker("x"):Connect(function() end)
		t:setTime(1)
	end
	rig:play(42)
	rig:play(nil)
	rig:play({ name = "junk" })
	rig:play("wave", { fade = "slow", speed = 0 / 0, weight = "heavy" })
	local nobody = Anim.load(nil)
	nobody:play("wave")
	nobody:lean(1)
	nobody:stopAll()
	nobody:takeOver(true)
	rig:recoil("NoSuchJoint", { 1, 2, 3 }, 0.2)
	rig:recoil(nil, nil)
	rig:lookAt("nowhere")
	rig:lean("fast")
	rig:breathe(true, { rate = "x" })
	rig:squash(0.3)
	frames(5)
	rig:breathe(false)
	rig:stopAll(0)
	frames(90)
end)
check("bad calls never error", ok, err)
check("unknown clip names warn once", countWarnings("no_such_clip") == 1, countWarnings("no_such_clip"))

-- 5. rigs jointed with Bones are skipped with one warning ------------------------------------------------------
local blob = Fake.new("Model", "BoneRig")
local body = Fake.new("MeshPart", "Body", blob, { CFrame = CFrame.identity, Size = Vector3.new(2, 2, 2) })
Fake.new("Bone", "Spine", body)
local okb = pcall(function()
	local b = Anim.load(blob)
	b:play("wave")
	b:play("wave")
	frames(3)
end)
check("Bones-only rig: skipped, one warning", okb and countWarnings("Bones") == 1, countWarnings("Bones"))

-- 6. procedural layers -------------------------------------------------------------------------------------------
local model4, parts4, motors4 = buildR15("Proc")
local rig4 = Anim.load(model4)
local root = parts4.HumanoidRootPart
rig4:lean(1)
root.AssemblyLinearVelocity = Vector3.new(0, 0, -16)
for i = 1, 30 do
	root.CFrame = CFrame.fromYaw(0, 3, 0, i * 3) -- turning left at 180 degrees a second
	Fake.frame(1 / 60)
end
local _, _, rz = quatOf(motors4.Root.Transform)
local wx = quatOf(motors4.Waist.Transform)
check("lean banks into a left turn and leans forward", rz > 0.02 and wx < -0.005, `{rz} {wx}`)
rig4:lean(0)
root.CFrame = CFrame.new(0, 3, 0)
root.AssemblyLinearVelocity = Vector3.zero
frames(120)
check("lean settles back to rest", motors4.Root.Transform == CFrame.identity, tostring(quatOf(motors4.Root.Transform)))
rig4:lookAt(Vector3.new(-10, 4.5, -3)) -- to the character's left
frames(60)
local _, ny = quatOf(motors4.Neck.Transform)
local _, wy = quatOf(motors4.Waist.Transform)
check("lookAt turns head and chest left (ry > 0)", ny > 0.1 and wy > 0.05, `{ny} {wy}`)
rig4:lookAt(Vector3.new(0, 20, -10)) -- up ahead
frames(60)
local nx = quatOf(motors4.Neck.Transform)
check("lookAt up tips the head back (rx > 0)", nx > 0.1, nx)
rig4:lookAt(nil)
frames(90)
check("lookAt nil lets go", motors4.Neck.Transform == CFrame.identity)
rig4:breathe(true)
frames(60)
local bxq = quatOf(motors4.Waist.Transform)
check("breathe moves the chest", math.abs(bxq) > 1e-3, bxq)
rig4:breathe(false)
frames(240)
check("breathe off settles", motors4.Waist.Transform == CFrame.identity)
rig4:recoil("RightShoulder", { -30, 0, 0 }, 0.3)
local peak = 0
for _ = 1, 30 do
	Fake.frame(1 / 60)
	local qx = quatOf(motors4.RightShoulder.Transform)
	peak = math.min(peak, 2 * math.deg(math.asin(qx)))
end
check("recoil peaks near the kick", peak < -24 and peak > -36, peak)
frames(90)
check("recoil springs back", motors4.RightShoulder.Transform == CFrame.identity)
local slime = Fake.new("Model", "Slime")
local blobBody = Fake.new("Part", "Body", slime, { CFrame = CFrame.new(0, 1, 0), Size = Vector3.new(2, 2, 2) })
local mesh = Fake.new("SpecialMesh", "Mesh", blobBody, { Scale = Vector3.new(1, 1, 1), Offset = Vector3.zero })
local eye = Fake.new("Part", "Eye", slime, { CFrame = CFrame.new(0, 1.5, -0.9), Size = Vector3.new(0.4, 0.4, 0.4) })
Fake.new("Motor6D", "EyeJoint", eye, { Part0 = blobBody, Part1 = eye, C0 = CFrame.new(0, 0.5, -0.9),
	C1 = CFrame.identity, Transform = CFrame.identity })
slime.PrimaryPart = blobBody
local srig = Anim.load(slime)
srig:squash(0.3)
Fake.frame(1 / 60)
check("squash flattens and widens the mesh", mesh.Scale.Y < 0.8 and mesh.Scale.X > 1.05, `{mesh.Scale.X} {mesh.Scale.Y}`)
frames(150)
check("squash springs back exactly", mesh.Scale == Vector3.new(1, 1, 1) and mesh.Offset == Vector3.zero)

-- 7. a rig whose C0 / C1 are rotated (R6 style): poses still mean the character's axes ---------------------------
local r6 = Fake.new("Model", "R6ish")
local torso = Fake.new("Part", "Torso", r6, { CFrame = CFrame.new(0, 3, 0), Size = Vector3.new(2, 2, 1) })
local arm = Fake.new("Part", "Right Arm", r6, { CFrame = CFrame.new(1.5, 3, 0), Size = Vector3.new(1, 2, 1) })
local yaw90 = { AnimCore.euler(0, 90, 0) }
local c0 = CFrame.new(1, 0.5, 0, yaw90[1], yaw90[2], yaw90[3], yaw90[4])
local c1 = CFrame.new(-0.5, 0.5, 0, yaw90[1], yaw90[2], yaw90[3], yaw90[4])
local shoulder = Fake.new("Motor6D", "Right Shoulder", arm, { Part0 = torso, Part1 = arm, C0 = c0, C1 = c1,
	Transform = CFrame.identity })
Fake.new("Humanoid", "Humanoid", r6, { RootPart = torso })
local rig6 = Anim.load(r6)
rig6:play({ name = "r6_raise", length = 1, looped = true, keys = {
	{ t = 0, pose = { ["Right Shoulder"] = { 90, 0, 0 } } }, { t = 1, pose = { ["Right Shoulder"] = { 90, 0, 0 } } } } },
	{ fade = 0 })
frames(2)
local tx, ty, tz, tw = quatOf(shoulder.Transform)
local c0x, c0y, c0z, c0w = quatOf(c0)
local c1x, c1y, c1z, c1w = quatOf(c1)
local ox, oy, oz, ow = AnimCore.mul(c0x, c0y, c0z, c0w, tx, ty, tz, tw)
ox, oy, oz, ow = AnimCore.mul(ox, oy, oz, ow, -c1x, -c1y, -c1z, c1w)
local fx, fy, fz, fw = AnimCore.euler(90, 0, 0)
local d = math.abs(ox * fx + oy * fy + oz * fz + ow * fw)
check("rotated C0/C1: rx 90 raises the arm forward in character axes", d > 1 - 1e-9, d)

-- 8. ClipPack from ReplicatedStorage.Shared, and destroy ----------------------------------------------------------
check("ClipPack clips load lazily", Anim.clip(DATA.packedName) ~= nil and table.find(Anim.clips(), DATA.packedName) ~= nil)
local packed = rig:play(DATA.packedName, { fade = 0.05 })
frames(10)
check("a packed clip plays", packed.isPlaying and packed.time > 0.1)
model:Destroy()
check("destroying the rig destroys its player", Anim.get(model) == nil and rig.destroyed and not packed.isPlaying)

-- 9. cost: 20 rigs, each with a full-body loop, a leg loop and an arm one-shot ----------------------------------
local crowd = {}
for i = 1, 20 do
	local m = buildR15("Crowd" .. i)
	local p = Anim.load(m)
	p:play(DATA.packedName)
	p:play("walk_legs")
	p:play("wave")
	table.insert(crowd, p)
end
frames(5)
local t0 = os.clock()
local N = 120
frames(N)
local ms = (os.clock() - t0) * 1000 / N
print(string.format("PERF 20 rigs x 3 tracks: %.3f ms/frame (fake CFrames; interpreted)", ms))
check("20 rigs animate", crowd[20].nTracks >= 2)
print("DONE")
'''


def _smoke_data() -> str:
    def vec(v):
        return "{ " + ", ".join(repr(float(x)) for x in v) + " }"

    wave = clip_of({"length": 0.5, "looped": False, "priority": "action", "keys": [
        {"t": 0, "pose": {"RightShoulder": [0, 0, 0], "RightElbow": [0, 0, 0]}},
        {"t": 0.2, "ease": "quadOut", "pose": {"RightShoulder": [20, 0, 150], "RightElbow": [60, 0, 0]}},
        {"t": 0.35, "ease": "backOut", "pose": {"RightShoulder": [10, 0, 120]}},
        {"t": 0.5, "pose": {"RightShoulder": [0, 0, 0], "RightElbow": [0, 0, 0]}}],
        "markers": [{"t": 0.25, "name": "hit"}]}, "wave")
    wave_loop = clip_of({"length": 1, "looped": True, "priority": "action", "keys": [
        {"t": 0, "pose": {"RightShoulder": [0, 0, 120]}}, {"t": 0.5, "pose": {"RightShoulder": [0, 0, 150]}},
        {"t": 1, "pose": {"RightShoulder": [0, 0, 120]}}]}, "wave_loop")
    walk_legs = clip_of({"length": 1, "looped": True, "priority": "movement", "keys": [
        {"t": 0, "pose": {"RightHip": [30, 0, 0], "LeftHip": [-30, 0, 0], "RightKnee": [-10, 0, 0]}},
        {"t": 0.5, "pose": {"RightHip": [-30, 0, 0], "LeftHip": [30, 0, 0], "RightKnee": [-60, 0, 0]}},
        {"t": 1, "pose": {"RightHip": [30, 0, 0], "LeftHip": [-30, 0, 0], "RightKnee": [-10, 0, 0]}}]}, "walk_legs")
    idle_sway = clip_of({"length": 2, "looped": True, "priority": "idle", "keys": [
        {"t": 0, "pose": {j: [2, 0, 1] for j in A.R15_ORDER}}, {"t": 1, "pose": {j: [-2, 0, -1] for j in A.R15_ORDER}},
        {"t": 2, "pose": {j: [2, 0, 1] for j in A.R15_ORDER}}]}, "idle_sway")
    t = 0.0
    for _ in range(15):                               # the time after 15 frames of 1/60, summed as the runtime does
        t += 1 / 60
    pose = A.sample_clip(wave, t)
    joints = ",\n".join(f'\t\t{{ name = "{j.name}", part0 = "{j.part0}", part1 = "{j.part1}", c0 = {vec(j.c0)}, '
                        f'c1 = {vec(j.c1)} }}' for j in A.R15_JOINTS)
    parts = ",\n".join(f'\t\t["{p}"] = {vec(o)}' for p, (_, o) in A.fk_r15({}).items())
    pack = A.pack_luau({"idle_sway": idle_sway, "walk_legs": walk_legs, "wave_loop": wave_loop})
    return (f"return {{\n\tjoints = {{\n{joints}\n\t}},\n\tparts = {{\n{parts}\n\t}},\n"
            f"\texpect = {{ wave = {vec(pose['RightShoulder'][0])}, waveElbow = {vec(pose['RightElbow'][0])} }},\n"
            f"\twave = {A.clip_luau(wave)},\n\tpackedName = \"idle_sway\",\n"
            f"\tpackSource = {lua_long_string(pack)},\n"
            f"\tanimSource = {lua_long_string((KIT / 'Anim.luau').read_text(encoding='utf-8'))},\n}}\n")


@needs_luau
def test_kit_anim_runs_against_a_fake_roblox(tmp_path):
    """Kit.Anim end to end: the pose it writes to Motor6D.Transform is the Python-sampled pose; markers and
    events fire once; it blends over the Animator's pose and leaves unposed joints alone; priorities override per
    joint; takeOver pauses and restores the rig's own tracks; bad data only warns; Bones rigs are skipped with one
    warning; lean / lookAt / breathe / recoil / squash move the right joints and settle back to rest; rotated C0 / C1
    still pose in character axes; packed clips load lazily; destroying the rig cleans up; 20 rigs animate."""
    out = run_luau(tmp_path, {"fake_roblox.luau": FAKE_ROBLOX, "anim_smoke.luau": ANIM_SMOKE,
                              "anim_data.luau": _smoke_data()}, "anim_smoke.luau")
    lines = out.splitlines()
    failed = [line for line in lines if line.startswith("FAIL")]
    assert not failed, "\n".join(failed)
    assert "DONE" in lines
    assert sum(line.startswith("OK ") for line in lines) == ANIM_SMOKE.count('check("')
    perf = next(line for line in lines if line.startswith("PERF"))
    print(perf)


def test_kit_modules_pass_the_luau_checker():
    from harness.tools.luau import analyzer, check_sources
    if analyzer() is None:
        pytest.skip("luau-analyze not found")
    sources = {f"src/ReplicatedStorage/Kit/{m}.luau": (KIT / f"{m}.luau").read_text(encoding="utf-8")
               for m in ("AnimCore", "Anim")}
    assert asyncio.run(check_sources(sources)) == {}

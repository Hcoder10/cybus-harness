"""Load and validate the benchmark's data files (ideas.yaml, aspects.yaml) plus small shared helpers.

Both loaders validate strictly and raise SpecError listing every problem, so a bad edit to either file
stops the bench before it spends hours building or money judging.
"""
from __future__ import annotations

import json
import os
import re
import tempfile
from datetime import datetime
from pathlib import Path
from typing import Any

import yaml

BENCH_DIR = Path(__file__).resolve().parent
REPO_ROOT = BENCH_DIR.parent
IDEAS_PATH = BENCH_DIR / "ideas.yaml"
ASPECTS_PATH = BENCH_DIR / "aspects.yaml"

ASPECT_IDS = ("ui_menus", "hud", "camera", "game_feel", "vfx", "animation", "world_art", "characters",
              "audio_design", "core_loop", "cohesion", "polish")
DONE_KEYS = ("core_loop", "title_menu", "hud", "signature_moment", "audio_feel")
ANCHOR_LEVELS = (1, 4, 7, 9)
EVIDENCE_KINDS = ("still", "strip", "log")
# The harness gets only these fields of an idea; genre, craft_focus and done stay with the scorer.
HARNESS_INPUT_KEYS = ("id", "title", "pitch")
# Nothing in the benchmark may resemble the owner's reference game. Matched as case-insensitive
# substrings of every string (and of the raw file text, comments included), so inflected forms count.
BANNED_TERMS = ("anime", "manga", "duel", "fight", "arena", "ultimate", "combat", "battle", "pvp", "roster")

_ID_RE = re.compile(r"^[a-z][a-z0-9_]*[a-z0-9]$")
_EVIDENCE_NAME_RE = re.compile(r"^[a-z0-9_*?]+$")
_FRAME_SUFFIX_RE = re.compile(r"__\d+$")


class SpecError(ValueError):
    """A benchmark data file is malformed or breaks a benchmark rule."""


def banned_hits(obj: Any, where: str = "") -> list[str]:
    """Every banned term found in any string (keys included) inside obj, as 'where: term'."""
    hits: list[str] = []
    if isinstance(obj, dict):
        for k, v in obj.items():
            hits += banned_hits(k, f"{where}.{k}(key)")
            hits += banned_hits(v, f"{where}.{k}")
    elif isinstance(obj, (list, tuple)):
        for i, v in enumerate(obj):
            hits += banned_hits(v, f"{where}[{i}]")
    elif isinstance(obj, str):
        low = obj.lower()
        hits += [f"{where or '<text>'}: {t!r}" for t in BANNED_TERMS if t in low]
    return hits


def _nonempty_str(x: Any) -> bool:
    return isinstance(x, str) and bool(x.strip())


def validate_ideas(data: Any) -> list[str]:
    errs: list[str] = []
    ideas = data.get("ideas") if isinstance(data, dict) else None
    if not isinstance(ideas, list) or not ideas:
        return ["top level must be a mapping with a non-empty 'ideas' list"]
    seen: set[str] = set()
    for i, idea in enumerate(ideas):
        at = f"ideas[{i}]"
        if not isinstance(idea, dict):
            errs.append(f"{at}: must be a mapping")
            continue
        iid = idea.get("id")
        at = f"ideas[{i}] ({iid})"
        if not isinstance(iid, str) or not _ID_RE.match(iid) or "__" in iid:
            errs.append(f"{at}: id must be snake_case without '__'")
        elif iid in seen:
            errs.append(f"{at}: duplicate id")
        else:
            seen.add(iid)
        for key in ("title", "genre", "pitch"):
            if not _nonempty_str(idea.get(key)):
                errs.append(f"{at}: '{key}' must be a non-empty string")
        pitch = idea.get("pitch")
        if isinstance(pitch, str):
            if "\n" in pitch.strip():
                errs.append(f"{at}: pitch must be one paragraph (use a folded '>-' block)")
            n = len(pitch.split())
            if not 60 <= n <= 260:
                errs.append(f"{at}: pitch has {n} words, expected 60-260")
        done = idea.get("done")
        if not isinstance(done, dict) or set(done) != set(DONE_KEYS):
            errs.append(f"{at}: 'done' must have exactly the keys {list(DONE_KEYS)}")
        else:
            errs += [f"{at}: done.{k} must be a non-empty string" for k in DONE_KEYS if not _nonempty_str(done[k])]
        focus = idea.get("craft_focus")
        if (not isinstance(focus, list) or not 1 <= len(focus) <= 4 or len(set(focus)) != len(focus)
                or any(f not in ASPECT_IDS for f in focus)):
            errs.append(f"{at}: craft_focus must list 1-4 distinct aspect ids from {list(ASPECT_IDS)}")
        extra = set(idea) - {"id", "title", "genre", "pitch", "done", "craft_focus"}
        if extra:
            errs.append(f"{at}: unknown keys {sorted(extra)}")
    errs += [f"banned term in ideas{h}" for h in banned_hits(ideas)]
    return errs


def _validate_evidence(at: str, ev: Any) -> list[str]:
    if not isinstance(ev, dict):
        return [f"{at}: evidence entries must be mappings"]
    errs = []
    name, kind = ev.get("name"), ev.get("kind")
    if not isinstance(name, str) or not _EVIDENCE_NAME_RE.match(name) or "__" in name or _FRAME_SUFFIX_RE.search(name):
        errs.append(f"{at}: bad evidence name {name!r} (lowercase, digits, '_', fnmatch wildcards; no '__')")
    if kind not in EVIDENCE_KINDS:
        errs.append(f"{at}: kind must be one of {EVIDENCE_KINDS}")
    if not isinstance(ev.get("required", False), bool):
        errs.append(f"{at}: 'required' must be true/false")
    if not _nonempty_str(ev.get("what")):
        errs.append(f"{at}: 'what' must say what to capture")
    if kind == "log":
        path = ev.get("path")
        if not isinstance(path, str) or not path.startswith("logs/") or ".." in path:
            errs.append(f"{at}: log evidence needs a 'path' under logs/")
    if "frames" in ev and not (isinstance(ev["frames"], int) and 2 <= ev["frames"] <= 24):
        errs.append(f"{at}: 'frames' must be an int in 2..24")
    return errs


def validate_aspects(data: Any) -> list[str]:
    if not isinstance(data, dict):
        return ["top level must be a mapping"]
    errs: list[str] = []
    if not isinstance(data.get("capture"), dict):
        errs.append("'capture' must be a mapping (the capture protocol)")
    scale = data.get("scale")
    if not isinstance(scale, dict) or set(scale) != set(range(0, 11)) or not all(_nonempty_str(v) for v in scale.values()):
        errs.append("'scale' must describe every level 0..10")
    aspects = data.get("aspects")
    if not isinstance(aspects, list):
        return errs + ["'aspects' must be a list"]
    ids = [a.get("id") if isinstance(a, dict) else None for a in aspects]
    if tuple(ids) != ASPECT_IDS:
        errs.append(f"aspect ids must be exactly {list(ASPECT_IDS)} in that order, got {ids}")
    for a in aspects:
        if not isinstance(a, dict):
            continue
        at = f"aspect {a.get('id')}"
        for key in ("title", "judges"):
            if not _nonempty_str(a.get(key)):
                errs.append(f"{at}: '{key}' must be a non-empty string")
        evidence = a.get("evidence")
        if not isinstance(evidence, list) or not evidence:
            errs.append(f"{at}: 'evidence' must be a non-empty list")
            evidence = []
        for j, ev in enumerate(evidence):
            errs += _validate_evidence(f"{at} evidence[{j}]", ev)
        names = [ev.get("name") for ev in evidence if isinstance(ev, dict)]
        if len(set(names)) != len(names):
            errs.append(f"{at}: duplicate evidence names")
        borrow = a.get("borrow", [])
        if not isinstance(borrow, list) or any(b not in ASPECT_IDS or b == a.get("id") for b in borrow):
            errs.append(f"{at}: 'borrow' must list other aspect ids")
            borrow = []
        has_images = any(isinstance(ev, dict) and ev.get("kind") in ("still", "strip") for ev in evidence)
        if not has_images and not borrow:
            errs.append(f"{at}: needs at least one still/strip entry or a 'borrow' list")
        mi = a.get("min_images", 1)
        if not isinstance(mi, int) or mi < 1:
            errs.append(f"{at}: 'min_images' must be an int >= 1")
        anchors = a.get("anchors")
        if not isinstance(anchors, dict) or not set(ANCHOR_LEVELS) <= set(anchors):
            errs.append(f"{at}: anchors must cover levels {list(ANCHOR_LEVELS)}")
        elif any(not isinstance(k, int) or not 1 <= k <= 10 or not _nonempty_str(v) for k, v in anchors.items()):
            errs.append(f"{at}: anchors must map ints 1..10 to non-empty text")
    errs += [f"banned term in aspects{h}" for h in banned_hits(data)]
    return errs


def _load(path: Path, validate) -> Any:
    path = Path(path)
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as e:
        raise SpecError(f"cannot read {path}: {e}") from e
    try:
        data = yaml.safe_load(text)
    except yaml.YAMLError as e:
        raise SpecError(f"{path}: invalid YAML: {e}") from e
    errs = validate(data) + [f"banned term in the raw text of {path.name}: {t!r}"
                             for t in BANNED_TERMS if t in text.lower()]
    if errs:
        raise SpecError(f"{path} failed validation:\n  - " + "\n  - ".join(dict.fromkeys(errs)))
    return data


def load_ideas(path: Path | str = IDEAS_PATH) -> list[dict]:
    return _load(Path(path), validate_ideas)["ideas"]


def load_aspects(path: Path | str = ASPECTS_PATH) -> dict:
    """The whole aspects document: {'version', 'capture', 'scale', 'aspects': [...]}."""
    return _load(Path(path), validate_aspects)


def harness_input(idea: dict) -> dict:
    """What build_game receives: the pitch (plus id and title). Never the scorer's fields."""
    return {k: idea[k] for k in HARNESS_INPUT_KEYS}


def now_iso() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def write_json(path: Path, obj: Any) -> None:
    """Atomic JSON write (temp file + replace) so a crash never leaves a half-written manifest."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=path.name + ".", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(obj, f, indent=2, ensure_ascii=False, default=str)
            f.write("\n")
        os.replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def read_json(path: Path, default: Any = None) -> Any:
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return default

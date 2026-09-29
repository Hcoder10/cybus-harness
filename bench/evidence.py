"""Evidence conventions: which captured files count as evidence for which aspect, and how they are
turned into the images a vision judge sees.

File conventions (paths relative to an idea's run_dir; bench/aspects.yaml lists the entries):

    captures/<tag>__<name>.png          a still. A pre-composited contact sheet is also just a still.
    captures/<tag>__<name>__<NN>.png    frame NN (00, 01, ... in time order) of the strip <name>
    captures/<tag>__<name>/<frame>.png  a strip stored as a folder of frames (natural file-name order)
    logs/<file>                         text logs, at the exact `path` a log entry names

    <tag>  = an aspect id (hud), several joined with '+' (hud+world_art), or 'all' (every aspect).
    <name> = matched against each entry's `name` pattern (fnmatch, e.g. menu_* matches menu_shop).
             A still's name must never end in __<digits>; that suffix marks a strip frame.
    .png, .jpg and .jpeg are accepted. Files with an unknown tag, or unreadable images, are reported
    as unmatched and never judged.

How an aspect's evidence is assembled, in order, capped at max_images (aspects.yaml capture.max_images
or a per-aspect override): the entries in the order written (1 file per exact name, up to 3 per
wildcard pattern); then for each `borrow` aspect its first own image (its first entry match, else its
first tagged file; never that aspect's borrowed or shared files); then files tagged 'all'; then any
other files tagged with the aspect. A required entry with no file is listed as missing; an aspect with
missing required entries, or fewer images than its min_images, is flagged incomplete but still judged.
An aspect with nothing at all scores 0 (bench/score.py). A strip becomes ONE contact-sheet image; a log
becomes ONE text image (head and tail when long), because the judge reads images only.
"""
from __future__ import annotations

import fnmatch
import functools
import io
import math
import re
import textwrap
from dataclasses import dataclass, field
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

IMAGE_EXTS = (".png", ".jpg", ".jpeg")
DEFAULT_STRIP_FRAMES = 8
PATTERN_LIMIT = 3          # files taken per wildcard entry (exact names take 1)
MAX_STILL_SIDE = 2048      # larger stills are downscaled before judging
_TAG_RE = re.compile(r"^[a-z0-9_]+(\+[a-z0-9_]+)*$")
_FRAME_RE = re.compile(r"^(?P<name>.+?)__(?P<idx>\d+)$")
_ERR_RE = re.compile(r"\b(error|exception|traceback|stack begin)\b|attempt to (index|call|perform|compare|concatenate)", re.I)
_WARN_RE = re.compile(r"\bwarn(ing)?\b|infinite yield possible", re.I)


@dataclass
class Capture:
    """One captured thing: a still (one file) or a strip (ordered frames)."""
    kind: str                     # still | strip
    tags: tuple[str, ...]
    name: str
    paths: list[Path]
    label: str                    # run_dir-relative, for reports


@dataclass
class Piece:
    """One image the judge will see for an aspect. judge() takes bare images, so the file label and
    what the capture is meant to show are drawn in a bar ABOVE the pixels (never over them)."""
    source: str                   # entry:<name> | borrow:<aspect> | all | extra
    kind: str                     # still | strip | log
    label: str
    paths: list[Path]
    caption: str = ""             # the evidence entry's `what`, when there is one

    def title(self) -> str:
        head = f"{self.label} (borrowed from {self.source[7:]})" if self.source.startswith("borrow:") else self.label
        return f"{head}: {self.caption}" if self.caption else head

    def image(self) -> bytes:
        if self.kind == "log":
            text = self.paths[0].read_text(encoding="utf-8", errors="replace")
            return text_image(self.label, text)
        if self.kind == "strip" and len(self.paths) > 1:
            return contact_sheet(self.paths, title=f"{self.title()} [{len(self.paths)} frames in time order]")
        return captioned(still_bytes(self.paths[0]), self.title())


@dataclass
class AspectEvidence:
    aspect: str
    pieces: list[Piece] = field(default_factory=list)
    missing: list[str] = field(default_factory=list)    # required entries with nothing captured
    short: str | None = None                             # set when fewer images than min_images

    @property
    def empty(self) -> bool:
        return not self.pieces

    @property
    def incomplete(self) -> bool:
        return bool(self.missing or self.short)

    def labels(self) -> list[str]:
        return [p.label for p in self.pieces]

    def images(self) -> list[bytes]:
        return [p.image() for p in self.pieces]


def _natural_key(s: str) -> list:
    return [int(t) if t.isdigit() else t.lower() for t in re.split(r"(\d+)", s)]


def _readable(p: Path) -> bool:
    try:
        with Image.open(p) as im:
            im.size
        return True
    except Exception:
        return False


def _rel(p: Path, root: Path) -> str:
    try:
        return p.relative_to(root).as_posix()
    except ValueError:
        return p.as_posix()


def scan(run_dir: Path, aspect_ids: tuple[str, ...] | list[str]) -> tuple[list[Capture], list[str]]:
    """All captures under run_dir/captures, plus 'path: reason' strings for files that match nothing."""
    run_dir = Path(run_dir)
    cap_dir = run_dir / "captures"
    known = set(aspect_ids) | {"all"}
    captures: list[Capture] = []
    unmatched: list[str] = []
    frames: dict[tuple[str, str, str], list[tuple[int, Path]]] = {}
    ignored = 0
    if not cap_dir.is_dir():
        return captures, unmatched

    def split(stem: str, p: Path) -> tuple[tuple[str, ...], str] | None:
        nonlocal ignored
        tag, sep, rest = stem.partition("__")
        if not sep or not rest or not tag:
            ignored += 1                               # not bench evidence (e.g. the harness's working captures)
            return None
        tags = tuple(tag.split("+")) if _TAG_RE.match(tag) else ()
        if not tags or any(t not in known for t in tags):
            unmatched.append(f"{_rel(p, run_dir)}: tag {tag!r} is not an aspect id or 'all'")
            return None
        return tags, rest

    for p in sorted(cap_dir.iterdir(), key=lambda q: _natural_key(q.name)):
        if p.is_dir():
            parsed = split(p.name, p)
            if parsed is None:
                continue
            imgs = sorted((q for q in p.iterdir() if q.suffix.lower() in IMAGE_EXTS),
                          key=lambda q: _natural_key(q.name))
            bad = [q for q in imgs if not _readable(q)]
            unmatched += [f"{_rel(q, run_dir)}: unreadable image" for q in bad]
            imgs = [q for q in imgs if q not in bad]
            if imgs:
                captures.append(Capture("strip", parsed[0], parsed[1], imgs, _rel(p, run_dir) + "/"))
            continue
        if p.suffix.lower() not in IMAGE_EXTS:
            continue                                   # sidecar notes, json, etc.
        parsed = split(p.stem, p)
        if parsed is None:
            continue
        if not _readable(p):
            unmatched.append(f"{_rel(p, run_dir)}: unreadable image")
            continue
        tags, rest = parsed
        m = _FRAME_RE.match(rest)
        if m:
            key = ("+".join(tags), m["name"], p.suffix.lower())
            frames.setdefault(key, []).append((int(m["idx"]), p))
        else:
            captures.append(Capture("still", tags, rest, [p], _rel(p, run_dir)))
    for (tag, name, ext), fr in frames.items():
        fr.sort(key=lambda t: t[0])
        captures.append(Capture("strip", tuple(tag.split("+")), name, [p for _, p in fr],
                                f"captures/{tag}__{name}__NN{ext}"))
    captures.sort(key=lambda c: (len(c.tags), _natural_key(c.label)))
    if ignored:
        unmatched.append(f"captures/: {ignored} file(s) not named <tag>__<name> ignored (not bench evidence)")
    return captures, unmatched


def expected_file(aspect_id: str, entry: dict) -> str:
    if entry["kind"] == "log":
        return entry["path"]
    base = f"captures/{aspect_id}__{entry['name']}"
    return base + ("__NN.png" if entry["kind"] == "strip" else ".png")


def _is_pattern(name: str) -> bool:
    return any(ch in name for ch in "*?[")


def gather(run_dir: Path, aspects_doc: dict) -> tuple[dict[str, AspectEvidence], list[str]]:
    """Evidence for every aspect of one run, plus the unmatched-file report."""
    run_dir = Path(run_dir)
    aspects = aspects_doc["aspects"]
    ids = [a["id"] for a in aspects]
    default_max = int(aspects_doc.get("capture", {}).get("max_images", 6))
    captures, unmatched = scan(run_dir, ids)
    tagged = {aid: [c for c in captures if aid in c.tags] for aid in ids}
    shared = [c for c in captures if "all" in c.tags]
    result: dict[str, AspectEvidence] = {}
    used: dict[str, set[int]] = {}

    for a in aspects:                                  # pass 1: the aspect's own entries
        ev, taken = AspectEvidence(a["id"]), set()
        for entry in a["evidence"]:
            if entry["kind"] == "log":
                p = run_dir / entry["path"]
                if p.is_file():
                    ev.pieces.append(Piece(f"entry:{entry['name']}", "log", entry["path"], [p]))
                elif entry.get("required"):
                    ev.missing.append(f"log {entry['path']}")
                continue
            matches = [c for c in tagged[a["id"]]
                       if id(c) not in taken and fnmatch.fnmatchcase(c.name, entry["name"])]
            for c in matches[:PATTERN_LIMIT if _is_pattern(entry["name"]) else 1]:
                ev.pieces.append(Piece(f"entry:{entry['name']}", c.kind, c.label, c.paths, entry["what"]))
                taken.add(id(c))
            if not matches and entry.get("required"):
                ev.missing.append(f"{entry['kind']} {expected_file(a['id'], entry)}")
        result[a["id"]], used[a["id"]] = ev, taken

    def first_own(aid: str) -> Piece | None:
        """What another aspect borrows: the first entry match, else any capture tagged with aid."""
        piece = next((p for p in result[aid].pieces if p.kind != "log"), None)
        if piece is None and tagged[aid]:
            c = tagged[aid][0]
            piece = Piece("extra", c.kind, c.label, c.paths)
        return piece

    own_first = {aid: first_own(aid) for aid in ids}
    for a in aspects:                                  # pass 2: borrowed, shared, extra
        ev, taken = result[a["id"]], used[a["id"]]
        seen = {tuple(p.paths) for p in ev.pieces}

        def add(piece: Piece) -> None:
            if tuple(piece.paths) not in seen:
                seen.add(tuple(piece.paths))
                ev.pieces.append(piece)

        for b in a.get("borrow", []):
            if own_first.get(b) is not None:
                src = own_first[b]
                add(Piece(f"borrow:{b}", src.kind, src.label, src.paths, src.caption))
        for c in shared:
            add(Piece("all", c.kind, c.label, c.paths))
        for c in tagged[a["id"]]:
            if id(c) not in taken:
                add(Piece("extra", c.kind, c.label, c.paths))
        ev.pieces = ev.pieces[: int(a.get("max_images", default_max))]
        need = int(a.get("min_images", 1))
        if ev.pieces and len(ev.pieces) < need:
            ev.short = f"only {len(ev.pieces)} image(s), at least {need} wanted"
    return result, unmatched


def evidence_plan(aspects_doc: dict) -> dict:
    """The capture plan handed to build_game: protocol + one item per evidence entry."""
    items = []
    for a in aspects_doc["aspects"]:
        for e in a["evidence"]:
            item = {"aspect": a["id"], "name": e["name"], "kind": e["kind"], "required": bool(e.get("required")),
                    "file": expected_file(a["id"], e), "what": e["what"]}
            if e["kind"] == "strip":
                item["frames"] = int(e.get("frames", DEFAULT_STRIP_FRAMES))
            items.append(item)
    return {"protocol": aspects_doc.get("capture", {}),
            "conventions": __doc__.split("File conventions", 1)[1].split("How an aspect", 1)[0].strip(),
            "borrow": {a["id"]: a["borrow"] for a in aspects_doc["aspects"] if a.get("borrow")},
            "items": items}


def coverage(run_dir: Path, aspects_doc: dict) -> dict:
    """Compact per-aspect evidence status for manifests: counts, missing entries, unmatched files."""
    ev, unmatched = gather(run_dir, aspects_doc)
    return {"aspects": {aid: {"images": len(e.pieces), "missing": e.missing + ([e.short] if e.short else [])}
                        for aid, e in ev.items()},
            "no_evidence": [aid for aid, e in ev.items() if e.empty],
            "unmatched": unmatched}


def log_summary(path: Path) -> dict:
    lines = Path(path).read_text(encoding="utf-8", errors="replace").splitlines()
    return {"lines": len(lines),
            "errors": sum(1 for ln in lines if _ERR_RE.search(ln)),
            "warnings": sum(1 for ln in lines if _WARN_RE.search(ln))}


# ----------------------------------------------------------------------------- image helpers

@functools.lru_cache(maxsize=16)
def _font(size: int, mono: bool = False):
    names = (("consola.ttf", "DejaVuSansMono.ttf", "Menlo.ttc", "cour.ttf") if mono
             else ("segoeui.ttf", "arial.ttf", "DejaVuSans.ttf", "Helvetica.ttc"))
    for n in names:
        try:
            return ImageFont.truetype(n, size)
        except OSError:
            continue
    try:
        return ImageFont.load_default(size=size)
    except TypeError:                                  # Pillow < 10.1
        return ImageFont.load_default()


def _png(img: Image.Image) -> bytes:
    buf = io.BytesIO()
    img.save(buf, "PNG")
    return buf.getvalue()


def _fit(text: str, font, max_w: float) -> str:
    if font.getlength(text) <= max_w:
        return text
    keep = max(1, int(len(text) * max_w / max(1.0, font.getlength(text))))
    while keep > 1 and font.getlength(text[:keep] + "...") > max_w:
        keep -= 1
    return text[:keep] + "..."


def captioned(data: bytes, caption: str) -> bytes:
    """The image with a caption bar added above it; sized to stay legible after a 1280 px downscale."""
    with Image.open(io.BytesIO(data)) as src:
        im = src.convert("RGB")
    size = max(16, im.width // 64)
    font, bar = _font(size), size + 16
    canvas = Image.new("RGB", (im.width, im.height + bar), (18, 18, 22))
    canvas.paste(im, (0, bar))
    ImageDraw.Draw(canvas).text((10, 7), _fit(caption, font, im.width - 20), fill=(240, 240, 240), font=font)
    return _png(canvas)


def still_bytes(path: Path) -> bytes:
    """The file's bytes, re-encoded only when it is too large or not PNG/JPEG-safe."""
    data = Path(path).read_bytes()
    with Image.open(io.BytesIO(data)) as im:
        if max(im.size) <= MAX_STILL_SIDE and im.format in ("PNG", "JPEG"):
            return data
        im = im.convert("RGB")
        im.thumbnail((MAX_STILL_SIDE, MAX_STILL_SIDE))
        return _png(im)


def contact_sheet(paths: list[Path], cols: int = 4, width: int = 1280, title: str | None = None) -> bytes:
    """Frames in a labelled grid (1/N, 2/N, ...) so one image carries a whole strip."""
    frames = []
    for p in paths:
        with Image.open(p) as im:
            frames.append(im.convert("RGB"))
    n = len(frames)
    cols = max(1, min(cols, n))
    rows = math.ceil(n / cols)
    cw = width // cols
    w0, h0 = frames[0].size
    ch = max(1, round(cw * h0 / max(1, w0)))
    head, lab = (30 if title else 0), 20
    sheet = Image.new("RGB", (cw * cols, head + rows * (ch + lab)), (18, 18, 22))
    draw = ImageDraw.Draw(sheet)
    if title:
        draw.text((8, 6), title, fill=(240, 240, 240), font=_font(16))
    for i, im in enumerate(frames):
        r, c = divmod(i, cols)
        x0, y0 = c * cw, head + r * (ch + lab)
        draw.text((x0 + 6, y0 + 2), f"{i + 1}/{n}", fill=(250, 210, 120), font=_font(13))
        im.thumbnail((cw - 4, ch - 2))
        sheet.paste(im, (x0 + (cw - im.width) // 2, y0 + lab + (ch - im.height) // 2))
    return _png(sheet)


def text_image(title: str, text: str, width: int = 1280, max_lines: int = 64, size: int = 15) -> bytes:
    """Render a log as a readable monospace image; long logs keep their head and tail."""
    font = _font(size, mono=True)
    cols = max(20, int((width - 24) // max(1.0, font.getlength("M"))))
    lines: list[str] = []
    for ln in text.replace("\t", "    ").splitlines():
        lines += textwrap.wrap(ln, cols, break_long_words=True, replace_whitespace=False) or [""]
    total = len(lines)
    if total > max_lines:
        head = max_lines // 3
        tail = max_lines - head - 1
        lines = lines[:head] + [f"... {total - head - tail} lines omitted ..."] + lines[-tail:]
    line_h = size + 5
    img = Image.new("RGB", (width, 44 + line_h * max(1, len(lines)) + 10), (14, 16, 20))
    draw = ImageDraw.Draw(img)
    draw.text((12, 10), f"{title}  ({len(text.splitlines())} lines)", fill=(240, 200, 120), font=_font(size + 3))
    y = 44
    for ln in lines or ["(empty)"]:
        draw.text((12, y), ln, fill=(215, 220, 225), font=font)
        y += line_h
    return _png(img)

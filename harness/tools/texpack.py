"""Texture packs: a compact lossless image codec with a small, fast Luau decoder (Kit/TexCodec.luau), and the
generated modules that carry painted textures into the game.

    entry = encode(img)            # {"w", "h", "fmt": "RGBA" | "LA", "data": str, "checksum": int}
    rgba = decode(entry)           # the RGBA8 bytes TexCodec.decode returns in the game (reference decoder)
    packs = TexturePacks(workspace)
    packs.add("panel_skin", img, slice=[28, 28, 68, 68])

Codec (version 1). Channels are coded as planes, alpha first, then R, G, B (RGBA) or L (LA). Each row of each
plane picks the predictor that codes it best (2 bits per row):
    0 left   p = a          1 up   p = b          2 average   p = (a + b) >> 1
    3 gradient   p = clamp(a + b - c, 0, 255)     (a = left, b = above, c = above-left; 0 outside the image)
The residual (x - p) mod 256 is zigzagged (0, -1, 1, -2, ... -> 0, 1, 2, 3, ...) and the plane bytes form one
stream of symbols: 0..255 a residual, 256 + k a run of zeros of length n + 2, where n has k bits (k = 0: n = 0,
k = 1: n = 1, k >= 2: n = 2^(k-1) + the next k-1 bits). Symbols are Huffman coded (canonical, LSB first, at most
12 bits, one table per texture), so flat areas and transparent space cost almost nothing and smooth gradients and
glows cost a few bits per pixel. On panels, buttons, icons, glows and noise this lands near PNG size (usually under
it); there is no LZ stage, so long repeating patterns (e.g. the rounding pattern of a full-texture diagonal
gradient) cost more than in PNG.

Byte layout (integers little-endian):
    u8 version (1) | u8 channels (2 or 4) | u16 width | u16 height | u8 literal symbols - 1 | u8 run symbols
    row predictors: 2 bits per row, planes in order, LSB first     (ceil(height * channels / 4) bytes)
    code lengths: 4 bits each for symbols 0 .. nlit-1, then 256 .. 256+nrun-1, low nibble first
    Huffman bitstream, then zero padding (at least 4 bytes, up to a multiple of 4)
Text: base85, each little-endian u32 -> 5 characters, most significant digit first, alphabet ALPHABET (it has no
quote or backslash, so the text sits in a plain Luau string). Checksum: Adler-32 of the decoded RGBA8 pixels
(an LA texture decodes to R = G = B = L).

Packs: ReplicatedStorage/Shared/TexPacks/Index.luau maps name -> {pack, w, h, fmt, slice, checksum}, and
Pack<n>.luau modules each return {name = data}; every module stays under 150,000 characters (a texture larger
than that is split over several packs and `pack` lists them in order). The manifest (texpacks.json in the
workspace root) keeps each texture's data and packs so the modules can be rebuilt; a texture stays in its pack
while it fits, so adding or replacing one texture rewrites only its pack and the index, and the same manifest
always produces the same files.
"""
from __future__ import annotations

import heapq
import json
import os
import re
import struct
import threading
import zlib
from pathlib import Path
from typing import TYPE_CHECKING, Any

import numpy as np
from PIL import Image

if TYPE_CHECKING:
    from harness.tools.workspace import Workspace

VERSION = 1
MAX_CODE_BITS = 12
RUN_BASE = 256
ALPHABET = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-:+=^!/*?&<>()[]{}@%$#"
_ENC = np.frombuffer(ALPHABET.encode("ascii"), dtype=np.uint8)
_DEC = np.full(256, 255, dtype=np.uint8)
_DEC[_ENC] = np.arange(85, dtype=np.uint8)
NAME_RE = re.compile(r"^[a-z0-9_]{1,64}$")


# ------------------------------------------------------------------------------------------------ helpers

def _as_texture(img: Image.Image) -> tuple[str, np.ndarray]:
    """-> (fmt, pixels (h, w, channels) uint8) for RGBA or LA; other modes are converted."""
    if img.mode not in ("RGBA", "LA"):
        img = img.convert("LA" if img.mode in ("1", "L", "I", "I;16", "F") else "RGBA")
    return img.mode, np.asarray(img, dtype=np.uint8)


def rgba_bytes(img: Image.Image) -> bytes:
    """The RGBA8 pixels the game ends up with (LA expanded to R = G = B = L)."""
    fmt, a = _as_texture(img)
    if fmt == "LA":
        a = np.stack([a[..., 0], a[..., 0], a[..., 0], a[..., 1]], axis=2)
    return np.ascontiguousarray(a).tobytes()


def checksum(rgba: bytes) -> int:
    """Adler-32 of RGBA8 pixel bytes (what TexCodec.checksum computes in Luau)."""
    return zlib.adler32(rgba) & 0xFFFFFFFF


def b85encode(data: bytes) -> str:
    if len(data) % 4:
        raise ValueError("base85 input must be a multiple of 4 bytes")
    v = np.frombuffer(data, dtype="<u4").astype(np.uint64)
    digits = np.empty((len(v), 5), dtype=np.uint8)
    for i in range(4, -1, -1):
        digits[:, i] = (v % 85).astype(np.uint8)
        v //= 85
    return _ENC[digits].tobytes().decode("ascii")


def b85decode(text: str) -> bytes:
    raw = np.frombuffer(text.encode("ascii"), dtype=np.uint8)
    if len(raw) % 5:
        raise ValueError("base85 text length must be a multiple of 5")
    d = _DEC[raw]
    if (d == 255).any():
        raise ValueError("base85 text has a character outside the alphabet")
    d = d.reshape(-1, 5).astype(np.uint64)
    v = (((d[:, 0] * 85 + d[:, 1]) * 85 + d[:, 2]) * 85 + d[:, 3]) * 85 + d[:, 4]
    if (v > 0xFFFFFFFF).any():
        raise ValueError("base85 group out of range")
    return v.astype("<u4").tobytes()


def _residuals(plane: np.ndarray) -> np.ndarray:
    """Zigzagged residuals of a plane under each of the 4 predictors: (4, h, w) uint8."""
    p = plane.astype(np.int16)
    a = np.zeros_like(p)
    a[:, 1:] = p[:, :-1]
    b = np.zeros_like(p)
    b[1:, :] = p[:-1, :]
    c = np.zeros_like(p)
    c[1:, 1:] = p[:-1, :-1]
    out = np.empty((4,) + p.shape, dtype=np.uint8)
    for i, pred in enumerate((a, b, (a + b) >> 1, np.clip(a + b - c, 0, 255))):
        r = (p - pred) & 255
        out[i] = np.where(r < 128, r * 2, (256 - r) * 2 - 1)
    return out


def _bit_length(n: np.ndarray) -> np.ndarray:
    return np.frexp(n.astype(np.float64))[1].astype(np.int64)


def _tokens(stream: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Residual bytes -> (symbols, extra-bit values, extra-bit counts): zero runs of 2+ become run symbols."""
    n = len(stream)
    z = np.concatenate(([0], (stream == 0).astype(np.int8), [0]))
    edges = np.flatnonzero(np.diff(z))
    starts, lens = edges[0::2], edges[1::2] - edges[0::2]
    long = lens >= 2
    ls, ll = starts[long], lens[long]
    marks = np.zeros(n + 1, dtype=np.int32)
    np.add.at(marks, ls + 1, 1)
    np.add.at(marks, ls + ll, -1)
    keep = np.cumsum(marks[:n]) == 0
    syms = stream.astype(np.int64)
    extra = np.zeros(n, dtype=np.int64)
    ebits = np.zeros(n, dtype=np.int64)
    m = (ll - 2).astype(np.int64)
    k = _bit_length(m)
    syms[ls] = RUN_BASE + k
    eb = np.maximum(k - 1, 0)
    ebits[ls] = eb
    extra[ls] = np.where(k >= 2, m - (np.int64(1) << eb), 0)
    return syms[keep], extra[keep], ebits[keep]


def _code_lengths(freq: dict[int, int]) -> dict[int, int]:
    """Huffman code lengths, at most MAX_CODE_BITS (frequencies are flattened until the tree is shallow enough)."""
    used = sorted(s for s, f in freq.items() if f > 0)
    if len(used) == 1:
        return {used[0]: 1}
    f = {s: freq[s] for s in used}
    while True:
        heap = [(f[s], i, [s]) for i, s in enumerate(used)]
        heapq.heapify(heap)
        depth = dict.fromkeys(used, 0)
        order = len(heap)
        while len(heap) > 1:
            w1, _, s1 = heapq.heappop(heap)
            w2, _, s2 = heapq.heappop(heap)
            for s in s1 + s2:
                depth[s] += 1
            heapq.heappush(heap, (w1 + w2, order, s1 + s2))
            order += 1
        if max(depth.values()) <= MAX_CODE_BITS:
            return depth
        f = {s: (v + 1) // 2 for s, v in f.items()}


def _canonical(lengths: dict[int, int]) -> dict[int, int]:
    """Symbol -> canonical code, bit-reversed so the stream can be read LSB first."""
    count = [0] * (MAX_CODE_BITS + 1)
    for L in lengths.values():
        count[L] += 1
    count[0] = 0
    nxt = [0] * (MAX_CODE_BITS + 2)
    code = 0
    for bits in range(1, MAX_CODE_BITS + 1):
        code = (code + count[bits - 1]) << 1
        nxt[bits] = code
    out = {}
    for s in sorted(lengths):
        L = lengths[s]
        c = nxt[L]
        nxt[L] += 1
        out[s] = int(f"{c:0{L}b}"[::-1], 2)
    return out


def _pack_bits(vals: np.ndarray, nbits: np.ndarray) -> bytes:
    """Concatenate values of nbits each, LSB first. Bit ranges are disjoint, so summing bytes is OR-ing them."""
    if len(vals) == 0:
        return b""
    starts = np.cumsum(nbits) - nbits
    total = int(nbits.sum())
    nbytes = (total + 7) // 8
    b0 = starts >> 3
    v = vals.astype(np.uint64) << (starts & 7).astype(np.uint64)
    acc = np.zeros(nbytes + 8, dtype=np.float64)
    for j in range(6):
        part = ((v >> np.uint64(8 * j)) & np.uint64(255)).astype(np.float64)
        nz = part != 0
        if nz.any():
            acc += np.bincount(b0[nz] + j, weights=part[nz], minlength=len(acc))
    return acc[:nbytes].astype(np.uint8).tobytes()


# ------------------------------------------------------------------------------------------------ codec

def encode(img: Image.Image) -> dict:
    """Image (RGBA or LA; others are converted) -> {w, h, fmt, data, checksum}. Deterministic."""
    fmt, px = _as_texture(img)
    h, w, ch = px.shape
    if not (1 <= w <= 65535 and 1 <= h <= 65535):
        raise ValueError(f"texture size {w}x{h} is out of range")
    planes = [px[..., 3], px[..., 0], px[..., 1], px[..., 2]] if fmt == "RGBA" else [px[..., 1], px[..., 0]]
    filters, parts = [], []
    rows = np.arange(h)
    for plane in planes:
        res = _residuals(plane)
        cost = np.log2(1.0 + res.astype(np.float32)).sum(axis=2)       # (4, h)
        choice = cost.argmin(axis=0)
        filters.append(choice)
        parts.append(res[choice, rows].ravel())
    stream = np.concatenate(parts)
    syms, extra, ebits = _tokens(stream)
    freq = {int(s): int(c) for s, c in zip(*np.unique(syms, return_counts=True))}
    lengths = _code_lengths(freq)
    codes = _canonical(lengths)
    lits = [s for s in lengths if s < RUN_BASE]
    runs = [s - RUN_BASE for s in lengths if s >= RUN_BASE]
    nlit = (max(lits) + 1) if lits else 1
    nrun = (max(runs) + 1) if runs else 0
    order = list(range(nlit)) + [RUN_BASE + k for k in range(nrun)]
    lut_len = np.zeros(RUN_BASE + 32, dtype=np.int64)
    lut_code = np.zeros(RUN_BASE + 32, dtype=np.int64)
    for s, L in lengths.items():
        lut_len[s], lut_code[s] = L, codes[s]
    nb = lut_len[syms] + ebits
    vals = lut_code[syms] | (extra << lut_len[syms])
    bits = _pack_bits(vals, nb)

    f = np.concatenate(filters).astype(np.uint8)
    f = np.concatenate([f, np.zeros((-len(f)) % 4, dtype=np.uint8)]).reshape(-1, 4)
    flag_bytes = (f[:, 0] | (f[:, 1] << 2) | (f[:, 2] << 4) | (f[:, 3] << 6)).astype(np.uint8).tobytes()
    nib = np.array([lengths.get(s, 0) for s in order] + [0] * (len(order) % 2), dtype=np.uint8).reshape(-1, 2)
    len_bytes = (nib[:, 0] | (nib[:, 1] << 4)).astype(np.uint8).tobytes()
    payload = (struct.pack("<BBHHBB", VERSION, ch, w, h, nlit - 1, nrun) + flag_bytes + len_bytes + bits
               + b"\0\0\0\0")
    payload += b"\0" * ((-len(payload)) % 4)
    return {"w": int(w), "h": int(h), "fmt": fmt, "data": b85encode(payload), "checksum": checksum(rgba_bytes(img))}


def decode(entry: dict) -> bytes:
    """Reference decoder: an encode() entry -> RGBA8 pixel bytes (w * h * 4), as TexCodec.decode returns them."""
    raw = b85decode(entry["data"])
    version, ch, w, h, nlit1, nrun = struct.unpack_from("<BBHHBB", raw, 0)
    if version != VERSION:
        raise ValueError(f"unsupported texture codec version {version}")
    if (w, h) != (entry.get("w", w), entry.get("h", h)) or ch != {"RGBA": 4, "LA": 2}.get(entry.get("fmt", ""), ch):
        raise ValueError("texture header does not match its entry")
    nlit = nlit1 + 1
    pos = 8
    nrows = h * ch
    flags = raw[pos:pos + (nrows + 3) // 4]
    pos += (nrows + 3) // 4
    filters = [(flags[i >> 2] >> ((i & 3) * 2)) & 3 for i in range(nrows)]
    order = list(range(nlit)) + [RUN_BASE + k for k in range(nrun)]
    nib = raw[pos:pos + (len(order) + 1) // 2]
    pos += (len(order) + 1) // 2
    lengths = {s: (nib[i >> 1] >> ((i & 1) * 4)) & 15 for i, s in enumerate(order)}
    lengths = {s: L for s, L in lengths.items() if L}
    codes = _canonical(lengths) if lengths else {}
    size = 1 << MAX_CODE_BITS
    table_sym = [0] * size
    table_len = [0] * size
    for s, c in codes.items():
        L = lengths[s]
        for i in range(c, size, 1 << L):
            table_sym[i], table_len[i] = s, L
    n = w * h * ch
    stream = bytearray(n)
    o, bp = 0, pos * 8
    mask = size - 1

    def peek(bp: int, nbits: int) -> int:
        i = bp >> 3
        return (int.from_bytes(raw[i:i + 4], "little") >> (bp & 7)) & ((1 << nbits) - 1)

    while o < n:
        idx = peek(bp, MAX_CODE_BITS) & mask
        L = table_len[idx]
        if L == 0:
            raise ValueError("corrupt texture bitstream")
        s = table_sym[idx]
        bp += L
        if s < RUN_BASE:
            stream[o] = s
            o += 1
        else:
            k = s - RUN_BASE
            m = k
            if k >= 2:
                m = (1 << (k - 1)) + peek(bp, k - 1)
                bp += k - 1
            o += m + 2
    if o != n:
        raise ValueError("corrupt texture bitstream (run past the end)")
    z = np.frombuffer(bytes(stream), dtype=np.uint8).astype(np.int64)
    delta = np.where(z & 1, 255 - (z >> 1), z >> 1).reshape(ch, h, w)
    planes = np.zeros((ch, h, w), dtype=np.int64)
    for pi in range(ch):
        for y in range(h):
            f = filters[pi * h + y]
            d = delta[pi, y]
            up = planes[pi, y - 1] if y > 0 else np.zeros(w, dtype=np.int64)
            if f == 0:
                planes[pi, y] = np.cumsum(d) & 255
            elif f == 1:
                planes[pi, y] = (up + d) & 255
            else:
                row = planes[pi, y]
                a = c = 0
                for x in range(w):
                    b = int(up[x])
                    p = (a + b) >> 1 if f == 2 else min(255, max(0, a + b - c))
                    a = (p + int(d[x])) & 255
                    row[x] = a
                    c = b
    px = planes.astype(np.uint8)
    if ch == 4:
        rgba = np.stack([px[1], px[2], px[3], px[0]], axis=2)
    else:
        rgba = np.stack([px[1], px[1], px[1], px[0]], axis=2)
    return np.ascontiguousarray(rgba).tobytes()


# ------------------------------------------------------------------------------------------------ packs

def check_name(name: str) -> str:
    if not isinstance(name, str) or not NAME_RE.match(name):
        raise ValueError(f"bad texture name {name!r}: use 1-64 lowercase letters, digits and underscores, "
                         f"e.g. panel_skin")
    return name


def check_slice(slc: Any, w: int, h: int) -> list[int] | None:
    if slc is None:
        return None
    if (not isinstance(slc, (list, tuple)) or len(slc) != 4
            or not all(isinstance(v, (int, float)) and not isinstance(v, bool) and float(v) == int(v) for v in slc)):
        raise ValueError(f"slice must be [x0, y0, x1, y1] in whole pixels, got {slc!r}")
    x0, y0, x1, y1 = (int(v) for v in slc)
    if not (0 <= x0 < x1 <= w and 0 <= y0 < y1 <= h):
        raise ValueError(f"slice {list(slc)} must satisfy 0 <= x0 < x1 <= {w} and 0 <= y0 < y1 <= {h}")
    return [x0, y0, x1, y1]


class TexturePacks:
    """A game's painted textures: the manifest on disk and the generated Index / Pack<n> modules."""

    DIR = "ReplicatedStorage/Shared/TexPacks"
    INDEX = DIR + "/Index.luau"
    MODULE_LIMIT = 150_000
    MANIFEST = "texpacks.json"
    HEADER = "-- Generated by cybus-harness (harness/tools/texpack.py): {what}. Do not edit; use Kit.Textures.\n"

    def __init__(self, workspace: "Workspace", manifest: Path | None = None) -> None:
        self.ws = workspace
        self.manifest = Path(manifest) if manifest else Path(workspace.root) / self.MANIFEST
        self.textures: dict[str, dict] = {}
        self._lock = threading.RLock()     # builders may share one TexturePacks
        try:
            data = json.loads(self.manifest.read_text(encoding="utf-8"))
            if isinstance(data, dict) and isinstance(data.get("textures"), dict):
                self.textures = data["textures"]
        except (OSError, ValueError):
            pass

    # ---------------------------------------------------------------------------------------- api

    def add(self, name: str, img: Image.Image, slice: Any = None) -> dict:
        """Encode and add (or replace) a texture, then rewrite the modules. Returns info(name)."""
        check_name(name)
        entry = encode(img)
        entry["slice"] = check_slice(slice, entry["w"], entry["h"])
        with self._lock:
            entry["packs"] = (self.textures.get(name) or {}).get("packs") or []
            self.textures[name] = entry
            self.write()
            return self.info(name)  # type: ignore[return-value]

    def remove(self, name: str) -> bool:
        with self._lock:
            if name not in self.textures:
                return False
            del self.textures[name]
            self.write()
            return True

    def names(self) -> list[str]:
        with self._lock:
            return sorted(self.textures)

    def info(self, name: str) -> dict | None:
        with self._lock:
            e = self.textures.get(name)
            if e is None:
                return None
            return {"name": name, "w": e["w"], "h": e["h"], "fmt": e["fmt"], "slice": e.get("slice"),
                    "checksum": e["checksum"], "packs": list(e.get("packs") or []), "chars": len(e["data"])}

    def data(self, name: str) -> dict | None:
        """The full encode() entry of a texture (for tests and tools)."""
        with self._lock:
            e = self.textures.get(name)
            return None if e is None else {k: e[k] for k in ("w", "h", "fmt", "data", "checksum")}

    # ---------------------------------------------------------------------------------------- writing

    def _budget(self) -> int:
        return self.MODULE_LIMIT - 1 - len(self.HEADER.format(what="texture data")) - len("return {\n}\n")

    @staticmethod
    def _line(name: str, part: str) -> str:
        return f'\t["{name}"] = "{part}",\n'

    def _assign(self) -> dict[int, list[tuple[str, int, str]]]:
        """Place every texture chunk in a pack: keep its previous pack while it fits, else first fit."""
        budget = self._budget()
        items = []
        for name in sorted(self.textures):
            e = self.textures[name]
            chunk = budget - len(self._line(name, ""))
            data = e["data"]
            parts = [data[i:i + chunk] for i in range(0, len(data), chunk)] or [""]
            prefs = e.get("packs") or []
            for i, part in enumerate(parts):
                pref = prefs[i] if i < len(prefs) and isinstance(prefs[i], int) and prefs[i] >= 1 else None
                items.append((name, i, part, pref))
        packs: dict[int, list[tuple[str, int, str]]] = {}
        used: dict[int, int] = {}
        owners: dict[int, set[str]] = {}

        def fits(n: int, name: str, cost: int) -> bool:
            return used.get(n, 0) + cost <= budget and name not in owners.get(n, set())

        def place(n: int, name: str, i: int, part: str, cost: int) -> None:
            packs.setdefault(n, []).append((name, i, part))
            used[n] = used.get(n, 0) + cost
            owners.setdefault(n, set()).add(name)

        pending = []
        for name, i, part, pref in sorted((it for it in items if it[3] is not None), key=lambda it: (it[3], it[0], it[1])):
            cost = len(self._line(name, part))
            if fits(pref, name, cost):
                place(pref, name, i, part, cost)
            else:
                pending.append((name, i, part))
        pending += [(name, i, part) for name, i, part, pref in items if pref is None]
        for name, i, part in sorted(pending, key=lambda it: (it[0], it[1])):
            cost = len(self._line(name, part))
            n = 1
            while not fits(n, name, cost):
                n += 1
            place(n, name, i, part, cost)
        return packs

    def write(self) -> list[str]:
        """Rewrite Index.luau and every Pack<n>.luau from the manifest, drop stale packs, save the manifest.
        Returns the module paths (under src/) that now exist."""
        with self._lock:
            return self._write()

    def _write(self) -> list[str]:
        packs = self._assign()
        chunks: dict[str, dict[int, int]] = {}
        for n, entries in packs.items():
            for name, i, _ in entries:
                chunks.setdefault(name, {})[i] = n
        for name, e in self.textures.items():
            e["packs"] = [chunks[name][i] for i in sorted(chunks.get(name, {}))]
        count = max(packs) if packs else 0
        written = []
        for n in range(1, count + 1):
            body = "".join(self._line(name, part) for name, _, part in sorted(packs.get(n, []), key=lambda it: it[0]))
            src = self.HEADER.format(what="texture data") + "return {\n" + body + "}\n"
            if len(src) >= self.MODULE_LIMIT:
                raise RuntimeError(f"Pack{n} would be {len(src)} characters")
            rel = f"{self.DIR}/Pack{n}.luau"
            self.ws.write(rel, src)
            written.append(rel)
        self.ws.write(self.INDEX, self.index_source())
        written.append(self.INDEX)
        pack_dir = Path(self.ws.src) / self.DIR
        if pack_dir.is_dir():
            for f in pack_dir.glob("Pack*.luau"):
                m = re.fullmatch(r"Pack(\d+)\.luau", f.name)
                if m and int(m.group(1)) > count:
                    f.unlink()
        self._save()
        return written

    def index_source(self) -> str:
        lines = [self.HEADER.format(what="the texture index (name -> pack, size, format, 9-slice centre, "
                                         "checksum)"), "return {\n"]
        for name in sorted(self.textures):
            e = self.textures[name]
            packs = e.get("packs") or [0]
            pack = str(packs[0]) if len(packs) == 1 else "{ " + ", ".join(str(p) for p in packs) + " }"
            slc = e.get("slice")
            slice_s = f", slice = {{ {', '.join(str(int(v)) for v in slc)} }}" if slc else ""
            lines.append(f'\t["{name}"] = {{ pack = {pack}, w = {e["w"]}, h = {e["h"]}, fmt = "{e["fmt"]}"{slice_s}, '
                         f'checksum = {e["checksum"]} }},\n')
        lines.append("}\n")
        return "".join(lines)

    def _save(self) -> None:
        self.manifest.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.manifest.with_name(self.manifest.name + ".tmp")
        tmp.write_text(json.dumps({"version": VERSION, "textures": self.textures}, indent=1, sort_keys=True),
                       encoding="utf-8")
        os.replace(tmp, self.manifest)


__all__ = ["ALPHABET", "TexturePacks", "b85decode", "b85encode", "check_name", "check_slice", "checksum", "decode",
           "encode", "rgba_bytes"]

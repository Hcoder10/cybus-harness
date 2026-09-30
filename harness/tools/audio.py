"""Finding sound for a game without uploading any: search the Roblox Creator Store's public audio.

Every result is a public, distributed Creator Store asset the game can play by id. Sounds by the "Roblox"
account (licensed library) rank first, then verified creators. Loading is checked later, in Studio, through
the kit's Sound.manifest() (IsLoaded / TimeLength), which the audio review reads.
"""
from __future__ import annotations

import asyncio
import json
import logging
import time
from pathlib import Path

import urllib.error
import urllib.parse
import urllib.request

log = logging.getLogger("harness.audio")

SEARCH_URL = "https://apis.roblox.com/toolbox-service/v2/assets:search"


def _row(item: dict) -> dict | None:
    asset = item.get("asset") or {}
    aid = asset.get("id")
    if not aid:
        return None
    creator = item.get("creator") or {}
    votes = item.get("voting") or {}
    return {"id": int(aid), "title": str(asset.get("title") or asset.get("name") or "")[:80],
            "creator": str(creator.get("name") or ""), "verified": bool(creator.get("verified")),
            "seconds": float(asset.get("durationSeconds") or 0), "type": str(asset.get("audioType") or ""),
            "up": int(votes.get("upVotes") or 0), "down": int(votes.get("downVotes") or 0)}


def rank(rows: list[dict], kind: str | None = None) -> list[dict]:
    def score(r: dict) -> tuple:
        want_music = kind == "music"
        type_ok = (r["type"] == "Music") == want_music if kind in ("music", "sfx") else True
        length_ok = (r["seconds"] >= 20) if want_music else (0 < r["seconds"] <= 12) if kind == "sfx" else True
        return (not type_ok, not length_ok, r["creator"] != "Roblox", not r["verified"], -(r["up"] - r["down"]))
    return sorted(rows, key=score)


class AudioSearch:
    def __init__(self, cache_file: Path | None = None) -> None:
        self.cache_file = cache_file
        self._cache: dict[str, list[dict]] = {}
        if cache_file and cache_file.exists():
            try:
                self._cache = json.loads(cache_file.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                self._cache = {}
        self._lock = asyncio.Lock()
        self._last = 0.0

    async def search(self, query: str, kind: str | None = None, limit: int = 8) -> list[dict]:
        key = query.strip().lower()
        if key not in self._cache:
            async with self._lock:                        # be polite to the public endpoint: one at a time
                wait = 1.0 - (time.monotonic() - self._last)
                if wait > 0:
                    await asyncio.sleep(wait)
                rows = await self._fetch(key)
                self._last = time.monotonic()
            self._cache[key] = rows
            if self.cache_file:
                try:
                    self.cache_file.write_text(json.dumps(self._cache), encoding="utf-8")
                except OSError:
                    pass
        return rank(self._cache[key], kind)[:limit]

    async def _fetch(self, query: str) -> list[dict]:
        # urllib, not httpx: in one venv (the model server's, with extra compression codecs) every httpx request
        # to this endpoint timed out while urllib and curl answered in 0.3 s.
        params = urllib.parse.urlencode({"searchCategoryType": "Audio", "query": query, "maxPageSize": 40})

        def get() -> tuple[int, bytes]:
            req = urllib.request.Request(f"{SEARCH_URL}?{params}", headers={"User-Agent": "cybus-harness"})
            try:
                with urllib.request.urlopen(req, timeout=15) as r:
                    return r.status, r.read()
            except urllib.error.HTTPError as e:
                return e.code, b""

        for attempt in range(3):
            try:
                status, body = await asyncio.to_thread(get)
                if status == 200:
                    return [x for x in (_row(i) for i in json.loads(body).get("creatorStoreAssets") or []) if x]
                log.warning("audio search %r: HTTP %s", query, status)
            except (OSError, ValueError) as e:
                log.warning("audio search %r failed: %s: %s", query, type(e).__name__, e)
            await asyncio.sleep(1 + attempt * 2)
        return []

    def tools(self) -> list:
        from harness.tools.base import Tool, ToolResult

        async def search_audio(query: str, kind: str = "sfx", limit: int = 8) -> ToolResult:
            rows = await self.search(query, kind if kind in ("sfx", "music", "any") else None, max(1, min(15, limit)))
            if not rows:
                return ToolResult(text=f"no audio found for {query!r}; try other words (e.g. 'whoosh', 'coin pickup', "
                                       "'ui click', 'ambient forest', 'upbeat music')")
            lines = [f"rbxassetid://{r['id']}  {r['seconds']:.1f}s  {r['type'] or '?'}  by {r['creator']}"
                     f"{' (verified)' if r['verified'] else ''}  \"{r['title']}\"" for r in rows]
            return ToolResult(text="\n".join(lines) + "\nRegister the ones you use with Sound.register(name, {ids = {...}}); "
                                                      "prefer 2-3 ids per event for variation.", data={"results": rows})

        return [Tool("search_audio", "Search the Roblox Creator Store for public sound effects or music the game can "
                                     "use by id (no upload). kind: sfx | music | any.",
                     {"type": "object", "additionalProperties": False, "required": ["query"],
                      "properties": {"query": {"type": "string"},
                                     "kind": {"type": "string", "enum": ["sfx", "music", "any"]},
                                     "limit": {"type": "integer"}}},
                     search_audio)]

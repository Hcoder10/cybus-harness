"""Score benchmark runs: judge every aspect of every run from its captured evidence.

    python -m bench.score runs/bench/<model>/               # a bench out dir (reads its manifest.json)
    python -m bench.score runs/bench/<model>/<id> [...]    # or individual run dirs
        [--ideas bench/ideas.yaml] [--aspects bench/aspects.yaml] [--out DIR]
        [--only id,id] [--concurrency 4] [--dry-run]

For each run and each of the 12 aspects, evidence is gathered by the conventions in bench/evidence.py
(captures/<aspect>__<name>.png stills, captures/<aspect>__<name>__NN.png strips, logs/...), then
    await harness.judge.judge(llm, aspect, images, intent=<the idea's pitch>)
with llm = harness.llm.llm_from_env("judge") (HARNESS_JUDGE_* env vars, falling back to HARNESS_DEFAULT_*).

Rules: an aspect with no evidence scores 0 without a judge call and is listed. Judged scores are clamped
to 1-10, so 0 always means "no evidence". A judge failure (an exception, a missing or non-numeric score,
or the judge's own "returned no JSON" fallback verdict) is recorded as an error, excluded from the means
and listed; re-run to fill it in. Writes <out>/scores.json and <out>/scores.md: ideas x aspects, the mean,
and the count of aspects at >= 7 (front-page) and >= 9 (the owner's reference bar).
"""
from __future__ import annotations

import argparse
import asyncio
import dataclasses
import inspect
import math
import os
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

from bench import evidence, spec
from bench.spec import now_iso, read_json, write_json


class ScoreError(RuntimeError):
    pass


@dataclass
class Run:
    key: str                       # the idea id (prefixed with its bench dir when ids collide)
    id: str
    title: str
    pitch: str
    run_dir: Path
    craft_focus: list[str] = field(default_factory=list)
    build: dict = field(default_factory=dict)


def _build_info(rec: dict) -> dict:
    return {k: rec.get(k) for k in ("status", "hours", "place_file", "error") if rec.get(k) is not None}


def find_runs(paths: list[Path], ideas: list[dict]) -> tuple[list[Run], Path, str]:
    """Runs from bench out dirs (via manifest.json) and/or run dirs; plus a default out dir and a label."""
    by_id = {i["id"]: i for i in ideas}
    runs: list[Run] = []
    labels: list[str] = []

    def make(run_dir: Path, rid: str, idea: dict | None, rec: dict) -> Run:
        src = idea or rec.get("input") or by_id.get(rid)
        if not src or not src.get("pitch"):
            raise ScoreError(f"no pitch for run {rid!r} ({run_dir}); pass --ideas with that idea")
        full = by_id.get(rid, {})
        return Run(rid, rid, src.get("title") or full.get("title") or rid, src["pitch"], run_dir,
                   list(full.get("craft_focus") or src.get("craft_focus") or []), _build_info(rec))

    for p in paths:
        p = Path(p)
        manifest = read_json(p / "manifest.json")
        if isinstance(manifest, dict) and isinstance(manifest.get("runs"), dict):
            labels.append(str(manifest.get("model") or p.name))
            for rid, entry in manifest["runs"].items():
                run_dir = p / entry.get("run_dir", rid)
                rec = read_json(run_dir / "bench_run.json") or entry
                runs.append(make(run_dir, rid, entry.get("idea"), rec))
        elif (p / "bench_run.json").is_file() or (p / "captures").is_dir():
            rec = read_json(p / "bench_run.json") or {}
            rid = (rec.get("input") or {}).get("id") or p.name
            labels.append(p.parent.name)
            runs.append(make(p, rid, None, rec))
        else:
            raise ScoreError(f"{p} is neither a bench out dir (manifest.json) nor a run dir (captures/)")
    keys = [r.id for r in runs]
    for r in runs:
        if keys.count(r.id) > 1:
            r.key = f"{r.run_dir.parent.name}/{r.id}"
    if len(paths) == 1 and (Path(paths[0]) / "manifest.json").is_file():
        out = Path(paths[0])
    else:
        out = Path(os.path.commonpath([str(r.run_dir.resolve().parent) for r in runs])) if runs else Path(".")
    return runs, out, " + ".join(dict.fromkeys(labels)) or out.name


def load_judge() -> tuple[Callable, Any]:
    """harness.judge.judge and the judge LLM, imported lazily with actionable errors."""
    try:
        from harness.judge import judge
    except ImportError as e:
        raise ScoreError(f"harness.judge is not importable ({e}); the scorer needs "
                         "harness.judge.judge(llm, aspect, images, intent) (ARCHITECTURE.md)") from e
    try:
        from harness.llm import llm_from_env
    except ImportError as e:
        raise ScoreError(f"harness.llm is not importable ({e}); the judge LLM comes from llm_from_env('judge')") from e
    try:
        llm = llm_from_env("judge")
    except Exception as e:
        raise ScoreError(f"cannot build the judge LLM ({type(e).__name__}: {e}); set HARNESS_JUDGE_BASE_URL, "
                         "HARNESS_JUDGE_MODEL and HARNESS_JUDGE_API_KEY (or the HARNESS_DEFAULT_* ones)") from e
    return judge, llm


def _plain(x: Any) -> Any:
    if dataclasses.is_dataclass(x) and not isinstance(x, type):
        return dataclasses.asdict(x)
    return x


def verdict_dict(v: Any) -> dict:
    """A Verdict dataclass, a dict, or any object with the Verdict attributes, as a plain dict."""
    if isinstance(v, dict):
        d = dict(v)
    elif dataclasses.is_dataclass(v) and not isinstance(v, type):
        d = dataclasses.asdict(v)
    else:
        d = {k: getattr(v, k) for k in ("aspect", "score", "passed", "issues", "strengths", "raw") if hasattr(v, k)}
    d["issues"] = [_plain(i) for i in d.get("issues") or []]
    d["strengths"] = [str(s) for s in d.get("strengths") or []]
    return d


def judged_score(d: dict) -> tuple[float | None, str | None]:
    """(score clamped to 1-10, None) for a real verdict, else (None, why it is a judge failure)."""
    raw = d.get("raw")
    if isinstance(raw, dict) and "_raw" in raw:
        return None, "judge returned no JSON (the judge's fallback verdict, not a real score)"
    if isinstance(raw, dict) and raw and "score" not in raw:
        return None, "judge answer had no score"
    try:
        s = float(d.get("score"))
    except (TypeError, ValueError):
        return None, f"judge returned a non-numeric score {d.get('score')!r}"
    if math.isnan(s):
        return None, "judge returned NaN"
    return min(10.0, max(1.0, s)), None


async def _close(llm: Any) -> None:
    for name in ("aclose", "close"):
        fn = getattr(llm, name, None)
        if callable(fn):
            try:
                r = fn()
                if inspect.isawaitable(r):
                    await r
            except Exception:
                pass
            return


async def score_runs(runs: list[Run], aspects_doc: dict, judge_fn: Callable | None, llm: Any = None, *,
                     concurrency: int = 4, label: str = "", judge_name: str = "",
                     log: Callable[[str], None] = print) -> dict:
    """Judge every (run, aspect); judge_fn=None is a dry run (evidence only). Returns the full report."""
    ids = [a["id"] for a in aspects_doc["aspects"]]
    sem = asyncio.Semaphore(max(1, concurrency))
    cells: dict[str, dict[str, dict]] = {r.key: {} for r in runs}
    extra: dict[str, dict] = {}

    async def one(r: Run, aid: str, ev: evidence.AspectEvidence) -> None:
        cell: dict[str, Any] = {"score": None, "status": "not_judged", "evidence": ev.labels(),
                                "missing": ev.missing + ([ev.short] if ev.short else []), "incomplete": ev.incomplete}
        cells[r.key][aid] = cell
        if ev.empty:
            cell.update(score=0.0, status="no_evidence")
        elif judge_fn is not None:
            t0 = time.monotonic()
            try:
                images = await asyncio.to_thread(ev.images)
                async with sem:
                    v = judge_fn(llm, aid, images, intent=r.pitch)
                    if inspect.isawaitable(v):
                        v = await v
                d = verdict_dict(v)
                score, problem = judged_score(d)
                if problem:
                    cell.update(status="judge_error", error=problem, raw=d.get("raw"))
                else:
                    cell.update(score=score, status="judged", passed=d.get("passed"),
                                issues=d["issues"], strengths=d["strengths"])
            except Exception as e:
                cell.update(status="judge_error", error=f"{type(e).__name__}: {e}")
            cell["seconds"] = round(time.monotonic() - t0, 1)
        shown = cell["score"] if cell["score"] is not None else cell["status"]
        log(f"[score] {r.key}/{aid}: {shown} ({len(ev.pieces)} images{', incomplete' if ev.incomplete else ''})")

    jobs = []
    for r in runs:
        ev_map, unmatched = evidence.gather(r.run_dir, aspects_doc)
        logs_dir = r.run_dir / "logs"
        logs = ({p.relative_to(r.run_dir).as_posix(): evidence.log_summary(p)
                 for p in sorted(logs_dir.rglob("*.log")) if p.is_file()} if logs_dir.is_dir() else {})
        extra[r.key] = {"unmatched": unmatched, "logs": logs}
        jobs += [one(r, aid, ev_map[aid]) for aid in ids]
    try:
        await asyncio.gather(*jobs)
    finally:
        if llm is not None:
            await _close(llm)
    return aggregate(runs, cells, extra, ids, label=label, judge_name=judge_name)


def _mean(xs: list[float]) -> float | None:
    return round(sum(xs) / len(xs), 2) if xs else None


def aggregate(runs: list[Run], cells: dict, extra: dict, ids: list[str], *, label: str = "",
              judge_name: str = "") -> dict:
    out_runs, all_scores = [], []
    for r in runs:
        rc = cells[r.key]
        nums = [c["score"] for c in rc.values() if isinstance(c.get("score"), (int, float))]
        all_scores += nums
        out_runs.append({
            "key": r.key, "id": r.id, "title": r.title, "run_dir": str(r.run_dir), "craft_focus": r.craft_focus,
            "build": r.build, "mean": _mean(nums), "n_scored": len(nums),
            "n_ge7": sum(s >= 7 for s in nums), "n_ge9": sum(s >= 9 for s in nums),
            "no_evidence": [a for a in ids if rc[a]["status"] == "no_evidence"],
            "judge_errors": [a for a in ids if rc[a]["status"] == "judge_error"],
            "incomplete": [a for a in ids if rc[a]["incomplete"] and rc[a]["status"] != "no_evidence"],
            **extra.get(r.key, {}), "cells": {a: rc[a] for a in ids}})
    aspect_means = {a: _mean([cells[r.key][a]["score"] for r in runs
                              if isinstance(cells[r.key][a].get("score"), (int, float))]) for a in ids}
    return {"bench": "cybus-harness new-genre bench", "version": 1, "label": label, "scored_at": now_iso(),
            "judge": judge_name, "aspects": ids, "runs": out_runs, "aspect_means": aspect_means,
            "overall": {"mean": _mean(all_scores), "n_ge7": sum(s >= 7 for s in all_scores),
                        "n_ge9": sum(s >= 9 for s in all_scores), "scored_cells": len(all_scores),
                        "total_cells": len(runs) * len(ids)}}


def _fmt(x: float | None) -> str:
    return "-" if x is None else f"{x:.2f}".rstrip("0").rstrip(".") if x != int(x) else f"{int(x)}"


def render_markdown(report: dict) -> str:
    ids = report["aspects"]
    L = [f"# Bench scores: {report['label'] or 'runs'}", "",
         f"Judge `{report['judge'] or '?'}`, scored {report['scored_at']}. Scale 1-10 per bench/aspects.yaml: "
         "4 typical hobby game, 7 strong front-page game, 9 the owner's reference bar.", "",
         "Legend: `0` no evidence captured (scored 0, never judged) | `*` required evidence missing, judged on "
         "what exists | `err` judge failure, excluded from the mean | `ev:N` dry run, N images found | "
         "**bold** the idea's craft focus.", "",
         "| Idea | " + " | ".join(ids) + " | Mean | >= 7 | >= 9 |",
         "|:--|" + "--:|" * (len(ids) + 3)]
    for r in report["runs"]:
        row = []
        for a in ids:
            c = r["cells"][a]
            if c["status"] == "judge_error":
                txt = "err"
            elif c["status"] == "not_judged":
                txt = f"ev:{len(c['evidence'])}"
            else:
                txt = _fmt(c["score"]) + ("*" if c["incomplete"] and c["status"] == "judged" else "")
            row.append(f"**{txt}**" if a in r["craft_focus"] else txt)
        n = f" (n={r['n_scored']})" if r["n_scored"] < len(ids) else ""
        L.append(f"| {r['title']} `{r['key']}` | " + " | ".join(row)
                 + f" | {_fmt(r['mean'])}{n} | {r['n_ge7']} | {r['n_ge9']} |")
    ov = report["overall"]
    L.append("| **Aspect mean** | " + " | ".join(_fmt(report["aspect_means"][a]) for a in ids)
             + f" | **{_fmt(ov['mean'])}** | **{ov['n_ge7']}** | **{ov['n_ge9']}** |")
    L += ["", f"{ov['scored_cells']} of {ov['total_cells']} cells scored; {ov['n_ge7']} at >= 7, {ov['n_ge9']} at >= 9.", ""]

    def section(title: str, items: list[str]) -> None:
        if items:
            L.extend([f"## {title}", "", *items, ""])

    def gaps(r: dict) -> str:
        if len(r["no_evidence"]) == len(ids):
            return "nothing captured for any aspect (all score 0)"
        return "; ".join((f"{a}: nothing captured" if r["cells"][a]["status"] == "no_evidence"
                          else f"{a}: " + ", ".join(r["cells"][a]["missing"]))
                         for a in ids if r["cells"][a]["status"] == "no_evidence" or r["cells"][a]["missing"])

    section("Missing evidence", [f"- `{r['key']}`: {gaps(r)}" for r in report["runs"]
                                 if r["no_evidence"] or any(r["cells"][a]["missing"] for a in ids)])
    section("Judge errors", [f"- `{r['key']}` {a}: {str(r['cells'][a].get('error', '')).splitlines()[0][:200]}"
                             for r in report["runs"] for a in r["judge_errors"]])
    section("Captures that matched nothing", [f"- `{r['key']}`: " + "; ".join(r["unmatched"][:10])
                                              + (" ..." if len(r["unmatched"]) > 10 else "")
                                              for r in report["runs"] if r.get("unmatched")])
    builds = []
    for r in report["runs"]:
        b, logs = r.get("build") or {}, r.get("logs") or {}
        parts = [f"build {b.get('status', '?')}"]
        if b.get("hours") is not None:
            parts.append(f"{b['hours']:.2f} h")
        parts.append(f"place {b.get('place_file') or 'none'}")
        parts += [f"{k}: {v['lines']} lines, {v['errors']} error lines, {v['warnings']} warnings" for k, v in logs.items()]
        builds.append(f"- `{r['key']}`: " + "; ".join(parts))
    section("Builds and logs", builds)
    return "\n".join(L).rstrip() + "\n"


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="python -m bench.score", description=__doc__.split("\n\n")[0])
    p.add_argument("paths", nargs="+", help="bench out dir(s) with manifest.json, or run dir(s)")
    p.add_argument("--ideas", default=str(spec.IDEAS_PATH), help="source of pitches for runs without a record")
    p.add_argument("--aspects", default=str(spec.ASPECTS_PATH))
    p.add_argument("--out", help="where scores.json and scores.md go (default: the bench dir)")
    p.add_argument("--only", default="", help="comma-separated idea ids")
    p.add_argument("--concurrency", type=int, default=4, help="parallel judge calls (default 4)")
    p.add_argument("--dry-run", action="store_true", help="gather evidence and report gaps; no judge calls")
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        aspects_doc = spec.load_aspects(args.aspects)
        ideas = spec.load_ideas(args.ideas) if Path(args.ideas).is_file() else []
        runs, default_out, label = find_runs([Path(p) for p in args.paths], ideas)
        wanted = {s.strip() for s in args.only.split(",") if s.strip()}
        runs = [r for r in runs if not wanted or r.id in wanted]
        if not runs:
            raise ScoreError("no runs to score")
        judge_fn, llm, judge_name = None, None, "(dry run: not judged)"
        if not args.dry_run:
            judge_fn, llm = load_judge()
            judge_name = str(getattr(llm, "model", "") or type(llm).__name__)
    except (spec.SpecError, ScoreError) as e:
        print(f"score: {e}", file=sys.stderr)
        return 2
    report = asyncio.run(score_runs(runs, aspects_doc, judge_fn, llm, concurrency=args.concurrency,
                                    label=label, judge_name=judge_name))
    out = Path(args.out) if args.out else default_out
    write_json(out / "scores.json", report)
    (out / "scores.md").write_text(render_markdown(report), encoding="utf-8")
    ov = report["overall"]
    print(f"[score] {len(runs)} run(s): mean {_fmt(ov['mean'])}, {ov['n_ge7']} cells >= 7, {ov['n_ge9']} >= 9 "
          f"-> {out / 'scores.md'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

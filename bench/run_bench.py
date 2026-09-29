"""Run the new-genre benchmark: build every idea with the harness, one run_dir per idea.

    python -m bench.run_bench --ideas bench/ideas.yaml --model <role config name> \
        [--only id,id] [--out runs/bench/<model>/] [--hours 8] [--grace-minutes 10] \
        [--allow-place-id ID ...] [--opt key=value ...] [--force] [--inline] [--dry-run]

For each idea this calls harness.workflows.build_game.build_game(idea, run_dir, **opts) with
    idea = {"id", "title", "pitch"} only (genre, craft_focus and done belong to the scorer)
    opts = {"model": <role config name>, "deadline": <epoch seconds; wrap up and capture before it>,
            "budget_hours": float, "evidence_plan": <capture plan from bench/aspects.yaml>,
            "allow_place_ids": [...] (when --allow-place-id is given), **--opt pairs}
build_game may be sync or async and may return a dict. Its "place_file" (or "place_path"/"place") names
the built place; otherwise the newest *.rbxl/*.rbxlx under run_dir is recorded.

The wall-clock budget is real: each idea runs in a child process (python -m bench.run_bench --child
<run_dir>) that cancels an async build at budget + grace, and the parent kills the child's process tree
if it is still alive BACKSTOP_S later. --inline runs in this process instead (debugging only; a sync
build function cannot be stopped there).

Outputs: <out>/manifest.json holds every idea's record (the idea, start/end, status, place file, capture
and log paths, evidence coverage); <out>/<id>/bench_run.json holds the same record minus the scorer's
fields, bench_result.json the child's report and bench.log the child's stdout/stderr. Ideas already ok
in the manifest are skipped unless --force. Statuses: ok, error, timeout, interrupted.
"""
from __future__ import annotations

import argparse
import asyncio
import hashlib
import importlib
import inspect
import json
import os
import re
import signal
import subprocess
import sys
import time
import traceback
from pathlib import Path
from typing import Any, Callable

from bench import evidence, spec
from bench.spec import now_iso, read_json, write_json

DEFAULT_BUILD_FN = "harness.workflows.build_game:build_game"
BACKSTOP_S = 120.0
RESERVED_OPTS = ("model", "deadline", "budget_hours", "evidence_plan", "allow_place_ids")
PLACE_KEYS = ("place_file", "place_path", "place")


class BenchError(RuntimeError):
    """A configuration problem that stops the bench before anything runs."""


class BudgetExceeded(Exception):
    pass


def load_build_fn(target: str = DEFAULT_BUILD_FN) -> Callable:
    """Import 'module:function' lazily, with an actionable message when it is not there yet."""
    mod_name, _, attr = target.partition(":")
    attr = attr or "build_game"
    want = f"{mod_name}.{attr}(idea: dict, run_dir: Path, **opts)"
    try:
        mod = importlib.import_module(mod_name)
    except ModuleNotFoundError as e:
        if e.name and (mod_name == e.name or mod_name.startswith(e.name + ".")):
            raise BenchError(f"{mod_name} is not written yet. The bench needs {want} "
                             "(ARCHITECTURE.md, Workflows). Write it, or pass --build-fn module:function.") from e
        raise BenchError(f"{mod_name} exists but failed to import: module {e.name!r} is missing ({e})") from e
    except Exception as e:
        raise BenchError(f"{mod_name} exists but failed to import: {type(e).__name__}: {e}") from e
    fn = getattr(mod, attr, None)
    if not callable(fn):
        raise BenchError(f"{mod_name} has no callable {attr!r}. The bench needs {want}.")
    return fn


async def _bounded(awaitable, timeout_s: float):
    t0 = time.monotonic()
    try:
        return await asyncio.wait_for(awaitable, timeout_s)
    except TimeoutError:
        if time.monotonic() - t0 >= timeout_s * 0.98:
            raise BudgetExceeded() from None
        raise                                        # a TimeoutError raised inside the build itself


def execute(fn: Callable, idea: dict, run_dir: Path, opts: dict, timeout_s: float) -> tuple[str, Any, str | None]:
    """Run one build; returns (status, returned value, error text). Sync functions run outside any
    event loop (they may call asyncio.run themselves); only async work can be cancelled here."""
    try:
        if inspect.iscoroutinefunction(fn):
            result = asyncio.run(_bounded(fn(idea, run_dir, **opts), timeout_s))
        else:
            result = fn(idea, run_dir, **opts)
            if inspect.isawaitable(result):
                result = asyncio.run(_bounded(result, timeout_s))
        return "ok", result, None
    except BudgetExceeded:
        return "timeout", None, f"build exceeded budget + grace ({timeout_s / 3600:.3f} h) and was cancelled"
    except KeyboardInterrupt:
        raise
    except BaseException as e:                      # SystemExit included: a build never ends the bench
        return "error", None, "".join(traceback.format_exception(e)).strip()[-8000:]


def jsonable(x: Any, limit: int = 20000) -> Any:
    try:
        text = json.dumps(x, default=str)
    except (TypeError, ValueError):
        text = json.dumps(repr(x))
    return json.loads(text) if len(text) <= limit else {"truncated": True, "json": text[:limit]}


def _rel(p: Path, root: Path) -> str:
    try:
        return p.resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        return str(p)


def find_place_file(run_dir: Path, returned: Any) -> str | None:
    if isinstance(returned, dict):
        for k in PLACE_KEYS:
            v = returned.get(k)
            if isinstance(v, str) and v.strip():
                p = Path(v) if Path(v).is_absolute() else run_dir / v
                if p.is_file():
                    return _rel(p, run_dir)
    found = [p for pat in ("*.rbxl", "*.rbxlx") for p in run_dir.rglob(pat) if p.is_file()]
    return _rel(max(found, key=lambda p: p.stat().st_mtime), run_dir) if found else None


def _files(d: Path, root: Path) -> list[str]:
    return sorted(_rel(p, root) for p in d.rglob("*") if p.is_file()) if d.is_dir() else []


def _tail(path: Path, n: int = 20) -> str:
    try:
        return "\n".join(path.read_text(encoding="utf-8", errors="replace").splitlines()[-n:])
    except OSError:
        return "(no log)"


def kill_tree(proc: subprocess.Popen) -> None:
    if proc.poll() is not None:
        return
    try:
        if os.name == "nt":
            subprocess.run(["taskkill", "/PID", str(proc.pid), "/T", "/F"], capture_output=True, timeout=30)
        else:
            os.killpg(proc.pid, signal.SIGKILL)
    except Exception:
        pass
    try:
        proc.kill()
        proc.wait(timeout=30)
    except Exception:
        pass


def run_child(run_dir: Path, hard_timeout_s: float) -> tuple[str, Any, str | None]:
    env = dict(os.environ, PYTHONUNBUFFERED="1")
    env["PYTHONPATH"] = os.pathsep.join([str(spec.REPO_ROOT), os.getcwd()] + ([env["PYTHONPATH"]] if env.get("PYTHONPATH") else []))
    group = ({"creationflags": subprocess.CREATE_NEW_PROCESS_GROUP} if os.name == "nt"
             else {"start_new_session": True})
    with open(run_dir / "bench.log", "ab") as logf:
        proc = subprocess.Popen([sys.executable, "-m", "bench.run_bench", "--child", str(run_dir)],
                                stdout=logf, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                cwd=os.getcwd(), env=env, **group)
        try:
            code = proc.wait(timeout=hard_timeout_s)
        except subprocess.TimeoutExpired:
            kill_tree(proc)
            return "timeout", None, f"child killed after {hard_timeout_s / 3600:.3f} h (budget + grace + backstop)"
        except BaseException:                       # Ctrl+C: never leave a build running behind us
            kill_tree(proc)
            raise
    res = read_json(run_dir / "bench_result.json")
    if not isinstance(res, dict):
        return "error", None, f"child exited with code {code} and no result; bench.log tail:\n{_tail(run_dir / 'bench.log')}"
    return res.get("status", "error"), res.get("returned"), res.get("error")


def child_main(run_dir: Path) -> int:
    run_dir = Path(run_dir).resolve()
    rec = read_json(run_dir / "bench_run.json")
    if not isinstance(rec, dict):
        print(f"run_bench --child: no bench_run.json in {run_dir}", file=sys.stderr)
        return 2
    print(f"[bench child] {rec['input']['id']} start {now_iso()} pid {os.getpid()}", flush=True)
    try:
        fn = load_build_fn(rec["build_fn"])
        status, returned, error = execute(fn, rec["input"], run_dir, rec["opts"], rec["timeout_s"])
    except BenchError as e:
        status, returned, error = "error", None, str(e)
    write_json(run_dir / "bench_result.json",
               {"status": status, "error": error, "returned": jsonable(returned), "end": now_iso()})
    print(f"[bench child] {rec['input']['id']} {status} {now_iso()}", flush=True)
    return 0 if status == "ok" else 1


def run_idea(idea: dict, run_dir: Path, *, model: str, build_fn: str, budget_s: float, grace_s: float,
             aspects_doc: dict, extra_opts: dict, inline: bool = False) -> dict:
    """Build one idea into run_dir and return its manifest record (without the full idea)."""
    run_dir = Path(run_dir).resolve()
    for sub in ("captures", "logs"):
        (run_dir / sub).mkdir(parents=True, exist_ok=True)
    (run_dir / "bench_result.json").unlink(missing_ok=True)
    t0 = time.time()
    opts = {"model": model, "deadline": t0 + budget_s, "budget_hours": budget_s / 3600,
            "evidence_plan": evidence.evidence_plan(aspects_doc), **extra_opts}
    rec = {"input": spec.harness_input(idea), "model": model, "build_fn": build_fn, "opts": opts,
           "timeout_s": budget_s + grace_s, "start": now_iso(), "status": "running"}
    write_json(run_dir / "bench_run.json", rec)
    status, returned, error = "interrupted", None, "interrupted by the user"
    try:
        if inline:
            status, returned, error = execute(load_build_fn(build_fn), rec["input"], run_dir, opts, rec["timeout_s"])
        else:
            status, returned, error = run_child(run_dir, rec["timeout_s"] + BACKSTOP_S)
    finally:
        rec.update(status=status, error=error, end=now_iso(), hours=round((time.time() - t0) / 3600, 4),
                   place_file=find_place_file(run_dir, returned),
                   captures=_files(run_dir / "captures", run_dir), logs=_files(run_dir / "logs", run_dir),
                   evidence=evidence.coverage(run_dir, aspects_doc), returned=jsonable(returned))
        write_json(run_dir / "bench_run.json", rec)
    return rec


def manifest_entry(idea: dict, rec: dict) -> dict:
    """The top-level manifest's record: the full idea plus the run record (the capture plan omitted)."""
    entry = {"idea": idea, "run_dir": idea["id"], **{k: v for k, v in rec.items() if k != "input"}}
    if isinstance(entry.get("opts"), dict):
        entry["opts"] = {k: v for k, v in entry["opts"].items() if k != "evidence_plan"}
    return entry


def parse_opts(pairs: list[str], place_ids: list[str]) -> dict:
    opts: dict[str, Any] = {}
    for pair in pairs:
        key, sep, raw = pair.partition("=")
        if not sep or not key.isidentifier():
            raise ValueError(f"--opt expects key=value with an identifier key, got {pair!r}")
        if key in RESERVED_OPTS:
            raise ValueError(f"--opt {key} is set by the bench itself")
        try:
            opts[key] = json.loads(raw)
        except ValueError:
            opts[key] = raw
    if place_ids:
        opts["allow_place_ids"] = [str(p) for p in place_ids]
    return opts


def _sha(path: Path) -> str:
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()[:16]


def git_info() -> dict:
    try:
        run = lambda *a: subprocess.run(["git", *a], cwd=spec.REPO_ROOT, capture_output=True, text=True, timeout=10).stdout.strip()
        return {"commit": run("rev-parse", "HEAD") or None, "dirty": bool(run("status", "--porcelain"))}
    except Exception:
        return {"commit": None, "dirty": None}


def slug(s: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]+", "_", s).strip("._") or "model"


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="python -m bench.run_bench", description=__doc__.split("\n\n")[0])
    p.add_argument("--ideas", default=str(spec.IDEAS_PATH), help="ideas file (default: bench/ideas.yaml)")
    p.add_argument("--aspects", default=str(spec.ASPECTS_PATH), help="aspects file, for the capture plan")
    p.add_argument("--model", help="role config name handed to build_game as opts['model']")
    p.add_argument("--only", default="", help="comma-separated idea ids (default: all)")
    p.add_argument("--out", help="output dir (default: runs/bench/<model>/)")
    p.add_argument("--hours", type=float, default=8.0, help="wall-clock budget per idea (default 8)")
    p.add_argument("--grace-minutes", type=float, default=10.0, help="extra time after the budget before cancelling")
    p.add_argument("--allow-place-id", action="append", default=[], help="Studio PlaceId the build may mutate (repeatable)")
    p.add_argument("--opt", action="append", default=[], help="extra build_game option key=value (JSON value or string)")
    p.add_argument("--build-fn", default=DEFAULT_BUILD_FN, help="module:function to call (default: %(default)s)")
    p.add_argument("--force", action="store_true", help="re-run ideas already ok in the manifest")
    p.add_argument("--inline", action="store_true", help="run builds in this process (no hard kill)")
    p.add_argument("--dry-run", action="store_true", help="print the plan, run nothing")
    p.add_argument("--child", help=argparse.SUPPRESS)
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.child:
        return child_main(Path(args.child))
    def err(msg: str) -> int:
        print(f"run_bench: {msg}", file=sys.stderr)
        return 2

    if not args.model:
        return err("--model is required")
    if args.hours <= 0 or args.grace_minutes < 0:
        return err("--hours must be > 0 and --grace-minutes >= 0")
    try:
        ideas = spec.load_ideas(args.ideas)
        aspects_doc = spec.load_aspects(args.aspects)
        extra_opts = parse_opts(args.opt, args.allow_place_id)
    except (spec.SpecError, ValueError) as e:
        return err(str(e))
    wanted = [s.strip() for s in args.only.split(",") if s.strip()]
    unknown = sorted(set(wanted) - {i["id"] for i in ideas})
    if unknown:
        return err(f"unknown idea id(s) {unknown}; known: {[i['id'] for i in ideas]}")
    selected = [i for i in ideas if not wanted or i["id"] in wanted]
    out = Path(args.out) if args.out else Path("runs") / "bench" / slug(args.model)
    budget_s, grace_s = args.hours * 3600, args.grace_minutes * 60

    if args.dry_run:
        print(f"model {args.model} | out {out} | {args.hours:g} h per idea + {args.grace_minutes:g} min grace | build {args.build_fn}")
        print(f"opts: model, deadline, budget_hours, evidence_plan ({len(evidence.evidence_plan(aspects_doc)['items'])} items)"
              + "".join(f", {k}" for k in extra_opts))
        for i in selected:
            print(f"  {i['id']:20s} {i['title']!r} -> {out / i['id']}")
        return 0
    try:
        load_build_fn(args.build_fn)
    except BenchError as e:
        return err(str(e))
    if "allow_place_ids" not in extra_opts:
        print("run_bench: note: no --allow-place-id given; build_game must get its Studio allow-list elsewhere", flush=True)

    out.mkdir(parents=True, exist_ok=True)
    mpath = out / "manifest.json"
    manifest = read_json(mpath) or {}
    runs: dict = manifest.get("runs", {}) if isinstance(manifest.get("runs"), dict) else {}
    manifest.update({"bench": "cybus-harness new-genre bench", "version": 1, "model": args.model,
                     "ideas_file": str(Path(args.ideas)), "ideas_sha256": _sha(Path(args.ideas)),
                     "aspects_sha256": _sha(Path(args.aspects)), "hours_per_idea": args.hours,
                     "grace_minutes": args.grace_minutes, "build_fn": args.build_fn, "git": git_info(),
                     "created": manifest.get("created", now_iso())})
    order = [i["id"] for i in ideas]

    def save() -> None:
        manifest["runs"] = {k: runs[k] for k in sorted(runs, key=lambda k: order.index(k) if k in order else len(order))}
        manifest["updated"] = now_iso()
        write_json(mpath, manifest)

    failed = False
    try:
        for idea in selected:
            prev = runs.get(idea["id"], {})
            if prev.get("status") == "ok" and not args.force:
                print(f"[bench] {idea['id']}: already ok, skipped (--force to re-run)", flush=True)
                continue
            run_dir = out / idea["id"]
            print(f"[bench] {idea['id']}: building {idea['title']!r} for up to {args.hours:g} h -> {run_dir}", flush=True)
            runs[idea["id"]] = {"idea": idea, "run_dir": idea["id"], "status": "running", "start": now_iso()}
            save()
            rec = None
            try:
                rec = run_idea(idea, run_dir, model=args.model, build_fn=args.build_fn, budget_s=budget_s,
                               grace_s=grace_s, aspects_doc=aspects_doc, extra_opts=extra_opts, inline=args.inline)
            finally:                                 # also on Ctrl+C: run_idea already wrote its record
                if rec is None:
                    rec = read_json(run_dir / "bench_run.json") or {"status": "interrupted"}
                runs[idea["id"]] = manifest_entry(idea, rec)
                save()
            failed |= rec["status"] == "error"
            ev = rec["evidence"]
            print(f"[bench] {idea['id']}: {rec['status']} in {rec['hours']:.2f} h | {len(rec['captures'])} captures | "
                  f"no evidence for {len(ev['no_evidence'])}/12 aspects | place {rec['place_file']}", flush=True)
            if rec["error"]:
                print("         " + (rec["error"].strip().splitlines() or [""])[-1][:300], flush=True)
    except KeyboardInterrupt:
        print("[bench] interrupted; manifest saved", file=sys.stderr)
        return 130
    print(f"[bench] manifest: {mpath}", flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

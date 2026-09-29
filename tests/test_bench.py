"""Benchmark tests: data-file schemas, the anti-resemblance rule, evidence conventions, score
aggregation with a fake judge, and the runner with fake builds. No network, no Studio."""
from __future__ import annotations

import asyncio
import io
import json
import re
from pathlib import Path

import pytest
import yaml
from PIL import Image

from bench import evidence, run_bench, score, spec

BENCH = Path(__file__).resolve().parent.parent / "bench"
ASPECTS = ["ui_menus", "hud", "camera", "game_feel", "vfx", "animation", "world_art", "characters",
           "audio_design", "core_loop", "cohesion", "polish"]
# The owner's rule: nothing may resemble the reference game. These five are required; spec may ban more.
MUST_BAN = ("anime", "duel", "fight", "arena", "ultimate")
DONE_KEYS = {"core_loop", "title_menu", "hud", "signature_moment", "audio_feel"}
GENRE_FAMILIES = {
    "cozy life / fishing / farming": ("cozy", "life sim", "fishing", "farming"),
    "racing / vehicle": ("racing", "racer", "vehicle", "driving"),
    "horror / escape": ("horror", "escape"),
    "strategy / tower defense / management": ("strategy", "tower defense", "management", "tycoon"),
    "platformer / obby / rhythm": ("platformer", "obby", "rhythm"),
    "social / party / simulator": ("social", "party", "simulator"),
}


def _raw_ideas() -> list[dict]:
    return yaml.safe_load((BENCH / "ideas.yaml").read_text(encoding="utf-8"))["ideas"]


def _png(path: Path, color=(90, 140, 200), size=(160, 90)) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    Image.new("RGB", size, color).save(path)
    return path


def _is_image(data: bytes) -> bool:
    with Image.open(io.BytesIO(data)) as im:
        return im.size[0] > 0


# ------------------------------------------------------------------------------------------ data files

def test_ideas_schema():
    ideas = spec.load_ideas(BENCH / "ideas.yaml")            # strict loader: raises on any problem
    assert ideas == _raw_ideas()
    assert len(ideas) == 6
    assert len({i["id"] for i in ideas}) == 6 and len({i["title"] for i in ideas}) == 6
    for idea in ideas:
        assert re.fullmatch(r"[a-z][a-z0-9_]*[a-z0-9]", idea["id"]) and "__" not in idea["id"]
        assert set(idea) == {"id", "title", "genre", "pitch", "done", "craft_focus"}
        assert all(isinstance(idea[k], str) and idea[k].strip() for k in ("title", "genre", "pitch"))
        assert "\n" not in idea["pitch"].strip(), f"{idea['id']}: pitch must be one paragraph"
        assert 100 <= len(idea["pitch"].split()) <= 230, f"{idea['id']}: pitch length"
        assert idea["title"] in idea["pitch"], "the pitch names the game, since it is the only input"
        assert set(idea["done"]) == DONE_KEYS
        assert all(isinstance(v, str) and len(v.split()) >= 8 for v in idea["done"].values())
        assert set(idea["craft_focus"]) <= set(ASPECTS)


def test_ideas_span_six_genre_families_and_every_aspect():
    ideas = _raw_ideas()
    for family, words in GENRE_FAMILIES.items():
        hits = [i["id"] for i in ideas if any(w in i["genre"].lower() for w in words)]
        assert len(hits) == 1, f"{family}: expected exactly one idea, got {hits}"
    assert {a for i in ideas for a in i["craft_focus"]} == set(ASPECTS)


def test_nothing_resembles_the_reference_game():
    assert set(MUST_BAN) <= set(spec.BANNED_TERMS)
    for name in ("ideas.yaml", "aspects.yaml"):              # raw text, comments included
        text = (BENCH / name).read_text(encoding="utf-8").lower()
        assert not [t for t in spec.BANNED_TERMS if t in text], name

    def strings(x):
        if isinstance(x, dict):
            for k, v in x.items():
                yield str(k)
                yield from strings(v)
        elif isinstance(x, list):
            for v in x:
                yield from strings(v)
        else:
            yield str(x)

    for idea in _raw_ideas():
        blob = " ".join(strings(idea)).lower()
        assert not [t for t in MUST_BAN if t in blob], idea["id"]


def test_harness_gets_only_the_pitch():
    for idea in _raw_ideas():
        given = spec.harness_input(idea)
        assert set(given) == {"id", "title", "pitch"} and given["pitch"] == idea["pitch"]


def test_aspects_schema():
    doc = spec.load_aspects(BENCH / "aspects.yaml")
    assert [a["id"] for a in doc["aspects"]] == ASPECTS
    assert set(doc["scale"]) == set(range(11)) and isinstance(doc["capture"]["max_images"], int)
    for a in doc["aspects"]:
        assert {1, 4, 7, 9} <= set(a["anchors"]), a["id"]
        assert all(isinstance(v, str) and len(v.split()) >= 5 for v in a["anchors"].values())
        kinds = {e["kind"] for e in a["evidence"]}
        assert kinds <= {"still", "strip", "log"}
        required_images = [e for e in a["evidence"] if e.get("required") and e["kind"] != "log"]
        assert required_images or a.get("borrow"), f"{a['id']} can never have evidence"
        for e in a["evidence"]:
            assert re.fullmatch(r"[a-z0-9_*?]+", e["name"]) and "__" not in e["name"]
            assert e["what"].strip()
            if e["kind"] == "log":
                assert e["path"].startswith("logs/")
        assert set(a.get("borrow", [])) <= set(ASPECTS) - {a["id"]}


def test_validators_reject_bad_data():
    bad_idea = {"id": "bad", "title": "Bad", "genre": "x", "pitch": "An arena game.\n\nSecond paragraph.",
                "done": {"core_loop": "x"}, "craft_focus": ["nope"]}
    errs = " | ".join(spec.validate_ideas({"ideas": [bad_idea]}))
    for needle in ("one paragraph", "'done'", "craft_focus", "'arena'"):
        assert needle in errs
    doc = yaml.safe_load((BENCH / "aspects.yaml").read_text(encoding="utf-8"))
    del doc["aspects"][0]["anchors"][9]
    doc["aspects"][1]["evidence"][0]["name"] = "play__01"
    errs = " | ".join(spec.validate_aspects(doc))
    assert "anchors must cover" in errs and "bad evidence name" in errs


# ------------------------------------------------------------------------------------------ evidence

def test_evidence_conventions(tmp_path):
    cap = tmp_path / "captures"
    _png(cap / "ui_menus__title.png")
    for m in ("shop", "journal", "settings", "zeta"):
        _png(cap / f"ui_menus__menu_{m}.png")
    for i in (10, 2, 1):                                        # frames out of order on disk
        _png(cap / f"game_feel__core_action__{i:02d}.png", (i * 20, 50, 90))
    for f in ("frame2.png", "frame10.png", "frame1.png"):
        _png(cap / "animation__locomotion" / f)
    _png(cap / "hud+world_art__overview.png")
    _png(cap / "all__wide.png")
    _png(cap / "oops__thing.png")                               # unknown tag
    _png(cap / "0001_item_0.png")                               # a harness working capture: ignored
    (cap / "hud__corrupt.png").write_bytes(b"not an image")
    (tmp_path / "logs").mkdir()
    (tmp_path / "logs" / "output.log").write_text("ok\nScript error: attempt to index nil\n", encoding="utf-8")

    doc = spec.load_aspects()
    ev, unmatched = evidence.gather(tmp_path, doc)
    assert set(ev) == set(ASPECTS)
    strip = ev["game_feel"].pieces[0]
    assert strip.kind == "strip" and [p.name for p in strip.paths] == [
        "game_feel__core_action__01.png", "game_feel__core_action__02.png", "game_feel__core_action__10.png"]
    assert [p.name for p in ev["animation"].pieces[0].paths] == ["frame1.png", "frame2.png", "frame10.png"]
    assert ev["world_art"].pieces[0].source == "entry:overview"
    assert "captures/hud+world_art__overview.png" in ev["hud"].labels()
    assert all("captures/all__wide.png" in e.labels() for e in ev.values())
    assert len([p for p in ev["ui_menus"].pieces if p.source == "entry:menu_*"]) == evidence.PATTERN_LIMIT
    assert "strip captures/camera__explore__NN.png" in ev["camera"].missing
    assert ev["camera"].incomplete and not ev["ui_menus"].missing
    assert any(p.source == "borrow:ui_menus" for p in ev["cohesion"].pieces)
    assert any(p.kind == "log" and p.label == "logs/output.log" for p in ev["polish"].pieces)
    assert len(ev["ui_menus"].pieces) <= doc["capture"]["max_images"]
    joined = " | ".join(unmatched)
    assert "oops__thing.png" in joined and "hud__corrupt.png: unreadable" in joined and "1 file(s) not named" in joined
    images = ev["polish"].images() + ev["game_feel"].images()
    assert all(isinstance(b, bytes) and _is_image(b) for b in images)
    assert evidence.log_summary(tmp_path / "logs" / "output.log") == {"lines": 2, "errors": 1, "warnings": 0}
    plan = evidence.evidence_plan(doc)
    item = {(i["aspect"], i["name"]): i for i in plan["items"]}
    assert item[("hud", "play")]["file"] == "captures/hud__play.png" and item[("hud", "play")]["required"]
    assert item[("camera", "explore")]["file"] == "captures/camera__explore__NN.png"
    assert item[("camera", "explore")]["frames"] == 10
    assert item[("polish", "output")]["file"] == "logs/output.log"
    assert "<tag>__<name>" in plan["conventions"] and plan["borrow"]["cohesion"]


# ------------------------------------------------------------------------------------------ scoring

FAKE_SCORES = {"ui_menus": 9, "game_feel": 6, "world_art": 8, "cohesion": 9.5, "polish": 7}


def _make_bench_dir(tmp_path: Path) -> tuple[Path, list[dict]]:
    ideas = spec.load_ideas()
    out = tmp_path / "bench_out"
    runs = {}
    for idea in ideas[:2]:
        (out / idea["id"] / "captures").mkdir(parents=True)
        runs[idea["id"]] = {"idea": idea, "run_dir": idea["id"], "status": "ok"}
    spec.write_json(out / "manifest.json", {"model": "fake-model", "runs": runs})
    cap = out / ideas[0]["id"] / "captures"                      # run A has some evidence; run B none
    _png(cap / "ui_menus__title.png")
    _png(cap / "hud__play.png")
    for i in range(4):
        _png(cap / f"game_feel__core_action__{i:02d}.png")
    _png(cap / "world_art__overview.png")
    return out, ideas


def test_score_aggregation_with_fake_judge(tmp_path, monkeypatch):
    out, ideas = _make_bench_dir(tmp_path)
    calls = []

    async def fake_judge(llm, aspect, images, intent):
        calls.append((aspect, len(images), intent))
        assert images and all(_is_image(b) for b in images)
        if aspect == "hud":
            raise RuntimeError("judge unavailable")
        s = FAKE_SCORES[aspect]
        return {"aspect": aspect, "score": s, "passed": s >= 7, "issues": [], "strengths": ["x"], "raw": {"score": s}}

    monkeypatch.setattr(score, "load_judge", lambda: (fake_judge, None))
    assert score.main([str(out)]) == 0

    report = json.loads((out / "scores.json").read_text(encoding="utf-8"))
    a, b = report["runs"]
    assert (a["id"], b["id"]) == (ideas[0]["id"], ideas[1]["id"])
    assert sorted(c[0] for c in calls) == sorted(["hud", *FAKE_SCORES])          # never judged without evidence
    assert {c[2] for c in calls} == {ideas[0]["pitch"]}                           # intent = the pitch
    assert a["cells"]["hud"]["status"] == "judge_error" and a["judge_errors"] == ["hud"]
    for asp in ("camera", "vfx", "animation", "characters", "audio_design", "core_loop"):
        assert a["cells"][asp]["score"] == 0 and a["cells"][asp]["status"] == "no_evidence"
    assert a["cells"]["ui_menus"]["score"] == 9 and a["cells"]["cohesion"]["score"] == 9.5
    assert a["n_scored"] == 11 and a["mean"] == round(39.5 / 11, 2)
    assert (a["n_ge7"], a["n_ge9"]) == (4, 2)
    assert b["mean"] == 0 and b["no_evidence"] == ASPECTS and (b["n_ge7"], b["n_ge9"]) == (0, 0)
    assert report["aspect_means"]["ui_menus"] == 4.5 and report["aspect_means"]["hud"] == 0
    assert report["overall"] == {"mean": round(39.5 / 23, 2), "n_ge7": 4, "n_ge9": 2, "scored_cells": 23,
                                 "total_cells": 24}

    md = (out / "scores.md").read_text(encoding="utf-8")
    assert "| Idea | " + " | ".join(ASPECTS) + " | Mean | >= 7 | >= 9 |" in md
    row_a = next(ln for ln in md.splitlines() if f"`{ideas[0]['id']}`" in ln and ln.startswith("|"))
    assert "err" in row_a and row_a.endswith(f"| {round(39.5 / 11, 2)} (n=11) | 4 | 2 |")
    row_b = next(ln for ln in md.splitlines() if f"`{ideas[1]['id']}`" in ln and ln.startswith("|"))
    assert row_b.endswith("| 0 | 0 | 0 |")
    assert "## Missing evidence" in md and "## Judge errors" in md and "judge unavailable" in md


def test_score_dry_run_and_judge_failures(tmp_path):
    out, _ = _make_bench_dir(tmp_path)
    assert score.main([str(out), "--dry-run"]) == 0
    report = json.loads((out / "scores.json").read_text(encoding="utf-8"))
    assert report["runs"][0]["cells"]["ui_menus"]["status"] == "not_judged"
    assert "ev:" in (out / "scores.md").read_text(encoding="utf-8")
    # the harness judge's no-JSON fallback is a failure, not a real 0; real scores clamp to 1-10
    assert score.judged_score({"score": 0, "raw": {"score": 0, "_raw": "garbage"}})[0] is None
    assert score.judged_score({"score": "high", "raw": {"score": "high"}})[0] is None
    assert score.judged_score({"score": 12, "raw": {"score": 12}}) == (10.0, None)
    assert score.judged_score({"score": 0.2, "raw": {"score": 0.2}}) == (1.0, None)


# ------------------------------------------------------------------------------------------ runner

async def fake_build_ok(idea, run_dir, **opts):
    run_dir = Path(run_dir)
    assert set(idea) == {"id", "title", "pitch"}
    _png(run_dir / "captures" / "ui_menus__title.png")
    (run_dir / "place").mkdir(exist_ok=True)
    (run_dir / "place" / "final.rbxl").write_bytes(b"place")
    return {"opts": sorted(opts)}


async def fake_build_slow(idea, run_dir, **opts):
    await asyncio.sleep(30)


def fake_build_sync_error(idea, run_dir, **opts):
    raise RuntimeError("boom in the build")


def test_missing_build_fn_is_a_clear_error():
    with pytest.raises(run_bench.BenchError, match="not written yet"):
        run_bench.load_build_fn("harness.workflows.no_such_module_xyz:build_game")
    with pytest.raises(run_bench.BenchError, match="has no callable 'build_game'"):
        run_bench.load_build_fn("bench.spec:build_game")


def test_run_idea_inline(tmp_path):
    doc, idea = spec.load_aspects(), spec.load_ideas()[0]
    common = dict(model="fake", budget_s=60, grace_s=0, aspects_doc=doc, extra_opts={"allow_place_ids": ["0"]},
                  inline=True)
    rec = run_bench.run_idea(idea, tmp_path / "ok", build_fn="tests.test_bench:fake_build_ok", **common)
    assert rec["status"] == "ok" and rec["error"] is None
    assert rec["place_file"] == "place/final.rbxl" and rec["captures"] == ["captures/ui_menus__title.png"]
    assert rec["returned"]["opts"] == ["allow_place_ids", "budget_hours", "deadline", "evidence_plan", "model"]
    assert rec["evidence"]["aspects"]["ui_menus"]["images"] == 1
    saved = json.loads((tmp_path / "ok" / "bench_run.json").read_text(encoding="utf-8"))
    assert set(saved["input"]) == {"id", "title", "pitch"} and "done" not in json.dumps(saved["input"])
    runs, _, _ = score.find_runs([tmp_path / "ok"], [])
    assert runs[0].pitch == idea["pitch"] and runs[0].build["status"] == "ok"

    common["budget_s"] = 0.3
    rec = run_bench.run_idea(idea, tmp_path / "slow", build_fn="tests.test_bench:fake_build_slow", **common)
    assert rec["status"] == "timeout" and rec["hours"] < 0.01
    rec = run_bench.run_idea(idea, tmp_path / "err", build_fn="tests.test_bench:fake_build_sync_error", **common)
    assert rec["status"] == "error" and "boom in the build" in rec["error"]


def test_run_bench_cli(tmp_path, capsys):
    out = tmp_path / "bench_out"
    assert run_bench.main(["--model", "fake", "--only", "nope", "--out", str(out)]) == 2
    assert "unknown idea id" in capsys.readouterr().err
    assert run_bench.main(["--model", "fake", "--dry-run", "--out", str(out)]) == 0
    assert not out.exists()
    # the default mode: a real child process per idea, budget enforced there
    args = ["--model", "fake", "--only", "sky_minigolf,rhythm_obby", "--out", str(out), "--hours", "0.01",
            "--grace-minutes", "0", "--build-fn", "tests.test_bench:fake_build_ok"]
    assert run_bench.main(args) == 0
    manifest = json.loads((out / "manifest.json").read_text(encoding="utf-8"))
    assert list(manifest["runs"]) == ["rhythm_obby", "sky_minigolf"]              # ideas.yaml order
    for rid, entry in manifest["runs"].items():
        assert entry["status"] == "ok" and entry["idea"]["id"] == rid and "done" in entry["idea"]
        assert entry["place_file"] == "place/final.rbxl" and entry["start"] and entry["end"]
        assert "evidence_plan" not in entry["opts"]
        assert f"[bench child] {rid} ok" in (out / rid / "bench.log").read_text(encoding="utf-8")
    assert run_bench.main(args) == 0                                              # ok runs are skipped
    assert "already ok, skipped" in capsys.readouterr().out

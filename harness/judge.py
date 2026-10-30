"""Vision judges: the harness's eyes.

Every artifact the harness builds is captured and judged here against a written rubric (the taste, in
harness/playbooks/rubric_<aspect>.md), the game's own style guide, and, when there is one, a visual target
(a mockup or concept frame the build is supposed to reach). A verdict is a score on a shared 1-10 anchor
scale plus concrete, fixable issues, so a builder agent can repair against it.

    1  broken / placeholder         4  typical hobby Roblox game
    7  strong front-page Roblox game    9  the bar: cohesive, AAA-feeling, custom, cinematic, tuned

Judges never see code: they judge what a player would see.
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path

PLAYBOOKS = Path(__file__).parent / "playbooks"

VERDICT_KEYS = ("score", "issues", "strengths")
SEVERITIES = ("blocker", "major", "minor", "nit")


@dataclass
class Issue:
    severity: str
    where: str
    problem: str
    fix: str


@dataclass
class Verdict:
    aspect: str
    score: float
    passed: bool
    issues: list[Issue]
    strengths: list[str]
    raw: dict = field(default_factory=dict)

    def fix_list(self, limit: int = 12) -> str:
        """The issues as a numbered repair brief, most severe first."""
        order = {s: i for i, s in enumerate(SEVERITIES)}
        items = sorted(self.issues, key=lambda x: order.get(x.severity, 9))[:limit]
        return "\n".join(f"{k + 1}. [{x.severity}] {x.where}: {x.problem} -> FIX: {x.fix}" for k, x in enumerate(items))


def playbook(name: str) -> str:
    p = PLAYBOOKS / f"{name}.md"
    return p.read_text(encoding="utf-8") if p.exists() else ""


def rubric(aspect: str) -> str:
    """The aspect's rubric followed by the shared scale, principles and severities."""
    return "\n\n".join(s for s in (playbook(f"rubric_{aspect}"), playbook("rubric_general")) if s)


JUDGE_SYSTEM = """You are the principal art director, UX lead and game-feel designer of a top Roblox studio,
reviewing captures of a game in development. You judge only what a player would see. You are exacting
and concrete: vague praise is useless, and every problem you name comes with a fix a developer can apply
(positions, sizes, colours, timings, what to add or remove). You score on the studio's shared scale:
1 broken/placeholder, 4 typical hobby Roblox game, 7 strong front-page Roblox game, 9 a cohesive,
AAA-feeling Roblox game (the bar), 10 best-in-class. Most in-development work is 3-6; do not inflate."""


def _parse_json(text: str) -> dict | None:
    """The first balanced JSON object in the text (models wrap JSON in prose or code fences)."""
    text = re.sub(r"```(?:json)?", "", text)
    start = text.find("{")
    while start != -1:
        depth, instr, esc = 0, False, False
        for i in range(start, len(text)):
            ch = text[i]
            if instr:
                esc = (ch == "\\" and not esc)
                if ch == '"' and not esc:
                    instr = False
                continue
            if ch == '"':
                instr = True
            elif ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    try:
                        return json.loads(text[start:i + 1])
                    except json.JSONDecodeError:
                        break
        start = text.find("{", start + 1)
    return None


def _verdict(aspect: str, obj: dict, threshold: float) -> Verdict:
    try:
        score = float(obj.get("score", 0))
    except (TypeError, ValueError):
        score = 0.0
    score = max(0.0, min(10.0, score))
    issues = []
    for it in obj.get("issues") or []:
        if not isinstance(it, dict):
            continue
        sev = str(it.get("severity", "minor")).lower()
        issues.append(Issue(sev if sev in SEVERITIES else "minor", str(it.get("where", "")), str(it.get("problem", "")),
                            str(it.get("fix", ""))))
    strengths = [str(s) for s in (obj.get("strengths") or [])]
    passed = score >= threshold and not any(i.severity == "blocker" for i in issues)
    return Verdict(aspect, score, passed, issues, strengths, obj)


async def _ask_json(llm, content: list[dict], tries: int = 3) -> dict:
    from harness.llm import Message
    msgs = [Message("system", JUDGE_SYSTEM), Message("user", content)]
    last = ""
    for _ in range(tries):
        r = await llm.chat(msgs)
        last = r.message.content if isinstance(r.message.content, str) else json.dumps(r.message.content)
        obj = _parse_json(last)
        if obj is not None:
            return obj
        msgs = msgs + [r.message, Message("user", "Answer again with ONLY the JSON object described, nothing else.")]
    return {"score": 0, "issues": [{"severity": "blocker", "where": "judge", "problem": "judge returned no JSON",
                                    "fix": "re-run the judge"}], "strengths": [], "_raw": last[:2000]}


async def judge(llm, aspect: str, images: list[bytes], intent: str, style: str = "",
                target: list[bytes] | None = None, threshold: float = 7.0) -> Verdict:
    """Score captures of one aspect against its rubric, the style guide and (optionally) a visual target."""
    from harness.llm import image_part, text_part
    parts: list[dict] = [text_part(
        f"ASPECT UNDER REVIEW: {aspect}\n\nWHAT THIS IS SUPPOSED TO BE (the developer's intent):\n{intent}\n\n"
        + (f"THE GAME'S STYLE GUIDE (the build must follow it):\n{style}\n\n" if style else "")
        # Live (Starbloom): judges scored worlds 1/10 for "a bright blue glowing placeholder structure in the centre",
        # which was the tester's own avatar in its spawn force-field bubble, and sent the repairs after it.
        + "NOTE: the character near the centre of gameplay captures is the TESTER'S OWN Roblox avatar (its clothes, "
          "crown or cape are not part of the game), possibly inside a translucent spawn force-field bubble, plus "
          "Roblox's own top-left menu buttons. Ignore all of these entirely; judge only what the game built.\n\n"
        + f"RUBRIC FOR {aspect.upper()}:\n{rubric(aspect)}\n\nCAPTURES OF THE BUILD ({len(images)}):")]
    for k, im in enumerate(images):
        parts += [text_part(f"Capture {k + 1}:"), image_part(im)]
    if target:
        parts.append(text_part("VISUAL TARGET the build should reach (mockup / concept; judge how close the build gets "
                               "in composition, hierarchy, palette and mood, not pixel identity):"))
        for k, im in enumerate(target):
            parts += [text_part(f"Target {k + 1}:"), image_part(im)]
    parts.append(text_part(
        "Reply with ONLY a JSON object: {\"score\": number 1-10 on the shared scale, "
        "\"issues\": [{\"severity\": \"blocker|major|minor|nit\", \"where\": \"which element/moment\", "
        "\"problem\": \"what is wrong, concretely\", \"fix\": \"the concrete change to make\"}], "
        "\"strengths\": [\"what already works and must be kept\"]}. List every issue that keeps this below 9, "
        "most severe first. A blocker is anything broken, unreadable, overlapping, clipped, off-screen, "
        "placeholder, or contradicting the style guide."))
    return _verdict(aspect, await _ask_json(llm, parts), threshold)


async def pairwise(llm, aspect: str, a: list[bytes], b: list[bytes], intent: str) -> dict:
    """Which of two builds is better on one aspect. Asked in both orders; disagreement is a tie."""
    from harness.llm import image_part, text_part

    async def ask(first: list[bytes], second: list[bytes]) -> str:
        parts = [text_part(f"ASPECT: {aspect}\nINTENT: {intent}\nRUBRIC:\n{rubric(aspect)}\n\nBUILD A:")]
        parts += [image_part(x) for x in first]
        parts.append(text_part("BUILD B:"))
        parts += [image_part(x) for x in second]
        parts.append(text_part("Which build is better on this aspect? Reply with ONLY JSON: "
                               "{\"prefer\": \"A\" or \"B\" or \"tie\", \"why\": \"one or two sentences\"}"))
        obj = await _ask_json(llm, parts)
        return str(obj.get("prefer", "tie")).upper(), str(obj.get("why", ""))
    p1, w1 = await ask(a, b)
    p2, w2 = await ask(b, a)
    p2 = {"A": "B", "B": "A"}.get(p2, "TIE")
    prefer = p1 if p1 == p2 else "tie"
    return {"prefer": prefer.upper() if prefer != "tie" else "tie", "why": w1 if prefer == p1 else f"{w1} / {w2}",
            "orders": [p1, p2]}


PANEL_LENSES = {
    "first_time_player": "a first-time player on a phone: can they tell what to do, what matters, and what just happened?",
    "art_director": "an art director: cohesion with the style guide, palette discipline, hierarchy, restraint, polish",
    "ux_designer": "a UX designer: readability, layout, alignment, spacing, affordances, safe areas, states",
    "feel_designer": "a game-feel designer: impact, timing, feedback, camera, anticipation and follow-through",
    "roblox_veteran": "a front-page Roblox developer: does this look and feel like a top Roblox game, native to the platform?",
}


async def panel(llm, aspect: str, images: list[bytes], intent: str, style: str = "",
                lenses: list[str] | None = None, threshold: float = 7.0) -> dict:
    """Independent critics with different lenses (for polish passes). Returns every verdict, the minimum
    score, and the merged issue list (deduplicated by 'where' + first words of the problem)."""
    import asyncio
    lenses = lenses or list(PANEL_LENSES)

    async def one(lens: str) -> Verdict:
        return await judge(llm, aspect, images, intent + f"\n\nREVIEW LENS: you are {PANEL_LENSES.get(lens, lens)}",
                           style, None, threshold)
    verdicts = await asyncio.gather(*(one(l) for l in lenses))
    seen, merged = set(), []
    for v in verdicts:
        for i in v.issues:
            k = (i.where.lower()[:40], " ".join(i.problem.lower().split()[:6]))
            if k not in seen:
                seen.add(k)
                merged.append(i)
    return {"verdicts": verdicts, "min_score": min(v.score for v in verdicts), "issues": merged,
            "passed": all(v.passed for v in verdicts)}

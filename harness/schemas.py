"""JSON Schemas for the structured outputs the build workflow asks agents for.

Kept small and flat on purpose: open-weight builders fill small schemas far more reliably than deep ones.
"""
from __future__ import annotations

ASPECTS = ["ui_menus", "hud", "camera", "game_feel", "vfx", "animation", "world_art", "characters",
           "audio_design", "core_loop", "cohesion", "polish"]

_str = {"type": "string"}
_strs = {"type": "array", "items": {"type": "string"}}

PLAN = {
    "type": "object",
    "properties": {
        "title": _str,
        "fantasy": _str,
        "hook": _str,
        "core_loop": _strs,
        "verbs": {"type": "array", "items": {"type": "object", "properties": {
            "name": _str, "input": _str, "feedback": _str}, "required": ["name", "input", "feedback"]}},
        "signature_moment": _str,
        "first_minute": _str,
        "session": _str,
        "systems": {"type": "array", "items": {"type": "object", "properties": {
            "name": _str, "responsibility": _str, "side": {"type": "string", "enum": ["server", "client", "shared"]},
            "test": _str}, "required": ["name", "responsibility", "side"]}},
        "screens": {"type": "array", "items": {"type": "object", "properties": {
            "name": _str, "job": _str, "reads_first": _str}, "required": ["name", "job", "reads_first"]}},
        "content": {"type": "array", "items": {"type": "object", "properties": {
            "kind": _str, "name": _str, "source": {"type": "string", "enum": ["generated_art", "built", "library", "procedural"]}},
            "required": ["kind", "name", "source"]}},
        "aspects": {"type": "object", "additionalProperties": _str},
        "risks": _strs,
    },
    "required": ["title", "fantasy", "hook", "core_loop", "verbs", "signature_moment", "first_minute", "systems",
                 "screens", "content", "aspects", "risks"],
}

STYLE = {
    "type": "object",
    "properties": {
        "direction": _str,
        "references": _strs,
        "avoid": _strs,
        "palette": {"type": "object", "additionalProperties": _str,
                    "description": "token name -> #RRGGBB; must include bg, surface, surface_raised, text, text_muted, "
                                   "primary, secondary, success, warning, danger"},
        "fonts": {"type": "object", "properties": {"display": _str, "heading": _str, "body": _str, "numeric": _str},
                  "required": ["display", "heading", "body", "numeric"]},
        "type_scale": {"type": "object", "additionalProperties": {"type": "number"},
                       "description": "display, h1, h2, body, caption, numeric -> TextSize in dp on the 1920x1080 canvas"},
        "radius": {"type": "object", "additionalProperties": {"type": "number"}},
        "stroke": {"type": "number"},
        "depth_recipe": _str,
        "shape_language": _str,
        "motion": {"type": "object", "properties": {
            "fast": {"type": "number"}, "base": {"type": "number"}, "slow": {"type": "number"},
            "dramatic": {"type": "number"}, "ease_out": _str, "ease_in": _str}, "required": ["fast", "base", "slow"]},
        "camera": _str,
        "vfx": _str,
        "lighting": {"type": "object", "properties": {
            "ClockTime": {"type": "number"}, "Brightness": {"type": "number"}, "Ambient": _str,
            "OutdoorAmbient": _str, "ExposureCompensation": {"type": "number"},
            "atmosphere": {"type": "object", "additionalProperties": {"type": ["number", "string"]}},
            "color_correction": {"type": "object", "additionalProperties": {"type": ["number", "string"]}},
            "bloom": {"type": "object", "additionalProperties": {"type": "number"}}},
            "required": ["ClockTime", "Brightness", "Ambient", "OutdoorAmbient"]},
        "world": _str,
        "audio": _str,
        "reference_shots": {"type": "array", "items": {"type": "object", "properties": {
            "name": _str, "prompt": _str}, "required": ["name", "prompt"]}},
    },
    "required": ["direction", "avoid", "palette", "fonts", "type_scale", "radius", "depth_recipe", "shape_language",
                 "motion", "camera", "vfx", "lighting", "world", "audio", "reference_shots"],
}

# A work item is the unit a builder owns: an aspect of one part of the game, its files, and how to see it.
ITEM = {"type": "object", "properties": {
    "id": _str,
    "aspect": {"type": "string", "enum": ASPECTS},
    "title": _str,
    "brief": _str,
    "files": _strs,
    "depends_on": _strs,
    "capture": {"type": "object", "properties": {
        "kind": {"type": "string", "enum": ["screen", "moment", "world", "loop", "audio"]},
        "commands": _strs,
        "description": _str}, "required": ["kind", "description"]},
}, "required": ["id", "aspect", "title", "brief", "files", "capture"]}

ARCH = {
    "type": "object",
    "properties": {
        "files": {"type": "array", "items": {"type": "object", "properties": {
            "path": _str, "responsibility": _str, "api": _str}, "required": ["path", "responsibility", "api"]}},
        "remotes": {"type": "array", "items": {"type": "object", "properties": {
            "name": _str, "kind": {"type": "string", "enum": ["RemoteEvent", "RemoteFunction", "UnreliableRemoteEvent"]},
            "direction": _str, "payload": _str}, "required": ["name", "kind", "direction", "payload"]}},
        "debug_commands": {"type": "array", "items": {"type": "object", "properties": {
            "name": _str, "side": {"type": "string", "enum": ["server", "client"]}, "effect": _str},
            "required": ["name", "side", "effect"]}},
        "items": {"type": "array", "items": ITEM},
    },
    "required": ["files", "remotes", "debug_commands", "items"],
}

REPORT = {
    "type": "object",
    "properties": {
        "summary": _str,
        "files": _strs,
        "how_to_see_it": _str,
        "debug_commands": _strs,
        "requests": {"type": "array", "items": {"type": "object", "properties": {
            "file": _str, "change": _str}, "required": ["file", "change"]}},
        "open_issues": _strs,
    },
    "required": ["summary", "files", "how_to_see_it"],
}

CRIT = {
    "type": "object",
    "properties": {
        "verdict": {"type": "string", "enum": ["pass", "revise"]},
        "issues": {"type": "array", "items": {"type": "object", "properties": {
            "severity": {"type": "string", "enum": ["blocker", "major", "minor", "nit"]},
            "where": _str, "problem": _str, "fix": _str}, "required": ["severity", "where", "problem", "fix"]}},
    },
    "required": ["verdict", "issues"],
}

ROUTE = {
    "type": "object",
    "properties": {"assignments": {"type": "array", "items": {"type": "object", "properties": {
        "item_id": _str, "issues": _strs}, "required": ["item_id", "issues"]}}},
    "required": ["assignments"],
}

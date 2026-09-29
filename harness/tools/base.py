"""Tools agents can call, the result they return, and small registry helpers."""

from __future__ import annotations

import inspect
import json
from dataclasses import dataclass, field
from typing import Any, Awaitable, Callable


@dataclass
class ToolResult:
    text: str                                          # what the model reads
    images: list[bytes] = field(default_factory=list)  # PNG/JPEG bytes shown to the model as images
    data: dict | None = None                           # structured payload for code; not sent to the model


@dataclass
class Tool:
    name: str
    description: str
    parameters: dict                                   # JSON Schema (type: object) of fn's keyword arguments
    fn: Callable[..., Awaitable[str | dict | ToolResult]]
    mutating: bool = False                             # changes the world (Studio, files): guarded, and the
                                                       # agent runs it in call order, not concurrently

    def spec(self) -> dict:
        """The OpenAI function-tool spec."""
        return {"type": "function",
                "function": {"name": self.name, "description": self.description,
                             "parameters": self.parameters or {"type": "object", "properties": {}}}}

    async def invoke(self, arguments: dict | None = None) -> ToolResult:
        """Call fn with the arguments as keywords (a plain function works too) and normalize its result."""
        out = self.fn(**(arguments or {}))
        if inspect.isawaitable(out):
            out = await out
        return as_tool_result(out)


def as_tool_result(value: Any) -> ToolResult:
    """ToolResult as is; str -> text; dict -> JSON text plus data; None -> empty; anything else -> JSON/str."""
    if isinstance(value, ToolResult):
        return value
    if value is None:
        return ToolResult("")
    if isinstance(value, str):
        return ToolResult(value)
    if isinstance(value, dict):
        return ToolResult(json.dumps(value, ensure_ascii=False, default=str), data=value)
    try:
        return ToolResult(json.dumps(value, ensure_ascii=False, default=str))
    except (TypeError, ValueError):
        return ToolResult(str(value))


def tool_specs(tools: list[Tool]) -> list[dict]:
    return [t.spec() for t in tools]


def tools_by_name(tools: list[Tool]) -> dict[str, Tool]:
    """name -> tool. Duplicate names are an error: the model could not tell the tools apart."""
    out: dict[str, Tool] = {}
    for t in tools:
        if t.name in out:
            raise ValueError(f"duplicate tool name {t.name!r}")
        out[t.name] = t
    return out

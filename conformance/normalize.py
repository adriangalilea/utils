"""Reads a probe's stderr, checks every line is an event in the contract's shape,
and prints it with what differs every run replaced by stable tokens.

    python3 normalize.py < probe.err > probe.jsonl

Checked, raising on the first line that breaks it: one JSON object per line; the
keys a subset of the contract's, in its order; `time` an RFC3339 millisecond UTC
instant; ids lowercase hex of their length; `dur_ms` a non-negative number;
`fields` keys in lexicographic order at every depth (an error's own keys in their
fixed order instead).

Replaced: `time` by "T"; each distinct trace id by "trace#n" and span id by
"span#n" in order of first appearance, so which events share an id survives;
`dur_ms` by "D"; an error's `type` by "E" and its `stack` dropped (both are each
language's own). `TRACE_ID` and `PARENT_ID` in the environment are kept as
themselves, so a joined trace shows its real ids.
"""

import json
import os
import re
import sys

ORDER = [
    "time", "level", "verb", "msg", "service", "scope", "phase",
    "trace_id", "span_id", "parent_id", "status", "dur_ms", "fields",
]
ERROR_ORDER = ["type", "message", "stack", "cause", "source", "operation", "status", "context"]
TIME = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$")
HEX = {"trace_id": re.compile(r"^[0-9a-f]{32}$"), "span_id": re.compile(r"^[0-9a-f]{16}$"),
       "parent_id": re.compile(r"^[0-9a-f]{16}$")}
KEEP = {os.environ.get("TRACE_ID"), os.environ.get("PARENT_ID")} - {None}


def fail(n: int, line: str, why: str) -> None:
    sys.exit(f"line {n}: {why}\n  {line}")


def is_error(v: object) -> bool:
    return isinstance(v, dict) and "type" in v and "message" in v and list(v)[:2] == ["type", "message"]


def check_order(n: int, line: str, v: object, path: str) -> None:
    if isinstance(v, list):
        for i, x in enumerate(v):
            check_order(n, line, x, f"{path}[{i}]")
    if not isinstance(v, dict):
        return
    keys = list(v)
    if is_error(v):
        want = [k for k in ERROR_ORDER if k in v]
        if keys != want:
            fail(n, line, f"{path}: error keys {keys}, want {want}")
        if "cause" in v:
            check_order(n, line, v["cause"], f"{path}.cause")
        return
    if keys != sorted(keys):
        fail(n, line, f"{path}: keys {keys} not in lexicographic order")
    for k, x in v.items():
        check_order(n, line, x, f"{path}.{k}")


def scrub_errors(v: object) -> object:
    if isinstance(v, list):
        return [scrub_errors(x) for x in v]
    if not isinstance(v, dict):
        return v
    if is_error(v):
        out = {k: scrub_errors(x) for k, x in v.items() if k != "stack"}
        out["type"] = "E"
        return out
    return {k: scrub_errors(x) for k, x in v.items()}


ids: dict[str, str] = {}


def token(kind: str, value: str) -> str:
    if value in KEEP:
        return value
    if value not in ids:
        ids[value] = f"{kind}#{sum(1 for t in ids.values() if t.startswith(kind)) + 1}"
    return ids[value]


for n, line in enumerate(sys.stdin, 1):
    line = line.rstrip("\n")
    try:
        event = json.loads(line, object_pairs_hook=lambda pairs: dict(pairs))
    except json.JSONDecodeError:
        fail(n, line, "not a JSON event")
    if not isinstance(event, dict):
        fail(n, line, "not an object")
    keys = list(event)
    if any(k not in ORDER for k in keys):
        fail(n, line, f"unknown keys {[k for k in keys if k not in ORDER]}")
    if keys != [k for k in ORDER if k in event]:
        fail(n, line, f"keys {keys} out of the contract's order")
    if not TIME.match(event["time"]):
        fail(n, line, f"time {event['time']!r} is not RFC3339 milliseconds UTC")
    for k, pattern in HEX.items():
        if k in event and not pattern.match(event[k]):
            fail(n, line, f"{k} {event[k]!r} is not lowercase hex of its length")
    if "dur_ms" in event and not (isinstance(event["dur_ms"], (int, float)) and event["dur_ms"] >= 0):
        fail(n, line, f"dur_ms {event['dur_ms']!r}")
    if "fields" in event:
        check_order(n, line, event["fields"], "fields")

    event["time"] = "T"
    if "trace_id" in event:
        event["trace_id"] = token("trace", event["trace_id"])
    for k in ("span_id", "parent_id"):
        if k in event:
            event[k] = token("span", event[k])
    if "dur_ms" in event:
        event["dur_ms"] = "D"
    if "fields" in event:
        event["fields"] = scrub_errors(event["fields"])
    print(json.dumps(event, separators=(",", ":"), ensure_ascii=False))

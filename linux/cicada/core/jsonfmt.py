"""JSON written the way the Mac's JSONEncoder writes [.prettyPrinted, .sortedKeys], byte for byte:
`"key" : value`, two-space indent, `[\n\n  ]` for an empty array, `\\/` for a slash, shortest
doubles with no ".0". The stdlib's json.dumps can't produce that spacing, so records are written
here; reading uses json.loads (ints stay ints, so a whole number reads and writes back unchanged)."""
from __future__ import annotations

import json
from decimal import Decimal


def parse(text: str):
    return json.loads(text)


def parse_object(text: str) -> dict | None:
    try:
        v = json.loads(text)
    except (ValueError, TypeError):
        return None
    return v if isinstance(v, dict) else None


def number(d: float) -> str:
    """Shortest round-trip digits, as Swift prints a Double: "2" not "2.0", no exponent."""
    if d != d or d in (float("inf"), float("-inf")):
        return "0"
    if d == int(d) and abs(d) < 1e15:
        return str(int(d))
    s = repr(d)
    if "e" in s or "E" in s:
        s = format(Decimal(s).normalize(), "f")
    return s


def write(value, pretty: bool = True) -> str:
    out: list[str] = []
    _emit(out, value, pretty, 0)
    return "".join(out)


def _emit(out: list[str], v, pretty: bool, depth: int) -> None:
    if v is None:
        out.append("null")
    elif isinstance(v, bool):
        out.append("true" if v else "false")
    elif isinstance(v, int):
        out.append(str(v))
    elif isinstance(v, float):
        out.append(number(v))
    elif isinstance(v, str):
        _quote(out, v)
    elif isinstance(v, dict):
        # Sorted like Swift's .sortedKeys; nulls are left out, as Swift leaves out nil optionals.
        items = sorted(((k, x) for k, x in v.items() if x is not None), key=lambda kv: kv[0])
        if not items:
            out.append("{\n\n" + "  " * depth + "}" if pretty else "{}")
            return
        out.append("{")
        for n, (k, x) in enumerate(items):
            if n:
                out.append(",")
            if pretty:
                out.append("\n" + "  " * (depth + 1))
            _quote(out, k)
            out.append(" : " if pretty else ":")
            _emit(out, x, pretty, depth + 1)
        if pretty:
            out.append("\n" + "  " * depth)
        out.append("}")
    elif isinstance(v, (list, tuple)):
        if not v:
            out.append("[\n\n" + "  " * depth + "]" if pretty else "[]")
            return
        out.append("[")
        for n, x in enumerate(v):
            if n:
                out.append(",")
            if pretty:
                out.append("\n" + "  " * (depth + 1))
            _emit(out, x, pretty, depth + 1)
        if pretty:
            out.append("\n" + "  " * depth)
        out.append("]")
    else:
        _quote(out, str(v))


_ESC = {'"': '\\"', "\\": "\\\\", "/": "\\/", "\n": "\\n", "\r": "\\r", "\t": "\\t", "\b": "\\b", "\f": "\\f"}


def _quote(out: list[str], s: str) -> None:
    out.append('"')
    for c in s:
        e = _ESC.get(c)
        if e is not None:
            out.append(e)
        elif c < " ":
            out.append("\\u%04x" % ord(c))
        else:
            out.append(c)
    out.append('"')


# Lenient accessors for decoded JSON.

def obj(v) -> dict | None:
    return v if isinstance(v, dict) else None


def arr(v) -> list:
    return v if isinstance(v, list) else []


def string(v) -> str | None:
    return v if isinstance(v, str) else None


def num(v) -> float | None:
    if isinstance(v, bool):
        return None
    if isinstance(v, (int, float)):
        return v
    if isinstance(v, str):
        try:
            return float(v.strip())
        except ValueError:
            return None
    return None


def integer(v) -> int | None:
    n = num(v)
    return None if n is None else int(n)


def boolean(v) -> bool | None:
    return v if isinstance(v, bool) else None

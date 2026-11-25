"""Searching a meeting's lines, shared by the notes window and the records window, so a search finds
the same lines (misheard names included) and marks them the same way in both (the Mac's
TranscriptSearch.swift)."""
from __future__ import annotations


def terms(query: str, notes: list = ()) -> list:
    """The query, plus every way the notes say that name was heard (江充 also finds 江松)."""
    q = query.strip()
    if not q:
        return []
    out = [q]
    low = q.lower()
    for t in notes or ():
        forms = [t.name] + list(t.heard or [])
        if any(f and (low in f.lower() or f.lower() in low) for f in forms):
            out += [f for f in forms if f and f not in out]
    return out


def line_matches(line, terms_: list) -> bool:
    low = [t.lower() for t in terms_ if t]
    shown, dst = line.shown.lower(), (line.dst or "").lower()
    return any(t in shown or t in dst for t in low)


def matches(lines: list, terms_: list) -> list:
    """The ids of the lines a search finds, in order."""
    if not terms_:
        return []
    return [l.id for l in lines if line_matches(l, terms_)]


def spans(text: str, terms_: list) -> list:
    """Where each term is in `text` (case-insensitive), as merged (start, end) pairs: every occurrence
    gets marked."""
    low = text.lower()
    found = []
    for t in terms_:
        t = t.lower()
        # lower() can change a string's length (İ): then its offsets don't fit `text`, so leave it unmarked.
        if not t or len(low) != len(text):
            continue
        i = low.find(t)
        while i >= 0:
            found.append((i, i + len(t)))
            i = low.find(t, i + len(t))
    found.sort()
    merged = []
    for a, b in found:
        if merged and a <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(b, merged[-1][1]))
        else:
            merged.append((a, b))
    return merged

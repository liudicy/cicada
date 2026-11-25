"""词表: the spellings the user stands behind, and how speech recognition has misheard each (the Mac's
Vocabulary.swift). Only these let a new name be fixed without asking: names the notes guess are often
wrong, so they stay suggestions until the user confirms one. One JSON file beside the records
(vocabulary.json, the Mac's format); not a secret, so not one of the 0600 key files. Thread-safe."""
from __future__ import annotations

import os
import threading
import unicodedata
from dataclasses import dataclass, field
from datetime import datetime

from . import correction, jsonfmt
from .models import iso_read, iso_write, now
from .support import Log, Paths

# More would make every sentence's request long, and more terms means more wrong swaps.
LIMIT = 300
_SEPARATORS = "、,，;；"


@dataclass
class Term:
    word: str
    heard: list = field(default_factory=list)  # wrong forms the recognizer produced, confirmed or typed by the user
    source: str = "user"  # "user" (added or imported), "live" (confirmed during a meeting)
    fixes: int = 0
    used: datetime | None = None

    def copy(self) -> "Term":
        return Term(self.word, list(self.heard), self.source, self.fixes, self.used)

    def to_json(self) -> dict:
        return {"word": self.word, "heard": list(self.heard), "source": self.source, "fixes": self.fixes,
                "used": iso_write(self.used) if self.used else None}

    @staticmethod
    def from_json(o: dict) -> "Term | None":
        w = jsonfmt.string(o.get("word"))
        if not w:
            return None
        return Term(w, [h for h in jsonfmt.arr(o.get("heard")) if isinstance(h, str)], jsonfmt.string(o.get("source")) or "user",
                    jsonfmt.integer(o.get("fixes")) or 0, iso_read(jsonfmt.string(o.get("used"))))


@dataclass
class ImportResult:
    added: int = 0
    updated: int = 0
    skipped: list = field(default_factory=list)


def key(s: str) -> str:
    """Same word whatever its width, case or spacing ("ＡＡＶＥ" is "aave")."""
    return " ".join(unicodedata.normalize("NFKC", s).lower().split())


def _punct(c: str) -> bool:
    return unicodedata.category(c).startswith("P")


def _edge(c: str) -> bool:
    return c.isspace() or unicodedata.category(c)[0] in "PS"


def learnable(heard: str, word: str):
    """What a fix can teach the list, or None (Vocabulary.swift's learnable): both sides trimmed of
    spaces and punctuation, no punctuation inside, short, and a real swap. An edit that only adds or
    drops words around the heard ones ("我来" → "OK我来") or ends on a full stop ("持。" → "讲。")
    teaches nothing."""
    def trim(s: str) -> str:
        a, b = 0, len(s)
        while a < b and _edge(s[a]):
            a += 1
        while b > a and _edge(s[b - 1]):
            b -= 1
        return s[a:b]
    h, w = trim(heard), trim(word)
    if (not h or not w or len(h) > 20 or len(w) > 40 or key(h) == key(w) or h in w or w in h
            or any(_punct(c) for c in h) or any(_punct(c) and c not in ".-" for c in w)):
        return None
    return h, w


def default_path() -> str:
    return os.path.join(Paths.data(), "vocabulary.json")


def parse(text: str) -> list:
    """粘贴导入: one per line, heard forms after "=" ("Morpho = 莫拉、莫法"). Each non-empty line as
    (line number, word, heard); a word too long or with control characters comes back as "" (skipped)."""
    out = []
    for i, raw in enumerate(text.splitlines()):
        line = raw.strip()
        if not line:
            continue
        word, eq, rest = line.partition("=")
        word = word.strip()
        heard = []
        if eq:
            part = ""
            for c in rest:
                if c in _SEPARATORS:
                    heard.append(part)
                    part = ""
                else:
                    part += c
            heard.append(part)
            heard = [h.strip() for h in heard if h.strip()]
        if not word or len(word) > 40 or any(unicodedata.category(c) == "Cc" for c in word):
            out.append((i + 1, "", []))
        else:
            out.append((i + 1, word, heard))
    return out


class Vocabulary:
    def __init__(self, path: str | None):
        self.path = path
        self._gate = threading.RLock()
        self.terms: list = []
        self.on_change = None
        if path and os.path.isfile(path):
            try:
                with open(path, encoding="utf-8") as f:
                    v = jsonfmt.parse(f.read())
                self.terms = [t for t in (Term.from_json(o) for o in jsonfmt.arr(v) if isinstance(o, dict)) if t]
            except (OSError, ValueError) as e:
                Log.d("vocabulary: unreadable (%s)" % type(e).__name__)

    def _find(self, word: str) -> int | None:
        k = key(word)
        return next((i for i, t in enumerate(self.terms) if key(t.word) == k), None)

    def snapshot(self) -> list:
        with self._gate:
            return [t.copy() for t in self.terms]

    def knows(self, heard: str, word: str) -> bool:
        h, w = key(heard), key(word)
        with self._gate:
            return any(key(t.word) == w and any(key(x) == h for x in t.heard) for t in self.terms)

    def confirm(self, heard: str, word: str, source: str = "live") -> None:
        """The user said yes to a fix (or added it): the word, and the form it was heard as. A pair
        that isn't a word for a word (`learnable`) adds nothing. A yes in a meeting never teaches a
        translation (平台 → platform): it would rewrite that word everywhere after."""
        if heard:
            pair = learnable(heard, word)
            if pair is None or (source != "user" and correction.translation(*pair)):
                return
            heard, word = pair
        with self._gate:
            i = self._find(word)
            if i is not None:
                if heard and not any(key(x) == key(heard) for x in self.terms[i].heard):
                    self.terms[i].heard.append(heard)
            else:
                self.terms.append(Term(word, [heard] if heard else [], source))
        self._save()

    def forget(self, heard: str, word: str) -> None:
        """A heard form the user turned down twice (or took off in 词表) stops being one."""
        with self._gate:
            i = self._find(word)
            if i is None:
                return
            self.terms[i].heard = [x for x in self.terms[i].heard if key(x) != key(heard)]
        self._save()

    def rename(self, word: str, new: str) -> None:
        """词表 › click a word: its spelling changes; what it was heard as stays with it."""
        n = new.strip()
        with self._gate:
            i = self._find(word)
            if not n or len(n) > 40 or i is None:
                return
            j = self._find(n)
            if j is not None and j != i:
                # Renamed onto a word already there: the two become one.
                for h in self.terms[i].heard:
                    if not any(key(x) == key(h) for x in self.terms[j].heard):
                        self.terms[j].heard.append(h)
                del self.terms[i]
            else:
                self.terms[i].word = n
        self._save()

    def owners(self, heard: str, except_word: str | None = None) -> list:
        """The other words a heard form already belongs to ("莫拉" is Morpho's)."""
        with self._gate:
            return [t.word for t in self.terms if any(key(x) == key(heard) for x in t.heard)
                    and key(t.word) != key(except_word or "")]

    def insert(self, term: Term, index: int) -> None:
        """Back where it was, after 撤销 on a delete."""
        with self._gate:
            if self._find(term.word) is not None:
                return
            self.terms.insert(min(index, len(self.terms)), term.copy())
        self._save()

    def restore(self, saved: list) -> None:
        """撤销: the list as it was."""
        with self._gate:
            if saved == self.terms:
                return
            self.terms = [t.copy() for t in saved]
        self._save()

    def remove(self, word: str) -> None:
        with self._gate:
            self.terms = [t for t in self.terms if key(t.word) != key(word)]
        self._save()

    def used(self, word: str, at: datetime | None = None) -> None:
        with self._gate:
            i = self._find(word)
            if i is None:
                return
            self.terms[i].fixes += 1
            self.terms[i].used = at or now()
        self._save()

    def prompt_lines(self) -> list:
        """For the request: the most recently useful first, "Morpho (heard as 莫拉, 莫法)"."""
        oldest = datetime.min.replace(tzinfo=now().tzinfo)
        with self._gate:
            ts = sorted(self.terms, key=lambda t: t.used or oldest, reverse=True)[:LIMIT]
            return [t.word if not t.heard else "%s (heard as %s)" % (t.word, ", ".join(t.heard)) for t in ts]

    def preview(self, text: str) -> ImportResult:
        """What 粘贴导入 would do, before it does it (the sheet's counts and its button)."""
        r = ImportResult()
        seen = set()
        with self._gate:
            for line, word, _heard in parse(text):
                if not word:
                    r.skipped.append(line)
                    continue
                k = key(word)
                if self._find(word) is not None or k in seen:
                    r.updated += 1
                else:
                    r.added += 1
                seen.add(k)
        return r

    def import_text(self, text: str) -> ImportResult:
        r = ImportResult()
        with self._gate:
            for line, word, heard in parse(text):
                if not word:
                    r.skipped.append(line)
                    continue
                i = self._find(word)
                if i is not None:
                    for h in heard:
                        if not any(key(x) == key(h) for x in self.terms[i].heard):
                            self.terms[i].heard.append(h)
                    r.updated += 1
                else:
                    self.terms.append(Term(word, list(heard), "user"))
                    r.added += 1
        self._save()
        return r

    def _save(self) -> None:
        if self.on_change is not None:
            self.on_change()
        if not self.path:
            return
        with self._gate:
            # The Mac writes this file without escaping slashes (.withoutEscapingSlashes); an escaped
            # slash is always "\/" here, after an even run of backslashes, so the swap is exact.
            text = jsonfmt.write([t.to_json() for t in self.terms]).replace("\\/", "/")
        try:
            os.makedirs(os.path.dirname(self.path), exist_ok=True)
            tmp = self.path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                f.write(text)
            os.replace(tmp, self.path)
        except OSError as e:
            Log.d("vocabulary: save failed %s" % type(e).__name__)

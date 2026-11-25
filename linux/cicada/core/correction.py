"""改正听错的词: which of the AI service's proposed fixes to take, and the line as shown once they are
in. A port of the Mac's Correction.swift, rule for rule (its tests are in tests/test_fixes.py)."""
from __future__ import annotations

import os
from dataclasses import dataclass

from . import jsonfmt
from .models import LineFix


def _word(c: str) -> bool:
    """A character of a Latin word: ASCII letters and digits."""
    return c.isascii() and c.isalnum()


def core(frm: str, to: str) -> tuple:
    """The part an edit changes, as a word: "解除质压" → "解除质押" is "质压" → "质押" (at least two
    characters, so one refusal doesn't block every 压 → 押), and a Latin word stays whole
    ("Un450P三" → "Uniswap V3", not "450P三" → "iswap V3")."""
    a, b = frm, to
    i = 0
    while i < min(len(a), len(b)) and a[i] == b[i]:
        i += 1
    j = 0
    while j < min(len(a), len(b)) - i and a[len(a) - 1 - j] == b[len(b) - 1 - j]:
        j += 1

    def from_edge(k):
        return (k < len(a) and _word(a[k])) or (k < len(b) and _word(b[k]))
    # Only a change that starts or ends inside a Latin word takes the rest of the word.
    if from_edge(i):
        while i > 0 and _word(a[i - 1]):
            i -= 1
    if (len(a) - j - 1 >= 0 and _word(a[len(a) - j - 1])) or (len(b) - j - 1 >= 0 and _word(b[len(b) - j - 1])):
        while j > 0 and _word(a[len(a) - j]):
            j -= 1
    # Two characters at least, taken from the Chinese side: "FFT制押" → "FFT质押" is "制押" → "质押".
    while len(a) - j - i < 2 or len(b) - j - i < 2:
        if j > 0 and not _word(a[len(a) - j]):
            j -= 1
        elif i > 0 and not _word(a[i - 1]):
            i -= 1
        else:
            break
    return a[i:len(a) - j], b[i:len(b) - j]



def label(f) -> tuple:
    """A fix as the UI names it (听成 X → Y, 已改回 X): the changed words, or the whole fix when it
    only adds or drops words ("in" → "in now", whose changed part alone would be "" → "now")."""
    cf, ct = core(f.from_, f.to)
    return (f.from_, f.to) if not cf or not ct else (cf, ct)

def word(s: str, text: str) -> int:
    """Where `s` stands as words of its own in `text` (its offset, or -1): a Latin edge of it never runs
    on into a Latin word around it. `core` pads a fix to two characters, so the word list learned
    "S平 → X平", which matched inside "iOS平台" and made it "iOX平台"."""
    if not s:
        return -1
    i = text.find(s)
    while i >= 0:
        before = text[i - 1] if i > 0 else ""
        after = text[i + len(s)] if i + len(s) < len(text) else ""
        if not (_word(s[0]) and before and _word(before)) and not (_word(s[-1]) and after and _word(after)):
            return i
        i = text.find(s, i + 1)
    return -1


def apply(fixes: list, src: str) -> tuple:
    """The line as shown: each applied fix replaces its words where they still are. The marks are the
    replaced words as (start, end) character offsets into the text, for the underline."""
    text = src
    spans = []  # replacement and its character offset, kept valid as the text changes
    # The user's own last: written against the line as it was shown, other fixes in.
    ordered = [f for f in fixes if f.user is not True] + [f for f in fixes if f.user is True]
    for f in ordered:
        if not f.applied or not f.from_:
            continue
        start = word(f.from_, text)
        if start < 0:
            start = text.find(f.from_)
        if start < 0:
            continue
        delta = len(f.to) - len(f.from_)
        spans = [(w, o + delta) if o > start else (w, o) for w, o in spans]
        text = text[:start] + f.to + text[start + len(f.from_):]
        spans.append((f.to, start))
    marks = sorted((o, o + len(w)) for w, o in spans if o + len(w) <= len(text))
    return text, marks


# Deciding which of the service's proposed fixes to take, without asking it again. Its own confidence
# isn't enough: in a 21-minute test it rated "快销 → 区块" and "苍蝇 → 方向" above 0.85. So a Chinese
# word may only be swapped for one that sounds alike, a Latin word only for a near spelling, and a new
# name only once the user says so.

APPLY, ASK, DROP = "apply", "ask", "drop"
APPLY_AT = 0.6
SPELLING_AT = 0.8
ASK_AT = 0.8


@dataclass
class Edit:
    """A fix the service proposed: the subtitle's words, what was said, how sure it is."""
    from_: str
    to: str
    confidence: float


def decide(e: Edit, known, rejected) -> str:
    """`known(heard, word)`: the user confirmed this heard form for this word (the word list).
    `rejected(heard, word)`: they said no to it in this meeting."""
    cf, ct = core(e.from_, e.to)
    if not cf or not ct or cf.lower() == ct.lower() or rejected(e.from_, e.to) or rejected(cf, ct):
        return DROP
    if known(e.from_, e.to) or known(cf, ct):
        return APPLY
    if e.confidence < APPLY_AT:
        return DROP
    latin_from = any(_latin_letter(c) for c in cf)
    latin_to = any(_latin_letter(c) for c in ct)
    if not latin_from and not latin_to and han(cf) and han(ct) and sounds_alike(cf, ct):
        return APPLY
    if latin_from and latin_to and cf.isascii() and ct.isascii() and e.confidence >= SPELLING_AT \
            and cf.lower() != ct.lower() and distance(cf.lower(), ct.lower()) <= 2:
        return APPLY
    # A new name (Chinese heard as a Latin name, or a respelled one): sound can't check it. A
    # name has a capital or a digit; "X平台 → X platform" is a translation, and one 对 to it
    # taught the word list 平台 → platform, which then rewrote every 平台 in the meeting.
    if latin_to and e.confidence >= ASK_AT and name_shaped(ct):
        return ASK
    return DROP


def name_shaped(s: str) -> bool:
    """Latin text that could be a name: a capital or a digit in it (Morpho, GPT4o), not "platform"."""
    return any(c.isascii() and (c.isupper() or c.isdigit()) for c in s)


def translation(heard: str, word: str) -> bool:
    """A Chinese word "fixed" into a plain English one (平台 → platform): a translation, not a
    misheard name."""
    return han(heard) and any(_latin_letter(c) for c in word) and word.isascii() and not name_shaped(word)


def _latin_letter(c: str) -> bool:
    return c.isascii() and c.isalpha()


# Toneless pinyin per character. Ubuntu's Python has no Mandarin transform, so the table is the Mac's
# own: generated once from Apple's ICU/CLDR Han-Latin transform (kCFStringTransformMandarinLatin, then
# diacritics stripped) for U+4E00–U+9FFF, 20,924 characters, one "<char>\t<syllable>" per line. Data,
# not a dependency; the same readings the Mac compares, so both decide alike.
_PINYIN: dict | None = None


def _table() -> dict:
    global _PINYIN
    if _PINYIN is None:
        t = {}
        with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "pinyin.tsv"), encoding="utf-8") as f:
            for line in f:
                ch, _, syl = line.rstrip("\n").partition("\t")
                if ch and syl:
                    t[ch] = syl
        _PINYIN = t
    return _PINYIN


def pinyin(s: str) -> list:
    """One toneless syllable per character; a character the table doesn't know stays itself."""
    t = _table()
    return [t.get(c, c.lower()) for c in s]


_INITIALS = ("zh", "ch", "sh", "b", "p", "m", "f", "d", "t", "n", "l", "g", "k", "h", "j", "q",
             "x", "r", "z", "c", "s", "y", "w")


def _split(syllable: str) -> tuple:
    for i in _INITIALS:
        if syllable.startswith(i):
            return i, syllable[len(i):]
    return "", syllable


def sounds_alike(a: str, b: str) -> bool:
    """Same number of syllables, and on average three quarters alike: a syllable counts whole when
    equal, half when its initial or its final matches (质/追, 销/照). 苍蝇/方向 is a quarter."""
    x, y = pinyin(a), pinyin(b)
    if len(x) != len(y) or not x:
        return False
    score = 0.0
    for p, q in zip(x, y):
        if p == q:
            score += 1
            continue
        i1, f1 = _split(p)
        i2, f2 = _split(q)
        if i1 == i2 or f1 == f2 or f1.replace("ng", "n") == f2.replace("ng", "n"):
            score += 0.5
    return score / len(x) >= 0.75


def han(s: str) -> bool:
    """Every character a Han ideograph (Swift's isIdeographic)."""
    def ideograph(c):
        o = ord(c)
        return (0x3400 <= o <= 0x4DBF or 0x4E00 <= o <= 0x9FFF or 0xF900 <= o <= 0xFAFF or 0x20000 <= o <= 0x3134F
                or o in (0x3006, 0x3007) or 0x3021 <= o <= 0x3029 or 0x3038 <= o <= 0x303A)
    return all(ideograph(c) for c in s)


def distance(a: str, b: str) -> int:
    row = list(range(len(b) + 1))
    for i, ca in enumerate(a):
        prev = row[0]
        row[0] = i + 1
        for j, cb in enumerate(b):
            cur = row[j + 1]
            row[j + 1] = min(row[j + 1] + 1, row[j] + 1, prev + (0 if ca == cb else 1))
            prev = cur
    return row[len(b)]


def parse(reply: str, subtitle: str):
    """The service's reply to a sentence sent with fixes asked for: {"translation": "…", "fixes":
    [{"from", "to", "confidence"}]} → (translation, [Edit]). None when it isn't that shape, and the
    caller treats it as a failed translation. Fixes whose words aren't in the subtitle are dropped:
    the service sometimes quotes them rephrased."""
    # Asked for JSON in the prompt only: take the outermost {…}, fenced or not.
    a, b = reply.find("{"), reply.rfind("}")
    if a < 0 or b <= a:
        return None
    o = jsonfmt.parse_object(reply[a:b + 1])
    if o is None or not isinstance(o.get("translation"), str):
        return None
    edits = []
    for f in jsonfmt.arr(o.get("fixes")):
        if not isinstance(f, dict):
            continue
        frm, to = jsonfmt.string(f.get("from")), jsonfmt.string(f.get("to"))
        if not frm or to is None or frm == to or frm not in subtitle:
            continue
        edits.append(Edit(frm, to, float(jsonfmt.num(f.get("confidence")) or 0.0)))
    return o["translation"].strip(), edits


def merge(old: list, new: list) -> list:
    """What a line's fixes become after the service answered for it again (a joined line, or a
    recheck with the lines after it in view): the user's decisions stay (said no, said yes, wrote it),
    and of the rest only what is proposed again. So a recheck that no longer proposes a fix takes it back."""
    kept = [f for f in old if f.off is True or f.user is True]
    fresh = []
    for n in new:
        cf = core(n.from_, n.to)[0]
        if not any(k.from_ == n.from_ or core(k.from_, k.to)[0] == cf for k in kept):
            fresh.append(n)
    return kept + fresh


def user_edit(shown: str, edited: str, src: str, fixes: list):
    """改这句…: the user rewrote the line as shown. What changed, as a fix on top of the others: the
    changed span grown to whole tokens (a Latin word, or one CJK character), and further, a token at a
    time, until it holds a letter and is the only such span in the line. An added word ("lock that
    in." → "lock that in now.") is then "in" → "in now" on this line, never "." on every line.
    `swap` is whether words were replaced (not only added or dropped): only a swap may go to the rest
    of the meeting and teach the word list. `heard` is the words in `src` when they are there, else
    the heard words of the fix the user corrected again ("莫纳" → "Morpho" → "Monad").
    (fix, heard, swap), or None: no change (Correction.swift's userEdit)."""
    new = edited.strip()
    if not new or new == shown:
        return None
    a, b = shown, new
    p = 0
    while p < min(len(a), len(b)) and a[p] == b[p]:
        p += 1
    q = 0
    while q < min(len(a), len(b)) - p and a[len(a) - 1 - q] == b[len(b) - 1 - q]:
        q += 1
    swap = len(a) - p - q > 0 and len(b) - p - q > 0

    def latin(c: str) -> bool:
        return c.isascii() and c.isalnum()
    # Tokens of the shown line, as (start, end): a run of ASCII letters and digits, else one character.
    tokens = []
    k = 0
    while k < len(a):
        e = k + 1
        if latin(a[k]):
            while e < len(a) and latin(a[e]):
                e += 1
        tokens.append((k, e))
        k = e
    start, end = p, len(a) - q
    t = next((t for t in tokens if t[0] <= start < t[1]), None)
    if t is not None:
        start = t[0]
    if end > start:
        t = next((t for t in tokens if t[0] <= end - 1 < t[1]), None)
        if t is not None:
            end = t[1]
    # A dropped word ("in now." → "in.") grows too, so neither side of the fix is empty.
    while True:
        span = a[start:end]
        if any(c.isalnum() for c in span) and span and a.count(span) == 1 and b[start:len(b) - (len(a) - end)]:
            break
        before = [t for t in tokens if t[1] <= start]
        after = [t for t in tokens if t[0] >= end]
        if before:
            start = before[-1][0]
        elif after:
            end = after[0][1]
        else:
            break
    frm = a[start:end]
    to = b[start:len(b) - (len(a) - end)]
    if not frm or frm == to:
        return None
    heard = frm
    if frm not in src:
        earlier = next((f for f in fixes if f.applied and f.to in frm), None)
        if earlier is not None:
            heard = core(earlier.from_, earlier.to)[0]
    return LineFix(frm, to, user=True), heard, swap

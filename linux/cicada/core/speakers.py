"""说话人识别: telling the other side's voices apart (SpeakerID.swift). Each heard line's audio becomes a
voiceprint (WeSpeaker ResNet34-LM, VoxCeleb, CC BY 4.0), voiceprints are grouped as they arrive, and a
voice is only named once it has a few lines. The thresholds are the Mac's (tuned on AMI meetings).

The model runs in native/voiceprint.c (libcicada-voice), loaded with ctypes: a stock Ubuntu desktop has no
BLAS and Python can't run a ResNet in real time. Without the library or the weights the feature is
unavailable and listening carries on as before."""
from __future__ import annotations

import copy
import ctypes
import json
import os
import platform
import threading

from . import strings
from .support import Log, clock


# Voiceprints

def _root() -> str:
    # linux/ in the source tree, cicada-linux/ in the installed one: the folder holding cicada/.
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def library_path() -> str | None:
    env = os.environ.get("CICADA_VOICE_LIB")
    if env:
        return env if os.path.isfile(env) else None
    name = "libcicada-voice.dylib" if platform.system() == "Darwin" else "libcicada-voice-%s.so" % platform.machine()
    for folder in ("lib", os.path.join("native", "out")):
        p = os.path.join(_root(), folder, name)
        if os.path.isfile(p):
            return p
    return None


def model_path() -> str | None:
    p = os.path.join(_root(), "models", "voiceprint.bin")
    return p if os.path.isfile(p) else None


class Voiceprints:
    MIN_SECONDS = 0.5
    DIMS = 256

    def __init__(self, lib, model):
        self._lib = lib
        self._model = model
        self._lock = threading.Lock()  # one at a time: each already uses up to four cores

    @staticmethod
    def load() -> "Voiceprints | None":
        lib_file, weights = library_path(), model_path()
        if lib_file is None or weights is None:
            Log.d("speakers: no voiceprint %s" % ("library" if lib_file is None else "model"))
            return None
        try:
            lib = ctypes.CDLL(lib_file)
        except OSError as e:
            Log.d("speakers: voiceprint library failed to load (%s)" % e)
            return None
        lib.cvp_load.restype = ctypes.c_void_p
        lib.cvp_load.argtypes = [ctypes.c_char_p]
        lib.cvp_embed_s16.restype = ctypes.c_int
        lib.cvp_embed_s16.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p, ctypes.c_int]
        model = lib.cvp_load(weights.encode())
        if not model:
            Log.d("speakers: voiceprint model failed to load")
            return None
        return Voiceprints(lib, model)

    def embed(self, samples) -> list | None:
        """A unit-length 256-d voiceprint of 16 kHz mono 16-bit samples (an array('h')), or None when too short."""
        n = len(samples)
        if n < self.MIN_SECONDS * 16000:
            return None
        buf = (ctypes.c_int16 * n).from_buffer_copy(samples.tobytes() if hasattr(samples, "tobytes") else bytes(samples))
        out = (ctypes.c_float * self.DIMS)()
        with self._lock:
            ok = self._lib.cvp_embed_s16(self._model, buf, n, out, 0) == 0
        return list(out) if ok else None


# Grouping

class VoiceClusterer:
    """Groups voiceprints as lines arrive, never revising a line already labelled. A line joins the
    closest voice when similar enough; a long line unlike every voice starts a new one; anything else
    stays unlabelled ("对方"). Tuned on AMI dev meetings (VoiceClusterer, SpeakerID.swift)."""
    NEW_SECONDS = 2.0
    JOIN = 0.5
    START_NEW = 0.5

    def __init__(self):
        self.sums: list = []

    def merge(self, frm: int, into: int) -> None:
        """The user said two voices are one: later lines like either go to `into`."""
        if not (0 <= frm < len(self.sums) and 0 <= into < len(self.sums)) or frm == into:
            return
        self.sums[into] = [a + b for a, b in zip(self.sums[into], self.sums[frm])]
        self.sums[frm] = [0.0] * len(self.sums[frm])  # never the closest again

    def label(self, v: list, seconds: float) -> int | None:
        best, best_sim = -1, -1.0
        for i, s in enumerate(self.sums):
            dot = sum(a * b for a, b in zip(v, s))
            sq = sum(b * b for b in s)
            sim = dot / max(sq ** 0.5, 1.1920929e-07)
            if sim > best_sim:
                best_sim, best = sim, i
        if best >= 0 and best_sim >= self.JOIN:
            self.sums[best] = [a + b for a, b in zip(self.sums[best], v)]
            return best
        if seconds >= self.NEW_SECONDS and (not self.sums or best_sim < self.START_NEW):
            self.sums.append(list(v))
            return len(self.sums) - 1
        return None


class Tagger:
    """Voiceprints on their own thread (while Ming hears the same segment), labelled in arrival order."""

    def __init__(self):
        self._model = None
        self._tried = False
        self._load_lock = threading.Lock()
        self.clusterer = VoiceClusterer()
        self._gate = threading.Lock()

    @property
    def available(self) -> bool:
        return self.model() is not None

    def model(self):
        with self._load_lock:
            if not self._tried:
                self._tried = True
                self._model = Voiceprints.load()
            return self._model

    def reset(self) -> None:
        """A new meeting: forget the voices of the last one."""
        with self._gate:
            self.clusterer = VoiceClusterer()

    def merge(self, frm: int, into: int) -> None:
        with self._gate:
            self.clusterer.merge(frm, into)

    def embed(self, samples):
        m = self.model()
        return m.embed(samples) if m is not None else None

    def label(self, vector, seconds: float) -> int | None:
        if vector is None:
            return None
        with self._gate:
            return self.clusterer.label(vector, seconds)


# What the transcript shows (SpeakerLabels)

SHOWN_AFTER = 5


def _cjk(c: str) -> bool:
    o = ord(c)
    return (0x3400 <= o <= 0x4DBF or 0x4E00 <= o <= 0x9FFF or 0xF900 <= o <= 0xFAFF or 0x20000 <= o <= 0x3FFFF
            or 0x3040 <= o <= 0x30FF or 0xAC00 <= o <= 0xD7A3 or o in (0x3005, 0x3006, 0x3007))


def substantive(text: str) -> bool:
    """A line long enough to say whose voice it is: three words, or four characters of Chinese,
    Japanese or Korean. "Yeah." or a stray "." don't count towards a name."""
    if sum(1 for w in text.split() if any(c.isalpha() for c in w)) >= 3:
        return True
    return sum(1 for c in text if _cjk(c)) >= 4


def voice_numbers(lines) -> dict:
    """Voice id → 1-based speaker number for the voices on show: a voice gets one once it has
    SHOWN_AFTER substantive lines, and only when two voices have, so a one-to-one call stays 对方.
    Numbers follow the order voices got there, so a number never moves once shown."""
    count, reached = {}, {}
    for i, l in enumerate(lines):
        if l.speaker != "them" or l.voice is None or not substantive(l.src):
            continue
        count[l.voice] = count.get(l.voice, 0) + 1
        if count[l.voice] == SHOWN_AFTER:
            reached[l.voice] = i
    shown = sorted(reached, key=lambda v: reached[v])
    if len(shown) < 2:
        return {}
    return {v: n + 1 for n, v in enumerate(shown)}


def numbers(lines) -> dict:
    """Line id → speaker number; lines without one show as 对方."""
    number = voice_numbers(lines)
    return {l.id: number[l.voice] for l in lines if l.speaker == "them" and l.voice in number}


def names(s) -> dict:
    """Speaker number → name: the user's, else Ling's guess (unless the user turned it down)."""
    if s.voiceNames is None and s.voiceGuesses is None:
        return {}
    out = {}
    for v, n in voice_numbers(s.lines).items():
        mine = (s.voiceNames or {}).get(str(v))
        if mine is not None:
            if mine:
                out[n] = mine
        elif (s.voiceGuesses or {}).get(str(v)) is not None:
            out[n] = s.voiceGuesses[str(v)].name
    return out


def guessed(s) -> dict:
    """Speaker number → Ling's guess, for the voices whose shown name is that guess."""
    out = {}
    for v, n in voice_numbers(s.lines).items():
        if (s.voiceNames or {}).get(str(v)) is None and (s.voiceGuesses or {}).get(str(v)) is not None:
            out[n] = s.voiceGuesses[str(v)]
    return out


def run_starts(lines, nums: dict) -> set:
    """Lines where the speaker changes: the transcript names the speaker there only, as chat apps do."""
    out, last = set(), None
    for l in lines:
        key = "me" if l.speaker == "me" else ("n%d" % nums[l.id] if l.id in nums else "?")
        if key != last:
            out.add(l.id)
        last = key
    return out


def label(number: int, shown: dict) -> str:
    """"George", else "说话人 2"."""
    return shown.get(number) or strings.LF("说话人 %lld", number)


def speaker_name(line, nums: dict, shown: dict) -> str:
    """你, a speaker, 对方 (no voices told apart) or 未识别 (a voice not on show) (TranscriptExport.speakerName)."""
    if line.speaker == "me":
        return strings.L("你")
    if line.id in nums:
        return label(nums[line.id], shown)
    return strings.L("对方") if not nums else strings.L("未识别")


def named(notes, shown: dict):
    """The notes as shown: Ling wrote "说话人 6" before anyone named them; show the name since given."""
    if not shown or notes is None:
        return notes

    def swap(text):
        if text is None or ("说话人" not in text and "Speaker" not in text):
            return text
        for n, name in sorted(shown.items(), key=lambda kv: -kv[0]):  # 说话人 12 before 说话人 1
            for form in ("说话人 %d" % n, "说话人%d" % n, "Speaker %d" % n):
                text = text.replace(form, name)
        return text
    n = copy.deepcopy(notes)
    n.summary = swap(n.summary)
    for t in n.topics:
        t.title, t.summary = swap(t.title), swap(t.summary)
        t.points = [swap(p) for p in t.points]
    for c in n.conclusions:
        c.text, c.owner = swap(c.text), swap(c.owner)
    for t in n.todos:
        t.text, t.owner = swap(t.text), swap(t.owner)
    return n


def shown_count(lines) -> int:
    return len(set(numbers(lines).values()))


# People the notes mention (NoteTerm.people)

ROLES = ["首席", "执行官", "主席", "总裁", "董事", "经理", "创始人", "记者", "主持", "研究员", "分析师", "教授", "老师",
         "教师", "官员", "部长", "议员", "候选人", "嘉宾", "发言人", "CEO", "CFO", "CTO", "host", "analyst", "reporter", "founder"]


def people(terms) -> list:
    return [t.name for t in terms if any(r.lower() in (t.note or "").lower() for r in ROLES)]


def suggestions(s, voice: int) -> list:
    """For renaming a voice: its current name, Ling's guess, then people the notes mention, without
    names other voices already have; at most four (SpeakerEditor.suggestions)."""
    nums = voice_numbers(s.lines)
    number = nums.get(voice)
    shown = names(s)
    taken = {v for k, v in shown.items() if k != number}
    out = []
    g = (s.voiceGuesses or {}).get(str(voice))
    if g is not None:
        out.append(g.name)
    for t in people(s.notes.terms if s.notes else []):
        if t not in out and t not in taken:
            out.append(t)
    mine = shown.get(number)
    if mine and mine not in out:
        out.insert(0, mine)
    return out[:4]


# Names from the conversation (SpeakerNameGuess), Ling's prompt word for word

INSTRUCTION = (
    "Who are the people labelled 说话人N? Name one only when the transcript makes it clear: they "
    "introduce themselves on a line labelled with their own 说话人N; someone addresses them by name just "
    "before or after they speak (\"Thanks, George\" right after 说话人1's answer: 说话人1 is George); "
    "or others name them as they speak. A name on a 对方 line, or far from any line of 说话人N (an advert, "
    "a clip, people introducing themselves on another show), is not theirs. Speech recognition writes "
    "names by ear and often misspells them: for a public figure (an official, an executive, a presenter) "
    "recognisable from the name and what is said, write the name as the news spells it (\"Jensen Hwang\" "
    "→ \"Jensen Huang\"); otherwise as written. Leave out anyone "
    "you are unsure of. Reply as JSON: {\"speakers\": [{\"speaker\": 2, \"name\": \"George\", \"evidence\": \"L12\"}]}, "
    "the evidence being the line with the name; an empty list if none. Check each name's spelling before replying.")

EVIDENCE_REACH = 2  # "Okay, Amos, thank you" comes right after Amos's last words


def content(s) -> str | None:
    """The transcript as Ling sees it, newest 400 lines, with speaker labels; None when no voices are shown."""
    nums = numbers(s.lines)
    if not nums:
        return None
    out = ["Meeting transcript. Speakers: 你 = the user; 说话人N = one person on the other side, told apart by voice; "
           "对方 = someone on the other side, not identified.\n"]
    for i, l in enumerate(s.lines[-400:]):
        who = "你" if l.speaker == "me" else ("说话人%d" % nums[l.id] if l.id in nums else "对方")
        out.append("[L%d %s %s] %s\n" % (i + 1, clock(l.t), who, l.src))
    return "".join(out)


def read(reply: str, s):
    """(found: voice → VoiceGuess, refuted: voice → name). A name given on a line the voice neither said
    nor spoke next to is refuted; a name Ling gives two voices goes to the one with more lines."""
    from .models import VoiceGuess
    try:
        obj = json.loads(reply)
    except ValueError:
        return {}, {}
    lst = obj.get("speakers") if isinstance(obj, dict) else None
    if not isinstance(lst, list):
        return {}, {}
    voice_of = {n: v for v, n in voice_numbers(s.lines).items()}
    lines = s.lines[-400:]

    def count(v):
        return sum(1 for l in s.lines if l.voice == v)
    found, refuted = {}, {}
    for item in lst:
        if not isinstance(item, dict):
            continue
        try:
            n = int(str(item.get("speaker")))
        except ValueError:
            continue
        v = voice_of.get(n)
        name = item.get("name")
        if v is None or not isinstance(name, str) or not name.strip() or len(name.strip()) > 40:
            continue
        name = name.strip()
        e = str(item.get("evidence", ""))
        digits = ""
        for c in e[next((k for k, c in enumerate(e) if c.isdigit()), len(e)):]:
            if not c.isdigit():
                break
            digits += c
        i = int(digits) - 1 if digits else -1
        near = lines[max(0, i - EVIDENCE_REACH):i + EVIDENCE_REACH + 1] if 0 <= i < len(lines) else []
        if not any(l.speaker == "them" and l.voice == v for l in near):
            refuted[v] = name
            continue
        other = next((k for k, g in found.items() if g.name == name), None)
        if other is not None:
            if count(other) >= count(v):
                continue
            del found[other]
        l = lines[i]
        quote = l.src[:60] + "…" if len(l.src) > 60 else l.src
        found[v] = VoiceGuess(name, "%s “%s”" % (clock(l.t), quote))
    return found, refuted


def holds(g, v: int, s) -> bool:
    """Whether a stored guess still stands: its evidence line is found again and the voice speaks there."""
    if "“" not in g.evidence:
        return True
    at, quote = g.evidence.split("“", 1)
    at = at.strip()
    quote = quote[:-1] if quote.endswith("”") else quote
    quote = quote.split("…")[0]
    for i, l in enumerate(s.lines):
        if clock(l.t) == at and l.src.startswith(quote):
            return any(x.speaker == "them" and x.voice == v
                       for x in s.lines[max(0, i - EVIDENCE_REACH):i + EVIDENCE_REACH + 1])
    return True


class Namer:
    """Asks Ling for names on its own: once two voices are on show, again every 20 lines, and once more
    when the meeting ends. Guesses go straight into the meeting (voiceGuesses); the user corrects."""

    def __init__(self, ling, store, changed=None):
        self.ling = ling
        self.store = store
        self.changed = changed
        self.busy: set = set()
        self._asked: dict = {}
        self._gate = threading.Lock()

    def guess(self, sid: str, force: bool = False) -> None:
        from .ling import NOTES, LingError
        s = self.store.get(sid)
        if s is None or not self.ling.has_key:
            return
        with self._gate:
            if sid in self.busy or not (force or len(s.lines) >= self._asked.get(sid, -1000) + 20):
                return
            text = content(s)
            if text is None:
                return
            nums = voice_numbers(s.lines)
            if all((s.voiceNames or {}).get(str(v)) is not None for v in nums):
                return  # everyone already has a name the user gave
            self.busy.add(sid)
            self._asked[sid] = len(s.lines)

        def run():
            try:
                reply = self.ling.chat(text, INSTRUCTION, NOTES, json=True, max_tokens=300)
                found, refuted = read(reply, s)
                for key, g in (s.voiceGuesses or {}).items():
                    try:
                        v = int(key)
                    except ValueError:
                        continue
                    if v not in found and not holds(g, v, s):
                        refuted[v] = g.name
                self.store.set_voice_guesses(sid, found, refuted)
                Log.d("speakers: names %d found, %d without evidence" % (len(found), len(refuted)))
            except LingError as e:
                Log.d("speakers: names, ling failed %s" % e)
            finally:
                with self._gate:
                    self.busy.discard(sid)
                if self.changed:
                    self.changed()
        threading.Thread(target=run, name="SpeakerNames", daemon=True).start()

"""Translation and recognition through the cloud (the Windows design): listening sends each stretch
of audio to Ming's audio model, which returns the language, the original and the translation in one
call. Text translation is Ling first, then Google. Calls block."""
from __future__ import annotations

import re
import time
import urllib.parse
from dataclasses import dataclass

from . import jsonfmt
from .jsonfmt import arr
from .ling import AUDIO_MODEL, SPEAK, TRANSLATE, LingError, UrlTransport
from .support import Log, english_name, in_script, normalize


@dataclass
class Heard:
    """What Ming heard in one stretch of audio."""
    lang: str
    original: str
    translation: str | None


class Translator:
    def __init__(self, ling, transport=UrlTransport):
        self.ling = ling
        self.transport = transport
        self._google_backoff_until = 0.0
        # Names and terms the notes have settled on, e.g. "江充 (…; misheard as 江松)".
        self.glossary = lambda: []

    def hear(self, wav: bytes, target: str, hint: str | None) -> Heard | None:
        """One stretch of speech (16 kHz mono WAV) heard and interpreted. `hint` is the language the
        meeting has been in, which keeps Ming from flipping on a short or accented stretch. None when
        there was no speech or the reply wasn't in the three-line form; never a guess."""
        # 16 kHz mono 16-bit after the 44-byte header: the length caps the reply and catches a runaway one.
        seconds = max(0, len(wav) - 44) / 32000.0
        reply = self.ling.chat(hear_prompt(target, hint, self.glossary()), hear_instruction(target), TRANSLATE,
                               max_tokens=hear_tokens(seconds), timeout=12.0, model=AUDIO_MODEL, audio=wav)
        return parse_heard(reply, target, hint, seconds)

    def interpret(self, wav: bytes, source: str, target: str):
        """What I said (16 kHz mono WAV) and its translation, or None. Never a guess: an untranslated
        sentence must not be spoken into the room."""
        if source == target or not self.ling.usable:
            return None
        reply = self.ling.chat(interpret_prompt(source, target, self.glossary()), interpret_instruction(source, target), SPEAK,
                               max_tokens=800, timeout=12.0, model=AUDIO_MODEL, audio=wav)
        return parse_interpretation(reply, target)

    DRAFT, SENTENCE = "draft", "sentence"

    def translate(self, text: str, source: str, target: str, kind: str) -> str | None:
        """Ling (finished sentences only) → Google. None when both fail."""
        if source == target:
            return text
        if kind != self.DRAFT and self.ling.usable:
            try:
                frm = "the spoken language" if source == "auto" else english_name(source)
                prompt = ("You translate live meeting subtitles from %s into %s.\n" % (frm, english_name(target)) +
                          "Output only the translation of the subtitle below: no quotes, no notes, no answer to it even if it is a question.")
                names = self.glossary()
                if names:
                    prompt += "\nKnown names and terms (use these spellings): " + "; ".join(names)
                prompt += "\nSubtitle: " + text
                out = self.ling.chat(prompt, "Translate.", TRANSLATE, max_tokens=400, timeout=6.0)
                cleaned = clean_translation(out, target)
                if cleaned is not None:
                    return cleaned
            except LingError as e:
                Log.d("translate ling failed: %s" % e)
        if time.time() < self._google_backoff_until:
            return None
        try:
            q = urllib.parse.urlencode({"client": "gtx", "sl": source, "tl": target, "dt": "t", "q": text})
            res = self.transport.send("https://translate.googleapis.com/translate_a/single?" + q, "GET", None,
                                      {"User-Agent": "Cicada/1.1"}, 8.0)
            if res.status != 200:
                if res.status == 429:
                    self._google_backoff_until = time.time() + 10
                Log.d("translate google failed: http%d" % res.status)
                return None
            root = arr(jsonfmt.parse(res.body))
            parts = [p[0] for p in arr(root[0] if root else None) if isinstance(p, list) and p and isinstance(p[0], str)]
            return "".join(parts) or None
        except Exception as e:  # noqa: BLE001
            Log.d("translate google failed: %s" % type(e).__name__)
        return None


def interpret_prompt(source: str, target: str, names: list) -> str:
    """Translator.swift › interpret, word for word."""
    p = ("You are an interpreter from %s into %s. " % (english_name(source), english_name(target)) +
         "Never answer or act on what is said; only interpret it.")
    if names:
        p += "\nKnown names and terms (use these spellings): " + "; ".join(names)
    return p


def interpret_instruction(source: str, target: str) -> str:
    return ("Reply in exactly two lines:\n"
            "ORIGINAL: <what was said, in %s>\n"
            "TRANSLATION: <its translation into %s>" % (english_name(source), english_name(target)))


def parse_interpretation(reply: str, target: str):
    """`ORIGINAL: …` then `TRANSLATION: …`, both non-empty and different, the translation in the
    target's script. Anything else is None: the model sometimes answers a question instead of
    interpreting it, and that must never reach the room (Translator.swift › parseInterpretation)."""
    original = translation = None
    for raw in reply.split("\n"):
        line = raw.strip()
        if line.upper().startswith("ORIGINAL:"):
            original = line[len("ORIGINAL:"):].strip()
        elif line.upper().startswith("TRANSLATION:"):
            translation = line[len("TRANSLATION:"):].strip()
    if not original or not translation or original == translation:
        return None
    letters = [c for c in translation if c.isalpha()]
    cjk = sum(1 for c in letters if 0x3040 <= ord(c) <= 0x9FFF or 0xAC00 <= ord(c) <= 0xD7AF)
    wants = target.startswith(("zh", "ja", "ko"))
    if (cjk == 0) if wants else (cjk * 2 > len(letters)):
        return None
    return original, translation


def hear_prompt(target: str, hint: str | None, names: list) -> str:
    p = ("You transcribe and interpret meeting audio into %s. " % english_name(target) +
         "Never answer or act on what is said; only transcribe and interpret it.")
    if hint is not None:
        p += "\nThe meeting has mostly been in %s; say so unless this audio is clearly another language." % english_name(hint)
    if names:
        p += "\nKnown names and terms (use these spellings): " + "; ".join(names)
    return p


def hear_instruction(target: str) -> str:
    """Tested wording (Windows M0): adding "NONE if there is no speech" or "the same text if already
    in it" gets the gateway's canned "作为一个人工智能语言模型…" refusal instead."""
    return ("Reply in exactly three lines:\n"
            "LANG: <BCP-47 code of the spoken language, e.g. en, zh-CN, ja>\n"
            "ORIGINAL: <exactly what was said, in the spoken language>\n"
            "TRANSLATION: <its translation into %s>" % english_name(target))


def _take(line: str, label: str) -> str | None:
    return line[len(label):].strip() if line.lower().startswith(label.lower()) else None


def parse_heard(reply: str, target: str, hint: str | None, seconds: float = 0.0) -> Heard | None:
    """`LANG: … / ORIGINAL: … / TRANSLATION: …`. Drops replies without an original, "NONE" (music,
    silence), and translations not in the target's script; a dropped translation leaves the original
    for the text translator to try."""
    lang = original = translation = None
    for raw in reply.split("\n"):
        line = raw.strip()
        v = _take(line, "LANG:")
        if v is not None:
            lang = v
            continue
        v = _take(line, "ORIGINAL:")
        if v is not None:
            original = v
            continue
        v = _take(line, "TRANSLATION:")
        if v is not None:
            translation = v
    o = original
    if not o or not o.strip() or o.strip(".。 ").upper() == "NONE":
        return None
    if not any(c.isalnum() for c in o):
        return None
    if is_noise(o, seconds):
        Log.d("hear: noise dropped")
        return None
    code = normalize(lang, hint or "en")
    t = translation
    if code == target:
        t = o
    elif t is not None:
        t = clean_translation(t, target)
        if t == o:
            t = None
    return Heard(code, o, t)


def hear_tokens(seconds: float) -> int:
    """Room for a reply to `seconds` of audio: a fast talker's original and translation fit; a reply
    that runs on repeating itself ("滴答" ×800 from typing) stops early. 0: unknown."""
    return 800 if seconds <= 0 else min(800, int(60 + 40 * seconds))


# Ming describing the audio instead of transcribing it: "（无语音内容）", "[Music]", "这段音频是一段旋律，
# 没有说话声。". A bracketed note beside real words ("（笑）好的") keeps the words.
_ANNOTATION = re.compile(r"[(（\[【][^)）\]】]*[)）\]】]|♪")
_NO_SPEECH = (
    "没有说话", "无语音", "没有语音", "没有人声", "无人声", "没有人说话", "无人说话",
    "no speech", "no spoken", "no one is speaking", "nobody is speaking", "no audible speech", "no dialogue",
    "音声がありません", "発話がありません", "話し声はありません", "음성이 없습니다", "말소리가 없습니다",
)

_FILLERS = (
    "嗯", "啊", "呃", "额", "哦", "噢", "喔", "唔", "哈", "诶", "欸", "哎", "喂", "嘿", "哼",
    "uh", "uhm", "um", "umm", "hmm", "hm", "mm", "mhm", "ah", "oh", "eh", "er", "erm", "huh",
    "え", "えー", "あ", "あー", "う", "うー", "うん", "うーん", "ん", "えっと", "ええと", "あの",
    "음", "어", "아", "응", "흠", "으",
)


def is_noise(original: str, seconds: float = 0.0) -> bool:
    """Ming writes something for every stretch it is sent, speech or not (it can't be asked for NONE,
    see hear_instruction): hold music, a ringback tone, a fan or typing came back as "嗯。", "嗯，嗯，嗯…"
    or "滴答" ×800. That is noise: fillers only, one short sound six or more times over, or more than
    anyone says in `seconds` (0: unknown). A short real answer ("对", "好的", "喂，能听到吗") stays.
    Same rules and lists as the Android and Windows ports."""
    text = _ANNOTATION.sub(" ", original.lower())
    if any(r in text for r in _NO_SPEECH):
        return True
    words, word = [], ""
    for c in text:
        if c.isalnum():
            word += c
        elif word:
            words.append(word)
            word = ""
    if word:
        words.append(word)
    if not words or all(_filler_word(w) for w in words):
        return True
    # Each CJK character is a unit, as a word is elsewhere.
    units = [u for w in words for u in (list(w) if any(_cjk(c) for c in w) else [w])]
    n = len(units)
    for p in range(1, 5):
        if n >= 6 * p and all(units[i] == units[i - p] for i in range(p, n)):
            return True
    return seconds > 0 and n > max(12.0, 12 * seconds)


def _filler_word(raw: str) -> bool:
    """Made of fillers only, a held sound shortened first: "嗯嗯嗯", "hmmmm"; "えーと" is not."""
    w = ""
    for c in raw:
        if len(w) < 2 or w[-1] != c or w[-2] != c:
            w += c
    ok = [True] + [False] * len(w)
    for i in range(1, len(w) + 1):
        ok[i] = any(len(f) <= i and ok[i - len(f)] and w[i - len(f):i] == f for f in _FILLERS)
    return ok[len(w)]


def _cjk(c: str) -> bool:
    o = ord(c)
    return (0x3040 <= o <= 0x30FF or 0x3400 <= o <= 0x4DBF or 0x4E00 <= o <= 0x9FFF
            or 0xF900 <= o <= 0xFAFF or 0xAC00 <= o <= 0xD7AF)


_OPENER = ("here is", "here's", "the subtitle", "this subtitle", "the text", "this text", "the original",
           "the user", "note", "(note", "i'm sorry", "i am sorry", "sorry", "it seems", "it appears", "this appears")
_ABOUT = ("translat", "subtitle", "garbled", "transcri", "asr", "speech recognition", "best-effort")
_ZH_ABOUT = ("字幕", "翻译")
_ZH_REMARK = ("请提供", "似乎", "看起来", "无法", "乱码", "没有附上", "您只发送")


def clean_translation(reply: str, target: str) -> str | None:
    """Ling sometimes comments on a garbled subtitle instead of translating it ("The subtitle appears
    to be…"). Remark lines go, a "Translation:" label is stripped, and what is left must be in the
    target's script; None lets the next provider try. Port of cleanTranslation."""
    answer = reply.split("</think>")[-1]
    kept = []
    for raw in answer.split("\n"):
        line = raw.strip()
        if not line:
            continue
        lower = line.lower()
        remark = ((lower.startswith(_OPENER) or line.endswith((":", "："))) and any(a in lower for a in _ABOUT)) or \
                 (any(a in line for a in _ZH_ABOUT) and any(r in line for r in _ZH_REMARK))
        if lower.startswith("translation:"):
            line = line[len("translation:"):].strip()
        elif remark:
            if kept:
                break
            continue
        if line:
            kept.append(line)
    output = " ".join(kept)
    for o, c in (('"', '"'), ("“", "”"), ("「", "」")):
        if len(output) >= 2 and output.startswith(o) and output.endswith(c) and o not in output[1:-1]:
            output = output[1:-1]
    output = output.strip()
    if not output:
        return None
    return output if in_script(output, target) else None

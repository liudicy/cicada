"""Paths, the debug log and languages."""
from __future__ import annotations

import os
import tempfile
import threading
import sys
from datetime import datetime


class Paths:
    """Where the app keeps its files, by the XDG rules: records in ~/.local/share/cicada, settings
    and the Ling key in ~/.config/cicada. Dev builds use "cicada-dev" so they never touch real
    records. Tests and the CLI point everything at one folder with CICADA_HOME."""
    dev = os.environ.get("CICADA_DEV") == "1"
    home_override: str | None = None

    @classmethod
    def _name(cls) -> str:
        return "cicada-dev" if cls.dev else "cicada"

    @classmethod
    def _home(cls) -> str | None:
        return cls.home_override or os.environ.get("CICADA_HOME") or None

    @classmethod
    def data(cls) -> str:
        h = cls._home()
        if h:
            return h
        base = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
        return os.path.join(base, cls._name())

    @classmethod
    def config(cls) -> str:
        h = cls._home()
        if h:
            return h
        base = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
        return os.path.join(base, cls._name())

    @classmethod
    def sessions(cls) -> str:
        return os.path.join(cls.data(), "Sessions")

    @classmethod
    def settings(cls) -> str:
        return os.path.join(cls.config(), "settings.json")

    @classmethod
    def key_file(cls) -> str:
        return os.path.join(cls.config(), "ling-api-key")

    log_override: str | None = None

    @classmethod
    def log(cls) -> str:
        """~/.local/state/cicada/debug.log (XDG state, private to the user), not a shared /tmp file."""
        if cls.log_override:
            return cls.log_override
        h = cls._home()
        if h:
            return os.path.join(h, "debug.log")
        base = os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")
        folder = os.path.join(base, cls._name())
        try:
            os.makedirs(folder, mode=0o700, exist_ok=True)
        except OSError:
            return os.path.join(tempfile.gettempdir(), cls._name() + "-debug.log")
        return os.path.join(folder, "debug.log")


class Log:
    """The debug log: timings and states, never meeting text or the key."""
    _gate = threading.Lock()
    echo = False

    @classmethod
    def d(cls, message: str) -> None:
        line = datetime.now().strftime("%H:%M:%S.%f")[:-3] + " " + message
        with cls._gate:
            try:
                with open(Paths.log(), "a", encoding="utf-8") as f:
                    f.write(line + "\n")
            except OSError:
                pass
            if cls.echo:
                print(line, file=sys.stderr)


# The languages the Mac app offers (Languages.swift), as translation codes.
SOURCES = [("English", "en"), ("日本語", "ja"), ("中文", "zh-CN"), ("한국어", "ko"),
           ("Español", "es"), ("Français", "fr"), ("Deutsch", "de"), ("Português", "pt")]
TARGETS = [("简体中文", "zh-CN"), ("繁體中文", "zh-TW"), ("English", "en"), ("日本語", "ja"),
           ("한국어", "ko"), ("Español", "es"), ("Français", "fr"), ("Deutsch", "de"), ("Português", "pt")]

_ENGLISH = {"zh-CN": "Simplified Chinese", "zh-TW": "Traditional Chinese", "zh": "Chinese", "en": "English",
            "ja": "Japanese", "ko": "Korean", "es": "Spanish", "fr": "French", "de": "German", "pt": "Portuguese",
            "it": "Italian", "ru": "Russian", "ar": "Arabic", "hi": "Hindi", "th": "Thai", "vi": "Vietnamese",
            "id": "Indonesian", "ms": "Malay", "tr": "Turkish", "nl": "Dutch", "pl": "Polish", "sv": "Swedish",
            "uk": "Ukrainian", "he": "Hebrew", "el": "Greek", "cs": "Czech", "da": "Danish", "fi": "Finnish",
            "no": "Norwegian", "hu": "Hungarian", "ro": "Romanian", "yue": "Cantonese"}


def english_name(code: str) -> str:
    """"Simplified Chinese", "Japanese": the names prompts use."""
    return _ENGLISH.get(code) or _ENGLISH.get(code.split("-")[0].lower()) or code


def from_system(tag: str) -> str:
    """A system UI language ("zh_CN.UTF-8", "zh-Hant-HK", "en_US") as a translation code."""
    parts = tag.split(".")[0].split("@")[0].replace("_", "-").split("-")
    if parts[0] != "zh":
        return parts[0] or "en"
    return "zh-TW" if any(p in ("Hant", "TW", "HK", "MO") for p in parts) else "zh-CN"


def system_languages() -> list:
    """The desktop's languages, most preferred first: LANGUAGE is a list ("en_US:zh_CN"), the
    locale variables add one each. What the Mac reads as Locale.preferredLanguages."""
    out = []
    for var in ("LANGUAGE", "LC_ALL", "LC_MESSAGES", "LANG"):
        for v in (os.environ.get(var) or "").split(":"):
            if v and v not in ("C", "POSIX", "C.UTF-8") and v not in out:
                out.append(v)
    return out or ["en_US"]


def my_language(prefs: list) -> str:
    """The reader's own language under "follow system" (the Mac's myLanguage): Chinese when the
    system list has it, otherwise the first system language."""
    return from_system(next((p for p in prefs if p.startswith("zh")), prefs[0] if prefs else "zh_CN"))


def follow_system_target(source: str | None, prefs: list) -> str:
    """What "follow system" translates into (the Mac's followSystemTarget): my language, unless that
    is what they speak; then the next system language, or between Chinese and English when the
    system has only one."""
    mine = my_language(prefs)
    if source is None or source != mine:
        return mine
    return next((c for c in map(from_system, prefs) if c != mine), "en" if mine.startswith("zh") else "zh-CN")


def system_language() -> str:
    """The desktop's language, as POSIX locale variables give it."""
    for var in ("LANGUAGE", "LC_ALL", "LC_MESSAGES", "LANG"):
        v = os.environ.get(var)
        if v and v not in ("C", "POSIX", "C.UTF-8"):
            return v.split(":")[0]
    return "en_US"


def normalize(reported: str | None, fallback: str) -> str:
    """Normalizes what Ming says the language is ("zh", "zh-Hans", "cmn") to a source code."""
    if not reported or not reported.strip():
        return fallback
    r = reported.strip().strip('.`"')
    head = r.replace("_", "-").split("-")[0].lower()
    if head in ("zh", "cmn", "yue"):
        return "zh-TW" if "tw" in r.lower() or "hant" in r.lower() else "zh-CN"
    return head if len(head) in (2, 3) else fallback


def _is_cjk(c: str) -> bool:
    cp = ord(c)
    return 0x3040 <= cp <= 0x9FFF or 0xAC00 <= cp <= 0xD7AF


def _count(text: str):
    letters = cjk = 0
    for c in text:
        if c.isalpha():
            letters += 1
            if _is_cjk(c):
                cjk += 1
    return letters, cjk


def is_cjk_language(code: str) -> bool:
    return code.startswith(("zh", "ja", "ko"))


def in_script(text: str, target: str) -> bool:
    """Whether text is in the target's script: Chinese, Japanese and Korean targets need some CJK,
    others must not be mostly CJK (TranslationService.cleanTranslation's check)."""
    letters, cjk = _count(text)
    if letters == 0:
        return True
    return cjk > 0 if is_cjk_language(target) else cjk * 2 <= letters


def written_in(text: str, english_language: str) -> bool:
    """Notes' check: CJK languages need a fair share (names and numbers stay Latin)."""
    letters, cjk = _count(text)
    if letters == 0:
        return True
    wants = any(w in english_language for w in ("Chinese", "Japanese", "Korean"))
    return cjk * 5 >= letters if wants else cjk * 2 < letters


def clock(t: float) -> str:
    s = int(max(0.0, t))
    return "%d:%02d:%02d" % (s // 3600, s // 60 % 60, s % 60) if s >= 3600 else "%02d:%02d" % (s // 60, s % 60)

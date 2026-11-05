"""Ming's voices for what the room hears (Voices.swift › VoiceCatalog.ming): hand-picked natural
ones per language; for languages Ming has no native voice for, Emma and George speak them with
`language_id`. Linux has no system voice worth sending into a meeting, so only these."""
from __future__ import annotations


def key(code: str) -> str:
    """"zh" for zh-CN / zh-TW, "en" for en-US."""
    return (code or "en").split("-")[0].lower() or "en"


def ming_language(code: str) -> str | None:
    k = key(code)
    return k if k in ("ja", "ko", "de", "fr", "es") else None


# (voice, name, tags as Chinese keys)
_CATALOG = {
    "en": [("US_Emma", "Emma", ["女", "美式", "自然对话"]), ("UK_George", "George", ["男", "英式", "稳重"]),
           ("UK_Charlotte", "Charlotte", ["女", "英式", "平稳"])],
    "zh": [("灵小雅", "小雅", ["女", "清亮", "播报"]), ("灵小棠", "小棠", ["女", "温和", "沉稳"]),
           ("灵小锋", "小锋", ["男", "温暖", "亲切"]), ("灵卓然", "卓然", ["男", "沉着", "清楚"])],
}
_OTHER = [("US_Emma", "Emma", ["女"]), ("UK_George", "George", ["男"])]

# The languages the room can hear: those Ming speaks.
ROOM_LANGUAGES = ["en", "zh-CN", "zh-TW", "ja", "ko", "es", "fr", "de"]


def voices(code: str) -> list:
    k = key(code)
    if k in _CATALOG:
        return _CATALOG[k]
    return _OTHER if k in ("ja", "ko", "de", "fr", "es") else []


def default_voice(code: str) -> str | None:
    v = voices(code)
    return v[0][0] if v else None

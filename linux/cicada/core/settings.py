"""The app's settings, in settings.json beside the key (never the key itself: it has its own file)."""
from __future__ import annotations

import os

from . import jsonfmt
from .support import Log, Paths, follow_system_target, my_language, system_language, system_languages

DEFAULT_MODEL = "Ling-3.1-flash"


class AppSettings:
    FIELDS = {
        "target": "system",          # what subtitles translate into; "system" follows the desktop language
        "notesLanguage": "mine",     # 纪要语言, the Mac's: "mine" (my language) or "source" (the meeting's own)
        "model": DEFAULT_MODEL,       # Ling's text model (the others' are in aiModels)
        # AI 服务 (Settings.swift's keys): the service, and per service the models chosen over its
        # recommended ones. aiHearModels is the port's own: what hears the audio (Ming on Ling).
        "aiProvider": "ling",
        "aiModels": {},
        "aiHearModels": {},
        "aiVoiceModels": {},
        "aiCustomBase": "",
        "aiCustomVoiceBase": "",
        "aiCustomVoice": "",
        # The custom service's hear model at an address of its own (the port's, like the Mac's
        # aiCustomHearBase); empty: the same address as the text model.
        "aiCustomHearBase": "",
        # The custom service's notes (the Mac's keys): 另一个服务, at its own address (empty: the same
        # one) with its own key in the `custom-notes` key file. Off keeps the address. The notes
        # model is aiModels["custom.notes"] (empty: the translation model).
        "aiCustomNotesOwn": False,
        "aiCustomNotesBase": "",
        # 语音和文字只发给你的服务 (the Mac's aiCustomOnly): with the custom service, Google Translate is
        # never asked. Kept when another service is picked, but only acts on the custom one.
        "aiCustomOnly": False,
        "view": "notes",             # "notes" (the notes window, default) or "subtitles" (the subtitle bar)
        "showInCapture": False,      # 共享屏幕时让对方看到 (Linux can't hide it; see NotesWindow)
        "onboarded": False,
        # The setup checklist (会议记录 › 还差几步): the onboarding heard the computer's sound / played the sample.
        "heardSystemAudio": False,
        "sampleSeen": False,
        "speakLater": False,         # 还差几步 › 同声传译 › 以后再说
        "trayHintShown": False,      # 知了还在顶栏, said once after the records window is first closed
        "showInDock": True,          # 在 Dock 中显示 (the Mac's): in the dock for as long as 知了 runs
        "uiLanguage": "system",      # "system", "zh-Hans", "en", "ja" or "ko"
        # 同声传译: what I say is interpreted and spoken into 知了 麦克风 (the Mac's speakEnabled etc.).
        # 保存会议录音 (the Mac's recordAudio): system.m4a beside session.json, when GStreamer has an AAC encoder.
        "recordAudio": True,
        # 存到文件夹 (the Mac's keys): settled meetings also written as Markdown into exportFolder (a
        # path; "" until one is chosen). See folder_export.py.
        "exportOn": False,
        "exportFolder": "",
        # 会中改正听错的词 (the Mac's keys): finished sentences carry the word list to the AI service, which
        # points out misheard words (correction.py); askNames: a new name is asked about once.
        "fixMisheard": True,
        "askNames": True,
        "speakerVoices": True,       # 说话人识别: tell the other side's voices apart (说话人 1、2…), as on the Mac
        "speakEnabled": False,
        "speakFrom": "system",       # the language I speak; "system" = the subtitles' language
        "speakTo": "room",           # what the room hears; "room" = the language they have been speaking
        "speakVoices": {},           # Ming voice per language key ("en": "US_Emma")
        "speakHeadphones": False,    # 戴着耳机: skip the echo guard, talking over them is fine
        # 打开麦克风 (the Mac's listenSource): "both" while the mic is on (people online and in the
        # room, each heard on its own), else "system"; never kept for the next launch. roomMic: the
        # room's microphone, "" = 自动.
        "listenSource": "system",
        "roomMic": "",
        # 结束会议 (meeting_end.py), the Mac's keys: end when the meeting app hangs up; when nobody
        # speaks, "prompt" (count down, then end), "end" or "off", after silenceMinutes.
        "endWithApp": True,
        "silenceEnd": "prompt",
        "silenceMinutes": 10,
    }

    SOURCES = ("system", "room", "both")

    def __init__(self, **kw):
        for k, v in self.FIELDS.items():
            v = kw.get(k, v)
            setattr(self, k, dict(v) if isinstance(v, dict) else v)

    @property
    def target_code(self) -> str:
        """My language: the translate-to choice, or under "follow system" the Mac's myLanguage."""
        return my_language(system_languages()) if self.target == "system" else self.target

    def resolved_target(self, source: str | None) -> str:
        """What lines in `source` translate into: under "follow system", the next system language when
        they speak mine (the Mac's resolvedTarget)."""
        return follow_system_target(source, system_languages()) if self.target == "system" else self.target

    def ai_config(self):
        """The AI service in use, its address and models (what LingClient calls with)."""
        from .providers import config_from
        return config_from(self)

    def notes_code(self, choice: str | None = None, meeting: str | None = None) -> str:
        """The notes' language for a 纪要语言 choice (this one's when None): the meeting's own language
        (`meeting`, the one it was heard in) for "source", else mine (the Mac's notesLanguageCode)."""
        return meeting if (choice or self.notesLanguage) == "source" and meeting else self.target_code

    @property
    def google_off(self) -> bool:
        """语音和文字只发给你的服务 in effect: on, and the custom service in use."""
        return self.aiProvider == "custom" and self.aiCustomOnly

    @property
    def hears_room(self) -> bool:
        """The room microphone is open: 会议室 or 电脑和会议室."""
        return self.listenSource != "system"

    @property
    def speak_from_code(self) -> str:
        return self.target_code if self.speakFrom == "system" else self.speakFrom

    @property
    def ui_code(self) -> str:
        return system_language() if self.uiLanguage == "system" else self.uiLanguage

    def to_json(self) -> dict:
        return {k: getattr(self, k) for k in self.FIELDS}

    def save(self) -> None:
        try:
            os.makedirs(Paths.config(), exist_ok=True)
            with open(Paths.settings(), "w", encoding="utf-8") as f:
                f.write(jsonfmt.write(self.to_json()))
        except OSError as e:
            Log.d("settings: save failed %s" % type(e).__name__)

    @staticmethod
    def load() -> "AppSettings":
        try:
            if os.path.isfile(Paths.settings()):
                with open(Paths.settings(), encoding="utf-8") as f:
                    o = jsonfmt.parse_object(f.read())
                if o is not None:
                    kw = {k: o[k] for k, d in AppSettings.FIELDS.items() if k in o and type(o[k]) is type(d)}
                    # 纪要语言 was "system" or a language code before it took the Mac's two choices.
                    if kw.get("notesLanguage") not in (None, "mine", "source"):
                        kw["notesLanguage"] = "mine"
                    # Every launch starts with the microphone off.
                    kw.pop("listenSource", None)
                    return AppSettings(**kw)
        except OSError as e:
            Log.d("settings: unreadable, defaults used (%s)" % type(e).__name__)
        return AppSettings()

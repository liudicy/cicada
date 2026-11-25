"""The AI services the port can use (AIProviders.swift, plus what hears audio). Ling is the
reference: Ming hears each stretch of audio and answers language, original and translation in one
call, and only Ling clones the user's voice. The others are OpenAI-compatible and hear through an
audio-input chat model with the same prompt (tools/audio-probe measured them against Ming, 2026-11:
about as accurate, 0.5–2 s slower). OpenAI itself is left out: a port needs a model that hears,
and its audio models are untested.

Recommended models come first in every menu and are the defaults. For hearing, the first is the one
that wrote nothing for a clip without speech: a made-up line ends up in the notes and, when
interpreting, in the room."""
from __future__ import annotations

import base64
import re
import urllib.parse
from dataclasses import dataclass, field, replace

from .jsonfmt import arr, obj, string


@dataclass(frozen=True)
class Model:
    id: str
    note: str = ""  # why it is recommended: a Chinese UI key, localized where shown


@dataclass(frozen=True)
class CloudVoice:
    id: str
    gender: str  # "女" / "男", a Chinese UI key


@dataclass(frozen=True)
class Provider:
    id: str
    name: str
    base: str | None            # None for "custom": the user's address
    site: str | None            # where to create a key
    text_models: tuple = ()
    hear_models: tuple = ()
    voice_models: tuple = ()    # empty: this service can't speak into the room here
    voices: tuple = ()          # of `voice_models` (Gemini TTS: the same names in every language)
    clones: bool = False
    spacing: float = 0.1        # Ling allows ~2 request starts a second; the aggregators far more

    @property
    def has_voices(self) -> bool:
        return bool(self.voice_models)


GEMINI_VOICES = (CloudVoice("Kore", "女"), CloudVoice("Aoede", "女"), CloudVoice("Charon", "男"), CloudVoice("Puck", "男"))

LING = Provider(
    "ling", "Ling", "https://api.ant-ling.com/v1/", "https://chat.ant-ling.com/platform/api",
    text_models=(Model("Ling-3.1-flash", "更准"), Model("Ling-3.0-flash", "更快、更省")),
    hear_models=(Model("Ming-3.0-audio-flash"),),
    voice_models=(Model("Ming-3.0-tts-0.5B"),), clones=True, spacing=0.6)

OPENROUTER = Provider(
    "openrouter", "OpenRouter", "https://openrouter.ai/api/v1/", "https://openrouter.ai/settings/keys",
    text_models=(Model("inclusionai/ling-3.1-flash", "和 Ling 同款"), Model("qwen/qwen3.8-flash", "中文好")),
    hear_models=(Model("qwen/qwen3.8-omni-flash", "没人说话时不乱写"), Model("google/gemini-3.1-flash-lite", "最快，偶尔把杂音写成字")),
    voice_models=(Model("google/gemini-3.8-flash-tts", "效果和价格最均衡"), Model("google/gemini-3.8-flash-lite-tts", "更省")),
    voices=GEMINI_VOICES)

ZENMUX = Provider(
    "zenmux", "ZenMux", "https://zenmux.ai/api/v1/", "https://zenmux.ai/settings/keys",
    text_models=(Model("inclusionai/ling-3.0-flash", "和 Ling 同款"), Model("qwen/qwen3.8-flash", "中文好")),
    hear_models=(Model("qwen/qwen3.8-omni-flash", "没人说话时不乱写"), Model("bytedance/doubao-seed-2.0-mini", "更快"),
                 Model("google/gemini-3.1-flash-lite", "最快，偶尔把杂音写成字")),
    voice_models=(Model("google/gemini-3.8-flash-tts", "效果和价格最均衡"), Model("google/gemini-3.8-flash-lite-tts", "更省")),
    voices=GEMINI_VOICES)

# Any OpenAI-compatible address (a company gateway, Ollama…). Its hear model must take audio in;
# voices only when the user names a speech model.
CUSTOM = Provider("custom", "其他（兼容 OpenAI）", None, None)

ALL = (LING, OPENROUTER, ZENMUX, CUSTOM)


def named(raw: str) -> Provider:
    return next((p for p in ALL if p.id == raw), LING)


def _host(host_or_url: str) -> str:
    s = (host_or_url or "").strip()
    if "://" not in s and s.count(":") > 1 and "/" not in s:
        return s.strip("[]").lower()  # a bare IPv6 address
    try:
        host = urllib.parse.urlsplit(s if "://" in s else "http://" + s).hostname
    except ValueError:
        host = None
    return (host or s).strip("[]").lower()


def is_local(host_or_url: str) -> bool:
    """This computer."""
    return _host(host_or_url) in ("localhost", "127.0.0.1", "::1")


def is_nearby(host_or_url: str) -> bool:
    """This computer or the local network (AIProvider.isNearby): plain http is allowed and a key
    isn't needed. Private IPv4 (10/8, 172.16/12, 192.168/16), link-local, Tailscale's 100.64/10,
    IPv6 unique and link-local addresses, and `.local` names."""
    h = _host(host_or_url)
    if is_local(h) or h.endswith(".local"):
        return True
    parts = h.split(".")
    if len(parts) == 4 and all(p.isdigit() for p in parts):
        a, b = (int(p) for p in parts[:2])
        if not all(0 <= int(p) <= 255 for p in parts):
            return False
        return a == 10 or (a, b) in ((192, 168), (169, 254)) or (a == 172 and 16 <= b <= 31) or (a == 100 and 64 <= b <= 127)
    if ":" in h:
        return h.startswith(("fc", "fd", "fe80"))
    return False


def custom_base(raw: str) -> str | None:
    """The address as typed, normalized: https, or http only on this computer or the local network
    (Ollama, LM Studio, a GPU box at home or work, a Tailscale address); ends in "/"."""
    s = (raw or "").strip()
    if not s:
        return None
    if "://" not in s:
        s = ("http://" if is_nearby(s) else "https://") + s
    if not s.endswith("/"):
        s += "/"
    try:
        parts = urllib.parse.urlsplit(s)
        host = parts.hostname
    except ValueError:
        return None
    if not host:
        return None
    if parts.scheme == "https":
        return s
    return s if parts.scheme == "http" and is_nearby(host) else None


def thought(root: dict) -> bool:
    """The model thought before answering, which makes every translation slow (AIConfig.thought):
    a `reasoning_content` (or `reasoning`) field, reasoning tokens in the usage, or a `<think>`
    block in the answer."""
    choices = arr((root or {}).get("choices"))
    message = obj((obj(choices[0]) or {}).get("message")) if choices else None
    message = message or {}
    for k in ("reasoning_content", "reasoning"):
        r = message.get(k)
        if isinstance(r, str) and r.strip():
            return True
    details = obj((obj((root or {}).get("usage")) or {}).get("completion_tokens_details")) or {}
    n = details.get("reasoning_tokens")
    if isinstance(n, (int, float)) and not isinstance(n, bool) and n > 0:
        return True
    content = message.get("content")
    return isinstance(content, str) and "<think>" in content


@dataclass
class AIConfig:
    """What one call needs to know about the service in use, resolved from settings each time."""
    provider: Provider
    base: str | None            # None: a custom service without a valid address yet
    text_model: str
    hear_model: str
    voice_model: str | None = None   # None: no voices with this service
    voice_base: str | None = None
    custom_voice: str | None = None
    extra: dict = field(default_factory=dict)
    # Where the hear model is asked: a custom service's own hear address (the text model and an
    # audio model often run as separate servers). None: the text address; "" (only from
    # config_from): an address typed that isn't valid.
    hear_base: str | None = None
    # A custom service's notes (实时纪要, 说话人): another model, and with 另一个服务 another server
    # with its own key. None: the same as translation.
    notes_model: str | None = None
    notes_base: str | None = None
    # 另一个服务 is picked: notes use their own key file when there is one.
    notes_own_service: bool = False
    # 另一个服务 with an address that can't be used (http to the internet): notes fail the check.
    notes_bad_address: bool = False

    @property
    def notes_apart(self) -> bool:
        """Notes go somewhere translation doesn't: they get their own check, result and start gate."""
        return self.provider.id == "custom" and (self.notes_model is not None or self.notes_base is not None
                                                 or self.notes_own_service)

    @property
    def for_notes(self) -> "AIConfig":
        """What a notes call is sent with: notes' model at notes' address, the rest as translation."""
        if not self.notes_apart:
            return self
        return replace(self, text_model=self.notes_model or self.text_model, base=self.notes_base or self.base)

    @property
    def hear_url(self) -> str | None:
        """The address every hear call (and the check's hear step) goes to."""
        return self.base if self.hear_base is None else (self.hear_base or None)

    @property
    def own_hear_address(self) -> bool:
        """The hear model is at an address of its own, not the text model's."""
        return self.hear_base is not None and self.hear_base != self.base

    @property
    def is_ling(self) -> bool:
        return self.provider.id == "ling"

    @property
    def has_voices(self) -> bool:
        return self.voice_model is not None and self.voice_base is not None

    @property
    def voices(self) -> tuple:
        """The voices the room can pick from with this service (Ling's are in voices.py)."""
        if not self.has_voices or self.is_ling:
            return ()
        if self.provider.id == "custom":
            return (CloudVoice(self.custom_voice, ""),) if self.custom_voice else ()
        return self.provider.voices

    def shape(self, body: dict, max_tokens: int, template_kwargs: bool = True) -> None:
        """Each service turns thinking off its own way (AIConfig.shape on the Mac). A custom service
        gets `chat_template_kwargs` (vLLM, SGLang and llama.cpp pass it to the chat template, which
        is how Qwen3 turns thinking off); `template_kwargs` False leaves it out for a server that
        refused it."""
        body["max_tokens"] = max_tokens
        body["temperature"] = 0.2
        if self.is_ling:
            body["thinking"] = {"type": "disabled"}
        elif self.provider.id in ("openrouter", "zenmux"):
            body["reasoning"] = {"enabled": False}
        elif self.provider.id == "custom" and template_kwargs:
            body["chat_template_kwargs"] = {"enable_thinking": False}

    def audio_part(self, wav: bytes, model: str) -> dict:
        """One WAV in a user message: Ming takes a data URL; the others the standard `input_audio`,
        except that Qwen's omni models want the data URL inside it (DashScope's form)."""
        b64 = base64.b64encode(wav).decode()
        if self.is_ling:
            return {"type": "audio_url", "audio_url": {"url": "data:audio/wav;base64," + b64}}
        if model.split("/")[-1].startswith("qwen"):
            b64 = "data:audio/wav;base64," + b64
        return {"type": "input_audio", "input_audio": {"data": b64, "format": "wav"}}


def config_from(settings) -> AIConfig:
    """The service, its address and models from the app's settings (Settings.swift › aiConfig)."""
    p = named(settings.aiProvider)
    models, hears, voices = settings.aiModels, settings.aiHearModels, settings.aiVoiceModels
    if p.id == "ling":
        text = settings.model if settings.model in [m.id for m in p.text_models] else p.text_models[0].id
        return AIConfig(p, p.base, text, p.hear_models[0].id, p.voice_models[0].id, p.base)
    if p.id == "custom":
        base = custom_base(settings.aiCustomBase)
        voice = (voices.get("custom") or "").strip()
        voice_base = custom_base(settings.aiCustomVoiceBase) if settings.aiCustomVoiceBase.strip() else base
        name = settings.aiCustomVoice.strip()
        # The hear model's own address (empty: the text model's); "" marks one typed that isn't valid.
        typed = (getattr(settings, "aiCustomHearBase", "") or "").strip()
        hear_base = (custom_base(typed) or "") if typed else None
        # Notes (Settings.swift › aiConfig): their model (empty or the translation one: none of their
        # own), and with 另一个服务 their address (empty or the same: translation's). Off keeps the
        # address typed, so switching back and forth loses nothing.
        text = (models.get("custom") or "").strip()
        notes_model = (models.get("custom.notes") or "").strip()
        own = bool(getattr(settings, "aiCustomNotesOwn", False))
        notes_typed = (getattr(settings, "aiCustomNotesBase", "") or "").strip() if own else ""
        notes_base = custom_base(notes_typed) if notes_typed else None
        return AIConfig(p, base, text, (hears.get("custom") or "").strip(),
                        voice or None, voice_base if voice else None, name or None, hear_base=hear_base,
                        notes_model=None if not notes_model or notes_model == text else notes_model,
                        notes_base=None if notes_base == base else notes_base, notes_own_service=own,
                        notes_bad_address=bool(notes_typed) and notes_base is None)
    return AIConfig(p, p.base, models.get(p.id) or p.text_models[0].id, hears.get(p.id) or p.hear_models[0].id,
                    voices.get(p.id) or p.voice_models[0].id, p.base)


_NOT_CHAT = re.compile(r"(embed|whisper|tts|asr|transcribe|dall-e|image|moderation|realtime|sora|search|video|seedance|wan\d)")


def catalog(data: str | dict, recommended: list, hears: bool) -> list:
    """Model ids from a `/models` reply, recommended ones first: those that answer in text, and for
    `hears` only those that take audio in. ZenMux lists modalities at the top level, OpenRouter under
    `architecture`; a service that says nothing keeps everything but obvious non-chat names."""
    from .jsonfmt import parse_object
    root = parse_object(data) if isinstance(data, str) else data
    ids = []
    for m in arr((root or {}).get("data")):
        m = obj(m) or {}
        mid = string(m.get("id"))
        if not mid or mid.endswith(":batch"):
            continue
        a = obj(m.get("architecture")) or {}
        ins = arr(m.get("input_modalities") or a.get("input_modalities"))
        outs = arr(m.get("output_modalities") or a.get("output_modalities"))
        if outs and "text" not in outs:
            continue
        if ins and ins == ["audio"]:
            continue  # speech-to-text only: no prompt, no translation
        if hears and "audio" not in ins:
            continue
        if not outs and _NOT_CHAT.search(mid):
            continue
        ids.append(mid)
    rest = sorted(i for i in ids if i not in recommended)
    return list(recommended) + rest


def hosts(c: AIConfig, notes: bool = True) -> list:
    """Every host a custom service's uses go to, in order, once each: text, notes (when at their own
    address; `notes` False leaves them out), hear, and the voice if set up (AISettings.swift ›
    customHosts, keyHosts)."""
    urls = [c.base] + ([c.for_notes.base] if notes and c.notes_apart else []) + [c.hear_url] \
        + ([c.voice_base] if c.has_voices else [])
    out = []
    for u in urls:
        h = urllib.parse.urlsplit(u).hostname if u else None
        if h and h not in out:
            out.append(h)
    return out


def only_host(c: AIConfig) -> str | None:
    """Where a custom service's audio and text go, when every use shares one host; None when they
    differ."""
    h = hosts(c)
    return h[0] if len(h) == 1 else None

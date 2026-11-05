"""Ling (ant-ling.com), OpenAI-compatible, and the user's key."""
from __future__ import annotations

import base64
import os
import random
import socket
import threading
import time
import urllib.error
import urllib.request

from . import jsonfmt
from .jsonfmt import arr, obj, string
from .settings import DEFAULT_MODEL
from .support import Log, Paths


class AIKey:
    """The user's Ling key, only ever in the `ling-api-key` file, mode 0600, in ~/.config/cicada (as
    on the Mac): never in settings, logs or exports."""

    def __init__(self, path: str | None = None):
        self._path = path
        self._cached = None
        self._loaded = False
        self._lock = threading.Lock()

    @property
    def path(self) -> str:
        return self._path or Paths.key_file()

    def read(self) -> str | None:
        with self._lock:
            if self._loaded:
                return self._cached
            self._loaded = True
            try:
                if os.path.isfile(self.path):
                    with open(self.path, encoding="utf-8") as f:
                        self._cached = f.read().strip() or None
                else:
                    self._cached = None
            except OSError as e:
                Log.d("ai key: read failed %s" % type(e).__name__)
                self._cached = None
            return self._cached

    def save(self, key: str) -> bool:
        k = key.strip()
        with self._lock:
            try:
                os.makedirs(os.path.dirname(self.path), mode=0o700, exist_ok=True)
                # Created 0600 from the start: the key is never readable by others, even briefly.
                fd = os.open(self.path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
                with os.fdopen(fd, "w", encoding="utf-8") as f:
                    f.write(k)
                os.chmod(self.path, 0o600)
                self._cached = k
                self._loaded = True
                return True
            except OSError as e:
                Log.d("ai key: save failed %s" % type(e).__name__)
                return False

    def remove(self) -> None:
        with self._lock:
            try:
                os.remove(self.path)
            except OSError:
                pass
            self._cached = None
            self._loaded = True

    def reload(self) -> None:
        with self._lock:
            self._loaded = False

    @staticmethod
    def masked(key: str) -> str:
        """"sk-••••••••••••3f9a" for display."""
        return "sk-…" if len(key) <= 8 else key[:3] + "•" * 12 + key[-4:]


# Priorities, most urgent first.
SPEAK, TRANSLATE, NOTES = 0, 1, 2
PRIORITY_NAMES = {SPEAK: "speak", TRANSLATE: "translate", NOTES: "notes"}

# Key states.
NONE, UNCHECKED, CHECKING, OK, INVALID, UNREACHABLE = "none", "unchecked", "checking", "ok", "invalid", "unreachable"


class LingError(Exception):
    NO_KEY, INVALID_KEY, RATE_LIMITED, HIJACKED, TIMEOUT, HTTP, NETWORK, PARSE = (
        "NoKey", "InvalidKey", "RateLimited", "Hijacked", "Timeout", "Http", "Network", "Parse")

    def __init__(self, kind: str, status: int = 0):
        super().__init__("http%d" % status if kind == self.HTTP else kind)
        self.kind = kind
        self.status = status


class Response:
    def __init__(self, status: int, body: str):
        self.status = status
        self.body = body


class StreamResponse:
    def __init__(self, status: int, lines):
        self.status = status
        self.lines = lines  # an iterator of text lines (SSE)


class UrlTransport:
    """How requests leave the app: urllib (which honours http_proxy / https_proxy), or a fake in tests.
    Raises TimeoutError on a timeout and OSError when the network fails."""

    @staticmethod
    def send(url: str, method: str, body: str | None, headers: dict, timeout: float) -> Response:
        req = urllib.request.Request(url, data=body.encode() if body is not None else None, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return Response(r.status, r.read().decode("utf-8", "replace"))
        except urllib.error.HTTPError as e:
            return Response(e.code, e.read().decode("utf-8", "replace") if e.fp else "")
        except socket.timeout as e:
            raise TimeoutError() from e
        except urllib.error.URLError as e:
            if isinstance(e.reason, socket.timeout):
                raise TimeoutError() from e
            raise OSError(str(e.reason)) from e


    @staticmethod
    def stream(url: str, body: str, headers: dict, timeout: float) -> StreamResponse:
        """A POST whose reply is read line by line as it arrives (Ming's server-sent speech)."""
        req = urllib.request.Request(url, data=body.encode(), method="POST", headers=headers)
        try:
            r = urllib.request.urlopen(req, timeout=timeout)
        except urllib.error.HTTPError as e:
            return StreamResponse(e.code, iter(()))
        except socket.timeout as e:
            raise TimeoutError() from e
        except urllib.error.URLError as e:
            raise OSError(str(e.reason)) from e

        def lines():
            with r:
                for raw in r:
                    yield raw.decode("utf-8", "replace").rstrip("\r\n")
        return StreamResponse(r.status, lines())


BASE = "https://api.ant-ling.com/v1/"
TTS_MODEL = "Ming-3.0-tts-0.5B"
TTS_RATE = 24000
AUDIO_MODEL = "Ming-3.0-audio-flash"
# Search essays (Ling.swift), and the canned refusal some audio prompts get.
HIJACK_PREFIXES = ("根据现有检索证据", "暂未找到足够可靠的信息", "根据检索", "作为一个人工智能语言模型")


class LingClient:
    """One instance for the app: the account allows about 2 requests per second across every model,
    so request *starts* go through one gate (≥ 0.6 s apart, overlapping is fine) in priority order.
    Two gateway quirks shape every call (see Ling.swift): thinking is always disabled, and the
    content goes in the system message with a fixed user instruction, because a question-like user
    message gets a search essay back; such replies are dropped. Calls block: run them off the UI thread."""
    spacing = 0.6

    def __init__(self, key: AIKey, transport=UrlTransport):
        self.key = key
        self.transport = transport
        self.model = DEFAULT_MODEL
        self.key_state = NONE if key.read() is None else UNCHECKED
        self.rate_limited_at = None
        self._listeners = []
        self._gate = threading.Condition()
        self._waiting = []
        self._last_start = 0.0
        self._seq = 0

    def on_change(self, listener) -> None:
        self._listeners.append(listener)

    def _changed(self) -> None:
        for l in list(self._listeners):
            l()

    @property
    def has_key(self) -> bool:
        return self.key.read() is not None

    @property
    def usable(self) -> bool:
        return self.has_key and self.key_state != INVALID

    def key_changed(self) -> None:
        self.key_state = NONE if self.key.read() is None else UNCHECKED
        self._changed()

    def check(self) -> str:
        """A tiny request that says whether the key works."""
        self.key_state = CHECKING
        self._changed()
        try:
            self.chat("Reply with OK.", "Reply.", SPEAK, max_tokens=5, timeout=10.0, model="Ling-3.0-tiny")
            state = OK
        except LingError as e:
            state = {LingError.NO_KEY: NONE, LingError.INVALID_KEY: INVALID,
                     LingError.RATE_LIMITED: OK}.get(e.kind, UNREACHABLE)  # a busy key is still a good key
        except Exception:  # noqa: BLE001
            state = UNREACHABLE
        self.key_state = state
        self._changed()
        return state

    def chat(self, content: str, instruction: str, priority: int, json: bool = False, max_tokens: int = 1024,
             timeout: float = 30.0, model: str | None = None, audio: bytes | None = None) -> str:
        """One chat completion. `content` goes in the system message, `instruction` is the fixed user
        message, `audio` (a WAV) goes before it for Ming. Notes retry 429s with backoff; heard audio
        gets one retry (a lost reply loses the words); the rest fail fast so the caller can fall back."""
        k = self.key.read()
        if k is None:
            raise LingError(LingError.NO_KEY)
        if self.key_state == INVALID:
            raise LingError(LingError.INVALID_KEY)
        user = instruction if audio is None else [
            {"type": "audio_url", "audio_url": {"url": "data:audio/wav;base64," + base64.b64encode(audio).decode()}},
            {"type": "text", "text": instruction},
        ]
        body = {"model": model or self.model,
                "messages": [{"role": "system", "content": content}, {"role": "user", "content": user}],
                "max_tokens": max_tokens, "temperature": 0.2, "thinking": {"type": "disabled"}, "stream": False}
        if json:
            body["response_format"] = {"type": "json_object"}
        payload = jsonfmt.write(body, pretty=False)
        attempts = 4 if priority == NOTES else 2 if audio is not None else 1
        delay = 1.0
        attempt = 1
        name = PRIORITY_NAMES[priority]
        while True:
            self._acquire(priority)
            started = time.monotonic()
            try:
                root = self._post("chat/completions", payload, k, timeout)
                choices = arr(root.get("choices"))
                choice = obj(choices[0]) if choices else None
                text = string((obj(choice.get("message")) or {}).get("content")) if choice else None
                if text is None:
                    raise LingError(LingError.PARSE)
                finish = string(choice.get("finish_reason"))
                trimmed = text.strip()
                if finish is None or trimmed.startswith(HIJACK_PREFIXES):
                    Log.d("ling: %s search-style reply dropped" % name)
                    raise LingError(LingError.HIJACKED)
                usage = obj(root.get("usage")) or {}
                Log.d("ling: %s ok %d ms tokens=%s/%s" % (name, (time.monotonic() - started) * 1000,
                                                          usage.get("prompt_tokens"), usage.get("completion_tokens")))
                if self.rate_limited_at is not None:
                    self.rate_limited_at = None
                    self._changed()
                return trimmed
            except LingError as e:
                if e.kind != LingError.RATE_LIMITED:
                    raise
                if attempt >= attempts:
                    self.rate_limited_at = time.time()
                    self._changed()
                    raise
                wait = delay + random.random() * 0.5
                Log.d("ling: %s 429, retry in %.1f s" % (name, wait))
                time.sleep(wait)
                delay *= 2
                attempt += 1

    def speech(self, text: str, voice: str = "UK_Charlotte", language: str | None = None, timeout: float = 20.0):
        """Ming's voice for `text`, as raw 24 kHz mono 16-bit PCM chunks while they arrive (a generator).
        `language` is Ming's language_id, needed for Japanese, Korean, German, French and Spanish
        (Ling.swift › speech)."""
        k = self.key.read()
        if k is None:
            raise LingError(LingError.NO_KEY)
        body = {"model": TTS_MODEL, "input": text, "response_format": "pcm", "sample_rate": TTS_RATE,
                "stream": True, "stream_format": "sse", "voice": voice}
        if language:
            body["language_id"] = language
        self._acquire(SPEAK)
        try:
            res = self.transport.stream(BASE + "audio/speech", jsonfmt.write(body, pretty=False), {
                "Authorization": "Bearer " + k, "Content-Type": "application/json", "User-Agent": "Cicada-Linux/0.1",
            }, timeout)
        except TimeoutError:
            raise LingError(LingError.TIMEOUT) from None
        except OSError:
            raise LingError(LingError.NETWORK) from None
        if res.status in (401, 403):
            self.key_state = INVALID
            self._changed()
            raise LingError(LingError.INVALID_KEY)
        if res.status == 429:
            raise LingError(LingError.RATE_LIMITED)
        if res.status != 200:
            raise LingError(LingError.HTTP, res.status)
        for line in res.lines:
            if not line.startswith("data:"):
                continue
            obj = jsonfmt.parse_object(line[5:].strip())
            if obj is None:
                continue
            if obj.get("type") == "speech.audio.done":
                break
            audio = obj.get("audio")
            if isinstance(audio, str) and audio:
                yield base64.b64decode(audio)

    def _post(self, path: str, payload: str, k: str, timeout: float) -> dict:
        try:
            res = self.transport.send(BASE + path, "POST", payload, {
                "Authorization": "Bearer " + k, "Content-Type": "application/json", "User-Agent": "Cicada-Linux/0.1",
            }, timeout)
        except TimeoutError:
            raise LingError(LingError.TIMEOUT) from None
        except OSError as e:
            Log.d("ling: network error %s" % type(e).__name__)
            raise LingError(LingError.NETWORK) from None
        if res.status in (401, 403):
            if self.key_state != INVALID:
                self.key_state = INVALID
                self._changed()
            raise LingError(LingError.INVALID_KEY)
        if res.status == 429:
            raise LingError(LingError.RATE_LIMITED)
        if res.status != 200:
            Log.d("ling: HTTP %d" % res.status)
            raise LingError(LingError.HTTP, res.status)
        root = jsonfmt.parse_object(res.body)
        if root is None:
            raise LingError(LingError.PARSE)
        return root

    # Start gate: request starts ≥ `spacing` apart, the most urgent waiting one first.

    def _acquire(self, priority: int) -> None:
        with self._gate:
            self._seq += 1
            me = (priority, self._seq)
            self._waiting.append(me)
            try:
                while True:
                    head = min(self._waiting)
                    wait = self.spacing - (time.monotonic() - self._last_start)
                    if head == me and wait <= 0:
                        self._waiting.remove(me)
                        self._last_start = time.monotonic()
                        self._gate.notify_all()
                        return
                    self._gate.wait(wait if head == me else None)
            except BaseException:
                if me in self._waiting:
                    self._waiting.remove(me)
                self._gate.notify_all()
                raise

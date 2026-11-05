"""同声传译 (the Mac's 说): what I say into my microphone, interpreted and spoken into the meeting.

Each sentence (cut by the same Segmenter as listening) goes to Ming's audio model, which returns
what was said and its translation in one call; the translation is voiced by Ming's TTS and played
into 知了 麦克风, the virtual microphone the meeting app uses. Sentences play one after another, in
order. A sentence that couldn't be interpreted is never spoken (AGENTS.md: never speak untranslated
text into the room).

Without headphones my microphone also hears the other side through the speakers; a sentence heard
while the system audio was loud for most of it is dropped, so the room doesn't get its own words
back. UI-free like ListenEngine: on_change is called on worker threads."""
from __future__ import annotations

import queue
import threading
import time
from collections import deque
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

from . import strings
from . import voices as voicemod
from .audio import RATE, Wav
from .ling import LingError, TTS_RATE
from .models import TranscriptLine
from .segmenter import Segmenter
from .support import Log

_END = object()


class LoudnessLog:
    """When the system audio was loud: (monotonic time, loud) per buffer, the last minute. Fed by
    listening, read by the echo check."""

    def __init__(self):
        self._items: deque = deque(maxlen=600)
        self._lock = threading.Lock()

    def add(self, loud: bool) -> None:
        with self._lock:
            self._items.append((time.monotonic(), loud))

    def fraction(self, start: float, end: float) -> float:
        with self._lock:
            span = [l for t, l in self._items if start <= t <= end]
        return sum(span) / len(span) if span else 0.0


class SpeakEngine:
    ECHO = 0.5  # drop a sentence if the system audio was loud for more than half of it

    def __init__(self, ling, translator, settings, store=None, listen=None, player=None):
        self.ling = ling
        self.translator = translator
        self.settings = settings
        self.store = store
        self.listen = listen
        self.player = player  # make() -> object with write(pcm bytes), drain(), close(); 24 kHz mono s16
        self.loudness = LoudnessLog()
        self._listeners = []
        self._source = None
        self._audio = None
        self._work: queue.Queue = queue.Queue()
        self._gen = 0  # bumped by cancel(): sentences queued before it are never spoken
        self._pool = ThreadPoolExecutor(max_workers=3, thread_name_prefix="Interpret")
        self._worker = None
        self._feeder = None
        self.active = False
        self.stage = "idle"      # idle, hearing, interpreting, speaking
        self.last = None          # (original, translation) of the last sentence spoken
        self.problem = None       # the last thing worth saying (a sentence not spoken, a missing voice)
        self.level = 0.0
        self.spoken = 0
        self._me = 0

    def on_change(self, listener) -> None:
        self._listeners.append(listener)

    def _changed(self) -> None:
        for l in list(self._listeners):
            l()

    # Languages

    @property
    def source(self) -> str:
        return self.settings.speak_from_code

    @property
    def target(self) -> str:
        """What the room hears: "room" follows the language they have been speaking."""
        to = self.settings.speakTo
        if to != "room":
            return to
        heard = self.listen.spoken if self.listen is not None else None
        if heard and voicemod.key(heard) != voicemod.key(self.source):
            return heard
        return "en" if voicemod.key(self.source) != "en" else "zh-CN"

    def voice(self, code: str) -> str | None:
        chosen = (self.settings.speakVoices or {}).get(voicemod.key(code))
        names = [v for v, _n, _t in voicemod.voices(code)]
        return chosen if chosen in names else voicemod.default_voice(code)

    # Running

    def start(self, mic) -> None:
        if self.active:
            return
        self.active = True
        self.stage = "hearing"
        self.problem = None
        self.last = None  # the strip starts empty, not on a sentence from an earlier time
        segmenter = Segmenter()
        gen = self._gen
        audio: queue.Queue = queue.Queue()
        self._audio = audio

        def emitted(seg):
            # Interpreted at once, while the sentence before may still be playing; spoken in order.
            ended = time.monotonic()
            self._work.put((gen, seg, self._pool.submit(self._interpret, seg, ended - seg.seconds, ended)))
        segmenter.on_segment = emitted

        def feed():
            while True:
                buf = audio.get()
                if buf is _END:
                    break
                segmenter.feed(buf)
                self.level = Wav.rms(buf)
            segmenter.flush()
        self._feeder = threading.Thread(target=feed, name="SpeakFeed", daemon=True)
        self._feeder.start()
        if self._worker is None or not self._worker.is_alive():
            self._worker = threading.Thread(target=self._run, name="Speak", daemon=True)
            self._worker.start()
        self._source = mic
        mic.on_samples = audio.put
        mic.start()
        Log.d("speak: started %s -> %s" % (self.source, self.target))
        self._changed()

    def stop(self) -> None:
        if not self.active:
            return
        self.active = False
        if self._source is not None:
            self._source.on_samples = None
            self._source.stop()
        if self._audio is not None:
            self._audio.put(_END)
        Log.d("speak: stopped, %d sentences spoken" % self.spoken)
        self._changed()

    def cancel(self) -> None:
        """同声传译 off or 退出: stop, and nothing still waiting is said (知了 麦克风 is going away).
        A plain stop() still says what I finished before pressing it, as releasing the key does on the Mac."""
        self._gen += 1
        self.stop()

    def _run(self) -> None:
        while True:
            gen, seg, job = self._work.get()
            try:
                if gen != self._gen:
                    Log.d("speak: segment %d dropped, cancelled before it was said" % seg.index)
                    continue
                self._say(seg, job.result(), gen)
            except Exception as e:  # noqa: BLE001 - one bad sentence never stops the next
                Log.d("speak: sentence failed %s" % type(e).__name__)
            finally:
                self.stage = "hearing" if self.active else "idle"
                self._changed()

    def _interpret(self, seg, start: float, end: float):
        """(original, translation, source, target, ended, voice chunks) or None, on the pool."""
        listening = self.listen is not None and self.listen.listening
        if listening and not self.settings.speakHeadphones and self.loudness.fraction(start, end) > self.ECHO:
            Log.d("speak: segment %d dropped, the system audio was playing (echo)" % seg.index)
            # Said, so the user knows: talking over them (or no headphones) is why it didn't go out.
            self.problem = strings.L("对方在说话时说的，没有说出去")
            self._changed()
            return None
        source, target = self.source, self.target
        if self.voice(target) is None:
            self.problem = strings.L("这种语言还没有可用的声音")
            return None
        self.stage = "interpreting"
        self._changed()
        try:
            heard = self.translator.interpret(Wav.bytes(seg.samples), source, target)
        except LingError as e:
            Log.d("speak: interpret failed %s" % e)
            heard = None
        if heard is None:
            # Never the original, never a guess.
            self.problem = strings.L("翻译失败，这句话未发送")
            Log.d("speak: segment %d %.1fs not interpreted, not spoken" % (seg.index, seg.seconds))
            return None
        original, translation = heard
        # The voice starts now, on its own thread: ready the moment the sentence before stops playing,
        # instead of each sentence waiting out Ming's first chunk after the last one's playback.
        return original, translation, source, target, end, self._fetch(translation, target)

    def _fetch(self, text: str, target: str) -> queue.Queue:
        chunks: queue.Queue = queue.Queue()

        def run():
            try:
                for pcm in self.ling.speech(text, voice=self.voice(target), language=voicemod.ming_language(target)):
                    chunks.put(pcm)
                chunks.put(_END)
            except LingError as e:
                chunks.put(e)
            except Exception as e:  # noqa: BLE001
                chunks.put(LingError(LingError.NETWORK))
                Log.d("speak: voice fetch failed %s" % type(e).__name__)
        threading.Thread(target=run, name="SpeakVoice", daemon=True).start()
        return chunks

    def _say(self, seg, interpreted, gen: int = 0) -> None:
        if interpreted is None:
            return
        original, translation, source, target, ended, chunks = interpreted
        self.problem = None
        self.last = (original, translation)
        self.stage = "speaking"
        self._changed()
        n = 0
        played = 0
        lag = None
        out = self.player() if self.player else None
        try:
            while True:
                pcm = chunks.get(timeout=30)
                if pcm is _END or gen != self._gen:
                    break  # finished, or stopped mid-sentence
                if isinstance(pcm, LingError):
                    raise pcm
                if lag is None:
                    lag = time.monotonic() - ended  # what the room waits: end of my sentence → its voice
                if out is not None:
                    out.write(pcm)
                n += 1
                played += len(pcm)
            if out is not None:
                out.drain()
        except (LingError, queue.Empty) as e:
            Log.d("speak: voice failed %s" % e)
            self.problem = strings.L("连不上 Ling，检查网络或代理")
        finally:
            if out is not None:
                out.close()
        if n:
            self.spoken += 1
            Log.d("speak: segment %d %.1fs -> %s, voice %.1f s, lag %.2f s after the sentence, %d chunks"
                  % (seg.index, seg.seconds, target, played / 2 / TTS_RATE, lag or 0, n))
            # Stamped when I started the sentence, not when its voice finished (the Mac's secondsAgo).
            self._record(original, translation, source, target, time.monotonic() - (ended - seg.seconds))

    def _record(self, original, translation, source, target, ago: float = 0.0) -> None:
        """My sentence in the meeting's record, as the Mac writes it (speaker "me", ids m<n>)."""
        if self.store is None or self.listen is None or not self.listen.listening or not self.listen.session_id:
            return
        sid = self.listen.session_id
        s = self.store.get(sid)
        if s is None:
            return
        self._me += 1
        t = round(max(0.0, (datetime.now(timezone.utc) - s.startedAt).total_seconds() - ago), 3)
        self.store.append(sid, TranscriptLine(id="m%d" % self._me, t=t, speaker="me", src=original, dst=translation,
                                              srcLang=source, dstLang=target))

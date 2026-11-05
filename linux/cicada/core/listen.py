"""Listening end to end: audio → segments → Ming (language, original, translation in one call) →
lines in the record, plus live notes. UI-free; the app shows the record and listens to on_change
(called on worker threads: hand it to the GTK main loop).

Ming takes ~2.2 s whatever the segment's length, so segments overlap in flight: request starts still
go through LingClient's gate, and lines are delivered in segment order."""
from __future__ import annotations

import queue
import threading
import time
from concurrent.futures import ThreadPoolExecutor, wait

from . import strings
from .audio import RATE, Wav
from .ling import LingError
from .models import TranscriptLine
from .segmenter import Segmenter
from .support import Log, english_name, is_cjk_language
from .translator import Translator

_END = object()


class ListenEngine:
    def __init__(self, ling, translator, store, notes, settings):
        self.ling = ling
        self.translator = translator
        self.store = store
        self.notes = notes
        self.settings = settings
        self._gate = threading.RLock()
        self._pool = ThreadPoolExecutor(max_workers=8, thread_name_prefix="Listen")
        self._source = None
        self._audio = None
        self._worker = None
        self._done: dict = {}
        self._segments: dict = {}
        self._in_flight: list = []
        self._next = 1
        self._line_count = 0
        self._last = None
        self._last_end = 0.0
        self._hint = None
        self._candidate = None
        self._votes = 0
        self._listeners = []
        self.listening = False
        self.session_id = None
        self.source_kind = None  # what this meeting is heard from ("system", "file")
        self.problem = None  # the last error worth showing, cleared by the next good reply
        # What kind of problem, for a state the UI can draw: "key", "busy", "network", "source".
        self.problem_kind = None
        self.level = 0.0
        self.heard_seconds = 0.0  # the capture is alive while this grows
        self.peak = 0.0  # 0 for a while means the source is silent
        self.loudness = None  # SpeakEngine's LoudnessLog: when the system audio was loud (the echo check)
        # 说话人识别: a voiceprint per segment on its own thread while Ming hears it, labelled in order.
        self.speakers = None  # speakers.Tagger, set by the app
        self.on_voice = None  # called with the meeting's id when a line gets a voice (Ling may name it)
        self._voice_pool = ThreadPoolExecutor(1, thread_name_prefix="Voiceprint")
        self._deliver_lock = threading.Lock()
        self._voices_waiting = 0
        # 纪要语言 chosen for one meeting (the notes window's language card), over the setting.
        self.notes_for: dict = {}
        notes.language = lambda sid: english_name(self.notes_code(sid))
        translator.glossary = notes.glossary

    def on_change(self, listener) -> None:
        self._listeners.append(listener)

    def _changed(self) -> None:
        for l in list(self._listeners):
            l()

    @property
    def target(self) -> str:
        return self.settings.target_code

    def meeting_language(self, sid: str | None) -> str | None:
        """The language the other side spoke most in a meeting; while nothing is recorded yet, the one
        the live meeting is being heard in (the Mac's meetingLanguage)."""
        s = self.store.get(sid) if sid else None
        counts: dict = {}
        for l in (s.lines if s else []):
            if l.speaker != "me" and l.srcLang:
                counts[l.srcLang] = counts.get(l.srcLang, 0) + 1
        if counts:
            return max(counts, key=counts.get)
        return self._hint if self.listening and sid == self.session_id else None

    def notes_choice(self, sid: str | None) -> str:
        return self.notes_for.get(sid, self.settings.notesLanguage)

    def notes_code(self, sid: str | None) -> str:
        """The language a meeting's notes are written in (the Mac's notesLanguageCode)."""
        return self.settings.notes_code(self.notes_choice(sid), self.meeting_language(sid))

    def set_notes_language(self, choice: str, meeting_only: bool = False) -> None:
        """纪要语言 changed, in the settings or for this meeting only: a different language during a
        meeting rewrites its notes in it right away (the Mac's setNotesLanguage)."""
        live = self.session_id if self.listening else None
        before = self.notes_code(live) if live else None
        if meeting_only and live:
            self.notes_for[live] = choice
        else:
            self.settings.notesLanguage = choice
            self.settings.save()
        if live and self.notes_code(live) != before:
            self.notes.rewrite()
        Log.d("notesLanguage=%s meetingOnly=%s" % (self.notes_code(live) if live else choice, meeting_only))
        self._changed()

    @property
    def spoken(self):
        with self._gate:
            return self._hint

    @property
    def pending(self) -> int:
        """Segments sent and not yet back: the UI shows "…" while this is above zero."""
        with self._gate:
            return len(self._segments)

    def start(self, source, kind: str) -> None:
        if self.listening:
            return
        session = self.store.begin()
        self.session_id = session.id
        self.source_kind = kind
        with self._gate:
            self._done.clear()
            self._segments.clear()
            self._in_flight.clear()
            self._next, self._line_count, self._last, self._last_end = 1, 0, None, 0.0
            self._hint, self._candidate, self._votes, self.problem = None, None, 0, None
            self.problem_kind = None
        self.heard_seconds = 0.0
        self.peak = 0.0
        self.notes.begin(session.id)
        if self.speakers is not None:
            self.speakers.reset()
        segmenter = Segmenter()
        segmenter.on_segment = self._send
        q: queue.Queue = queue.Queue()
        self._audio = q

        def work():
            # One worker owns the segmenter: audio callbacks only queue buffers.
            while True:
                buf = q.get()
                if buf is _END:
                    break
                segmenter.feed(buf)
                self.level = Wav.rms(buf)
                self.peak = max(self.peak * 0.995, self.level)
                if self.loudness is not None:
                    self.loudness.add(self.level >= Segmenter.threshold)
                self.heard_seconds += len(buf) / RATE
            segmenter.flush()
        self._worker = threading.Thread(target=work, name="ListenWorker", daemon=True)
        self._worker.start()
        self._source = source
        source.on_samples = q.put
        # Listening before the source starts: a source that fails at once calls on_ended → stop(),
        # which must see this meeting as running to end it.
        self.listening = True
        source.start()
        Log.d("listen: started %s source=%s target=%s" % (session.id, kind, self.target))
        self._changed()

    def stop(self, ended_at=None) -> None:
        """Stops listening, waits (briefly) for segments still at Ming, ends the record (at `ended_at`
        for a meeting that ended by itself) and starts the final notes. Blocks until the record is
        saved: call off the main thread."""
        if not self.listening:
            return
        self.listening = False
        if self._source is not None:
            self._source.on_samples = None
            self._source.stop()
        if self._audio is not None:
            self._audio.put(_END)
        if self._worker is not None:
            self._worker.join(5)
        with self._gate:
            waiting = list(self._in_flight)
        wait(waiting, timeout=15)
        sid = self.session_id
        if sid is None:
            return
        self.store.end(sid, ended_at)
        Log.d("listen: stopped %s, %d lines" % (sid, self._line_count))
        self._changed()
        self._pool.submit(self.notes.finish)

    @property
    def voices_on(self) -> bool:
        return bool(self.speakers is not None and getattr(self.settings, "speakerVoices", False) and self.speakers.available)

    def _send(self, seg) -> None:
        wav = Wav.bytes(seg.samples)
        seg.voiceprint = None
        if self.voices_on:
            # Subtitles wait for a line's voice, so on a CPU too slow to keep up a line goes unlabelled
            # (对方) rather than every subtitle falling further behind.
            with self._gate:
                behind = self._voices_waiting >= 2
                if not behind:
                    self._voices_waiting += 1
            if behind:
                Log.d("speakers: voiceprints behind, segment %d left unlabelled" % seg.index)
            else:
                def embed(samples=seg.samples):
                    try:
                        return self.speakers.embed(samples)
                    finally:
                        with self._gate:
                            self._voices_waiting -= 1
                seg.voiceprint = self._voice_pool.submit(embed)
        with self._gate:
            self._segments[seg.index] = seg
            lang = self._hint
        # Asked for what the meeting's language translates into; _record checks it against the
        # language Ming actually heard ("follow system" turns my own language into the next one).
        seg.asked = self.settings.resolved_target(lang)
        self._changed()

        def job():
            heard = None
            started = time.monotonic()
            try:
                heard = self.translator.hear(wav, seg.asked, lang)
                self.problem = self.problem_kind = None
            except LingError as e:
                self.problem_kind = {
                    LingError.NO_KEY: "key", LingError.INVALID_KEY: "key", LingError.RATE_LIMITED: "busy",
                    LingError.NETWORK: "network", LingError.TIMEOUT: "network",
                }.get(e.kind)
                self.problem = {
                    LingError.NO_KEY: strings.L("需要 Ling key 才能听"),
                    LingError.INVALID_KEY: strings.L("Ling key 无效"),
                    LingError.RATE_LIMITED: strings.L("Ling 太忙，稍后再试"),
                    LingError.NETWORK: strings.L("连不上 Ling，检查网络或代理"),
                    LingError.TIMEOUT: strings.L("连不上 Ling，检查网络或代理"),
                }.get(e.kind)
                Log.d("listen: segment %d failed %s" % (seg.index, e))
            except Exception as e:  # noqa: BLE001
                Log.d("listen: segment %d failed %s" % (seg.index, type(e).__name__))
            Log.d("listen: segment %d %.1fs -> %s in %d ms" % (seg.index, seg.seconds, heard.lang if heard else "nothing",
                                                              (time.monotonic() - started) * 1000))
            with self._gate:
                self._done[seg.index] = heard
            self._deliver()
        f = self._pool.submit(job)
        with self._gate:
            self._in_flight.append(f)
            self._in_flight = [x for x in self._in_flight if not x.done()]

    def _deliver(self) -> None:
        """Hands finished segments on in order: one slow reply holds back those after it. One thread
        at a time, so lines (and their voices) are recorded strictly in segment order."""
        with self._deliver_lock:
            ready = []
            with self._gate:
                while self._next in self._done:
                    heard = self._done.pop(self._next)
                    ready.append((self._segments.pop(self._next), heard))
                    self._next += 1
            for seg, heard in ready:
                if heard is not None:
                    self._record(seg, heard)
        if ready:
            self._changed()

    def _voice(self, seg, heard):
        """The segment's voice, or None when unsure. A line with hardly a letter ("." from a breath or
        a click) gets no voiceprint; like the Mac, every labelled segment counts towards its voice."""
        future = getattr(seg, "voiceprint", None)
        if future is None or sum(1 for c in heard.original if c.isalpha()) < 2:
            return None
        try:
            vector = future.result(timeout=20)
        except Exception as e:  # noqa: BLE001
            Log.d("speakers: voiceprint failed %s" % type(e).__name__)
            return None
        return self.speakers.label(vector, seg.seconds)

    def _record(self, seg, heard) -> None:
        sid = self.session_id
        if sid is None:
            return
        target = self.settings.resolved_target(heard.lang)
        # Ming translated into what the hint asked for: when the line turned out to be in another
        # language, that translation is for the wrong reader, so the text translation redoes it.
        translation = heard.translation if getattr(seg, "asked", target) == target else None
        voice = self._voice(seg, heard)
        # The meeting's language moves only after two segments agree, so one misheard stretch doesn't
        # flip the hint (the Mac waits for confidence the same way).
        with self._gate:
            h = self._hint
            if h is None:
                self._hint = heard.lang
            elif heard.lang != h:
                if self._candidate == heard.lang:
                    self._votes += 1
                else:
                    self._candidate, self._votes = heard.lang, 1
                if self._votes >= 2:
                    self._hint, self._candidate, self._votes = self._candidate, None, 0
            else:
                self._candidate, self._votes = None, 0
            prev = self._last
            joined = False
            # Two voices never share a line: a half sentence joins only the same voice (or an unknown one).
            if prev is not None and continues(prev, seg.start - self._last_end, heard) and (
                    voice is None or prev.voice is None or voice == prev.voice):
                prev.src = join(prev.src, heard.original, heard.lang)
                prev.dst = None if prev.dst is None or translation is None else join(prev.dst, translation, target)
                line = prev
                joined = True
            else:
                self._line_count += 1
                line = TranscriptLine(id="h%d-%d" % (self._line_count, seg.index), t=seg.start, speaker="them",
                                      src=heard.original, dst=translation, srcLang=heard.lang, dstLang=target,
                                      voice=voice)
                self._last = line
            self._last_end = seg.start + seg.seconds
            copy = line.copy()
        if joined:
            self.store.replace(sid, copy)
        else:
            self.store.append(sid, copy)
        if voice is not None and self.on_voice is not None:
            self.on_voice(sid)
        # A joined sentence is translated again as a whole; a line Ming didn't translate gets text translation.
        if (joined or line.dst is None) and line.srcLang != target:
            src = line.src

            def retranslate():
                dst = self.translator.translate(src, line.srcLang, target, Translator.SENTENCE)
                with self._gate:
                    if dst is None or line.src != src:
                        return
                    line.dst = dst
                    updated = line.copy()
                self.store.replace(sid, updated)
                self._changed()
            self._pool.submit(retranslate)


def continues(last, gap: float, nxt) -> bool:
    """A segment continues the last line when the cut came mid-sentence: no sentence end on the last
    line, a short gap, the same language, and the joined line not too long to read."""
    if gap > 0.8 or last.srcLang != nxt.lang:
        return False
    text = last.src.rstrip()
    if not text or text[-1] in ".!?。！？…":
        return False
    cjk = is_cjk_language(nxt.lang)
    size = len(text) + len(nxt.original) if cjk else len((text + " " + nxt.original).split())
    return size <= (80 if cjk else 45)


def join(a: str, b: str, lang: str) -> str:
    cjk = lang.startswith(("zh", "ja"))
    return a.rstrip() + b.lstrip() if cjk else a.rstrip() + " " + b.lstrip()

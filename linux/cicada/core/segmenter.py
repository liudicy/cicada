"""Cuts the audio into stretches of speech by loudness alone: a pause of 0.6 s ends one, and one that
runs to 8 s is cut at its quietest moment in the last 2 s, so a word is split as rarely as possible
(Ming has no word timings to put it back together). Not thread-safe: fed from the listening worker
only. Same numbers as the Windows and Android Segmenters."""
from __future__ import annotations

from array import array
from collections import deque

from .audio import RATE, Wav

FRAME = 480  # 30 ms
PRE_ROLL = 0.15
TAIL = 0.15
CUT_WINDOW = 2.0


class Segment:
    """A stretch of speech to send to Ming: where it starts (seconds since listening began) and its
    16 kHz mono samples."""

    def __init__(self, index: int, start: float, samples: array):
        self.index = index
        self.start = start
        self.samples = samples

    @property
    def seconds(self) -> float:
        return len(self.samples) / RATE


class Segmenter:
    threshold = 0.01  # the Mac AudioRouter's gate (about -40 dBFS)
    pause = 0.6
    max_length = 8.0
    min_speech = 0.25

    def __init__(self):
        self.pending = array("h")
        self.current = array("h")
        self.levels: list = []
        self.before: deque = deque()
        self.consumed = 0
        self.current_start = 0.0
        self.quiet = 0
        self.loud = 0
        self.index = 0
        self.on_segment = None

    def feed(self, samples) -> None:
        self.pending.extend(samples)
        whole = len(self.pending) // FRAME * FRAME
        for i in range(0, whole, FRAME):
            self._step(self.pending[i:i + FRAME])
        del self.pending[:whole]

    def flush(self) -> None:
        """Ends the open segment (listening stopped)."""
        if len(self.current):
            self._close(len(self.current) - self.quiet * FRAME + int(TAIL * RATE))

    def _step(self, frame: array) -> None:
        level = Wav.rms(frame)
        loud = level >= self.threshold
        now = self.consumed / RATE
        self.consumed += len(frame)
        if not len(self.current):
            if not loud:
                self.before.append(frame)
                while len(self.before) > PRE_ROLL * RATE / FRAME:
                    self.before.popleft()
                return
            self.current_start = now - len(self.before) * FRAME / RATE
            for f in self.before:
                self.current.extend(f)
                self.levels.append(0.0)
            self.before.clear()
            self.quiet = self.loud = 0
        self.current.extend(frame)
        self.levels.append(level)
        if loud:
            self.quiet = 0
            self.loud += 1
        else:
            self.quiet += 1
        if self.quiet * FRAME >= self.pause * RATE:
            self._close(len(self.current) - self.quiet * FRAME + int(TAIL * RATE))
        elif len(self.current) >= self.max_length * RATE:
            # The quietest frame in the last 2 s; the rest starts the next segment.
            frm = max(1, len(self.levels) - int(CUT_WINDOW * RATE / FRAME))
            cut = frm
            for i in range(frm, len(self.levels)):
                if self.levels[i] < self.levels[cut]:
                    cut = i
            self._close(cut * FRAME)

    def _close(self, end_at: int) -> None:
        """Emits current[:end] and keeps what follows as the start of the next segment."""
        end = max(0, min(end_at, len(self.current)))
        samples = self.current[:end]
        rest = self.current[end:]
        rest_levels = self.levels[min(len(self.levels), end // FRAME):]
        start = self.current_start
        speech = self.loud * FRAME >= self.min_speech * RATE
        self.current = array("h")
        self.levels = []
        self.quiet = self.loud = 0
        if speech and self.on_segment:
            self.index += 1
            self.on_segment(Segment(self.index, round(start * 1000) / 1000.0, samples))
        elif speech:
            self.index += 1
        # A forced cut carries on with the remainder; after a pause the remainder is silence.
        if any(l >= self.threshold for l in rest_levels):
            self.current_start = start + end / RATE
            self.current.extend(rest)
            self.levels = list(rest_levels)
            trailing = 0
            for l in reversed(self.levels):
                if l >= self.threshold:
                    break
                trailing += 1
            self.quiet = trailing
            self.loud = sum(1 for l in self.levels if l >= self.threshold)

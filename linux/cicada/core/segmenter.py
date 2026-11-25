"""Cuts the audio into stretches of speech by loudness alone: a pause of 0.6 s ends one, and one that
runs to 8 s is cut at its quietest moment in the last 2 s, so a word is split as rarely as possible
(Ming has no word timings to put it back together). Not thread-safe: fed from the listening worker
only. Same numbers as the Windows and Android Segmenters."""
from __future__ import annotations

import math
from array import array
from collections import deque

from .audio import RATE, Wav

FRAME = 480  # 30 ms
STEP = 160  # 10 ms: a key click is judged in these, as the Mac's VoiceActivity does
ONSET = 3  # steps of sound before it counts as speech
PRE_ROLL = 0.15
TAIL = 0.15
CUT_WINDOW = 2.0
# A first-order high-pass at 100 Hz, for how much of a sound is above it (_rumble).
HIGH_PASS = 1.0 / (1.0 + 2.0 * math.pi * 100.0 / RATE)


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
    # The Mac AudioRouter's gate (about -40 dBFS). A room microphone's segmenter has it set by
    # roommic.VoiceGate as the room's noise is learnt.
    threshold = 0.01
    pause = 0.6
    max_length = 8.0
    min_speech = 0.25
    min_word = 0.2  # a word on its own (_isolated): this much over gate / 4 ("Thanks." at -36 dBFS: 0.21 s)
    steady = 2.0  # frames' 90th / 10th percentile below this: not speech…
    dips = 2.5  # …unless the median is this far over the 10th percentile, quiet ones held at gate / 8
    short = 2.0  # a sound up to this long, with real quiet (gate / 4) on both sides…
    swell = 10 ** (10 / 20)  # …that swells and fades by 10 dB is a word: see _isolated
    fade = 10 ** (30 / 20)  # its rise and fade reach this far under its loudest step (or gate / 4 if lower)
    voiced = 0.15  # a word's full frames crossing zero under this often (per sample) have voice in them: see _voiced
    above = 0.25  # under this share of its loud frames' energy over 100 Hz: rumble, not speech

    def __init__(self):
        self.pending = array("h")
        self.current = array("h")
        self.levels: list = []
        self.highs: list = []  # per frame of `current`: its level over 100 Hz
        self.speech: list = []  # per frame of `current`: whether it held speech (_speech)
        self.sounding = 0  # 10 ms steps of sound in a row so far
        self.carried = False  # the sound that made the last frame speech began in the frame before
        self._hx = 0.0  # the high-pass's last input and output, carried from frame to frame
        self._hy = 0.0
        self.before: deque = deque()
        self.idle: deque = deque(maxlen=int(self.pause * RATE / FRAME))  # levels of the last quiet frames
        self.lead = None  # the quietest of those when the open segment began (None: it didn't begin in quiet)
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

    def _speech(self, frame) -> bool:
        """Whether the frame holds speech: sound that has lasted 30 ms, judged in 10 ms steps against the
        line, so a lone key click (a few ms) neither opens a segment nor breaks the pause that ends
        one (VoiceActivity.swift's onset). The pre-roll then reaches back to where that sound began."""
        said = False
        carried = self.sounding > 0
        for i in range(0, len(frame), STEP):
            if Wav.rms(frame[i:i + STEP]) >= self.threshold:
                self.sounding += 1
                if self.sounding >= ONSET and not said:
                    said = True
                    self.carried = carried
            else:
                self.sounding = 0
                carried = False
        return said

    def _step(self, frame: array) -> None:
        level = Wav.rms(frame)
        high = self._high(frame)
        loud = self._speech(frame)
        now = self.consumed / RATE
        self.consumed += len(frame)
        if not len(self.current):
            if not loud:
                self.idle.append(level)
                self.before.append((frame, level, high))
                while len(self.before) > PRE_ROLL * RATE / FRAME + 1:
                    self.before.popleft()
                return
            # One frame more when the sound began in the last quiet one.
            while len(self.before) > PRE_ROLL * RATE / FRAME + self.carried:
                self.before.popleft()
            self.current_start = now - len(self.before) * FRAME / RATE
            self.lead = min(self.idle) if self.idle else None
            self.idle.clear()
            for f, l, h in self.before:
                self.current.extend(f)
                self.levels.append(l)
                self.highs.append(h)
                self.speech.append(False)
            self.before.clear()
            self.quiet = self.loud = 0
        self.current.extend(frame)
        self.levels.append(level)
        self.highs.append(high)
        self.speech.append(loud)
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

    def _steady(self, levels) -> bool:
        """Steady sound just over the gate (a fan, hum, hiss) isn't speech: its loud frames barely vary
        (90th / 10th percentile about 1.1; speech, even over such a floor, 3 and up). Given one, Ming
        writes a stock sentence in the hint's language ("I'm going to show you a couple of things").
        Speech buried under steady noise goes too; system audio rarely carries it. Every frame from
        the first loud one to the last counts, the quiet ones held at the gate: counting only the
        loud ones dropped quiet speech (under about -30 dBFS), whose dips fall below the gate.
        A voice so quiet that its loudest frames barely clear the gate (about -38 dBFS: 6 of 6 lines
        lost in testing) still pauses between syllables, its quietest tenth of frames far under its
        median (8 dB and more); noise near the gate stays within about 6 dB of its median. So a flat
        top is steady only when it has no such dips, measured with quiet frames held at gate / 8.
        Very low rumble (brown noise with almost nothing over 20 Hz) can look like that and gets
        through more often than before (about 1 in 3 segments, was 1 in 5); what Ming makes of it
        still meets the hear filter (translator.is_noise)."""
        loud = [i for i, l in enumerate(levels) if l >= self.threshold]
        if len(loud) < 2:
            return False
        body = levels[loud[0]:loud[-1] + 1]
        top = sorted(max(l, self.threshold) for l in body)
        if top[int(0.9 * (len(top) - 1))] >= self.steady * top[int(0.1 * (len(top) - 1))]:
            return False
        low = sorted(max(l, self.threshold / 8) for l in body)
        return low[int(0.5 * (len(low) - 1))] < self.dips * low[int(0.1 * (len(low) - 1))]

    def _isolated(self, levels) -> bool:
        """A short word on its own: a sound up to `short` that rises out of real quiet and falls back
        into it (under gate / 4, about -52 dBFS, in the 0.6 s before it and in the pause after),
        and that swells and fades by 10 dB or more: at least 5% of its 10 ms steps (and 3 of them),
        from where it rises to where it fades, are that far under its 90th percentile. Such a word
        ("Thanks.", "Good morning everyone,") is one smooth syllable or a run of voiced ones, so the
        steady test, which looks for dips inside, dropped it even at -26 dBFS; and a quiet one
        ("Thanks." at -36 dBFS) has under 0.25 s over the gate, so it needs `min_word` over gate / 4
        instead (a knock with a 150 ms tail has 0.15 s). A fan, hum or hiss is there on both sides;
        a short burst of one in silence has at most one low step at each edge (its 5th percentile
        stays within 2 dB, 9 dB with 50 ms fades), and Ming makes up a sentence for a hum or fan
        burst. Not for a forced cut, whose end isn't a pause.
        Where it rises and fades: over gate / 4, or 30 dB under its loudest step if that's lower;
        over gate / 4 alone, a quiet word lost its rise and fade (an "s" or breath at -55 dBFS) and
        only its flat top was left. 30 ms frames and their 10th percentile put Samantha's "Good
        morning everyone." at 7.5 to 11.4 dB depending on where the frames fell, so it came and
        went with a few ms of lead-in; 10 ms steps and their 5th percentile give it 14.6 to 16.5."""
        loud = [i for i, l in enumerate(levels) if l >= self.threshold]
        if not loud or (loud[-1] - loud[0] + 1) * FRAME > self.short * RATE:
            return False
        quiet = self.threshold / 4
        after = levels[loud[-1] + 1:]
        if self.lead is None or self.lead > quiet or not after or min(after) > quiet:
            return False
        steps = [Wav.rms(self.current[i:i + STEP]) for i in range(0, len(self.current) - STEP + 1, STEP)]
        rise = min(quiet, max(steps) / self.fade)
        sound = [i for i, l in enumerate(steps) if l >= rise]
        body = sorted(max(l, self.threshold / 8) for l in steps[sound[0]:sound[-1] + 1])
        low = max(2, int(0.05 * (len(body) - 1)))
        return low < len(body) and body[int(0.9 * (len(body) - 1))] >= self.swell * body[low] and self._voiced(levels)

    def _voiced(self, levels) -> bool:
        """Whether a word has voice in it: 2 or more of its full frames (within 3 dB of its 90th
        percentile) cross zero under `voiced` times a sample. Voiced speech crosses slowly (every
        voice tested had full frames at 0.01 to 0.06); a hiss crosses about every other sample (0.46
        and up) and, faded in and out over 0.3 s, swells like a word. Edge frames half silence
        cross slowly whatever they hold, hence full frames only and more than one."""
        full = sorted(levels)[int(0.9 * (len(levels) - 1))] / math.sqrt(2)
        slow = 0
        for i, l in enumerate(levels):
            if l < full:
                continue
            f = self.current[i * FRAME:(i + 1) * FRAME]
            crossings = sum(1 for k in range(1, len(f)) if (f[k] >= 0) != (f[k - 1] >= 0))
            if crossings < self.voiced * (len(f) - 1):
                slow += 1
        return slow >= 2

    def _high(self, frame) -> float:
        """The frame's level over 100 Hz (RMS after the high-pass), the filter running on across frames.
        A plain loop, not sum(): every port adds in the same order and gets the same number."""
        a, x0, y, total = HIGH_PASS, self._hx, self._hy, 0.0
        for x in frame:
            y = a * (y + x - x0)
            x0 = x
            total += y * y
        self._hx, self._hy = float(x0), y
        return math.sqrt(total / len(frame)) / 32768 if len(frame) else 0.0

    def _rumble(self, levels, highs) -> bool:
        """Rumble, not speech: under a quarter of the loud frames' energy is over 100 Hz. Speech keeps
        nearly all of it there (-0.3 to -1 dB in testing, the low male voices included); brown noise
        with almost nothing over 20 Hz keeps -20 to -28 dB, and Ming made a sentence of 15 of 17 such
        segments ("I'm going to go ahead and start the meeting."), which the loudness rules can't
        tell from a voice. Brown noise up to about 12 Hz keeps -10 dB and goes too; a 50 Hz hum or a
        fan keeps about -5 dB and is left to the steady test."""
        full = above = 0.0
        for l, h in zip(levels, highs):
            if l >= self.threshold:
                full += l * l
                above += h * h
        return above < self.above * full

    def _close(self, end_at: int) -> None:
        """Emits current[:end] and keeps what follows as the start of the next segment."""
        end = max(0, min(end_at, len(self.current)))
        samples = self.current[:end]
        rest = self.current[end:]
        rest_levels = self.levels[min(len(self.levels), end // FRAME):]
        rest_highs = self.highs[min(len(self.highs), end // FRAME):]
        rest_speech = self.speech[min(len(self.speech), end // FRAME):]
        start = self.current_start
        sent = self.levels[:end // FRAME]
        if self._isolated(self.levels):
            sound = sum(1 for l in sent if l >= self.threshold / 4)
            speech = sound * FRAME >= self.min_word * RATE
        else:
            speech = self.loud * FRAME >= self.min_speech * RATE and not self._steady(sent)
        speech = speech and not self._rumble(sent, self.highs[:end // FRAME])
        self.current = array("h")
        self.levels = []
        self.highs = []
        self.speech = []
        self.quiet = self.loud = 0
        if speech and self.on_segment:
            self.index += 1
            self.on_segment(Segment(self.index, round(start * 1000) / 1000.0, samples))
        elif speech:
            self.index += 1
        # A forced cut carries on with the remainder; after a pause the remainder is silence.
        if any(rest_speech):
            self.current_start = start + end / RATE
            self.lead = None
            self.current.extend(rest)
            self.levels = list(rest_levels)
            self.highs = list(rest_highs)
            self.speech = list(rest_speech)
            trailing = 0
            for v in reversed(self.speech):
                if v:
                    break
                trailing += 1
            self.quiet = trailing
            self.loud = sum(self.speech)

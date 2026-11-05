"""Where listening gets its sound: 16 kHz mono Int16 (array('h')), pushed from any thread. On Linux
the PulseAudio/PipeWire monitor of the speakers (app/capture.py); in tests, the CLI and the sample
meeting, a file."""
from __future__ import annotations

import math
import struct
import sys
import threading
import time
from array import array

RATE = 16000


class AudioSource:
    """Set on_samples / on_ended before start(); both are called on the source's own thread.
    on_ended(None) when a file finished, else why the source stopped."""
    on_samples = None
    on_ended = None

    def start(self) -> None:
        raise NotImplementedError

    def stop(self) -> None:
        raise NotImplementedError


class PcmAudioSource(AudioSource):
    """Plays 16 kHz samples into listening, in real time or as fast as it can (`speed` 0)."""

    def __init__(self, load, speed: float = 1.0):
        self._load = load if callable(load) else (lambda: Wav.read_file(load))
        self.speed = speed
        self._stopped = False

    def start(self) -> None:
        self._stopped = False
        threading.Thread(target=self._run, name="PcmAudioSource", daemon=True).start()

    def _run(self) -> None:
        try:
            pcm = self._load()
        except Exception as e:  # noqa: BLE001 - any unreadable file ends the source
            from .support import Log
            Log.d("file source: unreadable %s" % type(e).__name__)
            if self.on_ended:
                self.on_ended("unreadable")
            return
        chunk = RATE // 10  # 100 ms, like a capture callback
        started = time.monotonic()
        i = 0
        while i < len(pcm) and not self._stopped:
            if self.on_samples:
                self.on_samples(pcm[i:i + chunk])
            if self.speed > 0:
                wait = started + (i + chunk) / RATE / self.speed - time.monotonic()
                if wait > 0:
                    time.sleep(wait)
            i += chunk
        # A second of silence so the last sentence's pause is heard.
        if self.on_samples and not self._stopped:
            self.on_samples(array("h", bytes(RATE * 2)))
        if self.on_ended:
            self.on_ended(None)

    def stop(self) -> None:
        self._stopped = True


def _le(a: array) -> array:
    if sys.byteorder != "little":
        a = array("h", a)
        a.byteswap()
    return a


class Wav:
    @staticmethod
    def bytes(pcm: array, rate: int = RATE) -> bytes:
        data = _le(pcm).tobytes()
        return (b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVEfmt " +
                struct.pack("<IHHIIHH", 16, 1, 1, rate, rate * 2, 2, 16) + b"data" + struct.pack("<I", len(data)) + data)

    @staticmethod
    def read_file(path: str) -> array:
        with open(path, "rb") as f:
            return Wav.read(f.read())

    @staticmethod
    def read(data: bytes) -> array:
        """A PCM16 WAV of any rate and channel count, as 16 kHz mono."""
        if data[:4] != b"RIFF" or data[8:12] != b"WAVE":
            raise ValueError("not a WAV")
        pos = 12
        channels, rate = 1, RATE
        while pos + 8 <= len(data):
            cid = data[pos:pos + 4]
            size = struct.unpack("<I", data[pos + 4:pos + 8])[0]
            body = pos + 8
            if cid == b"fmt ":
                fmt, channels, rate = struct.unpack("<HHI", data[body:body + 8])
                bits = struct.unpack("<H", data[body + 14:body + 16])[0]
                if fmt not in (1, 0xFFFE) or bits != 16:
                    raise ValueError("only 16-bit PCM WAV")
            elif cid == b"data":
                raw = data[body:body + min(size, len(data) - body)]
                raw = raw[:len(raw) // (2 * channels) * 2 * channels]
                s = array("h")
                s.frombytes(raw)
                s = _le(s)
                if channels == 1 and rate == RATE:
                    return s
                if channels == 1:
                    mono = s
                else:
                    mono = array("d", (sum(s[f * channels:(f + 1) * channels]) / channels for f in range(len(s) // channels)))
                return Wav.resample(mono, rate)
            pos = body + size + (size & 1)
        raise ValueError("no data chunk")

    @staticmethod
    def resample(mono, rate: int) -> array:
        """Box average then pick: plenty for speech going to a recognizer."""
        def clamp(x):
            return int(max(-32768, min(32767, x)))
        if rate == RATE:
            return array("h", (clamp(x) for x in mono))
        window = max(1, rate // RATE)
        count = len(mono) * RATE // rate
        out = array("h", bytes(count * 2))
        for i in range(count):
            start = i * rate // RATE
            stop = min(len(mono), start + window)
            out[i] = clamp(sum(mono[start:stop]) / max(1, stop - start))
        return out

    @staticmethod
    def rms(buf) -> float:
        if not len(buf):
            return 0.0
        return math.sqrt(sum(x * x for x in buf) / len(buf)) / 32768


def sink_description(pactl_sinks: str, name: str) -> str | None:
    """The description of sink `name` in `pactl list sinks` output (the onboarding shows the default
    output by it). The field names are English under LC_MESSAGES=C; the description stays translated."""
    if not name:
        return None
    current = None
    for line in pactl_sinks.splitlines():
        field, _, value = line.strip().partition(":")
        if field == "Name":
            current = value.strip()
        elif field == "Description" and current == name:
            return value.strip() or None
    return None

"""System audio on Linux: the monitor of the default output, read through libpulse-simple (ctypes).
PulseAudio and PipeWire (through pipewire-pulse, Ubuntu's default since 22.10) both serve it, and
reading a monitor needs no permission. Cicada itself plays nothing while it listens, so unlike the
Mac's process tap there is nothing of its own to leave out.

Two things a meeting outlives: the default output changing (headphones plugged in, a Bluetooth
headset connecting; PipeWire moves the stream itself, plain PulseAudio leaves it on the old device,
so it is reopened when the default changes) and the sound server going away for a moment (suspend
and resume, a restart; the stream is reopened for up to 20 s before listening gives up)."""
from __future__ import annotations

import ctypes
import ctypes.util
import os
import subprocess
import threading
import time
from array import array

from ..core.audio import RATE, AudioSource
from ..core.strings import L
from ..core.support import Log

PA_SAMPLE_S16LE = 3
PA_STREAM_RECORD = 2
CHUNK = RATE // 10  # 100 ms per read, like a capture callback


class _Spec(ctypes.Structure):
    _fields_ = [("format", ctypes.c_int), ("rate", ctypes.c_uint32), ("channels", ctypes.c_uint8)]


class _Attr(ctypes.Structure):
    _fields_ = [("maxlength", ctypes.c_uint32), ("tlength", ctypes.c_uint32), ("prebuf", ctypes.c_uint32),
                ("minreq", ctypes.c_uint32), ("fragsize", ctypes.c_uint32)]


_lib = None


def _pulse():
    global _lib
    if _lib is None:
        name = ctypes.util.find_library("pulse-simple") or "libpulse-simple.so.0"
        lib = ctypes.CDLL(name)
        lib.pa_simple_new.restype = ctypes.c_void_p
        lib.pa_simple_new.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_char_p,
                                      ctypes.POINTER(_Spec), ctypes.c_void_p, ctypes.POINTER(_Attr), ctypes.POINTER(ctypes.c_int)]
        lib.pa_simple_read.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_int)]
        lib.pa_simple_free.argtypes = [ctypes.c_void_p]
        pulse = ctypes.CDLL(ctypes.util.find_library("pulse") or "libpulse.so.0")
        pulse.pa_strerror.restype = ctypes.c_char_p
        pulse.pa_strerror.argtypes = [ctypes.c_int]
        lib.strerror = pulse.pa_strerror
        _lib = lib
    return _lib


class _ServerInfo(ctypes.Structure):
    # pa_server_info, as far as default_source_name.
    _fields_ = [("user_name", ctypes.c_char_p), ("host_name", ctypes.c_char_p), ("server_version", ctypes.c_char_p),
                ("server_name", ctypes.c_char_p), ("sample_spec", _Spec), ("default_sink_name", ctypes.c_char_p),
                ("default_source_name", ctypes.c_char_p)]


_INFO_CB = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.POINTER(_ServerInfo), ctypes.c_void_p)
_full = None


def _libpulse():
    global _full
    if _full is None:
        l = ctypes.CDLL(ctypes.util.find_library("pulse") or "libpulse.so.0")
        l.pa_mainloop_new.restype = ctypes.c_void_p
        l.pa_mainloop_get_api.restype = ctypes.c_void_p
        l.pa_mainloop_get_api.argtypes = [ctypes.c_void_p]
        l.pa_mainloop_iterate.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
        l.pa_mainloop_free.argtypes = [ctypes.c_void_p]
        l.pa_context_new.restype = ctypes.c_void_p
        l.pa_context_new.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
        l.pa_context_connect.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int, ctypes.c_void_p]
        l.pa_context_get_state.argtypes = [ctypes.c_void_p]
        l.pa_context_get_server_info.restype = ctypes.c_void_p
        l.pa_context_get_server_info.argtypes = [ctypes.c_void_p, _INFO_CB, ctypes.c_void_p]
        l.pa_operation_get_state.argtypes = [ctypes.c_void_p]
        l.pa_operation_unref.argtypes = [ctypes.c_void_p]
        l.pa_context_disconnect.argtypes = [ctypes.c_void_p]
        l.pa_context_unref.argtypes = [ctypes.c_void_p]
        _full = l
    return _full


def default_sink() -> str | None:
    """The sound server's default output, or None when it can't be asked (a few ms, blocking)."""
    return _server_info().get("sink")


def default_source() -> str | None:
    """The sound server's default input, or None when it can't be asked."""
    return _server_info().get("source")


def sources_text() -> str:
    """`pactl list sources` in English (roommic.parse_sources reads it); empty without pactl."""
    try:
        return subprocess.run(["pactl", "list", "sources"], env={**os.environ, "LC_ALL": "C"}, capture_output=True,
                              text=True, timeout=3).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def _server_info() -> dict:
    try:
        l = _libpulse()
    except OSError:
        return {}
    loop = l.pa_mainloop_new()
    ctx = l.pa_context_new(l.pa_mainloop_get_api(loop), b"Cicada")
    found = {}

    @_INFO_CB
    def got(_c, info, _u):
        if info and info.contents.default_sink_name:
            found["sink"] = info.contents.default_sink_name.decode()
        if info and info.contents.default_source_name:
            found["source"] = info.contents.default_source_name.decode()
    try:
        if l.pa_context_connect(ctx, None, 0, None) < 0:
            return {}
        deadline = time.monotonic() + 1.0
        op = None
        while time.monotonic() < deadline:
            l.pa_mainloop_iterate(loop, 0, None)
            state = l.pa_context_get_state(ctx)
            if state in (5, 6):  # FAILED, TERMINATED
                return {}
            if state == 4 and op is None:  # READY
                op = l.pa_context_get_server_info(ctx, got, None)
            if op is not None and l.pa_operation_get_state(op) != 0:  # no longer RUNNING
                l.pa_operation_unref(op)
                break
            time.sleep(0.005)
        return found
    finally:
        l.pa_context_disconnect(ctx)
        l.pa_context_unref(ctx)
        l.pa_mainloop_free(loop)


def available() -> bool:
    try:
        _pulse()
        return True
    except OSError:
        return False


class SystemAudio(AudioSource):
    """16 kHz mono from "@DEFAULT_MONITOR@" (or a microphone, `device`): the server resamples and
    downmixes for us. `name` is what the sound settings and GNOME's privacy menu show."""

    def __init__(self, device: str = "@DEFAULT_MONITOR@", name: str | None = None):
        self.device = device
        self.name = name
        self._stop = threading.Event()
        self._thread = None

    def start(self) -> None:
        self._stop.clear()
        self._thread = threading.Thread(target=self._run, name="SystemAudio", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()

    def _open(self, lib):
        spec = _Spec(PA_SAMPLE_S16LE, RATE, 1)
        # fragsize: hand data over every 100 ms rather than in the server's default 2 s blocks.
        attr = _Attr(0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, CHUNK * 2)
        err = ctypes.c_int(0)
        # The stream's name is what the sound settings and GNOME's privacy menu show.
        s = lib.pa_simple_new(None, b"Cicada", PA_STREAM_RECORD, self.device.encode(), (self.name or L("知了 · 系统声音")).encode(),
                              ctypes.byref(spec), None, ctypes.byref(attr), ctypes.byref(err))
        return s, (None if s else lib.strerror(err.value).decode())

    def _reopen(self, lib, why: str):
        """The server went away: try again for a while (it is back within seconds after resume)."""
        deadline = time.monotonic() + 20
        while not self._stop.is_set() and time.monotonic() < deadline:
            time.sleep(1)
            s, err = self._open(lib)
            if s:
                Log.d("tap: reconnected after %s" % why)
                return s
        return None

    def _run(self) -> None:
        try:
            lib = _pulse()
        except OSError as e:
            Log.d("tap: no libpulse (%s)" % e)
            self._end("no libpulse")
            return
        s, why = self._open(lib)
        if not s:
            Log.d("tap: can't open %s: %s" % (self.device, why))
            self._end(why)
            return
        sink = default_sink()
        Log.d("tap: %s s16le %d Hz mono (output %s)" % (self.device, RATE, "known" if sink else "unknown"))
        buf = ctypes.create_string_buffer(CHUNK * 2)
        err = ctypes.c_int(0)
        reads = 0
        try:
            while not self._stop.is_set():
                if lib.pa_simple_read(s, buf, CHUNK * 2, ctypes.byref(err)) < 0:
                    why = lib.strerror(err.value).decode()
                    Log.d("tap: read failed %s" % why)
                    lib.pa_simple_free(s)
                    s = self._reopen(lib, why)
                    if s is None:
                        self._end(why)
                        return
                    sink = default_sink()
                    continue
                reads += 1
                if self.device == "@DEFAULT_MONITOR@" and reads % 30 == 0:  # every 3 s: did the default output change?
                    now = default_sink()
                    if now and sink and now != sink:
                        Log.d("tap: default output changed, reopening")
                        lib.pa_simple_free(s)
                        s, why = self._open(lib)
                        if not s:
                            s = self._reopen(lib, why or "reopen")
                            if s is None:
                                self._end(why)
                                return
                    sink = now or sink
                samples = array("h")
                samples.frombytes(buf.raw)
                cb = self.on_samples
                if cb:
                    cb(samples)
        finally:
            if s:
                lib.pa_simple_free(s)

    def _end(self, why) -> None:
        cb = self.on_ended
        if cb:
            cb(why)

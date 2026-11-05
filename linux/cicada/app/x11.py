"""The one X11 detail GTK 3 doesn't cover. With set_accept_focus(False) GTK still lists
WM_TAKE_FOCUS in WM_PROTOCOLS, so on every click Mutter hands focus away from the meeting app for a
moment (the "globally active" input model) before giving it back; a blip a browser-based meeting app
sees as blur. Listing only WM_DELETE_WINDOW (the "no input" model) leaves focus alone."""
from __future__ import annotations

import ctypes
import ctypes.util

from ..core.support import Log

_x = None


def _lib():
    global _x
    if _x is None:
        x = ctypes.CDLL(ctypes.util.find_library("X11") or "libX11.so.6")
        x.XOpenDisplay.restype = ctypes.c_void_p
        x.XOpenDisplay.argtypes = [ctypes.c_char_p]
        x.XInternAtom.restype = ctypes.c_ulong
        x.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
        x.XSetWMProtocols.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(ctypes.c_ulong), ctypes.c_int]
        x.XFlush.argtypes = [ctypes.c_void_p]
        x.XCloseDisplay.argtypes = [ctypes.c_void_p]
        _x = x
    return _x


def never_take_focus(gdk_window) -> None:
    """Drops WM_TAKE_FOCUS from an X11 window's protocols. No-op off X11."""
    _protocols(gdk_window, False)


def take_focus(gdk_window) -> None:
    """Lists WM_TAKE_FOCUS again, for the moment the window needs the keyboard (its search)."""
    _protocols(gdk_window, True)


def _protocols(gdk_window, focus: bool) -> None:
    xid = gdk_window.get_xid() if hasattr(gdk_window, "get_xid") else None
    if not xid:
        return
    try:
        x = _lib()
        d = x.XOpenDisplay(None)
        if not d:
            return
        names = [b"WM_DELETE_WINDOW"] + ([b"WM_TAKE_FOCUS"] if focus else [])
        atoms = (ctypes.c_ulong * len(names))(*[x.XInternAtom(d, n, 0) for n in names])
        x.XSetWMProtocols(d, xid, atoms, len(names))
        x.XFlush(d)
        x.XCloseDisplay(d)
    except OSError as e:
        Log.d("x11: protocols not set (%s)" % e)

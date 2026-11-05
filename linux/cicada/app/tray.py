"""The tray icon (the Mac's menu bar panel), through Ayatana AppIndicator: Ubuntu's top bar shows it
(the AppIndicator extension ships enabled), as do KDE, Xfce and most others. Ubuntu installs the C
library but not its GObject typelib, so it's called through ctypes with our own Gtk.Menu. Plain GNOME
has no tray; then there is none, and the records window's header bar carries 开始听 instead."""
from __future__ import annotations

import ctypes
import ctypes.util

from ..core.strings import L, LF
from ..core.support import Log


def _gpointer(obj) -> int:
    """The C pointer behind a PyGObject object (its __gpointer__ capsule)."""
    get = ctypes.pythonapi.PyCapsule_GetPointer
    get.restype = ctypes.c_void_p
    get.argtypes = [ctypes.py_object, ctypes.c_char_p]
    return get(obj.__gpointer__, None)


def make(app, icon: str | None):
    for name in ("ayatana-appindicator3", "appindicator3"):
        path = ctypes.util.find_library(name)
        if not path:
            continue
        try:
            return Tray(app, ctypes.CDLL(path), icon)
        except (OSError, AttributeError) as e:
            Log.d("tray: %s unusable (%s)" % (name, e))
    Log.d("tray: no AppIndicator, records window instead")
    return None


class Tray:
    CATEGORY_APPLICATION_STATUS = 0
    STATUS_ACTIVE = 1

    def __init__(self, app, lib, icon):
        from gi.repository import Gtk
        self.app = app
        self.Gtk = Gtk
        lib.app_indicator_new.restype = ctypes.c_void_p
        lib.app_indicator_new.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int]
        for f in ("app_indicator_set_status",):
            getattr(lib, f).argtypes = [ctypes.c_void_p, ctypes.c_int]
        lib.app_indicator_set_menu.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        lib.app_indicator_set_title.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
        lib.app_indicator_set_label.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
        lib.app_indicator_set_icon_full.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
        self.lib = lib
        self.icon = icon or "cicada"
        self.badged = False
        # An absolute path works as the icon "name", so no icon theme install is needed.
        self.ind = lib.app_indicator_new(b"cicada", (icon or "cicada").encode(), self.CATEGORY_APPLICATION_STATUS)
        lib.app_indicator_set_status(self.ind, self.STATUS_ACTIVE)
        lib.app_indicator_set_title(self.ind, L("知了").encode())
        self.menu = None
        self.update()
        Log.d("tray: AppIndicator")

    def update(self) -> None:
        Gtk = self.Gtk
        listening = self.app.listen.listening
        menu = Gtk.Menu()

        def item(label, action, sensitive=True):
            i = Gtk.MenuItem(label=label)
            if action:
                i.connect("activate", lambda *_: action())
            i.set_sensitive(sensitive)
            menu.append(i)
            return i
        # A new version first, with the accent dot the Mac's panel gives it; greyed while it downloads.
        upd = self.app.updates.menu_label()
        if upd:
            item("● " + upd, self.app.updates.install, sensitive=self.app.updates.progress is None
                 and not self.app.updates.after_meeting)
            menu.append(Gtk.SeparatorMenuItem())
        # A status header, as the design's tray menu: what's happening, then the actions.
        self.status_item = item(self._status(), None, False)
        if listening:
            self.detail_item = item(self._detail(), None, False)
        else:
            self.detail_item = None
        menu.append(Gtk.SeparatorMenuItem())
        item(L("结束") if listening else L("开始听"), self.app.request_stop)
        if self.app.settings.speakEnabled:
            item(L("停止说") if self.app.speak.active else L("开始说"), self.app.toggle_speaking)
        item(L("显示实时纪要"), self.app.show_notes)
        item(L("打开会议记录"), self.app.show_records)
        item(L("设置…"), self.app.show_settings)
        menu.append(Gtk.SeparatorMenuItem())
        item(LF("退出 %@", L("知了")), self.app.quit)
        menu.show_all()
        menu.connect("show", lambda *_: self.app.updates.menu_opened())  # an hour-old check: check again
        self.lib.app_indicator_set_menu(self.ind, _gpointer(menu))
        self.menu = menu  # the indicator holds a ref too; keep ours so Python doesn't free it early
        self.lib.app_indicator_set_label(self.ind, (self._clock() if listening else "").encode(), b"")
        self._badge(self.app.updates.update)

    def _badge(self, update) -> None:
        """The Mac's update dot on the top-bar icon: the same icon with an orange dot top right."""
        on = update is not None
        if on == self.badged:
            return
        path = badged_icon(self.icon) if on else self.icon
        if path is None:
            return
        desc = L("知了") + (" · " + LF("有新版本 %@", update.version) if on else "")
        self.lib.app_indicator_set_icon_full(self.ind, path.encode(), desc.encode())
        self.badged = on

    def _clock(self) -> str:
        from datetime import datetime, timezone
        from ..core.support import clock
        s = self.app.store.get(self.app.listen.session_id) if self.app.listen.session_id else None
        return clock((datetime.now(timezone.utc) - s.startedAt).total_seconds()) if s else ""

    def _status(self) -> str:
        return (L("正在听") + " · " + self._clock()) if self.app.listen.listening else L("知了")

    def _detail(self) -> str:
        from ..core import session_store
        s = self.app.store.get(self.app.listen.session_id) if self.app.listen.session_id else None
        if s is None:
            return ""
        return "%s · %d %s" % (session_store.display_title(s), len(s.lines), L("句"))

    def tick(self) -> None:
        """Once a second while listening: the clock in the top bar and the menu's header."""
        if not self.app.listen.listening:
            return
        self.status_item.set_label(self._status())
        if self.detail_item is not None:
            self.detail_item.set_label(self._detail())
        self.lib.app_indicator_set_label(self.ind, self._clock().encode(), b"")


def badged_icon(icon: str) -> str | None:
    """A copy of the app icon (an SVG, 100 units square) with the accent dot over its top right
    corner and a white ring around it, written once under the data folder. The logo itself stays
    in one place (site/icon.svg); this only adds the dot."""
    try:
        with open(icon, encoding="utf-8") as f:
            svg = f.read()
    except OSError:
        return None
    end = svg.rfind("</svg>")
    if end < 0 or 'viewBox="0 0 100 100"' not in svg:
        return None
    dot = '<circle cx="80" cy="20" r="20" fill="#fff"/><circle cx="80" cy="20" r="13" fill="#E8552B"/>'
    from ..core.support import Paths
    import os
    out = os.path.join(Paths.data(), "tray-update.svg")
    try:
        os.makedirs(Paths.data(), exist_ok=True)
        with open(out, "w", encoding="utf-8") as f:
            f.write(svg[:end] + dot + svg[end:])
    except OSError:
        return None
    return out

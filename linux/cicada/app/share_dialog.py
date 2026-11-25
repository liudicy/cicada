"""分享…: a meeting as a link on cicada.indaloop.app (the Mac's ShareViews.swift). Settings, then the
server's review, then the link (and its password) or what the review stopped. A meeting already
shared opens on its link. The network runs on a worker thread; the dialog never blocks the app."""
from __future__ import annotations

import threading
import time

from gi.repository import Gdk, Gio, GLib, Gtk, Pango

from ..core import share
from ..core.share import ShareClient, ShareStore
from ..core.strings import L, LF
from ..core.support import Log, clock
from ..core import session_store
from . import ui

_client = None


def client() -> ShareClient:
    global _client
    if _client is None:
        _client = ShareClient()
    return _client


def can_share(app, s) -> bool:
    """Not while the meeting is still going, nor before an import has its text, nor with nothing in it."""
    has_notes = s.notes is not None and not s.notes.is_empty
    return bool(s.lines or has_notes) and s.id != app.store.live and not s.importing


class ShareDialog:
    def __init__(self, app, s, parent=None):
        self.app, self.s = app, s
        self.has_notes = s.notes is not None and not s.notes.is_empty
        self.step = "settings"
        self.scope = "notes" if self.has_notes else "full"
        self.days = 7
        self.names = False
        self.use_password = False
        self.password = share.make_password()
        self.summary = False
        self.removed: set = set()
        self.drop_notes = False
        self.views = None
        self.confirm = False
        self.copied = None
        self.show_options = False
        self.hits, self.kept, self.record, self.message = [], [], None, ""
        self.busy = False

        d = Gtk.Dialog(transient_for=parent, modal=True)
        d.set_decorated(False)
        d.set_resizable(False)
        ui.classes(d, "endask", "sharesheet")
        d.connect("key-press-event", self._key)
        d.connect("destroy", lambda *_: self._gone())
        self.window = d
        self.body = ui.vbox(16)
        self.body.set_size_request(372, -1)  # 420 with the padding, as on the Mac
        d.get_content_area().pack_start(ui.pad(self.body, 24), True, True, 0)
        r = ShareStore.read(s.id)
        if r is not None and r.expiresAt > time.time():
            self.step, self.record = "done", r
            self._load_views(r)
        self.render()
        d.show_all()

    # Steps

    def render(self) -> None:
        ui.clear(self.body)
        {"settings": self._settings, "working": self._working, "blocked": self._blocked, "done": self._done,
         "failed": self._failed}[self.step]()
        self.body.show_all()
        # Shrink back after a taller step, once the new content has its size.
        GLib.idle_add(lambda: self.window is not None and self.window.resize(1, 1) and False)

    def _header(self, title: str) -> None:
        self.body.pack_start(ui.vbox(4, ui.text(title, 15, "ink", bold=True, wrap=False),
                                     ui.text(session_store.display_title(self.s), 12, "secondary", wrap=False)),
                             False, False, 0)

    def _row(self, title: str, control) -> Gtk.Widget:
        row = ui.hbox(12)
        row.pack_start(ui.text(title, 13, "ink", wrap=False, ellipsize=False), True, True, 0)
        control.set_valign(Gtk.Align.CENTER)
        row.pack_end(control, False, False, 0)
        return row

    def _switch(self, on: bool, changed) -> Gtk.Switch:
        sw = Gtk.Switch()
        sw.set_active(on)
        sw.connect("notify::active", lambda w, _p: changed(w.get_active()))
        return sw

    def _buttons(self, *buttons) -> Gtk.Widget:
        row = ui.hbox(8)
        row.set_halign(Gtk.Align.END)
        for b in buttons:
            row.pack_start(b, False, False, 0)
        return row

    def _settings(self) -> None:
        self._header(L("分享这场会议"))
        content = ui.vbox(8, ui.text(L("内容"), 12, "secondary", bold=True, wrap=False))

        def scope(v):
            self.scope = v
        seg = ui.segmented([("notes", L("只分享纪要")), ("full", L("纪要和双语全文"))], self.scope, scope)
        ui.classes(seg, "big")
        if not self.has_notes:
            seg.get_children()[0].set_sensitive(False)
        content.pack_start(seg, False, False, 0)
        self.body.pack_start(content, False, False, 0)

        go = ui.button(L("生成并复制"), self.go, "darkbtn")
        if self.show_options:
            self._options(go)
        else:
            # The choices already made, in one line; 更改 opens them in place.
            line = ui.hbox(8)
            line.pack_start(ui.text(share.summary(self.use_password, self.days, self.names), 13, "secondary", wrap=False),
                            True, True, 0)

            def change():
                self.show_options = True
                self.render()
            more = ui.button(L("更改"), change, "outline")
            more.set_valign(Gtk.Align.CENTER)
            line.pack_end(more, False, False, 0)
            self.body.pack_start(line, False, False, 0)
        if not self.use_password:
            self.body.pack_start(ui.text(L("内容将上传至 cicada.indaloop.app，拿到链接的人都能看。"), 12, "tertiary",
                                         width_chars=46), False, False, 0)
        go.set_sensitive(not self.use_password or len(self.password) >= 6)
        self.body.pack_start(self._buttons(ui.button(L("取消"), self.close, "outline"), go), False, False, 0)
        go.set_can_default(True)
        self.window.set_default(go)

    def _options(self, go) -> None:
        """Password, expiry, names and the preview's summary, as the Mac lists them once 更改 is pressed."""
        def password(v):
            self.use_password = v
            self.render()
        self.body.pack_start(self._row(L("用密码保护"), self._switch(self.use_password, password)), False, False, 0)
        if self.use_password:
            entry = Gtk.Entry()
            entry.set_text(self.password)
            ui.classes(entry, "mono")

            def typed(e):
                self.password = e.get_text()
                go.set_sensitive(len(self.password) >= 6)
            entry.connect("changed", typed)

            def again():
                entry.set_text(share.make_password())
            row = ui.hbox(8)
            row.pack_start(entry, True, True, 0)
            row.pack_start(ui.button(L("换一个"), again, "outline"), False, False, 0)
            self.body.pack_start(row, False, False, 0)
        days = Gtk.ComboBoxText()
        for n, label in zip(share.DAYS, (L("7 天"), L("30 天"), L("1 年"))):
            days.append(str(n), label)
        days.set_active_id(str(self.days))
        days.connect("changed", lambda c: setattr(self, "days", int(c.get_active_id())))
        self.body.pack_start(self._row(L("有效期"), days), False, False, 0)
        self.body.pack_start(self._row(L("显示说话人名字"), self._switch(self.names, lambda v: setattr(self, "names", v))),
                             False, False, 0)
        if not self.use_password and self.has_notes:
            self.body.pack_start(self._row(L("预览卡显示摘要"), self._switch(self.summary, lambda v: setattr(self, "summary", v))),
                                 False, False, 0)

    def options(self) -> share.Options:
        return share.Options(scope=self.scope, days=self.days, names=self.names,
                             password=self.password if self.use_password else None,
                             summary_in_preview=not self.use_password and self.summary,
                             removed=self.removed, drop_notes=self.drop_notes)

    def go(self) -> None:
        if self.busy:
            return
        self.busy = True
        self.step = "working"
        self.render()
        s, o = self.s, self.options()

        def run():
            out = client().share(s, o)
            GLib.idle_add(lambda: self._finished(out) and False)
        threading.Thread(target=run, name="Share", daemon=True).start()

    def _finished(self, out) -> None:
        self.busy = False
        if self.window is None:
            return
        if out.kind == "shared":
            self.record, self.views, self.confirm = out.record, 0, False
            self._copy(self._message(out.record), "all")
            self.step = "done"
        elif out.kind == "blocked":
            self.hits, self.kept, self.step = out.hits, out.kept, "blocked"
        else:
            self.message, self.step = share.message(out.code or ""), "failed"
        self.render()

    def _working(self) -> None:
        self._header(L("分享这场会议"))
        spin = Gtk.Spinner()
        spin.start()
        row = ui.hbox(10, spin, ui.text(L("正在检查有没有敏感内容…"), 13, "secondary", wrap=False))
        row.set_halign(Gtk.Align.CENTER)
        row.set_valign(Gtk.Align.CENTER)
        row.set_size_request(-1, 80)
        self.body.pack_start(row, False, False, 0)

    # Blocked

    def _left_after(self) -> bool:
        """Would anything be left to share once the flagged parts are out? (A notes-only share whose
        notes were flagged has nothing; the server would refuse an empty document.)"""
        notes_left = self.has_notes and not self.drop_notes and not any(h.get("part") == "notes" for h in self.hits)
        if self.scope != "full":
            return notes_left
        out = self.removed | share.record_lines(self.hits, self.kept)
        return notes_left or any(i not in out and l.src for i, l in enumerate(self.s.lines))

    def _hit_row(self, h) -> Gtk.Widget:
        what = "、".join(share.category(q) for q in h.get("questions") or [])
        if h.get("part") == "notes":
            place, quote = L("纪要"), self.s.notes.summary if self.s.notes else ""
        else:
            lines = sorted(share.record_lines([h], self.kept))
            a = clock(self.s.lines[lines[0]].t) if lines else ""
            b = clock(self.s.lines[lines[-1]].t) if lines else ""
            place = a if a == b else "%s–%s" % (a, b)
            quote = self.s.lines[lines[0]].src if lines else ""
        q = ui.text(quote, 12, "secondary", width_chars=44)
        q.set_lines(2)
        q.set_ellipsize(Pango.EllipsizeMode.END)  # two lines at most
        box = ui.vbox(3, ui.text("%s · %s" % (what, place), 12, "ink", bold=True, width_chars=44), q)
        return ui.panel(ui.pad(box, 10), "sharehit")

    def _blocked(self) -> None:
        icon = ui.icon("dialog-warning-symbolic", 16)
        ui.classes(icon, "link")
        self.body.pack_start(ui.hbox(8, icon, ui.text(L("检测到潜在敏感内容"), 15, "ink", bold=True, wrap=False)), False, False, 0)
        self.body.pack_start(ui.text(L("链接尚未生成。请先核对以下内容："), 12, "secondary"), False, False, 0)
        hits = ui.vbox(8)
        for h in self.hits[:5]:
            hits.pack_start(self._hit_row(h), False, False, 0)
        if len(self.hits) > 5:
            hits.pack_start(ui.text(LF("还有 %lld 处", len(self.hits) - 5), 12, "secondary"), False, False, 0)
        self.body.pack_start(hits, False, False, 0)
        left = self._left_after()
        self.body.pack_start(ui.text(L("去掉后再检查一次；你的记录不会改动。") if left else L("去掉这些内容后就没有可分享的了。"),
                                     12, "tertiary", width_chars=46), False, False, 0)

        def back():
            self.step = "settings"
            self.render()
        buttons = [ui.button(L("返回修改"), back, "outline")]
        if left:
            buttons.append(ui.button(L("去掉这些内容后分享"), self.strip, "darkbtn"))
        self.body.pack_start(self._buttons(*buttons), False, False, 0)

    def strip(self) -> None:
        if self.step != "blocked" or not self._left_after():
            return
        self.removed |= share.record_lines(self.hits, self.kept)
        if any(h.get("part") == "notes" for h in self.hits):
            self.drop_notes = True
        self.go()

    # Done

    def _message(self, r) -> str:
        return share.clipboard_text(r, session_store.display_title(self.s))

    def _copy_control(self, r) -> Gtk.Widget:
        """复制 puts the link and the password on the clipboard as one message; with a password, its
        arrow copies either alone, for whoever sends them apart."""
        def copy(text, what):
            self._copy(text, what)
            self.render()
        main = ui.button(L("复制") if self.copied is None else L("已复制"), lambda: copy(self._message(r), "all"), "outline")
        main.set_valign(Gtk.Align.CENTER)
        if not r.password:
            return main
        menu = Gtk.Menu()
        for label, text, what in ((L("只复制链接"), r.url, "link"), (L("只复制密码"), r.password, "password")):
            item = Gtk.MenuItem(label=label)
            item.connect("activate", lambda _i, t=text, w=what: GLib.idle_add(lambda: copy(t, w) and False))
            menu.append(item)
        menu.show_all()
        arrow = Gtk.MenuButton()
        arrow.set_popup(menu)
        arrow.add(ui.icon("pan-down-symbolic", 12))
        ui.classes(arrow, "outline", "arrow")
        box = ui.hbox(0, main, arrow)
        ui.classes(box, "linked", "copybtn")
        box.set_valign(Gtk.Align.CENTER)
        return box

    def _done(self) -> None:
        r = self.record
        self._header((L("链接和密码已复制") if r.password else L("链接已复制")) if self.copied == "all" else L("已分享"))
        url = ui.text(r.url, 12, "ink", wrap=False, selectable=True)
        url.set_ellipsize(Pango.EllipsizeMode.MIDDLE)
        field = ui.vbox(4, url)
        if r.password:
            field.pack_start(ui.text(LF("密码：%@", r.password), 12, "secondary", wrap=False, selectable=True), False, False, 0)
        for l in field.get_children():
            ui.classes(l, "mono")
        row = ui.hbox(8)
        row.pack_start(ui.panel(ui.pad(field, 6, 8), "sharefield"), True, True, 0)
        row.pack_start(self._copy_control(r), False, False, 0)
        self.body.pack_start(row, False, False, 0)
        status = LF("%lld 天后失效", r.days_left())
        if self.views is not None:
            status += " · " + LF("打开 %lld 次", self.views)
        self.body.pack_start(ui.text(status, 12, "secondary", wrap=False), False, False, 0)
        self.body.pack_start(Gtk.Separator(), False, False, 0)
        if self.confirm:
            def keep():
                self.confirm = False
                self.render()
            self.body.pack_start(ui.vbox(6, ui.text(L("取消后链接立即失效"), 13, "ink", bold=True, wrap=False),
                                         ui.text(L("已查看过的人可能留有副本。"), 12, "tertiary"),
                                         self._buttons(ui.button(L("暂不取消"), keep, "outline"),
                                                       ui.button(L("取消分享"), self.revoke, "darkbtn"))), False, False, 0)
        else:
            def ask():
                self.confirm = True
                self.render()
            row = ui.hbox(8)
            row.pack_start(ui.button(L("取消分享"), ask, "outline"), False, False, 0)
            done = ui.button(L("完成"), self.close, "darkbtn")
            row.pack_end(done, False, False, 0)
            row.pack_end(ui.button(L("在浏览器中打开"), lambda: self._open(r.url), "outline"), False, False, 0)
            self.body.pack_start(row, False, False, 0)

    def revoke(self) -> None:
        if self.busy or self.record is None:
            return
        self.busy = True
        r, sid = self.record, self.s.id

        def run():
            ok = client().revoke(r, sid)

            def after():
                self.busy = False
                if self.window is None:
                    return False
                if ok:
                    self.close()
                else:
                    self.message, self.step = share.message("network"), "failed"
                    self.render()
                return False
            GLib.idle_add(after)
        threading.Thread(target=run, name="Share", daemon=True).start()

    def _load_views(self, r) -> None:
        sid = self.s.id

        def run():
            st = client().stats([r.id]).get(r.id)

            def after():
                if st is None or self.window is None:
                    return False
                if st.get("state") != "live":
                    ShareStore.remove(sid)
                    self.step, self.record = "settings", None
                else:
                    self.views = st.get("views", 0)
                self.render()
                return False
            GLib.idle_add(after)
        threading.Thread(target=run, name="Share", daemon=True).start()

    def _failed(self) -> None:
        self._header(L("没有分享出去"))
        self.body.pack_start(ui.text(self.message, 13, "ink", width_chars=46), False, False, 0)
        self.body.pack_start(self._buttons(ui.button(L("关闭"), self.close, "outline"),
                                           ui.button(L("重试"), self.go, "darkbtn")), False, False, 0)

    # Parts

    def _copy(self, text: str, what: str) -> None:
        Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD).set_text(text, -1)
        self.copied = what

    def _open(self, url: str) -> None:
        try:
            Gio.AppInfo.launch_default_for_uri(url, None)
        except GLib.Error as e:
            Log.d("share: could not open the browser (%s)" % e.message)

    def _key(self, _w, event) -> bool:
        if event.keyval == Gdk.KEY_Escape:
            if self.step == "blocked":
                self.step = "settings"
                self.render()
            elif self.step != "working":
                self.close()
            return True
        return False

    def _gone(self) -> None:
        self.window = None
        if getattr(self.app, "share_dialog", None) is self:
            self.app.share_dialog = None

    def close(self) -> None:
        if self.window is not None:
            self.window.destroy()

    def state(self) -> dict:
        """For the control socket: where the dialog is and what it shows."""
        r = self.record
        return {"step": self.step, "session": self.s.id, "scope": self.scope, "days": self.days, "names": self.names,
                "password": self.use_password, "summary": self.summary, "busy": self.busy, "confirm": self.confirm,
                "hits": self.hits, "kept": self.kept, "removed": sorted(self.removed), "dropNotes": self.drop_notes,
                "left": self._left_after() if self.step == "blocked" else None, "message": self.message or None,
                "url": r.url if r else None, "views": self.views, "options": self.show_options, "copied": self.copied,
                "clipboard": Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD).wait_for_text() if self.copied else None}


def open_for(app, s, parent=None) -> ShareDialog:
    """The one share dialog: a new record replaces whatever was open."""
    old = getattr(app, "share_dialog", None)
    if old is not None:
        old.close()
    app.share_dialog = ShareDialog(app, s, parent)
    return app.share_dialog

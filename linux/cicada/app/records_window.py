"""会议记录, the main window: a header bar with 开始听 (or 正在听 · 结束) and the app menu; the
meetings grouped by day and searchable on the left; the chosen meeting's notes and its bilingual
transcript side by side on the right (stacked when the window is narrow). Export and delete answer
with a toast; delete can be undone for a few seconds before the record is really removed."""
from __future__ import annotations

import os
import time
from datetime import datetime, timedelta, timezone

from gi.repository import Gdk, Gio, GLib, Gtk

from ..core import session_store, speakers
from ..core.strings import L, LF
from ..core.support import SOURCES, TARGETS, Log, clock
from . import ui

LANG_NAMES = {code: name for name, code in SOURCES + TARGETS}


def lang_name(code: str) -> str:
    return LANG_NAMES.get(code) or LANG_NAMES.get(code.split("-")[0], code)


class RecordsWindow(Gtk.Window):
    def __init__(self, app):
        super().__init__(title=L("会议记录") + " · " + L("知了"))
        self.app = app
        self.set_default_size(1180, 760)
        self.set_size_request(720, 480)
        self.set_position(Gtk.WindowPosition.CENTER)
        self.set_wmclass("cicada", "Cicada")
        self.connect("delete-event", lambda *_: self.hide() or self.app.records_closed() or True)
        self.selected = None
        self.pending_delete = None  # a record deleted but still undoable
        self.query = ""
        self.mode = "both"  # transcript: "both" or "dst"
        self._both = False  # the shown meeting has lines I said (同声传译): rows name 你 / 对方
        self._nums, self._vnums, self._shown, self._speaker_key = {}, {}, {}, None  # 说话人识别 on show
        self._queued = False

        bar = Gtk.HeaderBar()
        bar.set_show_close_button(True)
        # The title sits over the sidebar; the middle holds the listening capsule, as on the Mac.
        # A stack, not a box: the pill cross-fades and changes width between states over 0.35 s, as
        # the Mac's spring does, instead of jumping.
        self.listen_box = Gtk.Stack()
        self.listen_box.set_transition_type(Gtk.StackTransitionType.CROSSFADE)
        self.listen_box.set_transition_duration(350)
        self.listen_box.set_hhomogeneous(False)
        self.listen_box.set_vhomogeneous(False)
        self.listen_box.set_interpolate_size(True)
        self.listen_box.set_valign(Gtk.Align.CENTER)
        bar.set_custom_title(self.listen_box)
        ui.classes(bar, "cicada", "records-bar")
        self.bar_side = ui.panel(ui.pad(ui.text(L("会议记录"), 13, "heading", bold=True, wrap=False), 0, 0, 0, 18), "sidebar-top")
        self.bar_side.set_size_request(260, -1)
        self.bar_side.get_child().set_valign(Gtk.Align.CENTER)
        self.bar_side.set_no_show_all(True)  # with the sidebar: hidden while there are no meetings
        bar.pack_start(self.bar_side)
        bar.pack_end(self._app_menu())
        self.set_titlebar(bar)

        overlay = Gtk.Overlay()
        self.toasts = ui.Toasts(overlay)
        root = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        ui.classes(root, "sheet")
        overlay.add(root)
        self.add(overlay)

        # Sidebar
        side = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.sidebar = ui.panel(side, "sidebar")
        self.sidebar.set_size_request(260, -1)
        self.sidebar.set_no_show_all(True)  # fill() decides: hidden while there are no meetings
        self.search = Gtk.SearchEntry()
        self.search.set_placeholder_text(L("搜索标题和对话"))
        self.search.connect("search-changed", self._searched)
        ui.classes(self.search, "search")
        # "Ctrl F" at the field's right end while it's empty, as the Mac shows ⌘F; the clear icon
        # takes its place once something is typed.
        search_box = Gtk.Overlay()
        search_box.add(self.search)
        hint = ui.text("Ctrl F", 11, "secondary", wrap=False, ellipsize=False)
        hint.set_halign(Gtk.Align.END)
        hint.set_valign(Gtk.Align.CENTER)
        hint.set_margin_end(10)
        search_box.add_overlay(hint)
        search_box.set_overlay_pass_through(hint, True)
        self.search.connect("changed", lambda e: hint.set_visible(not e.get_text()))
        ui.pad(search_box, 2, 10, 8, 10)
        side.pack_start(search_box, False, False, 0)
        left_scroll = Gtk.ScrolledWindow()
        left_scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        self.list = Gtk.ListBox()
        self.list.set_selection_mode(Gtk.SelectionMode.SINGLE)
        self.list.connect("row-selected", self._row_selected)
        self.list.set_header_func(self._header)
        left_scroll.add(self.list)
        side.pack_start(left_scroll, True, True, 0)
        side.show_all()
        root.pack_start(self.sidebar, False, False, 0)

        # Content
        self.right = Gtk.ScrolledWindow()
        self.right.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        self.content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        ui.pad(self.content, 6, 36, 28, 36)
        self.right.add(self.content)
        ui.classes(self.right, "sheet")
        root.pack_start(self.right, True, True, 0)
        self.columns = None
        self.connect("size-allocate", self._resized)
        self.connect("key-press-event", self._key)
        self._tick = GLib.timeout_add_seconds(1, self._clock)
        self.fill()

    def _key(self, _w, event) -> bool:
        """Ctrl+F searches (Ctrl+Q and Ctrl+, are app-wide accelerators)."""
        if event.state & Gdk.ModifierType.CONTROL_MASK and Gdk.keyval_name(event.keyval) in ("f", "F"):
            self.search.grab_focus()
            return True
        return False

    # Header bar

    def _app_menu(self) -> Gtk.MenuButton:
        menu = Gtk.Menu()
        for label, action in ((L("显示实时纪要"), self.app.show_notes), (L("设置…"), self.app.show_settings),
                              (L("新手引导"), self.app.show_onboarding), (None, None), (LF("退出 %@", L("知了")), self.app.quit)):
            if label is None:
                menu.append(Gtk.SeparatorMenuItem())
                continue
            item = Gtk.MenuItem(label=label)
            item.connect("activate", lambda _i, a=action: a())
            menu.append(item)
        menu.show_all()
        b = Gtk.MenuButton()
        b.set_popup(menu)
        b.add(ui.icon("open-menu-symbolic"))
        b.set_tooltip_text(L("主菜单"))
        ui.classes(b, "iconbtn")
        return b

    def _fill_listen_box(self) -> None:
        """The listening switch, led by the logo (ListenPill.swift): a white capsule while idle
        (logo, 知了, 开始听 or 会议已自动结束, the shortcut), an ink one while listening (the breathing
        logo, 正在听, the level, the time, and 结束), and while the meeting is about to end by itself
        a countdown ring round the logo, why, the seconds left and 继续记录. Built once per state;
        the time, the level and the countdown update in place."""
        app = self.app
        listen = app.listen
        if listen.listening:
            state = "ending" if app.ending is not None else "live"
        else:
            state = "auto" if app.auto_ended else "setup" if app.setup_left else "idle"
        key = (state, app.ending.reason.kind + app.ending.reason.name if state == "ending" else
               str(app.setup_left) if state == "setup" else "")
        if key != getattr(self, "_pill_state", None):
            first = getattr(self, "_pill_state", None) is None
            self._pill_state = key
            stack = self.listen_box
            old = stack.get_children()
            box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
            box.set_valign(Gtk.Align.CENTER)
            box.set_halign(Gtk.Align.CENTER)
            if state == "setup":
                # Not set up yet: the capsule says how much is left and opens the onboarding there.
                b = Gtk.Button()
                inner = ui.hbox(9, self._logo(22), ui.text(L("知了"), 13, "ink", bold=True, wrap=False, ellipsize=False),
                                ui.panel(Gtk.Box(), "pillsep"),
                                ui.text(LF("还差 %@ 步", app.setup_left), 13, "link", bold=True, wrap=False, ellipsize=False),
                                ui.text(L("继续设置"), 11, "secondary", wrap=False, ellipsize=False))
                sep = inner.get_children()[2]
                sep.set_size_request(1, 14)
                sep.set_valign(Gtk.Align.CENTER)
                b.add(inner)
                ui.classes(b, "listenpill")
                b.connect("clicked", lambda *_: self.app.show_onboarding())
                b.get_accessible().set_name(L("继续设置"))
                box.pack_start(b, False, False, 0)
            elif state in ("idle", "auto"):
                b = Gtk.Button()
                inner = ui.hbox(9, self._logo(22), ui.text(L("知了"), 13, "ink", bold=True, wrap=False, ellipsize=False),
                                ui.panel(Gtk.Box(), "pillsep"),
                                ui.text(L("会议已自动结束") if state == "auto" else L("开始听"), 13, "ink", bold=True,
                                        wrap=False, ellipsize=False))
                sep = inner.get_children()[2]
                sep.set_size_request(1, 14)
                sep.set_valign(Gtk.Align.CENTER)
                keys = self._shortcut_hint()
                if keys:
                    inner.pack_start(ui.text(keys, 11, "secondary", wrap=False, ellipsize=False), False, False, 0)
                b.add(inner)
                ui.classes(b, "listenpill")
                b.connect("clicked", lambda *_: self.app.toggle_listening())
                b.get_accessible().set_name(L("开始听"))
                box.pack_start(b, False, False, 0)
            elif state == "live":
                show = Gtk.Button()
                inner = ui.hbox(10, self._breathing_logo(22), ui.text(L("正在听"), 13, "ink", bold=True, wrap=False, ellipsize=False))
                self._bars = []
                meter = ui.hbox(2)
                meter.set_valign(Gtk.Align.CENTER)
                for _ in range(8):
                    bar = ui.panel(Gtk.Box(), "meterbar")
                    bar.set_size_request(3, 3)
                    bar.set_valign(Gtk.Align.CENTER)
                    meter.pack_start(bar, False, False, 0)
                    self._bars.append(bar)
                self._levels = [0.0] * 8
                inner.pack_start(meter, False, False, 0)
                self._pill_time = ui.classes(ui.text("", 13, "ink", wrap=False, ellipsize=False), "tnum")
                inner.pack_start(self._pill_time, False, False, 0)
                show.add(inner)
                ui.classes(show, "pillshow")
                show.set_tooltip_text(L("显示实时纪要") if self.app.settings.view == "notes" else L("显示字幕条"))
                show.connect("clicked", lambda *_: self.app.show_notes())
                end = ui.button(L("结束"), lambda: self.app.request_stop(self), "pillend")
                end.set_valign(Gtk.Align.CENTER)
                end.get_accessible().set_name(L("结束会议"))
                box.pack_start(self._live_pill(show, end), False, False, 0)
                GLib.timeout_add(80, self._meter)
            else:
                show = Gtk.Button()
                ring = Gtk.Overlay()
                self._ring = Gtk.Image()
                self._ring_total = max(1.0, app.ending.deadline - time.time())
                ring.add(self._ring)
                logo = self._logo(16)
                logo.set_halign(Gtk.Align.CENTER)
                logo.set_valign(Gtk.Align.CENTER)
                ring.add_overlay(logo)
                ring.set_valign(Gtk.Align.CENTER)
                self._pill_left = ui.classes(ui.text("", 13, "countdown", wrap=False, ellipsize=False), "tnum")
                inner = ui.hbox(10, ring, ui.text(app.ending_title(app.ending), 13, "ink", bold=True, wrap=False, ellipsize=False),
                                self._pill_left)
                show.add(inner)
                ui.classes(show, "pillshow")
                show.set_tooltip_text(L("显示实时纪要") if self.app.settings.view == "notes" else L("显示字幕条"))
                show.connect("clicked", lambda *_: self.app.show_notes())
                keep = ui.button(L("继续记录"), self.app.keep_recording, "pillkeep")
                keep.set_valign(Gtk.Align.CENTER)
                box.pack_start(self._live_pill(show, keep, ending=True), False, False, 0)
            box.show_all()
            stack.add(box)
            # The first state appears as is; later ones cross-fade (and the old one goes once faded).
            stack.set_transition_type(Gtk.StackTransitionType.NONE if first else Gtk.StackTransitionType.CROSSFADE)
            stack.set_visible_child(box)

            def drop():
                for c in old:
                    if c.get_parent() is stack:
                        c.destroy()
                return False
            GLib.timeout_add(400, drop)
        if state == "live":
            s = self.app.store.get(listen.session_id) if listen.session_id else None
            secs = (datetime.now(timezone.utc) - s.startedAt).total_seconds() if s else 0
            ui.retext(self._pill_time, clock(secs))
        elif state == "ending":
            left = app.ending_left(app.ending)
            ui.retext(self._pill_left, LF("%lld 秒后结束", left))
            self._ring.set_from_pixbuf(ui.ring_pixbuf(left / self._ring_total))

    def _live_pill(self, show: Gtk.Widget, button: Gtk.Widget, ending: bool = False) -> Gtk.Widget:
        """The ink capsule: 32 px high, 5 px in on the left and 4 px round the rest (ListenPill).
        A plain box, not an EventBox: it honours CSS padding and has no window of its own, so the
        breathing rings may run past its edge, as they do on the Mac."""
        pill = ui.classes(ui.hbox(10, show, button), "listenpill", "live", "ending" if ending else "on")
        pill.set_valign(Gtk.Align.CENTER)
        return pill

    def _breathing_logo(self, px: int) -> Gtk.Widget:
        """BreathingMark: two rings swell out of the logo in turn while Cicada listens."""
        # Plain boxes, not panels: an EventBox's own window would clip the ring drawn outside it.
        inner = ui.classes(ui.hbox(0, self._logo(px)), "breathemark")
        outer = ui.classes(ui.hbox(0, inner), "breathemark", "late")
        outer.set_valign(Gtk.Align.CENTER)
        outer.set_halign(Gtk.Align.CENTER)
        return outer

    def _logo(self, px: int) -> Gtk.Widget:
        from .main import icon_path
        path = icon_path()
        if path:
            try:
                from gi.repository import GdkPixbuf
                # A pixbuf, not a cairo surface: stock Ubuntu has no python3-gi-cairo.
                return Gtk.Image.new_from_pixbuf(GdkPixbuf.Pixbuf.new_from_file_at_size(path, px, px))
            except GLib.Error:
                pass
        return ui.dot(True)

    def _shortcut_hint(self) -> str:
        """The start / stop shortcut, when one is set ("Super ⇧ C", as the Mac shows ⌘R)."""
        from .settings_window import SHORTCUTS, gnome_shortcut
        if not gnome_shortcut("toggle"):
            return ""
        return SHORTCUTS["toggle"][2].replace(" + Shift + ", " ⇧ ")

    def _meter(self) -> bool:
        """The level of what Cicada hears, newest on the right (LevelMeter): 8 bars, 15 px high."""
        if self._pill_state[0] != "live" or not self.app.listen.listening:
            return False
        self._levels = (self._levels + [ui.loudness(self.app.listen.level)])[-8:]
        for bar, v in zip(self._bars, self._levels):
            bar.set_size_request(3, max(3, int(v * 15)))
        return True

    def _clock(self) -> bool:
        if self.get_visible() and self.app.listen.listening:
            self._fill_listen_box()
        return True

    # List

    def refresh(self) -> None:
        if self._queued:
            return
        self._queued = True

        def run():
            self._queued = False
            if self.get_visible():
                self.fill()
            return False
        GLib.idle_add(run)

    def _visible_sessions(self) -> list:
        q = self.query.strip().lower()
        out = []
        for s in self.app.store.all():
            if s.id == self.pending_delete:
                continue
            if q and q not in session_store.display_title(s).lower() and not any(
                    q in l.src.lower() or q in (l.dst or "").lower() for l in s.lines):
                continue
            out.append(s)
        return out

    def _group(self, s) -> str:
        day = s.startedAt.astimezone().date()
        today = datetime.now().date()
        if day == today:
            return L("今天")
        if day == today - timedelta(days=1):
            return L("昨天")
        return L("更早")

    def _header(self, row, before) -> None:
        g = getattr(row, "group", None)
        if before is None or getattr(before, "group", None) != g:
            l = ui.text(g, 11, "group-label", bold=True, wrap=False)
            ui.pad(l, 12 if before is not None else 4, 20, 4, 20)
            row.set_header(l)
        else:
            row.set_header(None)

    def fill(self) -> None:
        self._fill_listen_box()
        listen = self.app.listen
        sessions = self._visible_sessions()
        everything = [s for s in self.app.store.all() if s.id != self.pending_delete]
        self._filling = True
        for row in self.list.get_children():
            self.list.remove(row)
        for s in sessions:
            live = listen.listening and listen.session_id == s.id
            when = s.startedAt.astimezone()
            start = "%02d:%02d" % (when.hour, when.minute) if self._group(s) != L("更早") else session_store._local_date(s.startedAt, L("M月d日"))
            meta = (L("正在听") + " · " + start) if live else start + " · " + clock(s.duration)
            title_row = ui.hbox(8)
            if live:
                title_row.pack_start(ui.breathing_dot(small=True), False, False, 0)
            title_row.pack_start(ui.text(session_store.display_title(s), 13, "ink", wrap=False), True, True, 0)
            box = ui.vbox(1, title_row, ui.text(meta, 11, "accent" if live else "tertiary", wrap=False))
            ui.pad(box, 7, 10)
            row = Gtk.ListBoxRow()
            row.add(box)
            row.session_id = s.id
            row.group = self._group(s)
            self.list.add(row)
        self.list.show_all()
        self.sidebar.set_visible(bool(everything))
        self.bar_side.set_visible(bool(everything))
        self.bar_side.get_child().show_all()
        if not sessions:
            self.selected = None if not everything else self.selected
        elif self.selected not in [s.id for s in sessions]:
            self.selected = sessions[0].id
        for row in self.list.get_children():
            if row.session_id == self.selected:
                self.list.select_row(row)
        self._filling = False
        self.show_detail(empty=not everything, no_match=bool(everything) and not sessions)

    def _searched(self, entry) -> None:
        self.query = entry.get_text()
        self.fill()

    def _row_selected(self, _list, row) -> None:
        if row is None or getattr(self, "_filling", False):
            return
        if row.session_id != self.selected:
            self.selected = row.session_id
            self.show_detail()
            self.right.get_vadjustment().set_value(0)

    # Detail

    def _resized(self, _w, alloc) -> None:
        if self.columns is not None:
            want = Gtk.Orientation.HORIZONTAL if alloc.width >= 1000 else Gtk.Orientation.VERTICAL
            if self.columns.get_orientation() != want:
                self.columns.set_orientation(want)
                self.columns.set_homogeneous(want == Gtk.Orientation.HORIZONTAL)

    def _setup_page(self) -> Gtk.Widget:
        """No meetings and not set up yet (Windows' Welcome › Checklist): what is left, ticked by what
        really happened, each step opening the onboarding where it is. 同声传译 is optional."""
        app = self.app
        key, audio, sample = app.setup_done
        first = 0 if not key else 1 if not audio else 2 if not sample else 3
        page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        page.set_halign(Gtk.Align.CENTER)
        page.set_valign(Gtk.Align.CENTER)
        page.set_vexpand(True)
        mark = self._logo(72)
        mark.set_halign(Gtk.Align.CENTER)
        page.pack_start(mark, False, False, 0)
        t = ui.text(LF("还差 %@ 步就能用", app.setup_left), 26, "heading", bold=True, wrap=False)
        t.set_halign(Gtk.Align.CENTER)
        page.pack_start(ui.gap(t, 26), False, False, 0)
        line = ui.text(L("知了把电脑里放出来的会议声音变成字幕和纪要。"), 15, "secondary", wrap=False)
        line.set_halign(Gtk.Align.CENTER)
        page.pack_start(ui.gap(line, 8), False, False, 0)
        from .settings_window import SHORTCUTS, gnome_shortcut
        speak = (LF("按 %@ 说话，对方听到翻译后的声音", SHORTCUTS["speak"][2].replace(" + Shift + ", " ⇧ "))
                 if gnome_shortcut("speak") else L("点纪要窗的麦克风说话，对方听到翻译后的声音"))
        steps = ((L("接上 Ling"), L("只存在这台电脑上（只有你的账户能读）") if key else L("识别、翻译和纪要都靠它，约 1 分钟"), key),
                 (L("听一下电脑里的声音"), L("放一段测试声音，看音量条动起来"), audio),
                 (L("看看效果"), L("一段 9 秒的英文会议，字幕和纪要一句句出来"), sample),
                 (L("同声传译"), L("以后在设置 › 同声传译里打开") if app.settings.speakLater and not app.settings.speakEnabled
                  else speak, app.settings.speakEnabled))
        rows = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        for i, (title, detail, done) in enumerate(steps):
            if i:
                sep = ui.panel(Gtk.Box(), "hair")
                sep.set_size_request(-1, 1)
                rows.pack_start(sep, False, False, 0)
            now = i == first
            disc = ui.panel(ui.icon("object-select-symbolic", 13) if done else
                            ui.text(str(i + 1), 12, "", bold=True, wrap=False, ellipsize=False),
                            "setupdisc", "done" if done else "now" if now else "")
            disc.set_size_request(26, 26)
            disc.get_child().set_halign(Gtk.Align.CENTER)
            disc.get_child().set_valign(Gtk.Align.CENTER)
            disc.set_valign(Gtk.Align.CENTER)
            head = ui.hbox(8, ui.text(title, 14, "secondary" if done else "ink", bold=not done, wrap=False))
            head.set_halign(Gtk.Align.START)
            if i == 3:
                head.pack_start(ui.panel(ui.text(L("可选"), 11, "secondary", wrap=False, ellipsize=False), "setuptag"), False, False, 0)
            sub = ui.text(detail, 12, "secondary", width_chars=40)
            sub.set_halign(Gtk.Align.START)
            sub.set_xalign(0)
            texts = ui.vbox(1, head, sub)
            texts.set_valign(Gtk.Align.CENTER)
            row = ui.hbox(14, disc)
            row.pack_start(texts, True, True, 0)  # filled, so the words start at the left of every row
            action = None
            if now:
                action = ui.button(L("继续设置"), lambda n=i: app.show_onboarding(n), "darkbtn")
            elif i == 3 and not done and not app.settings.speakLater:
                action = ui.button(L("以后再说"), self._speak_later, "outline")
            if action is not None:
                action.set_valign(Gtk.Align.CENTER)
                row.pack_end(action, False, False, 0)
            rows.pack_start(ui.pad(row, 14, 0), False, False, 0)
        card = ui.panel(ui.pad(rows, 2, 18), "setupcard")
        card.set_size_request(460, -1)
        page.pack_start(ui.gap(card, 28), False, False, 0)
        page.set_margin_bottom(40)
        return page

    def _speak_later(self) -> None:
        self.app.settings.speakLater = True
        self.app.settings.save()
        self.app.changed()

    def _welcome_page(self) -> Gtk.Widget:
        """No meetings yet, set up (Views.swift › welcome): the logo, one line, 开始听 and the sample."""
        page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        page.set_halign(Gtk.Align.CENTER)
        page.set_valign(Gtk.Align.CENTER)
        page.set_vexpand(True)
        mark = self._logo(72)
        mark.set_halign(Gtk.Align.CENTER)
        page.pack_start(mark, False, False, 0)
        t = ui.text(L("还没有会议"), 26, "heading", bold=True, wrap=False)
        t.set_halign(Gtk.Align.CENTER)
        page.pack_start(ui.gap(t, 26), False, False, 0)
        line = ui.text(L("打开会议或视频，开始听后，每一场都会存在这里。"), 15, "secondary", wrap=False)
        line.set_halign(Gtk.Align.CENTER)
        page.pack_start(ui.gap(line, 8), False, False, 0)
        inner = ui.hbox(10, ui.dot(True), ui.text(L("开始听"), 15, "", bold=True, wrap=False, ellipsize=False))
        keys = self._shortcut_hint()
        if keys:
            cap = ui.panel(ui.pad(ui.text(keys, 12, "", wrap=False, ellipsize=False), 0, 6, 1, 6), "ctakeys")
            cap.set_valign(Gtk.Align.CENTER)
            inner.pack_start(cap, False, False, 0)
        start = Gtk.Button()
        start.add(inner)
        ui.classes(start, "ctapill")
        start.connect("clicked", lambda *_: self.app.toggle_listening())
        start.get_accessible().set_name(L("开始听"))
        start.set_halign(Gtk.Align.CENTER)
        page.pack_start(ui.gap(start, 30), False, False, 0)
        sample = ui.button(L("先听一段示例"), self.app.play_sample, "quietbtn greytext")
        sample.set_halign(Gtk.Align.CENTER)
        page.pack_start(ui.gap(sample, 10), False, False, 0)
        page.set_margin_bottom(40)
        return page

    def _status_page(self, icon_name, title, body, actions) -> Gtk.Widget:
        page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        page.set_halign(Gtk.Align.CENTER)
        page.set_valign(Gtk.Align.CENTER)
        page.set_vexpand(True)
        page.pack_start(ui.icon_tile(icon_name, 80, 36, "grey"), False, False, 0)
        t = ui.text(title, 17, "heading", bold=True, wrap=False)
        t.set_halign(Gtk.Align.CENTER)
        page.pack_start(ui.gap(t, 22), False, False, 0)
        if body:
            b = ui.text(body, 13, "secondary", width_chars=44)
            b.set_justify(Gtk.Justification.CENTER)
            b.set_halign(Gtk.Align.CENTER)
            page.pack_start(ui.gap(b, 8), False, False, 0)
        if actions:
            row = ui.hbox(10, *actions)
            row.set_halign(Gtk.Align.CENTER)
            page.pack_start(ui.gap(row, 22), False, False, 0)
        page.set_margin_top(120)
        return page

    def show_detail(self, empty: bool = False, no_match: bool = False) -> None:
        started = time.monotonic()
        self._show_detail(empty, no_match)
        Log.d("records: detail in %d ms" % ((time.monotonic() - started) * 1000))

    def _show_detail(self, empty: bool = False, no_match: bool = False) -> None:
        d = self.content
        keep = self.right.get_vadjustment().get_value()
        if empty or no_match:
            ui.clear(d)
            self.columns = None
            self._built_key = None
        if empty and self.app.setup_left:
            d.pack_start(self._setup_page(), True, True, 0)
            d.show_all()
            return
        if empty:
            d.pack_start(self._welcome_page(), True, True, 0)
            if self.app.tray is not None:  # where 知了 is once this window is closed
                hint = ui.text(L("关掉窗口后，知了在顶栏右上角"), 12, "secondary", wrap=False)
                hint.set_halign(Gtk.Align.END)
                d.pack_end(ui.pad(hint, 0, 18, 14, 0), False, False, 0)
            d.show_all()
            return
        if no_match:
            d.pack_start(self._status_page("system-search-symbolic", LF("没有找到“%@”", self.query.strip()), "", []), True, True, 0)
            d.show_all()
            return
        s = self.app.store.get(self.selected) if self.selected else None
        if s is None:
            ui.clear(d)
            self.columns = None
            self._built_key = None
            d.show_all()
            return
        live = self.app.listen.listening and self.app.listen.session_id == s.id
        key = (s.id, self.mode, live)
        if getattr(self, "_built_key", None) == key and self.columns is not None:
            self._update_detail(s, live)
            return
        ui.clear(d)
        self._built_key = key

        # Title, meta, actions
        top = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=16)
        left = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=3)
        self.title_label = ui.text(session_store.display_title(s), 22, "heading", bold=True, selectable=True, width_chars=36)
        left.pack_start(self.title_label, False, False, 0)
        self.meta_label = ui.text(self._meta(s, live), 12, "tertiary", wrap=False)
        left.pack_start(self.meta_label, False, False, 0)
        top.pack_start(left, True, True, 0)
        actions = ui.hbox(8)
        actions.set_valign(Gtk.Align.START)
        actions.pack_start(ui.button(L("导出…"), lambda: self.export(s), "outline", "document-save-symbolic"), False, False, 0)
        actions.pack_start(self._more_menu(s), False, False, 0)
        top.pack_end(actions, False, False, 0)
        d.pack_start(top, False, False, 0)

        # Notes | transcript
        self.columns = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=40)
        self.columns.set_homogeneous(True)
        self.columns.set_margin_top(24)
        self.notes_col = self._notes_column(s, live)
        self._notes_key = self._notes_state(s, live)
        self.columns.pack_start(self.notes_col, True, True, 0)
        self.columns.pack_start(self._transcript_column(s), True, True, 0)
        d.pack_start(self.columns, False, False, 0)
        self._resized(self, self.get_allocation())
        d.show_all()
        GLib.idle_add(lambda: self.right.get_vadjustment().set_value(keep) and False)

    def _meta(self, s, live) -> str:
        langs = ""
        if s.lines:
            src, dst = s.lines[0].srcLang, s.lines[0].dstLang
            langs = " · " + (lang_name(src) if src == dst else lang_name(src) + " → " + lang_name(dst))
        return "%s · %s · %d %s%s" % (session_store._local_date(s.startedAt, L("M月d日 HH:mm")), L("正在听") if live else clock(s.duration),
                                      len(s.lines), L("句"), langs)

    def _notes_state(self, s, live):
        return (id(s.notes), s.notes.updatedAt if s.notes else None, self.app.notes.working_id == s.id, live)

    def _update_detail(self, s, live) -> None:
        """The same meeting changed (a new line while listening, new notes, a rename): touch only what
        changed. Rebuilding a long transcript on every line froze the window for half a second."""
        if (not self._both and s.sourceFile is None and any(l.speaker == "me" for l in s.lines)) or \
                self._speaker_state_key(s) != self._speaker_key:
            # My first sentence, or voices newly on show / renamed / merged: every row may now say
            # someone else, so a full rebuild (the same key would come straight back here).
            self._built_key = None
            self.show_detail()
            return
        ui.retext(self.title_label, session_store.display_title(s))
        ui.retext(self.meta_label, self._meta(s, live))
        state = self._notes_state(s, live)
        if state != self._notes_key:
            self._notes_key = state
            new = self._notes_column(s, live)
            self.columns.remove(self.notes_col)
            self.notes_col.destroy()
            self.notes_col = new
            self.columns.pack_start(new, True, True, 0)
            self.columns.reorder_child(new, 0)
            new.show_all()
        self._nums = speakers.numbers(s.lines) if self._vnums else {}
        starts = speakers.run_starts(s.lines, self._nums)
        for i, l in enumerate(s.lines[:len(self._rows)]):
            if self._rows[i][0] != self._row_key(l, l.id in starts):
                old_row = self._rows[i][1]
                k, row = self._row(l, l.id in starts)
                self.transcript.remove(old_row)
                old_row.destroy()
                self.transcript.pack_start(row, False, False, 0)
                self.transcript.reorder_child(row, i + 1)  # after the header
                row.show_all()
                self._rows[i] = (k, row)
        self._more_rows()

    def _more_menu(self, s) -> Gtk.MenuButton:
        """The record as it is when pressed: 恢复自动标题 only for a renamed meeting the notes have
        named, 删除 off for the live one (the Mac's context menu). The items stay; a menu filled
        while it opens pops up empty, so they are updated on the press, before it opens."""
        menu = Gtk.Menu()
        sid = s.id

        def current():
            return self.app.store.get(sid)
        items = []
        for label, action in ((L("重命名…"), lambda: current() and self.rename(current())),
                              (L("恢复自动标题"), lambda: self.app.store.rename(sid, "")),
                              (L("删除"), lambda: current() and self.delete(current()))):
            item = Gtk.MenuItem(label=label)
            item.connect("activate", lambda _i, a=action: a())
            menu.append(item)
            items.append(item)
        menu.show_all()

        def update(*_):
            cur = current()
            renamed = cur is not None and (cur.renamed if cur.renamed is not None else not cur.title.startswith("会议 "))
            items[1].set_visible(bool(renamed and cur.notes is not None and cur.notes.title))
            items[2].set_sensitive(sid != self.app.store.live)
            return False
        update()
        b = Gtk.MenuButton()
        b.set_popup(menu)
        b.connect("button-press-event", update)
        b.connect("toggled", update)  # the keyboard opens it too; the items are already right by then
        b.add(ui.icon("view-more-symbolic"))
        b.set_tooltip_text(L("更多操作"))
        ui.classes(b, "outline")
        return b

    def _section_title(self, s: str) -> Gtk.Label:
        return ui.text(s, 12, "tertiary", bold=True, wrap=False)

    def _notes_column(self, s, live) -> Gtk.Widget:
        col = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        col.set_valign(Gtk.Align.START)
        col.pack_start(self._section_title(L("纪要")), False, False, 0)
        # Ling wrote "说话人 2" before anyone was named: the name given since shows instead.
        n = speakers.named(s.notes, self._speakers(s)[2])
        working = self.app.notes.working_id == s.id
        if n is None or n.is_empty:
            if working:
                row = ui.hbox(10)
                sp = Gtk.Spinner()
                sp.start()
                row.pack_start(sp, False, False, 0)
                row.pack_start(ui.text(L("正在整理纪要…"), 13, "secondary", wrap=False), False, False, 0)
                col.pack_start(ui.gap(row, 14), False, False, 0)
            elif live:
                col.pack_start(ui.gap(ui.text(L("会中每 45 秒更新"), 13, "secondary"), 12), False, False, 0)
            else:
                col.pack_start(ui.gap(ui.text(L("这场会议还没有纪要"), 13, "secondary"), 12), False, False, 0)
                b = ui.button(L("生成纪要"), lambda: self._generate(s.id), "darkbtn")
                b.set_halign(Gtk.Align.START)
                col.pack_start(ui.gap(b, 12), False, False, 0)
            return col
        if n.summary:
            # The summary in a soft card, as the Mac sets it apart.
            summary = ui.panel(ui.pad(ui.text(n.summary, 14, "body", selectable=True, width_chars=50), 13, 16), "summarycard")
            col.pack_start(ui.gap(summary, 10), False, False, 0)
        for t in n.topics:
            row = ui.hbox(10, ui.chip(clock(t.start)))
            row.pack_start(ui.text(t.title, 14, "ink", bold=True, selectable=True, width_chars=40), True, True, 0)
            col.pack_start(ui.gap(row, 22), False, False, 0)
            if t.summary:
                col.pack_start(ui.gap(ui.text(t.summary, 12, "tertiary", selectable=True, width_chars=50), 4), False, False, 0)
            for p in t.points:
                bullet = ui.text("•", 11, "tertiary", wrap=False, ellipsize=False)
                bullet.set_valign(Gtk.Align.START)
                bullet.set_margin_top(2)  # level with the first line of 13 px text
                line = ui.hbox(9, bullet)
                line.pack_start(ui.text(p, 13, "body", selectable=True, width_chars=46), True, True, 0)
                col.pack_start(ui.gap(line, 6), False, False, 0)
        cards = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        cards.set_homogeneous(True)
        for title, items in ((L("结论"), [c.text for c in n.conclusions]),
                             (L("待办"), ["☐ " + t.text + (" · " + t.owner if t.owner else "") for t in n.todos])):
            if not items:
                continue
            inner = ui.vbox(6, ui.text(title, 12, "tertiary", bold=True, wrap=False))
            for it in items:
                inner.pack_start(ui.text(it, 13, "ink", selectable=True, width_chars=22), False, False, 0)
            ui.pad(inner, 14, 16)
            cards.pack_start(ui.panel(inner, "softcard"), True, True, 0)
        if cards.get_children():
            col.pack_start(ui.gap(cards, 24), False, False, 0)
        if working:
            col.pack_start(ui.gap(ui.helper(L("正在整理纪要…")), 14), False, False, 0)
        return col

    def _transcript_column(self, s) -> Gtk.Widget:
        col = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        col.set_valign(Gtk.Align.START)
        head = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        head.pack_start(self._section_title(L("文字记录")), True, True, 0)

        def mode(v):
            self.mode = v
            self.show_detail()
        has_dst = any(l.dst and l.dst != l.src for l in s.lines)
        if has_dst:
            head.pack_end(ui.segmented([("both", L("双语")), ("dst", L("只看译文"))], self.mode, mode), False, False, 0)
        col.pack_start(head, False, False, 0)
        self.transcript = col
        self._both = s.sourceFile is None and any(l.speaker == "me" for l in s.lines)
        self._nums, self._vnums, self._shown = self._speakers(s)
        self._speaker_key = self._speaker_state_key(s)
        self._sid = s.id
        if self._vnums:
            col.pack_start(self._people(s), False, False, 0)
        self._rows = []
        self._loader = None
        self._more_rows(first=True)
        return col

    # 说话人识别

    def _speakers(self, s):
        """(line id → number, voice → number, number → name) for the voices on show; empty when off."""
        if not self.app.settings.speakerVoices or s.sourceFile is not None:
            return {}, {}, {}
        vnums = speakers.voice_numbers(s.lines)
        return speakers.numbers(s.lines), vnums, (speakers.names(s) if vnums else {})

    def _speaker_state_key(self, s):
        _n, vnums, shown = self._speakers(s)
        busy = s.id in self.app.namer.busy
        return (tuple(sorted(vnums.items())), tuple(sorted(shown.items())), str(sorted((s.voiceGuesses or {}).keys())), busy)

    def _row_key(self, l, start):
        return (l.id, l.src, l.dst, l.voice, start)

    def _who(self, l):
        """The label at a change of speaker, and its colour class."""
        if l.speaker == "me":
            return L("你"), "accent"
        n = self._nums.get(l.id)
        if n is not None:
            return speakers.label(n, self._shown), "spk%d" % ((n - 1) % 4 + 1)
        return speakers.speaker_name(l, self._nums, self._shown), "secondary"

    def _speaker_label(self, l):
        text, cls = self._who(l)
        lbl = ui.text(text, 11, cls, bold=True, wrap=False)
        if l.speaker == "me" or not self._vnums:
            return lbl
        # A click on whose line it is: say it was someone else's (这句是谁说的).
        b = Gtk.Button()
        b.add(lbl)
        b.set_relief(Gtk.ReliefStyle.NONE)
        b.set_halign(Gtk.Align.START)
        ui.classes(b, "spklabel")
        b.set_tooltip_text(L("这句是谁说的"))
        b.connect("clicked", lambda w: self._assign_menu(w, l))
        return b

    def _assign_menu(self, widget, l) -> None:
        menu = Gtk.Menu()
        head = Gtk.MenuItem(label=L("这句是谁说的"))
        head.set_sensitive(False)
        menu.append(head)
        for v, n in sorted(self._vnums.items(), key=lambda kv: kv[1]):
            item = Gtk.MenuItem(label=speakers.label(n, self._shown) + (" ✓" if l.voice == v else ""))
            item.connect("activate", lambda _i, v=v: self._edited(*self.app.assign_lines(self._sid, {l.id}, v)))
            menu.append(item)
        menu.show_all()
        menu.attach_to_widget(widget, None)
        menu.popup_at_widget(widget, Gdk.Gravity.SOUTH_WEST, Gdk.Gravity.NORTH_WEST, None)

    def _edited(self, text, snap) -> None:
        sid = self._sid
        if text:
            self.toasts.show(text, L("撤销"), lambda: self.app.undo_speaker_edit(sid, snap), seconds=6)

    def _people(self, s) -> Gtk.Widget:
        """Who is speaking, above the transcript: each person opens the editor; and a way out."""
        # Chips wrap onto more lines rather than widen the window; each keeps its natural width in its cell.
        row = Gtk.FlowBox()
        row.set_selection_mode(Gtk.SelectionMode.NONE)
        row.set_column_spacing(6)
        row.set_row_spacing(6)
        row.set_min_children_per_line(1)
        row.set_max_children_per_line(6)
        row.set_valign(Gtk.Align.START)
        guessed = speakers.guessed(s)
        for v, n in sorted(self._vnums.items(), key=lambda kv: kv[1]):
            chip = Gtk.Button()
            box = ui.hbox(5)
            box.pack_start(ui.text("●", 9, "spk%d" % ((n - 1) % 4 + 1), wrap=False, ellipsize=False), False, False, 0)
            box.pack_start(ui.text(speakers.label(n, self._shown), 11, "ink", bold=True, wrap=False, ellipsize=False), False, False, 0)
            chip.add(box)
            ui.classes(chip, "spkchip")
            chip.set_tooltip_text(L("Ling 从对话里认出，点一下可以改") if n in guessed else L("改名字，或和别人合并"))
            chip.connect("clicked", lambda w, v=v: self._editor(w, v))
            chip.set_halign(Gtk.Align.START)
            child = Gtk.FlowBoxChild()
            child.add(chip)
            row.add(child)
        off = ui.link(L("不准？关掉"), lambda: self.app.set_speaker_voices(False))
        off.set_tooltip_text(L("关掉说话人识别，记录里的名字一起收起"))
        line = ui.hbox(8)
        line.pack_start(row, True, True, 0)
        off.set_valign(Gtk.Align.START)
        line.pack_end(off, False, False, 0)
        return ui.gap(line, 12)

    def _editor(self, chip, voice) -> None:
        """One voice: its name (Ling's guess and people the notes mention a click away), or merge it
        into another voice (SpeakerEditor)."""
        s = self.app.store.get(self._sid)
        if s is None or voice not in self._vnums:
            return
        n = self._vnums[voice]
        guess = speakers.guessed(s).get(n)
        pop = Gtk.Popover(relative_to=chip)
        box = ui.vbox(10)
        ui.pad(box, 14, 16)
        head = ui.hbox(6)
        head.pack_start(ui.text("●", 10, "spk%d" % ((n - 1) % 4 + 1), wrap=False, ellipsize=False), False, False, 0)
        head.pack_start(ui.text(speakers.label(n, self._shown), 13, "ink", bold=True, wrap=False), False, False, 0)
        said = sum(1 for l in s.lines if l.voice == voice)
        head.pack_start(ui.text(LF("说了 %lld 句", said), 11, "tertiary", wrap=False), False, False, 0)
        box.pack_start(head, False, False, 0)
        box.pack_start(ui.text(L("是谁"), 11, "secondary", bold=True, wrap=False), False, False, 0)
        entry = Gtk.Entry()
        entry.set_placeholder_text(L("输入名字"))
        entry.set_text(self._shown.get(n, ""))
        entry.set_width_chars(24)
        picks = speakers.suggestions(s, voice)
        if picks:
            flow = ui.hbox(6)
            for name in picks:
                b = ui.button(name, lambda name=name: (entry.set_text(name), entry.grab_focus()), "pick" + (" chosen" if name == self._shown.get(n) else ""))
                flow.pack_start(b, False, False, 0)
            box.pack_start(flow, False, False, 0)
        box.pack_start(entry, False, False, 0)

        def apply():
            name = entry.get_text().strip()
            pop.popdown()
            # Keeping Ling's name stores nothing, so a later, better guess can still replace it.
            if guess is not None and name == guess.name:
                self._edited(*self.app.rename_speaker(self._sid, voice, None))
            elif (s.voiceNames or {}).get(str(voice)) is not None or name:
                self._edited(*self.app.rename_speaker(self._sid, voice, name))
        entry.connect("activate", lambda *_: apply())
        if guess is not None:
            g = ui.hbox(8)
            g.pack_start(ui.text(LF("Ling 从对话里认出：%@", guess.evidence) if guess.evidence else L("Ling 从对话里认出"),
                                 11, "secondary", width_chars=30), True, True, 0)

            def not_them():
                pop.popdown()
                self._edited(*self.app.rename_speaker(self._sid, voice, ""))
            g.pack_end(ui.link(L("不是 TA"), not_them), False, False, 0)
            box.pack_start(g, False, False, 0)
        elif self._sid in self.app.namer.busy:
            box.pack_start(ui.text(L("Ling 正在从对话里找名字…"), 11, "tertiary", wrap=False), False, False, 0)
        others = sorted(((v, m) for v, m in self._vnums.items() if v != voice), key=lambda kv: kv[1])
        if others:
            box.pack_start(ui.text(L("其实是同一个人"), 11, "secondary", bold=True, wrap=False), False, False, 0)
            merges = ui.hbox(6)

            def merge(into):
                pop.popdown()
                self._edited(*self.app.merge_speaker(self._sid, voice, into))
            for v, m in others[:3]:
                merges.pack_start(ui.button(LF("并入 %@", speakers.label(m, self._shown)), lambda v=v: merge(v), "pick"), False, False, 0)
            if len(others) > 3:
                more = Gtk.MenuButton(label=L("更多"))
                ui.classes(more, "pick")
                menu = Gtk.Menu()
                for v, m in others[3:]:
                    item = Gtk.MenuItem(label=LF("并入 %@", speakers.label(m, self._shown)))
                    item.connect("activate", lambda _i, v=v: merge(v))
                    menu.append(item)
                menu.show_all()
                more.set_popup(menu)
                merges.pack_start(more, False, False, 0)
            box.pack_start(merges, False, False, 0)
        buttons = ui.hbox(8)
        buttons.pack_end(ui.button(L("完成"), apply, "darkbtn"), False, False, 0)
        buttons.pack_end(ui.button(L("取消"), pop.popdown, "outline"), False, False, 0)
        box.pack_start(buttons, False, False, 0)
        pop.add(box)
        box.show_all()
        pop.popup()
        entry.grab_focus()

    def _row(self, l, start: bool = False):
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        t = ui.text(clock(l.t), 11, "link", wrap=False, ellipsize=False)  # times in the logo's orange ink
        t.set_size_request(44, -1)
        t.set_valign(Gtk.Align.START)
        t.set_margin_top(2)
        row.pack_start(t, False, False, 0)
        texts = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        # Whose it is, where the speaker changes (as chat apps do): with voices told apart, or in a
        # meeting I spoke in through 同声传译.
        if start and (self._both or self._vnums):
            texts.pack_start(self._speaker_label(l), False, False, 0)
        translated = l.dst and l.dst != l.src
        texts.pack_start(ui.text(l.dst if translated else l.src, 13, "ink", selectable=True, width_chars=46,
                                 lang=l.dstLang if translated else l.srcLang), False, False, 0)
        if translated and self.mode == "both":
            texts.pack_start(ui.text(l.src, 12, "tertiary", selectable=True, width_chars=46, lang=l.srcLang), False, False, 0)
        row.pack_start(texts, True, True, 0)
        ui.pad(row, 9, 0, 9, 0)
        return self._row_key(l, start), ui.panel(row, "transcript-row")

    def _more_rows(self, first: bool = False) -> None:
        """Rows not shown yet: the first screenful at once, the rest in batches between frames, so
        a two-hour meeting opens instantly."""
        built = self._built_key

        def step(count):
            if self._built_key != built:
                return False
            s = self.app.store.get(built[0])
            if s is None:
                return False
            lines = s.lines
            starts = speakers.run_starts(lines, self._nums)
            for l in lines[len(self._rows):len(self._rows) + count]:
                k, row = self._row(l, l.id in starts)
                self.transcript.pack_start(row, False, False, 0)
                row.show_all()
                self._rows.append((k, row))
            if len(self._rows) < len(lines):
                return True
            self._loader = None
            return False
        if step(60 if first else 200) and self._loader is None:
            self._loader = GLib.idle_add(step, 200)

    def _generate(self, sid) -> None:
        self.app.notes.generate(sid)
        # Shown at once: the engine marks the record busy on its worker a moment later.
        GLib.timeout_add(150, lambda: self.refresh() or False)

    # Actions

    def export(self, s) -> None:
        dialog = Gtk.FileChooserDialog(title=L("导出"), transient_for=self, action=Gtk.FileChooserAction.SAVE)
        dialog.add_buttons(L("取消"), Gtk.ResponseType.CANCEL, L("保存"), Gtk.ResponseType.ACCEPT)
        dialog.set_do_overwrite_confirmation(True)
        dialog.set_current_name(session_store.display_title(s).replace("/", "-") + ".md")
        docs = GLib.get_user_special_dir(GLib.UserDirectory.DIRECTORY_DOCUMENTS) or os.path.expanduser("~")
        dialog.set_current_folder(docs)
        path = dialog.get_filename() if dialog.run() == Gtk.ResponseType.ACCEPT else None
        dialog.destroy()
        if not path:
            return
        try:
            with open(path, "w", encoding="utf-8") as f:
                f.write(session_store.markdown(s, voices=self.app.settings.speakerVoices))
        except OSError:
            self.toasts.show(L("保存失败"))
            return
        self.toasts.show(LF("已导出“%@”", os.path.basename(path)), L("在文件夹中显示"), lambda: show_in_folder(path))

    def rename(self, s) -> None:
        dialog = Gtk.Dialog(title=L("重命名"), transient_for=self, modal=True)
        dialog.add_buttons(L("取消"), Gtk.ResponseType.CANCEL, L("重命名"), Gtk.ResponseType.OK)
        dialog.set_default_response(Gtk.ResponseType.OK)
        entry = Gtk.Entry()
        entry.set_text(session_store.display_title(s))
        entry.set_activates_default(True)
        entry.set_width_chars(36)
        area = dialog.get_content_area()
        ui.pad(area, 12, 16)
        area.add(entry)
        dialog.show_all()
        if dialog.run() == Gtk.ResponseType.OK and entry.get_text().strip():
            self.app.store.rename(s.id, entry.get_text())
        dialog.destroy()

    def delete(self, s) -> None:
        """Hidden at once, removed when the toast goes without 撤销 (or when the app quits)."""
        if s.id == self.app.store.live:
            return
        self.commit_delete()
        self.pending_delete = s.id
        self.selected = None
        self.fill()

        def undo():
            self.pending_delete = None
            self.selected = s.id
            self.fill()
        # Longer than an info toast: undo is the only way back.
        self.toasts.show(LF("已删除“%@”", session_store.display_title(s)), L("撤销"), undo, self.commit_delete, seconds=8)

    def commit_delete(self) -> None:
        sid, self.pending_delete = self.pending_delete, None
        if sid:
            self.app.store.delete(sid)


def show_in_folder(path: str) -> None:
    """Opens the file manager with the file selected (org.freedesktop.FileManager1), else the folder.
    Asynchronous: a file manager that isn't running yet takes seconds to start."""
    uri = Gio.File.new_for_path(path).get_uri()
    folder = Gio.File.new_for_path(os.path.dirname(path)).get_uri()

    def fallback():
        try:
            Gio.AppInfo.launch_default_for_uri(folder, None)
        except GLib.Error:
            pass

    def done(bus, result):
        try:
            bus.call_finish(result)
        except GLib.Error:
            fallback()
    try:
        bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        bus.call("org.freedesktop.FileManager1", "/org/freedesktop/FileManager1", "org.freedesktop.FileManager1",
                 "ShowItems", GLib.Variant("(ass)", ([uri], "")), None, Gio.DBusCallFlags.NONE, 10000, None, done)
    except GLib.Error:
        fallback()

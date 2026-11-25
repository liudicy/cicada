"""会议记录, the main window: a header bar with 开始听 (or 正在听 · 结束) and the app menu; the
meetings grouped by day and searchable on the left; the chosen meeting's notes and its bilingual
transcript side by side on the right (stacked when the window is narrow). Export and delete answer
with a toast; delete can be undone for a few seconds before the record is really removed."""
from __future__ import annotations

import math
import os
import time
from datetime import datetime, timedelta, timezone

from gi.repository import Gdk, Gio, GLib, Gtk, Pango

from ..core import aac, roommic, session_store, speakers, transcript_search
from ..core.strings import L, LF
from ..core.support import SOURCES, TARGETS, Log, clock
from . import share_dialog, ui

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
        self.connect("delete-event", lambda *_: self.close_to_dock() or self.app.records_closed() or True)
        # Minimized it isn't refilled on every change of a meeting; it catches up when it comes back.
        self.iconified = False
        self.parked = False  # minimized by 知了 to keep its dock icon (Controller.keep_in_dock)
        self.connect("window-state-event", self._state_changed)
        self.connect("hide", lambda *_: setattr(self, "iconified", False) or setattr(self, "parked", False))
        self.selected = None
        self.pending_delete = None  # a record deleted but still undoable
        self.query = ""
        # The search in the shown record (#33: a search opens the line, not just the meeting): its terms
        # (misheard names too), the lines found, which one is being looked at.
        self.match_index = 0
        self._terms, self._matches, self._match_set, self._current = [], [], set(), None
        self.mode = "both"  # transcript: "both" or "dst"
        self._both = False  # the shown meeting has lines I said (同声传译): rows name 你 / 对方
        self._nums, self._vnums, self._shown, self._speaker_key = {}, {}, {}, None  # 说话人识别 on show
        self._queued = False
        self.player = None  # the shown record's recording (media.Player), while it has one to play
        self._player_sid = None
        self._dragging = False
        self._hl_row = None  # the transcript row at the playhead
        self._hl_line = None
        self._bars = None  # the bouncing bars on it while playing
        self._was_following = True
        self._scroll_anim = None
        # 改这句…: the line being rewritten and what its editor opens with; the last fix toast shown.
        self._editing = None
        self._edit_start = ""
        self._fix_toast = None

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
        # Enter goes to the next line found, as Ctrl+G does; Shift+Ctrl+G to the one before.
        self.search.connect("activate", lambda *_: self.step(1))
        self.search.connect("next-match", lambda *_: self.step(1))
        self.search.connect("previous-match", lambda *_: self.step(-1))
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
        side.pack_start(self._match_bar(), False, False, 0)
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
        # Once the title scrolls away, a slim bar over the top of the page keeps the title, 导出…
        # and the two columns' names in view (the Mac's pinned bar).
        # A plain box shown and hidden: an overlay child takes the clicks under it even while a
        # revealer hides its content.
        self.pinned = Gtk.Box()
        self.pinned.set_valign(Gtk.Align.START)
        self.pinned.set_no_show_all(True)
        page = Gtk.Overlay()
        page.add(self.right)
        page.add_overlay(self.pinned)
        # Scrolled away from what is playing: one way back (the Mac's 回到正在播放 capsule).
        self.back_pill = self._back_pill()
        page.add_overlay(self.back_pill)
        # The recording's player bar sits under the page, not in its header: the controls stay while
        # the transcript scrolls.
        self.bottom = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        right_col = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        right_col.pack_start(page, True, True, 0)
        right_col.pack_start(self.bottom, False, False, 0)
        root.pack_start(right_col, True, True, 0)
        # Only a hand scrolls with the wheel / touchpad or moves the scrollbar; the follower sets the
        # adjustment, which emits neither.
        self.right.connect("scroll-event", self._hand_scrolled)
        self.right.get_vscrollbar().connect("change-value", self._hand_scrolled)
        self.top_box = None
        self.right.get_vadjustment().connect("value-changed", lambda *_: self._pin())
        self.columns = None
        self.connect("size-allocate", self._resized)
        self.connect("key-press-event", self._key)
        self._tick = GLib.timeout_add_seconds(1, self._clock)
        # Closed: the recording stops; it is set up again when the window is next shown.
        self.connect("hide", lambda *_: (self._unload_player(), setattr(self, "_built_key", None)))
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
                # A key the check found failing is fixed in 设置 › AI 服务, not in the onboarding.
                b.connect("clicked", lambda *_: self.app.show_settings(ai=True) if self.app.ling.has_key and not self.app.key_works
                          else self.app.show_onboarding())
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

    def close_to_dock(self) -> None:
        """✕: hidden, or with 在 Dock 中显示 on, minimized: the dock lists 知了 only while it has a window."""
        if self.app.settings.showInDock:
            self.parked = True
            self.iconify()
        else:
            self.hide()

    def _state_changed(self, _w, event) -> bool:
        if event.changed_mask & Gdk.WindowState.ICONIFIED and not event.new_window_state & Gdk.WindowState.WITHDRAWN:
            self.iconified = bool(event.new_window_state & Gdk.WindowState.ICONIFIED)
            if not self.iconified:
                self.refresh()  # back from the dock: what changed while it was minimized
                # Mapped minimized, Mutter flicks it to normal and back within a few ms: only a
                # window still up a moment later was brought back (by the dock, or Alt+Tab).
                GLib.timeout_add(200, self._restored)
        return False

    def _restored(self) -> bool:
        if self.parked and not self.iconified and self.get_mapped() and self.is_active():
            self.parked = False
            # Mapped minimized, it isn't drawn when it comes back (seen with the notes window up):
            # presenting it, which it already is (active: the WM brought it back, not the flick),
            # gets it drawn.
            self.present()
            self.set_focus(None)
            Log.d("dock: records window brought back")
        return False

    # List

    def refresh(self) -> None:
        if self._queued:
            return
        self._queued = True

        def run():
            self._queued = False
            if self.get_visible() and not self.iconified:
                self.fill()
                self.fix_toast()
            return False
        GLib.idle_add(run)

    def _visible_sessions(self) -> list:
        q = self.query.strip().lower()
        out = []
        for s in self.app.store.all():
            if s.id == self.pending_delete:
                continue
            if q and q not in session_store.display_title(s).lower():
                terms = transcript_search.terms(self.query, s.notes.terms if s.notes else [])
                if not any(transcript_search.line_matches(l, terms) for l in s.lines):
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
        if entry.get_text() == self.query:
            return  # SearchEntry's delayed signal for text already searched: keep the line being looked at
        self.query = entry.get_text()
        self.match_index = 0
        self.fill()
        self._apply_search(scroll=True)

    def _row_selected(self, _list, row) -> None:
        if row is None or getattr(self, "_filling", False):
            return
        if row.session_id != self.selected:
            self.selected = row.session_id
            self.match_index = 0
            self.show_detail()
            self.right.get_vadjustment().set_value(0)
            if self.query.strip():
                self._apply_search(scroll=True)

    # The search in the shown record

    def _match_bar(self) -> Gtk.Widget:
        """Where the search is in the shown record: 本场 2 / 7, and a way to the previous and next line."""
        self.match_count = ui.text("", 12, "secondary", wrap=False, ellipsize=False)
        bar = ui.hbox(2)
        bar.pack_start(self.match_count, True, True, 0)
        bar.pack_end(ui.icon_button("go-down-symbolic", L("下一个"), lambda: self.step(1), px=13, focus=False), False, False, 0)
        bar.pack_end(ui.icon_button("go-up-symbolic", L("上一个"), lambda: self.step(-1), px=13, focus=False), False, False, 0)
        ui.pad(bar, 0, 14, 6, 10)
        bar.show_all()
        bar.set_no_show_all(True)
        bar.hide()
        self.match_bar = bar
        return bar

    def _fill_match_bar(self) -> None:
        on = bool(self.query.strip()) and bool(self._matches)
        if on:
            ui.retext(self.match_count, LF("本场 %lld / %lld", self.match_index + 1, len(self._matches)))
        self.match_bar.set_visible(on)

    def _search_state(self, s) -> None:
        """The search's terms and the lines it finds in `s` (none while there is no query or record)."""
        self._terms = transcript_search.terms(self.query, s.notes.terms if s.notes else []) if s is not None else []
        self._matches = transcript_search.matches(s.lines, self._terms) if s is not None else []
        self._match_set = set(self._matches)
        if self._matches:
            self.match_index = min(self.match_index, len(self._matches) - 1)
        self._current = self._matches[self.match_index] if self._matches else None
        self._fill_match_bar()

    def step(self, d: int) -> None:
        n = len(self._matches)
        if not n:
            return
        self.match_index = (min(self.match_index, n - 1) + d + n) % n
        self._apply_search(scroll=True)

    def _apply_search(self, scroll: bool) -> None:
        """Marks the shown record's lines for the search; with `scroll`, goes to the line being looked at."""
        s = self.app.store.get(self.selected) if self.selected else None
        if s is None or self.columns is None or getattr(self, "_sid", None) != s.id:
            self._search_state(None)
            return
        self._search_state(s)
        self._refresh_rows(s)
        if not scroll or self._current is None:
            return
        idx = next(i for i, l in enumerate(s.lines) if l.id == self._current)
        self._more_rows_until(idx + 1)  # the batches may not have got that far yet
        row = self._rows[idx][1]
        # Once the rows just built are laid out, and again once a long page has its final height.
        GLib.idle_add(lambda: self._centre(row) or False)
        GLib.timeout_add(200, lambda: self._centre(row) or False)

    # Detail

    def _resized(self, _w, alloc) -> None:
        if self.columns is not None:
            want = Gtk.Orientation.HORIZONTAL if alloc.width >= 1000 else Gtk.Orientation.VERTICAL
            if self.columns.get_orientation() != want:
                self.columns.set_orientation(want)
                self.columns.set_homogeneous(want == Gtk.Orientation.HORIZONTAL)
                if self.pinned_heads is not None:
                    self.pinned_heads.set_visible(want == Gtk.Orientation.HORIZONTAL)

    pinned_heads = None

    def _pinned_bar(self, s) -> Gtk.Widget:
        """The title (a click goes back to the top), 导出… and ⋯; under them, side by side, the two
        columns' names, so a long scroll still says which side is the notes."""
        title = Gtk.Button()
        ui.classes(title, "flat", "pinned-title")
        self.pinned_title = ui.text(session_store.display_title(s), 14, "heading", bold=True, wrap=False)
        self.pinned_title.set_ellipsize(Pango.EllipsizeMode.END)
        self.pinned_title.set_xalign(0)
        title.add(self.pinned_title)
        title.set_tooltip_text(L("回到顶部"))
        title.connect("clicked", lambda *_: self.right.get_vadjustment().set_value(0))
        row = ui.hbox(8)
        row.pack_start(title, True, True, 0)
        row.pack_end(self._more_menu(s), False, False, 0)
        row.pack_end(ui.button(L("导出…"), lambda: self.export(s), "outline", "document-save-symbolic"), False, False, 0)
        row.pack_end(self._share_button(s), False, False, 0)
        heads = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=40)
        heads.set_homogeneous(True)
        heads.pack_start(self._section_title(L("纪要")), True, True, 0)
        # The transcript's side as its own head has it: 双语 / 只看译文 stays a click away (the Mac's
        # bar keeps the transcript's language choice too).
        trans = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        trans.pack_start(self._section_title("%s %d" % (L("文字记录"), len(s.lines))), True, True, 0)
        if any(l.dst and l.dst != l.shown for l in s.lines):
            def mode(v):
                self.mode = v
                self.show_detail()
            trans.pack_end(ui.segmented([("both", L("双语")), ("dst", L("只看译文"))], self.mode, mode), False, False, 0)
        heads.pack_start(ui.pad(trans, 0, 10, 0, 10), True, True, 0)
        heads.set_no_show_all(True)
        heads.set_visible(self.columns is None or self.columns.get_orientation() == Gtk.Orientation.HORIZONTAL)
        for c in heads.get_children():
            c.show_all()
        self.pinned_heads = heads
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        box.pack_start(row, False, False, 0)
        box.pack_start(heads, False, False, 0)
        ui.pad(box, 6, 36, 8, 36)
        return ui.panel(box, "pinned-bar")

    def _pin(self) -> None:
        """Show the pinned bar while the title block is above the top of the page."""
        top = self.top_box
        show = top is not None and top.get_mapped() and \
            self.right.get_vadjustment().get_value() > top.get_allocation().y + top.get_allocation().height
        if show != self.pinned.get_visible():
            self.pinned.set_visible(show)

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
        speak = (LF("按 %@ 说话，线上的人听到翻译后的声音", SHORTCUTS["speak"][2].replace(" + Shift + ", " ⇧ "))
                 if gnome_shortcut("speak") else L("点纪要窗的麦克风说话，线上的人听到翻译后的声音"))
        service = L("接上 Ling") if app.settings.aiProvider == "ling" else LF("接上 %@", app.ling.provider.name)
        # A key that the check found failing: why, and 去修 opens 设置 › AI 服务 (not the onboarding).
        from . import aicheck_view
        broken = aicheck_view.strip_words(app) if app.ling.has_key and not key else None
        key_line = (broken[1] or broken[0]) if broken else (L("只存在这台电脑上（只有你的账户能读）") if key else L("识别、翻译和纪要都靠它，约 1 分钟"))
        steps = ((service, key_line, key),
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
            if now and i == 0 and broken:
                action = ui.button(L("去修"), lambda: app.show_settings(ai=True), "darkbtn")
                sub.get_style_context().add_class("stepwhy")
            elif now:
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
            self._unload_player()
            ui.clear(d)
            self.top_box = None
            self.pinned.hide()
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
        if empty or no_match:
            self._search_state(None)
        if no_match:
            d.pack_start(self._status_page("system-search-symbolic", LF("没有找到“%@”", self.query.strip()), "", []), True, True, 0)
            d.show_all()
            return
        s = self.app.store.get(self.selected) if self.selected else None
        self._search_state(s)
        if s is None:
            self._unload_player()
            ui.clear(d)
            self.top_box = None
            self.pinned.hide()
            self.columns = None
            self._built_key = None
            d.show_all()
            return
        live = self.app.listen.listening and self.app.listen.session_id == s.id
        audio = self._audio_state(s, live)
        key = (s.id, self.mode, live, audio)
        if getattr(self, "_built_key", None) == key and self.columns is not None:
            self._update_detail(s, live)
            return
        ui.clear(d)
        self._built_key = key
        self._hl_row = None
        if audio != "ready" or self._player_sid != s.id:
            self._unload_player()
        if audio == "ready" and self.player is None:
            from . import media
            try:
                self.player = media.Player(self.app.store.audio_path(s.id), on_change=self._player_changed)
                self._player_sid = s.id
                GLib.timeout_add(250, self._poll, self.player)
            except Exception as e:  # noqa: BLE001 - a file GStreamer can't open: no player, the record still shows
                Log.d("records: can't play %s" % type(e).__name__)
                self.player = None
        self._playable = self.player is not None
        ui.clear(self.bottom)
        if audio == "ready" and self.player is not None:
            self.bottom.pack_start(self._player_bar(), False, False, 0)
            self.bottom.show_all()

        # Title, meta, actions
        top = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=16)
        left = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=3)
        self.title_label = ui.text(session_store.display_title(s), 22, "heading", bold=True, selectable=True, width_chars=36)
        left.pack_start(self.title_label, False, False, 0)
        self.meta_label = ui.text(self._meta(s, live), 12, "tertiary", wrap=False)
        left.pack_start(self.meta_label, False, False, 0)
        # 存到文件夹: where this record's file is, or why it isn't there yet (not while it's live).
        self.export_slot = ui.hbox(0)
        self.export_slot.set_margin_top(5)
        self.export_slot.set_no_show_all(True)
        self._export_key = False
        left.pack_start(self.export_slot, False, False, 0)
        self._fill_export_line(s, live)
        top.pack_start(left, True, True, 0)
        actions = ui.hbox(8)
        actions.set_valign(Gtk.Align.START)
        actions.pack_start(self._share_button(s), False, False, 0)
        actions.pack_start(ui.button(L("导出…"), lambda: self.export(s), "outline", "document-save-symbolic"), False, False, 0)
        actions.pack_start(self._more_menu(s), False, False, 0)
        top.pack_end(actions, False, False, 0)
        d.pack_start(top, False, False, 0)
        self.top_box = top
        recording = self._audio_view(s, audio)
        if recording is not None:
            d.pack_start(ui.gap(recording, 14), False, False, 0)

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
        for old in self.pinned.get_children():
            old.destroy()
        bar = self._pinned_bar(s)
        self.pinned.pack_start(bar, True, True, 0)
        bar.show_all()
        GLib.idle_add(lambda: (self.right.get_vadjustment().set_value(keep), self._pin()) and False)

    def _fill_export_line(self, s, live) -> None:
        from . import folder_export_view
        key = None if live else folder_export_view.line_key(self.app, s)
        if key == self._export_key:
            return
        self._export_key = key
        ui.clear(self.export_slot)
        line = folder_export_view.record_line(self.app, s, show_in_folder) if key is not None else None
        if line is not None:
            self.export_slot.pack_start(line, False, False, 0)
            line.show_all()
        self.export_slot.set_visible(line is not None)

    def _meta(self, s, live) -> str:
        langs = ""
        if s.lines:
            src, dst = s.lines[0].srcLang, s.lines[0].dstLang
            langs = " · " + (lang_name(src) if src == dst else lang_name(src) + " → " + lang_name(dst))
        # Heard through a microphone in the room, and with the computer's audio too: as on the Mac.
        place = " · " + (L("电脑和会议室") if roommic.heard_both(s.lines) else L("会议室")) if s.room else ""
        return "%s · %s · %s%s%s" % (session_store._local_date(s.startedAt, L("M月d日 HH:mm")), L("正在听") if live else clock(s.duration),
                                     LF("%lld 句", len(s.lines)), langs, place)

    def _notes_state(self, s, live):
        return (id(s.notes), s.notes.updatedAt if s.notes else None, self.app.notes.working_id == s.id, live)

    def _update_detail(self, s, live) -> None:
        """The same meeting changed (a new line while listening, new notes, a rename): touch only what
        changed. Rebuilding a long transcript on every line froze the window for half a second."""
        if self._audio_state(s, live) != self._built_key[3]:
            # The recording was rewrapped (or went missing) since: the player bar and the time links change.
            self._built_key = None
            self.show_detail()
            return
        if (not self._both and s.sourceFile is None and any(l.speaker == "me" for l in s.lines)) or \
                self._speaker_state_key(s) != self._speaker_key:
            # My first sentence, or voices newly on show / renamed / merged: every row may now say
            # someone else, so a full rebuild (the same key would come straight back here).
            self._built_key = None
            self.show_detail()
            return
        ui.retext(self.title_label, session_store.display_title(s))
        ui.retext(self.pinned_title, session_store.display_title(s))
        ui.retext(self.meta_label, self._meta(s, live))
        self._fill_export_line(s, live)
        self._search_state(s)
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
        self._refresh_rows(s)
        self._fill_fix_banner(s)
        self._more_rows()

    def _refresh_rows(self, s) -> None:
        """Rebuilds the rows shown so far whose line, speaker label or search marks changed."""
        starts = self._starts(s.lines)
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

    # The recording (保存会议录音)

    def _audio_state(self, s, live):
        """What shows under the title: "live" (it is being recorded), "ready" (a recording to play),
        "missing" (the record says it has one, the file is gone), "none" (no recording), or None."""
        from . import media
        if live:
            return "live" if self.app.listen.recording else None
        path = self.app.store.audio_path(s.id)
        if os.path.isfile(path):
            # Without an AAC decoder (a record from a Mac on a stock computer) nothing true and
            # useful can be said here: no bar.
            return "ready" if media.can_play() else None
        if os.path.isfile(aac.partial(path)):
            return None  # being rewrapped into system.m4a: the bar comes a moment later
        if s.hasAudio:
            return "missing"
        return "none" if s.lines else None

    def _audio_view(self, s, audio):
        if audio == "live":
            return ui.text(L("会议结束后可以回放录音"), 12, "secondary")
        if audio == "missing":
            return ui.text(L("找不到录音，没法播放"), 12, "secondary")
        if audio == "none":
            if not self.app.can_record:
                # 保存会议录音 can't be turned on here (no AAC encoder): no link to a greyed-out switch.
                return ui.text(L("这场会议没存录音 ·").rstrip(" ·"), 12, "secondary", wrap=False)
            line = ui.hbox(4, ui.text(L("这场会议没存录音 ·"), 12, "secondary", wrap=False, ellipsize=False))
            go = Gtk.Button()
            go.add(ui.text(L("保存会议录音"), 12, "link", wrap=False, ellipsize=False))
            go.set_relief(Gtk.ReliefStyle.NONE)
            ui.classes(go, "timelink")
            go.connect("clicked", lambda *_: self.app.show_settings(general=True))
            line.pack_start(go, False, False, 0)
            return line
        return None  # "ready": the player bar is under the page (self.bottom)

    def _player_bar(self) -> Gtk.Widget:
        """Play / pause, where in the meeting, and the speed (RecordingPlayerBar), in a soft box."""
        p = self.player
        self._pb_icon = ui.icon("media-playback-start-symbolic", 13)
        play = Gtk.Button()
        play.add(self._pb_icon)
        ui.classes(play, "playround")
        play.set_valign(Gtk.Align.CENTER)
        play.connect("clicked", lambda *_: self.player is not None and self.player.toggle())
        self._pb_play = play
        self._pb_time = ui.classes(ui.text(clock(0), 12, "secondary", wrap=False, ellipsize=False), "tnum")
        self._pb_len = ui.classes(ui.text(clock(p.length), 12, "secondary", wrap=False, ellipsize=False), "tnum")
        scale = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, 0, max(p.length, 1), 0.1)
        scale.set_draw_value(False)
        scale.set_valign(Gtk.Align.CENTER)
        ui.classes(scale, "playerscale")
        scale.connect("button-press-event", lambda *_: setattr(self, "_dragging", True) or False)

        def released(w, _e):
            self._dragging = False
            if self.player is not None:
                self.player.seek(w.get_value())
            return False
        scale.connect("button-release-event", released)

        def moved(_w, _scroll, value):
            ui.retext(self._pb_time, clock(max(0, value)))
            if not self._dragging and self.player is not None:
                self.player.seek(value)  # the keyboard
            return False
        scale.connect("change-value", moved)
        self._pb_scale = scale
        rate = Gtk.Button()
        self._pb_rate = ui.text("1×", 11, "secondary", bold=True, wrap=False, ellipsize=False)
        rate.add(self._pb_rate)
        ui.classes(rate, "ratebtn")
        rate.set_valign(Gtk.Align.CENTER)
        rate.set_tooltip_text(L("播放速度"))
        rate.connect("clicked", lambda *_: self.player is not None and self.player.next_rate())
        row = ui.hbox(12, play, self._pb_time)
        row.pack_start(scale, True, True, 0)
        row.pack_start(self._pb_len, False, False, 0)
        row.pack_start(rate, False, False, 0)
        self._player_changed()
        bar = ui.panel(ui.pad(row, 8, 14, 8, 10), "playerbar")
        # At most 680 wide in the middle of the page, as on the Mac.
        bar.set_halign(Gtk.Align.CENTER)

        def fit(_w, alloc):
            want = max(200, min(680, alloc.width - 72))
            if bar.get_size_request()[0] != want:
                bar.set_size_request(want, -1)
        strip = ui.panel(ui.pad(bar, 10, 0, 10, 0), "playerstrip")
        strip.connect("size-allocate", fit)
        return strip

    def _player_changed(self) -> None:
        p = self.player
        if p is None or getattr(self, "_pb_play", None) is None:
            return
        self._pb_icon.set_from_icon_name("media-playback-pause-symbolic" if p.playing else "media-playback-start-symbolic",
                                         Gtk.IconSize.BUTTON)
        tip = L("暂停") if p.playing else L("播放")
        self._pb_play.set_tooltip_text(tip)
        self._pb_play.get_accessible().set_name(tip)
        ui.retext(self._pb_rate, {1.0: "1×", 1.5: "1.5×"}.get(p.rate, "2×"))

    def _unload_player(self) -> None:
        if self.player is not None:
            self.player.close()
        self.player = None
        self._player_sid = None
        self._pb_play = None
        self._hl_row = None
        self._hl_line = None
        self._bars = None
        self._was_following = True
        ui.clear(self.bottom)
        self.back_pill.hide()

    def _poll(self, player) -> bool:
        """Four times a second while a recording is loaded: the time, the bar, and the line being played."""
        if player is not self.player:
            return False
        if getattr(self, "_pb_play", None) is None or not self.get_visible():
            return True
        t, length = player.time, player.length
        ui.retext(self._pb_len, clock(length))
        if self._pb_scale.get_adjustment().get_upper() != max(length, 1):
            self._pb_scale.set_range(0, max(length, 1))
        if not self._dragging:
            ui.retext(self._pb_time, clock(t))
            self._pb_scale.set_value(min(t, max(length, 1)))
        self._player_changed()
        if player.started:
            self._highlight(t, player.playing, player.following)
        return True

    def _hand_scrolled(self, *_args) -> bool:
        """The wheel, the touchpad or the scrollbar moved the page: stop following what plays."""
        if self.player is not None and self.player.playing:
            adj = self.right.get_vadjustment()
            if adj.get_upper() > adj.get_page_size():  # nothing to scroll: nothing moved
                self._stop_scroll_anim()
                self.player.user_scrolled()
                self._update_pill()
        return False

    def _highlight(self, now: float, playing: bool, following: bool) -> None:
        """The last line that began by now (a little ahead, so it lights as it starts) on a pale
        accent; while playing, its bars bounce and the page keeps it in the middle until scrolled by hand."""
        s = self.app.store.get(self._player_sid) if self._player_sid else None
        if s is None:
            return
        idx = -1
        for i, l in enumerate(s.lines):
            if l.t <= now + 0.2:
                idx = i
            else:
                break
        if idx >= len(self._rows) and getattr(self, "_loader", None) is not None:
            self._more_rows_until(idx + 1)  # played (or picked) past the rows built so far
        row = self._rows[idx][1] if 0 <= idx < len(self._rows) else None
        self._hl_line = s.lines[idx] if idx >= 0 else None
        changed = row is not self._hl_row
        if changed:
            old, self._hl_row = self._hl_row, row
            for r, on in ((old, False), (row, True)):
                if r is None or r.get_parent() is None:  # a row rebuilt since (its line changed) is gone
                    continue
                ctx = r.get_style_context()
                ctx.add_class("playing") if on else ctx.remove_class("playing")
                self._style_time(r)
        self._set_bars(row if playing else None)
        refollow = following and not self._was_following
        self._was_following = following
        if row is not None and following and ((changed and playing) or refollow):
            self._centre(row)
        self._update_pill()

    def _style_time(self, r) -> None:
        """A row's time: accent and bold while it plays or is pointed at (with ▶ then), the link ink otherwise."""
        label = r.time_label
        ctx = r.get_style_context()
        on = ctx.has_class("playing") or ctx.has_class("hover")
        lc = label.get_style_context()
        lc.remove_class("link" if on else "accent")
        lc.add_class("accent" if on else "link")
        if r.time_play is not None:
            r.time_play.set_visible(ctx.has_class("hover"))
        size, lang, bold = label.cicada_format
        if bold != on:
            label.cicada_format = (size, lang, on)
            ui.retext(label, label.get_text())

    def _set_bars(self, row) -> None:
        """Three bars bouncing at the right edge of the row playing (PlayingBars); none while paused."""
        bars = self._bars
        slot = getattr(row, "bars_slot", None) if row is not None else None
        if bars is not None and (slot is None or bars.get_parent() is not slot):
            if bars.get_parent() is not None:
                bars.destroy()
            self._bars = bars = None
        if slot is None or bars is not None:
            return
        # CSS-filled boxes, not a drawing: stock Ubuntu has no python3-gi-cairo.
        moving = Gtk.Settings.get_default().get_property("gtk-enable-animations")
        bars, sticks = self._sticks("playbars", (8, 8, 8), Gtk.Align.END)
        bars.set_size_request(14, 12)
        bars.set_valign(Gtk.Align.START)
        slot.pack_start(bars, False, False, 0)
        bars.show_all()
        self._bars = bars

        def tick():
            if self._bars is not bars:
                return False
            t = time.monotonic()
            for i, stick in enumerate(sticks):
                h = (0.35 + 0.65 * abs(math.sin(t * 3.5 + i * 0.9))) if moving else 0.7
                stick.set_size_request(3, max(3, round(12 * h)))
            return moving
        tick()
        if moving:
            GLib.timeout_add(40, tick)

    @staticmethod
    def _sticks(cls: str, heights, align) -> tuple:
        """A row of thin rounded bars (the Mac's capsules) of these heights, filled by CSS."""
        box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=2 if cls == "playbars" else 1)
        sticks = []
        for h in heights:
            stick = ui.panel(Gtk.Box(), "stick")
            stick.set_size_request(3 if cls == "playbars" else 2, h)
            stick.set_valign(align)
            box.pack_start(stick, False, False, 0)
            sticks.append(stick)
        ui.classes(box, cls)
        return box, sticks

    def _back_pill(self) -> Gtk.Widget:
        """回到正在播放 · m:ss: a dark capsule at the bottom of the page while it doesn't follow."""
        b = Gtk.Button()
        ui.classes(b, "backpill")
        wave, _ = self._sticks("pillwave", (5, 11, 7, 9, 4), Gtk.Align.CENTER)
        wave.set_valign(Gtk.Align.CENTER)
        self._pill_label = ui.text("", 13, "ink", bold=True, wrap=False, ellipsize=False)
        inner = ui.hbox(6, wave, self._pill_label)
        inner.show_all()  # the button itself is no_show_all: shown and hidden on its own
        b.add(inner)
        b.set_halign(Gtk.Align.CENTER)
        b.set_valign(Gtk.Align.END)
        b.set_margin_bottom(16)
        b.connect("clicked", lambda *_: self.follow_playing())
        b.set_no_show_all(True)
        return b

    def follow_playing(self) -> None:
        """回到正在播放: follow the recording again, and scroll back to it."""
        if self.player is None:
            return
        self.player.follow()
        if self.player.started:
            self._highlight(self.player.time, self.player.playing, True)

    def _update_pill(self) -> None:
        p = self.player
        l = self._hl_line
        show = p is not None and p.started and not p.following and l is not None
        if show:
            ui.retext(self._pill_label, L("回到正在播放") + " · " + clock(l.t))
            if not self.back_pill.get_visible():
                self.back_pill.show()
        elif self.back_pill.get_visible():
            self.back_pill.hide()

    def _centre(self, row) -> None:
        """Scrolls the row to the middle of the page under the pinned bar, eased over 0.25 s."""
        pos = row.translate_coordinates(self.content, 0, 0)
        if pos is None:
            return
        adj = self.right.get_vadjustment()
        pinned = self.pinned.get_allocated_height() if self.pinned.get_visible() else 0
        view = adj.get_page_size() - pinned
        to = pos[1] + row.get_allocated_height() / 2 - pinned - view / 2
        to = max(0, min(to, adj.get_upper() - adj.get_page_size()))
        self._stop_scroll_anim()
        start, frm = time.monotonic(), adj.get_value()
        if abs(to - frm) < 1:
            return

        def step():
            k = min(1.0, (time.monotonic() - start) / 0.25)
            adj.set_value(frm + (to - frm) * (1 - (1 - k) ** 3))
            if k >= 1:
                self._scroll_anim = None
                return False
            return True
        self._scroll_anim = GLib.timeout_add(16, step)

    def _stop_scroll_anim(self) -> None:
        if self._scroll_anim is not None:
            GLib.source_remove(self._scroll_anim)
            self._scroll_anim = None

    def _reveal(self, row) -> None:
        pos = row.translate_coordinates(self.content, 0, 0)
        if pos is None:
            return
        adj = self.right.get_vadjustment()
        y, h = pos[1], row.get_allocated_height()
        top = adj.get_value() + (self.pinned.get_allocated_height() if self.pinned.get_visible() else 0)
        if y < top or y + h > adj.get_value() + adj.get_page_size():
            adj.set_value(max(0, min(y - adj.get_page_size() / 3, adj.get_upper() - adj.get_page_size())))

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
                             (L("待办"), ["☐ " + t.with_owner for t in n.todos])):
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
        has_dst = any(l.dst and l.dst != l.shown for l in s.lines)
        if has_dst:
            head.pack_end(ui.segmented([("both", L("双语")), ("dst", L("只看译文"))], self.mode, mode), False, False, 0)
        # The review banner rides with the header, so the rows keep their places among col's children.
        self.fix_banner = ui.vbox(0)
        self._banner_key = None
        # Inset as far as the rows' text, which sits 10 px inside their fill.
        col.pack_start(ui.pad(ui.vbox(0, head, self.fix_banner), 0, 10, 0, 10), False, False, 0)
        self.transcript = col
        self._both = s.sourceFile is None and any(l.speaker == "me" for l in s.lines)
        self._nums, self._vnums, self._shown = self._speakers(s)
        self._places = roommic.heard_both(s.lines)
        self._speaker_key = self._speaker_state_key(s)
        self._sid = s.id
        if self._vnums:
            people = self._people(s)
            people.set_margin_start(10)
            people.set_margin_end(10)
            col.pack_start(people, False, False, 0)
        self._rows = []
        self._loader = None
        self._editing = None
        self._fill_fix_banner(s)
        self._more_rows(first=True)
        return col

    # 说话人识别

    def _speakers(self, s):
        """(line id → number, voice → number, number → name) for the voices on show; empty when off."""
        if not self.app.settings.speakerVoices:
            return {}, {}, {}
        vnums = speakers.voice_numbers(s.lines)
        # An imported file without voices on show has no "other side" to label.
        if not speakers.says_who(s, vnums):
            return {}, {}, {}
        return speakers.numbers(s.lines), vnums, (speakers.names(s) if vnums else {})

    def _speaker_state_key(self, s):
        _n, vnums, shown = self._speakers(s)
        busy = s.id in self.app.namer.busy
        # The room side's first line in 电脑和会议室: every line of theirs now says where it was heard.
        return (tuple(sorted(vnums.items())), tuple(sorted(shown.items())), str(sorted((s.voiceGuesses or {}).keys())), busy,
                roommic.heard_both(s.lines))

    def _row_key(self, l, start):
        fixes = tuple((f.from_, f.to, f.ask, f.off, f.user) for f in l.fixes or [])
        # The search marks only lines it finds: typing a query doesn't rebuild the whole transcript.
        found = (tuple(self._terms), l.id == self._current) if l.id in self._match_set else None
        return (l.id, l.shown, l.dst, l.voice, start, fixes, self._editing == l.id, found)

    def _who(self, l):
        """The label at a change of speaker, and its colour class."""
        if l.speaker == "me":
            return L("你"), "accent"
        n = self._nums.get(l.id)
        if n is not None:
            return speakers.label(n, self._shown), "spk%d" % ((n - 1) % 4 + 1)
        return speakers.speaker_name(l, self._nums, self._shown), "secondary"

    def _speaker_label(self, l):
        if l.speaker == "me":
            return ui.me_tag()
        text, cls = self._who(l)
        lbl = ui.text(text, 11, cls, bold=True, wrap=False)
        if not self._vnums:
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
        time_widget = t
        play_icon = None
        playable = getattr(self, "_playable", False)
        if playable:
            # With a recording, a time plays from that line (the Mac's line times), and so does a
            # click anywhere on the line; pointed at, it shows ▶ in the accent.
            t.set_size_request(-1, -1)
            play_icon = ui.icon("media-playback-start-symbolic", 8)
            ui.classes(play_icon, "accent")
            play_icon.set_no_show_all(True)
            play_icon.set_valign(Gtk.Align.CENTER)
            inner = ui.hbox(3, play_icon, t)
            inner.set_size_request(52, -1)
            time_widget = Gtk.Button()
            time_widget.add(inner)
            time_widget.set_relief(Gtk.ReliefStyle.NONE)
            ui.classes(time_widget, "timelink")
            time_widget.set_tooltip_text(L("从这里播放"))
            time_widget.connect("clicked", lambda *_: self.play_line(l))
        time_widget.set_valign(Gtk.Align.START)
        time_widget.set_halign(Gtk.Align.START)
        time_widget.set_margin_top(2)
        row.pack_start(time_widget, False, False, 0)
        texts = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        # Whose it is, where the speaker changes (as chat apps do): with voices told apart, or in a
        # meeting I spoke in through 同声传译.
        if start and (self._both or self._vnums or self._places):
            label = self._speaker_label(l)
            if self._places and l.speaker != "me":
                label = ui.hbox(6, label, ui.place_tag(l))
            texts.pack_start(label, False, False, 0)
        translated = l.dst and l.dst != l.shown
        terms = self._terms if l.id in self._match_set else []
        found = l.id == self._current
        selectable = []  # the line's text: a drag over it selects, and must not play
        if self._editing == l.id:
            texts.pack_start(self._line_editor(l), False, False, 0)
        else:
            if translated:
                dst = ui.marked(l.dst, terms, 13, "ink", found, lang=l.dstLang, width_chars=46)
                dst.set_selectable(True)
                selectable.append(dst)
                texts.pack_start(dst, False, False, 0)
            if not translated or self.mode == "both":
                src = ui.fixed(l, 12 if translated else 13, "tertiary" if translated else "ink", terms, found)
                src.set_selectable(True)
                src.set_max_width_chars(46)
                selectable.append(src)
                texts.pack_start(src, False, False, 0)
            # Pointing at a line: what its fixed words were heard as, 改回, and 改这句….
            tools = ui.hbox(8)
            applied = [(l.id, f) for f in l.fixes or [] if f.applied]
            if applied:
                tools.pack_start(ui.fixed_words(applied, lambda i, f: self.app.fixes.revert(f, i, self._sid)), False, False, 0)
            edit = Gtk.Button(label=L("改这句…"))
            ui.classes(edit, "fixlink")
            edit.set_valign(Gtk.Align.CENTER)
            edit.connect("clicked", lambda *_: self.edit_line(l.id))
            tools.pack_start(edit, False, False, 0)
            tools.set_no_show_all(True)
            for c in tools.get_children():
                c.show_all()
            texts.pack_start(ui.gap(tools, 2), False, False, 0)
        row.pack_start(texts, True, True, 0)
        panel = ui.panel(row, "transcript-row")
        panel.time_label = t
        panel.time_play = play_icon
        panel.bars_slot = None
        if playable:
            # Where the bars bounce while this line plays: kept wide so the text doesn't move.
            panel.bars_slot = Gtk.Box()
            panel.bars_slot.set_size_request(14, -1)
            panel.bars_slot.set_margin_top(4)
            row.pack_end(panel.bars_slot, False, False, 0)
        # 10 px of fill around the text, so the line playing reads as one rounded block.
        ui.pad(row, 9, 10, 9, 10)
        if self._editing != l.id:
            panel.add_events(Gdk.EventMask.ENTER_NOTIFY_MASK | Gdk.EventMask.LEAVE_NOTIFY_MASK |
                             Gdk.EventMask.BUTTON_PRESS_MASK | Gdk.EventMask.BUTTON_RELEASE_MASK)

            def entered(*_):
                tools.show()
                if playable:
                    panel.get_style_context().add_class("hover")
                    self._style_time(panel)
                return False
            panel.connect("enter-notify-event", entered)

            def left(_w, event):
                if event.detail != Gdk.NotifyType.INFERIOR:
                    tools.hide()
                    if playable:
                        panel.get_style_context().remove_class("hover")
                        self._style_time(panel)
                return False
            panel.connect("leave-notify-event", left)
            panel.connect("button-press-event", lambda _w, e: self._line_menu(e, l.id))
            if playable:
                self._tap_to_play(panel, selectable, l)
        return self._row_key(l, start), panel

    def _tap_to_play(self, panel, labels, l) -> None:
        """A click anywhere on the line plays from it; a drag (or a double click) that selects text
        doesn't. The selectable labels take the presses over the text, so they report them too."""
        down = {}

        def press(_w, e):
            if e.button == 1:
                down["at"] = (e.x_root, e.y_root) if e.type == Gdk.EventType.BUTTON_PRESS else None
            return False

        def release(_w, e):
            at = down.pop("at", None)
            if e.button != 1 or at is None or self._editing == l.id:
                return False
            if abs(e.x_root - at[0]) > 4 or abs(e.y_root - at[1]) > 4:
                return False
            if any(lb.get_selection_bounds()[0] for lb in labels):
                return False  # text selected (a drag that came back, a shift-click)
            self.play_line(l)
            return False
        for w in [panel, *labels]:
            w.connect("button-press-event", press)
            w.connect("button-release-event", release)

    def play_line(self, l) -> None:
        """Plays the recording from a line (also while paused); the page follows it again."""
        if self.player is None:
            return
        self.player.play_from(l.t)
        self._highlight(l.t, True, True)

    # 改正听错的词: 改这句…, the review banner, the toast

    def _line_menu(self, event, line_id) -> bool:
        """Right-click on a line: 改这句…."""
        if event.button != 3:
            return False
        menu = Gtk.Menu()
        item = Gtk.MenuItem(label=L("改这句…"))
        item.connect("activate", lambda *_: self.edit_line(line_id))
        menu.append(item)
        menu.show_all()
        menu.attach_to_widget(self, None)
        menu.popup_at_pointer(event)
        return True

    def edit_line(self, line_id, start: str | None = None) -> None:
        """Opens 改这句… on a line, with the line as shown (or `start`, the banner's suggestion)."""
        l = self.app.store.line(self._sid, line_id)
        if l is None:
            return
        before = self._editing
        self._editing, self._edit_start = line_id, start if start is not None else l.shown
        if before is not None and before != line_id:
            self._rebuild_row(before)  # one editor at a time
        self._rebuild_row(line_id)

    def _rebuild_row(self, line_id) -> None:
        s = self.app.store.get(self._sid)
        if s is None:
            return
        starts = self._starts(s.lines)
        for i, l in enumerate(s.lines[:len(self._rows)]):
            if l.id == line_id:
                old = self._rows[i][1]
                k, row = self._row(l, l.id in starts)
                parent = old.get_parent()
                pos = parent.get_children().index(old)
                parent.remove(old)
                old.destroy()
                parent.pack_start(row, False, False, 0)
                parent.reorder_child(row, pos)
                row.show_all()
                self._rows[i] = (k, row)
                if self._editing == line_id:
                    GLib.idle_add(lambda: self._reveal(row) and False)
                return

    def _line_editor(self, l) -> Gtk.Widget:
        """改这句…: the line as shown, to rewrite (the Mac's LineEditor). What changed becomes the user's
        own fix, on every line heard the same way or only this one, and with 记进词表 the word list's."""
        fx, sid = self.app.fixes, self._sid
        box = ui.vbox(8)
        entry = Gtk.Entry()
        entry.set_text(self._edit_start)
        entry.set_placeholder_text(L("改这句"))
        ui.classes(entry, "fixedit")
        box.pack_start(entry, False, False, 0)
        options = ui.vbox(6)
        box.pack_start(options, False, False, 0)
        state = {"everywhere": True, "keep": True}

        def close():
            self._editing = None
            self._rebuild_row(l.id)

        def apply():
            same = fx.same_heard(l.id, sid, entry.get_text())
            if same is None:
                close()
                return
            every = state["everywhere"] if same[1] > 1 else True
            self._editing = None
            fx.edit(l.id, sid, entry.get_text(), everywhere=every, remember=state["keep"] and every)
            self._rebuild_row(l.id)

        def update(*_):
            ui.clear(options)
            same = fx.same_heard(l.id, sid, entry.get_text())
            if same is not None:
                heard, n, swap = same
                options.pack_start(ui.hbox(6, ui.text(L("听成"), 12, "tertiary", wrap=False, ellipsize=False),
                                           ui.text(heard, 12, "ink", wrap=False)), False, False, 0)
                keep = Gtk.CheckButton(label=L("记进词表，以后自动改"))
                keep.set_active(state["keep"])
                keep.connect("toggled", lambda b: state.__setitem__("keep", b.get_active()))
                if n > 1:
                    all_ = Gtk.RadioButton.new_with_label(None, LF("整场听成 %@ 的 %lld 处都改", heard, n))
                    one = Gtk.RadioButton.new_with_label_from_widget(all_, L("只改这一处"))
                    (all_ if state["everywhere"] else one).set_active(True)

                    def scope(b):
                        state["everywhere"] = all_.get_active()
                        keep.set_sensitive(state["everywhere"])
                    all_.connect("toggled", scope)
                    keep.set_sensitive(state["everywhere"])
                    options.pack_start(all_, False, False, 0)
                    options.pack_start(one, False, False, 0)
                # Only a word for a word can teach the list: an added or dropped word can't.
                if swap:
                    options.pack_start(keep, False, False, 0)
            options.show_all()
        entry.connect("changed", update)
        entry.connect("activate", lambda *_: apply())

        def key(_w, event):
            if event.keyval == Gdk.KEY_Escape:
                close()
                return True
            return False
        entry.connect("key-press-event", key)
        update()
        foot = ui.hbox(8)
        foot.pack_start(ui.text(L("回车 改成 · esc 取消"), 11, "tertiary", wrap=False), True, True, 0)
        foot.pack_end(ui.soft_button(L("改成"), apply, dark=True), False, False, 0)
        foot.pack_end(ui.soft_button(L("取消"), close), False, False, 0)
        box.pack_start(foot, False, False, 0)
        def focus():
            entry.grab_focus()
            entry.set_position(-1)  # the caret at the end, not the whole line selected
            return False
        GLib.idle_add(focus)
        return box

    def _fill_fix_banner(self, s) -> None:
        """Above a finished meeting's transcript (the Mac's FixReviewBanner): how many words were fixed,
        and the ones waiting for the user, one at a time (对 / 不对 / 改成…)."""
        box = getattr(self, "fix_banner", None)
        if box is None:
            return
        live = self.app.listen.listening and self.app.listen.session_id == s.id
        fx = self.app.fixes
        waiting = [] if live else fx.pending(s.id)
        fixed = sum(1 for l in s.lines for f in l.fixes or [] if f.applied)
        key = (s.id, live, fixed, len(waiting), (waiting[0][0].id, waiting[0][1].from_, waiting[0][1].to) if waiting else None)
        if key == getattr(self, "_banner_key", None):
            return
        self._banner_key = key
        ui.clear(box)
        if waiting:
            from ..core.correction import label
            line, fix = waiting[0]
            cf, ct = label(fix)
            left = ui.vbox(2)
            left.pack_start(ui.text(LF("改了 %lld 处听错的词，%lld 处等你确认", fixed, len(waiting)), 13, "ink", bold=True, width_chars=40),
                            False, False, 0)
            what = Gtk.Label()
            what.set_xalign(0)
            what.set_markup('<span size="%d">%s → %s？<span foreground="#6B7080"> · %s</span></span>'
                            % (12 * 768, ui.esc(cf), ui.esc(ct), ui.esc(clock(line.t))))
            ui.classes(what, "secondary")
            left.pack_start(what, False, False, 0)
            row = ui.hbox(10)
            row.pack_start(left, True, True, 0)
            row.pack_start(ui.soft_button(L("对"), lambda: fx.answer(fix, True, s.id), dark=True), False, False, 0)
            row.pack_start(ui.soft_button(L("不对"), lambda: fx.answer(fix, False, s.id)), False, False, 0)
            # 改成…: the editor on that line, to write what was really said.
            row.pack_start(ui.soft_button(L("改成…"), lambda: self.edit_line(line.id)), False, False, 0)
            for b in row.get_children()[1:]:
                b.set_valign(Gtk.Align.CENTER)
            box.pack_start(ui.gap(ui.panel(ui.pad(row, 10, 14), "fixbanner"), 10), False, False, 0)
        elif fixed:
            box.pack_start(ui.gap(ui.text(LF("改了 %lld 处听错的词", fixed), 12, "tertiary", wrap=False), 6), False, False, 0)
        box.show_all()

    def fix_toast(self) -> None:
        """The last fix decision, with 撤销, as this window's toast (once per decision)."""
        fx = self.app.fixes
        text = fx.toast_text()
        if text is None or fx.toast is self._fix_toast:
            return
        self._fix_toast = fx.toast
        self.toasts.show(text, L("撤销") if fx.can_undo else None, fx.undo, seconds=6)

    def _starts(self, lines) -> set:
        """Lines whose speaker label shows: a change of speaker, or in 电脑和会议室 of place too."""
        starts = speakers.run_starts(lines, self._nums)
        return starts | roommic.place_starts(lines) if self._places else starts

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
            starts = self._starts(lines)
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

    def _more_rows_until(self, count: int) -> None:
        """The rows up to `count` built now: the playhead got there before the batches did."""
        s = self.app.store.get(self._sid)
        if s is None:
            return
        starts = self._starts(s.lines)
        for l in s.lines[len(self._rows):count]:
            k, row = self._row(l, l.id in starts)
            self.transcript.pack_start(row, False, False, 0)
            row.show_all()
            self._rows.append((k, row))

    def _generate(self, sid) -> None:
        self.app.notes.generate(sid)
        # Shown at once: the engine marks the record busy on its worker a moment later.
        GLib.timeout_add(150, lambda: self.refresh() or False)

    # Actions

    def _share_button(self, s) -> Gtk.Widget:
        """分享…, beside 导出…: off while the meeting is live or has nothing in it (share_dialog.can_share)."""
        sid = s.id
        b = ui.button(L("分享…"), lambda: self.share(sid), "outline", "emblem-shared-symbolic")
        b.set_sensitive(share_dialog.can_share(self.app, s))
        return b

    def share(self, sid: str) -> None:
        s = self.app.store.get(sid)
        if s is not None and share_dialog.can_share(self.app, s):
            share_dialog.open_for(self.app, s, self)

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
            self.app.folder_export.deleted(sid)  # its file in the folder stays


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

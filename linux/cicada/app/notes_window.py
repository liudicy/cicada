"""The window shown while listening: live notes (default) or the subtitle bar. Like the Mac's notes
panel it stays above other windows and never takes focus, so the user keeps typing in their meeting
app: an X11 window (the app runs on XWayland under GNOME's Wayland session, see main.py) with the
"above" state and an input hint of false, which the window manager honours.

Linux has no way to keep one window out of screen sharing (the portal shares whatever is on
screen), so unlike the Mac and Windows the footer always says 共享屏幕时此窗口可见, and 共享屏幕时
让对方看到 isn't offered. The notes panel follows the desktop's dark style; the subtitle bar is
always dark, to read over video."""
from __future__ import annotations

from datetime import datetime, timezone

from gi.repository import Gdk, GLib, Gtk

from ..core import notes as notesmod
from ..core import speakers
from ..core.strings import L, LF
from ..core.support import Log, clock
from . import ui, x11


class NotesWindow(Gtk.Window):
    def __init__(self, app):
        super().__init__(type=Gtk.WindowType.TOPLEVEL)
        self.app = app
        self.set_title(L("知了"))
        self.set_decorated(False)
        self.set_keep_above(True)
        self.set_accept_focus(False)
        self.set_focus_on_map(False)
        self.set_skip_taskbar_hint(True)
        self.set_skip_pager_hint(True)
        # A notification-type window: Mutter keeps it in the top layer and doesn't move focus when
        # it's clicked (a utility window still blinks the meeting app out of focus for ~0.1 s).
        # The WM won't move such a window, so dragging is done here (_drag/_motion).
        self.set_type_hint(Gdk.WindowTypeHint.NOTIFICATION)
        self.set_wmclass("cicada", "Cicada")
        screen = self.get_screen()
        visual = screen.get_rgba_visual()
        if visual is not None and screen.is_composited():
            self.set_visual(visual)
            self.set_app_paintable(True)
        ui.classes(self, "notes-window")
        self.add_events(Gdk.EventMask.BUTTON_PRESS_MASK | Gdk.EventMask.BUTTON_RELEASE_MASK | Gdk.EventMask.BUTTON1_MOTION_MASK)
        self._grab = None
        self.connect("button-press-event", self._drag)
        self.connect("motion-notify-event", self._motion)
        self.connect("button-release-event", lambda *_: setattr(self, "_grab", None))
        self._bottom = None  # the subtitle bar's bottom edge: it grows upward as text wraps
        self.connect("configure-event", self._configured)
        self.connect("realize", lambda w: x11.never_take_focus(w.get_window()))
        self.connect("delete-event", lambda *_: self.hide() or True)
        self._queued = False
        self._built = False
        self._timer = None
        # 纪要 / 文字记录, the search in the transcript and 纪要和原话并排 (NotesWindow.swift).
        self.tab = "notes"
        self.wide = False
        self.query = ""
        self.matches = []
        self.match_index = 0
        self._transcript_key = None
        self._keys = False  # taking the keyboard while the search is typed in
        self.connect("show", lambda *_: self._start_clock())
        self.connect("hide", lambda *_: self._stop_clock())
        self.render()
        self.place()

    @property
    def subtitles(self) -> bool:
        return self.app.settings.view == "subtitles"

    @property
    def dark(self) -> bool:
        return self.subtitles or ui.prefers_dark()

    # Moving and placing

    def _drag(self, _w, event):
        Log.d("notes window: click at %d,%d, active=%s" % (event.x, event.y, self.is_active()))
        if event.button == 1:
            x, y = self.get_position()
            self._grab = (event.x_root - x, event.y_root - y)
        return False

    def _motion(self, _w, event):
        if self._grab is not None:
            x, y = int(event.x_root - self._grab[0]), int(event.y_root - self._grab[1])
            self.move(x, y)
            if self._bottom is not None:
                self._bottom = y + self.get_size()[1]
        return False

    def _configured(self, _w, event):
        if self.subtitles and self._bottom is not None and self._grab is None and event.y + event.height != self._bottom:
            self.move(event.x, self._bottom - event.height)
        return False

    def place(self) -> None:
        """Notes at the top right, subtitles along the bottom, on the primary monitor's work area."""
        display = Gdk.Display.get_default()
        mon = display.get_primary_monitor() or display.get_monitor(0)
        area = mon.get_workarea()
        if self.subtitles:
            w = min(860, area.width - 40)
            self.set_size_request(w, -1)
            self.resize(w, 1)
            self._bottom = area.y + area.height - 16
            self.move(area.x + (area.width - w) // 2, self._bottom - 120)
        else:
            h = min(680, area.height - 40)
            w = 820 if self.wide else 400
            self.set_size_request(w, 260)
            self.resize(w, h)
            self.move(area.x + area.width - w - 12, area.y + 12)

    def _start_clock(self):
        if self._timer is None:
            self._timer = GLib.timeout_add_seconds(1, self._tick)

    def _stop_clock(self):
        if self._timer is not None:
            GLib.source_remove(self._timer)
            self._timer = None

    def _tick(self):
        if self.app.listen.listening:
            self._fill_header()
            s = self.app.store.get(self.app.listen.session_id) if self.app.listen.session_id else None
            if s is not None and not s.lines:
                self._fill_live()  # before the first line the state follows the sound
            if self.footer_time is not None:
                self._fill_footer()
            self._fill_ending()
        return True

    def refresh(self) -> None:
        """Changes come from engine threads (via the controller): coalesce them into one render."""
        if self._queued:
            return
        self._queued = True

        def run():
            self._queued = False
            self.render()
            return False
        GLib.idle_add(run)

    # Layout

    def _build(self) -> None:
        self._built = True
        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.panel = ui.panel(outer, "panel")
        ui.pad(self.panel, 8)
        self.header = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=4)
        ui.pad(self.header, 8, 8, 4, 16)
        outer.pack_start(self.header, False, False, 0)
        self.live = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        self.body = None
        self.footer_time = None
        self.speakbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=3)
        if self.subtitles:
            ui.pad(self.live, 0, 22, 16, 22)
            outer.pack_start(self.live, False, False, 0)
            # The wrapper is what hides: show_all() skips a no_show_all widget's own children.
            self.speakwrap = Gtk.Box()
            self.speakwrap.pack_start(ui.pad(self.speakbox, 0, 22, 14, 22), True, True, 0)
            outer.pack_start(self.speakwrap, False, False, 0)
        else:
            # Below the header: the ending strip (a meeting about to end by itself), the tabs, then
            # the notes and / or the transcript (side by side when wide).
            self.ending_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
            self.ending_wrap = ui.pad(ui.panel(ui.pad(self.ending_box, 14), "endingstrip"), 2, 12, 8, 12)
            self.tabs = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=0, homogeneous=True)
            ui.classes(self.tabs, "segmented", "big")
            self.tab_buttons = {}
            for value in ("notes", "transcript"):
                b = Gtk.ToggleButton()
                b.add(ui.text("", 13, "", wrap=False, ellipsize=False))
                b.set_can_focus(False)
                b.connect("toggled", self._tab_toggled, value)
                self.tab_buttons[value] = b
                self.tabs.pack_start(b, True, True, 0)
            self.tabs_wrap = ui.pad(self.tabs, 2, 16, 10, 16)
            outer.pack_start(self.tabs_wrap, False, False, 0)
            outer.pack_start(self.ending_wrap, False, False, 0)
            # This meeting's languages ("English → 简体中文", the Mac's languageLink) and, opened from
            # it, the card that changes them; after the meeting, 改用…重新整理.
            self.lang_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
            self.lang_wrap = ui.pad(self.lang_box, 0, 12, 8, 12)
            outer.pack_start(self.lang_wrap, False, False, 0)
            self.columns = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=0, homogeneous=True)
            self.scroll = Gtk.ScrolledWindow()
            self.scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
            self.body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
            ui.pad(self.body, 6, 18, 12, 18)
            self.scroll.add(self.body)
            self.columns.pack_start(self.scroll, True, True, 0)
            self.transcript_col = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
            self.transcript_col.pack_start(self._search_row(), False, False, 0)
            self.tscroll = Gtk.ScrolledWindow()
            self.tscroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
            self.transcript = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
            ui.pad(self.transcript, 4, 18, 12, 18)
            self.tscroll.add(self.transcript)
            self._after_layout = None
            self.transcript.connect("size-allocate", self._laid_out)
            self.transcript_col.pack_start(self.tscroll, True, True, 0)
            self.columns.pack_start(self.transcript_col, True, True, 0)
            outer.pack_start(self.columns, True, True, 0)
            # What is being said, at the bottom as on the Mac: a dark card (a light one for states).
            # Only under the notes: the transcript shows what is said in place.
            ui.pad(self.live, 12, 16)
            self.live_box = ui.panel(self.live, "livebox")
            ui.pad(self.live_box, 6, 12, 0, 12)
            outer.pack_start(self.live_box, False, False, 0)
            for w in (self.ending_wrap, self.tabs_wrap, self.scroll, self.transcript_col, self.live_box, self.lang_wrap):
                w.set_no_show_all(True)
            speak_panel = ui.panel(ui.pad(self.speakbox, 10, 16), "speakbox")
            self.speakwrap = Gtk.Box()
            self.speakwrap.pack_start(ui.pad(speak_panel, 8, 12, 0, 12), True, True, 0)
            outer.pack_start(self.speakwrap, False, False, 0)
            footer = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
            ui.pad(footer, 9, 16)
            eye = ui.icon("view-reveal-symbolic", 12)
            ui.classes(eye, "secondary")
            footer.pack_start(eye, False, False, 0)
            footer.pack_start(ui.text(L("共享屏幕时此窗口可见"), 11, "tertiary", wrap=False), False, False, 0)
            self.footer_time = ui.text("", 11, "tertiary", wrap=False)
            footer.pack_end(self.footer_time, False, False, 0)
            outer.pack_start(ui.panel(footer, "footer"), False, False, 0)
        self.add(self.panel)
        self.speakwrap.set_no_show_all(True)
        self.panel.show_all()
        if self.body is not None:
            for w in (self.ending_wrap, self.tabs_wrap, self.scroll, self.transcript_col, self.live_box):
                for c in w.get_children():
                    c.show_all()
            self.search_tools.hide()  # until there is a query
            self.connect("key-press-event", self._key)
            self.connect("focus-out-event", lambda *_: self._take_keys(False) or False)

    def render(self) -> None:
        if not self._built:
            self._build()
        ctx = self.panel.get_style_context()
        if self.dark or self.subtitles:  # the subtitle bar is dark, as on the Mac
            ctx.add_class("dark")
        else:
            ctx.remove_class("dark")
        self._fill_header()
        self._fill_live()
        self._fill_speak()
        if self.subtitles:
            # Back to the text's height when a shorter line follows a long one (the bottom stays put).
            self.resize(self.get_size()[0], 1)
        if self.body is not None:
            self._layout()
            self._fill_ending()
            self._fill_languages()
            adj = self.scroll.get_vadjustment()
            keep = adj.get_value()
            self._fill_body()
            self._fill_footer()
            GLib.idle_add(lambda: adj.set_value(keep) and False)
            self._fill_transcript()

    def _fill_header(self) -> None:
        h = self.header
        ui.clear(h)
        listen = self.app.listen
        session = self.app.store.get(listen.session_id) if listen.session_id else None
        h.pack_start(ui.breathing_dot() if listen.listening else ui.dot(False), False, False, 4)
        if listen.listening and session is not None:
            h.pack_start(ui.text(L("正在听"), 13, "ink", bold=True, wrap=False, ellipsize=False), False, False, 2)
            t = ui.text(clock((datetime.now(timezone.utc) - session.startedAt).total_seconds()), 13, "tertiary", wrap=False, ellipsize=False)
            h.pack_start(t, False, False, 0)
        else:
            h.pack_start(ui.text(L("知了"), 13, "ink", bold=True, wrap=False, ellipsize=False), False, False, 2)
        h.pack_end(ui.icon_button("window-close-symbolic", L("隐藏纪要（继续听）") if not self.subtitles else L("隐藏字幕条（继续听）"),
                                  self.hide, focus=False), False, False, 0)
        if listen.listening:
            h.pack_end(ui.icon_button("media-playback-stop-symbolic", L("结束"), self._ask_end, "stop", 14, focus=False), False, False, 0)
        else:
            h.pack_end(ui.icon_button("media-record-symbolic", L("开始听"), self.app.toggle_listening, "stop", 14, focus=False), False, False, 0)
        if self.app.settings.speakEnabled:
            speaking = self.app.speak.active
            h.pack_end(ui.icon_button("audio-input-microphone-symbolic", L("停止说") if speaking else L("开始说"),
                                      self.app.toggle_speaking, "stop" if speaking else "", focus=False), False, False, 0)
        if self.subtitles:
            h.pack_end(ui.icon_button("x-office-document-symbolic", L("切到实时纪要"), lambda: self.app.set_view("notes"), focus=False), False, False, 0)
        else:
            h.pack_end(ui.icon_button("media-view-subtitles-symbolic", L("切到字幕条"), lambda: self.app.set_view("subtitles"), focus=False), False, False, 0)
            h.pack_end(ui.icon_button("view-dual-symbolic", L("收窄") if self.wide else L("纪要和原话并排"),
                                      lambda: self.set_wide(not self.wide), "on" if self.wide else "", focus=False), False, False, 0)
        if self.subtitles and self.app.ending is not None:
            # The subtitle bar has no room for buttons: it says what will happen (the Mac's notice).
            p = self.app.ending
            note = ui.text(self.app.ending_title(p) + " · " + LF("%lld 秒后结束", self.app.ending_left(p)), 12, "accent", wrap=False)
            h.pack_start(note, False, False, 8)
        h.show_all()

    # 纪要 / 文字记录, side by side

    def _layout(self) -> None:
        """What shows below the header: both columns when wide, else the chosen tab; the live
        caption only under the notes."""
        session = self._session()
        heard = len(session.lines) if session else 0
        labels = {"notes": L("纪要"),
                  "transcript": LF("文字记录 · %lld", heard) if self.app.notes.notes.is_empty and heard else L("文字记录")}
        self._setting_tab = True
        for value, b in self.tab_buttons.items():
            b.set_active(value == self.tab)
            ui.retext(b.get_child(), labels[value])
        self._setting_tab = False
        self.tabs_wrap.set_visible(not self.wide)
        self.scroll.set_visible(self.wide or self.tab == "notes")
        self.transcript_col.set_visible(self.wide or self.tab == "transcript")
        self.live_box.set_visible(not self.wide and self.tab == "notes")
        ctx = self.columns.get_style_context()
        (ctx.add_class if self.wide else ctx.remove_class)("wide")

    def _tab_toggled(self, button, value) -> None:
        if getattr(self, "_setting_tab", False):
            return
        if button.get_active():
            self.set_tab(value)
        elif value == self.tab:
            button.set_active(True)  # a segmented control: clicking the chosen tab keeps it

    def set_tab(self, tab: str) -> None:
        if tab not in ("notes", "transcript"):
            return
        self.tab = tab
        if tab == "notes":
            self._take_keys(False)
        self.render()

    def set_wide(self, wide: bool) -> None:
        self.wide = wide
        self._transcript_key = None
        x, y = self.get_position()
        w0 = self.get_size()[0]
        w = 820 if wide else 400
        self.set_size_request(w, 260)
        self.resize(w, self.get_size()[1])
        self.move(max(0, x + w0 - w), y)  # it grows to the left, keeping its right edge
        self.render()

    def _session(self):
        sid = self.app.listen.session_id
        return self.app.store.get(sid) if sid else None

    # The search in the transcript

    def _search_row(self) -> Gtk.Widget:
        self.search = Gtk.Entry()
        self.search.set_placeholder_text(L("搜索文字记录"))
        self.search.set_icon_from_icon_name(Gtk.EntryIconPosition.PRIMARY, "system-search-symbolic")
        ui.classes(self.search, "search", "notes-search")
        self.search.connect("changed", self._searched)
        self.search.connect("activate", lambda *_: self.step(1))
        # The window never takes focus, so typing in here needs it for a moment (as the Mac makes its
        # panel key for a search): from the click until Esc, or until the pointer goes elsewhere.
        self.search.connect("button-press-event", lambda *_: self._take_keys(True) or False)
        self.count = ui.text("", 12, "tertiary", wrap=False, ellipsize=False)
        self.prev_b = ui.icon_button("go-up-symbolic", L("上一个"), lambda: self.step(-1), px=13, focus=False)
        self.next_b = ui.icon_button("go-down-symbolic", L("下一个"), lambda: self.step(1), px=13, focus=False)
        self.clear_b = ui.icon_button("window-close-symbolic", L("清除"), lambda: self.search.set_text(""), px=12, focus=False)
        self.search_tools = ui.hbox(2, self.count, self.prev_b, self.next_b, self.clear_b)
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        row.pack_start(self.search, True, True, 0)
        row.pack_start(self.search_tools, False, False, 0)
        return ui.pad(row, 0, 16, 10, 16)

    def _take_keys(self, on: bool) -> None:
        if on == self._keys or self.get_window() is None:
            return
        self._keys = on
        Log.d("notes window: %s the keyboard for the search" % ("takes" if on else "gives back"))
        self.set_accept_focus(on)
        if on:
            x11.take_focus(self.get_window())
            self.get_window().focus(Gtk.get_current_event_time())
            self.present_with_time(Gtk.get_current_event_time())
            self.search.grab_focus()
        else:
            x11.never_take_focus(self.get_window())

    def _key(self, _w, event) -> bool:
        name = Gdk.keyval_name(event.keyval)
        if name == "Escape":
            if self.search.get_text():
                self.search.set_text("")
            else:
                self._take_keys(False)
            return True
        if event.state & Gdk.ModifierType.CONTROL_MASK and name in ("f", "F"):
            self.set_tab("transcript")
            self._take_keys(True)
            return True
        return False

    def _searched(self, entry) -> None:
        self.query = entry.get_text()
        self.match_index = 0
        if self.query.strip() and not self.wide and self.tab != "transcript":
            self.set_tab("transcript")
            return
        self._fill_transcript(scroll=True)

    def step(self, d: int) -> None:
        if not self.matches:
            return
        self.match_index = (self.match_index + d) % len(self.matches)
        self._fill_transcript(scroll=True)

    def _terms(self) -> list:
        """The query, plus every way the notes say that name was heard (江充 also finds 江松)."""
        q = self.query.strip()
        if not q:
            return []
        out = [q]
        for t in self.app.notes.notes.terms:
            forms = [t.name] + list(t.heard)
            if any(f and (q.lower() in f.lower() or f.lower() in q.lower()) for f in forms):
                out += [f for f in forms if f and f not in out]
        return out

    def _fill_transcript(self, scroll: bool = False) -> None:
        if not self.transcript_col.get_visible():
            return
        session = self._session()
        lines = session.lines if session else []
        terms = self._terms()
        low = [t.lower() for t in terms]

        def hit(l):
            return any(t in l.src.lower() or t in (l.dst or "").lower() for t in low)
        self.matches = [l.id for l in lines if hit(l)] if terms else []
        if self.matches:
            self.match_index %= len(self.matches)
        current = self.matches[self.match_index] if self.matches else None
        voices = self.app.settings.speakerVoices and session is not None and session.sourceFile is None
        nums = speakers.numbers(lines) if voices else {}
        names = speakers.names(session) if voices else {}
        pending = self.app.listen.listening and self.app.listen.pending > 0
        topics = [(t.start, t.title) for t in self.app.notes.notes.topics]
        key = (len(lines), lines[-1].id if lines else None, (lines[-1].dst or "") if lines else "", tuple(terms), current,
               tuple(sorted(nums.items())), tuple(sorted(names.items())), pending, tuple(topics))
        self._fill_search_tools()
        if key == self._transcript_key and not scroll:
            return
        self._transcript_key = key
        box = self.transcript
        adj = self.tscroll.get_vadjustment()
        keep = adj.get_value()
        ui.clear(box)
        target = None
        if not lines:
            box.pack_start(ui.gap(ui.text(L("说话的内容会出现在这里"), 13, "tertiary"), 8), False, False, 0)
        nxt = 0
        for l in lines:
            while nxt < len(topics) and topics[nxt][0] <= l.t:
                box.pack_start(ui.text(clock(topics[nxt][0]) + " · " + topics[nxt][1], 11, "tertiary", bold=True, wrap=False), False, False, 0)
                nxt += 1
            row = self._line(l, nums, names, terms, l.id == current)
            if terms and not hit(l):
                row.set_opacity(0.45)
            if l.id == current:
                target = row
            box.pack_start(row, False, False, 0)
        if pending:
            live = ui.hbox(6, ui.text("•••", 11, "accent", wrap=False, ellipsize=False), ui.text(L("正在识别…"), 11, "tertiary", wrap=False))
            box.pack_start(live, False, False, 0)
        box.show_all()
        # After the new rows are laid out: to the current match, to the newest line while listening
        # (it follows what's said), else where the reader was.
        if target is not None and scroll:
            def to_match():
                ok, _x, y = target.translate_coordinates(box, 0, 0)
                if ok:
                    adj.set_value(max(0, y - adj.get_page_size() / 3))
            self._after_layout = to_match
        elif not terms and self.app.listen.listening:
            self._after_layout = lambda: adj.set_value(adj.get_upper())
        elif target is None or not scroll:
            self._after_layout = lambda: adj.set_value(keep)

    def _laid_out(self, *_):
        fn, self._after_layout = self._after_layout, None
        if fn is not None:
            # Once now and once more when a column that just appeared (并排) has its final height.
            GLib.idle_add(lambda: fn() and False)
            GLib.timeout_add(150, lambda: fn() and False)

    def _fill_search_tools(self) -> None:
        searching = bool(self.query.strip())
        self.search_tools.set_visible(searching)
        if searching:
            ui.retext(self.count, "%d / %d" % (self.match_index + 1, len(self.matches)) if self.matches else L("无结果"))
            for b in (self.prev_b, self.next_b):
                b.set_sensitive(bool(self.matches))

    def _line(self, l, nums, names, terms, current) -> Gtk.Widget:
        row = ui.vbox(2)
        top = ui.hbox(8)
        if l.speaker == "me":
            top.pack_start(ui.text(L("你"), 11, "accent", bold=True, wrap=False, ellipsize=False), False, False, 0)
        elif l.id in nums:
            n = nums[l.id]
            top.pack_start(ui.text(speakers.label(n, names), 11, "spk%d" % ((n - 1) % 4 + 1), bold=True, wrap=False, ellipsize=False), False, False, 0)
        top.pack_start(ui.text(clock(l.t), 11, "tertiary", wrap=False, ellipsize=False), False, False, 0)
        row.pack_start(top, False, False, 0)
        if l.dst and l.dst != l.src:
            row.pack_start(ui.marked(l.src, terms, 12, "secondary", current, lang=l.srcLang), False, False, 0)
        row.pack_start(ui.marked(l.dst or l.src, terms, 13, "ink", current, lang=l.dstLang if l.dst else l.srcLang), False, False, 0)
        return row

    # Ending by itself

    def _names(self) -> dict:
        from ..core.support import TARGETS
        return {code: name for name, code in TARGETS}

    def _fill_languages(self) -> None:
        """While live: "English → 简体中文" (what they speak → the notes' language), which opens this
        meeting's choice in place, not a popup (the window never takes focus). After the meeting: the
        notes once more in the other language, when the meeting wasn't in mine."""
        listen = self.app.listen
        names = self._names()
        name = lambda c: names.get(c, c)  # noqa: E731
        s = self._session()
        live = listen.listening and s is not None
        mine = self.app.settings.target_code
        heard = listen.meeting_language(s.id) if s is not None else None
        notes = self.app.notes
        other = None
        if not live and s is not None and s.lines and heard and heard != mine and notes.status != notesmod.UPDATING:
            other = ("mine", mine) if listen.notes_choice(s.id) == "source" else ("source", heard)
        open_ = live and getattr(self, "lang_open", False)
        key = (live, open_, s.id if s else None, heard, listen.notes_choice(s.id) if s else None, mine, other)
        self.lang_wrap.set_visible(live or other is not None)
        if key == getattr(self, "_lang_key", None):
            return
        self._lang_key = key
        ui.clear(self.lang_box)
        if live:
            # 12 px grey and underlined, as on the Mac: a quiet way in, not a button.
            link = Gtk.Button()
            label = ui.text((name(heard) if heard else L("自动")) + " → " + name(listen.notes_code(s.id)), 12, "secondary", wrap=False)
            label.set_markup(label.get_label().replace("<span ", '<span underline="single" ', 1))
            link.add(label)
            ui.classes(link, "quietbtn")
            link.set_relief(Gtk.ReliefStyle.NONE)
            link.connect("clicked", lambda *_: self._toggle_languages())
            link.set_tooltip_text(L("这场会议的语言"))
            link.get_accessible().set_name(L("这场会议的语言"))
            link.set_can_focus(False)
            link.set_halign(Gtk.Align.START)
            self.lang_box.pack_start(link, False, False, 0)
        if open_:
            card = ui.vbox(10)
            top = ui.hbox(8)
            top.pack_start(ui.text(L("这场会议的语言"), 13, "ink", bold=True, wrap=False), True, True, 0)
            top.pack_end(ui.icon_button("window-close-symbolic", L("收起"), self._toggle_languages, focus=False), False, False, 0)
            card.pack_start(top, False, False, 0)
            card.pack_start(ui.vbox(6, ui.text(L("对方说"), 12, "secondary", bold=True, wrap=False),
                                    ui.text(name(heard) if heard else L("还没听出来"), 13, "ink", wrap=False)), False, False, 0)
            seg = ui.segmented([("mine", name(mine)), ("source", LF("%@（原文）", name(heard)) if heard else L("会议原文"))],
                               listen.notes_choice(s.id), lambda v: listen.set_notes_language(v, meeting_only=True))
            for b in seg.get_children():
                b.set_can_focus(False)
            card.pack_start(ui.vbox(6, ui.text(L("纪要"), 12, "secondary", bold=True, wrap=False), seg,
                                    ui.text(L("换了以后会马上用新语言重写纪要"), 12, "tertiary", width_chars=30)), False, False, 0)
            settings = ui.link(L("打开语言设置"), lambda: (self._toggle_languages(), self.app.show_settings()))
            settings.set_can_focus(False)
            settings.set_halign(Gtk.Align.START)
            card.pack_start(settings, False, False, 0)
            self.lang_box.pack_start(ui.panel(ui.pad(card, 14), "notice"), False, False, 0)
        if other is not None:
            sid, choice = s.id, other[0]

            def again():
                listen.notes_for[sid] = choice
                notes.generate(sid)
                GLib.timeout_add(150, lambda: self.refresh() or False)
            b = ui.button(LF("改用%@重新整理", name(other[1])), again, "outline")
            b.set_can_focus(False)
            b.set_halign(Gtk.Align.START)
            self.lang_box.pack_start(b, False, False, 0)
        # The box itself is no_show_all (it hides with the tabs), so show_all() on it does nothing.
        for c in self.lang_box.get_children():
            c.show_all()

    def _toggle_languages(self) -> None:
        self.lang_open = not getattr(self, "lang_open", False)
        self._fill_languages()

    def _ask_end(self) -> None:
        """结束 in the header (the Mac's askToEnd): nothing said yet just stops; otherwise the question
        goes in the window, never a dialog, which would take the focus from the meeting."""
        if self.subtitles:
            self.app.request_stop()
        elif self.app.recorded() is None:
            self.app.toggle_listening()
        else:
            self.confirm_end = True
            self._fill_ending()

    def _end_answer(self, end: bool) -> None:
        self.confirm_end = False
        self._fill_ending()
        if end and self.app.listen.listening:
            self.app.stop_listening()

    def _fill_ending(self) -> None:
        """已经 10 分钟没人说话 · 60 秒后结束 (MeetingEndingStrip): what will happen, and 继续记录 / 现在结束;
        under it 结束这场会议？ when 结束 was pressed. No timeout on the question: a strip that went
        away under the pointer would let the click land on the notes."""
        if getattr(self, "ending_wrap", None) is None:
            return
        listening = self.app.listen.listening
        p = self.app.ending if listening else None
        rec = self.app.recorded() if listening and getattr(self, "confirm_end", False) else None
        if rec is None:
            self.confirm_end = False
        self.ending_wrap.set_visible(p is not None or rec is not None)
        if p is None and rec is None:
            self._ending_key = None
            return
        key = (repr(p.reason) if p is not None else None, rec is not None)
        if key != getattr(self, "_ending_key", None):
            self._ending_key = key
            ui.clear(self.ending_box)
            self._ending_detail = self._confirm_detail = None
            if p is not None:
                self._ending_detail = ui.text("", 12, "secondary", wrap=False)
                self.ending_box.pack_start(ui.vbox(3, ui.text(self.app.ending_title(p), 14, "ink", bold=True, width_chars=30),
                                                   self._ending_detail), False, False, 0)
                keep = ui.button(L("继续记录"), self.app.keep_recording, "darkbtn")
                now = ui.button(L("现在结束"), self.app.toggle_listening, "outline")
                for b in (keep, now):
                    b.set_can_focus(False)
                self.ending_box.pack_start(ui.hbox(8, keep, now), False, False, 0)
            if rec is not None:
                self._confirm_detail = ui.text("", 12, "secondary", width_chars=30)
                self.ending_box.pack_start(ui.vbox(3, ui.text(L("结束这场会议？"), 14, "ink", bold=True, width_chars=30),
                                                   self._confirm_detail), False, False, 0)
                keep = ui.button(L("继续记录"), lambda: self._end_answer(False), "outline")
                end = ui.button(L("结束会议"), lambda: self._end_answer(True), "darkbtn")
                for b in (keep, end):
                    b.set_can_focus(False)
                self.ending_box.pack_start(ui.hbox(8, keep, end), False, False, 0)
            self.ending_box.show_all()
        if self._ending_detail is not None:
            ui.retext(self._ending_detail, LF("%lld 秒后结束会议并整理纪要", self.app.ending_left(p)))
        if self._confirm_detail is not None:
            ui.retext(self._confirm_detail, LF("已记录 %@ · %lld 句。结束后停止收听，并整理一份完整版纪要。", clock(rec[0]), rec[1]))

    def _state_card(self, box, icon_name, tone, title, body, action=None, on_action=None) -> None:
        self._state_shown = True  # a state (waiting, no network…) sits on a light card, not the dark caption
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        row.pack_start(ui.icon_tile(icon_name, 34, 16, tone), False, False, 0)
        texts = ui.vbox(1)
        if title:
            texts.pack_start(ui.text(title, 13, "ink", bold=True, wrap=False), False, False, 0)
        texts.pack_start(ui.text(body, 12, "secondary", width_chars=30), False, False, 0)
        texts.set_valign(Gtk.Align.CENTER)
        row.pack_start(texts, True, True, 0)
        if action:
            b = ui.button(action, on_action, "outline")
            b.set_valign(Gtk.Align.CENTER)
            b.set_can_focus(False)
            row.pack_end(b, False, False, 0)
        box.pack_start(row, False, False, 0)

    def _fill_live(self) -> None:
        box = self.live
        ui.clear(box)
        listen = self.app.listen
        session = self.app.store.get(listen.session_id) if listen.session_id else None
        # What they said: my own sentences show in the 同声传译 strip below, not twice.
        theirs = [l for l in session.lines if l.speaker != "me"] if session else []
        line = theirs[-1] if theirs else None
        kind = listen.problem_kind
        self._state_shown = False
        if kind == "source":
            # Saved only if something was heard before the audio service went away.
            body = L("音频服务已断开，本次会议记录已保存") if session is not None and session.lines else L("没能开始听")
            self._state_card(box, "audio-volume-muted-symbolic", "warn", L("系统声音中断"), body, L("开始听"), self.app.toggle_listening)
        elif kind == "network" and (line is None or listen.listening):
            self._state_card(box, "network-offline-symbolic", "warn", L("连不上 Ling"), L("请检查网络。恢复后会自动继续，断开期间的声音无法识别"))
        elif kind == "key":
            self._state_card(box, "dialog-password-symbolic", "warn", listen.problem or L("Ling key 无效"),
                             L("在设置里更换 Ling key"), L("设置"), self.app.show_settings)
        elif line is None:
            if listen.listening:
                hearing = listen.pending > 0 or listen.level >= 0.01
                self._state_card(box, "audio-speakers-symbolic", "grey",
                                 L("正在识别…") if hearing else L("等有人说话"),
                                 L("正在听电脑播放的声音，有声音后约 3 秒出字幕"))
            else:
                self._state_card(box, "audio-speakers-symbolic", "grey", None,
                                 L("点“开始听”，将电脑播放的声音转为双语字幕和纪要"))
        else:
            big = 22 if self.subtitles else 15
            # 说话人识别: who said it, once voices are told apart ("说话人 2", or the name given).
            if self.app.settings.speakerVoices and session is not None and session.sourceFile is None:
                nums = speakers.numbers(session.lines)
                if line.id in nums:
                    n = nums[line.id]
                    box.pack_start(ui.text(speakers.label(n, speakers.names(session)), 11, "spk%d" % ((n - 1) % 4 + 1),
                                           bold=True, wrap=False), False, False, 0)
            if line.dst and line.dst != line.src:
                box.pack_start(ui.text(line.src, 13 if self.subtitles else 12, "secondary",
                                       wrap=not self.subtitles, width_chars=60, lang=line.srcLang), False, False, 0)
            box.pack_start(ui.text(line.dst or line.src, big, "ink", bold=True, width_chars=60 if self.subtitles else 30,
                                   lang=line.dstLang if line.dst else line.srcLang), False, False, 0)
            if not self.subtitles and (listen.pending > 0 or kind == "busy"):
                foot = ui.hbox(6)
                foot.pack_start(ui.text("•••", 11, "accent", wrap=False, ellipsize=False), False, False, 0)
                foot.pack_start(ui.text(listen.problem if kind == "busy" else L("正在识别…"), 11, "secondary", wrap=False), False, False, 0)
                box.pack_start(ui.gap(foot, 6), False, False, 0)
        if getattr(self, "live_box", None) is not None:
            ctx = self.live_box.get_style_context()
            (ctx.add_class if self._state_shown else ctx.remove_class)("light")
        box.show_all()

    def _fill_speak(self) -> None:
        """同声传译: where my sentence is (听 → 翻译 → 说), what I said and what they hear."""
        box = self.speakbox
        sp = self.app.speak
        show = self.app.settings.speakEnabled and (sp.active or sp.last is not None or sp.problem is not None)
        ui.clear(box)
        self.speakwrap.set_visible(show)
        if not show:
            return
        from ..core.support import TARGETS
        names = {c: n for n, c in TARGETS}
        stage = {"hearing": L("正在听你说…"), "interpreting": L("正在翻译…"),
                 "speaking": L("正在说") + " · " + names.get(sp.target, sp.target)}.get(sp.stage, L("同声传译"))
        top = ui.hbox(8)
        mic = ui.icon("audio-input-microphone-symbolic", 14)
        ui.classes(mic, "accent" if sp.active else "secondary")
        top.pack_start(mic, False, False, 0)
        top.pack_start(ui.text(stage if sp.active else L("同声传译"), 11, "secondary", bold=True, wrap=False), False, False, 0)
        box.pack_start(top, False, False, 0)
        if sp.last:
            original, translation = sp.last
            if not self.subtitles:
                box.pack_start(ui.text(LF("你说：%@", original), 11, "secondary", width_chars=34, lang=sp.source), False, False, 0)
            box.pack_start(ui.text(LF("对方听到：%@", translation), 13 if not self.subtitles else 15, "ink", bold=True,
                                   width_chars=34 if not self.subtitles else 70, lang=sp.target), False, False, 0)
        if sp.problem:
            box.pack_start(ui.text(sp.problem, 11, "warn", width_chars=34), False, False, 0)
        for child in self.speakwrap.get_children():
            child.show_all()

    def _fill_footer(self) -> None:
        n = self.app.notes.notes
        when = n.updatedAt if not n.is_empty else None
        if when is None:
            ui.retext(self.footer_time, "")
            return
        ago = max(0, int((datetime.now(timezone.utc) - when).total_seconds()))
        ui.retext(self.footer_time, L("刚刚更新") if ago < 10 else LF("%lld 秒前更新", ago) if ago < 60 else LF("%lld 分钟前更新", ago // 60))

    def _banner(self, body, engine) -> None:
        """Why the notes stopped, above them, notes or not (the Mac's banner): a dead key, too many
        requests, or a round that failed; each says where the notes stop."""
        s = self._session()
        covered = engine.notes.covered
        last = s.lines[covered - 1].t if s is not None and 0 < covered <= len(s.lines) else 0.0
        if engine.status == notesmod.INVALID_KEY:
            text, tone = LF("key 已失效（令牌被删或免费额度用尽），纪要停留在 %@。", clock(last)), "error"
        elif engine.status == notesmod.RATE_LIMITED:
            text, tone = LF("请求过于频繁，稍后会自动重试。纪要停留在 %@。", clock(last)), ""
        elif engine.status == notesmod.FAILED:
            text, tone = L("这轮没整理好，下一轮会自动重试。"), ""
        else:
            return
        row = ui.hbox(10)
        row.pack_start(ui.text(text, 12, "ink", width_chars=24), True, True, 0)
        if tone == "error":
            b = ui.button(L("更换 key"), self.app.show_settings, "darkbtn")
            b.set_can_focus(False)
            b.set_valign(Gtk.Align.CENTER)
            row.pack_end(b, False, False, 0)
        card = ui.panel(ui.pad(row, 12), "notice", *([tone] if tone else []))
        body.pack_start(ui.pad(card, 0, 0, 10, 0), False, False, 0)

    def _fill_body(self) -> None:
        body = self.body
        ui.clear(body)
        engine = self.app.notes
        n = engine.notes
        listening = self.app.listen.listening
        self._banner(body, engine)
        if n.is_empty:
            hint = {notesmod.NO_KEY: L("生成纪要需要 API key"),
                    notesmod.UPDATING: L("正在整理纪要…")}.get(engine.status, L("会中每 45 秒更新") if listening else "")
            if engine.status in (notesmod.INVALID_KEY, notesmod.RATE_LIMITED, notesmod.FAILED):
                hint = ""  # the banner says it
            if hint:
                body.pack_start(ui.helper(hint), False, False, 0)
            body.show_all()
            return
        if n.title:
            body.pack_start(ui.text(n.title, 15, "heading", bold=True, width_chars=30), False, False, 0)
        if n.summary:
            body.pack_start(ui.gap(ui.text(n.summary, 13, "body", width_chars=30), 6), False, False, 0)
        for i, t in enumerate(n.topics):
            now = listening and i == len(n.topics) - 1
            row = ui.hbox(8, ui.chip(clock(t.start)))
            row.pack_start(ui.text(t.title, 13, "ink", bold=True, width_chars=24), True, True, 0)
            if now:
                badge = ui.panel(ui.pad(ui.text(L("正在讨论"), 11, "", wrap=False, ellipsize=False), 1, 6), "badge")
                badge.set_valign(Gtk.Align.CENTER)
                row.pack_start(badge, False, False, 0)
            body.pack_start(ui.gap(row, 16), False, False, 0)
            for p in t.points:
                body.pack_start(ui.gap(ui.text(p, 13, "body", width_chars=30), 4), False, False, 0)
        for title, items in ((L("结论"), [c.text for c in n.conclusions]),
                             (L("待办"), [t.text + (" · " + t.owner if t.owner else "") for t in n.todos])):
            if not items:
                continue
            body.pack_start(ui.gap(ui.text(title, 11, "tertiary", bold=True), 16), False, False, 0)
            for it in items:
                body.pack_start(ui.gap(ui.text(("☐ " if title == L("待办") else "") + it, 13, "body", width_chars=30), 4), False, False, 0)
        if engine.status == notesmod.UPDATING:
            body.pack_start(ui.gap(ui.helper(L("正在整理纪要…")), 14), False, False, 0)
        body.show_all()

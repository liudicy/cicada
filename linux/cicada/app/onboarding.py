"""First run, the Mac's four steps (Onboarding.swift, canvas 知了 Linux · 补齐 Mac): the logo and a
labelled progress bar, a large left-aligned title, white cards, the next action bottom right; then a
closing page outside the count. One difference in order: Linux recognises speech with Ming, so nothing
works without the Ling key, and 接 Ling comes first (the Mac puts it third). So: Ling key → system audio
(no permission on Linux) → sample meeting → 同声传译, if wanted → where Cicada lives."""
from __future__ import annotations

import os
import shutil
import subprocess
import threading
from collections import deque

from gi.repository import Gdk, GLib, Gtk, Pango

from ..core import ling as lingmod
from ..core.audio import Wav, sink_description
from ..core.strings import L, LF
from ..core.support import TARGETS, Log
from . import ui
from .capture import SystemAudio
from .settings_window import LING_PLATFORM, SHORTCUTS, choice, gnome_shortcut, open_uri, set_gnome_shortcut, target_options

KEY, AUDIO, SAMPLE, SPEAK, DONE = range(5)
STEPS = 4


class Onboarding(Gtk.Window):
    def __init__(self, app, step: int | None = None):
        super().__init__(title=L("知了"))
        self.app = app
        # Fixed at the Mac's 860 x 640. Not set_resizable(False): GTK then sizes the window to its
        # content's natural width, so wrapped (English) text would widen it instead of wrapping.
        geometry = Gdk.Geometry()
        geometry.min_width = geometry.max_width = 860
        geometry.min_height = geometry.max_height = 640
        self.set_geometry_hints(None, geometry, Gdk.WindowHints.MIN_SIZE | Gdk.WindowHints.MAX_SIZE)
        self.set_position(Gtk.WindowPosition.CENTER)
        self.set_wmclass("cicada", "Cicada")
        bar = Gtk.HeaderBar()
        bar.set_show_close_button(True)
        ui.classes(bar, "cicada", "ground-bar")
        self.set_titlebar(bar)
        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        ui.pad(outer, 6, 64, 36, 64)
        # The page's real width as its minimum: GTK 3 sizes a window for its content at the content's
        # minimum width, where every wrapped line wraps most, so the fixed 640 would be outgrown.
        outer.set_size_request(860 - 128, -1)
        self.head = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=14)
        outer.pack_start(self.head, False, False, 0)
        self.page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        outer.pack_start(self.page, True, True, 0)
        self.footer = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=16)
        self.footer.set_size_request(-1, 44)
        outer.pack_end(self.footer, False, False, 0)
        self.add(ui.panel(outer, "ground"))
        self.tap = None
        self.levels = deque([0.0] * 8, maxlen=8)
        self.peak = 0.0
        self.meter = None
        self.speak_setup = None  # 同声传译: None until chosen here (then True / False)
        self.connect("destroy", lambda *_: self._stop_tap())
        self.connect("key-press-event", self._key)
        self.step = step if step is not None and (step == KEY or app.ling.has_key) else AUDIO if app.ling.has_key else KEY
        self.testing = None   # 放一段测试声音: the player while it plays
        self.tested = False   # a test sound played and nothing was heard
        self.device = None    # the default output's name, once pactl has said it
        self.render()

    def _key(self, _w, event) -> bool:
        if event.keyval in (Gdk.KEY_Return, Gdk.KEY_KP_Enter) and self.next_action is not None and not isinstance(self.get_focus(), Gtk.Entry):
            self.next_action()
            return True
        return False

    def go(self, step: int) -> None:
        self._stop_tap()
        if step > DONE:
            self.app.settings.onboarded = True
            self.app.settings.save()
            self.destroy()
            return
        self.step = max(KEY, step)
        self.render()

    def render(self) -> None:
        for box in (self.head, self.page, self.footer):
            ui.clear(box)
        self.next_action = None
        self._header()
        [self._key_step, self._audio_step, self._sample_step, self._speak_step, self._done_step][self.step]()
        self.show_all()
        self.resize(860, 640)  # back to the fixed size if a step's content asked for more

    def refresh(self) -> None:
        """Engine changes (the sample being heard, 知了 麦克风 made): only the step that shows them."""
        if self.step == SAMPLE:
            GLib.idle_add(lambda: self._fill_sample() and False)

    # Frame

    def _header(self) -> None:
        self.head.pack_start(self.app_logo(34), False, False, 0)
        if self.step == DONE:
            return
        names = [L("接 Ling"), L("听声音"), L("看效果"), L("同声传译")]
        bars = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6, homogeneous=True)
        for i, name in enumerate(names):
            cap = ui.panel(Gtk.Box(), "stepbar", "on" if i <= self.step else "")
            cap.set_size_request(-1, 4)
            label = ui.text(name, 11, "ink" if i == self.step else "secondary", bold=i == self.step, wrap=False)
            bars.pack_start(ui.vbox(7, cap, label), True, True, 0)
        bars.set_margin_top(8)
        bars.get_accessible().set_name(LF("第 %lld 步，共 %lld 步：%@", self.step + 1, STEPS, names[self.step]))
        self.head.pack_start(bars, True, True, 0)

    def app_logo(self, px: int) -> Gtk.Widget:
        from .main import icon_path
        path = icon_path()
        if path:
            try:
                from gi.repository import GdkPixbuf
                img = Gtk.Image.new_from_pixbuf(GdkPixbuf.Pixbuf.new_from_file_at_size(path, px, px))
                img.set_valign(Gtk.Align.START)
                return img
            except GLib.Error:
                pass
        return ui.dot(True)

    def _title(self, title: str, sub: str) -> None:
        t = ui.text(title, 26, "heading", bold=True, width_chars=40)
        self.page.pack_start(ui.gap(t, 24 if self.step != DONE else 28), False, False, 0)
        self.page.pack_start(ui.gap(ui.text(sub, 14, "secondary", width_chars=70), 8), False, False, 0)

    def _card(self, *rows, gap: int = 24) -> Gtk.Widget:
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        for i, r in enumerate(rows):
            if i:
                sep = ui.panel(Gtk.Box(), "hair")
                sep.set_size_request(-1, 1)
                box.pack_start(ui.pad(sep, 0, 22), False, False, 0)
            box.pack_start(r, False, False, 0)
        card = ui.panel(box, "bigcard")
        self.page.pack_start(ui.gap(card, gap), False, False, 0)
        return card

    def _row(self, icon_name: str | None, title: str, detail: str, trailing: Gtk.Widget | None = None, number: int | None = None) -> Gtk.Widget:
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=16)
        if icon_name:
            row.pack_start(ui.icon_tile(icon_name, 44, 20, "grey"), False, False, 0)
        elif number is not None:
            n = ui.panel(ui.text(str(number), 12, "", bold=True, wrap=False, ellipsize=False), "stepnum")
            n.set_size_request(24, 24)
            n.get_child().set_halign(Gtk.Align.CENTER)
            n.set_valign(Gtk.Align.START)
            row.pack_start(n, False, False, 0)
        texts = ui.vbox(4, ui.text(title, 15, "ink", bold=True, width_chars=34), ui.text(detail, 13, "secondary", width_chars=40))
        texts.set_valign(Gtk.Align.CENTER)
        row.pack_start(texts, True, True, 0)
        if trailing is not None:
            trailing.set_valign(Gtk.Align.CENTER)
            row.pack_end(trailing, False, False, 0)
        return ui.pad(row, 20, 22)

    def _primary(self, text: str, action, arrow: bool = True, enabled: bool = True) -> Gtk.Button:
        b = ui.button(text, action, "bigbtn" if enabled else "bigbtn waiting", "go-next-symbolic" if arrow else None)
        if arrow:  # the arrow after the words, as on the Mac
            box = b.get_child()
            img = box.get_children()[0]
            box.reorder_child(img, 1)
        if enabled:
            self.next_action = action
        return b

    def _back(self) -> None:
        self.footer.pack_start(ui.button(L("上一步"), lambda: self.go(self.step - 1), "quietbtn bigquiet"), False, False, 0)

    def _done_mark(self, text: str) -> Gtk.Widget:
        img = ui.icon("object-select-symbolic", 14)
        return ui.hbox(6, img, ui.text(text, 13, "ink", bold=True, wrap=False, ellipsize=False))

    # 1. Ling key

    def _key_step(self) -> None:
        self._title(L("接上 Ling"), L("识别、翻译和纪要都靠它，约 1 分钟。"))
        entry = Gtk.Entry()
        entry.set_visibility(False)
        entry.set_placeholder_text("sk-…")
        ui.classes(entry, "keyentry")
        entry.set_icon_from_icon_name(Gtk.EntryIconPosition.SECONDARY, "view-reveal-symbolic")
        entry.set_icon_tooltip_text(Gtk.EntryIconPosition.SECONDARY, L("显示 key"))
        entry.connect("icon-press", lambda e, *_: e.set_visibility(not e.get_visibility()))
        self.key_status = ui.text("", 13, "secondary", width_chars=40)
        self.key_entry = entry
        platform = ui.button(L("打开 Ling 开放平台") + " ↗", lambda: open_uri(LING_PLATFORM), "outline midbtn")
        paste = ui.button(L("粘贴并检查"), self._paste, "darkbtn midbtn")
        field = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        field.pack_start(entry, True, True, 0)
        field.pack_start(paste, False, False, 0)
        second = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=14)
        n = ui.panel(ui.text("2", 12, "", bold=True, wrap=False, ellipsize=False), "stepnum")
        n.set_size_request(24, 24)
        n.get_child().set_halign(Gtk.Align.CENTER)
        n.set_valign(Gtk.Align.START)
        second.pack_start(n, False, False, 0)
        second.pack_start(ui.vbox(10, ui.text(L("复制 sk- 开头的 key，回来粘贴"), 15, "ink", bold=True, width_chars=34), field, self.key_status),
                          True, True, 0)
        steps = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        steps.pack_start(self._row(None, L("在 Ling 开放平台创建 key"), L("注册或登录后点“创建令牌”"), platform, number=1), False, False, 0)
        sep = ui.panel(Gtk.Box(), "hair")
        sep.set_size_request(-1, 1)
        steps.pack_start(ui.pad(sep, 0, 22), False, False, 0)
        steps.pack_start(ui.pad(second, 20, 22), False, False, 0)
        left = ui.panel(steps, "bigcard")
        perks = ui.vbox(4, ui.text(L("Ling 每月赠送 ¥10 额度"), 15, "ink", bold=True, width_chars=20),
                        ui.text(L("约够 10–50 小时会议"), 13, "secondary", width_chars=20))
        items = ui.vbox(10)
        for title, sub in ((L("实时纪要"), L("会中每 45 秒更新")), (L("更准的翻译"), L("人名、术语前后一致")),
                           (L("自然人声"), L("同传约 2 秒出声"))):
            items.pack_start(ui.vbox(1, ui.text(title, 13, "ink", bold=True, wrap=False), ui.text(sub, 12, "tertiary", width_chars=22)),
                             False, False, 0)
        sep2 = ui.panel(Gtk.Box(), "hair")
        sep2.set_size_request(-1, 1)
        right = ui.panel(ui.pad(ui.vbox(14, perks, sep2, items), 20), "bigcard")
        right.set_size_request(236, -1)
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=16)
        row.pack_start(left, True, True, 0)
        row.pack_start(right, False, False, 0)
        self.page.pack_start(ui.gap(row, 24), False, False, 0)
        entry.connect("activate", lambda *_: self._save_key(entry.get_text()))
        if self.app.ling.has_key and self.app.ling.key_state == lingmod.OK:
            self._key_ok()
        hint = ui.text(L("只存在这台电脑上（只有你的账户能读），只发给 Ling（ant-ling.com）"), 13, "secondary", wrap=False)
        self.footer.pack_start(hint, True, True, 0)
        self.footer.pack_end(self._primary(L("继续"), self._key_next), False, False, 0)
        GLib.idle_add(lambda: entry.grab_focus() and False)

    def _key_next(self) -> None:
        text = self.key_entry.get_text().strip()
        if text:
            self._save_key(text)
        elif self.app.ling.has_key:
            self.go(AUDIO)
        else:
            self._key_problem(L("复制 sk- 开头的 key，回来粘贴"))

    def _paste(self) -> None:
        text = (Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD).wait_for_text() or "").strip()
        if not text.startswith("sk-"):
            self._key_problem(L("剪贴板里没有 sk- 开头的 key，先在 Ling 开放平台复制。"))
            return
        self.key_entry.set_text(text)
        self._save_key(text)

    def _key_problem(self, text: str) -> None:
        ctx = self.key_status.get_style_context()
        ctx.remove_class("secondary")
        ctx.add_class("warn")
        ui.retext(self.key_status, text)

    def _key_ok(self) -> None:
        ctx = self.key_status.get_style_context()
        ctx.remove_class("warn")
        ctx.add_class("ok")
        ui.retext(self.key_status, L("已连接") + " · " + L("现在可以用了"))

    def _save_key(self, text: str) -> None:
        text = text.strip()
        if not text.startswith("sk-"):
            self._key_problem(L("复制 sk- 开头的 key，回来粘贴"))
            return
        self.app.key.save(text)
        self.app.ling.key_changed()
        ctx = self.key_status.get_style_context()
        ctx.remove_class("warn")
        ui.retext(self.key_status, L("正在检查…"))

        def check():
            state = self.app.ling.check()

            def done():
                if self.step != KEY:
                    return False
                if state == lingmod.OK:
                    self._key_ok()
                    GLib.timeout_add(700, lambda: (self.step == KEY and self.go(AUDIO)) and False)
                else:
                    self._key_problem(L("这个 key 无效，请检查是否复制完整，或重新创建一个") if state == lingmod.INVALID
                                      else L("连不上 Ling，检查网络或代理"))
                return False
            GLib.idle_add(done)
        threading.Thread(target=check, daemon=True).start()

    # 2. System audio

    def _audio_step(self) -> None:
        self._title(L("让知了听到电脑里的声音"), L("会议里对方说的话从电脑放出来，字幕和纪要都从这里来。不用麦克风，也不用授权。"))
        if self.device is None:
            threading.Thread(target=self._find_device, daemon=True).start()
        if self.tap is None:
            self.tap = SystemAudio()

            def heard(buf):
                level = Wav.rms(buf)
                self.levels.append(level)
                self.peak = max(self.peak, level)
            self.tap.on_samples = heard
            self.tap.start()
            self.meter = GLib.timeout_add(80, self._meter_tick)
        self.bars = []
        meter = ui.hbox(3)
        meter.set_size_request(-1, 18)
        for _ in range(8):
            b = ui.panel(Gtk.Box(), "meterbar")
            b.set_size_request(3, 3)
            b.set_valign(Gtk.Align.END)
            meter.pack_start(b, False, False, 0)
            self.bars.append(b)
        self.heard_row = ui.hbox(6)
        trailing = ui.hbox(12, meter, self.heard_row)
        source = self._row("audio-speakers-symbolic", L("电脑播放的声音"), self._device_line(), trailing)
        self.device_label = source.get_children()[1].get_children()[1]  # the row's detail line
        test = ui.button(L("正在播放…") if self.testing else L("放一段测试声音"), self._play_test, "accentbtn midbtn",
                         "media-playback-start-symbolic")
        test.set_sensitive(self.testing is None)
        self.test_button = test
        test_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=16)
        test_row.pack_start(ui.vbox(2, ui.text(L("没有声音在放？"), 14, "ink", wrap=False),
                                    ui.text(L("放 3 秒测试声音，从同一个设备出来"), 13, "secondary", wrap=False)), True, True, 0)
        test.set_valign(Gtk.Align.CENTER)
        test_row.pack_end(test, False, False, 0)
        self._card(source, ui.pad(test_row, 16, 22))
        # The two sounds side by side: people try speaking first, but this step hears the computer.
        sources = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12, homogeneous=True)
        sources.pack_start(self._source(L("对方的声音"), L("这一步"), [L("会议软件"), L("扬声器"), L("知了：字幕和纪要")], True), True, True, 0)
        sources.pack_start(self._source(L("你的声音 · 麦克风"), L("第 4 步再用"), [L("麦克风"), L("同声传译"), L("对方听到译文")], False), True, True, 0)
        self.page.pack_start(ui.gap(sources, 12), False, False, 0)
        self.sources = sources
        sources.set_no_show_all(True)  # _fill_silent decides, not the window's show_all
        # Played and still nothing: most likely the sound goes to another output (an HDMI screen).
        self.silent = Gtk.Box()
        self.page.pack_start(ui.gap(self.silent, 12), False, False, 0)
        self._fill_silent()
        self._back()
        self.audio_hint = Gtk.Box()  # 放一段测试声音 says what the old 音量条没动？ hint said
        self.footer.pack_start(self.audio_hint, True, True, 0)
        self.audio_next = Gtk.Box()
        self.footer.pack_end(self.audio_next, False, False, 0)
        self._heard_shown = None
        self._update_heard()

    def _meter_tick(self) -> bool:
        if self.step != AUDIO:
            self.meter = None
            return False
        for bar, level in zip(self.bars, list(self.levels)):  # the capture thread appends meanwhile
            v = ui.loudness(level)
            bar.set_size_request(3, max(3, int(v * 18)))
        self._update_heard()
        return True

    def _source(self, title: str, badge: str, flow: list, on: bool) -> Gtk.Widget:
        """One of the two sounds and where it goes, outlined in ink when it is this step's."""
        head = ui.hbox(8, ui.text(title, 14, "ink", bold=True, wrap=False),
                       ui.panel(ui.text(badge, 11, "", bold=on, wrap=False, ellipsize=False), "badge" if on else "srcbadge"))
        # One wrapping label, each step on a tinted ground (the last in ink when it is this step's):
        # GTK 3 sizes a FlowBox for its narrowest layout, which would stretch the fixed-size window.
        words = []
        for i, word in enumerate(flow):
            last = on and i == len(flow) - 1
            words.append('<span background="%s" foreground="%s">\u00a0%s\u00a0</span>'
                         % ("#15171C" if last else "#F3F4F6", "#FFFFFF" if last else "#15171C",
                            GLib.markup_escape_text(word).replace(" ", "\u00a0")))  # breaks only between steps
        path = ui.text("", 12, "", width_chars=36)
        path.set_markup('<span size="%d">%s</span>' % (round(12 * 768), '  <span foreground="#5A5F6B">→</span>  '.join(words)))
        # Whole words only: WORD_CHAR's one-character minimum width makes GTK 3 ask for a window as
        # tall as the text would be one letter wide.
        path.set_line_wrap_mode(Pango.WrapMode.WORD)
        return ui.panel(ui.pad(ui.vbox(8, head, path), 12, 16, 10, 16), "srccard", "on" if on else "")

    def _device_line(self) -> str:
        return LF("%@ · 只听声音，不录屏幕画面", self.device) if self.device else L("只听声音，不录屏幕画面")

    def _find_device(self) -> None:
        """The default output's name ("内置音频 模拟立体声") through pactl, off the main loop; none
        without pactl (the row then says only what it hears)."""
        name = None
        if shutil.which("pactl"):
            env = dict(os.environ, LC_ALL="C")
            try:
                sink = subprocess.run(["pactl", "get-default-sink"], capture_output=True, text=True, timeout=3, env=env).stdout.strip()
                # Descriptions in the desktop's language: pactl translates them under LANG.
                sinks = subprocess.run(["pactl", "list", "sinks"], capture_output=True, text=True, timeout=3,
                                       env=dict(os.environ, LC_MESSAGES="C")).stdout
                name = sink_description(sinks, sink)
            except (OSError, subprocess.SubprocessError):
                pass

        def show():
            self.device = name or ""
            if self.step == AUDIO and hasattr(self, "device_label"):
                ui.retext(self.device_label, self._device_line())
            return False
        GLib.idle_add(show)

    def _play_test(self) -> None:
        """放一段测试声音: the sample's first 3 s through the default output, the device Cicada hears:
        the bars move only if the sound really reaches the monitor."""
        from .main import sample_path
        path = sample_path()
        player = next((p for p in ("pw-play", "paplay", "aplay") if shutil.which(p)), None)
        if self.testing is not None or path is None or player is None:
            return
        try:
            self.testing = subprocess.Popen([player, path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError as e:
            Log.d("onboarding: test sound failed %s" % type(e).__name__)
            return
        Log.d("onboarding: test sound (%s)" % player)
        self.tested = False
        self._fill_silent()
        self.test_button.get_child().get_children()[-1].set_text(L("正在播放…"))
        self.test_button.set_sensitive(False)
        GLib.timeout_add(3000, self._test_ended)

    def _test_ended(self) -> bool:
        self._stop_test()
        if self.step != AUDIO:
            return False

        def settle():  # the last buffers arrive a moment after the player stops
            if self.step != AUDIO:
                return False
            self.tested = self.peak < 0.01
            Log.d("onboarding: test sound %s" % ("not heard" if self.tested else "heard"))
            self.test_button.get_child().get_children()[-1].set_text(L("放一段测试声音"))
            self.test_button.set_sensitive(True)
            self._fill_silent()
            return False
        GLib.timeout_add(400, settle)
        return False

    def _fill_silent(self) -> None:
        """The warning takes the two sounds' place, so the window keeps its fixed size."""
        ui.clear(self.silent)
        if self.tested:
            self.sources.hide()
        else:
            for child in self.sources.get_children():  # show_all() skips a no_show_all widget
                child.show_all()
            self.sources.show()
        if not self.tested:
            self.silent.hide()
            return
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        row.pack_start(ui.icon("dialog-warning-symbolic", 16), False, False, 0)
        row.get_children()[0].set_valign(Gtk.Align.START)
        ui.classes(row.get_children()[0], "link")
        row.pack_start(ui.vbox(2, ui.text(L("测试声音放了，但知了没听到"), 14, "ink", bold=True, wrap=False),
                               ui.text(L("看看声音是不是从别的设备出来（比如 HDMI 显示器），或被静音了。"), 13, "ink", width_chars=50)),
                       True, True, 0)
        # GNOME's own sound page; other desktops differ, so only there.
        if "GNOME" in os.environ.get("XDG_CURRENT_DESKTOP", "").upper() and shutil.which("gnome-control-center"):
            b = ui.button(L("打开声音设置"), lambda: subprocess.Popen(["gnome-control-center", "sound"]), "outline")
            b.set_valign(Gtk.Align.CENTER)
            row.pack_end(b, False, False, 0)
        strip = ui.panel(ui.pad(row, 12, 16), "endingstrip")
        self.silent.pack_start(strip, True, True, 0)
        self.silent.show_all()

    def _update_heard(self) -> None:
        heard = self.peak >= 0.01
        if heard:
            self.app.setup_step_done("heardSystemAudio")
            if self.tested:
                self.tested = False
                self._fill_silent()
        if self._heard_shown == heard:
            return
        self._heard_shown = heard
        ui.clear(self.heard_row)
        ui.clear(self.audio_next)
        self.audio_hint.set_opacity(0 if heard else 1)
        if heard:
            self.heard_row.pack_start(self._done_mark(L("已收到声音")), False, False, 0)
        else:
            self.heard_row.pack_start(ui.text(L("等声音…"), 13, "secondary", wrap=False), False, False, 0)
        # 继续 stays grey until sound arrives, as on the Mac, but still works (a quiet machine).
        self.audio_next.pack_start(self._primary(L("继续"), lambda: self.go(SAMPLE), enabled=True), False, False, 0)
        if not heard:
            ui.classes(self.audio_next.get_children()[0], "waiting")
        self.heard_row.show_all()
        self.audio_next.show_all()

    # 3. Sample

    def _sample_step(self) -> None:
        self._title(L("放一段会议试试"), L("一段 9 秒的英文会议，字幕会跟着声音实时出来。"))
        self.stage = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        self.stage.set_valign(Gtk.Align.END)
        stage = ui.panel(ui.pad(self.stage, 16), "samplestage")
        stage.set_size_request(-1, 184)
        self.page.pack_start(ui.gap(stage, 18), False, False, 0)
        s = self.app.settings

        def set_target(v):
            s.target = v
            s.save()
            self.app.settings_changed()
        self.heard_value = ui.text("", 13, "ink", bold=True, wrap=False, ellipsize=False)
        combos = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12, homogeneous=True)
        for label, control in ((L("听到"), self.heard_value), (L("翻译成"), choice(target_options(), s.target, set_target))):
            r = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
            r.pack_start(ui.text(label, 13, "secondary", wrap=False), False, False, 0)
            control.set_valign(Gtk.Align.CENTER)
            r.pack_end(control, False, False, 0)
            card = ui.panel(ui.pad(r, 0, 14), "midcard")
            card.set_size_request(-1, 44)
            r.set_valign(Gtk.Align.CENTER)
            combos.pack_start(card, True, True, 0)
        self.page.pack_start(ui.gap(combos, 14), False, False, 0)
        teaser = ui.text(L("开会时，纪要会跟着字幕一起更新。"), 14, "ink", bold=True, wrap=False)
        self.page.pack_start(ui.gap(ui.panel(ui.pad(teaser, 12, 18), "midcard"), 14), False, False, 0)
        self._back()
        self.footer.pack_start(Gtk.Box(), True, True, 0)
        self.sample_buttons = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=16)
        self.footer.pack_end(self.sample_buttons, False, False, 0)
        self._fill_sample()

    def _fill_sample(self) -> None:
        if self.step != SAMPLE or not hasattr(self, "stage"):
            return
        listen = self.app.listen
        s = self.app.store.get(listen.session_id) if listen.session_id else None
        line = s.lines[-1] if s and s.lines else None
        playing = listen.listening and listen.source_kind == "file"
        ui.clear(self.stage)
        if line is not None:
            if line.dst and line.dst != line.src:
                src = ui.text(line.src, 12, "stage-dim", width_chars=60, lang=line.srcLang)
                src.set_justify(Gtk.Justification.CENTER)
                src.set_xalign(0.5)
                self.stage.pack_start(src, False, False, 0)
            dst = ui.text(line.dst or line.src, 17, "stage-ink", bold=True, width_chars=50, lang=line.dstLang)
            dst.set_justify(Gtk.Justification.CENTER)
            dst.set_xalign(0.5)
            self.stage.pack_start(dst, False, False, 0)
        elif playing:
            t = ui.text(L("正在识别…"), 14, "stage-dim", wrap=False)
            t.set_xalign(0.5)
            self.stage.pack_start(t, False, False, 0)
        else:
            play = ui.button(L("播放示例"), self._play, "pillkeep bigplay", "media-playback-start-symbolic")
            play.set_halign(Gtk.Align.CENTER)
            self.stage.set_valign(Gtk.Align.CENTER)
            self.stage.pack_start(play, False, False, 0)
        if line is not None or playing:
            self.stage.set_valign(Gtk.Align.END)
        self.stage.show_all()
        from .records_window import lang_name
        ui.retext(self.heard_value, LF("自动 · %@", lang_name(line.srcLang)) if line is not None else L("自动识别"))
        ui.clear(self.sample_buttons)
        self.sample_buttons.pack_start(self._primary(L("继续"), lambda: self.go(SPEAK)), False, False, 0)
        self.sample_buttons.show_all()

    def _play(self) -> None:
        self.app.play_sample()
        if self.app.listen.listening:
            self.app.setup_step_done("sampleSeen")
        self._fill_sample()

    # 4. 同声传译

    def _speak_step(self) -> None:
        app = self.app
        on = self.speak_setup if self.speak_setup is not None else app.settings.speakEnabled
        lang = dict((c, n) for n, c in TARGETS).get(app.settings.speak_from_code, app.settings.speak_from_code)
        head = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=24)
        texts = ui.vbox(8, ui.text(L("开会时要说外语吗？"), 26, "heading", bold=True, width_chars=24),
                        ui.text(LF("点一下“开始说”或按快捷键说%@，对方听到翻译后的语音。", lang), 14, "secondary", width_chars=50))
        head.pack_start(texts, True, True, 0)
        if on:
            head.pack_end(self._keycaps(), False, False, 0)
        self.page.pack_start(ui.gap(head, 24), False, False, 0)
        if not on:
            row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=14, homogeneous=True)
            for title, detail, action in ((L("要，现在设置"), L("约 1 分钟，会建一个“知了 麦克风”，不用装驱动"), self._speak_yes),
                                          (L("先不用"), L("以后在设置 › 同声传译里打开"), lambda: self.go(DONE))):
                b = Gtk.Button()
                b.add(ui.pad(ui.vbox(8, ui.text(title, 16, "ink", bold=True, wrap=False), ui.text(detail, 13, "secondary", width_chars=30)), 22))
                ui.classes(b, "choicecard")
                b.connect("clicked", lambda _b, a=action: a())
                row.pack_start(b, True, True, 0)
            self.page.pack_start(ui.gap(row, 28), False, False, 0)
            self._back()
            return
        made = app.room.on
        mic_state = self._done_mark(L("已建好")) if made else ui.text(L("没能建好知了麦克风"), 13, "warn", wrap=False)
        keys = gnome_shortcut("speak")
        if keys:
            key_state = self._done_mark(L("已添加"))
        elif keys is None:
            key_state = ui.text(L("在系统的键盘设置里绑定"), 12, "secondary", wrap=False)
        else:
            key_state = ui.button(L("添加这个快捷键"), self._add_shortcut, "outline midbtn")
        self._card(self._row(None, L("知了 麦克风"), L("译文从这里传给会议软件，不用安装驱动"), mic_state),
                   self._row(None, L("开始 / 停止说的快捷键"), L("在任何窗口里都能用"), key_state), gap=22)
        tip = ui.text(L("在会议软件里把麦克风选成“知了 麦克风”（或“默认”），并戴上耳机：外放时对方的声音会被当成你说的。"),
                      13, "ink", width_chars=80)
        self.page.pack_start(ui.gap(ui.panel(ui.pad(tip, 12, 16), "endingstrip"), 14), False, False, 0)
        if self.speak_setup:
            self.footer.pack_start(ui.button(L("先不用了"), self._speak_no, "quietbtn bigquiet"), False, False, 0)
        else:
            self._back()
        self.footer.pack_start(Gtk.Box(), True, True, 0)
        self.footer.pack_end(self._primary(L("完成"), lambda: self.go(DONE), arrow=False), False, False, 0)

    def _keycaps(self) -> Gtk.Widget:
        caps = ui.hbox(6)
        for k, w in (("Super", 72), ("⇧", 52), ("S", 52)):
            label = ui.text(k, 11, "secondary", wrap=False, ellipsize=False)
            label.set_valign(Gtk.Align.END)
            label.set_halign(Gtk.Align.START)
            cap = ui.panel(ui.pad(label, 6, 8, 7, 8), "keycap")
            cap.set_size_request(w, 52)
            caps.pack_start(cap, False, False, 0)
        hint = ui.text(L("可在设置中更改"), 11, "tertiary", wrap=False)
        hint.set_halign(Gtk.Align.END)
        box = ui.vbox(6, caps, hint)
        box.set_valign(Gtk.Align.START)
        return box

    def _speak_yes(self) -> None:
        self.speak_setup = True
        self.app.set_speak_enabled(True)
        self.render()

    def _speak_no(self) -> None:
        self.speak_setup = None
        self.app.set_speak_enabled(False)
        self.render()

    def _add_shortcut(self) -> None:
        from ..core.support import Paths
        set_gnome_shortcut("speak", self.app.launcher + (" --dev" if Paths.dev else "") + " --speak")
        self.render()

    # Closing

    def _done_step(self) -> None:
        tray = self.app.tray is not None
        self._title(L("好了，知了在顶栏") if tray else L("好了，可以开始了"),
                    L("接下来会打开会议记录窗口，之后从右上角的图标找到它。") if tray
                    else L("接下来会打开会议记录窗口；开会时在这里点“开始听”。"))
        if tray:
            self.page.pack_start(ui.gap(self._top_bar(), 24), False, False, 0)
        tips = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12, homogeneous=True)
        speak_keys = gnome_shortcut("speak")
        items = [(L("开会时点它") if tray else L("开会时点“开始听”"), L("开始听，出字幕和纪要"))]
        if self.app.settings.speakEnabled:
            items.append((LF("按 %@ 说话", SHORTCUTS["speak"][2].replace(" + Shift + ", " ⇧ ")) if speak_keys else L("点纪要窗的麦克风说话"),
                          L("对方听到翻译后的语音")))
        items.append((L("会后看记录"), L("每场会都存在会议记录里")))
        for title, sub in items:
            tips.pack_start(ui.panel(ui.pad(ui.vbox(4, ui.text(title, 14, "ink", bold=True, wrap=False),
                                                    ui.text(sub, 12, "tertiary", width_chars=22)), 16), "tipcard"), True, True, 0)
        self.page.pack_start(ui.gap(tips, 24), False, False, 0)
        if not tray:
            note = ui.text(L("顶栏没有知了的图标？装上 AppIndicator 扩展，就能从顶栏打开知了。"), 12, "secondary", wrap=False)
            self.page.pack_start(ui.gap(note, 18), False, False, 0)
        self.footer.pack_start(Gtk.Box(), True, True, 0)
        self.footer.pack_end(self._primary(L("开始使用"), lambda: self.go(DONE + 1), arrow=False), False, False, 0)

    def _top_bar(self) -> Gtk.Widget:
        """A slice of GNOME's top bar with Cicada's icon ringed: where to look once this window is gone."""
        bar = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=16)
        bar.set_size_request(-1, 32)
        act = ui.panel(ui.pad(ui.text(L("活动"), 12, "topbar-ink", wrap=False, ellipsize=False), 2, 10), "topbar-pill")
        act.set_valign(Gtk.Align.CENTER)
        bar.pack_start(act, False, False, 0)
        from datetime import datetime
        clock = ui.text(datetime.now().strftime("%H:%M"), 12, "topbar-ink", bold=True, wrap=False, ellipsize=False)
        bar.set_center_widget(clock)
        for name in ("battery-full-symbolic", "audio-volume-high-symbolic", "network-wireless-signal-excellent-symbolic"):
            img = ui.icon(name, 14)
            ui.classes(img, "topbar-ink")
            bar.pack_end(img, False, False, 0)
        ring = ui.panel(self.app_logo(16), "topbar-ring")
        ring.set_size_request(26, 24)
        ring.get_child().set_halign(Gtk.Align.CENTER)
        ring.get_child().set_valign(Gtk.Align.CENTER)
        ring.set_valign(Gtk.Align.CENTER)
        bar.pack_end(ring, False, False, 0)
        top = ui.panel(ui.pad(bar, 0, 14), "topbar")
        arrow = ui.vbox(4, ui.icon("go-up-symbolic", 14), ui.text(L("就是它"), 13, "link", bold=True, wrap=False, ellipsize=False))
        arrow.get_children()[0].get_style_context().add_class("link")
        arrow.set_halign(Gtk.Align.END)
        arrow.set_margin_end(96)
        arrow.set_margin_top(8)
        below = Gtk.Box()
        below.set_size_request(-1, 76)
        below.pack_end(arrow, False, False, 0)
        return ui.panel(ui.vbox(0, top, below), "bigcard", "clip")

    def _stop_test(self) -> None:
        if self.testing is not None:
            player, self.testing = self.testing, None
            player.terminate()
            threading.Thread(target=player.wait, daemon=True).start()  # reaped, not left a zombie

    def _stop_tap(self) -> None:
        self._stop_test()
        if self.meter is not None:
            GLib.source_remove(self.meter)
            self.meter = None
        if self.tap is not None:
            self.tap.on_samples = None
            self.tap.stop()
            self.tap = None

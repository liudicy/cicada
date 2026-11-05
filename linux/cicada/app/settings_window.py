"""设置, GNOME preferences style: groups of boxed-list rows, the title and a grey line on the left and
the control on the right. Ling key, languages, what shows while listening (and 登录时启动), the
model, about."""
from __future__ import annotations

import os
import subprocess
import threading
import time

from gi.repository import Gdk, GLib, Gtk

from .. import VERSION
from ..core import ling as lingmod
from ..core.ling import AIKey
from ..core.strings import L, LF
from ..core.support import TARGETS, Paths, follow_system_target, my_language, system_languages
from . import ui

LING_PLATFORM = "https://chat.ant-ling.com/platform/api"


def open_uri(uri: str) -> None:
    try:
        Gtk.show_uri_on_window(None, uri, Gtk.get_current_event_time())
    except GLib.Error:
        subprocess.Popen(["xdg-open", uri], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def choice(options, current, on_change) -> Gtk.ComboBoxText:
    c = Gtk.ComboBoxText()
    for value, label in options:
        c.append(value, label)
    c.set_active_id(current if current in [o[0] for o in options] else options[0][0])
    c.connect("changed", lambda w: on_change(w.get_active_id()))
    c.set_size_request(170, -1)
    return c


def target_options():
    """跟随系统（简体中文 / English）: my language, then what it becomes when they speak mine."""
    names = {code: name for name, code in TARGETS}
    prefs = system_languages()
    mine = my_language(prefs)
    both = " / ".join(names.get(c, c) for c in (mine, follow_system_target(mine, prefs)))
    return [("system", LF("跟随系统（%@）", both))] + [(code, name) for name, code in TARGETS]


# 登录时启动: an XDG autostart entry, the file's presence being the setting.

def autostart_path() -> str:
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    return os.path.join(base, "autostart", "com.wquguru.cicada%s.desktop" % (".dev" if Paths.dev else ""))


def autostart_enabled() -> bool:
    return os.path.isfile(autostart_path())


def set_autostart(on: bool, launcher: str) -> None:
    path = autostart_path()
    if not on:
        try:
            os.remove(path)
        except OSError:
            pass
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    # --background: a login start stays in the top bar; opening 知了 by hand shows its window.
    with open(path, "w", encoding="utf-8") as f:
        f.write("[Desktop Entry]\nType=Application\nName=Cicada\nName[zh_CN]=知了\n"
                "Exec=%s%s --background\nIcon=cicada\nTerminal=false\nNoDisplay=true\nX-GNOME-Autostart-enabled=true\n"
                % (launcher, " --dev" if Paths.dev else ""))


def refresh_autostart(launcher: str) -> None:
    """An autostart file from before --background (or from another install place) is rewritten."""
    path = autostart_path()
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except OSError:
        return
    if "--background" not in text or ("Exec=%s " % launcher) not in text:
        set_autostart(True, launcher)


# GNOME custom keyboard shortcuts: `cicada --toggle` (开始 / 结束听) and `cicada --speak` (开始 / 停止说).

PREVIEW = {  # what 试听 says, spoken text not UI (not L()): one per language a voice speaks
    "en": "This is the voice the room will hear.", "zh": "这是对方会听到的声音。",
    "ja": "これは相手に聞こえる声です。", "ko": "상대방에게 들리는 목소리입니다.",
    "es": "Esta es la voz que oirán los demás.", "fr": "Voici la voix que les autres entendront.",
    "de": "So klingt die Stimme, die die anderen hören.",
}
SHORTCUTS = {"toggle": ("cicada", "<Super><Shift>c", "Super + Shift + C"),
             "speak": ("cicada-speak", "<Super><Shift>s", "Super + Shift + S")}
MEDIA_KEYS = "org.gnome.settings-daemon.plugins.media-keys"
CUSTOM = "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding"


def _custom_path(which: str) -> str:
    return "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/%s%s/" % (SHORTCUTS[which][0], "-dev" if Paths.dev else "")


def gnome_shortcut(which: str):
    """None off GNOME; "" when not added; else the key, as shown."""
    try:
        from gi.repository import Gio
        source = Gio.SettingsSchemaSource.get_default()
        if not source or not source.lookup(MEDIA_KEYS, True):
            return None
        keys = Gio.Settings.new(MEDIA_KEYS)
        if _custom_path(which) not in keys.get_strv("custom-keybindings"):
            return ""
        return SHORTCUTS[which][2]
    except Exception:  # noqa: BLE001 - any failure: treat as not GNOME
        return None


def set_gnome_shortcut(which: str, command: str) -> None:
    from gi.repository import Gio
    keys = Gio.Settings.new(MEDIA_KEYS)
    paths = keys.get_strv("custom-keybindings")
    if _custom_path(which) not in paths:
        keys.set_strv("custom-keybindings", paths + [_custom_path(which)])
    one = Gio.Settings.new_with_path(CUSTOM, _custom_path(which))
    one.set_string("name", "Cicada" if which == "toggle" else "Cicada · 同声传译")
    one.set_string("command", command)
    one.set_string("binding", SHORTCUTS[which][1])


class SettingsWindow(Gtk.Window):
    def __init__(self, app):
        super().__init__(title=L("设置") + " · " + L("知了"))
        self.app = app
        self.set_default_size(640, 760)
        self.set_position(Gtk.WindowPosition.CENTER)
        self.set_wmclass("cicada", "Cicada")
        self.connect("delete-event", lambda *_: self.hide() or True)
        self.connect("key-press-event", lambda _w, e: (self.hide() or True) if e.keyval == Gdk.KEY_Escape else False)
        bar = Gtk.HeaderBar()
        bar.set_show_close_button(True)
        bar.set_title(L("设置"))
        ui.classes(bar, "cicada", "ground-bar")
        self.set_titlebar(bar)
        s = app.settings

        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        ui.classes(scroll, "ground")
        page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=20)
        ui.pad(page, 8, 32, 28, 32)
        scroll.add(page)
        self.add(scroll)

        def save():
            s.save()
            app.settings_changed()

        # Ling key
        self.key_line = ui.text("", 13, "ink mono", wrap=False)
        self.key_status = ui.hbox(6)
        key_left = ui.vbox(4, self.key_line, self.key_status)
        self.change_button = ui.button(L("更换…"), self._toggle_entry, "outline")
        self.remove_button = ui.button(L("删除"), self.remove_key, "dangertext")
        key_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        key_row.pack_start(key_left, True, True, 0)
        for b in (self.change_button, self.remove_button):
            b.set_valign(Gtk.Align.CENTER)
            key_row.pack_start(b, False, False, 0)
        key_row = ui.panel(ui.pad(key_row, 10, 14), "prow")
        self.key_entry = Gtk.Entry()
        self.key_entry.set_visibility(False)
        self.key_entry.set_placeholder_text("sk-…")
        self.key_entry.connect("activate", lambda *_: self.save_key())
        self.key_entry.set_icon_from_icon_name(Gtk.EntryIconPosition.SECONDARY, "view-reveal-symbolic")
        self.key_entry.set_icon_tooltip_text(Gtk.EntryIconPosition.SECONDARY, L("显示 key"))
        self.key_entry.connect("icon-press", lambda e, *_: e.set_visibility(not e.get_visibility()))
        entry_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        entry_row.pack_start(self.key_entry, True, True, 0)
        entry_row.pack_start(ui.button(L("保存"), self.save_key, "darkbtn"), False, False, 0)
        self.entry_row = ui.panel(ui.pad(entry_row, 12, 16), "prow")
        get_key = Gtk.Button()
        get_key.add(ui.pad(ui.hbox(8, ui.text(L("获取 Ling key"), 13, "ink", wrap=False)), 10, 14))
        get_key.get_child().pack_end(ui.icon("external-link-symbolic", 14), False, False, 0)
        ui.classes(get_key, "linkrow")
        get_key.connect("clicked", lambda *_: open_uri(LING_PLATFORM))
        # Shown and hidden by show_key_state; show_all() must leave them alone.
        self.entry_row.set_no_show_all(True)
        entry_row.show_all()
        self.key_group = ui.boxed([key_row, self.entry_row, get_key])
        page.pack_start(self._group(L("Ling key"), self.key_group,
                                    L("只存在这台电脑上（只有你的账户能读），只发给 Ling（ant-ling.com）")), False, False, 0)

        # Languages
        def set_target(v):
            s.target = v
            save()

        def set_notes(v):
            app.listen.set_notes_language(v)  # saves, and rewrites the live meeting's notes in it

        def set_ui(v):
            s.uiLanguage = v
            save()
        names = {code: name for name, code in TARGETS}
        heard = app.listen.meeting_language(app.listen.session_id) if app.listen.listening else None
        notes_options = [("mine", LF("我的语言 · %@", names.get(s.target_code, s.target_code))),
                         ("source", LF("会议原文 · %@", names.get(heard, heard)) if heard else L("会议原文"))]
        combos = [choice(target_options(), s.target, set_target),
                  ui.segmented(notes_options, s.notesLanguage, set_notes),
                  choice([("system", L("跟随系统")), ("zh-Hans", "简体中文"), ("en", "English"), ("ja", "日本語"), ("ko", "한국어")],
                         s.uiLanguage, set_ui)]
        ui_row = ui.prow(L("界面语言"), combos[2], L("重启知了后生效"))
        page.pack_start(self._group(L("语言"), ui.boxed([ui.prow(L("翻译成"), combos[0]), ui.prow(L("纪要语言"), combos[1], L("实时纪要和完整版同一种语言")), ui_row])),
                        False, False, 0)

        # While listening
        switch = Gtk.Switch()
        switch.set_active(autostart_enabled())
        switch.connect("notify::active", lambda w, _p: set_autostart(w.get_active(), app.launcher))
        warn = ui.hbox(12)
        warn_icon = ui.icon("view-reveal-symbolic", 15)
        ui.classes(warn_icon, "warn")
        warn_icon.set_valign(Gtk.Align.START)
        warn.pack_start(warn_icon, False, False, 0)
        warn.pack_start(ui.text(L("Linux 下共享屏幕时对方能看到纪要窗。共享前点它右上角的 × 隐藏，知了会继续听。"), 12, "", width_chars=50), True, True, 0)
        warn_row = ui.panel(ui.pad(warn, 10, 14), "warnrow")
        page.pack_start(self._group(L("正在听时"), ui.boxed([
            ui.prow(L("悬浮窗"), ui.segmented([("notes", L("实时纪要")), ("subtitles", L("字幕条"))], s.view, app.set_view)),
            ui.prow(L("登录时打开"), switch, L("登录后在顶栏待命")),
            self._voices_row(),
            self._shortcut_row(),
            warn_row])), False, False, 0)

        page.pack_start(self._speak_group(combos), False, False, 0)
        page.pack_start(self._end_group(), False, False, 0)

        # Model
        def set_model(v):
            s.model = v
            app.ling.model = v
            save()
        model = choice([("Ling-3.1-flash", "Ling-3.1-flash"), ("Ling-3.0-flash", "Ling-3.0-flash")], s.model, set_model)
        combos.append(model)
        page.pack_start(self._group(L("模型"), ui.boxed([
            ui.prow(L("翻译与纪要模型"), model, L("3.1 更准；3.0 更快、更省")),
            ui.prow(L("语音识别"), ui.text(L("Ming（云端）"), 12, "tertiary", wrap=False))])), False, False, 0)

        # About
        # 版本 with the update check under it and its button (UpdateViews' settings row).
        self.version_slot = ui.hbox(0)
        self.version_row = ui.prow(LF("版本 %@", VERSION + " · Linux"), self.version_slot, " ")
        rows = [self.version_row]
        for label, action in ((L("打开记录文件夹"), lambda: self._open_folder(Paths.sessions())),
                              (L("打开日志"), lambda: open_uri("file://" + Paths.log())),
                              (L("新手引导"), app.show_onboarding)):
            b = Gtk.Button()
            inner = ui.hbox(8, ui.text(label, 13, "ink", wrap=False))
            chevron = ui.icon("go-next-symbolic", 12)
            ui.classes(chevron, "tertiary")
            inner.pack_end(chevron, False, False, 0)
            b.add(ui.pad(inner, 10, 14))
            ui.classes(b, "linkrow")
            b.connect("clicked", lambda _b, a=action: a())
            rows.append(b)
        page.pack_start(self._group(L("关于"), ui.boxed(rows)), False, False, 0)

        for c in combos:
            ui.no_wheel(c, scroll)
        app.ling.on_change(lambda: GLib.idle_add(self.show_key_state))
        self.connect("show", lambda *_: self.show_key_state())
        self.refresh_version()

    def refresh_version(self) -> None:
        """The update line and button: 检查更新, 安装并重新打开 / 重试, nothing while downloading."""
        u = self.app.updates
        detail = u.detail()
        sub = next((w for w in _labels(self.version_row) if w.get_style_context().has_class("secondary")
                    or w.get_style_context().has_class("tertiary")), None)
        if sub is not None:
            ui.retext(sub, detail or " ")
            ui.classes(sub, "err") if u.failure and u.update else sub.get_style_context().remove_class("err")
        key = (u.update is not None, u.progress is not None, bool(u.failure), u.check == "checking", u.after_meeting)
        if key == getattr(self, "_version_key", None):
            return
        self._version_key = key
        ui.clear(self.version_slot)
        if u.update is not None and u.progress is None:
            if u.after_meeting:
                return
            b = ui.button(L("重试") if u.failure else L("安装并重新打开"), u.install, "outline" if u.failure else "darkbtn")
        elif u.update is None:
            b = ui.button(L("检查更新"), u.check_now, "outline")
            b.set_sensitive(u.check != "checking")
        else:
            return
        b.set_valign(Gtk.Align.CENTER)
        self.version_slot.pack_start(b, False, False, 0)
        self.version_slot.show_all()

    def _end_group(self) -> Gtk.Widget:
        """结束会议: when a meeting ends by itself (meeting_end.py), as the Mac's settings say it."""
        s = self.app.settings

        def save():
            s.save()
            self.app.settings_changed()
        app_switch = Gtk.Switch()
        app_switch.set_active(s.endWithApp)
        app_switch.connect("notify::active", lambda w, _p: (setattr(s, "endWithApp", w.get_active()), save()))
        minutes = ui.prow(L("多久算没人说话"), ui.segmented([(str(m), LF("%lld 分钟", m)) for m in (5, 10, 15, 30)],
                                                       str(s.silenceMinutes),
                                                       lambda v: (setattr(s, "silenceMinutes", int(v)), save())))
        # Hidden after the window's show_all() (a no_show_all row would stay empty once shown).
        self.connect("show", lambda *_: minutes.set_visible(s.silenceEnd != "off"))

        def set_silence(v):
            s.silenceEnd = v
            save()
            minutes.set_visible(v != "off")
        silence = ui.prow(L("没人说话时"), ui.segmented([("prompt", L("提醒后结束")), ("end", L("直接结束")), ("off", L("一直记录"))],
                                                    s.silenceEnd, set_silence), L("按识别出的话算，背景音乐不算"))
        return self._group(L("结束会议"), ui.boxed([
            ui.prow(L("会议应用挂断后结束"), app_switch, L("Zoom、腾讯会议、飞书、Teams 等")), silence, minutes]))

    def _shortcut_row(self, which: str = "toggle") -> Gtk.Widget:
        """From anywhere: GNOME runs `cicada --toggle` / `--speak` on a custom keyboard shortcut.
        Added only when the user asks (it writes to their keyboard settings)."""
        title = L("开始 / 结束听的快捷键") if which == "toggle" else L("开始 / 停止说的快捷键")
        flag = " --toggle" if which == "toggle" else " --speak"
        state = gnome_shortcut(which)
        if state is None:  # not GNOME: say how
            return ui.prow(title, None, LF("在系统的键盘设置里，把命令 %@ 绑到一个按键", self.app.launcher + flag))
        label = ui.text(state or "", 12, "secondary", wrap=False)

        def add():
            set_gnome_shortcut(which, self.app.launcher + (" --dev" if Paths.dev else "") + flag)
            ui.retext(label, SHORTCUTS[which][2])
            button.set_visible(False)
        button = ui.button(L("添加"), add, "outline")
        box = ui.hbox(8, label, button)
        if state:
            button.set_visible(False)
            button.set_no_show_all(True)
        return ui.prow(title, box, L("在任何窗口里都能用"))

    def _voices_row(self) -> Gtk.Widget:
        """说话人识别: on by default, as on the Mac; off when this build has no voiceprint library."""
        app = self.app
        sw = Gtk.Switch()
        sw.set_valign(Gtk.Align.CENTER)
        ok = app.voices_available
        sw.set_active(ok and app.settings.speakerVoices)
        sw.set_sensitive(ok)
        sw.connect("notify::active", lambda w, _p: app.set_speaker_voices(w.get_active()))
        return ui.prow(L("说话人识别"), sw, L("按声音标出说话人 1、2…，只在这台电脑上处理") if ok
                       else L("这个版本缺少声纹组件，暂时用不了"))

    def _speak_group(self, combos) -> Gtk.Widget:
        """同声传译: on/off (makes 知了 麦克风), my language, what they hear, the voice, 试听, the shortcut."""
        from ..core import voices as voicemod
        from ..core.support import TARGETS
        app, s = self.app, self.app.settings
        names = {c: n for n, c in TARGETS}
        rows = []
        switch = Gtk.Switch()
        switch.set_active(s.speakEnabled)
        dependents = []

        def toggled(w, _p):
            on = w.get_active()
            if on != s.speakEnabled and not app.set_speak_enabled(on):
                w.set_active(False)
                self.speak_status.set_visible(True)
                ui.retext(self.speak_status, L("没能建好知了麦克风"))
            for d in dependents:
                d.set_sensitive(s.speakEnabled)
        switch.connect("notify::active", toggled)
        rows.append(ui.prow(L("同声传译"), switch, L("你说的话翻译后，用“知了 麦克风”传给对方")))

        def set_from(v):
            s.speakFrom = v
            s.save()

        def set_to(v):
            s.speakTo = v
            s.save()
            fill_voices()
        mine = choice([("system", LF("和字幕一样（%@）", names.get(s.target_code, s.target_code)))] + [(c, n) for n, c in TARGETS],
                      s.speakFrom, set_from)
        theirs = choice([("room", LF("跟随对方（%@）", names.get(app.speak.target, app.speak.target)))] +
                        [(c, names.get(c, c)) for c in voicemod.ROOM_LANGUAGES], s.speakTo, set_to)
        voice = Gtk.ComboBoxText()
        voice.set_size_request(170, -1)

        def fill_voices():
            code = app.speak.target
            voice.handler_block_by_func(set_voice) if getattr(voice, "_wired", False) else None
            voice.remove_all()
            for v, n, tags in voicemod.voices(code):
                voice.append(v, "%s · %s" % (n, "、".join(L(t) for t in tags)))
            voice.set_active_id(app.speak.voice(code) or "")
            if getattr(voice, "_wired", False):
                voice.handler_unblock_by_func(set_voice)

        def set_voice(w):
            v = w.get_active_id()
            if v:
                s.speakVoices[voicemod.key(app.speak.target)] = v
                s.save()
        fill_voices()
        voice.connect("changed", set_voice)
        voice._wired = True

        def preview():
            code = app.speak.target
            # In the voice's own language: a Japanese voice reading English says nothing about it.
            text = PREVIEW.get(code[:2], PREVIEW["en"]) if code != "zh-TW" else "這是對方會聽到的聲音。"
            from .room import Player

            def run():
                from ..core.support import Log
                p = Player(None)  # the speakers, not the room
                start, n = time.monotonic(), 0
                try:
                    for pcm in app.ling.speech(text, voice=app.speak.voice(code) or "US_Emma", language=voicemod.ming_language(code)):
                        n += len(pcm)
                        p.write(pcm)
                    p.drain()
                    Log.d("speak: preview %s %.1f s of voice in %.1f s" % (code, n / 2 / 24000, time.monotonic() - start))
                except Exception as e:  # noqa: BLE001
                    Log.d("speak: preview failed %s" % type(e).__name__)
                finally:
                    p.close()
            threading.Thread(target=run, daemon=True).start()
        voice_box = ui.hbox(8, voice, ui.button(L("试听"), preview, "outline"))
        combos.extend([mine, theirs, voice])
        for title, control, sub in ((L("我说"), mine, None),
                                    (L("对方听到"), theirs, L("跟随对方时，对方说什么语言就翻成什么")),
                                    (L("声音"), voice_box, None)):
            r = ui.prow(title, control, sub)
            dependents.append(r)
            rows.append(r)
        short = self._shortcut_row("speak")
        dependents.append(short)
        rows.append(short)
        # Without headphones a sentence said while they talk may be their voice from the speakers, so
        # it is dropped; with them it's mine, and talking over each other is normal in a meeting.
        phones = Gtk.Switch()
        phones.set_active(s.speakHeadphones)
        phones.set_valign(Gtk.Align.CENTER)

        def phones_toggled(sw, _p):
            s.speakHeadphones = sw.get_active()
            s.save()
        phones.connect("notify::active", phones_toggled)
        phones_row = ui.prow(L("戴着耳机"), phones, L("和对方同时说的话也会传出去"))
        dependents.append(phones_row)
        rows.append(phones_row)
        tip = ui.hbox(12)
        tip_icon = ui.icon("audio-headphones-symbolic", 15)
        ui.classes(tip_icon, "warn")
        tip_icon.set_valign(Gtk.Align.START)
        tip.pack_start(tip_icon, False, False, 0)
        tip.pack_start(ui.text(L("在会议软件里把麦克风选成“知了 麦克风”（或“默认”），并戴上耳机：外放时对方的声音会被当成你说的。"),
                               12, "", width_chars=50), True, True, 0)
        rows.append(ui.panel(ui.pad(tip, 10, 14), "warnrow"))
        for d in dependents:
            d.set_sensitive(s.speakEnabled)
        self.speak_status = ui.text("", 11, "warn", width_chars=60)
        self.speak_status.set_no_show_all(True)
        return ui.vbox(6, self._group(L("同声传译"), ui.boxed(rows)), ui.pad(self.speak_status, 0, 4, 0, 4))

    def _group(self, title, body, footer=None) -> Gtk.Widget:
        box = ui.vbox(6, ui.pad(ui.text(title, 12, "group-title", bold=True, wrap=False), 0, 0, 0, 2), body)
        if footer:
            box.pack_start(ui.pad(ui.text(footer, 11, "tertiary", width_chars=60), 0, 2, 0, 2), False, False, 0)
        return box

    def _toggle_entry(self) -> None:
        self.entry_row.set_visible(not self.entry_row.get_visible())
        if self.entry_row.get_visible():
            self.key_entry.grab_focus()

    def show_key_state(self) -> bool:
        k = self.app.key.read() or ""
        state = self.app.ling.key_state
        ui.clear(self.key_status)
        have = bool(k)
        ui.retext(self.key_line, AIKey.masked(k) if have else L("还没填 API key"))
        icon_name, cls, label = {
            lingmod.OK: ("object-select-symbolic", "ok", L("可以用")),
            lingmod.CHECKING: ("content-loading-symbolic", "secondary", L("正在检查…")),
            lingmod.INVALID: ("dialog-error-symbolic", "warn", L("这个 key 无效，请检查是否复制完整，或重新创建一个")),
            lingmod.UNREACHABLE: ("network-offline-symbolic", "warn", L("连不上 Ling，检查网络或代理")),
        }.get(state, (None, "secondary", ""))
        if have and label:
            if icon_name:
                img = ui.icon(icon_name, 14)
                ui.classes(img, cls)
                self.key_status.pack_start(img, False, False, 0)
            self.key_status.pack_start(ui.text(label, 12, cls, width_chars=36), False, False, 0)
        self.key_status.show_all()
        self.key_status.set_visible(have and bool(label))
        self.change_button.set_visible(have)
        self.remove_button.set_visible(have)
        self.entry_row.set_visible(not have or state == lingmod.INVALID)
        return False

    def save_key(self) -> None:
        text = self.key_entry.get_text().strip()
        if not text.startswith("sk-"):
            self.key_entry.set_placeholder_text(L("复制 sk- 开头的 key，回来粘贴"))
            self.key_entry.set_text("")
            return
        if not self.app.key.save(text):
            return
        self.key_entry.set_text("")
        self.app.ling.key_changed()
        threading.Thread(target=self.app.ling.check, daemon=True).start()

    def remove_key(self) -> None:
        self.app.key.remove()
        self.app.ling.key_changed()

    @staticmethod
    def _open_folder(path) -> None:
        os.makedirs(path, exist_ok=True)
        open_uri("file://" + path)


def _labels(w) -> list:
    out = [w] if isinstance(w, Gtk.Label) else []
    if hasattr(w, "get_children"):
        for c in w.get_children():
            out += _labels(c)
    return out

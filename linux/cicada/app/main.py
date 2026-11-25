"""Entry point and Controller: wires the engines to the windows, as AppModel does on the Mac.
Engine events arrive on worker threads; everything that touches GTK runs on the main loop."""
from __future__ import annotations

import os
import shutil
import signal
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone

# GNOME on Wayland gives a client no way to stay on top or refuse focus; its X11 server (XWayland,
# always there on Ubuntu) does, and Mutter honours "above" and the input hint for X11 windows. So
# the app speaks X11 whenever it can. Must be set before GTK loads.
if os.environ.get("DISPLAY") and "GDK_BACKEND" not in os.environ:
    os.environ["GDK_BACKEND"] = "x11"

import gi  # noqa: E402

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, Gio, GLib, Gtk  # noqa: E402

from ..core import strings  # noqa: E402
from ..core.audio import PcmAudioSource  # noqa: E402
from ..core import meeting_end, roommic  # noqa: E402
from ..core.ling import AIKey, LingClient  # noqa: E402
from ..core.listen import ListenEngine  # noqa: E402
from ..core.notes import NotesEngine  # noqa: E402
from ..core.session_store import SessionStore  # noqa: E402
from ..core.settings import AppSettings  # noqa: E402
from ..core.strings import L, LF  # noqa: E402
from ..core.support import Log, Paths, clock, english_name  # noqa: E402
from ..core.translator import Translator  # noqa: E402
from . import debug, tray, ui  # noqa: E402
from . import capture  # noqa: E402
from .capture import SystemAudio  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))  # linux/ or the installed tree


def resource_dirs() -> list:
    """The strings tables: an installed tree has them under lproj/; a checkout reads the Mac's
    Resources/ and linux/strings/ directly."""
    installed = os.path.join(ROOT, "lproj")
    if os.path.isdir(installed):
        return [installed]
    return [os.path.join(ROOT, "..", "Resources"), os.path.join(ROOT, "strings")]


def icon_path() -> str | None:
    for p in (os.path.join(ROOT, "cicada.svg"), os.path.join(ROOT, "..", "site", "icon.svg")):
        if os.path.isfile(p):
            return os.path.abspath(p)
    return None


def sample_path() -> str | None:
    for p in (os.path.join(ROOT, "sample.wav"), os.path.join(ROOT, "build", "cicada-linux", "sample.wav")):
        if os.path.isfile(p):
            return p
    return None


class Controller:
    def __init__(self, application: Gtk.Application):
        self.application = application
        self.settings = AppSettings.load()
        strings.load(self.settings.ui_code, resource_dirs())
        # The AI service in use (设置 › AI 服务): its key file, address and models, read on every call.
        self.key = AIKey(service=lambda: self.settings.aiProvider)
        self.ling = LingClient(self.key, config=self.settings.ai_config)
        self.store = SessionStore()
        self.notes = NotesEngine(self.ling, self.store)
        # 纪要语言 for notes written outside a meeting too (生成纪要 in the records window).
        self.translator = Translator(self.ling)
        self.translator.google_off = self.settings.google_off
        self.listen = ListenEngine(self.ling, self.translator, self.store, self.notes, self.settings)
        # 改正听错的词: the word list beside the records, and the fixes the translation brings back.
        from ..core import vocabulary
        from ..core.live_fixes import LiveFixes
        self.vocabulary = vocabulary.Vocabulary(vocabulary.default_path())
        self.fixes = LiveFixes(self.store, self.vocabulary, self.settings)
        self.fixes.on_change = self.changed
        self.vocabulary.on_change = self.changed
        self.listen.fixes = self.fixes
        self.translator.fix_context = self.fixes.context
        self.translator.on_fixes = self.fixes.received
        # 同声传译: my microphone → the AI service → 知了 麦克风. The listen side's loudness feeds its echo check.
        from ..core.speak import SpeakEngine
        from .room import TALK_MIC, TALK_SINK, EchoCanceller, Player, VirtualMic
        self.room = VirtualMic()
        # The talk key's microphone with the meeting's voices taken out, made with 知了 麦克风 (as the
        # Mac makes its voice unit ahead): what I say while they talk goes out instead of being dropped.
        self.talk_echo = EchoCanceller(TALK_SINK, TALK_MIC, "talk-sink", agc_off=True)
        self._talk_echo_lock = threading.Lock()
        # 电脑和会议室: the online voices taken out of the room mic (module-echo-cancel).
        self.echo = EchoCanceller()
        # Debug (roomEcho on): the room mic through the canceller. Off by default, as on the Mac: there
        # the system's echo cancellation let no echo through but lost most of what the table said;
        # the measured gate (roommic.EchoGate) and EchoMatch are what's left on by default.
        self.room_echo_cancel = False
        self.headset_default = False  # the default input is a Bluetooth headset's (the room uses another mic)
        self.forced_room_mic = None
        self.speak = SpeakEngine(self.ling, self.translator, self.settings, self.store, self.listen, player=lambda: Player())
        self.listen.loudness = self.speak.loudness
        # 说话人识别: voiceprints (native/voiceprint.c), Ling's guesses at names.
        from ..core import speakers
        self.speakers = speakers.Tagger()
        self.listen.speakers = self.speakers
        self.namer = speakers.Namer(self.ling, self.store, self.changed)
        self.listen.on_voice = self.namer.guess
        # 保存会议录音: only where GStreamer can write AAC (stock Ubuntu can't, see media.py).
        self.listen.recorder = self._recorder
        threading.Thread(target=self._finish_recordings, name="Rewrap", daemon=True).start()
        self.notes.voices = lambda: self.settings.speakerVoices
        self.speak.on_change(self.changed)
        self.listen.on_change(self.changed)
        self.notes.on_change(self.changed)
        self.store.on_change(lambda _id: self.changed())
        self.store.on_words(self._words)
        self.ling.on_change(self.changed)
        # 存到文件夹 (设置 › 通用): written once a record is settled, rewritten when it changes.
        from ..core.folder_export import FolderExporter
        self.folder_export = FolderExporter(self.store, self.settings)
        self.folder_export.settling = self.notes.settling
        self.folder_export.voices = lambda: self.settings.speakerVoices
        self.folder_export.on_change(self.changed)
        self.folder_export.on_denied = lambda: GLib.idle_add(lambda: self._notify_folder_denied() and False)
        self.store.on_save(self.folder_export.saved)
        self.notes.final_done = self.folder_export.settled
        self.notes_window = None
        self.share_dialog = None  # 分享… (share_dialog.py), one at a time
        self.records_window = None
        self.settings_window = None
        self.onboarding = None
        self.tray = None
        self._queued = False
        self.launcher = os.path.join(ROOT, "bin", "cicada")  # for 登录时启动
        # 结束会议 (meeting_end.py): `ending` while a meeting is about to end by itself, `auto_ended`
        # after one did (the capsule says so, and the next call starts a new meeting).
        self.end_watch = None
        self.ending = None
        self.auto_ended = False
        self.fake_calls = None   # debug: meeting apps pretending to be in a call
        self.end_times = None    # debug: (silence, countdown, grace) in seconds
        self._calls_busy = False
        from .updater import Updates
        self.updates = Updates(self)  # 新版本: GitHub Releases, the tray menu and 设置 › 关于
        # Something only the user can fix, said beyond the notes window (problem.py): the tray's dot
        # and, once a meeting while the window is put away, a notification.
        from ..core.problem import Notices
        self.notices = Notices()
        self._notified = False
        GLib.timeout_add_seconds(1, self._tick)
        GLib.timeout_add_seconds(2, self._watch_end)

    @property
    def can_record(self) -> bool:
        from . import media
        return media.encoder() is not None

    def _recorder(self, sid: str):
        """The new meeting's recorder, or None (setting off, or no AAC encoder here)."""
        from . import media
        media.rescan()  # formats installed since launch record this meeting
        if not self.settings.recordAudio or media.encoder() is None:
            return None
        rec = media.Recorder(self.store.audio_path(sid))
        rec.on_finished = lambda: GLib.idle_add(lambda: self.changed() and False)
        return rec

    def _finish_recordings(self) -> None:
        """A meeting the app didn't get to close: its system.aac becomes system.m4a now (the Mac's load())."""
        from . import media
        for sid in self.store.unfinished_audio():
            if media.finish(self.store.audio_path(sid)):
                self.store.set_has_audio(sid)
        GLib.idle_add(lambda: self.changed() and False)

    def _tick(self) -> bool:
        if self.tray is not None and self.listen.listening:
            self.tray.tick()
        self.check_problem()
        return True

    def check_problem(self) -> None:
        """Every second and on each change: a notification when problem.Notices says one is due,
        withdrawn once the service works again. Never a dialog: it would take the focus from the
        meeting app."""
        from ..core import aicheck, problem
        reason = self.ling.check_result.reason if self.ling.has_key else None
        w = self.notes_window
        shown = w is not None and w.get_visible() and w.shows_problem(reason)
        kind = self.notices.tick(time.time(), self.listen.listening, reason, shown)
        if kind is not None:
            from .aicheck_view import blocking, blocking_detail
            name = self.ling.service_label
            title = blocking(self) if kind == "blocking" else LF("连不上 %@", name)
            n = Gio.Notification.new(title or L("AI 服务的设置要改一下"))
            n.set_body(blocking_detail(self) if kind == "blocking" else self.ling.message() or "")
            n.set_default_action("app.ai-settings")
            n.add_button(L("打开设置"), "app.ai-settings")
            self.application.send_notification("problem", n)
            self._notified = True
            Log.d("problem: notified %s (%s)" % (kind, reason))
        elif self._notified and not (problem.blocking(reason) or reason == aicheck.UNREACHABLE):
            self.application.withdraw_notification("problem")
            self._notified = False
            Log.d("problem: withdrawn")

    def _notify_folder_denied(self) -> None:
        """Once after a meeting, until a write works again (folder_export decides when): its own id,
        so check_problem's withdraw never takes it away."""
        from ..core.folder_export import short_path
        folder = self.folder_export.folder
        if not folder:
            return
        n = Gio.Notification.new(L("纪要没存到文件夹"))
        n.set_body(LF("知了没有权限写入 %@。点按去设置", short_path(folder)))
        n.set_default_action("app.folder-settings")
        self.application.send_notification("folder-export", n)
        Log.d("folder export: notified denied")

    def launch(self, speak: bool = False, background: bool = False) -> None:
        ui.install_css()
        lang = strings.language
        ui.DEFAULT_LANG = ui.pango_lang({"zh-Hans": "zh-CN"}.get(lang, lang)) if lang != "en" else ui.pango_lang(self.settings.target_code)
        backend = type(Gdk.Display.get_default()).__name__
        Log.d("app: launch %s %s on %s, session %s" % ("dev" if Paths.dev else "release", sys.version.split()[0], backend,
                                                       os.environ.get("XDG_SESSION_TYPE", "?")))
        icon = icon_path()
        if icon:
            try:
                Gtk.Window.set_default_icon_from_file(icon)
            except GLib.Error:
                pass
        self.tray = tray.make(self, icon)
        def prepare():
            self.talk_echo.remove()  # left by a run that crashed: the speakers are the default output again
            self.echo.remove()  # left by a run that crashed during 电脑和会议室
            if self.settings.speakEnabled:
                if self.room.create():
                    self._make_talk_echo()
            else:
                self.room.leftovers()
            if speak:  # `cicada --speak` before Cicada was running: speak once 知了 麦克风 is there
                GLib.idle_add(lambda: self.toggle_speaking() and False)
        threading.Thread(target=prepare, daemon=True).start()
        # Logging out or `kill` sends SIGTERM / SIGHUP: quit properly so 知了 麦克风 goes and the real
        # microphone is the default again, the same as 退出.
        for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
            GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, sig, self._signalled, sig)
        if Paths.dev:
            debug.start(self)
        from .settings_window import refresh_autostart
        refresh_autostart(self.launcher)
        if self.settings.onboarded and self.ling.has_key:
            threading.Thread(target=self.ling.check, daemon=True).start()
        self._watch_network()
        # Opened by hand, 知了 shows its window: a top-bar icon alone looks like nothing happened, and
        # plain GNOME has no top bar icon at all. Only a login start (--background) with an icon to be
        # reached through, set up already, stays out of the way. Not set up: the onboarding on top.
        if not background or self.tray is None or not self.settings.onboarded:
            self.show_records()
        if not self.settings.onboarded:
            GLib.timeout_add(500, lambda: self.show_onboarding() and False)
        reopened = self.updates.reopened()
        if reopened and self.settings.onboarded:
            self.show_records()  # where 已更新到 … is said, once
            self.records_window.toasts.show(reopened)
        self.updates.start()
        self.keep_in_dock()
        self.folder_export.retry()  # meetings that waited (a folder that wasn't there, or the app quit)

    def changed(self) -> None:
        """Engine threads call this: one coalesced refresh on the main loop."""
        if self._queued:
            return
        self._queued = True

        def run():
            self._queued = False
            # 会议室 while 同声传译 hears me through the same microphone: what it hears is me.
            self.listen.set_muted(self.speak.active)
            if self.notes_window is not None:
                self.notes_window.refresh()
            if self.records_window is not None:
                self.records_window.refresh()
            if self.onboarding is not None:
                self.onboarding.refresh()
            if self.tray is not None:
                self.tray.update()
            if self.settings_window is not None:
                self.settings_window.refresh_version()
                self.settings_window.word_list.refresh()
                self.settings_window.folder_card.refresh()
            self.check_problem()
            return False
        GLib.idle_add(run)

    # Windows

    def show_notes(self) -> None:
        if self.notes_window is None:
            from .notes_window import NotesWindow
            self.notes_window = NotesWindow(self)
            self.application.add_window(self.notes_window)
        self.notes_window.refresh()
        self.notes_window.show_all()

    def _records(self):
        if self.records_window is None:
            from .records_window import RecordsWindow
            self.records_window = RecordsWindow(self)
            self.application.add_window(self.records_window)
            # Coming forward: a folder fixed meanwhile (the Mac's didBecomeActive).
            self.records_window.connect("focus-in-event", lambda *_: self.folder_export.retry() or False)
        return self.records_window

    def show_records(self) -> None:
        from . import media
        media.rescan()  # a recording plays once the formats are installed, no restart
        w = self._records()
        if w.get_visible() and w.iconified:
            # Minimized (keep_in_dock), Mutter won't bring it back for a request without a user's
            # event time (the tray, a second launch): shown afresh instead, as when it was hidden.
            w.hide()
        w.fill()
        w.set_focus_on_map(True)
        w.deiconify()  # unmapped, this only clears GTK's "map it minimized" (keep_in_dock's iconify)
        w.show_all()
        self.records_window.present()
        self.records_window.set_focus(None)  # not the search box: its placeholder would vanish

    @property
    def records_open(self) -> bool:
        """On screen: not hidden, nor minimized to keep the dock icon (a dialog over it would be too)."""
        w = self.records_window
        return w is not None and w.get_visible() and not w.iconified

    def keep_in_dock(self) -> None:
        """在 Dock 中显示 (the Mac's showInDock): GNOME's dock lists an app only while it has a window
        there, and the notes window, a notification that never takes focus, has none. So while the
        setting is on the records window stays, minimized, and clicking the dock icon brings it back.
        Mapped minimized and never presented: the meeting app keeps the focus."""
        w = self.records_window
        if not self.settings.showInDock or (w is not None and w.get_visible()):
            return
        w = self._records()
        w.fill()
        w.parked = True
        w.set_focus_on_map(False)
        w.iconify()  # before it's mapped: it starts minimized (WM_HINTS IconicState)
        w.show_all()
        w.set_focus(None)  # back from the dock, not in the search box: its placeholder would vanish
        Log.d("dock: records window kept minimized")

    def set_show_in_dock(self, on: bool) -> None:
        """设置 › 在 Dock 中显示. Off: as before it existed, the records window only while it's open."""
        self.settings.showInDock = on
        self.settings.save()
        w = self.records_window
        if on:
            self.keep_in_dock()
        elif w is not None and w.parked:
            w.hide()
        Log.d("dock: %s" % ("on" if on else "off"))

    def show_settings(self, ai: bool = False, general: bool = False) -> None:
        """设置; `ai`: at AI 服务 (its first section), where every AI problem is fixed; `general`: at 通用
        (保存会议录音, from a record that has none)."""
        if self.settings_window is None:
            from .settings_window import SettingsWindow
            self.settings_window = SettingsWindow(self)
            self.application.add_window(self.settings_window)
        # show_all() only on the way up: on an open window it would bring back what its "show"
        # handlers hid (the key card under a custom service's own rows).
        if not self.settings_window.get_visible():
            self.settings_window.show_all()
        self.settings_window.present()
        if ai:
            self.settings_window.scroll.get_vadjustment().set_value(0)
        elif general:
            self.settings_window.scroll_to_general()

    # Setup (会议记录 › 还差几步 and the capsule)

    @property
    def setup_done(self) -> tuple:
        """The setup steps as the onboarding numbers them (key, computer sound, sample): done by what
        really happened, not by "the onboarding was finished" (Windows' SetupDone)."""
        s = self.settings
        return self.key_works, s.heardSystemAudio or s.onboarded, s.sampleSeen or s.onboarded

    @property
    def key_works(self) -> bool:
        """The key step is done: a key, and no failure only the user can fix (a check still running,
        or one not run yet, doesn't undo it; busy counts as passed)."""
        f = self.ling.check_result.failure
        return self.ling.has_key and (f is None or f[1] in ("busy", "serverError"))

    @property
    def setup_left(self) -> int:
        """Steps left before listening works; 0 once set up. 同声传译 is optional and never counted."""
        key, audio, sample = self.setup_done
        if self.settings.onboarded and key:
            return 0
        return (not key) + (not audio) + (not sample)

    def setup_step_done(self, name: str) -> None:
        """The onboarding heard the computer (heardSystemAudio) or played the sample (sampleSeen)."""
        if not getattr(self.settings, name):
            setattr(self.settings, name, True)
            self.settings.save()
            self.changed()

    def show_onboarding(self, step: int | None = None) -> None:
        """The onboarding at `step`, or at the first step not done, over the records window."""
        from .onboarding import AUDIO, KEY, SAMPLE, Onboarding
        _, audio, _ = self.setup_done
        key = self.ling.has_key
        at = step if step is not None else KEY if not key else AUDIO if not audio else SAMPLE
        if self.onboarding is not None:
            if step is not None and self.onboarding.step != step:
                self.onboarding.go(step)
            self.onboarding.present()
            return
        self.onboarding = Onboarding(self, at)
        self.application.add_window(self.onboarding)
        # Over the records window, so closing it leaves a window to click, not an empty screen.
        if self.records_open:
            self.onboarding.set_transient_for(self.records_window)
            self.onboarding.set_position(Gtk.WindowPosition.CENTER_ON_PARENT)

        def closed(*_):
            self.onboarding = None
            if self.tray is None and not self.records_open:
                self.show_records()
            self.changed()
        self.onboarding.connect("destroy", closed)
        self.onboarding.show_all()
        self.onboarding.present()

    def records_closed(self) -> None:
        """The records window was closed: once, say 知了 is still in the top bar (it keeps running)."""
        if self.tray is None or self.settings.trayHintShown:
            return
        self.settings.trayHintShown = True
        self.settings.save()
        n = Gio.Notification.new(L("知了还在顶栏"))
        n.set_body(L("从右上角的知了图标打开会议记录，或开始听。"))
        self.application.send_notification("still-here", n)

    def set_ai_provider(self, provider: str) -> None:
        """设置 › AI 服务: another service, with its own key file and models; checked again."""
        from ..core.providers import named
        if named(provider).id != provider or provider == self.settings.aiProvider:
            return
        self.settings.aiProvider = provider
        self.settings.save()
        self.ai_changed()

    def can_switch_to_ling(self) -> bool:
        """改用 Ling where another service is out of reach: only when a Ling key is already saved, so
        the one click works without a trip to the settings. Read fresh: the key may have just been saved."""
        return self.settings.aiProvider != "ling" and AIKey(service=lambda: "ling").read() is not None

    def switch_to_ling(self) -> None:
        if self.can_switch_to_ling():
            self.set_ai_provider("ling")

    def set_ai_model(self, kind: str, model: str) -> None:
        """A model chosen over the recommended one ("text", "hear", "voice", or a custom service's
        "notes"; "" goes back to it)."""
        s = self.settings
        p = s.aiProvider
        if kind == "text" and p == "ling":
            s.model = model or s.FIELDS["model"]
        else:
            table = {"text": s.aiModels, "hear": s.aiHearModels, "voice": s.aiVoiceModels, "notes": s.aiModels}.get(kind)
            if table is None:
                return
            if kind == "notes":
                p = "custom.notes"  # the custom service's notes model ("": the translation one)
            if model:
                table[p] = model
            else:
                table.pop(p, None)
        s.save()
        self.ai_changed()

    def ai_changed(self) -> None:
        """The service, its address, models or key changed: forget the old check and check again."""
        self.translator.google_off = self.settings.google_off
        self.ling.key_changed()
        if self.ling.has_key:
            threading.Thread(target=self.ling.check, daemon=True).start()

    def set_custom_only(self, on: bool) -> None:
        """语音和文字只发给你的服务: Google is never asked while the custom service is in use. Nothing
        to check again: only where translations go changes."""
        self.settings.aiCustomOnly = on
        self.settings.save()
        self.translator.google_off = self.settings.google_off
        if self.settings_window is not None:
            self.settings_window.show_key_state()  # the switch, its grey line and the footnote
        self.changed()

    def recheck(self) -> None:
        """重新检查: the AI service, step by step, off the main loop."""
        if self.ling.has_key and not self.ling.check_result.running:
            threading.Thread(target=self.ling.check, daemon=True).start()

    def use_recommended(self, kind: str) -> None:
        """换成推荐的: the service's first recommended text or hear model, then a fresh check. Only
        ever on the user's click: the app never changes a model by itself."""
        p = self.ling.provider
        models = p.text_models if kind == "text" else p.hear_models
        if models:
            self.set_ai_model(kind, models[0].id)

    def switch_service(self, provider: str, key: str) -> None:
        """改用 <服务>: a key pasted for another service goes there, then it is checked."""
        self.settings.aiProvider = provider
        self.settings.save()
        self.key.save(key)
        self.ai_changed()

    def _watch_network(self) -> None:
        """A change of route (Wi-Fi back, a proxy app's TUN) waits 3 s for the network to settle, then
        the service is looked at again if it was unreachable. No timer otherwise."""
        monitor = Gio.NetworkMonitor.get_default()
        self._net_wait = None

        def settled():
            self._net_wait = None
            self.ling.network_changed()
            return False

        def changed(_m, available):
            if not available:
                return
            if self._net_wait is not None:
                GLib.source_remove(self._net_wait)
            self._net_wait = GLib.timeout_add(3000, settled)
        monitor.connect("network-changed", changed)
        self._net_monitor = monitor

    def set_view(self, view: str) -> None:
        if view not in ("notes", "subtitles") or view == self.settings.view:
            return
        self.settings.view = view
        self.settings.save()
        # A new window for the new layout: GTK won't shrink a mapped 620 px notes window to a bar.
        if self.notes_window is not None:
            visible = self.notes_window.get_visible()
            self.notes_window.destroy()
            self.notes_window = None
            if visible:
                self.show_notes()

    def settings_changed(self) -> None:
        self.changed()

    # Listening

    def toggle_listening(self) -> None:
        if self.listen.listening:
            self.stop_listening()
        else:
            self.start_listening(*self.heard_source())

    # 听哪里

    def room_mic(self) -> str:
        """The microphone that hears the room now (roommic.pick). 知了 麦克风 as the default input
        (同声传译 on) stands for the real microphone it took the place of."""
        if self.forced_room_mic:  # debug: a null sink's monitor standing in for one (a VM has no microphone)
            return self.forced_room_mic
        inputs = roommic.parse_sources(capture.sources_text())
        default = capture.default_source()
        if default == "cicada_mic":
            default = self.room.real_mic
        picked = roommic.pick(default, inputs, self.settings.roomMic)
        if picked is None and not inputs:  # no pactl to list them: the default, if it's a real one
            picked = default or "@DEFAULT_SOURCE@"
        Log.d("room mic: %s (default %s, %d inputs)" % (picked, default, len(inputs)))
        return picked

    def heard_source(self):
        """(source, kind) for 听哪里: the computer's audio, or the room through a microphone. For
        电脑和会议室 the computer's audio; the room side starts beside it (_start_room_side)."""
        if self.settings.listenSource == "both":
            return SystemAudio(), "both"
        if self.settings.listenSource == "room":
            mic = self.room_mic()
            if mic is not None:
                return SystemAudio(mic, L("知了 · 会议室")), "room"
            Log.d("room mic: none, listening to the computer instead")
        return SystemAudio(), "system"

    @property
    def mic_on(self) -> bool:
        return self.settings.listenSource == "both"

    def set_mic(self, on: bool) -> None:
        """打开麦克风 / 关闭麦克风, from the tray, the notes window or the debug pipe (the Mac's setMic):
        the computer's audio is always heard, the mic adds the room to the same meeting. Not kept for
        the next launch; turning it on while nothing is heard starts listening."""
        value = "both" if on else "system"
        if value == self.settings.listenSource:
            if on and not self.listen.listening:
                self.start_listening(*self.heard_source())
            return
        self.settings.listenSource = value
        Log.d("mic %s" % ("on" if on else "off"))
        if self.listen.listening and self.listen.source_kind != "file":
            if on:
                self._start_room_side()
            else:
                self._stop_room_side()
        elif on and not self.listen.listening:
            self.start_listening(*self.heard_source())
        self.changed()

    def _room_side_source(self):
        """(source, gated) for 电脑和会议室's room side, or None without a microphone: the room mic
        through the echo canceller; without one (or the sound server won't) the plain mic, gated
        while the computer plays speech. 戴着耳机: nothing comes out of the speakers to cancel."""
        mic = self.room_mic()
        if mic is None:
            Log.d("hybrid: no microphone, the computer's audio only")
            return None
        default = capture.default_source()
        bt = [i.name for i in roommic.parse_sources(capture.sources_text()) if i.bluetooth]
        self.headset_default = (self.room.real_mic if default == "cicada_mic" else default) in bt
        cancelled = self.echo.create(mic) if self.room_echo_cancel else None
        if cancelled is None:
            Log.d("hybrid: the room mic, gated while the computer plays speech that reaches it")
        source = SystemAudio(cancelled or mic, L("知了 · 会议室"))
        source.on_ended = self._room_lost
        return source, cancelled is None

    def _start_room_side(self) -> None:
        room = self._room_side_source()
        if room is not None:
            self.listen.start_room(*room)

    def _room_lost(self, why) -> None:
        """The room side's microphone went away (unplugged, the sound server gone for 20 s): another
        one takes over if there is one; otherwise the computer's audio goes on alone."""
        def run():
            if self.listen.listening and self.listen.hears_room_too and why:
                Log.d("hybrid: room microphone lost (%s)" % why)
                self._stop_room_side()
                self._start_room_side()
                self.changed()
            return False
        GLib.idle_add(run)

    def _stop_room_side(self) -> None:
        self.listen.stop_room()
        if self.echo.on:
            self.echo.remove()

    def set_headphones(self, on: bool) -> None:
        """戴着耳机 (同声传译's): whether a sentence said while they talk may be their voice from the
        speakers. The room mic measures that for itself (roommic.EchoGate)."""
        if on == self.settings.speakHeadphones:
            return
        self.settings.speakHeadphones = on
        self.settings.save()
        self.changed()

    def _source_ended(self, kind: str):
        def ended(reason):
            # A file that finished stops a little later, so its last sentence's pause is heard;
            # a capture that failed stops now.
            if reason is None:
                GLib.timeout_add(1500, lambda: self.stop_listening() and False)
                return
            Log.d("listen: source ended %s" % reason)
            # Said where the subtitles would be (start() clears it), not silently stopped.
            self.listen.problem = L("没有可用的麦克风") if kind == "room" else L("系统声音中断")
            self.listen.problem_kind = "source"
            GLib.idle_add(lambda: self.stop_listening() and False)
        return ended

    def recorded(self):
        """(elapsed seconds, lines) of the live meeting, or None when nothing has been said yet."""
        s = self.store.get(self.listen.session_id) if self.listen.listening and self.listen.session_id else None
        if s is None or not s.lines:
            return None
        return (datetime.now(timezone.utc) - s.startedAt).total_seconds(), len(s.lines)

    def request_stop(self, parent=None) -> None:
        """结束 from the tray, the records window, the subtitle bar or the shortcut (the Mac's
        requestStop): a meeting with lines ends only after asking, 继续记录 the default so a stray
        Return keeps it going. An empty one just stops. Starting needs no question."""
        if not self.listen.listening:
            self.toggle_listening()
            return
        rec = self.recorded()
        if rec is None:
            self.stop_listening()
            return
        sid = self.listen.session_id
        # Drawn in the app's own look (white sheet, ink and outline buttons), not the theme's message
        # dialog with its icon and red button.
        dialog = Gtk.Dialog(transient_for=parent, modal=True)
        dialog.set_decorated(False)
        dialog.set_resizable(False)
        dialog.set_keep_above(True)
        ui.classes(dialog, "endask")
        body = ui.vbox(6, ui.text(L("结束这场会议？"), 15, "ink", bold=True, width_chars=34),
                       ui.text(LF("已记录 %@ · %lld 句。结束后停止收听，并整理一份完整版纪要。", clock(rec[0]), rec[1]),
                               12, "secondary", width_chars=34))
        keep = ui.button(L("继续记录"), lambda: dialog.response(Gtk.ResponseType.CANCEL), "outline")
        end = ui.button(L("结束会议"), lambda: dialog.response(Gtk.ResponseType.ACCEPT), "darkbtn")
        row = ui.hbox(8)
        row.set_halign(Gtk.Align.END)
        row.pack_start(keep, False, False, 0)
        row.pack_start(end, False, False, 0)
        area = dialog.get_content_area()
        area.pack_start(ui.pad(ui.vbox(18, body, row), 22, 22), True, True, 0)
        area.show_all()
        keep.set_can_default(True)
        keep.grab_default()
        keep.grab_focus()
        answer = dialog.run()
        dialog.destroy()
        # The same meeting still running: it may have ended by itself while the question was open.
        if answer == Gtk.ResponseType.ACCEPT and self.listen.listening and self.listen.session_id == sid:
            self.stop_listening()

    def start_listening(self, source, kind: str, checked: bool = False) -> None:
        if self.listen.listening:
            return
        if not self.ling.has_key:
            self.show_onboarding()
            return
        # The service hears for us: a known failure stops here with the fix, not in an empty window.
        # Unknown or busy starts as usual; unreachable is looked at once more first.
        r = self.ling.check_result
        if r.reason == "unreachable" and not checked:
            def again():
                self.ling.check()
                GLib.idle_add(lambda: self.start_listening(source, kind, checked=True) and False)
            threading.Thread(target=again, daemon=True).start()
            return
        if r.reason in ("deaf", "unreachable") and not self._may_start(source, kind):
            return

        source.on_ended = self._source_ended(kind)
        # A new meeting's notes window starts without the last meeting's interpreted sentence.
        if not self.speak.active:
            self.speak.last = None
            self.speak.problem = None
        self.auto_ended = False
        self.ending = None
        self.end_watch = meeting_end.MeetingEndWatch(self.end_config(), time.time())
        self.notices.start()
        room = self._room_side_source() if kind == "both" else None
        self.fixes.meeting_started()
        self.listen.start(source, kind, mic=kind == "room")
        if room is not None:
            self.listen.start_room(*room)
        self.show_notes()
        self.changed()

    def _may_start(self, source, kind: str) -> bool:
        """开始听 when the last check found the hear model deaf or the service unreachable: say so,
        with 打开设置 and the one fix (换成推荐的并开始 / 重新检查并开始). False: not now."""
        from ..core import aicheck
        ling = self.ling
        r = ling.check_result
        name = ling.service_name
        if r.reason == aicheck.DEAF:
            model = ling.config().hear_model
            title, body, hint = LF("%@ 现在听不了声音", model), LF("%@ 只收文字。换成推荐的模型就能开始听。", model), None
            p = ling.provider
            fix = L("换成推荐的并开始") if p.hear_models and p.hear_models[0].id != model else None
        else:
            title, body = LF("连不上 %@", name), ling.message()
            hint = r.proxy_line(name, ling.service_host)
            fix = L("重新检查并开始")
        dialog = Gtk.Dialog(transient_for=self.records_window if self.records_open else None,
                            modal=True)
        dialog.set_decorated(False)
        dialog.set_resizable(False)
        dialog.set_keep_above(True)
        ui.classes(dialog, "endask")
        texts = ui.vbox(6, ui.text(title, 15, "ink", bold=True, width_chars=36), ui.text(body or "", 12, "secondary", width_chars=36))
        if hint:
            texts.pack_start(ui.panel(ui.pad(ui.text(hint, 12, "", width_chars=36), 7, 10), "proxybox"), False, False, 0)
        row = ui.hbox(8)
        row.set_halign(Gtk.Align.END)
        settings = ui.button(L("打开设置"), lambda: dialog.response(Gtk.ResponseType.CANCEL), "outline")
        row.pack_start(settings, False, False, 0)
        if fix:
            row.pack_start(ui.button(fix, lambda: dialog.response(Gtk.ResponseType.ACCEPT), "darkbtn"), False, False, 0)
        dialog.connect("key-press-event", lambda _d, e: e.keyval == Gdk.KEY_Escape and dialog.response(Gtk.ResponseType.CLOSE))
        dialog.get_content_area().pack_start(ui.pad(ui.vbox(18, texts, row), 22, 22), True, True, 0)
        dialog.get_content_area().show_all()
        self._asking = dialog  # debug: screenshots, and answering it from the control socket
        answer = dialog.run()
        self._asking = None
        dialog.destroy()
        if answer == Gtk.ResponseType.CANCEL:
            self.show_settings(ai=True)
        elif answer == Gtk.ResponseType.ACCEPT:
            if r.reason == aicheck.DEAF:
                self.use_recommended("hear")  # checks again; the meeting starts now
                return True

            def again():
                self.ling.check()
                GLib.idle_add(lambda: self.start_listening(source, kind, checked=True) and False)
            threading.Thread(target=again, daemon=True).start()
        return False

    # 结束会议

    def end_config(self) -> meeting_end.Config:
        s = self.settings
        c = meeting_end.Config(follow_apps=s.endWithApp, silence=s.silenceEnd, silence_after=s.silenceMinutes * 60)
        if self.end_times:
            c.silence_after, c.countdown, c.app_grace = self.end_times
        return c

    def _watch_end(self) -> bool:
        """Every 2 s: while listening, whether the meeting is over; after one ended by itself,
        whether a meeting app started the next call. `pactl` runs off the main loop."""
        listening = self.listen.listening and self.end_watch is not None
        after = not self.listen.listening and self.auto_ended
        if self._calls_busy or not (listening or after):
            return True
        follow = self.settings.endWithApp
        if not follow and not listening:
            return True
        self._calls_busy = True

        def read():
            calls = (self.fake_calls if self.fake_calls is not None else meeting_end.calls()) if follow else {}

            def apply():
                self._calls_busy = False
                self._end_tick(calls)
                return False
            GLib.idle_add(apply)
        threading.Thread(target=read, daemon=True).start()
        return True

    def _end_tick(self, calls: dict) -> None:
        now = time.time()
        if self.listen.listening and self.end_watch is not None:
            w = self.end_watch
            w.config = self.end_config()
            s = self.store.get(self.listen.session_id) if self.listen.session_id else None
            reason = w.tick(now, calls, bool(s and s.lines))
            self._set_ending(w.pending)
            if reason is not None:
                self._auto_end(reason, w)
        elif not self.listen.listening and self.auto_ended and self.settings.endWithApp and calls:
            Log.d("meeting end: a meeting app started a call, starting a new meeting")
            self.start_listening(*self.heard_source())

    def _words(self, sid: str) -> None:
        """Words recognised in the live meeting (theirs or mine): the silence countdown stops now,
        as on the Mac, not at the next tick."""
        def run():
            if self.end_watch is not None and self.listen.listening and sid == self.listen.session_id:
                self.end_watch.heard(time.time())
                self._set_ending(self.end_watch.pending)
            return False
        GLib.idle_add(run)

    def _set_ending(self, p) -> None:
        if p == self.ending:
            return
        if p is not None:
            Log.d("meeting end: pending %r, ends in %d s" % (p.reason, p.deadline - time.time()))
        elif self.ending is not None:
            Log.d("meeting end: pending cleared")
        self.ending = p
        self.changed()

    def _auto_end(self, reason, w) -> None:
        if reason.kind == "nobody":
            # Nothing to keep or summarise: back to 开始听, not 会议已自动结束.
            Log.d("meeting end: nobody spoke for %d s, stopped" % w.config.silence_after)
            self.stop_listening()
            return
        # Where the meeting really ended: a little after the last words, or at the hang-up if that
        # was later.
        at = w.last_speech + 5
        if reason.kind == "app":
            at = max(at, time.time() - w.config.app_grace)
        at = min(at, time.time())
        Log.d("meeting end: ended by itself (%r), end time %d s ago" % (reason, time.time() - at))
        self.stop_listening(ended_at=datetime.fromtimestamp(at, timezone.utc), auto=True)

    def keep_recording(self) -> None:
        """继续记录 on the ending prompt."""
        if self.end_watch is not None:
            self.end_watch.keep_going(time.time())
        self._set_ending(None)
        Log.d("meeting end: kept going")

    def ending_title(self, p) -> str:
        if p.reason.kind == "app":
            return LF("%@ 已挂断", p.reason.name)
        return LF("已经 %lld 分钟没人说话", max(1, round(self.end_config().silence_after / 60)))

    def ending_left(self, p) -> int:
        return max(0, int(round(p.deadline - time.time())))

    # 同声传译

    def set_speak_enabled(self, on: bool) -> bool:
        """Turning it on makes 知了 麦克风 (and the default input); off removes it. False if the sound
        server wouldn't make the device."""
        if on and not self.room.on:
            if not self.room.create():
                return False
            self._make_talk_echo()
        if not on:
            self.speak.cancel()
            self.talk_echo.remove()
            self.room.remove()
        self.settings.speakEnabled = on
        self.settings.save()
        self.changed()
        return True

    def _make_talk_echo(self) -> None:
        """The talk key's echo canceller, in front of the output that is the default now. Not while
        电脑和会议室's debug canceller is (two in a row fight over the default output)."""
        real = self.room.real_mic
        if not real or self.echo.on:
            return
        with self._talk_echo_lock:  # a press can ask again while the last one is still being made
            if self.talk_echo.ready(real):
                return
            self.talk_echo.remove()
            made = self.talk_echo.create(real) is not None
        Log.d("speak: echo canceller %s" % ("ready" if made else "unavailable, the plain mic"))

    def toggle_speaking(self) -> None:
        if self.speak.active:
            self.speak.stop()
            return
        if not self.ling.has_key:
            self.show_onboarding()
            return
        if self.ling.usable and not self.ling.speaks:
            # A service without a speech model: say why now, not "没听清" for every sentence.
            self.speak.problem = L("这个服务不能出声音")
            self.changed()
            return
        if not self.settings.speakEnabled or not self.room.on:
            if not self.set_speak_enabled(True):
                self.speak.problem = L("没能建好知了麦克风")
                self.changed()
                return
        # Me, from the microphone that was the default before 知了 麦克风 took its place: through the
        # echo canceller made for it while the meeting still plays through that, else the plain mic
        # (said over the meeting is dropped then) and the canceller is made again for the next time.
        real = self.room.real_mic
        cancelled = bool(real) and self.talk_echo.ready(real)
        why = ""
        if not cancelled:
            why = ("no real microphone known" if not real else "no canceller" if not self.talk_echo.on
                   else "the canceller was made for another microphone" if self.talk_echo.mic != real
                   else "the canceller isn't the default output")
            if real:
                threading.Thread(target=self._make_talk_echo, daemon=True).start()
        mic = SystemAudio(self.talk_echo.source if cancelled else real or "@DEFAULT_SOURCE@")

        def ended(reason):
            if reason:
                Log.d("speak: microphone ended %s" % reason)
                self.speak.problem = L("没有可用的麦克风")
                GLib.idle_add(lambda: self.speak.stop() or False)
        mic.on_ended = ended
        self.speak.start(mic, cancelled, why)
        self.show_notes()

    def stop_listening(self, ended_at=None, auto: bool = False) -> None:
        self.end_watch = None
        self.ending = None
        self.auto_ended = auto

        # stop() waits for Ming's last replies: off the main loop.

        def run():
            sid = self.listen.session_id
            self.listen.stop(ended_at)
            if sid and self.store.get(sid) is not None:
                self.folder_export.ended(sid)
            if self.echo.on:
                self.echo.remove()  # the speakers are the default output again
            if sid and self.settings.speakerVoices:
                self.namer.guess(sid, force=True)  # the whole meeting read once more for names
            self.changed()
            GLib.idle_add(lambda: self.updates.meeting_ended() and False)  # 会后安装
        threading.Thread(target=run, daemon=True).start()

    # 说话人识别

    @property
    def voices_available(self) -> bool:
        from ..core import speakers
        return speakers.library_path() is not None and speakers.model_path() is not None

    def set_speaker_voices(self, on: bool) -> None:
        self.settings.speakerVoices = on
        self.settings.save()
        Log.d("speakers: %s" % ("on" if on else "off"))
        self.changed()

    def _speaker_edit(self, sid, change):
        """Runs a speaker edit and returns what 撤销 puts back."""
        snap = self.store.voice_snapshot(sid)
        change()
        return snap

    def rename_speaker(self, sid: str, voice: int, name):
        """Name a voice ("" keeps 说话人 N, None goes back to Ling's guess). (toast text or None, snapshot)."""
        from ..core import speakers
        s = self.store.get(sid)
        if s is None:
            return None, None
        n = speakers.voice_numbers(s.lines).get(voice, 0)
        before = speakers.label(n, speakers.names(s))
        snap = self._speaker_edit(sid, lambda: self.store.set_voice_name(sid, voice, name))
        after = speakers.label(n, speakers.names(self.store.get(sid)))
        Log.d("speakers: renamed a voice in %s" % sid)
        return (LF("%@ 已改成 %@", before, after) if after != before else None), snap

    def merge_speaker(self, sid: str, frm: int, into: int):
        """Two voices are one person. While listening the voiceprints merge too, which 撤销 can't take back."""
        from ..core import speakers
        s = self.store.get(sid)
        if s is None:
            return None, None
        nums, shown = speakers.voice_numbers(s.lines), speakers.names(s)
        a, b = speakers.label(nums.get(frm, 0), shown), speakers.label(nums.get(into, 0), shown)
        snap = self._speaker_edit(sid, lambda: self.store.merge_voice(sid, frm, into))
        if self.listen.listening and self.listen.session_id == sid:
            self.speakers.merge(frm, into)
        Log.d("speakers: merged two voices in %s" % sid)
        return LF("%@ 已并入 %@", a, b), snap

    def assign_lines(self, sid: str, ids: set, voice: int):
        """These lines were someone else's."""
        from ..core import speakers
        s = self.store.get(sid)
        if s is None:
            return None, None
        first = next((l for l in s.lines if l.id in ids), None)
        snap = self._speaker_edit(sid, lambda: self.store.set_line_voices(sid, ids, voice))
        s2 = self.store.get(sid)
        who = speakers.label(speakers.voice_numbers(s2.lines).get(voice, 0), speakers.names(s2))
        return LF("%@ 这句已改给 %@", clock(first.t) if first else "", who), snap

    def undo_speaker_edit(self, sid: str, snap) -> None:
        if snap is not None:
            self.store.restore(sid, snap)
            Log.d("speakers: undo %s" % sid)

    def play_sample(self) -> None:
        """The onboarding sample: heard straight from the file while it plays aloud for the user (the
        system capture isn't running, so it isn't heard twice)."""
        path = sample_path()
        if path is None:
            Log.d("sample: no sample.wav")
            return
        if self.listen.listening:
            return
        player = next((p for p in ("pw-play", "paplay", "aplay") if shutil.which(p)), None)
        self.start_listening(PcmAudioSource(path, 1.0), "file")
        if player and self.listen.listening:
            try:
                subprocess.Popen([player, path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            except OSError as e:
                Log.d("sample: play failed %s" % type(e).__name__)

    def feed(self, path: str) -> None:
        """Debug: a WAV heard as if the speakers played it, in real time."""
        self.start_listening(PcmAudioSource(path, 1.0), "file")

    def _signalled(self, sig) -> bool:
        Log.d("app: signal %d, quitting" % sig)
        self.quit()
        return False

    def quit(self) -> None:
        if self.records_window is not None:
            self.records_window.commit_delete()  # a delete still showing 撤销 goes through

        def run():
            self.speak.cancel()
            self.talk_echo.remove()  # the speakers are the default output again
            if self.room.on:
                self.room.remove()  # the real microphone is the default again
            if self.echo.on:
                self.echo.remove()
            if self.listen.listening:
                sid = self.listen.session_id
                self.listen.stop()
                if sid and self.store.get(sid) is not None:
                    self.folder_export.ended(sid)  # kept as waiting: written at the next launch
            self.store.flush()
            GLib.idle_add(lambda: self.application.quit() and False)
        threading.Thread(target=run, daemon=True).start()


class App(Gtk.Application):
    def __init__(self):
        super().__init__(application_id="com.wquguru.cicada.dev" if Paths.dev else "com.wquguru.cicada",
                         flags=Gio.ApplicationFlags.FLAGS_NONE)
        self.controller = None

    def do_startup(self):
        Gtk.Application.do_startup(self)
        self.hold()  # a menu bar style app: no window doesn't mean quit
        GLib.set_application_name(L("知了"))
        self.controller = Controller(self)
        # `cicada --toggle` (a system keyboard shortcut runs it) reaches the running app as this action.
        toggle = Gio.SimpleAction.new("toggle", None)
        toggle.connect("activate", lambda *_: self.controller.request_stop())
        self.add_action(toggle)
        speak = Gio.SimpleAction.new("speak", None)  # `cicada --speak`: 开始 / 停止说
        speak.connect("activate", lambda *_: self.controller.toggle_speaking())
        self.add_action(speak)
        # The update notification's click and its 更新说明 button; a problem's 打开设置.
        for name, action in (("install-update", lambda: self.controller.updates.install()),
                             ("ai-settings", lambda: self.controller.show_settings(ai=True)),
                             # 纪要没存到文件夹: 设置 › 通用, where the row says what to do.
                             ("folder-settings", lambda: self.controller.show_settings(general=True)),
                             ("update-notes", lambda: self.controller.updates.open_notes())):
            a = Gio.SimpleAction.new(name, None)
            a.connect("activate", lambda _a, _p, f=action: f())
            self.add_action(a)
        for name, action, keys in (("quit", self.controller.quit, ["<Control>q"]),
                                   ("settings", self.controller.show_settings, ["<Control>comma"])):
            a = Gio.SimpleAction.new(name, None)
            a.connect("activate", lambda _a, _p, f=action: f())
            self.add_action(a)
            self.set_accels_for_action("app." + name, keys)
        self.controller.launch(speak=getattr(self, "speak_at_start", False), background=getattr(self, "background", False))
        if getattr(self, "toggle_at_start", False):
            GLib.idle_add(lambda: self.controller.toggle_listening() and False)

    def do_activate(self):
        # A second launch lands here in the running instance: the records, and the onboarding on top
        # while not set up (closed with ✕ earlier, it would otherwise never come back).
        if self.controller is not None and getattr(self, "_activated", False):
            self.controller.show_records()
            if not self.controller.settings.onboarded:
                self.controller.show_onboarding()
        self._activated = True


def main(argv=None) -> int:
    argv = list(sys.argv if argv is None else argv)
    if "--dev" in argv:
        Paths.dev = True
        argv.remove("--dev")
    GLib.set_prgname("cicada")
    app = App()
    if "--background" in argv:  # 登录时启动: stay in the top bar
        argv.remove("--background")
        app.background = True
    for flag, action in (("--toggle", "toggle"), ("--speak", "speak")):
        if flag in argv:
            argv.remove(flag)
            if _remote(app.get_application_id(), action):
                return 0  # the running instance starts or stops listening / speaking
            # Not running yet: start, then listen / speak.
            setattr(app, action + "_at_start", True)
    return app.run(argv)


def _remote(app_id: str, action: str) -> bool:
    """Activates the running instance's action over D-Bus (org.gtk.Actions), as GLib's own
    remote activation does, without registering a second application."""
    try:
        bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        bus.call_sync(app_id, "/" + app_id.replace(".", "/"), "org.gtk.Actions", "Activate",
                      GLib.Variant("(sava{sv})", (action, [], {})), None, Gio.DBusCallFlags.NO_AUTO_START, 3000, None)
        return True
    except GLib.Error:
        return False

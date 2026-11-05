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
from ..core import meeting_end  # noqa: E402
from ..core.ling import AIKey, LingClient  # noqa: E402
from ..core.listen import ListenEngine  # noqa: E402
from ..core.notes import NotesEngine  # noqa: E402
from ..core.session_store import SessionStore  # noqa: E402
from ..core.settings import AppSettings  # noqa: E402
from ..core.strings import L, LF  # noqa: E402
from ..core.support import Log, Paths, clock, english_name  # noqa: E402
from ..core.translator import Translator  # noqa: E402
from . import debug, tray, ui  # noqa: E402
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
        self.key = AIKey()
        self.ling = LingClient(self.key)
        self.ling.model = self.settings.model
        self.store = SessionStore()
        self.notes = NotesEngine(self.ling, self.store)
        # 纪要语言 for notes written outside a meeting too (生成纪要 in the records window).
        self.translator = Translator(self.ling)
        self.listen = ListenEngine(self.ling, self.translator, self.store, self.notes, self.settings)
        # 同声传译: my microphone → Ming → 知了 麦克风. The listen side's loudness feeds its echo check.
        from ..core.speak import SpeakEngine
        from .room import Player, VirtualMic
        self.room = VirtualMic()
        self.speak = SpeakEngine(self.ling, self.translator, self.settings, self.store, self.listen, player=lambda: Player())
        self.listen.loudness = self.speak.loudness
        # 说话人识别: voiceprints (native/voiceprint.c), Ling's guesses at names.
        from ..core import speakers
        self.speakers = speakers.Tagger()
        self.listen.speakers = self.speakers
        self.namer = speakers.Namer(self.ling, self.store, self.changed)
        self.listen.on_voice = self.namer.guess
        self.notes.voices = lambda: self.settings.speakerVoices
        self.speak.on_change(self.changed)
        self.listen.on_change(self.changed)
        self.notes.on_change(self.changed)
        self.store.on_change(lambda _id: self.changed())
        self.store.on_words(self._words)
        self.ling.on_change(self.changed)
        self.notes_window = None
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
        GLib.timeout_add_seconds(1, self._tick)
        GLib.timeout_add_seconds(2, self._watch_end)

    def _tick(self) -> bool:
        if self.tray is not None and self.listen.listening:
            self.tray.tick()
        return True

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
            (self.room.create if self.settings.speakEnabled else self.room.leftovers)()
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

    def changed(self) -> None:
        """Engine threads call this: one coalesced refresh on the main loop."""
        if self._queued:
            return
        self._queued = True

        def run():
            self._queued = False
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

    def show_records(self) -> None:
        if self.records_window is None:
            from .records_window import RecordsWindow
            self.records_window = RecordsWindow(self)
            self.application.add_window(self.records_window)
        self.records_window.fill()
        self.records_window.show_all()
        self.records_window.present()
        self.records_window.set_focus(None)  # not the search box: its placeholder would vanish

    def show_settings(self) -> None:
        if self.settings_window is None:
            from .settings_window import SettingsWindow
            self.settings_window = SettingsWindow(self)
            self.application.add_window(self.settings_window)
        self.settings_window.show_all()
        self.settings_window.present()

    # Setup (会议记录 › 还差几步 and the capsule)

    @property
    def setup_done(self) -> tuple:
        """The setup steps as the onboarding numbers them (key, computer sound, sample): done by what
        really happened, not by "the onboarding was finished" (Windows' SetupDone)."""
        s = self.settings
        return self.ling.has_key, s.heardSystemAudio or s.onboarded, s.sampleSeen or s.onboarded

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
        key, audio, _ = self.setup_done
        at = step if step is not None else KEY if not key else AUDIO if not audio else SAMPLE
        if self.onboarding is not None:
            if step is not None and self.onboarding.step != step:
                self.onboarding.go(step)
            self.onboarding.present()
            return
        self.onboarding = Onboarding(self, at)
        self.application.add_window(self.onboarding)
        # Over the records window, so closing it leaves a window to click, not an empty screen.
        if self.records_window is not None and self.records_window.get_visible():
            self.onboarding.set_transient_for(self.records_window)
            self.onboarding.set_position(Gtk.WindowPosition.CENTER_ON_PARENT)

        def closed(*_):
            self.onboarding = None
            if self.tray is None and (self.records_window is None or not self.records_window.get_visible()):
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
            self.start_listening(SystemAudio(), "system")

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

    def start_listening(self, source, kind: str) -> None:
        if self.listen.listening:
            return
        if not self.ling.has_key:
            self.show_onboarding()
            return

        def ended(reason):
            # A file that finished stops a little later, so its last sentence's pause is heard;
            # a capture that failed stops now.
            if reason is None:
                GLib.timeout_add(1500, lambda: self.stop_listening() and False)
                return
            Log.d("listen: source ended %s" % reason)
            # Said where the subtitles would be (start() clears it), not silently stopped.
            self.listen.problem = L("系统声音中断")
            self.listen.problem_kind = "source"
            GLib.idle_add(lambda: self.stop_listening() and False)
        source.on_ended = ended
        self.auto_ended = False
        self.ending = None
        self.end_watch = meeting_end.MeetingEndWatch(self.end_config(), time.time())
        self.listen.start(source, kind)
        self.show_notes()
        self.changed()

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
            self.start_listening(SystemAudio(), "system")

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
        if on and not self.room.on and not self.room.create():
            return False
        if not on:
            self.speak.cancel()
            self.room.remove()
        self.settings.speakEnabled = on
        self.settings.save()
        self.changed()
        return True

    def toggle_speaking(self) -> None:
        if self.speak.active:
            self.speak.stop()
            return
        if not self.ling.has_key:
            self.show_onboarding()
            return
        if not self.settings.speakEnabled or not self.room.on:
            if not self.set_speak_enabled(True):
                self.speak.problem = L("没能建好知了麦克风")
                self.changed()
                return
        # Me, from the microphone that was the default before 知了 麦克风 took its place.
        mic = SystemAudio(self.room.real_mic or "@DEFAULT_SOURCE@")

        def ended(reason):
            if reason:
                Log.d("speak: microphone ended %s" % reason)
                self.speak.problem = L("没有可用的麦克风")
                GLib.idle_add(lambda: self.speak.stop() or False)
        mic.on_ended = ended
        self.speak.start(mic)
        self.show_notes()

    def stop_listening(self, ended_at=None, auto: bool = False) -> None:
        self.end_watch = None
        self.ending = None
        self.auto_ended = auto

        # stop() waits for Ming's last replies: off the main loop.
        def run():
            sid = self.listen.session_id
            self.listen.stop(ended_at)
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
            if self.room.on:
                self.room.remove()  # the real microphone is the default again
            if self.listen.listening:
                self.listen.stop()
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
        # The update notification's click and its 更新说明 button.
        for name, action in (("install-update", lambda: self.controller.updates.install()),
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

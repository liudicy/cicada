"""What the tray menu and 设置 › 关于 show about new versions (the Mac's Updates): a newer release, a
manual check's result, download progress, and why installing in place failed. Checks at launch and
every 4 hours (a 15-minute tick that checks when due, so a laptop that sleeps still checks); a dev
build checks only when CICADA_UPDATE_FEED points at a test feed. While a meeting is being recorded
the update waits for it to end (会后安装) instead of ending it."""
from __future__ import annotations

import os
import subprocess
import threading
import time

from gi.repository import Gio, GLib

from .. import VERSION
from ..core import updates
from ..core.strings import L, LF
from ..core.support import Log, Paths


def open_uri(url: str, done=None) -> None:
    """Opens `url` in the browser, then calls done(opened) on the main thread: True only when
    something said it took it: the browser GIO names for the scheme, else xdg-open exiting cleanly
    (waited for on a thread, up to 10 s: it can take a while to try its fallbacks and fail). Logged: a page
    that doesn't open leaves no other trace."""
    def tell(opened):
        if done is not None:
            GLib.idle_add(lambda: done(opened) and False)

    def xdg_open():
        try:
            p = subprocess.Popen(["xdg-open", url], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL, start_new_session=True)
        except OSError as e:
            Log.d("open: no xdg-open (%s)" % type(e).__name__)
            return tell(False)
        try:
            code = p.wait(10)
        except subprocess.TimeoutExpired:
            Log.d("open: xdg-open still running after 10 s")
            tell(False)  # unconfirmed: say where the page is rather than claim it opened
            p.wait()  # reaped whenever it ends
            return
        if code != 0:
            Log.d("open: xdg-open exited %d" % code)
        tell(code == 0)

    # The scheme's handler, asked for by name: launch_default_for_uri, without one, reads the page
    # through gvfs to guess its type, which blocked the main loop for minutes behind a bad network.
    scheme = url.split(":", 1)[0]
    browser = Gio.AppInfo.get_default_for_uri_scheme(scheme)
    if browser is None:
        Log.d("open: no handler for %s" % scheme)
    else:
        try:
            if browser.launch_uris([url], None):
                return tell(True)
            Log.d("open: %s didn't start" % browser.get_id())
        except GLib.Error as e:
            Log.d("open: %s failed (%s)" % (browser.get_id(), e.message))
    threading.Thread(target=xdg_open, name="OpenPage", daemon=True).start()


class Updates:
    def __init__(self, app):
        self.app = app
        self.update: updates.Update | None = None
        self.check = "idle"          # idle | checking | upToDate | failed (the last manual check)
        self.progress: float | None = None  # 0…1 while downloading; the app quits and reopens when done
        self.failure: str | None = None     # why the last in-place update failed
        self.opened = False                 # and whether the release page opened then
        self.after_meeting = False   # 会后安装: install once this meeting ends
        self.installing = False
        self.started = False
        self._inflight = False       # one check at a time (the tray menu's "show" also fires as it's built)
        # When the last check started, failed or not: a failed one isn't remembered on disk, and the
        # menu is rebuilt (firing "show") whenever a check ends, so offline it would check again at once.
        self._last_try: float | None = None

    @property
    def last_checked(self) -> float | None:
        return updates.last_checked()

    def start(self) -> None:
        if Paths.dev and not os.environ.get("CICADA_UPDATE_FEED"):
            return
        self.started = True
        self._run_check(manual=False)
        GLib.timeout_add_seconds(15 * 60, self._tick)

    def _tick(self) -> bool:
        if updates.due(self.last_checked, time.time(), updates.EVERY):
            self._run_check(manual=False)
        return True

    def menu_opened(self) -> None:
        last = max((t for t in (self.last_checked, self._last_try) if t is not None), default=None)
        if self.started and updates.due(last, time.time(), updates.STALE):
            self._run_check(manual=False)

    def check_now(self) -> None:
        self._run_check(manual=True)

    def _run_check(self, manual: bool) -> None:
        if self._inflight:
            return
        self._inflight = True
        self._last_try = time.time()
        if manual:
            self.check = "checking"
            self.app.changed()

        def run():
            ok, u = updates.check(VERSION)

            def done():
                self._inflight = False
                if ok:
                    if u != self.update:
                        self.failure = None
                    self.update = u
                    self.notify_if_due()
                if manual:
                    self.check = ("upToDate" if u is None else "idle") if ok else "failed"
                self.app.changed()
                return False
            GLib.idle_add(done)
        threading.Thread(target=run, name="Updates", daemon=True).start()

    # Installing

    def install(self) -> None:
        """安装并重新打开; while listening, 会后安装 (the meeting isn't cut short)."""
        u = self.update
        if u is None or self.installing:
            return
        if self.app.listen.listening:
            self.after_meeting = True
            Log.d("update: %s after the meeting" % u.version)
            self.app.changed()
            return
        if updates.install_root() is None:
            # A checkout or a build tree, not an install.sh install: nothing to replace in place.
            self._fail(L("请先用 install.sh 安装知了"), u)
            return
        self.installing, self.failure, self.progress = True, None, 0.0
        self.app.changed()

        def progress(p):
            # Whole percents only: every 64 KB would rebuild the tray menu hundreds of times.
            if self.progress is not None and int(p * 100) == int(self.progress * 100):
                return

            def show():
                self.progress = p
                self.app.changed()
                return False
            GLib.idle_add(show)

        def run():
            try:
                tree = updates.prepare(u, progress)
            except updates.Failure as e:
                why = LF(e.key, *e.args)
                GLib.idle_add(lambda: self._fail(why, u) and False)
                return
            except Exception as e:  # noqa: BLE001
                Log.d("update: failed %s" % type(e).__name__)
                GLib.idle_add(lambda: self._fail(L("更新包无效"), u) and False)
                return
            GLib.idle_add(lambda: self._hand_over(tree, u) and False)
        threading.Thread(target=run, name="Update", daemon=True).start()

    def _hand_over(self, tree: str, u) -> None:
        updates.hand_over(tree, u.version, ["--dev"] if Paths.dev else [])
        self.app.quit()

    def _fail(self, why: str, u) -> None:
        """Opens the release page, then says why, and whether the page really opened."""
        def done(opened):
            self.installing, self.progress, self.failure, self.opened = False, None, why, opened
            Log.d("update: in place failed; release page %s" % ("opened" if opened else "didn't open"))
            self.app.changed()
        open_uri(u.url, done)

    def notify_if_due(self) -> None:
        """One desktop notification per version, for people who never open the tray menu; a click
        installs (会后安装 while a meeting is on). Held while listening or speaking: meeting_ended
        tells. Withdrawn once there's nothing newer (installed, or the release was pulled)."""
        u = self.update
        if u is None:
            self.app.application.withdraw_notification("update")
            return
        busy = self.app.listen.listening or self.app.speak.active
        if not updates.should_notify(u.version, updates.notified(), busy):
            return
        updates.remember_notified(u.version)
        n = Gio.Notification.new(LF("知了有新版本 %@", u.version))
        n.set_body(L("点按安装，完成后自动重新打开"))
        n.set_default_action("app.install-update")
        n.add_button(L("更新说明"), "app.update-notes")
        self.app.application.send_notification("update", n)
        Log.d("update: notified %s" % u.version)

    def open_notes(self) -> None:
        if self.update is not None:
            open_uri(self.update.url)

    def meeting_ended(self) -> None:
        self.notify_if_due()
        if self.after_meeting and not self.app.listen.listening:
            self.after_meeting = False
            self.install()

    def reopened(self) -> str | None:
        """After an update reopened the app: the line to show once (已更新到 …), or None."""
        r = updates.take_result()
        if r is None:
            return None
        if r[0] == "ok" and r[1] == VERSION:
            Log.d("update: now %s" % VERSION)
            return LF("已更新到 %@", VERSION)
        Log.d("update: install of %s didn't finish" % r[1])
        self.failure = L("安装没有完成")
        return LF("没能更新到 %@，还是原来的版本", r[1])

    # What the UI shows

    def menu_label(self) -> str | None:
        """The tray menu's first item, or None (no update)."""
        u = self.update
        if u is None:
            return None
        if self.progress is not None:
            return LF("正在下载 %@：%lld%%", u.version, int(self.progress * 100))
        if self.after_meeting or self.app.listen.listening:
            return LF("新版本 %@", u.version) + " · " + L("会后安装")
        return LF("新版本 %@", u.version) + " · " + L("安装并重新打开")

    def detail(self) -> str:
        """The grey line under 版本 in 设置 › 关于."""
        u = self.update
        if u is not None:
            if self.progress is not None:
                return LF("正在下载 %@：%lld%%", u.version, int(self.progress * 100))
            if self.failure and self.opened:
                return LF("没能自动更新：%@。已打开下载页", self.failure)
            if self.failure:
                # No browser came up: the address to type, selectable in 设置 › 关于.
                return LF("没能自动更新：%@。请在浏览器里打开 %@ 下载", self.failure, u.url.split("://", 1)[-1])
            if self.after_meeting:
                return LF("有新版本 %@", u.version) + " · " + L("会议结束后安装")
            size = ("%.1f MB · " % (u.size / 1e6)) if u.size else ""
            return LF("有新版本 %@", u.version) + " · " + size + L("安装后自动重新打开")
        if self.check == "checking":
            return L("正在检查…")
        if self.check == "upToDate":
            return L("已是最新版本")
        if self.check == "failed":
            return L("连不上 GitHub，请稍后再试")
        last = self.last_checked
        if last:
            t = time.localtime(last)
            same_day = time.strftime("%Y%m%d", t) == time.strftime("%Y%m%d")
            return LF("上次检查 %@", time.strftime("%H:%M" if same_day else "%m-%d %H:%M", t))
        return ""

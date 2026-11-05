"""New versions (the Mac's UpdateChecker and Updater): GitHub Releases is read at launch and when a
check is due, the newest release that ships the Linux tarball is offered, and installing it
downloads the tarball, checks it against the release's checksums.txt, unpacks it and hands it to a
small script that runs its install.sh once the app has quit, then opens Cicada again.

UI-free and stdlib only: the app shows the state, this module finds, fetches and checks."""
from __future__ import annotations

import hashlib
import json
import os
import shlex
import shutil
import subprocess
import tarfile
import tempfile
import time
import urllib.request

from . import jsonfmt
from .support import Log, Paths

# The list, not releases/latest: every platform shares one version, and a release that only ships
# the Mac or Windows has no Linux tarball, so the newest Linux release may be further down.
FEED = "https://api.github.com/repos/wquguru/cicada/releases?per_page=20"
# How often a running app checks, and how old a check must be before a manual-ish one (the tray
# menu, waking) checks again. GitHub allows 60 anonymous API calls an hour.
EVERY = 4 * 60 * 60
STALE = 60 * 60
USER_AGENT = "Cicada-Linux"


class Update:
    def __init__(self, version: str, url: str, tarball: str | None, checksums: str | None, size: int, name: str):
        self.version, self.url, self.tarball, self.checksums, self.size, self.name = version, url, tarball, checksums, size, name

    def __eq__(self, other) -> bool:
        return isinstance(other, Update) and vars(self) == vars(other)

    def __repr__(self) -> str:
        return "Update(%s)" % self.version


class Failure(Exception):
    """Why installing in place didn't work, said to the user (the release page opens instead): a
    Mac string key and its values, translated by the app."""

    def __init__(self, key: str, *args):
        super().__init__(key)
        self.key, self.args = key, args


def feed() -> str:
    """CICADA_UPDATE_FEED points at another release JSON (a list or one release); file:// works."""
    return os.environ.get("CICADA_UPDATE_FEED") or FEED


def is_newer(a: str, than: str) -> bool:
    """Dotted numeric versions: "2.10.0" is newer than "2.9.1"."""
    def parts(v):
        out = []
        for p in v.strip().lstrip("v").split("."):
            try:
                out.append(int(p))
            except ValueError:
                out.append(0)
        return out
    x, y = parts(a), parts(than)
    for i in range(max(len(x), len(y))):
        l, r = (x[i] if i < len(x) else 0), (y[i] if i < len(y) else 0)
        if l != r:
            return l > r
    return False


def due(last: float | None, now: float, after: float) -> bool:
    if last is None:
        return True
    # A clock set back leaves `last` in the future: check rather than wait for it.
    return now - last >= after or last > now


def decode(data: bytes) -> list | None:
    try:
        v = json.loads(data)
    except ValueError:
        return None
    if isinstance(v, dict):
        v = [v]
    return v if isinstance(v, list) else None


def newest_linux(releases: list) -> Update | None:
    """The newest published release with the Linux tarball. One without it carries only other
    platforms (Linux had no change), so it is skipped, not offered."""
    best = None
    for r in releases:
        if not isinstance(r, dict) or r.get("draft") or r.get("prerelease"):
            continue
        assets = [a for a in r.get("assets") or [] if isinstance(a, dict)]
        tar = next((a for a in assets if str(a.get("name", "")).startswith("Cicada-")
                    and str(a.get("name", "")).endswith("-Linux.tar.gz")), None)
        if tar is None or not r.get("tag_name") or not r.get("html_url"):
            continue
        sums = next((a for a in assets if a.get("name") == "checksums.txt"), None)
        u = Update(str(r["tag_name"]).strip().lstrip("v"), r["html_url"], tar.get("browser_download_url"),
                   sums.get("browser_download_url") if sums else None, int(tar.get("size") or 0), tar["name"])
        if best is None or is_newer(u.version, best.version):
            best = u
    return best


def checksum_for(text: str, name: str) -> str | None:
    """The SHA-256 of `name` in a sha256sum listing ("<hex>  <name>", or "<hex> *<name>")."""
    for line in text.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and parts[1].lstrip("*") == name:
            return parts[0].lower()
    return None


# Where the last successful check is remembered (the Mac keeps it in UserDefaults).

def _state_file() -> str:
    return os.path.join(Paths.data(), "updates.json")


def _state() -> dict:
    try:
        with open(_state_file(), encoding="utf-8") as f:
            v = json.load(f)
        return v if isinstance(v, dict) else {}
    except (OSError, ValueError):
        return {}


def _save(**changes) -> None:
    state = _state()
    state.update(changes)
    os.makedirs(Paths.data(), exist_ok=True)
    with open(_state_file(), "w", encoding="utf-8") as f:
        f.write(jsonfmt.write(state))


def last_checked() -> float | None:
    v = _state().get("lastChecked")
    try:
        return float(v) if v is not None else None
    except (TypeError, ValueError):
        return None


def _remember(when: float) -> None:
    _save(lastChecked=when)


def notified() -> str | None:
    """The version the update notification was last shown for: one per version."""
    v = _state().get("notified")
    return v if isinstance(v, str) else None


def remember_notified(version: str) -> None:
    _save(notified=version)


def should_notify(version: str, told: str | None, busy: bool) -> bool:
    """A notification per version, none while listening or speaking (the meeting's end tells)."""
    return not busy and version != told


def _get(url: str, timeout: float = 20):
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "application/vnd.github+json"})
    return urllib.request.urlopen(req, timeout=timeout)  # noqa: S310 - our feed, or file:// in tests


def check(current: str) -> tuple:
    """(ok, update): ok is False when the feed couldn't be reached or answered oddly; update is a
    release newer than `current`, or None. Blocking: run it off the main thread."""
    try:
        with _get(feed()) as r:
            if getattr(r, "status", 200) not in (200, None):
                return False, None
            releases = decode(r.read())
    except Exception as e:  # noqa: BLE001 - offline, rate-limited, private repo (404): all silent
        Log.d("update: check failed (%s)" % type(e).__name__)
        return False, None
    if releases is None:
        return False, None
    u = newest_linux(releases)
    _remember(time.time())
    Log.d("update: checked, latest Linux %s, running %s" % (u.version if u else "none", current))
    return True, (u if u and is_newer(u.version, current) else None)


# Installing

def install_root() -> str | None:
    """The install this app runs from, when it's one install.sh made (~/.local/lib/cicada): only
    that can be replaced in place. A checkout or a build tree gets the release page instead."""
    here = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    lib = os.path.realpath(os.path.expanduser("~/.local/lib/cicada"))
    return here if os.path.realpath(here) == lib and os.path.isfile(os.path.join(here, "VERSION")) else None


def _download(url: str, to: str, progress, expected: int = 0) -> None:
    with _get(url, timeout=60) as r, open(to, "wb") as f:
        total = int(r.headers.get("Content-Length") or expected or 0)
        got = 0
        while True:
            chunk = r.read(64 * 1024)
            if not chunk:
                break
            f.write(chunk)
            got += len(chunk)
            if total and progress:
                progress(min(1.0, got / total))


def _safe_extract(tar_path: str, into: str) -> None:
    """Unpacks only regular files and folders that stay inside `into`: a tarball that names
    absolute paths, "..", links or devices is refused rather than trusted."""
    root = os.path.realpath(into)
    with tarfile.open(tar_path, "r:gz") as t:
        for m in t.getmembers():
            target = os.path.realpath(os.path.join(root, m.name))
            if not (m.isfile() or m.isdir()) or os.path.isabs(m.name) or not target.startswith(root + os.sep):
                raise Failure("更新包无效")
        t.extractall(root)  # noqa: S202 - every member checked above


def prepare(u: Update, progress=None) -> str:
    """Downloads and checks the release; returns the unpacked tree (…/cicada-linux) ready for its
    install.sh. Raises Failure with a reason to show. Blocking: run it off the main thread."""
    if not u.tarball or not u.checksums:
        raise Failure("这个版本没有可安装的文件")
    work = tempfile.mkdtemp(prefix="cicada-update-")
    try:
        tar_path = os.path.join(work, u.name)
        try:
            with _get(u.checksums) as r:
                want = checksum_for(r.read().decode("utf-8", "replace"), u.name)
            _download(u.tarball, tar_path, progress, u.size)
        except Failure:
            raise
        except Exception as e:  # noqa: BLE001
            code = getattr(e, "code", None)
            raise (Failure("下载失败（HTTP %lld）", code) if code else Failure("下载失败")) from e
        h = hashlib.sha256()
        with open(tar_path, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        if want is None or h.hexdigest() != want:
            raise Failure("下载的文件校验不通过")
        _safe_extract(tar_path, work)
        tree = os.path.join(work, "cicada-linux")
        try:
            with open(os.path.join(tree, "VERSION"), encoding="utf-8") as f:
                got = f.read().strip()
        except OSError:
            raise Failure("更新包无效") from None
        if got != u.version:
            raise Failure("下载的不是预期的版本")
        # The new version's own dependency check, before anything is replaced or the app quits.
        r = subprocess.run(["sh", os.path.join(tree, "install.sh"), "--check"], capture_output=True, text=True)
        if r.returncode != 0:
            # install.sh says which packages are missing (and the apt line); shown as it is.
            raise Failure("%@", (r.stdout or r.stderr).strip() or "The update package is invalid")
        return tree
    except BaseException:
        shutil.rmtree(work, ignore_errors=True)
        raise


def marker_file() -> str:
    """Left by the swap script for the reopened app: "ok <version>" or "failed <version>"."""
    return os.path.join(Paths.data(), "update-result")


def take_result() -> tuple | None:
    """("ok"|"failed", version) once after an update reopened the app, then forgotten."""
    p = marker_file()
    try:
        with open(p, encoding="utf-8") as f:
            parts = f.read().split()
        os.unlink(p)
    except OSError:
        return None
    return (parts[0], parts[1]) if len(parts) == 2 and parts[0] in ("ok", "failed") else None


def hand_over(tree: str, version: str, argv: list) -> None:
    """Starts the script that waits for this process to quit, runs the new install.sh and opens
    Cicada again with the same arguments; the caller quits next. If install.sh fails the old
    install is untouched (it only replaces after its checks), so that one reopens."""
    pid = os.getpid()
    os.makedirs(Paths.data(), exist_ok=True)
    marker = marker_file()
    launcher = os.path.expanduser("~/.local/lib/cicada/bin/cicada")
    log = os.path.join(tempfile.gettempdir(), "cicada-update.log")
    script = (
        "while kill -0 %d 2>/dev/null; do sleep 0.2; done\n"
        "if sh %s >%s 2>&1; then echo 'ok %s' > %s; else echo 'failed %s' > %s; fi\n"
        "rm -rf %s\n"
        "exec %s %s\n"
    ) % (pid, shlex.quote(os.path.join(tree, "install.sh")), shlex.quote(log), version, shlex.quote(marker),
         version, shlex.quote(marker), shlex.quote(os.path.dirname(tree)), shlex.quote(launcher),
         " ".join(shlex.quote(a) for a in argv))
    subprocess.Popen(["sh", "-c", script], start_new_session=True, stdin=subprocess.DEVNULL,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, close_fds=True,
                     env={k: v for k, v in os.environ.items() if k != "PYTHONPATH"})
    Log.d("update: handing over to install %s (pid %d)" % (version, pid))

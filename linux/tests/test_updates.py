"""Updates: the Mac's UpdateTests case for case, then downloading, checking and unpacking a release
from a file:// feed, the way the app installs one."""
from __future__ import annotations

import hashlib
import io
import json
import os
import sys
import tarfile
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from cicada.core import updates  # noqa: E402
from cicada.core.strings import LF  # noqa: E402
from cicada.core.support import Paths  # noqa: E402

NOW = 1_000_000.0


def release(tag, assets, prerelease=False, base="https://x/"):
    return {"tag_name": tag, "html_url": "https://x/" + tag, "prerelease": prerelease,
            "assets": [{"name": a, "browser_download_url": base + a, "size": 1} for a in assets]}


def newest(rs):
    u = updates.newest_linux(updates.decode(json.dumps(rs).encode()))
    return u.version if u else None


class Versions(unittest.TestCase):
    def test_versions_compare_numerically(self):
        self.assertTrue(updates.is_newer("2.10.0", "2.9.1"))
        self.assertTrue(updates.is_newer("2.0.1", "2.0"))
        self.assertFalse(updates.is_newer("2.0", "2.0.0"))
        self.assertFalse(updates.is_newer("1.9.9", "2.0.0"))
        self.assertFalse(updates.is_newer("2.0.0", "2.0.0"))

    def test_checksum_is_found_by_name(self):
        f = "AAA111  Cicada-2.1.0-Linux.tar.gz\nBBB222 *Cicada-2.1.0-Windows-x64.zip\n"
        self.assertEqual("bbb222", updates.checksum_for(f, "Cicada-2.1.0-Windows-x64.zip"))
        self.assertEqual("aaa111", updates.checksum_for(f, "Cicada-2.1.0-Linux.tar.gz"))
        self.assertIsNone(updates.checksum_for(f, "Cicada-2.0.0-Linux.tar.gz"))

    def test_a_literal_percent(self):
        self.assertEqual("正在下载 1.3.0：42%", LF("正在下载 %@：%lld%%", "1.3.0", 42))


class Releases(unittest.TestCase):
    def test_a_release_without_the_linux_tarball_is_skipped(self):
        linux = release("v1.1.0", ["Cicada-1.1.0-Linux.tar.gz", "checksums.txt"])
        mac = release("v1.2.0", ["Cicada-1.2.0-macOS-AppleSilicon.zip", "checksums.txt"])
        self.assertEqual("1.1.0", newest([mac, linux]))
        self.assertIsNone(newest([mac]))

    def test_prereleases_are_skipped_and_newest_wins(self):
        old = release("v1.0.0", ["Cicada-1.0.0-Linux.tar.gz"])
        new = release("v1.10.0", ["Cicada-1.10.0-Linux.tar.gz"])
        beta = release("v2.0.0", ["Cicada-2.0.0-Linux.tar.gz"], prerelease=True)
        self.assertEqual("1.10.0", newest([beta, old, new]))

    def test_a_single_release_feed_still_works(self):
        one = release("v1.3.0", ["Cicada-1.3.0-Linux.tar.gz"])
        self.assertEqual("1.3.0", updates.newest_linux(updates.decode(json.dumps(one).encode())).version)

    def test_drafts_are_skipped(self):
        d = release("v3.0.0", ["Cicada-3.0.0-Linux.tar.gz"])
        d["draft"] = True
        self.assertIsNone(newest([d]))


class Schedule(unittest.TestCase):
    def test_due_when_never_checked_or_old_enough(self):
        self.assertTrue(updates.due(None, NOW, updates.EVERY))
        self.assertTrue(updates.due(NOW - 4 * 3600, NOW, updates.EVERY))
        self.assertFalse(updates.due(NOW - 3 * 3600, NOW, updates.EVERY))
        self.assertTrue(updates.due(NOW - 3601, NOW, updates.STALE))
        self.assertFalse(updates.due(NOW - 600, NOW, updates.STALE))

    def test_due_when_last_check_is_in_the_future(self):
        self.assertTrue(updates.due(NOW + 86_400, NOW, updates.EVERY))


class Install(unittest.TestCase):
    """A release on disk: a tarball like scripts/build.sh makes, its checksums, and a feed."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        Paths.home_override = os.path.join(self.dir, "home")
        self.addCleanup(setattr, Paths, "home_override", None)
        self.addCleanup(os.environ.pop, "CICADA_UPDATE_FEED", None)

    def publish(self, version="9.0.0", tree_version=None, install_ok=True, extra=None, bad_sum=False):
        name = "Cicada-%s-Linux.tar.gz" % version
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode="w:gz") as t:
            def add(path, text, mode=0o644):
                data = text.encode()
                info = tarfile.TarInfo(path)
                info.size, info.mode = len(data), mode
                t.addfile(info, io.BytesIO(data))
            add("cicada-linux/VERSION", (tree_version or version) + "\n")
            add("cicada-linux/install.sh", "#!/bin/sh\n[ \"$1\" = --check ] && exit %d\nexit 0\n" % (0 if install_ok else 1)
                if install_ok else "#!/bin/sh\necho 'Cicada needs: libpulse0  (sudo apt install libpulse0)'\nexit 1\n", 0o755)
            if extra:
                extra(t)
        data = buf.getvalue()
        with open(os.path.join(self.dir, name), "wb") as f:
            f.write(data)
        digest = "0" * 64 if bad_sum else hashlib.sha256(data).hexdigest()
        with open(os.path.join(self.dir, "checksums.txt"), "w") as f:
            f.write("%s  %s\n" % (digest, name))
        feed = os.path.join(self.dir, "releases.json")
        with open(feed, "w") as f:
            json.dump([release("v" + version, [name, "checksums.txt"], base="file://" + self.dir + "/")], f)
        os.environ["CICADA_UPDATE_FEED"] = "file://" + feed

    def test_a_newer_release_is_found_and_remembered(self):
        self.publish("9.0.0")
        ok, u = updates.check("1.2.0")
        self.assertTrue(ok)
        self.assertEqual("9.0.0", u.version)
        self.assertIsNotNone(updates.last_checked())
        ok, u = updates.check("9.0.0")
        self.assertTrue(ok)
        self.assertIsNone(u, "the same version isn't offered")

    def test_an_unreachable_feed_fails_quietly(self):
        os.environ["CICADA_UPDATE_FEED"] = "file://" + os.path.join(self.dir, "missing.json")
        self.assertEqual((False, None), updates.check("1.0.0"))

    def test_prepare_unpacks_a_checked_release(self):
        self.publish("9.0.0")
        seen = []
        tree = updates.prepare(updates.check("1.0.0")[1], seen.append)
        self.assertTrue(os.path.isfile(os.path.join(tree, "install.sh")))
        self.assertEqual(1.0, seen[-1])

    def failure(self, **kw):
        self.publish("9.0.0", **kw)
        u = updates.check("1.0.0")[1]
        with self.assertRaises(updates.Failure) as c:
            updates.prepare(u)
        return c.exception

    def test_a_bad_checksum_is_refused(self):
        self.assertEqual("下载的文件校验不通过", self.failure(bad_sum=True).key)

    def test_the_wrong_version_inside_is_refused(self):
        self.assertEqual("下载的不是预期的版本", self.failure(tree_version="8.0.0").key)

    def test_missing_libraries_are_said_before_anything_changes(self):
        e = self.failure(install_ok=False)
        self.assertIn("sudo apt install libpulse0", e.args[0])

    def test_a_tarball_escaping_its_folder_is_refused(self):
        def evil(t):
            info = tarfile.TarInfo("../outside.txt")
            info.size = 1
            t.addfile(info, io.BytesIO(b"x"))
        self.assertEqual("更新包无效", self.failure(extra=evil).key)
        self.assertFalse(os.path.exists(os.path.join(tempfile.gettempdir(), "outside.txt")))

    def test_the_reopened_app_hears_the_result_once(self):
        os.makedirs(Paths.data(), exist_ok=True)
        with open(updates.marker_file(), "w") as f:
            f.write("ok 9.0.0\n")
        self.assertEqual(("ok", "9.0.0"), updates.take_result())
        self.assertIsNone(updates.take_result())

    def test_only_an_installed_copy_updates_in_place(self):
        self.assertIsNone(updates.install_root(), "a checkout is not ~/.local/lib/cicada")


class Notify(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        Paths.home_override = os.path.join(self.dir, "home")

    def tearDown(self):
        Paths.home_override = None

    def test_once_per_version_and_not_while_busy(self):
        self.assertTrue(updates.should_notify("1.1.0", None, False))
        self.assertTrue(updates.should_notify("1.2.0", "1.1.0", False))
        self.assertFalse(updates.should_notify("1.1.0", "1.1.0", False))
        self.assertFalse(updates.should_notify("1.1.0", None, True))

    def test_notified_is_kept_beside_last_checked(self):
        updates._remember(NOW)
        updates.remember_notified("1.1.0")
        updates._remember(NOW + 1)
        self.assertEqual(updates.notified(), "1.1.0")
        self.assertEqual(updates.last_checked(), NOW + 1)


if __name__ == "__main__":
    unittest.main()

"""存到文件夹: the file name and frontmatter are a contract with the Mac and the other ports
(Tests/fixtures/folder-export), then the exporter against a folder in a temporary directory."""
from __future__ import annotations

import json
import os
import shutil
import stat
import sys
import tempfile
import unittest
from datetime import timedelta
from zoneinfo import ZoneInfo

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
REPO = os.path.dirname(os.path.dirname(HERE))
FIXTURES = os.path.join(REPO, "Tests", "fixtures", "folder-export")

from cicada.core import folder_export as fx, strings  # noqa: E402
from cicada.core.models import Session  # noqa: E402
from cicada.core.session_store import SessionStore, default_title  # noqa: E402
from cicada.core.settings import AppSettings  # noqa: E402
from cicada.core.support import Paths  # noqa: E402


def read(name: str) -> str:
    with open(os.path.join(FIXTURES, name), encoding="utf-8", newline="") as f:
        return f.read()


def cases() -> dict:
    return json.loads(read("cases.json"))


def session() -> Session:
    return Session.read(read("session.json"))


class FormatTests(unittest.TestCase):
    def test_frontmatter_bytes(self):
        tz = ZoneInfo(cases()["timeZone"])
        self.assertEqual(read("frontmatter.md"), fx.frontmatter(session(), tz))

    def test_file_name(self):
        c = cases()
        st = fx.stem(session(), ZoneInfo(c["timeZone"]))
        self.assertEqual(c["fileName"], fx.file_name(st, lambda _n: False))

    def test_names(self):
        for given, want in cases()["names"]:
            self.assertEqual(want, fx.safe_name(given), given)

    def test_stems(self):
        c = cases()
        s = session()
        for title, want in c["stems"]:
            s.title = title
            self.assertEqual(want, fx.stem(s, ZoneInfo(c["timeZone"])))

    def test_escapes(self):
        for given, want in cases()["escapes"]:
            self.assertEqual(want, fx.quote(given), given)
        # Short forms only for \n \r \t; json.dumps would write \b and \f.
        self.assertEqual('"\\u0008\\u000c\\u001f"', fx.quote("\b\f\x1f"))

    def test_collisions(self):
        for c in cases()["collisions"]:
            self.assertEqual(c["want"], fx.file_name(c["stem"], lambda n, t=c["taken"]: n in t))

    def test_name_precedence(self):
        """The user's title, else the notes', else the imported file's; never the display title."""
        s = session()
        s.renamed = False
        s.title = default_title(s.startedAt)
        self.assertEqual("产品路线评审", fx.name(s))
        s.notes = None
        self.assertEqual("", fx.name(s))
        s.sourceFile = "Weekly sync.m4a"
        self.assertEqual("Weekly sync", fx.name(s))
        self.assertIn('source: "file"\nnotes: "none"', fx.frontmatter(s))
        # An older record (no `renamed`): any title but the default one is the user's.
        s.renamed = None
        s.title = "周会"
        self.assertEqual("周会", fx.name(s))

    def test_utc_offset_and_draft(self):
        s = session()
        s.notes.final = False
        text = fx.frontmatter(s, ZoneInfo("UTC"))
        self.assertIn('started: "2026-11-06T06:00:00+00:00"', text)
        self.assertIn('notes: "draft"', text)

    def test_obsidian_vaults(self):
        text = '{"vaults":{"a":{"path":"/v/old","ts":1},"b":{"path":"/v/new","ts":5,"open":true},"c":{"path":"/gone","ts":9}}}'
        self.assertEqual(["/v/new", "/v/old"], fx.obsidian_vaults(text, lambda p: p != "/gone"))
        self.assertEqual([], fx.obsidian_vaults("not json"))
        self.assertEqual("/v/new/Cicada", fx.default_folder(["/v/new"]))
        self.assertEqual("/docs/Cicada", fx.default_folder([], "/docs"))
        self.assertEqual("/v/new", fx.vault_of("/v/new/Cicada", ["/v/new"]))
        self.assertIsNone(fx.vault_of("/v/newer", ["/v/new"]))

    def test_short_path(self):
        self.assertEqual("工作笔记 › Cicada", fx.short_path("/home/me/工作笔记/Cicada/"))


class ExporterTests(unittest.TestCase):
    def setUp(self):
        strings.load("zh-Hans", [os.path.join(REPO, "Resources")])
        self.home = tempfile.mkdtemp()
        Paths.home_override = self.home
        self.folder = os.path.join(self.home, "vault", "Cicada")
        os.makedirs(os.path.dirname(self.folder))
        self.store = SessionStore()
        self.settings = AppSettings()
        self.settings.save = lambda: None
        self.ex = self.exporter()
        self.denied = 0

    def tearDown(self):
        Paths.home_override = None
        for root, dirs, _files in os.walk(self.home):
            for d in dirs:
                os.chmod(os.path.join(root, d), 0o700)
        shutil.rmtree(self.home, ignore_errors=True)

    def exporter(self):
        ex = fx.FolderExporter(self.store, self.settings, delay=0.01)
        ex.on_denied = lambda: setattr(self, "denied", self.denied + 1)
        return ex

    def add(self, sid="20261106-140000", title="产品路线评审", minutes=0) -> Session:
        s = session()
        s.id = sid
        s.title = title
        s.startedAt = s.startedAt + timedelta(minutes=minutes)
        s.endedAt = s.startedAt + timedelta(minutes=48)
        self.store.import_session(s)
        return s

    def files(self) -> list:
        return sorted(os.listdir(self.folder))

    def test_written_rewritten_moved(self):
        self.ex.choose(self.folder)
        self.ex.wait()
        self.assertIsNone(self.ex.problem)
        self.add()
        self.ex.ended("20261106-140000")
        self.ex.wait()
        name = self.ex.index.files["20261106-140000"]
        self.assertTrue(name.endswith(" 产品路线评审.md"))
        self.assertEqual([name], self.files())
        with open(os.path.join(self.folder, name), encoding="utf-8") as f:
            text = f.read()
        self.assertTrue(text.startswith('---\ncicada: 1\nid: "20261106-140000"\n'))
        self.assertIn("\n---\n# 产品路线评审\n", text)
        self.assertEqual([], self.ex.index.pending)
        self.assertEqual(name, self.ex.index.lastFile)
        # Unchanged: not written again.
        mtime = os.stat(os.path.join(self.folder, name)).st_mtime_ns
        self.ex.saved("20261106-140000")
        self.ex.wait()
        self.assertEqual(mtime, os.stat(os.path.join(self.folder, name)).st_mtime_ns)
        # Renamed: the file moves.
        self.store.rename("20261106-140000", "路线")
        self.store.flush()
        self.ex.saved("20261106-140000")
        self.ex.wait()
        self.assertEqual([name.replace("产品路线评审", "路线")], self.files())
        # Deleted in Cicada: the file stays.
        self.ex.deleted("20261106-140000")
        self.assertEqual(1, len(self.files()))
        # The index survives a restart.
        self.assertEqual(self.ex.index.folder, self.exporter().index.folder)

    def test_never_overwrites_a_foreign_file(self):
        self.ex.choose(self.folder)
        self.ex.wait()
        s = self.add()
        mine = fx.stem(s) + ".md"
        with open(os.path.join(self.folder, mine), "w") as f:
            f.write("someone's")
        self.ex.ended(s.id)
        self.ex.wait()
        self.assertEqual(fx.stem(s) + " 2.md", self.ex.index.files[s.id])
        with open(os.path.join(self.folder, mine)) as f:
            self.assertEqual("someone's", f.read())

    def test_waits_for_the_final_notes(self):
        self.ex.choose(self.folder)
        self.ex.wait()
        s = self.add()
        busy = {s.id}
        self.ex.settling = lambda sid: sid in busy
        self.ex.ended(s.id)
        self.ex.wait()
        self.assertEqual([s.id], self.ex.index.pending)
        self.assertEqual([], self.files())
        busy.clear()
        self.ex.settled(s.id)
        self.ex.wait()
        self.assertEqual([], self.ex.index.pending)
        self.assertEqual(1, len(self.files()))

    def test_write_all_and_new_folder(self):
        self.add("20261106-140000", "一")
        self.add("20261106-150000", "二", minutes=60)
        self.ex.choose(self.folder)
        self.ex.wait()
        self.assertEqual(2, len(self.ex.unwritten()))
        self.ex.write_all()
        self.ex.wait()
        self.assertEqual(2, len(self.files()))
        self.assertEqual([], self.ex.unwritten())
        other = os.path.join(self.home, "other")
        self.ex.choose(other)
        self.ex.wait()
        self.assertEqual({}, self.ex.index.files)
        self.assertEqual(2, len(self.ex.unwritten()))
        self.assertEqual(2, len(self.files()))  # the old folder's files stay

    def test_missing_then_back(self):
        self.ex.choose(self.folder)
        self.ex.wait()
        s = self.add()
        shutil.rmtree(os.path.dirname(self.folder))  # the drive went
        self.ex.ended(s.id)
        self.ex.wait()
        self.assertEqual(fx.MISSING, self.ex.problem)
        self.assertEqual([s.id], self.ex.index.pending)
        self.assertEqual(0, self.denied)
        os.makedirs(os.path.dirname(self.folder))  # back: only the last folder is made again
        self.ex.retry()
        self.ex.wait()
        self.assertIsNone(self.ex.problem)
        self.assertEqual(1, len(self.files()))

    @unittest.skipIf(hasattr(os, "geteuid") and os.geteuid() == 0, "root writes anywhere")
    def test_denied_notifies_once(self):
        self.ex.choose(self.folder)
        self.ex.wait()
        self.add("20261106-140000", "一")
        self.add("20261106-150000", "二", minutes=60)
        os.chmod(self.folder, stat.S_IRUSR | stat.S_IXUSR)
        self.ex.write_all()
        self.ex.wait()
        self.assertEqual(fx.DENIED, self.ex.problem)
        self.assertEqual(0, self.denied)  # never for 也存一份
        self.ex.ended("20261106-140000")
        self.ex.wait()
        self.ex.ended("20261106-150000")
        self.ex.wait()
        self.assertEqual(1, self.denied)
        self.assertEqual(2, len(self.ex.index.pending))
        os.chmod(self.folder, 0o700)
        self.ex.retry()
        self.ex.wait()
        self.assertIsNone(self.ex.problem)
        self.assertEqual(2, len(self.files()))

    def test_a_record_that_fails_to_render_holds_up_nothing(self):
        self.ex.choose(self.folder)
        self.ex.wait()
        self.add("20261106-140000", "一")
        self.add("20261106-150000", "二", minutes=60)
        real = fx.document

        def document(s, voices=False):
            if s.id == "20261106-140000":
                raise ValueError("bad record")
            return real(s, voices)
        fx.document = document
        try:
            for _ in range(2):
                self.ex.write_all()
                self.ex.wait()
        finally:
            fx.document = real
        self.assertEqual(1, len(self.files()), "the good one, once")
        self.assertEqual(["20261106-140000"], self.ex.index.pending)

    def test_off_writes_nothing(self):
        s = self.add()
        self.ex.ended(s.id)
        self.ex.wait()
        self.assertEqual([], self.ex.index.pending)
        self.assertFalse(os.path.exists(self.folder))


if __name__ == "__main__":
    unittest.main()

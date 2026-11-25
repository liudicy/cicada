"""Something only the user can fix (problem.py, the Mac's AIServiceStrip.blocking): which reasons
count, and when the notification is due."""
from __future__ import annotations

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from cicada.core import aicheck, problem  # noqa: E402
from cicada.core.problem import Notices  # noqa: E402


class Reasons(unittest.TestCase):
    def test_which_reasons_block(self):
        for r in ("invalidKey", "mgmtKey", "noCredit", "noModel", "badAddress", "noJSON", "deaf"):
            self.assertTrue(problem.blocking(r), r)
        for r in ("unreachable", "busy", "serverError", None):
            self.assertFalse(problem.blocking(r), r)
        self.assertEqual(set(aicheck.REASONS), set(problem.BLOCKING) | {"unreachable", "busy", "serverError"})

    def test_notes_only_reasons_leave_hearing(self):
        self.assertFalse(problem.stops_hearing("noModel"))
        self.assertFalse(problem.stops_hearing("noJSON"))
        self.assertTrue(problem.stops_hearing("noCredit"))
        self.assertTrue(problem.stops_hearing("deaf"))
        self.assertFalse(problem.stops_hearing("unreachable"))

    def test_titles_are_the_macs(self):
        t = lambda r: problem.title(r, "OpenRouter", "qwen/text", "qwen/omni")  # noqa: E731
        self.assertEqual("OpenRouter 的 key 用不了", t("invalidKey"))
        self.assertEqual("OpenRouter 的 key 用不了", t("mgmtKey"))
        self.assertEqual("OpenRouter 账户余额不足。", t("noCredit"))
        self.assertEqual("OpenRouter 上找不到 qwen/text 这个模型。", t("noModel"))
        self.assertEqual("AI 服务的设置要改一下", t("badAddress"))
        self.assertEqual("AI 服务的设置要改一下", t("noJSON"))
        self.assertEqual("qwen/omni 听不了声音。", t("deaf"))
        self.assertIsNone(t("unreachable"))
        self.assertIsNone(t("busy"))
        self.assertIsNone(t(None))


class When(unittest.TestCase):
    def test_blocking_once_a_meeting_only_while_listening_and_put_away(self):
        n = Notices()
        n.start()
        self.assertIsNone(n.tick(0, False, "invalidKey", False))  # not listening
        self.assertIsNone(n.tick(1, True, "invalidKey", True))    # the notes window says it
        self.assertEqual("blocking", n.tick(2, True, "invalidKey", False))
        self.assertIsNone(n.tick(3, True, "invalidKey", False))
        self.assertIsNone(n.tick(4, True, "noCredit", False))     # another one, same meeting
        n.start()
        self.assertEqual("blocking", n.tick(5, True, "noCredit", False))

    def test_busy_and_server_errors_never(self):
        n = Notices()
        n.start()
        for t in range(0, 600, 10):
            self.assertIsNone(n.tick(t, True, "busy" if t % 20 else "serverError", False))

    def test_unreachable_after_two_minutes(self):
        n = Notices()
        n.start()
        self.assertIsNone(n.tick(0, True, "unreachable", False))
        self.assertIsNone(n.tick(119, True, "unreachable", False))
        self.assertEqual("unreachable", n.tick(120, True, "unreachable", False))
        self.assertIsNone(n.tick(400, True, "unreachable", False))

    def test_unreachable_clock_restarts_when_it_comes_back(self):
        n = Notices()
        n.start()
        n.tick(0, True, "unreachable", False)
        n.tick(100, True, None, False)  # back
        self.assertIsNone(n.tick(110, True, "unreachable", False))
        self.assertIsNone(n.tick(200, True, "unreachable", False))
        self.assertEqual("unreachable", n.tick(230, True, "unreachable", False))

    def test_unreachable_counts_while_the_window_shows_it(self):
        # Down for 2 minutes with the window up, then put away: due at once.
        n = Notices()
        n.start()
        n.tick(0, True, "unreachable", True)
        self.assertIsNone(n.tick(150, True, "unreachable", True))
        self.assertEqual("unreachable", n.tick(151, True, "unreachable", False))

    def test_unreachable_only_counts_while_listening(self):
        n = Notices()
        n.start()
        n.tick(0, False, "unreachable", False)
        self.assertIsNone(n.tick(10, True, "unreachable", False))
        self.assertIsNone(n.tick(129, True, "unreachable", False))
        self.assertEqual("unreachable", n.tick(130, True, "unreachable", False))

    def test_a_shorter_wait(self):
        n = Notices(wait=5)
        n.start()
        n.tick(0, True, "unreachable", False)
        self.assertEqual("unreachable", n.tick(5, True, "unreachable", False))


if __name__ == "__main__":
    unittest.main()

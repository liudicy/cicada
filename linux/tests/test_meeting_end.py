"""MeetingEndWatch, the Mac's MeetingEndTests case for case, and reading meeting apps off `pactl`."""
from __future__ import annotations

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from cicada.core.meeting_end import END, OFF, PROMPT, Config, MeetingEndWatch, Pending, Reason, parse_source_outputs  # noqa: E402

T0 = 1_000_000.0
ZOOM = {"zoom": "Zoom"}


def watch(silence=PROMPT, follow_apps=True):
    return MeetingEndWatch(Config(follow_apps=follow_apps, silence=silence), T0)


def at(s):
    return T0 + s


class MeetingEndTests(unittest.TestCase):
    def test_hang_up_ends_after_the_grace(self):
        w = watch()
        self.assertIsNone(w.tick(at(10), ZOOM, True))
        self.assertIsNone(w.tick(at(20), {}, True))
        self.assertEqual(Pending(Reason("app", "Zoom"), at(50)), w.pending)
        self.assertIsNone(w.tick(at(49), {}, True))
        self.assertEqual(Reason("app", "Zoom"), w.tick(at(50), {}, True))

    def test_rejoining_within_the_grace_keeps_going(self):
        w = watch()
        w.tick(at(10), ZOOM, True)
        w.tick(at(20), {}, True)
        self.assertIsNone(w.tick(at(30), ZOOM, True))
        self.assertIsNone(w.pending)

    def test_speech_does_not_cancel_a_hang_up(self):
        w = watch()
        w.tick(at(10), ZOOM, True)
        w.tick(at(20), {}, True)
        w.heard(at(25))
        self.assertEqual(Reason("app", "Zoom"), w.tick(at(50), {}, True))

    def test_keep_going_forgets_the_hang_up(self):
        w = watch()
        w.tick(at(10), ZOOM, True)
        w.tick(at(20), {}, True)
        w.keep_going(at(30))
        self.assertIsNone(w.tick(at(100), {}, True))
        self.assertIsNone(w.pending)

    def test_silence_prompts_then_ends(self):
        w = watch()
        w.heard(at(5))
        self.assertIsNone(w.tick(at(604), {}, True))
        self.assertIsNone(w.pending)
        self.assertIsNone(w.tick(at(605), {}, True))
        self.assertEqual(Pending(Reason("silence"), at(665)), w.pending)
        self.assertEqual(Reason("silence"), w.tick(at(665), {}, True))

    def test_words_cancel_the_silence_prompt(self):
        w = watch()
        w.tick(at(600), {}, True)
        self.assertEqual("silence", w.pending.reason.kind)
        w.heard(at(620))
        self.assertIsNone(w.pending)
        self.assertIsNone(w.tick(at(700), {}, True))

    def test_silence_end_mode_ends_at_once_and_off_never(self):
        self.assertEqual(Reason("silence"), watch(END).tick(at(600), {}, True))
        off = watch(OFF)
        self.assertIsNone(off.tick(at(99_999), {}, True))
        self.assertIsNone(off.pending)

    def test_silence_does_not_count_during_a_call(self):
        w = watch()
        self.assertIsNone(w.tick(at(5_000), ZOOM, True))
        self.assertIsNone(w.pending)
        plain = watch(follow_apps=False)  # without following apps, a call says nothing
        self.assertIsNone(plain.tick(at(600), ZOOM, True))
        self.assertEqual("silence", plain.pending.reason.kind)

    def test_nothing_said_stops_quietly_after_the_silence(self):
        w = watch()
        self.assertIsNone(w.tick(at(599), {}, False))
        self.assertEqual(Reason("nobody"), w.tick(at(600), {}, False))
        self.assertIsNone(w.pending)
        self.assertEqual(Reason("nobody"), watch(END).tick(at(600), {}, False))
        self.assertIsNone(watch(OFF).tick(at(5_000), {}, False))
        self.assertIsNone(watch().tick(at(5_000), ZOOM, False))

    def test_nothing_said_keeps_listening(self):
        w = watch()
        w.tick(at(10), ZOOM, False)
        self.assertIsNone(w.tick(at(500), {}, False))
        self.assertIsNone(w.pending)
        w.heard(at(5_001))  # a call that ended before anyone spoke is forgotten once someone does
        self.assertIsNone(w.tick(at(5_002), {}, True))
        self.assertIsNone(w.pending)


PACTL = """Source Output #109
\tDriver: PipeWire
\tSource: 101
\tProperties:
\t\tnode.name = "input.fakemic"
\t\tstream.capture.sink = "true"
\t\tmedia.class = "Stream/Input/Audio"
Source Output #120
\tDriver: PipeWire
\tSource: 55
\tProperties:
\t\tapplication.name = "ZOOM VoiceEngine"
\t\tapplication.process.id = "4321"
\t\tapplication.process.binary = "zoom"
\t\tmedia.class = "Stream/Input/Audio"
Source Output #121
\tProperties:
\t\tapplication.name = "ZOOM VoiceEngine"
\t\tapplication.process.binary = "zoom"
Source Output #122
\tProperties:
\t\tapplication.name = "Firefox"
\t\tapplication.process.binary = "firefox"
Source Output #123
\tProperties:
\t\tapplication.name = "cicada"
\t\tapplication.process.id = "777"
\t\tapplication.process.binary = "python3"
Source Output #124
\tProperties:
\t\tapplication.name = "wemeetapp"
\t\tapplication.process.binary = "wemeetapp"
"""


class MicStreamTests(unittest.TestCase):
    def test_only_meeting_apps_reading_a_mic_count(self):
        self.assertEqual({"zoom": "Zoom", "wemeetapp": "腾讯会议"}, parse_source_outputs(PACTL, own_pid=777))

    def test_nothing_recording(self):
        self.assertEqual({}, parse_source_outputs(""))


class HeardWordsTests(unittest.TestCase):
    """What counts as someone speaking: recognised words landing (a line, mine too, or a half
    sentence that grew), as the Mac counts recognised text. A retranslation isn't speech."""

    def test_words_fire_on_new_and_grown_lines_only(self):
        import tempfile
        from cicada.core.models import TranscriptLine
        from cicada.core.session_store import SessionStore
        from cicada.core.support import Paths
        Paths.home_override = tempfile.mkdtemp()
        Paths.log_override = os.path.join(Paths.home_override, "debug.log")
        self.addCleanup(lambda: (setattr(Paths, "home_override", None), setattr(Paths, "log_override", None)))
        store = SessionStore()
        sid = store.begin().id
        heard = []
        store.on_words(heard.append)
        store.append(sid, TranscriptLine(id="h1-1", t=0, src="so we will", dst="所以我们会", srcLang="en", dstLang="zh-CN"))
        store.append(sid, TranscriptLine(id="m1", t=1, speaker="me", src="好的", dst="OK", srcLang="zh-CN", dstLang="en"))
        store.replace(sid, TranscriptLine(id="h1-1", t=0, src="so we will", dst="所以我们将", srcLang="en", dstLang="zh-CN"))
        self.assertEqual(2, len(heard), "a retranslation isn't speech")
        store.replace(sid, TranscriptLine(id="h1-1", t=0, src="so we will ship", dst="所以我们会发布", srcLang="en", dstLang="zh-CN"))
        self.assertEqual([sid] * 3, heard)


if __name__ == "__main__":
    unittest.main()

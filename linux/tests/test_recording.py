"""保存会议录音's parts that need no GStreamer: the ADTS file (core/aac.py), the record's hasAudio, and
the listening engine handing the recorder every sample the lines are timed by."""
from __future__ import annotations

import os
import sys
import threading
import time
import unittest
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)

import test_core as tc  # noqa: E402 - its helpers; a module import, so its tests aren't collected twice
from cicada.core import aac  # noqa: E402
from cicada.core.audio import RATE, PcmAudioSource  # noqa: E402
from cicada.core.listen import ListenEngine, RoomMix  # noqa: E402
from array import array  # noqa: E402
from cicada.core.models import TranscriptLine  # noqa: E402
from cicada.core.notes import NotesEngine  # noqa: E402
from cicada.core.session_store import SessionStore  # noqa: E402
from cicada.core.settings import AppSettings  # noqa: E402
from cicada.core.translator import Translator  # noqa: E402


def adts(n: int, rate_index: int = 8, body: int = 20) -> bytes:
    """n ADTS frames (16 kHz by default) with `body` bytes each."""
    length = 7 + body
    head = bytes([0xFF, 0xF1, 0x40 | (rate_index << 2), 0x40 | ((length >> 11) & 0x03),
                  (length >> 3) & 0xFF, ((length & 0x07) << 5) | 0x1F, 0xFC])
    return (head + bytes(body)) * n


class Adts(unittest.TestCase):
    def test_reads_frames_and_their_length(self):
        data = adts(250)
        self.assertEqual(250, len(list(aac.frames(data))))
        self.assertAlmostEqual(250 * 1024 / 16000, aac.seconds(data))

    def test_a_torn_last_frame_goes(self):
        data = adts(10) + adts(1)[:12]  # killed mid-write
        self.assertEqual(adts(10), aac.cut(data, None))

    def test_cuts_at_the_meetings_end(self):
        data = adts(100)  # 6.4 s
        kept = aac.cut(data, 3.0)
        self.assertAlmostEqual(3.008, aac.seconds(kept), places=3)  # whole frames, up to the first one past 3 s
        self.assertEqual(data, aac.cut(data, 60))

    def test_partial_name(self):
        self.assertEqual("/x/20261106-101010/system.aac", aac.partial("/x/20261106-101010/system.m4a"))


class HasAudio(tc.Base):
    def test_a_meeting_with_a_recording_says_so(self):
        store = SessionStore()
        s = store.begin(datetime(2026, 1, 1, 2, tzinfo=timezone.utc))
        store.append(s.id, TranscriptLine(id="h1-1", src="hi", srcLang="en", dstLang="zh-CN"))
        os.makedirs(os.path.dirname(store.audio_path(s.id)), exist_ok=True)
        with open(aac.partial(store.audio_path(s.id)), "wb") as f:
            f.write(adts(5))
        store.end(s.id)
        self.assertTrue(store.get(s.id).hasAudio)
        with open(os.path.join(os.path.dirname(store.audio_path(s.id)), "session.json"), encoding="utf-8") as f:
            self.assertIn('"hasAudio" : true', f.read())
        # The app quit before rewrapping: the next launch finds it.
        self.assertEqual([s.id], SessionStore().unfinished_audio())

    def test_without_one_it_says_none(self):
        store = SessionStore()
        s = store.begin(datetime(2026, 1, 1, 2, tzinfo=timezone.utc))
        store.append(s.id, TranscriptLine(id="h1-1", src="hi", srcLang="en", dstLang="zh-CN"))
        store.end(s.id)
        self.assertFalse(store.get(s.id).hasAudio)
        self.assertEqual([], store.unfinished_audio())


class FakeRecorder:
    def __init__(self):
        self.samples = 0
        self.pcm = array("h")
        self.closed = False
        self.finished = threading.Event()
        self.until = "unset"

    def write(self, buf):
        assert not self.closed
        self.samples += len(buf)
        self.pcm.extend(buf)

    def close(self):
        self.closed = True

    def finish(self, until):
        self.until = until
        self.finished.set()


class Recording(tc.Base):
    def engine(self):
        ling = tc.client(tc.Fake(lambda body: tc.reply("LANG: en\nORIGINAL: Hello.\nTRANSLATION: 你好。")
                                 if "Ming-3.0-audio-flash" in body else tc.reply("{}")))
        tc.LingClient.spacing = 0.05
        store = SessionStore()
        return store, ListenEngine(ling, Translator(ling), store, NotesEngine(ling, store), AppSettings(target="zh-CN"))

    def run_meeting(self, engine, ended_at=None):
        rec = FakeRecorder()
        engine.recorder = lambda sid: rec
        src = PcmAudioSource(lambda: tc.concat(tc.tone(1.0), tc.silence(1.5)), speed=0)
        done = threading.Event()
        src.on_ended = lambda why: done.set()
        engine.start(src, "file")
        self.assertTrue(engine.recording)
        done.wait(10)
        time.sleep(0.5)
        heard = engine.heard_seconds
        engine.stop(ended_at)
        return rec, heard

    def test_every_sample_heard_is_written_then_rewrapped(self):
        store, engine = self.engine()
        rec, heard = self.run_meeting(engine)
        self.assertTrue(rec.closed)
        # The lines' clock is the samples the lane heard: the file holds exactly those.
        self.assertEqual(round(heard * RATE), rec.samples)
        self.assertTrue(rec.finished.wait(5))
        self.assertIsNone(rec.until)
        self.assertFalse(engine.recording)

    def test_a_meeting_that_ended_by_itself_is_cut_there(self):
        store, engine = self.engine()
        rec, _ = self.run_meeting(engine, ended_at=datetime.now(timezone.utc) + timedelta(seconds=-0.5))
        self.assertTrue(rec.finished.wait(5))
        s = store.get(engine.session_id)
        self.assertIsNotNone(s, "a line was heard, so the meeting is kept")
        self.assertAlmostEqual(s.duration, rec.until, places=3)

    def test_no_recorder_no_recording(self):
        _store, engine = self.engine()
        engine.recorder = lambda sid: None
        src = PcmAudioSource(lambda: tc.silence(0.3), speed=0)
        engine.start(src, "file")
        self.assertFalse(engine.recording)
        engine.stop()


def loud(pcm, a, b):
    """The largest sample between a and b seconds."""
    return max((abs(v) for v in pcm[int(a * RATE):int(b * RATE)]), default=0)


class Mix(unittest.TestCase):
    """电脑和会议室: the room mic goes into the meeting's one recording, at its place on the clock (#19)."""

    def test_the_room_is_added_where_it_was_heard(self):
        rec = FakeRecorder()
        mix = RoomMix(rec)
        for i in range(30):  # 3 s of the computer at 1000, in 0.1 s buffers; the room at 500 from 1 s to 2 s
            mix.write(array("h", [1000] * 1600))
            if 10 <= i < 20:
                mix.room(array("h", [500] * 1600), i * 1600)
        mix.close()
        self.assertTrue(rec.closed)
        self.assertEqual(3 * RATE, rec.samples)
        self.assertEqual(1000, loud(rec.pcm, 0, 1))
        self.assertEqual(1500, loud(rec.pcm, 1, 2))
        self.assertEqual(1000, loud(rec.pcm, 2, 3))

    def test_a_room_buffer_a_little_late_is_still_mixed(self):
        rec = FakeRecorder()
        mix = RoomMix(rec)
        for i in range(20):
            mix.write(array("h", [0] * 1600))
            if i >= 5:  # the room's buffer for each 0.1 s arrives half a second after the computer's
                mix.room(array("h", [700] * 1600), (i - 5) * 1600)
        mix.close()
        self.assertEqual(700, min(rec.pcm[:int(1.5 * RATE)]))

    def test_the_room_alone_is_the_recording_and_it_clips_instead_of_wrapping(self):
        rec = FakeRecorder()
        mix = RoomMix(rec)
        mix.write(array("h", [30000] * 1600))
        mix.room(array("h", [30000] * 1600), 0)
        mix.room(array("h", [800] * 1600), 2 * RATE)  # the computer stopped sending: the room goes on
        mix.close()
        self.assertEqual(32767, rec.pcm[0])
        self.assertEqual(2 * RATE + 1600, rec.samples)
        self.assertEqual(0, loud(rec.pcm, 0.2, 2))
        self.assertEqual(800, rec.pcm[-1])

    def test_both_lanes_end_up_in_the_file(self):
        from test_hybrid import both_engine
        store = SessionStore()
        e = both_engine(store, "x")
        rec = FakeRecorder()
        e.recorder = lambda sid: rec
        # In real time, as the sound server sends them: the computer's tone 0-1 s, the room's 0.5-2.1 s.
        main = PcmAudioSource(lambda: tc.concat(tc.tone(1.0), tc.silence(1.0)), speed=1)
        room = PcmAudioSource(lambda: tc.concat(tc.silence(0.5), tc.tone(1.6, amp=0.2), tc.silence(0.4)), speed=1)
        done = [threading.Event(), threading.Event()]
        main.on_ended = lambda why: done[0].set()
        room.on_ended = lambda why: done[1].set()
        e.start(main, "both")
        e.start_room(room, gated=False)
        for d in done:
            d.wait(10)
        time.sleep(0.3)
        e.stop()
        self.assertTrue(rec.closed)
        self.assertTrue(rec.finished.wait(5))
        self.assertGreater(loud(rec.pcm, 1.2, 2.0), 3000, "the room's tone, after the computer's ended")


if __name__ == "__main__":
    unittest.main()

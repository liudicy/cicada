"""听哪里 on Linux: 会议室 (a microphone in the room) and 电脑和会议室 (both at once), the Mac's
HybridTests / HybridRecordTests case for case where the logic is shared."""
from __future__ import annotations

import threading
import time

from test_core import Base, Fake, client, concat, content, reply, silence, tone

from cicada.core.audio import PcmAudioSource
from cicada.core.ling import LingClient
from cicada.core.listen import ROOM_IDS, ListenEngine
from cicada.core.models import TranscriptLine
from cicada.core.notes import NotesEngine
from cicada.core.roommic import (EchoGate, EchoMatch, Heard, Input, VoiceGate, heard_both, parse_sources,
                                 pick, place_starts)
from cicada.core.session_store import SessionStore
from cicada.core.settings import AppSettings
from cicada.core.translator import Translator

PACTL = """Source #47
\tState: SUSPENDED
\tName: alsa_output.pci-0000_00_05.0.analog-stereo.monitor
\tDescription: Monitor of Built-in Audio
\tMonitor of Sink: alsa_output.pci-0000_00_05.0.analog-stereo
\tProperties:
\t\tdevice.api = "alsa"
\t\tdevice.class = "monitor"
\t\tdevice.bus = "pci"
Source #48
\tState: SUSPENDED
\tName: alsa_input.pci-0000_00_05.0.analog-stereo
\tDescription: Built-in Audio Analog Stereo
\tMonitor of Sink: n/a
\tProperties:
\t\tdevice.api = "alsa"
\t\tdevice.class = "sound"
\t\tdevice.bus = "pci"
\t\tdevice.form_factor = "internal"
Source #60
\tName: bluez_input.AA_BB_CC_DD_EE_FF.0
\tDescription: WH-1000XM4
\tMonitor of Sink: n/a
\tProperties:
\t\tdevice.api = "bluez5"
\t\tdevice.bus = "bluetooth"
Source #61
\tName: alsa_input.usb-Jabra_Speak_510-00.mono-fallback
\tDescription: Jabra SPEAK 510 Mono
\tMonitor of Sink: n/a
\tProperties:
\t\tdevice.api = "alsa"
\t\tdevice.bus = "usb"
Source #70
\tName: cicada_mic
\tDescription: 知了 麦克风
\tMonitor of Sink: n/a
\tProperties:
\t\tdevice.class = "filter"
"""


class Microphones(Base):
    def test_reads_the_inputs(self):
        got = {i.name: i for i in parse_sources(PACTL)}
        self.assertEqual(5, len(got))
        self.assertTrue(got["alsa_output.pci-0000_00_05.0.analog-stereo.monitor"].virtual)
        self.assertTrue(got["cicada_mic"].virtual, "知了 麦克风 hears no room")
        built_in = got["alsa_input.pci-0000_00_05.0.analog-stereo"]
        self.assertTrue(built_in.builtin and not built_in.virtual)
        self.assertTrue(got["bluez_input.AA_BB_CC_DD_EE_FF.0"].bluetooth)
        usb = got["alsa_input.usb-Jabra_Speak_510-00.mono-fallback"]
        self.assertFalse(usb.builtin or usb.bluetooth or usb.virtual)
        self.assertEqual("Jabra SPEAK 510 Mono", usb.description)

    def test_picks_like_the_mac(self):
        # RoomMicPlan: the default unless virtual or a Bluetooth headset's, then the built-in one.
        inputs = parse_sources(PACTL)
        usb = "alsa_input.usb-Jabra_Speak_510-00.mono-fallback"
        built_in = "alsa_input.pci-0000_00_05.0.analog-stereo"
        self.assertEqual(usb, pick(usb, inputs))
        self.assertEqual(built_in, pick("bluez_input.AA_BB_CC_DD_EE_FF.0", inputs))
        self.assertEqual(built_in, pick("cicada_mic", inputs))
        self.assertEqual(built_in, pick(None, inputs))
        # Chosen in 设置 › 会议室, while it is plugged in.
        self.assertEqual(usb, pick(built_in, inputs, chosen=usb))
        self.assertEqual(built_in, pick(built_in, inputs, chosen="gone"))
        # Only a headset: better than nothing.
        bt = [Input("bt", bluetooth=True), Input("cicada_mic", virtual=True)]
        self.assertEqual("bt", pick("cicada_mic", bt))
        self.assertIsNone(pick(None, [Input("m", virtual=True)]))

    def test_voice_gate_learns_the_room(self):
        fixed = VoiceGate()
        self.assertFalse(fixed.voiced(0.006))
        g = VoiceGate(adaptive=True)
        self.assertEqual(0.004, g.threshold)
        # Ten seconds of a quiet room (0.001) with talk at 0.006.
        for i in range(100):
            g.voiced(0.001 if i % 10 == 0 else 0.006, 0.1)
        self.assertLess(g.threshold, 0.003)
        self.assertGreaterEqual(g.threshold, VoiceGate.lowest)
        self.assertTrue(g.voiced(0.006))
        # A loud room: the line never goes over the fixed gate.
        for _ in range(400):
            g.voiced(0.05, 0.1)
        self.assertEqual(VoiceGate.fixed, g.threshold)


def engine(store):
    LingClient.spacing = 0.02
    ling = client(Fake(lambda b: reply("LANG: en\nORIGINAL: Hello from the table.\nTRANSLATION: 桌边的人好。")
                       if "Ming-3.0-audio-flash" in b else reply("{}")))
    return ListenEngine(ling, Translator(ling), store, NotesEngine(ling, store), AppSettings(target="zh-CN"))


def run(e, pcm, mic):
    src = PcmAudioSource(lambda: pcm, speed=0)
    ended = threading.Event()
    src.on_ended = lambda why: ended.set()
    e.start(src, "room" if mic else "system", mic=mic)
    ended.wait(10)
    time.sleep(0.3)
    e.stop()


class Room(Base):
    QUIET = concat(silence(3.5), tone(1.0, amp=0.01), silence(1.0))  # a voice across the table, under -40 dBFS

    def test_a_quiet_voice_in_the_room_is_heard(self):
        store = SessionStore()
        e = engine(store)
        run(e, self.QUIET, mic=True)
        s = store.get(e.session_id)
        self.assertEqual(["Hello from the table."], [l.src for l in s.lines])
        self.assertTrue(s.room, "the record says 会议室")
        self.assertEqual("room", s.lines[0].via)
        self.assertFalse(heard_both(s.lines), "会议室 alone: no place on each line, as on the Mac")

    def test_the_computers_audio_keeps_the_fixed_gate(self):
        store = SessionStore()
        e = engine(store)
        run(e, self.QUIET, mic=False)
        self.assertIsNone(store.get(e.session_id), "nothing heard, nothing kept")

    def test_changing_source_mid_meeting_goes_on_in_the_same_meeting(self):
        store = SessionStore()
        e = engine(store)
        first = PcmAudioSource(lambda: silence(0.5), speed=0)
        e.start(first, "system")
        sid = e.session_id
        time.sleep(0.2)
        mic = PcmAudioSource(lambda: self.QUIET, speed=0)
        ended = threading.Event()
        mic.on_ended = lambda why: ended.set()
        e.attach(mic, mic=True)
        ended.wait(10)
        time.sleep(0.3)
        e.stop()
        s = store.get(sid)
        self.assertEqual(1, len(s.lines))
        self.assertTrue(s.room)

    def test_muted_while_i_speak_through_the_same_mic(self):
        store = SessionStore()
        e = engine(store)
        src = PcmAudioSource(lambda: self.QUIET, speed=0)
        ended = threading.Event()
        src.on_ended = lambda why: ended.set()
        # Muted before any audio arrives: the worker replaces it with silence.
        e.start(PcmAudioSource(lambda: silence(0.1), speed=0), "room", mic=True)
        e.set_muted(True)
        e.attach(src, mic=True)
        e.set_muted(True)
        ended.wait(10)
        time.sleep(0.3)
        e.stop()
        self.assertEqual(0, len(store.get(e.session_id).lines) if store.get(e.session_id) else 0)


def h(text, start, end):
    return Heard(text, start, end)


class EchoMatchTests(Base):
    """The Mac's EchoMatchTests, case for case."""

    def test_the_rooms_copy_of_a_remote_sentence_is_an_echo(self):
        online = [h("Revenue grew by 12%, mostly from the new region.", 10, 14)]
        # Heard worse from the speakers, and a word lost.
        self.assertTrue(EchoMatch.is_echo(h("revenue grew by 12% mostly from new region", 10.3, 14.2), online))

    def test_cut_differently_still_matches(self):
        online = [h("我们先看一下这个季度的数据。", 0, 2), h("收入增长了百分之十二，主要来自新的市场。", 2.2, 5)]
        self.assertTrue(EchoMatch.is_echo(h("这个季度的数据收入增长了百分之十二", 0.8, 4), online))

    def test_room_speech_is_kept(self):
        online = [h("Revenue grew by 12%, mostly from the new region.", 10, 14)]
        self.assertFalse(EchoMatch.is_echo(h("I think we should check the numbers for Europe first", 11, 15), online))
        self.assertFalse(EchoMatch.is_echo(h("我觉得应该先看一下欧洲的情况", 11, 15), online))

    def test_the_same_words_long_after_are_not_an_echo(self):
        online = [h("Can everyone hear me okay?", 0, 2)]
        self.assertFalse(EchoMatch.is_echo(h("can everyone hear me okay", 20, 22), online))

    def test_short_lines_match_only_exactly(self):
        online = [h("OK.", 5, 5.5)]
        self.assertTrue(EchoMatch.is_echo(h("ok", 5.2, 5.6), online))
        self.assertFalse(EchoMatch.is_echo(h("no", 5.2, 5.6), online))

    def test_gate_closes_for_the_hang(self):
        g = EchoGate()
        self.assertFalse(g.closed(100))
        g.hold(100)
        self.assertTrue(g.closed(100.3))
        self.assertFalse(g.closed(100 + EchoGate.hang + 0.01))


def line(i, speaker="them", via=None):
    return TranscriptLine(id=i, speaker=speaker, src="x", srcLang="en", dstLang="zh-CN", via=via)


class Places(Base):
    """The Mac's HybridRecordTests."""

    def test_only_a_meeting_that_heard_both_shows_places(self):
        self.assertFalse(heard_both([line("a"), line("b")]))
        self.assertFalse(heard_both([line("a", via="room"), line("b", via="room")]))
        # My own lines (同声传译) don't make it a meeting that heard the computer.
        self.assertFalse(heard_both([line("a", via="room"), line("b", "me")]))
        self.assertTrue(heard_both([line("a", via="room"), line("b")]))

    def test_a_change_of_place_starts_a_new_run(self):
        ls = [line("a"), line("b"), line("c", via="room"), line("d", "me"), line("e", via="room"), line("f")]
        self.assertEqual({"a", "c", "e", "f"}, place_starts(ls))

    def test_music_stops_closing_the_gate(self):
        g = EchoGate()
        t = 0.0
        while t < EchoGate.music - 1:
            g.hold(t)
            t += 0.1
        self.assertTrue(g.closed(t))  # no words yet: still taken for speech
        while t < EchoGate.music + 1:
            g.hold(t)
            t += 0.1
        self.assertTrue(g.playing_music(t))
        t += EchoGate.hang + 0.01
        g.hold(t)
        self.assertFalse(g.closed(t + 0.01))
        g.heard_words(t + 0.1)  # someone talks over it: words close it again
        g.hold(t + 0.2)
        self.assertTrue(g.closed(t + 0.3))

    def _play(self, g, start, level):
        t = start
        for _ in range(60):
            g.hold(t)
            g.room_level(level, 0.1, t + 0.05)
            t += 0.1
        for _ in range(60):
            t += 0.1
            g.room_level(0.001, 0.1, t)
        return t

    def test_headphones_keep_the_room_open(self):
        g = EchoGate()
        self.assertTrue(g.echo)  # until measured
        t = self._play(g, 0, 0.001)
        self.assertFalse(g.echo)
        g.hold(t + 1)
        self.assertFalse(g.closed(t + 1.1))
        self._play(g, t + 100, 0.03)  # the speakers reach the mic again
        self.assertTrue(g.echo)
        self.assertIsNone(EchoGate.ratio([(0.001, 1)], [(0.001, 10)]))


ONLINE = "Revenue grew by 12%, mostly from the new region."


def both_engine(store, room_text):
    """The computer plays a 1 s sentence; the room mic hears 1.6 s at the same time."""
    def respond(body):
        if "Ming-3.0-audio-flash" not in body:
            return reply("{}")
        short = len(content(body, 1)[0]["audio_url"]["url"]) < 60000
        return reply("LANG: en\nORIGINAL: %s\nTRANSLATION: 译文。" % (ONLINE if short else room_text))
    LingClient.spacing = 0.02
    ling = client(Fake(respond))
    return ListenEngine(ling, Translator(ling), store, NotesEngine(ling, store), AppSettings(target="zh-CN"))


def run_both(e, gated=False):
    main = PcmAudioSource(lambda: concat(tone(1.0), silence(1.0)), speed=0)
    room = PcmAudioSource(lambda: concat(silence(0.5), tone(1.6, amp=0.2), silence(1.0)), speed=0)
    done = [threading.Event(), threading.Event()]
    main.on_ended = lambda why: done[0].set()
    room.on_ended = lambda why: done[1].set()
    e.start(main, "both")
    e.start_room(room, gated=gated)
    for d in done:
        d.wait(10)
    time.sleep(0.6)
    e.stop()


class Both(Base):
    def test_the_rooms_own_words_are_kept_and_say_room(self):
        store = SessionStore()
        e = both_engine(store, "I think we should check the numbers for Europe first.")
        run_both(e)
        s = store.get(e.session_id)
        got = sorted((l.via or "", l.src) for l in s.lines)
        self.assertEqual([("", ONLINE), ("room", "I think we should check the numbers for Europe first.")], got)
        room = next(l for l in s.lines if l.via == "room")
        self.assertTrue(room.id.endswith("-%d" % (ROOM_IDS + 1)), room.id)
        self.assertTrue(s.room)
        self.assertTrue(heard_both(s.lines))

    def test_the_rooms_copy_of_an_online_sentence_is_dropped(self):
        store = SessionStore()
        e = both_engine(store, "revenue grew by 12% mostly from new region")
        run_both(e)
        s = store.get(e.session_id)
        self.assertEqual([(None, ONLINE)], [(l.via, l.src) for l in s.lines])

    def test_a_room_side_started_mid_meeting_keeps_the_meetings_clock(self):
        # 听哪里 changed to 电脑和会议室 two seconds in: the room's line is timed after them, not at 00:00.
        store = SessionStore()
        e = both_engine(store, "I think we should check the numbers for Europe first.")
        main = PcmAudioSource(lambda: concat(tone(1.0), silence(1.0)), speed=0)
        room = PcmAudioSource(lambda: concat(silence(0.5), tone(1.6, amp=0.2), silence(1.0)), speed=0)
        done = [threading.Event(), threading.Event()]
        main.on_ended = lambda why: done[0].set()
        room.on_ended = lambda why: done[1].set()
        e.start(main, "both")
        done[0].wait(10)
        time.sleep(0.3)
        e.start_room(room, gated=False)
        done[1].wait(10)
        time.sleep(0.6)
        e.stop()
        line = next(l for l in store.get(e.session_id).lines if l.via == "room")
        self.assertGreaterEqual(line.t, 2.0)

    def test_stopping_the_room_side_keeps_the_meeting(self):
        store = SessionStore()
        e = both_engine(store, "x")
        e.start(PcmAudioSource(lambda: silence(0.2), speed=0), "both")
        e.start_room(PcmAudioSource(lambda: silence(0.2), speed=0), gated=True)
        self.assertTrue(e.hears_room_too and e.gated)
        sid = e.session_id
        e.stop_room()
        self.assertFalse(e.hears_room_too or e.gated)
        self.assertTrue(e.listening)
        self.assertEqual(sid, e.session_id)
        e.stop()

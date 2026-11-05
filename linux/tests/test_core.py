"""Unit tests for the engines (no network: LingClient runs against a fake transport). The Windows and
Android suites' cases, plus byte-for-byte checks of the Mac's JSON format.
    python3 -m unittest discover -s linux/tests      (scripts/test.sh)"""
from __future__ import annotations

import math
import os
import shutil
import stat
import sys
import tempfile
import threading
import time
import unittest
from array import array
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
REPO = os.path.dirname(os.path.dirname(HERE))

from cicada.core import jsonfmt, strings, support  # noqa: E402
from cicada.core.audio import PcmAudioSource, Wav  # noqa: E402
from cicada.core.ling import AUDIO_MODEL, INVALID, NOTES, TRANSLATE, AIKey, LingClient, LingError, Response  # noqa: E402
from cicada.core.listen import ListenEngine, continues, join  # noqa: E402
from cicada.core.models import Fishbone, FishboneBranch, MeetingNotes, NoteItem, NoteTerm, NoteTopic, Session, TranscriptLine  # noqa: E402
from cicada.core import notes as notesmod  # noqa: E402
from cicada.core.notes import NotesEngine  # noqa: E402
from cicada.core.segmenter import Segmenter  # noqa: E402
from cicada.core import session_store  # noqa: E402
from cicada.core.session_store import SessionStore  # noqa: E402
from cicada.core.settings import AppSettings  # noqa: E402
from cicada.core.support import Paths  # noqa: E402
from cicada.core.translator import Heard, Translator, clean_translation, hear_tokens, is_noise, parse_heard, parse_interpretation  # noqa: E402
from cicada.core.ling import StreamResponse  # noqa: E402
from cicada.core.speak import SpeakEngine  # noqa: E402
from cicada.core import speakers  # noqa: E402
from cicada.core.models import VoiceGuess  # noqa: E402

MAC = """{
  "endedAt" : "2026-11-02T15:24:12Z",
  "hasAudio" : true,
  "id" : "20261102-101639",
  "lines" : [
    {
      "dst" : "Hello \\/ \\"hi\\"",
      "dstLang" : "en",
      "id" : "h1-1",
      "speaker" : "them",
      "src" : "你好",
      "srcLang" : "zh-CN",
      "t" : 2.5,
      "voice" : 1
    }
  ],
  "notes" : {
    "conclusions" : [

    ],
    "covered" : 1,
    "final" : true,
    "summary" : "总结",
    "terms" : [
      {
        "heard" : [

        ],
        "name" : "鸟哥",
        "note" : "分享者"
      }
    ],
    "title" : "标题",
    "todos" : [
      {
        "owner" : "你",
        "support" : 3,
        "t" : 202.4,
        "text" : "记录"
      }
    ],
    "topics" : [
      {
        "pointTimes" : [
          12.4,
          null
        ],
        "points" : [
          "a",
          "b"
        ],
        "start" : 0,
        "summary" : "s",
        "title" : "t"
      }
    ],
    "updatedAt" : "2026-11-02T15:24:40Z"
  },
  "startedAt" : "2026-11-02T15:16:39Z",
  "title" : "会议 11月2日 10:16",
  "voiceNames" : {
    "1" : "Emma"
  }
}"""


def tone(seconds, amp=0.3):
    return array("h", (int(math.sin(2 * math.pi * 300 * i / 16000) * amp * 32767) for i in range(int(seconds * 16000))))


def silence(seconds):
    return array("h", bytes(int(seconds * 16000) * 2))


def concat(*parts):
    out = array("h")
    for p in parts:
        out.extend(p)
    return out


def cut(*parts):
    got = []
    seg = Segmenter()
    seg.on_segment = got.append
    for p in parts:
        for i in range(0, len(p), 1600):
            seg.feed(p[i:i + 1600])
    seg.flush()
    return got


class Fake:
    def __init__(self, respond, speech=None):
        self.respond = respond
        self.speech = speech  # body -> list of SSE lines
        self.calls = []
        self.spoken = []
        self.lock = threading.Lock()

    def stream(self, url, body, headers, timeout):
        with self.lock:
            self.spoken.append(body)
        return StreamResponse(200, iter(self.speech(body) if self.speech else []))

    def send(self, url, method, body, headers, timeout):
        with self.lock:
            self.calls.append((time.monotonic(), body or ""))
        return self.respond(body or "")


def reply(content, finish="stop"):
    return Response(200, jsonfmt.write({"choices": [{"message": {"content": content}, "finish_reason": finish}],
                                        "usage": {"prompt_tokens": 1, "completion_tokens": 1}}, pretty=False))


def client(fake):
    key = AIKey()
    key.save("sk-test-0000000000")
    return LingClient(key, fake)


def content(body, i):
    return jsonfmt.parse(body)["messages"][i]["content"]


class Base(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="cicada-tests-")
        Paths.home_override = self.home
        Paths.log_override = os.path.join(self.home, "debug.log")
        self.spacing = LingClient.spacing

    def tearDown(self):
        LingClient.spacing = self.spacing
        Paths.home_override = None
        Paths.log_override = None
        shutil.rmtree(self.home, ignore_errors=True)


class Records(Base):
    def test_session_json_matches_the_mac(self):
        s = Session(id="20261103-101611", title="会议 11月3日 10:16", startedAt=datetime(2026, 11, 3, 15, 16, 11, tzinfo=timezone.utc),
                    lines=[TranscriptLine(id="h1-1", t=2.7636849899291995, src="你好/世界", srcLang="zh-CN", dstLang="en")])
        j = s.write()
        self.assertIn('"startedAt" : "2026-11-03T15:16:11Z"', j)
        self.assertIn("你好\\/世界", j)
        self.assertNotIn('"dst"', j)
        self.assertNotIn("endedAt", j)
        self.assertNotIn("notes", j)
        self.assertIn("2.7636849899291995", j)
        self.assertTrue(j.startswith('{\n  "hasAudio" : false,\n  "id" : '))

    def test_reads_a_mac_record_and_writes_it_back_byte_for_byte(self):
        s = Session.read(MAC)
        self.assertEqual(1, len(s.lines))
        self.assertEqual(1, s.lines[0].voice)
        self.assertEqual('Hello / "hi"', s.lines[0].dst)
        self.assertEqual("Emma", s.voiceNames["1"])
        self.assertEqual(12.4, s.notes.topics[0].point_time(0))
        self.assertIsNone(s.notes.topics[0].point_time(1))
        self.assertEqual(MAC, s.write())

    def test_json_edge_cases(self):
        self.assertEqual("3", jsonfmt.number(3.0))
        self.assertEqual("0.0001", jsonfmt.number(0.0001))
        self.assertEqual("0.00001", jsonfmt.number(0.00001))
        self.assertEqual("-1.5", jsonfmt.number(-1.5))
        parsed = jsonfmt.parse('{"a":[1,2.5,"x中\\n",true,null,{}],"b":-3e2}')
        self.assertEqual('{"a":[1,2.5,"x中\\n",true,null,{}],"b":-300}', jsonfmt.write(parsed, pretty=False))
        self.assertIsNone(jsonfmt.parse_object("not json"))
        self.assertEqual('"a\\u0001"', jsonfmt.write("a\x01"))

    def test_store_saves_and_drops_empty_meetings(self):
        store = SessionStore()
        empty = store.begin(datetime(2026, 1, 1, 1, tzinfo=timezone.utc))
        store.end(empty.id)
        self.assertIsNone(store.get(empty.id))
        self.assertFalse(os.path.exists(os.path.join(Paths.sessions(), empty.id)))
        s = store.begin(datetime(2026, 1, 1, 2, tzinfo=timezone.utc))
        store.append(s.id, TranscriptLine(id="h1-1", src="hi", srcLang="en", dstLang="zh-CN"))
        store.end(s.id)
        path = os.path.join(Paths.sessions(), s.id, "session.json")
        self.assertTrue(os.path.isfile(path))
        with open(path, encoding="utf-8") as f:
            self.assertEqual(1, len(Session.read(f.read()).lines))
        self.assertIsNotNone(SessionStore().get(s.id))
        self.assertTrue(s.title.startswith("会议 "))
        md = session_store.markdown(store.get(s.id))
        self.assertIn("**[00:00] 对方**  \nhi\n", md)
        self.assertNotIn("## 文字记录", md, "only under notes, as on the Mac")
        store.rename(s.id, "我的会")
        self.assertTrue(session_store.markdown(store.get(s.id)).startswith("# 我的会\n"))

    def test_keeps_room_and_keys_it_does_not_know(self):
        # A Mac record heard in the room (会议室), plus a key from a newer Mac: written back unchanged.
        o = jsonfmt.parse(MAC)
        o["room"] = True
        o["zFuture"] = {"a": [1, "x"]}
        text = jsonfmt.write(o)
        s = Session.read(text)
        self.assertTrue(s.room)
        self.assertEqual(text, s.write())

    def test_rename_as_on_the_mac(self):
        strings.load("zh-Hans", [os.path.join(REPO, "Resources")])
        store = SessionStore()
        s = store.begin(datetime(2026, 1, 1, 2, tzinfo=timezone.utc))
        store.set_notes(s.id, MeetingNotes(title="路线评审", summary="x"))
        shown = session_store.display_title(store.get(s.id))
        # Saving the title as shown is no rename: the notes may still name the meeting later.
        store.rename(s.id, "  " + shown + " ")
        self.assertIsNone(store.get(s.id).renamed)
        store.rename(s.id, "我的会")
        self.assertEqual(("我的会", True), (store.get(s.id).title, store.get(s.id).renamed))
        # 恢复自动标题: back to the stored default and the notes' name.
        store.rename(s.id, "")
        self.assertEqual((session_store.default_title(s.startedAt), False), (store.get(s.id).title, store.get(s.id).renamed))
        self.assertEqual(shown, session_store.display_title(store.get(s.id)))

    def test_the_live_meeting_cannot_be_deleted(self):
        store = SessionStore()
        s = store.begin(datetime(2026, 1, 1, 2, tzinfo=timezone.utc))
        store.append(s.id, TranscriptLine(id="h1-1", src="hi", srcLang="en", dstLang="zh-CN"))
        store.delete(s.id)
        self.assertIsNotNone(store.get(s.id))
        store.end(s.id)
        self.assertIsNone(store.live)
        store.delete(s.id)
        self.assertIsNone(store.get(s.id))

    def test_display_title(self):
        strings.load("zh-Hans", [os.path.join(REPO, "Resources")])
        s = Session(title="会议 1月1日 10:00", startedAt=datetime.now(timezone.utc), notes=MeetingNotes(title="路线评审", summary="x"))
        self.assertTrue(session_store.display_title(s).endswith(" 路线评审"))
        s.renamed = True
        s.title = "我的会"
        self.assertEqual("我的会", session_store.display_title(s))


class Hearing(Base):
    def test_parses_ming_replies(self):
        h = parse_heard("LANG: en\nORIGINAL: Hello there.\nTRANSLATION: 你好。", "zh-CN", None)
        self.assertEqual(("en", "Hello there.", "你好。"), (h.lang, h.original, h.translation))
        self.assertIsNone(parse_heard("作为一个人工智能语言模型，这个问题超出我目前的学习范围了", "zh-CN", None))
        self.assertIsNone(parse_heard("LANG: en\nORIGINAL: NONE\nTRANSLATION: 无", "zh-CN", None))
        self.assertIsNone(parse_heard("LANG: en\nORIGINAL: ...\nTRANSLATION: …", "zh-CN", None))
        same = parse_heard("LANG: zh\nORIGINAL: 好的\nTRANSLATION: OK", "zh-CN", "en")
        self.assertEqual(("zh-CN", "好的"), (same.lang, same.translation))
        self.assertIsNone(parse_heard("LANG: en\nORIGINAL: Hi\nTRANSLATION: Hi again", "zh-CN", None).translation)
        self.assertEqual("ja", parse_heard("lang: ja-JP\noriginal: はい\ntranslation: 是", "zh-CN", None).lang)

    def test_drops_noise(self):
        # Same cases as the Android and Windows ports' noise tests.
        for o in ("嗯。", "Mm.", "uh, um", "呃呃呃呃呃", "嗯，嗯，嗯，嗯，嗯，嗯，嗯，嗯，嗯，嗯，嗯，嗯。", "滴答" * 50,
                  "hmmmm", "うーん", "음…", "喂？", "No no no no no no",
                         "（无语音内容）", "[Music]", "♪♪", "这段音频是一段旋律，没有说话声。", "There is no speech in this audio."):
            self.assertTrue(is_noise(o), o)
        for o in ("嗯，好的。", "OK.", "Oh no, it crashed.", "对", "对对对", "谢谢谢谢", "喂喂，能听到吗？", "No, no, no.",
                  "えーと、来週の件ですが", "あの人です", "Okay, let's move on to the quarterly numbers.", "（笑）好的"):
            self.assertFalse(is_noise(o), o)
        spoken = "我们今天讨论一下这个季度的数字和下个季度的计划安排"
        self.assertTrue(is_noise(spoken, 1.0))
        self.assertFalse(is_noise(spoken, 4.0))
        self.assertIsNone(parse_heard("LANG: zh-CN\nORIGINAL: 嗯，嗯，嗯，嗯，嗯，嗯。\nTRANSLATION: 嗯，嗯，嗯，嗯，嗯，嗯。", "zh-CN", None))
        self.assertEqual((800, 380, 800), (hear_tokens(0), hear_tokens(8.0), hear_tokens(30.0)))

    def test_follow_system_as_on_the_mac(self):
        # FollowSystemTests, with Linux locale names.
        for prefs, mine in ((["zh_CN.UTF-8"], "zh-CN"), (["en_US.UTF-8"], "en"), (["en_CA", "zh_CN"], "zh-CN"),
                            (["ja_JP", "zh_TW"], "zh-TW"), (["ja_JP", "en_US"], "ja"), ([], "zh-CN")):
            self.assertEqual(mine, support.my_language(prefs), prefs)
        for prefs in (["en_CA", "zh_CN"], ["zh_CN", "en_US"], ["ja_JP", "en_US"], ["en_US"]):
            mine = support.my_language(prefs)
            for source in ("en", "ja", "ko", "zh-CN", None):
                if source != mine:
                    self.assertEqual(mine, support.follow_system_target(source, prefs))
        self.assertEqual("en", support.follow_system_target("zh-CN", ["en_CA", "zh_CN"]))
        self.assertEqual("en", support.follow_system_target("ja", ["ja_JP", "en_US"]))
        self.assertEqual("en", support.follow_system_target("zh-CN", ["zh_CN"]))
        self.assertEqual("zh-CN", support.follow_system_target("en", ["en_US"]))
        old = {k: os.environ.get(k) for k in ("LANGUAGE", "LC_ALL", "LC_MESSAGES", "LANG")}
        try:
            for k in old:
                os.environ.pop(k, None)
            os.environ["LANGUAGE"], os.environ["LANG"] = "en_US:zh_CN", "en_US.UTF-8"
            self.assertEqual(["en_US", "zh_CN", "en_US.UTF-8"], support.system_languages())
            s = AppSettings()
            self.assertEqual("zh-CN", s.target_code)
            self.assertEqual("en", s.resolved_target("zh-CN"))
            self.assertEqual("zh-CN", s.resolved_target("ja"))
            self.assertEqual("ja", AppSettings(target="ja").resolved_target("ja"))
        finally:
            for k, v in old.items():
                os.environ.pop(k, None)
                if v is not None:
                    os.environ[k] = v

    def test_normalizes_languages(self):
        self.assertEqual("zh-CN", support.normalize("zh-Hans", "en"))
        self.assertEqual("zh-TW", support.normalize("zh-TW", "en"))
        self.assertEqual("zh-CN", support.normalize("cmn", "en"))
        self.assertEqual("en", support.normalize("en-US", "ja"))
        self.assertEqual("ja", support.normalize("", "ja"))
        self.assertEqual("zh-TW", support.from_system("zh-Hant-HK"))
        self.assertEqual("zh-CN", support.from_system("zh_CN.UTF-8"))
        self.assertEqual("zh-TW", support.from_system("zh_TW.UTF-8"))
        self.assertEqual("en", support.from_system("en_GB.UTF-8"))
        self.assertEqual("Simplified Chinese", support.english_name("zh-CN"))
        self.assertEqual("Japanese", support.english_name("ja"))
        self.assertEqual("01:05", support.clock(65.9))
        self.assertEqual("1:00:01", support.clock(3601.0))

    def test_cleans_translations(self):
        self.assertEqual("你好", clean_translation("Translation: 你好", "zh-CN"))
        self.assertEqual("你好", clean_translation("“你好”", "zh-CN"))
        self.assertEqual("Hello", clean_translation("Here is the translation:\nHello", "en"))
        self.assertIsNone(clean_translation("请提供需要翻译的字幕内容", "en"))
        self.assertIsNone(clean_translation("Hello", "zh-CN"))
        self.assertEqual("Done.", clean_translation("<think>x</think>Done.", "en"))

    def test_joins_cut_sentences(self):
        last = TranscriptLine(src="We finished the migration and", srcLang="en")
        self.assertTrue(continues(last, 0.2, Heard("en", "the error rate dropped.", None)))
        self.assertFalse(continues(last, 1.5, Heard("en", "next", None)))
        self.assertFalse(continues(TranscriptLine(src="Done.", srcLang="en"), 0.1, Heard("en", "Next", None)))
        self.assertFalse(continues(last, 0.1, Heard("ja", "はい", None)))
        self.assertEqual("我们完成了迁移", join("我们完成了", "迁移", "zh-CN"))
        self.assertEqual("a b", join("a ", " b", "en"))


class FirstRun(Base):
    def test_setup_facts_are_kept(self):
        s = AppSettings()
        self.assertEqual((False, False, False), (s.heardSystemAudio, s.sampleSeen, s.trayHintShown))
        s.heardSystemAudio = s.sampleSeen = True
        s.save()
        back = AppSettings.load()
        self.assertEqual((True, True, False), (back.heardSystemAudio, back.sampleSeen, back.trayHintShown))

    def test_default_output_is_named_by_its_description(self):
        from cicada.core.audio import sink_description
        sinks = ("Sink #48\n\tState: SUSPENDED\n\tName: alsa_output.hdmi-stereo\n\tDescription: HDMI / DisplayPort\n"
                 "\tDriver: PipeWire\n\nSink #51\n\tState: RUNNING\n\tName: alsa_output.pci-0000_00_1f.3.analog-stereo\n"
                 "\tDescription: 内置音频 模拟立体声\n\tMonitor Source: alsa_output.pci-0000_00_1f.3.analog-stereo.monitor\n")
        self.assertEqual("内置音频 模拟立体声", sink_description(sinks, "alsa_output.pci-0000_00_1f.3.analog-stereo"))
        self.assertEqual("HDMI / DisplayPort", sink_description(sinks, "alsa_output.hdmi-stereo"))
        self.assertIsNone(sink_description(sinks, "missing"))
        self.assertIsNone(sink_description(sinks, ""))
        self.assertIsNone(sink_description("", "alsa_output.hdmi-stereo"))


class Segmenting(Base):
    def test_segments_on_pauses(self):
        got = cut(silence(0.5), tone(2.0), silence(1.0), tone(1.5), silence(1.0))
        self.assertEqual(2, len(got))
        self.assertAlmostEqual(0.35, got[0].start, delta=0.05)
        self.assertAlmostEqual(3.35, got[1].start, delta=0.05)
        self.assertTrue(2.1 <= got[0].seconds <= 2.4, got[0].seconds)

    def test_cuts_long_speech_at_its_quietest_moment(self):
        got = cut(tone(7.0), tone(0.3, 0.004), tone(4.0), silence(1.0))
        self.assertEqual(2, len(got))
        self.assertTrue(6.9 <= got[0].seconds <= 7.4, got[0].seconds)
        self.assertTrue(all(s.seconds <= 8.0 for s in got))
        self.assertAlmostEqual(got[1].start, got[0].start + got[0].seconds, delta=0.001)

    def test_ignores_clicks(self):
        self.assertEqual(0, len(cut(silence(1.0), tone(0.1), silence(1.0))))
        self.assertEqual(0, len(cut(tone(3.0, 0.002))))

    def test_wav_round_trip(self):
        pcm = tone(0.5)
        self.assertEqual(pcm, Wav.read(Wav.bytes(pcm)))
        self.assertEqual(16000, len(Wav.resample(array("d", bytes(48000 * 8)), 48000)))
        stereo = Wav.bytes(array("h", [100, 300] * 8000), rate=16000).replace(b"\x01\x00\x01\x00\x80>", b"\x01\x00\x02\x00\x80>", 1)
        self.assertEqual(array("h", [200] * 8000), Wav.read(stereo))


class Notes(Base):
    def test_notes_language_as_on_the_mac(self):
        # "mine" or "source"; one meeting's choice over the setting; a change while live rewrites.
        store = SessionStore()
        settings = AppSettings(target="zh-CN", notesLanguage="source")
        ling = client(Fake(lambda body: reply("{}")))
        notes = NotesEngine(ling, store)
        engine = ListenEngine(ling, Translator(ling), store, notes, settings)
        s = store.begin()
        for i, lang in enumerate(("en", "en", "ja")):
            store.append(s.id, TranscriptLine(id="h%d-%d" % (i + 1, i + 1), t=i, src="x", srcLang=lang, dstLang="zh-CN"))
        store.append(s.id, TranscriptLine(id="m1", t=4, speaker="me", src="y", srcLang="ja", dstLang="en"))
        self.assertEqual("en", engine.meeting_language(s.id), "the other side's most spoken, not mine")
        self.assertEqual("English", notes.language(s.id))
        engine.notes_for[s.id] = "mine"
        self.assertEqual("Simplified Chinese", notes.language(s.id))
        self.assertEqual("zh-CN", AppSettings(target="zh-CN").notes_code("source", None), "nothing heard yet: mine")
        rewrites = []
        notes.rewrite = lambda: rewrites.append(1)
        engine.listening, engine.session_id = True, s.id
        engine.set_notes_language("source", meeting_only=True)
        self.assertEqual((1, "source"), (len(rewrites), settings.notesLanguage))
        engine.set_notes_language("source", meeting_only=True)
        self.assertEqual(1, len(rewrites), "the same language again: nothing to rewrite")
        engine.listening = False

    def test_old_notes_language_settings_become_mine(self):
        with open(Paths.settings(), "w", encoding="utf-8") as f:
            f.write('{"notesLanguage" : "ja"}')
        self.assertEqual("mine", AppSettings.load().notesLanguage)

    def test_todo_owner_names_people_when_voices_are_told_apart(self):
        lines = [TranscriptLine(id="h%d-%d" % (i, i), t=i * 3, src="we should ship this on Friday", voice=i % 2) for i in range(12)]
        owner = lambda voices: [x for x in notesmod.prompt(MeetingNotes(), lines, 0, "English", False, voices=voices).split("\n")
                                if '"todos"' in x][0]  # noqa: E731
        self.assertIn('"owner": "对方" or "你" or null,', owner(False))
        self.assertIn('"owner": the person\'s label from the transcript (a name like "George", or "说话人2"), "你", or null when unclear,', owner(True))

    def test_parses_notes(self):
        raw = """```json
        {"title": "“发布评审”", "summary": "讨论发布。",
         "topics": [{"start": 0, "title": "进展", "summary": "一句", "points": [{"text": "迁移完成", "evidence": ["L2"]}, "旧格式要点", {"text": "", "evidence": []}],
                     "fishbone": {"question": "为何延期", "branches": [{"label": "测试", "detail": "x", "t": 3, "evidence": ["L1"]}, {"label": "设计", "detail": "y", "evidence": ["L9"]}]}}],
         "conclusions": [{"text": "周五上线", "evidence": ["L1", "L2", "L99"]}],
         "todos": [{"text": "发说明", "owner": "", "evidence": ["L2"]}],
         "terms": [{"name": "Stripe", "note": "支付", "heard": ["Stripe", "Strip"]}]}
        ```"""
        n = notesmod.parse(raw, [1.0, 5.0], 0.0)
        self.assertEqual("发布评审", n.title)
        self.assertEqual(2, len(n.topics[0].points))
        self.assertEqual(5.0, n.topics[0].point_time(0))
        self.assertIsNone(n.topics[0].point_time(1))
        self.assertEqual(2, len(n.topics[0].fishbone.branches))
        self.assertEqual(0, n.topics[0].fishbone.branches[1].support)
        self.assertEqual(2, n.conclusions[0].support)
        self.assertIsNone(n.todos[0].owner)
        self.assertEqual(["Strip"], n.terms[0].heard)
        self.assertIsNone(notesmod.parse("not json", [], 0.0))
        self.assertIsNone(notesmod.parse("{}", [], 0.0))

    def test_keeps_earliest_times(self):
        old = MeetingNotes(topics=[NoteTopic(title="t", points=["a"], pointTimes=[3.0])], todos=[NoteItem(text="x", t=2.0)])
        nxt = MeetingNotes(topics=[NoteTopic(title="t", points=["a", "b"], pointTimes=[9.0, None])], todos=[NoteItem(text="x", t=8.0)])
        notesmod.carry_times(old, nxt)
        self.assertEqual(3.0, nxt.topics[0].point_time(0))
        self.assertEqual(2.0, nxt.todos[0].t)

    def test_notes_prompt_is_the_macs(self):
        lines = [TranscriptLine(t=1.0, src="你好", speaker="them"), TranscriptLine(t=65.0, src="我来说", speaker="me")]
        p = notesmod.prompt(MeetingNotes(), lines, 0, "Simplified Chinese", final=False)
        self.assertTrue(p.startswith("You keep notes for a meeting that is still going on. Update them with the new lines.\nWrite the notes in Simplified Chinese. Return JSON only.\n"))
        self.assertIn("[L1 00:01 对方] 你好\n[L2 01:05 你] 我来说", p)
        self.assertIn("These are the first lines: make one topic.", p)
        self.assertTrue(p.endswith("No markdown, no text outside the JSON."))
        f = notesmod.prompt(MeetingNotes(), lines, 0, "English", final=True)
        self.assertIn("This meeting ran 01:04: use at most 1 topic.", f)
        self.assertTrue(notesmod.written(MeetingNotes(summary="讨论发布 Stripe"), "Simplified Chinese"))
        self.assertFalse(notesmod.written(MeetingNotes(summary="We talked"), "Simplified Chinese"))

    def test_notes_prompt_matches_the_android_port(self):
        """The same prompt text as android/core Notes.kt, checked against its source so a change
        on one side shows up here."""
        src = os.path.join(REPO, "android/core/src/main/kotlin/cicada/Notes.kt")
        if not os.path.isfile(src):
            self.skipTest("no Android source")
        with open(src, encoding="utf-8") as f:
            kt = f.read()
        p = notesmod.prompt(MeetingNotes(), [TranscriptLine(t=1.0, src="x")], 0, "English", final=True)
        for rule in [l for l in p.split("\n") if l.startswith("- ")]:
            probe = rule.replace('"', '\\"')[:60]
            self.assertIn(probe, kt, rule)


class Strings(Base):
    def test_loads_the_macs_translations(self):
        res = [os.path.join(REPO, "Resources"), os.path.join(REPO, "linux", "strings")]
        strings.load("en_US.UTF-8", res)
        self.assertEqual("Live notes", strings.L("实时纪要"))
        self.assertEqual("没有这条", strings.L("没有这条"))
        strings.load("zh-Hans", res)
        self.assertEqual("实时纪要", strings.L("实时纪要"))
        t = strings.parse('/* c */\n"a \\"b\\"" = "x\\ny";\n// line\n"%@ 分钟" = "%@ min";')
        self.assertEqual("x\ny", t['a "b"'])
        self.assertEqual("%@ min", t["%@ 分钟"])
        self.assertEqual("3 分钟", strings.LF("%@ 分钟", 3))
        self.assertEqual("b a", strings.LF("%2$@ %1$@", "a", "b"))

    def test_key_file_is_private(self):
        key = AIKey()
        self.assertTrue(key.save("sk-test-0000000000"))
        self.assertEqual(0o600, stat.S_IMODE(os.stat(Paths.key_file()).st_mode))
        AppSettings().save()
        with open(Paths.settings(), encoding="utf-8") as f:
            self.assertNotIn("sk-", f.read())
        self.assertEqual("sk-••••••••••••0000", AIKey.masked("sk-test-0000000000"))


class Ling(Base):
    def test_request_shape(self):
        fake = Fake(lambda b: reply("ok"))
        client(fake).chat("the content", "Translate.", TRANSLATE, model=AUDIO_MODEL, audio=bytes([1, 2, 3]))
        body = jsonfmt.parse(fake.calls[0][1])
        self.assertEqual("disabled", body["thinking"]["type"])
        self.assertEqual("system", body["messages"][0]["role"])
        self.assertEqual("the content", content(fake.calls[0][1], 0))
        user = content(fake.calls[0][1], 1)
        self.assertEqual("audio_url", user[0]["type"])
        self.assertEqual("data:audio/wav;base64,AQID", user[0]["audio_url"]["url"])
        self.assertEqual("Translate.", user[1]["text"])

    def test_drops_hijacked_and_refused_replies(self):
        for r, finish in (("根据现有检索证据，……", "stop"), ("作为一个人工智能语言模型，这个问题超出……", "stop"), ("fine", None)):
            ling = client(Fake(lambda b, r=r, f=finish: reply(r, f)))
            with self.assertRaises(LingError) as e:
                ling.chat("c", "i", TRANSLATE)
            self.assertEqual(LingError.HIJACKED, e.exception.kind)

    def test_retries_audio_once_when_busy(self):
        n = [0]

        def respond(b):
            n[0] += 1
            return Response(429, "") if n[0] == 1 else reply("LANG: en\nORIGINAL: Hi.\nTRANSLATION: 嗨。")
        r = client(Fake(respond)).chat("c", "i", TRANSLATE, model=AUDIO_MODEL, audio=bytes([1]))
        self.assertIn("ORIGINAL: Hi.", r)
        self.assertEqual(2, n[0])
        with self.assertRaises(LingError) as e:
            client(Fake(lambda b: Response(429, ""))).chat("c", "i", TRANSLATE)
        self.assertEqual(LingError.RATE_LIMITED, e.exception.kind)

    def test_marks_a_bad_key(self):
        ling = client(Fake(lambda b: Response(401, "")))
        with self.assertRaises(LingError) as e:
            ling.chat("c", "i", TRANSLATE)
        self.assertEqual(LingError.INVALID_KEY, e.exception.kind)
        self.assertEqual(INVALID, ling.key_state)
        self.assertFalse(ling.usable)

    def test_gate_spaces_starts_and_serves_priority_first(self):
        LingClient.spacing = 0.2
        fake = Fake(lambda b: reply("ok"))
        ling = client(fake)
        a = threading.Thread(target=ling.chat, args=("first", "i", NOTES))
        a.start()
        time.sleep(0.02)
        # Queued while the gate is closed: the translation goes before the earlier notes call.
        b = threading.Thread(target=ling.chat, args=("notes", "i", NOTES))
        b.start()
        time.sleep(0.02)
        c = threading.Thread(target=ling.chat, args=("translate", "i", TRANSLATE))
        c.start()
        for t in (a, b, c):
            t.join()
        self.assertEqual(["first", "translate", "notes"], [content(x[1], 0) for x in fake.calls])
        for i in range(1, len(fake.calls)):
            self.assertGreaterEqual(fake.calls[i][0] - fake.calls[i - 1][0], 0.18)


class Listening(Base):
    def test_end_to_end_with_a_fake_ming(self):
        # Two stretches of "speech", told apart by length (1 s, then 1.6 s); the fake Ming answers
        # the first one slower, and lines still come out in order.
        def respond(body):
            if "Ming-3.0-audio-flash" in body:
                url = content(body, 1)[0]["audio_url"]["url"]
                first = len(url) < 60000
                if first:
                    time.sleep(0.4)
                return reply("LANG: en\nORIGINAL: First one.\nTRANSLATION: 第一句。" if first else
                             "LANG: en\nORIGINAL: Second one.\nTRANSLATION: 第二句。")
            return reply("{}")
        LingClient.spacing = 0.05
        ling = client(Fake(respond))
        store = SessionStore()
        notes = NotesEngine(ling, store)
        engine = ListenEngine(ling, Translator(ling), store, notes, AppSettings(target="zh-CN"))
        src = PcmAudioSource(lambda: concat(tone(1.0), silence(1.0), tone(1.6), silence(1.0)), speed=0)
        ended = threading.Event()
        src.on_ended = lambda why: ended.set()
        engine.start(src, "file")
        ended.wait(10)
        time.sleep(0.1)
        engine.stop()
        s = store.get(engine.session_id)
        self.assertEqual(["First one.", "Second one."], [l.src for l in s.lines])
        self.assertEqual("第一句。", s.lines[0].dst)
        self.assertEqual("h1-1", s.lines[0].id)
        self.assertIsNotNone(s.endedAt)

    def test_follow_system_translates_my_own_language_into_the_next(self):
        # They speak Chinese, my language: the first stretch was asked for Chinese (nothing heard
        # yet), so its translation is dropped for the text translation; the next is asked for English.
        asked = []

        def respond(body):
            if "Ming-3.0-audio-flash" in body:
                asked.append(content(body, 0))
                return reply("LANG: zh\nORIGINAL: 大家好。\nTRANSLATION: %s" % ("Hello all." if "into English" in asked[-1] else "大家好。"))
            return reply("{}")
        LingClient.spacing = 0.05
        ling = client(Fake(respond))
        store = SessionStore()
        settings = AppSettings()
        settings.resolved_target = lambda src: "en" if src == "zh-CN" else "zh-CN"
        engine = ListenEngine(ling, Translator(ling), store, NotesEngine(ling, store), settings)
        # Four times real time: the first reply is back before the second stretch is sent, as in a meeting.
        src = PcmAudioSource(lambda: concat(tone(1.0), silence(3.0), tone(1.6), silence(1.0)), speed=4)
        ended = threading.Event()
        src.on_ended = lambda why: ended.set()
        engine.start(src, "file")
        ended.wait(10)
        time.sleep(0.3)
        engine.stop()
        lines = store.get(engine.session_id).lines
        self.assertTrue(all(l.dstLang == "en" for l in lines))
        self.assertNotIn("大家好。", [l.dst for l in lines])
        self.assertIn("into Simplified Chinese", asked[0])
        self.assertIn("into English", asked[-1])


def sse(*chunks):
    import base64
    return ["data: " + jsonfmt.write({"type": "speech.audio.delta", "audio": base64.b64encode(c).decode()}, pretty=False) for c in chunks] + \
           ["", "data: {\"type\":\"speech.audio.done\"}"]


class Player:
    def __init__(self):
        self.data = b""
        self.closed = 0

    def write(self, pcm):
        self.data += pcm

    def drain(self):
        pass

    def close(self):
        self.closed += 1


class Speaking(Base):
    def test_parses_interpretations(self):
        self.assertEqual(("你好", "Hello"), parse_interpretation("ORIGINAL: 你好\nTRANSLATION: Hello", "en"))
        self.assertIsNone(parse_interpretation("Sure! Here is my answer.", "en"), "an answer is not an interpretation")
        self.assertIsNone(parse_interpretation("ORIGINAL: 你好\nTRANSLATION: 你好", "en"), "untranslated")
        self.assertIsNone(parse_interpretation("ORIGINAL: 你好\nTRANSLATION: 你好吗", "en"), "wrong script")
        self.assertIsNone(parse_interpretation("ORIGINAL: hi\nTRANSLATION:", "zh-CN"), "empty")

    def test_streams_ming_voice(self):
        fake = Fake(lambda b: reply("ok"), speech=lambda b: sse(b"\x01\x00", b"\x02\x00"))
        pcm = list(client(fake).speech("Hello", voice="US_Emma", language=None))
        self.assertEqual([b"\x01\x00", b"\x02\x00"], pcm)
        body = jsonfmt.parse(fake.spoken[0])
        self.assertEqual(("Ming-3.0-tts-0.5B", "US_Emma", 24000, True), (body["model"], body["voice"], body["sample_rate"], body["stream"]))
        self.assertNotIn("language_id", body)

    def _engine(self, interpret_reply, listen=None):
        LingClient.spacing = 0.01
        fake = Fake(lambda b: reply(interpret_reply), speech=lambda b: sse(b"\x10\x00" * 100))
        ling = client(fake)
        player = Player()
        settings = AppSettings(target="zh-CN", speakTo="en")
        eng = SpeakEngine(ling, Translator(ling), settings, listen=listen, player=lambda: player)
        return eng, fake, player

    def _say(self, eng, pcm):
        src = PcmAudioSource(lambda: pcm, speed=0)
        done = threading.Event()
        src.on_ended = lambda why: done.set()
        eng.start(src)
        done.wait(5)
        time.sleep(0.6)
        eng.stop()

    def test_speaks_the_translation_into_the_room(self):
        eng, fake, player = self._engine("ORIGINAL: 我们周五上线\nTRANSLATION: We launch on Friday")
        self._say(eng, concat(tone(1.2), silence(1.0)))
        self.assertEqual(1, eng.spoken)
        self.assertEqual(b"\x10\x00" * 100, player.data)
        self.assertEqual("We launch on Friday", jsonfmt.parse(fake.spoken[0])["input"])
        self.assertIn("into English", content(fake.calls[0][1], 0))

    def test_never_speaks_what_was_not_interpreted(self):
        eng, fake, player = self._engine("I think the launch should be on Friday, here is why...")
        self._say(eng, concat(tone(1.2), silence(1.0)))
        self.assertEqual(0, eng.spoken)
        self.assertEqual([], fake.spoken, "nothing sent to the voice")
        self.assertEqual(b"", player.data)
        self.assertIsNotNone(eng.problem)

    def test_fetches_the_next_voice_while_the_last_one_plays(self):
        eng, fake, player = self._engine("ORIGINAL: 你好\nTRANSLATION: Hello")
        fetched = []
        slow = threading.Event()

        def write(pcm, _w=player.write):
            if not fetched:
                fetched.append(len(fake.spoken))
                slow.wait(1.5)  # the first sentence still playing
                fetched.append(len(fake.spoken))
            _w(pcm)
        player.write = write
        self._say(eng, concat(tone(1.2), silence(1.0), tone(1.2), silence(1.0)))
        slow.set()
        time.sleep(0.3)
        self.assertEqual(2, eng.spoken)
        self.assertEqual(2, fetched[1], "the second voice was asked for before the first finished playing")

    def test_export_names_who_said_each_line(self):
        s = Session(title="会议", startedAt=datetime(2026, 1, 1, tzinfo=timezone.utc), lines=[
            TranscriptLine(id="h1-1", t=1, src="Hi", dst="你好", srcLang="en", dstLang="zh-CN"),
            TranscriptLine(id="m1", t=3, speaker="me", src="我们周五上线", dst="We launch on Friday", srcLang="zh-CN", dstLang="en")])
        strings.load("zh-Hans", [os.path.join(REPO, "Resources")])
        s.endedAt = s.startedAt + timedelta(minutes=24, seconds=30)
        s.notes = MeetingNotes(title="上线", summary="定了周五。", topics=[NoteTopic(
            title="上线时间", start=0, summary="讨论日期", points=["周五"],
            fishbone=Fishbone(question="为什么推迟？", branches=[FishboneBranch(label="测试", detail="还没跑完")]))],
            todos=[NoteItem(text="发说明", owner="你")], terms=[NoteTerm(name="Ling", note="模型")])
        local = s.startedAt.astimezone()
        when = "%d年%d月%d日 %02d:%02d" % (local.year, local.month, local.day, local.hour, local.minute)
        # TranscriptExport.markdown on the Mac, character for character.
        self.assertEqual(
            "# %s\n\n%s · 24 分钟\n\n" % (session_store.display_title(s), when) +
            "## 纪要\n\n定了周五。\n\n### 00:00 上线时间\n\n讨论日期\n\n- 周五\n\n**为什么推迟？**\n\n- 测试：还没跑完\n\n"
            "### 待办\n\n- [ ] 发说明（你）\n\n### 人名和术语\n\n- **Ling** 模型\n\n## 文字记录\n\n"
            "**[00:01] 对方**  \nHi\n> 你好\n\n**[00:03] 你**  \n我们周五上线\n> We launch on Friday\n\n",
            session_store.markdown(s))
        s.sourceFile = "call.m4a"
        self.assertIn("**[00:01]**  \nHi\n", session_store.markdown(s), "an imported file names nobody")

    def test_drops_the_other_sides_voice_heard_through_the_speakers(self):
        class Listening:
            listening = True
            spoken = "en"
            session_id = None
        eng, fake, player = self._engine("ORIGINAL: 你好\nTRANSLATION: Hello", listen=Listening())
        stop = threading.Event()

        def loud():
            while not stop.is_set():
                eng.loudness.add(True)
                time.sleep(0.02)
        threading.Thread(target=loud, daemon=True).start()
        self._say(eng, concat(tone(1.2), silence(1.0)))
        stop.set()
        self.assertEqual(0, eng.spoken)
        self.assertEqual([], fake.calls, "not even sent to Ming")
        self.assertIsNotNone(eng.problem, "and the user is told")

    def test_with_headphones_talking_over_them_still_goes_out(self):
        class Listening:
            listening = True
            spoken = "en"
            session_id = None
        eng, fake, player = self._engine("ORIGINAL: 你好\nTRANSLATION: Hello", listen=Listening())
        eng.settings.speakHeadphones = True
        for _ in range(200):
            eng.loudness.add(True)
        self._say(eng, concat(tone(1.2), silence(1.0)))
        self.assertEqual(1, eng.spoken)

    def test_cancel_drops_what_is_still_waiting(self):
        eng, fake, player = self._engine("ORIGINAL: 你好\nTRANSLATION: Hello")
        src = PcmAudioSource(lambda: concat(tone(1.2), silence(1.0)), speed=0)
        done = threading.Event()
        src.on_ended = lambda why: done.set()
        eng.start(src)
        done.wait(5)
        eng.cancel()
        time.sleep(0.8)
        self.assertEqual(0, eng.spoken)
        self.assertEqual(b"", player.data)


def unit(seed, dims=256):
    import random
    r = random.Random(seed)
    v = [r.gauss(0, 1) for _ in range(dims)]
    n = math.sqrt(sum(x * x for x in v))
    return [x / n for x in v]


def near(v, seed, mix=0.3):
    w = unit(seed)
    out = [a + mix * b for a, b in zip(v, w)]
    n = math.sqrt(sum(x * x for x in out))
    return [x / n for x in out]


def them(i, voice, text="we should ship this on Friday", t=None):
    return TranscriptLine(id="h%d-%d" % (i, i), t=t if t is not None else float(i), src=text, srcLang="en", dstLang="zh-CN", voice=voice)


class Speakers(Base):
    def test_the_voiceprint_is_the_macs(self):
        # The C library against the Mac's Core ML model on the same audio (linux/tests/voiceprint-ref.json).
        import json
        import wave
        if speakers.library_path() is None or speakers.model_path() is None:
            self.skipTest("no voiceprint library: native/build.sh")
        with open(os.path.join(HERE, "voiceprint-ref.json")) as f:
            ref = json.load(f)
        w = wave.open(os.path.join(REPO, ref["clip"]))
        w.setpos(ref["start"] * 16000)
        pcm = array("h", w.readframes(ref["seconds"] * 16000))
        v = speakers.Voiceprints.load().embed(pcm)
        self.assertGreater(sum(a * b for a, b in zip(v, ref["coreml"])), 0.999)
        self.assertIsNone(speakers.Voiceprints.load().embed(pcm[:4000]), "under half a second")

    def test_clusterer_matches_the_mac(self):
        c = speakers.VoiceClusterer()
        a, b = unit(1), unit(2)
        self.assertIsNone(c.label(a, 1.5), "too short to start a voice")
        self.assertEqual(0, c.label(a, 3))
        self.assertEqual(1, c.label(b, 3))
        self.assertEqual(0, c.label(near(a, 7), 1.0), "joins the closest voice even when short")
        self.assertEqual(1, c.label(near(b, 8), 3))
        c.merge(1, 0)
        self.assertEqual(0, c.label(near(b, 9), 3), "after a merge, either voice goes to the one kept")

    def test_numbers_wait_for_two_voices_with_five_lines(self):
        lines = [them(i, 0) for i in range(5)]
        self.assertEqual({}, speakers.voice_numbers(lines), "one voice: still 对方")
        lines += [them(10 + i, 1) for i in range(4)] + [them(20, 1, "ok")]
        self.assertEqual({}, speakers.voice_numbers(lines), "a short line doesn't count")
        lines.append(them(21, 1))
        self.assertEqual({0: 1, 1: 2}, speakers.voice_numbers(lines))
        self.assertTrue(speakers.substantive("我们周五上线"))
        self.assertFalse(speakers.substantive("好的"))

    def test_names_merges_and_undo(self):
        strings.load("zh-Hans", [os.path.join(REPO, "Resources")])
        store = SessionStore()
        s = store.begin()
        for i in range(5):
            store.append(s.id, them(i, 0))
            store.append(s.id, them(10 + i, 1))
        store.append(s.id, them(30, 2))
        snap = store.voice_snapshot(s.id)
        store.set_voice_guesses(s.id, {1: VoiceGuess("George", "00:10 “Thanks, George”")})
        got = store.get(s.id)
        self.assertEqual({2: "George"}, speakers.names(got))
        self.assertEqual("说话人 1", speakers.label(1, speakers.names(got)))
        store.set_voice_name(s.id, 0, "Emma")
        store.set_voice_name(s.id, 1, "")  # 不是 TA: 说话人 2 again
        self.assertEqual({1: "Emma"}, speakers.names(store.get(s.id)))
        store.merge_voice(s.id, 2, 0)
        self.assertEqual(6, sum(1 for l in store.get(s.id).lines if l.voice == 0))
        store.restore(s.id, snap)
        got = store.get(s.id)
        self.assertEqual(({}, None, None), (speakers.names(got), got.voiceNames, got.voiceGuesses))
        self.assertEqual(1, sum(1 for l in got.lines if l.voice == 2))
        md = session_store.markdown(got, voices=True)
        self.assertIn("**[00:00] 说话人 1**", md)
        self.assertIn("**[00:30] 未识别**", md)
        notes = MeetingNotes(summary="说话人 2 会发说明", topics=[NoteTopic(title="说话人2 的计划")])
        named = speakers.named(notes, {2: "George"})
        self.assertEqual(("George 会发说明", "George 的计划"), (named.summary, named.topics[0].title))
        self.assertEqual("说话人 2 会发说明", notes.summary, "the stored notes are untouched")

    def test_ling_names_need_evidence_near_the_voice(self):
        s = Session(title="会议", startedAt=datetime(2026, 1, 1, tzinfo=timezone.utc))
        for i in range(5):
            s.lines.append(them(2 * i, 0, t=2.0 * i))
            s.lines.append(them(2 * i + 1, 1, t=2.0 * i + 1))
        s.lines.append(them(40, 1, "Thanks so much, George, that was clear", t=40))
        found, refuted = speakers.read('{"speakers": [{"speaker": 2, "name": "George", "evidence": "L11"},'
                                       '{"speaker": 1, "name": "Christina", "evidence": "L99"}]}', s)
        self.assertEqual("George", found[1].name)
        self.assertTrue(found[1].evidence.startswith("00:40 “Thanks"))
        self.assertEqual({0: "Christina"}, refuted)
        self.assertEqual(({}, {}), speakers.read("not json", s))
        self.assertIn("说话人1", speakers.content(s))

    def test_notes_prompt_names_the_voices(self):
        lines = [them(i, i % 2) for i in range(10)] + [them(20, None)]
        p = notesmod.prompt(MeetingNotes(), lines, 0, "Chinese", False, {2: "George"}, voices=True)
        self.assertIn(" 说话人1] ", p)
        self.assertIn("George] ", p)
        self.assertIn("未识别] ", p)
        self.assertIn("对方] ", notesmod.prompt(MeetingNotes(), lines, 0, "Chinese", False))

    def _halves(self, voices):
        # Ming cuts "so we will ship" | "on Friday then." mid-sentence; `voices` says whose each half is.
        def respond(body):
            # Both halves go to Ming at once: answer by the audio's length (1.0 s, then 1.4 s).
            if "Ming-3.0-audio-flash" not in body:
                return reply("{}")
            first = len(content(body, 1)[0]["audio_url"]["url"]) < 60000
            return reply("LANG: en\nORIGINAL: so we will ship\nTRANSLATION: 所以我们会发布" if first else
                         "LANG: en\nORIGINAL: on Friday then.\nTRANSLATION: 那就周五。")
        order = iter(voices)

        class Voices:
            available = True

            def reset(self):
                pass

            def embed(self, samples):
                return [float(next(order))]

            def label(self, vector, seconds):
                return int(vector[0])
        LingClient.spacing = 0.05
        ling = client(Fake(respond))
        store = SessionStore()
        engine = ListenEngine(ling, Translator(ling), store, NotesEngine(ling, store), AppSettings(target="zh-CN"))
        engine.speakers = Voices()
        heard = []
        engine.on_voice = heard.append
        src = PcmAudioSource(lambda: concat(tone(1.0), silence(0.8), tone(1.4), silence(1.0)), speed=0)
        ended = threading.Event()
        src.on_ended = lambda why: ended.set()
        engine.start(src, "file")
        ended.wait(10)
        time.sleep(0.2)
        engine.stop()
        return [(l.voice, l.src) for l in store.get(engine.session_id).lines], heard

    def test_slow_voiceprints_never_hold_subtitles_back(self):
        LingClient.spacing = 0.01
        ling = client(Fake(lambda b: reply("LANG: en\nORIGINAL: We should ship it on Friday.\nTRANSLATION: 我们周五发布。")
                           if "Ming-3.0-audio-flash" in b else reply("{}")))
        store = SessionStore()
        engine = ListenEngine(ling, Translator(ling), store, NotesEngine(ling, store), AppSettings(target="zh-CN"))

        class Slow:
            available = True

            def reset(self):
                pass

            def embed(self, samples):
                time.sleep(0.6)  # a CPU that can't keep up
                return [1.0]

            def label(self, vector, seconds):
                return 0
        engine.speakers = Slow()
        pcm = concat(*([tone(1.0), silence(1.0)] * 5))
        src = PcmAudioSource(lambda: pcm, speed=0)
        ended = threading.Event()
        src.on_ended = lambda why: ended.set()
        engine.start(src, "file")
        ended.wait(10)
        time.sleep(2.5)
        engine.stop()
        voices = [l.voice for l in store.get(engine.session_id).lines]
        self.assertEqual(5, len(voices))
        self.assertIn(None, voices, "some lines went unlabelled rather than waiting")
        self.assertIn(0, voices)

    def test_a_half_sentence_joins_only_the_same_voice(self):
        lines, heard = self._halves([1, 2])
        self.assertEqual([(1, "so we will ship"), (2, "on Friday then.")], lines)
        self.assertEqual(2, len(heard))
        lines, _ = self._halves([1, 1])
        self.assertEqual([(1, "so we will ship on Friday then.")], lines, "the same voice: one sentence")


if __name__ == "__main__":
    unittest.main()

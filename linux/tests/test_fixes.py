"""改正听错的词: the record's fixes, read and written as the Mac does (mac-fixes-session.json is a record
the Mac dev build wrote), and the line as shown in display, search and export.
    python3 -m unittest discover -s linux/tests      (scripts/test.sh)"""
from __future__ import annotations

import os
import shutil
import sys
import tempfile
import unittest
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)

from cicada.core import correction, jsonfmt, session_store  # noqa: E402
from cicada.core.correction import APPLY, ASK, DROP, Edit, apply  # noqa: E402
from cicada.core.live_fixes import FixContext, LiveFixes  # noqa: E402
from cicada.core.models import LineFix, Session, TranscriptLine  # noqa: E402
from cicada.core.settings import AppSettings  # noqa: E402
from cicada.core.support import Paths  # noqa: E402
from cicada.core.translator import Translator  # noqa: E402
from cicada.core.vocabulary import Term, Vocabulary  # noqa: E402


class Base(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="cicada-fixes-")
        Paths.home_override = self.home
        Paths.log_override = os.path.join(self.home, "debug.log")

    def tearDown(self):
        Paths.home_override = None
        Paths.log_override = None
        shutil.rmtree(self.home, ignore_errors=True)


class RecordFormat(Base):
    def test_mac_record_with_fixes_round_trips_byte_for_byte(self):
        with open(os.path.join(HERE, "mac-fixes-session.json"), encoding="utf-8") as f:
            text = f.read()
        s = Session.read(text)
        self.assertEqual(s.lines[0].fixes, [LineFix("开布特", "Curve", user=True)])
        self.assertIsNone(s.lines[1].fixes)
        self.assertEqual(s.lines[0].src, "最近那个开布特提了好几次他们那个协议的更新慢。")
        self.assertEqual(s.lines[0].shown, "最近那个Curve提了好几次他们那个协议的更新慢。")
        self.assertEqual(s.lines[2].shown, "就是你不更新它数量就不变但质押这种基本不怎么变。")
        self.assertEqual(s.write(), text)

    def test_unchanged_without_fixes(self):
        line = TranscriptLine(id="1", t=0, speaker="them", src="a", srcLang="zh", dstLang="en")
        s = Session(id="x", title="t", lines=[line])
        self.assertNotIn("fixes", s.write())
        line.fixes = []
        self.assertNotIn("fixes", s.write())  # none is absent, as the Mac stores nil
        line.fixes = [LineFix("a", "b")]
        back = Session.read(s.write()).lines[0]
        self.assertEqual(back.shown, "b")
        self.assertEqual(back.src, "a")
        self.assertIn('"fixes" : [\n        {\n          "from" : "a",\n          "to" : "b"\n        }\n      ]', s.write())

    def test_copy_keeps_fixes_apart(self):
        line = TranscriptLine(id="1", src="质压", fixes=[LineFix("质压", "质押")])
        c = line.copy()
        c.fixes[0].off = True
        self.assertEqual(line.shown, "质押")
        self.assertEqual(c.shown, "质压")

    def test_export_uses_the_shown_text(self):
        with open(os.path.join(HERE, "mac-fixes-session.json"), encoding="utf-8") as f:
            s = Session.read(f.read())
        md = session_store.markdown(s)
        self.assertIn("最近那个Curve提了", md)
        self.assertNotIn("开布特", md)

    def test_store_keeps_fixes_when_the_engine_replaces_a_line(self):
        store = session_store.SessionStore()
        s = store.begin()
        store.append(s.id, TranscriptLine(id="l0", src="但质压这种", fixes=[LineFix("质压", "质押")]))
        store.replace(s.id, TranscriptLine(id="l0", src="但质压这种", dst="But staking"))
        self.assertEqual(store.get(s.id).lines[0].shown, "但质押这种")


class Applying(unittest.TestCase):
    def test_apply_replaces_and_marks(self):
        fixes = [LineFix("莫拉", "Morpho"), LineFix("质压", "质押"), LineFix("开布特", "Curve", ask=True),
                 LineFix("ropax", "RoPax", off=True)]
        text, marks = apply(fixes, "解释这个莫拉的，质压和开布特，ropax")
        self.assertEqual(text, "解释这个Morpho的，质押和开布特，ropax")
        self.assertEqual([text[a:b] for a, b in marks], ["Morpho", "质押"])

    def test_apply_keeps_earlier_marks_when_later_fixes_shift(self):
        text, marks = apply([LineFix("质压", "质押"), LineFix("莫拉", "Morpho")], "莫拉说质压")
        self.assertEqual(text, "Morpho说质押")
        self.assertEqual([text[a:b] for a, b in marks], ["Morpho", "质押"])

    def test_fix_whose_words_went_away_is_skipped(self):
        self.assertEqual(apply([LineFix("莫拉", "Morpho")], "解释这个摩托的")[0], "解释这个摩托的")


def verdict(frm, to, c, known=(), rejected=()):
    return correction.decide(Edit(frm, to, c), lambda a, b: (a, b) in known, lambda a, b: (a, b) in rejected)


class Correction(unittest.TestCase):
    """The Mac's CorrectionTests: cases from a 21-minute meeting recording (a DeFi team's weekly)."""

    def test_sound_alike_chinese_is_applied(self):
        self.assertEqual(verdict("解除质压", "解除质押", 0.9), APPLY)
        self.assertNotEqual(verdict("跳便是", "跳变", 0.9), APPLY)  # a word dropped: not a sound fix
        self.assertEqual(verdict("两个代笔", "两个代币", 0.9), APPLY)
        self.assertEqual(verdict("管理房", "管理方", 0.9), APPLY)
        self.assertEqual(verdict("追压", "质押", 0.85), APPLY)
        # Only the changed part is compared: 花/概 share nothing, though the phrase around them does.
        self.assertEqual(verdict("花了大花", "花了大概", 0.85), DROP)
        self.assertEqual(verdict("FFT制押", "FFT质押", 0.9), APPLY)

    def test_confident_but_unlike_sound_is_dropped(self):
        self.assertEqual(verdict("快销", "区块", 0.85), DROP)
        self.assertEqual(verdict("苍蝇", "方向", 0.85), DROP)
        self.assertEqual(verdict("机录", "机会", 0.8), DROP)

    def test_low_confidence_is_dropped(self):
        self.assertEqual(verdict("质压", "质押", 0.5), DROP)

    def test_spelling_fix_needs_high_confidence(self):
        self.assertEqual(verdict("cransfer", "transfer", 0.85), APPLY)
        self.assertEqual(verdict("cransfer", "transfer", 0.7), DROP)
        self.assertEqual(verdict("bos", "BOS", 0.9), DROP)  # case only

    def test_new_names_are_asked(self):
        self.assertEqual(verdict("莫拉", "Morpho", 0.85), ASK)
        self.assertEqual(verdict("开布特", "Curve", 0.8), ASK)
        self.assertEqual(verdict("Ero", "Euler", 0.85), ASK)
        self.assertEqual(verdict("莫纳", "Morpho", 0.7), DROP)

    def test_learned_words_stay_whole(self):
        """A learned "S平 → X平" never reaches into "iOS平台"; on its own it still applies."""
        self.assertEqual(correction.word("S平", "iOS平台很好"), -1)
        self.assertEqual(correction.word("A工", "DATA工具"), -1)
        self.assertNotEqual(correction.word("S平", "在S平台上"), -1)
        self.assertNotEqual(correction.word("S平", "iOS平台和S平台"), -1)
        self.assertNotEqual(correction.word("莫拉", "解释这个莫拉的"), -1)
        self.assertEqual(apply([LineFix("S平", "X平")], "iOS平台和S平台")[0], "iOS平台和X平台")

    def test_translations_are_not_asked(self):
        """A translation isn't a misheard name: one 对 to "X平台 → X platform" taught 平台 → platform."""
        self.assertEqual(verdict("X平台", "X platform", 0.9), DROP)
        self.assertEqual(verdict("平台", "platform", 0.95), DROP)
        self.assertEqual(verdict("respons", "responsible", 0.85), DROP)
        self.assertEqual(verdict("GPT四", "GPT4", 0.85), ASK)
        self.assertTrue(correction.translation("平台", "platform"))
        self.assertFalse(correction.translation("莫拉", "Morpho"))

    def test_confirmed_heard_form_is_applied(self):
        self.assertEqual(verdict("莫拉", "Morpho", 0.5, known=[("莫拉", "Morpho")]), APPLY)
        self.assertEqual(verdict("解释这个莫拉的", "解释这个Morpho的", 0.5, known=[("莫拉", "Morpho")]), APPLY)

    def test_rejected_is_dropped(self):
        self.assertEqual(verdict("质压", "质押", 0.95, rejected=[("质压", "质押")]), DROP)
        self.assertEqual(verdict("莫拉", "Morpho", 0.95, known=[("莫拉", "Morpho")], rejected=[("莫拉", "Morpho")]), DROP)

    def test_core_drops_shared_ends(self):
        core = correction.core
        self.assertEqual(core("解除质压", "解除质押"), ("质压", "质押"))
        self.assertEqual(core("Un450P三", "Uniswap V3"), ("Un450P三", "Uniswap V3"))
        self.assertEqual(core("解释这个莫拉的", "解释这个Morpho的"), ("莫拉", "Morpho"))
        self.assertEqual(core("找了cransfer记录", "找了transfer记录"), ("cransfer", "transfer"))
        # A Chinese change next to a Latin word leaves the word out.
        self.assertEqual(core("FFT制押", "FFT质押"), ("制押", "质押"))

    def test_pinyin_is_the_macs(self):
        self.assertEqual(correction.pinyin("质押追销女"), ["zhi", "ya", "zhui", "xiao", "nu"])
        self.assertEqual(correction.pinyin("a"), ["a"])

    def test_parse_reply(self):
        reply = ('{"translation": "I explained Morpho.", "fixes": [{"from": "莫拉", "to": "Morpho", "confidence": 0.85},\n'
                 ' {"from": "不在原文", "to": "x", "confidence": 0.9}]}')
        translation, edits = correction.parse(reply, "解释这个莫拉的。")
        self.assertEqual(translation, "I explained Morpho.")
        self.assertEqual(edits, [Edit("莫拉", "Morpho", 0.85)])
        self.assertIsNone(correction.parse("I explained Mora.", "x"))
        self.assertEqual(correction.parse('```json\n{"translation": "Hi"}\n```', "x")[0], "Hi")

    def test_merge_keeps_refusals(self):
        old = [LineFix("莫拉", "Morpho", off=True), LineFix("质压", "质押")]
        new = [LineFix("莫拉", "Morpho"), LineFix("寻检", "巡检")]
        self.assertEqual(correction.merge(old, new), [LineFix("莫拉", "Morpho", off=True), LineFix("寻检", "巡检")])

    def test_recheck_takes_back_what_it_no_longer_proposes_but_not_the_users(self):
        old = [LineFix("跑好的", "跑跑的"), LineFix("开布特", "Curve", user=True)]
        self.assertEqual(correction.merge(old, []), [LineFix("开布特", "Curve", user=True)])
        self.assertEqual(correction.merge(old, [LineFix("开布特", "Cobalt")]), [LineFix("开布特", "Curve", user=True)])

    def test_user_edit_on_top_of_a_fix(self):
        fixes = [LineFix("莫纳", "Morpho")]
        src = "扩展到这个莫纳的 Link"
        shown = apply(fixes, src)[0]
        fix, heard, swap = correction.user_edit(shown, "扩展到这个Monad的 Link", src, fixes)
        self.assertTrue(swap)
        self.assertEqual(fix, LineFix("Morpho", "Monad", user=True))
        self.assertEqual(heard, "莫纳")
        self.assertEqual(apply(fixes + [fix], src)[0], "扩展到这个Monad的 Link")
        self.assertEqual(correction.user_edit("我木娜找了一个", "我在 Monad 找了一个", "我木娜找了一个", [])[1], "木娜")
        self.assertIsNone(correction.user_edit("a", " a ", "a", []))

    def test_dropped_word_keeps_both_sides_of_the_fix(self):
        line = "Great, let's lock that in now."
        fix = correction.user_edit(line, "Great, let's lock that in.", line, [])[0]
        self.assertTrue(fix.from_ and fix.to)
        self.assertEqual(apply([fix], line)[0], "Great, let's lock that in.")
        self.assertTrue(all(correction.label(fix)))

    def test_label_names_an_added_word_whole(self):
        self.assertEqual(correction.label(LineFix("in", "in now", user=True)), ("in", "in now"))
        self.assertEqual(correction.label(LineFix("Great", "OK Great", user=True)), ("Great", "OK Great"))
        self.assertEqual(correction.label(LineFix("解除质压", "解除质押")), ("质压", "质押"))

    def test_added_word_stays_on_its_line_and_never_matches_punctuation(self):
        # "now" added before the full stop: the fix is the last word, unique in the line, not ".".
        line = "Great, let's lock that in."
        fix, _, swap = correction.user_edit(line, "Great, let's lock that in now.", line, [])
        self.assertEqual((fix.from_, fix.to, swap), ("in", "in now", False))
        self.assertEqual(apply([fix], line)[0], "Great, let's lock that in now.")
        # A word added at the start.
        fix, _, swap = correction.user_edit(line, "OK Great, let's lock that in.", line, [])
        self.assertEqual((fix.from_, fix.to, swap), ("Great", "OK Great", False))
        # A word that appears twice: grown until the span is unique.
        line = "in the room in the hall"
        fix = correction.user_edit(line, "in the room inside the hall", line, [])[0]
        self.assertEqual(apply([fix], line)[0], "in the room inside the hall")
        # Chinese: an inserted word takes its neighbour.
        line = "好的我来看一下"
        fix, _, swap = correction.user_edit(line, "好的OK我来看一下", line, [])
        self.assertEqual(apply([fix], line)[0], "好的OK我来看一下")
        self.assertFalse(swap)
        # A real swap is still a swap.
        self.assertTrue(correction.user_edit("我木娜找了", "我Monad找了", "我木娜找了", [])[2])


class Vocab(Base):
    """The Mac's VocabularyTests."""

    def test_import_lines_with_heard_forms(self):
        v = Vocabulary(None)
        r = v.import_text("Uniswap V3\nMorpho = 莫拉、莫法\n\n" + "长" * 41 + "\n巡检=寻检,巡练")
        self.assertEqual((r.added, r.updated, r.skipped), (3, 0, [4]))
        self.assertTrue(v.knows("莫法", "morpho"))
        self.assertEqual(next(t for t in v.terms if t.word == "巡检").heard, ["寻检", "巡练"])

    def test_same_word_whatever_width_or_case(self):
        v = Vocabulary(None)
        v.import_text("Aave")
        r = v.import_text("ＡＡＶＥ = 阿韦")
        self.assertEqual((r.updated, r.added), (1, 0))
        self.assertEqual(len(v.terms), 1)
        self.assertTrue(v.knows("阿韦", "Aave"))

    def test_a_yes_never_teaches_a_translation(self):
        v = Vocabulary(None)
        v.confirm("平台", "platform")
        self.assertEqual(v.terms, [])
        v.confirm("平台", "platform", source="user")
        self.assertTrue(v.knows("平台", "platform"))

    def test_confirm_and_forget(self):
        v = Vocabulary(None)
        v.confirm("开布特", "Curve")
        self.assertEqual(v.terms, [Term("Curve", ["开布特"], "live")])
        v.forget("开布特", "Curve")
        self.assertFalse(v.knows("开布特", "Curve"))

    def test_edits_that_arent_a_word_for_a_word_teach_nothing(self):
        v = Vocabulary(None)
        v.confirm("持。", "讲。")
        self.assertTrue(v.knows("持", "讲"))
        v.confirm("我来", "OK我来", source="user")
        v.confirm("然后，", "然后")
        self.assertEqual([t.word for t in v.terms], ["讲"])
        v.confirm("木娜", "Monad", source="user")
        v.confirm("Uni斯图 V三", "Uniswap V3")
        self.assertTrue(v.knows("木娜", "Monad") and v.knows("Uni斯图 V三", "Uniswap V3"))

    def test_prompt_puts_recent_first(self):
        v = Vocabulary(None)
        v.import_text("A\nB = b")
        v.used("B", at=datetime.fromtimestamp(100, timezone.utc))
        self.assertEqual(v.prompt_lines(), ["B (heard as b)", "A"])

    def test_saves_and_loads_as_the_mac_writes_it(self):
        path = os.path.join(self.home, "vocabulary.json")
        v = Vocabulary(path)
        v.import_text("Morpho = 莫拉\nA/B")
        v.used("Morpho", at=datetime(2026, 11, 7, 7, 8, 1, tzinfo=timezone.utc))
        self.assertTrue(Vocabulary(path).knows("莫拉", "Morpho"))
        with open(path, encoding="utf-8") as f:
            text = f.read()
        self.assertTrue(text.startswith('[\n  {\n    "fixes" : 1,\n    "heard" : [\n      "莫拉"\n    ],\n    "source" : "user",\n'
                                        '    "used" : "2026-11-07T07:08:01Z",\n    "word" : "Morpho"\n  },'))
        self.assertIn('"word" : "A/B"', text)  # slashes unescaped, as the Mac's encoder writes them
        self.assertIn('"heard" : [\n\n    ]', text)

    def test_reads_the_macs_file(self):
        mac = ('[\n  {\n    "fixes" : 2,\n    "heard" : [\n      "Un450P三",\n      "Uniswet V三"\n    ],\n    "source" : "user",\n'
               '    "used" : "2026-11-07T07:08:01Z",\n    "word" : "Uniswap V3"\n  }\n]')
        path = os.path.join(self.home, "vocabulary.json")
        with open(path, "w", encoding="utf-8") as f:
            f.write(mac)
        v = Vocabulary(path)
        self.assertEqual(v.terms[0].fixes, 2)
        self.assertTrue(v.knows("Uniswet V三", "Uniswap V3"))
        v._save()
        with open(path, encoding="utf-8") as f:
            self.assertEqual(f.read(), mac)

    def test_rename_keeps_heard_forms_and_merges(self):
        v = Vocabulary(None)
        v.import_text("Morfo = 莫拉\nMorpho = 莫法")
        v.rename("Morfo", "Morpho")
        self.assertEqual(len(v.terms), 1)
        self.assertTrue(v.knows("莫拉", "Morpho") and v.knows("莫法", "Morpho"))

    def test_owners_and_preview(self):
        v = Vocabulary(None)
        v.import_text("Morpho = 莫拉")
        self.assertEqual(v.owners("莫拉", "Mora"), ["Morpho"])
        self.assertEqual(v.owners("莫拉", "Morpho"), [])
        r = v.preview("Morpho = 莫法\nPendle\n" + "长" * 41)
        self.assertEqual((r.added, r.updated, r.skipped), (1, 1, [3]))
        self.assertEqual(len(v.terms), 1)


class Live(Base):
    """The Mac's LiveFixesTests: who wins on a line, the user's decisions, then the word list, then the
    recheck, then the first guess."""

    def setup(self, texts):
        store = session_store.SessionStore()
        s = store.begin()
        for i, t in enumerate(texts):
            store.append(s.id, TranscriptLine(id="l%d" % i, t=float(i), src=t, srcLang="zh-CN", dstLang="en"))
        settings = AppSettings(fixMisheard=True, askNames=True)
        return LiveFixes(store, Vocabulary(None), settings), store, s.id

    def test_recheck_takes_back_a_guess_but_keeps_the_users_yes(self):
        fx, store, sid = self.setup(["最近那个开布特提了，这个是跑好的测试"])
        text = store.line(sid, "l0").src
        fx.received(text, [Edit("开布特", "Curve", 0.9), Edit("跑好的", "跑跑的", 0.9)])
        self.assertIn("跑跑的", store.line(sid, "l0").shown)
        fx.answer(fx.pending(sid)[0][1], True, sid)
        self.assertEqual(store.line(sid, "l0").shown, "最近那个Curve提了，这个是跑跑的测试")
        fx.received(text, [])
        self.assertEqual(store.line(sid, "l0").shown, "最近那个Curve提了，这个是跑好的测试")

    def test_confirmed_heard_forms_apply_without_the_service(self):
        fx, store, sid = self.setup(["扩展到这个莫拉的链", "单个的拉不改"])
        fx.vocabulary.confirm("莫拉", "Morpho")
        fx.apply_known("l0", sid)
        fx.apply_known("l1", sid)
        self.assertEqual(store.line(sid, "l0").shown, "扩展到这个Morpho的链")
        self.assertIsNone(store.line(sid, "l1").fixes)

    def test_edit_everywhere_teaches_the_list_and_undo_puts_it_back(self):
        fx, store, sid = self.setup(["我木娜找了一个", "木娜那边也有", "别的"])
        self.assertEqual(fx.same_heard("l0", sid, "我Monad找了一个")[1], 2)
        self.assertEqual(fx.edit("l0", sid, "我Monad找了一个", everywhere=True, remember=True), 2)
        self.assertEqual(store.line(sid, "l1").shown, "Monad那边也有")
        self.assertTrue(fx.vocabulary.knows("木娜", "Monad"))
        # A later pass can't override what the user wrote.
        fx.received(store.line(sid, "l1").src, [Edit("木娜", "Mona", 0.95)])
        self.assertEqual(store.line(sid, "l1").shown, "Monad那边也有")
        fx.undo()
        self.assertEqual(store.line(sid, "l0").shown, "我木娜找了一个")
        self.assertFalse(fx.vocabulary.knows("木娜", "Monad"))

    def test_edit_that_adds_words_around_is_applied_but_not_learned(self):
        fx, store, sid = self.setup(["我来说一下", "别的"])
        fx.edit("l0", sid, "OK我来说一下", everywhere=True, remember=True)
        self.assertEqual(store.line(sid, "l0").shown, "OK我来说一下")
        self.assertEqual(fx.vocabulary.terms, [])
        self.assertNotIn("记进词表", fx.toast_text())

    def test_added_word_is_never_offered_for_the_whole_meeting(self):
        fx, store, sid = self.setup(["Great, let's lock that in.", "We are in.", "Fine."])
        self.assertEqual(fx.same_heard("l0", sid, "Great, let's lock that in now.")[1:], (1, False))
        self.assertEqual(fx.edit("l0", sid, "Great, let's lock that in now.", everywhere=True, remember=True), 1)
        self.assertEqual(store.line(sid, "l0").shown, "Great, let's lock that in now.")
        self.assertEqual(store.line(sid, "l1").shown, "We are in.")
        self.assertEqual(store.line(sid, "l2").shown, "Fine.")
        self.assertEqual(fx.vocabulary.terms, [])
        self.assertEqual(fx.toast_text(), "已改 1 处：in → in now")
        fx.revert(store.line(sid, "l0").fixes[-1], "l0", sid)
        self.assertEqual(fx.toast_text(), "已改回 in，这场不再改")

    def test_edit_revert_edit_revert_goes_back(self):
        fx, store, sid = self.setup(["Great, let's lock that in.", "Design signs off by Friday."])
        for _ in range(2):
            fx.edit("l0", sid, "Great, let's lock that in now.", everywhere=True, remember=True)
            self.assertEqual(store.line(sid, "l0").shown, "Great, let's lock that in now.")
            f = next(f for f in store.line(sid, "l0").fixes if f.applied)
            fx.revert(f, "l0", sid)
            self.assertEqual(store.line(sid, "l0").shown, "Great, let's lock that in.")
        self.assertEqual(len(store.line(sid, "l0").fixes), 1)
        self.assertIsNone(store.line(sid, "l1").fixes)

    def test_one_off_edit_does_not_teach_the_list(self):
        fx, store, sid = self.setup(["我木娜找了一个", "木娜那边也有"])
        fx.edit("l0", sid, "我Monad找了一个", everywhere=False, remember=True)
        self.assertEqual(store.line(sid, "l1").shown, "木娜那边也有")
        self.assertEqual(fx.vocabulary.terms, [])

    def test_later_takes_it_off_the_card_but_keeps_it_waiting(self):
        fx, store, sid = self.setup(["最近那个开布特提了"])
        fx.received("最近那个开布特提了", [Edit("开布特", "Curve", 0.9)])
        a = fx.asking(sid)
        fx.later(a[1], sid)
        self.assertIsNone(fx.asking(sid))
        self.assertEqual(len(fx.pending(sid)), 1)
        fx.undo()
        self.assertIsNotNone(fx.asking(sid))

    def test_revert_stays_reverted_through_the_recheck(self):
        fx, store, sid = self.setup(["但质压这种"])
        fx.received("但质压这种", [Edit("质压", "质押", 0.9)])
        f = store.line(sid, "l0").fixes[0]
        fx.revert(f, "l0", sid)
        fx.received("但质压这种", [Edit("质压", "质押", 0.9)])
        self.assertEqual(store.line(sid, "l0").shown, "但质压这种")

    def test_yes_fixes_the_rest_of_the_meeting_at_once(self):
        fx, store, sid = self.setup(["最近那个开布特提了", "开布特那边也说了"])
        fx.received("最近那个开布特提了", [Edit("开布特", "Curve", 0.9)])
        fx.answer(fx.pending(sid)[0][1], True, sid)
        self.assertEqual(store.line(sid, "l1").shown, "Curve那边也说了")
        fx.undo()
        self.assertEqual(store.line(sid, "l1").shown, "开布特那边也说了")

    def test_toast_says_what_was_done(self):
        fx, store, sid = self.setup(["但质压这种"])
        fx.received("但质压这种", [Edit("质压", "质押", 0.9)])
        fx.revert(store.line(sid, "l0").fixes[0], "l0", sid)
        self.assertEqual(fx.toast_text(), "已改回 质压，这场不再改")
        self.assertTrue(fx.can_undo)


class Request(Base):
    """The translation request with fixes: the Mac's prompt word for word, no JSON mode, and a reply
    that isn't the JSON asked for falls through like a failed one."""

    def test_prompt_and_reply(self):
        from test_core import Fake, client, reply
        bodies = []

        def respond(body):
            bodies.append(body)
            if "translate_a" in body or not body:
                return reply("")
            return reply('{"translation": "Staking.", "fixes": [{"from": "质压", "to": "质押", "confidence": 0.9}]}')
        fake = Fake(respond)
        t = Translator(client(fake))
        got = []
        t.fix_context = lambda text: FixContext(["Morpho (heard as 莫拉)"], topic="周会", recent=["上一句"])
        t.on_fixes = lambda text, edits: got.append((text, edits))
        self.assertEqual(t.fix("质压。", "zh-CN", "en"), "Staking.")
        self.assertEqual(got, [("质压。", [Edit("质压", "质押", 0.9)])])
        system = jsonfmt.parse(bodies[0])["messages"][0]["content"]
        self.assertTrue(system.startswith("You translate live meeting subtitles from Simplified Chinese into English, and point out"))
        self.assertIn('Reply with only this JSON object, starting with {, no analysis: {"translation": "...", "fixes": '
                      '[{"from": "exact words from the subtitle", "to": "what was said", "confidence": 0.0-1.0}]}\nMeeting: 周会\n'
                      "The user's word list (spellings to use): Morpho (heard as 莫拉)\nLines just before:\n上一句\nSubtitle: 质压。", system)
        self.assertNotIn("response_format", bodies[0])
        self.assertEqual(jsonfmt.parse(bodies[0])["messages"][1]["content"], "JSON only.")

    def test_not_json_is_no_translation(self):
        from test_core import Fake, client, reply
        t = Translator(client(Fake(lambda body: reply("Let me analyze this subtitle first."))))
        t.fix_context = lambda text: FixContext([])
        self.assertIsNone(t.fix("质压。", "zh-CN", "en"))


if __name__ == "__main__":
    unittest.main()

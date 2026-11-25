"""The search in a meeting's lines, shared by the notes window and the records window (the Mac's
TranscriptSearchTests)."""
from __future__ import annotations

import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

from cicada.core import transcript_search as ts  # noqa: E402
from cicada.core.models import NoteTerm, TranscriptLine  # noqa: E402


def line(id_, src, dst=None):
    return TranscriptLine(id=id_, t=0, speaker="them", src=src, dst=dst, srcLang="zh-CN", dstLang="en")


class TranscriptSearchTests(unittest.TestCase):
    def test_a_name_also_finds_how_it_was_misheard(self):
        notes = [NoteTerm(name="江充", note="", heard=["江松"]), NoteTerm(name="Ling", note="", heard=[])]
        self.assertEqual(ts.terms("江充", notes), ["江充", "江松"])
        # Searching the misheard form finds the right one too; an unrelated term stays out.
        self.assertEqual(ts.terms(" 江松 ", notes), ["江松", "江充"])
        self.assertEqual(ts.terms("  ", notes), [])
        # A query inside a name, and a name inside the query, both bring the forms in, case aside.
        self.assertEqual(ts.terms("ling", notes), ["ling", "Ling"])
        self.assertEqual(ts.terms("问江充吧", notes), ["问江充吧", "江充", "江松"])

    def test_matches_look_in_both_languages_in_order(self):
        lines = [line("a", "我们看一下预算"), line("b", "下周再说", "the budget next week"), line("c", "好的")]
        self.assertEqual(ts.matches(lines, ["预算"]), ["a"])
        self.assertEqual(ts.matches(lines, ["BUDGET"]), ["b"])
        self.assertEqual(ts.matches(lines, ["预算", "budget"]), ["a", "b"])
        self.assertEqual(ts.matches(lines, []), [])

    def test_a_misheard_name_is_found_in_the_meeting(self):
        notes = [NoteTerm(name="江充", note="", heard=["江松"])]
        lines = [line("a", "江松说了"), line("b", "没有"), line("c", "问江充")]
        self.assertEqual(ts.matches(lines, ts.terms("江充", notes)), ["a", "c"])

    def test_every_occurrence_is_marked(self):
        self.assertEqual(ts.spans("Budget, budget, done", ["budget"]), [(0, 6), (8, 14)])
        # Overlapping terms mark one stretch.
        self.assertEqual(ts.spans("江充江松", ["江充", "充江"]), [(0, 3)])
        self.assertEqual(ts.spans("nothing", ["budget"]), [])


if __name__ == "__main__":
    unittest.main()

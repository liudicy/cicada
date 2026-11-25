import Foundation
import Testing
@testable import Cicada

@Suite struct TranscriptSearchTests {
    private func line(_ id: String, _ src: String, _ dst: String? = nil) -> TranscriptLine {
        TranscriptLine(id: id, t: 0, speaker: "them", src: src, dst: dst, srcLang: "zh-CN", dstLang: "en")
    }

    @Test func aNameAlsoFindsHowItWasMisheard() {
        let notes = [NoteTerm(name: "江充", note: "", heard: ["江松"]), NoteTerm(name: "Ling", note: "", heard: [])]
        #expect(TranscriptSearch.terms("江充", notes: notes) == ["江充", "江松"])
        // Searching the misheard form finds the right one too; an unrelated term stays out.
        #expect(TranscriptSearch.terms(" 江松 ", notes: notes) == ["江松", "江充"])
        #expect(TranscriptSearch.terms("  ", notes: notes).isEmpty)
    }

    @Test func matchesLookInBothLanguagesInOrder() {
        let lines = [line("a", "我们看一下预算"), line("b", "下周再说", "the budget next week"), line("c", "好的")]
        #expect(TranscriptSearch.matches(lines, ["预算"]) == ["a"])
        #expect(TranscriptSearch.matches(lines, ["BUDGET"]) == ["b"])
        #expect(TranscriptSearch.matches(lines, ["预算", "budget"]) == ["a", "b"])
        #expect(TranscriptSearch.matches(lines, []).isEmpty)
    }

    @Test func everyOccurrenceIsMarked() {
        let a = TranscriptSearch.highlighted(AttributedString("Budget, budget, done"), ["budget"], current: false)
        let marked = a.runs.filter { $0.backgroundColor != nil }.map { String(a[$0.range].characters) }
        #expect(marked == ["Budget", "budget"])
    }
}

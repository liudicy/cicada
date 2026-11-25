// 会议记录's search: the Mac's TranscriptSearchTests, plus where the marks go.
package cicada.cli

import cicada.*

object SearchTests {
    val tests: List<Pair<String, () -> Unit>> = listOf(
        "aNameAlsoFindsHowItWasMisheard" to ::aNameAlsoFindsHowItWasMisheard,
        "matchesLookInBothLanguagesInOrder" to ::matchesLookInBothLanguagesInOrder,
        "everyOccurrenceIsMarked" to ::everyOccurrenceIsMarked,
    )

    private fun line(id: String, src: String, dst: String? = null) = TranscriptLine(id = id, src = src, dst = dst, srcLang = "zh-CN", dstLang = "en")
    private fun equal(want: Any?, got: Any?, what: String) { if (want != got) throw AssertionError("$what: want $want, got $got") }

    private fun aNameAlsoFindsHowItWasMisheard() {
        val notes = listOf(NoteTerm("江充", "", mutableListOf("江松")), NoteTerm("Ling", "", mutableListOf()))
        equal(listOf("江充", "江松"), TranscriptSearch.terms("江充", notes), "name")
        // Searching the misheard form finds the right one too; an unrelated term stays out.
        equal(listOf("江松", "江充"), TranscriptSearch.terms(" 江松 ", notes), "misheard")
        equal(emptyList<String>(), TranscriptSearch.terms("  ", notes), "blank")
        equal(listOf("ling", "Ling"), TranscriptSearch.terms("ling", notes), "case")
    }

    private fun matchesLookInBothLanguagesInOrder() {
        val lines = listOf(line("a", "我们看一下预算"), line("b", "下周再说", "the budget next week"), line("c", "好的"))
        equal(listOf("a"), TranscriptSearch.matches(lines, listOf("预算")), "original")
        equal(listOf("b"), TranscriptSearch.matches(lines, listOf("BUDGET")), "translation")
        equal(listOf("a", "b"), TranscriptSearch.matches(lines, listOf("预算", "budget")), "both")
        equal(emptyList<String>(), TranscriptSearch.matches(lines, emptyList()), "none")
    }

    private fun everyOccurrenceIsMarked() {
        val text = "Budget, budget, done"
        equal(listOf("Budget", "budget"), TranscriptSearch.ranges(text, listOf("budget")).map { text.substring(it) }, "marks")
        // Terms that overlap mark the text once.
        equal(listOf(0..5, 8..13), TranscriptSearch.ranges(text, listOf("budget", "udge")), "overlap")
        equal(emptyList<IntRange>(), TranscriptSearch.ranges(text, listOf("")), "empty term")
    }
}

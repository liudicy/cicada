// 改正听错的词: the Mac's CorrectionTests, VocabularyTests and LiveFixesTests (cases from a
// 21-minute meeting recording), and records with fixes read and written as the Mac does.
package cicada.cli

import cicada.*

object FixTests {
    val tests: List<Pair<String, () -> Unit>> = listOf(
        "fixesReadAndWrittenLikeTheMac" to ::recordWithFixes,
        "editsThatArentAWordForAWordTeachNothing" to ::editsThatArentAWordForAWordTeachNothing,
        "editAroundTheHeardWordsFixesTheLineButTeachesNothing" to ::editAroundTheHeardWordsFixesTheLineButTeachesNothing,
        "yesFixesTheRestOfTheMeetingHeardTheSameWayAtOnce" to ::yesFixesTheRestOfTheMeetingHeardTheSameWayAtOnce,
        "recordFormatUnchangedWithoutFixes" to ::recordFormatUnchangedWithoutFixes,
        "exportsShowTheFixedText" to ::exportsShowTheFixedText,
        "applyReplacesAndMarks" to ::applyReplacesAndMarks,
        "applyKeepsEarlierMarksWhenLaterFixesShift" to ::applyKeepsEarlierMarks,
        "fixWhoseWordsWentAwayIsSkipped" to ::fixWhoseWordsWentAwayIsSkipped,
        "soundAlikeChineseIsApplied" to ::soundAlikeChineseIsApplied,
        "confidentButUnlikeSoundIsDropped" to ::confidentButUnlikeSoundIsDropped,
        "lowConfidenceIsDropped" to ::lowConfidenceIsDropped,
        "spellingFixNeedsHighConfidence" to ::spellingFixNeedsHighConfidence,
        "newNamesAreAsked" to ::newNamesAreAsked,
        "learnedWordsStayWhole" to ::learnedWordsStayWhole,
        "translationsAreNotAsked" to ::translationsAreNotAsked,
        "confirmedHeardFormIsApplied" to ::confirmedHeardFormIsApplied,
        "rejectedIsDropped" to ::rejectedIsDropped,
        "coreDropsSharedEnds" to ::coreDropsSharedEnds,
        "parseReply" to ::parseReply,
        "mergeKeepsRefusals" to ::mergeKeepsRefusals,
        "recheckTakesBackWhatItNoLongerProposesButNotTheUsers" to ::recheckTakesBack,
        "userEditOnTopOfAFix" to ::userEditOnTopOfAFix,
        "labelNamesAnAddedWordWhole" to ::labelNamesAnAddedWordWhole,
        "droppedWordKeepsBothSidesOfTheFix" to ::droppedWordKeepsBothSidesOfTheFix,
        "editRevertEditRevertGoesBack" to ::editRevertEditRevertGoesBack,
        "addedWordStaysOnItsLineAndNeverMatchesPunctuation" to ::addedWordStaysOnItsLineAndNeverMatchesPunctuation,
        "vocabImportLinesWithHeardForms" to ::importLinesWithHeardForms,
        "vocabSameWordWhateverWidthOrCase" to ::sameWordWhateverWidthOrCase,
        "vocabAYesNeverTeachesATranslation" to ::aYesNeverTeachesATranslation,
        "vocabConfirmAndForget" to ::confirmAndForget,
        "vocabPromptPutsRecentFirst" to ::promptPutsRecentFirst,
        "vocabSavesAndLoads" to ::savesAndLoads,
        "vocabRenameKeepsHeardFormsAndMerges" to ::renameKeepsHeardFormsAndMerges,
        "vocabOwnersAndPreview" to ::ownersAndPreview,
        "fixesRecheckTakesBackAGuessButKeepsTheUsersYes" to ::recheckTakesBackAGuessButKeepsTheUsersYes,
        "fixesConfirmedHeardFormsApplyWithoutTheService" to ::confirmedHeardFormsApplyWithoutTheService,
        "fixesEditEverywhereTeachesTheListAndUndoPutsItBack" to ::editEverywhereTeachesTheListAndUndoPutsItBack,
        "fixesOneOffEditDoesNotTeachTheList" to ::oneOffEditDoesNotTeachTheList,
        "fixesLaterTakesItOffTheCardButKeepsItWaiting" to ::laterTakesItOffTheCardButKeepsItWaiting,
        "fixesRevertStaysRevertedThroughTheRecheck" to ::revertStaysRevertedThroughTheRecheck,
        "fixesRideOnTheSentenceTranslation" to ::fixesRideOnTheSentenceTranslation,
        "aLineMingTranslatedIsFixedByOneMoreRequest" to ::aLineMingTranslatedIsFixed,
    )

    /// The Mac's own transform for each character (generated with CFStringTransform, as
    /// Correction.swift reads it); the phone's ICU "Han-Latin; Latin-ASCII" gives the same syllables.
    private val table: Map<Char, String> by lazy {
        FixTests::class.java.getResourceAsStream("/pinyin.tsv")!!.bufferedReader().readLines()
            .mapNotNull { l -> l.split('\t').takeIf { it.size == 2 && it[0].length == 1 }?.let { it[0][0] to it[1] } }.toMap()
    }

    fun usePinyinTable() { Correction.pinyinOf = { table[it] ?: "" } }

    private fun check(ok: Boolean, what: String) { if (!ok) throw AssertionError(what) }
    private fun <T> equal(expected: T, actual: T, what: String) { if (expected != actual) throw AssertionError("$what: expected «$expected», got «$actual»") }

    // MARK: Records

    /// As the Mac writes a line with fixes (JSONEncoder, sorted keys, nil left out).
    val MAC_WITH_FIXES = """
{
  "endedAt" : "2026-11-07T08:24:12Z",
  "hasAudio" : false,
  "id" : "20261107-031639",
  "lines" : [
    {
      "dst" : "I explained Morpho, and Curve.",
      "dstLang" : "en",
      "fixes" : [
        {
          "from" : "莫拉",
          "to" : "Morpho",
          "user" : true
        },
        {
          "ask" : true,
          "from" : "开布特",
          "to" : "Curve"
        },
        {
          "from" : "质压",
          "off" : true,
          "to" : "质押"
        }
      ],
      "id" : "h1-1",
      "speaker" : "them",
      "src" : "解释这个莫拉的，质压和开布特",
      "srcLang" : "zh-CN",
      "t" : 2.5
    },
    {
      "dst" : "Fine.",
      "dstLang" : "en",
      "id" : "h2-2",
      "speaker" : "them",
      "src" : "好的。",
      "srcLang" : "zh-CN",
      "t" : 6
    }
  ],
  "startedAt" : "2026-11-07T08:16:39Z",
  "title" : "会议 11月7日 03:16"
}""".trimStart()

    fun recordWithFixes() {
        val s = Session.read(MAC_WITH_FIXES)!!
        val l = s.lines[0]
        equal(3, l.fixes!!.size, "fixes read")
        equal(LineFix("开布特", "Curve", ask = true), l.fixes!![1], "a waiting fix")
        equal("解释这个莫拉的，质压和开布特", l.src, "src stays what was heard")
        equal("解释这个Morpho的，质压和开布特", l.shown, "shown: applied fixes only")
        equal(null, s.lines[1].fixes, "a line without fixes has none")
        equal(MAC_WITH_FIXES, Json.write(s.toJson()), "written back byte for byte")
        // A copy (what the screens read) keeps them, apart from the record's own.
        val c = l.copy(); c.fixes!![0].off = true
        equal(null, l.fixes!![0].off, "copies are deep")
    }

    fun recordFormatUnchangedWithoutFixes() {
        val line = TranscriptLine(id = "1", src = "a", srcLang = "zh", dstLang = "en")
        check(!Json.write(line.toJson()).contains("fixes"), "no fixes key")
        line.fixes = mutableListOf(LineFix("a", "b"))
        val back = TranscriptLine.from(Json.parseObject(Json.write(line.toJson()))!!)
        equal("b", back.shown, "shown")
        equal("a", back.src, "src")
    }

    fun exportsShowTheFixedText() {
        val s = Session.read(MAC_WITH_FIXES)!!
        check(TranscriptExport.markdown(s).contains("解释这个Morpho的，质压和开布特\n> I explained Morpho, and Curve.\n"), "markdown")
        check(TranscriptExport.srt(s).contains("解释这个Morpho的，质压和开布特\nI explained"), "srt")
    }

    fun applyReplacesAndMarks() {
        val fixes = listOf(LineFix("莫拉", "Morpho"), LineFix("质压", "质押"), LineFix("开布特", "Curve", ask = true), LineFix("ropax", "RoPax", off = true))
        val a = Correction.apply(fixes, "解释这个莫拉的，质压和开布特，ropax")
        equal("解释这个Morpho的，质押和开布特，ropax", a.text, "text")
        equal(listOf("Morpho", "质押"), a.marks.map { a.text.substring(it.first, it.last + 1) }, "marks")
    }

    fun applyKeepsEarlierMarks() {
        val a = Correction.apply(listOf(LineFix("质压", "质押"), LineFix("莫拉", "Morpho")), "莫拉说质压")
        equal("Morpho说质押", a.text, "text")
        equal(listOf("Morpho", "质押"), a.marks.map { a.text.substring(it.first, it.last + 1) }, "marks")
    }

    fun fixWhoseWordsWentAwayIsSkipped() {
        equal("解释这个摩托的", Correction.apply(listOf(LineFix("莫拉", "Morpho")), "解释这个摩托的").text, "skipped")
    }

    // MARK: The gate (CorrectionTests.swift)

    private fun verdict(from: String, to: String, c: Double, known: List<Pair<String, String>> = emptyList(),
                        rejected: List<Pair<String, String>> = emptyList()): Correction.Verdict {
        usePinyinTable()
        return Correction.decide(Correction.Edit(from, to, c), known = { a, b -> (a to b) in known }, rejected = { a, b -> (a to b) in rejected })
    }
    private val A = Correction.Verdict.Apply; private val D = Correction.Verdict.Drop; private val Q = Correction.Verdict.Ask

    fun soundAlikeChineseIsApplied() {
        equal(A, verdict("解除质压", "解除质押", 0.9), "质压")
        check(verdict("跳便是", "跳变", 0.9) != A, "a word dropped: not a sound fix")
        equal(A, verdict("两个代笔", "两个代币", 0.9), "代笔")
        equal(A, verdict("管理房", "管理方", 0.9), "管理房")
        equal(A, verdict("追压", "质押", 0.85), "追压")
        // Only the changed part is compared: 花/概 share nothing, though the phrase around them does.
        equal(D, verdict("花了大花", "花了大概", 0.85), "花了大花")
        equal(A, verdict("FFT制押", "FFT质押", 0.9), "FFT制押")
    }

    fun confidentButUnlikeSoundIsDropped() {
        equal(D, verdict("快销", "区块", 0.85), "快销")
        equal(D, verdict("苍蝇", "方向", 0.85), "苍蝇")
        equal(D, verdict("机录", "机会", 0.8), "机录")
    }

    fun lowConfidenceIsDropped() = equal(D, verdict("质压", "质押", 0.5), "low")

    fun spellingFixNeedsHighConfidence() {
        equal(A, verdict("cransfer", "transfer", 0.85), "near spelling")
        equal(D, verdict("cransfer", "transfer", 0.7), "not sure enough")
        equal(D, verdict("bos", "BOS", 0.9), "case only")
    }

    fun newNamesAreAsked() {
        equal(Q, verdict("莫拉", "Morpho", 0.85), "莫拉")
        equal(Q, verdict("开布特", "Curve", 0.8), "开布特")
        equal(Q, verdict("Ero", "Euler", 0.85), "Ero")
        equal(D, verdict("莫纳", "Morpho", 0.7), "莫纳")
    }

    /// A learned "S平 → X平" never reaches into "iOS平台"; on its own it still applies.
    fun learnedWordsStayWhole() {
        equal(null, Correction.word("S平", "iOS平台很好"), "inside iOS")
        equal(null, Correction.word("A工", "DATA工具"), "inside DATA")
        check(Correction.word("S平", "在S平台上") != null, "on its own")
        check(Correction.word("S平", "iOS平台和S平台") != null, "the second one")
        check(Correction.word("莫拉", "解释这个莫拉的") != null, "Chinese")
        equal("iOS平台和X平台", Correction.apply(listOf(LineFix("S平", "X平")), "iOS平台和S平台").text, "apply")
    }

    /// A translation isn't a misheard name: one 对 to "X平台 → X platform" taught 平台 → platform.
    fun translationsAreNotAsked() {
        equal(D, verdict("X平台", "X platform", 0.9), "X平台")
        equal(D, verdict("平台", "platform", 0.95), "平台")
        equal(D, verdict("respons", "responsible", 0.85), "respons")
        equal(Q, verdict("GPT四", "GPT4", 0.85), "GPT四")
        check(Correction.translation("平台", "platform"), "a translation")
        check(!Correction.translation("莫拉", "Morpho"), "a name")
    }

    fun confirmedHeardFormIsApplied() {
        equal(A, verdict("莫拉", "Morpho", 0.5, known = listOf("莫拉" to "Morpho")), "known")
        equal(A, verdict("解释这个莫拉的", "解释这个Morpho的", 0.5, known = listOf("莫拉" to "Morpho")), "known in a phrase")
    }

    fun rejectedIsDropped() {
        equal(D, verdict("质压", "质押", 0.95, rejected = listOf("质压" to "质押")), "rejected")
        equal(D, verdict("莫拉", "Morpho", 0.95, known = listOf("莫拉" to "Morpho"), rejected = listOf("莫拉" to "Morpho")), "rejected beats known")
    }

    fun coreDropsSharedEnds() {
        equal("质压" to "质押", Correction.core("解除质压", "解除质押"), "shared ends")
        equal("Un450P三" to "Uniswap V3", Correction.core("Un450P三", "Uniswap V3"), "a Latin word stays whole")
        equal("莫拉" to "Morpho", Correction.core("解释这个莫拉的", "解释这个Morpho的"), "name")
        equal("cransfer" to "transfer", Correction.core("找了cransfer记录", "找了transfer记录"), "word")
        equal("制押" to "质押", Correction.core("FFT制押", "FFT质押"), "a Chinese change next to a Latin word leaves the word out")
    }

    fun parseReply() {
        val reply = """
        {"translation": "I explained Morpho.", "fixes": [{"from": "莫拉", "to": "Morpho", "confidence": 0.85},
         {"from": "不在原文", "to": "x", "confidence": 0.9}]}
        """
        val p = Correction.parse(reply, "解释这个莫拉的。")
        equal("I explained Morpho.", p?.first, "translation")
        equal(listOf(Correction.Edit("莫拉", "Morpho", 0.85)), p?.second, "edits in the subtitle only")
        equal(null, Correction.parse("I explained Mora.", "x"), "not JSON")
        equal("Hi", Correction.parse("```json\n{\"translation\": \"Hi\"}\n```", "x")?.first, "fenced")
    }

    fun mergeKeepsRefusals() {
        val old = listOf(LineFix("莫拉", "Morpho", off = true), LineFix("质压", "质押"))
        val new = listOf(LineFix("莫拉", "Morpho"), LineFix("寻检", "巡检"))
        equal(listOf(LineFix("莫拉", "Morpho", off = true), LineFix("寻检", "巡检")), Correction.merge(old, new), "merge")
    }

    fun recheckTakesBack() {
        val old = listOf(LineFix("跑好的", "跑跑的"), LineFix("开布特", "Curve", user = true))
        equal(listOf(LineFix("开布特", "Curve", user = true)), Correction.merge(old, emptyList()), "the guess goes, the user's yes stays")
        equal(listOf(LineFix("开布特", "Curve", user = true)), Correction.merge(old, listOf(LineFix("开布特", "Cobalt"))), "nor overridden")
    }

    fun userEditOnTopOfAFix() {
        val fixes = listOf(LineFix("莫纳", "Morpho"))
        val src = "扩展到这个莫纳的 Link"
        val shown = Correction.apply(fixes, src).text
        val e = Correction.userEdit(shown, "扩展到这个Monad的 Link", src, fixes)
        equal(LineFix("Morpho", "Monad", user = true), e?.fix, "fix on the fix")
        equal("莫纳", e?.heard, "heard form")
        equal("扩展到这个Monad的 Link", Correction.apply(fixes + e!!.fix, src).text, "shown")
        equal("木娜", Correction.userEdit("我木娜找了一个", "我在 Monad 找了一个", "我木娜找了一个", emptyList())?.heard, "plain heard word")
        equal(null, Correction.userEdit("a", " a ", "a", emptyList()), "unchanged")
    }

    // MARK: 词表 (VocabularyTests.swift)

    fun importLinesWithHeardForms() {
        val v = Vocabulary(null)
        val r = v.importText("Uniswap V3\nMorpho = 莫拉、莫法\n\n" + "长".repeat(41) + "\n巡检=寻检,巡练")
        equal(Vocabulary.ImportResult(3, 0, mutableListOf(4)), r, "result")
        check(v.knows("莫法", "morpho"), "heard form, any case")
        equal(listOf("寻检", "巡练"), v.terms.first { it.word == "巡检" }.heard, "heard forms")
    }

    fun sameWordWhateverWidthOrCase() {
        val v = Vocabulary(null)
        v.importText("Aave")
        val r = v.importText("ＡＡＶＥ = 阿韦")
        check(r.updated == 1 && r.added == 0, "updated")
        equal(1, v.terms.size, "one word")
        check(v.knows("阿韦", "Aave"), "knows")
    }

    fun editsThatArentAWordForAWordTeachNothing() {
        val v = Vocabulary(null)
        v.confirm("持。", "讲。")
        check(v.knows("持", "讲"), "trimmed of the full stop")
        v.confirm("我来", "OK我来", "user")
        v.confirm("然后，", "然后")
        equal(listOf("讲"), v.terms.map { it.word }, "words added around, or only punctuation, teach nothing")
        v.confirm("木娜", "Monad", "user")
        v.confirm("Uni斯图 V三", "Uniswap V3")
        check(v.knows("木娜", "Monad") && v.knows("Uni斯图 V三", "Uniswap V3"), "a word for a word is learned")
    }

    fun editAroundTheHeardWordsFixesTheLineButTeachesNothing() {
        val t = setup("我来看一下", "我来吧")
        equal(1, t.fx.sameHeard("l0", t.id, "OK我来看一下")?.count, "an added word offers this line only")
        equal(1, t.fx.edit("l0", t.id, "OK我来看一下", everywhere = true, keep = true), "edited")
        equal("OK我来看一下", t.line("l0").shown, "the edit applies")
        equal("我来吧", t.line("l1").shown, "and stays on its line")
        check(t.fx.vocabulary.terms.isEmpty(), "not taught")
        equal("已改 1 处：我 → OK我", t.fx.toastNow()?.text, "the toast shows the span the added word changed")
        val u = setup("lock that in.")
        u.fx.edit("l0", u.id, "lock that in now.", everywhere = true, keep = true)
        equal("已改 1 处：in → in now", u.fx.toastNow()?.text, "an added word at the end")
        val s = setup("我木娜找了")
        s.fx.edit("l0", s.id, "我Monad找了", everywhere = true, keep = true)
        equal("已改 1 处：木娜 → Monad，记进词表", s.fx.toastNow()?.text, "a swap reads as the words swapped")
    }

    fun droppedWordKeepsBothSidesOfTheFix() {
        val line = "Great, let's lock that in now."
        val e = Correction.userEdit(line, "Great, let's lock that in.", line, emptyList())!!
        check(e.fix.from.isNotEmpty() && e.fix.to.isNotEmpty(), "both sides: ${e.fix}")
        equal("Great, let's lock that in.", Correction.apply(listOf(e.fix), line).text, "applied")
        val l = Correction.label(e.fix)
        check(l.first.isNotEmpty() && l.second.isNotEmpty(), "label both sides: $l")
    }

    fun editRevertEditRevertGoesBack() {
        val t = setup("Great, let's lock that in.", "Design signs off by Friday.")
        repeat(2) { i ->
            t.fx.edit("l0", t.id, "Great, let's lock that in now.", everywhere = true, keep = true)
            equal("Great, let's lock that in now.", t.line("l0").shown, "edited, round ${i + 1}")
            t.fx.revert(t.line("l0").fixes!!.first { it.applied }, "l0", t.id)
            equal("Great, let's lock that in.", t.line("l0").shown, "reverted, round ${i + 1}")
        }
        equal(1, t.line("l0").fixes!!.size, "one copy of the fix")
        equal(null, t.line("l1").fixes, "the other line untouched")
    }

    fun labelNamesAnAddedWordWhole() {
        equal("in" to "in now", Correction.label(LineFix("in", "in now", user = true)), "added at the end")
        equal("Great" to "OK Great", Correction.label(LineFix("Great", "OK Great", user = true)), "added at the start")
        equal("质压" to "质押", Correction.label(LineFix("解除质压", "解除质押")), "a swap names the changed words")
        // 改回 says the whole span too.
        val t = setup("lock that in.")
        t.fx.edit("l0", t.id, "lock that in now.", everywhere = false, keep = false)
        t.fx.revert(t.line("l0").fixes!!.first(), "l0", t.id)
        equal("已改回 in，这场不再改", t.fx.toastNow()?.text, "revert toast")
    }

    fun addedWordStaysOnItsLineAndNeverMatchesPunctuation() {
        val line = "Great, let's lock that in."
        // "now" added before the full stop: the fix is the last word, unique in the line, not ".".
        val e = Correction.userEdit(line, "Great, let's lock that in now.", line, emptyList())!!
        equal("in", e.fix.from, "from"); equal("in now", e.fix.to, "to"); equal(false, e.swap, "not a swap")
        equal("Great, let's lock that in now.", Correction.apply(listOf(e.fix), line).text, "applied")
        // A word added at the start.
        val s = Correction.userEdit(line, "OK Great, let's lock that in.", line, emptyList())!!
        equal("Great", s.fix.from, "start from"); equal("OK Great", s.fix.to, "start to"); equal(false, s.swap, "start not a swap")
        equal("OK Great, let's lock that in.", Correction.apply(listOf(s.fix), line).text, "start applied")
        // A word that appears twice: grown until the span is unique.
        val r = "in the room in the hall"
        val t = Correction.userEdit(r, "in the room inside the hall", r, emptyList())!!
        equal("in the room inside the hall", Correction.apply(listOf(t.fix), r).text, "unique span")
        // Chinese: an inserted word takes its neighbour.
        val c = Correction.userEdit("好的我来看一下", "好的OK我来看一下", "好的我来看一下", emptyList())!!
        equal("好的OK我来看一下", Correction.apply(listOf(c.fix), "好的我来看一下").text, "Chinese applied")
        equal(false, c.swap, "Chinese not a swap")
        // A real swap is still a swap.
        equal(true, Correction.userEdit("我木娜找了", "我Monad找了", "我木娜找了", emptyList())?.swap, "swap")
    }

    fun aYesNeverTeachesATranslation() {
        val v = Vocabulary(null)
        v.confirm("平台", "platform")
        check(v.terms.isEmpty(), "a yes teaches no translation")
        v.confirm("平台", "platform", source = "user")
        check(v.knows("平台", "platform"), "the user's own does")
    }

    fun confirmAndForget() {
        val v = Vocabulary(null)
        v.confirm("开布特", "Curve")
        equal(listOf(Vocabulary.Term("Curve", listOf("开布特"), "live")), v.terms, "confirmed")
        v.forget("开布特", "Curve")
        check(!v.knows("开布特", "Curve"), "forgotten")
    }

    fun promptPutsRecentFirst() {
        val v = Vocabulary(null)
        v.importText("A\nB = b")
        v.used("B", java.time.Instant.ofEpochSecond(100))
        equal(listOf("B (heard as b)", "A"), v.promptLines(), "prompt")
    }

    fun savesAndLoads() {
        val f = java.io.File(Paths.root, "vocab-test.json")
        try {
            Vocabulary(f).apply { importText("Morpho = 莫拉"); used("Morpho", java.time.Instant.parse("2026-11-07T08:00:00Z")) }
            val back = Vocabulary(f)
            check(back.knows("莫拉", "Morpho"), "read back")
            equal(java.time.Instant.parse("2026-11-07T08:00:00Z"), back.terms[0].used, "date read back")
            check(f.readText().contains("\"used\" : \"2026-11-07T08:00:00Z\""), "ISO-8601 dates, as on the Mac")
        } finally { f.delete() }
    }

    fun renameKeepsHeardFormsAndMerges() {
        val v = Vocabulary(null)
        v.importText("Morfo = 莫拉\nMorpho = 莫法")
        v.rename("Morfo", "Morpho")
        equal(1, v.terms.size, "merged")
        check(v.knows("莫拉", "Morpho") && v.knows("莫法", "Morpho"), "both heard forms")
    }

    fun ownersAndPreview() {
        val v = Vocabulary(null)
        v.importText("Morpho = 莫拉")
        equal(listOf("Morpho"), v.owners("莫拉", "Mora"), "owner")
        check(v.owners("莫拉", "Morpho").isEmpty(), "not its own")
        equal(Vocabulary.ImportResult(1, 1, mutableListOf(3)), v.preview("Morpho = 莫法\nPendle\n" + "长".repeat(41)), "preview")
        equal(1, v.terms.size, "preview changes nothing")
    }

    // MARK: Who wins on a line (LiveFixesTests.swift)

    private class Setup(val fx: LiveFixes, val store: SessionStore, val id: String) {
        fun line(l: String) = store.line(id, l)!!
    }

    private fun setup(vararg lines: String): Setup {
        usePinyinTable()
        val store = SessionStore(loadNow = false)
        val s = store.begin()
        lines.forEachIndexed { i, t -> store.append(s.id, TranscriptLine(id = "l$i", t = i.toDouble(), src = t, srcLang = "zh-CN", dstLang = "en")) }
        val settings = AppSettings(fixMisheard = true, askNames = true)
        return Setup(LiveFixes(store, Vocabulary(null), settings), store, s.id)
    }

    fun recheckTakesBackAGuessButKeepsTheUsersYes() {
        val t = setup("最近那个开布特提了，这个是跑好的测试")
        val text = t.line("l0").src
        t.fx.received(text, listOf(Correction.Edit("开布特", "Curve", 0.9), Correction.Edit("跑好的", "跑跑的", 0.9)))
        check(t.line("l0").shown.contains("跑跑的"), "sound-alike applied")
        t.fx.answer(t.fx.pending(t.id)[0].fix, true, t.id)
        equal("最近那个Curve提了，这个是跑跑的测试", t.line("l0").shown, "after yes")
        t.fx.received(text, emptyList())
        equal("最近那个Curve提了，这个是跑好的测试", t.line("l0").shown, "the recheck takes back the guess only")
    }

    fun confirmedHeardFormsApplyWithoutTheService() {
        val t = setup("扩展到这个莫拉的链", "单个的拉不改")
        t.fx.vocabulary.confirm("莫拉", "Morpho")
        t.fx.applyKnown("l0", t.id); t.fx.applyKnown("l1", t.id)
        equal("扩展到这个Morpho的链", t.line("l0").shown, "known form")
        equal(null, t.line("l1").fixes, "one character never")
    }

    fun editEverywhereTeachesTheListAndUndoPutsItBack() {
        val t = setup("我木娜找了一个", "木娜那边也有", "别的")
        equal(2, t.fx.sameHeard("l0", t.id, "我Monad找了一个")?.count, "same heard")
        equal(2, t.fx.edit("l0", t.id, "我Monad找了一个", everywhere = true, keep = true), "edited")
        equal("Monad那边也有", t.line("l1").shown, "everywhere")
        check(t.fx.vocabulary.knows("木娜", "Monad"), "taught")
        t.fx.received(t.line("l1").src, listOf(Correction.Edit("木娜", "Mona", 0.95)))
        equal("Monad那边也有", t.line("l1").shown, "a later pass can't override the user")
        t.fx.undo()
        equal("我木娜找了一个", t.line("l0").shown, "undone")
        check(!t.fx.vocabulary.knows("木娜", "Monad"), "list undone")
    }

    fun oneOffEditDoesNotTeachTheList() {
        val t = setup("我木娜找了一个", "木娜那边也有")
        t.fx.edit("l0", t.id, "我Monad找了一个", everywhere = false, keep = true)
        equal("木娜那边也有", t.line("l1").shown, "one line only")
        check(t.fx.vocabulary.terms.isEmpty(), "not taught")
    }

    fun yesFixesTheRestOfTheMeetingHeardTheSameWayAtOnce() {
        val t = setup("最近那个开布特提了", "开布特那边也有", "别的")
        t.fx.received(t.line("l0").src, listOf(Correction.Edit("开布特", "Curve", 0.9)))
        t.fx.answer(t.fx.asking(t.id)!!.fix, true, t.id)
        equal("Curve那边也有", t.line("l1").shown, "the other line follows at once")
        equal(null, t.line("l2").fixes, "a line without it untouched")
        t.fx.undo()
        equal("开布特那边也有", t.line("l1").shown, "undo takes it back too")
        equal("最近那个开布特提了", t.line("l0").shown, "and the asked line")
    }

    fun laterTakesItOffTheCardButKeepsItWaiting() {
        val t = setup("最近那个开布特提了")
        t.fx.received("最近那个开布特提了", listOf(Correction.Edit("开布特", "Curve", 0.9)))
        val a = t.fx.asking(t.id)!!
        t.fx.later(a.fix, t.id)
        equal(null, t.fx.asking(t.id), "off the card")
        equal(1, t.fx.pending(t.id).size, "still waiting")
        t.fx.undo()
        check(t.fx.asking(t.id) != null, "undo puts it back")
    }

    fun revertStaysRevertedThroughTheRecheck() {
        val t = setup("但质压这种")
        t.fx.received("但质压这种", listOf(Correction.Edit("质压", "质押", 0.9)))
        t.fx.revert(t.line("l0").fixes!![0], "l0", t.id)
        t.fx.received("但质压这种", listOf(Correction.Edit("质压", "质押", 0.9)))
        equal("但质压这种", t.line("l0").shown, "stays reverted")
    }

    /// The sentence's translation request carries the word list and the lines before it, and the
    /// fixes in its reply reach the line (Translator → LiveFixes), with no JSON mode.
    fun fixesRideOnTheSentenceTranslation() {
        val t = setup("我们先看这个", "解释这个莫拉的，质压很高")
        t.fx.vocabulary.importText("Morpho = 莫法")
        var sent = ""
        val fake = Tests.Fake { body -> sent = body; Tests.reply("""{"translation": "Explain Morpho; the staking is high.", "fixes": [{"from": "莫拉", "to": "Morpho", "confidence": 0.9}, {"from": "质压", "to": "质押", "confidence": 0.9}]}""") }
        val tr = Translator(Tests.client(fake))
        tr.googleOff = true
        tr.fixContext = { t.fx.context(it) }
        tr.onFixes = { text, edits -> t.fx.received(text, edits) }
        val out = tr.translate("解释这个莫拉的，质压很高", "zh-CN", "en", Translator.Kind.Sentence)
        equal("Explain Morpho; the staking is high.", out, "translation")
        check(sent.contains("The user's word list (spellings to use): Morpho (heard as 莫法)"), "word list sent")
        check(sent.contains("Lines just before:\\n我们先看这个"), "lines before sent")
        check(!sent.contains("response_format"), "no JSON mode")
        equal("解释这个莫拉的，质押很高", t.line("l1").shown, "the sound-alike applied, the name waits")
        equal(1, t.fx.pending(t.id).size, "the name asked about")
    }

    /// The path a real meeting takes: Ming hears and translates a stretch, then (fixing on) the text
    /// model translates the line again with the misheard words pointed out. Its translation replaces
    /// Ming's and its fixes reach the record; with fixing off, no second request.
    fun aLineMingTranslatedIsFixed() {
        usePinyinTable()
        for (on in listOf(true, false)) {
            val texts = java.util.Collections.synchronizedList(mutableListOf<String>())
            val fake = Tests.Fake { body ->
                if (body.contains("Ming-3.0-audio-flash")) Tests.reply("LANG: zh-CN\nORIGINAL: 最近质压率也很高。\nTRANSLATION: The pledge rate is high lately.")
                else if (body.contains("point out words the speech recognizer got wrong")) {
                    texts.add(body)
                    Tests.reply("""{"translation": "The staking rate is high lately.", "fixes": [{"from": "质压率", "to": "质押率", "confidence": 0.9}]}""")
                } else Tests.reply("{}")
            }
            val old = LingClient.spacing
            LingClient.spacing = 0.05
            try {
                val ling = Tests.client(fake)
                val store = SessionStore(loadNow = false)
                val settings = AppSettings(target = "en", fixMisheard = on)
                val tr = Translator(ling)
                val engine = ListenEngine(ling, tr, store, NotesEngine(ling, store), settings)
                val fx = LiveFixes(store, Vocabulary(null), settings)
                engine.fixes = fx
                tr.fixContext = { fx.context(it) }
                tr.onFixes = { text, edits -> fx.received(text, edits) }
                val src = PcmAudioSource({ Tests.concat(Tests.tone(1.2), Tests.silence(1.0)) }, speed = 0.0)
                val ended = java.util.concurrent.CountDownLatch(1)
                src.onEnded = { ended.countDown() }
                engine.start(src, "file")
                ended.await()
                // No wait: stop() itself waits for the line's fixing request.
                engine.stop()
                val l = store.get(engine.sessionId!!)!!.lines.single()
                if (on) {
                    equal(1, texts.size, "one more text request")
                    equal("The staking rate is high lately.", l.dst, "the fixed line's translation replaces Ming's")
                    equal("最近质押率也很高。", l.shown, "the sound-alike fix is in the record")
                    equal("最近质压率也很高。", l.src, "src stays what was heard")
                } else {
                    equal(0, texts.size, "fixing off: no extra request")
                    equal("The pledge rate is high lately.", l.dst, "Ming's translation")
                    equal(null, l.fixes, "no fixes")
                }
            } finally { LingClient.spacing = old }
        }
    }
}

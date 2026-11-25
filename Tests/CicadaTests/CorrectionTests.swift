import Foundation
import Testing
@testable import Cicada

/// Cases from a 21-minute meeting recording (a DeFi team's weekly), labelled by reading the context.
@Suite struct CorrectionTests {
    private func verdict(_ from: String, _ to: String, _ c: Double, known: [(String, String)] = [],
                         rejected: [(String, String)] = []) -> Correction.Verdict {
        Correction.decide(.init(from: from, to: to, confidence: c),
                          known: { a, b in known.contains { $0 == (a, b) } },
                          rejected: { a, b in rejected.contains { $0 == (a, b) } })
    }

    @Test func soundAlikeChineseIsApplied() {
        #expect(verdict("解除质压", "解除质押", 0.9) == .apply)
        #expect(verdict("跳便是", "跳变", 0.9) != .apply)      // a word dropped: not a sound fix
        #expect(verdict("两个代笔", "两个代币", 0.9) == .apply)
        #expect(verdict("管理房", "管理方", 0.9) == .apply)
        #expect(verdict("追压", "质押", 0.85) == .apply)
        // Only the changed part is compared: 花/概 share nothing, though the phrase around them does.
        #expect(verdict("花了大花", "花了大概", 0.85) == .drop)
        #expect(verdict("FFT制押", "FFT质押", 0.9) == .apply)
    }

    @Test func confidentButUnlikeSoundIsDropped() {
        #expect(verdict("快销", "区块", 0.85) == .drop)
        #expect(verdict("苍蝇", "方向", 0.85) == .drop)
        #expect(verdict("机录", "机会", 0.8) == .drop)
    }

    @Test func lowConfidenceIsDropped() {
        #expect(verdict("质压", "质押", 0.5) == .drop)
    }

    @Test func spellingFixNeedsHighConfidence() {
        #expect(verdict("cransfer", "transfer", 0.85) == .apply)
        #expect(verdict("cransfer", "transfer", 0.7) == .drop)
        #expect(verdict("bos", "BOS", 0.9) == .drop)         // case only
    }

    @Test func newNamesAreAsked() {
        #expect(verdict("莫拉", "Morpho", 0.85) == .ask)
        #expect(verdict("开布特", "Curve", 0.8) == .ask)
        #expect(verdict("Ero", "Euler", 0.85) == .ask)
        #expect(verdict("莫纳", "Morpho", 0.7) == .drop)
    }

    /// A learned "S平 → X平" never reaches into "iOS平台"; on its own it still applies.
    @Test func learnedWordsStayWhole() {
        #expect(Correction.word("S平", in: "iOS平台很好") == nil)
        #expect(Correction.word("A工", in: "DATA工具") == nil)
        #expect(Correction.word("S平", in: "在S平台上") != nil)
        #expect(Correction.word("S平", in: "iOS平台和S平台") != nil)
        #expect(Correction.word("莫拉", in: "解释这个莫拉的") != nil)
        #expect(Correction.apply([LineFix(from: "S平", to: "X平")], to: "iOS平台和S平台").text == "iOS平台和X平台")
    }

    /// A translation isn't a misheard name: one 对 to "X平台 → X platform" taught 平台 → platform.
    @Test func translationsAreNotAsked() {
        #expect(verdict("X平台", "X platform", 0.9) == .drop)
        #expect(verdict("平台", "platform", 0.95) == .drop)
        #expect(verdict("respons", "responsible", 0.85) == .drop)
        #expect(verdict("GPT四", "GPT4", 0.85) == .ask)
        #expect(Correction.translation(heard: "平台", word: "platform"))
        #expect(!Correction.translation(heard: "莫拉", word: "Morpho"))
    }

    @Test func confirmedHeardFormIsApplied() {
        #expect(verdict("莫拉", "Morpho", 0.5, known: [("莫拉", "Morpho")]) == .apply)
        #expect(verdict("解释这个莫拉的", "解释这个Morpho的", 0.5, known: [("莫拉", "Morpho")]) == .apply)
    }

    @Test func rejectedIsDropped() {
        #expect(verdict("质压", "质押", 0.95, rejected: [("质压", "质押")]) == .drop)
        #expect(verdict("莫拉", "Morpho", 0.95, known: [("莫拉", "Morpho")], rejected: [("莫拉", "Morpho")]) == .drop)
    }

    @Test func coreDropsSharedEnds() {
        #expect(Correction.core("解除质压", "解除质押") == ("质压", "质押"))
        #expect(Correction.core("Un450P三", "Uniswap V3") == ("Un450P三", "Uniswap V3"))
        #expect(Correction.core("解释这个莫拉的", "解释这个Morpho的") == ("莫拉", "Morpho"))
        #expect(Correction.core("找了cransfer记录", "找了transfer记录") == ("cransfer", "transfer"))
        // A Chinese change next to a Latin word leaves the word out.
        #expect(Correction.core("FFT制押", "FFT质押") == ("制押", "质押"))
        #expect(Correction.core("Un450P三", "Uniswap V3") == ("Un450P三", "Uniswap V3"))
    }

    @Test func applyReplacesAndMarks() {
        let fixes = [LineFix(from: "莫拉", to: "Morpho"), LineFix(from: "质压", to: "质押"),
                     LineFix(from: "开布特", to: "Curve", ask: true), LineFix(from: "ropax", to: "RoPax", off: true)]
        let (text, marks) = Correction.apply(fixes, to: "解释这个莫拉的，质压和开布特，ropax")
        #expect(text == "解释这个Morpho的，质押和开布特，ropax")
        #expect(marks.map { String(text[$0]) } == ["Morpho", "质押"])
    }

    @Test func applyKeepsEarlierMarksWhenLaterFixesShift() {
        let (text, marks) = Correction.apply([LineFix(from: "质压", to: "质押"), LineFix(from: "莫拉", to: "Morpho")],
                                             to: "莫拉说质压")
        #expect(text == "Morpho说质押")
        #expect(marks.map { String(text[$0]) } == ["Morpho", "质押"])
    }

    @Test func fixWhoseWordsWentAwayIsSkipped() {
        // The record recognizer rewrote the line: the fix no longer applies, nothing breaks.
        #expect(Correction.apply([LineFix(from: "莫拉", to: "Morpho")], to: "解释这个摩托的").text == "解释这个摩托的")
    }

    @Test func parseReply() {
        let reply = """
        {"translation": "I explained Morpho.", "fixes": [{"from": "莫拉", "to": "Morpho", "confidence": 0.85},
         {"from": "不在原文", "to": "x", "confidence": 0.9}]}
        """
        let p = Correction.parse(reply, subtitle: "解释这个莫拉的。")
        #expect(p?.translation == "I explained Morpho.")
        #expect(p?.edits == [.init(from: "莫拉", to: "Morpho", confidence: 0.85)])
        #expect(Correction.parse("I explained Mora.", subtitle: "x") == nil)
        #expect(Correction.parse("```json\n{\"translation\": \"Hi\"}\n```", subtitle: "x")?.translation == "Hi")
    }

    @Test func mergeKeepsRefusals() {
        let old = [LineFix(from: "莫拉", to: "Morpho", off: true), LineFix(from: "质压", to: "质押")]
        let new = [LineFix(from: "莫拉", to: "Morpho"), LineFix(from: "寻检", to: "巡检")]
        #expect(Correction.merge(old, new) == [LineFix(from: "莫拉", to: "Morpho", off: true), LineFix(from: "寻检", to: "巡检")])
    }

    @Test func recheckTakesBackWhatItNoLongerProposesButNotTheUsers() {
        let old = [LineFix(from: "跑好的", to: "跑跑的"), LineFix(from: "开布特", to: "Curve", user: true)]
        // The recheck proposes nothing: the model's guess goes, the user's yes stays.
        #expect(Correction.merge(old, []) == [LineFix(from: "开布特", to: "Curve", user: true)])
        // Nor can it override the user's word with another.
        #expect(Correction.merge(old, [LineFix(from: "开布特", to: "Cobalt")]) == [LineFix(from: "开布特", to: "Curve", user: true)])
    }

    @Test func userEditOnTopOfAFix() {
        let fixes = [LineFix(from: "莫纳", to: "Morpho")]
        let src = "扩展到这个莫纳的 Link"
        let shown = Correction.apply(fixes, to: src).text
        let e = Correction.userEdit(shown: shown, edited: "扩展到这个Monad的 Link", src: src, fixes: fixes)
        #expect(e?.fix == LineFix(from: "Morpho", to: "Monad", user: true))
        #expect(e?.heard == "莫纳")
        #expect(Correction.apply(fixes + [e!.fix], to: src).text == "扩展到这个Monad的 Link")
        // A plain heard word.
        let p = Correction.userEdit(shown: "我木娜找了一个", edited: "我在 Monad 找了一个", src: "我木娜找了一个", fixes: [])
        #expect(p?.heard == "木娜")
        #expect(Correction.userEdit(shown: "a", edited: " a ", src: "a", fixes: []) == nil)
    }

    @Test func recordFormatUnchangedWithoutFixes() throws {
        let line = TranscriptLine(id: "1", t: 0, speaker: "them", src: "a", dst: nil, srcLang: "zh", dstLang: "en")
        let json = String(data: try JSONEncoder().encode(line), encoding: .utf8)!
        #expect(!json.contains("fixes"))
        var fixed = line
        fixed.fixes = [LineFix(from: "a", to: "b")]
        let back = try JSONDecoder().decode(TranscriptLine.self, from: JSONEncoder().encode(fixed))
        #expect(back.shown == "b")
        #expect(back.src == "a")
    }

    @Test func addedWordStaysOnItsLineAndNeverMatchesPunctuation() {
        // "now" added before the full stop: the fix is the last word, unique in the line, not ".".
        let e = Correction.userEdit(shown: "Great, let's lock that in.", edited: "Great, let's lock that in now.", src: "Great, let's lock that in.", fixes: [])
        #expect(e?.fix.from == "in")
        #expect(e?.fix.to == "in now")
        #expect(e?.swap == false)
        #expect(Correction.apply([e!.fix], to: "Great, let's lock that in.").text == "Great, let's lock that in now.")
        // A word added at the start.
        let s = Correction.userEdit(shown: "Great, let's lock that in.", edited: "OK Great, let's lock that in.", src: "Great, let's lock that in.", fixes: [])
        #expect(s?.fix.from == "Great")
        #expect(s?.fix.to == "OK Great")
        #expect(s?.swap == false)
        // A word that appears twice: grown until the span is unique.
        let t = Correction.userEdit(shown: "in the room in the hall", edited: "in the room inside the hall", src: "in the room in the hall", fixes: [])
        #expect(Correction.apply([t!.fix], to: "in the room in the hall").text == "in the room inside the hall")
        // Chinese: an inserted word takes its neighbour.
        let c = Correction.userEdit(shown: "好的我来看一下", edited: "好的OK我来看一下", src: "好的我来看一下", fixes: [])
        #expect(c.map { Correction.apply([$0.fix], to: "好的我来看一下").text } == "好的OK我来看一下")
        #expect(c?.swap == false)
        // A real swap is still a swap.
        #expect(Correction.userEdit(shown: "我木娜找了", edited: "我Monad找了", src: "我木娜找了", fixes: [])?.swap == true)
    }

    @Test func labelNamesAnAddedWordWhole() {
        #expect(Correction.label(LineFix(from: "in", to: "in now", user: true)) == ("in", "in now"))
        #expect(Correction.label(LineFix(from: "Great", to: "OK Great", user: true)) == ("Great", "OK Great"))
        #expect(Correction.label(LineFix(from: "解除质压", to: "解除质押")) == ("质压", "质押"))
    }

    @Test func droppedWordKeepsBothSidesOfTheFix() {
        let e = Correction.userEdit(shown: "Great, let's lock that in now.", edited: "Great, let's lock that in.", src: "Great, let's lock that in now.", fixes: [])
        #expect(e != nil && !e!.fix.from.isEmpty && !e!.fix.to.isEmpty)
        #expect(Correction.apply([e!.fix], to: "Great, let's lock that in now.").text == "Great, let's lock that in.")
        let l = Correction.label(e!.fix)
        #expect(!l.from.isEmpty && !l.to.isEmpty)
    }
}

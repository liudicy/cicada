import Foundation
import Testing
@testable import LiveSubs

/// Lines from a recorded Bloomberg interview (session 20261103-000911).
@Suite struct HeardTextTests {
    @Test func cleanStrayMarks() {
        #expect(HeardText.clean("in..........") == "in…")
        #expect(HeardText.clean(", , that") == "that")
        #expect(HeardText.clean(",...... has translated at its end into infrastructure...") == "has translated at its end into infrastructure…")
        #expect(HeardText.clean(". , that is causing a product twice.") == "that is causing a product twice.")
        #expect(HeardText.clean("that.......... in increased production") == "that… in increased production")
        #expect(HeardText.clean("would.. would be oversupplied.") == "would… would be oversupplied.")
        #expect(HeardText.clean(", and......... in alternative infrastructure routes that let's.................") ==
                "and… in alternative infrastructure routes that let's…")
        #expect(HeardText.clean("whether it's in the UALE, , Saudi Arab, or the wider.") == "whether it's in the UALE, Saudi Arab, or the wider.")
        #expect(HeardText.clean(",, and there should be more diversified.") == "and there should be more diversified.")
        #expect(HeardText.clean(", you... lucrative") == "you… lucrative")
        #expect(HeardText.clean("of people..") == "of people…")
        // What is fine stays as it is.
        #expect(HeardText.clean("to over 1.4 million a day.") == "to over 1.4 million a day.")
        #expect(HeardText.clean("The U.S. said no.") == "The U.S. said no.")
        #expect(HeardText.clean("，，我们周四上线。。。") == "我们周四上线…")
        #expect(HeardText.clean("........") == "")
    }

    @Test func keepTheDraftWhenTheFinalDroppedPhrases() {
        // Issue #1, from a 200 wpm run: the final pass lost "the support team asked", "numbers", "foxtrot 6".
        let final = "for a new escalation process for enterprise customers, and Echo 5 Finance, needs the budget. for next year by the end. of this month. in."
        let draft = "to for the support team asked for a new escalation process for enterprise customers and echo 5 Finance needs the budget numbers for next year by the end of this month in foxtrot 6"
        #expect(HeardText.fuller(final: final, draft: draft) == draft)
    }

    @Test func keepTheFinalWhenItHasAboutAsMuch() {
        let final = "We need the design review finished by Tuesday, and the audit too."
        #expect(HeardText.fuller(final: final, draft: "We need the design review finished by Tuesday and the the audit too") == final)
        #expect(HeardText.fuller(final: final, draft: "") == final)
        #expect(HeardText.fuller(final: "我们周五之前把文案定下来。", draft: "我们周五之前把落地页的文案定下来") == "我们周五之前把文案定下来。")
        #expect(HeardText.fuller(final: "我们周五。", draft: "我们周五之前把落地页的文案定下来") == "我们周五之前把落地页的文案定下来")
    }

    @Test func englishHeardByAChineseModelEndsInLatin() {
        // From test runs: English after Chinese, still on the zh-CN model.
        #expect(HeardText.endsInLatin("提前准备一下会议室和午餐。reigifridadeinali"))
        #expect(HeardText.endsInLatin("下会议室和午餐ouchrivesignin of Fridayndeledinalrin cop foretinge"))
        // English terms in Chinese speech.
        #expect(!HeardText.endsInLatin("Want还在做 onbording的 UIAtaging环境不太稳定。"))
        #expect(!HeardText.endsInLatin("我们这个 featur的 rroatemape下周要定下来 datline是月底 backent那边的 API已经 bready了"))
        #expect(!HeardText.endsInLatin("必要 dev帮忙看一下 Quberned的配置，另外 productmanager希望我们在 sprintreview之前把 Demo准备好"))
    }

    @Test func joinOnlyWhatCarriesOn() {
        // Cut mid-sentence by a pause, carried on at once.
        #expect(HeardText.continues("that… in increased production that you would have expected at this",
                                    "because I think as soon as this crisis is over,", gap: 0.2, cut: true))
        #expect(HeardText.continues("in, diesel and gasoline crisis in Russia that is combined with the Middle",
                                    "that is causing a product twice.", gap: 0.1, cut: false))
        // The recognizer put a "." where Cicada cut; the next piece starts in lower case.
        #expect(HeardText.continues("So, I think the long term headwinds for global energy markets are going to be.",
                                    "in the, and in the getting the tanker market back", gap: 0.3, cut: true))
        // A real full stop, a question, or too long a pause: a new line.
        #expect(!HeardText.continues("It's not just rhetoric.", "it costs a lot more to transport.", gap: 0.2, cut: false))
        #expect(!HeardText.continues("are going to be.", "So the tanker market", gap: 0.2, cut: true))
        #expect(!HeardText.continues("Is it the headlines that are moving markets?", "or is it more", gap: 0.1, cut: true))
        #expect(!HeardText.continues("at this", "because I think", gap: 2.4, cut: true))
        #expect(!HeardText.continues(String(repeating: "word ", count: 40), "and more", gap: 0.1, cut: true))
        #expect(HeardText.continues(String(repeating: "word ", count: 39), "and five or six more words", gap: 0.1, cut: true))
        #expect(HeardText.continues("我们下周", "再看这个方案", gap: 0.3, cut: true))
        #expect(!HeardText.continues("我们下周再看。", "这个方案", gap: 0.3, cut: true))
    }

    @Test func joinedText() {
        #expect(HeardText.join("are going to be.", "in the tanker market") == "are going to be in the tanker market")
        #expect(HeardText.join("at this", "because I think") == "at this because I think")
        #expect(HeardText.join("between…", "loading a ship.") == "between… loading a ship.")
        #expect(HeardText.join("我们下周", "再看") == "我们下周再看")
    }

    /// `CICADA_REPLAY=<session.json>[:<debug log>]`: prints that meeting's lines through clean-up and
    /// joining, before and after. A line counts as cut when the log has a "cut:" between its start and
    /// the next line's (no log: none); the session keeps no audio times, so a cut line's gap is taken as 0.
    @Test func replay() throws {
        guard let arg = ProcessInfo.processInfo.environment["CICADA_REPLAY"] else { return }
        let parts = arg.split(separator: ":", maxSplits: 1).map(String.init)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let s = try decoder.decode(Session.self, from: Data(contentsOf: URL(fileURLWithPath: parts[0])))
        var cuts: [Double] = []
        if parts.count > 1, let log = try? String(contentsOfFile: parts[1], encoding: .utf8) {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
            for l in log.split(separator: "\n") where l.contains(" cut: line") {
                if let d = f.date(from: String(l.prefix(25))) { cuts.append(d.timeIntervalSince(s.startedAt)) }
            }
        }
        var out: [(t: Double, voice: Int?, src: String, from: [String])] = []
        for l in s.lines where l.speaker == "them" {
            let text = HeardText.clean(l.src)
            guard text.contains(where: \.isLetter) else { print("DROP  \(l.src)"); continue }
            if let prev = out.last, let pi = s.lines.firstIndex(where: { $0.t == prev.t }) {
                let cut = cuts.contains { $0 >= s.lines[pi].t && $0 < l.t + 1 }
                if (prev.voice == nil || l.voice == nil || prev.voice == l.voice),
                   HeardText.continues(prev.src, text, gap: cut ? 0 : .infinity, cut: cut) {
                    out[out.count - 1].src = HeardText.join(prev.src, text)
                    out[out.count - 1].from.append(l.src)
                    continue
                }
            }
            out.append((l.t, l.voice, text, [l.src]))
        }
        for o in out where o.from.count > 1 || o.from[0] != o.src {
            print("BEFORE " + o.from.map { "«\($0)»" }.joined(separator: " + "))
            print("AFTER  [\(TranscriptExport.clock(o.t)) v\(o.voice.map(String.init) ?? "-")] \(o.src)\n")
        }
        print("lines: \(s.lines.count) → \(out.count)")
    }
}

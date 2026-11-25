import Foundation
import Testing
@testable import Cicada

/// Live notes rewrite only their last topics, so a long meeting's reply stays small.
@MainActor @Suite struct NotesTests {
    private func topic(_ start: Double, _ title: String, _ points: [String] = ["p"], _ times: [Double?]? = nil) -> NoteTopic {
        NoteTopic(start: start, title: title, summary: "s", points: points, fishbone: nil, pointTimes: times)
    }

    private func lines(_ n: Int) -> [TranscriptLine] {
        (0..<n).map { TranscriptLine(id: "l\($0)", t: Double($0 * 10), speaker: "them", src: "line \($0)", dst: nil, srcLang: "zh-CN", dstLang: "en") }
    }

    /// A heard form only a fix wrote ("platform" for 平台) isn't one: it would teach the translator
    /// and the next fix the same mistake.
    @Test func termsKeepOnlyFormsTheRecognizerWrote() {
        var l = TranscriptLine(id: "a", t: 0, speaker: "them", src: "我们 twoty 平台", dst: nil, srcLang: "zh-CN", dstLang: "en")
        l.fixes = [LineFix(from: "平台", to: "platform")]
        let terms = [NoteTerm(name: "X平台", note: "n", heard: ["Xplatform", "platform", "Twoty"])]
        #expect(NotesEngine.heardAsSaid(terms, lines: [l]).first?.heard == ["Twoty"])
    }

    /// A rewritten topic cites only its newest lines; its points keep when they were first said,
    /// and the topic starts no later than they do (a 35-minute replay showed 17:20 for points at 12:50).
    @Test func fishboneBranchTimeComesFromItsLines() {
        // The model's own "t" came back past the meeting's end (12300 s in a 9000 s meeting).
        let raw = #"{"topics":[{"title":"预算","evidence":["L1"],"points":[],"fishbone":{"question":"q","branches":[{"label":"a","t":12300,"evidence":["L2"]},{"label":"b","t":40}]}}]}"#
        let n = NotesEngine.parse(raw, times: [100, 200, 300], startedAt: 0)!
        #expect(n.topics[0].fishbone?.branches.map(\.t) == [200, 40])
    }

    @Test func topicStartsNoLaterThanItsFirstPoint() {
        var old = MeetingNotes()
        old.topics = [topic(770, "油价", ["A", "B"], [678, 700])]
        var next = MeetingNotes()
        next.topics = [topic(1040, "油价", ["A", "B", "C"], [nil, nil, 1040])]
        NotesEngine.carryTimes(from: old, into: &next)
        #expect(next.topics[0].pointTimes == [678, 700, 1040])
        #expect(next.topics[0].start == 678)
    }

    @Test func keepsFrozenTopicsAndTakesTheReplysTail() {
        let old = (0..<5).map { topic(Double($0 * 100), "t\($0)") }
        // The model echoed everything, renamed the current topic and added one.
        let reply = [topic(0, "t0"), topic(100, "t1 改"), topic(300, "t3"), topic(400, "t4 改"), topic(500, "t5")]
        let merged = NotesEngine.merge(old, frozen: 3, returned: reply)
        #expect(merged.map(\.title) == ["t0", "t1", "t2", "t3", "t4 改", "t5"])
    }

    @Test func nothingFrozenKeepsEveryTopic() {
        // The first update over many lines: nothing to echo, so every topic is the model's own.
        let reply = (0..<5).map { topic(Double($0 * 100), "t\($0)") }
        #expect(NotesEngine.merge([], frozen: 0, returned: reply) == reply)
        #expect(NotesEngine.merge([topic(0, "t0")], frozen: 0, returned: reply) == reply)
    }

    @Test func emptyReplyKeepsTheTopics() {
        let old = [topic(0, "a"), topic(100, "b"), topic(200, "c")]
        #expect(NotesEngine.merge(old, frozen: 1, returned: []) == old)
        #expect(NotesEngine.merge(old, frozen: 1, returned: [topic(0, "a")]) == old)
    }

    @Test func fullLiveNotesJoinTheShortestSettledPair() {
        // Twelve topics, t3 and t4 the shortest neighbours (t3 to t5 is 100 s): a new topic
        // still starts, and those two become one.
        let starts: [Double] = [0, 100, 200, 300, 330, 400, 600, 700, 800, 900, 1000, 1100]
        let old = starts.enumerated().map { topic($0.element, "t\($0.offset)", ["a\($0.offset)", "b\($0.offset)", "c\($0.offset)"]) }
        let reply = [topic(1000, "t10"), topic(1100, "t11"), topic(1200, "t12")]
        let merged = NotesEngine.merge(old, frozen: 10, returned: reply)
        #expect(merged.count == NotesEngine.liveMaxTopics)
        #expect(merged.last?.title == "t12")
        #expect(merged[3].title == "t3 / t4")
        #expect(merged[3].start == 300)
        #expect(merged[3].points == ["a3", "b3", "a4", "b4"])
        #expect(merged[3].summary == "s s")
    }

    @Test func runawayTopicSummaryIsCutToItsFirstSentence() {
        let log = "对方展示AI眼镜后觉得是完全新的体验，提议可以出发回去。" + String(repeating: "最新对方又补充了一些内容，", count: 20)
        var t = topic(0, "t0")
        t.summary = log
        let merged = NotesEngine.merge([], frozen: 0, returned: [t])
        #expect(merged[0].summary == "对方展示AI眼镜后觉得是完全新的体验，提议可以出发回去。")
        #expect(NotesEngine.shortened(String(repeating: "长", count: 200)).count == NotesEngine.topicSummaryLimit + 1)
        #expect(NotesEngine.shortened("short") == "short")
    }

    @Test func livePromptSendsOnlyTheLatestTopics() {
        var notes = MeetingNotes()
        notes.summary = "summary"
        notes.topics = [topic(0, "最早的话题"), topic(100, "第二个话题"), topic(200, "当前话题")]
        notes.covered = 20
        let p = NotesEngine.prompt(notes: notes, lines: lines(24), from: 20, language: "Simplified Chinese", final: false, frozen: 1)
        let json = p.components(separatedBy: "Current notes")[1].components(separatedBy: "\n\n")[0]
        #expect(p.contains("Earlier topics"))
        #expect(p.contains("- 00:00 最早的话题: s"))
        #expect(!json.contains("最早的话题"))
        #expect(json.contains("第二个话题") && json.contains("当前话题"))
        // A full rewrite has nothing frozen.
        let fresh = NotesEngine.prompt(notes: notes, lines: lines(24), from: 20, language: "Simplified Chinese", final: false)
        #expect(!fresh.contains("Earlier topics"))
    }

    @Test func livePromptAsksForOneSentenceSummaries() {
        var notes = MeetingNotes()
        notes.summary = "summary"
        notes.topics = (0..<8).map { topic(Double($0 * 10), "t\($0)") }
        notes.covered = 20
        let p = NotesEngine.prompt(notes: notes, lines: lines(24), from: 20, language: "English", final: false, frozen: 6)
        #expect(!p.contains("do not start a new topic"))
        #expect(p.contains("never append to it"))
    }

    @Test func longMeetingsSplitByTime() {
        // A line every 10 s: 90 min stays whole, 4 h becomes four parts of an hour.
        #expect(NotesEngine.parts(lines(540)) == [0..<540])
        let two = NotesEngine.parts(lines(1440))
        #expect(two.count == 4)
        #expect(two.first?.lowerBound == 0 && two.last?.upperBound == 1440)
        #expect(zip(two, two.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound })
        #expect(NotesEngine.parts([]) == [])
    }

    @Test func partPromptKeepsLineNumbers() {
        let all = lines(720)
        let p = NotesEngine.prompt(notes: MeetingNotes(), lines: Array(all.prefix(480)), from: 240, language: "English",
                                   final: true, part: (2, 3))
        #expect(p.contains("part 2 of 3"))
        #expect(p.contains("[L241 40:00 对方] line 240"))
        #expect(!p.contains("[L238 "))
        #expect(p.contains("This part ran 39:50"))
        let merge = NotesEngine.mergePrompt(parts: ["{\"summary\":\"a\"}", "{\"summary\":\"b\"}"], lines: all, language: "English", voices: false)
        #expect(merge.contains("Part 2 of 2:\n{\"summary\":\"b\"}"))
        #expect(merge.contains("Return the full notes as one JSON object"))
        #expect(merge.contains("\"topics\": []"))
        // Each of three parts gets two of the eight topics.
        #expect(p.contains("use at most 2 topics"))
    }

    @Test func topicStartsWhenItsLinesWereSaid() {
        let times = (0..<100).map { Double($0 * 60) }
        let raw = """
        {"summary": "s", "topics": [
          {"start": 1380, "title": "late", "summary": "s", "points": [{"text": "a", "evidence": ["L86"]}, {"text": "b", "evidence": ["L52"]}], "evidence": ["L60"]},
          {"start": 300, "title": "no evidence", "summary": "s", "points": ["c"]}]}
        """
        let n = NotesEngine.parse(raw, times: times, startedAt: 0)
        #expect(n?.topics.map(\.start) == [51 * 60, 300])
    }

    @Test func partTopicsJoinedNotDropped() {
        let ten = (0..<10).map { topic(Double($0 * 300), "t\($0)") }
        let four = NotesEngine.thinned(ten, to: 4, end: 3000)
        #expect(four.count == 4)
        #expect(four.first?.start == 0)
        #expect(ten.allSatisfy { t in four.contains { $0.title.components(separatedBy: " / ").contains(t.title) } })
        #expect(NotesEngine.thinned(ten, to: 1, end: 3000).map(\.start) == [0])
        #expect(NotesEngine.thinned(Array(ten.prefix(3)), to: 4, end: 3000).count == 3)
    }

    @Test func partTopicsKeepATopicOverItsContinuation() {
        // A 2.5-hour meeting's last part, asked for 2 topics, came back with 3: the budget topic's
        // end as its own. Kept first and last, the budget topic at 125 min was lost.
        let part = [topic(6000, "营销发布安排", ["a"]), topic(7500, "预算评审", ["b"]), topic(8982, "预算评审（续）", ["c"])]
        let kept = NotesEngine.thinned(part, to: 2, end: 8990)
        #expect(kept.map(\.title) == ["营销发布安排", "预算评审"])
        #expect(kept.map(\.start) == [6000, 7500])
        #expect(kept[1].points == ["b", "c"])
        // Told apart by time alone, the stub still joins the topic it ends.
        let other = [topic(6000, "营销发布安排"), topic(7500, "预算评审"), topic(8982, "收尾")]
        #expect(NotesEngine.thinned(other, to: 2, end: 8990).map(\.start) == [6000, 7500])
        #expect(NotesEngine.subject("Budget review (cont.)") == "Budget review")
        #expect(NotesEngine.subject("(续)") == "(续)")
    }

    @Test func termsKeepTheirPlaceAcrossUpdates() {
        let t = { (n: String) in NoteTerm(name: n, note: "", heard: []) }
        let before = [t("A"), t("B"), t("C")]
        #expect(NoteTerm.keepingOrder(before, [t("C"), t("D"), t("A"), t("B")]).map(\.name) == ["A", "B", "C", "D"])
        #expect(NoteTerm.keepingOrder(before, [t("E"), t("B"), t("D")]).map(\.name) == ["B", "E", "D"])
        #expect(NoteTerm.keepingOrder([], [t("B"), t("A")]).map(\.name) == ["B", "A"])
    }

    @Test func fixedWordsKeepOneOrderAcrossRedraws() {
        var lines: [TranscriptLine] = []
        for (i, w) in ["王总", "Kubernetes", "李雷", "OpenAI", "张三", "Cicada", "李雷"].enumerated() {
            var l = TranscriptLine(id: "l\(i)", t: Double(i), speaker: "them", src: w, dst: nil, srcLang: "zh-CN", dstLang: "en")
            l.fixes = [LineFix(from: "x\(i)", to: w)]
            lines.append(l)
        }
        let s = Session(id: "s", title: "t", startedAt: Date(), endedAt: nil, lines: lines, hasAudio: false)
        let first = FixTermsView.fixedWords(s).map(\.word)
        #expect(first == ["李雷", "Cicada", "Kubernetes", "OpenAI", "张三", "王总"])
        for _ in 0..<20 { #expect(FixTermsView.fixedWords(s).map(\.word) == first) }
    }
}

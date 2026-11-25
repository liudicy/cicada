import Foundation
import Testing
@testable import Cicada

@Suite struct NotesWindowTests {
    @Test func notesWindowStandsBesideOnboardingOnlyWhereItFits() {
        let onboarding = { (screen: NSRect) in
            NSRect(x: screen.midX - 430, y: screen.minY + 12, width: 860, height: 668)
        }
        // 1024×768 (the menu bar and Dock taken): 82 pt either side, no room, so it waits.
        let small = NSRect(x: 0, y: 57, width: 1024, height: 686)
        #expect(NotesWindowController.beside(onboarding(small), in: small, width: 460, minWidth: 300) == nil)
        // 1920 wide: the full sidebar to the right, clear of the window.
        let big = NSRect(x: 0, y: 0, width: 1920, height: 1055)
        let r = NotesWindowController.beside(onboarding(big), in: big, width: 460, minWidth: 300)
        #expect(r?.width == 460)
        #expect(r.map { !$0.intersects(onboarding(big)) && big.contains($0) } == true)
        // Room only on the left (the window pushed right): narrower, still clear.
        let pushed = NSRect(x: 1600 - 860, y: 12, width: 860, height: 668)
        let l = NotesWindowController.beside(pushed, in: NSRect(x: 0, y: 0, width: 1600, height: 900), width: 460, minWidth: 300)
        #expect(l?.minX == 12)
        #expect(l.map { !$0.intersects(pushed) } == true)
    }

    private func line(_ id: String, _ t: Double, _ speaker: String = "them", _ src: String = "a line") -> TranscriptLine {
        TranscriptLine(id: id, t: t, speaker: speaker, src: src, dst: nil, srcLang: "en", dstLang: "zh-CN")
    }

    @Test func paragraphsKeepOnePersonWithinThirtySeconds() {
        let lines = [line("a", 0), line("b", 10), line("c", 29), line("d", 31), line("e", 32, "me"), line("f", 33)]
        let groups = TranscriptParagraphs.group(lines, ["a": 1, "b": 1, "c": 1, "d": 1, "f": 1])
        // a–c within 30 s of a; d starts a new one; 你 breaks the run; f is a new paragraph after it.
        #expect(groups.map { $0.map(\.id) } == [["a", "b", "c"], ["d"], ["e"], ["f"]])
    }

    @Test func paragraphsStopGrowingOnceFull() {
        // Fast Japanese with no break (issue #20): a few sentences to a paragraph, not 30 s of them.
        let ja = "いつも動画をご覧いただきありがとうございます。今回は新型が届いたので開封していきます。"  // 42 letters
        let fast = (0..<6).map { line("j\($0)", Double($0) * 4, "them", ja) }
        #expect(TranscriptParagraphs.group(fast, [:]).map { $0.map(\.id) } == [["j0", "j1"], ["j2", "j3"], ["j4", "j5"]])
        // Ordinary English lines: 30 s still decides.
        let en = (0..<4).map { line("e\($0)", Double($0) * 7, "them", "we should ship the fix this week") }
        #expect(TranscriptParagraphs.group(en, [:]).map(\.count) == [4])
    }

    @Test func paragraphsSplitBetweenSpeakers() {
        let lines = [line("a", 0), line("b", 2), line("c", 4)]
        let groups = TranscriptParagraphs.group(lines, ["a": 1, "b": 2, "c": 2])
        #expect(groups.map { $0.map(\.id) } == [["a"], ["b", "c"]])
    }

    @Test func paragraphsSplitBetweenVoicesBeforeNumbersShow() {
        func said(_ id: String, _ t: Double, _ voice: Int?, _ src: String = "three whole words") -> TranscriptLine {
            var l = line(id, t, "them", src); l.voice = voice; return l
        }
        // A speaks, B asks, A answers; a short "Yeah." heard as A stays put. b was like no voice,
        // and reads on its own.
        let lines = [said("a", 0, 1), said("b", 5, nil), said("c", 9, 2), said("d", 12, 1, "Yeah."),
                     said("e", 14, 1), said("f", 18, 1)]
        #expect(TranscriptParagraphs.group(lines, [:]).map { $0.map(\.id) } == [["a"], ["b"], ["c", "d"], ["e", "f"]])
        // Once numbers show, they decide: lines without one stay together as before.
        let shown = TranscriptParagraphs.group(lines, ["x": 1])
        #expect(shown.map { $0.map(\.id) } == [["a", "b", "c", "d", "e", "f"]])
        // A line whose voice is still being heard stays with the paragraph meanwhile.
        let waiting = [said("a", 0, 1), said("b", 3, 1), said("c", 6, nil)]
        #expect(TranscriptParagraphs.group(waiting, [:], pending: ["c"]).map { $0.map(\.id) } == [["a", "b", "c"]])
        #expect(TranscriptParagraphs.group(waiting, [:]).map { $0.map(\.id) } == [["a", "b"], ["c"]])
    }

    /// The sample meeting: "Great, let's lock that in." is too short to start a voice of its own
    /// and like no voice heard so far, so it has none. It doesn't join the answer before it.
    @Test func lineLikeNoVoiceStartsItsOwnParagraph() {
        func said(_ id: String, _ t: Double, _ voice: Int?, _ src: String) -> TranscriptLine {
            var l = line(id, t, "them", src); l.voice = voice; return l
        }
        let lines = [said("a", 0, 0, "Okay, so where are we on the launch?"),
                     said("b", 2, 1, "Uh, I think we can ship March 3rd if design signs off by Friday."),
                     said("c", 7, nil, "Great, let's lock that in."),
                     said("d", 9, nil, "Then I'll tell the team today."),
                     said("e", 12, 1, "Sounds good to me.")]
        #expect(TranscriptParagraphs.group(lines, [:]).map { $0.map(\.id) } == [["a"], ["b"], ["c", "d"], ["e"]])
        // The live recognizer gave "Great." a line of its own: too short to compare, but it has no
        // voice either, and starts the next speaker's paragraph.
        let short = [lines[1], said("g", 7, nil, "Great."), said("h", 8, nil, "Let's lock that in")]
        #expect(TranscriptParagraphs.group(short, [:]).map { $0.map(\.id) } == [["b"], ["g", "h"]])
        // Voices off: no line has one, and one person's lines still read as a paragraph.
        let off = lines.map { var l = $0; l.voice = nil; return l }
        #expect(TranscriptParagraphs.group(off, [:]).map(\.count) == [5])
    }

    @Test func joinSpacesWordsNotChinese() {
        #expect(TranscriptParagraphs.join(["Hello.", " World. "]) == "Hello. World.")
        #expect(TranscriptParagraphs.join(["你好。", "再见。"]) == "你好。再见。")
        #expect(TranscriptParagraphs.join(["", "Only"]) == "Only")
    }

    @Test func notesShowNamesGivenSince() {
        var n = MeetingNotes()
        n.summary = "说话人1和说话人 12 讨论，说话人 2 没说话"
        n.todos = [NoteItem(text: "说话人 1 跟进", owner: "说话人1", support: 1)]
        let shown = SpeakerLabels.named(n, [1: "David", 12: "Kenji"])
        #expect(shown.summary == "David和Kenji 讨论，说话人 2 没说话")
        #expect(shown.todos[0].text == "David 跟进")
        #expect(shown.todos[0].owner == "David")
    }

    @Test func peopleComeFromRoles() {
        let terms = [NoteTerm(name: "Wai Alamed", note: "BGN 集团首席运营官", heard: []),
                     NoteTerm(name: "ADNOC", note: "阿布扎比国家石油公司", heard: [])]
        #expect(NoteTerm.people(terms) == ["Wai Alamed"])
    }
}

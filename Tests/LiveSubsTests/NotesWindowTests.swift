import Foundation
import Testing
@testable import LiveSubs

@Suite struct NotesWindowTests {
    private func line(_ id: String, _ t: Double, _ speaker: String = "them", _ src: String = "a line") -> TranscriptLine {
        TranscriptLine(id: id, t: t, speaker: speaker, src: src, dst: nil, srcLang: "en", dstLang: "zh-CN")
    }

    @Test func paragraphsKeepOnePersonWithinThirtySeconds() {
        let lines = [line("a", 0), line("b", 10), line("c", 29), line("d", 31), line("e", 32, "me"), line("f", 33)]
        let groups = TranscriptParagraphs.group(lines, ["a": 1, "b": 1, "c": 1, "d": 1, "f": 1])
        // a–c within 30 s of a; d starts a new one; 你 breaks the run; f is a new paragraph after it.
        #expect(groups.map { $0.map(\.id) } == [["a", "b", "c"], ["d"], ["e"], ["f"]])
    }

    @Test func paragraphsSplitBetweenSpeakers() {
        let lines = [line("a", 0), line("b", 2), line("c", 4)]
        let groups = TranscriptParagraphs.group(lines, ["a": 1, "b": 2, "c": 2])
        #expect(groups.map { $0.map(\.id) } == [["a"], ["b", "c"]])
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

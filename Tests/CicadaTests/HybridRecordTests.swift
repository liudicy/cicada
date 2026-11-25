import Foundation
import Testing
@testable import Cicada

@Suite struct HybridRecordTests {
    private func line(_ id: String, _ speaker: String = "them", via: String? = nil) -> TranscriptLine {
        TranscriptLine(id: id, t: 0, speaker: speaker, src: "x", srcLang: "en", dstLang: "zh", via: via)
    }

    @Test func onlyAMeetingThatHeardBothShowsPlaces() {
        #expect(!RecordList.heardBoth([line("a"), line("b")]))
        #expect(!RecordList.heardBoth([line("a", via: "room"), line("b", via: "room")]))
        // Your own lines (the talk key) don't make it a meeting that heard the Mac.
        #expect(!RecordList.heardBoth([line("a", via: "room"), line("b", "me")]))
        #expect(RecordList.heardBoth([line("a", via: "room"), line("b")]))
    }

    @Test func aChangeOfPlaceStartsANewRun() {
        let ls = [line("a"), line("b"), line("c", via: "room"), line("d", "me"), line("e", via: "room"), line("f")]
        #expect(RecordList.placeStarts(ls) == ["a", "c", "e", "f"])
    }

    @Test func anUnpluggedMicSaysWhatTookOver() {
        #expect(RoomMicLoss.detail(next: "MacBook Pro Microphone", builtIn: true, both: true) == L("已改用 Mac 自带的麦克风"))
        #expect(RoomMicLoss.detail(next: "Jabra Speak 510", builtIn: false, both: false) == L("已改用 Jabra Speak 510"))
        #expect(RoomMicLoss.detail(next: nil, builtIn: false, both: true) == L("只听电脑了"))
        #expect(RoomMicLoss.detail(next: nil, builtIn: false, both: false) == L("没有别的麦克风，已暂停"))
    }
}

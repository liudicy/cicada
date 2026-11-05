import AVFoundation
import Foundation
import Testing
@testable import LiveSubs

@Suite struct ImportTests {
    @Test func importableFiles() {
        for name in ["a.m4a", "b.MP3", "c.wav", "d.mp4", "e.mov", "f.aiff"] {
            #expect(FileImporter.importable(URL(fileURLWithPath: "/tmp/\(name)")), "\(name)")
        }
        for name in ["a.txt", "b.pdf", "c", "d.png"] {
            #expect(!FileImporter.importable(URL(fileURLWithPath: "/tmp/\(name)")), "\(name)")
        }
    }

    /// Records written before importing existed still load, and count as not imported.
    @Test func olderSessionsDecode() throws {
        let json = #"{"id":"x","title":"会议 11月1日 14:30","startedAt":"2026-11-01T06:30:00Z","lines":[],"hasAudio":false}"#
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let s = try d.decode(Session.self, from: Data(json.utf8))
        #expect(s.sourceFile == nil && s.sourcePath == nil && s.importing == nil)
    }

    /// An imported file is known by its name until the notes name the meeting.
    @Test func importedTitleIsTheFileName() {
        var s = Session(id: "i", title: Session.defaultTitle(Date()), startedAt: Date(), endedAt: nil, lines: [], hasAudio: false)
        s.sourceFile = "客户访谈.m4a"
        #expect(s.displayTitle == "客户访谈")
        #expect(!RecordList.untitled(s))
        s.renamed = true
        s.title = "Renamed"
        #expect(s.displayTitle == "Renamed")
    }

    /// The sound of any file AVFoundation reads comes out as 16 kHz mono, as long as the original.
    @Test func extractsSixteenKilohertzMono() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cicada-import-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Two seconds of a stereo 44.1 kHz tone.
        let src = dir.appendingPathComponent("tone.m4a")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        do {
            // Closed when it goes out of scope (`close()` is macOS 15 and later).
            let writer = try AVAudioFile(forWriting: src, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2])
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 88_200)!
            buffer.frameLength = 88_200
            for ch in 0..<2 { for i in 0..<88_200 { buffer.floatChannelData![ch][i] = 0.3 * sin(Float(i) * 0.06) } }
            try writer.write(from: buffer)
        }
        let length = try await FileImporter.extractAudio(src, to: dir.appendingPathComponent("out.caf"))
        #expect(abs(length - 2) < 0.1)
        let out = try AVAudioFile(forReading: dir.appendingPathComponent("out.caf"))
        #expect(out.processingFormat.sampleRate == 16_000)
        #expect(out.processingFormat.channelCount == 1)
    }
}

@Suite struct ImportSentenceTests {
    @Test func longResultSplitsAtSentenceEnds() {
        let pieces: [(String, Double?)] = [("来年", 0.2), ("一月から", 0.6), ("試験導入できます。", 1.0),
                                          ("法務の", 3.1), ("確認は", 3.4), ("今週中に", 3.8), ("お返事します。", 4.2),
                                          ("以上", 6.0)]
        let s = FileImporter.sentences(pieces, start: 0)
        #expect(s.map(\.text) == ["来年一月から試験導入できます。", "法務の確認は今週中にお返事します。", "以上"])
        #expect(s.map(\.t) == [0.2, 3.1, 6.0])
    }

    @Test func shortSentencesStayTogether() {
        let pieces: [(String, Double?)] = [("OK.", 1), (" Mr.", 2), (" Lee will call.", 3)]
        let s = FileImporter.sentences(pieces, start: 0.5)
        #expect(s.map(\.text) == ["OK. Mr. Lee will call."])
        #expect(s.first?.t == 1)
    }

    /// macOS 14/15: one timed line, split at its sentence marks, each timed by its place in the line.
    @Test func legacyLineSplitsByCharacters() {
        let line = Recognition.Piece(text: "Good morning everyone. Let's review the launch plan.", isFinal: true,
                                     start: 10, end: 20.4, confidence: nil)
        let s = FileImporter.sentences(FileImporter.words(line), start: line.start)
        #expect(s.map(\.text) == ["Good morning everyone.", "Let's review the launch plan."])
        #expect(s.first?.t == 10)
        #expect(abs((s.last?.t ?? 0) - 14.4) < 0.01)
    }

    @Test func missingTimesFallBack() {
        let s = FileImporter.sentences([("Hello there, everyone.", nil), (" How are you?", nil)], start: 7)
        #expect(s.map(\.t) == [7, 7])
    }
}

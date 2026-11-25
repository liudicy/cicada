import AVFoundation
import Foundation
import Testing
@testable import Cicada

/// 电脑和会议室 records the room mic too, and the meeting keeps one recording with both (issue #19).
@MainActor @Suite struct RoomRecordingTests {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    func folder() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cicada-room-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `silent` seconds of nothing, then `seconds` of a tone.
    func write(_ url: URL, silent: Double = 0, seconds: Double, hz: Double) {
        let file = AudioFileWriter.open(url, format: format)!
        let n = Int((silent + seconds) * 16000)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
        buf.frameLength = AVAudioFrameCount(n)
        let start = Int(silent * 16000)
        for i in 0..<n { buf.floatChannelData![0][i] = i < start ? 0 : Float(0.2 * sin(2 * .pi * hz * Double(i) / 16000)) }
        try! file.write(from: buf)
    }

    /// RMS of each half-second of the file.
    func levels(_ url: URL) -> [Float] {
        let file = try! AVAudioFile(forReading: url)
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try! file.read(into: buf)
        let d = buf.floatChannelData![0], step = Int(file.processingFormat.sampleRate / 2)
        return stride(from: 0, to: Int(buf.frameLength) - step / 2, by: step).map { s in
            let e = min(s + step, Int(buf.frameLength))
            return (((s..<e).map { d[$0] * d[$0] }.reduce(0, +)) / Float(e - s)).squareRoot()
        }
    }

    @Test func theRoomIsMixedIntoTheMacsRecordingOnOneClock() {
        let dir = folder()
        let system = dir.appendingPathComponent("system.m4a"), room = dir.appendingPathComponent("room.m4a")
        write(system, seconds: 2, hz: 440)
        write(room, silent: 1, seconds: 2, hz: 660)
        #expect(AudioFileWriter.mix(room, into: system))
        let l = levels(system)
        #expect(l.count >= 6) // the longer of the two: 3 s
        #expect(l[1] > 0.1 && l[1] < 0.17) // the Mac alone
        #expect(l[3] > 0.17) // both
        #expect(l[5] > 0.1) // the room alone, after the Mac's file ended
    }

    @Test func aMeetingKeepsTheRoomInItsOneRecording() async throws {
        let root = folder()
        let store = SessionStore(root: root)
        let id = store.begin().id
        write(AudioFileWriter.partial(store.systemAudioURL(id)), seconds: 2, hz: 440)
        write(AudioFileWriter.partial(store.roomAudioURL(id)), seconds: 2, hz: 660)
        store.end(heardSpeech: true)
        for _ in 0..<100 where store.audioFinished != id { try await Task.sleep(for: .milliseconds(50)) }
        #expect(store.audioFinished == id)
        #expect(store.session(id)?.hasAudio == true)
        #expect(FileManager.default.fileExists(atPath: store.systemAudioURL(id).path))
        #expect(!FileManager.default.fileExists(atPath: store.roomAudioURL(id).path))
        #expect(levels(store.systemAudioURL(id)).dropLast().allSatisfy { $0 > 0.17 })
    }

    @Test func theRoomAloneBecomesTheRecording() async throws {
        let root = folder()
        let store = SessionStore(root: root)
        let id = store.begin().id
        write(AudioFileWriter.partial(store.roomAudioURL(id)), seconds: 2, hz: 660)
        store.end(heardSpeech: true)
        for _ in 0..<100 where store.audioFinished != id { try await Task.sleep(for: .milliseconds(50)) }
        #expect(FileManager.default.fileExists(atPath: store.systemAudioURL(id).path))
        #expect(!FileManager.default.fileExists(atPath: store.roomAudioURL(id).path))
        #expect(store.session(id)?.sourcePath == store.systemAudioURL(id).path)
    }
}

import AVFoundation
import CoreAudio
import Foundation
import Testing
@testable import Cicada

private final class MicFrames: RecognitionStream, @unchecked Sendable {
    let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!
    var results: AsyncThrowingStream<Recognition.Piece, Error> { AsyncThrowingStream { $0.finish() } }
    private let lock = NSLock()
    private var frames = 0
    var count: Int { lock.withLock { frames } }
    func append(_ buffer: AVAudioPCMBuffer) { lock.withLock { frames += Int(buffer.frameLength) } }
    func finalize(through seconds: Double) async throws {}
    func finish() async {}
    func cancel() async {}
}

// Requires microphone permission and a virtual system input with a different format from
// the real mic. Opt in locally: CI has neither these devices nor microphone permission.
@MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["CICADA_TEST_MIC"] == "1"))
struct SpeakMicTests {
    /// The system input (BlackHole) and this Mac's own microphone.
    private func devices() throws -> (original: OutputDevice, mic: OutputDevice) {
        let original = try #require(AudioDevices.defaultInput)
        try #require(original.isVirtualMic, "Select BlackHole as the system input before this hardware test")
        // A continuity microphone may be listed first: hardware tests must only open this Mac's mic.
        let mic = try #require(AudioDevices.inputs().first {
            AudioDevices.transport($0.id) == kAudioDeviceTransportTypeBuiltIn
        })
        return (original, mic)
    }

    @Test func repeatedPressesCaptureFromTheRealMic() async throws {
        let (original, device) = try devices()
        let frames = MicFrames()
        let previousHost = Recognition.host
        Recognition.host = { _, _ in frames }
        defer { Recognition.host = previousHost }
        let speak = SpeakEngine(settings: AppSettings(), voiceMic: VoiceMic())
        speak.inputDevice = { device }
        speak.probe = SpeakProbe()
        defer { speak.pressCancelled() }
        await speak.prepare()
        for _ in 0..<3 {
            let before = frames.count
            speak.pressBegan()
            try #require(speak.phase == .listening)
            try await Task.sleep(for: .milliseconds(500))
            // Cancel rather than release: this regression test must never translate or play audio.
            speak.pressCancelled()
            #expect(frames.count > before)
            #expect(speak.phase == .idle)
        }
        #expect(AudioDevices.defaultInput?.uid == original.uid)
    }

    @Test func roomMicCapturesFromTheRealMic() async throws {
        let (original, device) = try devices()
        let room = RoomMic(device: device)
        let frames = MicFrames()
        room.onAudio = { frames.append($0) }
        try room.start()
        try await Task.sleep(for: .milliseconds(500))
        room.stop()
        #expect(frames.count > 0)
        #expect(AudioDevices.defaultInput?.uid == original.uid)
    }

    @Test func voiceSampleRecordsFromTheRealMic() async throws {
        let (original, device) = try devices()
        let recorder = VoiceRecorder()
        for _ in 0..<2 {
            recorder.start(locale: "zh-CN", device: device)
            #expect(recorder.phase == .recording)
            try await Task.sleep(for: .milliseconds(500))
            let size = (try? FileManager.default.attributesOfItem(atPath: recorder.url.path)[.size] as? Int) ?? 0
            #expect(size > 8_000)  // a quarter second of 16 kHz 16-bit audio
            // Cancel: the sample is deleted, never transcribed or uploaded.
            recorder.cancel()
        }
        #expect(AudioDevices.defaultInput?.uid == original.uid)
    }
}

import AVFoundation
import Testing
@testable import Cicada

private final class NullStream: RecognitionStream, @unchecked Sendable {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    let results = AsyncThrowingStream<Recognition.Piece, Error> { $0.finish() }
    func append(_ buffer: AVAudioPCMBuffer) {}
    func finalize(through seconds: Double) async throws {}
    func finish() async {}
    func cancel() async {}
}

@Suite struct AudioRouterTests {
    /// One second at 16 kHz whose samples all carry `value`, so a slice says which second it came from.
    private func second(_ value: Float) -> AVAudioPCMBuffer {
        let f = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: 16000)!
        b.frameLength = 16000
        for i in 0..<16000 { b.floatChannelData![0][i] = value }
        return b
    }

    /// Lines held three minutes for the language are replayed to the new model; the voice kept
    /// for voiceprints is shorter and must sit at the end of that replay.
    @Test func voiceAfterLongReplay() {
        let router = AudioRouter()
        router.holdAudio(200)
        router.setVoiceCapture(true)
        router.attach(NullStream())
        for s in 0..<180 { router.push(second(Float(s) / 1000)) }
        _ = router.fedSeconds()   // waits for the pushes
        router.attach(NullStream(), replaySeconds: 180)
        #expect(abs(router.fedSeconds() - 180) < 0.01)
        let last = router.voiceSamples(from: 170, to: 171)
        #expect(last != nil)
        #expect(abs((last?[8000] ?? 0) - 0.170) < 0.0001)
        // Spoken after the switch: still found.
        router.push(second(0.5))
        #expect(router.voiceSamples(from: 180, to: 181)?[8000] == 0.5)
        // Older than the voice keeps: nothing rather than the wrong audio.
        #expect(router.voiceSamples(from: 10, to: 11) == nil)
    }
}

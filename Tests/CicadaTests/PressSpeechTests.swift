import Foundation
import Testing
@testable import Cicada

@Suite struct PressSpeechTests {
    /// `seconds` of a 200 Hz tone at `level` (0–1) after `quiet` seconds of room noise at `noise`.
    private func press(quiet: Double, noise: Float, seconds: Double, level: Float) -> [Int16] {
        var out: [Int16] = []
        var seed: UInt32 = 1
        func rnd() -> Float { seed = seed &* 1_664_525 &+ 1_013_904_223; return Float(seed >> 8) / Float(1 << 24) * 2 - 1 }
        for _ in 0..<Int(quiet * 16_000) { out.append(Int16(rnd() * noise * 1.7 * 32767)) }
        for i in 0..<Int(seconds * 16_000) {
            out.append(Int16((sin(Float(i) * 2 * .pi * 200 / 16_000) * level * 1.41 + rnd() * noise) * 32767))
        }
        return out
    }

    @Test func aSilentPressIsNothing() {
        #expect(!PressSpeech.spoken(press(quiet: 3, noise: 0.003, seconds: 0, level: 0)))
        // A noisier room, still nobody talking.
        #expect(!PressSpeech.spoken(press(quiet: 3, noise: 0.01, seconds: 0, level: 0)))
    }

    @Test func aSentenceIsSpeech() {
        #expect(PressSpeech.spoken(press(quiet: 0.4, noise: 0.003, seconds: 2, level: 0.03)))
        // A quiet voice, quieter than the line on its own room: still over three times its noise.
        #expect(PressSpeech.spoken(press(quiet: 0.4, noise: 0.002, seconds: 1, level: 0.008)))
    }

    @Test func aClickIsNotASentence() {
        #expect(!PressSpeech.spoken(press(quiet: 2, noise: 0.003, seconds: 0.1, level: 0.2)))
    }

    /// The log's numbers: a loud quiet (the meeting's leftover echo) holds the line at its cap, and
    /// a voice just under it counts for nothing.
    @Test func theMeasureSaysWhyAPressWasQuiet() {
        let m = PressSpeech.measure(press(quiet: 2, noise: 0.008, seconds: 2, level: 0.01))
        #expect(m.line == 0.016)
        #expect(!m.spoken)
        #expect(m.summary.contains("line -36 dBFS"))
        #expect(PressSpeech.measure([]).voiced == 0)
    }

    @Test func fillersAloneAreNotSent() {
        #expect(PressSpeech.filler("嗯。"))
        #expect(PressSpeech.filler("嗯嗯"))
        #expect(PressSpeech.filler("Um, uh..."))
        #expect(PressSpeech.filler("翻译结果："))
        #expect(PressSpeech.filler("Translation:"))
        #expect(!PressSpeech.filler("价格方面我需要先和财务确认一下。"))
        #expect(!PressSpeech.filler("我想补充三点：价格、时间和人手。"))
        #expect(!PressSpeech.filler("嗯，好的。"))
        #expect(!PressSpeech.filler("OK."))
    }
}

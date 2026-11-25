import Foundation
import Testing
@testable import Cicada

/// `SoundKind` in front of Ming, on the evaluation clips (see `VADEval`).
extension VADEval {
    /// 16 kHz Int16, as `CloudStream` gets it (three-sample average: enough for an evaluation).
    static func int16k(_ clip: Clip) -> [Int16] {
        let k = Int(clip.rate / 16000)
        return stride(from: 0, to: clip.samples.count - k + 1, by: k).map { i in
            var v: Float = 0
            for j in 0..<k { v += clip.samples[i + j] }
            return Int16(max(-1, min(1, v / Float(k))) * 32767)
        }
    }

    /// What `CloudStream` would send Ming, with and without `SoundKind`: stretches with speech in them
    /// that it would drop (must be none), and stretches without that it saves.
    @Test func cloudGate() throws {
        let clips = try Self.load()
        try #require(!clips.isEmpty)
        var out = "clip                 pieces  speech  sent-noise  dropped-noise  DROPPED-SPEECH  ms/piece  (speech/music of each dropped)\n"
        var lost = 0, saved = 0, wasted = 0
        for clip in clips where !clip.room {
            let samples = Self.int16k(clip)
            var seg = CloudSegmenter()
            var pieces: [CloudSegmenter.Piece] = []
            seg.feed(samples) { pieces.append($0) }
            seg.flush { pieces.append($0) }
            var speechN = 0, sentNoise = 0, droppedNoise = 0, droppedSpeech = 0, ms = 0.0, notes: [String] = []
            for p in pieces {
                let overlap = clip.speech.reduce(0.0) { $0 + max(0, min($1.1, p.start + p.seconds) - max($1.0, p.start)) }
                let hasSpeech = overlap >= 0.2
                if hasSpeech { speechN += 1 }
                let t0 = Date()
                let v = SoundKind.judge(p.samples)
                ms += Date().timeIntervalSince(t0) * 1000
                let drop = v.map { $0.speech < SoundKind.speechLine } ?? false
                if drop {
                    notes.append(String(format: "%.2f/%.2f", v!.speech, v!.music))
                    if hasSpeech { droppedSpeech += 1 } else { droppedNoise += 1 }
                } else if !hasSpeech {
                    sentNoise += 1
                    notes.append(String(format: "sent %.2f/%.2f", v?.speech ?? -1, v?.music ?? -1))
                }
            }
            lost += droppedSpeech; saved += droppedNoise; wasted += sentNoise
            out += String(format: "%-20@ %6d  %6d  %10d  %13d  %14d  %8.0f  %@\n", clip.name as NSString, pieces.count, speechN,
                          sentNoise, droppedNoise, droppedSpeech, ms / Double(max(1, pieces.count)),
                          notes.joined(separator: " ") as NSString)
        }
        // The shortest stretches: the start of each clip's first line, cut short.
        for clip in clips where !clip.room {
            let samples = Self.int16k(clip)
            let a = Int(clip.speech[0].0 * 16000)
            let v = [0.3, 0.5, 0.7].map { SoundKind.judge(Array(samples[a..<(a + Int($0 * 16000))]))?.speech ?? -1 }
            out += String(format: "short %-20@ 0.3 s %.2f  0.5 s %.2f  0.7 s %.2f\n", clip.name as NSString, v[0], v[1], v[2])
        }
        out += "\nTOTAL dropped with speech \(lost), noise dropped \(saved), noise still sent \(wasted)\n"
        print(out)
        try out.write(toFile: ProcessInfo.processInfo.environment["CICADA_VAD_EVAL"]! + "/cloud.txt", atomically: true, encoding: .utf8)
        #expect(lost == 0)
    }
}

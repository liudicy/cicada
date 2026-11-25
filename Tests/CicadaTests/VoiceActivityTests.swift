import AVFoundation
import Foundation
import Testing
@testable import Cicada

@Suite struct VoiceActivityTests {
    /// Blocks of `seconds` at `rms`, fed one after another on a running clock.
    private func run(_ a: inout VoiceActivity, _ blocks: [(rms: Float, seconds: Double)], clock: inout Double) {
        for b in blocks {
            _ = a.feed(rms: b.rms, seconds: b.seconds, clock: clock)
            clock += b.seconds
        }
    }

    private func repeated(_ rms: Float, _ seconds: Double, block: Double = 512.0 / 48000) -> [(rms: Float, seconds: Double)] {
        Array(repeating: (rms, block), count: Int((seconds / block).rounded()))
    }

    @Test func aKeyClickDoesNotEndTheSilence() {
        var a = VoiceActivity(gap: 1.5), clock = 0.0
        run(&a, repeated(0.05, 1), clock: &clock)
        run(&a, repeated(0, 1), clock: &clock)
        run(&a, [(0.05, 512.0 / 48000)], clock: &clock)   // one 11 ms click
        run(&a, repeated(0, 0.8), clock: &clock)
        #expect(a.silenceRun >= 1.5)
    }

    @Test func speechAfterAPauseMarksIt() {
        var a = VoiceActivity(gap: 1.5), clock = 0.0
        run(&a, repeated(0.05, 1), clock: &clock)
        run(&a, repeated(0, 0.5), clock: &clock)
        run(&a, repeated(0.05, 0.5), clock: &clock)
        // The pause ended where the sound started, not where it was confirmed.
        #expect(abs(a.pause.end - 1.5) < 0.012)
        #expect(abs(a.pause.length - 0.5) < 0.012)
        #expect(abs(a.voicedTotal - 1.5) < 0.012)
        #expect(a.silenceRun == 0)
    }

    @Test func aGapRestartsTheCount() {
        var a = VoiceActivity(gap: 1.5), clock = 0.0
        run(&a, repeated(0.05, 3), clock: &clock)
        run(&a, repeated(0, 2), clock: &clock)
        run(&a, repeated(0.05, 1), clock: &clock)
        #expect(abs(a.sinceGap - 1) < 0.012)
    }

    @Test func aWordsQuietEndingStaysSpeech() {
        var a = VoiceActivity(gap: 1.5), clock = 0.0
        run(&a, repeated(0.05, 0.5), clock: &clock)
        run(&a, repeated(0.007, 0.2), clock: &clock)   // under the line, over half of it
        #expect(a.silenceRun == 0)
        // From quiet, the same level is not speech.
        var b = VoiceActivity(gap: 1.5)
        clock = 0
        run(&b, repeated(0.007, 0.2), clock: &clock)
        #expect(b.voicedTotal == 0)
    }

    @Test func untunedIsTheBareGate() {
        var a = VoiceActivity(tuning: .none, gap: 1.5), clock = 0.0
        run(&a, repeated(0.05, 1), clock: &clock)
        run(&a, repeated(0, 1), clock: &clock)
        run(&a, [(0.05, 512.0 / 48000)], clock: &clock)
        #expect(a.silenceRun == 0)
        #expect(abs(a.pause.length - 1) < 0.012)
    }
}

/// The VAD evaluation: clips from `scripts/vad-clips.py`, with where the speech is, run through
/// `VoiceActivity` as the system tap and the room mic deliver them, for several tunings.
///     python3 scripts/vad-clips.py && CICADA_VAD_EVAL=build/vad-eval scripts/test.sh --filter VADEval
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CICADA_VAD_EVAL"] != nil))
struct VADEval {
    struct Clip {
        let name: String
        let room: Bool
        let samples: [Float]
        let rate: Double
        let speech: [(Double, Double)]
    }

    struct Score {
        /// Seconds called speech with no speech near (> 50 ms from a line).
        var falseSeconds = 0.0
        /// Times speech started with no line there.
        var falseStarts = 0
        /// Gaps between lines of ≥ `gapSeconds` that never got a silence that long.
        var missedGaps = 0
        var gaps = 0
        /// Pauses of ≥ 0.3 s found inside a line (where a sentence cut lands).
        var splits = 0
        /// Seconds of a line called silence.
        var missedSeconds = 0.0
        var speechSeconds = 0.0
        /// Mean delay from a line's start to the first block called speech.
        var lag = 0.0
    }

    static func load() throws -> [Clip] {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CICADA_VAD_EVAL"]!)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".wav") }.sorted()
        return try names.map { name in
            let file = try AVAudioFile(forReading: dir.appendingPathComponent(name))
            let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buf)
            let samples = Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent(
                name.replacingOccurrences(of: ".wav", with: ".json")))) as! [String: Any]
            let speech = (json["speech"] as! [[Double]]).map { ($0[0], $0[1]) }
            return Clip(name: String(name.dropLast(4)), room: json["source"] as? String == "room",
                        samples: samples, rate: file.processingFormat.sampleRate, speech: speech)
        }
    }

    /// `block`: frames per buffer, as the source delivers them (the mic tap's 4096; the system tap's
    /// is the HAL buffer size, so several are tried).
    static func score(_ clip: Clip, _ tuning: VoiceActivity.Tuning, block: Int) -> Score {
        var a = VoiceActivity(gate: VoiceGate(adaptive: clip.room), tuning: tuning, gap: AudioRouter.gapSeconds)
        var s = Score()
        var wasVoiced = false
        var started = Set<Int>()
        var lags: [Double] = []
        var longestSilence: [Int: Double] = [:]   // gap index → longest silence run seen in it
        var lastPause = (end: 0.0, length: 0.0)
        func line(at t: Double, margin: Double = 0) -> Int? {
            clip.speech.firstIndex { t >= $0.0 - margin && t < $0.1 + margin }
        }
        var i = 0
        while i + block <= clip.samples.count {
            let t = Double(i) / clip.rate, dt = Double(block) / clip.rate
            let voiced = clip.samples.withUnsafeBufferPointer {
                a.feed(UnsafeBufferPointer(rebasing: $0[i..<(i + block)]), rate: clip.rate, clock: t)
            }
            let mid = t + dt / 2
            if voiced {
                if line(at: mid, margin: 0.05) == nil {
                    s.falseSeconds += dt
                    if !wasVoiced { s.falseStarts += 1 }
                }
                if let l = line(at: mid), !started.contains(l) {
                    started.insert(l)
                    lags.append(max(0, t - clip.speech[l].0))
                }
            } else if line(at: mid) != nil {
                s.missedSeconds += dt
            }
            if line(at: mid) != nil { s.speechSeconds += dt }
            // Which gap this block is in: after line g, before line g + 1.
            if let g = clip.speech.indices.last(where: { clip.speech[$0].1 <= t }), g + 1 < clip.speech.count,
               t < clip.speech[g + 1].0 {
                longestSilence[g] = max(longestSilence[g] ?? 0, a.silenceRun)
            }
            if a.pause != lastPause {
                lastPause = a.pause
                let mid = a.pause.end - a.pause.length / 2
                if a.pause.length >= 0.3, line(at: mid) != nil { s.splits += 1 }
            }
            wasVoiced = voiced
            i += block
        }
        for g in 0..<(clip.speech.count - 1) where clip.speech[g + 1].0 - clip.speech[g].1 >= AudioRouter.gapSeconds + 0.2 {
            s.gaps += 1
            if (longestSilence[g] ?? 0) < AudioRouter.gapSeconds { s.missedGaps += 1 }
        }
        s.lag = lags.isEmpty ? 0 : lags.reduce(0, +) / Double(lags.count)
        return s
    }

    @Test func report() throws {
        let clips = try Self.load()
        try #require(!clips.isEmpty)
        let tunings: [(String, VoiceActivity.Tuning)] = [
            ("bare", .none),
            ("on20", .init(onset: 0.02, hold: 1)),
            ("on30", .init(onset: 0.03, hold: 1)),
            ("on50", .init(onset: 0.05, hold: 1)),
            ("on80", .init(onset: 0.08, hold: 1)),
            ("hold.5", .init(onset: 0, hold: 0.5)),
            ("std", .standard),
            ("on50h.5", .init(onset: 0.05, hold: 0.5)),
        ]
        var out = "clip                 tuning   falseS  falseN  gapMiss  splits  missS/speechS   lag\n"
        var totals: [String: Score] = [:]
        for clip in clips {
            for block in clip.room ? [4096] : [512, 1024, 2048] {
            for (tname, t) in tunings {
                let name = clip.room ? tname : "\(tname)/\(block)"
                let s = Self.score(clip, t, block: block)
                out += String(format: "%-20@ %-13@ %6.2f  %6d  %3d/%-3d  %6d  %5.2f/%-6.2f  %5.3f\n",
                              clip.name as NSString, name as NSString, s.falseSeconds, s.falseStarts,
                              s.missedGaps, s.gaps, s.splits, s.missedSeconds, s.speechSeconds, s.lag)
                var tot = totals[name] ?? Score()
                tot.falseSeconds += s.falseSeconds; tot.falseStarts += s.falseStarts
                tot.missedGaps += s.missedGaps; tot.gaps += s.gaps; tot.splits += s.splits
                tot.missedSeconds += s.missedSeconds; tot.speechSeconds += s.speechSeconds
                tot.lag += s.lag / Double(clips.count)
                totals[name] = tot
            }
            }
        }
        out += "\nTOTAL\n"
        for name in totals.keys.sorted() {
            let s = totals[name]!
            out += String(format: "%-13@ falseS %6.2f  falseN %4d  gapMiss %2d/%-2d  splits %3d  missS %5.2f/%-6.2f  lag %.3f\n",
                          name as NSString, s.falseSeconds, s.falseStarts, s.missedGaps, s.gaps, s.splits,
                          s.missedSeconds, s.speechSeconds, s.lag)
        }
        print(out)
        let path = ProcessInfo.processInfo.environment["CICADA_VAD_EVAL"]! + "/report.txt"
        try out.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

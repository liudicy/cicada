import Foundation

/// Speech and silence over time, block by block: what `AudioRouter` knows about pauses, gaps and
/// how much was said. The loudness line is `VoiceGate`'s; on top of it a lone loud blip (a key
/// click, a cough of the speakers) is not speech until the sound has lasted `onset`, so it neither
/// ends the silence that marks a gap or the end of a meeting nor splits a pause in two. Once speech
/// is on, it stays on down to `hold` × the line, so a word's quiet ending isn't a pause.
/// `CICADA_VAD_EVAL` in `VoiceActivityTests` measures both on labelled clips (`scripts/vad-clips.py`).
struct VoiceActivity {
    struct Tuning: Equatable {
        /// Seconds of sound before it counts as speech.
        var onset: Double
        /// Speech goes on down to this fraction of the gate's line.
        var hold: Float
        static let none = Tuning(onset: 0, hold: 1)
        static let standard = Tuning(onset: 0.03, hold: 0.5)
    }

    /// A silence this long between sounds is a pause (where a long line may be cut).
    static let shortestPause = 0.12

    var gate: VoiceGate
    var tuning: Tuning
    private(set) var voicedTotal = 0.0
    private(set) var silenceRun = 0.0
    /// Seconds since the last silence of ≥ `gap` ended.
    private(set) var sinceGap = 0.0
    /// The last pause between sounds: where it ended (on the caller's clock) and how long it was.
    private(set) var pause: (end: Double, length: Double) = (0, 0)
    private var speaking = false
    /// Sound heard but not yet long enough to be speech: counted as silence until it is.
    private var pending = 0.0
    private let gap: Double

    init(gate: VoiceGate = VoiceGate(), tuning: Tuning = .standard, gap: Double) {
        self.gate = gate
        self.tuning = tuning
        self.gap = gap
    }

    /// A new analyzer's clock starts at zero: a pause on the old one means nothing there.
    mutating func clearPause() { pause = (0, 0) }

    /// A block of audio as it arrives. The Mac's own audio is judged in 10 ms steps whatever the
    /// tap's buffer size, so the onset means the same everywhere; the room mic's gate learns its
    /// noise per block (`VoiceGate.blocksPerSecond`), so it takes whole blocks. Returns whether any
    /// of it is speech.
    mutating func feed(_ samples: UnsafeBufferPointer<Float>, rate: Double, clock: Double, pauses: Bool = true) -> Bool {
        let step = gate.adaptive ? samples.count : max(1, Int(rate / 100))
        var voiced = false
        var i = 0
        while i < samples.count {
            let end = min(samples.count, i + step)
            var sum: Float = 0
            for k in i..<end { sum += samples[k] * samples[k] }
            let rms = (sum / Float(end - i)).squareRoot()
            if feed(rms: rms, seconds: Double(end - i) / rate, clock: clock + Double(i) / rate, pauses: pauses) { voiced = true }
            i = end
        }
        return voiced
    }

    /// One block of `seconds` at `rms`, starting at `clock`. Returns whether it is speech;
    /// `pauses` false keeps the last pause as it is (nothing is listening for it).
    mutating func feed(rms: Float, seconds: Double, clock: Double, pauses: Bool = true) -> Bool {
        // The room's line already sits at twice its noise: half of it is the fan, and speech would never end.
        let hold = gate.adaptive ? 1 : tuning.hold
        let line = gate.threshold
        let loud = gate.voiced(rms, seconds: seconds) || (speaking && rms >= line * hold)
        if !loud {
            speaking = false
            silenceRun += pending + seconds
            pending = 0
            sinceGap += seconds
            return false
        }
        if !speaking {
            pending += seconds
            // Not yet: the blip is part of the silence so far.
            guard pending >= tuning.onset else {
                sinceGap += seconds
                return false
            }
            // The sound that made it speech started `pending − seconds` before this block.
            let started = clock + seconds - pending
            if silenceRun >= Self.shortestPause, pauses { pause = (started, silenceRun) }
            if silenceRun >= gap { sinceGap = pending - seconds }
            voicedTotal += pending - seconds
            speaking = true
            silenceRun = 0
            pending = 0
        }
        voicedTotal += seconds
        sinceGap += seconds
        return true
    }
}

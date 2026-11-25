import Foundation

/// 不用按键 (hands-free interpreting): the mic through echo cancellation all the time, a sentence from
/// when your voice rises over the room's floor to `hangover` of quiet after it. Fed the echo-cancelled
/// mic block by block (`VoiceMic`, ~10 ms). A blip (a click, a cough of the speakers) is not a start
/// until it has lasted `onset`; a pause between words shorter than `hangover` doesn't end the sentence.
struct HandsFreeDetector {
    struct Tuning: Equatable {
        /// Seconds of voice before a sentence starts (gaps under `bridge` don't reset it).
        var onset = 0.1
        var bridge = 0.15
        /// Quiet that ends a sentence.
        var hangover = 1.0
        /// A sentence is cut here (Ming takes a sentence or two; the next one starts at once).
        var longest = 20.0
        /// The voice must be this many times the room's floor, and at least `lowest`.
        var margin: Float = 4
        var lowest: Float = 0.004
        /// Once talking, voice goes on down to this share of the line (a word's quiet ending isn't quiet).
        var hold: Float = 0.5
        static let standard = Tuning()
    }

    /// `ended(cut: true)`: `longest` reached while still talking; the next sentence has begun.
    enum Event: Equatable { case none, began, ended(cut: Bool) }

    var tuning: Tuning
    private(set) var talking = false
    private(set) var length = 0.0
    private var voiced = 0.0
    private var gap = 0.0
    private var quiet = 0.0
    /// The quietest block of each of the last seconds: the room's floor.
    private var quietest: [Float] = []
    private var second: Float = .infinity
    private var elapsed = 0.0

    init(tuning: Tuning = .standard) { self.tuning = tuning }

    var floor: Float { quietest.count < 3 ? tuning.lowest / tuning.margin : quietest.sorted()[quietest.count / 5] }
    var line: Float { max(tuning.lowest, floor * tuning.margin) }

    mutating func reset() {
        talking = false
        length = 0; voiced = 0; gap = 0; quiet = 0
    }

    /// Seconds of floor learned: nothing starts before 3 (the unit's first moments are a burst, and a
    /// noisy room would read as a voice until its floor is known).
    var ready: Bool { quietest.count >= 3 }

    mutating func feed(rms: Float, seconds: Double) -> Event {
        // Always learning: speech has a gap in every second, so a sentence doesn't raise the floor, and a
        // room that got noisier (a fan on) can't leave it "talking" for good.
        learn(rms, seconds)
        guard ready else { return .none }
        if !talking {
            if rms >= line {
                voiced += seconds; gap = 0
            } else {
                gap += seconds
                if gap > tuning.bridge { voiced = 0 }
            }
            guard voiced >= tuning.onset else { return .none }
            talking = true
            length = voiced; quiet = 0; voiced = 0; gap = 0
            return .began
        }
        length += seconds
        quiet = rms >= line * tuning.hold ? 0 : quiet + seconds
        if quiet >= tuning.hangover {
            reset()
            return .ended(cut: false)
        }
        // Still talking: this sentence goes now and the next one starts here.
        if length >= tuning.longest {
            length = 0
            return .ended(cut: true)
        }
        return .none
    }

    private mutating func learn(_ rms: Float, _ seconds: Double) {
        second = min(second, rms)
        elapsed += seconds
        guard elapsed >= 1 - 1e-9 else { return }
        quietest.append(second)
        if quietest.count > 10 { quietest.removeFirst() }
        second = .infinity
        elapsed = 0
    }
}

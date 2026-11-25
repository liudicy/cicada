import AVFoundation
import SoundAnalysis

/// Whether a stretch of audio has anyone speaking in it, by the system's own sound classifier
/// (SoundAnalysis, on the device, nothing bundled). Loudness can't tell hold music, a ringtone or an
/// alert from a voice; this can, in 1 s windows: speech scores 0.8–0.98, music and alerts under 0.05,
/// and talk over music keeps its speech score (both labels are given).
enum SoundKind {
    struct Verdict: Equatable {
        /// The highest speech confidence of any window: one spoken second is enough.
        var speech: Double
        var music: Double
    }

    /// Below this nobody spoke in any window (`VADEval` measures it on `scripts/vad-clips.py`).
    static let speechLine = 0.3
    static let window = 1.0
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    private final class Observer: NSObject, SNResultsObserving {
        var verdict = Verdict(speech: 0, music: 0)
        var windows = 0
        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let c = result as? SNClassificationResult else { return }
            windows += 1
            verdict.speech = max(verdict.speech, c.classification(forIdentifier: "speech")?.confidence ?? 0)
            verdict.music = max(verdict.music, c.classification(forIdentifier: "music")?.confidence ?? 0)
        }
    }

    /// 16 kHz mono samples; nil when the classifier can't be had (then the caller treats it as speech).
    /// A stretch shorter than a window is padded with silence to one.
    static func judge(_ samples: [Float]) -> Verdict? {
        guard !samples.isEmpty else { return nil }
        let frames = max(samples.count, Int(window * 16000))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let dst = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        dst.update(repeating: 0, count: frames)
        samples.withUnsafeBufferPointer { dst.update(from: $0.baseAddress!, count: samples.count) }
        do {
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            request.windowDuration = CMTime(seconds: window, preferredTimescale: 16000)
            request.overlapFactor = 0.5
            let analyzer = SNAudioStreamAnalyzer(format: format)
            let observer = Observer()
            try analyzer.add(request, withObserver: observer)
            // The stream analyzer reports on this thread, before these return.
            analyzer.analyze(buffer, atAudioFramePosition: 0)
            analyzer.completeAnalysis()
            return observer.windows > 0 ? observer.verdict : nil
        } catch {
            debugLog("sound kind: \(error.localizedDescription)")
            return nil
        }
    }

    static func judge(_ samples: [Int16]) -> Verdict? {
        judge(samples.map { Float($0) / 32768 })
    }
}

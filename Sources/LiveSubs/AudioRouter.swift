import AppKit
import AVFoundation
import AudioToolbox
import CoreAudio
import CoreMedia
import Speech

// MARK: - Audio routing

/// Stateful sample-rate / sample-format converter.
final class PCMConverter {
    private var converter: AVAudioConverter?

    func convert(_ input: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if input.format == format { return input }
        if converter == nil || converter!.inputFormat != input.format || converter!.outputFormat != format {
            converter = AVAudioConverter(from: input.format, to: format)
        }
        guard let converter else { return nil }
        let ratio = format.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return input
        }
        if status == .error || out.frameLength == 0 { return nil }
        return out
    }
}

/// Moves audio off the real-time thread, converts it for the analyzer,
/// feeds the live transcriber, and keeps a short ring buffer for language detection.
final class AudioRouter: @unchecked Sendable {
    struct Stats {
        var voicedTotal: Double
        var silenceRun: Double
        /// Seconds of audio since the last pause of ≥ `gapSeconds`.
        var sinceGap: Double
        var recentVoiced: Double
    }

    static let gapSeconds = 1.5

    private let queue = DispatchQueue(label: "com.wquguru.cicada.audio", qos: .userInitiated)
    private let converter = PCMConverter()
    private var format: AVAudioFormat?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var ring: [(buffer: AVAudioPCMBuffer, seconds: Double, voiced: Bool)] = []
    private var ringSeconds = 0.0
    private let ringLimit = 10.0
    private var voicedTotal = 0.0
    private var silenceRun = 0.0
    private var sinceGap = 0.0
    /// The last short pause between words, on the analyzer's clock: where it ended and how long it was.
    private var pause: (end: Double, length: Double) = (0, 0)

    /// Experimental voiceprints: the last `voiceLimit` seconds as 16 kHz mono floats, placed on
    /// the analyzer clock so a result's time range finds its audio.
    private let voiceConverter = PCMConverter()
    private let voiceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private var voiceCapture = false
    private var voice: [Float] = []
    private var voiceStart = 0.0
    private let voiceLimit = 90.0

    func setVoiceCapture(_ on: Bool) {
        queue.async { [self] in
            voiceCapture = on
            if !on { voice = []; voiceStart = 0 }
        }
    }

    /// 16 kHz mono audio between two analyzer-clock times, or nil when it's no longer kept.
    func voiceSamples(from start: Double, to end: Double) -> [Float]? {
        queue.sync {
            let a = Int(((start - voiceStart) * 16000).rounded()), b = Int(((end - voiceStart) * 16000).rounded())
            guard a >= 0, b > a, b <= voice.count + 1600 else { return nil }
            // A voiceprint uses at most `Voiceprints.maxSeconds`; don't copy more.
            return Array(voice[a..<min(b, voice.count, a + Int(Voiceprints.maxSeconds * 16000))])
        }
    }

    private func keepVoice(_ mono: AVAudioPCMBuffer) {
        guard voiceCapture, continuation != nil,
              let b = voiceConverter.convert(mono, to: voiceFormat), let d = b.floatChannelData else { return }
        if voice.isEmpty { voiceStart = fed }
        voice.append(contentsOf: UnsafeBufferPointer(start: d[0], count: Int(b.frameLength)))
        let over = voice.count - Int(voiceLimit * 16000)
        if over > 16000 {
            voice.removeFirst(over)
            voiceStart += Double(over) / 16000
        }
    }

    private var recordURL: URL?
    private var recorder: AVAudioFile?

    /// Below this RMS the block counts as silence (≈ -40 dBFS).
    private let voiceThreshold: Float = 0.01

    /// Loudest buffer since the last `takeLevel()`, for the level meter.
    private var peak: Float = 0
    func takeLevel() -> Float {
        queue.sync {
            defer { peak = 0 }
            return peak
        }
    }

    func push(_ mono: AVAudioPCMBuffer) {
        queue.async { [self] in process(mono) }
    }

    private func process(_ mono: AVAudioPCMBuffer) {
        let n = Int(mono.frameLength)
        guard n > 0, let data = mono.floatChannelData else { return }
        var sum: Float = 0
        for i in 0..<n { sum += data[0][i] * data[0][i] }
        let rms = (sum / Float(n)).squareRoot()
        peak = max(peak, rms)
        let seconds = Double(n) / mono.format.sampleRate
        let voiced = rms >= voiceThreshold
        if voiced {
            if silenceRun >= 0.12, continuation != nil { pause = (fed, silenceRun) }
            if silenceRun >= Self.gapSeconds { sinceGap = 0 }
            voicedTotal += seconds
            silenceRun = 0
        } else {
            silenceRun += seconds
        }
        sinceGap += seconds

        guard let format, let converted = converter.convert(mono, to: format) else { return }
        continuation?.yield(AnalyzerInput(buffer: converted))
        keepVoice(mono)
        if continuation != nil { fed += seconds }
        record(converted)
        ring.append((converted, seconds, voiced))
        ringSeconds += seconds
        while ringSeconds > ringLimit, !ring.isEmpty {
            ringSeconds -= ring.removeFirst().seconds
        }
    }

    /// `replaySeconds` re-feeds recent audio so a newly detected language
    /// doesn't lose the words spoken while detection was running.
    /// Starts writing everything the analyzer hears to an AAC file (nil stops).
    func setRecording(_ url: URL?) {
        queue.sync {
            recorder = nil // closes the previous file
            recordURL = url
        }
    }

    private func record(_ buffer: AVAudioPCMBuffer) {
        guard let url = recordURL else { return }
        if recorder == nil {
            recorder = AudioFileWriter.open(AudioFileWriter.partial(url), format: buffer.format)
            if recorder == nil { recordURL = nil; return }
        }
        try? recorder?.write(from: buffer)
    }

    /// Seconds of audio given to the current analyzer, replay included: the analyzer's clock. A
    /// result ending at t was spoken (fed − t) seconds ago, since the tap runs in real time.
    private var fed = 0.0
    func fedSeconds() -> Double { queue.sync { fed } }
    /// Analyzer clock now, the silence running at the end of it, and the last pause before that.
    func clock() -> (fed: Double, silence: Double, pause: (end: Double, length: Double)) {
        // Named explicitly: Swift 6.4's diagnostics crash on the unlabelled nested tuple here.
        queue.sync { (fed: fed, silence: silenceRun, pause: pause) }
    }

    func attach(format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation, replaySeconds: Double = 0) {
        queue.sync {
            fed = 0
            pause = (0, 0)
            // The clock restarts; replayed audio (below) keeps its samples at the new times.
            let keptVoice = voice
            voice = []
            voiceStart = 0
            if self.format != format {
                ring.removeAll()
                ringSeconds = 0
            } else if replaySeconds > 0 {
                var acc = 0.0
                var replay: [AVAudioPCMBuffer] = []
                for item in ring.reversed() {
                    if acc >= replaySeconds { break }
                    acc += item.seconds
                    replay.append(item.buffer)
                }
                for buffer in replay.reversed() { continuation.yield(AnalyzerInput(buffer: buffer)) }
                fed = acc
                voice = Array(keptVoice.suffix(Int(acc * 16000)))
            }
            self.format = format
            self.continuation?.finish()
            self.continuation = continuation
        }
    }

    func detach() {
        queue.sync {
            continuation?.finish()
            continuation = nil
        }
    }

    func reset() {
        queue.sync {
            continuation?.finish()
            continuation = nil
            ring.removeAll()
            ringSeconds = 0
            voice = []
            voiceStart = 0
            voicedTotal = 0
            silenceRun = 0
            sinceGap = 0
        }
    }

    func stats(window: Double = 6) -> Stats {
        queue.sync {
            var acc = 0.0, voiced = 0.0
            for item in ring.reversed() {
                if acc >= window { break }
                acc += item.seconds
                if item.voiced { voiced += item.seconds }
            }
            return Stats(voicedTotal: voicedTotal, silenceRun: silenceRun, sinceGap: sinceGap, recentVoiced: voiced)
        }
    }

    func snapshot(seconds: Double) -> [AVAudioPCMBuffer] {
        queue.sync {
            var acc = 0.0
            var out: [AVAudioPCMBuffer] = []
            for item in ring.reversed() {
                if acc >= seconds { break }
                acc += item.seconds
                out.append(item.buffer)
            }
            return out.reversed()
        }
    }
}


enum AudioFileWriter {
    /// AAC .m4a, mono, at the buffer's sample rate. The processing format must
    /// match the buffers written to it exactly.
    static func open(_ url: URL, format: AVAudioFormat) -> AVAudioFile? {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVEncoderBitRateKey: 32_000,
        ]
        return try? AVAudioFile(forWriting: url, settings: settings,
                                commonFormat: format.commonFormat, interleaved: format.isInterleaved)
    }

    /// Meetings are recorded as ADTS (`system.aac`), which stays readable up to the last packet
    /// if the app is killed; an .m4a is unreadable until it is closed. `finish` turns it into
    /// the .m4a afterwards (and at launch, for a meeting the app didn't get to close).
    static func partial(_ url: URL) -> URL { url.deletingPathExtension().appendingPathExtension("aac") }

    /// Rewraps `partial(url)` into `url` without re-encoding, then removes the partial file.
    /// A partial file next to an .m4a means the last rewrap was cut short: it is done again.
    /// `until`: seconds to keep from the start (the silent tail of a meeting that ended by itself).
    nonisolated static func finish(_ url: URL, until: Double? = nil) async {
        let src = partial(url)
        guard FileManager.default.fileExists(atPath: src.path) else { return }
        try? FileManager.default.removeItem(at: url)
        let asset = AVURLAsset(url: src)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { return }
        if let until { export.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: until, preferredTimescale: 600)) }
        do {
            try await export.export(to: url, as: .m4a)
            try? FileManager.default.removeItem(at: src)
        } catch {
            debugLog("audio rewrap failed \(url.lastPathComponent): \(error)")
            try? FileManager.default.removeItem(at: url)
        }
    }
}

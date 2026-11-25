import AppKit
import AVFoundation
import AudioToolbox
import CoreAudio
import CoreMedia

// MARK: - Audio routing

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
    private var sink: RecognitionStream?
    private var ring: [(buffer: AVAudioPCMBuffer, seconds: Double, voiced: Bool)] = []
    private var ringSeconds = 0.0
    private var ringLimit = 10.0
    /// While the language is unknown the audio is kept longer: the right model, once it is known
    /// or fetched, hears it all again instead of the wrong model's guesses being kept.
    func holdAudio(_ seconds: Double) {
        queue.async { [self] in ringLimit = seconds }
    }
    /// Speech, pauses and gaps; pauses are on the analyzer's clock.
    private var activity = VoiceActivity(gap: AudioRouter.gapSeconds)

    /// Voiceprints (说话人识别): the last `voiceLimit` seconds as 16 kHz mono floats, placed on
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
        guard voiceCapture, sink != nil,
              let b = voiceConverter.convert(mono, to: voiceFormat), let d = b.floatChannelData else { return }
        if voice.isEmpty { voiceStart = fed }
        voice.append(contentsOf: UnsafeBufferPointer(start: d[0], count: Int(b.frameLength)))
        let over = voice.count - Int(voiceLimit * 16000)
        if over > 16000 {
            voice.removeFirst(over)
            voiceStart += Double(over) / 16000
        }
    }

    /// On this queue, for each block at the speech line (电脑和会议室 gates the room mic with it).
    private var onLoud: (() -> Void)?
    func setOnLoud(_ f: (() -> Void)?) { queue.async { [self] in onLoud = f } }

    private var recordURL: URL?
    private var recorder: AVAudioFile?
    /// The recording keeps the meeting's clock (the lines' times): when it began and what is written.
    private var recordStart: Date?
    private var recordedFrames: AVAudioFramePosition = 0
    /// Seconds written to the current recording (including silence gaps): a position in system.m4a
    /// for post-meeting cloud proofreading.
    private var recorded = 0.0
    func recordedSeconds() -> Double { queue.sync { recorded } }

    /// When a block counts as speech (pauses, language detection, the silence that ends a meeting).
    func setRoomGate(_ on: Bool) {
        queue.async { [self] in activity.gate = VoiceGate(adaptive: on) }
    }
    func gateThreshold() -> Float { queue.sync { activity.gate.threshold } }

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
        // Before the onset is confirmed: the first 30 ms of a remote sentence are already echo in the room.
        if let onLoud, rms >= activity.gate.threshold { onLoud() }
        let voiced = activity.feed(UnsafeBufferPointer(start: data[0], count: n), rate: mono.format.sampleRate,
                                   clock: fed, pauses: sink != nil)

        guard let format, let converted = converter.convert(mono, to: format) else { return }
        sink?.append(converted)
        keepVoice(mono)
        if sink != nil { fed += seconds }
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
            recordStart = url == nil ? nil : Date()
            recordedFrames = 0
            if url != nil { recorded = 0 }
        }
    }

    private func record(_ buffer: AVAudioPCMBuffer) {
        guard let url = recordURL else { return }
        if recorder == nil {
            recorder = AudioFileWriter.open(AudioFileWriter.partial(url), format: buffer.format)
            if recorder == nil { recordURL = nil; return }
        }
        // A process tap sends nothing while the Mac is silent: the gap goes in as silence, or every
        // later line's time would point past its words in the recording.
        if let recordStart {
            let rate = buffer.format.sampleRate
            let due = (Date().timeIntervalSince(recordStart) * rate).rounded() - Double(buffer.frameLength)
            let behind = due - Double(recordedFrames)
            if behind > rate / 4 { writeSilence(AVAudioFramePosition(behind), format: buffer.format) }
        }
        try? recorder?.write(from: buffer)
        recordedFrames += AVAudioFramePosition(buffer.frameLength)
        recorded += Double(buffer.frameLength) / buffer.format.sampleRate
    }

    private func writeSilence(_ frames: AVAudioFramePosition, format: AVAudioFormat) {
        let chunk = AVAudioFrameCount(format.sampleRate)
        guard let zeros = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return }
        zeros.frameLength = chunk // sizes the buffers to the whole capacity before they are cleared
        for b in UnsafeMutableAudioBufferListPointer(zeros.mutableAudioBufferList) {
            if let data = b.mData { memset(data, 0, Int(b.mDataByteSize)) }
        }
        var left = frames
        while left > 0 {
            zeros.frameLength = AVAudioFrameCount(min(left, AVAudioFramePosition(chunk)))
            guard (try? recorder?.write(from: zeros)) != nil else { return }
            recordedFrames += AVAudioFramePosition(zeros.frameLength)
            recorded += Double(zeros.frameLength) / format.sampleRate
            left -= AVAudioFramePosition(zeros.frameLength)
        }
    }

    /// Seconds of audio given to the current analyzer, replay included: the analyzer's clock. A
    /// result ending at t was spoken (fed − t) seconds ago, since the tap runs in real time.
    private var fed = 0.0
    func fedSeconds() -> Double { queue.sync { fed } }
    /// Analyzer clock now, the silence running at the end of it, and the last pause before that.
    func clock() -> (fed: Double, silence: Double, pause: (end: Double, length: Double)) {
        // The return type spelled out: Swift 6.4 (Xcode 27) crashes inferring this labelled tuple.
        queue.sync { () -> (fed: Double, silence: Double, pause: (end: Double, length: Double)) in (fed, activity.silenceRun, activity.pause) }
    }

    func attach(_ stream: RecognitionStream, replaySeconds: Double = 0) {
        let format = stream.format
        queue.sync {
            fed = 0
            activity.clearPause()
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
                for buffer in replay.reversed() { stream.append(buffer) }
                fed = acc
                // The ring can replay more than the voice keeps (3 min held for the language against
                // 90 s): the kept voice is the end of the replay, not its start, or every later line
                // looks past the end of it and the whole meeting goes without voices.
                voice = Array(keptVoice.suffix(Int(acc * 16000)))
                voiceStart = max(0, acc - Double(voice.count) / 16000)
            }
            self.format = format
            self.sink = stream
        }
    }

    func detach() {
        queue.sync {
            sink = nil
        }
    }

    func reset() {
        queue.sync {
            sink = nil
            ring.removeAll()
            ringSeconds = 0
            voice = []
            voiceStart = 0
            activity = VoiceActivity(gate: activity.gate, gap: Self.gapSeconds)
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
            return Stats(voicedTotal: activity.voicedTotal, silenceRun: activity.silenceRun, sinceGap: activity.sinceGap,
                         recentVoiced: voiced)
        }
    }

    /// The last `seconds` of speech with the silences left out: what was said, even when nobody is
    /// speaking now (a model that arrives after the talk stopped can still check it).
    func voicedSnapshot(seconds: Double) -> (buffers: [AVAudioPCMBuffer], seconds: Double) {
        queue.sync {
            var acc = 0.0
            var out: [AVAudioPCMBuffer] = []
            for item in ring.reversed() where item.voiced {
                if acc >= seconds { break }
                acc += item.seconds
                out.append(item.buffer)
            }
            return (out.reversed(), acc)
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

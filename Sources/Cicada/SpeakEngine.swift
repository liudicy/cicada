import AppKit
import AVFoundation
import Carbon.HIToolbox
import CoreAudio
import Speech

// MARK: - Output devices

struct OutputDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
    var isVirtualMic: Bool {
        let n = name.lowercased()
        return n.contains("blackhole") || n.contains("livesubs") || n.contains("cicada") || n.contains("loopback")
    }
}

enum AudioDevices {
    static func string(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(device, &addr, 0, nil, &size, $0) }
        return status == noErr ? value as String : nil
    }

    static func outputs() -> [OutputDevice] { devices(scope: kAudioObjectPropertyScopeOutput) }

    /// Devices with streams on one side (output or input), minus Cicada's own aggregate devices.
    static func devices(scope: AudioObjectPropertyScope) -> [OutputDevice] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                     mScope: scope,
                                                     mElement: kAudioObjectPropertyElementMain)
            var s: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &s) == noErr, s > 0,
                  let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName),
                  !uid.hasPrefix("com.wquguru.cicada") else { return nil }
            return OutputDevice(id: id, uid: uid, name: name)
        }
    }

    static var virtualMic: OutputDevice? { outputs().first(where: \.isVirtualMic) }

    static func name(_ device: AudioObjectID) -> String? { string(device, kAudioObjectPropertyName) }

    /// The system output (speakers or headphones): voice previews play here, not into the room.
    static var defaultOutput: OutputDevice? {
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr else { return nil }
        return outputs().first { $0.id == id }
    }
}

// MARK: - Speak engine

/// Hold to talk: microphone → Ming's audio model (what was said + its translation in one call),
/// or on-device transcription → translation when that fails → voice → chosen output device
/// (a virtual microphone for the call). The on-device transcriber always runs: it shows the words
/// while the key is held and is the fallback transcript.
@MainActor
final class SpeakEngine {
    enum Phase { case idle, listening, translating, speaking }

    var onLive: ((_ phase: Phase, _ source: String, _ translation: String) -> Void)?
    /// A finished utterance for the meeting record.
    var onUtterance: ((_ source: String, _ translation: String, _ from: String, _ to: String, _ secondsAgo: Double) -> Void)?
    var onStatus: ((String) -> Void)?
    /// Why a press of the talk key went nowhere: shown while the key is held.
    var onNotice: ((String) -> Void)?
    /// Translator shared with the listening side.
    var translate: ((_ text: String, _ from: String, _ to: String, _ trace: TranslateTrace) async -> String?)?
    /// The press as a WAV → (what was said, translation); nil when Ming is unavailable or its reply is unusable.
    var interpret: ((_ wav: Data, _ from: String, _ to: String, _ trace: TranslateTrace) async -> (original: String, translation: String)?)?
    /// Diagnostics: key released → transcript → translation → voice finished.
    var onTiming: ((SentenceTiming) -> Void)?
    /// Key released → the first sound of the translation went out, for every real press.
    var onLatency: ((Double) -> Void)?
    /// Set by the sound test: the next press is a rehearsal. It reports every stage here and stays
    /// out of the meeting record and the diagnostics.
    var probe: SpeakProbe?
    private var releasedAt: Date?
    /// When the latest `speak` call started sending audio, and how it was voiced.
    private(set) var firstAudioAt: Date?
    private(set) var lastVoice = ""
    /// The real microphone to record from; the system default may be the virtual mic.
    var inputDevice: (() -> OutputDevice?)?
    /// Language the room speaks (for "follow the room").
    var roomLanguage: (() -> String?)?

    let settings: AppSettings
    private(set) var phase: Phase = .idle {
        didSet {
            if phase == .idle { unitIdle() }
            // Hands-free: a sentence said while the last one was translated waits its turn.
            if handsFree, phase == .idle || phase == .speaking, !segments.isEmpty {
                DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.nextSegment() } }
            }
        }
    }

    private var mic = AVAudioEngine()
    /// The mic with echo cancellation, shared with 电脑和会议室's room (`VoiceMic`): used when
    /// `echoCancel` is on, or whenever the room already has it running.
    private let voiceMic: VoiceMic
    /// On by default (`speakVP:off` for the plain mic). With the meeting on the speakers and the
    /// plain mic, Ming took the meeting's own English for what I said and sent it back into the
    /// meeting, every press, even one nobody spoke in; through the unit my sentences came through
    /// whole (an ESP32 speaker 10 cm from the mic as me, the MacBook's speakers at 56 %).
    var echoCancel = true
    /// The real mic to cancel the echo for; nil when it is unknown or virtual (nothing to cancel there).
    private var echoInput: AudioObjectID? {
        // The plain room mic open: the unit readied after each press made it start again, which
        // gave the unit back, and every restart churned the system audio tap and the voice output
        // too, so later presses lost most of what was said and voices didn't reach the meeting.
        guard micTaken?() != true, let d = inputDevice?(), !d.isVirtualMic else { return nil }
        return d.id
    }
    private let micQueue = DispatchQueue(label: "com.wquguru.cicada.mic", qos: .userInitiated)
    private let converter = PCMConverter()
    private var analyzerFormat: AVAudioFormat?
    private var analyzerLocale = ""
    private nonisolated(unsafe) var feeding = false
    private var finals: [String] = []
    private var volatile = ""
    private var pressStarted = Date()
    /// The press went to the plain mic: echo cancellation wasn't to be had (打开麦克风 holds the mic
    /// without it, and lets go of the unit the press would need).
    private var pressPlain = false
    /// Whether the plain room mic holds the mic (打开麦克风 without echo cancellation).
    var micTaken: (() -> Bool)?
    /// The share of a stretch the Mac played its meeting through to the mic (`EchoGate.playedShare`).
    var playedShare: ((Date, Date) -> Double)?
    /// Over this share, what the plain mic heard is the meeting's echo as much as you: Ming sent the
    /// other side's own words back to them (as the ports drop it, Windows `EchoShare`).
    static let echoShare = 0.5
    private nonisolated(unsafe) var micRecorder: AVAudioFile?
    private nonisolated(unsafe) var micRecordURL: URL?
    /// This press's audio as 16 kHz mono 16-bit samples for Ming; only touched on `micQueue`.
    private nonisolated(unsafe) var pressSamples: [Int16] = []
    private nonisolated(unsafe) var pressConverter = PCMConverter()
    private nonisolated static let pressFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!
    /// Ming takes at most this much of a press (the talk key is meant for a sentence or two).
    private nonisolated static let pressLimit = 16_000 * 60

    private let synth = AVSpeechSynthesizer()
    private var out = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var outObserver: NSObjectProtocol?
    private var outFormat: AVAudioFormat?
    /// Where the output was last pointed, to wire a replaced engine the same way.
    private var outDevice: OutputDevice?
    private var outDeviceUID: String?
    /// The device the latest `speak` call played to.
    private(set) var lastDevice: OutputDevice?
    /// Debug: also write synthesized speech here.
    var debugOutputURL: URL?

    init(settings: AppSettings, voiceMic: VoiceMic) {
        self.settings = settings
        self.voiceMic = voiceMic
        wireOutput()
    }

    // MARK: Hands-free

    /// 不用按键: the mic through echo cancellation the whole time, and every sentence I say is
    /// interpreted as a press would be (`HandsFreeDetector` says where it starts and ends). Set by the
    /// app: on with the setting, off while 打开麦克风 hears the room (that unit is shared, and the
    /// room is heard unprocessed). The talk key still works and pauses the detector while held.
    var handsFree = false {
        didSet { if handsFree != oldValue { refreshHandsFree() } }
    }
    /// A hands-free sentence with less voice than this is not sent: every real sentence had ≥ 1.95 s,
    /// what Ming made a sentence of out of the meeting's leftovers ("啊！我要吓死你了！") 0.48 s.
    static let handsFreeVoiced = 0.8
    /// The press being finished is a hands-free sentence.
    private var pressHandsFree = false
    /// Whether a hands-free sentence is mostly what the meeting said around it (its lines or their
    /// translations, `EchoMatch`): the meeting's leftovers through the unit, made into a sentence by
    /// Ming ("营收增长；四名工程师；下半年" with the meeting at 100 % and nobody talking).
    var meetingSaid: ((_ text: String, _ from: Date, _ to: Date) async -> Bool)?
    private var handsFreeInput: AudioObjectID?
    private var handsFreeTimer: Timer?
    /// Sentences heard, waiting for the one before them to be translated.
    private var segments: [(buffers: [AVAudioPCMBuffer], start: Date, end: Date)] = []
    /// Only touched on `micQueue`.
    private nonisolated(unsafe) var detector = HandsFreeDetector()
    private nonisolated(unsafe) var recent: [AVAudioPCMBuffer] = []
    private nonisolated(unsafe) var recentSeconds = 0.0
    private nonisolated(unsafe) var segment: [AVAudioPCMBuffer]?
    private nonisolated(unsafe) var segmentStart = Date()
    /// Debug (`handsFreeDump:<path>`): the echo-cancelled mic as raw 16 kHz float32, to tune the detector.
    private nonisolated(unsafe) var dump: FileHandle?
    func setHandsFreeDump(_ path: String?) {
        micQueue.sync {
            try? dump?.close()
            dump = nil
            guard let path else { return }
            FileManager.default.createFile(atPath: path, contents: nil)
            dump = FileHandle(forWritingAtPath: path)
        }
    }
    /// Audio kept from before the detector is sure: its onset and the first syllable's rise.
    private nonisolated static let lookback = 0.8

    /// Attaches or lets go of the mic to match `handsFree`, the setting and the devices; checked again
    /// every 2 s while on (the unit is made for one output: headphones plugged in need a new one).
    func refreshHandsFree() {
        let want = handsFree && settings.speakEnabled && echoCancel && analyzerFormat != nil ? echoInput : nil
        if let d = handsFreeInput, want != d || !voiceMic.serves("handsfree", input: d) { stopHandsFree() }
        if handsFree, handsFreeTimer == nil {
            handsFreeTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshHandsFree() }
            }
        } else if !handsFree {
            handsFreeTimer?.invalidate()
            handsFreeTimer = nil
        }
        guard let d = want, handsFreeInput == nil else { return }
        handsFreeInput = d
        voiceMic.advancedDucking = true
        voiceMic.prepare(input: d) { [weak self] ok in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Stopped while it was being made: nobody else may be left to give it back.
                    guard self.handsFreeInput == d else {
                        if self.phase == .idle { self.unitIdle() }
                        return
                    }
                    let queue = self.micQueue
                    let attached = ok && self.voiceMic.attach("handsfree", input: d) { [weak self] buf in
                        queue.async { self?.hear(buf) }
                    }
                    if !attached { self.handsFreeInput = nil }
                    debugLog("hands-free: \(attached ? "listening" : "mic not ready, trying again")")
                }
            }
        }
    }

    private func stopHandsFree() {
        guard handsFreeInput != nil else { return }
        handsFreeInput = nil
        voiceMic.detach("handsfree")
        micQueue.sync { detector.reset(); segment = nil; recent = []; recentSeconds = 0 }
        // The talk key's unit keeps the meeting at its level again (made anew once nobody uses it).
        voiceMic.advancedDucking = false
        if phase == .idle { unitIdle() }
        debugLog("hands-free: stopped")
    }

    /// On `micQueue`: one block of the echo-cancelled mic.
    private nonisolated func hear(_ buf: AVAudioPCMBuffer) {
        let n = Int(buf.frameLength)
        guard n > 0, let d = buf.floatChannelData?[0] else { return }
        let seconds = Double(n) / buf.format.sampleRate
        dump?.write(Data(bytes: d, count: n * 4))
        // The talk key held: that press has the mic.
        if feeding {
            segment = nil
            detector.reset()
            return
        }
        recent.append(buf)
        recentSeconds += seconds
        while recentSeconds - Double(recent[0].frameLength) / buf.format.sampleRate >= Self.lookback {
            recentSeconds -= Double(recent.removeFirst().frameLength) / buf.format.sampleRate
        }
        var sum: Float = 0
        for i in 0..<n { sum += d[i] * d[i] }
        let rms = (sum / Float(n)).squareRoot()
        let line = detector.line
        switch detector.feed(rms: rms, seconds: seconds) {
        case .began:
            segment = recent
            segmentStart = Date().addingTimeInterval(-recentSeconds)
            debugLog(String(format: "hands-free: voice began (%.0f dB over a %.0f dB line)", 20 * log10(max(rms, 1e-6)), 20 * log10(line)))
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.voiceBegan() } }
        case .ended(let cut):
            guard let s = segment else { return }
            let start = segmentStart
            segment = cut ? [] : nil
            segmentStart = Date()
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.voiceEnded(s, start: start, cut: cut) } }
        case .none:
            segment?.append(buf)
        }
    }

    private func voiceBegan() {
        if phase == .idle { onLive?(.listening, "", "") }
    }

    private func voiceEnded(_ buffers: [AVAudioPCMBuffer], start: Date, cut: Bool) {
        debugLog(String(format: "hands-free: sentence of %.1f s%@", Date().timeIntervalSince(start), cut ? " (cut, still talking)" : ""))
        segments.append((buffers, start, Date()))
        nextSegment()
    }

    /// Sends the oldest sentence heard on as a press would be, once the one before it is translated.
    private func nextSegment() {
        guard phase == .idle || phase == .speaking, !segments.isEmpty else { return }
        guard let format = analyzerFormat, let input = beginUtterance() else {
            debugLog("hands-free: transcriber not ready, sentence dropped")
            segments.removeFirst()
            return
        }
        let s = segments.removeFirst()
        pressStarted = s.start
        pressPlain = false
        pressHandsFree = true
        phase = .listening
        let conv = PCMConverter()
        for buf in s.buffers {
            guard let c = conv.convert(buf, to: format) else { continue }
            input.append(c)
            micQueue.sync { keepForMing(c) }
        }
        releasedAt = s.end
        finishUtterance()
    }

    private func wireOutput() {
        out.attach(player)
        // Pointing the output at a device (the first sentence, BlackHole installed, headphones
        // plugged in) stops the engine, and the player stays silent until it is wired up again.
        outObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: out, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.outputChanged() }
        }
    }

    /// Making or letting go of the echo-cancelling unit leaves an output engine that was already
    /// there silent for good (still running, no notification; a restart doesn't help), so the room
    /// would hear nothing: a new engine plays again. Not in the middle of a sentence.
    func newOutputEngine() {
        // `player.isPlaying` stays true after the last buffer: the phase says whether a sentence is going out.
        if phase == .speaking {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                MainActor.assumeIsolated { self?.newOutputEngine() }
            }
            return
        }
        if let outObserver { NotificationCenter.default.removeObserver(outObserver) }
        player.stop()
        out.stop()
        out = AVAudioEngine()
        player = AVAudioPlayerNode()
        outFormat = nil
        outDeviceUID = nil
        wireOutput()
        debugLog("voice output: new engine after the voice mic changed")
    }

    var targetCode: String {
        if settings.speakTo != "room" { return settings.speakTo }
        let room = roomLanguage?() ?? "en"
        return room == settings.speakFromLang.code ? "en" : room
    }

    /// Debug: the device the mic engine reads.
    var micDeviceName: String { AudioDevices.inputDevice(of: mic) }

    func setRecording(_ url: URL?) {
        micQueue.sync {
            micRecorder = nil
            micRecordURL = url
        }
    }

    // MARK: Transcriber

    /// Makes sure the speech model for my language is installed and learns the
    /// audio format it wants. Each press then gets its own short-lived analyzer.
    func prepare() async {
        let lang = settings.speakFromLang
        guard analyzerLocale != lang.locale || analyzerFormat == nil else { return }
        do {
            try await Recognition.install(lang.locale) { _ in self.onStatus?(L("正在下载 \(lang.name) 语音模型…")) }
            analyzerFormat = await Recognition.format(lang.locale, drafts: true)
            analyzerLocale = lang.locale
            debugLog("speak transcriber ready locale=\(lang.locale)")
        } catch {
            debugLog("speak transcriber failed: \(error)")
            onStatus?(L("无法准备语音识别：\(error.localizedDescription)"))
        }
    }

    /// While a meeting is listened to with 同声传译 on, the echo-cancelling unit is made ahead and
    /// kept between presses. Made at each press, a press lost its first ~1.4 s and the fresh unit let
    /// the meeting from the speakers through as what I said: a press nobody spoke in sent the meeting
    /// back into it (audio-test, meeting at 56 %: 1.8.0 100 % and 0 sent; made per press 14–87 % and
    /// 2 of 3 silent presses sent). The meeting app hears the virtual mic then, so the built-in mic
    /// it mutes for other apps (#24) matters only outside a meeting, when it is let go of.
    var keepUnit = false {
        didSet { if keepUnit != oldValue, phase == .idle { unitIdle() } }
    }

    private func unitIdle() {
        if keepUnit, echoCancel, let d = echoInput { voiceMic.prepare(input: d) } else if !voiceMic.inUse { voiceMic.release() }
    }

    func teardownAnalyzer() async {
        if let input = utterance?.input { Task { await input.cancel() } }
        utterance = nil
        analyzerFormat = nil
        analyzerLocale = ""
    }

    /// One press = one analyzer over a finite stream. Finishing the stream and
    /// awaiting `finalizeAndFinishThroughEndOfInput` guarantees every word
    /// spoken during the press is in the result before we translate it.
    private var utterance: (input: RecognitionStream, text: Task<String, Never>)?

    private func beginUtterance() -> RecognitionStream? {
        guard let format = analyzerFormat else { return nil }
        let lang = settings.speakFromLang
        let stream = Recognition.startNow(lang.locale, drafts: true, format: format)
        finals = []
        volatile = ""
        micQueue.sync { pressSamples = []; pressConverter = PCMConverter() }
        let task = Task { [weak self] () -> String in
            do {
                for try await r in stream.results { self?.handle(r) }
            } catch {
                debugLog("speak recognition error: \(error)")
            }
            return self?.currentText ?? ""
        }
        utterance = (stream, task)
        return stream
    }

    private func handle(_ r: Recognition.Piece) {
        let text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.isFinal {
            if !text.isEmpty { finals.append(text) }
            volatile = ""
        } else {
            volatile = text
        }
        if phase == .listening { onLive?(.listening, currentText, "") }
    }

    private var currentText: String {
        let j = joiner(for: settings.speakFromLang.code)
        return (finals + [volatile]).filter { !$0.isEmpty }.joined(separator: j.isEmpty ? "" : " ")
    }

    // MARK: Push to talk

    func pressBegan() {
        guard settings.speakEnabled || probe != nil else { return }
        guard phase == .idle || phase == .speaking else {
            debugLog("speak: press while \(phase) ignored")
            return
        }
        if probe == nil {
            // 只听会议室 (older macOS): everyone is at the table and hears you; there is no call to speak into.
            if settings.listensToRoom { onNotice?(L("同声传译是给线上会议用的")); return }
            if outputDevice() == nil { onNotice?(L("还没装虚拟麦克风，线上的人听不到你")); return }
        }
        guard let format = analyzerFormat, let input = beginUtterance() else {
            Task { await prepare() }
            onNotice?(L("语音识别仍在准备中，请再按一次"))
            return
        }
        debugLog("speak: press began")
        pressStarted = Date()
        pressHandsFree = false
        phase = .listening
        onLive?(.listening, "", "")
        startMic(format: format, input: input)
    }

    /// The talk key turned out to be part of a chord: drop what was heard, send nothing.
    func pressCancelled() {
        guard phase == .listening else { return }
        stopMic()
        if let input = utterance?.input { Task { await input.cancel() } }
        utterance = nil
        micQueue.sync { pressSamples = [] }
        finals = []
        volatile = ""
        phase = .idle
        onLive?(.idle, "", "")
        debugLog("speak: press cancelled (chord)")
    }

    func pressEnded() {
        guard phase == .listening else { return }
        debugLog("speak: press ended")
        releasedAt = Date()
        // Keep the mic open a moment so the last syllable isn't cut off.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated { self?.finishUtterance() }
        }
    }

    /// Debug path: feed an audio file as if it were spoken into the mic.
    func speakFile(_ url: URL) {
        guard let file = try? AVAudioFile(forReading: url) else {
            debugLog("speakFile: unreadable \(url.path)")
            return
        }
        var buffers: [AVAudioPCMBuffer] = []
        while true {
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096),
                  (try? file.read(into: buf)) != nil, buf.frameLength > 0 else { break }
            buffers.append(buf)
        }
        Task { await speakBuffers(buffers) }
    }

    /// Feeds recorded audio in real time, as if someone said it into the mic, then "releases the
    /// key". Real time matters: fed all at once, recognition would look slower than it is after release.
    /// Returns false when the engine isn't ready.
    @discardableResult
    func speakBuffers(_ buffers: [AVAudioPCMBuffer]) async -> Bool {
        guard phase == .idle || phase == .speaking, let format = analyzerFormat, let input = beginUtterance() else {
            debugLog("speakBuffers: not ready")
            return false
        }
        pressStarted = Date()
        pressHandsFree = false
        phase = .listening
        onLive?(.listening, "", "")
        let conv = PCMConverter()
        for buf in buffers {
            if let c = conv.convert(buf, to: format) {
                input.append(c)
                micQueue.sync { keepForMing(c) }
            }
            let seconds = Double(buf.frameLength) / buf.format.sampleRate
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        releasedAt = Date()
        finishUtterance()
        return true
    }

    private func startMic(format: AVAudioFormat, input cont: RecognitionStream) {
        if echoCancel || voiceMic.inUse, let device = echoInput {
            // Made now, not ahead (see `VoiceMic`): the press hears from when it is ready.
            pressPlain = false
            let press = pressStarted
            voiceMic.prepare(input: device) { [weak self] ok in
                Task { @MainActor in self?.attachPress(press, ok: ok, device: device, format: format, input: cont) }
            }
            return
        }
        startPlainMic(format: format, input: cont)
    }

    private func attachPress(_ press: Date, ok: Bool, device: AudioObjectID, format: AVAudioFormat, input cont: RecognitionStream) {
        // The key was let go of before the unit was ready: the phase going idle found nothing to give back.
        guard phase == .listening, pressStarted == press, utterance?.input === cont else {
            if phase == .idle { unitIdle() }
            return
        }
        let conv = converter
        let queue = micQueue
        feeding = true
        let started = ok && voiceMic.attach("press", input: device) { [weak self] buf in
            queue.async {
                guard let self, self.feeding, let c = conv.convert(buf, to: format) else { return }
                cont.append(c)
                self.recordMic(c)
                self.keepForMing(c)
            }
        }
        debugLog(String(format: "speak: mic %@ after %.2f s", started ? "with echo cancellation" : "plain, echo cancellation failed",
                        Date().timeIntervalSince(press)))
        if !started { startPlainMic(format: format, input: cont) }
    }

    private func startPlainMic(format: AVAudioFormat, input cont: RecognitionStream) {
        pressPlain = true
        // A unit left over (toggled off mid-press, a virtual mic) would starve the plain mic; one the
        // room is using stays (the talk key is then on another mic).
        if !voiceMic.inUse { voiceMic.release() }
        // A fresh engine each press: one kept from the last press still reports the input's old
        // format after the device changed it (AirPods drop to call quality when their mic opens),
        // and installing a tap in that format raises an exception that ends the app.
        if mic.isRunning { mic.inputNode.removeTap(onBus: 0); mic.stop() }
        mic = AVAudioEngine()
        let inputNode = mic.inputNode
        AudioDevices.pinInput(mic, to: inputDevice?())
        // Pinning can leave the client format at BlackHole's rate/channels. A tap must use
        // the real hardware format or AVAudioEngine raises an Objective-C exception.
        let inFormat = inputNode.inputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            onNotice?(L("没有可用的麦克风"))
            phase = .idle
            return
        }
        inputNode.removeTap(onBus: 0)
        let conv = converter
        let queue = micQueue
        feeding = true
        inputNode.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buf, _ in
            queue.async {
                guard let self, self.feeding else { return }
                if let c = conv.convert(buf, to: format) {
                    cont.append(c)
                    self.recordMic(c)
                    self.keepForMing(c)
                }
            }
        }
        do {
            try mic.start()
        } catch {
            debugLog("mic start failed: \(error)")
            onNotice?(L("麦克风无法启动，请在系统设置里允许\(appDisplayName)使用麦克风"))
            phase = .idle
        }
    }

    private nonisolated func keepForMing(_ buffer: AVAudioPCMBuffer) {
        guard pressSamples.count < Self.pressLimit,
              let c = pressConverter.convert(buffer, to: Self.pressFormat), let p = c.int16ChannelData else { return }
        pressSamples.append(contentsOf: UnsafeBufferPointer(start: p[0], count: Int(c.frameLength)))
    }

    /// The press as a WAV file in memory (44-byte RIFF header + little-endian samples), and whether
    /// anyone spoke in it (`PressSpeech`).
    private func takePressWAV() -> (wav: Data?, spoken: Bool, voiced: Double) {
        let samples = micQueue.sync { () -> [Int16] in
            defer { pressSamples = [] }
            return pressSamples
        }
        let measure = PressSpeech.measure(samples)
        let spoken = measure.spoken
        debugLog("speak: press of \(String(format: "%.1f", Double(samples.count) / 16_000)) s, \(measure.summary)")
        guard samples.count >= 16_000 / 4 else { return (nil, spoken, measure.voiced) }
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        samples.withUnsafeBufferPointer { buf in
            for s in buf { withUnsafeBytes(of: s.littleEndian) { d.append(contentsOf: $0) } }
        }
        return (d, spoken, measure.voiced)
    }

    private nonisolated func recordMic(_ buffer: AVAudioPCMBuffer) {
        guard let url = micRecordURL else { return }
        if micRecorder == nil { micRecorder = AudioFileWriter.open(AudioFileWriter.partial(url), format: buffer.format) }
        try? micRecorder?.write(from: buffer)
    }

    private func stopMic() {
        micQueue.sync { feeding = false }
        voiceMic.detach("press")
        if mic.isRunning {
            mic.inputNode.removeTap(onBus: 0)
            mic.stop()
        }
    }

    private func finishUtterance() {
        stopMic()
        phase = .translating
        let probe = self.probe
        self.probe = nil
        guard let u = utterance else { phase = .idle; probe?.finish(); return }
        utterance = nil
        Task { await u.input.finish() }
        let released = releasedAt ?? Date()
        releasedAt = nil
        let (wav, spoken, voiced) = takePressWAV()
        probe?.released = released
        // A press too quiet for PressSpeech: nobody spoke (Ming would hear 嗯 in the room's hush and
        // the meeting "Hmm."), or a voice from across the desk under a line the meeting's leftover
        // echo raised. The on-device recognizer decides which once it has finished.
        let quiet = wav != nil && !spoken && probe == nil
        // Hands-free: a blip or the meeting's leftovers, not a sentence (Ming would make one up).
        if pressHandsFree, voiced < Self.handsFreeVoiced {
            debugLog(String(format: "hands-free: only %.2f s of voice, nothing sent", voiced))
            Task { _ = await u.text.value }
            finals = []
            volatile = ""
            phase = .idle
            onLive?(.idle, "", "")
            return
        }
        // The meeting playing through most of a press on the plain mic: don't send its echo back.
        if pressPlain, probe == nil, let share = playedShare?(pressStarted, released), share > Self.echoShare {
            debugLog(String(format: "speak: the Mac played through %.0f%% of the press (echo), nothing sent", share * 100))
            Task { _ = await u.text.value }
            finals = []
            volatile = ""
            phase = .idle
            onLive?(.idle, "", L("对方在说话时说的，没有说出去"))
            return
        }
        probe?.pressWAV = wav
        let from = settings.speakFromLang.code
        let to = targetCode
        let trace = TranslateTrace()
        // Pick the voice and ready its output while the sentence is translated: the device switch
        // (and the engine restart it causes) is then over before the first sound.
        let route = route?(to) ?? .system(nil)
        if case .stream = route, let device = outputDevice() { configureOutput(format: Self.streamFormat, device: device); try? out.start() }
        // Ming hears the audio while the on-device transcriber finishes, so its fallback costs nothing.
        // A quiet press waits for the transcriber first: most are nobody speaking, not worth a call.
        let interpret = self.interpret
        let startMing = { Task { () -> (original: String, translation: String)? in
            guard let wav, let interpret else { return nil }
            return await interpret(wav, from, to, trace)
        } }
        let early = quiet ? nil : startMing()
        Task {
            var text = await u.text.value
            finals = []
            volatile = ""
            if quiet {
                // Through echo cancellation the meeting's words don't reach the recognizer (none of
                // 43 at 60 % on the speakers), so a sentence it heard is you. The plain mic has no
                // such guarantee.
                // A tap is too short for a sentence: a 0.3 s one with the meeting's echo around
                // came back as two characters and went out.
                guard !pressPlain, released.timeIntervalSince(pressStarted) >= 1, !text.isEmpty, !PressSpeech.filler(text) else {
                    debugLog("speak: nothing said in the press, nothing sent")
                    phase = .idle
                    onLive?(.idle, "", L("没听清你说的，没有说出去"))
                    return
                }
                debugLog("speak: quiet press, but the on-device recognizer heard \(text.count) chars: sending")
            }
            if !text.isEmpty { onLive?(.translating, text, "") }
            let heard = await (early ?? startMing()).value
            debugLog("speak: on-device heard \(text.count) chars, Ming \(heard.map { "\($0.original.count)" } ?? "-") chars")
            if let heard { text = heard.original }
            // Hands-free: a word or two is a noise Ming named (喂, 咳咳; the talk key is there for 好的),
            // and the meeting's own words are its echo.
            let short = EchoMatch.units(text).count < 3
            var echo = false
            if pressHandsFree, !text.isEmpty, !short { echo = await meetingSaid?(text, pressStarted, released) == true }
            if pressHandsFree, !text.isEmpty, short || echo {
                debugLog("hands-free: \(text.count) chars, \(short ? "too short" : "the meeting's own words"): nothing sent")
                phase = .idle
                onLive?(.idle, "", "")
                return
            }
            // Ming answers recognition and translation together: its whole call counts as `recognize`.
            let textAt = Date()
            probe?.text = text
            probe?.textAt = textAt
            // A lone 嗯 or "um" is the room's hush or an echo's tail, not a sentence to interpret.
            guard !text.isEmpty, !PressSpeech.filler(text) else {
                if !text.isEmpty { debugLog("speak: only a filler heard, nothing sent") }
                phase = .idle
                onLive?(.idle, "", "")
                probe?.finish()
                return
            }
            onLive?(.translating, text, "")
            // Never speak the untranslated original into the room: if translation
            // fails, say so on the bar and send nothing.
            let result: String?
            if let heard {
                result = heard.translation
            } else {
                result = await translate?(text, from, to, trace)
            }
            let translatedAt = Date()
            probe?.translation = result
            probe?.translatedAt = translatedAt
            probe?.via = result == nil ? "none" : trace.via
            probe?.from = from
            probe?.to = to
            @MainActor func timing(voice: Double?, firstAudio: Double? = nil) -> SentenceTiming {
                SentenceTiming(at: textAt, side: "me", chars: text.count, recognize: textAt.timeIntervalSince(released),
                               queue: trace.lingQueue, translate: translatedAt.timeIntervalSince(textAt), voice: voice,
                               failed: trace.failedSeconds, via: result == nil ? "none" : trace.via, fallbacks: trace.fallbacks,
                               firstAudio: firstAudio)
            }
            guard let translated = result else {
                debugLog("speak: translation failed, nothing sent")
                if probe == nil { onTiming?(timing(voice: nil)) }
                phase = .idle
                onLive?(.idle, text, L("这句没翻译成 · 没有说出去"))
                probe?.finish()
                return
            }
            // The virtual mic went away during the press: no voice at all rather than the speakers.
            guard outputDevice() != nil else {
                debugLog("speak: no virtual mic, nothing sent")
                if probe == nil { onTiming?(timing(voice: nil)) }
                phase = .idle
                onLive?(.idle, text, L("没有虚拟麦克风 · 没有说出去"))
                probe?.finish()
                return
            }
            contentLog("SPEAK [\(from)→\(to)] via=\(trace.via) \(text) => \(translated)")
            debugLog("speak: via=\(trace.via) recognize \(String(format: "%.2f", textAt.timeIntervalSince(released))) s translate \(String(format: "%.2f", translatedAt.timeIntervalSince(textAt))) s fallbacks=\(trace.fallbacks)")
            if probe == nil { onUtterance?(text, translated, from, to, Date().timeIntervalSince(pressStarted)) }
            phase = .speaking
            onLive?(.speaking, text, translated)
            await speak(translated, language: to, route: route)
            if let probe {
                probe.firstAudioAt = firstAudioAt
                probe.voice = lastVoice
                probe.device = lastDevice
                probe.finish()
            } else {
                onTiming?(timing(voice: Date().timeIntervalSince(translatedAt),
                                 firstAudio: firstAudioAt.map { $0.timeIntervalSince(translatedAt) }))
                if let first = firstAudioAt { onLatency?(first.timeIntervalSince(released)) }
            }
            if phase == .speaking { phase = .idle }
            onLive?(.idle, text, translated)
        }
    }

    // MARK: Voice output

    private func voice(for code: String, identifier: String? = nil) -> AVSpeechSynthesisVoice? {
        if let identifier, let v = AVSpeechSynthesisVoice(identifier: identifier) { return v }
        let lang = code == "zh-CN" ? "zh-CN" : code == "zh-TW" ? "zh-TW" : code
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(lang) }
        return voices.max(by: { $0.quality.rawValue < $1.quality.rawValue }) ?? AVSpeechSynthesisVoice(language: lang)
    }

    /// Where a translation goes: a virtual mic, so only the people online hear it. Never the
    /// speakers: the room already heard you, and a voice after yours only talks over it. A
    /// `speakOutput` stored before this (the speakers, say) no longer counts. nil: none installed.
    func outputDevice() -> OutputDevice? {
        let all = AudioDevices.outputs()
        if let d = all.first(where: { $0.uid == settings.speakOutput }), d.isVirtualMic { return d }
        return all.first(where: \.isVirtualMic)
    }

    private func synthesize(_ text: String, language: String, voiceID: String?) async -> [AVAudioPCMBuffer] {
        let u = AVSpeechUtterance(string: text)
        u.voice = voice(for: language, identifier: voiceID)
        return await SpeechWriter.write(u, with: synth)
    }

    /// `device` overrides the chosen output (the virtual mic sound test).
    /// How a language is voiced: a PCM stream (Ming's built-in voices or the user's cloned one) or
    /// a voice on this Mac (nil: the best one for the language).
    enum VoiceRoute {
        case stream((String) -> AsyncThrowingStream<Data, Error>)
        case system(String?)
    }

    /// Set by the app: the voice chosen for a language.
    var route: ((String) -> VoiceRoute)?
    /// Who speaks a stream, for logs and the test ("ming", or the service: "zenmux").
    var streamName: () -> String = { "ming" }

    /// Returns after the audio has played. A stream that fails before any audio falls back to the
    /// Mac's voice, so the room always hears the sentence.
    func speak(_ text: String, language: String, device override: OutputDevice? = nil, route forced: VoiceRoute? = nil) async {
        var voiceID: String?
        firstAudioAt = nil
        lastDevice = override ?? outputDevice()
        switch forced ?? route?(language) ?? .system(nil) {
        case .stream(let make):
            let name = streamName()
            lastVoice = name
            if await speakStream(make(text), device: override ?? outputDevice()) { return }
            lastVoice = "system (\(name) failed)"
        case .system(let id):
            lastVoice = "system"
            voiceID = id
        }
        let buffers = await synthesize(text, language: language, voiceID: voiceID)
        guard let first = buffers.first else { return }
        if let url = debugOutputURL, let f = AudioFileWriter.open(url, format: first.format) {
            for b in buffers { try? f.write(from: b) }
        }
        let device = override ?? outputDevice()
        configureOutput(format: first.format, device: device)
        do {
            if !out.isRunning { try out.start() }
        } catch {
            debugLog("voice output failed: \(error)")
            return
        }
        guard outputReady(for: first.format) else { return }
        for b in buffers.dropLast() { player.scheduleBuffer(b, completionHandler: nil) }
        firstAudioAt = Date()
        player.play()
        let seconds = buffers.reduce(0) { $0 + Double($1.frameLength) / $1.format.sampleRate }
        await waitPlayed(buffers[buffers.count - 1], limit: seconds + 2)
        var cur = AudioObjectID(0); var sz = UInt32(MemoryLayout<AudioObjectID>.size)
        if let unit = out.outputNode.audioUnit {
            AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &cur, &sz)
        }
        debugLog("spoke \(buffers.count) buffers to \(device?.name ?? "default output") id=\(device?.id ?? 0) readback=\(cur)")
    }

    /// Core Audio restarted (virtual mic install): device IDs changed, rebuild the output next time.
    /// Plays 24 kHz mono 16-bit PCM chunks as they arrive. Returns false if nothing came, so the
    /// caller can fall back to the system voice.
    private func speakStream(_ stream: AsyncThrowingStream<Data, Error>, device: OutputDevice?) async -> Bool {
        let format = Self.streamFormat
        let started = Date()
        var seconds = 0.0
        var carry = Data()
        var count = 0
        var firstAt: TimeInterval?
        do {
            for try await chunk in stream {
                var bytes = carry + chunk
                if bytes.count % 2 == 1 { carry = bytes.suffix(1); bytes = bytes.dropLast() } else { carry = Data() }
                let frames = bytes.count / 2
                guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { continue }
                buf.frameLength = AVAudioFrameCount(frames)
                seconds += Double(frames) / format.sampleRate
                bytes.withUnsafeBytes { raw in
                    let src = raw.bindMemory(to: Int16.self)
                    let dst = buf.floatChannelData![0]
                    for i in 0..<frames { dst[i] = Float(Int16(littleEndian: src[i])) / 32768 }
                }
                if count == 0 {
                    firstAt = Date().timeIntervalSince(started)
                    firstAudioAt = Date()
                    configureOutput(format: format, device: device)
                }
                // The engine may have been replaced while the stream ran (the echo-cancelling unit
                // let go): a player not wired for this format throws, and that took the app down.
                guard outputReady(for: format) else { break }
                player.scheduleBuffer(buf, completionHandler: nil)
                if !player.isPlaying { player.play() }
                count += 1
            }
        } catch {
            debugLog("ming voice failed: \(error)")
            if count == 0 { return false }
        }
        guard count > 0 else { return false }
        // Wait for the queued audio to finish before the next utterance.
        if let tail = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240), let first = firstAudioAt {
            tail.frameLength = 240
            await waitPlayed(tail, limit: max(0, seconds - Date().timeIntervalSince(first)) + 2)
        }
        debugLog("spoke ming \(count) chunks to \(device?.name ?? "default output") first audio \(String(format: "%.2f", firstAt ?? 0)) s")
        return true
    }

    private static let streamFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!

    /// Schedules `buffer` last and waits until it has played, or `limit` seconds. A stalled output
    /// never calls back, and would otherwise hold every later sentence; it is rebuilt instead.
    private func waitPlayed(_ buffer: AVAudioPCMBuffer, limit: TimeInterval) async {
        guard outputReady(for: buffer.format) else { return }
        let once = Once()
        let played = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in once.run { cont.resume(returning: true) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + limit) { once.run { cont.resume(returning: false) } }
        }
        if !played {
            debugLog("voice output stalled (engine running=\(out.isRunning)), rebuilt")
            resetOutput()
        }
    }

    private func outputChanged() {
        guard let format = outFormat else { return }
        let playing = player.isPlaying
        out.disconnectNodeOutput(player)
        out.connect(player, to: out.mainMixerNode, format: format)
        do { try out.start() } catch { debugLog("voice output restart failed: \(error)"); return }
        if playing { player.play() }
        debugLog("voice output: configuration changed, engine restarted (playing=\(playing))")
    }

    func resetOutput() {
        player.stop()
        out.stop()
        outFormat = nil
        outDeviceUID = nil
    }

    private func configureOutput(format: AVAudioFormat, device: OutputDevice?) {
        let uid = device?.uid ?? ""
        guard outFormat != format || outDeviceUID != uid else { return }
        player.stop()
        out.stop()
        if let device, let unit = out.outputNode.audioUnit {
            var id = device.id
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &id, UInt32(MemoryLayout<AudioObjectID>.size))
        }
        out.disconnectNodeOutput(player)
        out.connect(player, to: out.mainMixerNode, format: format)
        outFormat = format
        outDeviceUID = uid
        outDevice = device
    }

    /// The player is wired for `format` and the engine runs (wired again after the engine was
    /// replaced or reset); false when it can't be started.
    private func outputReady(for format: AVAudioFormat) -> Bool {
        if outFormat != format { configureOutput(format: format, device: outDevice) }
        guard !out.isRunning else { return true }
        do { try out.start(); return true } catch {
            debugLog("voice output failed: \(error)")
            return false
        }
    }

    /// Plays a short sample through the chosen output so the user can check it.
    func preview() {
        Task { await speak(targetCode.hasPrefix("zh") ? "这是对方会听到的声音。" : "This is the voice the room will hear.", language: targetCode) }
    }
}

/// Runs its closure once, from whichever thread gets there first (the audio callback or a timer).
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}

/// The Mac's voice rendered to buffers. `AVSpeechSynthesizer.write` ends with an empty buffer, but
/// on macOS 14 that last buffer never comes (all the audio does): the delegate's didFinish, which
/// does come, ends it too, whichever is first.
final class SpeechWriter: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []
    private var cont: CheckedContinuation<[AVAudioPCMBuffer], Never>?

    static func write(_ u: AVSpeechUtterance, with synth: AVSpeechSynthesizer) async -> [AVAudioPCMBuffer] {
        let writer = SpeechWriter()
        let previous = synth.delegate
        synth.delegate = writer
        defer { synth.delegate = previous }
        return await withCheckedContinuation { cont in
            writer.cont = cont
            synth.write(u) { buf in
                guard let pcm = buf as? AVAudioPCMBuffer, pcm.frameLength > 0 else { writer.end(); return }
                writer.lock.withLock { writer.buffers.append(pcm) }
            }
        }
    }

    private func end() {
        let done = lock.withLock { () -> (CheckedContinuation<[AVAudioPCMBuffer], Never>, [AVAudioPCMBuffer])? in
            guard let c = cont else { return nil }
            cont = nil
            return (c, buffers)
        }
        done?.0.resume(returning: done!.1)
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { end() }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { end() }
}

/// Whether anyone spoke during a press of the talk key, from its 16 kHz samples: 0.3 s of 30 ms
/// frames over three times the press's own quiet (its quietest tenth), between -44 and -36 dBFS. A silent
/// press in a quiet room came back from Ming as "嗯。" and went out as "Hmm.".
enum PressSpeech {
    static let frame = 480
    static let needed = 0.3

    /// Nothing but fillers (嗯, 啊, um, hmm…), whatever the punctuation.
    static func filler(_ text: String) -> Bool {
        let words = text.lowercased().split { !$0.isLetter }.map(String.init)
        guard !words.isEmpty else { return true }
        // A heading with nothing after it ("翻译结果：", "Translation:"): Ming's answer to the meeting's
        // noise in a hands-free stretch nobody spoke in, not a sentence.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = trimmed.last, ":：".contains(last), trimmed.count <= 12 { return true }
        return words.allSatisfy { w in fillers.contains(w) || (w.count > 1 && Set(w).count == 1 && fillers.contains(String(w.first!))) }
    }
    static let fillers: Set<String> = ["嗯", "啊", "呃", "哦", "唔", "额", "噢", "哎", "um", "uh", "hmm", "hm", "mm", "mhm", "ah", "oh", "er", "えー", "あの", "음", "어"]

    /// What the check saw: seconds over the line, the press's quiet and the line (RMS, 0–1).
    struct Measure: Equatable {
        var voiced: Double
        var floor: Float
        var line: Float
        var spoken: Bool { voiced >= PressSpeech.needed }
        /// For the log: a line held at its −36 dBFS cap means the press's quiet was loud.
        var summary: String {
            func db(_ v: Float) -> String { v > 0 ? String(format: "%.0f", 20 * log10(v)) : "-inf" }
            return "voiced \(String(format: "%.2f", voiced)) s, quiet \(db(floor)) dBFS, line \(db(line)) dBFS"
        }
    }

    static func spoken(_ samples: [Int16]) -> Bool { measure(samples).spoken }

    static func measure(_ samples: [Int16]) -> Measure {
        guard samples.count >= frame else { return Measure(voiced: 0, floor: 0, line: 0) }
        var levels: [Float] = []
        var i = 0
        while i + frame <= samples.count {
            var sum: Float = 0
            for k in i..<(i + frame) { let v = Float(samples[k]) / 32768; sum += v * v }
            levels.append((sum / Float(frame)).squareRoot())
            i += frame
        }
        // A press can be speech from end to end: its quietest tenth is the room only when it has
        // pauses, so the line stops at -36 dBFS, which a voice into the mic clears anyway.
        let floor = levels.sorted()[levels.count / 10]
        let line = min(0.016, max(0.0063, floor * 3))
        let voiced = Double(levels.filter { $0 >= line }.count) * Double(frame) / 16_000
        return Measure(voiced: voiced, floor: floor, line: line)
    }
}


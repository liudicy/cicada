import AVFoundation
import Foundation

/// 听会议室 on iPhone and iPad: the microphone → the shared recognizer (`Recognition`) → the shared
/// translation chain → the meeting record, with live notes from the shared `NotesEngine`. The Mac's
/// `ListenEngine` is bound to Core Audio and AppKit; this is the same pipeline cut down to one source
/// and one language the user picked (对方说; detecting it comes later).
@MainActor
final class RoomListen: ObservableObject {
    /// One sentence on the 字幕 page.
    struct Line: Identifiable, Equatable {
        let id: String
        var src: String
        var dst: String?
        var voice: Int?
        var t: Double
    }

    @Published private(set) var isRunning = false
    @Published private(set) var startedAt: Date?
    @Published private(set) var lines: [Line] = []
    /// The sentence in progress and its draft translation.
    @Published private(set) var draft = ""
    @Published private(set) var draftTranslation = ""
    /// 0–1, for the wave.
    @Published private(set) var level: Float = 0
    @Published private(set) var status = ""
    @Published private(set) var sessionID: String?

    /// Every finished line, for the Live Activity.
    var onLine: ((Line) -> Void)?
    var onStateChange: (() -> Void)?

    private let store: SessionStore
    private let translator: TranslationService
    private let notes: NotesEngine
    private let speakers = SpeakerTagger()
    private let audio = RoomAudio()
    private var stream: RecognitionStream?
    private var reader: Task<Void, Never>?
    /// The last meeting still closing: its recognizer flushes the last sentence before its session ends.
    private var stopping: Task<Void, Never>?
    private var lang = sourceLanguages[0]
    private var target = "zh-Hans"
    private var counter = 0
    /// The last line written, with where it sits on the recognizer's clock, for joining a sentence a pause cut.
    private var last: (id: String, src: String, end: Double)?
    private var draftAsked = Date.distantPast
    private var draftEpoch = 0
    /// The microphone heard something loud enough to be a voice, for keeping a meeting with no lines.
    private var heardVoice = false

    init(store: SessionStore, translator: TranslationService, notes: NotesEngine) {
        self.store = store
        self.translator = translator
        self.notes = notes
        speakers.onVoice = { [weak self] lineID, voice in
            guard let self else { return }
            self.store.setVoice(lineID: lineID, voice)
            if let i = self.lines.firstIndex(where: { $0.id == lineID }) { self.lines[i].voice = voice }
        }
    }

    /// Distinct voices heard so far.
    var speakerCount: Int { Set(lines.compactMap(\.voice)).count }

    var elapsed: TimeInterval { startedAt.map { Date().timeIntervalSince($0) } ?? 0 }
    var languagePair: (source: String, target: String) { (lang.code, target) }

    func start(source: String, target: String, voices: Bool) {
        guard !isRunning else { return }
        lang = sourceLanguages.first { $0.locale == source } ?? sourceLanguages[0]
        self.target = target
        status = L("正在准备…")
        isRunning = true
        onStateChange?()
        Task { await begin(voices: voices) }
    }

    private func begin(voices: Bool) async {
        // Started again right after 结束: the last meeting's closing would otherwise cancel this one's
        // reader and end this one's session, leaving the microphone on with nothing coming in.
        await stopping?.value
        guard isRunning else { return }
        lines = []
        draft = ""
        draftTranslation = ""
        last = nil
        counter = 0
        speakers.reset()
        guard await AVAudioApplication.requestRecordPermission() else {
            fail(L("请在设置里允许知了使用麦克风"))
            return
        }
        do {
            if await Recognition.status(lang.locale) != .installed {
                status = L("正在下载 \(lang.name) 语音模型…")
                try await Recognition.install(lang.locale)
            }
            let stream = try await Recognition.start(lang.locale, drafts: true, confidence: true)
            guard isRunning else { await stream.cancel(); return }
            self.stream = stream
            let s = store.begin()
            store.markLiveInRoom()
            sessionID = s.id
            startedAt = s.startedAt
            notes.begin(s.id)
            audio.voices = voices
            try audio.start(recognizer: stream, recording: AudioFileWriter.partial(store.systemAudioURL(s.id)))
            heardVoice = false
            audio.onLevel = { [weak self] v in
                self?.level = v
                if v > 0.55 { self?.heardVoice = true }
            }
            reader = Task { [weak self] in
                do {
                    for try await piece in stream.results { self?.handle(piece) }
                } catch {
                    debugLog("room: recognizer ended: \(error)")
                    // The meeting so far is kept; listening stops with a reason rather than hearing nothing.
                    guard let self, self.isRunning else { return }
                    self.stop()
                    self.status = L("识别中断了，请重新开始听")
                }
            }
            status = ""
            debugLog("room: listening locale=\(lang.locale) target=\(target) format=\(stream.format) session=\(s.id)")
            onStateChange?()
        } catch {
            debugLog("room: start failed: \(error)")
            fail(Recognition.needsUser(error) ? error.localizedDescription : L("没能下载 \(lang.name) 语音模型"))
        }
    }

    private func fail(_ message: String) {
        status = message
        isRunning = false
        onStateChange?()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        audio.stop()
        let stream = self.stream, reader = self.reader
        self.stream = nil
        self.reader = nil
        stopping = Task {
            await stream?.finish()
            reader?.cancel()
            notes.finish()
            // A meeting with no line is kept only when the microphone heard voices (its recording holds them).
            store.end(heardSpeech: heardVoice)
            debugLog("room: stopped lines=\(lines.count)")
            sessionID = nil
            startedAt = nil
            level = 0
            onStateChange?()
        }
        onStateChange?()
    }

    private func handle(_ piece: Recognition.Piece) {
        let text = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard piece.isFinal else {
            if text != draft {
                draft = text
                translateDraft()
            }
            return
        }
        let final = HeardText.fuller(final: HeardText.clean(text), draft: draft)
        draft = ""
        draftTranslation = ""
        draftEpoch += 1
        guard final.contains(where: \.isLetter), let start = startedAt else { return }
        contentLog("FINAL [\(lang.locale)] \(final)")
        // One sentence a pause cut in two: the earlier line takes the rest.
        if let prev = last, lines.last?.id == prev.id,
           HeardText.continues(prev.src, final, gap: piece.start - prev.end, cut: false) {
            let joined = HeardText.join(prev.src, final)
            last = (prev.id, joined, piece.end)
            store.setSource(lineID: prev.id, joined)
            if let i = lines.firstIndex(where: { $0.id == prev.id }) { lines[i].src = joined }
            translate(prev.id, joined)
            return
        }
        counter += 1
        let id = "r\(counter)"
        // Where the sentence started, in meeting time: the recognizer's clock runs on the audio fed.
        let t = max(0, Date().timeIntervalSince(start) - max(0, audio.fedSeconds - piece.start))
        store.append(TranscriptLine(id: id, t: t, speaker: "them", src: final, dst: nil,
                                    srcLang: lang.code, dstLang: target))
        lines.append(Line(id: id, src: final, dst: nil, voice: nil, t: t))
        if lines.count > 60 { lines.removeFirst(lines.count - 60) }
        last = (id, final, piece.end)
        if let samples = audio.voiceSamples(from: piece.start, to: piece.end) {
            speakers.tag(lineID: id, samples: samples)
        }
        translate(id, final)
    }

    /// `retry`: every provider failed before (Ling busy while Google answers 429): asked again a
    /// little later, twice at most, as the Mac does.
    private func translate(_ id: String, _ text: String, retry: Int = 0) {
        let source = lang.code, target = self.target
        Task {
            guard let out = await translator.translate(text, source: source, target: target, kind: .sentence) else {
                debugLog("room: translation failed, try \(retry + 1)")
                guard retry < 2 else { return }
                try? await Task.sleep(nanoseconds: UInt64(retry == 0 ? 10 : 20) * 1_000_000_000)
                guard isRunning, lines.first(where: { $0.id == id })?.src == text else { return }
                translate(id, text, retry: retry + 1)
                return
            }
            // Joined meanwhile: only the whole sentence's translation counts.
            guard let i = lines.firstIndex(where: { $0.id == id }), lines[i].src == text else { return }
            lines[i].dst = out
            store.setTranslation(lineID: id, out)
            contentLog("TRANSLATE [\(source)→\(target)] \(text) => \(out)")
            onLine?(lines[i])
        }
    }

    /// The line in progress, at most every second (Google, never Ling: AGENTS.md).
    private func translateDraft() {
        guard Date().timeIntervalSince(draftAsked) > 1, draft.count >= 6 else { return }
        draftAsked = Date()
        let epoch = draftEpoch, text = draft, source = lang.code, target = self.target
        Task {
            let out = await translator.translate(text, source: source, target: target, kind: .draft)
            guard epoch == draftEpoch, let out else { return }
            draftTranslation = out
        }
    }
}

/// The microphone side, off the main actor: `AVAudioEngine`'s input tap → the recognizer's format,
/// the meeting's recording, a level and the last minute of 16 kHz audio for voiceprints.
final class RoomAudio: @unchecked Sendable {
    var voices = true
    var onLevel: (@MainActor (Float) -> Void)?

    /// A new engine for each meeting: one restarted after `stop` hears only silence in the simulator.
    private var engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "com.wquguru.cicada.room", qos: .userInitiated)
    private let toRecognizer = PCMConverter()
    private let toVoice = PCMConverter()
    private let voiceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var stream: RecognitionStream?
    private var recorder: AVAudioFile?
    private var recordingURL: URL?
    /// Recognizer-clock seconds of audio appended, and the voice ring (its first sample's time).
    private var fed = 0.0
    private var ring: [Float] = []
    private var ringStart = 0.0
    private var lastLevel = Date.distantPast

    var fedSeconds: Double { queue.sync { fed } }

    func start(recognizer: RecognitionStream, recording: URL) throws {
        let session = AVAudioSession.sharedInstance()
        // .measurement: no voice processing, which would duck what the room says as "echo".
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
        try session.setActive(true)
        engine = AVAudioEngine()
        queue.sync {
            stream = recognizer
            recordingURL = recording
            fed = 0
            ring = []
            ringStart = 0
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        debugLog("room: input \(format) route=\(session.currentRoute.inputs.map(\.portName))")
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, let copy = buffer.copy() as? AVAudioPCMBuffer else { return }
            self.queue.async { self.feed(copy) }
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        queue.sync {
            stream = nil
            recorder = nil
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func feed(_ buffer: AVAudioPCMBuffer) {
        guard let stream else { return }
        if let c = toRecognizer.convert(buffer, to: stream.format) {
            stream.append(c)
            fed += Double(c.frameLength) / c.format.sampleRate
        }
        guard let v = toVoice.convert(buffer, to: voiceFormat), let p = v.floatChannelData?[0] else { return }
        let n = Int(v.frameLength)
        if recorder == nil, let url = recordingURL { recorder = AudioFileWriter.open(url, format: voiceFormat) }
        try? recorder?.write(from: v)
        if voices {
            ring.append(contentsOf: UnsafeBufferPointer(start: p, count: n))
            let keep = 60 * 16_000
            if ring.count > keep + 16_000 {
                let drop = ring.count - keep
                ring.removeFirst(drop)
                ringStart += Double(drop) / 16_000
            }
            // The ring runs on the voice clock; it tracks the recognizer's since both see every buffer.
        } else {
            ringStart = fed
        }
        if Date().timeIntervalSince(lastLevel) > 0.08 {
            lastLevel = Date()
            var sum: Float = 0
            for i in 0..<n { sum += p[i] * p[i] }
            let rms = n > 0 ? (sum / Float(n)).squareRoot() : 0
            // -50…-10 dBFS onto 0…1.
            let db = 20 * log10(max(rms, 1e-6))
            let v = max(0, min(1, (db + 50) / 40))
            let cb = onLevel
            DispatchQueue.main.async { MainActor.assumeIsolated { cb?(v) } }
        }
    }

    /// 16 kHz mono audio between two recognizer-clock times, if still in the ring and long enough.
    func voiceSamples(from: Double, to: Double) -> [Float]? {
        queue.sync {
            guard voices else { return nil }
            let a = max(0, Int((from - ringStart) * 16_000)), b = min(ring.count, Int((to - ringStart) * 16_000))
            guard b - a >= Int(Voiceprints.minSeconds * 16_000) else { return nil }
            return Array(ring[a..<min(b, a + Int(Voiceprints.maxSeconds * 16_000))])
        }
    }
}

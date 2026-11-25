import AVFoundation
import Foundation

/// 听会议室 on iPhone and iPad: the microphone → the shared recognizer (`Recognition`) → the shared
/// translation chain → the meeting record, with live notes from the shared `NotesEngine`. The Mac's
/// `ListenEngine` is bound to Core Audio and AppKit; this is the same pipeline cut down to one source.
/// 对方说 is one language, or 自动识别: listening starts in the likeliest one and the first words
/// settle it (`LanguageDetector`, as on the Mac), heard again in another language if that's the one.
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
    /// 手机外放: a video app plays aloud while we listen from the background, so its audio keeps
    /// playing beside ours and the subtitles go to the picture-in-picture window (PiPSubtitles).
    @Published private(set) var speakerMode = false
    /// A call, Siri or another app took the audio, or 暂停 on the lock screen: the microphone is
    /// off until it ends.
    @Published private(set) var paused = false
    /// The pause is the user's (暂停): an interruption ending doesn't end it.
    private var userPaused = false

    /// Every finished line, for the Live Activity.
    var onLine: ((Line) -> Void)?
    /// A line was written or its words changed (a joined sentence): the word list's known
    /// misheard forms are fixed at once (`LiveFixes.applyKnown`).
    var onHeard: ((_ session: String, _ lineID: String) -> Void)?
    /// A meeting was stored as ended (存到文件夹 writes it once its notes are done).
    var onEnded: ((_ session: String) -> Void)?
    /// Debug (`silentListen`): a meeting with no microphone and no recognizer, fed by `heard:`.
    static var silent = false
    private var silentClock = 0.0
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

    /// 自动识别: until the language is settled, finished lines wait in `held` (written once it is
    /// the one listened in) and the microphone's audio is kept to hear again in another.
    private var auto = false
    private var settled = true
    private var candidates: [Lang] = []
    private var detection = LanguageDetection()
    private var held: [Recognition.Piece] = []
    private var detector: Task<Void, Never>?
    private var lastVoiceAt = Date.distantPast
    /// The recognizer in use: pieces from one replaced (another language) are dropped.
    private var generation = 0
    /// Models compared at once: each check transcribes the clip with every one of them.
    private static let maxCandidates = 4
    /// Kept audio after which the language stays as it is (nobody spoke a clear sentence).
    private static let giveUpSeconds = 90.0

    init(store: SessionStore, translator: TranslationService, notes: NotesEngine) {
        self.store = store
        self.translator = translator
        self.notes = notes
        speakers.onVoice = { [weak self] lineID, voice in
            guard let self else { return }
            self.store.setVoice(lineID: lineID, voice)
            if let i = self.lines.firstIndex(where: { $0.id == lineID }) { self.lines[i].voice = voice }
        }
        // 记住的人: a remembered voice is named as soon as it is heard, as on the Mac.
        speakers.onProfile = { [weak self] lineID, voice, match in
            guard let self, let id = self.store.liveID else { return }
            self.store.setVoice(lineID: lineID, voice)
            self.store.setVoiceProfile(id, voice: voice, ref: match.ref)
            self.profiles?.markSeen(id: match.profile.id)
            if let i = self.lines.firstIndex(where: { $0.id == lineID }) { self.lines[i].voice = voice }
            debugLog("voice profiles: heard \(match.profile.name) (\(String(format: "%.2f", match.similarity)))")
        }
    }

    /// 记住的人 (PeoplePage.swift): voices remembered by voiceprint, matched while listening.
    var profiles: SpeakerProfileStore? { didSet { speakers.profiles = profiles } }

    /// A voice just remembered in the meeting still going: it keeps that name from now on.
    func bind(voice: Int, profile: SpeakerProfile) { speakers.bind(voice: voice, profile: profile) }

    /// Distinct voices heard so far.
    var speakerCount: Int { Set(lines.compactMap(\.voice)).count }

    var elapsed: TimeInterval { startedAt.map { Date().timeIntervalSince($0) } ?? 0 }
    var languagePair: (source: String, target: String) { (lang.code, target) }

    func start(source: String, target: String, voices: Bool, speaker: Bool = false) {
        guard !isRunning else { return }
        speakerMode = speaker
        paused = false
        userPaused = false
        auto = source == "auto"
        settled = true
        held = []
        lang = sourceLanguages.first { $0.locale == source } ?? Pref.sourceLang
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
        if Self.silent {
            let s = store.begin()
            store.markLiveInRoom()
            sessionID = s.id
            startedAt = s.startedAt
            notes.begin(s.id)
            status = ""
            debugLog("room: listening silent (debug), no audio, session=\(s.id)")
            onStateChange?()
            return
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            fail(L("请在设置里允许知了使用麦克风"))
            return
        }
        do {
            settled = true
            held = []
            if auto {
                candidates = await autoCandidates()
                guard isRunning else { return }
                lang = initialSourceLanguage(candidates: candidates, last: UserDefaults.standard.string(forKey: Pref.lastDetected),
                                             systemLanguages: Locale.preferredLanguages)
                target = Pref.target(for: lang.code)
                settled = candidates.count < 2
                detection.start()
                debugLog("room: auto candidates=\(candidates.map(\.locale)) start=\(lang.locale)")
            }
            if await Recognition.status(lang.locale) != .installed {
                status = L("正在下载 \(lang.name) 语音模型…")
                try await Recognition.install(lang.locale)
            }
            let stream = try await Recognition.start(lang.locale, drafts: true, confidence: true)
            guard isRunning else { await stream.cancel(); return }
            self.stream = stream
            let s = store.begin()
            // Video played aloud is what the computer plays, not people in the room (the Mac's 会议室 tag).
            if !speakerMode { store.markLiveInRoom() }
            sessionID = s.id
            startedAt = s.startedAt
            notes.begin(s.id)
            audio.voices = voices
            audio.mix = speakerMode
            audio.onInterruption = { [weak self] began in self?.interrupted(began) }
            // 保存会议录音 off: nothing is written; voiceprints still read the last minute in memory.
            let keep = UserDefaults.standard.bool(forKey: Pref.recordAudio)
            try audio.start(recognizer: stream, recording: keep ? AudioFileWriter.partial(store.systemAudioURL(s.id)) : nil,
                            keep: !settled)
            heardVoice = false
            audio.onLevel = { [weak self] v in
                guard let self, !self.paused else { return }
                self.level = v
                if v > 0.55 {
                    self.heardVoice = true
                    self.lastVoiceAt = Date()
                    if self.status == L("没听到声音，请拔掉耳机或调大音量") { self.status = "" }
                    if !self.settled, self.status.isEmpty { self.status = L("正在识别语言…") }
                }
            }
            read(stream)
            status = ""
            if speakerMode { watchSilence(s.id) }
            if !settled { watchLanguage() }
            debugLog("room: listening locale=\(lang.locale) target=\(target) speaker=\(speakerMode) format=\(stream.format) session=\(s.id)")
            onStateChange?()
        } catch {
            debugLog("room: start failed: \(error)")
            fail(Recognition.needsUser(error) ? error.localizedDescription : L("没能下载 \(lang.name) 语音模型"))
        }
    }

    private func read(_ stream: RecognitionStream) {
        generation += 1
        let gen = generation
        reader = Task { [weak self] in
            do {
                for try await piece in stream.results { self?.handle(piece, gen) }
            } catch {
                // A recognizer replaced by another language's ends as it should.
                guard let self, gen == self.generation else { return }
                debugLog("room: recognizer ended: \(error)")
                // The meeting so far is kept; listening stops with a reason rather than hearing nothing.
                guard self.isRunning else { return }
                self.stop()
                self.status = L("识别中断了，请重新开始听")
            }
        }
    }

    // MARK: 自动识别

    /// The models to compare: the two likeliest for this phone (downloaded if they aren't yet),
    /// then any other already here.
    private func autoCandidates() async -> [Lang] {
        let likely = likelySourceLanguages(last: UserDefaults.standard.string(forKey: Pref.lastDetected),
                                           systemLanguages: Locale.preferredLanguages).prefix(2)
        var out: [Lang] = []
        for lang in likely {
            if await Recognition.status(lang.locale) != .installed {
                status = L("正在下载 \(lang.name) 语音模型…")
                do { try await Recognition.install(lang.locale) } catch {
                    debugLog("room: auto can't fetch \(lang.locale): \(error)")
                    continue
                }
            }
            out.append(lang)
        }
        for lang in sourceLanguages where out.count < Self.maxCandidates && !out.contains(lang) {
            if await Recognition.status(lang.locale) == .installed { out.append(lang) }
        }
        return out
    }

    /// Checks the language each time a few more seconds of speech came in, until it is settled.
    private func watchLanguage() {
        detector?.cancel()
        detector = Task { [weak self] in
            var checkedAt = 0.0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.isRunning, !self.settled else { return }
                if self.paused { continue }
                let kept = self.audio.keptSeconds
                if kept > Self.giveUpSeconds {
                    debugLog("room: auto gave up after \(Int(kept))s, staying in \(self.lang.locale)")
                    self.settle()
                    return
                }
                // Someone spoke just now, and enough of it since the last check to tell.
                guard kept >= 5, kept - checkedAt >= 4, Date().timeIntervalSince(self.lastVoiceAt) < 3 else { continue }
                checkedAt = kept
                let ranked = await LanguageDetector.rank(self.audio.keptClip(last: 8), candidates: self.candidates)
                guard self.isRunning, !self.settled else { return }
                debugLog("room: auto check " + ranked.map { String(format: "%@=%.2f", $0.lang.locale, $0.score) }.joined(separator: " "))
                switch self.detection.apply(ranked, active: self.lang) {
                case .confirmed:
                    self.settle()
                case .switchTo(let other, _):
                    await self.switchTo(other)
                default:
                    // Too close to call twice: the language listened in stands.
                    if self.detection.settledEnough { self.settle() }
                }
            }
        }
    }

    /// The language listened in is the one: the lines held come out.
    private func settle() {
        guard !settled else { return }
        settled = true
        audio.stopKeeping()
        UserDefaults.standard.set(lang.locale, forKey: Pref.lastDetected)
        if status == L("正在识别语言…") { status = "" }
        debugLog("room: auto settled on \(lang.locale), \(held.count) lines held")
        let pieces = held
        held = []
        for p in pieces { handle(p, generation) }
        onStateChange?()
    }

    /// Another language: a recognizer for it hears everything kept so far, then the microphone.
    private func switchTo(_ other: Lang) async {
        guard let next = try? await Recognition.start(other.locale, drafts: true, confidence: true) else {
            debugLog("room: auto can't start \(other.locale), staying in \(lang.locale)")
            settle()
            return
        }
        guard isRunning, !settled else { await next.cancel(); return }
        let old = stream
        lang = other
        target = Pref.target(for: other.code)
        held = []
        draft = ""
        draftTranslation = ""
        reader?.cancel()
        stream = next
        read(next)
        audio.replay(into: next)
        Task { await old?.cancel() }
        debugLog("room: auto switched to \(other.locale)")
        settle()
    }

    /// Paused while the audio is taken, then on again by itself; if the system won't give the
    /// microphone back yet (the app is still behind a call screen), again when the app comes back.
    private func interrupted(_ began: Bool) {
        guard isRunning else { return }
        if began {
            guard !paused else { return }
            paused = true
            level = 0
            status = L("已暂停，结束后接着听")
            debugLog("room: interrupted")
            return
        }
        guard paused, !userPaused else { return }
        do {
            try audio.resume()
            paused = false
            status = L("继续听")
            debugLog("room: resumed")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                if self?.status == L("继续听") { self?.status = "" }
            }
        } catch {
            debugLog("room: resume failed: \(error)")
            resumeWhenActive = true
        }
        onStateChange?()
    }

    private var resumeWhenActive = false

    /// 暂停 / 继续 (the Live Activity's button): the microphone off and on, the meeting going on.
    func setPaused(_ on: Bool) {
        guard isRunning, sessionID != nil, on != userPaused else { return }
        userPaused = on
        if on {
            paused = true
            level = 0
            draft = ""
            draftTranslation = ""
            status = L("已暂停")
            if !Self.silent { audio.pause() }
            debugLog("room: paused by the user")
        } else {
            do {
                if !Self.silent { try audio.resume() }
                paused = false
                status = ""
                debugLog("room: resumed by the user")
            } catch {
                debugLog("room: resume failed: \(error)")
                userPaused = true
            }
        }
        onStateChange?()
    }

    /// The app is in front again: a pause whose end came too early to take the microphone back.
    func appBecameActive() {
        guard resumeWhenActive, isRunning, paused else { return }
        resumeWhenActive = false
        interrupted(false)
    }

    /// 手机外放 with nothing loud enough after ten seconds: most likely headphones or a low volume.
    private func watchSilence(_ id: String) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self, self.isRunning, self.sessionID == id, !self.paused,
                  !self.heardVoice, self.lines.isEmpty, self.status.isEmpty else { return }
            self.status = L("没听到声音，请拔掉耳机或调大音量")
        }
    }

    /// Debug (`interrupt:began|ended`): what the system sends for a call or Siri.
    func debugInterrupt(_ began: Bool) { audio.debugInterrupt(began) }

    private func fail(_ message: String) {
        status = message
        isRunning = false
        onStateChange?()
    }

    /// `endedAt`: when the meeting really ended (结束会议 by itself: a little after the last words).
    func stop(endedAt: Date? = nil) {
        guard isRunning else { return }
        detector?.cancel()
        detector = nil
        // Ended before the language was settled: what was heard is kept, in the language listened in.
        if !settled, sessionID != nil { settle() }
        settled = true
        isRunning = false
        paused = false
        userPaused = false
        resumeWhenActive = false
        if !Self.silent { audio.stop() }
        let stream = self.stream, reader = self.reader
        self.stream = nil
        self.reader = nil
        stopping = Task {
            await stream?.finish()
            reader?.cancel()
            notes.finish()
            // A meeting with no line is kept only when the microphone heard voices (its recording holds them).
            let ended = sessionID
            store.end(at: endedAt, heardSpeech: heardVoice)
            if let ended, store.session(ended) != nil { onEnded?(ended) }
            debugLog("room: stopped lines=\(lines.count)")
            sessionID = nil
            startedAt = nil
            level = 0
            onStateChange?()
        }
        onStateChange?()
    }

    private func handle(_ piece: Recognition.Piece, _ gen: Int) {
        guard gen == generation else { return }
        // 自动识别 not settled: a line in what may be the wrong language waits, and no draft shows.
        guard settled else {
            if piece.isFinal { held.append(piece) }
            return
        }
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
            if let sid = sessionID { onHeard?(sid, prev.id) }
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
        if let sid = sessionID { onHeard?(sid, id) }
        if lines.count > 60 { lines.removeFirst(lines.count - 60) }
        last = (id, final, piece.end)
        if let samples = audio.voiceSamples(from: piece.start, to: piece.end) {
            speakers.tag(lineID: id, samples: samples)
        }
        translate(id, final)
    }

    /// Debug (`heard:<text>`): a finished sentence as if the recognizer gave it, in a silent meeting.
    /// The record, its translation and fixes, and the 字幕 page all follow.
    func debugHeard(_ text: String) {
        guard isRunning, Self.silent, sessionID != nil else { return }
        // Half a minute apart, so two lines are never joined as one sentence a pause cut.
        silentClock += 30
        let at = silentClock
        handle(Recognition.Piece(text: text, isFinal: true, start: at, end: at + 2, confidence: nil), generation)
    }

    /// Debug (`heardT:<text>|<translation>`): as `debugHeard`, with the translation given, for
    /// screenshots when no translation service answers.
    func debugHeard(_ text: String, translation: String) {
        debugHeard(text)
        guard let i = lines.lastIndex(where: { $0.src == text }) else { return }
        lines[i].dst = translation
        store.setTranslation(lineID: lines[i].id, translation)
        onLine?(lines[i])
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
    /// 手机外放: other apps keep playing beside us (without it, starting stops their audio).
    var mix = false
    var onLevel: (@MainActor (Float) -> Void)?
    /// true when a call, Siri or another app takes the audio, false when it gives it back.
    var onInterruption: (@MainActor (Bool) -> Void)?
    private var observers: [NSObjectProtocol] = []
    /// Inside an interruption: a configuration change then must not take the microphone back.
    private var held = false

    /// A new engine for each meeting: one restarted after `stop` hears only silence in the simulator.
    private var engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "com.indaloop.cicada.room", qos: .userInitiated)
    private var toRecognizer = PCMConverter()
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
    /// 自动识别: the 16 kHz audio since the start, until the language is settled.
    private var keeping = false
    private var kept: [AVAudioPCMBuffer] = []
    private var keptFrames = 0

    var fedSeconds: Double { queue.sync { fed } }
    var keptSeconds: Double { queue.sync { Double(keptFrames) / 16_000 } }

    /// The last `seconds` of the audio kept, for a language check.
    func keptClip(last seconds: Double) -> [AVAudioPCMBuffer] {
        queue.sync {
            var out: [AVAudioPCMBuffer] = [], frames = 0
            for b in kept.reversed() where Double(frames) < seconds * 16_000 {
                out.insert(b, at: 0)
                frames += Int(b.frameLength)
            }
            return out
        }
    }

    func stopKeeping() {
        queue.sync {
            keeping = false
            kept = []
            keptFrames = 0
        }
    }

    /// Settled on another language: `recognizer` takes over and first hears everything kept, so
    /// nothing said before is lost and its clock runs from the meeting's start as the old one did.
    func replay(into recognizer: RecognitionStream) {
        queue.sync {
            stream = recognizer
            toRecognizer = PCMConverter()
            fed = 0
            let conv = PCMConverter()
            for b in kept {
                guard let c = conv.convert(b, to: recognizer.format) else { continue }
                recognizer.append(c)
                fed += Double(c.frameLength) / c.format.sampleRate
            }
            keeping = false
            kept = []
            keptFrames = 0
        }
    }

    func start(recognizer: RecognitionStream, recording: URL?, keep: Bool = false) throws {
        let session = AVAudioSession.sharedInstance()
        // .measurement: no voice processing, which would duck what the room says as "echo".
        // .defaultToSpeaker sends every app's sound to the speaker, not the earpiece, while we record.
        try session.setCategory(.playAndRecord, mode: .measurement, options: mix ? [.defaultToSpeaker, .mixWithOthers] : [.defaultToSpeaker])
        try session.setActive(true)
        engine = AVAudioEngine()
        queue.sync {
            stream = recognizer
            recordingURL = recording
            fed = 0
            ring = []
            ringStart = 0
            keeping = keep
            kept = []
            keptFrames = 0
        }
        try tapAndStart()
        observe(session)
    }

    private func tapAndStart() throws {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        debugLog("room: input \(format) route=\(AVAudioSession.sharedInstance().currentRoute.inputs.map(\.portName))")
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, let copy = buffer.copy() as? AVAudioPCMBuffer else { return }
            self.queue.async { self.feed(copy) }
        }
        engine.prepare()
        try engine.start()
    }

    /// 暂停: nothing is heard or recorded until `resume`.
    func pause() {
        held = true
        engine.pause()
    }

    /// The microphone again after an interruption, in whatever format the route now has.
    func resume() throws {
        held = false
        try AVAudioSession.sharedInstance().setActive(true)
        if !engine.isRunning { try tapAndStart() }
    }

    private func observe(_ session: AVAudioSession) {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] n in
                guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                let began = type == .began
                self?.held = began
                if began { self?.engine.pause() }
                let cb = self?.onInterruption
                MainActor.assumeIsolated { cb?(began) }
            },
            // A route change (headphones in or out) stops the engine: on again in the new format.
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                guard let self, !self.held, !self.engine.isRunning else { return }
                debugLog("room: engine configuration changed")
                try? self.tapAndStart()
            },
        ]
    }

    func debugInterrupt(_ began: Bool) {
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
                                        userInfo: [AVAudioSessionInterruptionTypeKey: (began ? AVAudioSession.InterruptionType.began : .ended).rawValue])
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
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
        if keeping {
            kept.append(v)
            keptFrames += n
        }
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

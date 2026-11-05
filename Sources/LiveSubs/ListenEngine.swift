import AppKit
import AVFoundation
import CoreMedia
import Network

struct Segment {
    let id: Int
    var text: String
    let sourceCode: String
    var translation: String?
    /// The sentence's audio, 16 kHz mono, when telling voices apart is on.
    var voiceSamples: [Float]? = nil
    /// Where it sits in the recognizer's audio (seconds; `clock` changes with each new recognizer),
    /// and whether Cicada ended it at a pause: what deciding a join needs (`HeardText.continues`).
    var start = 0.0, end = 0.0, clock = 0
    var cut = false
}

/// System audio → language detection → on-device transcription → translation.
/// UI-free: it reports through the callbacks below.
@MainActor
final class ListenEngine {
    // Outputs
    var onSubtitle: ((_ source: String, _ translation: String) -> Void)?
    var onStatus: ((String) -> Void)?
    var onStateChange: (() -> Void)?
    /// A finished sentence; `secondsAgo` ≈ how long ago it started.
    var onFinal: ((Segment, _ secondsAgo: Double) -> Void)?
    var onTranslated: ((_ segmentID: Int, _ translation: String) -> Void)?
    /// Diagnostics: how long a sentence took from its last new words to its translation on screen.
    var onTiming: ((SentenceTiming) -> Void)?

    let settings: AppSettings
    let router = AudioRouter()

    private(set) var isRunning = false
    private(set) var statusText = L("准备就绪")
    private(set) var activeLang: Lang?
    private(set) var languageConfirmed = false
    private(set) var detecting = false
    private(set) var candidates: [Lang] = []
    private(set) var installedLocales: Set<String> = []
    /// The speech model fetched in the background so "auto" has two to compare.
    private(set) var fetchingModel: (lang: Lang, progress: Progress)?
    private var fetchFailed: Set<String> = []
    /// Debug (`models:`): treat only these as installed, plus what is fetched meanwhile, and these as the Mac's languages.
    var simulatedModels: Set<String>?
    var simulatedSystemLanguages: [String]?
    /// Debug (`models:…@<s>`): a background download takes at least this long, like a slow network.
    var simulatedFetchDelay: Double = 0
    /// Debug (`modelFail:`): every model download fails this way (offline, disk, limit, other).
    var simulatedModelFailure: String?
    /// Debug (`network:`): pretend to be on or offline; nil follows the real network.
    var simulatedOnline: Bool? { didSet { networkChanged() } }
    /// A model that couldn't be had while it was needed, shown in 听不出 with what to do.
    private(set) var modelProblem: ModelProblem?
    private let pathMonitor = NWPathMonitor()
    private var realOnline = true
    private var online: Bool { simulatedOnline ?? realOnline }
    private var systemLanguages: [String] { simulatedSystemLanguages ?? Locale.preferredLanguages }
    /// When words were first heard this run: 听不出 is offered once the language stays unknown long after.
    private var firstHeardAt: Date?
    private var askShown = false

    private var audioTap: AudioSource?
    /// 会议室: the microphone Cicada listens to the room with; nil leaves the input on its default.
    var roomDevice: (() -> OutputDevice?)?
    /// The Mac reading a translation aloud, or the talk key held: the room mic hears silence then.
    private var roomMuted = false
    private var startedAt = Date()
    /// Listening to the Mac, and it has played nothing since the start: maybe the meeting is in the room.
    private(set) var macSilent = false
    private var recognizer: RecognitionStream?
    private var resultsTask: Task<Void, Never>?
    private var generation = 0
    private var pendingSwitch: Lang?
    private var needsDetection = true
    private var nextPeriodicDetection = 30.0
    private var lastForeignCheck = Date.distantPast
    private var lastDetectionAt = Date.distantPast
    private var ambiguousDetections = 0
    /// Sentences finished before detection settled the language: recorded once it confirms the
    /// language they were heard in, dropped on a switch (the replay into the new model redoes them).
    private var unconfirmed: [(seg: Segment, at: Date, duration: Double)] = []
    private var recordable: Bool {
        settings.sourceMode != .auto || languageConfirmed || (ambiguousDetections >= 2 && !mismatch)
            || legacySingleLanguage
    }
    /// macOS 14/15 with one Dictation language: nothing to compare it with and none Cicada could
    /// fetch, and every check takes the recognizer from the meeting. It is taken as heard.
    private var legacySingleLanguage: Bool { Recognition.legacy && candidates.count < 2 }
    /// The only model there is checked the audio and it isn't its language: what it writes is
    /// noise, neither shown nor kept, until another model or a pick settles it.
    private(set) var mismatch = false
    private var unsureStreak = 0
    private var sureStreak = 0
    /// The model for the language it starts with couldn't be had, and there is none to fall back
    /// on: nothing is listening, so the problem shows without waiting for 听不出.
    var blockedByModel: Bool { isRunning && modelProblem?.picked == true && recognizer == nil && modelProblem?.lang == activeLang }
    var hidesSource: Bool { mismatch && !recordable }
    /// Someone has spoken and the language isn't settled yet: what 此刻 says instead of 等有人开口.
    var identifyingLanguage: Bool {
        isRunning && settings.sourceMode == .auto && !recordable && firstHeardAt != nil
    }
    /// How much audio a switch can replay: all of it since the start while the language is unknown.
    /// Three minutes (≈6 MB): a model download seen taking 106 s fits with room to spare.
    private static let holdUnknown = 180.0
    private func updateHold() {
        router.holdAudio(settings.sourceMode == .auto && !languageConfirmed ? Self.holdUnknown : 10)
    }
    private var failureStreak = 0

    private var segments: [Segment] = []
    private var nextSegmentID = 0
    /// Segments joined onto the line before: a retry of theirs would translate half a sentence.
    private var joinedAway: Set<Int> = []
    private var volatileText = ""
    private var volatileTranslation = ""
    private var lastVolatileSent = ""
    private var volatileInFlight = false
    private var volatileEpoch = 0
    private var tickTimer: Timer?
    private var ticks = 0
    /// When the line in progress started and last grew, for cutting long ones at a pause.
    private var volatileStartedAt = Date()
    private var volatileStartClock = 0.0
    private var volatileChangedAt = Date()
    private var cutting = false
    private var lastCut = ""
    private var lastCutThrough = 0.0
    /// A cut was asked for: the next final line ends at Cicada's pause, not the speaker's.
    private var cutAsked = false
    /// Final transcript time and how long after the last word it came, per segment, until its translation lands.
    private var finalTiming: [Int: (at: Date, recognize: Double?)] = [:]

    init(settings: AppSettings) {
        self.settings = settings
        // A download that failed for want of a network resumes when there is one again.
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.realOnline != up else { return }
                    self.realOnline = up
                    self.networkChanged()
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "cicada.network"))
    }

    var resolvedTarget: String { settings.resolvedTarget(source: activeLang?.code) }

    func languageSummary() -> String {
        let target = targetName(resolvedTarget)
        switch settings.sourceMode {
        case .fixed(let lang):
            return "\(lang.name) → \(target)"
        case .auto:
            guard let lang = activeLang else { return L("自动识别 → \(target)") }
            if detecting || !languageConfirmed { return L("\(lang.name)（识别中…）→ \(target)") }
            return "\(lang.name) → \(target)"
        }
    }

    private func setStatus(_ text: String) {
        statusText = text
        onStatus?(text)
        onStateChange?()
    }

    // MARK: Models

    func refreshInstalledLocales() async {
        installedLocales = await Recognition.installedLocales()
        if let simulatedModels { installedLocales.formIntersection(simulatedModels) }
        candidates = sourceLanguages.filter { installedLocales.contains($0.locale) }
        debugLog("installed speech models: \(installedLocales.sorted()) candidates=\(candidates.map(\.locale))")
        onStateChange?()
        // Also when not listening: at launch the Mac's language and English come in quietly, so
        // the first meeting already has two models to compare.
        fetchSecondModel()
    }

    /// Detection needs two models: a Mac with fewer fetches the likeliest missing ones in the
    /// background, one at a time (each one's end refreshes the list and asks for the next).
    private func fetchSecondModel(besides starting: Lang? = nil) {
        guard settings.sourceMode == .auto, fetchingModel == nil, candidates.count < 2 else { return }
        let last = UserDefaults.standard.string(forKey: "lastDetected")
        // The model being started is fetched by `ensureModel` already. At a start that is `starting`:
        // `activeLang` is still the last run's then, and may be a model since taken away.
        let busy = starting ?? (isRunning ? activeLang : nil)
        guard let lang = likelySourceLanguages(last: last, systemLanguages: systemLanguages).first(where: {
            !installedLocales.contains($0.locale) && !fetchFailed.contains($0.locale) && $0 != busy
        }) else { return }
        fetchingModel = (lang, Progress())
        Task { [weak self] in
            var ok = false
            do {
                if await Recognition.status(lang.locale) == .unsupported {
                    debugLog("model fetch: \(lang.locale) unsupported")
                } else {
                    try await Recognition.install(lang.locale) { progress in
                        self?.fetchingModel = (lang, progress)
                        self?.onStateChange?()
                        debugLog("model fetch: downloading \(lang.locale)")
                    }
                    if let delay = self?.simulatedFetchDelay, delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                    if let fail = self?.simulatedModelFailure { throw ModelProblem.simulated(fail) }
                    ok = true
                }
            } catch {
                debugLog("model fetch \(lang.locale) failed: \(error)")
                if let self, await self.modelFailed(lang, error, picked: false) {
                    // A slot was given back: try again straight away.
                    self.fetchingModel = nil
                    self.fetchSecondModel()
                    return
                }
            }
            guard let self else { return }
            debugLog("model fetch: \(lang.locale) \(ok ? "ready" : "gave up")")
            self.fetchingModel = nil
            // The new model gets its 20 s to settle the language before 听不出 is offered.
            if self.firstHeardAt != nil { self.firstHeardAt = Date() }
            if ok {
                self.mismatch = false
                self.unsureStreak = 0
                self.sureStreak = 0
                self.simulatedModels?.insert(lang.locale)
                if self.modelProblem?.lang == lang { self.modelProblem = nil }
            } else {
                self.fetchFailed.insert(lang.locale)
            }
            self.needsDetection = true
            await self.refreshInstalledLocales()
            if ok { self.detectHeld() }
        }
    }

    // MARK: Start / stop

    func start() {
        guard !isRunning else { return }
        guard Recognition.isAvailable else {
            setStatus(L("此 Mac 不支持本机语音识别"))
            return
        }
        guard !Recognition.authorizationDenied else {
            setStatus(Recognition.notAllowed.localizedDescription)
            return
        }
        languageConfirmed = false
        pendingSwitch = nil
        needsDetection = true
        nextPeriodicDetection = 30
        ambiguousDetections = 0
        unsureStreak = 0
        sureStreak = 0
        unconfirmed = []
        lastDetectionAt = .distantPast
        firstHeardAt = nil
        askShown = false
        fetchFailed = []
        modelProblem = nil
        mismatch = false
        startedAt = Date()
        macSilent = false
        updateHold()
        debugLog("listen start mode=\(settings.sourceMode) target=\(resolvedTarget)")

        guard startTap() else { return }
        router.setVoiceCapture(settings.speakerVoices)
        isRunning = true
        startTickTimer()

        let initial: Lang
        switch settings.sourceMode {
        case .fixed(let lang):
            initial = lang
        case .auto:
            let last = UserDefaults.standard.string(forKey: "lastDetected")
            let likely = likelySourceLanguages(last: last, systemLanguages: systemLanguages)
            // No model at all: start with the likeliest; the second follows in the background.
            initial = candidates.first(where: { $0.locale == last }) ?? candidates.first ?? likely.first ?? sourceLanguages[0]
        }
        // 会议室 the first time: nothing is heard until macOS's microphone question is answered.
        setStatus(audioTap == nil ? L("等你允许使用麦克风") : L("正在听"))
        Task { await switchTranscriber(to: initial) }
        fetchSecondModel(besides: initial)
    }

    /// The last run heard speech (a few seconds of it), read when its meeting ends.
    private(set) var heardSpeech = false

    func stop() {
        // Lines still waiting for the language are recorded rather than dropped: the meeting
        // ended before detection settled it. Not when the only model said the audio isn't its
        // language: those lines are noise, and the recording keeps what was said.
        if settings.sourceMode == .auto, !recordable, !mismatch { flushUnconfirmed() }
        unconfirmed = []
        heardSpeech = isRunning && (router.stats().voicedTotal >= 3 || firstHeardAt != nil)
        isRunning = false
        generation += 1
        tickTimer?.invalidate()
        tickTimer = nil
        audioTap?.stop()
        audioTap = nil
        router.reset()
        resultsTask?.cancel()
        resultsTask = nil
        if let recognizer {
            Task { await recognizer.cancel() }
        }
        recognizer = nil
        segments.removeAll()
        volatileText = ""
        volatileTranslation = ""
        lastVolatileSent = ""
        volatileInFlight = false
        detecting = false
        setStatus(L("已暂停"))
    }

    func reconnectAudio() {
        guard isRunning else { return }
        audioTap?.stop()
        audioTap = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                if self.startTap() { self.setStatus(L("正在听")) }
            }
        }
    }

    @discardableResult
    private func startTap() -> Bool {
        router.setRoomGate(settings.listensToRoom)
        if settings.listensToRoom { return startRoomMic() }
        if SystemAudioPermission.status() == .denied {
            debugLog("audio tap: system audio recording was refused")
            isRunning = false
            setStatus(L("请在系统设置里允许“系统音频录制”，再重新打开知了"))
            return false
        }
        let tap = SystemAudioTap()
        let router = self.router
        tap.onAudio = { pcm in router.push(pcm) }
        do {
            try tap.start()
            audioTap = tap
            debugLog("audio tap started, permission \(SystemAudioPermission.status().map { "\($0)" } ?? "unreadable")")
            return true
        } catch {
            debugLog("audio tap start failed: \(error)")
            isRunning = false
            setStatus(L("无法读取系统音频，请在系统设置里允许“系统音频录制”"))
            return false
        }
    }

    /// 会议室. The first time, macOS asks for the microphone; listening starts once it is allowed.
    private func startRoomMic() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            debugLog("room mic: asking for the microphone")
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.isRunning, self.settings.listensToRoom, self.audioTap == nil else { return }
                        if granted { if self.startRoomMic() { self.setStatus(L("正在听")) } } else { self.roomMicDenied() }
                    }
                }
            }
            return true
        default:
            roomMicDenied()
            return false
        }
        let mic = RoomMic(device: roomDevice?())
        mic.muted = roomMuted
        let router = self.router
        mic.onAudio = { pcm in router.push(pcm) }
        do {
            try mic.start()
            audioTap = mic
            debugLog("room mic started: \(mic.deviceName)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.audioTap === mic else { return }
                    debugLog("room mic speech threshold \(String(format: "%.4f", self.router.gateThreshold()))")
                }
            }
            return true
        } catch {
            debugLog("room mic start failed: \(error)")
            isRunning = false
            setStatus(L("麦克风无法启动，请在系统设置里允许\(appDisplayName)使用麦克风"))
            return false
        }
    }

    private func roomMicDenied() {
        debugLog("room mic: microphone not allowed")
        if isRunning { stop() }
        setStatus(L("麦克风无法启动，请在系统设置里允许\(appDisplayName)使用麦克风"))
    }

    /// While the Mac speaks into the room (or you hold the talk key) the room mic hears silence.
    func setRoomMuted(_ on: Bool) {
        guard on != roomMuted else { return }
        roomMuted = on
        (audioTap as? RoomMic)?.muted = on
        if settings.listensToRoom { debugLog("room mic \(on ? "muted" : "open")") }
    }

    /// 听哪里 changed: while listening, the new source takes over in the same meeting.
    func listenSourceChanged() {
        debugLog("listen source=\(settings.listenSource)")
        reconnectAudio()
        onStateChange?()
    }

    // MARK: Settings changes

    func sourceModeChanged() {
        languageConfirmed = false
        mismatch = false
        updateHold()
        pendingSwitch = nil
        needsDetection = true
        if isRunning, case .fixed(let lang) = settings.sourceMode {
            // Chosen by hand: what was held back in that language is now confirmed.
            if lang == activeLang { flushUnconfirmed() }
            Task { await switchTranscriber(to: lang) }
        }
        fetchSecondModel()
        onStateChange?()
    }

    func targetChanged() {
        retranslateVisible()
        onStateChange?()
    }

    func redetect() {
        guard isRunning, settings.sourceMode == .auto else { return }
        languageConfirmed = false
        updateHold()
        pendingSwitch = nil
        needsDetection = true
        ambiguousDetections = 0
        unsureStreak = 0
        sureStreak = 0
        lastDetectionAt = .distantPast
        onStateChange?()
    }

    // MARK: Transcriber

    private func ensureModel(for lang: Lang) async throws {
        // Already coming in the background (fetched at launch): wait for it rather than ask twice.
        while fetchingModel?.lang == lang {
            setStatus(L("正在下载 \(lang.name) 语音模型…"))
            try await Task.sleep(for: .milliseconds(300))
        }
        let status = await Recognition.status(lang.locale)
        if status == .installed {
            if simulatedModels?.insert(lang.locale).inserted == true { await refreshInstalledLocales() }
            return
        }
        debugLog("model status for \(lang.locale): \(status)")
        guard status != .unsupported else { throw Recognition.unsupported(lang.locale) }
        if let fail = simulatedModelFailure { throw ModelProblem.simulated(fail) }
        try await Recognition.install(lang.locale) { _ in self.setStatus(L("正在下载 \(lang.name) 语音模型…")) }
        simulatedModels?.insert(lang.locale)
        await refreshInstalledLocales()
    }

    private func switchTranscriber(to lang: Lang, replaySeconds: Double = 0) async {
        generation += 1
        let gen = generation
        router.detach()
        resultsTask?.cancel()
        resultsTask = nil
        if let old = recognizer {
            recognizer = nil
            await old.cancel()
        }
        guard isRunning, gen == generation else { return }

        let previous = activeLang
        if activeLang != lang {
            segments.removeAll()
            unconfirmed = []
            mismatch = false
        }
        activeLang = lang
        volatileText = ""
        volatileTranslation = ""
        lastVolatileSent = ""
        volatileEpoch += 1
        cutAsked = false
        // The new transcriber's audio clock starts again at zero.
        lastCutThrough = 0
        onStateChange?()

        do {
            do {
                try await ensureModel(for: lang)
            } catch where settings.sourceMode == .auto && previous != nil && previous != lang {
                // A model that can't be had (no network, or the Mac's five reserved languages taken):
                // retrying would fail the same way every 30 s. Go back to the one that works, unsure again.
                debugLog("model for \(lang.locale) unavailable, back to \(previous!.locale): \(error)")
                if await modelFailed(lang, error, picked: true) {
                    guard isRunning, gen == generation else { return }
                    Task { await switchTranscriber(to: lang, replaySeconds: replaySeconds) }
                    return
                }
                fetchFailed.insert(lang.locale)
                languageConfirmed = false
                // macOS 14/15: a language is added in Dictation settings, which only the user can do.
                setStatus(Recognition.needsUser(error) ? error.localizedDescription : L("没能下载 \(lang.name) 语音模型"))
                guard isRunning, gen == generation else { return }
                Task { await switchTranscriber(to: previous!) }
                return
            } catch {
                // Nothing to fall back on (a language chosen in settings, or the first model on this
                // Mac): say why instead of retrying every 30 s; the network back or 再试一次 resumes.
                debugLog("model for \(lang.locale) unavailable, nothing to fall back on: \(error)")
                if await modelFailed(lang, error, picked: true) {
                    guard isRunning, gen == generation else { return }
                    Task { await switchTranscriber(to: lang, replaySeconds: replaySeconds) }
                    return
                }
                setStatus(Recognition.needsUser(error) ? error.localizedDescription : L("没能下载 \(lang.name) 语音模型"))
                return
            }
            guard isRunning, gen == generation else { return }
            let stream = try await Recognition.start(lang.locale, drafts: true, confidence: true)
            guard isRunning, gen == generation else {
                await stream.cancel()
                return
            }
            router.attach(stream, replaySeconds: replaySeconds)
            updateHold()
            self.recognizer = stream
            resultsTask = Task { [weak self] in
                do {
                    for try await piece in stream.results {
                        self?.handle(piece, generation: gen)
                    }
                } catch {
                    self?.recognitionFailed(error, generation: gen)
                }
            }
            debugLog("transcriber started recognizer=\(Recognition.name) locale=\(lang.locale) format=\(stream.format)")
            setStatus(L("正在听"))
        } catch {
            debugLog("transcriber start failed locale=\(lang.locale): \(error)")
            recognitionFailed(error, generation: gen)
        }
    }

    private func recognitionFailed(_ error: Error, generation gen: Int) {
        guard gen == generation, isRunning else { return }
        debugLog("recognition error: \(error)")
        failureStreak += 1
        var delay = min(30.0, 2.0 * pow(2.0, Double(failureStreak - 1)))
        if Recognition.needsUser(error) {
            // Fixed in System Settings, not by waiting: say what to do, and try again soon after.
            delay = 3
            setStatus(error.localizedDescription)
        } else {
            setStatus(L("识别出错，\(Int(delay)) 秒后重试"))
        }
        guard let lang = activeLang else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isRunning, gen == self.generation else { return }
                Task { await self.switchTranscriber(to: lang) }
            }
        }
    }

    private func handle(_ result: Recognition.Piece, generation gen: Int) {
        guard gen == generation, isRunning else { return }
        failureStreak = 0
        var text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isFinal {
            text = HeardText.clean(text)
            let fuller = HeardText.fuller(final: text, draft: volatileText)
            if fuller != text {
                debugLog("final dropped words the draft had: kept the draft")
                contentLog("FINAL was: \(text)")
                text = fuller
            }
            volatileText = ""
            volatileEpoch += 1
            // A "." or "…" from a breath or a click is no sentence: Ling would answer it with a note that
            // there was nothing to translate, and it would sit in the record as a line.
            guard text.contains(where: \.isLetter) else { renderSubtitles(); return }
            let conf = result.confidence ?? 1
            let provisional = volatileTranslation.isEmpty ? nil : volatileTranslation
            var seg = Segment(id: nextSegmentID, text: text, sourceCode: activeLang?.code ?? "auto", translation: provisional)
            seg.start = result.start
            seg.end = result.end
            seg.clock = gen
            seg.cut = cutAsked
            cutAsked = false
            if settings.speakerVoices {
                seg.voiceSamples = router.voiceSamples(from: result.start, to: result.end)
            }
            nextSegmentID += 1
            // How long ago, in real time, the sentence's last word was spoken.
            let ago = router.fedSeconds() - result.end
            finalTiming[seg.id] = (Date(), ago.isFinite && ago >= 0 && ago < 30 ? ago : nil)
            if finalTiming.count > 40, let oldest = finalTiming.keys.min() { finalTiming[oldest] = nil }
            var shown = seg
            shown.voiceSamples = nil // the audio only travels to the meeting record
            segments.append(shown)
            // Only the last few are shown; in notes mode nothing clears them after a pause.
            if segments.count > 30 { segments.removeFirst(segments.count - 30) }
            if segments.count > 8 { segments.removeFirst(segments.count - 8) }
            volatileTranslation = ""
            lastVolatileSent = ""
            contentLog(String(format: "FINAL conf=%.2f [%@] %@", conf, activeLang?.locale ?? "?", text))
            let duration = max(0, result.end - result.start)
            // Only confirmed-language sentences go into the meeting record; earlier ones wait.
            let spoken = duration.isFinite ? duration : 0
            if recordable {
                // A replayed line was spoken longer ago than it lasted: the audio clock knows when.
                let since = router.fedSeconds() - seg.start
                onFinal?(seg, since.isFinite && since > spoken + 5 ? since : spoken)
            } else {
                unconfirmed.append((seg, Date(), spoken))
                // Held lines keep their audio only while recent: an undecided language must not pile up minutes of it.
                if unconfirmed.count > 20 { unconfirmed[unconfirmed.count - 21].seg.voiceSamples = nil }
            }
            translateSegment(id: seg.id)
            if settings.sourceMode == .auto, conf < 0.6, text.count >= 4 {
                needsDetection = true
            }
            checkForeignLetters(text)
        } else {
            if firstHeardAt == nil, text.contains(where: \.isLetter) { firstHeardAt = Date() }
            if volatileText.isEmpty { volatileStartedAt = Date(); volatileStartClock = router.fedSeconds() }
            if text != volatileText { volatileChangedAt = Date() }
            volatileText = text
            checkForeignLetters(text)
        }
        renderSubtitles()
    }

    private func renderSubtitles() {
        guard !(segments.isEmpty && volatileText.isEmpty) else { return }
        let srcJoin = joiner(for: activeLang?.code ?? "en")
        let source = [segments.last?.text ?? "", volatileText].filter { !$0.isEmpty }
            .joined(separator: srcJoin.isEmpty ? " " : srcJoin)
        if settings.sourceMode == .auto, !recordable {
            onSubtitle?(source, asksLanguage ? L("听不出是哪种语言，到菜单栏里选一下") : L("正在识别语言…"))
            return
        }
        let tgtJoin = joiner(for: resolvedTarget)
        var parts = segments.suffix(3).compactMap(\.translation)
        if !volatileTranslation.isEmpty { parts.append(volatileTranslation) }
        onSubtitle?(source, parts.joined(separator: tgtJoin.isEmpty ? "" : " "))
    }

    // MARK: Language detection

    /// A Chinese, Japanese or Korean model hearing English writes it out in Latin letters
    /// ("OKo where wen the lanch", "reigifridadeinali") with a confidence that looks fine; without
    /// this the switch waits for the next periodic check, 20 s of speech later. Only a line that
    /// ends in a run of Latin letters counts: English words mixed into Chinese ("还在做 onboarding
    /// 的 UI") would ask for checks that each risk a wrong switch.
    private func checkForeignLetters(_ text: String) {
        guard settings.sourceMode == .auto, !needsDetection, let code = activeLang?.code,
              ["zh", "ja", "ko"].contains(where: { code.hasPrefix($0) }),
              Date().timeIntervalSince(lastForeignCheck) >= 8, HeardText.endsInLatin(text) else { return }
        lastForeignCheck = Date()
        debugLog("detect: Latin letters from the \(code) model, checking the language")
        needsDetection = true
    }

    private func maybeDetectLanguage() {
        // One model can still tell whether the audio is its language, until the language is known.
        guard isRunning, settings.sourceMode == .auto, !detecting, !legacySingleLanguage,
              candidates.count >= 2 || (!languageConfirmed && candidates.first == activeLang && activeLang != nil) else { return }
        var stats = router.stats(window: 6)
        if stats.silenceRun >= AudioRouter.gapSeconds { needsDetection = true }
        if stats.voicedTotal >= nextPeriodicDetection { needsDetection = true }
        guard needsDetection, Date().timeIntervalSince(lastDetectionAt) >= 3 else { return }
        let clipSeconds = min(6, stats.sinceGap)
        guard clipSeconds >= 3 else { return }
        stats = router.stats(window: clipSeconds)
        guard stats.recentVoiced >= 2.5 else { return }

        nextPeriodicDetection = stats.voicedTotal + 20
        runDetection(router.snapshot(seconds: clipSeconds))
    }

    /// A model that just arrived checks the speech held back, without waiting for someone to talk again.
    private func detectHeld() {
        guard isRunning, settings.sourceMode == .auto, !languageConfirmed, !detecting, candidates.count >= 2 else { return }
        let held = router.voicedSnapshot(seconds: 6)
        guard held.seconds >= 2.5 else { return }
        debugLog(String(format: "detect: new model, checking %.1f s of held speech", held.seconds))
        runDetection(held.buffers)
    }

    private func runDetection(_ clip: [AVAudioPCMBuffer]) {
        needsDetection = false
        lastDetectionAt = Date()
        detecting = true
        onStateChange?()
        let candidates = self.candidates
        Task { [weak self] in
            let started = Date()
            let ranked = await LanguageDetector.rank(clip, candidates: candidates)
            guard let self else { return }
            self.detecting = false
            guard self.isRunning, self.settings.sourceMode == .auto else { return }
            let summary = ranked.map { String(format: "%@ s=%.2f c=%.2f n=%d", $0.lang.locale, $0.score, $0.confidence, $0.chars) }
            debugLog("detect (\(String(format: "%.2f", Date().timeIntervalSince(started)))s): \(summary.joined(separator: " | "))")
            self.applyDetection(ranked)
            self.onStateChange?()
        }
    }

    private func applyDetection(_ ranked: [LanguageDetector.Candidate]) {
        guard let best = ranked.first else { return }
        if ranked.count == 1 {
            // The right model is ≥0.85 sure; English heard by a French model scored 0.12.
            guard best.lang == activeLang, best.confidence >= 0.6, best.score >= 0.6 else {
                // Asked again only by the usual triggers (a pause, 20 s more speech), or when a model arrives.
                if !mismatch { debugLog("detect: not \(best.lang.locale), holding lines for another model") }
                mismatch = true
                // Checked on speech: someone is talking even if the model wrote nothing down.
                if firstHeardAt == nil { firstHeardAt = Date() }
                renderSubtitles()
                return
            }
            mismatch = false
        }
        // Every model unsure: a language with no model here, not a close call. On their own language
        // English scored 0.95, Chinese 0.84, Korean 0.97; Japanese heard by the Chinese model 0.66,
        // German and Spanish heard by English or Chinese at most 0.48.
        // Twice in a row, so one noisy clip doesn't ask; nothing is kept meanwhile.
        if ranked.count >= 2, best.score < 0.72 {
            unsureStreak += 1
            sureStreak = 0
            if unsureStreak >= 2, !mismatch, !languageConfirmed {
                debugLog("detect: none of \(ranked.map(\.lang.locale).joined(separator: ",")), holding lines")
                mismatch = true
                if firstHeardAt == nil { firstHeardAt = Date() }
            }
            if !languageConfirmed { needsDetection = true }
            renderSubtitles()
            return
        }
        unsureStreak = 0
        // Said no once: Japanese heard by the Chinese model reached 0.73 now and then, so one sure
        // answer doesn't take it back; two in a row do.
        if mismatch, ranked.count >= 2 {
            sureStreak += 1
            if sureStreak < 2 {
                needsDetection = true
                return
            }
        }
        let runnerUp = ranked.dropFirst().first?.score ?? 0
        guard best.confidence >= 0.6, best.score - runnerUp >= 0.08 else {
            debugLog("detect: ambiguous, keeping \(activeLang?.locale ?? "-")")
            ambiguousDetections += 1
            if !languageConfirmed { needsDetection = true }
            if recordable { flushUnconfirmed() }
            renderSubtitles()
            return
        }
        if best.lang == activeLang {
            languageConfirmed = true
            mismatch = false
            updateHold()
            flushUnconfirmed()
            pendingSwitch = nil
            UserDefaults.standard.set(best.lang.locale, forKey: "lastDetected")
            renderSubtitles()
            return
        }
        let currentScore = ranked.first(where: { $0.lang == activeLang })?.score ?? 0
        let overwhelming = best.score - currentScore >= 0.30
        if !languageConfirmed || overwhelming || pendingSwitch == best.lang {
            debugLog("detect: switching \(activeLang?.locale ?? "-") → \(best.lang.locale)")
            // The first answer replays everything held back; a later switch, the last sentence or so.
            let replay = languageConfirmed ? 8 : Self.holdUnknown
            languageConfirmed = true
            unconfirmed = []
            pendingSwitch = nil
            UserDefaults.standard.set(best.lang.locale, forKey: "lastDetected")
            Task { await switchTranscriber(to: best.lang, replaySeconds: replay) }
        } else {
            pendingSwitch = best.lang
            needsDetection = true
        }
    }

    /// Why a model couldn't be had. At the five-model limit a model Cicada isn't using is given
    /// back first: true means one was, and the caller tries again; otherwise the problem is kept
    /// for 听不出 to show.
    private func modelFailed(_ lang: Lang, _ error: Error, picked: Bool) async -> Bool {
        let cause = ModelProblem.cause(of: error, online: online, freeBytes: ModelProblem.freeBytes())
        debugLog("model problem \(lang.locale): \(cause)")
        if cause == .limit, simulatedModelFailure == nil, await freeModelSlot(for: lang) { return true }
        modelProblem = ModelProblem(lang: lang, cause: cause, picked: picked)
        onStateChange?()
        return false
    }

    /// Gives back a reserved model that isn't in use and isn't a likely language, oldest guess first.
    private func freeModelSlot(for wanted: Lang) async -> Bool {
        let keep = Set(likelySourceLanguages(last: UserDefaults.standard.string(forKey: "lastDetected"),
                                             systemLanguages: systemLanguages).map(\.locale)
                       + [wanted.locale, activeLang?.locale].compactMap { $0 })
        for locale in await Recognition.reservedLocales() where !keep.contains(locale) {
            if await Recognition.release(locale) {
                debugLog("model limit: gave back \(locale) for \(wanted.locale)")
                await refreshInstalledLocales()
                return true
            }
        }
        return false
    }

    /// 再试一次, or the network back for a download that needed it.
    func retryModel() {
        guard let p = modelProblem else { return }
        debugLog("model retry: \(p.lang.locale)")
        modelProblem = nil
        fetchFailed.remove(p.lang.locale)
        if p.picked, isRunning, p.lang == activeLang, recognizer == nil {
            // Nothing is listening: start the language again, with all the speech held since the start.
            Task { await switchTranscriber(to: p.lang, replaySeconds: languageConfirmed ? 0 : Self.holdUnknown) }
        } else if p.picked, isRunning {
            languageConfirmed = false
            pickLanguage(p.lang)
        } else {
            fetchSecondModel()
        }
        onStateChange?()
    }

    /// macOS 14/15: the language added in Dictation settings carries on by itself, as the network does.
    private func checkDictation() {
        guard isRunning, let p = modelProblem, case .dictation = p.cause, Recognition.dictationEnabled else { return }
        Task {
            guard await Recognition.status(p.lang.locale) == .installed, self.modelProblem == p else { return }
            self.retryModel()
        }
    }

    private func networkChanged() {
        debugLog("network \(online ? "up" : "down")")
        if online, modelProblem?.cause == .offline { retryModel() }
    }

    /// 听不出: the language is still unknown 20 s after the first words, with nothing under way that
    /// could settle it (no check running, no model coming). Too quiet for a check, two models that
    /// keep disagreeing, a model that couldn't be fetched: one click ends each.
    var asksLanguage: Bool {
        guard isRunning, settings.sourceMode == .auto, !languageConfirmed, fetchingModel == nil,
              !legacySingleLanguage, let firstHeardAt else { return false }
        // Once offered it stays until answered: a check running meanwhile doesn't make it blink.
        if askShown { return true }
        // The one model said no and no other is coming: nothing is shown or kept, so ask now.
        if mismatch { return true }
        return !detecting && Date().timeIntervalSince(firstHeardAt) >= 20
    }

    /// What 听不出 offers first; the rest sit under 更多.
    var askChoices: [Lang] {
        // None of the installed ones: offer what isn't installed; they are a 其实是 aside.
        if mismatch {
            let others = (likelySourceLanguages(last: nil, systemLanguages: systemLanguages) + sourceLanguages)
                .filter { !candidates.contains($0) && !fetchFailed.contains($0.locale) }
            var out: [Lang] = []
            for lang in others where !out.contains(lang) { out.append(lang) }
            if !out.isEmpty { return Array(out.prefix(3)) }
        }
        var out = likelySourceLanguages(last: activeLang?.locale, systemLanguages: systemLanguages)
        for lang in candidates + sourceLanguages where !out.contains(lang) { out.append(lang) }
        return Array(out.filter { !fetchFailed.contains($0.locale) }.prefix(3))
    }

    /// The language picked from 听不出: confirmed for this run (settings stay on auto). A model
    /// not on the Mac yet is downloaded as when it is detected.
    func pickLanguage(_ lang: Lang) {
        guard isRunning, settings.sourceMode == .auto else { return }
        debugLog("language picked: \(lang.locale) (was \(activeLang?.locale ?? "-"))")
        let replay = languageConfirmed ? 8 : Self.holdUnknown
        languageConfirmed = true
        mismatch = false
        pendingSwitch = nil
        needsDetection = false
        askShown = false
        unsureStreak = 0
        sureStreak = 0
        modelProblem = nil
        UserDefaults.standard.set(lang.locale, forKey: "lastDetected")
        if lang == activeLang, recognizer != nil {
            updateHold()
            flushUnconfirmed()
            renderSubtitles()
            onStateChange?()
        } else {
            // The hold shrinks once the new model is attached, after it took the replay.
            unconfirmed = []
            Task { await switchTranscriber(to: lang, replaySeconds: replay) }
        }
    }

    /// Records the sentences held back before the language was confirmed, with the translation
    /// they got meanwhile and their time of speaking.
    private func flushUnconfirmed() {
        let held = unconfirmed
        unconfirmed = []
        for h in held {
            var seg = h.seg
            if let now = segments.first(where: { $0.id == seg.id }) { seg.translation = now.translation }
            onFinal?(seg, h.duration + Date().timeIntervalSince(h.at))
        }
    }

    // MARK: Translation

    private func startTickTimer() {
        tickTimer?.invalidate()
        // Pauses are short: look for one four times a second; the rest runs once a second.
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.maybeCutSentence()
                self.ticks += 1
                guard self.ticks % 4 == 0 else { return }
                self.translateVolatile()
                self.maybeDetectLanguage()
                let silent = RoomPrompt.asks(room: self.settings.listensToRoom,
                                             listened: Date().timeIntervalSince(self.startedAt),
                                             voiced: self.router.stats().voicedTotal)
                if silent != self.macSilent {
                    self.macSilent = silent
                    debugLog("mac silent \(silent)")
                    self.onStateChange?()
                }
                if self.ticks % 20 == 0 { self.checkDictation() }
                // The fetch's progress, and 听不出 coming or going, redraw the windows.
                let ask = self.asksLanguage
                if ask != self.askShown || self.fetchingModel != nil {
                    if ask != self.askShown { debugLog("language ask \(ask ? "shown" : "hidden")") }
                    let flipped = ask != self.askShown
                    self.askShown = ask
                    self.onStateChange?()
                    if flipped { self.renderSubtitles() }
                }
            }
        }
        tickTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Set by the app: the shared translation chain.
    var translator: TranslationService?
    /// Subtitles set to the original only: nothing is translated.
    var translationOff: () -> Bool = { false }

    func translate(_ text: String, source: String, target: String? = nil,
                   kind: TranslationService.Kind = .sentence, trace: TranslateTrace? = nil) async -> String? {
        let target = target ?? resolvedTarget
        if source == target { return text }
        let out = await translator?.translate(text, source: source, target: target, kind: kind, trace: trace)
        if out == nil, segments.allSatisfy({ $0.translation == nil }) && volatileTranslation.isEmpty {
            onSubtitle?(volatileText.isEmpty ? (segments.last?.text ?? "") : volatileText, L("翻译暂不可用"))
        }
        return out
    }

    /// `retry` counts the earlier tries of a line every provider failed (Ling rate-limited while
    /// Google answers 429, and no on-device model): it is asked again a little later, as the copy
    /// `again`, since it may have scrolled off the bar meanwhile; the record still takes it.
    private func translateSegment(id: Int, retry: Int = 0, again: Segment? = nil) {
        guard !translationOff(), let seg = again ?? segments.first(where: { $0.id == id }) else { return }
        let trace = TranslateTrace()
        let asked = Date()
        // The target follows the detected language; log the one this call used, not the one after.
        let target = resolvedTarget
        Task { [weak self] in
            guard let self else { return }
            let result = await self.translate(seg.text, source: seg.sourceCode, target: target, trace: trace)
            if let timing = self.finalTiming.removeValue(forKey: id), !trace.attempts.isEmpty {
                self.onTiming?(SentenceTiming(at: timing.at, side: "them", chars: seg.text.count, recognize: timing.recognize,
                                              queue: trace.lingQueue, translate: Date().timeIntervalSince(asked), voice: nil,
                                              failed: trace.failedSeconds, via: result == nil ? "none" : trace.via,
                                              fallbacks: trace.fallbacks))
            }
            guard self.isRunning else { return }
            // The line was joined with the next one meanwhile: only the whole sentence's translation counts.
            if let now = self.segments.first(where: { $0.id == id }), now.text != seg.text { return }
            guard let out = result else {
                guard retry < 2 else { return }
                let delay = retry == 0 ? 10.0 : 20.0
                debugLog("translate: every provider failed, again in \(Int(delay)) s")
                // Segment ids are never reused, so a language switch in between does not matter.
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.isRunning, !self.joinedAway.contains(id) else { return }
                        // Joined meanwhile: the joined sentence was asked for on its own.
                        if let now = self.segments.first(where: { $0.id == id }), now.text != seg.text { return }
                        self.translateSegment(id: id, retry: retry + 1, again: seg)
                    }
                }
                return
            }
            if let idx = self.segments.firstIndex(where: { $0.id == id }) {
                self.segments[idx].translation = out
            }
            contentLog("TRANSLATE [\(seg.sourceCode)→\(target)] \(seg.text) => \(out)")
            self.onTranslated?(id, out)
            self.renderSubtitles()
        }
    }

    /// The app joined segment `id` onto `into` (one sentence cut by a pause): the bar shows them as
    /// one, and the whole sentence is translated again. The old translation stays until then.
    func join(_ id: Int, into: Int, text: String) {
        let piece = segments.firstIndex(where: { $0.id == id }).map { segments.remove(at: $0) }
        joinedAway.insert(id)
        if joinedAway.count > 200, let oldest = joinedAway.min() { joinedAway.remove(oldest) }
        if let i = segments.firstIndex(where: { $0.id == into }) {
            segments[i].text = text
        } else {
            // The bar was cleared in between: show the joined sentence on its own.
            segments.append(Segment(id: into, text: text, sourceCode: piece?.sourceCode ?? activeLang?.code ?? "auto", translation: nil))
        }
        finalTiming[id] = nil
        translateSegment(id: into)
        renderSubtitles()
    }

    /// SpeechTranscriber ends a sentence only at a clear pause; in a quick conversation that can
    /// take 15–20 s, and the subtitle stays a draft that long (the notes wait for it too). A long
    /// line in progress is ended at the next small pause: a dip in the sound, or no new words for
    /// a moment.
    private func maybeCutSentence() {
        guard isRunning, !cutting, let recognizer, !volatileText.isEmpty, volatileText != lastCut else { return }
        let cjk = joiner(for: activeLang?.code ?? "") == ""
        let long = cjk ? volatileText.count >= 24 : volatileText.split(separator: " ").count >= 10
        guard long else { return }
        // The longer the line has run, the smaller the pause that may end it.
        let held = Date().timeIntervalSince(volatileStartedAt)
        let needed = held >= 8 ? 0.15 : 0.3
        let c = router.clock()
        let mid = c.pause.end - c.pause.length / 2
        let through: Double, why: String
        if c.silence >= needed {
            (through, why) = (c.fed, "quiet")
        } else if c.pause.length >= needed, mid > volatileStartClock + 1.5, mid > lastCutThrough, c.pause.end <= c.fed {
            (through, why) = (mid, "pause")  // a pause already behind us: end the line there
        } else if Date().timeIntervalSince(volatileChangedAt) >= (held >= 8 ? 0.6 : 1.2) {
            (through, why) = (c.fed, "stalled")
        } else {
            return
        }
        cutting = true
        cutAsked = true
        lastCut = volatileText
        lastCutThrough = through
        let chars = volatileText.count
        Task { [weak self] in
            do {
                try await recognizer.finalize(through: through)
                debugLog(String(format: "cut: line of %d chars ended after %.1f s (%@) at %.1f s of %.1f s",
                                chars, held, why, through, c.fed))
            } catch {
                debugLog("cut: finalize failed \(error)")
                self?.cutAsked = false
            }
            self?.cutting = false
        }
    }

    private func translateVolatile() {
        guard isRunning, !translationOff(), !volatileInFlight, volatileText.count >= 2, volatileText != lastVolatileSent else { return }
        let text = volatileText
        let epoch = volatileEpoch
        let source = activeLang?.code ?? "auto"
        lastVolatileSent = text
        volatileInFlight = true
        Task { [weak self] in
            guard let self else { return }
            let out = await self.translate(text, source: source, kind: .draft)
            self.volatileInFlight = false
            guard let out, self.isRunning, epoch == self.volatileEpoch else { return }
            self.volatileTranslation = out
            self.renderSubtitles()
        }
    }

    /// After a quiet spell the next sentence starts on a clean bar.
    func clearDisplay() {
        segments.removeAll()
        volatileTranslation = ""
        lastVolatileSent = ""
    }

    /// Translation switched back on: translate what is on screen now.
    func translationResumed() { if isRunning { retranslateVisible() } }

    private func retranslateVisible() {
        volatileTranslation = ""
        lastVolatileSent = ""
        for seg in segments.suffix(3) {
            if let idx = segments.firstIndex(where: { $0.id == seg.id }) { segments[idx].translation = nil }
            translateSegment(id: seg.id)
        }
        renderSubtitles()
    }
}

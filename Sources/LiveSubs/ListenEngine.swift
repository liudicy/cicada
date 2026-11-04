import AppKit
import AVFoundation
import CoreMedia
import Speech

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

    private var audioTap: SystemAudioTap?
    private var micCapture: MicCapture?
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?
    private var generation = 0
    private var pendingSwitch: Lang?
    private var needsDetection = true
    private var nextPeriodicDetection = 30.0
    private var lastDetectionAt = Date.distantPast
    private var ambiguousDetections = 0
    /// Sentences finished before detection settled the language: recorded once it confirms the
    /// language they were heard in, dropped on a switch (the replay into the new model redoes them).
    private var unconfirmed: [(seg: Segment, at: Date, duration: Double)] = []
    private var recordable: Bool { settings.sourceMode != .auto || languageConfirmed || ambiguousDetections >= 2 }
    private var failureStreak = 0

    private var segments: [Segment] = []
    private var nextSegmentID = 0
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
        let installed = await SpeechTranscriber.installedLocales
        installedLocales = Set(installed.map { $0.identifier(.bcp47) })
        candidates = sourceLanguages.filter { installedLocales.contains($0.locale) }
        debugLog("installed speech models: \(installedLocales.sorted()) candidates=\(candidates.map(\.locale))")
        onStateChange?()
    }

    // MARK: Start / stop

    func start() {
        guard !isRunning else { return }
        guard SpeechTranscriber.isAvailable else {
            setStatus(L("此 Mac 不支持本机语音识别"))
            return
        }
        languageConfirmed = false
        pendingSwitch = nil
        needsDetection = true
        nextPeriodicDetection = 30
        ambiguousDetections = 0
        unconfirmed = []
        lastDetectionAt = .distantPast
        debugLog("listen start mode=\(settings.sourceMode) target=\(resolvedTarget) source=\(source)")

        guard startCapture() else { return }
        router.setVoiceCapture(settings.speakerVoices)
        isRunning = true
        startTickTimer()

        let initial: Lang
        switch settings.sourceMode {
        case .fixed(let lang):
            initial = lang
        case .auto:
            let last = UserDefaults.standard.string(forKey: "lastDetected")
            initial = candidates.first(where: { $0.locale == last }) ?? candidates.first ?? sourceLanguages[0]
        }
        setStatus(L("正在听"))
        Task { await switchTranscriber(to: initial) }
    }

    func stop() {
        isRunning = false
        generation += 1
        tickTimer?.invalidate()
        tickTimer = nil
        stopCapture()
        router.reset()
        resultsTask?.cancel()
        resultsTask = nil
        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
        analyzer = nil
        segments.removeAll()
        volatileText = ""
        volatileTranslation = ""
        lastVolatileSent = ""
        volatileInFlight = false
        detecting = false
        setStatus(L("已暂停"))
    }

    /// The real microphone a room meeting is recorded from (set by the app: `SystemMic.recordingDevice`,
    /// never the virtual mic). nil reads the system default input.
    var micDevice: (() -> OutputDevice?)?

    /// Where the meeting is heard: the Mac's own sound or a microphone in the room.
    private var source: String { settings.listenSource }

    func reconnectAudio() {
        guard isRunning else { return }
        stopCapture()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                if self.startCapture() { self.setStatus(L("正在听")) }
            }
        }
    }

    /// The 声源 choice flipped: switch capture without touching the meeting. Idle: nothing to restart.
    func sourceChanged() {
        guard isRunning else { onStateChange?(); return }
        stopCapture()
        if startCapture() { setStatus(L("正在听")) }
        onStateChange?()
    }

    private func stopCapture() {
        audioTap?.stop()
        audioTap = nil
        micCapture?.stop()
        micCapture = nil
    }

    @discardableResult
    private func startCapture() -> Bool {
        source == "mic" ? startMic() : startTap()
    }

    @discardableResult
    private func startMic() -> Bool {
        let capture = MicCapture()
        let router = self.router
        capture.onAudio = { pcm in router.push(pcm) }
        do {
            try capture.start(device: micDevice?())
            micCapture = capture
            return true
        } catch {
            debugLog("mic capture start failed: \(error)")
            isRunning = false
            setStatus(error.localizedDescription)
            return false
        }
    }

    @discardableResult
    private func startTap() -> Bool {
        let tap = SystemAudioTap()
        let router = self.router
        tap.onAudio = { pcm in router.push(pcm) }
        do {
            try tap.start()
            audioTap = tap
            debugLog("audio tap started")
            return true
        } catch {
            debugLog("audio tap start failed: \(error)")
            isRunning = false
            setStatus(L("无法读取系统音频，请在系统设置里允许“系统音频录制”"))
            return false
        }
    }

    // MARK: Settings changes

    func sourceModeChanged() {
        languageConfirmed = false
        pendingSwitch = nil
        needsDetection = true
        if isRunning, case .fixed(let lang) = settings.sourceMode {
            // Chosen by hand: what was held back in that language is now confirmed.
            if lang == activeLang { flushUnconfirmed() }
            Task { await switchTranscriber(to: lang) }
        }
        onStateChange?()
    }

    func targetChanged() {
        retranslateVisible()
        onStateChange?()
    }

    func redetect() {
        guard isRunning, settings.sourceMode == .auto else { return }
        languageConfirmed = false
        pendingSwitch = nil
        needsDetection = true
        ambiguousDetections = 0
        lastDetectionAt = .distantPast
        onStateChange?()
    }

    // MARK: Transcriber

    private func ensureModel(for transcriber: SpeechTranscriber, lang: Lang) async throws {
        let status = await AssetInventory.status(forModules: [transcriber])
        if status == .installed { return }
        debugLog("model status for \(lang.locale): \(status)")
        guard status != .unsupported else {
            throw NSError(domain: "LiveSubsSpeech", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: L("本机不支持\(lang.name)识别")])
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            setStatus(L("正在下载 \(lang.name) 语音模型…"))
            try await request.downloadAndInstall()
            await refreshInstalledLocales()
        }
    }

    private func switchTranscriber(to lang: Lang, replaySeconds: Double = 0) async {
        generation += 1
        let gen = generation
        router.detach()
        resultsTask?.cancel()
        resultsTask = nil
        if let old = analyzer {
            analyzer = nil
            await old.cancelAndFinishNow()
        }
        guard isRunning, gen == generation else { return }

        if activeLang != lang {
            segments.removeAll()
            unconfirmed = []
        }
        activeLang = lang
        volatileText = ""
        volatileTranslation = ""
        lastVolatileSent = ""
        volatileEpoch += 1
        cutAsked = false
        onStateChange?()

        let transcriber = SpeechTranscriber(locale: Locale(identifier: lang.locale),
                                            transcriptionOptions: [],
                                            reportingOptions: [.volatileResults, .fastResults],
                                            attributeOptions: [.transcriptionConfidence])
        do {
            try await ensureModel(for: transcriber, lang: lang)
            guard isRunning, gen == generation else { return }
            let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
                ?? AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            try await analyzer.prepareToAnalyze(in: format)
            guard isRunning, gen == generation else {
                await analyzer.cancelAndFinishNow()
                return
            }
            let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
            router.attach(format: format, continuation: continuation, replaySeconds: replaySeconds)
            self.analyzer = analyzer
            resultsTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        self?.handle(result, generation: gen)
                    }
                } catch {
                    self?.recognitionFailed(error, generation: gen)
                }
            }
            try await analyzer.start(inputSequence: stream)
            debugLog("transcriber started locale=\(lang.locale) format=\(format)")
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
        let delay = min(30.0, 2.0 * pow(2.0, Double(failureStreak - 1)))
        setStatus(L("识别出错，\(Int(delay)) 秒后重试"))
        guard let lang = activeLang else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isRunning, gen == self.generation else { return }
                Task { await self.switchTranscriber(to: lang) }
            }
        }
    }

    private func handle(_ result: SpeechTranscriber.Result, generation gen: Int) {
        guard gen == generation, isRunning else { return }
        failureStreak = 0
        var text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isFinal {
            text = HeardText.clean(text)
            volatileText = ""
            volatileEpoch += 1
            // A "." or "…" from a breath or a click is no sentence: Ling would answer it with a note that
            // there was nothing to translate, and it would sit in the record as a line.
            guard text.contains(where: \.isLetter) else { renderSubtitles(); return }
            var weighted = 0.0, chars = 0
            for run in result.text.runs {
                guard let c = run.transcriptionConfidence else { continue }
                let len = result.text[run.range].characters.count
                weighted += c * Double(len)
                chars += len
            }
            let conf = chars > 0 ? weighted / Double(chars) : 1
            let provisional = volatileTranslation.isEmpty ? nil : volatileTranslation
            var seg = Segment(id: nextSegmentID, text: text, sourceCode: activeLang?.code ?? "auto", translation: provisional)
            seg.start = CMTimeGetSeconds(result.range.start)
            seg.end = CMTimeGetSeconds(result.range.end)
            seg.clock = gen
            seg.cut = cutAsked
            cutAsked = false
            if settings.speakerVoices {
                seg.voiceSamples = router.voiceSamples(from: CMTimeGetSeconds(result.range.start), to: CMTimeGetSeconds(result.range.end))
            }
            nextSegmentID += 1
            // How long ago, in real time, the sentence's last word was spoken.
            let ago = router.fedSeconds() - CMTimeGetSeconds(result.range.end)
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
            let duration = max(0, CMTimeGetSeconds(result.range.duration))
            // Only confirmed-language sentences go into the meeting record; earlier ones wait.
            let spoken = duration.isFinite ? duration : 0
            if recordable {
                onFinal?(seg, spoken)
            } else {
                unconfirmed.append((seg, Date(), spoken))
                // Held lines keep their audio only while recent: an undecided language must not pile up minutes of it.
                if unconfirmed.count > 20 { unconfirmed[unconfirmed.count - 21].seg.voiceSamples = nil }
            }
            translateSegment(id: seg.id)
            if settings.sourceMode == .auto, conf < 0.6, text.count >= 4 {
                needsDetection = true
            }
        } else {
            if volatileText.isEmpty { volatileStartedAt = Date(); volatileStartClock = router.fedSeconds() }
            if text != volatileText { volatileChangedAt = Date() }
            volatileText = text
        }
        renderSubtitles()
    }

    private func renderSubtitles() {
        guard !(segments.isEmpty && volatileText.isEmpty) else { return }
        let srcJoin = joiner(for: activeLang?.code ?? "en")
        let source = [segments.last?.text ?? "", volatileText].filter { !$0.isEmpty }
            .joined(separator: srcJoin.isEmpty ? " " : srcJoin)
        if settings.sourceMode == .auto, !languageConfirmed, ambiguousDetections < 2 {
            onSubtitle?(source, L("正在识别语言…"))
            return
        }
        let tgtJoin = joiner(for: resolvedTarget)
        var parts = segments.suffix(3).compactMap(\.translation)
        if !volatileTranslation.isEmpty { parts.append(volatileTranslation) }
        onSubtitle?(source, parts.joined(separator: tgtJoin.isEmpty ? "" : " "))
    }

    // MARK: Language detection

    private func maybeDetectLanguage() {
        guard isRunning, settings.sourceMode == .auto, !detecting, candidates.count >= 2 else { return }
        var stats = router.stats(window: 6)
        if stats.silenceRun >= AudioRouter.gapSeconds { needsDetection = true }
        if stats.voicedTotal >= nextPeriodicDetection { needsDetection = true }
        guard needsDetection, Date().timeIntervalSince(lastDetectionAt) >= 3 else { return }
        let clipSeconds = min(6, stats.sinceGap)
        guard clipSeconds >= 3 else { return }
        stats = router.stats(window: clipSeconds)
        guard stats.recentVoiced >= 2.5 else { return }

        needsDetection = false
        lastDetectionAt = Date()
        detecting = true
        nextPeriodicDetection = stats.voicedTotal + 20
        onStateChange?()
        let clip = router.snapshot(seconds: clipSeconds)
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
            languageConfirmed = true
            unconfirmed = []
            pendingSwitch = nil
            UserDefaults.standard.set(best.lang.locale, forKey: "lastDetected")
            Task { await switchTranscriber(to: best.lang, replaySeconds: 8) }
        } else {
            pendingSwitch = best.lang
            needsDetection = true
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

    private func translateSegment(id: Int) {
        guard !translationOff(), let seg = segments.first(where: { $0.id == id }) else { return }
        let trace = TranslateTrace()
        let asked = Date()
        Task { [weak self] in
            guard let self else { return }
            let result = await self.translate(seg.text, source: seg.sourceCode, trace: trace)
            if let timing = self.finalTiming.removeValue(forKey: id), !trace.attempts.isEmpty {
                self.onTiming?(SentenceTiming(at: timing.at, side: "them", chars: seg.text.count, recognize: timing.recognize,
                                              queue: trace.lingQueue, translate: Date().timeIntervalSince(asked), voice: nil,
                                              failed: trace.failedSeconds, via: result == nil ? "none" : trace.via,
                                              fallbacks: trace.fallbacks))
            }
            guard let out = result else { return }
            guard self.isRunning else { return }
            // The line was joined with the next one meanwhile: only the whole sentence's translation counts.
            if let now = self.segments.first(where: { $0.id == id }), now.text != seg.text { return }
            if let idx = self.segments.firstIndex(where: { $0.id == id }) {
                self.segments[idx].translation = out
            }
            contentLog("TRANSLATE [\(seg.sourceCode)→\(self.resolvedTarget)] \(seg.text) => \(out)")
            self.onTranslated?(id, out)
            self.renderSubtitles()
        }
    }

    /// The app joined segment `id` onto `into` (one sentence cut by a pause): the bar shows them as
    /// one, and the whole sentence is translated again. The old translation stays until then.
    func join(_ id: Int, into: Int, text: String) {
        let piece = segments.firstIndex(where: { $0.id == id }).map { segments.remove(at: $0) }
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
        guard isRunning, !cutting, let analyzer, !volatileText.isEmpty, volatileText != lastCut else { return }
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
                try await analyzer.finalize(through: CMTime(seconds: through, preferredTimescale: 1000))
                debugLog(String(format: "cut: line of %d chars ended after %.1f s (%@)", chars, held, why))
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

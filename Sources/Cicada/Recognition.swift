import AVFoundation
import CoreMedia
import Speech

/// Speech recognition, whatever the Mac. On Apple silicon it is on the device: `SpeechAnalyzer` on 26
/// and later, the older `SFSpeechRecognizer` on 14.4–15 (on-device only: audio never leaves the Mac).
/// Intel Macs have neither, so the AI service hears everything there (`cloudOnly`). The engines only
/// see this file, so the check lives in one place.
enum Recognition {
    /// Dev builds can run the older recognizer on macOS 26, which is where most of its testing
    /// happens: `lsctl recognizer:legacy`, or `open --env CICADA_RECOGNIZER=legacy` from launch.
    /// Not kept in settings: two dev copies share them.
    nonisolated(unsafe) static var forceLegacy = DevBuild.isDev && ProcessInfo.processInfo.environment["CICADA_RECOGNIZER"] == "legacy"
    /// Dev builds run as an Intel Mac would on Apple silicon: `lsctl recognizer:cloud`, or
    /// `open --env CICADA_RECOGNIZER=cloud`.
    nonisolated(unsafe) static var forceCloud = DevBuild.isDev && ProcessInfo.processInfo.environment["CICADA_RECOGNIZER"] == "cloud"

    /// No speech model on this Mac: everything is heard by the AI service's audio model (`CloudStream`),
    /// so nothing works without its key. Intel Macs: `SpeechTranscriber` isn't there, and the older
    /// recognizer's on-device mode is Apple silicon only.
    static var cloudOnly: Bool {
        #if arch(x86_64)
        return true
        #else
        return forceCloud
        #endif
    }

    /// The user chose to have the meeting recognized by their own service (Settings › AI 服务 ›
    /// 语音识别 › 自建服务), set by the app. Unlike `cloudOnly` this Mac still has its engines: they
    /// stay ready, and listening falls back to them when the service stops answering.
    nonisolated(unsafe) static var serverPreferred = false

    /// `cloudOnly`: what the service heard in one stretch of `locale` (nil: any language), set by the
    /// app. The live meeting goes through `ListenEngine.startCloud`; this serves imports and clips.
    nonisolated(unsafe) static var cloudHear: (@MainActor @Sendable (_ wav: Data, _ seconds: Double, _ locale: String?) async -> CloudHeard?)?

    /// Set by the iOS simulator's dev build only: its speech models are empty placeholders, so it
    /// hands the audio to the Mac it runs on (ios/tools/host-recognizer), which recognizes it on
    /// device with this same file. Nil on a Mac and on an iPhone.
    nonisolated(unsafe) static var host: ((_ locale: String, _ drafts: Bool) throws -> RecognitionStream)?

    static var legacy: Bool {
        if host != nil || cloudOnly { return false }
        if #available(macOS 26, *) { return forceLegacy }
        return true
    }

    static var name: String { cloudOnly ? "cloud" : host != nil ? "mac-host" : legacy ? "legacy" : dictationModel ? "dictation" : "analyzer" }

    /// iOS only: a device without `SpeechTranscriber` (older iPhones, the simulator) still has the
    /// on-device dictation model, `DictationTranscriber`, which runs in the same `SpeechAnalyzer`.
    /// The Mac keeps `SpeechTranscriber` or the older recognizer, as before.
    static var dictationModel: Bool {
        #if CICADA_IOS
        if #available(macOS 26, *) { return !SpeechTranscriber.isAvailable }
        #endif
        return false
    }

    /// Apple's on-device translation can be made outside a SwiftUI view only on 26 (`Translator.viaApple`).
    static var hasOnDeviceTranslation: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    /// What a recognizer heard: a draft of the line in progress, or a finished one. Times are
    /// seconds on the stream's clock (the audio appended to it).
    struct Piece: Sendable {
        var text: String
        var isFinal: Bool
        var start: Double
        var end: Double
        /// Mean word confidence (0–1), nil when the recognizer gave none.
        var confidence: Double?
        /// Heard by the service (`CloudStream`): the language it says was spoken, and its translation.
        var language: String? = nil
        var translation: String? = nil
    }

    /// A few characters of a finished sentence and when they were said, from the meeting record's
    /// own recognizer (`RecordHearing`), so its text can be laid over the lines already recorded.
    struct Run: Sendable, Equatable {
        var text: String
        var start: Double
        var end: Double
    }

    /// Dev builds compare the record with and without its own recognizer: `lsctl recordTrack:off`.
    nonisolated(unsafe) static var recordTrackOff = DevBuild.isDev && ProcessInfo.processInfo.environment["CICADA_RECORD_TRACK"] == "off"

    /// The meeting record gets a second recognizer that is never hurried: no `.fastResults` and no
    /// lines cut short for the subtitles. Both cost Chinese about a third more wrong characters
    /// (meeting audio: 20% offline, 25–30% live). macOS 26's `SpeechTranscriber` only.
    static var recordTrack: Bool { host == nil && !cloudOnly && !legacy && !dictationModel && !recordTrackOff }

    /// The record's recognizer for `locale`, taking the same audio as the live one (`format`). Nil
    /// where there is none (`recordTrack`).
    static func startRecord(_ locale: String, format: AVAudioFormat) async throws -> RecordHearing? {
        guard recordTrack, #available(macOS 26, *) else { return nil }
        return try await RecordTrack.start(locale, format: format)
    }

    enum ModelStatus { case installed, downloadable, unsupported }

    static var isAvailable: Bool {
        if host != nil || cloudOnly { return true }
        if !legacy, #available(macOS 26, *) { return SpeechTranscriber.isAvailable || dictationModel }
        return true
    }

    /// The older recognizer asks for 语音识别 permission; 26 doesn't. False when it was refused.
    static func authorize() async -> Bool {
        guard legacy else { return true }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .denied, .restricted: return false
        default:
            return await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
            }
        }
    }

    static var authorizationDenied: Bool {
        legacy && [.denied, .restricted].contains(SFSpeechRecognizer.authorizationStatus())
    }

    /// The older recognizer only runs while Siri or Dictation is on (系统设置 › 键盘 › 听写);
    /// otherwise every line fails at once (`kLSRErrorDomain` 201).
    static var dictationEnabled: Bool {
        guard legacy else { return true }
        let domain = "com.apple.assistant.support" as CFString
        func on(_ key: String) -> Bool {
            (CFPreferencesCopyAppValue(key as CFString, domain) as? NSNumber)?.boolValue ?? false
        }
        return on("Dictation Enabled") || on("Assistant Enabled")
    }

    /// Everything the recognizer needs from the user is in place (always, on 26).
    static var ready: Bool {
        !legacy || (dictationEnabled && SFSpeechRecognizer.authorizationStatus() == .authorized)
    }

    /// Thrown when Dictation is off; the engines show its message rather than a retry count.
    static let dictationOff = NSError(domain: "LiveSubsSpeech", code: 3,
                                      userInfo: [NSLocalizedDescriptionKey: L("请在系统设置 › 键盘里打开“听写”")])
    static let notAllowed = NSError(domain: "LiveSubsSpeech", code: 2,
                                    userInfo: [NSLocalizedDescriptionKey: L("请在系统设置里允许知了使用“语音识别”")])

    /// A problem only the user can fix in System Settings.
    static func needsUser(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == "LiveSubsSpeech" && [2, 3, 4].contains(ns.code)
    }

    /// BCP-47 ids of the languages that can be recognized right now without a download.
    static func installedLocales() async -> Set<String> {
        if cloudOnly { return Set(sourceLanguages.map(\.locale)) }
        if !legacy, #available(macOS 26, *) {
            let installed = dictationModel ? await DictationTranscriber.installedLocales : await SpeechTranscriber.installedLocales
            return Set(installed.map { $0.identifier(.bcp47) })
        }
        return Set(sourceLanguages.map(\.locale).filter { LegacyStream.onDevice($0) })
    }

    static func status(_ locale: String) async -> ModelStatus {
        if host != nil || cloudOnly { return .installed }
        if !legacy, #available(macOS 26, *) {
            switch await AssetInventory.status(forModules: [Analyzer.module(locale)]) {
            case .installed: return .installed
            case .unsupported: return .unsupported
            default: return .downloadable
            }
        }
        // The older recognizer can't fetch a model: macOS downloads it for each Dictation language,
        // and only while Dictation is on. A language not there yet is the user's to add.
        return LegacyStream.onDevice(locale) ? .installed : .downloadable
    }

    /// Fetches the model for `locale` when it isn't on the Mac; `progress` is called once a
    /// download starts, on the main actor: every caller sets UI state there, and from the
    /// cooperative pool it redrew the menu bar panel off the main thread, which ended the app
    /// (`TSMGetInputSourceProperty` asserts the main queue). Throws when this Mac can't recognize
    /// the language.
    static func install(_ locale: String, progress: @MainActor (Progress) -> Void = { _ in }) async throws {
        if host != nil || cloudOnly { return }
        if !legacy, #available(macOS 26, *) {
            let t = Analyzer.module(locale)
            if await AssetInventory.status(forModules: [t]) == .unsupported { throw unsupported(locale) }
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
                await progress(request.progress)
                try await request.downloadAndInstall()
            }
            return
        }
        guard dictationEnabled else { throw dictationOff }
        if !LegacyStream.onDevice(locale) { throw addToDictation(locale) }
    }

    /// The models this app holds (macOS keeps five per app), as BCP-47 ids; none on 14/15,
    /// where Dictation owns them.
    static func reservedLocales() async -> [String] {
        guard !legacy, !cloudOnly, #available(macOS 26, *) else { return [] }
        return await AssetInventory.reservedLocales.map { $0.identifier(.bcp47) }
    }

    /// Gives a held model back to the system, making room under the five-model limit.
    static func release(_ locale: String) async -> Bool {
        guard !legacy, !cloudOnly, #available(macOS 26, *) else { return false }
        return await AssetInventory.release(reservedLocale: Locale(identifier: locale.replacingOccurrences(of: "-", with: "_")))
    }

    static func addToDictation(_ locale: String) -> NSError {
        let name = sourceLanguages.first { $0.locale == locale }?.name ?? locale
        return NSError(domain: "LiveSubsSpeech", code: 4,
                       userInfo: [NSLocalizedDescriptionKey: L("请在系统设置 › 键盘 › 听写里添加\(name)，下载好后可用")])
    }

    static func unsupported(_ locale: String) -> NSError {
        let name = sourceLanguages.first { $0.locale == locale }?.name ?? locale
        return NSError(domain: "LiveSubsSpeech", code: 1, userInfo: [NSLocalizedDescriptionKey: L("本机不支持\(name)识别")])
    }

    /// A recognizer for a stream of audio in `locale`: append buffers in `stream.format`, read
    /// `stream.results`. `drafts` adds lines in progress; `confidence` asks for word confidences.
    /// `speaking`: what the user says while holding the talk key. On macOS 14/15 it has the
    /// recognizer to itself meanwhile (the meeting's lines wait); on 26 both run at once.
    /// `background`: a file being imported; on macOS 14/15 it gives way to a live meeting.
    static func start(_ locale: String, drafts: Bool, confidence: Bool = false, speaking: Bool = false,
                      background: Bool = false) async throws -> RecognitionStream {
        if let host { return try host(locale, drafts) }
        if cloudOnly { return cloudStream(speaking ? nil : locale) }
        if !legacy, #available(macOS 26, *) {
            return try await Analyzer.start(locale, drafts: drafts, confidence: confidence)
        }
        guard await authorize() else { throw notAllowed }
        guard dictationEnabled else { throw dictationOff }
        return try LegacyStream(locale: locale, drafts: drafts, role: speaking ? .speak : background ? .background : drafts ? .listen : .other)
    }

    /// The audio format `start(locale, drafts:)` will want, known before starting one.
    static func format(_ locale: String, drafts: Bool) async -> AVAudioFormat {
        if cloudOnly { return cloudStream(nil).format }
        if !legacy, #available(macOS 26, *) {
            return await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [Analyzer.module(locale, drafts: drafts)])
                ?? AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!
        }
        return LegacyStream.audioFormat
    }

    /// A stream that takes audio at once (in `format`, from `format(locale, drafts:)`) and starts
    /// recognizing as soon as the recognizer is ready: the talk key opens the mic without waiting.
    /// It is what the user says (`speaking` above).
    static func startNow(_ locale: String, drafts: Bool, format: AVAudioFormat) -> RecognitionStream {
        // The talk key: Ming hears the press as a whole (`TranslationService.interpret`), so this one
        // hears nothing and costs nothing.
        if cloudOnly { return CloudStream(format: format) { _, _ in nil } }
        return DeferredStream(locale, drafts: drafts, format: format)
    }

    static func cloudStream(_ locale: String?) -> CloudStream {
        CloudStream { wav, seconds in await cloudHear?(wav, seconds, locale) }
    }

    /// Transcribes recorded audio (a clip, one press of the talk key): the finished lines joined,
    /// their confidence and how many letters they hold. Nil when the language can't be recognized.
    static func transcribe(_ buffers: [AVAudioPCMBuffer], locale: String) async -> (text: String, confidence: Double, letters: Int)? {
        // Language detection compares models; the service names the language itself.
        guard !cloudOnly, await status(locale) == .installed else { return nil }
        // The older recognizer can't run two tasks at once (both come back "no speech"): a clip
        // waits for a pause in the live line, which meanwhile holds its audio back.
        let gated = legacy
        if gated {
            guard await LegacyStream.Gate.enterClip() else { return nil }
        }
        defer { if gated { LegacyStream.Gate.leaveClip() } }
        guard let stream = try? await start(locale, drafts: false, confidence: true) else { return nil }
        let collector = Task { () -> [Piece] in
            var out: [Piece] = []
            do { for try await p in stream.results where p.isFinal { out.append(p) } } catch {}
            return out
        }
        let conv = PCMConverter()
        for b in buffers { if let c = conv.convert(b, to: stream.format) { stream.append(c) } }
        await stream.finish()
        let pieces = await collector.value
        var weighted = 0.0, letters = 0
        for p in pieces {
            let n = p.text.filter { !$0.isWhitespace && !$0.isPunctuation }.count
            letters += n
            weighted += (p.confidence ?? 0) * Double(n)
        }
        let text = pieces.map { $0.text.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        return (text, letters > 0 ? weighted / Double(letters) : 0, letters)
    }
}

/// One running recognition. `append` may be called from any thread.
protocol RecognitionStream: AnyObject, Sendable {
    var format: AVAudioFormat { get }
    var results: AsyncThrowingStream<Recognition.Piece, Error> { get }
    func append(_ buffer: AVAudioPCMBuffer)
    /// Ends the line in progress at `seconds` (or now), so it comes back finished.
    func finalize(through seconds: Double) async throws
    /// No more audio: returns once every line has come back and `results` has ended.
    func finish() async
    func cancel() async
}

// MARK: - macOS 26: SpeechAnalyzer

@available(macOS 26, *)
final class Analyzer: RecognitionStream, @unchecked Sendable {
    let format: AVAudioFormat
    let results: AsyncThrowingStream<Recognition.Piece, Error>
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let reader: Task<Void, Never>

    static func transcriber(_ locale: String, drafts: Bool = false, confidence: Bool = false) -> SpeechTranscriber {
        // Without `.fastResults` Chinese only reports every ~11 s of audio; with it, text trails
        // speech by about a second.
        SpeechTranscriber(locale: Locale(identifier: locale), transcriptionOptions: [],
                          reportingOptions: drafts ? [.volatileResults, .fastResults] : [],
                          attributeOptions: confidence ? [.transcriptionConfidence] : [])
    }

    /// What recognizes `locale`: `SpeechTranscriber`, or the dictation model where that is missing (`Recognition.dictationModel`).
    static func module(_ locale: String, drafts: Bool = false, confidence: Bool = false) -> any SpeechModule {
        guard Recognition.dictationModel else { return transcriber(locale, drafts: drafts, confidence: confidence) }
        // .farField: the room is heard from across the table. .frequentFinalization: sentences
        // come back finished about as often as SpeechTranscriber's.
        return DictationTranscriber(locale: Locale(identifier: locale), contentHints: [.farField], transcriptionOptions: [.punctuation],
                                    reportingOptions: drafts ? [.volatileResults, .frequentFinalization] : [],
                                    attributeOptions: confidence ? [.audioTimeRange, .transcriptionConfidence] : [.audioTimeRange])
    }

    static func start(_ locale: String, drafts: Bool, confidence: Bool) async throws -> Analyzer {
        let t = module(locale, drafts: drafts, confidence: confidence)
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t])
            ?? AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!
        let analyzer = SpeechAnalyzer(modules: [t])
        try await analyzer.prepareToAnalyze(in: format)
        let (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
        let me = Analyzer(t, analyzer: analyzer, format: format, input: input)
        try await analyzer.start(inputSequence: stream)
        return me
    }

    private init(_ t: any SpeechModule, analyzer: SpeechAnalyzer, format: AVAudioFormat,
                 input: AsyncStream<AnalyzerInput>.Continuation) {
        self.analyzer = analyzer
        self.format = format
        self.input = input
        let (results, out) = AsyncThrowingStream.makeStream(of: Recognition.Piece.self)
        self.results = results
        func piece(_ text: AttributedString, _ isFinal: Bool, _ range: CMTimeRange) -> Recognition.Piece {
            var weighted = 0.0, chars = 0
            for run in text.runs {
                guard let c = run.transcriptionConfidence else { continue }
                let len = text[run.range].characters.count
                weighted += c * Double(len)
                chars += len
            }
            return .init(text: String(text.characters), isFinal: isFinal,
                         start: CMTimeGetSeconds(range.start), end: CMTimeGetSeconds(range.end),
                         confidence: chars > 0 ? weighted / Double(chars) : nil)
        }
        reader = Task {
            do {
                if let t = t as? SpeechTranscriber {
                    for try await r in t.results { out.yield(piece(r.text, r.isFinal, r.range)) }
                } else if let d = t as? DictationTranscriber {
                    for try await r in d.results { out.yield(piece(r.text, r.isFinal, r.range)) }
                }
                out.finish()
            } catch {
                out.finish(throwing: error)
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) { input.yield(AnalyzerInput(buffer: buffer)) }

    func finalize(through seconds: Double) async throws {
        try await analyzer.finalize(through: CMTime(seconds: seconds, preferredTimescale: 1000))
    }

    func finish() async {
        input.finish()
        do { try await analyzer.finalizeAndFinishThroughEndOfInput() } catch { debugLog("analyzer finish: \(error)") }
        await reader.value
    }

    func cancel() async {
        input.finish()
        await analyzer.cancelAndFinishNow()
    }
}

// MARK: - macOS 14.4–15: SFSpeechRecognizer

/// `SFSpeechRecognizer` has no sentences of its own: a task's text grows until its audio ends.
/// So each line is one task, ended at a pause (or when asked to, for a long line), and the next
/// line starts a new task. The clock counts every buffer appended, as `SpeechAnalyzer`'s does.
final class LegacyStream: RecognitionStream, @unchecked Sendable {
    static let audioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let format = LegacyStream.audioFormat
    let results: AsyncThrowingStream<Recognition.Piece, Error>
    private let out: AsyncThrowingStream<Recognition.Piece, Error>.Continuation
    private let recognizer: SFSpeechRecognizer
    private let drafts: Bool
    private let queue = OperationQueue()
    private let lock = NSLock()

    /// Below this RMS a buffer is quiet (as `AudioRouter`).
    private static let quiet: Float = 0.01
    /// A pause this long ends the line; a line this long is ended anyway.
    private static let pause = 0.7
    private static let longest = 45.0
    private static let preroll = 0.3
    /// How long the meeting's audio can wait for the line before it, a language check or the
    /// talk key (a slow Mac takes several seconds to check two languages).
    private static let holdLimit = 12.0

    private struct Line {
        let request: SFSpeechAudioBufferRecognitionRequest
        var task: SFSpeechRecognitionTask?
        let start: Double
        var draft = ""
        /// Where its audio ended, less the pause that ended it.
        var endAt: Double?
    }
    /// One task at a time across the app: live lines and short clips (language checks) take turns.
    enum Gate {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var liveLines = 0
        nonisolated(unsafe) private static var clips = 0

        /// Waits (up to 15 s) for no live line and no other clip, then holds new lines back. One clip
        /// at a time: a language check of two candidates runs them one after the other. False: gave up.
        static func enterClip() async -> Bool {
            for _ in 0..<150 {
                let ok = lock.withLock { () -> Bool in
                    guard liveLines == 0, clips == 0 else { return false }
                    clips += 1
                    return true
                }
                if ok { return true }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            debugLog("legacy recognizer: no pause for a language check")
            return false
        }
        static func leaveClip() { lock.withLock { clips -= 1 } }
        static var clipRunning: Bool { lock.withLock { clips > 0 } }
        nonisolated(unsafe) private static var speakers = 0
        /// The talk key is held: the meeting's live stream holds its audio until it's let go.
        static var speaking: Bool { lock.withLock { speakers > 0 } }
        static func speaker(_ delta: Int) { lock.withLock { speakers += delta } }

        // An import (`.background`) and the meeting take turns: the meeting first.
        nonisolated(unsafe) private static var backgroundLines = 0
        nonisolated(unsafe) private static var meetingWaiting = false
        static func backgroundLine(_ delta: Int) { lock.withLock { backgroundLines += delta } }
        static var backgroundBusy: Bool { lock.withLock { backgroundLines > 0 } }
        static func meetingWaits(_ on: Bool) { lock.withLock { meetingWaiting = on } }
        /// The meeting (or the talk key, or a language check) has the recognizer or wants it.
        static var meetingBusy: Bool { lock.withLock { liveLines > 0 || speakers > 0 || clips > 0 || meetingWaiting } }
        static func liveLine(_ delta: Int) { lock.withLock { liveLines += delta } }
    }

    private var lines: [Int: Line] = [:]
    private var current: Int?
    private var nextID = 0
    private var fed = 0.0
    private var silence = 0.0
    private var heardVoice = false
    private var recent: [AVAudioPCMBuffer] = []
    private var recentSeconds = 0.0
    /// Speech that came during a language check or the talk key, waiting in `recent`.
    private enum Held {
        case nothing
        /// Audio held with no speech in it yet: just the quiet before the next line, if it stays so.
        case quiet
        case speech
    }
    private var held = Held.nothing
    /// Keeps `buffer` for later (in `recent`), noting whether it had speech in it. Lock held.
    private func hold(_ buffer: AVAudioPCMBuffer, seconds: Double, voiced: Bool) {
        recent.append(buffer)
        recentSeconds += seconds
        fed += seconds
        if voiced || held == .speech { held = .speech } else { held = .quiet }
    }
    private var finished = false
    private var finishWaiter: CheckedContinuation<Void, Never>?
    /// A draft of the next line held back until the line before it has come back finished, so
    /// the engine never sees a draft that belongs after a line still to be finished.
    private var heldDraft: (id: Int, piece: Recognition.Piece)?

    static func onDevice(_ locale: String) -> Bool {
        guard let r = SFSpeechRecognizer(locale: Locale(identifier: locale)) else { return false }
        return r.supportsOnDeviceRecognition
    }

    /// What the stream hears: the meeting (gives way while the user speaks), the user holding the
    /// talk key, or anything else (a file, a clip).
    enum Role { case listen, speak, background, other }
    private let role: Role
    private var spoke = false

    init(locale: String, drafts: Bool, role: Role = .other) throws {
        guard let r = SFSpeechRecognizer(locale: Locale(identifier: locale)), r.supportsOnDeviceRecognition else {
            throw Recognition.unsupported(locale)
        }
        recognizer = r
        self.drafts = drafts
        self.role = role
        queue.maxConcurrentOperationCount = 1
        recognizer.queue = queue
        (results, out) = AsyncThrowingStream.makeStream(of: Recognition.Piece.self)
        if role == .speak { Gate.speaker(1); spoke = true }
        if drafts { debugLog("legacy recognizer \(locale) available=\(r.isAvailable)") }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let n = Int(buffer.frameLength)
        guard n > 0, let d = buffer.floatChannelData else { return }
        var sum: Float = 0
        for i in 0..<n { sum += d[0][i] * d[0][i] }
        let voiced = (sum / Float(n)).squareRoot() >= Self.quiet
        let seconds = Double(n) / buffer.format.sampleRate
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        if role == .listen, Gate.speaking {
            // The user is speaking: the line in progress ends now, and the meeting's last few
            // seconds wait for the talk key to be let go (two tasks at once both come back empty).
            if current != nil { end() }
            hold(buffer, seconds: seconds, voiced: voiced)
            while recentSeconds > Self.holdLimit, recent.count > 1 {
                recentSeconds -= Double(recent.removeFirst().frameLength) / buffer.format.sampleRate
            }
            return
        }
        if current == nil {
            // The line before is still being finished, or a language check is running: starting a
            // task now would make the other come back empty. Keep the words until then (a few seconds).
            let importing = role == .listen && Gate.backgroundBusy
            if voiced || held != .nothing, (!lines.isEmpty || Gate.clipRunning || importing), recentSeconds < Self.holdLimit {
                // An import's line is in the recognizer: it ends its line and waits for this one.
                if importing { Gate.meetingWaits(true) }
                hold(buffer, seconds: seconds, voiced: voiced)
                return
            }
            // Held audio with no speech in it (the meeting was quiet while the user spoke) is just
            // the quiet before the next line, not the start of one.
            if held == .quiet, !voiced { held = .nothing }
            if voiced || held != .nothing {
                let spokenBefore = held == .speech
                held = .nothing
                // The quiet just before the first word belongs to it: a soft onset is still heard.
                begin(at: fed - recentSeconds)
                for b in recent { lines[current!]?.request.append(b) }
                recent = []
                recentSeconds = 0
                // Held speech counts: the next pause ends this line.
                if spokenBefore { heardVoice = true }
            } else {
                recent.append(buffer)
                recentSeconds += seconds
                while held == .nothing, recentSeconds > Self.preroll, recent.count > 1 {
                    recentSeconds -= Double(recent.removeFirst().frameLength) / buffer.format.sampleRate
                }
                fed += seconds
                return
            }
        }
        guard let id = current, let line = lines[id] else { return }
        line.request.append(buffer)
        fed += seconds
        if voiced { silence = 0; heardVoice = true } else { silence += seconds }
        if (heardVoice && silence >= Self.pause) || fed - line.start >= Self.longest { end() }
    }

    /// Called with the lock held.
    private func begin(at start: Double) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = drafts
        request.addsPunctuation = true
        request.taskHint = .dictation
        let id = nextID
        nextID += 1
        lines[id] = Line(request: request, start: max(0, start))
        if drafts { Gate.liveLine(1) }
        if role == .background { Gate.backgroundLine(1) }
        if role == .listen { Gate.meetingWaits(false) }
        current = id
        silence = 0
        heardVoice = false
        lines[id]?.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.deliver(id, result, error)
        }
    }

    /// Called with the lock held.
    private func end() {
        guard let id = current else { return }
        current = nil
        lines[id]?.endAt = fed - silence
        lines[id]?.request.endAudio()
        silence = 0
        // A line that never comes back (the recognizer can drop one) is closed with its draft. A
        // slow Mac (or a virtual one, with no Neural Engine) takes longer than the line itself.
        let wait = 10 + 2 * (fed - (lines[id]?.start ?? fed))
        DispatchQueue.global().asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.close(id, text: nil, confidence: nil) }
        }
    }

    private func deliver(_ id: Int, _ result: SFSpeechRecognitionResult?, _ error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        guard let line = lines[id] else { return }
        if let result {
            let text = result.bestTranscription.formattedString
            if result.isFinal {
                let segs = result.bestTranscription.segments
                var weighted = 0.0, chars = 0
                for s in segs where s.confidence > 0 {
                    weighted += Double(s.confidence) * Double(s.substring.count)
                    chars += s.substring.count
                }
                let end = segs.last.map { line.start + $0.timestamp + $0.duration }
                close(id, text: text, end: end, confidence: chars > 0 ? weighted / Double(chars) : nil)
                return
            }
            lines[id]?.draft = text
            let piece = Recognition.Piece(text: text, isFinal: false, start: line.start, end: fed, confidence: nil)
            // A line before this one is still being finished: its final comes first.
            if lines.keys.contains(where: { $0 < id }) { heldDraft = (id, piece) } else { out.yield(piece) }
        } else if let error {
            let ns = error as NSError
            // Siri and Dictation are off (or turned off meanwhile): no line can succeed.
            if ns.domain == "kLSRErrorDomain" && ns.code == 201 {
                debugLog("legacy recognizer: Siri and Dictation are off")
                fail(Recognition.dictationOff)
                return
            }
            // "No speech detected" and the like: the line ends with whatever its draft held.
            if !(ns.domain == "kAFAssistantErrorDomain" && [1110, 216].contains(ns.code)) {
                debugLog("legacy recognizer line \(id): \(ns.domain) \(ns.code) \(ns.localizedDescription)")
            }
            close(id, text: nil, confidence: nil)
        }
    }

    /// Ends line `id` once: yields it finished (its final text, else its draft). Lock held.
    private func close(_ id: Int, text: String?, end: Double? = nil, confidence: Double?) {
        guard let line = lines.removeValue(forKey: id) else { return }
        if drafts { Gate.liveLine(-1) }
        if role == .background { Gate.backgroundLine(-1) }
        if drafts {
            debugLog(String(format: "legacy line %d: %.1f–%.1f s, %@, %d chars", id, line.start, line.endAt ?? fed,
                            text == nil ? "draft" : "final", (text ?? line.draft).count))
        }
        if current == id { current = nil }
        line.task?.cancel()
        let words = (text ?? line.draft).trimmingCharacters(in: .whitespacesAndNewlines)
        if !words.isEmpty {
            out.yield(.init(text: words, isFinal: true, start: line.start,
                            end: max(line.start, end ?? line.endAt ?? fed), confidence: confidence))
        }
        if let held = heldDraft, !lines.keys.contains(where: { $0 < held.id }) {
            heldDraft = nil
            if lines[held.id] != nil { out.yield(held.piece) }
        }
        if finished, lines.isEmpty {
            releaseSpeaker()
            out.finish()
            finishWaiter?.resume()
            finishWaiter = nil
        }
    }

    /// The talk key's stream is done: the meeting may have the recognizer back. Lock held.
    private func releaseSpeaker() {
        guard spoke else { return }
        spoke = false
        Gate.speaker(-1)
    }

    deinit { if spoke { Gate.speaker(-1) } }

    /// Lines given audio that haven't come back yet.
    var backlog: Int { lock.withLock { lines.count } }

    func finalize(through seconds: Double) async throws {
        lock.withLock { end() }
    }

    func finish() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            finished = true
            if current == nil, held != .nothing {
                // Words held back for the line before: they still need a line of their own.
                held = .nothing
                begin(at: fed - recentSeconds)
                for b in recent { lines[current!]?.request.append(b) }
                recent = []
                recentSeconds = 0
            }
            end()
            if lines.isEmpty {
                releaseSpeaker()
                out.finish()
                lock.unlock()
                cont.resume()
            } else {
                finishWaiter = cont
                lock.unlock()
            }
        }
    }

    func cancel() async {
        lock.withLock { fail(nil) }
    }

    /// Stops every line; `results` ends with `error`. Lock held.
    private func fail(_ error: Error?) {
        finished = true
        releaseSpeaker()
        for line in lines.values { line.task?.cancel() }
        if drafts { Gate.liveLine(-lines.count) }
        if role == .background { Gate.backgroundLine(-lines.count) }
        if role == .listen { Gate.meetingWaits(false) }
        lines = [:]
        current = nil
        out.finish(throwing: error)
        finishWaiter?.resume()
        finishWaiter = nil
    }
}

// MARK: - Started late

/// Holds the audio until the recognizer behind it has started, then passes everything through.
final class DeferredStream: RecognitionStream, @unchecked Sendable {
    let format: AVAudioFormat
    let results: AsyncThrowingStream<Recognition.Piece, Error>
    private let lock = NSLock()
    private var pending: [AVAudioPCMBuffer] = []
    private var real: RecognitionStream?
    private var closed = false
    private var opening: Task<RecognitionStream?, Never>?
    private var forwarding: Task<Void, Never>?

    init(_ locale: String, drafts: Bool, format: AVAudioFormat) {
        self.format = format
        let (results, out) = AsyncThrowingStream.makeStream(of: Recognition.Piece.self)
        self.results = results
        opening = Task { [self] in
            do {
                let s = try await Recognition.start(locale, drafts: drafts, speaking: true)
                lock.withLock {
                    real = s
                    if !closed { for b in pending { s.append(b) } }
                    pending = []
                }
                forwarding = Task {
                    do {
                        for try await p in s.results { out.yield(p) }
                        out.finish()
                    } catch {
                        out.finish(throwing: error)
                    }
                }
                return s
            } catch {
                debugLog("recognizer start failed: \(error)")
                out.finish(throwing: error)
                return nil
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard !closed else { return }
            if let real { real.append(buffer) } else { pending.append(buffer) }
        }
    }

    func finalize(through seconds: Double) async throws {
        try await opening?.value?.finalize(through: seconds)
    }

    func finish() async {
        guard let s = await opening?.value else { return }
        lock.withLock { closed = true }
        await s.finish()
        await forwarding?.value
    }

    func cancel() async {
        lock.withLock { closed = true; pending = [] }
        await opening?.value?.cancel()
    }
}

// MARK: - The meeting record's recognizer

/// Finished sentences only, each as runs with their times (`Recognition.Run`) and the end of the
/// audio it covers.
protocol RecordHearing: AnyObject, Sendable {
    var sentences: AsyncThrowingStream<(runs: [Recognition.Run], through: Double), Error> { get }
    func append(_ buffer: AVAudioPCMBuffer)
    /// No more audio: returns once every sentence has come back.
    func finish() async
    func cancel() async
}

@available(macOS 26, *)
final class RecordTrack: RecordHearing, @unchecked Sendable {
    let sentences: AsyncThrowingStream<(runs: [Recognition.Run], through: Double), Error>
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let reader: Task<Void, Never>

    static func start(_ locale: String, format: AVAudioFormat) async throws -> RecordTrack {
        let t = SpeechTranscriber(locale: Locale(identifier: locale), transcriptionOptions: [],
                                  reportingOptions: [], attributeOptions: [.audioTimeRange])
        let analyzer = SpeechAnalyzer(modules: [t])
        try await analyzer.prepareToAnalyze(in: format)
        let (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
        let me = RecordTrack(t, analyzer: analyzer, input: input)
        try await analyzer.start(inputSequence: stream)
        return me
    }

    private init(_ t: SpeechTranscriber, analyzer: SpeechAnalyzer, input: AsyncStream<AnalyzerInput>.Continuation) {
        self.analyzer = analyzer
        self.input = input
        let (sentences, out) = AsyncThrowingStream.makeStream(of: (runs: [Recognition.Run], through: Double).self)
        self.sentences = sentences
        reader = Task {
            do {
                for try await r in t.results where r.isFinal {
                    let runs = Self.runs(r.text, r.range)
                    if !runs.isEmpty { out.yield((runs, CMTimeGetSeconds(r.range.end))) }
                }
                out.finish()
            } catch {
                out.finish(throwing: error)
            }
        }
    }

    /// Punctuation comes without a time: it stays with the run before it.
    static func runs(_ text: AttributedString, _ range: CMTimeRange) -> [Recognition.Run] {
        var out: [Recognition.Run] = []
        for run in text.runs {
            let piece = String(text[run.range].characters)
            if let r = run.audioTimeRange {
                out.append(.init(text: piece, start: CMTimeGetSeconds(r.start), end: CMTimeGetSeconds(r.end)))
            } else if !out.isEmpty {
                out[out.count - 1].text += piece
            } else {
                let t = CMTimeGetSeconds(range.start)
                out.append(.init(text: piece, start: t, end: t))
            }
        }
        return out.filter { $0.start.isFinite && $0.end.isFinite }
    }

    func append(_ buffer: AVAudioPCMBuffer) { input.yield(AnalyzerInput(buffer: buffer)) }

    func finish() async {
        input.finish()
        do { try await analyzer.finalizeAndFinishThroughEndOfInput() } catch { debugLog("record track finish: \(error)") }
        await reader.value
    }

    func cancel() async {
        input.finish()
        await analyzer.cancelAndFinishNow()
    }
}

/// The live recognizer and the record's, fed the same audio from the same moment so their clocks
/// agree. Only the live one is cut short for the subtitles.
final class TeeStream: RecognitionStream, @unchecked Sendable {
    let live: RecognitionStream
    let record: RecordHearing
    var format: AVAudioFormat { live.format }
    var results: AsyncThrowingStream<Recognition.Piece, Error> { live.results }

    init(live: RecognitionStream, record: RecordHearing) {
        self.live = live
        self.record = record
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        live.append(buffer)
        record.append(buffer)
    }

    func finalize(through seconds: Double) async throws { try await live.finalize(through: seconds) }

    func finish() async {
        async let a: Void = live.finish()
        async let b: Void = record.finish()
        _ = await (a, b)
    }

    func cancel() async {
        async let a: Void = live.cancel()
        async let b: Void = record.cancel()
        _ = await (a, b)
    }
}

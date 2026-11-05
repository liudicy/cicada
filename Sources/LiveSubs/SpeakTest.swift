import AVFoundation
import Foundation
import Speech

// MARK: - Probe

/// What one rehearsal press went through, filled in by `SpeakEngine` stage by stage.
@MainActor
final class SpeakProbe {
    var released: Date?
    var pressWAV: Data?
    var text = ""
    var textAt: Date?
    var translation: String?
    var translatedAt: Date?
    var via = ""
    var from = ""
    var to = ""
    var firstAudioAt: Date?
    var voice = ""
    var device: OutputDevice?

    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var done = false

    func finish() {
        guard !done else { return }
        done = true
        waiters.forEach { $0.resume() }
        waiters = []
    }

    func wait() async {
        if done { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

// MARK: - Scoring (pure)

enum SpeakScore {
    /// Words for comparing what was sent with what came back: CJK by character, others by word,
    /// lower-cased, punctuation dropped.
    static func tokens(_ text: String) -> [String] {
        var out: [String] = []
        var word = ""
        func flush() { if !word.isEmpty { out.append(word.lowercased()); word = "" } }
        for ch in text {
            if ch.unicodeScalars.contains(where: isCJK) {
                flush()
                out.append(String(ch))
            } else if ch.isLetter || ch.isNumber || ch == "'" || ch == "’" {
                word.append(ch == "’" ? "'" : ch)
            } else {
                flush()
            }
        }
        flush()
        return out
    }

    static func isCJK(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF: true
        default: false
        }
    }

    /// Share of the sent words that came back, from the word-level edit distance: 1 = identical.
    static func match(sent: String, heard: String) -> Double {
        let a = tokens(sent), b = tokens(heard)
        guard !a.isEmpty else { return b.isEmpty ? 1 : 0 }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in stride(from: 1, through: b.count, by: 1) {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return max(0, 1 - Double(prev[b.count]) / Double(a.count))
    }

    struct Signal: Equatable {
        /// Seconds from the start of the recording to the first sound; nil = silence throughout.
        var onset: Double?
        var peakDB: Double
        var clipped: Int
        var voiced: Double
    }

    /// Looks at a mono recording in 10 ms windows. The virtual mic is digital: silence is exact
    /// zeros, so a low threshold finds the first syllable without false starts.
    static func signal(_ samples: [Float], rate: Double, threshold: Float = 0.003) -> Signal {
        let window = max(1, Int(rate / 100))
        var onset: Double?
        var voicedWindows = 0
        var peak: Float = 0
        var clipped = 0
        var i = 0
        while i < samples.count {
            let end = min(samples.count, i + window)
            var sum: Float = 0
            for k in i..<end {
                let v = abs(samples[k])
                sum += v * v
                if v > peak { peak = v }
                if v >= 0.999 { clipped += 1 }
            }
            let rms = (sum / Float(end - i)).squareRoot()
            if rms > threshold {
                voicedWindows += 1
                if onset == nil { onset = Double(i) / rate }
            }
            i = end
        }
        return Signal(onset: onset, peakDB: peak > 0 ? 20 * log10(Double(peak)) : -120,
                      clipped: clipped, voiced: Double(voicedWindows) / 100)
    }

    /// Bars for the little waveform, 0…1.
    static func bars(_ samples: [Float], count: Int) -> [Float] {
        guard !samples.isEmpty, count > 0 else { return [] }
        let slice = max(1, samples.count / count)
        return stride(from: 0, to: samples.count, by: slice).prefix(count).map { start in
            let end = min(samples.count, start + slice)
            return min(1, samples[start..<end].reduce(0) { max($0, abs($1)) } * 1.4)
        }
    }

    /// Ling's verdict: `{"score": 0–100, "issue": "…"}`.
    static func parseJudge(_ reply: String) -> (score: Int, issue: String)? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"),
              let data = String(reply[start...end]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let score = (obj["score"] as? NSNumber)?.intValue ?? Int(obj["score"] as? String ?? "")
        guard let score, (0...100).contains(score) else { return nil }
        return (score, (obj["issue"] as? String ?? "").trimmingCharacters(in: .whitespaces))
    }
}

// MARK: - Result

/// One rehearsal: every stage's output, the timings, and where it broke if it did.
struct SpeakTestResult {
    enum Stage: Int, CaseIterable { case mic, recognize, translate, voice, room }
    enum Meaning: Equatable {
        case score(Int, String)
        /// No Ling key: what the room heard, translated back, for the user to judge.
        case back(String)
        case unchecked
    }

    var sample = false
    var source = ""
    var translation: String?
    var heard = ""
    var from = ""
    var to = ""
    var via = ""
    var voice = ""
    var outputName = ""
    var outputIsVirtualMic = true
    var micPeakDB: Double?
    var recognize: Double?
    var translate: Double?
    var synth: Double?
    var arrive: Double?
    /// Key released → the room's first sound, measured on the virtual mic's recording.
    var firstHeard: Double?
    var heardSeconds: Double = 0
    var heardPeakDB: Double = -120
    var clipped = 0
    var intelligibility: Double?
    var meaning: Meaning = .unchecked
    var broken: Stage?
    var problem: String?
    var bars: [Float] = []
    var heardURL: URL?
    var micURL: URL?

    var passed: Bool {
        broken == nil && (intelligibility ?? 1) >= 0.6 && { if case .score(let s, _) = meaning { s >= 60 } else { true } }()
    }

    /// Timings and checks only, never the words (like the diagnostics report).
    var report: String {
        func s(_ v: Double?) -> String { v.map { String(format: "%.2f s", $0) } ?? "-" }
        var lines = [
            "\(appDisplayName) speak-back test (\(sample ? "sample" : "voice")) \(from) → \(to)",
            "verdict: \(passed ? "pass" : "fail")\(broken.map { " at \($0)" } ?? "")",
            "released → room hears: \(s(firstHeard))",
            "  recognize \(s(recognize)) · translate \(s(translate)) via \(via) · first audio \(s(synth)) · to virtual mic \(s(arrive))",
            "voice: \(voice) → \(outputName)\(outputIsVirtualMic ? "" : " (not the virtual mic)")",
            "room audio: \(String(format: "%.1f", heardSeconds)) s, peak \(String(format: "%.0f", heardPeakDB)) dB, clipped \(clipped)",
            "intelligibility: \(intelligibility.map { "\(Int(($0 * 100).rounded()))%" } ?? "-")",
        ]
        if case .score(let v, _) = meaning { lines.append("meaning: \(v)/100") }
        if let micPeakDB { lines.append("mic peak: \(String(format: "%.0f", micPeakDB)) dB") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Tester

/// "试一句": one real press through the whole speak-back chain, with the virtual mic's input side
/// recorded so the user hears exactly what the meeting app receives, then scored without them:
/// signal on the virtual mic, the recording transcribed again on this Mac and compared with the
/// translation that was sent, and (with a Ling key) whether the meaning survived.
@MainActor
final class SpeakTester: ObservableObject {
    enum Mode: String { case voice, sample }
    enum Phase: Equatable {
        case idle
        case preparing
        /// Voice mode: waiting for the user to speak (button or talk key).
        case ready
        case talking
        /// The chain is running; `reached` says how far.
        case working
        case scoring
        case done
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var reached: SpeakTestResult.Stage?
    @Published private(set) var result: SpeakTestResult?
    @Published private(set) var playing: URL?
    @Published var mode: Mode = .voice

    let speak: SpeakEngine
    let ling: LingClient
    let settings: AppSettings
    /// The app's translation chain (for the back-translation without a Ling key).
    var translate: ((_ text: String, _ from: String, _ to: String) async -> String?)?
    /// A real press measured end to end.
    var onLatency: ((Double) -> Void)?

    private var probe: SpeakProbe?
    private var recorder: LoopbackRecorder?
    private var player: AVAudioPlayer?
    private var running: Task<Void, Never>?

    var busy: Bool { ![.idle, .done].contains(phase) }

    init(speak: SpeakEngine, ling: LingClient, settings: AppSettings) {
        self.speak = speak
        self.ling = ling
        self.settings = settings
    }

    static func sampleSentence(for code: String) -> String {
        switch VoiceCatalog.key(for: code) {
        case "zh": "我们下周三把方案定下来，然后再约一次评审。"
        case "ja": "来週の水曜日に計画を決めて、もう一度レビューしましょう。"
        case "ko": "다음 주 수요일에 계획을 확정하고 다시 검토합시다."
        case "es": "Cerremos el plan el próximo miércoles y luego hagamos otra revisión."
        case "fr": "Finalisons le plan mercredi prochain, puis refaisons une revue."
        case "de": "Lass uns den Plan nächsten Mittwoch festlegen und dann noch einmal prüfen."
        case "pt": "Vamos fechar o plano na próxima quarta e depois fazer outra revisão."
        default: "Let's finalize the plan next Wednesday, then set up another review."
        }
    }

    // MARK: Run

    func start(_ mode: Mode) {
        guard !busy else { return }
        self.mode = mode
        stopPlaying()
        result = nil
        reached = nil
        running = Task { await run(mode) }
    }

    /// Voice mode: the on-screen button, same as holding the talk key.
    func beginTalking() {
        guard phase == .ready else { return }
        phase = .talking
        speak.pressBegan()
    }

    func endTalking() {
        guard phase == .talking else { return }
        phase = .working
        speak.pressEnded()
    }

    func cancel() {
        if phase == .talking { speak.pressCancelled() }
        speak.probe = nil
        probe?.finish()
        _ = recorder?.stop()
        recorder = nil
        running?.cancel()
        phase = .idle
        stopPlaying()
    }

    private func run(_ mode: Mode) async {
        phase = .preparing
        var r = SpeakTestResult()
        r.sample = mode == .sample
        await speak.prepare()
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            finish(with: r, broken: .mic, problem: L("试音要用麦克风权限，请在系统设置里允许\(appDisplayName)"))
            return
        }
        guard let vm = AudioDevices.virtualMic else {
            finish(with: r, broken: .room, problem: L("还没有虚拟麦克风，先在上面装好它"))
            return
        }
        let out = speak.outputDevice()
        r.outputName = out?.name ?? L("默认输出")
        r.outputIsVirtualMic = out?.uid == vm.uid

        let recorder = LoopbackRecorder()
        guard recorder.start(deviceID: vm.id) else {
            finish(with: r, broken: .room, problem: L("打不开虚拟麦克风，点“让系统认出它”后再试"))
            return
        }
        self.recorder = recorder
        let probe = SpeakProbe()
        self.probe = probe
        speak.probe = probe

        switch mode {
        case .sample:
            phase = .working
            let buffers = await Self.synthesize(Self.sampleSentence(for: settings.speakFromLang.code),
                                                locale: settings.speakFromLang.locale)
            guard !buffers.isEmpty, await speak.speakBuffers(buffers) else {
                speak.probe = nil
                _ = recorder.stop()
                finish(with: r, broken: .mic, problem: L("语音识别还没准备好，请稍后再试"))
                return
            }
        case .voice:
            phase = .ready
        }
        await watch(probe)
        guard !Task.isCancelled, phase != .idle else { return }
        // The tail of the voice is still in Core Audio's buffers.
        try? await Task.sleep(nanoseconds: 600_000_000)
        let heard = recorder.stop()
        self.recorder = nil
        phase = .scoring
        await score(probe, heard: heard, rate: recorder.sampleRate, startedAt: recorder.startedAt, into: &r)
        finish(with: r)
    }

    /// Follows the probe so the progress list moves while the chain runs.
    private func watch(_ probe: SpeakProbe) async {
        let follow = Task { @MainActor [weak self] in
            while !Task.isCancelled, !probe.done {
                if probe.released != nil, self?.phase == .talking || self?.phase == .ready { self?.phase = .working }
                self?.reached = probe.firstAudioAt != nil ? .voice : probe.translation != nil ? .translate
                    : probe.textAt != nil ? .recognize : probe.released != nil ? .mic : nil
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        await probe.wait()
        follow.cancel()
        reached = probe.firstAudioAt != nil ? .voice : reached
    }

    private func score(_ p: SpeakProbe, heard buffers: [AVAudioPCMBuffer], rate: Double, startedAt: Date?,
                       into r: inout SpeakTestResult) async {
        r.source = p.text
        r.translation = p.translation
        r.from = p.from.isEmpty ? settings.speakFromLang.code : p.from
        r.to = p.to.isEmpty ? speak.targetCode : p.to
        r.via = p.via
        r.voice = p.voice
        if let d = p.device {
            r.outputName = d.name
            r.outputIsVirtualMic = d.isVirtualMic
        }
        if let released = p.released {
            r.recognize = p.textAt.map { $0.timeIntervalSince(released) }
            if let t = p.textAt, let tr = p.translatedAt { r.translate = tr.timeIntervalSince(t) }
            if let tr = p.translatedAt, let f = p.firstAudioAt { r.synth = f.timeIntervalSince(tr) }
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("CicadaSpeakTest", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !r.sample, let wav = p.pressWAV {
            let url = dir.appendingPathComponent("mic.wav")
            try? wav.write(to: url)
            r.micURL = url
            r.micPeakDB = Self.peakDB(wav: wav)
        }

        var samples: [Float] = []
        for b in buffers { if let ch = b.floatChannelData?[0] { samples.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(b.frameLength))) } }
        let sig = SpeakScore.signal(samples, rate: rate)
        r.heardSeconds = sig.voiced
        r.heardPeakDB = sig.peakDB
        r.clipped = sig.clipped
        r.bars = SpeakScore.bars(samples, count: 56)
        if let onset = sig.onset, let startedAt, let released = p.released {
            let at = startedAt.addingTimeInterval(onset)
            r.firstHeard = at.timeIntervalSince(released)
            if let f = p.firstAudioAt { r.arrive = at.timeIntervalSince(f) }
        }
        if !samples.isEmpty, let first = buffers.first {
            let url = dir.appendingPathComponent("heard.wav")
            try? FileManager.default.removeItem(at: url)
            if let f = try? AVAudioFile(forWriting: url, settings: first.format.settings) {
                for b in buffers { try? f.write(from: b) }
                r.heardURL = url
            }
        }

        // Where it broke: the first stage with nothing coming out.
        if !r.sample, (r.micPeakDB ?? -120) < -50 {
            r.broken = .mic
            r.problem = L("麦克风几乎没收到声音：检查系统设置里的输入设备")
        } else if p.text.isEmpty {
            r.broken = .recognize
            r.problem = L("没听出说了什么：靠近麦克风再说一次")
        } else if p.translation == nil {
            r.broken = .translate
            r.problem = L("翻译没有成功：检查网络，或稍后再试")
        } else if p.firstAudioAt == nil {
            r.broken = .voice
            r.problem = L("没有合成出声音：换一个声音再试")
        } else if sig.onset == nil {
            r.broken = .room
            r.problem = r.outputIsVirtualMic ? L("声音没进虚拟麦克风：点“再试音”或重新让系统认出它")
                : L("「声音输出到」是「\(r.outputName)」，对方只能听到虚拟麦克风里的声音")
        }
        if r.broken == nil, let sent = p.translation {
            phase = .scoring
            r.heard = await Self.transcribe(buffers, code: r.to)
            r.intelligibility = r.heard.isEmpty ? nil : SpeakScore.match(sent: sent, heard: r.heard)
            r.meaning = await judge(original: p.text, from: r.from, heard: r.heard.isEmpty ? sent : r.heard, to: r.to)
            if r.clipped > 200 { r.problem = L("声音有削波，对方可能听到破音") }
            else if let i = r.intelligibility, i < 0.6 { r.problem = L("对方那边听写出来差别较大，可能听不清") }
            else if case .score(let s, let issue) = r.meaning, s < 60 { r.problem = issue.isEmpty ? L("意思可能走样了") : issue }
        }
        debugLog("speak test: \(r.report.replacingOccurrences(of: "\n", with: " | "))")
        contentLog("speak test texts: \(r.source) => \(r.translation ?? "-") => heard \(r.heard)")
    }

    /// With a Ling key: one small call that scores whether the meaning survived. Without: the
    /// room's words translated back into the speaker's language, for the user to judge.
    private func judge(original: String, from: String, heard: String, to: String) async -> SpeakTestResult.Meaning {
        if ling.usable {
            let content = """
            Original (\(TranslationService.englishName(from))): \(original)
            What the listener heard (\(TranslationService.englishName(to))): \(heard)
            """
            let instruction = "Score from 0 to 100 how faithfully what the listener heard conveys the original's meaning. "
                + "Reply as JSON: {\"score\": <0-100>, \"issue\": \"<the main problem in at most 12 words of \(TranslationService.englishName(from)), or empty>\"}"
            if let reply = try? await ling.chat(content: content, instruction: instruction, priority: .translate, json: true,
                                                maxTokens: 120, timeout: 10, role: "test"),
               let v = SpeakScore.parseJudge(reply) {
                return .score(v.score, v.issue)
            }
        }
        if let back = await translate?(heard, to, from), !back.isEmpty { return .back(back) }
        return .unchecked
    }

    private func finish(with r: SpeakTestResult, broken: SpeakTestResult.Stage? = nil, problem: String? = nil) {
        var r = r
        if let broken { r.broken = broken; r.problem = problem }
        speak.probe = nil
        result = r
        phase = .done
        probe = nil
        if let v = r.firstHeard, r.broken == nil { onLatency?(v) }
    }

    // MARK: Playback

    func play(_ url: URL?) {
        guard let url else { return }
        if playing == url { stopPlaying(); return }
        stopPlaying()
        player = try? AVAudioPlayer(contentsOf: url)
        player?.play()
        playing = url
        let duration = player?.duration ?? 0
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((duration + 0.2) * 1_000_000_000))
            if self?.playing == url { self?.playing = nil }
        }
    }

    func stopPlaying() {
        player?.stop()
        player = nil
        playing = nil
    }

    // MARK: Helpers

    private static func peakDB(wav: Data) -> Double {
        guard wav.count > 44 else { return -120 }
        var peak: Int32 = 0
        wav.dropFirst(44).withUnsafeBytes { raw in
            for s in raw.bindMemory(to: Int16.self) { peak = max(peak, abs(Int32(Int16(littleEndian: s)))) }
        }
        return peak > 0 ? 20 * log10(Double(peak) / 32768) : -120
    }

    /// A sentence in the speaker's language in the Mac's voice: the "sample" input.
    private static func synthesize(_ text: String, locale: String) async -> [AVAudioPCMBuffer] {
        let synth = AVSpeechSynthesizer()
        let u = AVSpeechUtterance(string: text)
        let lang = locale.hasPrefix("zh") ? "zh-CN" : locale
        u.voice = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == lang && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: lang)
        let buffers = await SpeechWriter.write(u, with: synth)
        _ = synth
        return buffers
    }

    /// The room's audio transcribed again in its language, downloading the model if needed.
    private static func transcribe(_ buffers: [AVAudioPCMBuffer], code: String) async -> String {
        let locale = sourceLanguages.first { $0.code == code }?.locale ?? (code == "zh-TW" ? "zh-TW" : code)
        try? await Recognition.install(locale)
        return await LoopbackTest.transcribe(buffers, locale: locale)
    }
}

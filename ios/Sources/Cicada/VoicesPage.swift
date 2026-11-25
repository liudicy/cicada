import AVFoundation
import SwiftUI

/// 每种语言各记一个声音: the Mac's `speakVoices` (language key → voice id), read by 面对面.
enum SpeakVoices {
    static let key = "speakVoices"

    static var all: [String: String] { UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:] }

    /// The voice for a language: the one picked, while it can still be used (Ming and the clone need
    /// the key, the clone its recording), else the catalog's default. `mine`: read for me (their
    /// words in my language), where my own voice would make no sense.
    /// `clones`: the service can speak in the user's own voice (Ling only). A voice of another
    /// service (Ming's picked under Ling, then ZenMux chosen) gives way to the default.
    static func chosenID(for language: String, hasKey: Bool, mine: Bool = false, clones: Bool = true) -> String? {
        if let id = all[VoiceCatalog.key(for: language)] {
            if id.hasPrefix("system:") { return id }
            if hasKey, id == VoiceCatalog.cloneOption.id {
                if clones, !mine, VoiceReference.exists { return id }
            } else if hasKey, VoiceCatalog.remote(for: language).contains(where: { $0.id == id }) {
                return id
            }
        }
        return VoiceCatalog.defaultID(for: language, hasKey: hasKey)
    }

    static func set(_ id: String, for language: String) {
        var d = all
        d[VoiceCatalog.key(for: language)] = id
        UserDefaults.standard.set(d, forKey: key)
    }
}

/// 设置 › 念给对方的声音: 用你自己的声音 (a recording Ming clones), then each language 面对面
/// speaks, with Ming's voices and the phone's; ▶ tries one with a line in that language.
struct VoicesPage: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var ling: LingClient
    @ObservedObject var face: FaceToFace
    @State private var chosen = SpeakVoices.all
    @State private var trying: String?
    @State private var recording = false
    @State private var hasOwn = VoiceReference.exists
    private let voice = FaceVoice()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                own
                Text("每种语言各记一个声音").font(.footnote.weight(.semibold)).foregroundStyle(Ink.secondary)
                    .padding(.horizontal, 4).padding(.top, 24)
                ForEach(languages, id: \.self) { lang in
                    section(lang)
                }
                if ling.provider.id == .ling {
                    Text(ling.hasKey ? L("Ling 不可用时自动换成手机的声音") : L("填入 Ling key 后可用 Ming 声音和你自己的声音"))
                        .font(.footnote).foregroundStyle(Ink.secondary).padding(.horizontal, 4).padding(.top, 10)
                }
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 120)
            .frame(maxWidth: 640).frame(maxWidth: .infinity)
        }
        .background(Ink.ground)
        .navigationTitle(Text("念给对方的声音"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $recording, onDismiss: { hasOwn = VoiceReference.exists }) {
            OwnVoiceSheet(locale: face.mine.locale) { recording = false }
        }
        .onDisappear { voice.stop() }
    }

    /// Theirs first: what 面对面 reads to the other person; then mine, what it reads to me.
    private var languages: [String] {
        let both = [face.theirs.code, face.mine.code]
        return both.enumerated().filter { i, c in both.prefix(i).allSatisfy { VoiceCatalog.key(for: $0) != VoiceCatalog.key(for: c) } }.map(\.1)
    }

    private var own: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "mic.fill").font(.system(size: 18, weight: .semibold)).foregroundStyle(Ink.accentText)
                        .frame(width: 44, height: 44).background(Ink.accentWash, in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("用你自己的声音").font(.headline).foregroundStyle(Ink.ink)
                        Text("录 15 秒原声，对方听到你的音色，晚约 3 秒").font(.footnote).foregroundStyle(Ink.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !ling.clones {
                    Text("只有 Ling 能用你自己的声音").font(.footnote).foregroundStyle(Ink.secondary)
                } else if hasOwn {
                    HStack(spacing: 10) {
                        Button { tryVoice(VoiceCatalog.cloneOption.id, face.theirs.code) } label: {
                            Label(L("试听"), systemImage: trying == VoiceCatalog.cloneOption.id ? "stop.fill" : "play.fill")
                                .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).frame(height: 44)
                                .background(Ink.ground, in: Capsule())
                        }
                        Button { recording = true } label: {
                            Text("重录").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).frame(height: 44)
                                .background(Ink.ground, in: Capsule())
                        }
                        Button(role: .destructive) { VoiceReference.remove(); hasOwn = false } label: {
                            Text("删除").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).frame(height: 44)
                                .background(Ink.ground, in: Capsule())
                        }
                    }
                    .buttonStyle(.plain).foregroundStyle(Ink.ink)
                } else {
                    Button { recording = true } label: {
                        Text("录制你的声音").font(.headline).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).frame(height: 46).background(Ink.ink, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
    }

    private func section(_ lang: String) -> some View {
        let options = VoiceCatalog.options(for: lang)
        let mine = VoiceCatalog.key(for: lang) == VoiceCatalog.key(for: face.mine.code) && lang != face.theirs.code
        // My own voice only for what is read to the other person (这是我自己的声音。只在我说话时用它替我翻译。).
        let rows = (!mine && hasOwn && ling.clones ? [VoiceCatalog.cloneOption] : []) + options
        let current = SpeakVoices.chosenID(for: lang, hasKey: ling.hasKey, mine: mine, clones: ling.clones)
        return VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: name(lang) + " · " + (mine ? L("对方说\(Pref.name(of: face.theirs))时用") : L("对方会听到这个")))
                .font(.footnote).foregroundStyle(Ink.secondary).padding(.horizontal, 4).padding(.top, 14)
            Card {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, o in
                        if i > 0 { Hairline() }
                        row(o, lang: lang, on: o.id == current)
                    }
                }
            }
        }
    }

    private func name(_ code: String) -> String {
        targetLanguages.first { $0.code == code }?.name ?? sourceLanguages.first { $0.code == code }.map { Pref.name(of: $0) } ?? code
    }

    private func row(_ o: VoiceOption, lang: String, on: Bool) -> some View {
        let usable = !o.needsKey || ling.hasKey
        return HStack(spacing: 12) {
            Button {
                guard usable else { return }
                SpeakVoices.set(o.id, for: lang)
                chosen = SpeakVoices.all
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: o.name).font(.body).foregroundStyle(usable ? Ink.ink : Ink.tertiary)
                        let tags = o.kind == .clone ? [L("最像你")] : o.tags
                        if !tags.isEmpty {
                            Text(verbatim: tags.joined(separator: " · ")).font(.caption).foregroundStyle(Ink.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    if on { Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Ink.accentText) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(on ? .isSelected : [])
            Button { tryVoice(o.id, lang) } label: {
                Image(systemName: trying == o.id ? "stop.fill" : "play.fill").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Ink.ink).frame(width: 36, height: 36).background(Ink.ground, in: Circle())
            }
            .buttonStyle(.plain)
            .frame(width: 44, height: 44)
            .disabled(!usable)
            .accessibilityLabel(Text("试听"))
        }
        .padding(.horizontal, 16).frame(minHeight: 56)
    }

    private func tryVoice(_ id: String, _ lang: String) {
        if trying == id { voice.stop(); trying = nil; return }
        trying = id
        Task {
            await voice.speak(VoiceCatalog.sample(for: lang), language: lang, ling: ling.hasKey ? ling : nil, voiceID: id)
            if trying == id { trying = nil }
        }
    }
}

/// 录制你的声音: the passage to read, a meter and the seconds, 读完了; then 录好了，先听听像不像.
struct OwnVoiceSheet: View {
    @EnvironmentObject var ling: LingClient
    let locale: String
    let done: () -> Void
    @StateObject private var rec = OwnVoiceRecorder()
    @State private var trying = false
    private let voice = FaceVoice()

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Text("请用平时开会的自然语气朗读以下段落，约 15 秒，在安静环境下录制效果最佳。")
                    .font(.subheadline).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
                Text(verbatim: VoiceReference.passage(for: locale))
                    .font(.title3).foregroundStyle(Ink.ink).lineSpacing(6)
                    .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                Spacer(minLength: 0)
                switch rec.phase {
                case .idle, .failed:
                    if case .failed(let why) = rec.phase {
                        Text(verbatim: why).font(.footnote).foregroundStyle(Ink.accentText)
                    }
                    big(L("录制你的声音")) { rec.start(passage: VoiceReference.passage(for: locale)) }
                case .recording:
                    HStack(spacing: 12) {
                        Wave(level: rec.level)
                        Text(L("\(Int(rec.seconds)) 秒")).font(.headline).monospacedDigit().foregroundStyle(Ink.ink)
                        Spacer()
                    }
                    big(L("读完了")) { rec.finish() }
                        .disabled(rec.seconds < OwnVoiceRecorder.minSeconds)
                        .opacity(rec.seconds < OwnVoiceRecorder.minSeconds ? 0.5 : 1)
                case .ready:
                    Text("录好了，先听听像不像").font(.headline).foregroundStyle(Ink.ink)
                    Text("听起来不像或有杂音？换个安静的地方重录一次。录音只存在这台手机上，可随时删除。")
                        .font(.footnote).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button { listen() } label: {
                            Label(L("试听"), systemImage: trying ? "stop.fill" : "play.fill").font(.headline)
                                .frame(maxWidth: .infinity).frame(height: 50).background(Color.white, in: Capsule())
                        }
                        .buttonStyle(.plain).foregroundStyle(Ink.ink)
                        Button { rec.start(passage: VoiceReference.passage(for: locale)) } label: {
                            Text("再录一次").font(.headline).frame(maxWidth: .infinity).frame(height: 50).background(Color.white, in: Capsule())
                        }
                        .buttonStyle(.plain).foregroundStyle(Ink.ink)
                    }
                    big(L("用这个声音")) { voice.stop(); done() }
                }
            }
            .padding(20)
            .background(Ink.ground)
            .navigationTitle(Text("录制你的声音"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { rec.cancel(); voice.stop(); done() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(Text("取消"))
                }
            }
        }
        .interactiveDismissDisabled(rec.phase == .recording)
    }

    private func big(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title).font(.headline).foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 50).background(Ink.ink, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// What the other person will hear: a line in their language, in the voice just recorded.
    private func listen() {
        if trying { voice.stop(); trying = false; return }
        trying = true
        Task {
            let lang = locale.hasPrefix("en") ? "zh-CN" : "en-US"
            await voice.speak(VoiceCatalog.sample(for: lang), language: lang, ling: ling, voiceID: VoiceCatalog.cloneOption.id)
            trying = false
        }
    }
}

/// Records the user reading the passage: 16 kHz mono into a WAV, with a level for the meter;
/// stops by itself at 30 s. Saved as `VoiceReference` with the passage as what it says (the Mac
/// transcribes its recording; here the passage is read as shown, and Ming only needs it close).
@MainActor
final class OwnVoiceRecorder: ObservableObject {
    enum Phase: Equatable { case idle, recording, ready, failed(String) }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var seconds: Double = 0
    @Published private(set) var level: Float = 0
    static let minSeconds = 8.0, maxSeconds = 30.0

    private let engine = AVAudioEngine()
    private nonisolated(unsafe) var file: AVAudioFile?
    private nonisolated(unsafe) var converter: AVAudioConverter?
    private var timer: Timer?
    private var started = Date()
    private let url = FileManager.default.temporaryDirectory.appendingPathComponent("cicada-voice.wav")
    private let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

    func start(passage: String) {
        self.passage = passage
        Task {
            guard await AVAudioApplication.requestRecordPermission() else {
                phase = .failed(L("麦克风没收到声音，请检查麦克风权限"))
                return
            }
            begin()
        }
    }

    private func begin() {
        stopEngine()
        try? FileManager.default.removeItem(at: url)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
        try? session.setActive(true)
        let input = engine.inputNode
        let inFormat = input.inputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0,
              let f = try? AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true),
              let conv = AVAudioConverter(from: inFormat, to: format) else {
            phase = .failed(L("麦克风没收到声音，请检查麦克风权限"))
            return
        }
        file = f
        converter = conv
        let outFormat = format
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            guard let self, let conv = self.converter, let file = self.file else { return }
            let ratio = outFormat.sampleRate / buffer.format.sampleRate
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32) else { return }
            var fed = false
            conv.convert(to: out, error: nil) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            try? file.write(from: out)
            var peak: Float = 0
            if let ch = buffer.floatChannelData?[0] { for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(ch[i])) } }
            Task { @MainActor in self.level = min(1, peak * 2.5) }
        }
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            phase = .failed(L("麦克风没收到声音，请检查麦克风权限"))
            return
        }
        started = Date()
        seconds = 0
        phase = .recording
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.seconds = Date().timeIntervalSince(self.started)
                if self.seconds >= Self.maxSeconds { self.finish() }
            }
        }
        timer = t
        RunLoop.main.add(t, forMode: .common)
    }

    private var passage = ""

    func finish() {
        guard phase == .recording else { return }
        stopEngine()
        guard seconds >= Self.minSeconds else {
            phase = .failed(L("录音太短了，请至少朗读 \(Int(Self.minSeconds)) 秒"))
            return
        }
        do {
            try VoiceReference.save(wav: url, text: passage)
            try? FileManager.default.removeItem(at: url)
            debugLog("voice clone: saved \(String(format: "%.1f", VoiceReference.duration)) s")
            phase = .ready
        } catch {
            phase = .failed(L("麦克风没收到声音，请检查麦克风权限"))
        }
    }

    func cancel() {
        stopEngine()
        phase = .idle
        try? FileManager.default.removeItem(at: url)
    }

    private func stopEngine() {
        timer?.invalidate()
        timer = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        file = nil
        converter = nil
        level = 0
    }
}

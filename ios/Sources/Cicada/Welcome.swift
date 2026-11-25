import AVFoundation
import SwiftUI

// 第一次打开: three steps, as the design canvas (知了 iOS M2–M4). iPhone can't hear other apps or
// speak into them, so the Mac's system-audio and BlackHole steps have no place here: the microphone
// and the speech model, a sample meeting played aloud, then the Ling key.

struct Welcome: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Dots(step: model.welcomeStep).padding(.top, 18)
            Group {
                switch model.welcomeStep {
                case 0: WelcomeListen()
                case 1: WelcomeSample()
                default: WelcomeKey()
                }
            }
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .background(Ink.ground.ignoresSafeArea())
        .tint(Ink.accent)
        .preferredColorScheme(.light)
        .animation(.snappy(duration: 0.25), value: model.welcomeStep)
    }
}

/// Where the user is: the current step a short bar, the others dots.
private struct Dots: View {
    let step: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { i in
                Capsule().fill(i == step ? Ink.ink : Color(hex: 0xC9CCD3))
                    .frame(width: i == step ? 22 : 6, height: 6)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text(L("第 \(step + 1) 步，共 3 步")))
    }
}

/// The black capsule every step ends on.
struct PrimaryButton: View {
    let title: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.headline).foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(enabled ? Ink.ink : Ink.tertiary, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

// MARK: Step 1: the microphone and the speech model

private struct WelcomeListen: View {
    @EnvironmentObject var model: AppModel
    @State private var mic = AVAudioApplication.shared.recordPermission
    @State private var speech: ModelState = .unknown

    enum ModelState: Equatable { case unknown, ready, missing, downloading, failed }

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 12) {
                Logo(size: 72)
                Text("听会议室").font(.system(size: 28, weight: .bold)).foregroundStyle(Ink.ink)
                Text("用麦克风听，实时双语字幕和纪要").font(.subheadline).foregroundStyle(Ink.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 28)
            Card {
                row(icon: "mic", title: L("麦克风"), detail: L("听会议室里的人说话")) { micState }
                Hairline(inset: 54)
                row(icon: "text.alignleft", title: L("\(Pref.name(of: Pref.sourceLang))语音模型"), detail: L("在手机上把声音转成文字")) { speechState }
            }
            Spacer(minLength: 0)
            VStack(spacing: 10) {
                PrimaryButton(title: L("继续")) { model.welcomeStep = 1 }
                Text("线上会议里的声音请用电脑版").font(.footnote).foregroundStyle(Ink.tertiary)
            }
        }
        .task { await refreshSpeech() }
    }

    private func row<V: View>(icon: String, title: String, detail: String, @ViewBuilder trailing: () -> V) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 19)).foregroundStyle(Ink.ink).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).foregroundStyle(Ink.ink)
                Text(detail).font(.footnote).foregroundStyle(Ink.secondary)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(minHeight: 60)
    }

    @ViewBuilder private var micState: some View {
        switch mic {
        case .granted: Done(text: L("已允许"))
        case .denied:
            SmallButton(title: L("去设置")) {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
        default:
            SmallButton(title: L("允许")) {
                Task {
                    _ = await AVAudioApplication.requestRecordPermission()
                    mic = AVAudioApplication.shared.recordPermission
                    debugLog("welcome: microphone \(mic == .granted ? "granted" : "denied")")
                }
            }
        }
    }

    @ViewBuilder private var speechState: some View {
        switch speech {
        case .ready: Done(text: L("已就绪"))
        case .downloading: ProgressView().controlSize(.small)
        case .unknown: EmptyView()
        case .missing, .failed:
            SmallButton(title: speech == .failed ? L("重试") : L("下载")) {
                speech = .downloading
                Task {
                    do {
                        try await Recognition.install(Pref.sourceLang.locale)
                        speech = .ready
                    } catch {
                        debugLog("welcome: model download failed: \(error)")
                        speech = .failed
                    }
                }
            }
        }
    }

    private func refreshSpeech() async {
        speech = await Recognition.status(Pref.sourceLang.locale) == .installed ? .ready : .missing
    }
}

private struct Done: View {
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Ink.ok).frame(width: 7, height: 7)
            Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(Ink.ok)
        }
    }
}

private struct SmallButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Ink.ink)
                .padding(.horizontal, 16).frame(minHeight: 34)
                .background(Ink.ground, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
    }
}

// MARK: Step 2: the sample meeting, played aloud and heard through the microphone

private struct WelcomeSample: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var room: RoomListen
    @ObservedObject var sample: SampleRun

    init() { sample = SampleRun.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("先听一段示例").font(.system(size: 28, weight: .bold)).foregroundStyle(Ink.ink)
                Text("手机放出来，知了用麦克风听").font(.subheadline).foregroundStyle(Ink.secondary)
            }
            .padding(.horizontal, 4).padding(.top, 28)
            Card {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        if room.isRunning {
                            TimelineView(.periodic(from: .now, by: 1)) { _ in
                                HStack(spacing: 6) {
                                    LiveDot()
                                    Text(L("正在听 · \(TranscriptExport.clock(room.elapsed))"))
                                }
                                .font(.footnote.weight(.semibold).monospacedDigit()).foregroundStyle(Ink.accentText)
                            }
                        } else {
                            Text(sample.played ? L("放完了") : L("约 \(Int(SampleRun.duration.rounded())) 秒")).font(.footnote).foregroundStyle(Ink.secondary)
                        }
                        Text(verbatim: L("示例会议") + " · " + Pref.pairText("en", Pref.target(for: "en"))).font(.headline).foregroundStyle(Ink.ink)
                    }
                    Spacer(minLength: 8)
                    Button { sample.playing ? model.stopSample() : model.playSample() } label: {
                        Image(systemName: sample.playing ? "stop.fill" : "play.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(sample.playing ? Ink.ink : .white)
                            .frame(width: 46, height: 46)
                            .background(sample.playing ? Ink.ground : Ink.accent, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(sample.playing ? Text("停止") : Text("播放示例"))
                }
                .padding(.leading, 18).padding(.trailing, 10).padding(.vertical, 10)
                if sample.playing {
                    GeometryReader { g in
                        Capsule().fill(Ink.accent).frame(width: g.size.width * sample.progress, height: 3)
                    }
                    .frame(height: 3)
                    .padding(.horizontal, 18).padding(.bottom, 10)
                }
            }
            Card {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if room.lines.isEmpty && room.draft.isEmpty {
                                Text(room.status.isEmpty ? L("按 ▶ 开始，字幕会出现在这里") : room.status)
                                    .font(.subheadline).foregroundStyle(Ink.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            ForEach(room.lines.suffix(6)) { l in
                                SampleLine(src: l.src, dst: l.dst ?? "", voice: l.voice, final: true)
                            }
                            if !room.draft.isEmpty {
                                SampleLine(src: room.draft, dst: room.draftTranslation, voice: nil, final: false).id("draft")
                            }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .padding(18)
                    }
                    .onChange(of: room.lines.count) { proxy.scrollTo("end", anchor: .bottom) }
                    .onChange(of: room.draft) { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
            .frame(maxHeight: .infinity)
            VStack(spacing: 10) {
                PrimaryButton(title: room.lines.isEmpty ? L("跳过") : L("听到了，继续")) {
                    model.stopSample()
                    model.welcomeStep = 2
                }
                Text("没出字？把音量调大，手机别盖住").font(.footnote).foregroundStyle(Ink.tertiary)
                    .frame(maxWidth: .infinity)
            }
        }
        .onDisappear { model.stopSample() }
    }
}

private struct SampleLine: View {
    let src: String
    let dst: String
    let voice: Int?
    let final: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let voice {
                Text(L("说话人 \(voice + 1)")).font(.caption.weight(.semibold))
                    .foregroundStyle(SpeakerInk.ink(voice + 1))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(SpeakerInk.tint(voice + 1), in: Capsule())
            }
            Text(verbatim: src).font(.subheadline).foregroundStyle(Ink.secondary)
            if !dst.isEmpty {
                Text(verbatim: dst).font(.body.weight(.semibold)).foregroundStyle(final ? Ink.ink : Ink.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// sample.m4a through the speaker while the microphone listens: the room pipeline end to end.
@MainActor
final class SampleRun: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = SampleRun()
    static let duration: Double = Bundle.main.url(forResource: "sample", withExtension: "m4a")
        .flatMap { try? AVAudioPlayer(contentsOf: $0) }?.duration ?? 0
    @Published private(set) var playing = false
    @Published private(set) var played = false
    @Published private(set) var progress = 0.0
    private var player: AVAudioPlayer?
    private var ticker: Timer?
    var onFinished: (() -> Void)?

    func play() {
        guard !playing, let url = Bundle.main.url(forResource: "sample", withExtension: "m4a"),
              let p = try? AVAudioPlayer(contentsOf: url) else { return }
        player = p
        p.delegate = self
        p.volume = 1
        p.play()
        playing = true
        progress = 0
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let p = self.player, p.duration > 0 else { return }
                self.progress = p.currentTime / p.duration
            }
        }
        debugLog("sample: playing \(Int(p.duration)) s")
    }

    func stop() {
        guard playing else { return }
        player?.stop()
        finish()
    }

    private func finish() {
        ticker?.invalidate()
        ticker = nil
        player = nil
        playing = false
        played = true
        progress = 1
        onFinished?()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        MainActor.assumeIsolated {
            debugLog("sample: finished")
            finish()
        }
    }
}

// MARK: Step 3: the Ling key

private struct WelcomeKey: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var ling: LingClient
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: L("填入 Ling key")).font(.system(size: 28, weight: .bold)).foregroundStyle(Ink.ink)
                Text("纪要、改错和同声传译要用；不填也能看字幕").font(.subheadline).foregroundStyle(Ink.secondary)
            }
            .padding(.horizontal, 4).padding(.top, 28)
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Text(verbatim: "API key").font(.footnote).foregroundStyle(Ink.secondary)
                    HStack(spacing: 8) {
                        Group {
                            if let key = ling.key {
                                Text(verbatim: AIKey.masked(key)).frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                SecureField(text: $draft) { Text(verbatim: "sk-…") }
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .submitLabel(.done)
                                    .onSubmit { save(draft) }
                            }
                        }
                        .font(.body.monospaced())
                        .padding(.horizontal, 12).frame(minHeight: 46)
                        .background(Color(hex: 0xF9FAFB), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Ink.line))
                        Button { save(UIPasteboard.general.string ?? "") } label: {
                            Text(ling.key == nil ? L("粘贴") : L("更换")).font(.body.weight(.semibold)).foregroundStyle(Ink.ink)
                                .padding(.horizontal, 14).frame(minHeight: 46)
                                .background(Ink.ground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                    if ling.key != nil { KeyStatus(state: ling.keyState).font(.subheadline.weight(.semibold)) }
                }
                .padding(16)
            }
            Card {
                Link(destination: URL(string: "https://chat.ant-ling.com/platform/api")!) {
                    HStack {
                        Text("没有 key？去 Ling 拿一个").foregroundStyle(Ink.ink)
                        Spacer()
                        Image(systemName: "arrow.up.right").font(.footnote.weight(.semibold)).foregroundStyle(Ink.tertiary)
                    }
                    .padding(.horizontal, 16).frame(minHeight: 50)
                }
            }
            Text("key 只存在这台手机上，不进备份").font(.footnote).foregroundStyle(Ink.tertiary).padding(.horizontal, 16)
            Spacer(minLength: 0)
            VStack(spacing: 6) {
                PrimaryButton(title: L("开始用知了")) { model.finishWelcome() }
                if ling.key == nil {
                    Button { model.finishWelcome() } label: {
                        Text("以后再填").font(.subheadline).foregroundStyle(Ink.secondary).frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func save(_ raw: String) {
        let k = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        draft = ""
        Task { await ling.setKey(k) }
    }
}

extension AppModel {
    /// The sample on step 2: listening starts (in English, the sample's language), and the sample
    /// plays once the microphone is on; the meeting ends shortly after it does, so its last line lands.
    func playSample() {
        let sample = SampleRun.shared
        guard !sample.playing else { return }
        if !room.isRunning {
            fixes.meetingStarted()
            room.start(source: "en-US", target: Pref.target(for: "en"), voices: UserDefaults.standard.bool(forKey: Pref.voices))
        }
        sample.onFinished = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.stopListening() }
        }
        Task {
            for _ in 0..<600 where room.isRunning && room.sessionID == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
            guard room.isRunning, room.sessionID != nil else { return }
            sample.play()
        }
    }

    func stopSample() {
        SampleRun.shared.onFinished = nil
        SampleRun.shared.stop()
        if room.isRunning { stopListening() }
    }

    func finishWelcome() {
        UserDefaults.standard.set(true, forKey: Pref.welcomed)
        showWelcome = false
        debugLog("welcome: done key=\(ling.hasKey)")
    }
}

import AVFoundation
import SwiftUI

/// Settings › 同声传译, third step "对方听到": the voice for the room's current language as one chip,
/// opening into a list (any language, the Mac's voices, the user's own cloned voice). Each language
/// remembers its own choice (`speakVoices`).
struct VoiceSection: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var ling: LingClient

    @State private var tab: String?
    @State private var recording = false
    /// Bumped when the recording changes on disk.
    @State private var cloneVersion = 0

    private var roomKey: String { VoiceCatalog.key(for: model.speak.targetCode) }
    private var current: String { tab ?? roomKey }
    private var language: String { current == "zh" ? "zh-CN" : current }
    private var chosen: String? { model.voiceID(for: language) }
    private var roomLanguage: String { roomKey == "zh" ? "zh-CN" : roomKey }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The language is its own row above: this row is only the voice.
            HStack(spacing: 12) {
                Text("声音").font(.system(size: 13)).foregroundStyle(Palette.ink)
                Spacer(minLength: 8)
                chip
            }
            .padding(.horizontal, 16).padding(.vertical, 8).frame(minHeight: 46)
            if !ling.speechCapable { keyNudge }
            if model.voicePickerOpen { picker.padding(.horizontal, 16).padding(.bottom, 14) }
        }
        .sheet(isPresented: $recording) {
            VoiceCloneSheet(model: model, settings: settings, language: language) { saved in
                recording = false
                if saved {
                    cloneVersion += 1
                    model.setVoice("clone", for: language)
                }
            }
        }
    }

    // MARK: Chip

    private var roomOption: VoiceOption? {
        let id = model.voiceID(for: roomLanguage)
        if id == "clone" { return VoiceCatalog.cloneOption }
        return VoiceCatalog.options(for: roomLanguage).first { $0.id == id }
    }

    private var chip: some View {
        let v = roomOption
        return HStack(spacing: 8) {
            playButton(v?.id ?? "", highlighted: true, enabled: v != nil) {
                if let v { model.previewVoice(v.id, language: roomLanguage) }
            }
            Button { withAnimation(.easeOut(duration: 0.15)) { model.voicePickerOpen.toggle(); tab = nil } } label: {
                HStack(spacing: 6) {
                    Text(v?.name ?? L("系统声音")).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    if let v { Text(summary(v)).font(.system(size: 11)).foregroundStyle(Palette.secondary).lineLimit(1) }
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.tertiary)
                        .rotationEffect(.degrees(model.voicePickerOpen ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("选择对方听到的声音"))
        }
        .padding(.leading, 4).padding(.trailing, 10).frame(height: 36)
        .background(Capsule().fill(Color.white))
        .overlay(Capsule().stroke(model.voicePickerOpen ? Palette.accent : Palette.line, lineWidth: 1))
        .fixedSize()
    }

    /// "女 · Ming" / "男 · 本机": who it is and where it comes from.
    private func summary(_ v: VoiceOption) -> String {
        switch v.kind {
        case .ming: return [v.tags.first, "Ming"].compactMap { $0 }.joined(separator: " · ")
        case .system: return [v.tags.first, L("本机")].compactMap { $0 }.joined(separator: " · ")
        case .clone: return L("你的音色")
        }
    }

    private var keyNudge: some View {
        HStack(spacing: 10) {
            Text("填入 Ling key：声音更自然，还能用你自己的声音").font(.system(size: 12)).foregroundStyle(Palette.secondary)
            Spacer(minLength: 6)
            Button("去填写") { model.settingsSection = .ai }.buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 9).fill(Palette.raised))
        .padding(.horizontal, 16).padding(.bottom, 12)
    }

    // MARK: Picker

    private var picker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(current == roomKey ? L("每种语言各记一个声音") : L("对方说\(title(current))时用")).font(.system(size: 12))
                    .foregroundStyle(Palette.tertiary)
                Spacer()
                PillMenu(value: title(current) + (current == roomKey ? L("（当前）") : ""),
                         options: VoiceCatalog.languages.map { ($0.key, $0.title + ($0.key == roomKey ? L("（当前）") : "")) }) {
                    tab = $0 == roomKey ? nil : $0
                }
            }
            VStack(spacing: 0) {
                ForEach(VoiceCatalog.options(for: language)) { v in
                    row(v)
                    Divider()
                }
                cloneRow
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line, lineWidth: 1))
            Text(footnote).font(.system(size: 11)).foregroundStyle(Palette.tertiary)
        }
        .padding(.leading, 34)
    }

    private func title(_ key: String) -> String {
        VoiceCatalog.languages.first { $0.key == key }?.title ?? targetName(key)
    }

    private func row(_ v: VoiceOption) -> some View {
        let selected = chosen == v.id
        let usable = !v.needsKey || ling.speechCapable
        return Button { if usable { model.setVoice(v.id, for: language) } } label: {
            HStack(spacing: 10) {
                playButton(v.id, highlighted: selected, enabled: usable) { model.previewVoice(v.id, language: language) }
                Text(v.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                    .frame(width: 88, alignment: .leading)
                Text(usable ? v.tags.prefix(2).joined(separator: " · ") + (v.needsKey ? " · Ming" : "") : L("需要 Ling key"))
                    .font(.system(size: 12)).foregroundStyle(Palette.secondary).lineLimit(1)
                Spacer(minLength: 6)
                Text(v.needsKey ? L("慢约 1 秒") : L("最快")).font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                Radio(on: selected)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(selected ? Palette.accentWash : Color.clear)
            .opacity(usable ? 1 : 0.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func playButton(_ id: String, highlighted: Bool, enabled: Bool, action: @escaping () -> Void) -> some View {
        let playing = model.previewing == id
        return Button(action: action) {
            ZStack {
                Circle().fill(highlighted ? Palette.accent : Palette.fill)
                if playing {
                    Spinner(size: 11, track: highlighted ? Color.white.opacity(0.4) : Palette.accentPale)
                } else {
                    Image(systemName: "play.fill").font(.system(size: 9))
                        .foregroundStyle(highlighted ? Color.white : Palette.ink)
                }
            }
            .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .disabled(!enabled || playing)
        .help("试听")
        .accessibilityLabel(L("试听"))
    }

    @ViewBuilder
    private var cloneRow: some View {
        let has = VoiceReference.exists && cloneVersion >= 0
        let selected = chosen == "clone"
        HStack(spacing: 10) {
            if has {
                playButton("clone", highlighted: selected, enabled: ling.speechCapable) { model.previewVoice("clone", language: language) }
            } else {
                ZStack {
                    Circle().fill(Palette.accentPale)
                    Image(systemName: "mic").font(.system(size: 12)).foregroundStyle(Palette.accentInk)
                }
                .frame(width: 28, height: 28)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("我自己的声音").font(.system(size: 13, weight: .semibold))
                if has {
                    HStack(spacing: 4) {
                        Text("已录 \(Int(VoiceReference.duration.rounded())) 秒 · \(cloneNote)")
                        Text("·")
                        Button("重录") { recording = true }.buttonStyle(.plain).underline()
                        Button("删除") {
                            VoiceReference.remove()
                            for (k, v) in settings.speakVoices where v == "clone" { settings.speakVoices[k] = nil }
                            cloneVersion += 1
                        }
                        .buttonStyle(.plain).underline()
                    }
                    .font(.system(size: 11)).foregroundStyle(Palette.tertiary).lineLimit(1)
                } else {
                    Text("录 15 秒原声，对方听到你的音色，晚约 3 秒").font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                }
            }
            Spacer(minLength: 6)
            if has {
                Button { if ling.speechCapable { model.setVoice("clone", for: language) } } label: { Radio(on: selected) }
                    .buttonStyle(.plain).disabled(!ling.speechCapable)
                    .accessibilityLabel(L("用我自己的声音"))
            } else {
                SoftButton(L("录制")) { recording = true }.disabled(!ling.speechCapable)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(selected ? Palette.accentWash : Palette.raised)
    }

    private var cloneNote: String {
        let own = VoiceCatalog.key(for: settings.speakFromLang.locale)
        return own == current ? L("最像你") : L("会带你的口音")
    }

    private var footnote: String {
        ling.speechCapable ? L("Ling 不可用时自动换成本机声音") : L("填入 Ling key 后可用 Ming 声音和你自己的声音")
    }
}

/// A radio dot for list rows.
struct Radio: View {
    let on: Bool
    var body: some View {
        ZStack {
            Circle().stroke(on ? Palette.accent : Palette.placeholder, lineWidth: 1.5)
            if on { Circle().fill(Palette.accent).frame(width: 8, height: 8) }
        }
        .frame(width: 16, height: 16)
    }
}

// MARK: - Recording sheet

/// Read a passage for 15 s → transcribe it on this Mac → listen to the original and to the clone
/// speaking the room's language → keep it.
struct VoiceCloneSheet: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    let language: String
    let onDone: (Bool) -> Void

    @StateObject private var recorder = VoiceRecorder()
    @State private var consent = false
    @State private var player: AVAudioPlayer?
    @State private var clonePlaying = false

    private var ownLocale: String { settings.speakFromLang.locale }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch recorder.phase {
            case .ready: review
            default: record
            }
        }
        .padding(28)
        .frame(width: 560)
        .background(Color.white)
        .onDisappear { recorder.cancel(); player?.stop() }
    }

    // MARK: Record

    private var record: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("录制你的声音").font(.system(size: 18, weight: .bold))
                Text("请用平时开会的自然语气朗读以下段落，约 15 秒，在安静环境下录制效果最佳。")
                    .font(.system(size: 13)).foregroundStyle(Palette.secondary)
            }
            Text(VoiceReference.passage(for: ownLocale))
                .font(.system(size: 16)).lineSpacing(7)
                .padding(.horizontal, 20).padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14).fill(Palette.raised))
                .textSelection(.enabled)
            meter
            Toggle(isOn: $consent) {
                Text("这是我自己的声音。只在我说话时用它替我翻译。").font(.system(size: 12)).foregroundStyle(Palette.secondary)
            }
            .toggleStyle(.checkbox)
            .disabled(recorder.phase == .recording)
            HStack {
                SoftButton(L("取消")) { recorder.cancel(); onDone(false) }
                Spacer()
                switch recorder.phase {
                case .recording:
                    SoftButton(L("读完了"), dark: true) { recorder.finish() }
                        .disabled(recorder.seconds < VoiceRecorder.minSeconds)
                case .checking:
                    HStack(spacing: 8) { Spinner(size: 14); Text("正在听写…").font(.system(size: 12)).foregroundStyle(Palette.secondary) }
                default:
                    SoftButton(recorder.phase == .idle ? L("开始录") : L("再录一次"), dark: true) {
                        recorder.start(locale: ownLocale, device: model.systemMic.recordingDevice)
                    }
                    .disabled(!consent)
                }
            }
        }
    }

    @ViewBuilder
    private var meter: some View {
        switch recorder.phase {
        case .recording:
            HStack(spacing: 14) {
                LiveDot()
                Text(NotesEngine.clock(recorder.seconds)).font(.system(size: 14, weight: .semibold).monospacedDigit())
                LevelBars(level: recorder.level)
                Text("\(Int(VoiceRecorder.minSeconds))–\(Int(VoiceRecorder.maxSeconds)) 秒").font(.system(size: 12)).foregroundStyle(Palette.tertiary)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Palette.accentWash))
        case .failed(let why):
            Text(why).font(.system(size: 12)).foregroundStyle(Palette.error)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Palette.errorPale))
        default:
            EmptyView()
        }
    }

    // MARK: Review

    private var review: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("录好了，先听听像不像").font(.system(size: 18, weight: .bold))
                Text("\(Int(recorder.seconds.rounded())) 秒 · 识别出的文字会与录音一起用于学习你的音色")
                    .font(.system(size: 13)).foregroundStyle(Palette.secondary)
            }
            VStack(spacing: 0) {
                row(icon: playing ? "stop.fill" : "play.fill", accent: false, title: L("你的原声"), detail: recorder.transcript) {
                    togglePlayOriginal()
                }
                Divider()
                row(icon: clonePlaying ? nil : "play.fill", accent: true,
                    title: L("用你的声音说\(targetTitle)"), detail: VoiceCatalog.sample(for: language), tag: L("对方会听到这个")) {
                    playClone()
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.line, lineWidth: 1))
            if !model.ling.speechCapable {
                Text("需先在“AI 服务”中填入 Ling key，才能使用你自己的声音。").font(.system(size: 12)).foregroundStyle(Palette.error)
            }
            Text("听起来不像或有杂音？换个安静的地方重录一次。录音仅保存在本机，可随时删除。")
                .font(.system(size: 12)).foregroundStyle(Palette.tertiary)
            HStack {
                SoftButton(L("重录")) { player?.stop(); recorder.start(locale: ownLocale, device: model.systemMic.recordingDevice) }
                Spacer()
                SoftButton(L("用这个声音"), dark: true) { save() }
            }
        }
    }

    private var targetTitle: String {
        VoiceCatalog.languages.first { $0.key == VoiceCatalog.key(for: language) }?.title ?? targetName(language)
    }

    private var playing: Bool { player?.isPlaying ?? false }

    private func row(icon: String?, accent: Bool, title: String, detail: String, tag: String? = nil,
                     action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Button(action: action) {
                ZStack {
                    Circle().fill(accent ? Palette.accent : Palette.fill)
                    if let icon {
                        Image(systemName: icon).font(.system(size: 10)).foregroundStyle(accent ? Color.white : Palette.ink)
                    } else {
                        Spinner(size: 12, track: Color.white.opacity(0.4))
                    }
                }
                .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .disabled(icon == nil)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(Palette.tertiary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if let tag { Tag(tag, live: true) }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(accent ? Palette.accentWash : Color.clear)
    }

    private func togglePlayOriginal() {
        if let p = player, p.isPlaying { p.stop(); player = nil; return }
        player = try? AVAudioPlayer(contentsOf: recorder.url)
        player?.play()
    }

    private func playClone() {
        guard model.ling.speechCapable, let data = try? Data(contentsOf: recorder.url) else { return }
        clonePlaying = true
        let ref = (audio: "data:audio/wav;base64," + data.base64EncodedString(), text: recorder.transcript)
        let lang = VoiceCatalog.mingLanguage(for: language)
        let ling = model.ling
        Task {
            await model.speak.speak(VoiceCatalog.sample(for: language), language: language, device: AudioDevices.defaultOutput,
                                    route: .stream { text in ling.speech(text, voice: nil, reference: ref, language: lang) })
            clonePlaying = false
        }
    }

    private func save() {
        do {
            try VoiceReference.save(wav: recorder.url, text: recorder.transcript)
            debugLog("voice clone saved \(Int(recorder.seconds)) s")
            onDone(true)
        } catch {
            debugLog("voice clone save failed: \(error.localizedDescription)")
        }
    }
}

/// A row of bars following the microphone level.
private struct LevelBars: View {
    let level: Float
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<14, id: \.self) { i in
                    let wobble = 0.55 + 0.45 * sin(t * 9 + Double(i) * 1.3)
                    Capsule().fill(Palette.accent)
                        .frame(width: 4, height: max(4, 28 * CGFloat(level) * CGFloat(wobble)))
                }
            }
            .frame(height: 28)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

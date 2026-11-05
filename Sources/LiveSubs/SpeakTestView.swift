import AppKit
import SwiftUI

/// Settings › 同声传译 › 试一句: run one sentence through the real chain, play back what the room
/// received, show where it broke and how long each stage took.
struct SpeakTestView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var tester: SpeakTester
    let close: () -> Void
    @State private var holding = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            switch tester.phase {
            case .idle: intro
            case .done: if let r = tester.result { resultView(r) }
            default: progress
            }
            footer
        }
        .padding(24)
        .frame(width: 560, alignment: .leading)
        .foregroundStyle(Palette.ink)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            if let r = tester.result, tester.phase == .done {
                Circle().fill(r.passed ? Palette.ok : Palette.accent).frame(width: 10, height: 10).padding(.top, 8)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 18, weight: .bold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(Palette.secondary)
            }
        }
    }

    private var title: String {
        guard tester.phase == .done, let r = tester.result else { return L("试一句") }
        if r.passed { return L("对方听得到，也听得懂") }
        if r.broken == .room { return L("对方听不到") }
        if r.broken != nil { return L("这句话没送出去") }
        return L("对方听得到，但可能听不清")
    }

    private var subtitle: String {
        if tester.phase == .done, let r = tester.result {
            return r.problem ?? L("下面是对方那边收到的原样声音")
        }
        return L("走一遍真实流程，录下对方会听到的声音，再放给你听")
    }

    // MARK: Before

    private var intro: some View {
        VStack(alignment: .leading, spacing: 12) {
            Segments(options: [("voice", L("我说一句")), ("sample", L("用示例句子"))], value: tester.mode.rawValue) {
                tester.mode = SpeakTester.Mode(rawValue: $0) ?? .voice
            }
            Text(tester.mode == .voice ? (!talkKeyWorks ? L("点开始后按住按钮，说一句话再松开")
                 : model.settings.talkKey.isRightOption ? L("点开始后按住按钮或右侧 ⌥，说一句话再松开")
                 : L("点开始后按住按钮或说话快捷键，说一句话再松开"))
                 : L("用本机声音读一句\(model.settings.speakFromLang.name)：「\(SpeakTester.sampleSentence(for: model.settings.speakFromLang.code))」"))
                .font(.system(size: 12)).foregroundStyle(Palette.tertiary).fixedSize(horizontal: false, vertical: true)
            Text("试音会真的送进虚拟麦克风：开会时对方也会听到。")
                .font(.system(size: 12)).foregroundStyle(Palette.tertiary)
        }
    }

    // MARK: Running

    private var progress: some View {
        VStack(alignment: .leading, spacing: 12) {
            if tester.phase == .ready || tester.phase == .talking { talkButton }
            stageList(result: nil)
        }
    }

    private var talkButton: some View {
        let talking = tester.phase == .talking
        return HStack(spacing: 12) {
            HStack(spacing: 8) {
                if talking { LiveDot() } else { Image(systemName: "mic.fill").font(.system(size: 13)) }
                Text(talking ? L("松开就发送") : L("按住说话")).font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(talking ? Palette.accentInk : Color.white)
            .padding(.horizontal, 18).frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 10).fill(talking ? Palette.accentPale : Palette.ink))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !holding { holding = true; tester.beginTalking() } }
                .onEnded { _ in holding = false; tester.endTalking() })
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(L("按住说话"))
            if talkKeyWorks {
                Text(model.settings.talkKey.isRightOption ? L("或按住右侧 ⌥") : L("或按住说话快捷键"))
                    .font(.system(size: 12)).foregroundStyle(Palette.tertiary)
            }
        }
    }

    private struct StageRow: Identifiable {
        let id: SpeakTestResult.Stage
        let name: String
        let detail: String
        let time: Double?
        let state: Int // 0 waiting, 1 running, 2 done, 3 broken
        var playable: URL?
    }

    private func stages(_ r: SpeakTestResult?) -> [StageRow] {
        let reached = tester.reached
        let running = tester.phase != .done
        func state(_ s: SpeakTestResult.Stage) -> Int {
            if let r {
                if r.broken == s { return 3 }
                if let b = r.broken, b.rawValue < s.rawValue { return 0 }
                return 2
            }
            guard tester.phase == .working || tester.phase == .scoring else { return s == .mic && tester.phase == .talking ? 1 : 0 }
            let at = reached?.rawValue ?? -1
            if s.rawValue <= at { return 2 }
            return s.rawValue == at + 1 && running ? 1 : 0
        }
        let ming = r?.via == "ming"
        return [
            StageRow(id: .mic, name: L("你的话"),
                     detail: r.map { $0.sample ? L("示例句子") : $0.micPeakDB.map { L("麦克风峰值 \(Int($0)) dB") } ?? "" } ?? "",
                     time: nil, state: state(.mic), playable: r?.micURL),
            StageRow(id: .recognize, name: ming ? L("识别 + 翻译") : L("识别"),
                     detail: r.map { $0.source } ?? L("本机转写定稿"), time: r?.recognize, state: state(.recognize)),
            StageRow(id: .translate, name: L("翻译"),
                     detail: r.map { $0.translation ?? L("没有译文") } ?? "", time: ming ? nil : r?.translate, state: state(.translate)),
            StageRow(id: .voice, name: L("合成声音"), detail: r.map { voiceName($0) } ?? "", time: r?.synth, state: state(.voice)),
            StageRow(id: .room, name: L("虚拟麦克风"),
                     detail: r.map { $0.broken == .room ? L("只录到静音") : L("录到 \(String(format: "%.1f", $0.heardSeconds)) 秒声音") }
                        ?? (tester.phase == .scoring ? L("正在重新听写对方收到的声音…") : L("同时录下对方那一侧")),
                     time: r?.arrive.map { max(0, $0) }, state: tester.phase == .scoring && r == nil ? 1 : state(.room), playable: r?.heardURL),
        ]
    }

    private func voiceName(_ r: SpeakTestResult) -> String {
        // "ming" / "zenmux", or "system (zenmux failed)" when the stream fell back to the Mac's voice.
        let who = r.voice.contains("(") ? String(r.voice.drop { $0 != "(" }.dropFirst().prefix { $0 != " " }) : r.voice
        let cloud = who == "ming" ? "Ming" : AIProvider.named(who).name
        let v = r.voice.contains("failed") ? L("本机（\(cloud) 失败）") : r.voice.hasPrefix("system") ? L("本机声音") : cloud
        return "\(v) → \(r.outputName)"
    }

    private func stageList(result r: SpeakTestResult?) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(stages(r).enumerated()), id: \.element.id) { i, s in
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(s.state == 3 ? Palette.accent : s.state == 2 ? Palette.ink : s.state == 1 ? Palette.accentPale : Palette.fill)
                        switch s.state {
                        case 3: Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        case 2: Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        case 1: ProgressView().controlSize(.mini)
                        default: Text("\(i + 1)").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.tertiary)
                        }
                    }
                    .frame(width: 20, height: 20)
                    Text(s.name).font(.system(size: 13, weight: s.state == 0 ? .regular : .semibold))
                        .foregroundStyle(s.state == 3 ? Palette.accentInk : s.state == 0 ? Palette.tertiary : Palette.ink)
                        .lineLimit(1).fixedSize().frame(minWidth: 92, alignment: .leading)
                    Text(s.detail).font(.system(size: 12)).foregroundStyle(s.state == 3 ? Palette.accentInk : Palette.secondary)
                        .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                    if let url = s.playable, s.id == .mic {
                        Button(tester.playing == url ? L("停") : L("听")) { tester.play(url) }
                            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    }
                    if let t = s.time {
                        Text(seconds(t)).font(.system(size: 12, weight: .semibold).monospacedDigit())
                    }
                }
                .padding(.vertical, 9)
                if i < 4 { Divider() }
            }
        }
        .padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line, lineWidth: 1))
    }

    // MARK: Result

    @ViewBuilder
    private func resultView(_ r: SpeakTestResult) -> some View {
        if r.broken == nil {
            VStack(alignment: .leading, spacing: 12) {
                heardCard(r)
                checks(r)
                latency(r)
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                stageList(result: r)
                fix(r)
            }
        }
    }

    private func heardCard(_ r: SpeakTestResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button { tester.play(r.heardURL) } label: {
                    ZStack {
                        Circle().fill(Palette.accent)
                        Image(systemName: tester.playing == r.heardURL ? "stop.fill" : "play.fill")
                            .font(.system(size: 13)).foregroundStyle(.white)
                    }
                    .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("播放对方听到的声音"))
                VStack(alignment: .leading, spacing: 2) {
                    Text("听对方听到的").font(.system(size: 13, weight: .semibold))
                    Text("从虚拟麦克风录下的原样声音 · \(String(format: "%.1f", r.heardSeconds)) 秒")
                        .font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                }
                Spacer()
                if let url = r.micURL {
                    Button(tester.playing == url ? L("停") : L("听我的原声")) { tester.play(url) }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }
            }
            HStack(alignment: .center, spacing: 2) {
                ForEach(Array(r.bars.enumerated()), id: \.offset) { _, v in
                    Capsule().fill(Palette.accent.opacity(0.75)).frame(maxWidth: .infinity).frame(height: max(3, 30 * CGFloat(v)))
                }
            }
            .frame(height: 30)
            .accessibilityHidden(true)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                textRow(L("你说"), r.source)
                textRow(L("送出的译文"), r.translation ?? "")
                textRow(L("对方那边听写"), r.heard.isEmpty ? L("（没听写出来）") : r.heard)
                if case .back(let back) = r.meaning { textRow(L("再译回来"), back) }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line, lineWidth: 1))
    }

    private func textRow(_ label: String, _ text: String) -> some View {
        GridRow {
            Text(label).font(.system(size: 12)).foregroundStyle(Palette.secondary).gridColumnAlignment(.leading)
            Text(text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }

    private func checks(_ r: SpeakTestResult) -> some View {
        HStack(spacing: 8) {
            tile(L("有声"), r.clipped > 200 ? L("有削波") : L("音量正常"), ok: r.clipped <= 200,
                 detail: "\(Int(r.heardPeakDB.rounded())) dB")
            tile(L("听得清"), r.intelligibility.map { L("\(Int(($0 * 100).rounded()))% 词对上") } ?? L("未检查"),
                 ok: (r.intelligibility ?? 1) >= 0.6, detail: L("本机重新听写"))
            switch r.meaning {
            case .score(let s, _): tile(L("意思对"), s >= 60 ? L("一致 \(s)") : L("走样 \(s)"), ok: s >= 60, detail: L("Ling 比对原话"))
            case .back: tile(L("意思对"), L("请看上面"), ok: true, detail: L("已译回你的语言"))
            case .unchecked: tile(L("意思对"), L("未检查"), ok: true, detail: L("需要 Ling key"))
            }
        }
    }

    private func tile(_ title: String, _ value: String, ok: Bool, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11)).foregroundStyle(Palette.secondary)
            HStack(spacing: 4) {
                Image(systemName: ok ? "checkmark" : "exclamationmark.triangle.fill").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(ok ? Palette.ok : Palette.accent)
                Text(value).font(.system(size: 14, weight: .bold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            Text(detail).font(.system(size: 11)).foregroundStyle(Palette.tertiary).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line, lineWidth: 1))
    }

    private func latency(_ r: SpeakTestResult) -> some View {
        let ming = r.via == "ming"
        let parts: [(String, Double, Color)] = [
            (ming ? L("识别 + 翻译") : L("识别"), r.recognize ?? 0, Palette.ink),
            (L("翻译"), ming ? 0 : r.translate ?? 0, Palette.secondary),
            (L("合成首音"), r.synth ?? 0, Palette.accent),
            (L("到达虚拟麦克风"), max(0, r.arrive ?? 0), Palette.placeholder),
        ].filter { $0.1 > 0.005 }
        let total = max(0.01, parts.reduce(0) { $0 + $1.1 })
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("松开后").font(.system(size: 13, weight: .semibold))
                Text(r.firstHeard.map(seconds) ?? "-").font(.system(size: 22, weight: .bold).monospacedDigit())
                Text("对方听到第一个字").font(.system(size: 13)).foregroundStyle(Palette.secondary)
            }
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(parts, id: \.0) { p in
                        Rectangle().fill(p.2).frame(width: max(2, (geo.size.width - 6) * p.1 / total))
                    }
                }
            }
            .frame(height: 10).clipShape(Capsule())
            HStack(spacing: 14) {
                ForEach(parts, id: \.0) { p in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(p.2).frame(width: 8, height: 8)
                        Text("\(p.0) \(seconds(p.1))").font(.system(size: 11).monospacedDigit()).foregroundStyle(Palette.secondary)
                    }
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line, lineWidth: 1))
    }

    @ViewBuilder
    private func fix(_ r: SpeakTestResult) -> some View {
        if r.broken == .room {
            HStack(spacing: 10) {
                if !r.outputIsVirtualMic {
                    SoftButton(L("改回虚拟麦克风并重试"), dark: true) {
                        model.settings.speakOutput = ""
                        model.speak.resetOutput()
                        tester.start(tester.mode)
                    }
                } else if AudioDevices.virtualMic != nil {
                    SoftButton(L("让系统认出它"), dark: true) { model.installer.reload() }
                }
                // Tells "the voice itself is broken" from "it never reached the room".
                if let text = r.translation, let id = model.voiceID(for: r.to) {
                    SoftButton(model.previewing == id ? L("正在播放…") : L("在扬声器上听译文")) {
                        model.previewVoice(id, language: r.to, text: text)
                    }
                    .disabled(model.previewing != nil)
                }
            }
        } else if r.broken == .voice {
            SoftButton(L("换个声音"), dark: true) {
                model.voicePickerOpen = true
                close()
            }
        } else if r.broken == .translate && !model.ling.usable {
            Text("没有 Ling key 时用 Google 翻译，需要能访问 Google。").font(.system(size: 12)).foregroundStyle(Palette.tertiary)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            switch tester.phase {
            case .idle:
                SoftButton(L("取消")) { close() }
                Spacer()
                SoftButton(L("开始"), dark: true) { tester.start(tester.mode) }
            case .done:
                SoftButton(L("再试一句")) { tester.start(tester.mode) }
                Button(copied ? L("已复制") : L("复制报告")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tester.result?.report ?? "", forType: .string)
                    copied = true
                }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                Spacer()
                SoftButton(L("完成"), dark: true) { close() }
            default:
                Spacer()
                SoftButton(L("取消")) { tester.cancel(); close() }
            }
        }
    }

    /// The talk key only listens while speak-back is on (and, for the right ⌥, with Input Monitoring).
    private var talkKeyWorks: Bool { model.settings.speakEnabled && !model.talkNeedsPermission }

    private func seconds(_ v: Double) -> String { L("\(String(format: "%.1f", v)) 秒") }
}

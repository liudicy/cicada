import AppKit
import SwiftUI

enum Palette {
    static let ink = Color(red: 0.08, green: 0.09, blue: 0.11)
    static let ground = Color(red: 0.953, green: 0.957, blue: 0.965)
    static let line = Color(red: 0.894, green: 0.902, blue: 0.918)
    static let secondary = Color(red: 0.353, green: 0.373, blue: 0.42)
    static let tertiary = Color(red: 0.42, green: 0.44, blue: 0.50)
    /// Body text in the records window: darker than the greys, lighter than headings.
    static let body = Color(red: 0.239, green: 0.255, blue: 0.29)
    /// Times you can click to jump to the original, and the numbers that order notes: the logo's
    /// orange as ink, so text stays in the brand's family while the bright accent stays "live".
    static let link = Color(red: 0.70, green: 0.23, blue: 0.08)
    /// Highlighter behind numbers and dates in the conclusions.
    static let mark = Color(red: 1.0, green: 0.906, blue: 0.639)
    static let accent = Color(red: 0.91, green: 0.33, blue: 0.17)
    static let accentInk = Color(red: 0.70, green: 0.23, blue: 0.08)
    static let accentPale = Color(red: 0.99, green: 0.93, blue: 0.906)
    /// Controls, chips, search fields.
    static let fill = Color(red: 0.949, green: 0.953, blue: 0.961)
    /// Emphasis blocks (summary, setting cards).
    static let raised = Color(red: 0.961, green: 0.965, blue: 0.973)
    /// Current row while something is live.
    static let accentWash = Color(red: 1.0, green: 0.98, blue: 0.973)
    static let ok = Color(red: 0.122, green: 0.478, blue: 0.271)
    static let okPale = Color(red: 0.906, green: 0.961, blue: 0.925)
    static let error = Color(red: 0.706, green: 0.137, blue: 0.094)
    static let errorPale = Color(red: 0.992, green: 0.925, blue: 0.918)
    /// Headings over placeholder shapes while notes are being written.
    static let placeholder = Color(red: 0.722, green: 0.741, blue: 0.776)
}

struct LogoTile: View {
    var size: CGFloat = 34
    var body: some View { BrandMark(size: size) }
}

typealias ChoiceOption = (id: String, title: String)

/// A gray rounded row that opens a menu, used for the language choices.
struct ChoiceRow: View {
    let label: String
    let value: String
    var badge: String? = nil
    /// Groups the menu separates; a header is its grey section title.
    let sections: [(header: String?, options: [ChoiceOption])]
    let onPick: (String) -> Void

    init(label: String, value: String, badge: String? = nil,
         sections: [(header: String?, options: [ChoiceOption])], onPick: @escaping (String) -> Void) {
        self.label = label; self.value = value; self.badge = badge
        self.sections = sections.filter { !$0.options.isEmpty }
        self.onPick = onPick
    }

    init(label: String, value: String, badge: String? = nil,
         options: [ChoiceOption], onPick: @escaping (String) -> Void) {
        self.init(label: label, value: value, badge: badge, sections: [(nil, options)], onPick: onPick)
    }

    var body: some View {
        Menu {
            // Sections, not Dividers: the menu draws the separators itself, and a Divider next to
            // a headed Section would draw a second one.
            ForEach(sections.indices, id: \.self) { i in
                if let header = sections[i].header {
                    Section(header) { buttons(sections[i].options) }
                } else {
                    Section { buttons(sections[i].options) }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Text(label).font(.system(size: 12)).foregroundStyle(Palette.secondary).frame(width: uiIsChinese ? 44 : 72, alignment: .leading)
                Text(value).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                if let badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1).fixedSize()
                        .foregroundStyle(Palette.accentInk)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Palette.accentPale))
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.tertiary)
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 11).fill(Palette.ground))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    private func buttons(_ options: [ChoiceOption]) -> some View {
        ForEach(options, id: \.id) { o in
            Button(o.title) { onPick(o.id) }
        }
    }
}

// MARK: - Menu bar panel

struct MenuPanelView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings

    /// Languages without a speech model on this Mac sit in their own group under one line saying
    /// picking one downloads it, rather than a suffix on every row.
    private var sourceSections: [(header: String?, options: [ChoiceOption])] {
        let auto = model.candidates.map(\.name).joined(separator: "、")
        let ready = sourceLanguages.filter { model.installed.isEmpty || model.installed.contains($0.locale) }
        let missing = sourceLanguages.filter { !ready.contains($0) }
        return [
            (nil, [("auto", auto.isEmpty ? L("自动识别") : L("自动识别（\(auto)）"))]),
            (nil, ready.map { ($0.locale, $0.name) }),
            (L("选中后自动下载语音模型"), missing.map { ($0.locale, $0.name) }),
        ]
    }

    private var targetOptions: [(id: String, title: String)] {
        [("system", L("跟随系统（\(settings.systemTargetDescription())）"))] + targetLanguages.map { ($0.code, $0.name) }
    }

    private var heardValue: (String, String?) {
        switch settings.sourceMode {
        case .fixed(let l): return (l.name, nil)
        case .auto: return (model.listen.activeLang?.name ?? L("自动"), L("自动识别"))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                LogoTile(size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(appDisplayName).font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.ink)
                        if let dev = DevBuild.label {
                            Text("DEV").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Palette.ink))
                                .help(dev)
                        }
                    }
                    if let dev = DevBuild.label {
                        Text(dev).font(.system(size: 10).monospaced()).foregroundStyle(Palette.tertiary).lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        Circle().fill(model.running ? Palette.accent : Color.gray.opacity(0.5)).frame(width: 7, height: 7)
                        // Two lines: "English (detecting…) → 简体中文" doesn't fit one beside the switch.
                        Text(model.running ? model.summary : model.autoEnded ? L("会议已自动结束") : L("已暂停"))
                            .font(.system(size: 12)).foregroundStyle(Palette.secondary).lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                Toggle("字幕", isOn: Binding(get: { model.running }, set: { model.setRunning($0) }))
                    .toggleStyle(.switch).labelsHidden().tint(Palette.ink)
            }

            if let p = model.ending { MeetingEndingStrip(model: model, pending: p, compact: true) }

            VStack(spacing: 8) {
                ChoiceRow(label: L("声源"),
                          value: settings.listenSource == "mic" ? L("麦克风") : L("系统音频"),
                          badge: settings.listenSource == "mic" ? L("现场") : nil,
                          options: [("system", L("系统音频（线上会议）")), ("mic", L("麦克风（现场会议）"))]) {
                    model.setListenSource($0)
                }
                ChoiceRow(label: L("听到"), value: heardValue.0, badge: heardValue.1, sections: sourceSections) {
                    model.sourceSelection = $0
                }
                ChoiceRow(label: L("翻译成"),
                          value: targetName(model.listen.resolvedTarget),
                          // "Follow system" leaves no room for the language name in the panel.
                          badge: settings.target == "system" ? (uiIsChinese ? L("跟随系统") : L("系统")) : nil,
                          options: targetOptions) {
                    model.targetSelection = $0
                }
                ChoiceRow(label: L("内容"), value: subtitleOptions.first { $0.id == model.subtitles }?.title ?? L("原文 + 译文"),
                          badge: model.meetingSubtitles != nil ? L("仅本场") : nil, options: subtitleOptions) {
                    model.setSubtitles($0)
                }
            }

            Divider()

            speakSection
            if let strip = systemMicStrip {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(strip.title).font(.system(size: 12)).foregroundStyle(Palette.accentInk)
                        Text(strip.detail).font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    }
                    Spacer()
                    SoftButton(strip.button, dark: true, action: strip.action)
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9).fill(Palette.accentPale))
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("显示方式").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.ink)
                    Spacer()
                    HStack(spacing: 5) {
                        KeyCap(settings.toggleKey.display)
                        Text("轮换").foregroundStyle(Palette.tertiary)
                    }
                    .font(.system(size: 11))
                    .help(L("切换显示方式"))
                }
                HStack(spacing: 8) {
                    ForEach(DisplayTile.modes, id: \.self) { mode in
                        DisplayTile(mode: mode, selected: settings.displayMode == mode) { model.setDisplayMode(mode) }
                    }
                }
                displayCard
            }

            UpdateBanner(updates: model.updates, model: model)

            Divider()

            HStack {
                Button("会议记录") { model.openMainWindow?() }
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
            }
            .buttonStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(Palette.secondary)
        }
        .padding(18)
        .frame(width: 320)
        .background(Color.white)
    }
}

extension MenuPanelView {
    /// The settings of the chosen display mode only, so switching modes swaps one card
    /// instead of reshuffling the section.
    @ViewBuilder var displayCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch settings.displayMode {
            case "bar":
                cardRow(L("什么时候出现")) {
                    overlayAutoSegments(model: model, fill: uiIsChinese, track: Palette.line).frame(width: uiIsChinese ? segmentWidth : nil)
                }
                if settings.overlayAuto {
                    cardRow(L("安静多久后收起")) {
                        hideAfterSegments(settings: settings, fill: uiIsChinese, track: Palette.line).frame(width: uiIsChinese ? segmentWidth : nil)
                    }
                }
            case "none":
                Text("屏幕上不出字幕，文字记录照常保存")
                    .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            default:
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.notesShown ? L("纪要窗口已打开") : L("纪要窗口已收起"))
                            .font(.system(size: 12)).foregroundStyle(Palette.ink)
                        if !model.ling.hasKey {
                            Text("填入 API key 后可生成纪要；文字记录照常保存")
                                .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 4)
                    SoftButton(model.notesShown ? L("收起") : L("打开"), dark: !model.notesShown, onGrey: true) {
                        model.notesShown ? model.hideNotesWindow() : model.openNotesWindow()
                    }
                }
                Divider()
                // Tinted while on: sharing the screen shows the notes too.
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("共享屏幕时让对方看到").font(.system(size: 12)).foregroundStyle(Palette.ink)
                        if settings.notesCapturable {
                            Text("对方现在能看到纪要窗口").font(.system(size: 11)).foregroundStyle(Palette.accentInk)
                        }
                    }
                    Spacer(minLength: 4)
                    Toggle("共享屏幕时让对方看到", isOn: Binding(get: { settings.notesCapturable }, set: { model.setNotesCapturable($0) }))
                        .toggleStyle(.switch).controlSize(.mini).labelsHidden().tint(Palette.accent)
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 8).fill(settings.notesCapturable ? Palette.accentPale : .clear))
                .padding(.horizontal, -6)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11).fill(Palette.ground))
    }

    /// Both 字幕条 choices share one width so their right edges line up; English sizes to fit and may stack.
    private var segmentWidth: CGFloat { 160 }

    /// A label and its control on one line, or stacked when the English runs too wide.
    private func cardRow<C: View>(_ title: String, @ViewBuilder control: () -> C) -> some View {
        let label = Text(title).font(.system(size: 12)).foregroundStyle(Palette.ink)
        let c = control()
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) { label; Spacer(minLength: 8); c }
            VStack(alignment: .leading, spacing: 6) { label; c }
        }
    }

    var systemMicStrip: (title: String, detail: String, button: String, action: () -> Void)? {
        let virtual = model.virtualMic?.name ?? "BlackHole 2ch"
        switch model.systemMicState {
        case .notRestored:
            return (L("系统麦克风还是 \(virtual)"), L("别的软件现在听不到你说话"), L("还原"), model.restoreSystemMic)
        case .moved(let to):
            return (L("系统麦克风被换成了 \(to)"), L("跟随系统的网页听不到译文"), L("换回"), model.switchSystemMic)
        default:
            return nil
        }
    }
}

// MARK: - 同声传译 in the panel

extension MenuPanelView {
    private var speakFrom: String { settings.speakFromLang.name }
    private var speakTarget: String { targetName(model.speak.targetCode) }
    private var talkKeyName: String { settings.talkKey.display }

    /// What the switch changes, on hover and in the one-time question.
    private var speakMicLine: String {
        guard let mic = model.virtualMic?.name else { return L("先装好虚拟麦克风，对方才听得到") }
        return settings.autoSystemMic ? L("系统麦克风换成 \(mic)") : L("译文送进 \(mic)")
    }

    private var speakHelp: String {
        L("打开：\(speakMicLine)，按住 \(talkKeyName) 说话\n关掉：全部还原")
    }

    /// 同声传译: the first time the switch asks in place what it changes; once on, the talk key is
    /// the section, and whatever stops the room hearing you shows on it.
    var speakSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("同声传译").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.ink)
                    if !settings.speakEnabled && !model.speakAsking {
                        Text("说\(speakFrom) → \(speakTarget)").font(.system(size: 12))
                            .foregroundStyle(Palette.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if settings.speakEnabled {
                    Button("设置") { model.openSettings(.speak) }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.tertiary)
                }
                Toggle("同声传译", isOn: Binding(get: { settings.speakEnabled || model.speakAsking }, set: setSpeaking))
                    .toggleStyle(.switch).labelsHidden()
                    .tint(model.speakAsking ? Palette.tertiary : Palette.ink)
                    .help(speakHelp)
            }
            if model.speakAsking {
                speakQuestion
            } else if settings.speakEnabled {
                talkCard
                if model.lastSpeakLatency == nil, model.virtualMic != nil, model.speakPhase == .idle {
                    Button("先试一句 →") { model.openSettings(.speak); model.speakTestShown = true }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }
            }
        }
    }

    private func setSpeaking(_ on: Bool) {
        if on && !settings.speakConfirmed { model.speakAsking = true; return }
        model.speakAsking = false
        if on != settings.speakEnabled { model.enableSpeaking(on) }
    }

    /// Asked once: switching the system mic is a change people should hear about before it happens.
    private var speakQuestion: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("打开后：").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
            questionLine(1) { Text(speakMicLine) }
            questionLine(2) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) { Text("按住"); KeyCap(talkKeyName); Text("说话，松开后播出译文") }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) { Text("按住"); KeyCap(talkKeyName) }
                        Text("说话，松开后播出译文")
                    }
                }
            }
            questionLine(3) { Text("关掉后全部还原") }
            HStack(spacing: 8) {
                Spacer()
                SoftButton(L("取消"), onGrey: true) { model.speakAsking = false }
                SoftButton(L("好，打开"), dark: true) { model.speakAsking = false; model.enableSpeaking(true) }
            }
            .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11).fill(Palette.ground))
    }

    private func questionLine<C: View>(_ n: Int, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").foregroundStyle(Palette.tertiary).frame(width: 12, alignment: .leading)
            content().foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
    }

    /// The first thing keeping the room from hearing you, with the one action that fixes it.
    private var talkProblem: (text: String, button: String, action: () -> Void)? {
        if model.talkNeedsPermission {
            return (L("按键还需要“输入监控”权限"), L("去允许"), model.allowTalkKey)
        }
        if model.virtualMic == nil {
            return (L("虚拟麦克风还没装好"), L("设置"), { model.openSettings(.speak) })
        }
        if let user = model.micUsers.first(where: { $0.state.isOther }) {
            let text: String
            if case .otherMic(let mic) = user.state, !mic.isEmpty { text = L("\(user.name)还在用 \(mic)") }
            else { text = L("\(user.name)没选虚拟麦克风") }
            return (text, L("怎么改"), { model.showMicGuide(user) })
        }
        return nil
    }

    private var talkCard: some View {
        let phase = model.speakPhase
        let live = phase != .idle
        let problem = live ? nil : talkProblem
        let title: String = switch phase {
        case .idle: L("按住说\(speakFrom)")
        case .listening: L("正在听…")
        case .translating: L("正在翻译…")
        case .speaking: L("正在播出…")
        }
        let hearer = model.micUsers.first { $0.state == .virtualMic }?.name
        let detail = phase == .listening ? L("松开后播出\(speakTarget)")
            : live ? L("说\(speakFrom) → \(speakTarget)")
            : hearer.map { L("对方听到 \(speakTarget) · \($0)") } ?? L("对方听到 \(speakTarget)")
        return HStack(spacing: 12) {
            TalkKeyCap(text: talkKeyName, pressed: phase == .listening, live: live)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(live ? Palette.accentInk : Palette.ink).lineLimit(1)
                if let problem {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(problem.text).foregroundStyle(Palette.accentInk)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(problem.button, action: problem.action)
                            .buttonStyle(.plain).fontWeight(.semibold).foregroundStyle(Palette.accentInk).fixedSize()
                    }
                    .font(.system(size: 11))
                } else {
                    Text(detail).font(.system(size: 11)).foregroundStyle(Palette.secondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            if !live {
                Circle().fill(problem == nil ? Palette.ok : Palette.accent).frame(width: 7, height: 7)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11).fill(live ? Palette.accentWash : Color.white))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(live ? Palette.accent : Palette.line, lineWidth: 1))
        .animation(.easeOut(duration: 0.15), value: live)
    }
}

/// The talk key drawn as a key: raised while it waits, pressed down while you hold it.
struct TalkKeyCap: View {
    let text: String
    let pressed: Bool
    let live: Bool
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(live ? Palette.accentInk : Palette.ink)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 8)
            .frame(minWidth: 44, minHeight: 32)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(live ? Palette.accent : Color(white: 0.82), lineWidth: 1))
            .background(RoundedRectangle(cornerRadius: 7).fill(live ? Palette.accent : Color(white: 0.82)).offset(y: pressed ? 0 : 2))
            .offset(y: pressed ? 2 : 0)
            .padding(.bottom, 2)
    }
}

/// One of 实时纪要 / 字幕条 / 不显示 in the menu bar panel: a small picture of what shows on screen.
struct DisplayTile: View {
    static let modes = ["notes", "bar", "none"]
    let mode: String
    let selected: Bool
    let action: () -> Void

    private var title: String {
        switch mode {
        case "bar": return L("字幕条")
        case "none": return L("不显示")
        default: return L("实时纪要")
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                glyph.frame(height: 26).opacity(selected ? 1 : 0.7)
                Text(title)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Palette.ink : Palette.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .padding(.top, 10).padding(.bottom, 8).padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 11).fill(selected ? Color.white : Palette.ground))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(selected ? Palette.ink : .clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private let frameLine = Color(red: 0.79, green: 0.80, blue: 0.83)

    @ViewBuilder private var glyph: some View {
        switch mode {
        case "bar":
            RoundedRectangle(cornerRadius: 4).fill(Color.white)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(frameLine, lineWidth: 1))
                .overlay(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 2).fill(Palette.ink).frame(width: 26, height: 6).padding(.bottom, 3)
                }
                .frame(width: 38, height: 26)
        case "none":
            RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.tertiary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                .frame(width: 38, height: 26)
        default:
            VStack(alignment: .leading, spacing: 3) {
                Capsule().fill(Palette.ink).frame(width: 18, height: 3)
                Capsule().fill(frameLine).frame(width: 24, height: 3)
                Capsule().fill(frameLine).frame(width: 20, height: 3)
            }
            .padding(5)
            .frame(width: 34, height: 26, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(frameLine, lineWidth: 1))
        }
    }
}

struct KeyCap: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(white: 0.82), lineWidth: 1))
    }
}

// MARK: - Main window

struct MainWindowView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: SessionStore
    @ObservedObject var settings: AppSettings
    @State private var selection: String?
    @State private var query = ""
    @State private var view = "both"
    @State private var titleDraft = ""
    @State private var tab = "notes"
    @State private var jumpTo: Double?
    /// A topic's time picked in the notes, for the bilingual column beside them.
    @State private var quoteJump: Double?
    @State private var detailWidth: CGFloat = 0
    @FocusState private var searchFocused: Bool
    /// The bilingual column beside the notes is opt-in: three full columns of text read as crowded.
    @AppStorage("mainShowQuotes") private var showQuotes = false
    @State private var showOlder = false

    /// Wide enough for the notes and the bilingual transcript side by side.
    private var sideBySide: Bool { showQuotes && wideEnough }
    private var wideEnough: Bool { detailWidth >= 940 }

    private var filtered: [Session] {
        guard !query.isEmpty else { return store.sessions }
        return store.sessions.filter { s in
            s.displayTitle.localizedCaseInsensitiveContains(query)
                || s.lines.contains { $0.src.localizedCaseInsensitiveContains(query) || ($0.dst ?? "").localizedCaseInsensitiveContains(query) }
        }
    }

    private var current: Session? { store.session(selection ?? store.sessions.first?.id) }

    var body: some View {
        // One white sheet; the list sits on a faint tint instead of behind a rule. The listening
        // pill lives in the window's toolbar (`MainToolbar`). With no meetings yet, only the
        // welcome shows: an empty list is noise.
        HStack(spacing: 0) {
            if !store.sessions.isEmpty {
                sidebar
                    .frame(width: 232)
                    .background(UnevenRoundedRectangle(topTrailingRadius: 14).fill(Self.listTint).ignoresSafeArea(edges: .bottom))
            }
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { detailWidth = $0 }
        }
        .background(Color.white.ignoresSafeArea())
        .background(Button("") { searchFocused = true }.keyboardShortcut("f").opacity(0))
        .onChange(of: model.mainShow) { _, show in
            guard let parts = show?.split(separator: ",").map(String.init), let id = parts.first else { return }
            selection = id
            tab = parts.count > 1 ? parts[1] : "notes"
            if parts.count > 2 { view = parts[2] }
        }
    }

    static let hairline = Color(red: 0.941, green: 0.945, blue: 0.957)
    static let listTint = Color(red: 0.98, green: 0.98, blue: 0.984)

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.secondary)
                TextField("搜索", text: $query).textFieldStyle(.plain).focused($searchFocused)
                if query.isEmpty {
                    Text("⌘F").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                } else {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(Palette.secondary).help("清除")
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 12).frame(height: 30)
            .padding(.bottom, 6)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    // The newest day shows; older ones fold under one row until asked for (or searched).
                    let all = groups
                    let folded = query.isEmpty && !showOlder && all.count > 1
                    ForEach(Array((folded ? Array(all.prefix(1)) : all).enumerated()), id: \.element.title) { i, g in
                        Text(g.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.secondary)
                            .padding(.horizontal, 12).padding(.top, i == 0 ? 0 : 18).padding(.bottom, 6)
                        ForEach(g.sessions) { sessionRow($0) }
                    }
                    if query.isEmpty && all.count > 1 {
                        Button { withAnimation(.easeOut(duration: 0.2)) { showOlder.toggle() } } label: {
                            HStack {
                                Text(showOlder ? L("收起更早的会议") : L("更早的会议"))
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                                    .rotationEffect(.degrees(showOlder ? -90 : 0))
                            }
                            .font(.system(size: 13)).foregroundStyle(Palette.secondary)
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 12)
                    }
                    if filtered.isEmpty {
                        Text("没有找到“\(query)”").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                            .padding(.horizontal, 10)
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 14)
        .onChange(of: selection) { _, id in
            // A meeting picked from elsewhere (search, the notes window) shouldn't hide in a fold.
            if let id, let first = groups.first, !first.sessions.contains(where: { $0.id == id }) { showOlder = true }
        }
    }

    /// 今天 / 昨天 / 本周 / then one group per month, newest first.
    private var groups: [(title: String, sessions: [Session])] {
        let cal = Calendar.current
        var out: [(title: String, sessions: [Session])] = []
        for s in filtered {
            let d = s.startedAt
            let title: String
            if cal.isDateInToday(d) { title = L("今天") }
            else if cal.isDateInYesterday(d) { title = L("昨天") }
            else if cal.isDate(d, equalTo: Date(), toGranularity: .weekOfYear) { title = L("本周") }
            else if cal.isDate(d, equalTo: Date(), toGranularity: .year) { title = dateText(d, "MMMM") }
            else { title = dateText(d, "yMMMM") }
            if out.last?.title == title { out[out.count - 1].sessions.append(s) } else { out.append((title, [s])) }
        }
        return out
    }

    private func sessionRow(_ s: Session) -> some View {
        let selected = s.id == (selection ?? store.sessions.first?.id)
        let live = s.id == store.liveID
        return Button {
            selection = s.id
            titleDraft = ""
        } label: {
            // Titles only: the time and length are on the page (and in the tooltip). Unpicked rows
            // stay grey so the one being read stands out.
            HStack(spacing: 8) {
                if live { BreathingDot(size: 6) }
                Text(Self.untitled(s) ? L("未命名会议") : Self.listTitle(s))
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected || live ? Palette.ink : Palette.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.white : Color.clear)
                .shadow(color: selected ? Palette.ink.opacity(0.06) : .clear, radius: 1.5, y: 1))
            .contentShape(Rectangle())
        }
        .help(live ? L("正在记录") : [when(s), Self.length(s)].joined(separator: " · "))
        .buttonStyle(.plain)
        .contextMenu {
            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([store.folder(s.id)]) }
            if s.renamed ?? !s.title.hasPrefix("会议 "), s.notes?.title != nil {
                Button("恢复自动标题") { store.rename(s.id, to: "") }
            }
            Button("删除", role: .destructive) { store.delete(s.id) }.disabled(live)
        }
    }

    private func when(_ s: Session) -> String {
        let cal = Calendar.current
        return dateText(s.startedAt, cal.isDateInToday(s.startedAt) || cal.isDateInYesterday(s.startedAt) ? "HHmm"
            : cal.isDate(s.startedAt, equalTo: Date(), toGranularity: .weekOfYear) ? "EEE" : "MMMd")
    }

    /// Notes titles often start with the day ("11月2日 产品周会"); under a 今天 heading that only
    /// pushes the real title out of the row.
    static func listTitle(_ s: Session) -> String {
        let title = s.displayTitle
        for prefix in [dateText(s.startedAt, "MMMd"), dateText(s.startedAt, "MMMMd")] where title.hasPrefix(prefix) {
            let rest = title.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { return rest }
        }
        return title
    }

    /// Still on the stored "会议 <date>" title: not renamed, and no notes title to show.
    static func untitled(_ s: Session) -> Bool {
        !(s.renamed ?? !s.title.hasPrefix("会议 ")) && (s.notes?.title ?? "").isEmpty
    }

    static func length(_ s: Session) -> String {
        let mins = Int(s.duration / 60)
        if mins < 1 { return L("不到 1 分钟") }
        return mins < 60 ? L("\(mins) 分钟") : mins % 60 == 0 ? L("\(mins / 60) 小时") : L("\(mins / 60) 小时 \(mins % 60) 分")
    }

    /// "英 → 中" (short) or "英语 → 中文", from the most common pair among the lines.
    static func pair(_ s: Session, short: Bool) -> String? {
        let pairs = Dictionary(grouping: s.lines.filter { $0.speaker != "me" }, by: { "\(lang($0.srcLang))|\(lang($0.dstLang))" })
        guard let top = pairs.max(by: { $0.value.count < $1.value.count })?.key else { return nil }
        let p = top.split(separator: "|").map(String.init)
        guard p.count == 2, p[0] != p[1] else { return nil }
        func name(_ c: String) -> String {
            let names = ["en": L("英语"), "ja": L("日语"), "zh-CN": L("中文"), "zh-TW": L("繁中"), "ko": L("韩语"),
                         "es": L("西语"), "fr": L("法语"), "de": L("德语"), "pt": L("葡语")]
            guard let n = names[c] else { return c.uppercased() }
            guard short else { return n }
            return uiIsChinese ? String(n.prefix(1)) : c == "zh-TW" ? "ZH-TW" : String(c.prefix(2)).uppercased()
        }
        return "\(name(p[0])) → \(name(p[1]))"
    }

    private static func lang(_ code: String) -> String {
        let base = String(code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
        return base == "zh" ? (code.contains("Hant") || code.hasSuffix("TW") || code.hasSuffix("HK") ? "zh-TW" : "zh-CN") : base
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let s = current {
            VStack(spacing: 0) {
                if s.lines.isEmpty {
                    ScrollView {
                        header(s).frame(maxWidth: 680).padding(.horizontal, 44).padding(.vertical, 36)
                            .frame(maxWidth: .infinity)
                    }
                        .overlay {
                            Text(s.id == store.liveID ? L("正在听，说话的内容会出现在这里") : L("这场会议没有记录到内容"))
                                .font(.system(size: 13)).foregroundStyle(Palette.secondary)
                        }
                } else if tab == "notes" {
                    HStack(spacing: 0) {
                        SessionNotesView(model: model, engine: model.notes, ling: model.ling, session: s,
                                         header: AnyView(header(s))) { t in
                            // Beside the notes, a topic's time scrolls the column; otherwise it opens the transcript.
                            if sideBySide { quoteJump = t } else { jumpTo = t; tab = "transcript" }
                        }
                        if sideBySide {
                            quotes(s).frame(width: 300).padding(.trailing, 24)
                        }
                    }
                } else {
                    transcript(s)
                }
                if s.id == store.liveID { liveNow }
            }
            .onChange(of: s.id) { _, _ in titleDraft = "" }
        } else {
            welcome
        }
    }

    /// No meetings yet: the logo, one line and the one thing to do.
    private var welcome: some View {
        VStack(spacing: 0) {
            BrandMark(size: 72).shadow(color: Palette.accent.opacity(0.22), radius: 14, y: 8)
            Text("还没有会议").font(.system(size: 26, weight: .bold)).padding(.top, 28)
            Text("打开会议或视频，开始听后，每一场都会存在这里。")
                .font(.system(size: 15)).foregroundStyle(Palette.secondary).multilineTextAlignment(.center)
                .padding(.top, 10)
            Button { model.setRunning(true) } label: {
                HStack(spacing: 10) {
                    Circle().fill(Palette.accent).frame(width: 9, height: 9)
                    Text("开始听").font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(.white).padding(.horizontal, 22).frame(height: 44)
                .background(Capsule().fill(Palette.ink))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain).padding(.top, 32)
            Button("先听一段示例") { model.ensureListening(); model.sample.play() }
                .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Palette.secondary).padding(.top, 16)
        }
        .frame(maxWidth: 420)
        .padding(.bottom, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 此刻: the sentence being heard, pinned under the page while the meeting is live.
    @ViewBuilder private var liveNow: some View {
        let src = model.liveSource.trimmingCharacters(in: .whitespacesAndNewlines)
        if !src.isEmpty {
            HStack(alignment: .top, spacing: 14) {
                HStack(spacing: 6) {
                    BreathingDot(size: 6)
                    Text("此刻").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.accentInk)
                }
                .frame(width: 52, alignment: .leading).padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(src).font(.system(size: 13)).foregroundStyle(Palette.secondary)
                        .lineLimit(2).truncationMode(.head)
                    if !model.liveTranslation.isEmpty {
                        Text(model.liveTranslation).font(.system(size: 15)).foregroundStyle(Palette.ink)
                            .lineLimit(2).truncationMode(.head)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.accentWash)
            .overlay(alignment: .top) { Rectangle().fill(Palette.accentPale).frame(height: 1) }
        }
    }

    /// Text tabs, the transcript's language choice and 导出…, under the title: no toolbar band.
    private func tabsRow(_ s: Session) -> some View {
        HStack(alignment: .center, spacing: 22) {
            tabButton(L("纪要"), id: "notes")
            tabButton(L("文字记录"), id: "transcript", count: s.lines.count)
            Spacer()
            if tab == "transcript" {
                Segments(options: [("both", L("双语")), ("src", L("原文")), ("dst", L("译文"))], value: view) { view = $0 }
            } else if wideEnough, !s.lines.isEmpty {
                Button { withAnimation(.easeOut(duration: 0.2)) { showQuotes.toggle() } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "sidebar.right").font(.system(size: 12))
                        Text("原话").font(.system(size: 13))
                    }
                    .foregroundStyle(showQuotes ? Palette.ink : Palette.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(showQuotes ? L("收起原话") : L("在纪要旁显示原话"))
            }
            Menu {
                Button("复制为 Markdown") { model.export(s, kind: "copy") }
                Divider()
                Button("导出 Markdown…") { model.export(s, kind: "md") }
                Button("导出 Word…") { model.export(s, kind: "word") }
                Button("导出字幕 SRT…") { model.export(s, kind: "srt") }
                Divider()
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([store.folder(s.id)]) }
            } label: {
                Text("导出…").font(.system(size: 13)).foregroundStyle(Palette.secondary)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .disabled(s.lines.isEmpty)
        }
    }

    private func tabButton(_ title: String, id: String, count: Int? = nil) -> some View {
        let on = tab == id
        return Button { tab = id } label: {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 13, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? Palette.ink : Palette.secondary)
                if let count { Text("\(count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(Palette.secondary) }
            }
            .padding(.bottom, 6)
            .overlay(alignment: .bottom) { Rectangle().fill(on ? Palette.ink : .clear).frame(height: 2) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// One grey line of facts, the editable title, then the tabs: the top of the page, scrolling with it.
    private func header(_ s: Session) -> some View {
        let live = s.id == store.liveID
        let notes = live ? model.notes.notes : s.notes
        // When and how long up front; the languages and notes version wait in the tooltip.
        let more = [Self.pair(s, short: false),
                    notes.flatMap { $0.isEmpty ? nil : ($0.final ? L("完整版纪要") : L("速记版纪要")) }]
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if live { Tag(L("正在记录"), live: true) }
                Text([dateText(s.startedAt, "MMMdHHmm"), Self.length(s)].joined(separator: " · "))
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(Palette.tertiary).lineLimit(1)
                    .help(([dateLine(s, live: live)] + more.compactMap { $0 }).joined(separator: " · "))
            }
            TextField("标题", text: Binding(
                // The date is on the line above; a notes title that starts with it shows without.
                get: { titleDraft.isEmpty ? Self.listTitle(s) : titleDraft },
                set: { titleDraft = $0 }
            ), axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 26, weight: .semibold))
            .padding(.top, 8)
            .onSubmit {
                if !titleDraft.isEmpty { store.rename(s.id, to: titleDraft) }
                titleDraft = ""
            }
            tabsRow(s).padding(.top, 24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The bilingual lines beside the notes, so the record's two languages show without switching tabs.
    private func quotes(_ s: Session) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("原话").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                        Spacer()
                        Button(L("全部 \(s.lines.count) 句")) { tab = "transcript" }
                            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    }
                    .padding(.bottom, 8)
                    let speakers = settings.speakerVoices ? SpeakerLabels.numbers(s.lines) : [:]
                    let starts = SpeakerLabels.runStarts(s.lines, speakers)
                    ForEach(s.lines) { l in
                        quoteRow(l, speaker: speakers[l.id], picked: quoteJump.map { t in l.id == pickedLine(s, t)?.id } ?? false,
                                 label: starts.contains(l.id), voices: !speakers.isEmpty).id(l.id)
                    }
                }
                .environment(\.speakerNames, SpeakerLabels.names(s))
                .padding(.vertical, 40)
            }
            .scrollIndicators(.never)
            .onChange(of: quoteJump) { _, t in
                guard let t, let l = pickedLine(s, t) else { return }
                withAnimation { proxy.scrollTo(l.id, anchor: .top) }
            }
            .onChange(of: s.lines.count) { _, _ in
                if s.id == store.liveID, quoteJump == nil, let last = s.lines.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: s.id) { _, _ in quoteJump = nil }
        }
    }

    private func pickedLine(_ s: Session, _ t: Double) -> TranscriptLine? {
        s.lines.first(where: { $0.t >= t - 1 }) ?? s.lines.last
    }

    /// Whitespace between lines, no rules; the picked line gets a soft fill.
    private func quoteRow(_ l: TranscriptLine, speaker: Int?, picked: Bool, label: Bool = true, voices: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // Only once voices are told apart (or for your own lines): one speaker needs no label;
            // and only where the speaker changes.
            if !label {
            } else if let speaker { SpeakerTag(number: speaker).padding(.bottom, 2) }
            else if voices, l.speaker != "me" { UnknownSpeakerTag().padding(.bottom, 2) }
            else if l.speaker == "me" {
                Text("你").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.accentInk).padding(.bottom, 2)
            }
            Text(l.src).font(.system(size: 12)).foregroundStyle(Palette.secondary).lineSpacing(1)
                .textSelection(.enabled)
            Text(l.dst ?? L("翻译中…")).font(.system(size: 14)).lineSpacing(2)
                .foregroundStyle(l.dst == nil ? Palette.secondary : Palette.ink)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(picked ? Palette.fill : .clear))
        .padding(.horizontal, -8)
        .help(TranscriptExport.clock(l.t))
    }

    private func dateLine(_ s: Session, live: Bool) -> String {
        let start = dateText(s.startedAt, "MMMdEEEHHmm")
        guard !live, let end = s.endedAt else { return live ? L("\(start) 起") : start }
        return "\(start) – \(dateText(end, "HHmm"))"
    }

    private func transcript(_ s: Session) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    header(s).padding(.bottom, 16)
                    let speakers = settings.speakerVoices ? SpeakerLabels.numbers(s.lines) : [:]
                    if !speakers.isEmpty { SpeakerStrip(model: model, session: s).padding(.bottom, 8) }
                    let starts = SpeakerLabels.runStarts(s.lines, speakers)
                    ForEach(s.lines) { l in
                        lineRow(l, speaker: speakers[l.id], label: speakers.isEmpty || starts.contains(l.id), voices: !speakers.isEmpty).id(l.id)
                    }
                }
                .environment(\.speakerNames, SpeakerLabels.names(s))
                .frame(maxWidth: 680)
                .padding(.horizontal, 40).padding(.vertical, 36)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: s.lines.count) { _, _ in
                if s.id == store.liveID, let last = s.lines.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onAppear {
                if let t = jumpTo, let l = s.lines.first(where: { $0.t >= t - 1 }) { proxy.scrollTo(l.id, anchor: .top) }
                jumpTo = nil
            }
        }
    }

    private func lineRow(_ l: TranscriptLine, speaker: Int? = nil, label: Bool = true, voices: Bool = false) -> some View {
        let me = l.speaker == "me"
        return HStack(alignment: .top, spacing: 16) {
            Text(TranscriptExport.clock(l.t))
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(Palette.tertiary)
                .frame(width: 52, alignment: .leading).padding(.top, 1)
            VStack(alignment: .leading, spacing: 5) {
                if !label {
                } else if let speaker { SpeakerTag(number: speaker) }
                else if voices, !me { UnknownSpeakerTag() }
                else {
                    Text(me ? L("你") : L("对方")).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(me ? Palette.accentInk : Palette.secondary)
                }
                if view != "dst" {
                    Text(l.src)
                        .font(.system(size: view == "src" ? 15 : 13))
                        .foregroundStyle(view == "src" ? Palette.ink : Palette.tertiary)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                }
                if view != "src" {
                    Text(l.dst ?? L("翻译中…"))
                        .font(.system(size: 15)).lineSpacing(3)
                        .foregroundStyle(l.dst == nil ? Palette.tertiary : Palette.ink)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
    }
}


/// A meeting's notes in the main window: the same notes view as the live window, or a way to
/// make them for a meeting recorded without a key.
struct SessionNotesView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var engine: NotesEngine
    @ObservedObject var ling: LingClient
    let session: Session
    /// The page's title block, scrolling with the notes.
    var header: AnyView = AnyView(EmptyView())
    let onJump: (Double) -> Void

    private var live: Bool { session.id == model.store.liveID }
    private var notes: MeetingNotes? { live ? engine.notes : session.notes }
    private var generating: Bool { engine.generatingID == session.id }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                header
                if let notes, !notes.isEmpty {
                    NotesContentView(notes: notes, fresh: live ? engine.fresh : [], live: live, document: true,
                                     endedAt: session.lines.last?.t, onJump: onJump)
                } else if generating || (live && ling.hasKey && !session.lines.isEmpty) {
                    NotesGeneratingView(heard: session.lines.count)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(generating ? L("正在整理纪要…") : live ? L("纪要会在会议进行中自动生成") : L("这场会议还没有纪要"))
                            .font(.system(size: 15, weight: .bold))
                        Text(ling.hasKey ? L("使用 Ling 将文字记录整理为总结、议题、结论和人名，约需半分钟。")
                                         : L("前往 设置 › AI 服务 填入 Ling 的 API key 后即可生成。"))
                            .font(.system(size: 13)).foregroundStyle(Palette.secondary)
                        if !live {
                            HStack(spacing: 8) {
                                if ling.hasKey {
                                    SoftButton(generating ? L("正在生成…") : L("生成纪要"), dark: true) {
                                        engine.generate(for: session.id)
                                    }
                                    .disabled(generating)
                                } else {
                                    SoftButton(L("去填 key"), dark: true) { model.openSettings(.ai) }
                                }
                            }
                        }
                    }
                    .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 18).fill(Palette.raised))
                }
            }
            // A narrow measure and a tall top margin: the page reads as one quiet column.
            .frame(maxWidth: 600, alignment: .leading)
            .padding(.horizontal, 44).padding(.top, 52).padding(.bottom, 64)
            .frame(maxWidth: .infinity)
        }
    }
}

import SwiftUI

/// 设置, as the design's: grey section labels over white cards: the Ling key and model (纪要), the
/// language meetings are translated into, 说话人识别, 面对面's own language, and 快速开始.
struct SettingsView: View {
    /// iPad shows it as a sheet, with 完成.
    var sheet = false
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var ling: LingClient
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Pref.model) private var aiModel = LingClient.models[0]
    @AppStorage(Pref.target) private var target = "system"
    @AppStorage(Pref.voices) private var voices = true
    @AppStorage(Pref.recordAudio) private var recordAudio = true
    @AppStorage(Pref.silenceEnd) private var silenceEnd = "prompt"
    @AppStorage(Pref.silenceMinutes) private var silenceMinutes = 10.0
    @AppStorage(Pref.notesLanguage) private var notesLanguage = "mine"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !sheet {
                        Text("设置").font(.largeTitle.bold()).foregroundStyle(Ink.ink)
                            .padding(.horizontal, 4).padding(.top, 6)
                    }
                    SectionLabel(text: L("AI 服务"))
                    Card {
                        NavigationLink { AIServicePage() } label: {
                            row(Text(verbatim: ling.provider.id == .custom ? L("自定义服务") : ling.provider.name)) {
                                KeyStatus(state: ling.keyState)
                                Chevron()
                            }
                        }
                        .buttonStyle(RowPress())
                        Hairline()
                        NavigationLink { WordListPage(vocabulary: model.vocabulary) } label: {
                            row(Text("词表")) {
                                if !model.vocabulary.terms.isEmpty {
                                    Text(verbatim: "\(model.vocabulary.terms.count)").foregroundStyle(Ink.secondary).monospacedDigit()
                                }
                                Chevron()
                            }
                        }
                        .buttonStyle(RowPress())
                    }
                    SectionLabel(text: L("听对方"))
                    Card {
                        row(Text("翻译成")) {
                            Picker(selection: $target) {
                                Text("跟随系统").tag("system")
                                ForEach(targetLanguages, id: \.code) { Text(verbatim: $0.name).tag($0.code) }
                            } label: { Text("翻译成") }
                            .pickerStyle(.menu)
                            .tint(Ink.secondary)
                        }
                        Hairline()
                        row(Text("说话人识别")) {
                            Toggle(isOn: $voices) { Text("说话人识别") }
                                .labelsHidden()
                                .tint(Ink.ok)
                        }
                        Hairline()
                        NavigationLink { PeoplePage() } label: {
                            row(Text("人员库")) {
                                if !model.speakerProfiles.isEmpty {
                                    Text(verbatim: "\(model.speakerProfiles.count)").foregroundStyle(Ink.secondary).monospacedDigit()
                                }
                                Chevron()
                            }
                        }
                        .buttonStyle(RowPress())
                        Hairline()
                        helped(row(Text("保存会议录音")) {
                            Toggle(isOn: $recordAudio) { Text("保存会议录音") }
                                .labelsHidden()
                                .tint(Ink.ok)
                        }, L("只存在这台手机上，会议记录里能回放原声"))
                    }
                    // As on the Mac and Android, minus 会议应用挂断后结束: iOS can't see another app's microphone.
                    SectionLabel(text: L("结束会议"))
                    Card {
                        helped(row(Text("没人说话时")) {
                            Picker(selection: $silenceEnd) {
                                Text("提醒后结束").tag("prompt")
                                Text("直接结束").tag("end")
                                Text("一直记录").tag("off")
                            } label: { Text("没人说话时") }
                            .pickerStyle(.menu)
                            .tint(Ink.secondary)
                        }, L("按识别出的话算，背景音乐不算"))
                        if silenceEnd != "off" {
                            Hairline()
                            row(Text("多久算没人说话")) {
                                Picker(selection: $silenceMinutes) {
                                    ForEach([5.0, 10, 15, 30], id: \.self) { Text(L("\(Int($0)) 分钟")).tag($0) }
                                } label: { Text("多久算没人说话") }
                                .pickerStyle(.menu)
                                .tint(Ink.secondary)
                            }
                        }
                    }
                    SectionLabel(text: L("纪要"))
                    Card {
                        row(Text("纪要语言")) {
                            // The menu names the language; the row only the choice, so it fits on one line in English.
                            Menu {
                                Picker(selection: $notesLanguage) {
                                    Text(L("我的语言 · \(targetName(Pref.targetCode))")).tag("mine")
                                    Text("会议原文").tag("source")
                                } label: { Text("纪要语言") }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(notesLanguage == "source" ? L("会议原文") : L("我的语言")).lineLimit(1)
                                    Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
                                }
                                .foregroundStyle(Ink.secondary)
                            }
                        }
                    }
                    SectionLabel(text: L("面对面"))
                    Card {
                        row(Text("我说")) {
                            Picker(selection: Binding(get: { model.face.mine.locale }, set: { l in
                                guard let m = FaceToFace.lang(l) else { return }
                                model.face.setLanguages(mine: m, theirs: m == model.face.theirs ? model.face.mine : model.face.theirs)
                                model.objectWillChange.send()
                            })) {
                                ForEach(sourceLanguages, id: \.locale) { Text(verbatim: $0.name).tag($0.locale) }
                            } label: { Text("我说") }
                            .pickerStyle(.menu)
                            .tint(Ink.secondary)
                        }
                        Hairline()
                        NavigationLink { VoicesPage(face: model.face) } label: {
                            row(Text("念给对方的声音")) {
                                Text(verbatim: voiceSummary).foregroundStyle(Ink.secondary).lineLimit(1)
                                Chevron()
                            }
                        }
                        .buttonStyle(RowPress())
                    }
                    SectionLabel(text: L("会后存一份"))
                    Card {
                        NavigationLink { FolderPage(exporter: model.folderExport) } label: {
                            row(Text("存到文件夹")) {
                                Text(verbatim: model.folderExport.on ? model.folderExport.folder.map(FolderExporter.shortPath) ?? "" : L("关闭"))
                                    .foregroundStyle(Ink.secondary).lineLimit(1)
                                Chevron()
                            }
                        }
                        .buttonStyle(RowPress())
                    }
                    SectionLabel(text: L("快速开始"))
                    Card {
                        NavigationLink { QuickStartPage() } label: {
                            row(Text("操作按钮、控制中心和 Siri")) { Chevron() }
                        }
                        .buttonStyle(RowPress())
                    }
                    Text(L("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")"))
                        .font(.footnote).foregroundStyle(Ink.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 28)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 120)
                // On iPad a readable column, not the whole width.
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .background(Ink.ground)
            .navigationDestination(isPresented: $model.showWordList) { WordListPage(vocabulary: model.vocabulary) }
            .navigationDestination(isPresented: $model.showQuickStart) { QuickStartPage() }
            .navigationDestination(isPresented: $model.showVoices) { VoicesPage(face: model.face) }
            .navigationDestination(isPresented: $model.showAIService) { AIServicePage() }
            .navigationDestination(isPresented: $model.showFolder) { FolderPage(exporter: model.folderExport) }
            .navigationDestination(isPresented: $model.showPeople) { PeoplePage() }
            .toolbar(sheet ? .visible : .hidden, for: .navigationBar)
            .navigationTitle(sheet ? Text("设置") : Text(""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if sheet {
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
                }
            }
        }
        .onChange(of: voices) { TranscriptExport.voices = voices; model.objectWillChange.send() }
        .tint(Ink.ink)
    }

    /// A row with its one grey helper line under it.
    private func helped<R: View>(_ row: R, _ help: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            row
            Text(verbatim: help).font(.footnote).foregroundStyle(Ink.secondary)
                .padding(.horizontal, 16).padding(.top, -6).padding(.bottom, 10)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 念给对方的声音 at a glance: the voice the other person hears.
    private var voiceSummary: String {
        let lang = model.face.theirs.code
        let id = SpeakVoices.chosenID(for: lang, hasKey: ling.hasKey, clones: ling.clones)
        if id == VoiceCatalog.cloneOption.id { return L("我自己的声音") }
        return VoiceCatalog.options(for: lang).first { $0.id == id }?.name ?? L("手机自带")
    }

    private func row<V: View>(_ title: Text, @ViewBuilder value: () -> V) -> some View {
        HStack(spacing: 8) {
            title.foregroundStyle(Ink.ink)
            Spacer()
            value()
        }
        .font(.body)
        .padding(.horizontal, 16)
        .frame(minHeight: 50)
        .contentShape(Rectangle())
    }
}

/// "● 已连接" and the other key states, as on the Mac's AI 服务 page.
struct KeyStatus: View {
    let state: LingClient.KeyState

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).foregroundStyle(Ink.secondary)
        }
    }

    private var color: Color {
        switch state {
        case .ok: Ink.ok
        case .invalid, .unreachable: Color(red: 0.80, green: 0.20, blue: 0.16)
        case .checking, .unchecked: Ink.accent
        case .none: Color(white: 0.75)
        }
    }

    var title: String {
        switch state {
        case .none: L("还没填 API key")
        case .unchecked, .checking: L("正在检查…")
        case .ok: L("已连接")
        case .invalid: L("这个 key 用不了")
        case .unreachable: L("暂时连不上")
        }
    }
}

/// Paste or type the key; it is checked with one tiny request and kept only in the app's file.
struct KeyPage: View {
    @EnvironmentObject var ling: LingClient
    @AppStorage(Pref.model) private var aiModel = LingClient.models[0]
    @State private var draft = ""
    @State private var editing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        KeyStatus(state: ling.keyState).font(.body.weight(.semibold))
                        if let detail { Text(detail).font(.footnote).foregroundStyle(Ink.secondary) }
                    }
                    .padding(16)
                    Hairline()
                    if let key = ling.key, !editing {
                        HStack {
                            Text(verbatim: AIKey.masked(key)).font(.body.monospaced()).foregroundStyle(Ink.ink)
                            Spacer()
                            Button("更换") { draft = ""; editing = true }
                        }
                        .padding(.horizontal, 16).frame(minHeight: 50)
                    } else {
                        SecureField(text: $draft) { Text(verbatim: "sk-…") }
                            .font(.body.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .onSubmit(save)
                            .padding(.horizontal, 16).frame(minHeight: 50)
                    }
                }
                .padding(.top, 12)

                if ling.key == nil || editing {
                    HStack(spacing: 10) {
                        Button { draft = UIPasteboard.general.string ?? ""; save() } label: {
                            Text("粘贴并检查").font(.headline).foregroundStyle(.white)
                                .frame(maxWidth: .infinity, minHeight: 50)
                                .background(Ink.ink, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        if !draft.isEmpty {
                            Button("保存并检查", action: save).font(.headline)
                        }
                    }
                    .padding(.top, 16)
                    if ling.provider.id == .ling {
                        Text("在 Ling 开放平台点“创建令牌”，复制以 sk- 开头的那串。")
                            .font(.footnote).foregroundStyle(Ink.secondary)
                            .padding(.horizontal, 4).padding(.top, 12)
                    }
                    if let site = ling.provider.site {
                        Link(ling.provider.id == .ling ? L("打开 Ling 开放平台 ↗") : L("获取 \(ling.provider.name) key ↗"), destination: site)
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 4).padding(.top, 8)
                    }
                }
                if ling.key != nil && !editing {
                    HStack {
                        // Any state: a key fixed on the service's side (its model list, its credit) is checked again here.
                        Button("重新检查") { Task { await ling.check() } }
                            .disabled(ling.keyState == .checking)
                        Spacer()
                        Button("移除", role: .destructive) { ling.removeKey() }
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 4).padding(.top, 14)
                }
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(Ink.ground)
        .navigationTitle(Text(verbatim: ling.provider.id == .custom ? "Key" : "\(ling.provider.name) key"))
        .onAppear { ling.recheckIfFailed() }
        .navigationBarTitleDisplayMode(.inline)
    }

    private var detail: String? {
        switch ling.keyState {
        case .ok(let s): L("\(ling.config().textModel) · 响应约 \(String(format: "%.1f", s)) 秒")
        case .invalid: ling.provider.id == .ling ? L("Ling 提示此令牌无效，请检查是否复制完整，或重新创建一个") : L("这个 key 用不了")
        case .unreachable(let why): why
        case .none: L("不填 key 时，字幕和翻译仍可正常使用")
        default: nil
        }
    }

    private func save() {
        let k = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        draft = ""
        editing = false
        Task { await ling.setKey(k) }
    }
}

/// 设置 › 快速开始: where 开始听 can be put. iOS lets only the user choose them, in the system's own
/// settings; this page says where.
struct QuickStartPage: View {
    /// What Siri and the Action button list the app as.
    private let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? appDisplayName

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("不用先打开 app 就开始听，再按一次结束").font(.subheadline).foregroundStyle(Ink.secondary)
                    .padding(.horizontal, 16).padding(.top, 12)
                SectionLabel(text: L("操作按钮"))
                Card {
                    HStack(spacing: 16) {
                        RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Ink.ink, lineWidth: 2)
                            .frame(width: 56, height: 86)
                            .overlay(alignment: .topLeading) {
                                Capsule().fill(Ink.accent).frame(width: 4, height: 16).offset(x: -6, y: 16)
                            }
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("按一下开始听").font(.headline).foregroundStyle(Ink.ink)
                            Text(L("iPhone 设置 › 操作按钮 › 快捷指令 › \(name)“开始听”")).font(.footnote).foregroundStyle(Ink.secondary)
                            Button("打开 iPhone 设置") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                            }
                            .font(.subheadline.weight(.semibold)).tint(Ink.accentText)
                            .frame(minHeight: 32)
                        }
                    }
                    .padding(16)
                }
                SectionLabel(text: L("控制中心和锁屏"))
                Card {
                    HStack(spacing: 16) {
                        RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(hex: 0x2A2D35))
                            .frame(width: 60, height: 60)
                            .overlay { Image(systemName: "mic.fill").foregroundStyle(.white).frame(width: 34, height: 34).background(Ink.accent, in: Circle()) }
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("“开始听”按钮").font(.headline).foregroundStyle(Ink.ink)
                            Text("下拉控制中心，点左上角的 + 添加").font(.footnote).foregroundStyle(Ink.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(16)
                }
                SectionLabel(text: "Siri")
                Card {
                    Text(L("“嘿 Siri，用\(name)开始听”")).padding(.horizontal, 16).frame(minHeight: 50)
                    Hairline()
                    Text(L("“嘿 Siri，\(name)结束”")).padding(.horizontal, 16).frame(minHeight: 50)
                }
                Text("都按上次的语言听").font(.footnote).foregroundStyle(Ink.tertiary)
                    .padding(.horizontal, 16).padding(.top, 10)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 40)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(Ink.ground)
        .navigationTitle(Text("快速开始"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

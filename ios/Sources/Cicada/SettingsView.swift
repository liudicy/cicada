import SwiftUI

/// 设置, as the design's: grey section labels over white cards. Only what the app does today:
/// the Ling key and model (纪要), the language meetings are translated into, and 说话人识别.
/// 同声传译 and 快速开始 come with M3 and M4.
struct SettingsView: View {
    /// iPad shows it as a sheet, with 完成.
    var sheet = false
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var ling: LingClient
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Pref.model) private var aiModel = LingClient.models[0]
    @AppStorage(Pref.target) private var target = "system"
    @AppStorage(Pref.voices) private var voices = true
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
                        NavigationLink { KeyPage() } label: {
                            row(Text(verbatim: "Ling key")) {
                                KeyStatus(state: ling.keyState)
                                Chevron()
                            }
                        }
                        .buttonStyle(RowPress())
                        Hairline()
                        row(Text("模型")) {
                            Picker(selection: $aiModel) {
                                ForEach(LingClient.models, id: \.self) { Text(verbatim: $0).tag($0) }
                            } label: { Text("模型") }
                            .pickerStyle(.menu)
                            .tint(Ink.secondary)
                        }
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
                    }
                    SectionLabel(text: L("纪要"))
                    Card {
                        row(Text("纪要语言")) {
                            Picker(selection: $notesLanguage) {
                                Text(L("我的语言 · \(targetName(Pref.targetCode))")).tag("mine")
                                Text("会议原文").tag("source")
                            } label: { Text("纪要语言") }
                            .pickerStyle(.menu)
                            .tint(Ink.secondary)
                        }
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
                    Text("在 Ling 开放平台点“创建令牌”，复制以 sk- 开头的那串。")
                        .font(.footnote).foregroundStyle(Ink.secondary)
                        .padding(.horizontal, 4).padding(.top, 12)
                    Link("打开 Ling 开放平台 ↗", destination: URL(string: "https://chat.ant-ling.com/platform/api")!)
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 4).padding(.top, 8)
                }
                if ling.key != nil && !editing {
                    HStack {
                        if case .unreachable = ling.keyState { Button("重试") { Task { await ling.check() } } }
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
        .navigationTitle(Text(verbatim: "Ling key"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var detail: String? {
        switch ling.keyState {
        case .ok(let s): L("\(aiModel) · 响应约 \(String(format: "%.1f", s)) 秒")
        case .invalid: L("Ling 提示此令牌无效，请检查是否复制完整，或重新创建一个")
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

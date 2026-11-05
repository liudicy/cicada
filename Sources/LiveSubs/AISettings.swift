import AppKit
import SwiftUI

/// Settings › AI 服务: the service and its key, what works with it, and (folded away) its models.
/// Ling is the default and the only one with everything; the others are a way in for people who
/// cannot use Ling, with the recommended models already chosen.
struct AISettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var ling: LingClient
    @ObservedObject var settings: AppSettings
    @State private var draft = ""
    @State private var editing = false
    @State private var baseDraft = ""
    @State private var textDraft = ""
    @State private var asrDraft = ""
    @State private var asrEditing = false
    /// Re-read after saving/removing the cloud key (the key file is not observable).
    @State private var asrKey: String? = nil

    private var provider: AIProvider { settings.provider }
    private var name: String { provider.name }
    /// Cloud speech proofreading runs when it is on and has its own key.
    private var asrOn: Bool { settings.cloudASREnabled && asrKey != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            keyCard
            Text("现在能用的").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.secondary)
                .padding(.top, 4)
            SettingsCard { usage }
            Button { withAnimation(.easeOut(duration: 0.15)) { model.aiModelsOpen.toggle() } } label: {
                HStack(spacing: 4) {
                    Text("自己选模型")
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(model.aiModelsOpen ? 90 : 0))
                }
                .font(.system(size: 13)).foregroundStyle(Palette.secondary).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if model.aiModelsOpen { SettingsCard { models } }
            Text("语音识别校对").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.secondary)
                .padding(.top, 4)
            cloudASRCard
            Text(footnote).font(.system(size: 12)).foregroundStyle(Palette.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { syncDrafts() }
        .onChange(of: settings.aiProvider) { _, _ in syncDrafts(); editing = false; draft = "" }
    }

    // MARK: Key

    private var keyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(statusTitle).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.ink)
                if let detail = statusDetail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(Palette.tertiary).lineLimit(1)
                }
                Spacer()
            }
            if provider.id == .custom { customFields }
            if let key = ling.key, !key.isEmpty, !editing {
                HStack(spacing: 8) {
                    Text(AIKey.masked(key)).font(.system(size: 13, design: .monospaced)).foregroundStyle(Palette.ink)
                        .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line, lineWidth: 1))
                    SoftButton(L("更换")) { draft = ""; editing = true }
                    if case .unreachable = ling.keyState {
                        SoftButton(L("重试")) { Task { await ling.check() } }
                    }
                }
            } else {
                if ling.key == nil, provider.id != .custom {
                    Text(L("在 \(name) 创建 key，复制后粘贴到这里。"))
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }
                HStack(spacing: 8) {
                    SecureField(keyPlaceholder, text: $draft)
                        .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced))
                        .padding(.horizontal, 12).frame(height: 36)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.ink.opacity(0.6), lineWidth: 1))
                        .onSubmit(save)
                    SoftButton(L("保存并检查"), dark: true, action: save)
                    if editing { SoftButton(L("取消")) { editing = false } }
                }
                if let site = provider.site, ling.key == nil {
                    Button(L("打开 \(name) ↗")) { NSWorkspace.shared.open(site) }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "lock").font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                Text(lockLine).font(.system(size: 11)).foregroundStyle(Palette.tertiary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                if let key = ling.key, !key.isEmpty, !editing {
                    Button("移除") { ling.removeKey() }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.secondary)
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Palette.raised))
    }

    /// A custom service needs its address and a model before a key can be checked.
    private var customFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            field(L("地址"), "https://api.example.com/v1", $baseDraft)
            field(L("模型"), L("例如 qwen3:14b"), $textDraft)
            if !baseDraft.isEmpty, AIProvider.customBase(baseDraft) == nil {
                Text("地址需用 https，仅 localhost 可用 http。").font(.system(size: 11)).foregroundStyle(Palette.error)
            }
        }
    }

    private func field(_ label: String, _ placeholder: String, _ text: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 12)).foregroundStyle(Palette.secondary).frame(minWidth: 34, alignment: .leading).fixedSize()
            TextField(placeholder, text: text)
                .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced))
                .padding(.horizontal, 12).frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.white))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.line, lineWidth: 1))
                .onSubmit(save)
        }
    }

    private var keyPlaceholder: String {
        switch provider.id {
        case .openrouter: "sk-or-…"
        case .custom: AIProvider.isLocal(baseDraft) ? L("本机服务可不填") : "sk-…"
        default: "sk-…"
        }
    }

    private var lockLine: String {
        let host = provider.id == .custom ? (settings.aiConfig.base?.host ?? L("你填的地址")) : (provider.base?.host ?? "")
        return provider.id == .custom ? L("只存在这台 Mac 上（只有你的账户能读），只发给 \(host)")
            : L("只存在这台 Mac 上（只有你的账户能读），只发给 \(name)（\(host)）")
    }

    /// Saves what was typed (a custom service's address and model too), then checks.
    private func save() {
        if provider.id == .custom {
            settings.aiCustomBase = baseDraft.trimmingCharacters(in: .whitespaces)
            settings.aiModels["custom"] = textDraft.trimmingCharacters(in: .whitespaces)
            model.applyAIService()
        }
        let k = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        editing = false
        if k.isEmpty {
            if ling.hasKey { Task { await ling.check() } }
        } else {
            Task { await ling.setKey(k) }
        }
    }

    private func syncDrafts() {
        baseDraft = settings.aiCustomBase
        textDraft = settings.aiModels["custom"] ?? ""
    }

    private var statusColor: Color {
        switch ling.keyState {
        case .ok: Palette.ok
        case .invalid, .unreachable: Palette.error
        case .checking, .unchecked: Palette.accent
        case .none: Color(white: 0.75)
        }
    }

    private var statusTitle: String {
        switch ling.keyState {
        case .none: provider.id == .custom ? L("还没填好") : L("还没填 API key")
        case .unchecked, .checking: L("正在检查…")
        case .ok: L("已连接")
        case .invalid: L("这个 key 用不了")
        case .unreachable: L("暂时连不上")
        }
    }

    private var statusDetail: String? {
        switch ling.keyState {
        case .ok(let s): L("\(settings.textModel) · 响应约 \(String(format: "%.1f", s)) 秒")
        case .invalid: L("\(name) 提示 key 无效，请检查是否复制完整，或重新创建一个")
        case .unreachable(let why): why
        case .none: L("不填 key 时，字幕和翻译仍可正常使用")
        default: nil
        }
    }

    // MARK: What works

    @ViewBuilder private var usage: some View {
        let on = ling.usable
        let uses = L("用 \(name)")
        usageRow(L("实时纪要"), tag: on ? uses : L("需要 key"), style: on ? .ok : .off,
                 note: on ? L("会中每 45 秒更新") : L("填好 key 后可用"))
        usageRow(L("翻译"), tag: on ? uses : "Google", style: on ? .ok : .off,
                 note: on ? (Recognition.hasOnDeviceTranslation ? L("整句用它；不行时换 Google、本机") : L("整句用它；不行时换 Google"))
                          : L("没有 key 时照常可用"))
        usageRow(L("同传声音"), tag: ling.speaks ? uses : L("本机"), style: ling.speaks ? .ok : .off, note: voiceNote)
        if provider.clones {
            usageRow(L("你自己的声音"), tag: on ? uses : L("需要 key"), style: on ? .ok : .off, note: L("录一段，让对方听到你的音色"))
        } else {
            usageRow(L("你自己的声音"), tag: L("只有 Ling"), style: .ling, note: L("换用 Ling 才有"))
        }
        usageRow(L("语音识别"), tag: asrOn ? L("云端校对") : L("本机"), style: asrOn ? .ok : .off,
                 note: asrOn ? L("整句再请云端识别一遍，记录更准") : L("更快，不花钱"), divider: false)
    }

    private var voiceNote: String {
        if ling.speaks { return provider.id == .ling ? L("Ming 的声音") : (settings.aiConfig.voiceModel ?? "") }
        if !ling.usable { return L("没有 key 时用本机声音") }
        return provider.id == .custom ? L("没填声音模型，用本机声音") : L("\(name) 暂不能出声音，用本机声音")
    }

    private enum TagStyle { case ok, off, ling }

    private func usageRow(_ title: String, tag: String, style: TagStyle, note: String, divider: Bool = true) -> some View {
        SettingsRow(title: title, detail: note, divider: divider) {
            Text(tag).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(style == .ok ? Palette.ok : style == .ling ? Palette.accentInk : Palette.secondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(style == .ok ? Palette.okPale : style == .ling ? Palette.accentPale : Palette.fill))
                .lineLimit(1).fixedSize()
        }
    }

    // MARK: Models

    @ViewBuilder private var models: some View {
        switch provider.id {
        case .ling:
            SettingsRow(title: L("模型"), detail: L("3.1 更准；3.0 更快、更省"), divider: false) {
                PillMenu(value: settings.aiModel, options: LingClient.models.map { ($0, $0) }) {
                    settings.aiModel = $0
                    model.applyAIService()
                }
            }
        case .custom:
            customVoiceFields
        default:
            SettingsRow(title: L("文字模型"), detail: L("纪要和整句翻译"), divider: provider.hasVoices) {
                ModelMenu(value: settings.textModel, recommended: provider.textModels, catalog: ling.catalog) {
                    settings.aiModels[provider.id.rawValue] = $0
                    model.applyAIService()
                }
            }
            if provider.hasVoices {
                SettingsRow(title: L("声音模型"), detail: L("同传念给对方"), divider: false) {
                    ModelMenu(value: settings.aiConfig.voiceModel ?? "", recommended: provider.voiceModels, catalog: []) {
                        settings.aiVoiceModels[provider.id.rawValue] = $0
                        model.applyAIService()
                    }
                }
            }
        }
    }

    /// A custom service speaks only when given a speech model (`/audio/speech`), maybe at another address.
    private var customVoiceFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("声音（可选）").font(.system(size: 13)).foregroundStyle(Palette.ink)
            Text("需支持 /audio/speech；不填则用本机声音。").font(.system(size: 11)).foregroundStyle(Palette.tertiary)
            CommitField(label: L("模型"), placeholder: L("例如 kokoro"), value: settings.aiVoiceModels["custom"] ?? "") {
                settings.aiVoiceModels["custom"] = $0
                model.applyAIService()
            }
            CommitField(label: L("声音"), placeholder: L("例如 af_heart"), value: settings.aiCustomVoice) {
                settings.aiCustomVoice = $0
                model.applyAIService()
            }
            CommitField(label: L("地址"), placeholder: L("跟上面一样"), value: settings.aiCustomVoiceBase) {
                settings.aiCustomVoiceBase = $0
                model.applyAIService()
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: Cloud speech proofreading

    /// Fork addition: after each sentence finishes, its audio is re-recognized by a cloud model
    /// (preset: Xiaomi MiMo) and the more accurate text replaces the on-device transcript.
    private var cloudASRCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(L("云端校对")).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.ink)
                Spacer()
                Toggle("", isOn: $settings.cloudASREnabled).labelsHidden().toggleStyle(.switch)
            }
            Text("每句说完后，把这句的声音发给云端模型再识别一遍，用更准的文字替换记录里的原文并重译；实时字幕仍是本机识别。")
                .font(.system(size: 12)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            if settings.cloudASREnabled {
                if let key = asrKey, !asrEditing {
                    HStack(spacing: 8) {
                        Text(AIKey.masked(key)).font(.system(size: 13, design: .monospaced)).foregroundStyle(Palette.ink)
                            .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line, lineWidth: 1))
                        SoftButton(L("更换")) { asrDraft = ""; asrEditing = true }
                        Button("移除") { model.cloudASR.removeKey(); asrKey = nil }
                            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    }
                } else {
                    HStack(spacing: 8) {
                        SecureField("API key", text: $asrDraft)
                            .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced))
                            .padding(.horizontal, 12).frame(height: 36)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.ink.opacity(0.6), lineWidth: 1))
                        SoftButton(L("保存"), dark: true) {
                            model.cloudASR.setKey(asrDraft)
                            asrDraft = ""
                            asrEditing = false
                            asrKey = model.cloudASR.key
                        }
                        if asrEditing { SoftButton(L("取消")) { asrEditing = false } }
                    }
                    Button("去小米 MiMo 开放平台领 key ↗") {
                        if let url = URL(string: "https://platform.xiaomimimo.com") { NSWorkspace.shared.open(url) }
                    }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }
                asrField(L("接口地址"), text: $settings.cloudASRBase)
                asrField(L("模型"), text: $settings.cloudASRModel)
                HStack(spacing: 6) {
                    Image(systemName: "lock").font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                    Text("只发句子的录音（小米 MiMo 约 ¥0.5/小时）。key 只存在这台 Mac 上。")
                        .font(.system(size: 11)).foregroundStyle(Palette.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Palette.raised))
        .onAppear { asrKey = model.cloudASR.key }
    }

    /// Like `field`, but bound straight to a setting (no save-on-submit of the AI key).
    private func asrField(_ label: String, text: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 12)).foregroundStyle(Palette.secondary).frame(minWidth: 52, alignment: .leading).fixedSize()
            TextField("", text: text)
                .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced))
                .padding(.horizontal, 12).frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.white))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.line, lineWidth: 1))
        }
    }

    private var footnote: String {
        switch provider.id {
        case .ling: L("一小时会议约 ¥0.15–1（目前优惠价）。发出去的只有文字（用你自己的声音时还有那段录音），语音识别留在本机。")
        default: L("按所选模型计费。发出去的只有文字，语音识别留在本机。")
        }
    }
}

/// The service, in the page header: Ling first, the others for when Ling cannot be used.
struct AIServiceMenu: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings

    static func title(_ p: AIProvider) -> String { p.id == .custom ? L("其他（兼容 OpenAI）") : p.name }

    var body: some View {
        PillMenu(value: Self.title(settings.provider),
                 options: AIProvider.all.map { ($0.id.rawValue, $0.id == .ling ? "Ling" + L("（推荐）") : Self.title($0)) }) {
            guard $0 != settings.aiProvider else { return }
            settings.aiProvider = $0
            model.applyAIService()
        }
    }
}

/// A model menu: the recommended ones (with why) first, then everything the service lists, by
/// maker, then a name typed by hand.
struct ModelMenu: View {
    let value: String
    let recommended: [AIProvider.Model]
    let catalog: [String]
    let onPick: (String) -> Void
    @State private var typing = false
    @State private var typed = ""

    var body: some View {
        if typing {
            HStack(spacing: 6) {
                TextField(L("模型名"), text: $typed)
                    .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 8).frame(width: 220, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.line, lineWidth: 1))
                    .onSubmit(commit)
                SoftButton(L("好"), dark: true, action: commit)
                SoftButton(L("取消")) { typing = false }
            }
        } else {
            Menu {
                Section(L("推荐")) {
                    ForEach(recommended, id: \.id) { m in
                        Button(m.note.isEmpty ? m.id : "\(m.id)  ·  \(m.note)") { onPick(m.id) }
                    }
                }
                let rest = catalog.filter { id in !recommended.contains { $0.id == id } }
                if !rest.isEmpty {
                    Section(L("全部 \(rest.count) 个")) {
                        ForEach(groups(rest), id: \.0) { maker, ids in
                            Menu(maker) { ForEach(ids, id: \.self) { id in Button(id) { onPick(id) } } }
                        }
                    }
                }
                Divider()
                Button(L("填其他模型名…")) { typed = value; typing = true }
            } label: {
                HStack(spacing: 6) {
                    Text(value.isEmpty ? L("选一个") : value).font(.system(size: 13)).foregroundStyle(Palette.ink).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.secondary)
                }
                .padding(.horizontal, 10).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(Palette.ground))
                .contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        }
    }

    private func commit() {
        let t = typed.trimmingCharacters(in: .whitespaces)
        typing = false
        if !t.isEmpty { onPick(t) }
    }

    /// "openai/gpt-5-mini" → under "openai"; names without a maker go under "其他".
    private func groups(_ ids: [String]) -> [(String, [String])] {
        let other = L("其他")
        let by = Dictionary(grouping: ids) { $0.contains("/") ? String($0.prefix { $0 != "/" }) : other }
        return by.keys.sorted().map { ($0, by[$0]!.sorted()) }
    }
}

/// A labelled text field that saves on return or when it loses focus.
private struct CommitField: View {
    let label: String
    let placeholder: String
    let value: String
    let onCommit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 12)).foregroundStyle(Palette.secondary).frame(minWidth: 34, alignment: .leading).fixedSize()
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced))
                .padding(.horizontal, 12).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.white))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.line, lineWidth: 1))
                .focused($focused)
                .onSubmit { commit() }
                .onChange(of: focused) { _, now in if !now { commit() } }
        }
        .onAppear { text = value }
    }

    private func commit() {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t != value { onCommit(t) }
    }
}

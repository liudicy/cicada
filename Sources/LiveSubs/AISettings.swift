import AppKit
import SwiftUI

/// Settings › AI 服务: which provider translation and notes use (Ling or any OpenAI-compatible
/// endpoint the user adds), the provider keys, and the cloud speech proofreading.
struct AISettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var ling: LingClient
    @ObservedObject var settings: AppSettings
    @State private var draft = ""
    @State private var editing = false
    @State private var adding = false
    @State private var pName = ""
    @State private var pBase = ""
    @State private var pModel = ""
    @State private var asrDraft = ""
    @State private var asrEditing = false
    /// Re-read after saving/removing the cloud key (the key file is not observable).
    @State private var asrKey: String? = nil

    private var provider: AIProvider { model.activeAIProvider }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 1) Text AI first: pick a provider, paste its key, (Ling only) pick a model.
            sectionHeader(L("纪要和翻译"), detail: L("整句翻译和实时纪要都走这里选的服务商；不填 key 时翻译照常可用（Google、本机）"))
            providerCard
            keyCard
            if provider.isLing {
                SettingsCard {
                    SettingsRow(title: L("模型"), detail: L("3.1 更准；3.0 更快、更省"), divider: false) {
                        PillMenu(value: settings.aiModel, options: LingClient.models.map { ($0, $0) }) { settings.aiModel = $0 }
                    }
                }
                Text("一小时会议约 ¥0.15–1（目前优惠价）。发出去的只有文字（用你自己的声音时还有那段录音），语音识别留在本机。")
                    .font(.system(size: 12)).foregroundStyle(Palette.tertiary)
            } else {
                Text("发出去的只有文字（用你自己的声音时还有那段录音）；服务商的计费与隐私政策见其官网。")
                    .font(.system(size: 12)).foregroundStyle(Palette.tertiary)
            }
            // 2) Speech proofreading is an independent add-on with its own key.
            sectionHeader(L("语音识别校对"), detail: nil)
            cloudASRCard
            // 3) Last, the read-only summary: what each feature uses right now.
            sectionHeader(L("用在哪里"), detail: nil)
            SettingsCard {
                usageRow(L("实时纪要"), tag: ling.usable ? L("用 \(provider.name)") : L("需要 key"), on: ling.usable,
                         note: ling.usable ? L("会中每 45 秒更新") : L("在上面填好服务商 key 后可用"))
                usageRow(L("翻译"), tag: ling.usable ? provider.name : "Google", on: ling.usable,
                         note: ling.usable ? L("整句用选中的服务商；不行时换 Google、本机") : L("没有 key 时照常可用"))
                usageRow(L("语音识别"), tag: asrOn ? L("云端校对") : L("本机"), on: asrOn,
                         note: asrOn ? L("整句再请云端识别一遍，记录更准") : L("更快，不花钱"))
                SettingsRow(title: L("同声传译的声音"), detail: ling.speechCapable ? L("Ming 的声音或你自己的声音") : L("没有 Ling key 时用本机声音"),
                            divider: false) {
                    SoftButton(L("去选声音")) { model.settingsSection = .speak }
                }
            }
        }
    }

    private func sectionHeader(_ title: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.secondary)
            if let detail {
                Text(detail).font(.system(size: 12)).foregroundStyle(Palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 4)
    }

    private var asrOn: Bool { settings.cloudASREnabled && asrKey != nil }

    // MARK: Provider

    private var providerOptions: [(String, String)] {
        [("ling", "Ling")] + settings.aiProviders.map { ($0.id, $0.name) }
    }

    private var customIndex: Int? {
        provider.isLing ? nil : settings.aiProviders.firstIndex(where: { $0.id == provider.id })
    }

    private var providerCard: some View {
        SettingsCard {
            SettingsRow(title: L("服务商"), detail: L("纪要、翻译用选中的接口（OpenAI 兼容）"),
                        divider: adding || customIndex != nil) {
                HStack(spacing: 8) {
                    PillMenu(value: settings.aiActiveProvider, options: providerOptions) { model.setActiveProvider($0) }
                    SoftButton(L("添加")) { adding.toggle() }
                }
            }
            if adding {
                VStack(alignment: .leading, spacing: 8) {
                    field("名称，如 OpenAI", text: $pName)
                    field("接口地址，如 https://api.openai.com/v1", text: $pBase)
                    field("模型，如 gpt-4o-mini", text: $pModel)
                    HStack(spacing: 8) {
                        SoftButton(L("保存"), dark: true) {
                            let p = AIProvider(id: UUID().uuidString, name: pName.trimmingCharacters(in: .whitespaces),
                                               baseURL: pBase.trimmingCharacters(in: .whitespaces),
                                               model: pModel.trimmingCharacters(in: .whitespaces))
                            model.saveProvider(p)
                            pName = ""; pBase = ""; pModel = ""
                            adding = false
                        }
                        SoftButton(L("取消")) { adding = false }
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 14)
            }
            if let i = customIndex {
                VStack(alignment: .leading, spacing: 8) {
                    field(L("名称"), text: $settings.aiProviders[i].name)
                    field(L("接口地址"), text: $settings.aiProviders[i].baseURL)
                    field(L("模型"), text: $settings.aiProviders[i].model)
                    HStack {
                        Spacer()
                        Button(L("删除服务商")) { model.removeProvider(provider.id) }
                            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.error)
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 14)
            }
        }
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
            if let key = ling.key, !editing {
                HStack(spacing: 8) {
                    Text(AIKey.masked(key)).font(.system(size: 13, design: .monospaced)).foregroundStyle(Palette.ink)
                        .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line, lineWidth: 1))
                    SoftButton(L("更换")) { draft = ""; editing = true }
                    if case .invalid = ling.keyState {} else if case .unreachable = ling.keyState {
                        SoftButton(L("重试")) { Task { await ling.check() } }
                    }
                }
            } else {
                if ling.key == nil {
                    Text(provider.isLing
                         ? "在 Ling 开放平台点“创建令牌”，复制以 sk- 开头的那串。"
                         : "填入 \(provider.name) 的 API key。")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }
                HStack(spacing: 8) {
                    SecureField("sk-…", text: $draft)
                        .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced))
                        .padding(.horizontal, 12).frame(height: 36)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.ink.opacity(0.6), lineWidth: 1))
                        .onSubmit(save)
                    SoftButton(L("保存并检查"), dark: true, action: save)
                    if editing { SoftButton(L("取消")) { editing = false } }
                }
                if provider.isLing {
                    Button("打开 Ling 开放平台 ↗") {
                        if let url = URL(string: "https://chat.ant-ling.com/platform/api") { NSWorkspace.shared.open(url) }
                    }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "lock").font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                Text(provider.isLing
                     ? "只存在这台 Mac 上（只有你的账户能读），只发给 Ling（ant-ling.com）"
                     : "只存在这台 Mac 上（只有你的账户能读），只发给 \(provider.name)")
                    .font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                Spacer()
                if ling.key != nil && !editing {
                    Button("移除") { ling.removeKey() }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.secondary)
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(red: 0.961, green: 0.965, blue: 0.973)))
    }

    private func save() {
        let k = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        draft = ""
        editing = false
        Task { await ling.setKey(k) }
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
        case .none: L("还没填 API key")
        case .unchecked, .checking: L("正在检查…")
        case .ok: L("已连接")
        case .invalid: L("这个 key 用不了")
        case .unreachable: L("暂时连不上")
        }
    }

    private var statusDetail: String? {
        switch ling.keyState {
        case .ok(let s): L("\(provider.model) · 响应约 \(String(format: "%.1f", s)) 秒")
        case .invalid: L("\(provider.name) 提示此令牌无效，请检查是否复制完整，或重新创建一个")
        case .unreachable(let why): why
        case .none: L("不填 key 时，字幕和翻译仍可正常使用")
        default: nil
        }
    }

    private func usageRow(_ title: String, tag: String, on: Bool, note: String, divider: Bool = true) -> some View {
        SettingsRow(title: title, detail: note, divider: divider) {
            Text(tag).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(on ? Palette.ok : Palette.secondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(on ? Palette.okPale : Palette.fill))
        }
    }

    // MARK: Cloud speech proofreading

    private var cloudASRCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(L("云端语音识别校对")).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.ink)
                Spacer()
                Toggle("", isOn: $settings.cloudASREnabled).labelsHidden().toggleStyle(.switch)
            }
            Text("每句说完后，把这句的声音发给云端模型再识别一遍，用更准的文字替换记录里的原文并重译；实时字幕仍是本机识别。")
                .font(.system(size: 12)).foregroundStyle(Palette.secondary)
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
                field(L("接口地址"), text: $settings.cloudASRBase)
                field(L("模型"), text: $settings.cloudASRModel)
                HStack(spacing: 6) {
                    Image(systemName: "lock").font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                    Text("只发句子的录音（小米 MiMo 约 ¥0.5/小时）。key 只存在这台 Mac 上。")
                        .font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(red: 0.961, green: 0.965, blue: 0.973)))
        .onAppear { asrKey = model.cloudASR.key }
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced))
            .padding(.horizontal, 12).frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line, lineWidth: 1))
    }
}

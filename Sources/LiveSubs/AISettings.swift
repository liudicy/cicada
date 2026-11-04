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

    private var provider: AIProvider { model.activeAIProvider }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            providerCard
            keyCard
            Text("用在哪里").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.secondary)
                .padding(.top, 4)
            SettingsCard {
                usageRow(L("实时纪要"), tag: ling.usable ? L("用 \(provider.name)") : L("需要 key"), on: ling.usable,
                         note: ling.usable ? L("会中每 45 秒更新") : L("填好 key 后可用"))
                usageRow(L("翻译"), tag: ling.usable ? provider.name : "Google", on: ling.usable,
                         note: ling.usable ? L("整句用选中的服务商；不行时换 Google、本机") : L("没有 key 时照常可用"))
                usageRow(L("语音识别"), tag: L("本机"), on: false, note: L("更快，不花钱"))
                SettingsRow(title: L("同声传译的声音"), detail: ling.speechCapable ? L("Ming 的声音或你自己的声音") : L("没有 Ling key 时用本机声音"),
                            divider: false) {
                    SoftButton(L("去选声音")) { model.settingsSection = .speak }
                }
            }
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
        }
    }

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

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced))
            .padding(.horizontal, 12).frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line, lineWidth: 1))
    }
}

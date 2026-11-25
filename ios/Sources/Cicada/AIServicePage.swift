import SwiftUI

/// 设置 › AI 服务, as on the Mac and Android: Ling (recommended), OpenRouter, ZenMux, OpenAI or the
/// user's own OpenAI-compatible service. The settings are the Mac's (`aiProvider`, `aiModels`,
/// `aiVoiceModels`, `aiCustomBase`, Ling's model in `aiModel`), each service with its own key file.
/// The custom service here is the Mac's plain one: one address, a text model and optionally a speech
/// model; recognition stays on the phone, notes use the same server.
enum AIPrefs {
    static let provider = "aiProvider"
    static let models = "aiModels"
    static let voiceModels = "aiVoiceModels"
    static let customBase = "aiCustomBase"

    private static var d: UserDefaults { .standard }
    static var current: AIProvider { AIProvider.named(d.string(forKey: provider) ?? "ling") }
    static var modelMap: [String: String] { d.dictionary(forKey: models) as? [String: String] ?? [:] }
    static var voiceMap: [String: String] { d.dictionary(forKey: voiceModels) as? [String: String] ?? [:] }

    /// What `LingClient` calls with, as the Mac's `AppSettings.aiConfig`.
    static var config: AIConfig {
        let p = current
        switch p.id {
        case .ling:
            // Ming speaks 面对面 with the same key: without the voice model, every turn fell back to the phone's voice.
            return AIConfig(provider: p, base: p.base, textModel: d.string(forKey: Pref.model) ?? p.textModels.first?.id ?? "",
                            voiceModel: p.voiceModels.first?.id, voiceBase: p.base)
        case .custom:
            let base = AIProvider.customBase(d.string(forKey: customBase) ?? "")
            let voice = (voiceMap["custom"] ?? "").trimmingCharacters(in: .whitespaces)
            return AIConfig(provider: p, base: base, textModel: modelMap["custom"] ?? "",
                            voiceModel: voice.isEmpty ? nil : voice, voiceBase: base)
        default:
            return AIConfig(provider: p, base: p.base, textModel: modelMap[p.id.rawValue] ?? p.textModels.first?.id ?? "",
                            voiceModel: p.hasVoices ? voiceMap[p.id.rawValue] ?? p.voiceModels.first?.id : nil, voiceBase: p.base)
        }
    }

    /// 面对面's voices follow the service: Ming's with Ling, the speech model's with the others.
    static func applyVoices() {
        let c = config
        switch c.provider.id {
        case .ling: VoiceCatalog.service = .ming
        default:
            VoiceCatalog.service = c.hasVoices ? .cloud(label: c.provider.id == .custom ? L("自定义服务") : c.provider.name,
                                                        voices: c.provider.voices) : .none
        }
    }

    static func setModel(_ id: String, for p: AIProvider) {
        if p.id == .ling { d.set(id, forKey: Pref.model); return }
        var m = modelMap
        m[p.id.rawValue] = id
        d.set(m, forKey: models)
    }

    static func setVoiceModel(_ id: String, for p: AIProvider) {
        var m = voiceMap
        m[p.id.rawValue] = id
        d.set(m, forKey: voiceModels)
    }
}

struct AIServicePage: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var ling: LingClient
    @AppStorage(AIPrefs.provider) private var provider = "ling"
    @AppStorage(AIPrefs.customBase) private var base = ""
    @State private var customModel = AIPrefs.modelMap["custom"] ?? ""
    @State private var customVoice = AIPrefs.voiceMap["custom"] ?? ""
    @State private var tick = 0

    private var p: AIProvider { AIProvider.named(provider) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Card {
                    ForEach(Array(AIProvider.all.enumerated()), id: \.element.id) { i, s in
                        if i > 0 { Hairline() }
                        Button { pick(s) } label: { serviceRow(s) }.buttonStyle(RowPress())
                            .accessibilityAddTraits(s.id == p.id ? .isSelected : [])
                    }
                }
                .padding(.top, 12)

                if p.id == .custom {
                    SectionLabel(text: L("地址"))
                    Card {
                        TextField(text: $base) { Text(verbatim: "https://…/v1 · 192.168.1.20:8000/v1") }
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                            .padding(.horizontal, 16).frame(minHeight: 50)
                            .onSubmit { model.aiChanged() }
                    }
                    if !base.isEmpty, AIProvider.customBase(base) == nil {
                        Text("地址要用 https；这台手机和局域网里的服务可以用 http。")
                            .font(.footnote).foregroundStyle(Ink.accentText).padding(.horizontal, 4).padding(.top, 8)
                    }
                }

                SectionLabel(text: p.id == .custom ? L("Key（局域网里的服务可以不填）") : L("\(p.name) 的 key"))
                Card {
                    NavigationLink { KeyPage() } label: {
                        HStack(spacing: 8) {
                            // No key: the status beside it says so; this shows what a key looks like.
                            Text(verbatim: ling.key.map { $0.isEmpty ? L("不用 key") : AIKey.masked($0) } ?? "sk-…")
                                .font(.body.monospaced()).foregroundStyle(ling.key == nil ? Ink.secondary : Ink.ink).lineLimit(1)
                            Spacer()
                            KeyStatus(state: ling.keyState)
                            Chevron()
                        }
                        .padding(.horizontal, 16).frame(minHeight: 50).contentShape(Rectangle())
                    }
                    .buttonStyle(RowPress())
                }

                SectionLabel(text: L("模型"))
                Card {
                    if p.id == .custom {
                        field(L("翻译和纪要"), $customModel) { AIPrefs.setModel(customModel.trimmingCharacters(in: .whitespaces), for: p) }
                        Hairline()
                        field(L("声音模型"), $customVoice) { AIPrefs.setVoiceModel(customVoice.trimmingCharacters(in: .whitespaces), for: p) }
                    } else {
                        menu(L("翻译和纪要"), options: p.id == .ling ? LingClient.models : p.textModels.map(\.id), current: AIPrefs.config.textModel) {
                            AIPrefs.setModel($0, for: p)
                        }
                        if p.hasVoices && p.id != .ling, let v = AIPrefs.config.voiceModel {
                            Hairline()
                            menu(L("声音"), options: p.voiceModels.map(\.id), current: v) { AIPrefs.setVoiceModel($0, for: p) }
                        }
                    }
                }
                Text(p.clones ? L("填入 Ling key：声音更自然，还能用你自己的声音") : L("只有 Ling 能用你自己的声音"))
                    .font(.footnote).foregroundStyle(Ink.secondary).padding(.horizontal, 4).padding(.top, 10)
            }
            .padding(.horizontal, 16).padding(.bottom, 120)
            .frame(maxWidth: 640).frame(maxWidth: .infinity)
            .id(tick)
        }
        .background(Ink.ground)
        .navigationTitle(Text("AI 服务"))
        .onAppear { ling.recheckIfFailed() }
        .refreshable { await ling.check() }
        .navigationBarTitleDisplayMode(.inline)
    }

    private func serviceRow(_ s: AIProvider) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: s.name).foregroundStyle(Ink.ink)
            if s.id == .ling {
                Text("推荐").font(.caption2.weight(.semibold)).foregroundStyle(Ink.accentText)
                    .padding(.horizontal, 7).padding(.vertical, 2).background(Ink.accentWash, in: Capsule())
            }
            Spacer()
            if s.id == p.id { Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Ink.accentText) }
        }
        .padding(.horizontal, 16).frame(minHeight: 50).contentShape(Rectangle())
    }

    private func menu(_ title: String, options: [String], current: String, set: @escaping (String) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: title).foregroundStyle(Ink.ink)
            Spacer(minLength: 8)
            Menu {
                ForEach(options, id: \.self) { o in
                    Button { set(o); model.aiChanged(); tick += 1 } label: {
                        if o == current { Label(o, systemImage: "checkmark") } else { Text(verbatim: o) }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(verbatim: current).lineLimit(1).truncationMode(.head)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
                }
                .foregroundStyle(Ink.secondary)
            }
        }
        .padding(.horizontal, 16).frame(minHeight: 50)
    }

    private func field(_ title: String, _ text: Binding<String>, commit: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: title).foregroundStyle(Ink.ink)
            TextField(text: text) { Text("模型名") }
                .multilineTextAlignment(.trailing).foregroundStyle(Ink.secondary)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .onSubmit { commit(); model.aiChanged() }
        }
        .padding(.horizontal, 16).frame(minHeight: 50)
    }

    private func pick(_ s: AIProvider) {
        guard s.id != p.id else { return }
        provider = s.id.rawValue
        model.aiChanged()
        tick += 1
    }
}

extension LingClient {
    /// Opening AI 服务 after a failed check asks again: what was wrong may have been fixed on the
    /// service's side (a key's model list, its credit) without anything changing here.
    func recheckIfFailed() {
        switch keyState {
        case .invalid, .unreachable, .unchecked: Task { await check() }
        default: break
        }
    }
}

extension AppModel {
    /// The service, its address or a model changed: LingClient checks again and 面对面 takes the
    /// service's voices.
    func aiChanged() {
        AIPrefs.applyVoices()
        ling.reconfigure()
        debugLog("ai: service \(AIPrefs.config.provider.id.rawValue) model \(AIPrefs.config.textModel) voice \(AIPrefs.config.voiceModel ?? "-")")
        objectWillChange.send()
    }
}

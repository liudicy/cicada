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
    @State private var notesKeyDraft = ""
    @State private var editingNotesKey = false
    /// A pasted key that belongs elsewhere: what it is, and (for another service's key) where it fits.
    @State private var keyHint: (text: String, service: AIProvider.Kind?, key: String)?
    @State private var asrDraft = ""
    @State private var asrEditing = false
    /// Re-read after saving/removing the cloud key (the key file is not observable).
    @State private var asrKey: String? = nil

    private var provider: AIProvider { settings.provider }
    private var name: String { provider.name }
    /// Cloud speech proofreading runs when on-device recognition is active and a proofreading engine is ready.
    private var asrOn: Bool {
        settings.cloudASREnabled && !settings.aiConfig.transcribes
            && ((ling.usable && settings.serviceHearConfig != nil) || asrKey != nil)
    }

    /// Short summary of the active models shown beside 自己选模型 so bindings are visible at a glance.
    private var boundModelsSummary: String {
        let c = settings.aiConfig
        var parts = [c.textModel]
        if let v = c.voiceModel, !v.isEmpty { parts.append(v) }
        if let h = c.hearModel, !h.isEmpty { parts.append(h) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @State private var open: Set<String> = []

    var body: some View {
        if provider.id == .custom { customPage } else { servicePage }
    }

    private var servicePage: some View {
        VStack(alignment: .leading, spacing: 14) {
            keyCard
            if model.translationHealth.googleDown { translationCard }
            Text("现在能用的").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.secondary)
                .padding(.top, 4)
            SettingsCard { usage }
            Button { withAnimation(.easeOut(duration: 0.15)) { model.aiModelsOpen.toggle() } } label: {
                HStack(spacing: 6) {
                    Text("自己选模型")
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(model.aiModelsOpen ? 90 : 0))
                    Spacer(minLength: 8)
                    if !model.aiModelsOpen, !boundModelsSummary.isEmpty {
                        Text(boundModelsSummary)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Palette.tertiary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                .font(.system(size: 13)).foregroundStyle(Palette.secondary).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if model.aiModelsOpen { SettingsCard { models } }
            if !Recognition.cloudOnly, !settings.aiConfig.transcribes {
                Text("语音识别校对").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.secondary)
                    .padding(.top, 4)
                cloudASRCard
            }
            Text(footnote).font(.system(size: 12)).foregroundStyle(Palette.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { syncDrafts() }
        .onChange(of: settings.aiProvider) { _, _ in syncDrafts(); editing = false; draft = ""; keyHint = nil }
    }

    // MARK: Own service

    /// 其他（兼容 OpenAI）: one row per use, each at its own address if need be (a text model, a
    /// speech model and a recognition model often run as separate servers), each saying whether it
    /// works and how fast. Recognition stays on this Mac unless the user picks their service.
    private var customPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("每样可以接不同的机器；这台 Mac 和局域网里的服务可以用 http。")
                .font(.system(size: 12)).foregroundStyle(Palette.tertiary).fixedSize(horizontal: false, vertical: true)
            SettingsCard {
                textSection
                Divider()
                voiceSection
                Divider()
                hearSection
            }
            SettingsCard { onlyRow }
            HStack(spacing: 6) {
                Image(systemName: "lock").font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                Text(lockLine).font(.system(size: 11)).foregroundStyle(Palette.tertiary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                if let key = ling.key, !key.isEmpty {
                    Button("移除 key") { ling.removeKey() }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.secondary)
                }
            }
            if !Recognition.cloudOnly, !settings.aiConfig.transcribes {
                Text("语音识别校对").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.secondary)
                    .padding(.top, 4)
                cloudASRCard
            }
            Text(footnote).font(.system(size: 12)).foregroundStyle(Palette.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            syncDrafts()
            // A service that isn't set up yet, or doesn't work, opens where it needs filling in.
            if open.isEmpty, !ling.aiCheck.passed || ling.aiCheck.slow { open = ["text"] }
        }
        .onChange(of: settings.aiProvider) { _, _ in syncDrafts(); editing = false; draft = ""; keyHint = nil }
    }

    /// A row that opens to its fields: a state dot, the use, what it runs on, and how it's doing.
    private func sectionHeader(_ id: String, title: String, detail: String, dot: Color, trailing: String?,
                               trailingColor: Color = Palette.tertiary) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { if open.contains(id) { open.remove(id) } else { open.insert(id) } }
        } label: {
            HStack(spacing: 10) {
                Circle().fill(dot).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13)).foregroundStyle(Palette.ink)
                    Text(detail).font(.system(size: 11)).foregroundStyle(Palette.tertiary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing).font(.system(size: 12).monospacedDigit()).foregroundStyle(trailingColor).lineLimit(1).fixedSize()
                }
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.secondary)
                    .rotationEffect(.degrees(open.contains(id) ? 90 : 0))
            }
            .padding(.horizontal, 16).frame(minHeight: 52).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Under an address on the local network (not this Mac): macOS asks once before the first
    /// connection, and a "Don't Allow" there reads like a dead server.
    @ViewBuilder private func localNetworkNote(_ address: String) -> some View {
        // Once it said no, macOS won't ask again: the check's own line says what to do then.
        if !ling.aiCheck.needsLocalNetwork, let host = AIProvider.customBase(address)?.host,
           AIProvider.isNearby(host), !AIProvider.isLocal(host) {
            Text("局域网里的服务器：macOS 会问一次能否访问本地网络，点“允许”。")
                .font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                .fixedSize(horizontal: false, vertical: true).padding(.leading, 42)
        }
    }

    /// 语音和文字只发给你的服务: Google is never asked. The grey line says what it costs, and while
    /// the service can't be reached, what stands in (this Mac's translation, or the original only).
    private var onlyRow: some View {
        let on = settings.aiCustomOnly
        let failure = ling.aiCheck.failure
        let down = on && ling.hasKey && !ling.aiCheck.running && failure != nil && failure?.reason != .busy
        let detail = !down ? L("不用 Google 翻译；说话时要等整句说完才出译文")
            : Recognition.hasOnDeviceTranslation ? L("现在连不上：整句先用本机翻译，半句只显示原文")
            : L("现在连不上：新字幕暂时只有原文")
        return SettingsRow(title: L("语音和文字只发给你的服务"), detail: detail, divider: false) {
            Toggle("语音和文字只发给你的服务", isOn: Binding(get: { settings.aiCustomOnly }, set: {
                settings.aiCustomOnly = $0
                model.applyAIService()
            }))
            .toggleStyle(.switch).labelsHidden().controlSize(.small).tint(Palette.ink)
        }
    }

    /// Where the custom service's audio and text go: one host when every use shares it.
    private var customHosts: String {
        let c = settings.aiConfig
        var hosts = [c.base?.host]
        if c.notesApart { hosts.append(c.forNotes.base?.host) }
        if c.hasVoices { hosts.append(c.voiceBase?.host) }
        if c.transcribes { hosts.append(c.hearBase?.host) }
        var seen: [String] = []
        for h in hosts.compactMap({ $0 }) where !seen.contains(h) { seen.append(h) }
        if seen.count == 2 { return L("\(seen[0]) 和 \(seen[1])") }
        return seen.count == 1 ? seen[0] : L("你填的地址")
    }

    private var textHost: String { AIProvider.customBase(baseDraft)?.host ?? settings.aiConfig.base?.host ?? "" }

    /// "192.168.1.20 · qwen-mt-turbo", then the notes' model, or their own server after a bar.
    private var textDetail: String {
        let c = settings.aiConfig
        let model = settings.aiModels["custom"] ?? ""
        if textHost.isEmpty || model.isEmpty { return L("填上地址和模型") }
        let line = "\(textHost) · \(model)"
        guard c.notesApart else { return line }
        let n = c.forNotes
        if let host = n.base?.host, n.base != c.base { return line + " ｜ \(host) · \(n.textModel)" }
        return n.textModel == model ? line : line + " · \(n.textModel)"
    }

    @ViewBuilder private var textSection: some View {
        let check = ling.aiCheck
        let notesDown = check.failure == nil && check.notesFailed
        let trailing: String? = check.running ? L("正在检查…") : check.failure != nil && ling.hasKey ? statusTitle
            : notesDown ? L("纪要写不了")
            : check.translate.map { L("翻一句 \(String(format: "%.1f", $0.seconds)) 秒") }
        sectionHeader("text", title: L("翻译和纪要"), detail: textDetail, dot: customTextDot, trailing: trailing,
                      trailingColor: check.failure != nil || notesDown ? Palette.error : check.slow ? Palette.warn : Palette.tertiary)
        if open.contains("text") {
            VStack(alignment: .leading, spacing: 8) {
                groupTitle(L("翻译"))
                field(L("地址"), "http://192.168.1.20:8000/v1", $baseDraft)
                if !baseDraft.isEmpty, AIProvider.customBase(baseDraft) == nil {
                    Text("地址要用 https；这台 Mac 和局域网里的服务可以用 http。").font(.system(size: 11)).foregroundStyle(Palette.error)
                        .padding(.leading, 42)
                } else {
                    localNetworkNote(baseDraft)
                }
                HStack(spacing: 8) {
                    fieldLabel("key")
                    if let key = ling.key, !key.isEmpty, !editing {
                        maskedKey(key)
                        SoftButton(L("更换")) { draft = ""; editing = true }
                    } else {
                        SecureField(keyPlaceholder, text: $draft)
                            .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced))
                            .padding(.horizontal, 12).frame(height: 32)
                            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.line, lineWidth: 1))
                            .onSubmit(save)
                    }
                }
                if let hint = keyHint {
                    Text(hint.text).font(.system(size: 12)).foregroundStyle(Palette.error).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    fieldLabel(L("模型"))
                    // The models the service lists; a name it doesn't list can be typed. Picking saves and checks.
                    ModelPicker(value: textDraft, placeholder: L("例如 qwen3:14b"), catalog: ling.catalog, host: textHost,
                                refetch: { Task { await ling.fetchCatalog() } }) {
                        textDraft = $0
                        save()
                    }
                }
                Divider().padding(.vertical, 4)
                notesGroup
                HStack {
                    Spacer()
                    SoftButton(check.running ? L("正在检查…") : L("保存并检查"), dark: true, action: save)
                        .disabled(check.running)
                }
                if let slow = check.slowLine(googleOff: settings.aiCustomOnly) {
                    Text(slow).font(.system(size: 12)).foregroundStyle(Palette.warn).fixedSize(horizontal: false, vertical: true)
                }
                if showSteps {
                    AICheckSteps(model: model_, ling: ling, recheckInStep: false) { draft = ""; editing = true }
                        .padding(.horizontal, 12).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line, lineWidth: 1))
                } else if check.passed, settings.aiConfig.notesApart, let t = check.translate {
                    checkRows(t)
                } else if check.passed {
                    Text(textFacts).font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                }
            }
            .padding(.leading, 34).padding(.trailing, 16).padding(.bottom, 14)
        }
    }

    /// 纪要: the same service as translation (another model at most), or another one with its own
    /// address and key. Switching back keeps what was typed.
    @ViewBuilder private var notesGroup: some View {
        let c = settings.aiConfig
        let own = settings.aiCustomNotesOwn
        let notesHost = c.forNotes.base?.host ?? textHost
        // "给它单独填一个" only where a key of its own can be given (另一个服务).
        let shared = own && !ling.notesHasOwnKey
        HStack {
            groupTitle(L("纪要"))
            Spacer()
            Segments(options: [("same", L("同一个服务")), ("own", L("另一个服务"))], value: own ? "own" : "same") {
                settings.aiCustomNotesOwn = $0 == "own"
                model.applyAIService()
            }
        }
        if own {
            CommitField(label: L("地址"), placeholder: L("跟上面一样"), value: settings.aiCustomNotesBase) {
                settings.aiCustomNotesBase = $0
                model.applyAIService()
            }
            if c.notesBadAddress {
                Text("地址要用 https；这台 Mac 和局域网里的服务可以用 http。").font(.system(size: 11)).foregroundStyle(Palette.error)
                    .padding(.leading, 42)
            } else {
                localNetworkNote(settings.aiCustomNotesBase)
            }
            HStack(spacing: 8) {
                fieldLabel("key")
                if let key = ling.notesKey, ling.notesHasOwnKey, !key.isEmpty, !editingNotesKey {
                    maskedKey(key)
                    SoftButton(L("更换")) { notesKeyDraft = ""; editingNotesKey = true }
                    SoftButton(L("移除")) { ling.removeNotesKey() }
                } else {
                    SecureField(L("不填就用上面的 key"), text: $notesKeyDraft)
                        .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced))
                        .padding(.horizontal, 12).frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(
                            ling.aiCheck.notes?.reason == .invalidKey ? Palette.error : Palette.line, lineWidth: 1))
                        .onSubmit(save)
                }
            }
        }
        HStack(spacing: 8) {
            fieldLabel(L("模型"))
            ModelPicker(value: settings.aiModels["custom.notes"] ?? "", placeholder: L("和翻译模型一样"),
                        sameLabel: L("和翻译模型一样"),
                        catalog: c.forNotes.base != c.base ? ling.notesCatalog : ling.catalog, host: notesHost,
                        refetch: { Task { c.forNotes.base != c.base ? await ling.fetchNotesCatalog() : await ling.fetchCatalog() } }) {
                settings.aiModels["custom.notes"] = $0
                model.applyAIService()
            }
        }
        if let line = ling.aiCheck.notesLine(host: notesHost, model: c.forNotes.textModel, sharedKey: shared) {
            Text(line).font(.system(size: 12)).foregroundStyle(Palette.error)
                .fixedSize(horizontal: false, vertical: true).padding(.leading, 42)
        } else {
            Text("用来写实时纪要、识别说话人，默认和翻译用同一个").font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                .fixedSize(horizontal: false, vertical: true).padding(.leading, 42)
        }
    }

    /// After a check with notes apart: one row each, what it runs and how it did.
    private func checkRows(_ t: AICheck.Speed) -> some View {
        let c = settings.aiConfig
        let notes = ling.aiCheck.notes
        let notesText: String = switch notes {
        case .ok(let s)?: L("能写纪要 · \(String(format: "%.1f", s)) 秒")
        case .fail(.invalidKey, _)?, .fail(.mgmtKey, _)?: L("key 不对")
        case .fail(.noJSON, _)?: L("纪要写不了")
        case .fail?: L("纪要写不了")
        case .running?: L("正在检查…")
        case nil: ""
        }
        return VStack(spacing: 0) {
            checkRow(L("翻译"), c.textModel, ok: true,
                     L("翻一句 \(String(format: "%.1f", t.seconds)) 秒") + " · " + (t.thinks ? L("会先思考") : L("不思考")))
            Divider()
            checkRow(L("纪要"), c.forNotes.textModel, ok: notes?.reason == nil, notesText)
        }
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line, lineWidth: 1))
    }

    private func checkRow(_ use: String, _ model: String, ok: Bool, _ result: String) -> some View {
        HStack(spacing: 10) {
            Circle().fill(ok ? Palette.ok : Palette.error).frame(width: 6, height: 6)
            Text(use).font(.system(size: 12)).foregroundStyle(Palette.ink).frame(minWidth: 34, alignment: .leading).fixedSize()
            Text(model).font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.secondary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text(result).font(.system(size: 12).monospacedDigit()).foregroundStyle(ok ? Palette.ok : Palette.error).lineLimit(1).fixedSize()
        }
        .frame(minHeight: 36)
    }

    private func groupTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink).frame(height: 22)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Palette.secondary).frame(minWidth: 34, alignment: .leading).fixedSize()
    }

    private func maskedKey(_ key: String) -> some View {
        Text(AIKey.masked(key)).font(.system(size: 13, design: .monospaced)).foregroundStyle(Palette.ink)
            .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.line, lineWidth: 1))
    }

    private var model_: AppModel { model }

    /// "能写纪要 · 不思考": what the check proved beyond the speed.
    private var textFacts: String {
        var parts = [ling.aiCheck.failure == nil ? L("能写纪要") : L("纪要写不了")]
        if let t = ling.aiCheck.translate { parts.append(t.thinks ? L("会先思考") : L("不思考")) }
        return parts.joined(separator: " · ")
    }

    private var customTextDot: Color {
        let check = ling.aiCheck
        if !ling.hasKey { return Color(white: 0.75) }
        if check.running { return Palette.accent }
        if check.failure != nil { return Palette.error }
        if check.slow || check.busy || check.notesFailed { return Palette.warn }
        return check.passed ? Palette.ok : Color(white: 0.75)
    }

    @ViewBuilder private var voiceSection: some View {
        let c = settings.aiConfig
        let voiceModel = settings.aiVoiceModels["custom"] ?? ""
        let host = c.voiceBase?.host ?? textHost
        let detail = voiceModel.isEmpty ? L("没填，用本机声音")
            : [host, voiceModel, settings.aiCustomVoice].filter { !$0.isEmpty }.joined(separator: " · ")
        let last = ling.lastVoice
        sectionHeader("voice", title: L("同传声音"), detail: detail,
                      dot: voiceModel.isEmpty ? Color(white: 0.75) : last.map { $0.ok ? Palette.ok : Palette.error } ?? Color(white: 0.75),
                      trailing: voiceModel.isEmpty ? L("本机") : last.map { $0.ok ? L("上次正常") : L("上次没出声") },
                      trailingColor: last?.ok == false ? Palette.error : Palette.tertiary)
        if open.contains("voice") {
            VStack(alignment: .leading, spacing: 8) {
                Text("需支持 /audio/speech；不填则用本机声音。").font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                CommitField(label: L("模型"), placeholder: L("例如 qwen3-tts"), value: voiceModel) {
                    settings.aiVoiceModels["custom"] = $0
                    model.applyAIService()
                }
                CommitField(label: L("声音"), placeholder: L("例如 vivian"), value: settings.aiCustomVoice) {
                    settings.aiCustomVoice = $0
                    model.applyAIService()
                }
                CommitField(label: L("地址"), placeholder: L("跟上面一样"), value: settings.aiCustomVoiceBase) {
                    settings.aiCustomVoiceBase = $0
                    model.applyAIService()
                }
                localNetworkNote(settings.aiCustomVoiceBase)
            }
            .padding(.leading, 34).padding(.trailing, 16).padding(.bottom, 14)
        }
    }

    @ViewBuilder private var hearSection: some View {
        let c = settings.aiConfig
        let own = settings.aiCustomRecognize
        let hearModel = settings.aiCustomHearModel
        let host = (settings.aiCustomHearBase.isEmpty ? c.base : AIProvider.customBase(settings.aiCustomHearBase))?.host ?? textHost
        let hear = ling.aiCheck.hear
        HStack(spacing: 10) {
            Circle().fill(!own ? Palette.ok : hear?.ok == true ? Palette.ok : hear == nil ? Color(white: 0.75) : Palette.error)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text("语音识别").font(.system(size: 13)).foregroundStyle(Palette.ink)
                Text(own ? L("会议的声音会发到 \(host)；连不上时用本机") : L("更快，不花钱，声音不出这台 Mac"))
                    .font(.system(size: 11)).foregroundStyle(Palette.tertiary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Segments(options: [("mac", L("本机")), ("own", L("自建服务"))], value: own ? "own" : "mac") {
                settings.aiCustomRecognize = $0 == "own"
                if $0 == "own" { open.insert("hear") }
                model.applyAIService()
            }
        }
        .padding(.horizontal, 16).frame(minHeight: 52)
        if own {
            VStack(alignment: .leading, spacing: 8) {
                Text("需支持 /audio/transcriptions，例如 Qwen3-ASR、Whisper。下一场会议起生效。")
                    .font(.system(size: 11)).foregroundStyle(Palette.tertiary).fixedSize(horizontal: false, vertical: true)
                CommitField(label: L("模型"), placeholder: L("例如 qwen3-asr"), value: hearModel) {
                    settings.aiCustomHearModel = $0
                    model.applyAIService()
                }
                CommitField(label: L("地址"), placeholder: L("跟上面一样"), value: settings.aiCustomHearBase) {
                    settings.aiCustomHearBase = $0
                    model.applyAIService()
                }
                localNetworkNote(settings.aiCustomHearBase)
                if hearModel.isEmpty {
                    Text("填上模型才会用它识别。").font(.system(size: 12)).foregroundStyle(Palette.warn)
                } else if let line = ling.aiCheck.hearLine(host: host, model: hearModel) {
                    Text(line).font(.system(size: 12)).foregroundStyle(Palette.error).fixedSize(horizontal: false, vertical: true)
                    if hear == .localNetworkDenied {
                        HStack(spacing: 8) {
                            SoftButton(L("打开系统设置"), dark: true) { model.openLocalNetworkSettings() }
                            SoftButton(L("重新检查")) { Task { await ling.check() } }
                        }
                    }
                } else if case .ok(let s)? = hear {
                    Text(L("听一秒音频 \(String(format: "%.1f", s)) 秒")).font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                }
            }
            .padding(.leading, 34).padding(.trailing, 16).padding(.bottom, 14)
        }
    }

    // MARK: Translation

    /// Shown only while the translation behind live subtitles can't be reached. No provider names:
    /// with a key it costs only the half-sentence preview, without one the subtitles themselves.
    private var translationCard: some View {
        let health = model.translationHealth
        return SettingsCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle().fill(Palette.error).frame(width: 8, height: 8)
                    Text("翻译连不上").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.ink)
                    Spacer()
                }
                Text(health.sentencesUntranslated ? L("新字幕暂时只有原文，连上后自动继续。")
                                                  : L("说话时的字幕要等说完一句才有翻译。"))
                    .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let line = Self.proxyLine(health.proxy) {
                    Text(line).font(.system(size: 12)).foregroundStyle(Palette.body)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.fill))
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    SoftButton(L("怎么设置代理"), dark: true) { NSWorkspace.shared.open(ProxyProbe.helpURL) }
                }
                .padding(.top, 2)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    static func proxyLine(_ proxy: AICheck.ProxyHint?) -> String? {
        guard let proxy else { return nil }
        return switch proxy {
        case .systemOn: L("开了代理也连不上：换一个节点，或让代理软件放过 translate.googleapis.com。")
        // As text: a number would be grouped ("7,890").
        case .appRunning(let port): L("代理软件在运行（端口 \(String(port))），但没开系统代理。在代理软件里打开“系统代理”。")
        case .none: L("这台电脑没开代理。在国内通常要开代理才能翻译。")
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
            if let key = ling.key, !key.isEmpty, !editing {
                HStack(spacing: 8) {
                    Text(AIKey.masked(key)).font(.system(size: 13, design: .monospaced)).foregroundStyle(Palette.ink)
                        .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line, lineWidth: 1))
                    SoftButton(L("更换")) { draft = ""; editing = true }
                    SoftButton(ling.aiCheck.running ? L("正在检查…") : L("重新检查")) { Task { await ling.check() } }
                        .disabled(ling.aiCheck.running)
                }
                if showSteps {
                    AICheckSteps(model: model, ling: ling, recheckInStep: false) { draft = ""; editing = true }
                        .padding(.horizontal, 12).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line, lineWidth: 1))
                }
                if let low = ling.aiCheck.balanceLine(service: name) {
                    HStack(spacing: 8) {
                        Text(low).font(.system(size: 12)).foregroundStyle(Palette.warn)
                        Spacer()
                        SoftButton(L("去充值")) { NSWorkspace.shared.open(AICheckSteps.topUp(provider)) }
                    }
                    .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(Palette.warnPale))
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
                    if editing { SoftButton(L("取消")) { editing = false; keyHint = nil } }
                }
                if let hint = keyHint {
                    HStack(spacing: 8) {
                        Text(hint.text).font(.system(size: 12)).foregroundStyle(Palette.error)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        if let other = hint.service {
                            SoftButton(L("改用 \(AIProvider.named(other.rawValue).name)"), dark: true) {
                                let k = hint.key
                                keyHint = nil
                                editing = false
                                model.switchService(other, key: k)
                            }
                        }
                    }
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
        case .custom: AIProvider.isNearby(baseDraft) ? L("本机和局域网服务可不填") : "sk-…"
        default: "sk-…"
        }
    }

    private var lockLine: String {
        let host = provider.id == .custom ? keyHosts : (provider.base?.host ?? "")
        return provider.id == .custom ? L("key 只存在这台 Mac 上（只有你的账户能读），只发给 \(host)")
            : L("只存在这台 Mac 上（只有你的账户能读），只发给 \(name)（\(host)）")
    }

    /// Where the custom service's key is sent: every use's address, the notes' only while they share it.
    private var keyHosts: String {
        let c = settings.aiConfig
        var hosts = [c.base?.host]
        if c.notesApart, !ling.notesHasOwnKey { hosts.append(c.forNotes.base?.host) }
        if c.hasVoices { hosts.append(c.voiceBase?.host) }
        if c.transcribes { hosts.append(c.hearBase?.host) }
        var seen: [String] = []
        for h in hosts.compactMap({ $0 }) where !seen.contains(h) { seen.append(h) }
        if seen.count == 2 { return L("\(seen[0]) 和 \(seen[1])") }
        return seen.count == 1 ? seen[0] : L("你填的地址")
    }

    /// Saves what was typed (a custom service's address and model too), then checks.
    private func save() {
        if provider.id == .custom {
            settings.aiCustomBase = baseDraft.trimmingCharacters(in: .whitespaces)
            settings.aiModels["custom"] = textDraft.trimmingCharacters(in: .whitespaces)
            model.applyAIService()
            // Notes' own key (另一个服务): saved here too; it goes only to the notes' address.
            let nk = notesKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            if !nk.isEmpty, settings.aiCustomNotesOwn {
                notesKeyDraft = ""
                editingNotesKey = false
                Task { await ling.setNotesKey(nk) }
            }
        }
        let k = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        keyHint = nil
        // The prefix says whose key it is: a management key can't call models, and another
        // service's key goes there with one click (never a silent switch).
        if let owner = AICheck.owner(ofKey: k) {
            if owner.management {
                keyHint = (L("这是 ZenMux 的管理 key，不能用来调用模型。请粘贴 sk-payg 开头的 key。"), nil, "")
                return
            }
            if owner.service != provider.id {
                keyHint = (L("这是 \(AIProvider.named(owner.service.rawValue).name) 的 key。"), owner.service, k)
                return
            }
        }
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

    /// The steps show while something is wrong or being checked; all passed folds into the title line.
    private var showSteps: Bool {
        let c = ling.aiCheck
        return c.running || c.failure != nil || c.busy || (c.at != nil && !c.passed)
    }

    private var statusColor: Color {
        if ling.aiCheck.busy, ling.aiCheck.failure == nil { return Palette.warn }
        return switch ling.keyState {
        case .ok: Palette.ok
        case .invalid, .unreachable: Palette.error
        case .checking, .unchecked: Palette.accent
        case .none: Color(white: 0.75)
        }
    }

    private var statusTitle: String {
        // Named after the step that failed: a missing model is not a connection problem.
        if let f = ling.aiCheck.failure, f.reason != .busy, !ling.aiCheck.running {
            switch f.step {
            case .reach: return ling.aiCheck.localNetworkDenied ? L("没有本地网络权限") : L("暂时连不上")
            case .key: return L("这个 key 用不了")
            case .text: return L("模型用不了")
            }
        }
        return switch ling.keyState {
        case .none: provider.id == .custom ? L("还没填好") : L("还没填 API key")
        case .unchecked, .checking: L("正在检查…")
        case .ok: L("已连接")
        case .invalid: L("这个 key 用不了")
        case .unreachable: L("暂时连不上")
        }
    }

    private var statusDetail: String? {
        switch ling.keyState {
        case .ok(let s): ling.aiCheck.busy ? L("\(name) 现在很忙") : AICheckSummary.text(ling.aiCheck).map { "\(settings.textModel) · \($0)" }
            ?? L("\(settings.textModel) · 响应约 \(String(format: "%.1f", s)) 秒")
        case .invalid, .unreachable: nil
        case .none: Recognition.cloudOnly ? L("填入 Ling key 后才能识别语音、出字幕和纪要") : L("不填 key 时，字幕和翻译仍可正常使用")
        default: nil
        }
    }

    // MARK: What works

    /// Only what the last result supports: when the service can't be reached (or the key fails)
    /// nothing says "用 ZenMux" in green.
    @ViewBuilder private var usage: some View {
        let reason = ling.aiCheck.failure?.reason
        let down = ling.hasKey && [.unreachable, .badAddress, .invalidKey, .mgmtKey, .noCredit].contains(reason)
        let on = ling.usable && !down
        let textOn = on && reason != .noModel
        let notesOn = textOn && reason != .noJSON
        let uses = L("用 \(name)")
        let later = down ? (reason == .unreachable ? L("连上 \(name) 后可用") : L("换好 key 后可用")) : L("填好 key 后可用")
        if notesOn, ling.aiCheck.busy {
            usageRow(L("实时纪要"), tag: L("很忙"), style: .warn, note: L("会自动重试，纪要可能晚一点"))
        } else {
            usageRow(L("实时纪要"), tag: notesOn ? uses : ling.hasKey ? L("暂不可用") : L("需要 key"), style: notesOn ? .ok : .off,
                     note: notesOn ? L("会中每 45 秒更新") : reason == .noJSON ? L("这个服务不支持 JSON") : reason == .noModel ? L("换一个模型后可用") : later)
        }
        if Recognition.cloudOnly {
            usageRow(L("翻译"), tag: textOn ? uses : ling.hasKey ? L("暂不可用") : L("需要 key"), style: textOn ? .ok : .off,
                     note: textOn ? L("随语音识别一步翻出；不行时换 Google") : later)
        } else if !textOn, model.translationHealth.googleDown {
            usageRow(L("翻译"), tag: L("连不上"), style: .warn, note: L("填好 key 后用 \(name) 翻译"))
        } else {
            usageRow(L("翻译"), tag: textOn ? uses : "Google", style: textOn ? .ok : .off,
                     note: textOn ? (Recognition.hasOnDeviceTranslation ? L("整句用它；不行时换 Google、本机") : L("整句用它；不行时换 Google"))
                                  : ling.hasKey ? L("先用 Google 翻译") : L("没有 key 时照常可用"))
        }
        if !Recognition.cloudOnly {
            let fixOn = textOn && settings.fixMisheard
            usageRow(L("改正听错的词"), tag: fixOn ? uses : textOn ? L("已关") : ling.hasKey ? L("暂不可用") : L("需要 key"),
                     style: fixOn ? .ok : .off,
                     note: fixOn ? L("随翻译一起发，几乎不多花") : textOn ? L("在“词表”里打开") : later)
        }
        let speaks = ling.speaks && !down
        usageRow(L("同传声音"), tag: speaks ? uses : L("本机"), style: speaks ? .ok : .off, note: voiceNote(down: down))
        if provider.clones {
            usageRow(L("你自己的声音"), tag: on ? uses : ling.hasKey ? L("暂不可用") : L("需要 key"), style: on ? .ok : .off,
                     note: on ? L("录一段，让对方听到你的音色") : later)
        } else {
            usageRow(L("你自己的声音"), tag: L("只有 Ling"), style: .ling, note: L("换用 Ling 才有"))
        }
        if Recognition.cloudOnly {
            if provider.hearsAudio || provider.hasHearing {
                usageRow(L("语音识别"), tag: on ? uses : ling.hasKey ? L("暂不可用") : L("需要 key"), style: on ? .ok : .off,
                         note: on ? (provider.hearsAudio ? L("识别和翻译一步完成") : (settings.aiConfig.hearModel ?? "")) : later, divider: false)
            } else {
                usageRow(L("语音识别"), tag: L("只有 Ling"), style: .ling, note: L("换用 Ling 才有"), divider: false)
            }
        } else if provider.id == .stepfun, provider.hasHearing {
            SettingsRow(title: L("语音识别"),
                        detail: settings.stepfunRecognize ? L("会议的声音会发给 \(name) 识别；连不上时用本机") : L("更快，不花钱，声音不出这台 Mac"),
                        divider: false) {
                Segments(options: [("mac", L("本机")), ("cloud", name)], value: settings.stepfunRecognize ? "cloud" : "mac") {
                    settings.stepfunRecognize = $0 == "cloud"
                    model.applyAIService()
                }
            }
        } else {
            usageRow(L("语音识别"), tag: asrOn ? L("云端校对") : L("本机"), style: asrOn ? .ok : .off,
                     note: asrOn ? L("整句再请云端识别一遍，记录更准") : L("更快，不花钱"), divider: false)
        }
    }

    private func voiceNote(down: Bool) -> String {
        if down { return L("先用本机声音") }
        if ling.speaks {
            if let last = ling.lastVoice { return last.ok ? L("上次同传时正常") : L("上次同传没出声，用了本机声音") }
            return provider.id == .ling ? L("Ming 的声音") : (settings.aiConfig.voiceModel ?? "")
        }
        if !ling.usable { return L("没有 key 时用本机声音") }
        return provider.id == .custom ? L("没填声音模型，用本机声音") : L("\(name) 暂不能出声音，用本机声音")
    }

    private enum TagStyle { case ok, off, ling, warn }

    private func usageRow(_ title: String, tag: String, style: TagStyle, note: String, divider: Bool = true) -> some View {
        SettingsRow(title: title, detail: note, divider: divider) {
            Text(tag).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(style == .ok ? Palette.ok : style == .ling ? Palette.accentInk : style == .warn ? Palette.warn : Palette.secondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(style == .ok ? Palette.okPale : style == .ling ? Palette.accentPale
                                                                    : style == .warn ? Palette.warnPale : Palette.fill))
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
        default:
            SettingsRow(title: L("文字模型"), detail: L("纪要和整句翻译"), divider: provider.hasVoices || provider.hasHearing) {
                ModelMenu(value: settings.textModel, recommended: provider.textModels, catalog: ling.catalog) {
                    settings.aiModels[provider.id.rawValue] = $0
                    model.applyAIService()
                }
            }
            if provider.hasVoices {
                SettingsRow(title: L("声音模型"), detail: L("同传念给对方"), divider: provider.hasHearing) {
                    ModelMenu(value: settings.aiConfig.voiceModel ?? "", recommended: provider.voiceModels, catalog: []) {
                        settings.aiVoiceModels[provider.id.rawValue] = $0
                        model.applyAIService()
                    }
                }
            }
            if provider.hasHearing {
                SettingsRow(title: L("语音识别模型"), detail: L("把会议声音转成文字"), divider: false) {
                    ModelMenu(value: settings.aiHearModels[provider.id.rawValue] ?? provider.hearModels.first?.id ?? "",
                              recommended: provider.hearModels, catalog: []) {
                        settings.aiHearModels[provider.id.rawValue] = $0
                        model.applyAIService()
                    }
                }
            }
        }
    }

    // MARK: Cloud speech proofreading

    /// Fork addition: after each sentence finishes on-device, its audio is re-recognized by a cloud
    /// model and the more accurate text replaces the transcript. Reuses the active AI service's ASR
    /// when it has one (e.g. StepFun Plan); otherwise configures a standalone endpoint (preset: MiMo).
    private var cloudASRCard: some View {
        SettingsCard {
            if let hear = settings.serviceHearConfig {
                SettingsRow(title: L("云端校对"),
                            detail: L("实时字幕走本机，每句说完用 \(hear.name)（\(hear.model)）校对记录；共用上方 key"),
                            divider: false) {
                    Toggle("", isOn: $settings.cloudASREnabled).labelsHidden().toggleStyle(.switch)
                }
            } else {
                SettingsRow(title: L("云端校对"),
                            detail: L("每句说完后用云端模型再识别一遍并重译，实时字幕仍走本机"),
                            divider: settings.cloudASREnabled) {
                    Toggle("", isOn: $settings.cloudASREnabled).labelsHidden().toggleStyle(.switch)
                }
                if settings.cloudASREnabled {
                    VStack(alignment: .leading, spacing: 10) {
                        if let key = asrKey, !asrEditing {
                            HStack(spacing: 8) {
                                Text(AIKey.masked(key)).font(.system(size: 13, design: .monospaced)).foregroundStyle(Palette.ink)
                                    .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                                    .background(RoundedRectangle(cornerRadius: 9).fill(Palette.ground))
                                SoftButton(L("更换")) { asrDraft = ""; asrEditing = true }
                                Button("移除") { model.cloudASR.removeKey(); asrKey = nil }
                                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.secondary)
                            }
                        } else {
                            HStack(spacing: 8) {
                                SecureField("API key", text: $asrDraft)
                                    .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced))
                                    .padding(.horizontal, 12).frame(height: 34)
                                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.white))
                                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.ink.opacity(0.6), lineWidth: 1))
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
                    .padding(16)
                }
            }
        }
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
        if Recognition.cloudOnly, provider.id != .custom {
            return L("一小时会议约 ¥0.15–1（目前优惠价）。说话的声音分段发给 Ling 识别和翻译；会议录音和文字记录只存在这台 Mac 上。")
        }
        switch provider.id {
        case .ling: return L("一小时会议约 ¥0.15–1（目前优惠价）。发出去的只有文字（用你自己的声音时还有那段录音），语音识别留在本机。")
        case .stepfun:
            return settings.aiConfig.transcribes
                ? L("按 Step Plan 套餐额度计费。会议的声音和文字会发给 StepFun；录音和文字记录只存在这台 Mac 上。")
                : L("按 Step Plan 套餐额度计费。发出去的只有文字，语音识别留在本机。")
        case .custom:
            let nearby = settings.aiConfig.base.map { AIProvider.isNearby($0.absoluteString) } ?? false
            let cost = nearby ? L("跑在你自己的机器上，不按量计费。") : L("费用以这个服务为准。")
            if settings.aiCustomOnly { return cost + L("会议的语音和文字只发给 \(customHosts)，不经过 Google 等外部服务。") }
            return cost + (settings.aiConfig.transcribes ? L("会议的声音会发给你的服务识别。") : L("发出去的只有文字，语音识别留在本机。"))
        default: return L("按所选模型计费。发出去的只有文字，语音识别留在本机。")
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
                if !recommended.isEmpty {
                    Section(L("推荐")) {
                        ForEach(recommended, id: \.id) { m in
                            Button(m.note.isEmpty ? m.id : "\(m.id)  ·  \(m.note)") { onPick(m.id) }
                        }
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

/// A custom service's model: the names its `/models` lists, searchable, and any name typed that it
/// doesn't list (an alias, a model it hides). Without a list it is a plain field.
struct ModelPicker: View {
    let value: String
    let placeholder: String
    /// A first choice that clears the value ("和翻译模型一样"); nil: none.
    var sameLabel: String? = nil
    let catalog: [String]
    /// The address the list came from, for the line under it.
    let host: String
    let refetch: () -> Void
    let onPick: (String) -> Void
    @State private var open = false
    @State private var query = ""
    @State private var typed = ""
    @FocusState private var focused: Bool

    var body: some View {
        if catalog.isEmpty {
            HStack(spacing: 8) {
                TextField(sameLabel ?? placeholder, text: $typed)
                    .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced))
                    .padding(.horizontal, 12).frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.white))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.line, lineWidth: 1))
                    .focused($focused)
                    .onSubmit(commitTyped)
                    .onChange(of: focused) { _, now in if !now { commitTyped() } }
                    .help(L("这个地址没列出模型，直接填名字"))
                if !host.isEmpty { SoftButton(L("重新获取"), action: refetch) }
            }
            .onAppear { typed = value }
            .onChange(of: value) { _, v in typed = v }
        } else {
            Button { query = ""; open = true } label: {
                HStack(spacing: 6) {
                    Text(value.isEmpty ? (sameLabel ?? L("选一个")) : value)
                        .font(value.isEmpty ? .system(size: 13) : .system(size: 13, design: .monospaced))
                        .foregroundStyle(value.isEmpty ? Palette.secondary : Palette.ink).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.secondary)
                }
                .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 32)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.white))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(open ? Palette.ink : Palette.line, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $open, arrowEdge: .bottom) { list }
        }
    }

    private var matches: [String] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? catalog : catalog.filter { $0.localizedCaseInsensitiveContains(q) }
    }

    private var list: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                TextField(L("搜索或输入模型"), text: $query)
                    .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                    .onSubmit {
                        // Return: the only match, else exactly what was typed.
                        let m = matches
                        if m.count == 1 { pick(m[0]) } else if !q.isEmpty { pick(q) }
                    }
            }
            .padding(.horizontal, 10).frame(height: 32)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !q.isEmpty, !catalog.contains(q) {
                        row(L("用 \(q)（列表里没有）"), selected: false, mono: false) { pick(q) }
                        Divider().padding(.vertical, 4)
                    }
                    if let sameLabel, q.isEmpty {
                        row(sameLabel, selected: value.isEmpty, mono: false) { pick("") }
                        Divider().padding(.vertical, 4)
                    }
                    ForEach(matches, id: \.self) { id in row(id, selected: id == value, mono: true) { pick(id) } }
                }
                .padding(4)
            }
            .frame(maxHeight: 280)
            Divider()
            HStack {
                Text(L("\(host) 列出 \(catalog.count) 个模型")).font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                Spacer()
                Button(L("重新获取"), action: refetch).buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.link)
            }
            .padding(.horizontal, 10).frame(height: 28)
        }
        .frame(width: 320)
    }

    private func row(_ text: String, selected: Bool, mono: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).opacity(selected ? 1 : 0)
                Text(text).font(mono ? .system(size: 12, design: .monospaced) : .system(size: 12)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 8).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Palette.fill : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func pick(_ id: String) {
        open = false
        if id != value { onPick(id) }
    }

    private func commitTyped() {
        let t = typed.trimmingCharacters(in: .whitespaces)
        if t != value { onPick(t) }
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

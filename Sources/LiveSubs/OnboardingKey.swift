import AppKit
import SwiftUI

/// Onboarding step 3: connect a Ling key. Notes, Ling translation and Ming voices all need it, but it
/// comes after the sample video, once people have seen what the app does. Skipping is allowed: "先不接"
/// first shows what still works and what waits for a key (the notes window asks again later).
/// Ling is the whole path; "用不了 Ling？" opens another service as a way out, saying what it lacks.
struct OnboardingKeyStep: View {
    @ObservedObject var model: AppModel
    @ObservedObject var ling: LingClient
    @ObservedObject var settings: AppSettings
    /// "先不接" was clicked: the card shows what skipping leaves out until 回去接上 or 好，先这样.
    @Binding var skipping: Bool
    @State private var draft = ""
    @State private var clipboardEmpty = false
    /// Showing another service instead of Ling: follows the setting, so a change made in Settings
    /// while this step is open (or a reused window) never leaves the Ling title over another service.
    private var other: Bool { settings.provider.id != .ling }

    private static let others: [AIProvider] = [.openrouter, .zenmux, .openai]

    static let platform = URL(string: "https://chat.ant-ling.com/platform/api")!

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if other && !skipping {
                VStack(alignment: .leading, spacing: 8) {
                    Text("用其他服务").font(.system(size: 26, weight: .bold)).foregroundStyle(Palette.ink)
                    Text("纪要和翻译都能用，模型已经选好。").font(.system(size: 14)).foregroundStyle(Palette.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("接上 Ling，一个 key 用上全部功能").font(.system(size: 26, weight: .bold)).foregroundStyle(Palette.ink)
                    HStack(spacing: 6) {
                        ForEach([L("实时纪要"), L("更准的翻译"), L("自然的同传声音"), L("用你自己的声音")], id: \.self) { item in
                            Text("✓ " + item).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ok)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Palette.okPale))
                        }
                    }
                }
            }
            if case .ok = ling.keyState { connected } else if skipping { withoutKey } else if other { otherEntry } else { entry }
            if !skipping, !isConnected {
                HStack(spacing: 10) {
                    if other {
                        Button(L("‹ 还是用 Ling")) { switchTo(.ling) }.buttonStyle(.plain)
                            .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    } else {
                        Text("Ling 每月赠送 ¥10 额度").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.accentInk)
                            .padding(.horizontal, 9).padding(.vertical, 3)
                            .background(Capsule().fill(Palette.accentPale))
                        Text("约够 10–50 小时会议")
                            .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                        Spacer()
                        Button(L("用不了 Ling？")) { switchTo(.openrouter) }.buttonStyle(.plain)
                            .font(.system(size: 12)).foregroundStyle(Palette.secondary).underline()
                    }
                }
            }
        }
    }

    private var isConnected: Bool { if case .ok = ling.keyState { true } else { false } }

    private func switchTo(_ p: AIProvider) {
        draft = ""
        clipboardEmpty = false
        guard settings.aiProvider != p.id.rawValue else { return }
        settings.aiProvider = p.id.rawValue
        model.applyAIService()
    }

    // MARK: Another service

    private var otherEntry: some View {
        let p = settings.provider
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Segments(options: Self.others.map { ($0.id.rawValue, $0.name) }, value: p.id.rawValue) { id in
                    switchTo(AIProvider.named(id))
                }
                Spacer()
                if let site = p.site {
                    Button { NSWorkspace.shared.open(site) } label: {
                        HStack(spacing: 5) {
                            Text(L("打开 \(p.name)"))
                            Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
                        }
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                        .padding(.horizontal, 14).frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Palette.fill))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            keyField(placeholder: L("粘贴 \(p.name) 的 key"))
            status
            HStack(spacing: 4) {
                Text("少了：").foregroundStyle(Palette.secondary)
                Text(p.hasVoices ? L("用你自己的声音") : L("自然的同传声音、你自己的声音")).fontWeight(.semibold).foregroundStyle(Palette.ink)
                Text("（只有 Ling 支持）").foregroundStyle(Palette.secondary)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Palette.raised))
        }
        .padding(22)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.line, lineWidth: 1))
    }

    // MARK: Not connected yet

    private var entry: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                number(1)
                VStack(alignment: .leading, spacing: 2) {
                    Text("在 Ling 开放平台创建 key").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink)
                    Text("国内直接注册，不用代理；登录后点“创建令牌”").font(.system(size: 12)).foregroundStyle(Palette.tertiary)
                }
                Spacer()
                Button { NSWorkspace.shared.open(Self.platform) } label: {
                    HStack(spacing: 5) {
                        Text("打开 Ling 开放平台")
                        Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
                    }
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                    .padding(.horizontal, 14).frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Palette.fill))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 18)
            Divider()
            HStack(alignment: .top, spacing: 14) {
                number(2)
                VStack(alignment: .leading, spacing: 10) {
                    Text("复制 sk- 开头的 key，回来粘贴").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink)
                    keyField(placeholder: "sk-…")
                    status
                }
            }
            .padding(.top, 18)
        }
        .padding(22)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.line, lineWidth: 1))
    }

    @ViewBuilder private var status: some View {
        switch ling.keyState {
        case .checking, .unchecked:
            line(Palette.accent, L("正在检查…"), Palette.secondary)
        case .invalid:
            line(Palette.error, L("这个 key 无效，请检查是否复制完整，或重新创建一个"), Palette.accentInk)
        case .unreachable(let why):
            line(Palette.error, why, Palette.accentInk)
        default:
            if clipboardEmpty {
                line(Palette.error, other ? L("剪贴板里没有 sk- 开头的 key，请先去 \(settings.provider.name) 复制。")
                                          : L("剪贴板里没有 sk- 开头的 key，先在 Ling 开放平台复制。"), Palette.accentInk)
            } else {
                Label(L("只保存在这台 Mac 上，只发给 \(settings.provider.name)"), systemImage: "lock")
                    .font(.system(size: 12)).foregroundStyle(Palette.tertiary)
            }
        }
    }

    // MARK: Connected

    private var connected: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.ok)
                    .frame(width: 24, height: 24).background(Circle().fill(Palette.okPale))
                Text("已连接").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink)
                if case .ok(let s) = ling.keyState {
                    Text(L("\(settings.textModel) · 响应约 \(String(format: "%.1f", s)) 秒"))
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }
                Spacer()
                if let key = ling.key {
                    Text(AIKey.masked(key)).font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.secondary)
                }
            }
            Divider()
            Text("现在可以用了").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.secondary)
            HStack(spacing: 10) {
                benefit(L("实时纪要"), L("会中每 45 秒更新"))
                benefit(L("更准的翻译"), L("人名、术语前后一致"))
                if ling.speaks { benefit(L("自然人声"), L("同传约 2 秒出声")) }
            }
            Text("开会时，纪要会跟着字幕一起更新。").font(.system(size: 12)).foregroundStyle(Palette.secondary)
        }
        .padding(22)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.line, lineWidth: 1))
    }

    // MARK: Skipping

    /// Honest about both sides, so skipping is a choice rather than a dead end.
    private var withoutKey: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("先不接也行，基础功能照常能用").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink)
            HStack(alignment: .top, spacing: 10) {
                column(L("现在可用"), [L("实时翻译字幕"), L("双语文字记录"), L("同声传译（系统语音）")],
                       head: Palette.secondary, fill: Palette.ground, check: true)
                column(L("接上 Ling 才有"), [L("实时纪要和会后总结"), L("人名、术语前后一致"), L("自然人声，约 2 秒出声")],
                       head: Palette.accentInk, fill: Palette.accentPale, check: false)
            }
            Text("随时可在纪要窗口或设置里接上，开完的会也能补出纪要。")
                .font(.system(size: 12)).foregroundStyle(Palette.secondary)
        }
        .padding(22)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.line, lineWidth: 1))
    }

    private func column(_ title: String, _ items: [String], head: Color, fill: Color, check: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(head)
            ForEach(items, id: \.self) { item in
                HStack(spacing: 6) {
                    if check { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.ink) }
                    Text(item).font(.system(size: 14)).foregroundStyle(Palette.ink)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(fill))
    }

    private func keyField(placeholder: String) -> some View {
        HStack(spacing: 8) {
            SecureField(placeholder, text: $draft)
                .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced))
                .padding(.horizontal, 12).frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.ink.opacity(0.35), lineWidth: 1))
                .onSubmit { save(draft) }
            Button(action: pasteAndCheck) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.clipboard").font(.system(size: 12))
                    Text(draft.isEmpty ? L("粘贴并检查") : L("保存并检查"))
                }
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 14).frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 10).fill(Palette.ink))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
    }
    }

    // MARK: Pieces

    private func number(_ n: Int) -> some View {
        Text("\(n)").font(.system(size: 13, weight: .bold)).foregroundStyle(Palette.ink)
            .frame(width: 26, height: 26).background(Circle().fill(Palette.fill))
    }

    private func line(_ dot: Color, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(dot).frame(width: 7, height: 7)
            Text(text).font(.system(size: 12)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func benefit(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.ink)
            Text(detail).font(.system(size: 12)).foregroundStyle(Palette.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.ground))
    }

    /// Reads the clipboard only when the button is clicked (a deliberate paste, so macOS's paste
    /// privacy prompt, if any, makes sense to the user); a typed key is checked as typed.
    private func pasteAndCheck() {
        if !draft.isEmpty { save(draft); return }
        let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard text.hasPrefix("sk-"), !text.contains(where: \.isWhitespace) else { clipboardEmpty = true; return }
        save(text)
    }

    private func save(_ raw: String) {
        let k = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        clipboardEmpty = false
        draft = ""
        Task { await ling.setKey(k) }
    }
}

/// Step 3's footer. 继续 waits for a working key; "先不接" turns the card into what skipping leaves out,
/// and only "好，先这样" there moves on without one.
struct OnboardingKeyFooter: View {
    @ObservedObject var ling: LingClient
    @Binding var skipping: Bool
    var next: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            if case .ok = ling.keyState {
                primary(L("继续"), arrow: true, action: next)
            } else if skipping {
                Button { skipping = false } label: {
                    Text("回去接上")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.ink)
                        .padding(.horizontal, 20).frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(white: 0.84), lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                primary(L("好，先这样"), arrow: false) { skipping = false; next() }
            } else {
                Button("先不接") { skipping = true }.buttonStyle(.plain).foregroundStyle(Palette.secondary)
                Text("接上后继续")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.secondary)
                    .padding(.horizontal, 24).frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.87)))
            }
        }
    }

    private func primary(_ text: String, arrow: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(text)
                if arrow { Image(systemName: "arrow.right") }
            }
            .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 28).frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 12).fill(Palette.ink))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
    }
}

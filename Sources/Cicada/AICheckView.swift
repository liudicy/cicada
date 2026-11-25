import AppKit
import SwiftUI

extension Palette {
    /// "Busy, retrying": a passing state that still deserves a word.
    static let warn = Color(red: 0.54, green: 0.35, blue: 0.0)
    static let warnPale = Color(red: 1.0, green: 0.957, blue: 0.839)
}

/// The AI service's check, step by step (`AICheck`): settings and onboarding show the same list.
/// Every step that ran shows its result; the one that failed says why in one line and offers the
/// one thing that fixes it. All passed folds into one line (`AICheckSummary`).
struct AICheckSteps: View {
    @ObservedObject var model: AppModel
    @ObservedObject var ling: LingClient
    /// The settings have 重新检查 beside the key already; onboarding needs it in the failed step.
    var recheckInStep = true
    /// The key field opens (settings: 更换; onboarding: back to pasting).
    var changeKey: () -> Void

    private var check: AICheck { ling.aiCheck }
    private var service: String { ling.serviceLabel }
    private var host: String { ling.serviceHost }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(check.steps, id: \.id) { step in
                row(step)
                if step.id != check.steps.last?.id { Divider().padding(.leading, 30) }
            }
        }
    }

    private func row(_ step: AICheck.Step) -> some View {
        HStack(alignment: .top, spacing: 10) {
            icon(step.state).padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(AICheck.title(step.id, host: host)).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(step.state == .skipped || step.state == .untested ? Palette.tertiary : Palette.ink)
                if case .ok = step.state, step.id == .text {
                    Text(model.settings.textModel).font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                }
                if step.state == .untested, step.id == .text, check.passed {
                    Text("开会用过一次后确认").font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                }
                if isFailed(step.state) || step.state == .busy { problem(step.state) }
            }
            Spacer(minLength: 4)
            if case .ok(let s?) = step.state {
                Text(L("\(String(format: "%.1f", s)) 秒")).font(.system(size: 11).monospacedDigit()).foregroundStyle(Palette.tertiary)
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder private func problem(_ state: AICheck.State) -> some View {
        let model = self.model.settings.textModel
        if let why = check.message(service: service, host: host, model: model) {
            Text(why).font(.system(size: 12)).foregroundStyle(state == .busy ? Palette.warn : Palette.error)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let proxy = check.proxyLine(service: service, host: host) {
            Text(proxy).font(.system(size: 12)).foregroundStyle(Palette.body)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Palette.fill))
                .fixedSize(horizontal: false, vertical: true)
        }
        let acts = actions
        if !acts.isEmpty {
            HStack(spacing: 8) {
                ForEach(Array(acts.enumerated()), id: \.offset) { i, a in
                    SoftButton(a.title, dark: i == 0, action: a.run)
                }
            }
            .padding(.top, 2)
        }
    }

    private struct Action { let title: String; let run: () -> Void }

    /// One primary fix (dark) and at most one other.
    private var actions: [Action] {
        guard let f = check.failure else { return [] }
        let p = ling.provider
        let recheck = recheckInStep ? [Action(title: L("重新检查")) { Task { await ling.check() } }] : []
        switch f.reason {
        case .unreachable where check.localNetworkDenied:
            return [Action(title: L("打开系统设置")) { model.openLocalNetworkSettings() }] + recheck
        case .unreachable:
            // A proxy has nothing to do with a server on this Mac or the local network.
            if AIProvider.isNearby(host) { return recheck }
            return [Action(title: L("怎么设置代理")) { NSWorkspace.shared.open(ProxyProbe.helpURL) }] + recheck
        case .invalidKey, .mgmtKey:
            var a = [Action(title: L("更换 key"), run: changeKey)]
            if let site = p.site { a.append(Action(title: L("打开 \(p.name)")) { NSWorkspace.shared.open(site) }) }
            return a
        case .noCredit:
            return [Action(title: L("去充值")) { NSWorkspace.shared.open(AICheckSteps.topUp(p)) }] + recheck
        case .noModel:
            guard let rec = p.textModels.first?.id, rec != model.settings.textModel else { return recheck }
            return [Action(title: L("换成推荐的 \(rec)")) { model.useRecommendedTextModel() }]
        case .serverError:
            return recheck
        case .badAddress, .noJSON, .busy:
            return []
        }
    }

    /// Where to add money: OpenRouter's credits page, else the service's own site.
    static func topUp(_ p: AIProvider) -> URL {
        p.id == .openrouter ? URL(string: "https://openrouter.ai/settings/credits")! : (p.site ?? URL(string: "https://openrouter.ai")!)
    }

    private func isFailed(_ s: AICheck.State) -> Bool { if case .fail = s { true } else { false } }

    @ViewBuilder private func icon(_ s: AICheck.State) -> some View {
        let (symbol, fg, bg): (String, Color, Color) = switch s {
        case .ok: ("checkmark", Palette.ok, Palette.okPale)
        case .fail: ("xmark", Palette.error, Palette.errorPale)
        case .busy: ("exclamationmark", Palette.warn, Palette.warnPale)
        case .running: ("ellipsis", Palette.accentInk, Palette.accentPale)
        case .skipped, .untested: ("minus", Palette.tertiary, Palette.fill)
        }
        Image(systemName: symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(fg)
            .frame(width: 20, height: 20).background(Circle().fill(bg))
    }
}

/// The menu bar panel's line when the AI service needs the user (can't reach it, the key, money,
/// a model gone). Subtitles go on regardless (on-device recognition, Google), so it says so.
struct AIServiceStrip: View {
    @ObservedObject var model: AppModel
    @ObservedObject var ling: LingClient

    var body: some View {
        if let (title, detail) = words {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.accentInk)
                    Text(detail).font(.system(size: 11)).foregroundStyle(Palette.secondary)
                }
                Spacer()
                SoftButton(L("打开设置"), dark: true) { model.openSettings(.ai) }
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(Palette.accentPale))
        }
    }

    private var words: (String, String)? {
        let c = ling.aiCheck
        guard ling.hasKey, c.needsUser else { return nil }
        let name = ling.serviceLabel
        let stopped = L("字幕照常；纪要和整句翻译先停下")
        guard let f = c.failure else {
            return c.balanceLine(service: name).map { ($0, L("用完后纪要会停下")) }
        }
        if f.reason == .unreachable { return (c.localNetworkDenied ? L("知了没有本地网络权限") : L("连不上 \(name)"), stopped) }
        return Self.blocking(ling, textModel: model.settings.textModel).map { ($0, stopped) }
    }

    /// What stops the notes until you change something (not the network, not a busy service):
    /// also the menu bar's dot, beyond the panel.
    static func blocking(_ ling: LingClient, textModel: String) -> String? {
        guard ling.hasKey, let f = ling.aiCheck.failure else { return nil }
        let name = ling.serviceLabel
        switch f.reason {
        case .invalidKey, .mgmtKey: return L("\(name) 的 key 用不了")
        case .noCredit: return L("\(name) 账户余额不足。")
        case .noModel: return L("\(name) 上找不到 \(textModel) 这个模型。")
        case .badAddress, .noJSON: return L("AI 服务的设置要改一下")
        case .unreachable, .busy, .serverError: return nil
        }
    }
}

/// All passed, in one line: "文字 1.8 秒", or when the newest evidence came from a meeting,
/// "12 分钟前开会时用过".
struct AICheckSummary {
    static func text(_ check: AICheck) -> String? {
        guard check.passed, !check.busy else { return nil }
        if check.passive, let at = check.at {
            let f = RelativeDateTimeFormatter()
            f.locale = uiLocale
            f.unitsStyle = .short
            return L("\(f.localizedString(for: at, relativeTo: Date())) 开会时用过")
        }
        for s in check.steps.reversed() { if case .ok(let sec?) = s.state { return L("响应约 \(String(format: "%.1f", sec)) 秒") } }
        return nil
    }
}

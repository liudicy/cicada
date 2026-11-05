import SwiftUI

/// The panel's update strip, under the header while there is a newer release: install it, watch
/// it download, or read why installing in place failed (the release page was opened instead).
/// While a meeting is on it shrinks to one line, so it doesn't push the meeting's controls down.
struct UpdateBanner: View {
    @ObservedObject var updates: Updates
    @ObservedObject var model: AppModel

    var body: some View {
        if let update = updates.update {
            Group {
                if model.running && updates.progress == nil && updates.failure == nil {
                    HStack(spacing: 8) {
                        Circle().fill(Palette.accent).frame(width: 7, height: 7)
                        Text("新版本 \(update.version)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink)
                        Spacer()
                        SoftButton(L("安装"), onGrey: true) { updates.install(model: model) }
                    }
                } else {
                    full(update)
                }
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(Palette.accentPale))
            .contextMenu { Button("更新说明") { NSWorkspace.shared.open(update.url) } }
        }
    }

    private func full(_ update: UpdateChecker.Update) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(Palette.accent).frame(width: 7, height: 7)
                Text("新版本 \(update.version)").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                Spacer()
            }
            Text(detail(update)).font(.system(size: 11)).foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let p = updates.progress {
                ProgressView(value: p).controlSize(.small).tint(Palette.accent).accessibilityLabel(L("下载进度"))
            } else {
                HStack(spacing: 12) {
                    SoftButton(updates.failure == nil ? L("安装并重新打开") : L("重试"), dark: true) { updates.install(model: model) }
                    Button { NSWorkspace.shared.open(update.url) } label: {
                        Text("更新说明").font(.system(size: 12)).foregroundStyle(Palette.accentInk)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func detail(_ update: UpdateChecker.Update) -> String {
        if let p = updates.progress { return L("正在下载 \(Int(p * 100))%，完成后自动重新打开") }
        if let f = updates.failure { return L("没能自动更新：\(f)。已打开下载页") }
        let size = update.size > 0 ? ByteCountFormatter.string(fromByteCount: Int64(update.size), countStyle: .file) + " · " : ""
        return size + L("安装后自动重新打开")
    }
}

/// Settings › 会议记录, the app-wide rows: open at login and the version with a check button.
struct AppRows: View {
    @ObservedObject var updates: Updates
    @ObservedObject var loginItem: LoginItem
    let model: AppModel

    var body: some View {
        SettingsCard {
            SettingsRow(title: L("登录时打开"), detail: loginDetail) {
                Toggle("登录时打开", isOn: Binding(get: { loginItem.enabled }, set: { loginItem.set($0) }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small).tint(Palette.ink)
            }
            SettingsRow(title: L("版本 \(Updates.current)"), detail: checkDetail) {
                if updates.update != nil {
                    SoftButton(L("安装并重新打开"), dark: true) { updates.install(model: model) }
                        .disabled(updates.progress != nil)
                } else {
                    SoftButton(L("检查更新")) { updates.checkNow() }.disabled(updates.check == .checking)
                }
            }
            SettingsRow(title: L("首次引导"), divider: false) {
                SoftButton(L("重新看")) { model.onboardingStep = 1; model.openOnboarding?() }
            }
        }
        .onAppear { loginItem.refresh() }
    }

    private var loginDetail: String {
        if let e = loginItem.error { return e }
        if loginItem.needsApproval { return L("请在“系统设置 › 通用 › 登录项”中允许") }
        return L("开机后在菜单栏待命，不弹窗口")
    }

    private var checkDetail: String? {
        if let u = updates.update {
            if let p = updates.progress { return L("正在下载 \(u.version)：\(Int(p * 100))%") }
            if let f = updates.failure { return L("没能自动更新：\(f)") }
            return L("有新版本 \(u.version)")
        }
        switch updates.check {
        case .checking: return L("正在检查…")
        case .upToDate: return L("已是最新版本")
        case .failed: return L("连不上 GitHub，请稍后再试")
        case .idle:
            guard let d = updates.lastChecked else { return nil }
            return L("上次检查 \(dateText(d, Calendar.current.isDateInToday(d) ? "HHmm" : "MMMdHHmm"))")
        }
    }
}

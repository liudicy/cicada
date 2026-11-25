import AppKit
import SwiftUI

extension MicUser.State {
    var isOther: Bool { if case .otherMic = self { true } else { false } }
}

/// The app's own icon, so the row reads at a glance.
struct AppIcon: View {
    let bundleID: String
    var size: CGFloat = 28

    var body: some View {
        Image(nsImage: Self.icon(bundleID)).resizable().frame(width: size, height: size)
    }

    private static func icon(_ bundleID: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .application)
    }
}

/// "怎么改": the steps for one app, with its microphone checked live so the user sees it turn green.
struct MicGuideView: View {
    @ObservedObject var model: AppModel
    let bundleID: String
    let name: String
    let close: () -> Void

    /// The app's state now; idle once it closes its microphone.
    private var state: MicUser.State {
        model.micUsers.first { $0.bundleID == bundleID }?.state ?? .idle
    }

    private var micName: String { model.virtualMic?.name ?? "BlackHole 2ch" }

    /// Only apps whose menus we've checked get exact steps; the rest get the plain instruction.
    private var steps: [String] {
        let tune = L("顺便关掉自动调节麦克风音量和降噪，译文会更清楚")
        switch bundleID {
        case "com.tencent.meeting", "us.zoom.xos":
            return [L("进会议后，点麦克风图标旁边的 ⌃"), L("在选择麦克风菜单里点 \(micName)"), tune]
        // Browsers: the meeting page picks its own mic; Chrome can also set a default for every site.
        case "com.google.Chrome":
            // With the system mic switched, a page left on "default" needs nothing; one set to a
            // specific mic still has to be changed in the page.
            return [model.settings.autoSystemMic ? L("在会议网页的音频设置里，把麦克风选为 \(micName) 或“默认”")
                                                 : L("在会议网页的音频设置里，把麦克风选为 \(micName)"),
                    L("想让所有网页默认用它：Chrome 设置 › 隐私和安全 › 网站设置 › 麦克风"), tune]
        case "com.apple.Safari", "com.microsoft.edgemac", "company.thebrowser.Browser":
            return [L("在会议网页的音频设置里，把麦克风选为 \(micName)"), tune]
        default:
            return [L("打开\(name)的音频设置"), L("把麦克风选为 \(micName)"), tune]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                AppIcon(bundleID: bundleID, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("在\(name)里使用虚拟麦克风").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink)
                    Text("改好一次，下次开会不用再改").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(i + 1)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink)
                            .frame(width: 22, height: 22).background(Circle().fill(Palette.fill))
                        Text(step).font(.system(size: 13)).foregroundStyle(Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            status
            Text("换用虚拟麦克风后，对方只能听到译文，听不到你说话的原声。")
                .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Palette.accentPale))
            HStack(spacing: 10) {
                Spacer()
                if state == .virtualMic {
                    SoftButton(L("好了"), dark: true, action: close)
                } else {
                    SoftButton(L("先不改"), action: close)
                    SoftButton(L("打开\(name)"), dark: true) { model.openApp(bundleID) }
                }
            }
        }
        .padding(24)
        .frame(width: 440, alignment: .leading)
    }

    @ViewBuilder
    private var status: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(name)当前麦克风").font(.system(size: 12)).foregroundStyle(Palette.secondary)
            switch state {
            case .virtualMic:
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.ok)
                    Text("\(micName)，对方能听到译文").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ok)
                }
            case .otherMic(let mic):
                HStack(spacing: 10) {
                    Text(mic.isEmpty ? L("其他麦克风") : mic).font(.system(size: 13)).foregroundStyle(Palette.accentInk)
                    Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                    Text(micName).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                }
                Text("选对后这里会自动变绿").font(.system(size: 11)).foregroundStyle(Palette.tertiary)
            case .idle:
                Text("没开麦克风，进会议后这里会显示").font(.system(size: 13)).foregroundStyle(Palette.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(state == .virtualMic ? Palette.okPale : Palette.fill))
    }
}

import ActivityKit
import SwiftUI
import WidgetKit

// The CicadaLive extension: draws ListenActivity (ios/Sources/Cicada/ListenActivity.swift) on the
// lock screen and in the Dynamic Island, and 开始听 in Control Center. Built by ios/scripts/build.sh
// into PlugIns/CicadaLive.appex. Its buttons are App Intents (ios/Sources/Cicada/Intents.swift),
// which run in the app.

@main
struct CicadaLiveBundle: WidgetBundle {
    var body: some Widget {
        ListenLiveActivity()
        StartListeningControl()
    }
}

/// 开始听 in Control Center and on the lock screen.
struct StartListeningControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.indaloop.cicada.start") {
            ControlWidgetButton(action: StartListeningIntent()) {
                Label("开始听", systemImage: "mic.fill")
            }
        }
        .displayName("开始听")
        .description("用麦克风听会议室，出实时双语字幕和纪要")
    }
}

/// 暂停 / 继续 and 结束并出纪要, on the lock screen and in the expanded Dynamic Island.
private struct LiveButtons: View {
    let paused: Bool
    var dark = false

    var body: some View {
        HStack(spacing: 8) {
            Button(intent: PauseListeningIntent()) {
                Text(paused ? "继续" : "暂停").font(.subheadline.weight(.semibold))
                    .foregroundStyle(dark ? .white : LiveInk.ink)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background((dark ? Color.white : LiveInk.ink).opacity(dark ? 0.16 : 0.07), in: Capsule())
            }
            .buttonStyle(.plain)
            Button(intent: StopListeningIntent()) {
                Text("结束并出纪要").font(.subheadline.weight(.semibold))
                    .foregroundStyle(dark ? LiveInk.ink : .white)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(dark ? Color.white : LiveInk.ink, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}

private enum LiveInk {
    static let ink = Color(red: 0x15 / 255, green: 0x17 / 255, blue: 0x1C / 255)
    static let accent = Color(red: 0xE8 / 255, green: 0x55 / 255, blue: 0x2B / 255)
    static let grey = Color(red: 0x5A / 255, green: 0x5F / 255, blue: 0x6B / 255)
    static let ground = Color(red: 0xF3 / 255, green: 0xF4 / 255, blue: 0xF6 / 255)
}

private struct LiveLogo: View {
    let size: CGFloat
    private static let image = Bundle.main.path(forResource: "logo", ofType: "png").flatMap(UIImage.init(contentsOfFile:))

    var body: some View {
        Group {
            if let image = Self.image { Image(uiImage: image).resizable().scaledToFill().scaleEffect(1.24) } else { LiveInk.accent }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size / 4, style: .continuous))
    }
}

/// The elapsed time, counting up from the start, ticked by the system.
private struct Elapsed: View {
    let since: Date
    var body: some View {
        Text(timerInterval: since...Date.distantFuture, countsDown: false)
            .monospacedDigit()
    }
}

struct ListenLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ListenActivity.self) { context in
            // Lock screen: the logo, 正在听 · time, the languages, and the newest line.
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    LiveLogo(size: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Circle().fill(context.state.paused ? LiveInk.grey : LiveInk.accent).frame(width: 7, height: 7)
                            if context.state.paused {
                                Text("已暂停").font(.footnote.weight(.semibold)).foregroundStyle(LiveInk.grey)
                            } else {
                                Text("正在听").font(.footnote.weight(.semibold)).foregroundStyle(LiveInk.accent)
                                Elapsed(since: context.attributes.startedAt).font(.footnote.weight(.semibold)).foregroundStyle(LiveInk.accent)
                            }
                        }
                        Text(verbatim: "\(String(localized: "会议室")) · \(context.attributes.pair)")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(LiveInk.ink)
                    }
                    Spacer()
                    if context.state.people >= 2 {
                        Text(String(localized: "\(context.state.people) 人在说")).font(.caption).foregroundStyle(LiveInk.grey)
                    }
                }
                if !context.state.line.isEmpty {
                    Text(context.state.line).font(.callout).foregroundStyle(LiveInk.ink).lineLimit(2)
                } else {
                    Text("开始说话后，字幕会出现在这里").font(.callout).foregroundStyle(LiveInk.grey)
                }
                LiveButtons(paused: context.state.paused)
            }
            .padding(16)
            .activityBackgroundTint(LiveInk.ground.opacity(0.92))
            .activitySystemActionForegroundColor(LiveInk.ink)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        LiveLogo(size: 26)
                        Text(context.state.paused ? "已暂停" : "正在听").font(.footnote.weight(.semibold))
                            .foregroundStyle(context.state.paused ? .white.opacity(0.6) : LiveInk.accent)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if !context.state.paused {
                        Elapsed(since: context.attributes.startedAt).font(.footnote.weight(.semibold))
                            .foregroundStyle(.white).frame(maxWidth: 64, alignment: .trailing).padding(.trailing, 4)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.state.line.isEmpty ? String(localized: "开始说话后，字幕会出现在这里") : context.state.line)
                            .font(.callout).foregroundStyle(.white).lineLimit(2)
                        Text(verbatim: "\(String(localized: "会议室")) · \(context.attributes.pair)")
                            .font(.caption2).foregroundStyle(.white.opacity(0.6))
                        LiveButtons(paused: context.state.paused, dark: true).padding(.top, 6)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                HStack(spacing: 5) {
                    Circle().fill(context.state.paused ? LiveInk.grey : LiveInk.accent).frame(width: 7, height: 7)
                    LiveLogo(size: 20)
                }
            } compactTrailing: {
                // Paused: a still pause mark, not a clock that keeps running as if it were listening.
                if context.state.paused {
                    Image(systemName: "pause.fill").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.6))
                } else {
                    Elapsed(since: context.attributes.startedAt)
                        .font(.caption.weight(.semibold)).foregroundStyle(LiveInk.accent)
                        .frame(maxWidth: 46)
                }
            } minimal: {
                Circle().fill(context.state.paused ? LiveInk.grey : LiveInk.accent).frame(width: 9, height: 9)
            }
            .keylineTint(LiveInk.accent)
        }
    }
}

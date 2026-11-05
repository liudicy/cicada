import AppKit
import SwiftUI

/// The main window's toolbar: just the listening pill, centred. Settings lives at the bottom
/// of the sidebar instead; a real toolbar so macOS centres the window buttons on the same line.
@MainActor final class MainToolbar: NSObject, NSToolbarDelegate {
    static let pill = NSToolbarItem.Identifier("cicada.pill")
    let model: AppModel

    init(model: AppModel) { self.model = model }

    func make() -> NSToolbar {
        let t = NSToolbar(identifier: "cicada.main")
        t.delegate = self
        t.displayMode = .iconOnly
        t.allowsUserCustomization = false
        t.centeredItemIdentifiers = [Self.pill]
        return t
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.pill, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        item.view = NSHostingView(rootView: AnyView(ListenPill(model: model, store: model.store)))
        (item.view as? NSHostingView<AnyView>)?.sizingOptions = .intrinsicContentSize
        item.label = L("开始听")
        item.isBordered = false
        return item
    }
}

/// The listening switch, led by the logo: still in a white pill while idle, breathing in an ink pill while
/// listening, ringed by a countdown when the meeting is about to end. The brand is the switch.
struct ListenPill: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: SessionStore
    @State private var endingTotal: Double = 30

    var body: some View {
        Group {
            if model.running, let p = model.ending {
                ending(p)
            } else if model.running {
                listening
            } else {
                idle
            }
        }
        .animation(.spring(duration: 0.35), value: model.running)
        .animation(.spring(duration: 0.35), value: model.ending)
        .onChange(of: model.ending) { _, p in
            if let p { endingTotal = max(1, p.deadline.timeIntervalSinceNow) }
        }
        .padding(.vertical, 2)
        // A toolbar item keeps the width it was first laid out at: a fixed slot, wide enough for
        // the longest state (the English countdown), with the pill centred in it.
        .frame(width: 420)
    }

    private var idle: some View {
        // The quick default: start with the current source. The three explicit entries
        // (线上 / 现场 / 导入) live at the top of the sidebar.
        Button { model.setRunning(true) } label: {
            HStack(spacing: 9) {
                BrandMark(size: 22)
                Text(L("知了")).font(.system(size: 13, weight: .heavy)).foregroundStyle(Palette.ink)
                Rectangle().fill(Palette.line).frame(width: 1, height: 14)
                Text(model.autoEnded ? L("会议已自动结束") : L("开始听"))
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                Text("⌘R").font(.system(size: 11)).foregroundStyle(Palette.secondary)
            }
            .padding(.leading, 6).padding(.trailing, 12).frame(height: 32)
            .background(Capsule().fill(Color.white))
            .overlay(Capsule().stroke(Palette.line, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("开始听"))
    }

    private var listening: some View {
        HStack(spacing: 10) {
            Button { model.requestStop() } label: { BreathingMark(size: 22) }
                .buttonStyle(.plain).accessibilityLabel(L("结束会议"))
            Text("正在听").font(.system(size: 13, weight: .semibold))
            LevelMeter(model: model, bars: 8, height: 15, color: Palette.accent)
            if let start = store.session(store.liveID)?.startedAt {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(TranscriptExport.clock(max(0, ctx.date.timeIntervalSince(start))))
                        .font(.system(size: 13).monospacedDigit())
                }
            }
            Button { model.requestStop() } label: {
                Text("结束").font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12).frame(height: 24)
                    .background(Capsule().fill(Color(red: 0.184, green: 0.196, blue: 0.227)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("结束会议"))
        }
        .foregroundStyle(.white)
        .padding(.leading, 5).padding(.trailing, 4).frame(height: 32)
        .background(Capsule().fill(Palette.ink))
        // The languages stay one hover away; the pill keeps to state, level and time.
        .help(model.summary)
    }

    private func ending(_ p: MeetingEndWatch.Pending) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let left = max(0, p.deadline.timeIntervalSince(ctx.date))
            HStack(spacing: 10) {
                ZStack {
                    Circle().stroke(Color(red: 0.227, green: 0.239, blue: 0.27), lineWidth: 2.5)
                    Circle().trim(from: 0, to: min(1, left / endingTotal))
                        .stroke(Palette.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    BrandMark(size: 16)
                }
                .frame(width: 26, height: 26)
                Text(model.endingTitle(p)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(L("\(Int(left.rounded())) 秒后结束"))
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(Color(red: 0.957, green: 0.647, blue: 0.549))
                Button { model.keepRecording() } label: {
                    Text("继续记录").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink)
                        .padding(.horizontal, 12).frame(height: 24)
                        .background(Capsule().fill(Color.white))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(.white)
            .padding(.leading, 4).padding(.trailing, 4).frame(height: 32)
            .background(Capsule().fill(Palette.ink))
        }
    }
}

/// The logo with accent rings swelling out of it while Cicada listens.
struct BreathingMark: View {
    var size: CGFloat = 22
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        BrandMark(size: size)
            .background {
                if !reduceMotion {
                    ZStack {
                        Ring(size: size, delay: 0)
                        Ring(size: size, delay: 1.1)
                    }
                }
            }
            .accessibilityHidden(true)
    }

    private struct Ring: View {
        let size: CGFloat
        let delay: Double
        @State private var out = false
        var body: some View {
            RoundedRectangle(cornerRadius: size * 0.28).fill(Palette.accent)
                .scaleEffect(out ? 1.7 : 1).opacity(out ? 0 : 0.55)
                .onAppear {
                    withAnimation(.easeOut(duration: 2.2).repeatForever(autoreverses: false).delay(delay)) { out = true }
                }
        }
    }
}

/// An accent dot with a ring that keeps swelling out of it: "live", without blinking.
struct BreathingDot: View {
    var size: CGFloat = 8
    @State private var out = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle().fill(Palette.accent).frame(width: size, height: size)
            .background {
                if !reduceMotion {
                    Circle().fill(Palette.accent)
                        .scaleEffect(out ? 2.6 : 1).opacity(out ? 0 : 0.6)
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 2).repeatForever(autoreverses: false)) { out = true }
            }
            .accessibilityHidden(true)
    }
}

/// Bars that follow the loudness of what Cicada hears, newest on the right.
struct LevelMeter: View {
    @ObservedObject var model: AppModel
    var bars = 9
    var height: CGFloat = 16
    var color: Color = Palette.accent
    @State private var levels: [CGFloat] = []
    private let tick = Timer.publish(every: 0.08, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<bars, id: \.self) { i in
                let v = i < levels.count ? levels[i] : 0
                Capsule().fill(color).frame(width: 2.5, height: max(3, v * height))
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.08), value: levels)
        .onReceive(tick) { _ in
            guard model.running else { return }
            // Map −40…0 dBFS onto the bar height: quiet speech sits low, a loud voice near the top.
            let rms = model.listen.router.takeLevel()
            let db = 20 * log10(max(Double(rms), 1e-6))
            let v = CGFloat(min(1, max(0, (db + 40) / 40)))
            levels = Array((levels + [v]).suffix(bars))
        }
        .accessibilityHidden(true)
    }
}

import AppKit
import AVFoundation
import SwiftUI

// MARK: - Brand mark (logo B: a cicada's eyes and wings peeking over a white subtitle card)

/// The logo in its 100-unit design space, y down (same geometry as site/icon.svg and
/// Sources/CicadaIcon; keep the three in step). Design: claude.ai/artifact/96R6Md276c3jAS4Mk4Ustn
enum CicadaLogo {
    static let orange = rgb(0xE8552B)
    static let ink = rgb(0x15171C)
    static let white = CGColor(gray: 1, alpha: 1)

    static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
    static func gradient(_ stops: [(UInt32, CGFloat)], at locations: [CGFloat]) -> CGGradient {
        CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: stops.map { rgb($0.0, $0.1) } as CFArray,
                   locations: locations)!
    }
    static func circle(_ c: CGContext, _ x: CGFloat, _ y: CGFloat, _ r: CGFloat) {
        c.addEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
    }
    static func wings(_ c: CGContext) {
        c.move(to: CGPoint(x: 21, y: 42)); c.addQuadCurve(to: CGPoint(x: 44, y: 27), control: CGPoint(x: 26, y: 17))
        c.move(to: CGPoint(x: 78, y: 39)); c.addQuadCurve(to: CGPoint(x: 55, y: 25), control: CGPoint(x: 73, y: 14))
    }
    static let eyes: [(CGFloat, CGFloat)] = [(36, 51), (63, 49)]
    /// The card leans 5° and bleeds off the right and bottom edges, so the eyes peek over it.
    static func tilt(_ c: CGContext) {
        c.translateBy(x: 50, y: 70); c.rotate(by: -5 * .pi / 180); c.translateBy(x: -50, y: -70)
    }

    /// The whole icon, clipped to its squircle. `unit` is device pixels per design unit
    /// (shadows are in device space).
    static func drawIcon(_ c: CGContext, unit: CGFloat) {
        c.saveGState()
        c.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 100, height: 100), cornerWidth: 23, cornerHeight: 23, transform: nil))
        c.clip()
        c.drawLinearGradient(gradient([(0xF57447, 1), (0xDC461C, 1)], at: [0, 1]),
                             start: .zero, end: CGPoint(x: 100, y: 100), options: [])
        c.drawLinearGradient(gradient([(0xFFFFFF, 0.2), (0xFFFFFF, 0)], at: [0, 1]),
                             start: .zero, end: CGPoint(x: 0, y: 50), options: [])
        c.setLineCap(.round)
        c.setStrokeColor(white); c.setLineWidth(5.5); wings(c); c.strokePath()

        let eyeShade = gradient([(0x3A3E48, 1), (0x0E0F12, 1)], at: [0, 1])
        for (x, y) in eyes {
            c.saveGState(); circle(c, x, y, 12.5); c.clip()
            let centre = CGPoint(x: x - 3.75, y: y - 6.25)
            c.drawRadialGradient(eyeShade, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: 22.5,
                                 options: [.drawsAfterEndLocation])
            c.restoreGState()
            c.setStrokeColor(white); c.setLineWidth(5); circle(c, x, y, 12.5); c.strokePath()
            c.setFillColor(white); circle(c, x, y, 8.4); c.fillPath()
            c.setFillColor(ink); circle(c, x + 2, y + 2.2, 4.7); c.fillPath()
            c.setFillColor(white); circle(c, x + 3.5, y + 0.6, 1.5); c.fillPath()
        }

        c.saveGState()
        tilt(c)
        let card = CGPath(roundedRect: CGRect(x: 9, y: 60, width: 104, height: 56), cornerWidth: 12, cornerHeight: 12, transform: nil)
        c.saveGState()
        c.setShadow(offset: CGSize(width: 0, height: unit), blur: 4 * unit, color: rgb(0x7A1E05, 0.3))
        c.setFillColor(white); c.addPath(card); c.fillPath()
        c.restoreGState()
        c.saveGState(); c.addPath(card); c.clip()
        c.drawLinearGradient(gradient([(0xFFFFFF, 1), (0xF1EEEC, 1)], at: [0, 1]),
                             start: CGPoint(x: 0, y: 60), end: CGPoint(x: 0, y: 116), options: [])
        c.restoreGState()
        c.saveGState(); c.addPath(card); c.setLineWidth(2); c.replacePathWithStrokedPath(); c.clip()
        c.drawLinearGradient(gradient([(0xFFC9B4, 1), (0xFFFFFF, 1), (0xFFE3A8, 1)], at: [0, 0.5, 1]),
                             start: CGPoint(x: 9, y: 0), end: CGPoint(x: 113, y: 0), options: [])
        c.restoreGState()
        c.setLineWidth(5.4)
        c.setStrokeColor(ink); c.move(to: CGPoint(x: 22, y: 75)); c.addLine(to: CGPoint(x: 72, y: 75)); c.strokePath()
        c.setStrokeColor(orange); c.move(to: CGPoint(x: 22, y: 86)); c.addLine(to: CGPoint(x: 49, y: 86)); c.strokePath()
        c.restoreGState()
        c.restoreGState()
    }

    /// One colour for the menu bar: wings, eyes and a whole (not bleeding) card; whites of the eyes and text lines cut out.
    static func drawTemplate(_ c: CGContext, color: CGColor) {
        c.setLineCap(.round)
        c.setStrokeColor(color); c.setLineWidth(6.5); wings(c); c.strokePath()
        c.setFillColor(color)
        for (x, y) in eyes { circle(c, x, y, 12.5) }
        c.fillPath()
        c.saveGState()
        tilt(c)
        let card = CGPath(roundedRect: CGRect(x: 10, y: 60, width: 80, height: 30), cornerWidth: 9, cornerHeight: 9, transform: nil)
        // In one colour the eyes would melt into the card: cut a thin gap around it first.
        c.setBlendMode(.clear); c.setLineWidth(9); c.addPath(card); c.strokePath(); c.setBlendMode(.normal)
        c.addPath(card); c.fillPath()
        c.setBlendMode(.clear); c.setLineWidth(6)
        c.move(to: CGPoint(x: 22, y: 70.5)); c.addLine(to: CGPoint(x: 72, y: 70.5))
        c.move(to: CGPoint(x: 22, y: 80.5)); c.addLine(to: CGPoint(x: 49, y: 80.5))
        c.strokePath()
        c.restoreGState()
        // Eyes as in colour: ring, cut-out white, pupil.
        c.setBlendMode(.clear)
        for (x, y) in eyes { circle(c, x, y, 8.4) }
        c.fillPath()
        c.setBlendMode(.normal)
        for (x, y) in eyes { circle(c, x + 2, y + 2.2, 4.7) }
        c.fillPath()
    }
}

struct BrandMark: View {
    var size: CGFloat = 36
    var body: some View {
        Image(nsImage: BrandImage.mark)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

enum BrandImage {
    /// The in-app mark: the logo on its orange squircle, drawn as a vector image so it is sharp at any size.
    static let mark: NSImage = {
        NSImage(size: NSSize(width: 100, height: 100), flipped: true) { rect in
            guard let c = NSGraphicsContext.current?.cgContext else { return false }
            c.scaleBy(x: rect.width / 100, y: rect.height / 100)
            CicadaLogo.drawIcon(c, unit: abs(c.ctm.a))
            return true
        }
    }()

    /// Menu bar template glyph: the logo in one colour. Paused draws it at 40%.
    /// What the dot on the menu bar glyph says: something to fix (orange, the colour that asks
    /// for a look) wins over a new version (grey, it can wait).
    enum Badge { case none, update, problem }

    static func menuBar(live: Bool, badge: Badge = .none) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 16), flipped: true) { _ in
            guard let c = NSGraphicsContext.current?.cgContext else { return false }
            // Design units 8…92 across and 16…94 down fill the 16 pt height.
            c.translateBy(x: 1, y: 0.4); c.scaleBy(x: 0.19, y: 0.19); c.translateBy(x: -8, y: -16)
            CicadaLogo.drawTemplate(c, color: CGColor(gray: 0, alpha: live ? 1 : 0.4))
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = appDisplayName
        return badge == .none ? img : withBadge(img, badge)
    }

    /// The glyph with a dot top right. A coloured dot
    /// can't be part of a template image, so the glyph is filled with the label colour instead.
    /// The dot is cut out of the glyph with a clear ring, so it reads as a badge, not part of the logo.
    private static func withBadge(_ glyph: NSImage, _ badge: Badge) -> NSImage {
        let image = NSImage(size: glyph.size, flipped: false) { rect in
            glyph.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            NSColor.labelColor.setFill()
            rect.fill(using: .sourceIn)
            let dot = NSRect(x: rect.maxX - 7.5, y: rect.maxY - 7.5, width: 7.5, height: 7.5)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            (badge == .problem ? NSColor(red: 0xE8 / 255, green: 0x55 / 255, blue: 0x2B / 255, alpha: 1)
                               : NSColor.secondaryLabelColor).setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.accessibilityDescription = badge == .problem ? L("\(appDisplayName)（需要处理）") : L("\(appDisplayName)（有新版本）")
        return image
    }
}

// MARK: - Sample clip

/// Plays the bundled sample, a short meeting voiced by Ming (`scripts/make-sample.sh`), through a
/// separate `afplay` process, because the app leaves its own audio out of what it listens to.
/// The onboarding card draws the call itself and lights whoever is talking.
@MainActor
final class SamplePlayer: ObservableObject {
    static let duration = 8.8
    /// Who talks when in sample.m4a (0 Emma, 1 George), in seconds; re-measure after regenerating.
    static let turns: [(speaker: Int, start: Double, end: Double)] = [(0, 0.25, 2.34), (1, 2.56, 6.97), (0, 7.17, 8.45)]

    @Published private(set) var playing = false
    /// Played since the card appeared: its subtitles stay up after the clip ends, as the last
    /// translation lands a moment later.
    @Published private(set) var played = false
    @Published private(set) var elapsed = 0.0
    private var audio: Process?
    private var timer: Timer?
    private var started = Date()

    var progress: Double { min(1, elapsed / Self.duration) }
    var speaker: Int? {
        guard playing else { return nil }
        return Self.turns.first { elapsed >= $0.start && elapsed < $0.end }?.speaker
    }

    func play() {
        guard !playing, let audioURL = Bundle.main.url(forResource: "sample", withExtension: "m4a") else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        p.arguments = [audioURL.path]
        try? p.run()
        audio = p
        playing = true
        played = true
        started = Date()
        elapsed = 0
        timer?.invalidate()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer = t
        RunLoop.main.add(t, forMode: .common)
    }

    private func tick() {
        elapsed = Date().timeIntervalSince(started)
        if elapsed >= Self.duration { stop() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if audio?.isRunning == true { audio?.terminate() }
        audio = nil
        playing = false
    }

    /// Back to the untouched card, when the guide leaves the step.
    func reset() {
        stop()
        played = false
        elapsed = 0
    }
}

/// Step 2's card: a two-person call drawn in place of a video. The call sits in the top part and
/// the bottom strip is kept for the subtitles, so they never cover a face; before the first play
/// the play button holds that strip, where the eye should land.
struct SampleCallCard: View {
    @ObservedObject var sample: SamplePlayer
    let liveSource: String
    let liveTranslation: String
    let play: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(verbatim: "LIVE").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Palette.accent))
                Text(verbatim: "Launch sync").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                Spacer()
                if sample.played && !sample.playing {
                    Button(action: play) {
                        Label("重播", systemImage: "arrow.counterclockwise").font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(height: 18)
            HStack(spacing: 12) {
                tile(0, "Emma", Color(red: 0.36, green: 0.39, blue: 0.47))
                tile(1, "George", Color(red: 0.42, green: 0.36, blue: 0.31))
            }
            .padding(.top, 8)
            Spacer(minLength: 0)
            Group {
                if sample.played { subtitle } else { playButton }
            }
            .frame(height: 58)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .frame(height: 210)
        .background(Color(red: 0.1, green: 0.11, blue: 0.13))
        .overlay(alignment: .topLeading) {
            if sample.playing {
                GeometryReader { g in
                    Rectangle().fill(Palette.accent).frame(width: g.size.width * sample.progress, height: 3)
                }
                .frame(height: 3)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .animation(.easeOut(duration: 0.15), value: sample.speaker)
    }

    private func tile(_ index: Int, _ name: String, _ avatar: Color) -> some View {
        let speaking = sample.speaker == index
        return ZStack {
            RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.15, green: 0.16, blue: 0.19))
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(speaking ? Palette.accent : Color(red: 0.18, green: 0.19, blue: 0.22), lineWidth: 2)
            Circle().fill(avatar).frame(width: 42, height: 42)
                .overlay(Text(verbatim: String(name.prefix(1))).font(.system(size: 18, weight: .bold)).foregroundStyle(.white))
            Text(verbatim: name).font(.system(size: 11)).foregroundStyle(.white.opacity(0.9))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.horizontal, 9).padding(.vertical, 6)
            if speaking {
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach([6.0, 11, 8], id: \.self) { h in
                        RoundedRectangle(cornerRadius: 1.5).fill(Palette.accent).frame(width: 3, height: h)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(8)
            }
        }
        .frame(width: 168, height: 88)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: name))
    }

    private var playButton: some View {
        Button(action: play) {
            HStack(spacing: 8) {
                Image(systemName: "play.fill").font(.system(size: 12))
                Text("播放示例 · 0:09").font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 22).frame(height: 44)
            .background(Capsule().fill(Color.white))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var subtitle: some View {
        VStack(spacing: 3) {
            Text(liveSource.isEmpty ? L("正在听…") : liveSource)
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.65)).lineLimit(1).truncationMode(.head)
            Text(liveTranslation)
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white).lineLimit(1).truncationMode(.head)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 18)
        .frame(maxWidth: 600, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.03, opacity: 0.92)))
    }
}

// MARK: - Onboarding

struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var installer: VirtualMicInstaller
    @ObservedObject var sample: SamplePlayer
    private var step: Int {
        get { model.onboardingStep }
        nonmutating set { model.onboardingStep = newValue }
    }
    var onFinish: () -> Void
    /// System audio, sample video, Ling key, speaking; then a closing page (step 5) outside the count.
    /// The video comes before the key so people see the subtitles before being sent to sign up anywhere.
    static let steps = 4
    static let done = 5

    private var stepNames: [String] {
        Recognition.cloudOnly
            ? [L("听声音"), L("接 Ling"), L("看效果"), L("同声传译")]
            : [L("听声音"), L("看效果"), L("接 Ling"), L("同声传译")]
    }
    private var keyStep: Int { Recognition.cloudOnly ? 2 : 3 }
    private var tryStep: Int { Recognition.cloudOnly ? 3 : 2 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.top, 34)
            Group {
                switch step {
                case 1: permissions
                case tryStep: tryIt
                case keyStep: OnboardingKeyStep(model: model, ling: model.ling, settings: settings, skipping: $model.onboardingKeySkip)
                case 4: speaking
                default: closing
                }
            }
            .padding(.top, step == Self.done ? 28 : 24)
            Spacer(minLength: 0)
            footer
        }
        .padding(.horizontal, 64)
        .padding(.bottom, 36)
        .frame(width: 860, height: 640)
        .background(Color(red: 0.965, green: 0.969, blue: 0.976))
        .onChange(of: step) { _, _ in sample.reset() }
        // Only the moment it turns on moves on by itself: when it was already on (the guide
        // reopened from Settings), step 1 stays put with a plain 继续.
        .onChange(of: model.listenReady) { was, now in
            guard !was, now, step == 1 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                MainActor.assumeIsolated { if step == 1 { step = 2 } }
            }
        }
    }

    // MARK: Header / footer

    @ViewBuilder private var header: some View {
        if step == Self.done {
            BrandMark(size: 34)
        } else {
            HStack(alignment: .top, spacing: 14) {
                BrandMark(size: 34)
                HStack(alignment: .top, spacing: 6) {
                    ForEach(1...Self.steps, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 7) {
                            Capsule().fill(i <= step ? Palette.ink : Color(white: 0.87)).frame(height: 4)
                            Text(stepNames[i - 1])
                                .font(.system(size: 11, weight: i == step ? .semibold : .regular))
                                .foregroundStyle(i == step ? Palette.ink : Palette.tertiary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 8)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L("第 \(step) 步，共 \(Self.steps) 步：\(stepNames[step - 1])"))
            }
        }
    }

    @ViewBuilder private var footer: some View {
        HStack(spacing: 16) {
            // In the checklist, 先不用了 replaces 上一步, but only when speaking was turned on right here:
            // someone re-running the guide with it already on shouldn't have it switched off.
            if step > 1 && !(step == 4 && model.onboardingSpeakSetup == .checklist) {
                Button("上一步") {
                    model.onboardingKeySkip = false
                    step -= 1
                }
                .buttonStyle(.plain).foregroundStyle(Palette.secondary)
            }
            Spacer()
            switch step {
            case 1 where !model.listenReady:
                Text("打开后自动继续")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.secondary)
                    .padding(.horizontal, 24).frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.87)))
            case keyStep:
                OnboardingKeyFooter(ling: model.ling, skipping: $model.onboardingKeySkip, next: { step = keyStep + 1 })
            case 4 where !speakSetupShown:
                // The two cards above are the choice; nothing to confirm here.
                EmptyView()
            case 4:
                if model.onboardingSpeakSetup == .checklist {
                    Button("先不用了") {
                        model.onboardingSpeakSetup = .ask
                        model.enableSpeaking(false)
                    }
                    .buttonStyle(.plain).foregroundStyle(Palette.secondary)
                }
                primaryButton(L("完成"), arrow: false) { step = Self.done }
            case Self.done:
                primaryButton(L("开始使用"), arrow: false) { onFinish() }
            default:
                primaryButton(L("继续"), arrow: true) { step += 1 }
            }
        }
        .frame(height: 44)
        .font(.system(size: 13))
    }

    private func primaryButton(_ text: String, arrow: Bool, _ action: @escaping () -> Void) -> some View {
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

    private func title(_ text: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).font(.system(size: 26, weight: .bold)).foregroundStyle(Palette.ink)
            Text(sub).font(.system(size: 14)).foregroundStyle(Palette.secondary)
        }
    }

    private func row<Trailing: View>(icon: String, title: String, detail: String,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 12).fill(Palette.ground).frame(width: 44, height: 44)
                .overlay(Image(systemName: icon).font(.system(size: 18)).foregroundStyle(Palette.ink))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink)
                Text(detail).font(.system(size: 13)).foregroundStyle(Palette.secondary)
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 22).padding(.vertical, 20)
    }

    private func done(_ text: String) -> some View {
        Label(text, systemImage: "checkmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
    }

    private func primary(_ text: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 16).frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 10).fill(Palette.ink))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func secondary(_ text: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                .padding(.horizontal, 16).frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(white: 0.84), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func whiteCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .background(RoundedRectangle(cornerRadius: 18).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.line, lineWidth: 1))
    }

    // MARK: Step 1: system audio only (the microphone is asked for in step 4, if at all)

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 24) {
            title(L("让知了听到电脑里的声音"), L("字幕和纪要都从这里来。去系统设置打开，回来会自动识别。"))
            whiteCard { VStack(spacing: 0) {
                row(icon: "speaker.wave.2", title: L("听电脑里的声音"),
                    detail: model.systemAudioRefused ? L("在系统设置里打开后，要重新打开知了") : L("只听声音，不录屏幕画面")) {
                    if model.systemAudioOK {
                        done(L("已打开"))
                    } else if model.systemAudioRefused {
                        HStack(spacing: 8) {
                            secondary(L("重新打开")) { model.relaunch() }
                            primary(L("去开启")) { model.requestSystemAudio() }
                        }
                    } else {
                        primary(L("去开启")) { model.requestSystemAudio() }
                    }
                }
                // macOS 14/15: the older recognizer needs Dictation on and its own permission.
                if Recognition.legacy {
                    Divider().padding(.horizontal, 22)
                    row(icon: "waveform", title: L("识别语音"), detail: L("打开“听写”，允许“语音识别”")) {
                        if model.speechOK { done(L("已打开")) } else { primary(L("去开启")) { model.requestSpeech() } }
                    }
                }
            } }
            Label(Recognition.cloudOnly ? L("会议录音和文字记录只存在这台 Mac 上") : L("声音只在本机识别"), systemImage: "lock")
                .font(.system(size: 12)).foregroundStyle(Palette.secondary)
        }
    }

    // MARK: Step 2: the sample meeting

    private var tryIt: some View {
        VStack(alignment: .leading, spacing: 18) {
            title(L("放一段会议试试"), L("一段 9 秒的英文会议，字幕会跟着声音实时出来。"))
            SampleCallCard(sample: sample, liveSource: model.liveSource, liveTranslation: model.liveTranslation) {
                model.ensureListening()
                sample.play()
            }

            HStack(spacing: 12) {
                ChoiceRow(label: L("听到"), value: heardName, badge: nil, options: sourceOptions) { model.sourceSelection = $0 }
                ChoiceRow(label: L("翻译成"), value: targetName(model.listen.resolvedTarget),
                          badge: settings.target == "system" ? L("跟随系统") : nil, options: targetOptions) { model.targetSelection = $0 }
            }
            OnboardingNotesTeaser(ling: model.ling)
        }
    }

    private var heardName: String {
        if case .fixed(let l) = settings.sourceMode { return l.name }
        return model.listen.activeLang.map { L("自动 · \($0.name)") } ?? L("自动识别")
    }
    private var sourceOptions: [(id: String, title: String)] {
        [("auto", L("自动识别"))] + sourceLanguages.map { ($0.locale, $0.name) }
    }
    private var targetOptions: [(id: String, title: String)] {
        [("system", L("跟随系统"))] + targetLanguages.map { ($0.code, $0.name) }
    }

    // MARK: Step 4: speaking, only for those who want it

    /// The checklist shows once speaking is on (or was already on); before that, a yes/no.
    private var speakSetupShown: Bool {
        switch model.onboardingSpeakSetup {
        case .followSetting: settings.speakEnabled
        case .ask: false
        case .checklist: true
        }
    }

    private var speaking: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 24) {
                title(L("线上开会时要说外语吗？"), L("按住一个键说\(settings.speakFromLang.name)，线上的人听到翻译后的语音。"))
                Spacer()
                if speakSetupShown { talkKeyHint }
            }
            if speakSetupShown { speakChecklist } else { speakChoice }
        }
    }

    private var speakChoice: some View {
        HStack(spacing: 14) {
            choiceCard(L("要，现在设置"), L("约 2 分钟，会装一个虚拟麦克风")) {
                model.onboardingSpeakSetup = .checklist
                model.enableSpeaking(true)
            }
            choiceCard(L("先不用"), L("以后在设置 › 同声传译里打开")) { step = Self.done }
        }
        .padding(.top, 6)
    }

    private func choiceCard(_ title: String, _ detail: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink)
                Text(detail).font(.system(size: 13)).foregroundStyle(Palette.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(22)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var speakChecklist: some View {
        VStack(alignment: .leading, spacing: 14) {
            whiteCard {
                VStack(spacing: 0) {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("麦克风").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.ink)
                            Text("只在按住说话键时录音").font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                        }
                        Spacer()
                        switch model.micStatus {
                        case .authorized: done(L("已允许"))
                        case .notDetermined: primary(L("允许")) { model.requestMicrophone() }
                        default: primary(L("去打开")) { model.openMicrophoneSettings() }
                        }
                    }
                    .padding(.horizontal, 22).padding(.vertical, 14)
                    Divider().padding(.horizontal, 22)
                    MicSetupCard(installer: installer, deviceName: model.virtualMic?.name)
                        .padding(.horizontal, 6).padding(.vertical, 4)
                    if settings.speakEnabled && model.talkNeedsPermission {
                        Divider().padding(.horizontal, 22)
                        TalkKeyPermissionRow(model: model).padding(.horizontal, 6).padding(.vertical, 4)
                    }
                }
            }
            meetingAppStatus
        }
    }

    private var talkKeyHint: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(alignment: .bottom, spacing: 6) {
                if settings.talkKey.isRightOption {
                    key("⌥", L("右侧 option"), width: 96)
                } else {
                    ForEach(Array(settings.talkKey.keys.enumerated()), id: \.offset) {
                        key($0.element, "", width: $0.element.count > 2 ? 96 : 52)
                    }
                }
            }
            Text("可在设置中更改").font(.system(size: 11)).foregroundStyle(Palette.tertiary)
        }
    }

    // Turns green by itself once a meeting app reads the virtual mic.
    @ViewBuilder private var meetingAppStatus: some View {
        if model.virtualMic != nil && installer.passed {
            if let user = model.micUsers.first(where: { $0.state == .virtualMic }) {
                statusLine(ok: true, Text("\(user.name)已选虚拟麦克风，对方能听到译文"))
            } else if case .switched = model.systemMicState {
                // Apps on the default mic already hear it; only ones set to a specific mic need a change.
                statusLine(ok: true, Text("系统麦克风已换成 \(model.virtualMic?.name ?? "BlackHole 2ch")，用默认麦克风的会议软件不用再选"))
            } else {
                HStack(spacing: 10) {
                    (Text("最后一步：在会议软件中，将麦克风选为 ") + Text(model.virtualMic?.name ?? "BlackHole 2ch").bold())
                        .font(.system(size: 13)).foregroundStyle(Palette.ink)
                    Spacer(minLength: 8)
                    Text("等你选好…").font(.system(size: 12)).foregroundStyle(Palette.tertiary)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Palette.accentPale))
            }
        }
    }

    private func statusLine(ok: Bool, _ text: Text) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.ok)
            text.font(.system(size: 13)).foregroundStyle(Palette.ok)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.okPale))
    }

    private func key(_ top: String, _ bottom: String, width: CGFloat) -> some View {
        VStack(alignment: .leading) {
            Text(top).frame(maxWidth: .infinity, alignment: .trailing)
            Spacer(minLength: 0)
            Text(bottom)
        }
        .font(.system(size: 11)).foregroundStyle(Palette.secondary)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(width: width, height: 52)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(white: 0.84), lineWidth: 1))
        .overlay(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.84)).frame(height: 3).padding(.horizontal, 1)
        }
    }

    // MARK: Closing: where the app lives from now on

    private var closing: some View {
        VStack(alignment: .leading, spacing: 24) {
            title(L("好了，知了在菜单栏"), L("接下来会打开会议记录窗口，之后从右上角的图标找到它。"))
            menuBarSketch
            HStack(alignment: .top, spacing: 12) {
                tip(L("开会时点它"), L("开始听，出字幕和纪要"))
                if settings.speakEnabled {
                    tip(settings.talkKey.isRightOption ? L("按住右 ⌥ 说话") : L("按住 \(settings.talkKey.display) 说话"),
                        L("对方听到翻译后的语音"))
                }
                tip(L("会后看记录"), L("每场会都存在会议记录里"))
            }
        }
    }

    /// A slice of the menu bar with the app's icon ringed: where to look once this window is gone.
    private var menuBarSketch: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                Spacer()
                ForEach(["magnifyingglass", "wifi"], id: \.self) {
                    Image(systemName: $0).font(.system(size: 12)).foregroundStyle(Palette.tertiary)
                }
                BrandMark(size: 20)
                    .padding(3)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Palette.accentPale))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.accent, lineWidth: 1.5))
                    // Hangs below the bar, centred under the icon.
                    .overlay(alignment: .top) {
                        VStack(spacing: 4) {
                            Image(systemName: "arrow.up").font(.system(size: 14, weight: .semibold))
                            Text("就是它").font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(Palette.accentInk)
                        .fixedSize()
                        .offset(y: 42)
                    }
                Image(systemName: "battery.75percent").font(.system(size: 13)).foregroundStyle(Palette.tertiary)
                Text(Date.now, format: .dateTime.weekday().hour().minute())
                    .font(.system(size: 12)).foregroundStyle(Palette.secondary)
            }
            .padding(.horizontal, 18).frame(height: 36)
            .background(Color(white: 0.93))
            .zIndex(1)
            Color.white.frame(height: 64)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.line, lineWidth: 1))
        .accessibilityHidden(true)
    }

    private func tip(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.ink)
            Text(detail).font(.system(size: 12)).foregroundStyle(Palette.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white))
    }
}

/// Under the sample video: without a key, a hint that the same words become notes (the next step);
/// with one, where the subtitle bar can go.
struct OnboardingNotesTeaser: View {
    @ObservedObject var ling: LingClient

    var body: some View {
        if ling.hasKey {
            Text("字幕条可任意拖动，拖拽右下角可调整大小。").font(.system(size: 12)).foregroundStyle(Palette.secondary)
        } else if Recognition.cloudOnly {
            Text("先在上一步接上 Ling key，示例会议才能识别出实时字幕。").font(.system(size: 12)).foregroundStyle(Palette.accentInk)
        } else {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach([1.0, 0.8, 0.9], id: \.self) { w in
                        Capsule().fill(Color(white: 0.87)).frame(width: 110 * w, height: 6)
                    }
                }
                .frame(width: 110, alignment: .leading)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("开会时，这些字幕还能整理成纪要").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.ink)
                    Text("下一步接上 Ling 就有").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.line, lineWidth: 1))
        }
    }
}

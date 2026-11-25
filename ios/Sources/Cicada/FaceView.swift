import SwiftUI

/// 面对面, as the design: the top half turned around for the person across the table, each half with
/// its own hold-to-talk button, and between them 结束 and the two languages. Each half speaks its
/// own language, so the other person's half is in theirs (the app's strings where it has them).
struct FaceView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var face: FaceToFace

    var body: some View {
        VStack(spacing: 10) {
            FaceHalf(face: face, side: .them).rotationEffect(.degrees(180))
            middle
            FaceHalf(face: face, side: .me)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity)
        .background(Ink.ground.ignoresSafeArea())
        .preferredColorScheme(.light)
        .persistentSystemOverlays(.hidden)
    }

    private var middle: some View {
        VStack(spacing: 4) {
            HStack(spacing: 10) {
                Button { model.closeFace() } label: {
                    Image(systemName: "xmark").font(.system(size: 16, weight: .bold)).foregroundStyle(Ink.ink)
                        .frame(width: 44, height: 44).background(Color.white, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("结束"))
                Menu {
                    Picker(selection: Binding(get: { face.mine.locale }, set: { pick(mine: $0) })) {
                        ForEach(sourceLanguages, id: \.locale) { Text(verbatim: $0.name).tag($0.locale) }
                    } label: { Text("我说") }
                    Picker(selection: Binding(get: { face.theirs.locale }, set: { pick(theirs: $0) })) {
                        ForEach(sourceLanguages, id: \.locale) { Text(verbatim: $0.name).tag($0.locale) }
                    } label: { Text("对方说") }
                } label: {
                    HStack(spacing: 8) {
                        Text(verbatim: face.mine.name)
                        Image(systemName: "arrow.left.arrow.right").font(.footnote.weight(.semibold)).foregroundStyle(Ink.secondary)
                        Text(verbatim: face.theirs.name)
                    }
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Ink.ink)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color.white, in: Capsule())
                }
                .disabled(face.phase != .idle)
                .accessibilityLabel(Text("我说和对方说"))
                // 不用按键, where a spacer balanced the close button.
                Button { face.setHandsFree(!face.handsFree) } label: {
                    Image(systemName: face.handsFree ? "hand.raised.slash.fill" : "hand.raised.slash")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(face.handsFree ? .white : Ink.ink)
                        .frame(width: 44, height: 44)
                        .background(face.handsFree ? Ink.ink : Color.white, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("不用按键"))
                .accessibilityAddTraits(face.handsFree ? .isSelected : [])
            }
            if !face.problem.isEmpty {
                Text(verbatim: face.problem).font(.footnote).foregroundStyle(Ink.accentText)
            } else if face.handsFree {
                Text("不用按键 · 说完停一下就翻译，念完轮到对方").font(.footnote.weight(.semibold)).foregroundStyle(Ink.secondary)
            } else if case .hearing(.me) = face.phase {
                HStack(spacing: 6) { LiveDot(); Text("正在听你说") }.font(.footnote.weight(.semibold)).foregroundStyle(Ink.accentText)
            }
        }
        .frame(minHeight: 52)
    }

    private func pick(mine l: String) {
        guard let m = FaceToFace.lang(l) else { return }
        // Picking the other side's language swaps the two.
        face.setLanguages(mine: m, theirs: m == face.theirs ? face.mine : face.theirs)
    }

    private func pick(theirs l: String) {
        guard let t = FaceToFace.lang(l) else { return }
        face.setLanguages(mine: t == face.mine ? face.theirs : face.mine, theirs: t)
    }
}

private struct FaceHalf: View {
    @ObservedObject var face: FaceToFace
    let side: FaceToFace.Side

    private var lang: Lang { face.lang(side) }
    private var other: FaceToFace.Side { side == .me ? .them : .me }

    var body: some View {
        let (big, small, bigInk) = content
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: lang.name).font(.footnote).foregroundStyle(Ink.secondary)
            Text(verbatim: big)
                .font(.system(size: big.count > 80 ? 20 : 24, weight: .semibold))
                .foregroundStyle(bigInk ? Ink.ink : Ink.tertiary)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(nil, value: big)
            if !small.isEmpty {
                Text(verbatim: small).font(.subheadline).foregroundStyle(Ink.tertiary).lineLimit(3)
            }
            Spacer(minLength: 0)
            if face.handsFree {
                TurnButton(face: face, side: side, bundle: bundle).frame(maxWidth: .infinity)
            } else {
                HoldButton(face: face, side: side, label: buttonLabel)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            if face.phase == .hearing(side) {
                RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Ink.accent, lineWidth: 2)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// The big line, the grey one under it, and whether the big one is settled (ink) or not yet.
    private var content: (String, String, Bool) {
        switch face.phase {
        case .hearing(let s) where s == side:
            return (face.heard.isEmpty ? String(localized: "请说…", bundle: bundle) : face.heard, "", !face.heard.isEmpty)
        case .hearing:
            return (face.draftTranslation.isEmpty ? "…" : face.draftTranslation, "", false)
        case .translating(let s) where s == side:
            return (face.heard, String(localized: "正在翻译…", bundle: bundle), true)
        case .translating:
            return ("…", "", false)
        case .speaking(let s) where s == side:
            return (face.last?.said ?? "", String(localized: "正在念给对方", bundle: bundle), true)
        case .speaking:
            return (face.last?.translation ?? "", face.last?.said ?? "", true)
        case .idle:
            guard let last = face.last else { return (String(localized: "按住下面的按钮说话", bundle: bundle), "", false) }
            return last.side == side ? (last.said, last.translation, true) : (last.translation, last.said, true)
        }
    }

    private var buttonLabel: String {
        switch face.phase {
        case .hearing(let s): s == side ? String(localized: "松开就念给对方", bundle: bundle) : String(localized: "对方在说话", bundle: bundle)
        case .translating, .speaking: String(localized: "按住说话", bundle: bundle)
        case .idle: String(localized: "按住说话", bundle: bundle)
        }
    }

    /// The app's strings in this half's language: languages the app isn't translated into get English.
    private var bundle: Bundle { Self.bundle(lang.code) }

    static func bundle(_ code: String) -> Bundle {
        let folder = switch code {
        case "zh-CN": "zh-Hans"
        case "zh-TW": "zh-Hant"
        case "ja", "ko", "en": code
        default: "en"
        }
        return Bundle.main.path(forResource: folder, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
    }
}

/// The big round button: held, it listens (orange, with rings); let go, it translates and reads out.
private struct HoldButton: View {
    @ObservedObject var face: FaceToFace
    let side: FaceToFace.Side
    let label: String
    @State private var held = false

    private var hearing: Bool { face.phase == .hearing(side) }
    private var otherHearing: Bool { if case .hearing(let s) = face.phase { return s != side } else { return false } }

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(hearing ? Ink.accent : Ink.ink).frame(width: 84, height: 84)
                if hearing {
                    Circle().stroke(Ink.accent.opacity(0.16), lineWidth: 10).frame(width: 104, height: 104)
                    Image(systemName: "waveform").font(.system(size: 30, weight: .semibold)).foregroundStyle(.white)
                        .symbolEffect(.variableColor.iterative, isActive: true)
                } else {
                    Image(systemName: "mic.fill").font(.system(size: 30, weight: .semibold)).foregroundStyle(.white)
                }
            }
            .frame(width: 110, height: 110)
            .opacity(otherHearing ? 0.4 : 1)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !held, !otherHearing else { return }
                    held = true
                    face.press(side)
                }
                .onEnded { _ in
                    guard held else { return }
                    held = false
                    face.release(side)
                })
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: label))
            .accessibilityAddTraits(.isButton)
            // VoiceOver can't hold: a double tap starts, another one stops.
            .accessibilityAction {
                if hearing { face.release(side) } else { face.press(side) }
            }
            Text(verbatim: label).font(.subheadline.weight(hearing ? .semibold : .regular))
                .foregroundStyle(hearing ? Ink.ink : Ink.secondary)
                .accessibilityHidden(true)
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: hearing)
    }
}

/// 不用按键: the side being heard shows it (in its own language); a tap on the other gives it the turn.
private struct TurnButton: View {
    @ObservedObject var face: FaceToFace
    let side: FaceToFace.Side
    let bundle: Bundle

    private var hearing: Bool { face.phase == .hearing(side) }

    var body: some View {
        Button { face.giveTurn(side) } label: {
            VStack(spacing: 10) {
                ZStack {
                    Circle().fill(hearing ? Ink.accent : Ink.ground).frame(width: 64, height: 64)
                    Image(systemName: hearing ? "waveform" : "hand.tap").font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(hearing ? .white : Ink.ink)
                        .symbolEffect(.variableColor.iterative, isActive: hearing)
                }
                Text(verbatim: hearing ? String(localized: "在听你说 · 停一下就翻译", bundle: bundle)
                     : String(localized: "轮到你时点这里", bundle: bundle))
                    .font(.subheadline.weight(hearing ? .semibold : .regular))
                    .foregroundStyle(hearing ? Ink.accentText : Ink.secondary)
            }
            .frame(minHeight: 110)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .light), trigger: hearing)
    }
}

/// 面对面 under 开始听, a row of its own as tall as it: the icon and the name at full size, and
/// the languages and what happens (the phone reads it out), so it doesn't pass for another 开始听.
struct FaceRow: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var face: FaceToFace
    var onGlass = false

    var body: some View {
        Button { model.openFace() } label: {
            HStack(spacing: 12) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 19, weight: .medium)).foregroundStyle(Ink.ink)
                    .frame(width: 44, height: 44)
                    .background(Ink.ground, in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text("面对面").font(.headline).foregroundStyle(Ink.ink).lineLimit(1)
                    // Narrow (the iPad sidebar, English): the languages only, never a clipped sentence.
                    let pair = "\(Pref.name(of: face.mine)) ⇄ \(Pref.name(of: face.theirs))"
                    ViewThatFits(in: .horizontal) {
                        Text(verbatim: pair + " · " + L("手机念给对方听"))
                        Text(verbatim: pair)
                    }
                    .font(.footnote).foregroundStyle(Ink.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Ink.tertiary)
            }
            .padding(.leading, 7).padding(.trailing, 18)
            .frame(height: 58)
            .background {
                if onGlass { Capsule().fill(Color.white).shadow(color: Ink.ink.opacity(0.08), radius: 2, y: 1) }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(GlassRow(on: !onGlass))
        .accessibilityLabel(Text("面对面同声传译"))
    }
}

private struct GlassRow: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.glassEffect(.regular.interactive(), in: Capsule()) } else { content }
    }
}

extension AppModel {
    func openFace() {
        guard !room.isRunning else { return }
        face.open()
        showFace = true
    }

    func closeFace() {
        face.close()
        showFace = false
    }
}

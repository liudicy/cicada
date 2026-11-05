import SwiftUI

// The design's scheme 3 (知了当标题): the logo, the date and 会议记录 make the home's title, 开始听 is
// one glass bar under it, and while listening the same two places turn into 正在听 · 12:48 and the
// wave, who is talking and 结束. iPhone and the iPad's sidebar share them.

/// "11月4日 星期三 / 会议记录", or "● 正在听 · 12:48 / 会议室 · 英 → 中" while listening.
struct HomeTitle: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var room: RoomListen
    var logo: CGFloat = 52
    var titleSize: CGFloat = 28
    var trailing: AnyView? = nil

    var body: some View {
        HStack(spacing: 12) {
            Logo(size: logo)
            VStack(alignment: .leading, spacing: 1) {
                if room.isRunning {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        HStack(spacing: 6) {
                            LiveDot()
                            Text(L("正在听 · \(TranscriptExport.clock(room.elapsed))"))
                        }
                        .font(.footnote.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Ink.accentText)
                    }
                    Text(L("会议室 · \(Pref.pairText(room.languagePair.source, room.languagePair.target))"))
                        .font(.system(size: titleSize - 4, weight: .bold)).foregroundStyle(Ink.ink)
                        .lineLimit(1).minimumScaleFactor(0.7)
                } else {
                    Text(dateText(Date(), "MMMdEEEE")).font(.footnote).foregroundStyle(Ink.secondary)
                    Text("会议记录").font(.system(size: titleSize, weight: .bold)).foregroundStyle(Ink.ink)
                }
            }
            Spacer(minLength: 0)
            if let trailing, !room.isRunning { trailing }
        }
        .padding(.horizontal, 4)
    }
}

/// The orange dot that breathes while listening.
struct LiveDot: View {
    @State private var on = false

    var body: some View {
        Circle().fill(Ink.accent).frame(width: 8, height: 8)
            .shadow(color: Ink.accent.opacity(on ? 0 : 0.45), radius: on ? 6 : 0)
            .onAppear { withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: false)) { on = true } }
            .accessibilityHidden(true)
    }
}

/// 开始听 · 英语 → 简体中文 · the orange round button; while listening: the wave, who is talking, 结束.
struct ListenBar: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var room: RoomListen
    @AppStorage(Pref.source) private var source = "en-US"
    @AppStorage(Pref.target) private var target = "system"
    /// Glass on the ground (iPhone); white on the iPad's glass sidebar.
    var onGlass = false

    var body: some View {
        HStack(spacing: 10) {
            if room.isRunning { live } else { idle }
        }
        .frame(height: 58)
        .background {
            if onGlass {
                Capsule().fill(Color.white).shadow(color: Ink.ink.opacity(0.08), radius: 2, y: 1)
            }
        }
        .modifier(GlassCapsule(on: !onGlass))
        .animation(.snappy(duration: 0.25), value: room.isRunning)
    }

    private var idle: some View {
        Group {
            Text("开始听").font(.headline).foregroundStyle(Ink.ink).padding(.leading, 18)
            Rectangle().fill(Ink.line).frame(width: 1, height: 20)
            Menu {
                Picker(selection: $source) {
                    ForEach(sourceLanguages, id: \.locale) { Text(Pref.name(of: $0)).tag($0.locale) }
                } label: { Text("对方说") }
                Picker(selection: $target) {
                    Text("跟随系统").tag("system")
                    ForEach(targetLanguages, id: \.code) { Text($0.name).tag($0.code) }
                } label: { Text("翻译成") }
            } label: {
                Text(verbatim: "\(Pref.sourceName) → \(targetName(Pref.targetCode))")
                    .font(.subheadline).foregroundStyle(Ink.secondary).lineLimit(1).minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("对方说和翻译成"))
            Button { model.startListening() } label: {
                Image(systemName: "mic.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(Ink.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)
            .keyboardShortcut("r", modifiers: .command)
            .accessibilityLabel(Text("开始听"))
        }
    }

    private var live: some View {
        Group {
            Wave(level: room.level).padding(.leading, 16)
            let people = room.speakerCount
            Text(people >= 2 ? L("\(people) 人在说") : (room.status.isEmpty ? L("正在听") : room.status))
                .font(.subheadline).foregroundStyle(Ink.secondary).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { model.stopListening() } label: {
                Text("结束").font(.headline).foregroundStyle(.white)
                    .padding(.horizontal, 20).frame(height: 46)
                    .background(Ink.ink, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)
            .keyboardShortcut("r", modifiers: .command)
        }
    }
}

private struct GlassCapsule: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.glassEffect(.regular, in: Capsule()) } else { content }
    }
}

/// Five bars that follow the microphone's level.
struct Wave: View {
    let level: Float

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.08)) { t in
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { i in
                    let phase = sin(t.date.timeIntervalSinceReferenceDate * 7 + Double(i) * 1.3)
                    let h = 5 + CGFloat(level) * 16 * CGFloat(0.55 + 0.45 * phase)
                    Capsule().fill(Ink.accent).frame(width: 3, height: max(5, h))
                }
            }
            .frame(height: 22)
        }
        .accessibilityHidden(true)
    }
}

/// 正在听 on the iPhone: the title and bar as on the home, 字幕 / 纪要, and the lines as cards.
struct LivePhone: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var room: RoomListen
    @EnvironmentObject var notes: NotesEngine
    @State private var page: LivePage = .subtitles

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HomeTitle()
                ListenBar()
                PillSwitch(selection: $page, options: [(.subtitles, "字幕"), (.notes, notesTitle)])
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            switch page {
            case .subtitles: LiveLines().padding(.top, 12)
            case .notes:
                ScrollView { NotesPage(notes: notes.notes).padding(20) }
            }
        }
        .background(Ink.ground)
        .onChange(of: model.livePage) { page = model.livePage }
    }

    private var notesTitle: LocalizedStringKey {
        notes.fresh.isEmpty ? "纪要" : "纪要 · \(notes.fresh.count) 条新"
    }
}

enum LivePage: String { case subtitles, notes }

/// The lines so far as white cards, the one being said outlined in the accent; follows the newest.
struct LiveLines: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var room: RoomListen
    @ScaledMetric(relativeTo: .subheadline) private var srcSize: CGFloat = 14
    @ScaledMetric(relativeTo: .body) private var dstSize: CGFloat = 17

    var body: some View {
        let session = model.store.session(room.sessionID)
        let numbers = session.map(TranscriptExport.speakerNumbers) ?? [:]
        let names = session.map(SpeakerLabels.names) ?? [:]
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if room.lines.isEmpty && room.draft.isEmpty {
                        Text(room.status.isEmpty ? L("开始说话后，字幕会出现在这里") : room.status)
                            .font(.subheadline).foregroundStyle(Ink.secondary)
                            .frame(maxWidth: .infinity).padding(.top, 40)
                    }
                    ForEach(room.lines) { l in
                        card(who: numbers[l.id].map { SpeakerLabels.label($0, names) }, time: l.t, src: l.src, dst: l.dst, live: false)
                            .id(l.id)
                    }
                    if !room.draft.isEmpty {
                        card(who: nil, time: nil, src: room.draft, dst: room.draftTranslation.isEmpty ? nil : room.draftTranslation, live: true)
                            .id("draft")
                    }
                    Color.clear.frame(height: 40).id("end")
                }
                .padding(.horizontal, 16)
            }
            .onChange(of: room.lines.count) { withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            .onChange(of: room.draft) { proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    private func card(who: String?, time: Double?, src: String, dst: String?, live: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(live ? L("正在说") : [who, time.map(TranscriptExport.clock)].compactMap { $0 }.joined(separator: " · "))
                .font(.caption.weight(.semibold)).foregroundStyle(live ? Ink.accentText : Ink.ink)
            Text(src).font(.system(size: srcSize)).foregroundStyle(Ink.secondary).lineSpacing(2)
            if let dst { Text(dst).font(.system(size: dstSize)).foregroundStyle(live ? Ink.secondary : Ink.ink).lineSpacing(4) }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            if live { RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Ink.accent.opacity(0.35), lineWidth: 1.5) }
        }
    }
}

/// 正在听 on the iPad, beside the sidebar: 字幕 and 纪要 side by side when wide, switched when not.
struct LivePad: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var room: RoomListen
    @EnvironmentObject var notes: NotesEngine
    @State private var page: LivePage = .subtitles

    var body: some View {
        GeometryReader { g in
            if g.size.width >= 820 {
                HStack(alignment: .top, spacing: 22) {
                    column("字幕") { LiveLines().padding(.horizontal, -16) }
                    column(notesTitle) {
                        ScrollView {
                            NotesPage(notes: notes.notes).padding(20)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        }
                    }
                    .frame(width: g.size.width * 0.42)
                }
                .padding(.horizontal, 20).padding(.top, 18)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    PillSwitch(selection: $page, options: [(.subtitles, "字幕"), (.notes, notesTitle)]).frame(maxWidth: 320)
                    if page == .subtitles { LiveLines().padding(.horizontal, -16) } else {
                        ScrollView { NotesPage(notes: notes.notes).padding(20).background(Color.white, in: RoundedRectangle(cornerRadius: 22)) }
                    }
                }
                .padding(.horizontal, 20).padding(.top, 18)
            }
        }
        .background(Ink.ground)
        .onChange(of: model.livePage) { page = model.livePage }
    }

    private var notesTitle: LocalizedStringKey {
        notes.fresh.isEmpty ? "纪要" : "纪要 · \(notes.fresh.count) 条新"
    }

    private func column<C: View>(_ title: LocalizedStringKey, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(Ink.secondary).padding(.leading, 4)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

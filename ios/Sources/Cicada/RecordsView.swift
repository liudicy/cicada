import SwiftUI

/// 会议记录 (iPhone), as the design's home: the title with the import button, the 听会议室 card,
/// then the meetings as grouped white cards on the grey ground. Grouping and titles are the Mac's
/// (RecordList).
struct RecordsSplit: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var room: RoomListen
    @ObservedObject var store: SessionStore

    var body: some View {
        if room.isRunning {
            LivePhone()
        } else {
            records
        }
    }

    private var records: some View {
        NavigationStack(path: Binding(get: { model.selection.map { [$0] } ?? [] },
                                      set: { model.selection = $0.last })) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HomeTitle(trailing: AnyView(
                        Button { model.comingSoon = L("导入录音或视频") } label: { GlassIcon(systemName: "arrow.down.to.line") }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("导入录音或视频"))))
                    .padding(.top, 6)
                    ListenBar().padding(.top, 16)
                    if store.sessions.isEmpty {
                        EmptyRecords().frame(maxWidth: .infinity).padding(.top, 40)
                    } else {
                        RecordGroups(sessions: store.sessions, style: .cards, picked: nil) { model.selection = $0 }
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 120)
            }
            .background(Ink.ground)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { id in
                if let s = store.sessions.first(where: { $0.id == id }) { RecordView(session: s) }
            }
        }
    }
}

/// The app icon, drawn by the Mac's renderer at build time (ios/scripts/build.sh); its macOS margin
/// is cropped so the tile fills the frame.
struct Logo: View {
    let size: CGFloat
    private static let image = Bundle.main.path(forResource: "logo", ofType: "png").flatMap(UIImage.init(contentsOfFile:))

    var body: some View {
        Group {
            if let image = Self.image {
                Image(uiImage: image).resizable().scaledToFill().scaleEffect(1.24)
            } else {
                Ink.accent
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size / 4, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// iPad: the design's glass sidebar (title, import, settings, a search field, the meetings) beside
/// the open meeting, which is the newest until one is picked, as on the Mac.
struct PadRoot: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var room: RoomListen
    @ObservedObject var store: SessionStore

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 320)
                .padding(12)
            Group {
                if room.isRunning {
                    LivePad()
                } else if let s = shown {
                    NavigationStack { RecordView(session: s) }.id(s.id)
                } else {
                    Color.white
                }
            }
            .frame(maxWidth: .infinity)
        }
        .background(Ink.ground)
        .sheet(isPresented: $model.showSettings) {
            SettingsView(sheet: true)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HomeTitle(logo: 48, titleSize: 26, trailing: AnyView(HStack(spacing: 0) {
                Button { model.comingSoon = L("导入录音或视频") } label: { PadIcon(systemName: "arrow.down.to.line") }
                    .buttonStyle(.plain).accessibilityLabel(Text("导入录音或视频"))
                Button { model.showSettings = true } label: { PadIcon(systemName: "gearshape") }
                    .buttonStyle(.plain).accessibilityLabel(Text("设置"))
            }))
            .padding(.horizontal, 4)
            ListenBar(onGlass: true).padding(.top, 14).padding(.bottom, 12)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Ink.secondary)
                TextField(text: $model.query) { Text("搜索文字记录") }
                    .textFieldStyle(.plain)
                    .submitLabel(.search)
                if !model.query.isEmpty {
                    Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Ink.tertiary) }
                        .buttonStyle(.plain).accessibilityLabel(Text("清除"))
                }
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(Ink.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            ScrollView {
                let found = SearchView.matches(store.sessions, model.query)
                if store.sessions.isEmpty {
                    EmptyRecords().frame(maxWidth: .infinity).padding(.top, 40)
                } else if found.isEmpty {
                    Text(L("没有找到“\(model.query)”")).font(.subheadline).foregroundStyle(Ink.secondary)
                        .frame(maxWidth: .infinity).padding(.top, 40)
                } else {
                    RecordGroups(sessions: found, style: .sidebar, picked: shown?.id) { model.selection = $0 }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, 14)
        .padding(.top, 22)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var shown: Session? {
        if let id = model.selection, let s = store.sessions.first(where: { $0.id == id }) { return s }
        return store.sessions.first
    }
}

/// The sidebar's small white round buttons.
struct PadIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Ink.ink)
            .frame(width: 36, height: 36)
            .background(Color.white, in: Circle())
            .frame(width: 44, height: 44)
            .contentShape(Circle())
    }
}

struct EmptyRecords: View {
    var body: some View {
        Text("还没有会议").font(.title3.weight(.semibold)).foregroundStyle(Ink.ink).padding(32)
    }
}

/// 今天 / 昨天 / 本周 / months, each a card of rows (iPhone) or plain rows with the picked one on a
/// white card (iPad's sidebar, as in the design's iPad screen).
struct RecordGroups: View {
    @EnvironmentObject var model: AppModel
    enum Style { case cards, sidebar }
    let sessions: [Session]
    let style: Style
    let picked: String?
    let pick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(RecordList.groups(sessions), id: \.title) { group in
                SectionLabel(text: group.title)
                switch style {
                case .cards:
                    Card {
                        ForEach(Array(group.sessions.enumerated()), id: \.element.id) { i, s in
                            if i > 0 { Hairline() }
                            Button { pick(s.id) } label: { RecordRow(session: s, chevron: true) }
                                .buttonStyle(RowPress())
                                .contextMenu { menu(s) }
                        }
                    }
                case .sidebar:
                    VStack(spacing: 2) {
                        ForEach(group.sessions) { s in
                            Button { pick(s.id) } label: {
                                RecordRow(session: s, chevron: false)
                                    // White on the light glass needs a soft edge to read as picked.
                                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(s.id == picked ? Color.white : .clear)
                                        .shadow(color: Ink.ink.opacity(s.id == picked ? 0.10 : 0), radius: 6, y: 2))
                            }
                            .buttonStyle(RowPress())
                            .contextMenu { menu(s) }
                            .accessibilityAddTraits(s.id == picked ? .isSelected : [])
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The Mac's row menu, less what iOS can't do (Finder, the original file).
    @ViewBuilder private func menu(_ s: Session) -> some View {
        if s.renamed ?? !s.title.hasPrefix("会议 "), s.notes?.title != nil {
            Button { model.rename(s.id, to: "") } label: { Label("恢复自动标题", systemImage: "arrow.uturn.backward") }
        }
        Button(role: .destructive) { model.deleteSession(s.id) } label: { Label("删除", systemImage: "trash") }
            .disabled(s.id == model.store.liveID)
    }
}

/// A pressed row darkens slightly, like a system list cell.
struct RowPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(configuration.isPressed ? Ink.ink.opacity(0.05) : .clear)
    }
}

struct RecordRow: View {
    let session: Session
    let chevron: Bool
    /// Watched here so "3 人" comes and goes with 说话人识别 (a row's session doesn't change).
    @AppStorage(Pref.voices) private var voices = true

    private var runs: [SpeakerRail.Run] {
        SpeakerRail.runs(session, numbers: voices ? TranscriptExport.speakerNumbers(session) : [:])
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(RecordList.untitled(session) ? L("未命名会议") : RecordList.listTitle(session))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Ink.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(Self.meta(session, voices: voices))
                    .font(.footnote)
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
            }
            .padding(.leading, runs.isEmpty ? 0 : 14)
            // Scheme A's upright strip: each person's turns in grey, a bookmark of the meeting.
            .overlay(alignment: .leading) {
                if !runs.isEmpty { RailView(runs: runs, axis: .upright, thickness: 4).padding(.vertical, 2) }
            }
            Spacer(minLength: 0)
            if chevron { Chevron() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    /// "10:02 · 48 分钟 · 3 人 · 英 → 中 · 会议室", as in the design's rows.
    static func meta(_ s: Session, voices on: Bool) -> String {
        var parts = [RecordList.when(s), RecordList.length(s)]
        let voices = on ? SpeakerLabels.voiceNumbers(s.lines).count : 0
        if voices >= 2 { parts.append(L("\(voices) 人")) }
        if let pair = RecordList.pair(s, short: true) { parts.append(pair) }
        if s.sourceFile != nil { parts.append(L("导入")) } else if s.room == true { parts.append(L("会议室")) }
        return parts.joined(separator: " · ")
    }
}

/// Search on its own tab: titles and every line, original and translation.
struct SearchView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var store: SessionStore

    static func matches(_ sessions: [Session], _ query: String) -> [Session] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return sessions }
        return sessions.filter { s in
            s.displayTitle.localizedCaseInsensitiveContains(q)
                || s.lines.contains { $0.src.localizedCaseInsensitiveContains(q) || ($0.dst?.localizedCaseInsensitiveContains(q) ?? false) }
        }
    }

    var body: some View {
        let found = Self.matches(store.sessions, model.query)
        NavigationStack(path: $model.searchPath) {
            ScrollView {
                if found.isEmpty && !model.query.isEmpty {
                    Text(L("没有找到“\(model.query)”"))
                        .font(.body).foregroundStyle(Ink.secondary)
                        .frame(maxWidth: .infinity).padding(.top, 80)
                } else {
                    RecordGroups(sessions: found, style: .cards, picked: nil) { model.searchPath = [$0] }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 120)
                }
            }
            .background(Ink.ground)
            .navigationTitle("搜索")
            .navigationDestination(for: String.self) { id in
                if let s = store.sessions.first(where: { $0.id == id }) { RecordView(session: s) }
            }
            // At the top, under the title: the bottom is the tab bar's.
            .searchable(text: $model.query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("搜索文字记录"))
        }
    }
}

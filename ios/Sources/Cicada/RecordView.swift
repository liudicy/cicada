import AVFoundation
import SwiftUI

enum RecordPage: String { case transcript, notes }

/// One meeting, as the design's 会议记录 screen: one white sheet with the title, the voices as
/// chips, the 文字记录 / 纪要 switch, and the recording on a glass bar at the bottom.
struct RecordView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var ling: LingClient
    @EnvironmentObject var notes: NotesEngine
    let session: Session
    @StateObject private var player = RecordPlayer()
    @State private var needsKey = false
    /// What's typed into the title; nil until it is touched, so opening it changes nothing.
    @State private var titleDraft: String?
    @FocusState private var titleFocused: Bool
    /// The speaker picked on a chip (scheme A: only they are drawn in ink); nil follows the recording.
    private var picked: Int? { model.focusSpeaker }
    @AppStorage(Pref.voices) private var voicesOn = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // The design's 28 pt title; the day is in the line below, so a notes title's
                // leading "11月3日" goes.
                // Editable in place, as on the Mac: an unchanged title isn't a rename, an emptied
                // one goes back to the automatic title.
                TextField(text: Binding(get: { titleDraft ?? shownTitle }, set: setTitle), axis: .vertical) {
                    Text("未命名会议")
                }
                .font(.title.bold())
                .foregroundStyle(Ink.ink)
                .focused($titleFocused)
                .submitLabel(.done)
                .onChange(of: titleFocused) { if !titleFocused { commitTitle() } }
                .accessibilityLabel(Text("标题"))
                Text(Self.meta(session))
                    .font(.footnote).foregroundStyle(Ink.secondary)
                    .padding(.top, 4)
                let numbers = voicesOn ? TranscriptExport.speakerNumbers(session) : [:]
                let runs = SpeakerRail.runs(session, numbers: numbers)
                let focus = picked ?? playingNumber(numbers)
                if !runs.isEmpty {
                    MeetingRail(runs: runs, focus: focus,
                                playhead: player.available && (player.playing || player.now > 0) && player.duration > 0 ? player.now / player.duration : nil)
                        .padding(.top, 16)
                }
                SpeakerChips(session: session, shares: SpeakerRail.shares(runs), focus: focus, picked: $model.focusSpeaker).padding(.top, 12)
                if let n = picked {
                    Text(L("只看 \(SpeakerLabels.label(n, SpeakerLabels.names(session))) · \(runs.filter { $0.number == n }.count) 段 · 再点一下取消"))
                        .font(.footnote).foregroundStyle(Ink.secondary).padding(.top, 6)
                }
                PillSwitch(selection: $model.recordPage,
                           options: [(.transcript, "文字记录"), (.notes, "纪要")])
                    .padding(.top, 16)

                switch model.recordPage {
                case .transcript: TranscriptList(session: session, playing: player.lineID(in: session), focus: picked ?? playingNumber(voicesOn ? TranscriptExport.speakerNumbers(session) : [:]), dimOthers: picked != nil) { player.seek($0) }
                case .notes:
                    if notes.generatingID == session.id {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("正在整理纪要…").foregroundStyle(Ink.secondary)
                        }
                        .frame(maxWidth: .infinity).padding(.top, 40)
                    } else {
                        // Ling wrote "说话人 6" before anyone was named; show the names since given.
                        NotesPage(notes: session.notes.map { SpeakerLabels.named($0, SpeakerLabels.names(session)) })
                            .padding(.top, 18)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, player.available ? 110 : 40)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color.white)
        .navigationBarTitleDisplayMode(.inline)
        // The design's trailing glass pair: 生成纪要 and 导出, in ink like the back button.
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    if ling.hasKey { model.generateNotes(session.id) } else { needsKey = true }
                } label: {
                    if notes.generatingID == session.id { ProgressView() } else { Image(systemName: "arrow.triangle.2.circlepath") }
                }
                .disabled(notes.generatingID != nil || session.lines.isEmpty)
                .accessibilityLabel(Text("生成纪要"))
                ShareLink(item: TranscriptExport.markdown(session), subject: Text(session.displayTitle)) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel(Text("导出"))
            }
        }
        .tint(Ink.ink)
        .alert(Text("生成纪要"), isPresented: $needsKey) {
            Button("去填 key") { model.selection = nil; model.searchPath = []; model.tab = .settings; model.showSettings = true }
            Button("取消", role: .cancel) {}
        } message: {
            Text("前往 设置 › AI 服务 填入 Ling 的 API key 后即可生成。")
        }
        .safeAreaInset(edge: .bottom) {
            if let u = model.speakerUndo, u.session == session.id, !u.text.isEmpty, !player.available {
                SpeakerUndoBar(text: u.text) { model.undoSpeakerEdit() }.padding(.horizontal, 16).padding(.bottom, 8)
            }
            if player.available {
                VStack(spacing: 8) {
                    if let u = model.speakerUndo, u.session == session.id, !u.text.isEmpty {
                        SpeakerUndoBar(text: u.text) { model.undoSpeakerEdit() }
                    }
                    PlayerBar(player: player)
                }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    // The page fades out under the bar, as in the design, so text doesn't show through the glass.
                    .background(alignment: .bottom) {
                        LinearGradient(colors: [.white.opacity(0), .white], startPoint: .top, endPoint: .center)
                            .padding(.top, -24)
                            .ignoresSafeArea(edges: .bottom)
                    }
            }
        }
        .animation(.snappy(duration: 0.2), value: model.speakerUndo?.id)
        .onAppear { player.load(store: model.store, session: session) }
        .onChange(of: session.id) { titleDraft = nil; model.focusSpeaker = nil; player.load(store: model.store, session: session) }
        .onDisappear { player.stop() }
        .onReceive(NotificationCenter.default.publisher(for: .debugPlay)) { n in
            if let t = n.object as? Double { player.seek(t) }
        }
    }

    /// The speaker the recording is at, while it plays.
    private func playingNumber(_ numbers: [String: Int]) -> Int? {
        guard player.playing, let id = player.lineID(in: session) else { return nil }
        return numbers[id]
    }

    private var shownTitle: String { RecordList.untitled(session) ? "" : RecordList.listTitle(session) }

    /// Return ends the edit (the field wraps long titles, so it would otherwise add a line).
    private func setTitle(_ v: String) {
        if v.contains("\n") {
            titleDraft = v.replacingOccurrences(of: "\n", with: "")
            titleFocused = false
        } else {
            titleDraft = v
        }
    }

    private func commitTitle() {
        defer { titleDraft = nil }
        guard let draft = titleDraft?.trimmingCharacters(in: .whitespacesAndNewlines), draft != shownTitle else { return }
        model.rename(session.id, to: draft)
    }

    /// "今天 10:02 · 48 分钟 · 英 → 中".
    static func meta(_ s: Session) -> String {
        var parts = [dateText(s.startedAt, "MMMdHHmm"), RecordList.length(s)]
        if let pair = RecordList.pair(s, short: true) { parts.append(pair) }
        return parts.joined(separator: " · ")
    }
}

/// The voices told apart in this meeting, as chips in their colours ("Sarah", "说话人 3"); only
/// with 说话人识别 on, as the transcript. A chip renames the voice or merges it into another.
struct SpeakerChips: View {
    @EnvironmentObject var model: AppModel
    let session: Session
    /// Each speaker number's share of the meeting, shown on the chip ("Sarah · 58%").
    var shares: [Int: Double] = [:]
    /// Drawn in ink: the picked speaker, or the one playing.
    var focus: Int? = nil
    @Binding var picked: Int?
    @AppStorage(Pref.voices) private var voicesOn = true
    @State private var draft = ""
    /// The speaker number being named; on the model so a debug command can open it too.
    private var naming: Int? { model.namingSpeaker }

    var body: some View {
        let names = SpeakerLabels.names(session)
        let voices = voicesOn ? SpeakerLabels.voiceNumbers(session.lines) : [:]
        // Voice id by its speaker number.
        let byNumber = Dictionary(uniqueKeysWithValues: voices.map { ($1, $0) })
        let numbers = byNumber.keys.sorted()
        if !numbers.isEmpty {
            FlowLayout(spacing: 8) {
                ForEach(numbers, id: \.self) { n in
                    // Tap picks the speaker (only they stay in ink); a long press renames or merges.
                    Menu {
                        Button { draft = names[n] ?? ""; model.namingSpeaker = n } label: { Label("改名字", systemImage: "pencil") }
                        Section("其实是同一个人") {
                            ForEach(numbers.filter { $0 != n }, id: \.self) { other in
                                Button(L("并入 \(SpeakerLabels.label(other, names))")) {
                                    if let a = byNumber[n], let b = byNumber[other] { model.mergeSpeaker(session: session.id, a, into: b) }
                                }
                            }
                        }
                    } label: {
                        let on = focus == n
                        Text(shares[n].map { "\(SpeakerLabels.label(n, names)) · \(Int(($0 * 100).rounded()))%" } ?? SpeakerLabels.label(n, names))
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(on ? .white : Ink.ink)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 30)
                            .background(on ? Ink.ink : .white, in: Capsule())
                            .overlay(Capsule().strokeBorder(on ? Ink.ink : Ink.line, lineWidth: 1))
                            .contentShape(Capsule())
                    } primaryAction: {
                        picked = picked == n ? nil : n
                    }
                    .frame(minHeight: 44)
                    .accessibilityAddTraits(picked == n ? .isSelected : [])
                    .accessibilityHint(Text("只看这个人；按住可改名字，或和别人合并"))
                }
            }
            .onChange(of: model.namingSpeaker) { if let n = model.namingSpeaker, draft.isEmpty { draft = names[n] ?? "" } }
            .alert(Text("是谁"), isPresented: Binding(get: { naming != nil }, set: { if !$0 { model.namingSpeaker = nil } })) {
                TextField(L("输入名字"), text: $draft)
                Button("保存") { save(byNumber) }
                Button("取消", role: .cancel) { model.namingSpeaker = nil }
            }
        }
    }

    /// The Mac's rule: keeping Ling's guess stores nothing, so a later, better guess can still replace it.
    private func save(_ byNumber: [Int: Int]) {
        guard let n = naming, let voice = byNumber[n] else { return }
        model.namingSpeaker = nil
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let guess = session.voiceGuesses?[String(voice)]
        if let guess, name == guess.name { model.renameSpeaker(session: session.id, voice: voice, nil) }
        else if session.voiceNames?[String(voice)] != nil || !name.isEmpty { model.renameSpeaker(session: session.id, voice: voice, name) }
    }
}

/// "说话人 6 已改成 David · 撤销", dark above the player, the Mac toast's pale accent on 撤销, for a few seconds.
struct SpeakerUndoBar: View {
    let text: String
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Text(text).font(.subheadline).foregroundStyle(.white).lineLimit(2)
            Spacer(minLength: 0)
            Button("撤销", action: undo).font(.subheadline.weight(.semibold)).foregroundStyle(Color(red: 0.99, green: 0.93, blue: 0.906))
                .frame(minHeight: 44)
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 52)
        .background(Ink.ink, in: Capsule())
        .shadow(color: Ink.ink.opacity(0.18), radius: 10, y: 4)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

struct TranscriptList: View {
    let session: Session
    /// The line the recording is at, highlighted like the design's.
    let playing: String?
    /// Scheme A: this speaker's lines carry an ink bar, the rest a light grey one.
    var focus: Int? = nil
    /// A speaker was picked on purpose: the others' lines step back.
    var dimOthers = false
    let seek: (Double) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The design's 14 pt grey original over a 16 pt translation, scaling with the text size.
    @ScaledMetric(relativeTo: .subheadline) private var srcSize: CGFloat = 14
    @ScaledMetric(relativeTo: .callout) private var dstSize: CGFloat = 16

    var body: some View {
        let numbers = TranscriptExport.speakerNumbers(session), names = SpeakerLabels.names(session)
        // At the largest text sizes the time column would squeeze the text: the time goes on the
        // speaker's line instead.
        let inline = typeSize.isAccessibilitySize
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(session.lines.enumerated()), id: \.element.id) { i, l in
                let on = l.id == playing
                let mine = focus != nil && numbers[l.id] == focus
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    if !inline { time(l, on).frame(width: 40, alignment: .leading) }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            if inline { time(l, on) }
                            if session.sourceFile == nil {
                                Text(TranscriptExport.speakerName(l, numbers, names))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(l.speaker == "me" ? Ink.accentText : (focus == nil || mine ? Ink.ink : Ink.tertiary))
                            }
                        }
                        Text(l.src).font(.system(size: srcSize)).foregroundStyle(Ink.secondary).lineSpacing(2)
                        if let d = l.dst, d != l.src {
                            Text(d).font(.system(size: dstSize)).foregroundStyle(Ink.ink).lineSpacing(4)
                        }
                    }
                }
                .textSelection(.enabled)
                .opacity(dimOthers && !mine ? 0.4 : 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 14)
                .padding(.horizontal, 20)
                .background(on ? Ink.accent.opacity(0.06) : .clear)
                // The upright strip beside the text: each line in its speaker's run.
                .overlay(alignment: .leading) {
                    if !numbers.isEmpty {
                        RoundedRectangle(cornerRadius: 2).fill(mine ? SpeakerRail.focus : SpeakerRail.rest)
                            .frame(width: 4).padding(.vertical, 1).padding(.leading, 8)
                    }
                }
                .padding(.horizontal, -20)
                .overlay(alignment: .bottom) { if i < session.lines.count - 1 { Rectangle().fill(Ink.line).frame(height: 0.5) } }
            }
        }
        .padding(.top, 6)
        .overlay {
            if session.lines.isEmpty { Text("还没有句子").foregroundStyle(Ink.secondary).padding(.top, 40) }
        }
    }

    /// The time; with a recording it plays from that line.
    private func time(_ l: TranscriptLine, _ on: Bool) -> some View {
        Button { seek(l.t) } label: {
            Text(TranscriptExport.clock(l.t))
                .font(.caption.monospacedDigit().weight(on ? .semibold : .regular))
                .foregroundStyle(on ? Ink.accentText : Ink.tertiary)
        }
        .buttonStyle(.plain)
    }
}

struct NotesPage: View {
    let notes: MeetingNotes?
    /// The design's 16 pt notes text, as the transcript's translation.
    @ScaledMetric(relativeTo: .callout) private var size: CGFloat = 16

    var body: some View {
        if let n = notes, !n.summary.isEmpty || !n.topics.isEmpty {
            VStack(alignment: .leading, spacing: 22) {
                if !n.summary.isEmpty {
                    block("总结") { Text(n.summary).font(.system(size: size)).lineSpacing(5) }
                }
                if !n.topics.isEmpty {
                    block("议题") {
                        ForEach(n.topics) { t in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(TranscriptExport.clock(t.start)).font(.caption.monospacedDigit()).foregroundStyle(Ink.link)
                                    Text(t.title).font(.system(size: size, weight: .semibold))
                                }
                                if !t.summary.isEmpty {
                                    Text(t.summary).font(.subheadline).foregroundStyle(Ink.secondary).lineSpacing(3)
                                }
                                ForEach(t.points, id: \.self) { p in
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Circle().fill(Ink.tertiary).frame(width: 4, height: 4).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 5 }
                                        Text(p).font(.subheadline).foregroundStyle(Ink.ink).lineSpacing(3)
                                    }
                                }
                                if let f = t.fishbone, !f.branches.isEmpty { FishboneList(fishbone: f) }
                            }
                            .padding(.bottom, 6)
                        }
                    }
                }
                if !n.conclusions.isEmpty {
                    block("结论") {
                        ForEach(Array(n.conclusions.enumerated()), id: \.element.id) { i, c in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text("\(i + 1)").font(.system(size: size, weight: .bold)).foregroundStyle(Ink.link)
                                Text(c.text).font(.system(size: size)).lineSpacing(3)
                            }
                        }
                    }
                }
                if !n.todos.isEmpty {
                    block("待办") {
                        ForEach(n.todos) { t in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Image(systemName: "square").font(.system(size: size)).foregroundStyle(Ink.tertiary)
                                Text((t.owner.map { "\($0)：" } ?? "") + t.text).font(.system(size: size)).lineSpacing(3)
                            }
                        }
                    }
                }
                if !n.terms.isEmpty {
                    block("人名和术语") {
                        ForEach(n.terms) { t in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.name).font(.subheadline.weight(.semibold))
                                if !t.note.isEmpty { Text(t.note).font(.footnote).foregroundStyle(Ink.secondary) }
                            }
                        }
                    }
                }
            }
            .foregroundStyle(Ink.ink)
            .textSelection(.enabled)
        } else {
            Text("这场会议还没有纪要").foregroundStyle(Ink.secondary).frame(maxWidth: .infinity).padding(.top, 40)
        }
    }

    private func block<C: View>(_ title: LocalizedStringKey, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(Ink.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A topic's fishbone as the narrow Mac window draws it upright: the question, then each cause.
struct FishboneList: View {
    let fishbone: Fishbone

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(fishbone.question.isEmpty ? L("为什么") : fishbone.question).font(.subheadline.weight(.semibold))
            ForEach(fishbone.branches) { b in
                (Text(b.label).fontWeight(.semibold) + Text(verbatim: "：") + Text(b.detail))
                    .font(.subheadline).foregroundStyle(b.support == 0 ? Ink.secondary : Ink.ink).lineSpacing(3)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.ground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.top, 4)
    }
}

// MARK: - The recording

/// Plays the meeting's system.m4a; the transcript follows it and its times seek.
@MainActor
final class RecordPlayer: ObservableObject {
    @Published private(set) var now: Double = 0
    @Published private(set) var playing = false
    private(set) var duration: Double = 0
    private var audio: AVAudioPlayer?
    private var timer: Timer?

    var available: Bool { audio != nil }

    private var loaded: String?

    /// The meeting's recording; another meeting's replaces it (the page is reused when one is picked).
    func load(store: SessionStore, session: Session) {
        guard loaded != session.id else { return }
        stop()
        loaded = session.id
        audio = nil
        now = 0
        duration = 0
        objectWillChange.send()
        guard session.hasAudio else { return }
        let url = store.systemAudioURL(session.id)
        guard let a = try? AVAudioPlayer(contentsOf: url) else { return }
        audio = a
        duration = a.duration
        objectWillChange.send()
    }

    func toggle() {
        guard let audio else { return }
        if audio.isPlaying { audio.pause(); playing = false; timer?.invalidate(); return }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        audio.play(); playing = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let a = self.audio else { return }
                self.now = a.currentTime
                if !a.isPlaying { self.playing = false; self.timer?.invalidate() }
            }
        }
    }

    func seek(_ t: Double) {
        guard let audio else { return }
        audio.currentTime = min(max(0, t), duration)
        now = audio.currentTime
        if !audio.isPlaying { toggle() }
    }

    func stop() { audio?.stop(); playing = false; timer?.invalidate() }

    /// The last line that started at or before the playhead, once playing has begun.
    func lineID(in s: Session) -> String? {
        guard playing || now > 0 else { return nil }
        return s.lines.last(where: { $0.t <= now + 0.2 })?.id
    }
}

/// The design's glass bar: play / pause, a progress line, the time and the length.
struct PlayerBar: View {
    @ObservedObject var player: RecordPlayer

    var body: some View {
        HStack(spacing: 12) {
            Button(action: player.toggle) {
                Image(systemName: player.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(Ink.ink, in: Circle())
            }
            .accessibilityLabel(player.playing ? Text("暂停") : Text("播放"))
            VStack(spacing: 6) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Ink.line)
                        Capsule().fill(Ink.accent)
                            .frame(width: g.size.width * (player.duration > 0 ? min(1, player.now / player.duration) : 0))
                    }
                }
                .frame(height: 4)
                HStack {
                    Text(TranscriptExport.clock(player.now))
                    Spacer()
                    Text(TranscriptExport.clock(player.duration))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Ink.secondary)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 18)
        .frame(height: 62)
        .glassEffect(.regular, in: Capsule())
    }
}

extension Notification.Name {
    /// Debug `play:<seconds>`: the open record plays from there.
    static let debugPlay = Notification.Name("cicada.debugPlay")
}

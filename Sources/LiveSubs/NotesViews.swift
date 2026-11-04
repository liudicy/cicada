import AppKit
import SwiftUI

// Notes and transcript views shared by the live notes window and the main window (meeting
// records). The look follows the canvas: white ground, grey blocks for what matters most,
// framed lists with hairlines, orange only for what is happening now.

// MARK: - Notes

struct NotesContentView: View {
    let notes: MeetingNotes
    var fresh: Set<String> = []
    /// The meeting is still going: the last topic is "正在讲".
    var live = false
    /// The main window's page: the summary as a lead paragraph, quiet section labels, rules
    /// between rows instead of cards.
    var document = false
    var updating = false
    var summaryJustChanged = false
    /// 编辑 (document pages only): the working copy fields write into (nil = reading).
    var edit: Binding<MeetingNotes>? = nil
    /// The time of the last line the notes cover ("到 03:52").
    var coveredUntil: Double?
    /// Where the last topic ends when the meeting is over (its last line).
    var endedAt: Double?
    var onJump: (Double) -> Void = { _ in }

    var body: some View {
        if document {
            DocumentNotesView(notes: notes, fresh: fresh, live: live, updating: updating, edit: edit, endedAt: endedAt, onJump: onJump)
        } else {
            cards
        }
    }

    private var cards: some View {
        VStack(alignment: .leading, spacing: document ? 32 : 18) {
            if document && !notes.summary.isEmpty {
                Text(notes.summary).font(.system(size: 17)).lineSpacing(7).foregroundStyle(Palette.ink.opacity(0.9))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            } else if !notes.summary.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("总结").font(.system(size: 15, weight: .bold))
                        if summaryJustChanged { Tag(L("刚更新"), live: true) }
                        Spacer()
                        if notes.final { Tag(L("完整版")) } else if live {
                            Tag(coveredUntil.map { L("速记版 · 到 \(NotesEngine.clock($0))") } ?? L("速记版"))
                        }
                    }
                    Text(notes.summary).font(.system(size: 14)).lineSpacing(4).textSelection(.enabled)
                }
                .padding(.horizontal, 18).padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 18).fill(Palette.raised))
            }

            if !notes.topics.isEmpty {
                VStack(alignment: .leading, spacing: document ? 0 : 14) {
                    title(L("议题"))
                    ForEach(Array(notes.topics.enumerated()), id: \.element.id) { i, topic in
                        if document { Divider() }
                        TopicView(topic: topic,
                                  end: i + 1 < notes.topics.count ? notes.topics[i + 1].start : (live ? nil : endedAt),
                                  current: live && i == notes.topics.count - 1,
                                  updating: updating && i == notes.topics.count - 1, fresh: fresh, onJump: onJump)
                            .padding(.vertical, document ? 14 : 0)
                            .id(Self.topicID(topic))
                    }
                }
            }

            if !notes.conclusions.isEmpty || !notes.todos.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    title(notes.todos.isEmpty ? L("结论") : L("结论和待办"))
                    if document {
                        VStack(alignment: .leading, spacing: 0) { items }
                    } else {
                        FramedList { items }
                    }
                }
            }

            if !notes.terms.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    title(L("人名和术语"))
                    TermChips(terms: notes.terms, showHeard: true)
                }
            }
        }
    }

    /// Scroll target for a topic (the live notes window keeps the current one in view).
    static func topicID(_ topic: NoteTopic) -> String { "topic-\(topic.id)" }

    @ViewBuilder
    private func title(_ text: String) -> some View {
        if document {
            Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.secondary).padding(.bottom, 2)
        } else {
            SectionTitle(text)
        }
    }

    @ViewBuilder
    private var items: some View {
        let all = notes.conclusions + notes.todos
        ForEach(Array(all.enumerated()), id: \.offset) { i, item in
            let todo = i >= notes.conclusions.count
            if document && i > 0 { Divider() }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if todo {
                    Image(systemName: "circle").font(.system(size: document ? 13 : 11)).foregroundStyle(Palette.tertiary)
                } else if document {
                    Circle().fill(Palette.ink.opacity(0.55)).frame(width: 5, height: 5)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
                        .frame(width: 13)
                }
                Text(item.text + (item.owner.map { "（\($0)）" } ?? ""))
                    .font(.system(size: 14)).lineSpacing(2)
                    .foregroundStyle(item.support == 0 ? Palette.tertiary : Palette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if item.support == 0 {
                    Tag(L("依据较少"))
                } else if let t = item.t {
                    TimeLink(text: L("\(NotesEngine.clock(t)) · \(item.support) 句"), t: t, onJump: onJump)
                } else {
                    Tag(L("依据 \(item.support) 句"))
                }
            }
            .padding(.horizontal, document ? 0 : 16).padding(.vertical, 11)
            if !document && i < all.count - 1 { Divider() }
        }
    }
}

/// The main window's page: the conclusions first in one quiet block, the summary, then the topics
/// as numbered rows that open to their points. Less on screen at once than the live window's cards.
private struct DocumentNotesView: View {
    let notes: MeetingNotes
    let fresh: Set<String>
    let live: Bool
    let updating: Bool
    /// 编辑: the working copy fields write into (nil = reading).
    let edit: Binding<MeetingNotes>?
    let endedAt: Double?
    let onJump: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 40) {
            let items = notes.conclusions + notes.todos
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(notes.todos.isEmpty ? L("结论") : L("结论和待办"))
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.secondary)
                        .padding(.bottom, 2)
                    ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                        conclusion(item, index: i + 1, todo: i >= notes.conclusions.count)
                    }
                }
                .padding(.horizontal, 24).padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14).fill(Palette.raised))
            }

            if !notes.summary.isEmpty {
                if let edit {
                    TextEditor(text: edit.summary)
                        .font(.system(size: 15)).lineSpacing(9).foregroundStyle(Palette.body)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 96)
                        .modifier(NotesEditField())
                } else {
                    Text(notes.summary).font(.system(size: 15)).lineSpacing(9).foregroundStyle(Palette.body)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }

            if !notes.topics.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text("议题").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.tertiary).padding(.bottom, 8)
                    ForEach(Array(notes.topics.enumerated()), id: \.element.id) { i, topic in
                        let current = live && i == notes.topics.count - 1
                        Rectangle().fill(MainWindowView.hairline).frame(height: 1)
                        DocumentTopicRow(index: i, topic: topic, current: current,
                                         updating: updating && current, fresh: fresh,
                                         edit: edit.map { e in Binding(
                                            get: { e.wrappedValue.topics[i] },
                                            set: { e.wrappedValue.topics[i] = $0 }) },
                                         startOpen: i == 0 || current, onJump: onJump)
                            .id(NotesContentView.topicID(topic))
                    }
                    Rectangle().fill(MainWindowView.hairline).frame(height: 1)
                }
            }

            if !notes.terms.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("人名和术语").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.tertiary)
                    TermChips(terms: notes.terms, showHeard: false)
                }
            }
        }
    }

    /// A conclusion reads as a plain sentence, numbered, with its numbers and dates marked; clicking it
    /// jumps to the lines behind it. One with little support stays grey.
    private func conclusion(_ item: NoteItem, index: Int, todo: Bool) -> some View {
        let weak = item.support == 0
        let text = item.text + (item.owner.map { "（\($0)）" } ?? "")
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                if todo { Image(systemName: "circle").font(.system(size: 11)) } else { Text("\(index)").font(.system(size: 12).monospacedDigit()) }
            }
            .fontWeight(.semibold).foregroundStyle(weak ? Palette.secondary : Palette.link).frame(width: 16, alignment: .leading)
            if let edit {
                let isTodo = todo
                TextField("", text: Binding(
                    get: { isTodo ? edit.wrappedValue.todos[index - edit.wrappedValue.conclusions.count - 1].text
                                  : edit.wrappedValue.conclusions[index - 1].text },
                    set: { if isTodo { edit.wrappedValue.todos[index - edit.wrappedValue.conclusions.count - 1].text = $0 }
                           else { edit.wrappedValue.conclusions[index - 1].text = $0 } }
                ), axis: .vertical)
                .font(.system(size: 15)).lineSpacing(5).foregroundStyle(Palette.ink)
                .modifier(NotesEditField())
            } else {
                Text(weak ? AttributedString(text) : Highlight.facts(text))
                    .font(.system(size: 15)).lineSpacing(5)
                    .foregroundStyle(weak ? Palette.secondary : Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if weak { Tag(L("依据较少")) }
                if let t = item.t, !weak { TimeLink(text: NotesEngine.clock(t), t: t, onJump: onJump) }
            }
        }
        .padding(.vertical, 3)
    }
}

/// 编辑 in the notes page: text sits in quiet fields on the ground tint, so it reads as writable.
private struct NotesEditField: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Palette.ground))
    }
}

/// Numbers with their units and day words ("5000 元", "20 岁", "3月3日", "周五晚上") in a conclusion,
/// marked so the facts can be picked out at a glance.
enum Highlight {
    private static let pattern = try! NSRegularExpression(pattern:
        "(\\d+\\s*月\\s*\\d+\\s*[日号])"
        + "|((下|本|这|上)?(周|星期|礼拜)[一二三四五六日天](早上|上午|中午|下午|晚上)?)"
        + "|(\\d[\\d,.]*\\s*(万|千|百|亿)?\\s*(元|块|美元|岁|人|个|次|天|周|个月|月|年|小时|分钟|点|号|%|％|k|K)?)"
        + "|((今天|明天|后天|昨天|月底|月初|年底)(早上|上午|中午|下午|晚上)?)")

    static func facts(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        let ns = text as NSString
        for m in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            // A lone digit (list numbers, "第1") is noise; keep multi-digit numbers, units and days.
            let hit = ns.substring(with: m.range)
            if hit.count < 2 { continue }
            guard let r = Range(m.range, in: text),
                  let lo = AttributedString.Index(r.lowerBound, within: out),
                  let hi = AttributedString.Index(r.upperBound, within: out) else { continue }
            out[lo..<hi].backgroundColor = Palette.mark
            out[lo..<hi].font = .system(size: 15, weight: .semibold)
        }
        return out
    }
}

private struct DocumentTopicRow: View {
    let index: Int
    let topic: NoteTopic
    let current: Bool
    let updating: Bool
    let fresh: Set<String>
    /// 编辑: the working copy this row's fields write into (nil = reading). Editing rows stay open.
    let edit: Binding<NoteTopic>?
    let onJump: (Double) -> Void
    @State private var open: Bool

    init(index: Int, topic: NoteTopic, current: Bool, updating: Bool, fresh: Set<String>,
         edit: Binding<NoteTopic>?, startOpen: Bool, onJump: @escaping (Double) -> Void) {
        self.index = index; self.topic = topic; self.current = current; self.updating = updating
        self.fresh = fresh; self.edit = edit; self.onJump = onJump
        _open = State(initialValue: startOpen)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button { withAnimation(.easeOut(duration: 0.2)) { open.toggle() } } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(String(format: "%02d", index + 1)).font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Palette.link).frame(width: 28, alignment: .leading)
                        if let edit {
                            TextField("", text: edit.title, axis: .vertical)
                                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink)
                                .modifier(NotesEditField())
                        } else {
                            Text(topic.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink)
                                .multilineTextAlignment(.leading)
                        }
                        if current { Tag(L("正在讲"), live: true) }
                        if fresh.contains(topic.title) && !current { Tag(L("新"), live: true) }
                        Spacer(minLength: 8)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(edit != nil)
                if edit == nil {
                    TimeLink(text: NotesEngine.clock(topic.start), t: topic.start, onJump: onJump)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.secondary).rotationEffect(.degrees(open ? 90 : 0))
                }
            }
            .padding(.vertical, 15)

            if open || edit != nil {
                VStack(alignment: .leading, spacing: 7) {
                    if let edit {
                        if !topic.summary.isEmpty {
                            TextEditor(text: edit.summary)
                                .font(.system(size: 14)).lineSpacing(6).foregroundStyle(Palette.body)
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 56)
                                .modifier(NotesEditField())
                        }
                        ForEach(edit.wrappedValue.points.indices, id: \.self) { i in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("·").foregroundStyle(Palette.secondary)
                                TextField("", text: Binding(
                                    get: { edit.wrappedValue.points[i] },
                                    set: { edit.wrappedValue.points[i] = $0 }
                                ), axis: .vertical)
                                .font(.system(size: 14)).lineSpacing(5).foregroundStyle(Palette.ink)
                                .modifier(NotesEditField())
                            }
                        }
                    } else {
                        if !topic.summary.isEmpty {
                            Text(topic.summary).font(.system(size: 14)).lineSpacing(6).foregroundStyle(Palette.body)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(Array(topic.points.enumerated()), id: \.offset) { i, p in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("·").foregroundStyle(Palette.secondary)
                                Text(p).font(.system(size: 14)).lineSpacing(5).foregroundStyle(Palette.ink).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                if fresh.contains(p) { Tag(L("新"), live: true) }
                            }
                            .help(topic.pointTime(i).map { NotesEngine.clock($0) } ?? "")
                            .modifier(FadeIn(active: fresh.contains(p)))
                        }
                        if let fish = topic.fishbone { FishboneView(fishbone: fish, onJump: onJump).padding(.top, 4) }
                        if updating {
                            VStack(alignment: .leading, spacing: 7) {
                                SkeletonBar(fraction: 0.82, height: 10, warm: true)
                                SkeletonBar(fraction: 0.56, height: 10, warm: true)
                            }
                            .padding(.top, 2)
                        }
                    }
                }
                .padding(.leading, 36).padding(.bottom, 20)
                .transition(.opacity)
            }
        }
        .onChange(of: current) { _, now in if now { open = true } }
    }
}

private struct TopicView: View {
    let topic: NoteTopic
    /// The next topic's start, or the meeting's end; nil while it is still being discussed.
    let end: Double?
    let current: Bool
    let updating: Bool
    let fresh: Set<String>
    let onJump: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Button { onJump(topic.start) } label: {
                    Text(range)
                        .font(.system(size: 12, weight: current ? .semibold : .regular).monospacedDigit())
                        .foregroundStyle(current ? Palette.accentInk : Palette.tertiary)
                        .frame(width: column, alignment: .leading)
                }
                .buttonStyle(.plain).help("看原话")
                Text(topic.title).font(.system(size: 15, weight: .bold))
                if current { Tag(L("正在讲"), live: true) }
                if fresh.contains(topic.title) && !current { Tag(L("新"), live: true) }
            }
            VStack(alignment: .leading, spacing: 6) {
                if !topic.summary.isEmpty {
                    Text(topic.summary).font(.system(size: 13)).foregroundStyle(Palette.secondary).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(topic.points.enumerated()), id: \.offset) { i, p in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(fresh.contains(p) ? Palette.accent : Palette.ink.opacity(0.55)).frame(width: 4, height: 4)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
                        Text(p).font(.system(size: 14)).lineSpacing(2).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if fresh.contains(p) { Tag(L("新"), live: true) }
                        Spacer(minLength: 4)
                        if let t = topic.pointTime(i) { TimeLink(text: NotesEngine.clock(t), t: t, onJump: onJump) }
                    }
                    .modifier(FadeIn(active: fresh.contains(p)))
                }
                if let fish = topic.fishbone { FishboneView(fishbone: fish, onJump: onJump).padding(.top, 4) }
                if updating {
                    VStack(alignment: .leading, spacing: 7) {
                        SkeletonBar(fraction: 0.82, height: 10, warm: true)
                        SkeletonBar(fraction: 0.56, height: 10, warm: true)
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.leading, column + 10)
        }
        .padding(.vertical, current ? 10 : 0).padding(.horizontal, current ? 10 : 0)
        .background(RoundedRectangle(cornerRadius: 14).fill(current ? Palette.accentWash : .clear))
    }

    /// "01:04–02:02", or "02:03 起" for the topic being discussed.
    private var range: String {
        let from = NotesEngine.clock(topic.start)
        guard let end, end > topic.start + 1 else { return current ? L("\(from) 起") : from }
        return "\(from)–\(NotesEngine.clock(end))"
    }

    private var column: CGFloat { (end ?? topic.start) >= 3600 ? 104 : 76 }
}

/// A small time that jumps to that moment in the transcript.
struct TimeLink: View {
    let text: String
    let t: Double
    let onJump: (Double) -> Void
    @State private var hover = false

    var body: some View {
        Button { onJump(t) } label: {
            Text(text).font(.system(size: 12).monospacedDigit())
                .fontWeight(.medium)
                .foregroundStyle(Palette.link)
                .underline(hover)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .fixedSize()
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("回到原话")
    }
}

/// A fishbone drawn upright for a narrow window: the question on top, branches alternating on
/// either side of a spine. A branch no transcript line backs is dashed.
struct FishboneView: View {
    let fishbone: Fishbone
    var onJump: (Double) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                Text(fishbone.question.isEmpty ? L("为什么") : fishbone.question).font(.system(size: 13, weight: .bold))
                Spacer()
                Text("鱼骨图").font(.system(size: 11)).foregroundStyle(Palette.tertiary)
            }
            VStack(spacing: 6) {
                ForEach(Array(stride(from: 0, to: fishbone.branches.count, by: 2)), id: \.self) { i in
                    HStack(alignment: .center, spacing: 0) {
                        branch(fishbone.branches[i])
                        spine
                        if i + 1 < fishbone.branches.count {
                            branch(fishbone.branches[i + 1])
                        } else {
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("点击分支跳回原话").font(.system(size: 11)).foregroundStyle(Palette.tertiary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16).stroke(Palette.line, lineWidth: 1))
    }

    private var spine: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color(white: 0.84)).frame(width: 2)
            Circle().fill(Palette.ink).frame(width: 7, height: 7)
            Rectangle().fill(Color(white: 0.84)).frame(width: 2)
        }
        .frame(width: 18)
    }

    private func branch(_ b: FishboneBranch) -> some View {
        let weak = b.support == 0
        return Button { if let t = b.t { onJump(t) } } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(b.label).font(.system(size: 12, weight: .bold)).foregroundStyle(weak ? Palette.tertiary : Palette.ink)
                if !b.detail.isEmpty {
                    Text(b.detail).font(.system(size: 12)).foregroundStyle(Palette.secondary).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(weak ? Color.clear : Palette.raised))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(weak ? Color(white: 0.8) : .clear, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(weak ? L("依据较少，仅供参考") : L("看原话"))
    }
}

// MARK: - Transcript

/// When the user last turned a scroll wheel or swiped the trackpad in this app. SwiftUI also moves
/// a scroll view by itself (rows measured late, text rewrapping after a resize), so only a recent
/// real scroll may pause following.
@MainActor
enum UserScroll {
    private static var last = Date.distantPast
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            last = Date()
            return event
        }
    }

    static var recent: Bool { Date().timeIntervalSince(last) < 0.6 }
}

/// The transcript grouped under the notes' topics, oldest first. While live it follows the
/// newest line; scrolling up pauses that and collects new lines into a "↓ N 句新内容" button.
/// A search highlights matches in place instead of hiding the lines around them.
///
/// Every row is its own lazy child (a topic's card is drawn a row at a time, `cardSlice`), so a long
/// meeting lays out only what is on screen. What is being said right now is `partial`, a view that
/// watches the speech itself: with `.equatable()` a new word redraws that row, not the list.
struct TranscriptListView<Partial: View>: View, Equatable {
    let lines: [TranscriptLine]
    let topics: [NoteTopic]
    /// Spellings to highlight: the query, plus the notes' misrecognised forms of a name.
    var terms: [String] = []
    var currentMatch: String?
    var bilingual = true
    var live = false
    /// `partial` is on show (`TranscriptPartial.shows`).
    var partialShown = false
    var jumpTo: Double?
    /// Experimental: line id → speaker number for the other side's lines (SpeakerLabels).
    var speakers: [String: Int] = [:]
    /// When listening began, for the start mark shown before the first line.
    var startedAt: Date?
    @ViewBuilder var partial: Partial

    @State private var following = true
    @State private var seenCount = 0
    @State private var followQueued = false

    static func == (a: Self, b: Self) -> Bool {
        a.lines == b.lines && a.topics == b.topics && a.terms == b.terms && a.currentMatch == b.currentMatch
            && a.bilingual == b.bilingual && a.live == b.live && a.partialShown == b.partialShown
            && a.jumpTo == b.jumpTo && a.speakers == b.speakers && a.startedAt == b.startedAt
    }

    private var searching: Bool { !terms.isEmpty }

    private var groups: [(title: String, start: Double, lines: [TranscriptLine])] {
        guard !topics.isEmpty else { return [("", 0, lines)] }
        var out: [(String, Double, [TranscriptLine])] = []
        for (i, t) in topics.enumerated() {
            let end = i + 1 < topics.count ? topics[i + 1].start : .infinity
            let first = i == 0 ? -Double.infinity : t.start
            let ls = lines.filter { $0.t >= first && $0.t < end }
            if !ls.isEmpty { out.append((t.title, t.start, ls)) }
        }
        return out
    }

    /// One lazy child: a topic's title, or one line of its card.
    private enum Item: Identifiable {
        case header(title: String, start: Double, gap: Bool)
        case line(TranscriptLine, first: Bool, last: Bool, label: Bool, gap: Bool)
        var id: String {
            switch self {
            case .header(_, let start, _): "group-\(start)"
            case .line(let l, _, _, _, _): l.id
            }
        }
    }

    private var items: [Item] {
        let gs = groups
        let starts = SpeakerLabels.runStarts(lines, speakers)
        var out: [Item] = []
        for (gi, g) in gs.enumerated() {
            if !g.title.isEmpty { out.append(.header(title: g.title, start: g.start, gap: gi > 0)) }
            for (i, l) in g.lines.enumerated() {
                // The line being spoken closes the last card when it shows.
                let last = i == g.lines.count - 1 && !(gi == gs.count - 1 && partialShown)
                // With voices told apart, a name only where the speaker changes (and atop each topic).
                out.append(.line(l, first: i == 0, last: last, label: speakers.isEmpty || i == 0 || starts.contains(l.id),
                                 gap: gi > 0 && i == 0 && g.title.isEmpty))
            }
        }
        return out
    }

    private struct Edge: Equatable {
        var distance: CGFloat
        var height: CGFloat
        var container: CGFloat
    }

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(items) { item in
                            switch item {
                            case .header(let title, let start, let gap):
                                Text("\(NotesEngine.clock(start)) · \(title)")
                                    .font(.system(size: 13, weight: .bold)).foregroundStyle(Palette.secondary)
                                    .padding(.top, gap ? 16 : 6).padding(.bottom, 10)
                            case .line(let l, let first, let last, let label, let gap):
                                VStack(alignment: .leading, spacing: 0) {
                                    row(l, label: label)
                                    if !last { Divider() }
                                }
                                .cardSlice(first: first, last: last)
                                .padding(.top, gap ? 10 : 0)
                            }
                        }
                        if partialShown {
                            VStack(alignment: .leading, spacing: 0) {
                                if !lines.isEmpty { Divider() }
                                partial
                            }
                            .cardSlice(first: lines.isEmpty, last: true)
                            .id("partial")
                        }
                        if lines.isEmpty && !partialShown {
                            if live {
                                TranscriptWaitingView(startedAt: startedAt)
                            } else {
                                Text("说话的内容会出现在这里").font(.system(size: 13)).foregroundStyle(Palette.tertiary)
                                    .frame(maxWidth: .infinity).padding(.top, 40)
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.bottom, 12)
                }
                .onScrollGeometryChange(for: Edge.self) { g in
                    Edge(distance: g.contentSize.height - g.contentOffset.y - g.containerSize.height,
                         height: g.contentSize.height, container: g.containerSize.height)
                } action: { old, new in
                    if new.height != old.height || new.container != old.container {
                        // Not only new lines move the bottom: a translation arriving under its line,
                        // topic headers from a notes update, rows the lazy stack only now measured,
                        // the window resizing. Following means staying on the newest line through all of them.
                        if new.distance > 1 { follow(proxy) }
                    } else if new.distance < 40 {
                        if !following { following = true }
                    } else if following, new.distance > 60, UserScroll.recent {
                        // The reader scrolled up (content growing or reflowing never pauses following).
                        following = false
                        seenCount = lines.count
                    }
                }
                .onChange(of: lines.count) { _, _ in follow(proxy) }
                .onChange(of: partialShown) { _, _ in follow(proxy) }
                .onChange(of: currentMatch) { _, id in
                    guard let id, let line = lines.first(where: { $0.id == id }) else { return }
                    reveal(line, anchor: .center, proxy)
                }
                .onChange(of: jumpTo) { _, t in
                    guard let t, let target = lines.first(where: { $0.t >= t - 1 }) ?? lines.last else { return }
                    following = false
                    seenCount = lines.count
                    reveal(target, anchor: .top, proxy)
                }
                .onAppear {
                    UserScroll.install()
                    seenCount = lines.count
                    if let t = jumpTo, let target = lines.first(where: { $0.t >= t - 1 }) {
                        following = false
                        reveal(target, anchor: .top, proxy)
                    } else if live {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }

                if live, !following, !searching, lines.count > seenCount {
                    newLinesButton { following = true; proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
    }

    /// A row the lazy stack hasn't drawn yet lands where its height was guessed: jump, then settle
    /// once it is measured.
    private func reveal(_ line: TranscriptLine, anchor: UnitPoint, _ proxy: ScrollViewProxy) {
        proxy.scrollTo(line.id, anchor: anchor)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation { proxy.scrollTo(line.id, anchor: anchor) }
        }
    }

    /// Once per turn of the run loop, after layout: scrolling from inside a layout pass, while rows
    /// are still being measured, could leave the view past the end of what is drawn (a blank window).
    private func follow(_ proxy: ScrollViewProxy) {
        guard live, following, !searching, !followQueued else { return }
        followQueued = true
        DispatchQueue.main.async {
            followQueued = false
            guard following, !searching else { return }
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    private func newLinesButton(_ action: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.white.opacity(0), .white], startPoint: .top, endPoint: .bottom).frame(height: 40)
            Button(action: action) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down").font(.system(size: 12, weight: .bold))
                    Text("\(lines.count - seenCount) 句新内容").font(.system(size: 13, weight: .semibold))
                    if let last = lines.last {
                        Text(last.src).font(.system(size: 13)).foregroundStyle(Color(white: 0.74)).lineLimit(1)
                    }
                }
                .foregroundStyle(.white)
                .padding(.leading, 14).padding(.trailing, 18).frame(height: 40)
                .background(Capsule().fill(Palette.ink).shadow(color: .black.opacity(0.18), radius: 12, y: 6))
                .frame(maxWidth: 380)
                .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity)
            .background(Color.white)
        }
        .transition(.opacity)
    }

    private func matches(_ l: TranscriptLine) -> Bool {
        terms.contains { l.src.localizedCaseInsensitiveContains($0) || (l.dst ?? "").localizedCaseInsensitiveContains($0) }
    }

    private func highlighted(_ text: String, current: Bool) -> AttributedString {
        var a = AttributedString(text)
        for term in terms where !term.isEmpty {
            var from = a.startIndex
            while from < a.endIndex, let r = a[from...].range(of: term, options: .caseInsensitive) {
                a[r].backgroundColor = current ? Palette.accent : Palette.accentPale
                a[r].foregroundColor = current ? .white : Palette.accentInk
                from = r.upperBound
            }
        }
        return a
    }

    private func row(_ l: TranscriptLine, label: Bool = true) -> some View {
        let isMatch = l.id == currentMatch
        let latest = live && l.id == lines.last?.id
        let dim = searching && !matches(l)
        return HStack(alignment: .top, spacing: 12) {
            Text(NotesEngine.clock(l.t)).font(.system(size: 12, weight: isMatch ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(latest || isMatch ? Palette.accentInk : Palette.tertiary)
                .frame(width: l.t >= 3600 ? 56 : 40, alignment: .leading).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                if !label {
                } else if l.speaker == "me" { Text("你").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.accentInk) }
                else if let n = speakers[l.id] { SpeakerTag(number: n) }
                else if !speakers.isEmpty { UnknownSpeakerTag() }
                Text(highlighted(l.src, current: isMatch)).font(.system(size: 14)).lineSpacing(2).textSelection(.enabled)
                if bilingual, let d = l.dst, d != l.src {
                    Text(highlighted(d, current: isMatch)).font(.system(size: 13)).foregroundStyle(Palette.secondary)
                        .lineSpacing(2).textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(latest || isMatch ? Palette.accentWash : Color.clear)
        .opacity(dim ? 0.5 : 1)
    }

}

enum TranscriptPartial {
    /// The caption keeps the last sentence after it is finished: only show text not yet a line.
    static func shows(_ partial: String, live: Bool, after last: String?) -> Bool {
        let p = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        // A lone "." from background noise is not someone speaking.
        guard live, p.rangeOfCharacter(from: .alphanumerics) != nil else { return false }
        guard let last else { return true }
        return !last.contains(p) && !p.contains(last)
    }
}

/// The line being spoken, under the transcript. It watches the app itself so each new word redraws
/// only this row (`TranscriptListView` decides whether it shows).
struct LivePartialRow: View {
    @ObservedObject var model: AppModel
    let startedAt: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let time = startedAt.map { max(0, ctx.date.timeIntervalSince($0)) }
            HStack(alignment: .top, spacing: 12) {
                Text(time.map(NotesEngine.clock) ?? "").font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Palette.accentInk)
                    .frame(width: (time ?? 0) >= 3600 ? 56 : 40, alignment: .leading).padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .lastTextBaseline, spacing: 0) {
                        Text(model.liveSource).font(.system(size: 14)).foregroundStyle(Palette.secondary).lineSpacing(2)
                        AnimatedDots().font(.system(size: 14)).foregroundStyle(Palette.secondary)
                    }
                    Text("正在说").font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(Palette.accentWash)
        }
    }
}

extension View {
    /// One row of a `FramedList` card, drawn on its own so a long card can be lazy: the outline's
    /// top and rounded corners on the first row, its bottom on the last, only the sides between.
    func cardSlice(first: Bool, last: Bool) -> some View {
        let r: CGFloat = 16
        let shape = UnevenRoundedRectangle(topLeadingRadius: first ? r : 0, bottomLeadingRadius: last ? r : 0,
                                           bottomTrailingRadius: last ? r : 0, topTrailingRadius: first ? r : 0)
        return frame(maxWidth: .infinity, alignment: .leading)
            .clipShape(shape)
            .overlay {
                // Edges between rows are pushed outside the row and masked away; the sides stay whole.
                shape.stroke(Palette.line, lineWidth: 1)
                    .padding(.top, first ? 0 : -2).padding(.bottom, last ? 0 : -2)
                    .mask { Rectangle().padding(.horizontal, -2).padding(.top, first ? -2 : 0).padding(.bottom, last ? -2 : 0) }
            }
    }
}

/// The transcript before anyone has spoken: the start mark, two rows in the bilingual shape
/// lines will take, and 此刻 waiting for the first words.
struct TranscriptWaitingView: View {
    var startedAt: Date?

    private static let time: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if let startedAt { Text(Self.time.string(from: startedAt)).monospacedDigit() }
                Rectangle().fill(MainWindowView.hairline).frame(height: 1)
                Text("从这里开始听")
            }
            .font(.system(size: 12)).foregroundStyle(Palette.tertiary)
            .padding(.bottom, 14)
            FramedList {
                skeletonRow(0.7, 0.88)
                Divider()
                skeletonRow(0.54, 0.66).opacity(0.55)
            }
            HStack(spacing: 16) {
                legend(Palette.placeholder.opacity(0.6), L("原话"))
                legend(Palette.ink, L("译文"))
            }
            .padding(.top, 10).padding(.leading, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text("此刻").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.accentInk)
                HStack(spacing: 3) {
                    Text("等有人开口").font(.system(size: 15)).foregroundStyle(Palette.tertiary)
                    BlinkingCaret()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 14).fill(Palette.raised))
            .padding(.top, 28)
        }
        .padding(.top, 8)
    }

    private func skeletonRow(_ a: CGFloat, _ b: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SkeletonBar(fraction: a, height: 9)
            SkeletonBar(fraction: b, height: 11)
        }
        .padding(14)
    }

    private func legend(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 6) {
            Capsule().fill(color).frame(width: 14, height: 4)
            Text(title)
        }
        .font(.system(size: 12)).foregroundStyle(Palette.tertiary)
    }
}

/// A text caret blinking once a second.
struct BlinkingCaret: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            Rectangle().fill(Palette.accent).frame(width: 2, height: 17)
                .opacity(Int(ctx.date.timeIntervalSinceReferenceDate * 2) % 2 == 0 ? 1 : 0)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Small parts

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.secondary)
    }
}

struct Tag: View {
    let text: String
    var live = false
    init(_ text: String, live: Bool = false) {
        self.text = text
        self.live = live
    }
    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold))
            .foregroundStyle(live ? Palette.accentInk : Palette.secondary)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6).fill(live ? Palette.accentPale : Palette.fill))
            .fixedSize()
    }
}

/// 人名和术语: the corrected spellings first (what the reader can't work out alone), at most
/// `shown` until asked for the rest. All of them still go to the translation glossary.
struct TermChips: View {
    static let shown = 8
    let terms: [NoteTerm]
    var showHeard = true
    @State private var all = false

    var body: some View {
        let list = NoteTerm.ordered(terms)
        let extra = list.count - Self.shown
        FlowLayout(spacing: 6) {
            ForEach(all || extra <= 0 ? list : Array(list.prefix(Self.shown))) { t in
                (Text(t.name).bold() + Text(t.note.isEmpty ? "" : " \(t.note)")
                    + Text(!showHeard || t.heard.isEmpty ? "" : L(" · 原识别 \(t.heard.prefix(2).joined(separator: "、"))"))
                    .foregroundColor(Palette.tertiary))
                    .font(.system(size: 12))
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Palette.fill))
            }
            if extra > 0 {
                Button(all ? L("收起") : L("展开全部 \(list.count) 个")) { all.toggle() }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 5)
            }
        }
    }
}

struct FramedList<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.line, lineWidth: 1))
    }
}

/// Wraps chips onto as many lines as needed.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 { x = 0; y += row + spacing; row = 0 }
            x += s.width + spacing
            row = max(row, s.height)
        }
        return CGSize(width: width, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += row + spacing; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            row = max(row, s.height)
        }
    }
}

// MARK: - Motion (notes in progress)
// One moving thing at a time says the app is working. Driven by TimelineView rather than
// repeatForever animations, which the window's once-a-second redraw would restart.

func phase(_ date: Date, period: Double, delay: Double = 0) -> Double {
    let t = date.timeIntervalSinceReferenceDate - delay
    return (t.truncatingRemainder(dividingBy: period) + period).truncatingRemainder(dividingBy: period) / period
}

/// A small orange ring spinner.
struct Spinner: View {
    var size: CGFloat = 16
    var track = Palette.accentPale

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            ZStack {
                Circle().stroke(track, lineWidth: 2)
                Circle().trim(from: 0, to: 0.25)
                    .stroke(Palette.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(phase(ctx.date, period: 0.9) * 360))
            }
            .frame(width: size, height: size)
        }
        .accessibilityHidden(true)
    }
}

/// "…" whose dots light up one after another.
struct AnimatedDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 15)) { ctx in
            HStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { i in
                    Text(".").opacity(0.3 + 0.7 * (0.5 - 0.5 * cos(phase(ctx.date, period: 1.2, delay: Double(i) * 0.2) * 2 * .pi)))
                }
            }
        }
    }
}

/// The live dot beside "正在记录", breathing slowly.
struct LiveDot: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 15)) { ctx in
            Circle().fill(Palette.accent).frame(width: 7, height: 7)
                .opacity(0.35 + 0.65 * (0.5 + 0.5 * cos(phase(ctx.date, period: 1.4) * 2 * .pi)))
        }
    }
}

/// A placeholder line with a light sweeping across it. `warm` is the pale orange used inside
/// the topic being updated.
struct SkeletonBar: View {
    var fraction: CGFloat = 1
    var height: CGFloat = 12
    var warm = false

    var body: some View {
        let base = warm ? Color(red: 0.965, green: 0.89, blue: 0.86) : Color(red: 0.933, green: 0.941, blue: 0.953)
        let light = warm ? Color(red: 0.992, green: 0.953, blue: 0.933) : Color(red: 0.969, green: 0.973, blue: 0.98)
        GeometryReader { g in
            TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
                let x = phase(ctx.date, period: 1.4) * 2 - 0.5
                RoundedRectangle(cornerRadius: min(6, height / 2))
                    .fill(LinearGradient(stops: [.init(color: base, location: 0), .init(color: light, location: 0.5),
                                                 .init(color: base, location: 1)],
                                         startPoint: UnitPoint(x: x - 0.6, y: 0.5), endPoint: UnitPoint(x: x + 0.6, y: 0.5)))
                    .frame(width: g.size.width * fraction)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// Listening, nothing said yet: one quiet status row, then the notes' own shape waiting to be
/// filled, so the first version lands where the reader is already looking.
struct NotesListeningView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                SoundBars()
                Text("有人开口后，约半分钟出第一版").font(.system(size: 13)).foregroundStyle(Palette.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Palette.accentPale.opacity(0.7)))
            VStack(alignment: .leading, spacing: 10) {
                Text("总结").font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.placeholder)
                SkeletonBar(fraction: 0.94, height: 10)
                SkeletonBar(fraction: 0.8, height: 10)
                SkeletonBar(fraction: 0.56, height: 10)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("议题").font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.placeholder)
                topicSlot(time: "00:00", lines: [0.52, 0.88, 0.7])
                topicSlot(time: "--:--", lines: [0.4, 0.76]).opacity(0.6)
            }
            // Wraps: the English chips don't fit one line in a narrow window.
            FlowLayout(spacing: 6) {
                Text("会整理出").font(.system(size: 12)).foregroundStyle(Palette.tertiary).padding(.vertical, 4)
                ForEach([L("结论"), L("待办"), L("人名和术语"), L("鱼骨图")], id: \.self) { t in
                    Text(t).font(.system(size: 12)).foregroundStyle(Palette.secondary).fixedSize()
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(Palette.fill))
                }
            }
            .padding(.top, 4)
        }
    }

    private func topicSlot(time: String, lines: [CGFloat]) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(time).font(.system(size: 12).monospacedDigit()).foregroundStyle(Palette.placeholder)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(lines.enumerated()), id: \.offset) { i, f in
                    SkeletonBar(fraction: f, height: i == 0 ? 11 : 8)
                }
            }
        }
        .padding(14)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
    }
}

/// Four small orange bars rising and falling: "listening", at the size of a line of text.
struct SoundBars: View {
    var height: CGFloat = 22

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            HStack(spacing: 3) {
                ForEach(0..<4, id: \.self) { i in
                    let p = phase(ctx.date, period: 1.1, delay: Double(i) * 0.15)
                    Capsule().fill(Palette.accent).frame(width: 3, height: height)
                        .scaleEffect(x: 1, y: 0.3 + 0.7 * (0.5 - 0.5 * cos(p * 2 * .pi)))
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// The first version of the notes is being written: a spinner, how much has been heard, and
/// the shape of the notes shimmering where they will appear.
struct NotesGeneratingView: View {
    var heard: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Spinner()
                HStack(spacing: 0) {
                    Text("正在生成纪要")
                    AnimatedDots()
                }
                .font(.system(size: 15, weight: .bold))
                Spacer()
                if let heard, heard > 0 {
                    Text("已听到 \(heard) 句").font(.system(size: 12)).foregroundStyle(Palette.tertiary)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("总结").font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.placeholder)
                SkeletonBar()
                SkeletonBar(fraction: 0.92)
                SkeletonBar(fraction: 0.64)
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 18).fill(Palette.raised))
            VStack(alignment: .leading, spacing: 14) {
                Text("议题").font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.placeholder)
                topicRow(lines: [0.55, 0.88, 0.72])
                topicRow(lines: [0.42, 0.8]).opacity(0.6)
            }
        }
    }

    private func topicRow(lines: [CGFloat]) -> some View {
        HStack(alignment: .top, spacing: 12) {
            SkeletonBar(height: 12).frame(width: 36)
            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array(lines.enumerated()), id: \.offset) { i, f in
                    SkeletonBar(fraction: f, height: i == 0 ? 14 : 10)
                }
            }
        }
    }
}

/// "正在更新" pill in the header while notes that already exist are being updated.
struct UpdatingPill: View {
    var body: some View {
        HStack(spacing: 7) {
            Spinner(size: 12, track: Color(red: 0.965, green: 0.847, blue: 0.796))
            Text("正在更新").font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(Palette.accentInk)
        .padding(.horizontal, 11).padding(.vertical, 6)
        .background(Capsule().fill(Palette.accentPale))
        .fixedSize()
    }
}

/// A point that just arrived fades in from slightly below.
struct FadeIn: ViewModifier {
    let active: Bool
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(!active || shown ? 1 : 0)
            .offset(y: !active || shown ? 0 : 4)
            .onAppear { if active { withAnimation(.easeOut(duration: 0.6)) { shown = true } } }
    }
}

/// "已经 10 分钟没人说话 · 60 秒后结束": the meeting is about to end by itself. In the notes window
/// and the menu panel; neither takes focus, so a click lands on the buttons at once.
struct MeetingEndingStrip: View {
    @ObservedObject var model: AppModel
    let pending: MeetingEndWatch.Pending
    var compact = false
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.endingTitle(pending)).font(.system(size: compact ? 13 : 14, weight: .bold)).lineLimit(2)
                Text(model.endingDetail(pending, now: now)).font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Palette.secondary).lineLimit(2)
            }
            HStack(spacing: 8) {
                SoftButton(L("继续记录"), dark: true) { model.keepRecording() }
                SoftButton(L("现在结束")) { model.stop() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(compact ? 12 : 14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.accentPale))
        .onReceive(tick) { now = $0 }
    }
}

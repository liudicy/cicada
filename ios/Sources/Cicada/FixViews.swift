import SwiftUI

// 改正听错的词 on iPhone and iPad: the Mac's FixViews and WordListSettings in iOS idiom. The engine
// is the Mac's own (`LiveFixes`, `Vocabulary`); these only show it and pass taps back.

/// A line as shown, its fixed words with the Mac's dotted underline.
enum FixedText {
    /// The line with its applied fixes; each fixed word dotted, a word still waiting (这样改对吗？)
    /// on a pale wash as heard. The Mac's `TranscriptParagraphs.joinFixed` for one line.
    static func attributed(_ l: TranscriptLine) -> AttributedString {
        let (text, marks) = Correction.apply(l.fixes ?? [], to: l.src)
        var a = AttributedString(text)
        for m in marks {
            guard let lo = AttributedString.Index(m.lowerBound, within: a), let hi = AttributedString.Index(m.upperBound, within: a) else { continue }
            a[lo..<hi].underlineStyle = Text.LineStyle(pattern: .dot, color: Ink.tertiary)
        }
        for f in l.fixes ?? [] where f.ask == true {
            if let r = a.range(of: f.from) { a[r].backgroundColor = Ink.accentWash }
        }
        return a
    }

    /// The line's applied fixes, as the user sees them ("莫拉" → "Morpho").
    static func applied(_ l: TranscriptLine) -> [LineFix] { (l.fixes ?? []).filter(\.applied) }
}

/// 改这句… open: the meeting, the line, and what the editor starts with.
struct LineEdit: Identifiable, Equatable {
    var id: String { session + "/" + line }
    let session: String
    let line: String
    let start: String
}

/// A small button on a card or banner: ink for the answer that changes something, grey for the other.
struct FixButton: View {
    let title: LocalizedStringKey
    var dark = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(dark ? .semibold : .regular))
                .foregroundStyle(dark ? .white : Ink.ink)
                .padding(.horizontal, 16).frame(minHeight: 36)
                .background(dark ? Ink.ink : Color.white, in: Capsule())
                .overlay { if !dark { Capsule().strokeBorder(Ink.line, lineWidth: 1) } }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
    }
}

/// 这样改对吗？ while listening: a name the app couldn't check by sound, asked about once. 对 fixes
/// every line waiting on it and adds it to the word list; 稍后再看 asks again after the meeting.
struct FixAskCard: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var fixes: LiveFixes
    let session: String

    var body: some View {
        if let a = fixes.asking(in: session) {
            let c = Correction.core(a.fix.from, a.fix.to)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("这样改对吗？").font(.subheadline.weight(.semibold)).foregroundStyle(Ink.ink)
                    Spacer(minLength: 4)
                    if a.of > 1 { Text(verbatim: "1 / \(a.of)").font(.footnote.monospacedDigit()).foregroundStyle(Ink.tertiary) }
                }
                VStack(alignment: .leading, spacing: 3) {
                    (Text(c.from) + Text(verbatim: " → ").foregroundStyle(Ink.tertiary) + Text(c.to).bold())
                        .font(.body).foregroundStyle(Ink.ink)
                    Text(verbatim: "\(TranscriptExport.clock(a.line.t)) · \(a.line.src)")
                        .font(.footnote).foregroundStyle(Ink.tertiary).lineLimit(1)
                    Text("确认后整场一起改，以后也这样改").font(.footnote).foregroundStyle(Ink.secondary)
                }
                HStack(spacing: 8) {
                    FixButton(title: "对", dark: true) { fixes.answer(a.fix, yes: true, in: session) }
                    FixButton(title: "不对") { fixes.answer(a.fix, yes: false, in: session) }
                    Spacer(minLength: 0)
                    Button { fixes.later(a.fix, in: session) } label: {
                        Text("稍后再看").font(.subheadline).foregroundStyle(Ink.secondary).frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Ink.accent.opacity(0.35), lineWidth: 1.5))
            .shadow(color: Ink.ink.opacity(0.08), radius: 10, y: 4)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

/// Above a finished meeting's transcript: how many words were fixed, and the ones waiting for the
/// user, one at a time (对 / 不对 / 改成…). Nothing when there was nothing to fix.
struct FixReviewBanner: View {
    @ObservedObject var fixes: LiveFixes
    let session: Session
    let onShow: (String) -> Void
    let onEdit: (TranscriptLine, String) -> Void

    var body: some View {
        let waiting = fixes.pending(in: session.id)
        let fixedCount = session.lines.reduce(0) { $0 + FixedText.applied($1).count }
        if let first = waiting.first {
            let c = Correction.core(first.fix.from, first.fix.to)
            VStack(alignment: .leading, spacing: 8) {
                Button { onShow(first.line.id) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("改了 \(fixedCount) 处听错的词，\(waiting.count) 处等你确认")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Ink.ink)
                        (Text(verbatim: "\(c.from) → \(c.to)？") + Text(verbatim: " · \(TranscriptExport.clock(first.line.t))").foregroundStyle(Ink.tertiary))
                            .font(.footnote).foregroundStyle(Ink.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                HStack(spacing: 8) {
                    FixButton(title: "对", dark: true) { fixes.answer(first.fix, yes: true, in: session.id) }
                    FixButton(title: "不对") { fixes.answer(first.fix, yes: false, in: session.id) }
                    FixButton(title: "改成…") { onEdit(first.line, first.line.shown) }
                }
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Ink.accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Ink.accentWash, lineWidth: 1))
            // Not scrolled to on opening, as the Mac does: on a phone the banner would leave the
            // screen with it. A tap on the question goes there.
        } else if fixedCount > 0 {
            Text("改了 \(fixedCount) 处听错的词").font(.footnote).foregroundStyle(Ink.tertiary)
        }
    }
}

/// Under a line tapped open in the record: each fixed word, what it was heard as, 改回; and 改这句….
/// The Mac shows the same while the line is pointed at.
struct FixedWords: View {
    let line: TranscriptLine
    let onRevert: (LineFix) -> Void
    let onEdit: () -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(FixedText.applied(line).enumerated()), id: \.offset) { _, f in
                let c = Correction.core(f.from, f.to)
                HStack(spacing: 6) {
                    (Text("听成").foregroundStyle(Ink.tertiary) + Text(verbatim: " \(c.from)") + Text(verbatim: " → ").foregroundStyle(Ink.tertiary) + Text(c.to))
                        .font(.footnote)
                    Button("改回") { onRevert(f) }
                        .buttonStyle(.plain).font(.footnote.weight(.semibold)).foregroundStyle(Ink.link)
                }
                .padding(.horizontal, 10).frame(minHeight: 34)
                .background(Ink.ground, in: Capsule())
            }
            Button(action: onEdit) {
                Text("改这句…").font(.footnote.weight(.semibold)).foregroundStyle(Ink.link)
                    .padding(.horizontal, 10).frame(minHeight: 34)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 4)
    }
}

/// 改这句…: the line as shown, to rewrite. What changed becomes the user's own fix
/// (`LiveFixes.edit`), on every line heard the same way or only this one.
struct LineEditorSheet: View {
    let edit: LineEdit
    @ObservedObject var fixes: LiveFixes
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var everywhere = true
    @State private var keep = true
    @FocusState private var focused: Bool

    var body: some View {
        let same = fixes.sameHeard(lineID: edit.line, in: edit.session, edited: text)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Card(radius: 16) {
                        TextField(text: $text, axis: .vertical) { Text("改这句") }
                            .font(.body).lineSpacing(3)
                            .focused($focused)
                            .padding(14)
                    }
                    if let same {
                        (Text("听成").foregroundStyle(Ink.tertiary) + Text(verbatim: " \(same.heard)"))
                            .font(.subheadline).foregroundStyle(Ink.ink)
                            .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 8)
                        Card(radius: 16) {
                            if same.count > 1 {
                                choice(Text("整场听成 \(same.heard) 的 \(same.count) 处都改"), on: everywhere) { everywhere = true }
                                Hairline()
                                choice(Text("只改这一处"), on: !everywhere) { everywhere = false }
                                Hairline()
                            }
                            Toggle(isOn: $keep) { Text("记进词表，以后自动改").foregroundStyle(Ink.ink) }
                                .tint(Ink.ok)
                                .disabled(same.count > 1 && !everywhere)
                                .padding(.horizontal, 16).frame(minHeight: 50)
                        }
                    }
                }
                .padding(16)
            }
            .background(Ink.ground)
            .navigationTitle(Text("改这句"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("改成", action: apply).fontWeight(.semibold).disabled(same == nil)
                }
            }
        }
        .tint(Ink.ink)
        .presentationDetents([.medium, .large])
        .onAppear { text = edit.start; focused = true }
    }

    private func choice(_ title: Text, on: Bool, _ pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            HStack {
                title.foregroundStyle(Ink.ink).multilineTextAlignment(.leading)
                Spacer()
                if on { Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Ink.accent) }
            }
            .padding(.horizontal, 16).frame(minHeight: 50).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func apply() {
        guard let same = fixes.sameHeard(lineID: edit.line, in: edit.session, edited: text) else { dismiss(); return }
        let all = same.count > 1 ? everywhere : true
        fixes.edit(lineID: edit.line, in: edit.session, to: text, everywhere: all, remember: keep && all)
        dismiss()
    }
}

/// The last fix decision said back for a few seconds, with 撤销: the speaker toast's look.
struct FixToast: View {
    @ObservedObject var fixes: LiveFixes

    var body: some View {
        if let t = fixes.toast {
            SpeakerUndoBar(text: t.text) { fixes.undo() }.id(t.id)
        }
    }
}

// MARK: - 设置 › 词表

/// The switches for 改正听错的词 and the word list itself: each word, what it has been heard as,
/// where it came from and how often it fixed a line. Swipe to delete (撤销 in its place for a few
/// seconds), tap to change the spelling or the heard forms, 粘贴导入 for many at once.
struct WordListPage: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var ling: LingClient
    @ObservedObject var vocabulary: Vocabulary
    @AppStorage(Pref.fixMisheard) private var fixMisheard = true
    @AppStorage(Pref.askNames) private var askNames = true
    @State private var query = ""

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("会中改正听错的词").foregroundStyle(Ink.ink)
                        Spacer()
                        if ling.usable {
                            Toggle(isOn: $fixMisheard) { Text("会中改正听错的词") }.labelsHidden().tint(Ink.ok)
                        } else {
                            NavigationLink { KeyPage() } label: { Text("去设置").foregroundStyle(Ink.link) }.fixedSize()
                        }
                    }
                    Text(ling.usable ? L("走 \("Ling")，只发文字") : L("接上 AI 服务后才会改"))
                        .font(.footnote).foregroundStyle(Ink.secondary)
                }
                .padding(.vertical, 4)
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(isOn: $askNames) { Text("没见过的名字和专称先问我").foregroundStyle(Ink.ink) }
                        .tint(Ink.ok).disabled(!fixMisheard || !ling.usable)
                    Text("关掉就只改词表里的词和同音错字").font(.footnote).foregroundStyle(Ink.secondary)
                }
                .padding(.vertical, 4)
            }

            Section {
                if let d = model.deletedWord {
                    HStack {
                        (Text("已删除") + Text(verbatim: " ") + Text(d.term.word).bold()).foregroundStyle(Ink.secondary)
                        Spacer()
                        Button("撤销") { vocabulary.insert(d.term, at: d.index); model.deletedWord = nil }
                            .buttonStyle(.plain).fontWeight(.semibold).foregroundStyle(Ink.link)
                    }
                }
                if vocabulary.terms.isEmpty && model.deletedWord == nil {
                    Text("还没有词。把常用的人名、产品名贴进来，会中就照这些写法改")
                        .font(.subheadline).foregroundStyle(Ink.secondary).padding(.vertical, 6)
                }
                ForEach(shown, id: \.word) { t in
                    WordRow(term: t, vocabulary: vocabulary)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) { model.deleteWord(t) } label: { Label("删除", systemImage: "trash") }
                        }
                }
            } header: {
                HStack(spacing: 8) {
                    Text("词")
                    if !vocabulary.terms.isEmpty { Text(verbatim: "\(vocabulary.terms.count)").monospacedDigit() }
                }
            } footer: {
                Text("最多 \(Vocabulary.limit) 个，满了优先用最近的。只存在这台设备上")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Ink.ground)
        .contentMargins(.bottom, 100, for: .scrollContent)
        .navigationTitle(Text("词表"))
        .navigationBarTitleDisplayMode(.inline)
        .modifier(WordSearch(on: vocabulary.terms.count > 12, query: $query))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("粘贴导入…") { model.wordImport = UIPasteboard.general.hasStrings ? (UIPasteboard.general.string ?? "") : "" }
            }
        }
        .sheet(isPresented: Binding(get: { model.wordImport != nil }, set: { if !$0 { model.wordImport = nil } })) {
            WordImportSheet(vocabulary: vocabulary, text: model.wordImport ?? "")
        }
        .tint(Ink.ink)
        .animation(.snappy(duration: 0.2), value: model.deletedWord?.term.word)
    }

    /// Most recently useful first, then the rest newest first.
    private var shown: [Vocabulary.Term] {
        let q = Vocabulary.key(query)
        let all = vocabulary.terms.reversed().sorted { ($0.used ?? .distantPast) > ($1.used ?? .distantPast) }
        guard !q.isEmpty else { return all }
        return all.filter { Vocabulary.key($0.word).contains(q) || $0.heard.contains { Vocabulary.key($0).contains(q) } }
    }
}

/// 搜索词表 once the list is long enough to need it, as on the Mac (more than 12).
private struct WordSearch: ViewModifier {
    let on: Bool
    @Binding var query: String

    func body(content: Content) -> some View {
        if on { content.searchable(text: $query, prompt: Text("搜索词表")) } else { content }
    }
}

/// A heard form typed for a word that another word already has: whose it should be.
struct WordConflict: Equatable {
    let word: String
    let heard: String
    let owner: String
}

/// A deleted word, shown in its place with 撤销 for a few seconds.
struct DeletedWord: Equatable {
    let term: Vocabulary.Term
    let index: Int
}

/// One word: its spelling, what it was heard as, where it came from and how often it fixed a line.
/// Tapped, it opens in place: the spelling to change, heard forms to take off or add.
private struct WordRow: View {
    @EnvironmentObject var model: AppModel
    let term: Vocabulary.Term
    @ObservedObject var vocabulary: Vocabulary
    @State private var word = ""
    @State private var newHeard = ""
    @FocusState private var wordFocused: Bool

    private var editing: Bool { model.editingWord == term.word }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if editing {
                HStack {
                    TextField(text: $word) { Text(verbatim: term.word) }
                        .font(.body.weight(.semibold))
                        .focused($wordFocused)
                        .submitLabel(.done)
                        .onSubmit(commit)
                    Button("完成", action: commit).fontWeight(.semibold).buttonStyle(.plain).foregroundStyle(Ink.link)
                }
            } else {
                Button { word = term.word; model.editingWord = term.word } label: {
                    HStack(alignment: .firstTextBaseline) {
                        Text(term.word).font(.body.weight(.semibold)).foregroundStyle(Ink.ink)
                        Spacer(minLength: 8)
                        Text(term.source == "live" ? L("会中确认") : L("你加的"))
                            .font(.footnote).foregroundStyle(term.source == "live" ? Ink.accentText : Ink.tertiary)
                        Text(verbatim: "·").font(.footnote).foregroundStyle(Ink.tertiary)
                        Text(term.fixes > 0 ? L("改过 \(term.fixes) 次") : L("还没用上"))
                            .font(.footnote.monospacedDigit()).foregroundStyle(Ink.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if !term.heard.isEmpty || editing {
                FlowLayout(spacing: 6) {
                    ForEach(term.heard, id: \.self) { h in
                        HStack(spacing: 4) {
                            Text(h).font(.footnote).foregroundStyle(Ink.secondary)
                            if editing {
                                Button { vocabulary.forget(heard: h, word: term.word) } label: {
                                    Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(Ink.tertiary)
                                        .frame(width: 24, height: 28).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain).accessibilityLabel(Text("删掉这个听错的词"))
                            }
                        }
                        .padding(.leading, 10).padding(.trailing, editing ? 2 : 10).frame(minHeight: 28)
                        .background(Ink.ground, in: Capsule())
                    }
                    if editing {
                        TextField(text: $newHeard) { Text("加一个容易听错的词") }
                            .font(.footnote).frame(width: 150)
                            .submitLabel(.done)
                            .onSubmit(addHeard)
                            .padding(.horizontal, 10).frame(minHeight: 28)
                            .overlay(Capsule().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 2])).foregroundStyle(Ink.line))
                    }
                }
            }
            if let c = model.wordConflict, c.word == term.word {
                VStack(alignment: .leading, spacing: 6) {
                    Text("“\(c.heard)”已经记在 \(c.owner) 下").font(.subheadline).foregroundStyle(Ink.ink)
                    HStack(spacing: 8) {
                        FixButton(title: "改给 \(term.word)", dark: true) {
                            vocabulary.forget(heard: c.heard, word: c.owner)
                            vocabulary.confirm(heard: c.heard, word: term.word, source: term.source)
                            model.wordConflict = nil
                        }
                        FixButton(title: "两个都留") {
                            vocabulary.confirm(heard: c.heard, word: term.word, source: term.source)
                            model.wordConflict = nil
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .onChange(of: editing) { if editing { word = term.word; wordFocused = true } }
        .onAppear { if editing { word = term.word } }
    }

    private func commit() {
        if !newHeard.trimmingCharacters(in: .whitespaces).isEmpty { addHeard() }
        if model.wordConflict?.word == term.word { return }
        model.editingWord = nil
        vocabulary.rename(term.word, to: word)
    }

    private func addHeard() {
        model.addHeard(newHeard, to: term)
        newHeard = ""
    }
}

/// 粘贴导入: many words at once, each line one word, heard forms after "=". The counts follow what
/// is pasted, and the button says how many go in.
struct WordImportSheet: View {
    @ObservedObject var vocabulary: Vocabulary
    @Environment(\.dismiss) private var dismiss
    @State var text: String
    @State private var result: Vocabulary.ImportResult?

    var body: some View {
        let preview = vocabulary.preview(text)
        let n = preview.added + preview.updated
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("一行一个。常被听错的词，写在 = 后面").font(.subheadline).foregroundStyle(Ink.secondary)
                        .padding(.horizontal, 4)
                    TextEditor(text: $text)
                        .font(.body).frame(minHeight: 200)
                        .scrollContentBackground(.hidden)
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty {
                                Text(verbatim: "Uniswap V3\nMorpho = 莫拉、莫法\n巡检")
                                    .font(.body).foregroundStyle(Ink.tertiary.opacity(0.7))
                                    .padding(.leading, 5).padding(.top, 8).allowsHitTesting(false)
                            }
                        }
                        .padding(10)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    if let r = result {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("新增 \(r.added) · 补充听成 \(r.updated) · 跳过 \(r.skipped.count)")
                                .font(.subheadline.weight(.semibold)).foregroundStyle(Ink.ink)
                            if !r.skipped.isEmpty {
                                Text("第 \(r.skipped.map(String.init).joined(separator: "、")) 行没加进去：超过 40 个字")
                                    .font(.footnote).foregroundStyle(Ink.accentText)
                            }
                        }
                        .padding(.horizontal, 4)
                    } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("新增 \(preview.added) · 补充听成 \(preview.updated) · 跳过 \(preview.skipped.count)")
                            .font(.subheadline).foregroundStyle(Ink.secondary).padding(.horizontal, 4)
                    }
                }
                .padding(16)
            }
            .background(Ink.ground)
            .navigationTitle(Text("粘贴导入"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(result == nil ? "取消" : "完成") { dismiss() }
                }
                if result == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("导入 \(n) 个") { result = vocabulary.importText(text); text = "" }
                            .fontWeight(.semibold).disabled(n == 0)
                    }
                }
            }
        }
        .tint(Ink.ink)
        .presentationDetents([.medium, .large])
    }
}

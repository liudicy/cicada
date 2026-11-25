import Foundation

/// The two switches 改正听错的词 reads: the Mac's `AppSettings`, the iOS app's own preferences.
@MainActor
protocol FixSwitches: AnyObject {
    /// 会中改正听错的词.
    var fixMisheard: Bool { get }
    /// 没见过的名字和专称先问我.
    var askNames: Bool { get }
}

/// 改正听错的词, between the translation chain and the records: which fixes a line takes, which wait
/// for the user (待确认), and what the user's answers and edits teach the word list. Who wins: the
/// user's own decisions, then the word list, then the recheck, then the first live guess. UI-free;
/// the app shows `pending`, `toast` and passes taps back.
@MainActor
final class LiveFixes: ObservableObject {
    let store: SessionStore
    let vocabulary: Vocabulary
    let settings: FixSwitches
    /// The line changed: the app refreshes the subtitle bar if it is still showing it.
    var onLineFixed: ((_ session: String, _ line: TranscriptLine) -> Void)?
    var onChange: (() -> Void)?

    /// The last thing the user did, said back with 撤销 for a few seconds.
    struct Toast: Equatable { let id = UUID(); let text: String }
    @Published private(set) var toast: Toast?

    /// Fixes said no to in this meeting ("from→to"), and how often each heard form was turned down
    /// overall this run: twice and it leaves the word list.
    private var refused: Set<String> = []
    private var refusals: [String: Int] = [:]
    /// 稍后再看 on the card: still waiting, but asked again only after the meeting.
    private var deferred: Set<String> = []
    /// What 撤销 puts back: the lines' fixes and the word list as they were.
    private struct Step { let session: String; let lines: [String: [LineFix]]; let words: [Vocabulary.Term]; let refused: Set<String>; let deferred: Set<String> }
    private var undoStack: [Step] = []
    private var toastTimer: Timer?

    /// The card asks about at most this many names in a row; the rest wait for after the meeting.
    static let askAtOnce = 3

    init(store: SessionStore, vocabulary: Vocabulary, settings: FixSwitches) {
        self.store = store
        self.vocabulary = vocabulary
        self.settings = settings
    }

    func meetingStarted() { refused = []; deferred = []; undoStack = [] }

    private static func pair(_ a: String, _ b: String) -> String { a + "\u{1F}" + b }

    // MARK: The service's proposals

    /// What a finished sentence's request carries; nil while fixing is off. On a second pass (a
    /// joined line, or the recheck after the record's recognizer settled it) the lines after it
    /// and the notes' summary are there too.
    func context(for text: String) -> TranslationService.FixContext? {
        guard settings.fixMisheard else { return nil }
        var ctx = TranslationService.FixContext(topic: nil, words: vocabulary.promptLines(), recent: [])
        if let (id, line) = store.lineHeard(as: text), let s = store.session(id) {
            ctx.topic = s.notes?.title ?? (s.renamed == true ? s.title : nil)
            ctx.summary = s.notes?.summary
            if let i = s.lines.firstIndex(where: { $0.id == line.id }) {
                ctx.recent = s.lines[max(0, i - 3)..<i].map(\.shown)
                ctx.following = s.lines[(i + 1)..<min(s.lines.count, i + 4)].map(\.shown)
            }
        }
        return ctx
    }

    /// The service's proposals for a line heard as `text` (none at all is an answer too: on a
    /// recheck it takes back what isn't proposed again).
    func received(_ text: String, _ edits: [Correction.Edit]) {
        guard settings.fixMisheard, let (id, line) = store.lineHeard(as: text) else { return }
        var fresh: [LineFix] = []
        for e in edits {
            let verdict = Correction.decide(e, known: { self.vocabulary.knows(heard: $0, word: $1) },
                                            rejected: { self.refused.contains(Self.pair($0, $1)) })
            debugLog("fix \(verdict) c=\(String(format: "%.2f", e.confidence)) line=\(line.id)")
            contentLog("FIX \(verdict) \(e.from) → \(e.to)")
            switch verdict {
            case .apply:
                fresh.append(LineFix(from: e.from, to: e.to))
                // A listed word counts as used whichever way the fix was found (a sound-alike too).
                vocabulary.used(Correction.core(e.from, e.to).to)
            case .ask where settings.askNames:
                fresh.append(LineFix(from: e.from, to: e.to, ask: true))
            default: break
            }
        }
        let before = line.fixes ?? []
        let fixes = known(in: line.src, Correction.merge(before, fresh))
        let dropped = before.filter { $0.applied && $0.user != true && !fixes.contains($0) }.count
        if dropped > 0 { debugLog("fix recheck took back \(dropped) line=\(line.id)") }
        set(fixes, line: line.id, in: id)
    }

    /// The word list's confirmed heard forms, fixed without asking anyone: also with no AI service.
    /// Two characters at least, so a single 压 never turns into 押 everywhere.
    func applyKnown(lineID: String, in id: String) {
        guard settings.fixMisheard, let l = store.session(id)?.lines.first(where: { $0.id == lineID }) else { return }
        set(known(in: l.src, l.fixes ?? []), line: lineID, in: id)
    }

    private func known(in src: String, _ fixes: [LineFix]) -> [LineFix] {
        var out = fixes
        for t in vocabulary.terms {
            // A heard form two words claim (两个都留) is never fixed silently. A translation a yes taught
            // before that was refused (平台 → platform) isn't either; one the user typed is.
            for h in t.heard where h.count >= 2 && Correction.word(h, in: src) != nil && !refused.contains(Self.pair(h, t.word))
                && (t.source == "user" || !Correction.translation(heard: h, word: t.word))
                && vocabulary.owners(ofHeard: h, except: t.word).isEmpty {
                if out.contains(where: { $0.from == h || ($0.applied && $0.from.contains(h)) || ($0.off == true && $0.from == h) }) { continue }
                out.append(LineFix(from: h, to: t.word))
            }
        }
        return out
    }

    private func set(_ fixes: [LineFix], line: String, in id: String) {
        guard let l = store.session(id)?.lines.first(where: { $0.id == line }), fixes != l.fixes ?? [] else { return }
        store.setFixes(in: id, lineID: line, fixes)
        if let now = store.session(id)?.lines.first(where: { $0.id == line }) { onLineFixed?(id, now) }
        onChange?()
    }

    // MARK: 待确认

    /// 待确认 in a meeting: each (from → to) once, oldest first.
    func pending(in id: String) -> [(line: TranscriptLine, fix: LineFix)] {
        var seen: Set<String> = []
        var out: [(TranscriptLine, LineFix)] = []
        for l in store.session(id)?.lines ?? [] {
            for f in l.fixes ?? [] where f.ask == true {
                let c = Correction.core(f.from, f.to)
                if seen.insert(Self.pair(c.from, c.to)).inserted { out.append((l, f)) }
            }
        }
        return out
    }

    /// What the notes window's card asks now: not what was put off (稍后再看), and only the first
    /// few, so a burst of names doesn't keep the card up all meeting.
    func asking(in id: String) -> (line: TranscriptLine, fix: LineFix, position: Int, of: Int)? {
        let open = pending(in: id).filter { !deferred.contains(Self.key($0.fix)) }
        guard let first = open.first else { return nil }
        let n = min(open.count, Self.askAtOnce)
        return (first.line, first.fix, 1, n)
    }

    private static func key(_ f: LineFix) -> String { let c = Correction.core(f.from, f.to); return pair(c.from, c.to) }

    /// The notes window's card: asks only while it's useful, and never while the window is shown
    /// to the other side (共享屏幕时让对方看到).
    func later(_ fix: LineFix, in id: String) {
        remember(id, lines: [])
        deferred.insert(Self.key(fix))
        say(L("已收进人名和术语，稍后再看"))
        onChange?()
    }

    /// 对 / 不对 on a waiting fix: every line in the meeting waiting on the same change follows,
    /// and a yes goes into the word list so the next meeting fixes it without asking.
    func answer(_ fix: LineFix, yes: Bool, in id: String) {
        let c = Correction.core(fix.from, fix.to)
        guard let s = store.session(id) else { return }
        let touched = s.lines.filter { ($0.fixes ?? []).contains { $0.ask == true && Correction.core($0.from, $0.to) == c } }
        let others = yes ? s.lines.filter { $0.src.contains(c.from) && !touched.contains($0) } : []
        remember(id, lines: (touched + others).map(\.id))
        for l in touched {
            var fixes = l.fixes ?? []
            for k in fixes.indices where fixes[k].ask == true && Correction.core(fixes[k].from, fixes[k].to) == c {
                fixes[k].ask = nil
                if yes { fixes[k].user = true } else { fixes[k].off = true }
            }
            set(fixes, line: l.id, in: id)
        }
        if yes {
            vocabulary.confirm(heard: c.from, word: c.to)
            // The rest of the meeting heard the same way follows now, not with the next line.
            for l in others { applyKnown(lineID: l.id, in: id) }
        } else {
            refused.insert(Self.pair(c.from, c.to))
        }
        debugLog("fix answered \(yes ? "yes" : "no")")
        say(yes ? L("已改 \(c.from) → \(c.to)，记进词表") : L("这场不再问 \(c.from)"))
    }

    /// 改回: this line goes back to what was heard, and the meeting stops making this change.
    func revert(_ fix: LineFix, lineID: String, in id: String) {
        // The one still on: an earlier, already undone copy of the same change may sit before it.
        guard let l = store.session(id)?.lines.first(where: { $0.id == lineID }), var fixes = l.fixes,
              let k = fixes.firstIndex(where: { $0.from == fix.from && $0.to == fix.to && $0.applied })
                ?? fixes.firstIndex(where: { $0.from == fix.from && $0.to == fix.to }) else { return }
        remember(id, lines: [lineID])
        fixes[k].off = true
        fixes[k].ask = nil
        fixes[k].user = nil
        set(fixes, line: lineID, in: id)
        let c = Correction.core(fix.from, fix.to)
        refused.insert(Self.pair(c.from, c.to))
        refused.insert(Self.pair(fix.from, fix.to))
        let key = Self.pair(c.from, c.to)
        refusals[key, default: 0] += 1
        if refusals[key]! >= 2 { vocabulary.forget(heard: c.from, word: c.to) }
        debugLog("fix reverted line=\(lineID)")
        say(L("已改回 \(Correction.label(fix).from)，这场不再改"))
    }

    // MARK: 改这句…

    /// How many lines of the meeting the same edit would change ("整场同样听成 木娜 的 2 处都改").
    /// An edit that only adds or drops words stays on its line (count 1, nothing to learn).
    func sameHeard(lineID: String, in id: String, edited: String) -> (heard: String, count: Int, swap: Bool)? {
        guard let s = store.session(id), let l = s.lines.first(where: { $0.id == lineID }),
              let e = Correction.userEdit(shown: l.shown, edited: edited, src: l.src, fixes: l.fixes ?? []) else { return nil }
        let n = e.swap ? s.lines.filter { $0.shown.contains(e.fix.from) }.count : 1
        return (e.heard, max(1, n), e.swap)
    }

    /// The user rewrote a line (改这句…): what changed becomes their own fix, on this line or on
    /// every line showing the same words, and with `remember` the heard form joins the word list.
    @discardableResult
    func edit(lineID: String, in id: String, to edited: String, everywhere: Bool, remember keep: Bool) -> Int {
        guard let s = store.session(id), let l = s.lines.first(where: { $0.id == lineID }),
              let e = Correction.userEdit(shown: l.shown, edited: edited, src: l.src, fixes: l.fixes ?? []) else { return 0 }
        let everywhere = everywhere && e.swap
        let targets = everywhere ? s.lines.filter { $0.shown.contains(e.fix.from) } : [l]
        remember(id, lines: targets.map(\.id))
        for t in targets {
            // A guess still waiting on the same words is answered by the edit: not that.
            // The same change made again replaces any earlier copy (say, one undone with 改回).
            let fixes = (t.fixes ?? []).filter { !($0.from == e.fix.from && $0.to == e.fix.to) }.map { f -> LineFix in
                var f = f
                if f.ask == true, f.from.contains(e.heard) || e.heard.contains(f.from) { f.ask = nil; f.off = true }
                return f
            }
            set(fixes + [e.fix], line: t.id, in: id)
        }
        let c = Correction.core(e.fix.from, e.fix.to)
        // Only a change made everywhere teaches the word list (a one-off must not), and only a
        // word for a word (`Vocabulary.learnable`).
        let word = c.to.trimmingCharacters(in: .whitespaces)
        let learned = keep && everywhere && Vocabulary.learnable(heard: e.heard, word: word) != nil
        if learned { vocabulary.confirm(heard: e.heard, word: word, source: "user") }
        debugLog("fix edited lines=\(targets.count) learned=\(learned)")
        // A swap reads as the words swapped; an added or dropped word as the span it changed
        // ("in → in now", not "in → now").
        let (a, b) = e.swap ? (e.heard, word) : (e.fix.from, e.fix.to)
        say(learned ? L("已改 \(targets.count) 处：\(a) → \(b)，记进词表")
                    : L("已改 \(targets.count) 处：\(a) → \(b)"))
        return targets.count
    }

    // MARK: 撤销

    private func remember(_ id: String, lines: [String]) {
        let s = store.session(id)
        var before: [String: [LineFix]] = [:]
        for lid in lines { before[lid] = s?.lines.first { $0.id == lid }?.fixes ?? [] }
        undoStack.append(Step(session: id, lines: before, words: vocabulary.terms, refused: refused, deferred: deferred))
        if undoStack.count > 20 { undoStack.removeFirst() }
    }

    var canUndo: Bool { !undoStack.isEmpty }

    func undo() {
        guard let step = undoStack.popLast() else { return }
        for (lid, fixes) in step.lines {
            store.setFixes(in: step.session, lineID: lid, fixes)
            if let now = store.session(step.session)?.lines.first(where: { $0.id == lid }) { onLineFixed?(step.session, now) }
        }
        vocabulary.restore(step.words)
        refused = step.refused
        deferred = step.deferred
        toast = nil
        debugLog("fix undone")
        onChange?()
    }

    private func say(_ text: String) {
        toast = Toast(text: text)
        toastTimer?.invalidate()
        toastTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.toast = nil }
        }
        onChange?()
    }
}

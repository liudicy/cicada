import Foundation

// MARK: - Model

/// Meeting notes kept with the session (`session.json` › `notes`). Written by Ling while the
/// meeting runs ("速记版") and rewritten once over the whole transcript when it ends ("完整版").
struct MeetingNotes: Codable, Equatable {
    /// A short name for the meeting in the notes' language (absent in older notes).
    var title: String?
    var summary = ""
    var topics: [NoteTopic] = []
    var conclusions: [NoteItem] = []
    var todos: [NoteItem] = []
    var terms: [NoteTerm] = []
    /// How many transcript lines these notes cover.
    var covered = 0
    var updatedAt: Date?
    var final = false
    /// The user changed these notes by hand: an automatic pass (e.g. after a cloud proofread)
    /// must not regenerate over their edits.
    var edited: Bool? = nil

    var isEmpty: Bool { summary.isEmpty && topics.isEmpty }
}

struct NoteTopic: Codable, Equatable, Identifiable {
    var start: Double
    var title: String
    var summary: String
    var points: [String]
    var fishbone: Fishbone?
    /// When each point was said (its first evidence line), parallel to `points`; older notes have none.
    var pointTimes: [Double?]?
    var id: String { "\(Int(start))-\(title)" }

    func pointTime(_ i: Int) -> Double? { pointTimes.flatMap { i < $0.count ? $0[i] : nil } }
}

/// A cause-and-effect diagram for a topic that discusses why something happened.
struct Fishbone: Codable, Equatable {
    var question: String
    var branches: [FishboneBranch]
}

struct FishboneBranch: Codable, Equatable, Identifiable {
    var label: String
    var detail: String
    var t: Double?
    /// How many transcript lines back this branch; 0 is shown as weak.
    var support: Int
    var id: String { label + detail }
}

struct NoteItem: Codable, Equatable, Identifiable {
    var text: String
    var owner: String?
    var support: Int
    /// When it was said (first evidence line).
    var t: Double?
    var id: String { text }
}

/// A name or term as the notes settled on it, and how speech recognition heard it.
struct NoteTerm: Codable, Equatable, Identifiable {
    var name: String
    var note: String
    var heard: [String]
    var id: String { name }

    /// Corrected spellings first: what a reader can't work out alone.
    static func ordered(_ terms: [NoteTerm]) -> [NoteTerm] {
        terms.filter { !$0.heard.isEmpty } + terms.filter { $0.heard.isEmpty }
    }

    /// Roles that say a term is a person, for offering it as a speaker's name.
    private static let roles = ["首席", "执行官", "主席", "总裁", "董事", "经理", "创始人", "记者", "主持", "研究员",
                                "分析师", "教授", "老师", "教师", "官员", "部长", "议员", "候选人", "嘉宾", "发言人",
                                "CEO", "CFO", "CTO", "host", "analyst", "reporter", "founder"]

    /// Names of people the notes mention, by their note ("BGN 集团首席运营官").
    static func people(_ terms: [NoteTerm]) -> [String] {
        terms.filter { t in roles.contains { t.note.localizedCaseInsensitiveContains($0) } }.map(\.name)
    }
}

// MARK: - Engine

/// Keeps the live session's notes up to date: every ~45 s with new speech, one Ling call sends
/// the current notes plus the new lines and gets the whole updated notes back as JSON. A failed or
/// odd reply never replaces good notes. UI-free; the notes window observes it.
@MainActor
final class NotesEngine: ObservableObject {
    enum State: Equatable {
        case idle
        case updating
        case noKey
        case invalidKey
        case rateLimited
        case failed
    }

    @Published private(set) var notes = MeetingNotes()
    @Published private(set) var state: State = .idle
    /// Points and topics that appeared in the last update ("新").
    @Published private(set) var fresh: Set<String> = []
    @Published private(set) var summaryChangedAt: Date?
    /// A finished meeting whose full notes are being written (main window "生成纪要").
    @Published private(set) var generatingID: String?

    let ling: LingClient
    let store: SessionStore
    /// The language a meeting's notes are written in (English name), set by the app from the
    /// 纪要语言 choice.
    var language: (_ sessionID: String) -> String = { _ in "Simplified Chinese" }

    private var sessionID: String?
    /// The session whose notes `notes` shows (stays set after the meeting ends).
    private(set) var shownID: String?
    private var timer: Timer?
    private var inFlight = false
    /// Final passes asked for while another call was running, in order; each runs after it.
    /// Several can wait: an imported file can finish while the meeting's own pass is queued.
    private var pendingFinals: [String] = []
    /// A language change that arrived while another update was running: rewrite after it.
    private var pendingRewrite: String?
    private var lastAttempt = Date.distantPast
    private var freshGeneration = 0
    static let interval: TimeInterval = 45

    init(ling: LingClient, store: SessionStore) {
        self.ling = ling
        self.store = store
    }

    /// Names for the translation glossary: "江充 (heard as 江松, 江冲)".
    var glossary: [String] {
        notes.terms.prefix(30).map { t in
            t.heard.isEmpty ? "\(t.name) (\(t.note))" : "\(t.name) (\(t.note); misheard as \(t.heard.joined(separator: ", ")))"
        }
    }

    func begin(_ id: String) {
        sessionID = id
        shownID = id
        notes = store.session(id)?.notes ?? MeetingNotes()
        fresh = []
        state = ling.hasKey ? .idle : .noKey
        lastAttempt = Date()
        timer?.invalidate()
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer = t
        RunLoop.main.add(t, forMode: .common)
    }

    /// The meeting ended: one last pass over the whole transcript.
    func finish() {
        timer?.invalidate()
        timer = nil
        guard let id = sessionID else { return }
        sessionID = nil
        Task { await update(id, final: true) }
    }

    /// The notes language changed during the meeting: rewrite the whole notes in it now.
    func rewrite() {
        guard let id = sessionID else { return }
        Task { await update(id, final: false, fresh: true) }
    }

    func updateNow() {
        guard let id = sessionID else { return }
        Task { await update(id, final: false) }
    }

    /// Show a stored meeting's notes (the window shows the live meeting when there is one).
    func show(_ id: String) {
        shownID = id
        notes = store.session(id)?.notes ?? MeetingNotes()
        fresh = []
    }

    /// Notes for a finished meeting that has none (e.g. recorded before a key was set).
    func generate(for id: String) {
        Task { await update(id, final: true) }
    }

    /// Debug control: rebuild a stored meeting's notes the way a live meeting would, a few lines
    /// at a time, then the final pass.
    func replay(_ id: String, step: Int = 4) async {
        guard let count = store.session(id)?.lines.count else { return }
        shownID = id
        notes = MeetingNotes()
        for upto in stride(from: min(step, count), through: count, by: step) {
            await update(id, final: false, upto: upto)
        }
        if count % step != 0 { await update(id, final: false, upto: count) }
        await update(id, final: true)
    }

    private func tick() {
        // A key was added or replaced since the last failure.
        if (state == .noKey || state == .invalidKey), ling.usable, ling.keyState != .checking { state = .idle }
        if state == .idle, !ling.hasKey { state = .noKey }
        // A key that was just checked and refused says so, rather than asking for a key again.
        if state == .noKey || state == .idle, ling.hasKey, ling.keyState == .invalid { state = .invalidKey }
        guard let id = sessionID, !inFlight else { return }
        guard let s = store.session(id), s.lines.count > notes.covered else { return }
        // First notes as soon as there is something to say, then every 45 s.
        let due = notes.isEmpty ? (s.lines.count >= 3 || Date().timeIntervalSince(lastAttempt) > 20)
                                : Date().timeIntervalSince(lastAttempt) >= Self.interval
        if due { Task { await update(id, final: false) } }
    }

    /// `fresh`: start from nothing (a new notes language); the final pass always does.
    private func update(_ id: String, final: Bool, upto: Int? = nil, fresh: Bool = false) async {
        if inFlight {
            // Never drop the end-of-meeting pass or a "生成纪要" request: queue it.
            if final {
                if !pendingFinals.contains(id) { pendingFinals.append(id) }
                if generatingID == nil { generatingID = id }
            }
            if fresh { pendingRewrite = id }
            return
        }
        guard let session = store.session(id), !session.lines.isEmpty else { return }
        guard ling.hasKey else { state = .noKey; return }
        inFlight = true
        lastAttempt = Date()
        state = .updating
        if final { generatingID = id }
        defer {
            inFlight = false
            if final, generatingID == id { generatingID = nil }
            if !pendingFinals.isEmpty {
                let next = pendingFinals.removeFirst()
                if pendingRewrite == next { pendingRewrite = nil } // the final pass starts from nothing anyway
                Task { await update(next, final: true) }
            } else if let next = pendingRewrite {
                pendingRewrite = nil
                Task { await update(next, final: false, fresh: true) }
            }
        }

        let lines = Array(session.lines.prefix(upto ?? session.lines.count))
        let base = final || fresh ? MeetingNotes() : (id == shownID ? notes : session.notes ?? MeetingNotes())
        let from = final ? 0 : min(base.covered, lines.count)
        let lang = language(id)
        let names = TranscriptExport.voices ? SpeakerLabels.names(session) : [:]
        let prompt = Self.prompt(notes: base, lines: lines, from: from, language: lang, final: final, names: names)
        let started = Date()
        do {
            // The final pass sends only the transcript, with no notes in the reader's language to
            // follow: given a long English meeting the model drifts into English. Say the language
            // again where it is read last, and try once more if the reply still isn't in it.
            var next: MeetingNotes?
            for attempt in 1...(final || fresh ? 2 : 1) {
                let raw = try await ling.chat(content: prompt, instruction: "Update the notes. Write them in \(lang).",
                                              priority: .notes, json: true, maxTokens: 6000, timeout: 90)
                guard let parsed = Self.parse(raw, times: lines.map(\.t), startedAt: session.lines.first?.t ?? 0) else { break }
                if Self.written(parsed, in: lang) { next = parsed; break }
                debugLog("notes: \(final ? "final" : "live") reply not in \(lang) (attempt \(attempt)), dropped")
            }
            guard var next else {
                debugLog("notes: no usable reply, kept the previous notes")
                state = .failed
                return
            }
            // The notes language changed while this was running: the queued rewrite replaces it.
            guard language(id) == lang else {
                debugLog("notes: language changed during the update, reply dropped")
                state = .idle
                return
            }
            Self.carryTimes(from: base, into: &next)
            // A reply without a name keeps the last one (not after a language change).
            if next.title == nil, !fresh { next.title = (id == shownID ? notes : session.notes)?.title }
            next.covered = lines.count
            next.updatedAt = Date()
            next.final = final
            if id == shownID {
                markFresh(old: notes, new: next, final: final)
                if next.summary != notes.summary { summaryChangedAt = Date() }
                notes = next
            }
            store.setNotes(id, next)
            state = .idle
            debugLog("notes: \(final ? "final" : "live") update \(lines.count - from) new lines → \(next.topics.count) topics, \(next.terms.count) terms in \(Int(Date().timeIntervalSince(started))) s")
        } catch LingClient.Failure.invalidKey {
            state = .invalidKey
        } catch LingClient.Failure.rateLimited {
            state = .rateLimited
        } catch LingClient.Failure.noKey {
            state = .noKey
        } catch {
            debugLog("notes: update failed \(error)")
            state = .failed
        }
    }

    /// "新" marks what the last live update added, for a minute. The final pass rewrites
    /// everything, so it marks nothing.
    private func markFresh(old: MeetingNotes, new: MeetingNotes, final: Bool) {
        freshGeneration += 1
        guard !old.isEmpty, !final else { fresh = []; return }
        let before = Set(old.topics.flatMap { [$0.title] + $0.points })
        fresh = Set(new.topics.flatMap { [$0.title] + $0.points }).subtracting(before)
        let generation = freshGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            MainActor.assumeIsolated {
                if self?.freshGeneration == generation { self?.fresh = [] }
            }
        }
    }

    /// The model echoes points it already had without evidence: keep the times they had.
    static func carryTimes(from old: MeetingNotes, into new: inout MeetingNotes) {
        var known: [String: Double] = [:]
        for t in old.topics { for (i, p) in t.points.enumerated() { if let x = t.pointTime(i) { known[p] = x } } }
        for (ti, t) in new.topics.enumerated() {
            // A point keeps the time it was first heard: a later mention never moves it later.
            let times = t.points.enumerated().map { i, p in [t.pointTime(i), known[p]].compactMap { $0 }.min() }
            new.topics[ti].pointTimes = times.contains { $0 != nil } ? times : nil
        }
        let items = Dictionary((old.conclusions + old.todos).compactMap { i in i.t.map { (i.text, $0) } }, uniquingKeysWith: { a, _ in a })
        func earliest(_ a: Double?, _ b: Double?) -> Double? { [a, b].compactMap { $0 }.min() }
        for i in new.conclusions.indices { new.conclusions[i].t = earliest(new.conclusions[i].t, items[new.conclusions[i].text]) }
        for i in new.todos.indices { new.todos[i].t = earliest(new.todos[i].t, items[new.todos[i].text]) }
    }

    // MARK: Prompt

    static func clock(_ t: Double) -> String { TranscriptExport.clock(t) }

    static func prompt(notes: MeetingNotes, lines: [TranscriptLine], from: Int, language: String, final: Bool,
                       names: [Int: String] = [:]) -> String {
        let numbers = TranscriptExport.voices ? SpeakerLabels.numbers(lines) : [:]
        func line(_ i: Int) -> String {
            let l = lines[i]
            // A named voice goes as its name: notes then say "George" rather than "说话人2".
            let who = l.speaker == "me" ? "你" : numbers[l.id].map { names[$0] ?? "说话人\($0)" } ?? (numbers.isEmpty ? "对方" : "未识别")
            return "[L\(i + 1) \(clock(l.t)) \(who)] \(l.src)"
        }
        var current = "{}"
        if !notes.isEmpty, let data = try? JSONEncoder().encode(Compact(notes)), let s = String(data: data, encoding: .utf8) {
            current = s
        }
        let context = max(0, from - 2)
        var p = """
        You keep notes for a meeting \(final ? "that has just ended. Rewrite them from the whole transcript" : "that is still going on. Update them with the new lines").
        Write the notes in \(language). Return JSON only.

        """
        if !final {
            p += "Current notes (JSON):\n\(current)\n\n"
        }
        if context < from {
            p += "Already covered (context only):\n" + (context..<from).map(line).joined(separator: "\n") + "\n\n"
        }
        p += "\(final ? "Transcript" : "New lines") (id, mm:ss, speaker 对方=the other side / 你=me / a name or 说话人N=one person on the other side, told apart by voice and possibly wrong / 未识别=someone on the other side not identified, text). Speech recognition makes mistakes, often in names: correct them from context, and write a public figure's name as the news spells it.\n"
        p += (from..<lines.count).map(line).joined(separator: "\n")
        // The model splits too eagerly when only told how long a topic should be: say plainly
        // whether this update may start one.
        if final, let first = lines.first?.t, let last = lines.last?.t {
            let most = max(1, min(8, Int((last - first) / 180) + 1))
            p += "\n\nThis meeting ran \(clock(last - first)): use at most \(most) topic\(most == 1 ? "" : "s")."
        } else if !final, let current = notes.topics.last, let newest = lines.last?.t, newest - current.start < 120 {
            p += "\n\nThe current topic \"\(current.title)\" started at \(clock(current.start)), under 2 minutes ago: do not start a new topic in this update; add the new lines to it."
        } else if !final, notes.topics.isEmpty {
            p += "\n\nThese are the first lines: make one topic."
        }
        p += """


        Return the full notes as one JSON object with exactly these keys:
        {"title": "the meeting's name: what it is about, a few words",
         "summary": "2-3 sentences on the whole meeting so far",
         "topics": [{"start": seconds, "title": "short title", "summary": "one sentence", "points": [{"text": "key point", "evidence": ["L4"]}], "evidence": ["L3"],
                     "fishbone": null or {"question": "the problem or question", "branches": [{"label": "2-6 words", "detail": "one short line", "t": seconds, "evidence": ["L5"]}]}}],
         "conclusions": [{"text": "...", "evidence": ["L7", "L8"]}],
         "todos": [{"text": "...", "owner": \(numbers.isEmpty ? "\"对方\" or \"你\" or null" : "the person's label from the transcript (a name like \"George\", or \"说话人2\"), \"你\", or null when unclear"), "evidence": ["L9"]}],
         "terms": [{"name": "correct spelling", "note": "who or what, a few words", "heard": ["how it was misrecognised"]}]}
        Rules (be brief: these notes are read at a glance during the meeting):
        - title: a name for the whole meeting, like a calendar entry (at most 12 Chinese characters or 6 words; no date, no quotes, not "会议" alone). Keep the current title unless the meeting's subject has clearly changed.
        - summary: at most 3 short sentences.
        - Topics in time order, at most 8 in total. A topic is a stretch of the meeting, usually 3-10 minutes, not a single remark: start a new one only when the subject clearly changes and the current topic started at least 2 minutes before the newest line\(final ? "" : "; add at most one new topic per update"). Otherwise add to the current one, and merge small neighbouring topics. Keep earlier topics as they are unless new lines correct them. The last topic is the one being discussed now.
        - At most 4 points per topic, each one short phrase. Merge rather than repeat.
        - At most 5 conclusions and only real to-dos (often none).
        - Add a fishbone only to a topic that discusses causes, reasons or factors (3-5 branches); otherwise null.
        - Every topic, point, branch, conclusion and to-do needs evidence: the ids of the lines that say it. Never state anything the transcript does not say.
        - terms: at most 10 in total, replacing less useful ones rather than adding: first names the transcript misspells (heard), then the people, places and jargon a reader would not know. Leave out what everyone knows (a famous company, index or politician) unless it was misheard. name is the correct spelling in the transcript's language (no translation in brackets); heard lists only the wrong forms the transcript used; note is a few words.
        - Write the meeting title and every summary, title, point, branch, conclusion and to-do in \(language), even when the transcript is in another language. Only term names keep the transcript's spelling.
        - Write about what was said, never about the transcript or recognition quality.
        - Use empty arrays when there is nothing. No markdown, no text outside the JSON.
        """
        return p
    }

    /// Whether the notes' own words (summary, titles) are in `language`: Chinese, Japanese and
    /// Korean need a fair share of CJK (names and numbers stay Latin), other languages must not be mostly CJK.
    static func written(_ notes: MeetingNotes, in language: String) -> Bool {
        let text = ([notes.summary] + notes.topics.map(\.title)).joined()
        let letters = text.unicodeScalars.filter { $0.properties.isAlphabetic }
        guard !letters.isEmpty else { return true }
        let cjk = letters.filter { (0x3040...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }.count
        let wantsCJK = ["Chinese", "Japanese", "Korean"].contains { language.contains($0) }
        return wantsCJK ? cjk * 5 >= letters.count : cjk * 2 < letters.count
    }

    /// The current notes as sent back to the model (no bookkeeping fields).
    private struct Compact: Encodable {
        let title: String?
        let summary: String
        let topics: [Topic]
        let conclusions: [String]
        let todos: [String]
        let terms: [NoteTerm]
        struct Topic: Encodable {
            let start: Double
            let title: String
            let summary: String
            let points: [String]
            let fishbone: Fishbone?
        }
        init(_ n: MeetingNotes) {
            title = n.title
            summary = n.summary
            topics = n.topics.map { Topic(start: $0.start, title: $0.title, summary: $0.summary, points: $0.points, fishbone: $0.fishbone) }
            conclusions = n.conclusions.map(\.text)
            todos = n.todos.map(\.text)
            terms = n.terms
        }
    }

    // MARK: Parse

    /// Lenient: missing keys become empty, evidence ids are checked against the transcript.
    static func parse(_ raw: String, times: [Double], startedAt: Double) -> MeetingNotes? {
        let lineCount = times.count
        var text = raw
        if let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}") { text = String(text[a...b]) }
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func str(_ v: Any?) -> String { (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap(Double.init) }
        func lineNumbers(_ v: Any?) -> Set<Int> {
            let ids = (v as? [Any])?.compactMap { $0 as? String } ?? []
            return Set(ids.compactMap { id -> Int? in
                guard let n = Int(id.drop(while: { !$0.isNumber })), n >= 1, n <= lineCount else { return nil }
                return n
            })
        }
        func support(_ v: Any?) -> Int { lineNumbers(v).count }
        /// When it was first said: the earliest evidence line.
        func time(_ v: Any?) -> Double? { lineNumbers(v).min().map { times[$0 - 1] } }
        var n = MeetingNotes()
        n.summary = str(root["summary"])
        let title = str(root["title"]).trimmingCharacters(in: CharacterSet(charactersIn: "\"“”「」《》"))
        n.title = title.isEmpty ? nil : title
        n.topics = (root["topics"] as? [[String: Any]] ?? []).compactMap { t in
            let title = str(t["title"])
            guard !title.isEmpty else { return nil }
            var fish: Fishbone?
            if let f = t["fishbone"] as? [String: Any] {
                let branches = (f["branches"] as? [[String: Any]] ?? []).compactMap { b -> FishboneBranch? in
                    let label = str(b["label"])
                    return label.isEmpty ? nil : FishboneBranch(label: label, detail: str(b["detail"]), t: num(b["t"]),
                                                                support: support(b["evidence"]))
                }
                if branches.count >= 2 { fish = Fishbone(question: str(f["question"]), branches: branches) }
            }
            // Points come as {"text", "evidence"} (or plain strings from older replies).
            var points: [String] = [], pointTimes: [Double?] = []
            for p in t["points"] as? [Any] ?? [] {
                let text = (p as? [String: Any]).map { str($0["text"]) } ?? str(p)
                guard !text.isEmpty else { continue }
                points.append(text)
                pointTimes.append((p as? [String: Any]).flatMap { time($0["evidence"]) })
            }
            return NoteTopic(start: num(t["start"]) ?? startedAt, title: title, summary: str(t["summary"]),
                             points: points, fishbone: fish,
                             pointTimes: pointTimes.contains { $0 != nil } ? pointTimes : nil)
        }
        func items(_ key: String) -> [NoteItem] {
            (root[key] as? [[String: Any]] ?? []).compactMap { i in
                let text = str(i["text"])
                let owner = str(i["owner"])
                return text.isEmpty ? nil : NoteItem(text: text, owner: owner.isEmpty ? nil : owner, support: support(i["evidence"]),
                                                     t: time(i["evidence"]))
            }
        }
        n.conclusions = items("conclusions")
        n.todos = items("todos")
        n.terms = (root["terms"] as? [[String: Any]] ?? []).compactMap { t in
            let name = str(t["name"])
            let heard = (t["heard"] as? [Any] ?? []).map(str).filter { !$0.isEmpty && $0 != name }
            return name.isEmpty ? nil : NoteTerm(name: name, note: str(t["note"]), heard: heard)
        }
        // The model keeps every term it ever had: bound the glossary, keeping the misheard ones.
        if n.terms.count > 20 { n.terms = Array(NoteTerm.ordered(n.terms).prefix(20)) }
        return n.isEmpty ? nil : n
    }
}

import AppKit
import Foundation

struct TranscriptLine: Codable, Identifiable, Equatable {
    var id: String
    /// Seconds from the start of the session.
    var t: Double
    /// "them" (system audio) or "me" (microphone).
    var speaker: String
    var src: String
    var dst: String?
    var srcLang: String
    var dstLang: String
    /// Experimental: which of the other side's voices said it (SpeakerID.swift); nil when unknown.
    var voice: Int? = nil
    /// Where this line sits in the recording (seconds into system.m4a), so a post-meeting cloud
    /// proofread cuts exactly its audio. nil in older meetings and "me" lines.
    var audioStart: Double? = nil
    var audioEnd: Double? = nil
}

/// A name Ling found for a voice, and the line it is based on ("00:06 “Sure, Emma…”").
struct VoiceGuess: Codable, Equatable {
    var name: String
    var evidence: String
}

struct Session: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var startedAt: Date
    var endedAt: Date?
    var lines: [TranscriptLine]
    var hasAudio: Bool
    /// AI notes (absent in older sessions and without an API key).
    var notes: MeetingNotes?
    /// The user renamed it; nil in older sessions, where any title but the default counts as renamed.
    var renamed: Bool?
    /// Experimental 说话人识别: names the user gave voices, keyed by voice id. An empty name means
    /// "not Ling's guess": the voice shows as 说话人 N.
    var voiceNames: [String: String]? = nil
    /// Names Ling read from the conversation, keyed by voice id; shown until the user says otherwise.
    var voiceGuesses: [String: VoiceGuess]? = nil

    var duration: TimeInterval { (endedAt ?? Date()).timeIntervalSince(startedAt) }

    /// The user's own title, else the date and the name the notes gave the meeting
    /// ("11月1日 产品路线评审", in the notes' language), else "会议 11月1日 14:30".
    var displayTitle: String {
        if renamed ?? !title.hasPrefix("会议 ") { return title }
        // The stored default title is Chinese ("会议 11月1日 14:30"); shown in the UI language.
        guard let name = notes?.title, !name.isEmpty else { return L("会议 \(dateText(startedAt, "MMMdHHmm"))") }
        let thisYear = Calendar.current.isDate(startedAt, equalTo: Date(), toGranularity: .year)
        return "\(dateText(startedAt, thisYear ? "MMMd" : "yMMMd")) \(name)"
    }

    static func defaultTitle(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 HH:mm"
        return "会议 \(f.string(from: date))"
    }
}

/// One folder per meeting under ~/Library/Application Support/LiveSubs/Sessions/<id>/:
/// session.json, system.m4a (what you heard) and mic.m4a (what you said).
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    @Published private(set) var liveID: String?

    let root: URL
    private var saveWork: DispatchWorkItem?

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = base.appendingPathComponent("\(DevBuild.supportFolder)/Sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        load()
    }

    func folder(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    func systemAudioURL(_ id: String) -> URL { folder(id).appendingPathComponent("system.m4a") }
    func micAudioURL(_ id: String) -> URL { folder(id).appendingPathComponent("mic.m4a") }

    private func load() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var out: [Session] = []
        for dir in dirs {
            if let data = try? Data(contentsOf: dir.appendingPathComponent("session.json")),
               var s = try? decoder.decode(Session.self, from: data) {
                if s.endedAt == nil { s.endedAt = s.lines.last.map { s.startedAt.addingTimeInterval($0.t + 5) } ?? s.startedAt }
                // The app quit mid-meeting: its recording is still in the partial file.
                if s.id != liveID, hasPartialAudio(s.id) {
                    s.hasAudio = true
                    finishAudio(s.id)
                }
                out.append(s)
            }
        }
        sessions = out.sorted { $0.startedAt > $1.startedAt }
    }

    // MARK: Live session

    @discardableResult
    func begin() -> Session {
        let now = Date()
        let fid = DateFormatter()
        fid.dateFormat = "yyyyMMdd-HHmmss"
        let s = Session(id: fid.string(from: now), title: Session.defaultTitle(now),
                        startedAt: now, endedAt: nil, lines: [], hasAudio: false)
        sessions.insert(s, at: 0)
        liveID = s.id
        try? FileManager.default.createDirectory(at: folder(s.id), withIntermediateDirectories: true)
        return s
    }

    /// `at`: when the meeting really ended, for one that ended by itself after a hang-up or a
    /// long silence; the recordings are cut there too.
    func end(at: Date? = nil) {
        guard let id = liveID, let i = index(id) else { liveID = nil; return }
        let now = Date()
        sessions[i].endedAt = at.map { min(now, max(sessions[i].startedAt, $0)) } ?? now
        liveID = nil
        if sessions[i].lines.isEmpty {
            // Nothing was said: don't keep an empty meeting around.
            try? FileManager.default.removeItem(at: folder(id))
            sessions.remove(at: i)
            return
        }
        sessions[i].hasAudio = [systemAudioURL(id), micAudioURL(id)].contains {
            FileManager.default.fileExists(atPath: $0.path) || FileManager.default.fileExists(atPath: AudioFileWriter.partial($0).path)
        }
        saveNow(id)
        finishAudio(id, until: at == nil ? nil : sessions[i].duration)
    }

    private func hasPartialAudio(_ id: String) -> Bool {
        [systemAudioURL(id), micAudioURL(id)].contains { FileManager.default.fileExists(atPath: AudioFileWriter.partial($0).path) }
    }

    /// Turns the meeting's recordings into .m4a files (call after the recorders are closed).
    func finishAudio(_ id: String, until: Double? = nil) {
        let urls = [systemAudioURL(id), micAudioURL(id)]
        Task.detached(priority: .utility) { for u in urls { await AudioFileWriter.finish(u, until: until) } }
    }

    var liveStart: Date? { liveID.flatMap { index($0) }.map { sessions[$0].startedAt } }

    func append(_ line: TranscriptLine) {
        guard let id = liveID, let i = index(id) else { return }
        sessions[i].lines.append(line)
        scheduleSave(id)
    }

    func setTranslation(lineID: String, _ text: String) {
        guard let id = liveID, let i = index(id),
              let j = sessions[i].lines.firstIndex(where: { $0.id == lineID }) else { return }
        sessions[i].lines[j].dst = text
        scheduleSave(id)
    }

    /// A line joined with the one after it (`HeardText.join`).
    func setSource(lineID: String, _ text: String) {
        guard let id = liveID, let i = index(id),
              let j = sessions[i].lines.firstIndex(where: { $0.id == lineID }) else { return }
        sessions[i].lines[j].src = text
        scheduleSave(id)
    }

    /// A joined line's audio now reaches further into the recording (`HeardText.join`).
    func setAudioEnd(lineID: String, _ end: Double) {
        guard let id = liveID, let i = index(id),
              let j = sessions[i].lines.firstIndex(where: { $0.id == lineID }) else { return }
        sessions[i].lines[j].audioEnd = end
        scheduleSave(id)
    }

    /// A finished meeting's line got a new source from a retroactive proofread or an edit.
    func editSource(_ id: String, lineID: String, _ text: String) {
        guard let i = index(id),
              let j = sessions[i].lines.firstIndex(where: { $0.id == lineID }) else { return }
        sessions[i].lines[j].src = text
        id == liveID ? scheduleSave(id) : saveNow(id)
    }

    /// Its translation follows (`editSource`).
    func editTranslation(_ id: String, lineID: String, _ text: String) {
        guard let i = index(id),
              let j = sessions[i].lines.firstIndex(where: { $0.id == lineID }) else { return }
        sessions[i].lines[j].dst = text
        id == liveID ? scheduleSave(id) : saveNow(id)
    }

    func setVoice(lineID: String, _ voice: Int) {
        guard let id = liveID, let i = index(id),
              let j = sessions[i].lines.firstIndex(where: { $0.id == lineID }) else { return }
        sessions[i].lines[j].voice = voice
        scheduleSave(id)
    }

    /// The user names a voice. nil drops their name (Ling's guess shows again); "" keeps 说话人 N.
    func setVoiceName(_ id: String, voice: Int, _ name: String?) {
        guard let i = index(id) else { return }
        var names = sessions[i].voiceNames ?? [:]
        names[String(voice)] = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        sessions[i].voiceNames = names.isEmpty ? nil : names
        saveNow(id)
    }

    /// Ling's latest guesses; earlier ones stay for voices it no longer mentions, unless it now named
    /// them without evidence (`refuted`, voice → name): then that earlier name goes too.
    func setVoiceGuesses(_ id: String, _ guesses: [Int: VoiceGuess], refuted: [Int: String] = [:]) {
        guard let i = index(id), !guesses.isEmpty || !refuted.isEmpty else { return }
        var all = sessions[i].voiceGuesses ?? [:]
        for (v, name) in refuted where guesses[v] == nil && all[String(v)]?.name == name { all[String(v)] = nil }
        for (v, g) in guesses { all[String(v)] = g }
        guard all != sessions[i].voiceGuesses else { return }
        sessions[i].voiceGuesses = all.isEmpty ? nil : all
        saveNow(id)
    }

    /// The user said two voices are the same person: `from`'s lines become `into`'s.
    func mergeVoice(_ id: String, _ from: Int, into: Int) {
        guard let i = index(id), from != into else { return }
        for j in sessions[i].lines.indices where sessions[i].lines[j].voice == from { sessions[i].lines[j].voice = into }
        if var names = sessions[i].voiceNames, let moved = names.removeValue(forKey: String(from)) {
            // A turned-down guess ("") stays with the voice it was about; a real name moves over.
            if names[String(into)] == nil, !moved.isEmpty { names[String(into)] = moved }
            sessions[i].voiceNames = names.isEmpty ? nil : names
        }
        if var guesses = sessions[i].voiceGuesses, let moved = guesses.removeValue(forKey: String(from)) {
            if guesses[String(into)] == nil { guesses[String(into)] = moved }
            sessions[i].voiceGuesses = guesses.isEmpty ? nil : guesses
        }
        saveNow(id)
    }

    func setNotes(_ id: String, _ notes: MeetingNotes) {
        guard let i = index(id) else { return }
        sessions[i].notes = notes
        id == liveID ? scheduleSave(id) : saveNow(id)
    }

    // MARK: Editing

    /// An empty title, or the one shown already, goes back to the automatic one.
    func rename(_ id: String, to title: String) {
        guard let i = index(id) else { return }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t != sessions[i].displayTitle else { return }
        if t.isEmpty {
            sessions[i].title = Session.defaultTitle(sessions[i].startedAt)
            sessions[i].renamed = false
        } else {
            sessions[i].title = t
            sessions[i].renamed = true
        }
        id == liveID ? scheduleSave(id) : saveNow(id)
    }

    func delete(_ id: String) {
        guard id != liveID, let i = index(id) else { return }
        try? FileManager.default.removeItem(at: folder(id))
        sessions.remove(at: i)
    }

    func session(_ id: String?) -> Session? { id.flatMap { index($0) }.map { sessions[$0] } }

    /// A meeting made from an imported recording: stored and listed like a recorded one.
    func insert(_ s: Session) {
        var s = s
        while sessions.contains(where: { $0.id == s.id }) { s.id += "-2" }
        try? FileManager.default.createDirectory(at: folder(s.id), withIntermediateDirectories: true)
        sessions.append(s)
        sessions.sort { $0.startedAt > $1.startedAt }
        saveNow(s.id)
    }

    private func index(_ id: String) -> Int? { sessions.firstIndex(where: { $0.id == id }) }

    private func scheduleSave(_ id: String) {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveNow(id) }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    func saveNow(_ id: String) {
        guard let s = session(id) else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(s) else { return }
        try? FileManager.default.createDirectory(at: folder(id), withIntermediateDirectories: true)
        try? data.write(to: folder(id).appendingPathComponent("session.json"), options: .atomic)
    }
}

// MARK: - Export

enum TranscriptExport {
    static func clock(_ t: Double) -> String {
        let s = Int(max(0, t))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                         : String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// Experimental speaker numbers on (设置 › 通用 › 实验功能); kept in step by AppModel.
    nonisolated(unsafe) static var voices = false

    static func speakerName(_ line: TranscriptLine, _ numbers: [String: Int] = [:], _ names: [Int: String] = [:]) -> String {
        if line.speaker == "me" { return L("你") }
        if let n = numbers[line.id] { return SpeakerLabels.label(n, names) }
        return numbers.isEmpty ? L("对方") : L("未识别")
    }

    static func speakerNumbers(_ s: Session) -> [String: Int] { voices ? SpeakerLabels.numbers(s.lines) : [:] }

    static func header(_ s: Session) -> String {
        let mins = Int(s.duration / 60)
        return "\(dateText(s.startedAt, "yMMMdHHmm")) · " + (mins < 1 ? L("不到 1 分钟") : L("\(mins) 分钟"))
    }

    /// The notes as Markdown (empty when there are none).
    static func notesMarkdown(_ n: MeetingNotes?) -> String {
        guard let n, !n.isEmpty else { return "" }
        var out = "## \(L("纪要"))\n\n\(n.summary)\n\n"
        for t in n.topics {
            out += "### \(clock(t.start)) \(t.title)\n\n"
            if !t.summary.isEmpty { out += "\(t.summary)\n\n" }
            for p in t.points { out += "- \(p)\n" }
            if let f = t.fishbone {
                out += "\n**\(f.question)**\n\n"
                for b in f.branches { out += "- \(b.label)：\(b.detail)\n" }
            }
            out += "\n"
        }
        if !n.conclusions.isEmpty { out += "### \(L("结论"))\n\n" + n.conclusions.map { "- \($0.text)\n" }.joined() + "\n" }
        if !n.todos.isEmpty {
            out += "### \(L("待办"))\n\n" + n.todos.map { "- [ ] \($0.text)" + ($0.owner.map { "（\($0)）" } ?? "") + "\n" }.joined() + "\n"
        }
        if !n.terms.isEmpty {
            out += "### \(L("人名和术语"))\n\n" + n.terms.map { "- **\($0.name)** \($0.note)\n" }.joined() + "\n"
        }
        return out
    }

    static func markdown(_ s: Session) -> String {
        var out = "# \(s.displayTitle)\n\n\(header(s))\n\n"
        let notes = notesMarkdown(s.notes)
        if !notes.isEmpty { out += notes + "## \(L("文字记录"))\n\n" }
        let numbers = speakerNumbers(s), names = SpeakerLabels.names(s)
        for l in s.lines {
            out += "**[\(clock(l.t))] \(speakerName(l, numbers, names))**  \n\(l.src)\n"
            if let d = l.dst, d != l.src { out += "> \(d)\n" }
            out += "\n"
        }
        return out
    }

    static func srt(_ s: Session) -> String {
        func ts(_ t: Double) -> String {
            let ms = Int((max(0, t) * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
        }
        var out = ""
        for (i, l) in s.lines.enumerated() {
            let next = i + 1 < s.lines.count ? s.lines[i + 1].t : l.t + 4
            let end = max(l.t + 1, min(next, l.t + 8))
            out += "\(i + 1)\n\(ts(l.t)) --> \(ts(end))\n\(l.src)\n"
            if let d = l.dst, d != l.src { out += "\(d)\n" }
            out += "\n"
        }
        return out
    }

    static func docx(_ s: Session) throws -> Data {
        let doc = NSMutableAttributedString()
        func add(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .black, after: CGFloat = 4) {
            let p = NSMutableParagraphStyle()
            p.paragraphSpacing = after
            doc.append(NSAttributedString(string: text + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: weight),
                .foregroundColor: color,
                .paragraphStyle: p,
            ]))
        }
        add(s.displayTitle, size: 20, weight: .bold, after: 6)
        add(header(s), size: 10, color: .darkGray, after: 14)
        if let n = s.notes, !n.isEmpty {
            add(L("纪要"), size: 15, weight: .bold, after: 6)
            add(n.summary, size: 11, after: 10)
            for t in n.topics {
                add("\(clock(t.start))  \(t.title)", size: 12, weight: .semibold, after: 3)
                if !t.summary.isEmpty { add(t.summary, size: 11, color: .darkGray, after: 3) }
                for p in t.points { add("• \(p)", size: 11, after: 2) }
                if let f = t.fishbone {
                    add(f.question, size: 11, weight: .semibold, after: 2)
                    for b in f.branches { add("  – \(b.label)：\(b.detail)", size: 11, after: 2) }
                }
                add("", size: 6, after: 4)
            }
            if !n.conclusions.isEmpty {
                add(L("结论"), size: 12, weight: .semibold, after: 3)
                for c in n.conclusions { add("• \(c.text)", size: 11, after: 2) }
            }
            if !n.todos.isEmpty {
                add(L("待办"), size: 12, weight: .semibold, after: 3)
                for t in n.todos { add("☐ \(t.text)" + (t.owner.map { "（\($0)）" } ?? ""), size: 11, after: 2) }
            }
            add(L("文字记录"), size: 15, weight: .bold, after: 6)
        }
        let numbers = speakerNumbers(s), names = SpeakerLabels.names(s)
        for l in s.lines {
            add("[\(clock(l.t))] \(speakerName(l, numbers, names))", size: 9, weight: .semibold, color: .darkGray, after: 2)
            add(l.src, size: 11, after: 2)
            if let d = l.dst, d != l.src { add(d, size: 11, color: NSColor(calibratedWhite: 0.3, alpha: 1), after: 10) }
        }
        return try doc.data(from: NSRange(location: 0, length: doc.length),
                            documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
    }
}

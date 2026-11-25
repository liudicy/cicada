import Foundation

/// 词表: the spellings the user stands behind, and how speech recognition has misheard each. Only
/// these let a new name be fixed without asking: names the notes guess are often wrong (in a test
/// meeting 6 of 10, e.g. 巡检 → "audit"), so they stay suggestions until the user confirms one.
/// One JSON file beside the records; not a secret, so not one of the 0600 key files.
@MainActor
final class Vocabulary: ObservableObject {
    struct Term: Codable, Equatable {
        var word: String
        /// Wrong forms the recognizer produced, as confirmed or typed by the user.
        var heard: [String] = []
        /// "user" (added or imported), "live" (confirmed during a meeting).
        var source: String
        var fixes: Int = 0
        var used: Date? = nil
    }

    /// More would make every sentence's request long, and more terms means more wrong swaps.
    static let limit = 300

    @Published private(set) var terms: [Term] = []
    private let url: URL?
    var onChange: (() -> Void)?

    init(url: URL?) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder.vocabulary.decode([Term].self, from: data) {
            terms = saved
        }
    }

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(DevBuild.supportFolder).appendingPathComponent("vocabulary.json")
    }

    /// Same word whatever its width, case or spacing ("ＡＡＶＥ" is "aave").
    nonisolated static func key(_ s: String) -> String {
        s.precomposedStringWithCompatibilityMapping.lowercased()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// What a fix can teach the list, or nil: both sides trimmed of spaces and punctuation, no
    /// punctuation inside, short, and a real swap. An edit that only adds or drops words around the
    /// heard ones ("我来" → "OK我来") or ends on a full stop ("持。" → "讲。") teaches nothing.
    nonisolated static func learnable(heard: String, word: String) -> (heard: String, word: String)? {
        let edge = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)
        let h = heard.trimmingCharacters(in: edge), w = word.trimmingCharacters(in: edge)
        guard !h.isEmpty, !w.isEmpty, h.count <= 20, w.count <= 40, key(h) != key(w),
              !w.contains(h), !h.contains(w),
              h.unicodeScalars.allSatisfy({ !CharacterSet.punctuationCharacters.contains($0) }),
              w.unicodeScalars.allSatisfy({ !CharacterSet.punctuationCharacters.contains($0) || $0 == "." || $0 == "-" })
        else { return nil }
        return (h, w)
    }

    func knows(heard: String, word: String) -> Bool {
        let h = Self.key(heard), w = Self.key(word)
        return terms.contains { Self.key($0.word) == w && $0.heard.contains { Self.key($0) == h } }
    }

    /// The user said yes to a fix (or added it): the word, and the form it was heard as. A pair
    /// that isn't a word for a word (`learnable`) adds the word only, or nothing. A yes in a meeting
    /// never teaches a translation (平台 → platform): it would rewrite that word everywhere after.
    func confirm(heard: String, word: String, source: String = "live") {
        if !heard.isEmpty {
            guard let l = Self.learnable(heard: heard, word: word),
                  source == "user" || !Correction.translation(heard: l.heard, word: l.word) else { return }
            return add(heard: l.heard, word: l.word, source: source)
        }
        add(heard: "", word: word, source: source)
    }

    private func add(heard: String, word: String, source: String) {
        let w = Self.key(word)
        if let i = terms.firstIndex(where: { Self.key($0.word) == w }) {
            if !heard.isEmpty, !terms[i].heard.contains(where: { Self.key($0) == Self.key(heard) }) { terms[i].heard.append(heard) }
        } else {
            terms.append(Term(word: word, heard: heard.isEmpty ? [] : [heard], source: source))
        }
        save()
    }

    /// A heard form the user turned down twice stops being one.
    func forget(heard: String, word: String) {
        let w = Self.key(word), h = Self.key(heard)
        guard let i = terms.firstIndex(where: { Self.key($0.word) == w }) else { return }
        terms[i].heard.removeAll { Self.key($0) == h }
        save()
    }

    /// 词表 › click a word: its spelling changes; what it was heard as stays with it.
    func rename(_ word: String, to new: String) {
        let n = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n.count <= 40, let i = terms.firstIndex(where: { Self.key($0.word) == Self.key(word) }) else { return }
        if let j = terms.firstIndex(where: { Self.key($0.word) == Self.key(n) }), j != i {
            // Renamed onto a word already there: the two become one.
            for h in terms[i].heard where !terms[j].heard.contains(where: { Self.key($0) == Self.key(h) }) { terms[j].heard.append(h) }
            terms.remove(at: i)
        } else {
            terms[i].word = n
        }
        save()
    }

    /// The other words a heard form already belongs to ("莫拉" is Morpho's).
    func owners(ofHeard heard: String, except word: String? = nil) -> [String] {
        terms.filter { t in t.heard.contains { Self.key($0) == Self.key(heard) } && Self.key(t.word) != Self.key(word ?? "") }.map(\.word)
    }

    /// Back where it was, after 撤销 on a delete.
    func insert(_ term: Term, at index: Int) {
        guard !terms.contains(where: { Self.key($0.word) == Self.key(term.word) }) else { return }
        terms.insert(term, at: min(index, terms.count))
        save()
    }

    /// What 粘贴导入 would do, before it does it (the sheet's counts and its button).
    func preview(_ text: String) -> ImportResult {
        var r = ImportResult()
        var seen: Set<String> = []
        for case let entry? in Self.parse(text) {
            if entry.word.isEmpty { r.skipped.append(entry.line); continue }
            let k = Self.key(entry.word)
            if terms.contains(where: { Self.key($0.word) == k }) || seen.contains(k) { r.updated += 1 } else { r.added += 1 }
            seen.insert(k)
        }
        return r
    }

    /// 撤销: the list as it was.
    func restore(_ saved: [Term]) {
        guard saved != terms else { return }
        terms = saved
        save()
    }

    func remove(_ word: String) {
        terms.removeAll { Self.key($0.word) == Self.key(word) }
        save()
    }

    func used(_ word: String, at date: Date = Date()) {
        guard let i = terms.firstIndex(where: { Self.key($0.word) == Self.key(word) }) else { return }
        terms[i].fixes += 1
        terms[i].used = date
        save()
    }

    /// For the request: the most recently useful first, "Morpho (heard as 莫拉, 莫法)".
    func promptLines() -> [String] {
        terms.sorted { ($0.used ?? .distantPast) > ($1.used ?? .distantPast) }.prefix(Self.limit).map {
            $0.heard.isEmpty ? $0.word : "\($0.word) (heard as \($0.heard.joined(separator: ", ")))"
        }
    }

    /// 粘贴导入: one per line, heard forms after "=" ("Morpho = 莫拉、莫法"). Lines too long or empty
    /// are reported by number; a word already there gains the new heard forms.
    struct ImportResult: Equatable { var added = 0; var updated = 0; var skipped: [Int] = [] }

    nonisolated static func parse(_ text: String) -> [(line: Int, word: String, heard: [String])?] {
        text.components(separatedBy: .newlines).enumerated().compactMap { i, raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { return nil }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let word = parts[0]
            let heard = parts.count > 1
                ? parts[1].split(whereSeparator: { "、,，;；".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                : []
            guard !word.isEmpty, word.count <= 40, !word.contains(where: { $0.isNewline || $0.unicodeScalars.contains { $0.properties.generalCategory == .control } }) else {
                return (i + 1, "", [])
            }
            return (i + 1, word, heard)
        }
    }

    func importText(_ text: String) -> ImportResult {
        var r = ImportResult()
        for case let entry? in Self.parse(text) {
            if entry.word.isEmpty { r.skipped.append(entry.line); continue }
            let w = Self.key(entry.word)
            if let i = terms.firstIndex(where: { Self.key($0.word) == w }) {
                for h in entry.heard where !terms[i].heard.contains(where: { Self.key($0) == Self.key(h) }) { terms[i].heard.append(h) }
                r.updated += 1
            } else {
                terms.append(Term(word: entry.word, heard: entry.heard, source: "user"))
                r.added += 1
            }
        }
        save()
        return r
    }

    private func save() {
        onChange?()
        guard let url else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder.vocabulary.encode(terms) { try? data.write(to: url, options: .atomic) }
    }
}

private extension JSONEncoder {
    static var vocabulary: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }
}

private extension JSONDecoder {
    static var vocabulary: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

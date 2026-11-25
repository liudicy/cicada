import Foundation
import NaturalLanguage

/// The other side's finished lines before they are recorded and translated: tidied, and joined to the
/// line before when a pause cut one sentence in two.
enum HeardText {
    /// Speech recognition leaves stray marks where it hears breaths and hesitations: "in..........",
    /// ", , that", ". , that is". They start lines, and a translator turns them into "，……" or worse.
    static func clean(_ text: String) -> String {
        var s = text
        // Two dots or more, with or without spaces or commas between: one ellipsis.
        s = s.replacingOccurrences(of: #"\s*[.。]{2,}|\s*…+"#, with: "…", options: .regularExpression)
        s = s.replacingOccurrences(of: #"…(?:[\s,，]*…)+"#, with: "…", options: .regularExpression)
        // ", ," and ",," are one comma; a comma against an ellipsis adds nothing.
        s = s.replacingOccurrences(of: #"([,，])(?:\s*[,，])+"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[,，]\s*…|…\s*[,，]"#, with: "…", options: .regularExpression)
        // "UALE ," → "UALE,".
        s = s.replacingOccurrences(of: #"\s+([,，.。…?？!！;；:：])"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        // A line starts with a word, not with what was left of the last one.
        let lead: Set<Character> = [".", ",", ";", ":", "!", "?", "…", "、", "，", "。", "；", "：", "！", "？", "-", "–", "—"]
        s = String(s.drop(while: { lead.contains($0) || $0.isWhitespace }))
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The final text, unless it lost a good part of what the last draft of the line had. In fast
    /// speech without a break the recognizer's final pass drops whole phrases ("needs the budget.
    /// for next year by the end. of this month. in.") that its drafts had heard (issue #1), whether
    /// the line ended on its own or was cut. The draft may misspell a word; that beats losing five.
    static func fuller(final: String, draft: String) -> String {
        // Words, or characters in Chinese and Japanese (about two to a word).
        let cjk = (final + draft).unicodeScalars.contains { $0.properties.isIdeographic }
        func size(_ s: String) -> Int {
            cjk ? s.filter { $0.isLetter || $0.isNumber }.count
                : s.split(whereSeparator: { $0.isWhitespace }).filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }.count
        }
        let f = size(final), d = size(draft)
        guard d >= f + (cjk ? 6 : 3), Double(d) >= Double(f) * 1.15 else { return final }
        return clean(draft)
    }

    /// The line ends in a run of Latin letters, the way a Chinese, Japanese or Korean model writes
    /// English it hears: 15 letters or more after its last CJK character.
    static func endsInLatin(_ text: String) -> Bool {
        let isCJK: (Character) -> Bool = { c in
            c.unicodeScalars.contains { (0x3040...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }
        }
        let tail = text.reversed().prefix(while: { !isCJK($0) })
        return tail.filter { $0.isASCII && $0.isLetter }.count >= 15
    }

    /// A draft that has just reached the end of a sentence: it ends in 。/./?/!, and is long enough
    /// to be a line of its own (12 Chinese or Japanese characters, 5 words). The recognizer writes
    /// the mark the moment the sentence's last word is heard, so that draft's end is where the
    /// sentence ends: fast speech with no pause between sentences (issue #20) is ended there.
    static func endsSentence(_ draft: String) -> Bool {
        let t = draft.trimmingCharacters(in: .whitespaces)
        // "..." and "…" trail off; "3." is a number being read.
        guard let last = t.last, "。！？.!?".contains(last), !t.hasSuffix(".."),
              !(last == "." && t.dropLast().last?.isNumber == true) else { return false }
        let cjk = t.unicodeScalars.contains { $0.properties.isIdeographic || (0x3040...0x30FF).contains($0.value) }
        return cjk ? t.filter(\.isLetter).count >= 12 : t.split(separator: " ").count >= 5
    }

    /// A line ended at a sentence comes back running into the next one ("…思います。前回こちらの"):
    /// the draft's end trails its words by the recognizer's lag. Split at the last sentence end, when
    /// the head is a line of its own and the tail has words; the tail starts the next line.
    static func splitAtSentenceEnd(_ text: String) -> (head: String, tail: String)? {
        var i = text.endIndex
        while i > text.startIndex {
            i = text.index(before: i)
            let head = String(text[...i])
            guard "。！？.!?".contains(text[i]), endsSentence(head) else { continue }
            let tail = text[text.index(after: i)...].trimmingCharacters(in: .whitespaces)
            guard tail.contains(where: \.isLetter) else { return nil }
            return (head.trimmingCharacters(in: .whitespaces), tail)
        }
        return nil
    }

    /// Where a long line may be ended when no sentence end comes: Chinese recognition writes almost
    /// no 。 (4% of drafts in a fast review) but often a ，, so a line runs on for 10 s and 80 chars.
    enum Boundary: Int, Comparable {
        /// Between two words: only for a line past `capped`.
        case word
        /// After a comma, before a Chinese connective (所以, 但是…) or after a final particle (吧, 呢…).
        case clause
        case sentence
        static func < (a: Boundary, b: Boundary) -> Bool { a.rawValue < b.rawValue }
    }

    /// Chinese words that start a clause, and particles that end one.
    static let connectives: Set<String> = ["所以", "但是", "因为", "然后", "可是", "而且", "不过", "其实", "反正",
                                           "如果", "虽然", "或者", "另外", "接下来", "总之", "因此", "于是", "就是说"]
    static let particles: Set<String> = ["吧", "呢", "吗", "啊", "嘛", "呀", "啦"]

    /// Offsets inside a Chinese connective, each with where it starts: no line ends there, even
    /// where the tokenizer splits the word ("所" "以").
    static func insideConnectives(_ chars: [Character]) -> [Int: Int] {
        var out: [Int: Int] = [:]
        for c in connectives {
            let w = Array(c)
            guard chars.count >= w.count else { continue }
            for p in 0...(chars.count - w.count) where Array(chars[p..<(p + w.count)]) == w {
                for i in (p + 1)..<(p + w.count) { out[i] = p }
            }
        }
        return out
    }

    static func isCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.properties.isIdeographic || (0x3040...0x30FF).contains($0.value) }
    }

    /// How long a piece is: Chinese or Japanese characters, or words.
    static func size(_ text: String) -> Int {
        isCJK(text) ? text.filter(\.isLetter).count : text.split(whereSeparator: \.isWhitespace).count
    }

    /// A line this long gets a clause cut (`clause`) or, past `capped`, a cut between words.
    static func clauseFrom(_ code: String) -> Int { code.hasPrefix("zh") ? 24 : (code == "ja" ? 40 : 20) }
    static func capped(_ code: String) -> Int { ["zh", "ja"].contains(where: code.hasPrefix) ? 60 : 25 }

    /// Every place in `text` a new line could start, as a character offset, with its kind.
    static func boundaries(_ text: String, language code: String) -> [(at: Int, kind: Boundary)] {
        var out: [Int: Boundary] = [:]
        func add(_ at: Int, _ kind: Boundary) {
            guard at > 0, at < text.count else { return }
            out[at] = max(out[at] ?? kind, kind)
        }
        let commas: Set<Character> = code.hasPrefix("zh") ? ["，", ","] : (code == "ja" ? ["、", "，"] : [","])
        for (i, ch) in text.enumerated() {
            if "。！？!?".contains(ch) || (ch == "." && i + 1 < text.count) { add(i + 1, .sentence) }
            if commas.contains(ch) { add(i + 1, .clause) }
        }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        if code.hasPrefix("zh") { tokenizer.setLanguage(.simplifiedChinese) }
        var starts = Set<Int>()
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let start = text.distance(from: text.startIndex, to: range.lowerBound)
            starts.insert(start)
            add(start, .word)
            if code.hasPrefix("zh"), particles.contains(String(text[range])) {
                add(text.distance(from: text.startIndex, to: range.upperBound), .clause)
            }
            return true
        }
        if code.hasPrefix("zh") {
            // The tokenizer may split a connective ("所" "以"): it counts when it starts and ends on
            // word boundaries, so one inside a longer word does not.
            let chars = Array(text)
            var found: [Int: Int] = [:]
            for p in starts {
                for c in connectives where p + c.count <= chars.count && String(chars[p..<(p + c.count)]) == c
                    && (starts.contains(p + c.count) || p + c.count == chars.count) {
                    found[p] = c.count
                }
            }
            // "因为如果…" starts one clause: only the first of two connectives in a row.
            for p in found.keys where !found.contains(where: { $0.key + $0.value == p }) { add(p, .clause) }
            // Nor is a word gap inside one ("所" | "以").
            for (p, n) in found { for i in (p + 1)..<(p + n) where out[i] == .word { out[i] = nil } }
        }
        // Spaces belong to the line before: a boundary sits after them.
        return out.keys.sorted().map { at in
            var a = at
            while a < text.count, text[text.index(text.startIndex, offsetBy: a)].isWhitespace { a += 1 }
            return (a, out[at]!)
        }
    }

    /// A line Cicada ended at a clause or between words comes back running on past it: split it at
    /// the boundary of at least `kind` nearest `near` (the draft's head when the cut was asked for).
    /// The final may drop the draft's comma: then the word gap nearest the cut.
    static func split(_ text: String, near: Int, kind: Boundary, language code: String) -> (head: String, tail: String)? {
        if let s = split(text, near: near, kind: kind, within: max(8, near / 3), language: code) { return s }
        return kind > .word ? split(text, near: near, kind: .word, within: 3, language: code) : nil
    }

    private static func split(_ text: String, near: Int, kind: Boundary, within: Int,
                              language code: String) -> (head: String, tail: String)? {
        let fit = boundaries(text, language: code).filter { b in
            guard b.kind >= kind, abs(b.at - near) <= within else { return false }
            let head = String(text.prefix(b.at)), tail = String(text.dropFirst(b.at))
            return size(head) >= (isCJK(head) ? 12 : 5) && tail.contains(where: \.isLetter)
        }
        guard let best = fit.min(by: { (abs($0.at - near), -$0.kind.rawValue) < (abs($1.at - near), -$1.kind.rawValue) }) else { return nil }
        let head = text.prefix(best.at).trimmingCharacters(in: .whitespaces)
        let tail = text.dropFirst(best.at).trimmingCharacters(in: .whitespaces)
        return (head, tail)
    }

    /// The longest pause, in seconds, that still joins two pieces of one sentence.
    static let joinGap = 1.5
    /// A line this long takes nothing more: past it a translation is slow and the line hard to read.
    /// The piece that finishes a shorter line joins it, unless in Chinese or Japanese the two would
    /// pass `capped`: that long a line is ended at a clause or word anyway.
    static let joinWords = 40

    /// Whether `next` carries on `previous`, from the same voice, rather than starting a sentence.
    /// `gap`: seconds of audio between them. `cut`: Cicada ended `previous` at a pause (ListenEngine's
    /// `maybeCutSentence`), so its closing "." is the recognizer's guess, not the speaker's: it is
    /// ignored when `next` starts in lower case (scripts without case keep it).
    static func continues(_ previous: String, _ next: String, gap: Double, cut: Bool) -> Bool {
        guard gap >= -0.5, gap <= joinGap, let last = previous.last, let first = next.first else { return false }
        let cjk = previous.unicodeScalars.contains { $0.properties.isIdeographic }
        let size = cjk ? previous.count / 2 : previous.split(separator: " ").count
        guard size < joinWords else { return false }
        // Three pieces of fast Japanese joined into 113 characters (issue #20).
        if isCJK(previous + next), Self.size(previous + next) > capped("zh") { return false }
        switch last {
        case "?", "!", "？", "！": return false
        case ".", "。": return cut && first.isLowercase
        default: return true
        }
    }

    static func join(_ previous: String, _ next: String) -> String {
        let cjk = previous.unicodeScalars.contains { $0.properties.isIdeographic }
        // A cut's guessed "." goes: "are going to be." + "in the…" reads as one sentence.
        var head = previous
        if head.hasSuffix(".") && !head.hasSuffix("…") { head.removeLast() }
        if head.hasSuffix("。") { head.removeLast() }
        return cjk ? head + next : head + " " + next
    }
}

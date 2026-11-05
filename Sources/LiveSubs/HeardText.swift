import Foundation

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

    /// The longest pause, in seconds, that still joins two pieces of one sentence.
    static let joinGap = 1.5
    /// A line this long takes nothing more: past it a translation is slow and the line hard to read.
    /// The piece that finishes a shorter line always joins it, so a sentence is never left half.
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
